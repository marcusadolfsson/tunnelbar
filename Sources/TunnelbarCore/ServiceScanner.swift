import Darwin
import Foundation

/// A local service listening for TCP connections on this Mac.
public struct LocalService: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(address):\(port)/\(pid)" }

    public let port: UInt16
    public let address: String
    public let pid: pid_t
    public let processName: String
    /// False when bound to a wildcard address, so the service is reachable from
    /// the local network and not only from this Mac.
    public let isLoopbackOnly: Bool
    /// What this is, when it is something recognisable. Nil for anything the
    /// catalog does not know — which is the signal that it is worth a look.
    public let catalog: ServiceCatalog.Entry?

    /// Whether this is part of macOS rather than something installed.
    public var isSystemService: Bool { catalog?.isSystem ?? false }

    public init(
        port: UInt16,
        address: String,
        pid: pid_t,
        processName: String,
        isLoopbackOnly: Bool,
        catalog: ServiceCatalog.Entry? = nil
    ) {
        self.port = port
        self.address = address
        self.pid = pid
        self.processName = processName
        self.isLoopbackOnly = isLoopbackOnly
        self.catalog = catalog
    }
}

/// Enumerates listening TCP services across every visible process.
///
/// Read-only, like everything else in discovery: it reads socket tables through
/// `proc_pidinfo` and opens nothing.
///
/// Only processes running as the current user are visible without elevation, so
/// system daemons owned by root are absent. That is a real limit and is reported
/// as such rather than presented as "nothing else is listening".
public enum ServiceScanner {
    public static func listeningServices() -> [LocalService] {
        var services: [LocalService] = []

        for pid in ProcessScanner.allPIDs() {
            let listeners = SocketScanner.listeningSockets(of: pid)
            guard !listeners.isEmpty else { continue }
            let name = ProcessScanner.executablePath(of: pid)
                .map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"

            for listener in listeners {
                services.append(LocalService(
                    port: listener.port,
                    address: listener.address,
                    pid: pid,
                    processName: name,
                    isLoopbackOnly: listener.isLoopbackOnly,
                    catalog: ServiceCatalog.describe(processName: name, port: listener.port)))
            }
        }

        // One row per port per process: a service bound on both IPv4 and IPv6
        // is one service, and listing it twice reads as two.
        var seen = Set<String>()
        return services
            .sorted { ($0.port, $0.processName) < ($1.port, $1.processName) }
            .filter { seen.insert("\($0.port)/\($0.pid)").inserted }
    }
}
