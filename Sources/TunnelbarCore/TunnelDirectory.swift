import Foundation

/// One tunnel as Cloudflare sees it, account-wide.
public struct TunnelSummary: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case healthy, degraded, down, inactive, unknown

        init(apiValue: String?) {
            self = apiValue.flatMap(Status.init(rawValue:)) ?? .unknown
        }

        /// How this should read in the menu. `inactive` is not a fault: it
        /// means a tunnel exists but has never had a connector attached.
        public var label: String {
            switch self {
            case .healthy: "Healthy"
            case .degraded: "Degraded"
            case .down: "Down"
            case .inactive: "Never connected"
            case .unknown: "Unknown"
            }
        }
    }

    public let id: String
    public let name: String
    public let accountID: String
    public let status: Status
    /// Connector IDs Cloudflare currently sees serving this tunnel. The join
    /// key against a locally discovered connector's `/ready` connector ID.
    public let connectorIDs: Set<String>
    public let colos: [String]
    public let connectionCount: Int
}

/// Account-wide tunnel state, joined against what is running locally.
///
/// The join is what makes the account view useful rather than a second,
/// disconnected list: a local connector knows its connector ID but not its
/// tunnel's name, and Cloudflare knows both. Matching on connector ID gives
/// every local row a human name, and identifies which account tunnels are
/// running somewhere else entirely.
public struct TunnelDirectory: Sendable, Equatable {
    public let tunnels: [TunnelSummary]
    public let fetchedAt: Date

    public init(tunnels: [TunnelSummary], fetchedAt: Date = Date()) {
        self.tunnels = tunnels
        self.fetchedAt = fetchedAt
    }

    /// The tunnel a local connector is serving, if the account can see it.
    public func tunnel(forConnectorID connectorID: String) -> TunnelSummary? {
        tunnels.first { $0.connectorIDs.contains(connectorID) }
    }

    /// Friendly name for a locally discovered connector.
    public func name(for connector: Connector) -> String? {
        guard let connectorID = connector.metrics?.connectorID else { return nil }
        return tunnel(forConnectorID: connectorID)?.name
    }

    /// Account tunnels with no connector running on this machine.
    ///
    /// The point of the account view: a tunnel that is down, or up but served
    /// from somewhere else, is invisible to local discovery and is often
    /// exactly what the user is looking for.
    public func tunnelsNotRunningLocally(given connectors: [Connector]) -> [TunnelSummary] {
        let localIDs = Set(connectors.compactMap { $0.metrics?.connectorID })
        return tunnels
            .filter { $0.connectorIDs.isDisjoint(with: localIDs) }
            .sorted { ($0.status.rawValue, $0.name) < ($1.status.rawValue, $1.name) }
    }
}
