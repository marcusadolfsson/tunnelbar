import Foundation

/// Builds the complete read-only picture of connectors on this machine.
public struct DiscoveryEngine: Sendable {
    /// A healthy `cloudflared` connector maintains four HA edge connections.
    /// Fewer means degraded rather than down: the tunnel still serves traffic.
    public static let expectedConnections = 4

    private let metrics: MetricsClient

    public init(metrics: MetricsClient = MetricsClient()) {
        self.metrics = metrics
    }

    static func health(for snapshot: MetricsSnapshot?) -> Health {
        guard let snapshot, let ready = snapshot.readyConnections else { return .unknown }
        if ready <= 0 { return .down }
        return ready >= expectedConnections ? .healthy : .degraded
    }

    public func discover(now: Date = Date()) async -> DiscoveryReport {
        let resolver = OwnershipResolver()
        var notes = resolver.notes
        let processes = ProcessScanner.connectorProcesses()

        var connectors: [Connector] = []
        for process in processes {
            let ports = SocketScanner.listeningLoopbackPorts(of: process.pid)

            var snapshot: MetricsSnapshot?
            var metricsError: String?

            if ports.isEmpty {
                metricsError = "no loopback listener found for pid \(process.pid); "
                    + "the connector may still be starting up"
            } else if let port = await metrics.findMetricsPort(among: ports) {
                do {
                    snapshot = try await metrics.snapshot(port: port)
                } catch {
                    metricsError = "\(error)"
                }
            } else {
                metricsError = "none of the loopback ports "
                    + "\(ports.map(String.init).joined(separator: ", "))"
                    + " answered as a cloudflared metrics server"
            }

            let (ownership, ownerLabel) = resolver.ownership(for: process)

            connectors.append(Connector(
                pid: process.pid,
                executablePath: process.executablePath,
                redactedArguments: process.redactedArguments,
                startedAt: process.startedAt,
                uptimeSeconds: max(0, Int(now.timeIntervalSince(process.startedAt))),
                ownership: ownership,
                ownerLabel: ownerLabel,
                isManageable: ownership.isManageable,
                health: Self.health(for: snapshot),
                metrics: snapshot,
                metricsError: metricsError
            ))
        }

        if connectors.isEmpty {
            notes.append(DiscoveryNote(
                kind: "empty",
                detail: "no cloudflared connector is running on this machine"))
        }
        notes.append(contentsOf: localConfigNotes())

        let services = ServiceScanner.listeningServices()
        if !services.isEmpty {
            notes.append(DiscoveryNote(
                kind: "localServices",
                detail: "\(services.count) listening TCP services visible; processes owned by "
                    + "other users, including root daemons, are not"))
        }

        return DiscoveryReport(
            generatedAt: now,
            connectors: connectors.sorted { $0.pid < $1.pid },
            localServices: services,
            notes: notes
        )
    }

    /// Describes the state of `~/.cloudflared`.
    ///
    /// Its absence is the *expected* state for a token-based, remotely managed
    /// tunnel and must never be reported as an error. Only the
    /// directory listing is read — credentials and certificates in it are never
    /// opened.
    private func localConfigNotes() -> [DiscoveryNote] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            return [DiscoveryNote(
                kind: "localConfig",
                detail: "~/.cloudflared does not exist — normal for token-based tunnels")]
        }
        let hasConfig = entries.contains { $0 == "config.yml" || $0 == "config.yaml" }
        return [DiscoveryNote(
            kind: "localConfig",
            detail: hasConfig
                ? "~/.cloudflared holds a config.yml (locally managed ingress)"
                : "~/.cloudflared exists but holds no config.yml — normal for token-based tunnels")]
    }
}
