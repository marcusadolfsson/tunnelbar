import Foundation

/// The only way `TunnelbarCore` is allowed to spawn a subprocess.
///
/// Tunnelbar must never mutate a connector it did not start — no `launchctl
/// bootout`, no `brew services start`, nothing that could make a supervised
/// connector flap. Rather than rely on review to catch a
/// bad invocation, the executable and its verbs are checked against an
/// allowlist here, and nothing in the discovery path has any other way to run a
/// command. Adding a mutating verb requires editing this file, which is a much
/// louder change than adding an argument at a call site.
enum ReadOnlyCommand {
    /// Executable path → the sub-verbs it may be invoked with.
    private static let allowed: [String: Set<String>] = [
        "/bin/launchctl": ["print"],
        "/usr/bin/launchctl": ["print"],
        "/opt/homebrew/bin/brew": ["services"],
        "/usr/local/bin/brew": ["services"],
    ]

    /// `brew services` itself takes a sub-verb; only the listing one is read-only.
    private static let allowedSecondVerb: [String: Set<String>] = [
        "services": ["list"],
    ]

    struct Rejected: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs an allowlisted read-only command and returns its stdout.
    ///
    /// Returns nil when the executable is absent — a machine without Homebrew
    /// is a normal machine, not an error.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> String? {
        guard let verbs = allowed[executable] else {
            throw Rejected(description: "refusing to run non-allowlisted executable \(executable)")
        }
        guard let verb = arguments.first, verbs.contains(verb) else {
            throw Rejected(description: "refusing to run \(executable) \(arguments.first ?? "")")
        }
        if let second = allowedSecondVerb[verb] {
            guard arguments.count > 1, second.contains(arguments[1]) else {
                throw Rejected(description: "refusing to run \(executable) \(arguments.prefix(2).joined(separator: " "))")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()  // discarded; absence is reported as nil

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a pipe that fills up would deadlock otherwise.
        let data = output.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()  // our own child only, never a connector
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
