import Darwin
import Foundation

/// Finds the loopback TCP ports a process is listening on.
///
/// This is how Tunnelbar solves the port-discovery problem in the port-discovery problem:
/// started without an explicit `--metrics` flag, `cloudflared` binds a random
/// loopback port that changes on every restart. Reading the process's own
/// socket table needs no cooperation from the connector and no log file — which
/// matters because for a connector Tunnelbar did not start, the log location is
/// usually unknown.
///
/// Uses `proc_pidinfo` rather than shelling out to `lsof`: no subprocess, no
/// output parsing, and it cannot be made to do anything but read.
public enum SocketScanner {
    // Mirrors of <sys/proc_info.h> constants that Swift does not always import
    // as usable values. Verified against the macOS 26.6 SDK header.
    private static let socketKindTCP: Int32 = 2      // SOCKINFO_TCP
    private static let tcpStateListen: Int32 = 1     // TSI_S_LISTEN
    private static let flagIPv4: UInt8 = 0x1         // INI_IPV4
    private static let flagIPv6: UInt8 = 0x2         // INI_IPV6

    /// File descriptors owned by `pid`.
    private static func fileDescriptors(of pid: pid_t) -> [proc_fdinfo] {
        let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sized > 0 else { return [] }
        // Headroom for descriptors opened between sizing and fetching.
        let capacity = Int(sized) / MemoryLayout<proc_fdinfo>.size + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bytes = descriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress,
                         Int32(buffer.count * MemoryLayout<proc_fdinfo>.size))
        }
        guard bytes > 0 else { return [] }
        return Array(descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.size))
    }

    /// Whether a socket's local address is reachable over loopback.
    ///
    /// Accepts a wildcard bind as well as an explicit loopback one: a connector
    /// told to serve metrics on `0.0.0.0` is still reachable at 127.0.0.1, and
    /// refusing to probe it would report a healthy connector as unknown.
    private static func isLoopbackReachable(_ info: in_sockinfo) -> Bool {
        if info.insi_vflag & flagIPv4 != 0 {
            let address = info.insi_laddr.ina_46.i46a_addr4.s_addr
            return address == in_addr_t(0x7F00_0001).bigEndian || address == 0
        }
        if info.insi_vflag & flagIPv6 != 0 {
            let bytes = withUnsafeBytes(of: info.insi_laddr.ina_6) { Array($0) }
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            return isLoopback || isUnspecified
        }
        return false
    }

    /// One listening TCP socket.
    public struct Listener: Sendable, Hashable {
        public let address: String
        public let port: UInt16
        /// False when bound to a wildcard address, i.e. reachable from the
        /// network rather than only from this Mac. That distinction matters as
        /// much as tunnel exposure and is easy to be wrong about.
        public let isLoopbackOnly: Bool
    }

    /// Every listening TCP socket `pid` holds, loopback or not.
    public static func listeningSockets(of pid: pid_t) -> [Listener] {
        var found = Set<Listener>()

        for descriptor in fileDescriptors(of: pid)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInfo = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let written = withUnsafeMutablePointer(to: &socketInfo) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard written == size,
                  socketInfo.psi.soi_kind == socketKindTCP,
                  socketInfo.psi.soi_proto.pri_tcp.tcpsi_state == tcpStateListen
            else { continue }

            let inet = socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
            guard port > 0, let address = describe(inet) else { continue }
            found.insert(Listener(address: address, port: port,
                                  isLoopbackOnly: isLoopbackAddress(inet)))
        }
        return found.sorted { ($0.port, $0.address) < ($1.port, $1.address) }
    }

    /// Printable local address for a socket.
    private static func describe(_ info: in_sockinfo) -> String? {
        if info.insi_vflag & flagIPv4 != 0 {
            let raw = info.insi_laddr.ina_46.i46a_addr4.s_addr
            var address = in_addr(s_addr: raw)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
            else { return nil }
            return String(cString: buffer)
        }
        if info.insi_vflag & flagIPv6 != 0 {
            var address = info.insi_laddr.ina_6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { return nil }
            return String(cString: buffer)
        }
        return nil
    }

    /// Explicitly bound to loopback, as opposed to a wildcard address.
    private static func isLoopbackAddress(_ info: in_sockinfo) -> Bool {
        if info.insi_vflag & flagIPv4 != 0 {
            return info.insi_laddr.ina_46.i46a_addr4.s_addr == in_addr_t(0x7F00_0001).bigEndian
        }
        if info.insi_vflag & flagIPv6 != 0 {
            let bytes = withUnsafeBytes(of: info.insi_laddr.ina_6) { Array($0) }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
        return false
    }

    /// Every distinct loopback TCP port `pid` is listening on, ascending.
    ///
    /// A connector normally has exactly one (the metrics server), but the list
    /// is returned in full so the caller can probe each candidate rather than
    /// guessing — see `MetricsClient.findMetricsPort`.
    public static func listeningLoopbackPorts(of pid: pid_t) -> [UInt16] {
        var ports = Set<UInt16>()

        for descriptor in fileDescriptors(of: pid)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInfo = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let written = withUnsafeMutablePointer(to: &socketInfo) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard written == size,
                  socketInfo.psi.soi_kind == socketKindTCP,
                  socketInfo.psi.soi_proto.pri_tcp.tcpsi_state == tcpStateListen
            else { continue }

            let inet = socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini
            guard isLoopbackReachable(inet) else { continue }

            // insi_lport is stored in network byte order.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
            if port > 0 { ports.insert(port) }
        }

        return ports.sorted()
    }
}
