import Foundation
import TunnelbarCore

/// Value formatting for the menu. Deliberately free of any UI framework so it
/// can be unit tested directly.
enum Format {
    /// Compact uptime: `4d 3h`, `3h 12m`, `12m`, `48s`.
    static func uptime(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// `mia01, mia04, mia09` — sorted and de-duplicated for a stable reading.
    static func edgeLocations(_ connections: [EdgeConnection]) -> String {
        Set(connections.map(\.edgeLocation)).sorted().joined(separator: ", ")
    }

    static func connections(ready: Int?, expected: Int = DiscoveryEngine.expectedConnections) -> String {
        guard let ready else { return "connections unknown" }
        return "\(ready) of \(expected) connections"
    }
}
