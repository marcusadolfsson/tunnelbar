import Testing
import TunnelbarCore
@testable import Tunnelbar

@Suite("Menu formatting")
struct FormatTests {
    @Test(arguments: [
        (45, "45s"), (60, "1m"), (754, "12m"), (3_600, "1h 0m"),
        (11_520, "3h 12m"), (86_400, "1d 0h"), (356_400, "4d 3h"),
    ])
    func formatsUptime(_ seconds: Int, _ expected: String) {
        #expect(Format.uptime(seconds) == expected)
    }

    /// Edge locations arrive keyed by connection id and in arbitrary order;
    /// the menu shows a stable, de-duplicated reading.
    @Test func sortsAndDeduplicatesEdgeLocations() {
        let connections = [
            EdgeConnection(connectionID: "0", edgeLocation: "mia09"),
            EdgeConnection(connectionID: "1", edgeLocation: "mia01"),
            EdgeConnection(connectionID: "2", edgeLocation: "mia09"),
            EdgeConnection(connectionID: "3", edgeLocation: "mia04"),
        ]
        #expect(Format.edgeLocations(connections) == "mia01, mia04, mia09")
    }

    @Test func describesConnectionCounts() {
        #expect(Format.connections(ready: 4) == "4 of 4 connections")
        #expect(Format.connections(ready: 2) == "2 of 4 connections")
        // Unknown must not render as "0 of 4", which would read as an outage.
        #expect(Format.connections(ready: nil) == "connections unknown")
    }
}

@Suite("Read-only presentation")
struct ReadOnlyPresentationTests {
    /// The badge must name the actual supervisor, since "who would restart this
    /// if I killed it" is the question it exists to answer.
    @Test func badgesNameTheSupervisor() {
        #expect(Ownership.launchd.badgeText == "launchd")
        #expect(Ownership.homebrew.badgeText == "brew services")
        #expect(Ownership.tunnelbar.badgeText == "Tunnelbar")
    }

    /// Every externally-owned connector shows a lock; only app-owned does not.
    @Test func onlyManageableConnectorsAvoidTheLockGlyph() {
        #expect(Ownership.tunnelbar.badgeSymbol != "lock.fill")
        for ownership in [Ownership.launchd, .homebrew, .shell, .unknown] {
            #expect(ownership.badgeSymbol == "lock.fill", "\(ownership) must read as locked")
        }
    }

    /// Health must be distinguishable without relying on colour.
    @Test func healthSymbolsAreDistinctShapes() {
        let symbols = [Health.healthy, .degraded, .down, .unknown].map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
    }
}
