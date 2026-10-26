import Foundation

/// One DNS-SD service as browsing found it: its instance name ("HP LaserJet MFP M234dw (1A2B3C)") and what it announces.
public struct AnnouncedService: Equatable, Sendable {
    public var instance: String?
    public var dnssd: DnssdService

    public init(instance: String?, dnssd: DnssdService) {
        self.instance = instance
        self.dnssd = dnssd
    }
}

/// A printer found on the network: its `_ipp`, `_ipps`, `_uscan` and `_uscans` services joined on its UUID (`DnssdJoin`).
public struct DiscoveredPrinter: Equatable, Sendable {
    /// Lower case; a GUID or, when no service published one, the text a service did publish (the printer list takes GUIDs only).
    public var uuid: String
    public var name: String
    /// The `ty` TXT key.
    public var model: String?
    /// The first IPv4 address a service announced.
    public var host: String?
    public var hostName: String?
    public var esclRoot: URL?
    public var hasScanner: Bool
    /// From `_ipp` when the printer offers it (it needs no certificate), else `_ipps`.
    public var ippUri: URL?
    /// The IPP service's TXT, else the scanner's; keys in lower case.
    public var txt: [String: String]
    /// Every IPv4 address a service with this UUID announced (`host` is the first). More than one: two devices claim the UUID.
    public var addresses: [String]
}

/// The Windows app's `PrinterDiscovery` join, over Bonjour's services only (no Windows association endpoints): one printer
/// per UUID, only those with an IPv4 address, sorted by name.
public enum DiscoveredPrinters {
    public static func join(_ services: [AnnouncedService]) -> [DiscoveredPrinter] {
        let all = services.map(\.dnssd)
        var order: [String] = []
        var buckets: [String: [AnnouncedService]] = [:]
        for s in services {
            guard let key = DnssdJoin.key(s.dnssd, all)?.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased() else { continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }
        let printers = order.compactMap { key -> DiscoveredPrinter? in
            let svcs = buckets[key]!
            let ipp = svcs.first { ["_ipp._tcp", "_ipps._tcp"].contains($0.dnssd.service) }
            let scan = svcs.first { ["_uscan._tcp", "_uscans._tcp"].contains($0.dnssd.service) }
            guard let host = svcs.lazy.compactMap(\.dnssd.ipv4).first else { return nil }
            let any = ipp ?? scan
            let ippService = svcs.first { $0.dnssd.service == "_ipp._tcp" } ?? ipp
            let txt = ipp?.dnssd.txt ?? scan?.dnssd.txt ?? [:]
            var addresses: [String] = []
            for a in svcs.compactMap(\.dnssd.ipv4) where !addresses.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                addresses.append(a)
            }
            return DiscoveredPrinter(uuid: key, name: any?.instance ?? key, model: txt["ty"], host: host, hostName: any?.dnssd.hostName,
                                     esclRoot: scan.flatMap { DnssdJoin.esclRoot($0.dnssd, host: host) }, hasScanner: scan != nil || txt["scan"] == "T",
                                     ippUri: ippService.flatMap { DnssdJoin.ippUri($0.dnssd, host: host) }, txt: txt, addresses: addresses)
        }
        return printers.sorted { $0.name.compare($1.name, options: .caseInsensitive, locale: .current) == .orderedAscending }
    }
}
