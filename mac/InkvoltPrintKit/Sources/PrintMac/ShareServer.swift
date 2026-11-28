import Foundation
import Network
import PrintCore
import dnssd

/// The shared scanner's HTTPS server (roadmap 3.1; Windows' `KestrelShareHost`): the phone scan's Network framework server
/// (`NetworkPhoneHost`: TLS 1.2 or 1.3 with the app's certificate, a device `ShareListen.allowPeer` refuses cancelled
/// before TLS starts, `acceptLocalOnly`) serving eSCL through `PhoneHttp` to the `SharedScanner`, with Windows' connection
/// limits: `maxConnections` at once, `maxConnectionsPerPeer` from one device. No logging of devices. `close` closes the
/// port at once and cancels the requests under way.
public struct NetworkShareHost: ShareHost {
    /// Connections at once, all devices together, and from one device (Windows' `KestrelShareHost`).
    public static let maxConnections = 32, maxConnectionsPerPeer = 8

    public init() {}

    public func start(_ listen: ShareListen) async throws -> any PhoneListener {
        let listener = try NetworkPhoneHost.listener(listen.certificate, loopbackOnly: listen.loopbackOnly, port: listen.port)
        let server = NetworkPhoneListener(listener, allowPeer: listen.allowPeer,
                                          counts: PhoneConnections(maxConnections: Self.maxConnections, maxPerPeer: Self.maxConnectionsPerPeer),
                                          service: listen.scanner)
        return try await server.start()
    }
}

/// This Mac's networks for a share (`SystemPhoneNetworks`'), and Network framework's path monitor telling when they change
/// (an address, an interface, Wi-Fi joined or left), only while it's watched.
public struct SystemShareNetworks: ShareNetworks {
    public init() {}

    public func read() -> [LocalNetwork] { SocketNetworkScanner().localNetworks() }

    public func watch(_ changed: @escaping @Sendable () -> Void) -> any ShareWatch {
        let monitor = NWPathMonitor()
        let first = FirstSeen()
        monitor.pathUpdateHandler = { _ in
            if first.seen() { changed() } // the first update is the path as it is now
        }
        monitor.start(queue: DispatchQueue(label: "com.bermudezsystems.InkvoltPrint.share-networks"))
        return PathWatch(monitor: monitor)
    }

    private final class FirstSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var was = false
        /// False the first time, true after.
        func seen() -> Bool { lock.withLock { defer { was = true }; return was } }
    }

    private struct PathWatch: ShareWatch, @unchecked Sendable {
        let monitor: NWPathMonitor
        func stop() async { monitor.cancel() }
    }
}

/// Announces the share over DNS-SD with macOS's own responder (`DNSServiceRegister`; Windows' `DnssdAdvertiser`): the
/// instance, `_uscans._tcp`, the port and the TXT keys, on this Mac's `.local` name, until the announcement is stopped
/// (macOS then says goodbye). Waits at most `timeout` for the responder to confirm. **Mac difference:** registered on
/// every interface (macOS's responder answers on each; `LocalNetwork` has no interface): the server still lets in only the
/// served networks' devices. Local Network denied fails it (`kDNSServiceErr_PolicyDenied`): the card says it wasn't
/// announced.
public struct BonjourShareAdvertiser: ShareAdvertiser {
    static let timeout: Duration = .seconds(10)

    public init() {}

    public func advertise(_ advert: ShareAdvert, on: [LocalNetwork]) async throws -> any ShareWatch {
        let registration = Registration()
        let txt = Self.txtRecord(advert.txt)
        var ref: DNSServiceRef?
        let context = Unmanaged.passRetained(registration).toOpaque()
        let error = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&ref, 0, 0, advert.instance, ShareAdvert.service, nil, nil, UInt16(clamping: advert.port).bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, { _, _, error, _, _, _, context in
                                   guard let context else { return }
                                   Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue().done(error)
                               }, context)
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            Unmanaged<Registration>.fromOpaque(context).release()
            throw ShareAdvertError(error)
        }
        let announced = Announced(ref, context)
        DNSServiceSetDispatchQueue(ref, Announced.queue)
        let timer = Task {
            try? await Task.sleep(for: Self.timeout)
            registration.done(DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<DNSServiceErrorType, Never>) in registration.wait(c) }
        } onCancel: {
            registration.done(DNSServiceErrorType(kDNSServiceErr_Unknown))
        }
        timer.cancel()
        guard result == DNSServiceErrorType(kDNSServiceErr_NoError), !Task.isCancelled else {
            await announced.stop()
            if Task.isCancelled { throw CancellationError() }
            throw ShareAdvertError(result)
        }
        return announced
    }

    /// TXT record data: each `key=value` after its length, cut to 255 bytes.
    static func txtRecord(_ txt: [(key: String, value: String)]) -> [UInt8] {
        var data: [UInt8] = []
        for (key, value) in txt {
            let entry = Array("\(key)=\(value)".utf8).prefix(255)
            data.append(UInt8(entry.count))
            data += entry
        }
        return data.isEmpty ? [0] : data
    }

    /// The responder's first word on the registration (registered, or why not), once.
    private final class Registration: @unchecked Sendable {
        private let once = OnceResult<DNSServiceErrorType>()
        func wait(_ c: CheckedContinuation<DNSServiceErrorType, Never>) { once.start(c) }
        func done(_ error: DNSServiceErrorType) { once.finish(error) }
    }

    /// One registration until stopped; stopping deallocates it on its queue (the responder then sends goodbyes).
    private final class Announced: ShareWatch, @unchecked Sendable {
        static let queue = DispatchQueue(label: "com.bermudezsystems.InkvoltPrint.share-advert")
        private let lock = NSLock()
        private var ref: DNSServiceRef?
        private let context: UnsafeMutableRawPointer

        init(_ ref: DNSServiceRef, _ context: UnsafeMutableRawPointer) {
            self.ref = ref
            self.context = context
        }

        func stop() async {
            let taken: DNSServiceRef? = lock.withLock {
                defer { ref = nil }
                return ref
            }
            guard let taken else { return }
            let handle = Handle(ref: taken, context: context)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Self.queue.async {
                    handle.deallocate()
                    c.resume()
                }
            }
        }
    }

    /// A registration's reference and context, handed to its queue to be let go there (they're only ever used on it).
    private struct Handle: @unchecked Sendable {
        let ref: DNSServiceRef
        let context: UnsafeMutableRawPointer

        func deallocate() {
            DNSServiceRefDeallocate(ref)
            Unmanaged<Registration>.fromOpaque(context).release()
        }
    }
}

/// DNS-SD refused the announcement (its error code; -65570 is Local Network denied).
public struct ShareAdvertError: Error, CustomStringConvertible {
    public let code: Int32
    init(_ code: DNSServiceErrorType) { self.code = code }
    public var description: String { "DNS-SD error \(code)" }
}
