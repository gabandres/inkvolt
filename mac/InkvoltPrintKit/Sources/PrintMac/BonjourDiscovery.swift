import Foundation
import PrintCore
import dnssd

private let noError = Int(kDNSServiceErr_NoError)

/// Finds printers' DNS-SD services on the local network: browses `_ipp`, `_ipps`, `_uscan` and `_uscans`, resolves each to
/// its host, port, TXT and IPv4 address, and reports the whole list on every change (join it with `DiscoveredPrinters`).
/// The types must be listed in `NSBonjourServices`, or macOS refuses them. Local Network denied (`kDNSServiceErr_PolicyDenied`)
/// is told to `localNetwork`, and browsing starts again every 10 s until it's allowed.
public final class BonjourDiscovery: @unchecked Sendable {
    public static let serviceTypes = ["_ipp._tcp", "_ipps._tcp", "_uscan._tcp", "_uscans._tcp"]
    static let retry: DispatchTimeInterval = .seconds(10)
    static let resolveTimeout: DispatchTimeInterval = .seconds(10)

    // Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "com.bermudezsystems.InkvoltPrint.bonjour")
    private let onChange: @Sendable ([AnnouncedService]) -> Void
    private let localNetwork: LocalNetworkSignal?
    private var browses: [DNSServiceRef] = []
    private var found: [String: Found] = [:]
    private var running = false
    private var emitPending = false
    private var generation = 0

    /// One service as browsing and resolving found it.
    final class Found {
        let key: String
        let instance: String
        let type: String
        let domain: String
        var interface: UInt32
        /// Browse adds less removes (a service may be seen on two interfaces).
        var seen = 1
        var hostName: String?
        var port: Int?
        var txt: [String: String] = [:]
        var ipv4: String?
        var resolve: DNSServiceRef?
        var address: DNSServiceRef?
        /// Kept alive while `resolve` and `address` may call back.
        var contexts: [Context] = []

        init(key: String, instance: String, type: String, domain: String, interface: UInt32) {
            self.key = key
            self.instance = instance
            self.type = type
            self.domain = domain
            self.interface = interface
        }

        var announced: AnnouncedService {
            AnnouncedService(instance: instance, dnssd: DnssdService(service: type, uuid: txt.first { $0.key.lowercased() == "uuid" }?.value,
                                                                     hostName: hostName, ipv4: ipv4, port: port, txt: txt))
        }
    }

    /// What a C callback gets back: the discovery, and the service it's about.
    final class Context {
        weak var discovery: BonjourDiscovery?
        let key: String
        let generation: Int

        init(_ discovery: BonjourDiscovery, key: String, generation: Int) {
            self.discovery = discovery
            self.key = key
            self.generation = generation
        }
    }

    /// The browses' context, kept alive while they may call back (a service's are kept by its `Found`).
    private var browseContext: Context?

    /// - Parameter onChange: called on a private queue with every service resolved so far; hand the list off.
    public init(localNetwork: LocalNetworkSignal? = nil, onChange: @escaping @Sendable ([AnnouncedService]) -> Void) {
        self.localNetwork = localNetwork
        self.onChange = onChange
    }

    deinit {
        for ref in browses { DNSServiceRefDeallocate(ref) }
        for f in found.values {
            if let r = f.resolve { DNSServiceRefDeallocate(r) }
            if let r = f.address { DNSServiceRefDeallocate(r) }
        }
    }

    public func start() { queue.async { self.begin() } }

    public func stop() { queue.async { self.end(clear: true) } }

    /// Drops everything seen so far and browses again.
    public func restart() {
        queue.async {
            self.end(clear: true)
            self.emit()
            self.begin()
        }
    }

    // MARK: Browsing

    private func begin() {
        guard !running else { return }
        running = true
        generation += 1
        let context = Context(self, key: "", generation: generation)
        browseContext = context
        for type in Self.serviceTypes {
            var ref: DNSServiceRef?
            let error = DNSServiceBrowse(&ref, 0, 0, type, "local.", { _, flags, interface, error, name, type, domain, context in
                guard let context else { return }
                let c = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                c.discovery?.browsed(c.generation, flags, interface, error, name.map { String(cString: $0) }, type.map { String(cString: $0) },
                                     domain.map { String(cString: $0) })
            }, Unmanaged.passUnretained(context).toOpaque())
            guard Int(error) == noError, let ref else {
                failed(error)
                return
            }
            DNSServiceSetDispatchQueue(ref, queue)
            browses.append(ref)
        }
    }

    private func end(clear: Bool) {
        running = false
        generation += 1
        for ref in browses { DNSServiceRefDeallocate(ref) }
        browses.removeAll()
        for f in found.values { stopResolving(f) }
        if clear { found.removeAll() }
        browseContext = nil
    }

    private func failed(_ error: DNSServiceErrorType) {
        if Int(error) == Int(kDNSServiceErr_PolicyDenied) { localNetwork?.denied() }
        end(clear: false)
        let generation = generation
        queue.asyncAfter(deadline: .now() + Self.retry) { [weak self] in
            guard let self, self.generation == generation, !self.running else { return }
            self.begin()
        }
    }

    private func browsed(_ generation: Int, _ flags: DNSServiceFlags, _ interface: UInt32, _ error: DNSServiceErrorType, _ name: String?,
                         _ type: String?, _ domain: String?) {
        guard generation == self.generation else { return }
        guard Int(error) == noError else {
            failed(error)
            return
        }
        guard let name, let type, let domain else { return }
        let cleanType = type.split(separator: ".").prefix(2).joined(separator: ".") // "_ipp._tcp."
        let key = "\(name)|\(cleanType)"
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
            localNetwork?.answered()
            if let f = found[key] {
                f.seen += 1
            } else {
                let f = Found(key: key, instance: name, type: cleanType, domain: domain, interface: interface)
                found[key] = f
                resolve(f)
            }
        } else if let f = found[key] {
            f.seen -= 1
            if f.seen <= 0 {
                stopResolving(f)
                found[key] = nil
                emitSoon()
            }
        }
    }

    // MARK: Resolving

    private func resolve(_ f: Found) {
        let context = Context(self, key: f.key, generation: generation)
        f.contexts.append(context)
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(&ref, 0, f.interface, f.instance, f.type, f.domain, { _, _, _, error, _, host, port, txtLength, txt, context in
            guard let context else { return }
            let c = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            let record = txt.map { BonjourDiscovery.parseTxt(UnsafeRawPointer($0), txtLength) } ?? [:]
            c.discovery?.resolved(c, error, host.map { String(cString: $0) }, Int(UInt16(bigEndian: port)), record)
        }, Unmanaged.passUnretained(context).toOpaque())
        guard Int(error) == noError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        f.resolve = ref
        let generation = generation
        let key = f.key
        queue.asyncAfter(deadline: .now() + Self.resolveTimeout) { [weak self] in
            guard let self, self.generation == generation, let f = self.found[key], f.resolve != nil else { return }
            self.stopResolving(f) // no answer: tried again when it's announced again
        }
    }

    private func resolved(_ c: Context, _ error: DNSServiceErrorType, _ host: String?, _ port: Int, _ txt: [String: String]) {
        guard c.generation == generation, let f = found[c.key] else { return }
        if let r = f.resolve {
            DNSServiceRefDeallocate(r)
            f.resolve = nil
        }
        guard Int(error) == noError, let host else { return }
        f.hostName = host.hasSuffix(".") ? String(host.dropLast()) : host
        f.port = port
        f.txt = txt
        emitSoon()

        let context = Context(self, key: f.key, generation: generation)
        f.contexts.append(context)
        var ref: DNSServiceRef?
        let lookup = DNSServiceGetAddrInfo(&ref, 0, f.interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { _, flags, _, error, _, address, _, context in
            guard let context, Int(error) == noError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
            let c = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { BonjourDiscovery.ipString($0.pointee.sin_addr) }
            c.discovery?.addressed(c, ip)
        }, Unmanaged.passUnretained(context).toOpaque())
        guard Int(lookup) == noError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        f.address = ref
    }

    private func addressed(_ c: Context, _ ip: String) {
        guard c.generation == generation, let f = found[c.key] else { return }
        if let r = f.address {
            DNSServiceRefDeallocate(r)
            f.address = nil
        }
        f.ipv4 = ip
        emitSoon()
    }

    private func stopResolving(_ f: Found) {
        if let r = f.resolve { DNSServiceRefDeallocate(r) }
        if let r = f.address { DNSServiceRefDeallocate(r) }
        f.resolve = nil
        f.address = nil
        f.contexts.removeAll()
    }

    // MARK: Reporting

    private func emitSoon() {
        guard !emitPending else { return }
        emitPending = true
        queue.async {
            self.emitPending = false
            self.emit()
        }
    }

    private func emit() {
        onChange(found.values.sorted { $0.key < $1.key }.filter { $0.hostName != nil }.map(\.announced))
    }

    // MARK: Helpers

    /// TXT keys as given (`DnssdService` lower-cases them); values as UTF-8.
    static func parseTxt(_ bytes: UnsafeRawPointer, _ length: UInt16) -> [String: String] {
        var result: [String: String] = [:]
        let count = TXTRecordGetCount(length, bytes)
        var key = [CChar](repeating: 0, count: 256)
        for i in 0..<count {
            var valueLength: UInt8 = 0
            var value: UnsafeRawPointer?
            guard TXTRecordGetItemAtIndex(length, bytes, i, UInt16(key.count), &key, &valueLength, &value) == noError else { continue }
            let name = text(key)
            let text = value.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(valueLength)), as: UTF8.self) } ?? ""
            if !name.isEmpty { result[name] = text }
        }
        return result
    }

    static func ipString(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return text(buffer)
    }
}

/// A NUL-terminated C string in a buffer.
private func text(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
