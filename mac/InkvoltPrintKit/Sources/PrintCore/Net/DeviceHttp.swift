import Foundation
import Synchronization

/// Remembered certificate fingerprints for one printer, one per TLS port.
public protocol CertificatePin: Sendable {
    func get(_ port: Int) -> String?

    /// Stores the fingerprint for `port` unless one is already stored; returns the stored value.
    func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String
}

/// Where a printer's pin for a port is stored.
public enum CertificatePinKey {
    /// The printer id for 443 (pins stored before they were per port were all for the web server on 443, so they stay
    /// valid), `id:port` for any other port.
    public static func key(_ printerId: String, port: Int) -> String { port == 443 ? printerId : "\(printerId):\(port)" }

    /// The stored key is one of `printerId`'s pins (any port).
    public static func belongs(_ key: String, to printerId: String) -> Bool {
        key.caseInsensitiveCompare(printerId) == .orderedSame || key.lowercased().hasPrefix(printerId.lowercased() + ":")
    }
}

/// The certificate rule for one printer, which a TLS transport asks on every handshake. Printers use self-signed
/// certificates, so CA validation is meaningless. Instead the first certificate seen for a printer is remembered (trust on
/// first use) and any later different certificate is refused, so a machine impersonating the printer on the LAN can't
/// collect the admin password. Pins are per port: a printer may use one certificate for its web server (443) and another
/// for IPPS (631). Without a pin (an unpinned probe, which never carries credentials) every certificate is accepted.
public final class CertificateCheck: Sendable {
    private let pin: (any CertificatePin)?
    private let changed = Mutex(false)

    public init(pin: (any CertificatePin)?) { self.pin = pin }

    /// `sha256Hex`: the SHA-256 of the leaf certificate's DER bytes, in hex.
    public func accept(sha256Hex thumb: String, port: Int) -> Bool {
        guard let pin else { return true }
        // Two first handshakes can race: whichever pin is stored first wins, and both are checked against it.
        let known = pin.get(port) ?? pin.setIfAbsent(port, thumb)
        if known.caseInsensitiveCompare(thumb) == .orderedSame { return true }
        changed.withLock { $0 = true }
        return false
    }

    /// True after a connection was refused because the printer's certificate no longer matches the pin.
    public var certificateChanged: Bool { changed.withLock { $0 } }

    /// Call after the pin was cleared on purpose (the user chose to trust the new certificate).
    public func resetCertificateChanged() { changed.withLock { $0 = false } }
}

/// Builds the transport for one printer's host, given the certificate rule its TLS handshakes must follow.
public typealias HttpTransportFactory = @Sendable (_ host: String, _ check: CertificateCheck) -> any HttpTransport

/// One HTTP client per printer. Timeouts are per request; certificates follow the printer's pins (`CertificateCheck`),
/// never a process-wide rule; the admin password goes only to the web server's HTTPS port.
public final class DeviceHttp: Sendable {
    public static let defaultTimeout: Duration = .seconds(5)

    public let host: String
    public let httpBase: URL
    public let httpsBase: URL
    public let certificates: CertificateCheck
    private let transport: any HttpTransport
    private let basicAuth = Mutex<String?>(nil)

    public init(host: String, transport: HttpTransportFactory, pin: (any CertificatePin)? = nil) {
        self.host = host
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host // an IPv6 literal
        httpBase = URL(string: "http://\(h)/")!
        httpsBase = URL(string: "https://\(h)/")!
        certificates = CertificateCheck(pin: pin)
        self.transport = transport(host, certificates)
    }

    /// A fixed transport for every host (demo mode, tests).
    public convenience init(host: String, transport: any HttpTransport, pin: (any CertificatePin)? = nil) {
        self.init(host: host, transport: { _, _ in transport }, pin: pin)
    }

    public var hasCredentials: Bool { basicAuth.withLock { $0 != nil } }

    /// EWS admin credentials. Only ever sent over HTTPS to the web server's port.
    public func setCredentials(user: String, password: String) {
        basicAuth.withLock { $0 = Data("\(user):\(password)".utf8).base64EncodedString() }
    }

    public func clearCredentials() { basicAuth.withLock { $0 = nil } }

    public func http(_ path: String) -> URL { URL(string: path, relativeTo: httpBase)!.absoluteURL }
    public func https(_ path: String) -> URL { URL(string: path, relativeTo: httpsBase)!.absoluteURL }

    public var certificateChanged: Bool { certificates.certificateChanged }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        var request = request
        // The admin password belongs to the web server (HTTPS on 443), never to another TLS port such as IPPS on 631.
        if let auth = basicAuth.withLock({ $0 }), request.url.scheme == "https", (request.url.port ?? 443) == 443 {
            request.headers["Authorization"] = "Basic \(auth)"
        }
        if request.once { request.headers["Connection"] = "close" }
        let transport = self.transport
        let deadline = request.timeout
        let sent = request
        return try await withThrowingTaskGroup(of: HttpResponse?.self) { group in
            group.addTask { try await transport.send(sent) }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let response = first else { throw DeviceNetworkError.timedOut }
            return response
        }
    }

    /// A request that changes something on the printer and must never arrive twice (a maintenance POST: a second cleaning
    /// uses ink twice). The transport sends it on a connection of its own and never resends it.
    public func sendOnce(_ request: HttpRequest) async throws -> HttpResponse {
        var request = request
        request.once = true
        return try await send(request)
    }

    public func get(_ url: URL, timeout: Duration = DeviceHttp.defaultTimeout) async throws -> HttpResponse {
        try await send(HttpRequest("GET", url, timeout: timeout))
    }

    /// GET returning the body, or nil on 404. Other failures throw.
    public func getBytesOrNil(_ url: URL, timeout: Duration = DeviceHttp.defaultTimeout) async throws -> [UInt8]? {
        let response = try await get(url, timeout: timeout)
        if response.status == 404 { return nil }
        try Self.ensureSuccess(response, "GET", url)
        return response.body
    }

    public static func ensureSuccess(_ response: HttpResponse, _ method: String, _ url: URL) throws {
        if response.isSuccess { return }
        let text = response.text
        throw DeviceHttpError(status: response.status, method: method, url: url, body: text.count > 300 ? String(text.prefix(300)) : text,
                              location: response.header("Location"))
    }
}
