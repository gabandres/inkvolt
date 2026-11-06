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
    private let port: UInt16

    public init(localNetwork: LocalNetworkSignal? = nil) {
        self.localNetwork = localNetwork
        port = Self.port
    }

    /// On another port (the tests' agents on loopback).
    init(port: UInt16) {
        localNetwork = nil
        self.port = port
    }

    public func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        let stop = StopFlag()
        let port = port
        let once = OnceExchange()
        // Cancelled, the wait ends at once: not when the blocking loop next looks at `stop`, which on a busy machine may be
        // long after (the block can wait for a thread; CI once took 28 s to end a cancelled 30 s wait).
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Exchange, Never>) in
                once.start(done)
                DispatchQueue.global(qos: .utility).async {
                    once.finish(Self.exchange(request, host: host, port: port, timeout: timeout, stop: stop))
                }
            }
        } onCancel: {
            stop.set()
            once.finish(.none)
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

/// The exchange's continuation, resumed once: by the exchange's end or by cancellation, whichever comes first. Cancelled
/// before the continuation is there, it resumes as soon as it is.
final class OnceExchange: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<UdpSnmpTransport.Exchange, Never>?, ended: UdpSnmpTransport.Exchange?)>((nil, nil))

    func start(_ continuation: CheckedContinuation<UdpSnmpTransport.Exchange, Never>) {
        let ended: UdpSnmpTransport.Exchange? = state.withLock { s in
            if let ended = s.ended { return ended }
            s.continuation = continuation
            return nil
        }
        if let ended { continuation.resume(returning: ended) }
    }

    func finish(_ result: UdpSnmpTransport.Exchange) {
        let waiting: CheckedContinuation<UdpSnmpTransport.Exchange, Never>? = state.withLock { s in
            if s.ended != nil { return nil }
            s.ended = result
            let c = s.continuation
            s.continuation = nil
            return c
        }
        waiting?.resume(returning: result)
    }
}

/// Set when the waiting task is cancelled; the blocking receive loop checks it.
final class StopFlag: Sendable {
    private let value = Atomic(false)
    func set() { value.store(true, ordering: .relaxed) }
    var isSet: Bool { value.load(ordering: .relaxed) }
}
