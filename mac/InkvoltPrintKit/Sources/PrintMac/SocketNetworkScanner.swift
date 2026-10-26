import Darwin
import Foundation
import Network
import PrintCore
import Synchronization

/// The real network for Search my network (`NetworkSearch`): the IPv4 networks of this Mac's Ethernet and Wi-Fi interfaces
/// that are up (no VPN tunnel, bridge, AirDrop or loopback), TCP connections with Network framework, and the SNMP question
/// on a BSD socket (Network framework has no UDP broadcast). Nothing is sent until a search is asked for. Tells
/// `localNetwork` what it sees: a connection refused as Local Network denied, or an answer.
public struct SocketNetworkScanner: NetworkScanner {
    private let localNetwork: LocalNetworkSignal?

    public init(localNetwork: LocalNetworkSignal? = nil) { self.localNetwork = localNetwork }

    /// Interfaces never searched: VPN tunnels (utun, ipsec, ppp), virtual switches (bridge, vmnet), AirDrop and its low
    /// latency link (awdl, llw), Apple's internal ones (anpi, ap, gif, stf).
    private static let skipped = ["utun", "ipsec", "ppp", "bridge", "vmnet", "awdl", "llw", "anpi", "ap", "gif", "stf", "lo"]

    public func localNetworks() -> [LocalNetwork] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var found: [LocalNetwork] = []
        var cursor = head
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            let flags = Int32(bitPattern: entry.ifa_flags)
            let name = String(cString: entry.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  flags & IFF_BROADCAST != 0, !Self.skipped.contains(where: { name.hasPrefix($0) }), NetworkSearch.isLan(name, ""),
                  let address = Self.ipv4(entry.ifa_addr), let mask = Self.ipv4Number(entry.ifa_netmask) else { continue }
            found.append(LocalNetwork(address, mask.nonzeroBitCount))
        }
        return found
    }

    public func isOpen(_ host: String, port: Int, timeout: Duration) async throws -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let signal = localNetwork
        let open: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let once = Once()
                let finish: @Sendable (Bool) -> Void = { result in
                    guard once.claim() else { return }
                    connection.cancel()
                    done.resume(returning: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        signal?.answered()
                        finish(true)
                    case .waiting:
                        // Refused (nothing listens), no route, or Local Network denied: not a printer port either way.
                        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { signal?.denied() }
                        finish(false)
                    case .failed, .cancelled: finish(false)
                    default: break
                    }
                }
                connection.start(queue: Self.queue)
                Self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
        try Task.checkCancellation()
        return open
    }

    public func broadcastSnmp(_ broadcasts: [String], requests: [[UInt8]], window: Duration,
                              answered: @escaping @Sendable (String) -> Void) async throws {
        let stop = StopFlag()
        let signal = localNetwork
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    Self.broadcast(broadcasts, requests: requests, window: window, stop: stop, signal: signal, answered: answered)
                    done.resume()
                }
            }
        } onCancel: {
            stop.set()
        }
        try Task.checkCancellation()
    }

    /// Blocking: sends each request to UDP 161 at each broadcast address, then takes SNMP responses until `window` ends,
    /// checking `stop` every 100 ms. A datagram that isn't an SNMP response is ignored.
    static func broadcast(_ broadcasts: [String], requests: [[UInt8]], window: Duration, stop: StopFlag, signal: LocalNetworkSignal?,
                          answered: @Sendable (String) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        var slice = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))

        var sentAny = false
        for to in broadcasts {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UdpSnmpTransport.port.bigEndian
            guard inet_pton(AF_INET, to, &address.sin_addr) == 1 else { continue }
            for request in requests {
                let sent = request.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if sent == request.count { sentAny = true } else if errno == EHOSTUNREACH { signal?.denied() }
                // else: that network can't be reached now; the others are still asked
            }
        }
        guard sentAny else { return }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline && !stop.isSet {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length) }
                }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return
            }
            guard n > 0, UInt16(bigEndian: from.sin_port) == UdpSnmpTransport.port,
                  let message = try? SnmpMessage.decode(Array(buffer[0..<n])), message.type == .response else { continue }
            signal?.answered()
            answered(ipString(from.sin_addr))
        }
    }

    private static let queue = DispatchQueue(label: "inkvolt.network-search", attributes: .concurrent)

    private static func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let pointer, pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipString($0.pointee.sin_addr) }
    }

    private static func ipv4Number(_ pointer: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
        guard let pointer, pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }
}

private func ipString(_ address: in_addr) -> String {
    var address = address
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Lets only the first of several callbacks finish a continuation.
final class Once: Sendable {
    private let claimed = Atomic(false)
    func claim() -> Bool { !claimed.exchange(true, ordering: .relaxed) }
}

extension Duration {
    var timeInterval: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
