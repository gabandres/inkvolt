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
        guard port != defaultPort(scheme), (1...65535).contains(port), !bare.isEmpty, validHost(bare) else { return nil }
        let h = bare.contains(":") ? "[\(bare)]" : bare // an IPv6 literal
        return URL(string: "\(scheme)://\(h):\(port)/")
    }

    /// IPP Everywhere's path, for a host and port given without one.
    private static let ippPath = "/ipp/print"

    public static func parse(_ typed: String?) -> PrinterAddress {
        let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return fail(loc("Type the printer's IP address or name.")) }
        let invalid = fail(loc("\"{0}\" is not a valid address.", text))
        if text.contains("://") {
            guard let url = URLComponents(string: text), let host = url.host, !host.isEmpty, validPort(url.port) else { return invalid }
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
        guard let hostPort = URLComponents(string: "http://" + text), let host = hostPort.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
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

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    private static func validPort(_ port: Int?) -> Bool { port.map { (0...65535).contains($0) } ?? true }

    /// As .NET's Uri.CheckHostName: an IPv4 or IPv6 address, or a DNS name.
    private static func validHost(_ host: String) -> Bool {
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" } }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// ipp:// is IPP over http, ipps:// over https; both default to port 631 (RFC 8010 §4, RFC 7472). The default port of
    /// the scheme isn't written, as .NET's Uri does.
    private static func ippUrl(_ scheme: String, _ host: String, _ port: Int, _ path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        c.host = bare
        c.port = port == defaultPort(scheme) ? nil : port
        c.path = path.isEmpty || path == "/" ? ippPath : path
        if c.url == nil && bare.contains(":") { c.percentEncodedHost = "[\(bare)]" } // Apple's URLComponents wants an IPv6 host in brackets
        return c.url
    }
}
