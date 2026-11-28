import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network
import PrintCore
import Security

/// The phone scan page's HTTPS server (roadmap 4.6; Windows' `KestrelPhoneHost`), on Network framework: TLS 1.2 or 1.3 with
/// the app's own certificate (`PhoneCertificateKeychain`), HTTP/1.1 through PrintCore's `PhoneHttp`. A connection from a
/// device `PhoneListen.allowPeer` refuses is cancelled before TLS starts (the certificate isn't even shown), and again once
/// ready when it reached another address of this Mac; a few connections per device, a dozen in all (`PhoneConnections`);
/// a TLS handshake has 10 seconds. Listens on every address with `acceptLocalOnly` (Network framework takes only devices on
/// this Mac's own networks), or on 127.0.0.1 only. No logging of devices. `close` closes the port at once.
public struct NetworkPhoneHost: PhoneHost {
    static let handshakeTimeout: TimeInterval = 10

    public init() {}

    public func start(_ listen: PhoneListen) async throws -> any PhoneListener {
        let listener = try Self.listener(listen.certificate, loopbackOnly: listen.loopbackOnly, port: listen.port)
        let server = NetworkPhoneListener(listener, allowPeer: listen.allowPeer, counts: PhoneConnections(), service: listen.session)
        return try await server.start()
    }

    /// A listener with TLS and the app's certificate (the phone scan's and the shared scanner's), on loopback only or every
    /// address, not yet started.
    static func listener(_ certificate: any PhoneCertificate, loopbackOnly: Bool, port: Int) throws -> NWListener {
        guard let certificate = certificate as? KeychainPhoneCertificate, let identity = sec_identity_create(certificate.identity) else {
            throw PhoneServerError("no TLS identity")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, port))) ?? .any
        do {
            if loopbackOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                return try NWListener(using: parameters)
            }
            return try NWListener(using: parameters, on: port)
        } catch let error as NWError {
            throw Self.mapped(error)
        }
    }

    static func mapped(_ error: NWError) -> any Error {
        if case .posix(let code) = error, code == .EADDRINUSE { return PhoneHostError.portInUse }
        return error
    }

    /// An endpoint's address as text: dotted IPv4 (an IPv4-mapped IPv6 one too), IPv6 in its usual form; nil for a name.
    static func address(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return a.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let a):
            let b = Array(a.rawValue)
            if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return b[12...].map(String.init).joined(separator: ".") }
            return PhonePeers.normal("\(a)")
        case .name: return nil
        @unknown default: return nil
        }
    }
}

public struct PhoneServerError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One running server (the phone scan's, or the shared scanner's): the listener, its connections and the tasks serving them.
final class NetworkPhoneListener: PhoneListener, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.bermudezsystems.InkvoltPrint.phone")
    private let listener: NWListener
    private let allowPeer: @Sendable (String, String?) -> Bool
    private let service: any HttpService
    private let counts: PhoneConnections
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var closed = false
    private var boundPort: Int?
    private let stopped = OnceResult<Bool>()

    init(_ listener: NWListener, allowPeer: @escaping @Sendable (String, String?) -> Bool, counts: PhoneConnections, service: any HttpService) {
        self.listener = listener
        self.allowPeer = allowPeer
        self.counts = counts
        self.service = service
    }

    var port: Int? { lock.withLock { boundPort } }

    func start() async throws -> NetworkPhoneListener {
        enum Start: Sendable { case ready(Int?), failed(NWError) }
        let started = OnceResult<Start>()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: started.finish(.ready(self?.listener.port.map { Int($0.rawValue) }))
            case .failed(let e), .waiting(let e): started.finish(.failed(e))
            case .cancelled: self?.stopped.finish(true)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        listener.start(queue: Self.queue)
        let result = await withCheckedContinuation { (c: CheckedContinuation<Start, Never>) in started.start(c) }
        switch result {
        case .ready(let port):
            lock.withLock { boundPort = port }
            return self
        case .failed(let error):
            await close()
            throw NetworkPhoneHost.mapped(error)
        }
    }

    /// A new connection: refused before TLS unless its device may connect and has room; served once ready.
    private func accept(_ connection: NWConnection) {
        guard let peer = NetworkPhoneHost.address(connection.endpoint), allowPeer(peer, nil), counts.enter(peer) else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        let kept: Bool = lock.withLock {
            if closed { return false }
            connections[id] = connection
            return true
        }
        guard kept else {
            counts.leave(peer)
            connection.cancel()
            return
        }
        let allowPeer = self.allowPeer, service = self.service
        let ready = Mutexed(false)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.set(true)
                let local = connection.currentPath?.localEndpoint.flatMap(NetworkPhoneHost.address)
                guard local != nil, allowPeer(peer, local) else {
                    connection.cancel()
                    return
                }
                let task = Task {
                    await PhoneHttp.serve(NetworkPhoneConnection(connection), peer: peer, service: service)
                    connection.cancel()
                }
                self?.lock.withLock { self?.tasks[id] = task }
            case .failed: connection.cancel()
            case .cancelled:
                self?.counts.leave(peer)
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: id) }
                // A request still waiting (a shared scanner's long poll) ends with its connection.
                self?.lock.withLock { self?.tasks.removeValue(forKey: id) }?.cancel()
            default: break
            }
        }
        connection.start(queue: Self.queue)
        Self.queue.asyncAfter(deadline: .now() + NetworkPhoneHost.handshakeTimeout) {
            if !ready.value { connection.cancel() }
        }
    }

    func close() async {
        let (all, running, first): ([NWConnection], [Task<Void, Never>], Bool) = lock.withLock {
            if closed { return ([], [], false) }
            closed = true
            let all = Array(connections.values), running = Array(tasks.values)
            connections = [:]
            tasks = [:]
            return (all, running, true)
        }
        guard first else { return }
        running.forEach { $0.cancel() }
        all.forEach { $0.cancel() }
        listener.cancel()
        // The port is free once the listener says it's cancelled (at most a second).
        let timer = Task {
            try? await Task.sleep(for: .seconds(1))
            stopped.finish(false)
        }
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in stopped.start(c) }
        timer.cancel()
    }
}

/// A Bool shared between Network framework's callbacks.
private final class Mutexed: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { lock.withLock { v } }
    func set(_ new: Bool) { lock.withLock { v = new } }
}

/// One TLS connection's bytes for `PhoneHttp`. A receive that times out ends the connection (Network framework can't
/// take back a pending receive).
struct NetworkPhoneConnection: PhoneConnectionIO, @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    func receive(max: Int, timeout: Duration) async -> [UInt8]? {
        let once = OnceResult<[UInt8]>()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.finish([])
        }
        let bytes = await withCheckedContinuation { (c: CheckedContinuation<[UInt8], Never>) in
            once.start(c)
            connection.receive(minimumIncompleteLength: 1, maximumLength: Swift.max(1, max)) { data, _, _, _ in
                once.finish(data.map { Array($0) } ?? [])
            }
        }
        timer.cancel()
        if bytes.isEmpty {
            connection.cancel()
            return nil
        }
        return bytes
    }

    func send(_ bytes: [UInt8]) async -> Bool {
        let once = OnceResult<Bool>()
        let timer = Task {
            try? await Task.sleep(for: .seconds(30))
            once.finish(false)
        }
        let sent = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.start(c)
            connection.send(content: Data(bytes), completion: .contentProcessed { error in once.finish(error == nil) })
        }
        timer.cancel()
        return sent
    }
}

/// This Mac's networks for a phone scan: Search my network's (`SocketNetworkScanner.localNetworks`: Ethernet and Wi-Fi,
/// IPv4, no tunnel, bridge or AirDrop); `PhonePeers.served` keeps the private ones.
public struct SystemPhoneNetworks: PhoneNetworks {
    public init() {}

    public func read() -> [LocalNetwork] { SocketNetworkScanner().localNetworks() }
}

/// The phone scan's certificate as the server uses it: the keychain's identity (the certificate and its private key).
public struct KeychainPhoneCertificate: PhoneCertificate, @unchecked Sendable {
    public let identity: SecIdentity
    public let der: [UInt8]
    public let fingerprint: String
}

/// The phone scan's self-signed certificate (roadmap 4.6; Windows keeps scanner sharing's in the user's key store): made
/// once, an ECDSA P-256 key and the certificate (`PhoneCertificateDer`) in the app's keychain under `label`, both usable by
/// Inkvolt Print only, and made anew 30 days before its end. The app passes no keychain (the sandboxed app's own items in
/// the user's keychain); tests pass a keychain file of their own, so nothing of the account's is read or changed.
public struct PhoneCertificateKeychain: PhoneCertificates, @unchecked Sendable {
    public static let label = "Inkvolt Print phone scan"
    private let keychain: SecKeychain?

    public init() { keychain = nil }

    /// Everything in `keychain` only (a test's own file).
    public init(keychain: SecKeychain) { self.keychain = keychain }

    public func get(hostName: String, now: Date) throws -> any PhoneCertificate {
        if let kept = find(now) { return kept }
        remove()
        return try make(hostName: hostName, now: now)
    }

    /// The kept certificate still good at `now`, with its key, or nil.
    func find(_ now: Date) -> KeychainPhoneCertificate? {
        var query = scoped([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: Self.label])
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let certificates = found as? [SecCertificate] else { return nil }
        for certificate in certificates {
            guard let from = SecCertificateCopyNotValidBeforeDate(certificate) as Date?, let to = SecCertificateCopyNotValidAfterDate(certificate) as Date?,
                  PhoneCertificateDer.usable(notBefore: from, notAfter: to, now: now), let kept = identity(certificate) else { continue }
            return kept
        }
        return nil
    }

    /// Removes the kept certificates and keys (an old one, or one without its key).
    func remove() {
        for kind in [kSecClassCertificate, kSecClassKey] {
            let query = scoped([kSecClass as String: kind, kSecAttrLabel as String: Self.label])
            for _ in 0..<20 where SecItemDelete(query as CFDictionary) == errSecSuccess {}
        }
    }

    private func make(hostName: String, now: Date) throws -> KeychainPhoneCertificate {
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrLabel as String: Self.label],
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw PhoneServerError("key not made: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let publicKey = SecKeyCopyPublicKey(key), let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw PhoneServerError("public key not read")
        }
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { throw PhoneServerError("no random bytes") }
        let tbs = PhoneCertificateDer.tbs(publicKey: Array(point), hostName: hostName, serial: serial, now: now)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data? else {
            throw PhoneServerError("not signed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let der = PhoneCertificateDer.certificate(tbs: tbs, signature: Array(signature))
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else { throw PhoneServerError("certificate not read back") }
        var add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecAttrLabel as String: Self.label]
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PhoneServerError("certificate not kept (\(status))") }
        guard let made = identity(certificate) else { throw PhoneServerError("no identity for the certificate") }
        return made
    }

    private func identity(_ certificate: SecCertificate) -> KeychainPhoneCertificate? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(keychain, certificate, &identity) == errSecSuccess, let identity else { return nil }
        let der = Array(SecCertificateCopyData(certificate) as Data)
        return KeychainPhoneCertificate(identity: identity, der: der, fingerprint: Self.fingerprint(der))
    }

    public static func fingerprint(_ der: [UInt8]) -> String { PhoneCertificateDer.fingerprint(Array(SHA256.hash(data: der))) }

    private func scoped(_ query: [String: Any]) -> [String: Any] {
        var q = query
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        return q
    }
}

/// A keychain file of its own in a new folder, for one run (demo mode's phone scan, tests: Windows' certificate "made for
/// the run"), deleted with its folder by `delete`: never the login keychain, never on the search list, so nothing of the
/// account's is read or changed. SecKeychainCreate and SecKeychainDelete are looked up at run time: the SDK marks file
/// keychains deprecated, and the build has no warnings. SecKeychainCreate doesn't add the file to the search list
/// (`security create-keychain`'s users add it themselves), and nothing here does.
public final class KeychainFile: @unchecked Sendable {
    public let folder: URL
    public let keychain: SecKeychain
    private let lock = NSLock()
    private var deleted = false

    private typealias Create = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, UInt8, OpaquePointer?,
                                                UnsafeMutablePointer<OpaquePointer?>) -> OSStatus
    private typealias Delete = @convention(c) (UnsafeRawPointer?) -> OSStatus

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)
        return dlsym(security, name)
    }

    /// A new keychain file in a new folder under `parent` (the temporary folder by default), unlocked with a random password.
    public init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        folder = parent.appendingPathComponent("inkvolt-phone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("run.keychain").path
        guard let create = Self.symbol("SecKeychainCreate") else { throw PhoneServerError("no SecKeychainCreate") }
        let password = Array(UUID().uuidString.utf8)
        var made: OpaquePointer?
        let status = password.withUnsafeBytes { p in
            unsafeBitCast(create, to: Create.self)(path, UInt32(p.count), p.baseAddress, 0, nil, &made)
        }
        guard status == errSecSuccess, let made else {
            try? FileManager.default.removeItem(at: folder)
            throw PhoneServerError("keychain file not made (\(status))")
        }
        keychain = Unmanaged<SecKeychain>.fromOpaque(UnsafeRawPointer(made)).takeRetainedValue()
    }

    /// Deletes the keychain and its folder (again is nothing).
    public func delete() {
        let first: Bool = lock.withLock {
            if deleted { return false }
            deleted = true
            return true
        }
        guard first else { return }
        if let delete = Self.symbol("SecKeychainDelete") {
            _ = unsafeBitCast(delete, to: Delete.self)(Unmanaged.passUnretained(keychain).toOpaque())
        }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The QR code of a phone scan's address (CoreImage's generator, error correction M): one pixel per module, with the
/// generator's own margin. Shown scaled up without smoothing.
public enum PhoneQrCode {
    public static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }
}
