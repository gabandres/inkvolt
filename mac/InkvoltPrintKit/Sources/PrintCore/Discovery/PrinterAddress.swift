import Foundation

/// What an address typed into Add a printer means: the printer's host and, when it names an IPP printer of its own (an
/// `ipp://` or `ipps://` URL, or a port given), the IPP URL to ask first. A plain web address (the printer's web page) is
/// just its host. `error` says why it isn't an address.
public struct PrinterAddress: Equatable, Sendable {
    public var host: String?
    public var ipp: URL?
    public var error: String?

    /// IPP Everywhere's path, for a host and port given without one.
    private static let ippPath = "/ipp/print"

    public static func parse(_ typed: String?) -> PrinterAddress {
        let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return fail("Type the printer's IP address or name.") }
        let invalid = fail("\"\(text)\" is not a valid address.")
        if text.contains("://") {
            guard let url = URLComponents(string: text), let host = url.host, !host.isEmpty, validPort(url.port) else { return invalid }
            switch url.scheme?.lowercased() {
            case "ipp": return PrinterAddress(host: host, ipp: ippUrl("http", host, url.port ?? 631, url.path))
            case "ipps": return PrinterAddress(host: host, ipp: ippUrl("https", host, url.port ?? 631, url.path))
            case let scheme? where scheme == "http" || scheme == "https":
                // The printer's web page: its host. On a port of its own, it's the IPP server there.
                guard let port = url.port, port != defaultPort(scheme) else { return PrinterAddress(host: host) }
                return PrinterAddress(host: host, ipp: ippUrl(scheme, host, port, url.path))
            default:
                return fail("Use the printer's IP address or name (or an http, https, ipp or ipps address).")
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
        c.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        c.port = port == defaultPort(scheme) ? nil : port
        c.path = path.isEmpty || path == "/" ? ippPath : path
        return c.url
    }
}
