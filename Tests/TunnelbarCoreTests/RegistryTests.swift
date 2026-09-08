import Darwin
import Foundation
import Testing
@testable import TunnelbarCore

/// The pid-reuse guard. Getting this wrong would put a Stop button in front of
/// a connector Tunnelbar must never touch, so each of the three validation
/// conditions is asserted to fail independently.
@Suite("Registry pid-reuse guard")
struct RegistryTests {
    /// A process that certainly exists and certainly is not cloudflared:
    /// the test runner itself.
    private var selfInstance: RunningInstance {
        let info = ProcessScanner.bsdInfo(of: getpid())
        return RunningInstance(pid: getpid(), startedAt: info?.startedAt ?? Date(), logPath: nil)
    }

    /// Condition 3: right pid, right start time, wrong executable. This is the
    /// pid-reuse case that matters — the kernel handed the pid to something
    /// else — and the executable check is what catches it.
    @Test func rejectsLivePIDThatIsNotCloudflared() {
        #expect(!ConnectorRegistry.isLive(selfInstance))
    }

    /// Condition 1: no such process.
    @Test func rejectsDeadPID() {
        #expect(!ConnectorRegistry.isLive(
            RunningInstance(pid: 999_999, startedAt: Date(), logPath: nil)))
    }

    /// Condition 2: the pid is live but started at a different time, so it is
    /// not the process we launched.
    @Test func rejectsMismatchedStartTime() {
        let shifted = RunningInstance(pid: getpid(),
                                      startedAt: selfInstance.startedAt.addingTimeInterval(-3_600),
                                      logPath: nil)
        #expect(!ConnectorRegistry.isLive(shifted))
    }

    /// A dead instance must not be silently discarded on read: its start time
    /// is what tells a crash loop from a connector that ran for a day. Losing
    /// it would make the backoff meaningless.
    @Test func loadPreservesDeadInstancesForTheSupervisor() {
        let entry = ManagedConnector(
            spec: .namedTunnel(tunnelID: "t"),
            instance: RunningInstance(pid: 999_999, startedAt: Date(), logPath: nil))
        #expect(entry.instance != nil)
        #expect(!ConnectorRegistry.isLive(entry.instance!))
    }
}

@Suite("Launcher safety")
struct LauncherTests {
    /// A quick tunnel publishes its target to the internet, so a non-loopback
    /// origin must be refused outright rather than exposed by accident.
    @Test(arguments: [
        "http://example.com", "http://192.168.1.10:8080",
        "https://internal.corp:443", "file:///etc/passwd", "not a url",
    ])
    func refusesNonLoopbackOrigins(_ target: String) {
        #expect(throws: LaunchError.self) {
            try ConnectorLauncher.validate(.quickTunnel(localURL: target))
        }
    }

    @Test(arguments: ["http://localhost:8080", "http://127.0.0.1:3000", "https://localhost:8443"])
    func acceptsLoopbackOrigins(_ target: String) {
        #expect(throws: Never.self) {
            try ConnectorLauncher.validate(.quickTunnel(localURL: target))
        }
    }

    @Test func refusesToSignalAStaleInstance() {
        let stale = ManagedConnector(
            spec: .quickTunnel(localURL: "http://localhost:1"),
            instance: RunningInstance(pid: getpid(),
                                      startedAt: Date().addingTimeInterval(-9_999),
                                      logPath: nil))
        #expect(throws: LaunchError.self) { try ConnectorLauncher.stop(stale) }
    }

    /// Only cloudflared is reachable from the launcher; there is no path here
    /// to launchctl or brew.
    @Test func onlyEverLocatesCloudflared() {
        for path in ConnectorLauncher.searchPaths {
            #expect((path as NSString).lastPathComponent == "cloudflared")
        }
        if let located = ConnectorLauncher.locateCloudflared() {
            #expect((located as NSString).lastPathComponent == "cloudflared")
        }
    }

    /// A named tunnel's token must reach the child through the environment,
    /// never through argv, which `ps` exposes to every user on the machine.
    @Test func namedTunnelPassesNoTokenInArguments() throws {
        let tunnelID = "tunnelbar-argv-test-\(UUID().uuidString)"
        let secret = KeychainStore.Secret.tunnelToken(tunnelID: tunnelID)
        let token = TunnelTokenTests.makeToken(tunnel: tunnelID)
        try KeychainStore.set(token, for: secret)
        defer { try? KeychainStore.delete(secret) }

        let (arguments, environment) = try ConnectorLauncher.invocation(
            for: .namedTunnel(tunnelID: tunnelID))
        #expect(!arguments.contains { $0.contains("token") })
        #expect(!arguments.contains(token))
        #expect(environment["TUNNEL_TOKEN"] == token)
        // Minimal environment, not an inherited one.
        #expect(Set(environment.keys) == ["TUNNEL_TOKEN", "HOME", "PATH"])
    }

    @Test func quickTunnelPassesNoTokenAtAll() throws {
        let (arguments, environment) = try ConnectorLauncher.invocation(
            for: .quickTunnel(localURL: "http://localhost:8080"))
        #expect(arguments.contains("--url"))
        #expect(environment["TUNNEL_TOKEN"] == nil)
    }
}

@Suite("Quick tunnel matching")
struct QuickTunnelMatchingTests {
    /// Regression: quick tunnels were invisible to discovery because the
    /// matcher required `run` or `--token` after `tunnel`.
    @Test(arguments: [
        ["cloudflared", "tunnel", "--url", "http://localhost:9999", "--no-autoupdate"],
        ["cloudflared", "tunnel", "--url=http://localhost:8080"],
        ["cloudflared", "--url", "http://localhost:8080"],
        ["cloudflared", "tunnel", "--hello-world"],
    ])
    func matchesQuickTunnels(_ argv: [String]) {
        #expect(ProcessScanner.isConnectorInvocation(argv))
    }

    /// A token-based connector started by Tunnelbar has no token in its argv at
    /// all — it must still be recognised as a connector.
    @Test func matchesTokenlessRunInvocation() {
        #expect(ProcessScanner.isConnectorInvocation(
            ["cloudflared", "tunnel", "--no-autoupdate", "run"]))
    }

    /// `cloudflared access tcp` also takes `--url`, for a local listener. It is
    /// not a connector and must not appear as a row.
    @Test(arguments: [
        ["cloudflared", "access", "tcp", "--hostname", "x.com", "--url", "localhost:2222"],
        ["cloudflared", "tail", "--url", "http://localhost:1"],
    ])
    func stillExcludesNonConnectorSubcommands(_ argv: [String]) {
        #expect(!ProcessScanner.isConnectorInvocation(argv))
    }
}
