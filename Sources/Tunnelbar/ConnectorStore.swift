import Foundation
import Observation
import TunnelbarCore

/// Polls `DiscoveryEngine` and publishes the result to the menu.
///
/// Polling backs off when the machine has no connectors running: there is
/// nothing to watch, and a menu bar app has no business waking the CPU every
/// ten seconds to rediscover that. The interval resets the moment a connector
/// appears.
@MainActor
@Observable
final class ConnectorStore {
    /// Interval used whenever at least one connector is running.
    static let activeInterval: Duration = .seconds(10)
    /// The account list changes far more slowly than local process state, and
    /// each refresh is a network round trip against a rate-limited API, so it
    /// is fetched on its own much slower cadence rather than every poll.
    static let directoryInterval: TimeInterval = 60
    /// Ceiling for the idle backoff.
    static let maxIdleInterval: Duration = .seconds(120)

    private(set) var report: DiscoveryReport?
    private(set) var isRefreshing = false
    /// Set only when discovery itself fails, which is distinct from discovering
    /// that nothing is running.
    private(set) var lastRefreshFailed = false

    private let engine = DiscoveryEngine()
    private var pollingTask: Task<Void, Never>?
    private var idleInterval = activeInterval

    var connectors: [Connector] { report?.connectors ?? [] }

    /// Managed connectors keyed by the pid they are currently running, so a
    /// row can show its descriptor and offer a working Stop.
    private(set) var managedByPID: [pid_t: ManagedConnector] = [:]

    /// Managed connectors with no live process: crashed and awaiting a restart,
    /// or failing repeatedly. They have no row in discovery, so the menu shows
    /// them separately — a connector that is supposed to be up and is not is
    /// the single most important thing this app can tell you.
    private(set) var downManaged: [ManagedConnector] = []

    /// Account-wide tunnel state, when an API token is configured. Nil is a
    /// normal state — everything local works without a token.
    private(set) var directory: TunnelDirectory?
    /// Why the account list is missing, when a token exists but the fetch
    /// failed. Surfaced rather than swallowed: a token with the wrong
    /// permission otherwise looks identical to no token at all.
    private(set) var directoryError: String?
    private var lastDirectoryFetch: Date?

    /// Listening TCP services on this Mac, from the same discovery pass.
    var localServices: [LocalService] { report?.localServices ?? [] }

    /// Ingress rules per tunnel, fetched alongside the account list.
    private(set) var exposureMap = ExposureMap(rulesByTunnel: [:], namesByTunnel: [:])

    /// Local services joined against what tunnels publish.
    var exposures: [ServiceExposure] { exposureMap.exposures(for: localServices) }

    /// Surfaced to the user rather than swallowed: a failed start or stop is
    /// something they asked for and need to know about.
    var lastActionError: String?

    func managed(for pid: pid_t) -> ManagedConnector? { managedByPID[pid] }

    /// Health for the status item. Nil until the first discovery completes, so
    /// the icon can show an indeterminate state rather than a false "healthy".
    var overallHealth: Health? { report?.overallHealth }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.nextInterval()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Runs discovery once. Safe to call from a Refresh button mid-cycle.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // Supervise before discovering, so a connector restarted on this pass
        // appears in the very same refresh rather than a poll later.
        let outcome = ConnectorSupervisor.tick()
        if !outcome.failures.isEmpty {
            lastActionError = outcome.failures.joined(separator: "; ")
        }

        report = await engine.discover()

        let live = ConnectorRegistry.liveInstances()
        managedByPID = Dictionary(
            uniqueKeysWithValues: live.map { ($0.instance.pid, $0.managed) })
        let liveIDs = Set(live.map(\.managed.id))
        downManaged = ConnectorRegistry.load().filter { !liveIDs.contains($0.id) }
        lastRefreshFailed = false

        await refreshDirectoryIfNeeded()
    }

    /// Friendly tunnel name for a local connector, when the account list has
    /// been fetched. A connector knows its own connector ID but not the name of
    /// the tunnel it serves; only Cloudflare knows both.
    func tunnelName(for connector: Connector) -> String? {
        directory?.name(for: connector)
    }

    /// Account tunnels with nothing running for them on this Mac.
    var tunnelsElsewhere: [TunnelSummary] {
        directory?.tunnelsNotRunningLocally(given: connectors) ?? []
    }

    /// Fetches the account tunnel list, at most once per `directoryInterval`.
    private func refreshDirectoryIfNeeded(force: Bool = false) async {
        // `try?` flattens the optional `read` returns, so this single binding
        // covers both "no token stored" and "the Keychain refused".
        guard let token = try? KeychainStore.read(.cloudflareAPIToken) else {
            // No token is not an error. Everything local keeps working.
            directory = nil
            directoryError = nil
            return
        }
        if !force, let last = lastDirectoryFetch,
           Date().timeIntervalSince(last) < Self.directoryInterval {
            return
        }

        let api = CloudflareAPI()
        var summaries: [TunnelSummary] = []
        var rules: [String: [IngressRule]] = [:]
        var names: [String: String] = [:]
        var failure: String?
        // Most tokens see one account; the cap stops a token with sweeping
        // visibility from turning one poll into dozens of requests.
        for accountID in Preferences.accountIDs.prefix(5) {
            do {
                let tunnels = try await api.tunnels(accountID: accountID, token: token)
                summaries.append(contentsOf: tunnels)
                for tunnel in tunnels {
                    names[tunnel.id] = tunnel.name
                    // Best effort per tunnel: one unreadable config should not
                    // cost the exposure view for every other tunnel.
                    if let ingress = try? await api.ingress(
                        accountID: accountID, tunnelID: tunnel.id, token: token) {
                        rules[tunnel.id] = ingress
                    }
                }
            } catch {
                failure = "\(error)"
            }
        }

        lastDirectoryFetch = Date()
        // Keep the last good list when only some accounts failed, rather than
        // blanking a working view because one account errored.
        if summaries.isEmpty, failure != nil {
            directoryError = failure
        } else {
            directory = TunnelDirectory(tunnels: summaries)
            exposureMap = ExposureMap(rulesByTunnel: rules, namesByTunnel: names)
            directoryError = failure
        }
    }

    /// Manual refresh bypasses the directory's slow cadence: the user asked.
    func refreshEverything() async {
        await refresh()
        await refreshDirectoryIfNeeded(force: true)
    }

    // MARK: - Lifecycle, app-owned connectors only

    /// Starts a quick tunnel and refreshes immediately so the new row appears
    /// without waiting out the poll interval.
    func startQuickTunnel(port: Int) async {
        lastActionError = nil
        do {
            _ = try ConnectorLauncher.start(.quickTunnel(localURL: "http://localhost:\(port)"))
        } catch {
            lastActionError = "\(error)"
        }
        await refresh()
    }

    /// Starts a connector for a tunnel whose token is stored in the Keychain.
    func startTunnel(tunnelID: String) async {
        lastActionError = nil
        do {
            _ = try ConnectorLauncher.start(.namedTunnel(tunnelID: tunnelID))
        } catch {
            lastActionError = "\(error)"
        }
        await refresh()
    }

    /// Stops a connector Tunnelbar owns.
    ///
    /// Takes a pid and resolves it through the registry rather than accepting a
    /// connector to signal, so a row rendered from stale discovery output
    /// cannot become an instruction to kill an arbitrary process.
    func stop(pid: pid_t) async {
        lastActionError = nil
        guard let managed = managedByPID[pid] else {
            lastActionError = "pid \(pid) is not a connector Tunnelbar owns"
            return
        }
        do {
            try ConnectorLauncher.stop(managed)
        } catch {
            lastActionError = "\(error)"
        }
        await refresh()
    }

    /// Abandons a managed connector that is down, so the supervisor stops
    /// trying to restart it.
    func forget(_ managed: ManagedConnector) async {
        lastActionError = nil
        ConnectorRegistry.remove(id: managed.id)
        await refresh()
    }

    /// Ten seconds while there is anything to watch or repair; doubling up to
    /// two minutes only when the machine is genuinely idle.
    ///
    /// "Idle" means Tunnelbar manages nothing *and* discovers nothing. Keying
    /// this on discovery alone was wrong twice over: a managed connector that
    /// has just died leaves no discovered connector behind, and a connector
    /// started while the backoff was wound out could take two minutes to
    /// appear — including one Tunnelbar started itself, which is absurd. If the
    /// registry holds anything at all, there is something to watch.
    private func nextInterval() -> Duration {
        let managesAnything = !managedByPID.isEmpty || !downManaged.isEmpty
        if connectors.isEmpty && !managesAnything {
            idleInterval = min(idleInterval * 2, Self.maxIdleInterval)
        } else {
            idleInterval = Self.activeInterval
        }
        return idleInterval
    }
}
