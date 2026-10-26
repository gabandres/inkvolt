import Foundation

/// One DNS-SD service a printer advertises (`_ipp._tcp`, `_ipps._tcp`, `_uscan._tcp`, `_uscans._tcp`).
public struct DnssdService: Equatable, Sendable {
    public var service: String?
    public var uuid: String?
    public var hostName: String?
    public var ipv4: String?
    public var port: Int?
    /// TXT keys in lower case (DNS-SD keys are case-insensitive).
    public var txt: [String: String]

    public init(service: String?, uuid: String?, hostName: String?, ipv4: String?, port: Int?, txt: [String: String] = [:]) {
        self.service = service
        self.uuid = uuid
        self.hostName = hostName
        self.ipv4 = ipv4
        self.port = port
        self.txt = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}

/// How a printer's DNS-SD services are joined into one printer, and where its IPP and eSCL endpoints are. IPP Everywhere and
/// Mopria printers publish a `UUID` TXT key on every service; some leave it out of one of them.
public enum DnssdJoin {
    /// The printer id a service belongs to: its UUID (normalised when it is a GUID); without one, the UUID another service on
    /// the same host publishes (a GUID preferred). A UUID that isn't a GUID is kept as published, so services sharing it
    /// still join (the printer list only takes GUIDs). Nil when no service on the host has one: such a printer is left out
    /// until a sibling shows up; it can still be added by address.
    public static func key(_ s: DnssdService, _ all: [DnssdService]) -> String? {
        if PrinterId.isValid(clean(s.uuid)) { return PrinterId.normalize(s.uuid, host: "") }
        var others = all
        if let me = others.firstIndex(of: s) { others.remove(at: me) }
        let siblings = others.filter { sameHost($0, s) }
        if let valid = siblings.first(where: { PrinterId.isValid(clean($0.uuid)) }) { return PrinterId.normalize(valid.uuid, host: "") }
        if let raw = clean(s.uuid), !raw.isEmpty { return raw }
        return siblings.lazy.compactMap { clean($0.uuid) }.first { !$0.isEmpty }
    }

    /// The IPP printer URL from an `_ipp`/`_ipps` service: its port (631 by default) and the `rp` TXT resource path
    /// (`ipp/print` by default, as IPP Everywhere requires). https for `_ipps`. Nil for a path that tries to leave the root or
    /// carries a query.
    public static func ippUri(_ s: DnssdService, host: String) -> URL? {
        let rp = s.txt["rp"].map(trimSlashes) ?? "ipp/print"
        guard safePath(rp) else { return nil }
        return url(s.service == "_ipps._tcp" ? "https" : "http", host, s.port ?? 631, rp)
    }

    /// The eSCL root from a `_uscan`/`_uscans` service: its port and the `rs` TXT path (`eSCL` by default).
    public static func esclRoot(_ s: DnssdService, host: String) -> URL? {
        let rs = s.txt["rs"].map(trimSlashes) ?? "eSCL"
        guard safePath(rs) else { return nil }
        let https = s.service == "_uscans._tcp"
        return url(https ? "https" : "http", host, s.port ?? (https ? 443 : 80), rs.isEmpty ? "" : rs + "/")
    }

    /// As .NET's UriBuilder: the scheme's default port isn't written, an empty path is "/".
    private static func url(_ scheme: String, _ host: String, _ port: Int, _ path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = port == (scheme == "https" ? 443 : 80) ? nil : port
        c.path = "/" + path
        return c.url
    }

    private static func trimSlashes(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private static func safePath(_ path: String) -> Bool {
        !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." }
            && !path.contains { "?#\\:".contains($0) }
    }

    private static func clean(_ uuid: String?) -> String? {
        guard var raw = uuid?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "{}")) else { return nil }
        if raw.lowercased().hasPrefix("urn:uuid:") { raw = String(raw.dropFirst(9)) }
        return raw
    }

    private static func sameHost(_ a: DnssdService, _ b: DnssdService) -> Bool {
        (a.hostName != nil && a.hostName?.lowercased() == b.hostName?.lowercased()) || (a.ipv4 != nil && a.ipv4 == b.ipv4)
    }
}
