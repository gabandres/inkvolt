import Foundation

/// What an address typed into Add a printer means: the printer's host and, when it names an IPP printer of its own (an
/// `ipp://` or `ipps://` URL, or a port given), the IPP URL to ask first. A plain web address (the printer's web page) is
/// just its host; one on a port of its own (`http://host:8080/`) is also where its web server is (`web`: HP's LEDM and CDM,
/// its pages), as well as an IPP server to try. `error` says why it isn't an address.
public struct PrinterAddress: Equatable, Sendable {
    public var host: String?
    public var ipp: URL?
    public var error: String?
    /// The printer's web server when it isn't on port 80 or 443 (`webRoot`); nil otherwise.
    public var web: URL?

    /// A web address's scheme and port as the root of a printer's web server on `host`, when that port isn't the scheme's
    /// default; nil for a default port, another scheme or anything that isn't a web address. Only the scheme and port are
    /// taken: a printer's web server is on the printer, whatever host a link or announcement names.
    public static func webRoot(_ url: URL?, host: String) -> URL? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let port = c.port else { return nil }
        return webRoot(scheme: scheme, port: port, host: host)
    }

    private static func webRoot(scheme: String, port: Int, host: String) -> URL? {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard port != defaultPort(scheme), (1...65535).contains(port), !bare.isEmpty, validHost(bare), let h = urlHost(bare) else { return nil }
        return URL(string: "\(scheme)://\(h):\(port)/")
    }

    /// IPP Everywhere's path, for a host and port given without one.
    private static let ippPath = "/ipp/print"

    public static func parse(_ typed: String?) -> PrinterAddress {
        let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return fail(loc("Type the printer's IP address or name.")) }
        let invalid = fail(loc("\"{0}\" is not a valid address.", text))
        if text.contains("://") {
            guard let url = URLComponents(string: text), let host = typedHost(url, text), !host.isEmpty, validPort(url.port),
                  !host.contains(":") || validHost(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else { return invalid }
            switch url.scheme?.lowercased() {
            case "ipp": return PrinterAddress(host: host, ipp: ippUrl("http", host, url.port ?? 631, url.path))
            case "ipps": return PrinterAddress(host: host, ipp: ippUrl("https", host, url.port ?? 631, url.path))
            case let scheme? where scheme == "http" || scheme == "https":
                // The printer's web page: its host. On a port of its own, it's the IPP server there.
                guard let port = url.port, port != defaultPort(scheme) else { return PrinterAddress(host: host) }
                var a = PrinterAddress(host: host, ipp: ippUrl(scheme, host, port, url.path))
                // Port 631 or a path under /ipp/ names the IPP server (IPP Everywhere's), not the web server: no web root there.
                let ippPath = url.path.lowercased().hasPrefix("/ipp/") || url.path == "/ipp"
                a.web = port == 631 || ippPath ? nil : webRoot(scheme: scheme, port: port, host: host)
                return a
            default:
                return fail(loc("Use the printer's IP address or name (or an http, https, ipp or ipps address)."))
            }
        }
        // An IPv6 host comes with or without its brackets depending on the platform's URLComponents.
        guard let hostPort = URLComponents(string: "http://" + text), let host = typedHost(hostPort, text)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty, validPort(hostPort.port),
              hostPort.path.isEmpty || hostPort.path == "/", hostPort.query == nil, hostPort.fragment == nil, hostPort.user == nil,
              validHost(host) else { return invalid }
        // host:port names the printer's IPP server; a bare host keeps its spelling (names are shown as typed).
        guard let port = hostPort.port, port != 80 else { return PrinterAddress(host: text.hasPrefix("[") ? "[\(host)]" : text) }
        return PrinterAddress(host: host, ipp: ippUrl("http", host, port, "/"))
    }

    private init(host: String? = nil, ipp: URL? = nil, error: String? = nil) {
        self.host = host
        self.ipp = ipp
        self.error = error
    }

    private static func fail(_ why: String) -> PrinterAddress { PrinterAddress(error: why) }

    /// A typed URL's host, an IPv6 zone read as Windows' PrinterAddress.SplitZone reads it: "%25" is RFC 6874's escaped "%"
    /// when something follows it (`%25en0`, `%2512`: interface en0, 12), while "%25" alone is interface 25, as ipconfig shows
    /// an interface's number (the owner's call: an empty zone escaped is nothing anyone types). A zone typed raw (`%12`) is
    /// kept as it is. Whether the zone is one is `validHost`'s to say; any other host is URLComponents' own. An IPv6 literal
    /// is read from `text` as typed: swift-corelibs' URLComponents writes a stray "%" as "%25" (`[fe80::1%]` came back
    /// `[fe80::1%25]`, interface 25), where Apple's refuses it.
    private static func typedHost(_ c: URLComponents, _ text: String) -> String? {
        guard let encoded = c.percentEncodedHost else { return nil }
        let bracketed = encoded.hasPrefix("[") && encoded.hasSuffix("]")
        var bare = bracketed ? String(encoded.dropFirst().dropLast()) : encoded
        if bracketed, let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            bare = String(text[text.index(after: open)..<close])
        }
        guard bare.contains(":"), let pct = bare.firstIndex(of: "%") else { return c.host }
        var zone = String(bare[bare.index(after: pct)...])
        if zone.count > 2, zone.hasPrefix("25") { zone = String(zone.dropFirst(2)).removingPercentEncoding ?? "" }
        let host = String(bare[..<pct]) + "%" + zone
        return bracketed ? "[\(host)]" : host
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    private static func validPort(_ port: Int?) -> Bool { port.map { (0...65535).contains($0) } ?? true }

    /// `host` as a web address writes it: an IPv6 literal in brackets, its zone (`fe80::1%en0`, a link-local address's
    /// network interface) with its `%` written `%25` (RFC 6874); a name or IPv4 address as it is. Nil for an IPv6 literal
    /// that isn't one (`validHost`), so no URL is ever made from it.
    public static func urlHost(_ host: String) -> String? {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !bare.isEmpty else { return nil }
        guard bare.contains(":") else { return bare }
        guard validHost(bare) else { return nil }
        return "[" + bare.replacingOccurrences(of: "%", with: "%25") + "]"
    }

    /// As .NET's Uri.CheckHostName: an IPv4 or IPv6 address, or a DNS name. An IPv6 address may name its zone after a `%`
    /// (letters, digits, `-`, `.`, `_`, `~`: RFC 6874's unreserved characters), which .NET drops and the Mac keeps.
    private static func validHost(_ host: String) -> Bool {
        if host.contains(":") {
            let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            guard let address = parts.first, !address.isEmpty,
                  address.allSatisfy({ (c: Character) -> Bool in c.isASCII && (c.isHexDigit || c == ":" || c == ".") }) else { return false }
            guard parts.count == 2 else { return true }
            let zone = parts[1]
            return !zone.isEmpty && zone.count <= 64
                && zone.allSatisfy { (c: Character) -> Bool in c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "." || c == "_" || c == "~") }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// ipp:// is IPP over http, ipps:// over https; both default to port 631 (RFC 8010 §4, RFC 7472). The default port of
    /// the scheme isn't written, as .NET's Uri does.
    private static func ippUrl(_ scheme: String, _ host: String, _ port: Int, _ path: String) -> URL? {
        // An IPv6 host goes in as a URL writes it (`urlHost`): Apple's URLComponents wants the brackets, and traps on a `%`
        // that isn't an escape (a zone's).
        guard let h = urlHost(host) else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        if h.hasPrefix("[") { c.percentEncodedHost = h } else { c.host = h }
        c.port = port == defaultPort(scheme) ? nil : port
        c.path = path.isEmpty || path == "/" ? ippPath : path
        return c.url
    }
}
