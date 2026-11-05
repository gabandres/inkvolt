import Foundation
import PrintCore
import dnssd

/// PrintMac's readers for a queue printer whose printer may say more than its queue (roadmap 3.6, route 1): Get-Printer-
/// Attributes to the printer `IppQueueReading.target` names, through `transport` (this Mac's URLSession). A Bonjour service
/// (`dnssd://`, and macOS's `ippusb://`, whose backend is the dnssd one) is resolved first, each time it's asked, so a relay
/// that moved to another port is still found. Proved on `ignia-mac` (research file, 3.6): the sandboxed app reaches a relay
/// on `localhost` with `network.client` alone; cupsd's `localhost:631` stays refused, and isn't asked.
public enum QueueDeviceReaders {
    public static func readers(for d: CupsDestination, transport: @escaping HttpTransportFactory) -> [any QueueDeviceReader] {
        guard let from = IppQueueReading.route(d), let target = IppQueueReading.target(d) else { return [] }
        let usb = from == .printerOverUsb
        switch target {
        case .url(let url):
            return [IppQueueDeviceReader(usb: usb, transport: transport) { url }]
        case .service(let instance, let type, let domain):
            return [IppQueueDeviceReader(usb: usb, transport: transport) {
                guard let s = await ServiceResolve.once(instance: instance, type: type, domain: domain), let host = s.hostName else { return nil }
                return DnssdJoin.ippUri(s, host: host)
            }]
        }
    }
}

/// One Bonjour service resolved once (`DNSServiceResolve` on every interface, the local-only ones included): its host, port
/// and TXT record, or nil when it doesn't answer within `timeout`. Its type must be in `NSBonjourServices`.
enum ServiceResolve {
    static let timeout: DispatchTimeInterval = .seconds(5)

    static func once(instance: String, type: String, domain: String) async -> DnssdService? {
        let box = Resolving(tls: type == "_ipps._tcp")
        return await withCheckedContinuation { done in
            box.queue.async {
                box.done = done
                var ref: DNSServiceRef?
                let error = DNSServiceResolve(&ref, 0, 0, instance, type, domain, { _, _, _, error, _, host, port, txtLength, txt, context in
                    guard let context else { return }
                    let box = Unmanaged<Resolving>.fromOpaque(context).takeUnretainedValue()
                    guard Int(error) == Int(kDNSServiceErr_NoError), let host else { return box.finish(nil) }
                    var name = String(cString: host)
                    if name.hasSuffix(".") { name.removeLast() }
                    let record = txt.map { BonjourDiscovery.parseTxt(UnsafeRawPointer($0), txtLength) } ?? [:]
                    box.finish(DnssdService(service: box.tls ? "_ipps._tcp" : "_ipp._tcp", uuid: nil, hostName: name, ipv4: nil,
                                            port: Int(UInt16(bigEndian: port)), txt: record))
                }, Unmanaged.passUnretained(box).toOpaque())
                guard Int(error) == Int(kDNSServiceErr_NoError), let ref else { return box.finish(nil) }
                box.ref = ref
                DNSServiceSetDispatchQueue(ref, box.queue)
                box.queue.asyncAfter(deadline: .now() + timeout) { box.finish(nil) }
            }
        }
    }

    /// One resolve's state, touched only on `queue` (the callback runs there too).
    private final class Resolving: @unchecked Sendable {
        let queue = DispatchQueue(label: "inkvolt.resolve")
        let tls: Bool
        var ref: DNSServiceRef?
        var done: CheckedContinuation<DnssdService?, Never>?

        init(tls: Bool) { self.tls = tls }

        func finish(_ service: DnssdService?) {
            if let ref {
                DNSServiceRefDeallocate(ref)
                self.ref = nil
            }
            guard let done else { return }
            self.done = nil
            done.resume(returning: service)
        }
    }
}
