import Foundation

/// One ingress rule from a tunnel's configuration.
public struct IngressRule: Codable, Sendable, Equatable {
    /// Nil for the catch-all rule at the end of every ingress list.
    public let hostname: String?
    /// Where the rule sends traffic, e.g. `http://localhost:8080` or
    /// `http_status:404`.
    public let service: String
    public let path: String?

    public init(hostname: String?, service: String, path: String? = nil) {
        self.hostname = hostname
        self.service = service
        self.path = path
    }

    /// The local port this rule points at, when it points at one.
    ///
    /// Returns nil for rules that do not reach a local listener at all —
    /// `http_status:404`, `bastion`, and the like — so a catch-all is never
    /// mistaken for an exposed service.
    public var localPort: UInt16? {
        guard let separator = service.range(of: "://") else { return nil }
        let scheme = String(service[service.startIndex..<separator.lowerBound]).lowercased()
        let remainder = service[separator.upperBound...]
        // Strip any path, then split host from port.
        let authority = remainder.prefix { $0 != "/" }

        guard let colon = authority.lastIndex(of: ":") else {
            // No explicit port: only http and https have a well-known default,
            // and guessing one for anything else would invent an exposure.
            switch scheme {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }
        return UInt16(authority[authority.index(after: colon)...])
    }

    /// Whether the rule targets this machine rather than some other host.
    ///
    /// A tunnel can route to any address its connector can reach, so a rule
    /// pointing at another host must not be reported as exposing a local port
    /// that happens to share a number.
    public var targetsLocalhost: Bool {
        guard let separator = service.range(of: "://") else { return false }
        let authority = service[separator.upperBound...].prefix { $0 != "/" }
        let host = authority.lastIndex(of: ":").map { String(authority[..<$0]) }
            ?? String(authority)
        return ["localhost", "127.0.0.1", "[::1]", "::1", ""].contains(host.lowercased())
    }
}

/// A local service, and the tunnel hostnames that reach it.
public struct ServiceExposure: Sendable, Equatable, Identifiable {
    public struct Binding: Sendable, Equatable {
        public let hostname: String
        public let tunnelName: String
        public let tunnelID: String
    }

    public var id: String { service.id }
    public let service: LocalService
    public let bindings: [Binding]

    public var isExposed: Bool { !bindings.isEmpty }
}

/// Joins local listening services against tunnel ingress rules.
///
/// The question this answers — "what on this Mac is reachable from the
/// internet, and through what" — is not answerable from either side alone. The
/// machine knows what is listening; only Cloudflare knows what is published.
public struct ExposureMap: Sendable {
    /// Ingress rules per tunnel, keyed by tunnel id.
    private let rulesByTunnel: [String: [IngressRule]]
    private let namesByTunnel: [String: String]

    public init(rulesByTunnel: [String: [IngressRule]], namesByTunnel: [String: String]) {
        self.rulesByTunnel = rulesByTunnel
        self.namesByTunnel = namesByTunnel
    }

    public func exposures(for services: [LocalService]) -> [ServiceExposure] {
        services.map { service in
            var bindings: [ServiceExposure.Binding] = []
            for (tunnelID, rules) in rulesByTunnel {
                for rule in rules {
                    guard rule.targetsLocalhost,
                          rule.localPort == service.port,
                          let hostname = rule.hostname
                    else { continue }
                    bindings.append(ServiceExposure.Binding(
                        hostname: hostname,
                        tunnelName: namesByTunnel[tunnelID] ?? tunnelID,
                        tunnelID: tunnelID))
                }
            }
            return ServiceExposure(
                service: service,
                bindings: bindings.sorted { $0.hostname < $1.hostname })
        }
        // Exposed services first: they are the ones worth looking at.
        .sorted {
            ($0.isExposed ? 0 : 1, $0.service.port) < ($1.isExposed ? 0 : 1, $1.service.port)
        }
    }
}
