import Darwin
import Foundation

/// One `cloudflared` process found on this machine.
public struct RunningProcess: Sendable {
    public let pid: pid_t
    public let executablePath: String
    /// Already redacted. `ProcessScanner` never surfaces raw argv, so a token
    /// captured from `KERN_PROCARGS2` cannot escape this file.
    public let redactedArguments: [String]
    public let parentPID: pid_t
    public let startedAt: Date
}

/// Enumerates `cloudflared` processes using `libproc` and `sysctl`.
///
/// Read-only by construction: it opens no files belonging to the processes it
/// inspects and never signals them.
public enum ProcessScanner {
    /// Every pid on the system the caller is allowed to see.
    static func allPIDs() -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        // Ask for extra headroom: processes can appear between the sizing call
        // and the fetch, and a full buffer is indistinguishable from a truncated one.
        let capacity = Int(count) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress,
                          Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// Absolute executable path, or nil if the process is gone or unreadable.
    static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN, but the macro is not
        // importable into Swift, so the value is spelled out.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    /// Parent pid and start time, via `PROC_PIDTBSDINFO`.
    static func bsdInfo(of pid: pid_t) -> (parentPID: pid_t, startedAt: Date)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard written == size else { return nil }
        let seconds = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return (pid_t(bitPattern: info.pbi_ppid), Date(timeIntervalSince1970: seconds))
    }

    /// Full argv for `pid`, via `sysctl KERN_PROCARGS2`.
    ///
    /// The buffer layout is: `int32 argc`, the exec path, NUL padding, then
    /// `argc` NUL-terminated arguments, then the environment — which we stop
    /// before, deliberately: `TUNNEL_TOKEN` lives there.
    static func rawArguments(of pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argMax))
        var bufferSize = Int(argMax)
        var argsMIB: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&argsMIB, 3, &buffer, &bufferSize, nil, 0) == 0,
              bufferSize > MemoryLayout<Int32>.size
        else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc > 0 else { return nil }

        return buffer.withUnsafeBufferPointer { pointer -> [String]? in
            guard let base = pointer.baseAddress else { return nil }
            let end = base + bufferSize
            var cursor = base + MemoryLayout<Int32>.size

            // Skip the exec path, then the NUL padding that follows it.
            while cursor < end, cursor.pointee != 0 { cursor += 1 }
            while cursor < end, cursor.pointee == 0 { cursor += 1 }

            var arguments: [String] = []
            arguments.reserveCapacity(Int(argc))
            while cursor < end, arguments.count < Int(argc) {
                let start = cursor
                while cursor < end, cursor.pointee != 0 { cursor += 1 }
                let bytes = UnsafeBufferPointer(start: start, count: start.distance(to: cursor))
                arguments.append(String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                cursor += 1  // step over the NUL; stop before the environment
            }
            return arguments
        }
    }

    /// Flags that only appear on a long-lived connector.
    ///
    /// `--url` and `--hello-world` are how quick tunnels are spelled, and both
    /// are valid with or without the `tunnel` subcommand — `cloudflared --url
    /// http://localhost:8000` is accepted shorthand.
    private static let connectorFlags = ["--token", "--url", "--hello-world"]

    /// Subcommands that take a connector-looking flag without being one.
    /// `cloudflared access tcp --hostname H --url L` opens a local listener; it
    /// is not a tunnel connector and must not appear as a row.
    private static let nonConnectorSubcommands: Set<String> = ["access", "tail"]

    /// Whether an argv describes a long-lived connector rather than some other
    /// `cloudflared` invocation (`tunnel list`, `--version`, `access`, …).
    ///
    /// Errs toward inclusion: a connector missing from the menu defeats the
    /// point of the app, whereas a spurious row would be caught immediately by
    /// the metrics probe failing. Inclusion is still positive rather than
    /// denylisted, so an unrecognised future subcommand is simply not matched.
    static func isConnectorInvocation(_ arguments: [String]) -> Bool {
        let tokens = arguments.dropFirst()  // argv[0] is the executable path
        guard !tokens.contains(where: nonConnectorSubcommands.contains) else { return false }

        if let tunnelIndex = tokens.firstIndex(of: "tunnel"),
           tokens[tokens.index(after: tunnelIndex)...].contains("run") {
            return true
        }
        return tokens.contains { token in
            connectorFlags.contains { token == $0 || token.hasPrefix("\($0)=") }
        }
    }

    /// All `cloudflared` connector processes currently running.
    ///
    /// Matches on the executable's filename plus a `tunnel run`-shaped argv, so
    /// a connector installed somewhere other than Homebrew is still found.
    public static func connectorProcesses() -> [RunningProcess] {
        allPIDs().compactMap { pid -> RunningProcess? in
            guard let path = executablePath(of: pid),
                  (path as NSString).lastPathComponent == "cloudflared",
                  let arguments = rawArguments(of: pid),
                  isConnectorInvocation(arguments),
                  let info = bsdInfo(of: pid)
            else { return nil }

            return RunningProcess(
                pid: pid,
                executablePath: path,
                redactedArguments: Redaction.redact(arguments: arguments),
                parentPID: info.parentPID,
                startedAt: info.startedAt
            )
        }
    }
}
