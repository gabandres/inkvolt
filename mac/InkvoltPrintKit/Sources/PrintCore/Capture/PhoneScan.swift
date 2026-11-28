import Foundation

/// One request from the phone, as the server read its head (the body is read only when `PhoneSession` asks; the Windows
/// Core's `PhoneRequest`). `peer`: who asked, as an address (kept in memory for the session only, never logged); `cookie`: the
/// session cookie's value when the request carried it; `fromPage`: it carried `PhoneSession.pageHeader` (the page's own
/// script sent it: a form on another site can't).
public struct PhoneRequest: Sendable {
    public var method: String
    public var path: String
    public var peer: String
    public var cookie: String?
    public var fromPage: Bool

    public init(_ method: String, _ path: String, peer: String, cookie: String? = nil, fromPage: Bool = false) {
        self.method = method
        self.path = path
        self.peer = peer
        self.cookie = cookie
        self.fromPage = fromPage
    }
}

/// The answer, with the headers the page needs.
public struct PhoneReply: Sendable {
    public var status: Int
    public var contentType: String?
    public var body: [UInt8]?
    public var setCookie: String?
    public var contentSecurityPolicy: String?
    public var retryAfterSeconds: Int?
    /// A new resource's address (a shared scanner's job: eSCL's 201 Created).
    public var location: String?

    public init(_ status: Int, contentType: String? = nil, body: [UInt8]? = nil) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func empty(_ status: Int) -> PhoneReply { PhoneReply(status) }
}

/// How much one phone may send (roadmap 4.6: bounded sizes and counts). Tests make them small.
public struct PhoneLimits: Sendable {
    /// Photos one scan takes; more are refused (429).
    public var maxPhotos = 100
    /// The largest photo taken (bytes); larger is refused unread (413).
    public var maxPhotoBytes = CapturedPhotoInput.maxBytes
    /// Photos held while the Mac makes pages of earlier ones; the phone's next upload waits past that.
    public var waiting = 2

    public init(maxPhotos: Int = 100, maxPhotoBytes: Int = CapturedPhotoInput.maxBytes, waiting: Int = 2) {
        self.maxPhotos = maxPhotos
        self.maxPhotoBytes = maxPhotoBytes
        self.waiting = waiting
    }
}

/// Where a phone session stands: the code shown and no phone yet; a phone opened the page (only it may send); finished
/// (the phone said Done, or the Mac ended the scan: nothing more is taken).
public enum PhoneState: Sendable { case waiting, paired, finished }

/// One phone scan (roadmap 4.6; the Windows Core's `PhoneSession`): the page a phone's browser opens from the QR code, and
/// the photos it sends, without the HTTPS server around it (PrintMac's `NetworkPhoneHost`, through `PhoneHttp`). Every
/// request is hostile until it shows it may: the path's one-time `token` (32 random bytes, compared in constant time)
/// reaches the page; the page's script then pairs, and the first phone to pair gets a session cookie (another 32 random
/// bytes) bound to its address, after which no other device can pair or send. Photos are read only from the paired phone,
/// one at a time, at most `PhoneLimits.maxPhotoBytes`, a JPEG or PNG by their first bytes within `CapturedPhotoInput`'s
/// pixel limits, at most `PhoneLimits.maxPhotos`. Nothing names a file on this Mac, nothing is listed, nothing is kept
/// after the scan. `photos` finishes when the phone says Done or `finish` is called.
public final class PhoneSession: @unchecked Sendable {
    public static let cookieName = "inkvolt-phone"
    /// The header the page's script sends with each POST; a cross-site form can't send it without a preflight nothing
    /// answers.
    public static let pageHeader = "X-Inkvolt-Phone"

    public let token: String
    public let photos: PhotoChannel
    private let tokenBytes: [UInt8]
    private let macName: String
    private let limits: PhoneLimits
    private let lock = NSLock()
    private var secret: String?
    private var phone: String?
    private var current = PhoneState.waiting
    private var count = 0
    private var uploading = false
    private var listeners: [@Sendable () -> Void] = []

    /// - Parameter macName: this Mac's name, shown on the page (encoded there).
    public init(_ macName: String, limits: PhoneLimits = PhoneLimits()) {
        self.macName = macName
        self.limits = limits
        token = Self.base64Url(Self.random(32))
        tokenBytes = Array(token.utf8)
        photos = PhotoChannel(capacity: max(1, limits.waiting))
    }

    /// The page's path: `/p/` and the token.
    public var pagePath: String { "/p/" + token }

    public var state: PhoneState { lock.withLock { current } }

    /// Photos taken in so far.
    public var received: Int { lock.withLock { count } }

    /// Told (on the server's threads) when the state or the count changes.
    public func onChange(_ listener: @escaping @Sendable () -> Void) { lock.withLock { listeners.append(listener) } }

    /// The Mac ends the scan: the phone is told at its next request, nothing more is taken, the photos already in go on to
    /// be made pages.
    public func finish() {
        let first: Bool = lock.withLock {
            if current == .finished { return false }
            current = .finished
            return true
        }
        guard first else { return }
        photos.finish()
        raise()
    }

    /// Answers `request`. `readBody` reads the request's body, at most the bytes it's given (nil when there are more, or the
    /// connection broke); it's called only for a photo from the paired phone.
    public func handle(_ request: PhoneRequest, readBody: (Int) async -> [UInt8]?) async -> PhoneReply {
        // "/p/<token>" and, after it, the action: anything else is not here (no listing, no other path).
        guard request.path.hasPrefix("/p/") else { return .empty(404) }
        let rest = request.path.dropFirst(3)
        let slash = rest.firstIndex(of: "/")
        let given = slash.map { rest[..<$0] } ?? rest
        let action = slash.map { String(rest[rest.index(after: $0)...]) } ?? ""
        guard given.utf8.count <= 64, Self.same(Array(given.utf8), tokenBytes) else { return .empty(404) }
        let get = request.method == "GET" || request.method == "HEAD"
        let post = request.method == "POST"
        switch action {
        case "": return get ? page() : .empty(405)
        case "pair": return post ? pair(request) : .empty(405)
        case "photo": return post ? await photo(request, readBody) : .empty(405)
        case "done": return post ? done(request) : .empty(405)
        default: return .empty(404)
        }
    }

    /// The first phone to pair is the one; it pairs again (a reload) with its cookie, from its address.
    private func pair(_ request: PhoneRequest) -> PhoneReply {
        guard request.fromPage else { return .empty(403) }
        let made: String? = lock.withLock {
            if current == .finished { return nil }
            if current == .paired { return "" }
            let s = Self.base64Url(Self.random(32))
            secret = s
            phone = PhonePeers.normal(request.peer)
            current = .paired
            return s
        }
        guard let made else { return Self.json(410, "ended") }
        if made.isEmpty {
            let mine = lock.withLock { isPhone(request) }
            return mine ? Self.json(200, "paired") : Self.json(403, "used")
        }
        raise()
        var reply = Self.json(200, "paired")
        reply.setCookie = "\(Self.cookieName)=\(made); Path=\(pagePath); Secure; HttpOnly; SameSite=Strict"
        return reply
    }

    /// The paired phone: its cookie (constant time) from the address it paired from. Under the lock.
    private func isPhone(_ request: PhoneRequest) -> Bool {
        guard let secret, let phone, let cookie = request.cookie, !cookie.isEmpty, cookie.utf8.count <= 64 else { return false }
        let sameCookie = Self.same(Array(cookie.utf8), Array(secret.utf8))
        let samePeer = PhonePeers.normal(request.peer) == phone
        return sameCookie && samePeer
    }

    private func photo(_ request: PhoneRequest, _ readBody: (Int) async -> [UInt8]?) async -> PhoneReply {
        guard request.fromPage else { return .empty(403) }
        // One photo at a time: the page sends them in turn, so a second at once is someone else's doing.
        let refused: PhoneReply? = lock.withLock {
            if !isPhone(request) { return Self.json(403, "used") }
            if current == .finished { return Self.json(410, "ended") }
            if count >= limits.maxPhotos { return Self.json(429, "too-many") }
            if uploading {
                var busy = Self.json(429, "busy")
                busy.retryAfterSeconds = 2
                return busy
            }
            uploading = true
            return nil
        }
        if let refused { return refused }
        defer { lock.withLock { uploading = false } }
        guard let body = await readBody(limits.maxPhotoBytes) else { return Self.json(413, "too-big") }
        guard CapturedPhotoInput.inspect(body) != nil else { return Self.json(415, "not-a-photo") }
        let late: PhoneReply? = lock.withLock {
            if current == .finished { return Self.json(410, "ended") }
            if count >= limits.maxPhotos { return Self.json(429, "too-many") }
            return nil
        }
        if let late { return late }
        guard await photos.write(CapturedPhoto(data: body)) else { return Self.json(410, "ended") } // waits while the Mac is behind
        let n: Int = lock.withLock {
            count += 1
            return count
        }
        raise()
        return Self.json(200, "received", pages: n)
    }

    private func done(_ request: PhoneRequest) -> PhoneReply {
        guard request.fromPage else { return .empty(403) }
        guard lock.withLock({ isPhone(request) }) else { return Self.json(403, "used") }
        finish()
        return Self.json(200, "done", pages: received)
    }

    /// `{"state":…,"pages":…}` (Windows' reply).
    static func json(_ status: Int, _ state: String, pages: Int? = nil) -> PhoneReply {
        let text = "{\"state\":\"\(state)\",\"pages\":\(pages.map(String.init) ?? "null")}"
        return PhoneReply(status, contentType: "application/json; charset=utf-8", body: Array(text.utf8))
    }

    /// The page, with a fresh nonce for its script and style; nothing in it comes from a request.
    private func page() -> PhoneReply {
        let nonce = Self.base64Url(Self.random(16))
        var reply = PhoneReply(200, contentType: "text/html; charset=utf-8", body: Array(PhonePage.html(macName, nonce: nonce).utf8))
        reply.contentSecurityPolicy = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; img-src blob:; connect-src 'self'; "
            + "form-action 'none'; frame-ancestors 'none'; base-uri 'none'"
        return reply
    }

    private func raise() {
        let all = lock.withLock { listeners }
        for listener in all { listener() }
    }

    /// The system's secure random bytes (`SystemRandomNumberGenerator`: arc4random on the Mac, BCryptGenRandom on Windows).
    static func random(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    static func base64Url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Equal, in a time that doesn't depend on where they differ (only on their lengths).
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            let x: UInt8 = i < a.count ? a[i] : 0
            let y: UInt8 = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}

/// Who may reach a phone scan (roadmap 4.6, scanner sharing's rules: private networks only; the Windows Core's
/// `SharePeers`). macOS has no Private/Public network setting, so a served network is one of this Mac's Ethernet and Wi-Fi
/// IPv4 networks (`SocketNetworkScanner.localNetworks`: no VPN tunnel, bridge or AirDrop) whose address is private (RFC 1918)
/// with a real subnet (/8 to /30). Allowed: a device on one of those subnets that came in on that address, or this Mac
/// itself over loopback. Everyone else's connection is closed before TLS starts.
public enum PhonePeers {
    public static func served(_ all: [LocalNetwork]) -> [LocalNetwork] {
        all.filter { n in
            guard let a = NetworkSearch.number(n.address), (8...30).contains(n.prefixLength) else { return false }
            return isPrivate(a)
        }
    }

    /// 10/8, 172.16/12, 192.168/16 (RFC 1918).
    static func isPrivate(_ a: UInt32) -> Bool { a >> 24 == 10 || a >> 20 == (172 << 4 | 1) || a >> 16 == (192 << 8 | 168) }

    /// An address as one family and form: an IPv4 address a dual-stack socket reports as IPv4-mapped IPv6 is the IPv4
    /// address; an IPv6 one loses its interface (`%en0`) and is lowercased.
    public static func normal(_ address: String) -> String {
        var a = address.lowercased()
        if a.hasPrefix("[") && a.hasSuffix("]") { a = String(a.dropFirst().dropLast()) }
        if let percent = a.firstIndex(of: "%") { a = String(a[..<percent]) }
        if a.hasPrefix("::ffff:"), NetworkSearch.number(String(a.dropFirst(7))) != nil { a = String(a.dropFirst(7)) }
        return a
    }

    public static func isLoopback(_ address: String) -> Bool {
        let a = normal(address)
        if a == "::1" { return true }
        return NetworkSearch.number(a).map { $0 >> 24 == 127 } ?? false
    }

    /// Whether a connection from `peer`, arriving at this Mac's `local` address (nil while not known yet: before TLS, the
    /// peer alone is checked), may go on.
    public static func allows(_ peer: String, local: String?, _ served: [LocalNetwork]) -> Bool {
        if isLoopback(peer) { return local.map(isLoopback) ?? true }
        guard let p = NetworkSearch.number(normal(peer)) else { return false }
        let localNumber = local.flatMap { NetworkSearch.number(normal($0)) }
        if local != nil && localNumber == nil { return false }
        for n in served {
            guard let a = NetworkSearch.number(n.address) else { continue }
            if let localNumber, localNumber != a { continue }
            let mask: UInt32 = n.prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - n.prefixLength)
            if p & mask == a & mask && p != a { return true }
        }
        return false
    }
}

/// Connections at once to a phone scan's server, all devices together and from one device (a phone's browser opens a
/// few; Windows' `KestrelPhoneHost` limits). Thread-safe.
public final class PhoneConnections: @unchecked Sendable {
    public static let maxConnections = 12, maxPerPeer = 6
    private let limit: Int, limitPerPeer: Int
    private let lock = NSLock()
    private var all = 0
    private var byPeer: [String: Int] = [:]

    /// The phone scan's limits, or others (the shared scanner's: Windows' `KestrelShareHost`).
    public init(maxConnections: Int = PhoneConnections.maxConnections, maxPerPeer: Int = PhoneConnections.maxPerPeer) {
        limit = maxConnections
        limitPerPeer = maxPerPeer
    }

    /// Counts one more from `peer`; false (nothing counted) past either limit.
    public func enter(_ peer: String) -> Bool {
        let key = PhonePeers.normal(peer)
        return lock.withLock {
            let mine = byPeer[key] ?? 0
            guard all < limit, mine < limitPerPeer else { return false }
            all += 1
            byPeer[key] = mine + 1
            return true
        }
    }

    public func leave(_ peer: String) {
        let key = PhonePeers.normal(peer)
        lock.withLock {
            guard let mine = byPeer[key] else { return }
            all = max(0, all - 1)
            byPeer[key] = mine > 1 ? mine - 1 : nil
        }
    }

    public var open: Int { lock.withLock { all } }
}

/// The phone scan's TLS certificate, as the server uses it (PrintMac's keychain identity); `fingerprint`: SHA-256 of the
/// certificate as pairs of hex digits joined by colons (what Safari's and OpenSSL's views show).
public protocol PhoneCertificate: Sendable {
    var fingerprint: String { get }
}

/// Where the certificate comes from: the app's keychain (PrintMac's `PhoneCertificateKeychain`), a test's own keychain file.
public protocol PhoneCertificates: Sendable {
    func get(hostName: String, now: Date) throws -> any PhoneCertificate
}

/// This Mac's networks as a phone scan reads them (PrintMac: `SocketNetworkScanner.localNetworks`).
public protocol PhoneNetworks: Sendable {
    func read() -> [LocalNetwork]
}

/// What the phone server listens with: on loopback only (demo mode, tests) or every address; the port (0: any free one);
/// the certificate; who may connect (peer, and this Mac's address it reached when known); the session.
public struct PhoneListen: Sendable {
    public var loopbackOnly: Bool
    public var port: Int
    public var certificate: any PhoneCertificate
    public var allowPeer: @Sendable (String, String?) -> Bool
    public var session: PhoneSession
}

/// A started server: its port (nil when it can't say: then it's closed), and `close`, which closes the port at once.
public protocol PhoneListener: Sendable {
    var port: Int? { get }
    func close() async
}

/// Starts the phone page's HTTPS server (PrintMac's `NetworkPhoneHost`). Throws `PhoneHostError.portInUse` when the port is
/// taken.
public protocol PhoneHost: Sendable {
    func start(_ listen: PhoneListen) async throws -> any PhoneListener
}

public enum PhoneHostError: Error, Equatable { case portInUse }

/// What phone scanning works through: the server, this Mac's networks and the certificate. `loopbackOnly` (demo mode,
/// tests): 127.0.0.1 only, any free port.
public struct PhoneEnvironment: Sendable {
    public var host: any PhoneHost
    public var networks: any PhoneNetworks
    public var certificates: any PhoneCertificates
    public var port: Int
    public var loopbackOnly: Bool

    public init(host: any PhoneHost, networks: any PhoneNetworks, certificates: any PhoneCertificates, port: Int = PhoneScan.defaultPort,
                loopbackOnly: Bool = false) {
        self.host = host
        self.networks = networks
        self.certificates = certificates
        self.port = port
        self.loopbackOnly = loopbackOnly
    }

    public static func thisMacOnly(_ host: any PhoneHost, certificates: any PhoneCertificates) -> PhoneEnvironment {
        PhoneEnvironment(host: host, networks: NoNetworks(), certificates: certificates, port: 0, loopbackOnly: true)
    }

    private struct NoNetworks: PhoneNetworks {
        func read() -> [LocalNetwork] { [] }
    }
}

/// An open phone scan: the session, the address its QR code holds, and the certificate's fingerprint. `close` (again is
/// nothing) finishes the session and closes the port at once.
public final class PhoneLink: @unchecked Sendable {
    public let session: PhoneSession
    /// The page's address: https, this Mac's address on the private network, the port and the one-time path.
    public let url: String
    public let fingerprint: String
    public let port: Int
    private let listener: any PhoneListener
    private let lock = NSLock()
    private var closed = false

    init(session: PhoneSession, url: String, port: Int, listener: any PhoneListener, fingerprint: String) {
        self.session = session
        self.url = url
        self.port = port
        self.listener = listener
        self.fingerprint = fingerprint
    }

    /// The first eight bytes of the fingerprint, as a browser's certificate view shows them.
    public var shortFingerprint: String { String(fingerprint.prefix(23)) }

    public func close() async {
        let first: Bool = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard first else { return }
        session.finish()
        await listener.close()
    }
}

/// What opening a phone scan gave: the link, or why there's none in plain words.
public struct PhoneOpening: Sendable {
    public var link: PhoneLink?
    public var problem: String?
}

/// Phone as a scanner over the home network (roadmap 4.6; the Windows Core's `PhoneScan`): opens a `PhoneSession` on its
/// own HTTPS port (`defaultPort`), with scanner sharing's rules: only on private networks, only to devices on their own
/// subnets (`PhonePeers`), with the app's own certificate. The port is open only while a phone scan is (the app opens it
/// for one scan and closes it when the scan ends or the window closes).
public enum PhoneScan {
    /// The port (TCP, HTTPS); Windows' too.
    public static let defaultPort = 9781

    /// The Mac's line about the phone: waiting for it, connected, how many pages it sent, finished.
    public static func statusText(_ state: PhoneState, _ received: Int) -> String {
        switch state {
        case .waiting: return loc("Waiting for your phone: point its camera at the code and open the link it shows.")
        case .paired where received == 0:
            return loc("Phone connected. Take a photo of each page; tap Done on the phone, or Done here, when you've finished.")
        case .paired where received == 1: return loc("Phone connected: 1 page in. Tap Done on the phone, or Done here, when you've finished.")
        case .paired:
            return loc("Phone connected: {0} pages in. Tap Done on the phone, or Done here, when you've finished.", CoreLanguage.number(received))
        case .finished where received == 1: return loc("Done: 1 page came from the phone.")
        case .finished: return loc("Done: {0} pages came from the phone.", CoreLanguage.number(received))
        }
    }

    /// The address a phone reaches this Mac at: the first served network's (the order macOS lists them, Ethernet and Wi-Fi
    /// first), or nil.
    public static func address(for served: [LocalNetwork]) -> String? { served.first?.address }

    /// The page's address for `address` and `port`.
    public static func url(_ address: String, _ port: Int, _ session: PhoneSession) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "https://\(host):\(port)\(session.pagePath)"
    }

    /// The host name the certificate is made for: this Mac's name as a `.local` name (letters, digits and hyphens).
    public static func hostName(_ macName: String) -> String {
        let label = String(macName.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") ? Character($0) : "-" })
        let trimmed = label.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63)
        return (trimmed.isEmpty ? "mac" : String(trimmed)) + ".local"
    }

    /// Opens a phone scan, or says why it can't (no private network, the port taken, the server didn't start). `log` is told
    /// what happens, in plain words: never a device's address or the code.
    public static func open(_ env: PhoneEnvironment, macName: String, limits: PhoneLimits = PhoneLimits(), now: Date = Date(),
                            log: @Sendable (String) -> Void = { _ in }) async -> PhoneOpening {
        var served: [LocalNetwork] = []
        var shown = "127.0.0.1"
        if !env.loopbackOnly {
            served = PhonePeers.served(env.networks.read())
            guard let address = address(for: served) else {
                return PhoneOpening(link: nil, problem: loc("Your phone can send pages only over a private network, and this Mac isn't on one. Join your home or office Wi-Fi or Ethernet, then try again."))
            }
            shown = address
        }
        let session = PhoneSession(macName, limits: limits)
        let loopback = env.loopbackOnly
        let allowed = served
        var listener: (any PhoneListener)?
        do {
            let certificate = try env.certificates.get(hostName: hostName(macName), now: now)
            let listen = PhoneListen(loopbackOnly: loopback, port: env.port, certificate: certificate, allowPeer: { peer, local in
                loopback ? PhonePeers.isLoopback(peer) : PhonePeers.allows(peer, local: local, allowed)
            }, session: session)
            let started = try await env.host.start(listen)
            listener = started
            guard let port = started.port else {
                await started.close()
                session.finish()
                log("Phone scan didn't start: the server has no port.")
                return PhoneOpening(link: nil, problem: loc("Scanning with your phone couldn't start. Try again; if it still doesn't start, restart Inkvolt Print."))
            }
            log("Phone scan: listening on port \(port) (\(loopback ? "this Mac only" : "\(served.count) private network address(es)")).")
            let link = PhoneLink(session: session, url: url(shown, port, session), port: port, listener: started, fingerprint: certificate.fingerprint)
            return PhoneOpening(link: link, problem: nil)
        } catch {
            await listener?.close()
            session.finish()
            log("Phone scan didn't start: \(error)")
            let problem = (error as? PhoneHostError) == .portInUse
                ? loc("Another app uses port {0}, which scanning with your phone needs. Quit it and try again.", String(env.port))
                : loc("Scanning with your phone couldn't start. Try again; if it still doesn't start, restart Inkvolt Print.")
            return PhoneOpening(link: nil, problem: problem)
        }
    }
}
