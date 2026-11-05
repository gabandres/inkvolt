import Foundation

/// Route 1 on the Mac (roadmap 3.6, the Windows app's `IppQueueReading`): a queue whose printer speaks IPP (a driverless USB
/// printer's IPP-over-USB relay, or a network IPP queue nobody added as a network printer) is asked for its printer
/// attributes, and the reply is read with the same IPP mapping as a network printer's. The asking is PrintMac's
/// (`QueueDeviceReader`); this decides which queues are asked, what is asked, and what the bytes say.
public enum IppQueueReading {
    /// The attributes asked for: the status and supplies a network printer is read for, without identifiers.
    public static let attributes = [
        "printer-state", "printer-state-reasons", "printer-state-message", "marker-names", "marker-levels", "marker-low-levels",
        "marker-high-levels", "marker-types", "marker-colors", "printer-alert", "printer-alert-description",
    ]

    /// Largest reply read (a real one is a few kilobytes).
    public static let maxBytes = 256 * 1024

    /// The reading from the printer's bytes: a whole Get-Printer-Attributes reply (what the Mac's transport gets), or the
    /// printer-attributes group alone, with or without its group tag (what Windows hands over). Nil when there are none,
    /// too many, the printer refused, or they can't be read.
    public static func from(_ bytes: [UInt8], usb: Bool) -> QueueDeviceReading? {
        guard let first = bytes.first, bytes.count <= maxBytes else { return nil }
        var framed: [UInt8]
        if first == 1 || first == 2 { // IPP version 1.x or 2.x: a whole reply
            framed = bytes
        } else {
            framed = [1, 1, 0, 0, 0, 0, 0, 1] // version 1.1, successful-ok, request id 1
            if first >= 0x10 { framed.append(0x04) } // attributes without their group tag: printer-attributes
            framed += bytes
            framed.append(0x03)
        }
        guard let response = try? IppCodec.decode(framed), response.ok else { return nil }
        return from(response, usb: usb)
    }

    /// The reading from a decoded reply: nil when it has neither a state nor supplies.
    public static func from(_ response: IppResponse, usb: Bool) -> QueueDeviceReading? {
        guard response.attributes["printer-state"] != nil || response.attributes["marker-names"] != nil else { return nil }
        let status = IppClient.toStatus(response)
        let from: QueueReadingFrom = usb ? .printerOverUsb : .printerOverNetwork
        let supplies = IppClient.toConsumables(response)
        // No state it can read says nothing about the printer: macOS's status stands (a jam it knows of doesn't become
        // "Unknown"), with the problems it did give.
        return status.code == "unknown"
            ? QueueDeviceReading(from: from, status: nil, alerts: status.alerts, supplies: supplies)
            : QueueDeviceReading(from: from, status: status, alerts: [], supplies: supplies)
    }

    /// Which way a queue's printer can be asked over IPP, from its `device-uri`: over USB for CUPS's own IPP-over-USB
    /// (`ippusb://`) or a local relay to a USB printer (`ipp://localhost:60000/…`, as `ippusbxd` serves one); over the
    /// network for an IPP or Bonjour queue. Nil: nothing to ask (macOS's `usb://` backend speaks the printer's own language,
    /// not IPP, so only cupsd's copy of the levels is there; a raw socket or LPD queue has SNMP; a shared queue is another
    /// computer's printer).
    public static func route(_ d: CupsDestination) -> QueueReadingFrom? {
        guard let uri = d.deviceUri, let scheme = CupsQueues.scheme(uri) else { return nil }
        if scheme == "ippusb" { return .printerOverUsb }
        guard CupsQueues.connection(d) == .network, ["ipp", "ipps", "http", "https", "dnssd", "mdns"].contains(scheme) else { return nil }
        let host = CupsQueues.host(uri)?.lowercased()
        return ["localhost", "127.0.0.1", "::1"].contains(host) ? .printerOverUsb : .printerOverNetwork
    }

    /// Where a queue `route` names is asked: the address in its device URI (`ipp://localhost:8632/ipp/print` as
    /// `http://localhost:8632/ipp/print`; IPP's port 631 when none is given), or the Bonjour service it names, which PrintMac
    /// resolves first (`dnssd://`, `mdns://`, and macOS's `ippusb://`, whose backend is the dnssd one: research file, 3.6). Nil:
    /// nothing to ask (no route, an `ippusb://` with a make and model instead of a service, which only cupsd can reach, or an
    /// address that isn't one). Credentials in the URI are never kept.
    public static func target(_ d: CupsDestination) -> IppQueueTarget? {
        guard route(d) != nil, let uri = d.deviceUri, let scheme = CupsQueues.scheme(uri), let host = CupsQueues.host(uri) else { return nil }
        if let service = service(host) { return service }
        guard ["ipp", "ipps", "http", "https"].contains(scheme), isHostName(host) else { return nil }
        let tls = scheme == "ipps" || scheme == "https"
        let (given, path) = portAndPath(uri)
        let port = given ?? (scheme.hasPrefix("ipp") ? 631 : tls ? 443 : 80)
        guard (1...65535).contains(port), let path else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(tls ? "https" : "http")://\(bracketed):\(port)\(path)").map { .url($0) }
    }

    /// "Demo Inkjet._ipp._tcp.local." as the service to resolve; nil for a plain host, or a service that isn't IPP.
    static func service(_ host: String) -> IppQueueTarget? {
        for type in ["_ipp._tcp", "_ipps._tcp"] {
            guard let r = host.range(of: "." + type, options: .caseInsensitive) else { continue }
            let instance = String(host[..<r.lowerBound])
            var domain = String(host[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain.isEmpty { domain = "local" }
            guard !instance.isEmpty, instance.utf8.count <= 63, !instance.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  isHostName(domain) else { return nil }
            return .service(instance: instance, type: type, domain: domain + ".")
        }
        return nil
    }

    /// A DNS name or an IP address: letters, digits, dots, hyphens and an IPv6 address's colons, nothing else.
    private static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:".contains($0)) }
    }

    /// The port and the path (no query, no fragment) after a URI's host; nil path for one that can't be sent as it is.
    private static func portAndPath(_ uri: String) -> (Int?, String?) {
        guard let start = uri.range(of: "://")?.upperBound else { return (nil, nil) }
        let rest = uri[start...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var port: Int?
        let afterHost = authority.hasPrefix("[") ? authority.firstIndex(of: "]").map { authority[authority.index(after: $0)...] } ?? "" : authority
        if let colon = afterHost.lastIndex(of: ":"), !authority.hasPrefix("[") || afterHost.first == ":" {
            let digits = afterHost[afterHost.index(after: colon)...]
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return (nil, nil) }
            port = Int(digits)
        }
        let pathEnd = rest[authorityEnd...].firstIndex { "?#".contains($0) } ?? rest.endIndex
        var path = String(rest[authorityEnd..<pathEnd])
        if path.isEmpty { path = "/" }
        let safe = path.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != "\\" }
            && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
        return (port, safe ? path : nil)
    }
}

/// Where a queue's printer is asked (`IppQueueReading.target`).
public enum IppQueueTarget: Equatable, Sendable {
    /// The printer object's http(s) address.
    case url(URL)
    /// A Bonjour service to resolve first ("_ipp._tcp" or "_ipps._tcp", domain "local."): its host, port and `rp` give the
    /// address (`DnssdJoin.ippUri`).
    case service(instance: String, type: String, domain: String)
}

/// Route 1's asking, the part of PrintMac's reader that needs no Apple framework (so it's tested on the PC too):
/// Get-Printer-Attributes with `IppQueueReading.attributes` to the address `endpoint` gives (the device URI's, or a resolved
/// Bonjour service's), sent once, the reply cut at `IppQueueReading.maxBytes` and read by `IppQueueReading.from`. Read-only.
/// Nil: no address now, a refusal, an error page, or nothing it can read; a printer that doesn't answer throws.
public struct IppQueueDeviceReader: QueueDeviceReader {
    public let usb: Bool
    private let transport: HttpTransportFactory
    private let endpoint: @Sendable () async throws -> URL?

    public init(usb: Bool, transport: @escaping HttpTransportFactory, endpoint: @escaping @Sendable () async throws -> URL?) {
        self.usb = usb
        self.transport = transport
        self.endpoint = endpoint
    }

    public func read() async throws -> QueueDeviceReading? {
        guard let url = try await endpoint(),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else { return nil }
        let http = DeviceHttp(host: host, transport: transport)
        let body = IppCodec.encodeGetPrinterAttributes(IppClient(http, endpoint: url).printerUri, IppQueueReading.attributes)
        let request = HttpRequest("POST", url, headers: ["Content-Type": "application/ipp"], body: body, timeout: .seconds(5), once: true,
                                  replyLimit: IppQueueReading.maxBytes)
        let response = try await http.send(request)
        guard response.isSuccess else { return nil }
        return IppQueueReading.from(response.body, usb: usb)
    }
}
