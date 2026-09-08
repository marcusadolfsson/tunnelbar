import Foundation
import Testing
@testable import TunnelbarCore

/// Tests for the rule in the core rule: never offer lifecycle controls for a
/// connector this app did not start. These guard the one failure mode with
/// real-world consequences, so they assert the permissive direction explicitly
/// rather than only checking the happy path.
@Suite("Ownership safety")
struct OwnershipSafetyTests {
    @Test func onlyAppOwnedConnectorsAreManageable() {
        #expect(Ownership.tunnelbar.isManageable)
        for ownership in [Ownership.launchd, .homebrew, .shell, .unknown] {
            #expect(!ownership.isManageable, "\(ownership) must stay read-only")
        }
    }

    /// The JSON mirror of `isManageable` must never disagree with the enum.
    @Test func reportMirrorsManageabilityFaithfully() throws {
        let connector = Connector(
            pid: 10269, executablePath: "/opt/homebrew/bin/cloudflared",
            redactedArguments: ["cloudflared", "tunnel", "run", "--token", "<redacted>"],
            startedAt: Date(), uptimeSeconds: 0,
            ownership: .launchd, ownerLabel: "com.example.tunnel",
            isManageable: Ownership.launchd.isManageable,
            health: .healthy, metrics: nil, metricsError: nil)

        let encoded = try JSONEncoder().encode(connector)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["isManageable"] as? Bool == false)
        #expect(json["ownership"] as? String == "launchd")
    }

    /// A `--token` value must not survive into an encoded connector, whatever
    /// else changes about the model.
    @Test func encodedConnectorCarriesNoToken() throws {
        let argv = ["cloudflared", "tunnel", "run", "--token", "eyJhIjoiU1lOVEhFVElDU0VDUkVUVkFMVUUxMjM0NTY3ODkwIn0="]
        let connector = Connector(
            pid: 1, executablePath: "/opt/homebrew/bin/cloudflared",
            redactedArguments: Redaction.redact(arguments: argv),
            startedAt: Date(), uptimeSeconds: 0,
            ownership: .launchd, ownerLabel: "com.example.tunnel",
            isManageable: false, health: .healthy, metrics: nil, metricsError: nil)

        let json = String(decoding: try JSONEncoder().encode(connector), as: UTF8.self)
        #expect(!json.contains("eyJhIjoi"))
        #expect(json.contains("<redacted>"))
    }
}

@Suite("Connector matching")
struct ConnectorMatchingTests {
    @Test(arguments: [
        ["cloudflared", "--no-autoupdate", "tunnel", "run", "--token", "x"],
        ["cloudflared", "tunnel", "run", "my-tunnel"],
        ["cloudflared", "tunnel", "--token", "x"],
    ])
    func matchesConnectorInvocations(_ argv: [String]) {
        #expect(ProcessScanner.isConnectorInvocation(argv))
    }

    /// Short-lived CLI invocations share the binary but are not connectors, and
    /// listing them would put phantom rows in the menu.
    @Test(arguments: [
        ["cloudflared", "tunnel", "list"],
        ["cloudflared", "--version"],
        ["cloudflared", "access", "ssh", "--hostname", "example.com"],
        ["cloudflared", "update"],
    ])
    func ignoresNonConnectorInvocations(_ argv: [String]) {
        #expect(!ProcessScanner.isConnectorInvocation(argv))
    }

    /// `run` must be read as a sub-verb of `tunnel`, not matched anywhere.
    @Test func requiresRunAfterTunnel() {
        #expect(!ProcessScanner.isConnectorInvocation(["cloudflared", "run", "tunnel"]))
    }
}

@Suite("Health rollup")
struct HealthTests {
    private func snapshot(ready: Int?) -> MetricsSnapshot {
        MetricsSnapshot(port: 20241, connectorID: "id", readyConnections: ready,
                        haConnections: ready, edgeConnections: [],
                        totalRequests: nil, concurrentRequests: nil)
    }

    @Test func fullConnectionSetIsHealthy() {
        #expect(DiscoveryEngine.health(for: snapshot(ready: 4)) == .healthy)
    }

    @Test(arguments: [1, 2, 3])
    func partialConnectionsAreDegraded(_ ready: Int) {
        #expect(DiscoveryEngine.health(for: snapshot(ready: ready)) == .degraded)
    }

    @Test func zeroConnectionsIsDown() {
        #expect(DiscoveryEngine.health(for: snapshot(ready: 0)) == .down)
    }

    /// Unreachable metrics is not the same as a dead tunnel; conflating them
    /// would show a red status item for a perfectly healthy connector.
    @Test func missingMetricsIsUnknownNotDown() {
        #expect(DiscoveryEngine.health(for: nil) == .unknown)
        #expect(DiscoveryEngine.health(for: snapshot(ready: nil)) == .unknown)
    }

    /// The status item shows the worst case across all connectors.
    @Test func reportRollsUpWorstHealth() {
        func connector(_ health: Health) -> Connector {
            Connector(pid: 1, executablePath: "/x", redactedArguments: [],
                      startedAt: Date(), uptimeSeconds: 0, ownership: .unknown,
                      ownerLabel: nil, isManageable: false, health: health,
                      metrics: nil, metricsError: nil)
        }
        #expect(DiscoveryReport(generatedAt: Date(),
                                connectors: [connector(.healthy), connector(.degraded)],
                                notes: []).overallHealth == .degraded)
        #expect(DiscoveryReport(generatedAt: Date(),
                                connectors: [connector(.down), connector(.healthy)],
                                notes: []).overallHealth == .down)
        #expect(DiscoveryReport(generatedAt: Date(),
                                connectors: [connector(.healthy), connector(.unknown)],
                                notes: []).overallHealth == .unknown)
    }

    /// An empty machine is a correct empty state, not an error.
    @Test func emptyMachineIsHealthy() {
        #expect(DiscoveryReport(generatedAt: Date(), connectors: [], notes: [])
            .overallHealth == .healthy)
    }
}

@Suite("Read-only command allowlist")
struct ReadOnlyCommandTests {
    /// The structural guarantee behind the project rule: no mutating launchctl or
    /// brew verb can be spawned, even by a future call site that tries.
    @Test(arguments: [
        ("/bin/launchctl", ["bootout", "gui/501/com.example.tunnel"]),
        ("/bin/launchctl", ["kickstart", "-k", "gui/501/com.example.tunnel"]),
        ("/bin/launchctl", ["stop", "com.example.tunnel"]),
        ("/opt/homebrew/bin/brew", ["services", "start", "cloudflared"]),
        ("/opt/homebrew/bin/brew", ["services", "restart", "cloudflared"]),
        ("/bin/kill", ["-9", "10269"]),
        ("/usr/bin/pkill", ["cloudflared"]),
    ])
    func rejectsMutatingCommands(_ executable: String, _ arguments: [String]) {
        #expect(throws: ReadOnlyCommand.Rejected.self) {
            _ = try ReadOnlyCommand.run(executable, arguments)
        }
    }

    @Test(arguments: [
        ("/bin/launchctl", ["print", "gui/501/com.example"]),
        ("/opt/homebrew/bin/brew", ["services", "list", "--json"]),
    ])
    func allowsReadOnlyCommands(_ executable: String, _ arguments: [String]) {
        #expect(throws: Never.self) {
            _ = try ReadOnlyCommand.run(executable, arguments)
        }
    }
}
