import Darwin
import Foundation

public struct LaunchError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// The one place Tunnelbar starts or stops a process.
///
/// `ReadOnlyCommand` deliberately cannot express this, and this type
/// deliberately cannot express `ReadOnlyCommand`'s job: it will only ever exec
/// a binary named `cloudflared`, and it will only ever signal a pid that
/// re-validates as app-owned at the moment of signalling. Neither `launchctl`
/// nor `brew` is reachable from here, so no code path in the app can stop a
/// connector it did not start.
public enum ConnectorLauncher {
    /// Standard install locations, probed in order. `PATH` is not consulted:
    /// a GUI app's environment is not the user's shell environment, and an
    /// attacker-writable `PATH` entry must never decide what gets exec'd.
    static let searchPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared",
    ]

    public static func locateCloudflared() -> String? {
        if let known = searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return known
        }
        // Falls back to whatever an already-running connector uses, covering
        // installs in a non-standard prefix.
        return ProcessScanner.connectorProcesses().first?.executablePath
    }

    static var logDirectory: URL {
        ConnectorRegistry.storeURL.deletingLastPathComponent().appendingPathComponent("logs")
    }

    /// Quick tunnels may only expose a loopback origin: they publish their
    /// target to the public internet, so a LAN or remote address must never be
    /// exposed by a typo.
    static func validate(_ spec: ConnectorSpec) throws {
        guard case .quickTunnel(let localURL) = spec else { return }
        guard let parsed = URL(string: localURL),
              let host = parsed.host,
              ["localhost", "127.0.0.1", "::1"].contains(host),
              ["http", "https", "tcp"].contains(parsed.scheme ?? "")
        else {
            throw LaunchError("quick tunnels may only expose a loopback origin, got \(localURL)")
        }
    }

    /// Arguments and environment for a spec.
    ///
    /// A token is passed in the **environment**, never in `--token`. Process
    /// arguments appear in `ps` output for every user on the machine — exactly
    /// how a live tunnel token is exposed by a `--token`-style launchd agent,
    /// and the reason `Redaction` exists. The environment is not shown by `ps`.
    ///
    /// The child gets a minimal environment rather than an inherited one: a GUI
    /// app's environment is not the user's shell environment, and passing it
    /// through would hand the connector variables nobody chose for it.
    static func invocation(for spec: ConnectorSpec) throws -> ([String], [String: String]) {
        var environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        switch spec {
        case .quickTunnel(let localURL):
            return (["tunnel", "--no-autoupdate", "--url", localURL], environment)
        case .namedTunnel(let tunnelID):
            guard let token = try KeychainStore.read(.tunnelToken(tunnelID: tunnelID)) else {
                throw LaunchError("no tunnel token stored for \(tunnelID)")
            }
            environment["TUNNEL_TOKEN"] = token
            return (["tunnel", "--no-autoupdate", "run"], environment)
        }
    }

    /// Spawns the process for a spec and returns the resulting instance.
    /// Does not touch the registry; callers decide what to record.
    static func launch(_ spec: ConnectorSpec) throws -> RunningInstance {
        try validate(spec)
        guard let executable = locateCloudflared() else {
            throw LaunchError("cloudflared not found in any standard location")
        }
        let (arguments, environment) = try invocation(for: spec)

        let name: String
        switch spec {
        case .quickTunnel: name = "quick"
        case .namedTunnel(let tunnelID): name = "tunnel-\(tunnelID)"
        }
        let logURL = try prepareLog(named: name)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            throw LaunchError("could not open a log file at \(logURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle

        do {
            try process.run()
        } catch {
            // Deliberately interpolates nothing token-derived.
            throw LaunchError("could not start cloudflared for \(spec.descriptor)")
        }

        let pid = process.processIdentifier
        guard let info = ProcessScanner.bsdInfo(of: pid) else {
            throw LaunchError("started pid \(pid) but could not read its start time")
        }
        return RunningInstance(pid: pid, startedAt: info.startedAt, logPath: logURL.path)
    }

    /// Starts a new managed connector and records it.
    ///
    /// Refuses if Tunnelbar already runs one for the same spec: a second
    /// connector from one tunnel's token creates duplicate edge connections for
    /// that tunnel. This cannot see connectors owned by launchd
    /// or a shell, so it is a guard against Tunnelbar duplicating its own work,
    /// not a guarantee about the whole machine.
    public static func start(_ spec: ConnectorSpec) throws -> ManagedConnector {
        guard !ConnectorRegistry.hasLiveConnector(for: spec) else {
            throw LaunchError("Tunnelbar already runs a connector for \(spec.descriptor)")
        }
        let instance = try launch(spec)
        let managed = ManagedConnector(
            spec: spec, instance: instance, autoRestart: spec.defaultAutoRestart)
        ConnectorRegistry.upsert(managed)
        return managed
    }

    /// Creates an empty, owner-only log file for a connector we are starting.
    /// `0o600` because a connector's log carries hostnames and, at higher
    /// verbosity, more besides.
    static func prepareLog(named name: String) throws -> URL {
        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)
        let url = logDirectory.appendingPathComponent(
            "\(name)-\(Int(Date().timeIntervalSince1970)).log")
        guard FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw LaunchError("could not create a log file at \(url.path)")
        }
        return url
    }

    /// Stops a connector Tunnelbar owns and forgets it.
    ///
    /// Re-validates liveness immediately before signalling rather than trusting
    /// the value it was handed. A stale instance whose pid has been recycled
    /// would otherwise deliver SIGTERM to an unrelated process — conceivably a
    /// connector this app must never touch.
    ///
    /// Sends SIGTERM only: `cloudflared` handles it with a graceful shutdown
    /// that unregisters its edge connections, where SIGKILL would strand them.
    ///
    /// Removes the managed entry rather than merely clearing `autoRestart`, so
    /// the supervisor cannot resurrect something the user deliberately stopped.
    public static func stop(_ managed: ManagedConnector) throws {
        defer { ConnectorRegistry.remove(id: managed.id) }
        guard let instance = managed.instance else { return }
        guard ConnectorRegistry.isLive(instance) else {
            throw LaunchError(
                "refusing to signal pid \(instance.pid): it is no longer the connector "
                + "Tunnelbar started")
        }
        guard kill(instance.pid, SIGTERM) == 0 else {
            throw LaunchError(
                "SIGTERM to pid \(instance.pid) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// The public `trycloudflare.com` hostname, once the connector logs it.
    ///
    /// This is the log-parsing fallback, used where it actually
    /// applies: Tunnelbar knows the log location for connectors it started.
    public static func quickTunnelHostname(logPath: String) -> String? {
        guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else { return nil }
        for line in log.split(separator: "\n").reversed() {
            guard let range = line.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
                                         options: .regularExpression) else { continue }
            return String(line[range])
        }
        return nil
    }
}
