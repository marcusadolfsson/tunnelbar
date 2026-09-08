import Foundation
import Testing
@testable import TunnelbarCore

/// The respawn logic replaces launchd's `KeepAlive`. A mistake here is not
/// visible in the UI — it shows up as Tunnelbar hammering Cloudflare's edge, or
/// as a tunnel that never comes back. Every branch is pinned.
@Suite("Restart backoff")
struct RestartPolicyTests {
    /// First retry is immediate; the common case is a connector that died once
    /// and should come straight back.
    @Test func firstRetryIsImmediate() {
        #expect(RestartPolicy.delay(afterFailures: 0) == 0)
    }

    @Test(arguments: [(1, 2.0), (2, 4.0), (3, 8.0), (4, 16.0), (5, 32.0)])
    func backoffDoubles(_ failures: Int, _ expected: TimeInterval) {
        #expect(RestartPolicy.delay(afterFailures: failures) == expected)
    }

    /// A token Cloudflare is rejecting must settle at a fixed retry interval
    /// rather than escalating without bound — and must never stop trying.
    @Test func backoffIsCapped() {
        #expect(RestartPolicy.delay(afterFailures: 10) == RestartPolicy.maxDelay)
        #expect(RestartPolicy.delay(afterFailures: 1_000) == RestartPolicy.maxDelay)
    }

    /// Guards the shift in `delay`: a large failure count must not overflow.
    @Test func hugeFailureCountsDoNotOverflow() {
        #expect(RestartPolicy.delay(afterFailures: Int.max) == RestartPolicy.maxDelay)
    }

    /// A connector that ran happily for a long time and then died is not in a
    /// crash loop; without this reset the backoff would creep to five minutes
    /// over days of occasional restarts.
    @Test func healthyRunResetsTheFailureStreak() {
        #expect(RestartPolicy.updatedFailureCount(previous: 7, ranFor: 3_600) == 0)
        #expect(RestartPolicy.updatedFailureCount(
            previous: 7, ranFor: RestartPolicy.healthyRuntime) == 0)
    }

    @Test func shortRunIncrementsTheFailureStreak() {
        #expect(RestartPolicy.updatedFailureCount(previous: 0, ranFor: 0.5) == 1)
        #expect(RestartPolicy.updatedFailureCount(previous: 3, ranFor: 10) == 4)
    }
}

@Suite("Restart decisions")
struct RestartDecisionTests {
    private func managed(
        failures: Int = 0, autoRestart: Bool = true, exitedAgo: TimeInterval? = nil
    ) -> ManagedConnector {
        ManagedConnector(
            spec: .namedTunnel(tunnelID: "t"),
            instance: nil,
            autoRestart: autoRestart,
            consecutiveFailures: failures,
            lastExitAt: exitedAgo.map { Date().addingTimeInterval(-$0) })
    }

    /// A live connector is never restarted — that would be the duplicate
    /// connector hazard, self-inflicted.
    @Test func liveConnectorIsLeftAlone() {
        #expect(RestartPolicy.decide(for: managed(), isLive: true, now: Date()) == .idle)
    }

    /// Stop means stop. A user who stopped a connector must not have it
    /// resurrected on the next poll.
    @Test func autoRestartOffMeansNeverRestart() {
        let entry = managed(failures: 0, autoRestart: false, exitedAgo: 10_000)
        #expect(RestartPolicy.decide(for: entry, isLive: false, now: Date()) == .idle)
    }

    @Test func firstFailureRestartsImmediately() {
        let entry = managed(failures: 0, exitedAgo: 0)
        #expect(RestartPolicy.decide(for: entry, isLive: false, now: Date()) == .restart)
    }

    @Test func waitsOutTheBackoff() {
        // 3 failures → 8s backoff; only 2s have passed.
        let entry = managed(failures: 3, exitedAgo: 2)
        guard case .wait(let remaining) = RestartPolicy.decide(
            for: entry, isLive: false, now: Date()) else {
            Issue.record("expected to still be waiting")
            return
        }
        #expect(remaining > 5 && remaining <= 6)
    }

    @Test func restartsOnceTheBackoffElapses() {
        let entry = managed(failures: 3, exitedAgo: 9)  // 8s backoff, 9s elapsed
        #expect(RestartPolicy.decide(for: entry, isLive: false, now: Date()) == .restart)
    }

    /// Surfaced in the menu so a connector stuck in a loop reads as failing
    /// rather than as perpetually "restarting".
    @Test func failingThresholdIsReported() {
        #expect(!RestartPolicy.isFailing(managed(failures: 0)))
        #expect(!RestartPolicy.isFailing(managed(failures: 2)))
        #expect(RestartPolicy.isFailing(managed(failures: 3)))
        #expect(RestartPolicy.isFailing(managed(failures: 99)))
    }
}

@Suite("Restart defaults by kind")
struct RestartDefaultsTests {
    /// A restarted quick tunnel gets a *new* public hostname, so silently
    /// respawning one hands the user a dead link while the menu claims health.
    @Test func quickTunnelsDoNotAutoRestart() {
        #expect(!ConnectorSpec.quickTunnel(localURL: "http://localhost:8080").defaultAutoRestart)
    }

    /// Named tunnels are the whole reason respawn exists.
    @Test func namedTunnelsDoAutoRestart() {
        #expect(ConnectorSpec.namedTunnel(tunnelID: "t").defaultAutoRestart)
    }
}
