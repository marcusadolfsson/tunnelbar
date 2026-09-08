import Foundation

/// When a dead connector should be restarted.
///
/// Pure functions, deliberately: this is the logic that decides how often
/// Tunnelbar reconnects to Cloudflare's edge, and a mistake in it is a mistake
/// nobody sees until it is hammering someone's account. Keeping it free of
/// clocks, processes, and files makes every branch directly testable.
///
/// Modelled on launchd's `KeepAlive` throttle, which Tunnelbar is standing in
/// for: restart promptly, back off exponentially while failures repeat, and
/// keep trying indefinitely rather than giving up on a tunnel the user asked to
/// stay up. There is no jitter — jitter guards against a fleet reconnecting in
/// lockstep, and this supervises at most a handful of connectors on one Mac.
public enum RestartPolicy {
    /// First retry is immediate: a connector that dies once should come back at
    /// once, which is the common case and the one users notice.
    public static let baseDelay: TimeInterval = 2
    /// Ceiling on the backoff. A token Cloudflare is rejecting will retry at
    /// this interval forever rather than escalating without bound or stopping.
    public static let maxDelay: TimeInterval = 300
    /// A run at least this long counts as healthy, so the failure streak resets.
    /// Without it, a connector that dies every few hours would creep up to the
    /// maximum backoff over days and take five minutes to come back.
    public static let healthyRuntime: TimeInterval = 60
    /// Failure count at which the UI should call the connector out as failing
    /// rather than merely restarting.
    public static let failingThreshold = 3

    /// Backoff for a given consecutive-failure count: 0s, 2s, 4s, 8s … capped.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Shift rather than pow, and clamp the exponent before it can overflow.
        let exponent = min(failures - 1, 16)
        return min(baseDelay * TimeInterval(1 << exponent), maxDelay)
    }

    /// The failure streak after a run that has just ended.
    ///
    /// A run that lasted longer than `healthyRuntime` resets the streak: it was
    /// a working connector that happened to die, not a crash loop.
    public static func updatedFailureCount(
        previous: Int, ranFor runtime: TimeInterval
    ) -> Int {
        runtime >= healthyRuntime ? 0 : previous + 1
    }

    public enum Decision: Equatable, Sendable {
        /// Restart now.
        case restart
        /// Not yet; this much of the backoff remains.
        case wait(TimeInterval)
        /// Nothing to do: running, or the user turned auto-restart off.
        case idle
    }

    /// What to do with one managed connector, given that its process is gone.
    ///
    /// `isLive` is passed in rather than checked here so the decision stays
    /// pure and the caller keeps the single source of truth for liveness.
    public static func decide(
        for managed: ManagedConnector, isLive: Bool, now: Date
    ) -> Decision {
        if isLive { return .idle }
        guard managed.autoRestart else { return .idle }

        let exitedAt = managed.lastExitAt ?? now
        let due = exitedAt.addingTimeInterval(delay(afterFailures: managed.consecutiveFailures))
        if now >= due { return .restart }
        return .wait(due.timeIntervalSince(now))
    }

    /// Whether the UI should present this connector as failing rather than
    /// merely between restarts.
    public static func isFailing(_ managed: ManagedConnector) -> Bool {
        managed.consecutiveFailures >= failingThreshold
    }
}
