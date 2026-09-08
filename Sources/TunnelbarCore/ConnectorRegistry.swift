import Darwin
import Foundation

/// How to start a connector. The persistent half of a managed connector:
/// this is what survives the process dying.
public enum ConnectorSpec: Codable, Sendable, Equatable {
    /// Anonymous, ephemeral, no account or token.
    case quickTunnel(localURL: String)
    /// A real tunnel, started from a token in the Keychain.
    case namedTunnel(tunnelID: String)

    public var descriptor: String {
        switch self {
        case .quickTunnel(let localURL): "quick tunnel → \(localURL)"
        case .namedTunnel(let tunnelID): "tunnel \(tunnelID)"
        }
    }

    /// Whether an unexpected exit should be repaired by default.
    ///
    /// Named tunnels: yes — that is the whole point of replacing `KeepAlive`.
    /// Quick tunnels: no. A restarted quick tunnel gets a **new** public
    /// hostname, so silently respawning one leaves the user holding a dead link
    /// they may already have shared, while the menu cheerfully shows a healthy
    /// connector. Better to let it stay down and be visibly down.
    public var defaultAutoRestart: Bool {
        switch self {
        case .quickTunnel: false
        case .namedTunnel: true
        }
    }
}

/// The currently running process for a managed connector, if there is one.
public struct RunningInstance: Codable, Sendable, Equatable {
    public let pid: pid_t
    /// Start time, used to defeat pid reuse. See `ConnectorRegistry`.
    public let startedAt: Date
    public let logPath: String?

    public init(pid: pid_t, startedAt: Date, logPath: String?) {
        self.pid = pid
        self.startedAt = startedAt
        self.logPath = logPath
    }
}

/// A connector Tunnelbar is responsible for.
///
/// Splits **desired** state from **actual** state, which is the whole reason
/// respawn is possible. Earlier the two were conflated in one record, so an
/// entry whose process had died was simply dropped — and a forgotten connector
/// cannot be restarted. `spec` and `autoRestart` say what should be true;
/// `instance` says what currently is.
public struct ManagedConnector: Codable, Sendable, Equatable {
    /// Stable across restarts, unlike a pid.
    public let id: UUID
    public let spec: ConnectorSpec
    public var instance: RunningInstance?
    /// Whether an unexpected exit should be repaired. Cleared when the user
    /// stops a connector deliberately, so Stop means stop.
    public var autoRestart: Bool
    /// Consecutive failed or short-lived runs, driving the backoff.
    public var consecutiveFailures: Int
    /// When the process was last observed to be gone.
    public var lastExitAt: Date?

    public init(
        id: UUID = UUID(),
        spec: ConnectorSpec,
        instance: RunningInstance? = nil,
        autoRestart: Bool = true,
        consecutiveFailures: Int = 0,
        lastExitAt: Date? = nil
    ) {
        self.id = id
        self.spec = spec
        self.instance = instance
        self.autoRestart = autoRestart
        self.consecutiveFailures = consecutiveFailures
        self.lastExitAt = lastExitAt
    }
}

/// Persistent record of the connectors Tunnelbar manages.
///
/// ## Why this is the most dangerous file in the project
///
/// Ownership decides whether a connector gets a Stop button, and this registry
/// is the sole positive source of app-ownership. A pid is not a stable
/// identity: pids are recycled, and a stale entry claiming pid 10269 would make
/// whatever now holds that pid look app-owned. If the recycled pid happened to
/// belong to a launchd-supervised connector, Tunnelbar would render a Stop
/// button for a connector it must never touch — the precise failure the project
/// forbids.
///
/// So an instance is honoured only when **all three** hold:
///
/// 1. a live process exists at that pid,
/// 2. its start time matches the recorded one, and
/// 3. it is still a `cloudflared` connector.
///
/// Start time is what makes reuse effectively impossible: the kernel would have
/// to recycle the pid onto a cloudflared connector launched within the same
/// second. A failing instance is cleared to nil — but the managed entry itself
/// survives, because that is precisely the case respawn exists to repair.
public enum ConnectorRegistry {
    static let startTimeTolerance: TimeInterval = 1.0

    public static var storeURL: URL {
        OwnershipResolver.appOwnedRegistryURL
    }

    /// The three-part validation. Public so every caller about to *act* on a
    /// connector can re-run it immediately beforehand, rather than trusting a
    /// value read earlier.
    public static func isLive(_ instance: RunningInstance) -> Bool {
        guard let info = ProcessScanner.bsdInfo(of: instance.pid) else { return false }
        guard abs(info.startedAt.timeIntervalSince(instance.startedAt)) <= startTimeTolerance
        else { return false }
        guard let path = ProcessScanner.executablePath(of: instance.pid),
              (path as NSString).lastPathComponent == "cloudflared",
              let arguments = ProcessScanner.rawArguments(of: instance.pid),
              ProcessScanner.isConnectorInvocation(arguments)
        else { return false }
        return true
    }

    /// Reads the store verbatim, without validating or mutating anything.
    ///
    /// Deliberately does not clear dead instances: a dead instance still
    /// carries its `startedAt`, and the supervisor needs that to tell a crash
    /// loop from a connector that ran happily for a day and then died. Losing
    /// it here would make the backoff meaningless.
    public static func load() -> [ManagedConnector] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // A store written by an older, incompatible layout decodes to nothing,
        // which means "we manage nothing" — the safe direction to fail.
        return (try? decoder.decode([ManagedConnector].self, from: data)) ?? []
    }

    /// Managed connectors whose recorded process is still genuinely ours.
    public static func liveInstances() -> [(managed: ManagedConnector, instance: RunningInstance)] {
        load().compactMap { entry in
            guard let instance = entry.instance, isLive(instance) else { return nil }
            return (entry, instance)
        }
    }

    @discardableResult
    public static func save(_ entries: [ManagedConnector]) -> Bool {
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }
        return (try? data.write(to: storeURL, options: .atomic)) != nil
    }

    public static func upsert(_ entry: ManagedConnector) {
        var entries = load()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        save(entries)
    }

    /// Removes a managed connector entirely. Used when the user stops one:
    /// Stop means stop, so the desired state goes away with the process.
    public static func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    /// Whether a connector for this spec is already managed and running.
    ///
    /// Starting a second connector from one tunnel's token creates duplicate
    /// edge connections for that tunnel — the hazard the project rule names. This
    /// prevents Tunnelbar from doing it to itself. It cannot see connectors
    /// owned by launchd or a shell, so it is a guard, not a guarantee.
    public static func hasLiveConnector(for spec: ConnectorSpec) -> Bool {
        liveInstances().contains { $0.managed.spec == spec }
    }
}
