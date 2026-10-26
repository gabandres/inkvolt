import Darwin
import Foundation
import PrintCore
import Synchronization

/// SNMP to a printer's agent over UDP port 161, on a BSD socket (Network framework has no UDP broadcast, which the subnet
/// search needs; one socket kind for both). Each request gets a socket of its own, connected to the host, so only its
/// replies arrive. Receiving needs `com.apple.security.network.server` in the sandbox.
public struct UdpSnmpTransport: SnmpTransport {
    public static let port: UInt16 = 161
    private let localNetwork: LocalNetworkSignal?

    public init(localNetwork: LocalNetworkSignal? = nil) { self.localNetwork = localNetwork }

    public func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        let stop = StopFlag()
        let port = Self.port
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Exchange, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    done.resume(returning: Self.exchange(request, host: host, port: port, timeout: timeout, stop: stop))
                }
            }
        } onCancel: {
            stop.set()
        }
        try Task.checkCancellation()
        switch result {
        case .reply(let bytes):
            localNetwork?.answered()
            return bytes
        case .denied:
            localNetwork?.denied()
            return nil
        case .none:
            return nil
        }
    }

    enum Exchange: Sendable {
        case reply([UInt8])
        /// The sandbox refused the destination (Local Network privacy: EHOSTUNREACH on a LAN address).
        case denied
        case none
    }

    /// Blocking: sends once, then waits for the first reply until `timeout`, checking `stop` every 100 ms.
    static func exchange(_ request: [UInt8], host: String, port: UInt16, timeout: Duration, stop: StopFlag) -> Exchange {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard getaddrinfo(bare, String(port), &hints, &list) == 0, let first = list else { return .none }
        defer { freeaddrinfo(list) }
        let address = first.pointee

        let fd = socket(address.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .none }
        defer { close(fd) }
        var slice = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))
        if connect(fd, address.ai_addr, address.ai_addrlen) != 0 { return errno == EHOSTUNREACH ? .denied : .none }
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        if sent != request.count { return errno == EHOSTUNREACH ? .denied : .none }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline && !stop.isSet {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { return .reply(Array(buffer[0..<n])) }
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return .none } // ECONNREFUSED: no agent there
        }
        return .none
    }
}

/// Set when the waiting task is cancelled; the blocking receive loop checks it.
final class StopFlag: Sendable {
    private let value = Atomic(false)
    func set() { value.store(true, ordering: .relaxed) }
    var isSet: Bool { value.load(ordering: .relaxed) }
}
