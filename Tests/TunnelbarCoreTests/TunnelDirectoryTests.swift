import Foundation
import Testing
@testable import TunnelbarCore

@Suite("Account tunnel join")
struct TunnelDirectoryTests {
    private func summary(
        name: String, connectorIDs: Set<String>, status: TunnelSummary.Status = .healthy
    ) -> TunnelSummary {
        TunnelSummary(id: UUID().uuidString, name: name, accountID: "acc", status: status,
                      connectorIDs: connectorIDs, colos: ["mia01"],
                      connectionCount: connectorIDs.count)
    }

    private func connector(connectorID: String?) -> Connector {
        let metrics = connectorID.map {
            MetricsSnapshot(port: 20241, connectorID: $0, readyConnections: 4,
                            haConnections: 4, edgeConnections: [],
                            totalRequests: nil, concurrentRequests: nil)
        }
        return Connector(pid: 1, executablePath: "/x", redactedArguments: [],
                         startedAt: Date(), uptimeSeconds: 0, ownership: .launchd,
                         ownerLabel: "com.example.tunnel", isManageable: false,
                         health: .healthy, metrics: metrics, metricsError: nil)
    }

    /// The join that makes the account view worth having: a local connector
    /// knows its connector ID but not the name of the tunnel it serves.
    @Test func namesALocalConnectorByItsConnectorID() {
        let directory = TunnelDirectory(tunnels: [
            summary(name: "insta", connectorIDs: ["conn-a"]),
            summary(name: "other", connectorIDs: ["conn-b"]),
        ])
        #expect(directory.name(for: connector(connectorID: "conn-a")) == "insta")
        #expect(directory.name(for: connector(connectorID: "conn-b")) == "other")
    }

    /// A connector whose metrics could not be read has no connector ID, so it
    /// cannot be joined — and must not be matched to an arbitrary tunnel.
    @Test func doesNotGuessWhenTheConnectorIDIsUnknown() {
        let directory = TunnelDirectory(tunnels: [summary(name: "insta", connectorIDs: ["conn-a"])])
        #expect(directory.name(for: connector(connectorID: nil)) == nil)
        #expect(directory.name(for: connector(connectorID: "unrelated")) == nil)
    }

    /// The point of the account list: surfacing what local discovery cannot see.
    @Test func listsTunnelsWithNothingRunningHere() {
        let directory = TunnelDirectory(tunnels: [
            summary(name: "local", connectorIDs: ["conn-a"]),
            summary(name: "remote", connectorIDs: ["conn-z"]),
            summary(name: "offline", connectorIDs: [], status: .down),
        ])
        let elsewhere = directory.tunnelsNotRunningLocally(
            given: [connector(connectorID: "conn-a")])
        #expect(elsewhere.map(\.name).sorted() == ["offline", "remote"])
    }

    /// With no token there is no directory, and every tunnel would otherwise
    /// look like it is running nowhere.
    @Test func emptyDirectoryListsNothingRatherThanEverything() {
        let directory = TunnelDirectory(tunnels: [])
        #expect(directory.tunnelsNotRunningLocally(given: [connector(connectorID: "a")]).isEmpty)
    }

    /// `inactive` means a tunnel exists but never had a connector — not a fault.
    @Test func inactiveIsNotPresentedAsAFailure() {
        #expect(TunnelSummary.Status.inactive.label == "Never connected")
        #expect(TunnelSummary.Status(apiValue: nil) == .unknown)
        #expect(TunnelSummary.Status(apiValue: "healthy") == .healthy)
        #expect(TunnelSummary.Status(apiValue: "nonsense") == .unknown)
    }
}
