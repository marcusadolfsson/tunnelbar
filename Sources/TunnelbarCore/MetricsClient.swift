import Foundation

/// The JSON body of `cloudflared`'s `/ready` endpoint.
struct ReadyResponse: Decodable {
    let status: Int
    let readyConnections: Int
    let connectorId: String
}

public struct MetricsError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Reads a connector's loopback metrics server.
///
/// Every request is a GET against 127.0.0.1 on a port the target process is
/// already listening on, so this cannot affect a connector it did not start —
/// the read-only guarantee in the read-only guarantee holds at the network layer too.
public struct MetricsClient: Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 2.0) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // Loopback only: never let a proxy or a cache sit in front of this.
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    private func get(port: UInt16, path: String) async throws -> (Data, Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw MetricsError("could not build URL for port \(port)")
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    /// Fetches and decodes `/ready`.
    ///
    /// Accepts any HTTP status: a connector with zero live connections answers
    /// 503 with the same JSON body, and that is exactly the case the status
    /// item most needs to report.
    func ready(port: UInt16) async throws -> ReadyResponse {
        let (data, _) = try await get(port: port, path: "/ready")
        do {
            return try JSONDecoder().decode(ReadyResponse.self, from: data)
        } catch {
            throw MetricsError("port \(port) answered /ready but not with cloudflared JSON")
        }
    }

    func metrics(port: UInt16) async throws -> [PrometheusSample] {
        let (data, status) = try await get(port: port, path: "/metrics")
        guard status == 200, let text = String(data: data, encoding: .utf8) else {
            throw MetricsError("/metrics on port \(port) returned HTTP \(status)")
        }
        return PrometheusParser.parse(text)
    }

    /// Probes each candidate port and returns the first that behaves like a
    /// cloudflared metrics server.
    ///
    /// A connector may listen on more than one loopback port — a metrics server
    /// plus, say, a local ingress target — so identify it by response shape
    /// rather than assuming the only or lowest port is the right one.
    public func findMetricsPort(among candidates: [UInt16]) async -> UInt16? {
        for port in candidates {
            if (try? await ready(port: port)) != nil { return port }
        }
        return nil
    }

    /// Full snapshot for a connector whose metrics port is already known.
    public func snapshot(port: UInt16) async throws -> MetricsSnapshot {
        let ready = try await ready(port: port)
        // /metrics is best-effort: a connector that answers /ready is worth
        // reporting even if the Prometheus endpoint hiccups.
        let samples = (try? await metrics(port: port)) ?? []

        let edges = samples
            .filter { $0.name == "cloudflared_tunnel_server_locations" && $0.value > 0 }
            .compactMap { sample -> EdgeConnection? in
                guard let location = sample.labels["edge_location"] else { return nil }
                return EdgeConnection(
                    connectionID: sample.labels["connection_id"] ?? "?",
                    edgeLocation: location
                )
            }
            .sorted { $0.connectionID < $1.connectionID }

        func value(_ name: String) -> Double? {
            samples.first { $0.name == name }?.value
        }

        return MetricsSnapshot(
            port: port,
            connectorID: ready.connectorId,
            readyConnections: ready.readyConnections,
            haConnections: value("cloudflared_tunnel_ha_connections").map(Int.init),
            edgeConnections: edges,
            totalRequests: value("cloudflared_tunnel_total_requests"),
            concurrentRequests: value("cloudflared_tunnel_concurrent_requests_per_tunnel")
        )
    }
}
