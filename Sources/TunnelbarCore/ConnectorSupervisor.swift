import Foundation

/// Keeps managed connectors running, standing in for launchd's `KeepAlive`.
///
/// Runs as a sweep on the existing poll rather than off a process-exit
/// callback. A callback is more prompt, but only for connectors started in this
/// session: if Tunnelbar is relaunched, connectors that outlived it have no
/// callback to fire, and those are exactly the ones most in need of
/// supervision. Sweeping the registry handles both uniformly and survives the
/// app restarting.
///
/// Only ever acts on connectors in the registry, so it can no more restart an
/// externally-owned connector than it can stop one.
public enum ConnectorSupervisor {
    public struct Outcome: Sendable, Equatable {
        /// Connectors restarted on this pass.
        public var restarted: [String] = []
        /// Connectors whose restart attempt failed, with the reason.
        public var failures: [String] = []
        /// Connectors noticed to have exited on this pass.
        public var exited: [String] = []

        public var isEmpty: Bool {
            restarted.isEmpty && failures.isEmpty && exited.isEmpty
        }
    }

    /// One supervision pass. Safe to call on every poll; it does nothing when
    /// everything is already as it should be.
    @discardableResult
    public static func tick(now: Date = Date()) -> Outcome {
        var entries = ConnectorRegistry.load()
        guard !entries.isEmpty else { return Outcome() }
        var outcome = Outcome()
        var changed = false

        for index in entries.indices {
            var entry = entries[index]
            let live = entry.instance.map(ConnectorRegistry.isLive) ?? false

            // Notice a death exactly once, and account for it while the dead
            // instance's start time is still available.
            if let instance = entry.instance, !live {
                let runtime = now.timeIntervalSince(instance.startedAt)
                entry.consecutiveFailures = RestartPolicy.updatedFailureCount(
                    previous: entry.consecutiveFailures, ranFor: runtime)
                entry.instance = nil
                entry.lastExitAt = now
                outcome.exited.append(entry.spec.descriptor)
                changed = true
            }

            switch RestartPolicy.decide(for: entry, isLive: live, now: now) {
            case .idle, .wait:
                break
            case .restart:
                do {
                    entry.instance = try ConnectorLauncher.launch(entry.spec)
                    outcome.restarted.append(entry.spec.descriptor)
                } catch {
                    // A failed *attempt* counts as a failure and stamps the
                    // clock, so the backoff applies. Without this a connector
                    // whose token was deleted would be retried on every poll.
                    entry.consecutiveFailures += 1
                    entry.lastExitAt = now
                    outcome.failures.append("\(entry.spec.descriptor): \(error)")
                }
                changed = true
            }

            entries[index] = entry
        }

        if changed { ConnectorRegistry.save(entries) }
        return outcome
    }
}
