import Foundation

/// Who is responsible for the lifecycle of a connector process.
///
/// This drives the single most important rule in the project:
/// only `.tunnelbar` connectors may ever be offered lifecycle controls. Every
/// other case is strictly read-only, and the UI must *omit* controls for them
/// rather than disable them.
public enum Ownership: String, Codable, Sendable {
    /// Started and tracked by this app. The only case that may be managed.
    case tunnelbar
    /// Supervised by a launchd agent or daemon. Often `KeepAlive`, so killing
    /// it produces a flapping tunnel, not a stopped one.
    case launchd
    /// Supervised by `brew services`.
    case homebrew
    /// A bare process with no supervisor — typically a shell.
    case shell
    /// Discovered, but the supervisor could not be determined. Treated as
    /// read-only, exactly like every other non-`tunnelbar` case.
    case unknown

    /// Whether Tunnelbar may offer start/stop/restart for this connector.
    ///
    /// Deliberately a single choke point: no call site should ever re-derive
    /// this from the enum case directly.
    public var isManageable: Bool { self == .tunnelbar }
}

/// How a connector's health should be rendered in the status item.
public enum Health: String, Codable, Sendable {
    /// Metrics reachable and every expected edge connection is up.
    case healthy
    /// Metrics reachable, but fewer connections than a full set of four.
    case degraded
    /// Metrics reachable and reporting zero connections, or unreachable.
    case down
    /// No metrics port could be resolved, so health is genuinely unknown.
    /// Distinct from `.down`: the connector may be perfectly fine.
    case unknown

    /// Ordering for the worst-case rollup across connectors.
    var severity: Int {
        switch self {
        case .healthy: 0
        case .unknown: 1
        case .degraded: 2
        case .down: 3
        }
    }
}

/// One edge connection reported by `cloudflared_tunnel_server_locations`.
public struct EdgeConnection: Codable, Sendable, Equatable {
    public let connectionID: String
    public let edgeLocation: String

    public init(connectionID: String, edgeLocation: String) {
        self.connectionID = connectionID
        self.edgeLocation = edgeLocation
    }

    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case edgeLocation = "edge_location"
    }
}

/// The parsed `/ready` and `/metrics` payloads from one connector.
public struct MetricsSnapshot: Codable, Sendable, Equatable {
    public let port: UInt16
    public let connectorID: String?
    public let readyConnections: Int?
    public let haConnections: Int?
    public let edgeConnections: [EdgeConnection]
    public let totalRequests: Double?
    public let concurrentRequests: Double?

    public init(
        port: UInt16,
        connectorID: String?,
        readyConnections: Int?,
        haConnections: Int?,
        edgeConnections: [EdgeConnection],
        totalRequests: Double?,
        concurrentRequests: Double?
    ) {
        self.port = port
        self.connectorID = connectorID
        self.readyConnections = readyConnections
        self.haConnections = haConnections
        self.edgeConnections = edgeConnections
        self.totalRequests = totalRequests
        self.concurrentRequests = concurrentRequests
    }
}

/// Everything known about one `cloudflared` process on this machine.
public struct Connector: Codable, Sendable {
    public let pid: pid_t
    public let executablePath: String
    /// Argv with secrets removed. Never contains a raw `--token` value.
    public let redactedArguments: [String]
    public let startedAt: Date
    public let uptimeSeconds: Int
    public let ownership: Ownership
    /// Human-readable owner, e.g. a launchd label. Nil when unowned.
    public let ownerLabel: String?
    /// False for everything except `.tunnelbar`. Mirrors `ownership.isManageable`
    /// into the JSON so consumers cannot forget to check it.
    public let isManageable: Bool
    public let health: Health
    public let metrics: MetricsSnapshot?
    /// Why metrics are missing, when they are.
    public let metricsError: String?
}

/// A tunnel-shaped process that could not be probed, kept so the CLI can
/// explain gaps rather than silently omitting them.
public struct DiscoveryNote: Codable, Sendable {
    public let kind: String
    public let detail: String

    public init(kind: String, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// The whole read-only picture, as printed by `tunnelbar-discover`.
public struct DiscoveryReport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// Worst health across all connectors — what the status item icon reflects.
    public let overallHealth: Health
    public let connectors: [Connector]
    /// Everything listening for TCP on this Mac. Whether any of it is reachable
    /// from the internet needs the Cloudflare API, so that join lives in the
    /// app rather than here.
    public let localServices: [LocalService]
    public let notes: [DiscoveryNote]

    public init(
        generatedAt: Date,
        connectors: [Connector],
        localServices: [LocalService] = [],
        notes: [DiscoveryNote]
    ) {
        self.schemaVersion = 2
        self.generatedAt = generatedAt
        self.connectors = connectors
        self.localServices = localServices
        self.notes = notes
        // An empty machine is healthy-but-empty, not broken. the project's scope.
        self.overallHealth = connectors
            .map(\.health)
            .max(by: { $0.severity < $1.severity }) ?? .healthy
    }
}
