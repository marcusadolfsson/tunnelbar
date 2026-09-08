import Foundation

/// What `/user/tokens/verify` reports about a token.
public struct TokenVerification: Sendable, Equatable {
    public let id: String
    public let status: String
    public var isActive: Bool { status == "active" }
}

public struct CloudflareAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
}

/// A Cloudflare API failure.
///
/// Carries a message and optional API error codes, never the token. An error
/// string is the likeliest thing to reach a log or a bug report, and the token
/// is the one value that must not be in it.
public struct CloudflareAPIError: Error, CustomStringConvertible {
    public let description: String
    public let codes: [Int]

    init(_ description: String, codes: [Int] = []) {
        self.description = description
        self.codes = codes
    }
}

/// Minimal read-only client for the Cloudflare API.
///
/// Only the endpoints v0.2 actually needs. Everything here is a GET; nothing in
/// this type can change anything in a Cloudflare account, which matches the
/// account-level **Cloudflare Tunnel: Read** permission Tunnelbar asks for.
public struct CloudflareAPI: Sendable {
    static let base = URL(string: "https://api.cloudflare.com/client/v4")!
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    /// The envelope every Cloudflare API response is wrapped in.
    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable {
            let code: Int
            let message: String
        }
        let success: Bool
        let errors: [Failure]
        let result: T?
    }

    private func get<T: Decodable>(_ path: String, token: String, as: T.Type) async throws -> T {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLError descriptions never contain the request headers, but be
            // explicit rather than interpolating an arbitrary error.
            throw CloudflareAPIError("could not reach the Cloudflare API")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw CloudflareAPIError("unexpected response from the Cloudflare API (HTTP \(status))")
        }
        guard envelope.success, let result = envelope.result else {
            let codes = envelope.errors.map(\.code)
            // 1000 and 9109 are what Cloudflare returns for a bad or
            // insufficiently scoped token; say so plainly rather than echoing
            // an opaque code at the user.
            if status == 401 || status == 403 || codes.contains(1000) {
                throw CloudflareAPIError(
                    "the token was rejected — check it was copied whole and has "
                    + "account-level Cloudflare Tunnel: Read", codes: codes)
            }
            let message = envelope.errors.first?.message ?? "HTTP \(status)"
            throw CloudflareAPIError(message, codes: codes)
        }
        return result
    }

    /// Confirms a token is live before it is stored.
    ///
    /// Verifying first means a dead or mistyped token is never written to the
    /// Keychain, so "configured" in the UI always means "known to work".
    public func verify(token: String) async throws -> TokenVerification {
        struct Result: Decodable {
            let id: String
            let status: String
        }
        let result = try await get("user/tokens/verify", token: token, as: Result.self)
        return TokenVerification(id: result.id, status: result.status)
    }

    /// Accounts the token can see. Used to show *which* account a token is for,
    /// which is the difference between "a token" and a token you can identify.
    public func accounts(token: String) async throws -> [CloudflareAccount] {
        try await get("accounts", token: token, as: [CloudflareAccount].self)
    }

    /// Ingress rules for one tunnel: which hostname maps to which local
    /// service.
    ///
    /// For a token-based, remotely-managed tunnel this config lives in
    /// Cloudflare rather than in `~/.cloudflared/config.yml`, so the API is the
    /// only way to know what a tunnel actually exposes. Needs no permission
    /// beyond the Cloudflare Tunnel: Read the account list already uses.
    public func ingress(accountID: String, tunnelID: String, token: String) async throws -> [IngressRule] {
        struct Rule: Decodable {
            let hostname: String?
            let service: String?
            let path: String?
        }
        struct Config: Decodable { let ingress: [Rule]? }
        struct Wrapper: Decodable { let config: Config? }

        let wrapper = try await get(
            "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations",
            token: token, as: Wrapper.self)
        return (wrapper.config?.ingress ?? []).compactMap { rule in
            guard let service = rule.service else { return nil }
            return IngressRule(hostname: rule.hostname, service: service, path: rule.path)
        }
    }

    /// Tunnels on an account, newest first, excluding deleted ones.
    ///
    /// This is the only way to see tunnels that are **not** running on this
    /// machine, and the only source of a tunnel's friendly name — a local
    /// connector knows its own connector ID but not the name of the tunnel it
    /// serves.
    public func tunnels(accountID: String, token: String) async throws -> [TunnelSummary] {
        struct Connection: Decodable {
            let id: String?
            let client_id: String?
            let colo_name: String?
            let is_pending_reconnect: Bool?
            let opened_at: String?
        }
        struct Tunnel: Decodable {
            let id: String
            let name: String
            let status: String?
            let connections: [Connection]?
            let created_at: String?
        }

        let tunnels = try await get("accounts/\(accountID)/cfd_tunnel?is_deleted=false",
                                    token: token, as: [Tunnel].self)
        return tunnels.map { tunnel in
            let connections = (tunnel.connections ?? [])
            return TunnelSummary(
                id: tunnel.id,
                name: tunnel.name,
                accountID: accountID,
                status: TunnelSummary.Status(apiValue: tunnel.status),
                // `client_id` is the connector ID a running cloudflared reports
                // on /ready, which is what makes the local join possible.
                connectorIDs: Set(connections.compactMap(\.client_id)),
                colos: Array(Set(connections.compactMap(\.colo_name))).sorted(),
                connectionCount: connections.filter { $0.is_pending_reconnect != true }.count
            )
        }
    }
}
