import Darwin
import Foundation
import Testing
@testable import TunnelbarCore

/// End-to-end lifecycle against a real connector.
///
/// Starts an actual quick tunnel, so it needs network access and touches the
/// real registry. Off by default; run with:
///
///     TUNNELBAR_INTEGRATION=1 swift test
///
/// It targets a dead local port on purpose: the tunnel establishes real edge
/// connections, which is what the test needs, while exposing nothing.
@Suite("Lifecycle integration", .enabled(if: ProcessInfo.processInfo.environment["TUNNELBAR_INTEGRATION"] != nil))
struct LifecycleIntegrationTests {
    @Test func startsAdoptsDiscoversAndStopsAQuickTunnel() async throws {
        let owned = try ConnectorLauncher.start(.quickTunnel(localURL: "http://localhost:9999"))
        defer { try? ConnectorLauncher.stop(owned) }

        #expect(ConnectorRegistry.isLive(try #require(owned.instance)))
        #expect(ConnectorRegistry.liveInstances().contains { $0.managed.id == owned.id })

        // Give the connector time to bind its metrics port and reach the edge.
        try await Task.sleep(for: .seconds(15))

        let report = await DiscoveryEngine().discover()
        let row = try #require(report.connectors.first { $0.pid == owned.instance?.pid },
                               "the connector Tunnelbar started must be discovered")

        // The whole point: a connector this app started is app-owned and
        // manageable, while everything else on the machine is not.
        #expect(row.ownership == .tunnelbar)
        #expect(row.isManageable)
        #expect(row.metrics?.connectorID != nil)
        #expect((row.metrics?.readyConnections ?? 0) > 0)

        for other in report.connectors where other.pid != owned.instance?.pid {
            #expect(!other.isManageable, "pid \(other.pid) must stay read-only")
        }

        // The log-parsing fallback applies here, because Tunnelbar started this
        // connector and therefore knows where its log went.
        let hostname = ConnectorLauncher.quickTunnelHostname(logPath: owned.instance?.logPath ?? "")
        #expect(hostname?.hasSuffix(".trycloudflare.com") == true)

        try ConnectorLauncher.stop(owned)
        try await Task.sleep(for: .seconds(3))

        #expect(kill(try #require(owned.instance).pid, 0) != 0, "the connector should be gone")
        #expect(!ConnectorRegistry.load().contains { $0.id == owned.id })
    }
}

/// Proves respawn against a real process death.
///
/// Uses a quick tunnel with auto-restart forced on. Quick tunnels do not
/// auto-restart by default — a new one gets a different public hostname — but
/// the supervision path is identical to a named tunnel's, and a quick tunnel
/// needs no token.
@Suite("Respawn integration", .enabled(if: ProcessInfo.processInfo.environment["TUNNELBAR_INTEGRATION"] != nil))
struct RespawnIntegrationTests {
    @Test func restartsAConnectorThatDiesUnexpectedly() async throws {
        var managed = try ConnectorLauncher.start(.quickTunnel(localURL: "http://localhost:9999"))
        managed.autoRestart = true
        ConnectorRegistry.upsert(managed)
        defer { try? ConnectorLauncher.stop(ConnectorRegistry.load().first { $0.id == managed.id }
                                            ?? managed) }

        let originalPID = try #require(managed.instance).pid
        try await Task.sleep(for: .seconds(8))
        #expect(ConnectorRegistry.isLive(try #require(managed.instance)))

        // A healthy connector must not be touched by a supervision pass.
        let quiet = ConnectorSupervisor.tick()
        #expect(quiet.isEmpty, "supervising a live connector should do nothing")

        // Kill it the way a crash would: not through Tunnelbar.
        #expect(kill(originalPID, SIGKILL) == 0)
        try await Task.sleep(for: .seconds(2))

        // First pass notices the death but does *not* restart yet: the
        // connector ran for well under `healthyRuntime`, so this counts as a
        // failure and the 2s backoff applies. A connector that had been up for
        // longer would have its streak reset and come back immediately.
        let noticed = ConnectorSupervisor.tick()
        #expect(noticed.exited.count == 1)
        #expect(noticed.restarted.isEmpty, "the backoff should defer the restart")
        #expect(noticed.failures.isEmpty)

        let backingOff = try #require(ConnectorRegistry.load().first { $0.id == managed.id })
        #expect(backingOff.instance == nil)
        #expect(backingOff.consecutiveFailures == 1)
        #expect(backingOff.lastExitAt != nil)

        // A second pass inside the backoff window must still not restart, so
        // polling every ten seconds cannot turn into a retry storm.
        #expect(ConnectorSupervisor.tick().restarted.isEmpty)

        try await Task.sleep(for: .seconds(3))  // clears the 2s backoff

        let repair = ConnectorSupervisor.tick()
        #expect(repair.restarted.count == 1)
        #expect(repair.failures.isEmpty)

        let after = try #require(ConnectorRegistry.load().first { $0.id == managed.id })
        let newInstance = try #require(after.instance, "a replacement should be recorded")
        #expect(newInstance.pid != originalPID, "the replacement must be a new process")
        #expect(ConnectorRegistry.isLive(newInstance))

        try await Task.sleep(for: .seconds(10))
        let report = await DiscoveryEngine().discover()
        let row = try #require(report.connectors.first { $0.pid == newInstance.pid })
        #expect(row.ownership == .tunnelbar)
        #expect(row.isManageable)

        // Everything else on the machine stays read-only throughout.
        for other in report.connectors where other.pid != newInstance.pid {
            #expect(!other.isManageable)
        }
    }

    /// A connector the user stopped must stay stopped.
    @Test func doesNotResurrectADeliberateStop() async throws {
        let managed = try ConnectorLauncher.start(.quickTunnel(localURL: "http://localhost:9998"))
        try await Task.sleep(for: .seconds(5))
        try ConnectorLauncher.stop(managed)
        try await Task.sleep(for: .seconds(2))

        let outcome = ConnectorSupervisor.tick()
        #expect(outcome.restarted.isEmpty, "a stopped connector must not come back")
        #expect(!ConnectorRegistry.load().contains { $0.id == managed.id })
    }
}
