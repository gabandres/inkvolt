import Darwin
import Foundation

/// Where text sent to an AI endpoint goes.
public enum AiReach: Sendable, Equatable {
    /// Loopback: the server runs on this Mac (Ollama, LM Studio).
    case thisMac
    /// A private address or a local name (.local, a single-label name): another computer on your network.
    case localNetwork
    /// Anything else: the text leaves this Mac for that host.
    case internet
}

/// An IPv4 or IPv6 address (.NET's `IPAddress`). Reads what .NET's `IPAddress.TryParse` reads: the four-part form and
/// `inet_aton`'s shorter, hex and octal forms ("127.1"), IPv6 with or without brackets.
public struct AiAddress: Sendable, Equatable, CustomStringConvertible {
    /// 4 or 16 bytes, network order.
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }

    public init?(_ text: String) {
        var s = text
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, s, &v6) == 1 else { return nil }
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        // inet_aton takes trailing text after a space; only the address itself counts.
        guard s.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X") }) else { return nil }
        var v4 = in_addr()
        guard inet_aton(s, &v4) == 1 else { return nil }
        bytes = withUnsafeBytes(of: &v4) { Array($0) }
    }

    public var isIPv4: Bool { bytes.count == 4 }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isIPv4 ? AF_INET : AF_INET6
        let size = socklen_t(INET6_ADDRSTRLEN)
        return bytes.withUnsafeBytes { raw in
            guard let text = inet_ntop(family, raw.baseAddress, &buffer, size) else { return "?" }
            return String(cString: text)
        }
    }

    /// The IPv4 address an IPv4-mapped IPv6 address (::ffff:a.b.c.d) stands for; else itself.
    var unmapped: AiAddress {
        guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else { return self }
        return AiAddress(bytes: Array(bytes[12...]))
    }
}

/// An OpenAI-compatible endpoint the user chose (bring your own AI): its base URL, ending in the API version
/// ("http://localhost:11434/v1"), and where requests to it go. Classified by its address as written, never by resolving
/// it, so the label can't change behind the user's back.
public struct AiEndpoint: Sendable, Equatable {
    // 127.0.0.1, not localhost: both servers listen on IPv4 loopback only.
    public static let ollamaUrl = "http://127.0.0.1:11434/v1"
    public static let lmStudioUrl = "http://127.0.0.1:1234/v1"

    public let scheme: String
    /// The host as in the address, lower case; an IPv6 address in brackets.
    public let hostName: String
    /// nil: the scheme's default.
    public let port: Int?
    /// The path, without a trailing slash ("/v1").
    public let path: String
    public let reach: AiReach

    /// Host and port as shown to the user: "localhost:11434", "api.example.com".
    public var host: String { port.map { "\(hostName):\($0)" } ?? hostName }

    public var origin: String { "\(scheme)://\(host)" }

    /// The endpoint's identity for per-endpoint choices (its API key, "don't ask again").
    public var key: String { origin + path }

    public var chatUrl: String { key + "/chat/completions" }

    public var modelsUrl: String { key + "/models" }

    /// "Stays on this Mac", "Stays on your network (nas.local:11434)", "Leaves this Mac: sent to api.example.com".
    public var reachText: String {
        switch reach {
        case .thisMac: "Stays on this Mac"
        case .localNetwork: "Stays on your network (\(host))"
        case .internet: "Leaves this Mac: sent to \(host)"
        }
    }

    /// What usually serves this address, for "Is Ollama running?" hints (by its well-known port on this Mac).
    public var serverName: String? {
        guard reach == .thisMac else { return nil }
        switch port {
        case 11434: return "Ollama"
        case 1234: return "LM Studio"
        default: return nil
        }
    }

    /// Reads a base URL the user typed. Adds the scheme when missing (http:// for this Mac or the network, https://
    /// otherwise) and "/v1" when there is no path, and drops a pasted "/chat/completions" or "/models". Refuses user
    /// names and passwords in the address, queries, and plain http:// to a host outside the network (the text would
    /// travel unencrypted). Read by hand, not through Foundation's URL, which turns look-alike dots into real ones.
    public static func tryParse(_ typed: String?) -> (endpoint: AiEndpoint?, error: String?) {
        var text = AiText.trim(typed ?? "")
        if text.isEmpty { return (nil, "Enter the endpoint's address, e.g. https://api.example.com/v1") }
        let guessed = !text.contains("://")
        if guessed { text = "http://" + text }
        let notAddress = "That isn't a web address. Enter one such as https://api.example.com/v1"
        guard let schemeEnd = text.range(of: "://") else { return (nil, notAddress) }
        let schemeText = String(text[..<schemeEnd.lowerBound]).lowercased()
        var rest = String(text[schemeEnd.upperBound...])
        var authority = rest
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(rest[..<cut])
            rest = String(rest[cut...])
        } else {
            rest = ""
        }
        // A host name is taken as plain ASCII only: its IDNA form, in which "。" becomes a real dot, could be another host.
        if authority.unicodeScalars.contains(where: { $0.value > 0x7E }) {
            return (nil, "Type the host name in plain letters and digits (an international domain name in its xn-- form).")
        }
        if authority.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) || !isSchemeText(schemeText) { return (nil, notAddress) }
        var userInfo = ""
        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            userInfo = String(authority[..<at])
            hostPort = String(authority[authority.index(after: at)...])
        }
        guard let (rawHost, rawPort) = splitHostPort(hostPort), !rawHost.isEmpty, isHostText(rawHost) else { return (nil, notAddress) }
        guard schemeText == "http" || schemeText == "https" else {
            return (nil, "The address must start with https:// (or http:// for this Mac or your network).")
        }
        if !userInfo.isEmpty { return (nil, "Leave the user name and password out of the address; put an API key in the key box instead.") }
        var pathText = rest
        var hasTail = false
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            pathText = String(rest[..<cut])
            hasTail = true
        }
        if hasTail { return (nil, "Leave out the part after ? or #: enter just the base address, e.g. https://api.example.com/v1") }

        let host = rawHost.lowercased()
        let reach = classify(host)
        var scheme = schemeText
        var port = rawPort
        if guessed && reach == .internet {
            // As .NET's UriBuilder does: http's default port is no port at all under https.
            if port == 80 { port = nil }
            scheme = "https"
        }
        if scheme == "http" && reach == .internet {
            return (nil, "Use https:// for \(host): it is outside your network, and http:// would send the text unencrypted.")
        }
        if port == (scheme == "https" ? 443 : 80) { port = nil }

        var path = trimEndSlashes(pathText)
        for tail in ["/chat/completions", "/models"] where path.lowercased().hasSuffix(tail) {
            path = String(path.dropLast(tail.count))
        }
        if path.isEmpty { path = "/v1" }
        path = path.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? path
        return (AiEndpoint(scheme: scheme, hostName: host, port: port, path: path, reach: reach), nil)
    }

    private static let pathCharacters = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "%"))

    private static func isLetterOrDigit(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
    }

    private static func isSchemeText(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, isLetterOrDigit(first), first.value > 0x39 else { return false }
        return s.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Letters, digits, dots, hyphens and underscores; or an IPv6 address in brackets.
    private static func isHostText(_ s: String) -> Bool {
        if s.hasPrefix("[") { return AiAddress(s) != nil }
        return s.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "-" || $0 == "." || $0 == "_" }
    }

    /// "host:8080", "[::1]:8080", "host": the host and the port; nil when the port isn't a port.
    private static func splitHostPort(_ s: String) -> (String, Int?)? {
        var host = s
        var portText: Substring?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[...close])
            let after = s[s.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else if let colon = s.lastIndex(of: ":") {
            host = String(s[..<colon])
            portText = s[s.index(after: colon)...]
        }
        guard let portText, !portText.isEmpty else { return (host, nil) }
        guard portText.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(portText), port <= 65535 else { return nil }
        return (host, port)
    }

    private static func trimEndSlashes(_ s: String) -> String {
        var t = Substring(s)
        while t.hasSuffix("/") { t = t.dropLast() }
        return String(t)
    }

    /// True when a connection to `ip` keeps the promise of `reach`: loopback for this Mac; loopback or a private,
    /// link-local or unique-local address for the network; anything for the internet. Checked on every address a name
    /// resolves to, so a ".local" or ".localhost" name (or DNS rebinding) can't lead elsewhere.
    public func allows(_ ip: AiAddress) -> Bool {
        switch reach {
        case .thisMac: Self.classify(ip) == .thisMac
        case .localNetwork: Self.classify(ip) != .internet
        case .internet: true
        }
    }

    /// Where a host is, by its name or address as written.
    public static func classify(_ typed: String) -> AiReach {
        var host = AiText.trim(typed).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty { return .internet }
        if let ip = AiAddress(host) { return classify(ip) }
        if host == "localhost" || host.hasSuffix(".localhost") { return .thisMac }
        // Names that only resolve inside a network: mDNS (.local), home routers (.lan, .home.arpa), private zones
        // (.internal), and single-label names (a computer's name, found by the network's own DNS).
        if !host.contains(".") { return .localNetwork }
        for suffix in [".local", ".lan", ".home.arpa", ".internal"] where host.hasSuffix(suffix) { return .localNetwork }
        return .internet
    }

    /// Loopback is this Mac; private, link-local and shared (carrier-NAT / VPN) ranges are the network.
    public static func classify(_ address: AiAddress) -> AiReach {
        let ip = address.unmapped
        let b = ip.bytes
        if ip.isIPv4 {
            if b[0] == 127 { return .thisMac }
            let isPrivate = b[0] == 10
                || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
                || (b[0] == 100 && (64...127).contains(b[1])) // 100.64.0.0/10: never routed on the internet (Tailscale and the like use it)
            return isPrivate ? .localNetwork : .internet
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .thisMac } // ::1
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return .localNetwork } // fe80::/10
        if b[0] == 0xFE && (b[1] & 0xC0) == 0xC0 { return .localNetwork } // fec0::/10
        if (b[0] & 0xFE) == 0xFC { return .localNetwork } // fc00::/7
        return .internet
    }
}
