import Foundation
import PrintCore

/// What an address is asked for.
public enum LtvAddressKind: Sendable, CaseIterable {
    /// An OCSP responder a certificate names: receives which certificate is being asked about.
    case ocsp
    /// A CRL address a certificate names: a plain download of the issuer's list.
    case crl
    /// The address of a certificate's issuer, as the certificate names it: a plain download of a public certificate.
    case issuer
    /// The timestamp server the person chose: receives a hash, never the document.
    case timestamp
}

/// One request this run made, for the person to read afterwards. Kept in memory only.
public struct LtvContact: Sendable, Equatable {
    public let kind: LtvAddressKind
    public let url: String
    public let outcome: String
}

/// A server couldn't be used; the message says why, in the person's words (.NET's `LtvFetchException`).
public struct LtvFetchError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The one door through which long-term validation goes online, and only when the person asked (the Windows app's
/// `LtvClient`). Addresses come from certificates in files, so they are hostile: a file must not be able to make the app
/// probe this Mac or its network.
/// - Only http and https, no user names, plain ASCII host names. A timestamp server must be https.
/// - Names and addresses of this Mac or a local network are refused before anything is sent, and every address a name
///   resolves to is checked before connecting, and only those checked addresses are connected to (Network.framework,
///   `AiSocketTransport`), so DNS rebinding and redirects can't get there either.
/// - Redirects are followed by hand, a few at most, each checked again, never from https down to http.
/// - Bounded: the time of each request, the size of each reply, the number of requests in a run. No proxy (it would
///   connect on our behalf, out of sight of the checks), cookies, credentials or decompression.
public final class LtvClient: @unchecked Sendable {
    public static let maxOcspReply = RevocationPool.maxOcspBytes
    public static let maxCrlReply = RevocationPool.maxCrlBytes
    public static let maxCertificateReply = RevocationPool.maxCertBytes
    public static let maxTimestampReply = 256 * 1024
    private static let maxRedirects = 3
    private static let maxRequests = 48
    private static let maxRemembered = 64 << 20

    private let timeout: Double
    private let connectTimeout: Double
    private let allowLoopback: Bool
    private let allowHttpTimestamp: Bool
    private let resolve: @Sendable (String) async throws -> [AiAddress]
    private let lock = NSLock()
    private var contactList: [LtvContact] = []
    private var requests = 0
    /// Servers (host and port) that didn't answer at all: not asked again by this client.
    private var silent = Set<String>()
    /// Answers already had (by address, and request for a POST), timestamps never: asked once per client.
    private var answers: [String: [UInt8]] = [:]
    private var answerBytes = 0

    /// What this client asked so far.
    public var contacts: [LtvContact] { lock.withLock { contactList } }

    /// Batch: one client serves a whole run, one file at a time. Each file gets the request budget a single file has;
    /// what the run learnt stays: an answer is used again rather than asked for again (a CRL, an issuer, an OCSP answer
    /// for the same certificate), and a server that didn't answer isn't asked again, so a batch can't hammer a server.
    public func nextFile() { lock.withLock { requests = 0 } }

    public convenience init() { self.init(allowLoopback: false) }

    /// - Parameters:
    ///   - allowLoopback: tests and the self-test only: lets this Mac's own loopback through (still no other local address).
    ///   - timeout: how long one request may take; when given, also how long connecting may (8 s otherwise).
    ///   - resolve: tests only: stands in for DNS.
    ///   - allowHttpTimestamp: tests and the self-test only: a local timestamp server without a certificate.
    init(allowLoopback: Bool, timeout: Double? = nil, resolve: (@Sendable (String) async throws -> [AiAddress])? = nil, allowHttpTimestamp: Bool = false) {
        self.allowLoopback = allowLoopback
        self.allowHttpTimestamp = allowHttpTimestamp
        self.timeout = timeout ?? 15
        connectTimeout = timeout ?? 8
        self.resolve = resolve ?? AiSocketTransport.systemResolve
    }

    private func allowed(_ ip: AiAddress) -> Bool {
        Self.isPublic(ip) || (allowLoopback && AiEndpoint.classify(ip) == .thisMac)
    }

    /// False for this Mac, local and link-local networks, carrier NAT, multicast and reserved ranges, and for the IPv6
    /// forms that carry such an IPv4 address inside.
    public static func isPublic(_ address: AiAddress) -> Bool {
        let ip = address.unmapped
        if AiEndpoint.classify(ip) != .internet { return false }
        let b = ip.bytes
        if ip.isIPv4 {
            return !(b[0] == 0 || b[0] >= 224
                || (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2))
                || (b[0] == 198 && (b[1] == 18 || b[1] == 19))
                || (b[0] == 198 && b[1] == 51 && b[2] == 100)
                || (b[0] == 203 && b[1] == 0 && b[2] == 113))
        }
        if b[0] == 0xFF { return false } // multicast
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false } // ::, ::1, ::a.b.c.d
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B { return isPublic(AiAddress(bytes: Array(b[12..<16]))) } // NAT64
        if b[0] == 0x20 && b[1] == 0x02 { return isPublic(AiAddress(bytes: Array(b[2..<6]))) } // 6to4
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 { return false } // Teredo
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return false } // documentation
        return true
    }

    /// An address taken apart by hand (Foundation's URL turns look-alike dots into real ones).
    struct Address {
        let scheme: String
        let host: String
        let port: Int?
        /// The path and query, starting with "/".
        let path: String
        let userInfo: Bool
        let plain: Bool
    }

    static func parse(_ url: String) -> Address? {
        guard url.count <= 2048, let mark = url.range(of: "://") else { return nil }
        let scheme = url[..<mark.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme.unicodeScalars.allSatisfy({ ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || "+-.".unicodeScalars.contains($0) }) else { return nil }
        let rest = url[mark.upperBound...]
        let cut = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = String(rest[..<cut])
        var path = String(rest[cut...])
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if path.isEmpty || path.hasPrefix("?") { path = "/" + path }
        // Written into the request line as it is: anything but visible ASCII (a space, a line break that would start a
        // header of the certificate's choosing, other characters) goes percent-encoded.
        path = path.utf8.map { $0 > 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        let plain = authority.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
        var hostPort = authority
        var userInfo = false
        if let at = authority.lastIndex(of: "@") {
            userInfo = true
            hostPort = String(authority[authority.index(after: at)...])
        }
        var host = hostPort
        var port: Int?
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[...close])
            let after = hostPort[hostPort.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let p = Int(after.dropFirst()), p > 0, p <= 65535 else { return nil }
                port = p
            }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon])
            let text = hostPort[hostPort.index(after: colon)...]
            if !text.isEmpty {
                guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(text), p > 0, p <= 65535 else { return nil }
                port = p
            }
        }
        guard !host.isEmpty else { return nil }
        return Address(scheme: scheme, host: host.lowercased(), port: port, path: path, userInfo: userInfo, plain: plain)
    }

    /// Why `url` won't be contacted, judged from the address as written; nil when it may be.
    public static func whyRefused(_ url: String, _ kind: LtvAddressKind, allowLoopback: Bool = false, allowHttpTimestamp: Bool = false) -> String? {
        guard let u = parse(url) else { return loc("it isn't a web address") }
        if u.scheme != "http" && u.scheme != "https" { return loc("it isn't a web address ({0}:)", u.scheme) }
        if kind == .timestamp && u.scheme != "https" && !allowHttpTimestamp { return loc("a timestamp server must use https://") }
        if u.userInfo { return loc("it carries a user name or password") }
        // A host is taken as plain ASCII only: its IDNA form, in which look-alikes become real dots and letters, could be another.
        if !u.plain { return loc("its host name isn't plain letters and digits") }
        let host = u.host.hasPrefix("[") ? String(u.host.dropFirst().dropLast()) : u.host
        if let ip = AiAddress(host) {
            let local = AiEndpoint.classify(ip) == .thisMac
            if allowLoopback && local { return nil }
            return isPublic(ip) ? nil : local ? loc("it points at this Mac") : loc("it points at an address on a local network")
        }
        switch AiEndpoint.classify(host) {
        case .internet: return nil
        case .thisMac: return allowLoopback ? nil : loc("it points at this Mac")
        case .localNetwork: return loc("it points at a local network")
        }
    }

    private func refused(_ url: String, _ kind: LtvAddressKind) -> String? {
        Self.whyRefused(url, kind, allowLoopback: allowLoopback, allowHttpTimestamp: allowHttpTimestamp)
    }

    /// This client won't contact `url`, by the address as written.
    public func refuses(_ url: String, _ kind: LtvAddressKind) -> Bool { refused(url, kind) != nil }

    /// Why this client won't contact `url`, by the address as written; nil when it will.
    public func why(_ url: String, _ kind: LtvAddressKind) -> String? { refused(url, kind) }

    public func get(_ url: String, _ kind: LtvAddressKind, maxBytes: Int) async throws -> [UInt8] {
        try await send(url, kind, nil, nil, maxBytes)
    }

    public func post(_ url: String, _ kind: LtvAddressKind, contentType: String, body: [UInt8], maxBytes: Int) async throws -> [UInt8] {
        try await send(url, kind, contentType, body, maxBytes)
    }

    /// The RFC 3161 exchange with a timestamp server: posts the request (a hash only), returns the reply.
    public func timestampSender(_ url: String) -> @Sendable ([UInt8]) async throws -> [UInt8] {
        { [self] request in try await post(url, .timestamp, contentType: "application/timestamp-query", body: request, maxBytes: Self.maxTimestampReply) }
    }

    /// Host and port: what "didn't answer" is remembered by.
    private static func server(_ url: String) -> String {
        guard let u = parse(url) else { return url }
        return u.port.map { "\(u.host):\($0)" } ?? u.host
    }

    static func host(_ url: String) -> String {
        guard let u = parse(url) else { return url }
        return u.host.hasPrefix("[") ? String(u.host.dropFirst().dropLast()) : u.host
    }

    private func note(_ kind: LtvAddressKind, _ url: String, _ outcome: String) {
        lock.withLock { contactList.append(LtvContact(kind: kind, url: url, outcome: outcome)) }
    }

    private func failed(_ kind: LtvAddressKind, _ url: String, _ error: LtvFetchError) -> LtvFetchError {
        note(kind, url, error.message)
        return error
    }

    private static func bytesText(_ n: Int) -> String { CoreLanguage.number(n) }

    private func send(_ firstUrl: String, _ kind: LtvAddressKind, _ contentType: String?, _ body: [UInt8]?, _ maxBytes: Int) async throws -> [UInt8] {
        let key: String? = kind == .timestamp ? nil : body.map { "\(firstUrl) \(DigestAlgorithm.sha256.hash($0).map { String(format: "%02X", $0) }.joined())" } ?? firstUrl
        if let key, let known = lock.withLock({ answers[key] }), known.count <= maxBytes {
            note(kind, firstUrl, loc("answered earlier ({0} bytes)", Self.bytesText(known.count)))
            return known
        }
        var url = firstUrl
        do {
            var hop = 0
            while true {
                if let why = refused(url, kind) { throw LtvFetchError(loc("{0} wasn't contacted: {1}.", url, why)) }
                let server = Self.server(url)
                if lock.withLock({ silent.contains(server) }) { throw LtvFetchError(loc("{0} didn't answer earlier, so it wasn't asked again.", Self.host(url))) }
                let over = lock.withLock { () -> Bool in
                    requests += 1
                    return requests > Self.maxRequests
                }
                if over { throw LtvFetchError(loc("This would take more requests than a check should.")) }
                let reply = try await exchange(url, body == nil ? "GET" : "POST", contentType, body, maxBytes)
                if [301, 302, 303, 307, 308].contains(reply.status) {
                    if hop >= Self.maxRedirects { throw LtvFetchError(loc("{0} redirected too many times.", Self.host(firstUrl))) }
                    if body != nil && reply.status != 307 && reply.status != 308 { throw LtvFetchError(loc("{0} answered with a redirect that drops the request.", Self.host(firstUrl))) }
                    guard let location = reply.location, let next = URL(string: location, relativeTo: URL(string: url))?.absoluteString else {
                        throw LtvFetchError(loc("{0} sent a redirect that leads nowhere.", Self.host(firstUrl)))
                    }
                    if Self.parse(url)?.scheme == "https" && Self.parse(next)?.scheme != "https" {
                        throw LtvFetchError(loc("{0} redirected from https to an address that isn't.", Self.host(firstUrl)))
                    }
                    url = next
                    hop += 1
                    continue
                }
                if !(200..<300).contains(reply.status) { throw LtvFetchError(loc("{0} answered with an error ({1}).", Self.host(url), reply.status)) }
                note(kind, firstUrl, loc("answered ({0} bytes)", Self.bytesText(reply.body.count)))
                if let key {
                    lock.withLock {
                        if answerBytes + reply.body.count <= Self.maxRemembered && answers[key] == nil {
                            answers[key] = reply.body
                            answerBytes += reply.body.count
                        }
                    }
                }
                return reply.body
            }
        } catch let e as LtvFetchError {
            throw failed(kind, firstUrl, e)
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    /// One request and its whole reply (a redirect's body unread), within this client's time limit. Its errors are the
    /// person's words; a server that couldn't be connected to, or didn't answer in time, isn't asked again.
    private func exchange(_ url: String, _ method: String, _ contentType: String?, _ body: [UInt8]?, _ maxBytes: Int) async throws -> (status: Int, location: String?, body: [UInt8]) {
        guard let u = Self.parse(url) else { throw LtvFetchError(loc("{0} wasn't contacted: {1}.", url, loc("it isn't a web address"))) }
        let host = Self.host(url)
        let screen = resolve
        let allowed = allowed
        // Every address a name resolves to is checked: any local one refuses the name, since which one a connection
        // ends up on can't be left to chance. The transport then connects only to these.
        let checkedResolve: @Sendable (String) async throws -> [AiAddress] = { name in
            let found = try await screen(name)
            if found.isEmpty { throw AiNetError.hostNotFound }
            if let local = found.first(where: { !allowed($0) }) {
                throw LtvFetchError(AiEndpoint.classify(local) == .thisMac
                    ? loc("{0} points at this Mac, so it wasn't contacted.", name)
                    : loc("{0} points at an address on a local network, so it wasn't contacted.", name))
            }
            return found
        }
        let endpoint = AiEndpoint(scheme: u.scheme, hostName: u.host, port: u.port, path: "", reach: .internet)
        let transport = AiSocketTransport(endpoint, AiTimeouts(connect: connectTimeout, firstByte: timeout, idle: timeout), resolve: checkedResolve)
        var headers: [(name: String, value: String)] = [("User-Agent", "InkvoltPdf")]
        if let contentType { headers.append(("Content-Type", contentType)) }
        let request = AiHttpRequest(method: method, url: endpoint.origin + u.path, headers: headers, body: body)

        // The AI client's deadline: one GCD timer, which fires while the cooperative pool is busy (a sleeping task didn't,
        // on a loaded run), and lets go of the request when it ends.
        let deadline = AiDeadline(nil)
        defer { deadline.finish() }
        deadline.cancelAfter(timeout)
        let token = deadline.token
        do {
            return try await withTaskCancellationHandler {
                let response = try await transport.send(request, token)
                // Closed whatever happens: a body that came whole with the head leaves its connection open until then.
                defer { response.body.close() }
                if [301, 302, 303, 307, 308].contains(response.status) { return (response.status, response.location, []) }
                var bytes: [UInt8] = []
                while let piece = try await response.body.read(token) {
                    if bytes.count + piece.count > maxBytes {
                        throw LtvFetchError(loc("{0} sent more than the {1} KB allowed.", host, CoreLanguage.number(maxBytes / 1024)))
                    }
                    bytes += piece
                }
                return (response.status, response.location, bytes)
            } onCancel: {
                token.cancel()
            }
        } catch let e as LtvFetchError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let server = Self.server(url)
            if token.isCancelled || (error as? AiNetError) == .timedOut {
                lock.withLock { _ = silent.insert(server) }
                throw LtvFetchError(loc("{0} didn't answer in time.", host))
            }
            switch error as? AiNetError {
            case .closedEarly?:
                // The connection broke while the reply was being read: it answered, so it may be asked again.
                throw LtvFetchError(loc("{0} stopped answering.", host))
            case .refused?, .hostNotFound?, .unreachable?:
                lock.withLock { _ = silent.insert(server) }
                throw LtvFetchError(loc("{0} can't be reached. Check that this Mac is online.", host))
            default:
                throw LtvFetchError(loc("{0} can't be reached. Check that this Mac is online.", host))
            }
        }
    }
}
