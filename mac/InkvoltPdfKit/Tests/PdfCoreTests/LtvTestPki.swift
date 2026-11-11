import Foundation
import Security
@testable import PdfCore

/// A whole certificate authority on this Mac's loopback, for tests (ported from LtvTestPki.cs): a generated root, an
/// intermediate, a signer and a timestamp authority, with an OCSP responder, CRLs, issuer certificates and an RFC 3161
/// server behind the addresses those certificates name. Nothing here needs the internet. Each path can be overridden to
/// misbehave. The server is `AiLoopbackServer` (threads of its own, never GCD's pool, closed by `stop`); a handler that
/// waits does so with `pause`, which `stop` ends, so no thread outlives the test.
final class LtvTestPki: @unchecked Sendable {
    /// A certificate and its key.
    struct Issued {
        let cert: Certificate
        let key: SecKey
        var id: DigitalId { DigitalId(certificate: cert, key: key) }
        var thumbprint: String { cert.thumbprint }
    }

    /// Keys are slow to make and these tests make many authorities, so they share a few: each authority's certificates
    /// use different ones.
    private static let keyLock = NSLock()
    nonisolated(unsafe) private static var keys: [SecKey] = []

    private static func key(_ n: Int) -> SecKey {
        keyLock.withLock {
            while keys.count < 8 { keys.append(try! KeyEncoding.ephemeral(rsaBits: 2048)) }
            return keys[n % keys.count]
        }
    }

    private let lock = NSLock()
    private let stopped = NSCondition()
    private var isStopped = false
    private var nextKey = 0
    private var nextSerial = 1000
    private var revoked: [[UInt8]: Date] = [:]
    private var hitList: [String] = []
    private var issued: [String: Issued] = [:]
    private var overrideList: [String: @Sendable ([UInt8]) -> [UInt8]] = [:]
    private var delegate = false
    private var server: AiLoopbackServer!

    private(set) var root: Issued!
    private(set) var intermediate: Issued!
    private(set) var signer: Issued!
    private(set) var tsa: Issued!
    private(set) var responder: Issued!
    let baseUrl: String

    /// When set, OCSP answers are signed by the delegated responder instead of the issuer.
    var delegateOcsp: Bool {
        get { lock.withLock { delegate } }
        set { lock.withLock { delegate = newValue } }
    }

    /// Requests by path, as they arrive.
    var hits: [String] { lock.withLock { hitList } }

    /// Stands in for a path: what it answers instead (raw HTTP response bytes).
    func override(_ path: String, _ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) { lock.withLock { overrideList[path] = answer } }

    var anchors: [Certificate] { [root.cert] }

    /// A client that may reach this Mac's loopback, as nothing else may.
    func client(_ timeout: Double? = nil) -> LtvClient { LtvClient(allowLoopback: true, timeout: timeout, allowHttpTimestamp: true) }

    var timestampUrl: String { "\(baseUrl)/tsa" }

    /// The server's way back to this authority, set once it is made.
    private final class Box: @unchecked Sendable {
        weak var pki: LtvTestPki?
    }

    init() throws {
        let box = Box()
        guard let server = AiLoopbackServer(answer: { received in box.pki?.serve(received) ?? .raw("HTTP/1.1 503 X\r\nContent-Length: 0\r\n\r\n") }) else {
            throw SigningError("no loopback listener")
        }
        baseUrl = "http://127.0.0.1:\(server.port)"
        self.server = server
        box.pki = self
        root = try issue("Test Root CA", nil, ca: true, urls: false)
        intermediate = try issue("Test Intermediate CA", root, ca: true)
        signer = try issue("Test Long-Term Signer", intermediate, ku: 0xC0)
        tsa = try issue("Test Timestamp Authority", root, ku: 0x80, eku: Signatures.timestampingEku)
        responder = try issue("Test OCSP Responder", intermediate, ku: 0x80, eku: Oids.ocspSigning, noCheck: true, urls: false)
    }

    /// Stops the server and ends every handler still waiting (`pause`). Returns once the port is closed.
    func stop() {
        stopped.lock()
        isStopped = true
        stopped.broadcast()
        stopped.unlock()
        server.stop()
    }

    /// Waits `seconds`, or less when the authority stops: what a slow server does, without outliving the test.
    func pause(_ seconds: Double) {
        let until = Date() + seconds
        stopped.lock()
        while !isStopped && Date() < until { _ = stopped.wait(until: until) }
        stopped.unlock()
    }

    // MARK: Certificates

    /// A certificate from this authority (from `issuer`, self-signed when nil), naming this server's addresses unless told otherwise.
    func issue(_ cn: String, _ issuer: Issued?, ca: Bool = false, ku: UInt8? = nil, eku: String? = nil, noCheck: Bool = false, urls: Bool = true,
               ocsp: [String]? = nil, crl: [String]? = nil, issuers: [String]? = nil) throws -> Issued {
        let (key, serial): (SecKey, Int) = lock.withLock {
            nextKey += 1
            nextSerial += 1
            return (Self.key(nextKey - 1), nextSerial)
        }
        let spki = try KeyEncoding.subjectPublicKeyInfo(key)
        let keyBits = Array(try Der.parse(spki).child(1).content.dropFirst())
        let name = DerWriter.seq([(Oids.commonName, cn), (Oids.organization, "Inkvolt Tests"), ("2.5.4.6", "PR")].reversed().map { n in
            DerWriter.setOf([DerWriter.seq([DerWriter.oid(n.0), n.0 == "2.5.4.6" ? DerWriter.tlv(0x13, Array(n.1.utf8)) : DerWriter.utf8(n.1)])])
        })
        var exts: [[UInt8]] = []
        func ext(_ oid: String, _ critical: Bool, _ value: [UInt8]) {
            exts.append(DerWriter.seq([DerWriter.oid(oid)] + (critical ? [DerWriter.bool(true)] : []) + [DerWriter.octets(value)]))
        }
        ext(Oids.basicConstraints, true, DerWriter.seq(ca ? [DerWriter.bool(true)] : []))
        let usage = ku ?? (ca ? 0x06 : 0x80)
        ext(Oids.keyUsage, true, DerWriter.bits([usage], unused: UInt8(usage.trailingZeroBitCount)))
        if let eku { ext(Oids.extendedKeyUsage, true, DerWriter.seq([DerWriter.oid(eku)])) }
        ext(Oids.subjectKeyId, false, DerWriter.octets(DigestAlgorithm.sha1.hash(keyBits)))
        if let issuer {
            ext("2.5.29.35", false, DerWriter.seq([DerWriter.tlv(0x80, DigestAlgorithm.sha1.hash(issuer.cert.publicKeyBits))]))
            let id = issuer.thumbprint
            let ocspUrls = ocsp ?? (urls ? ["\(baseUrl)/ocsp"] : [])
            let crlUrls = crl ?? (urls ? ["\(baseUrl)/crl/\(id).crl"] : [])
            let issuerUrls = issuers ?? (urls ? ["\(baseUrl)/cert/\(id).cer"] : [])
            if !ocspUrls.isEmpty || !issuerUrls.isEmpty {
                ext(Oids.authorityInfoAccess, false, DerWriter.seq(
                    ocspUrls.map { DerWriter.seq([DerWriter.oid("1.3.6.1.5.5.7.48.1"), DerWriter.tlv(0x86, Array($0.utf8))]) }
                        + issuerUrls.map { DerWriter.seq([DerWriter.oid("1.3.6.1.5.5.7.48.2"), DerWriter.tlv(0x86, Array($0.utf8))]) }))
            }
            if !crlUrls.isEmpty {
                ext(Oids.crlDistributionPoints, false, DerWriter.seq(crlUrls.map {
                    DerWriter.seq([DerWriter.context(0, DerWriter.context(0, DerWriter.tlv(0x86, Array($0.utf8))))])
                }))
            }
        }
        if noCheck { exts.append(DerWriter.seq([DerWriter.oid(Oids.ocspNoCheck), DerWriter.octets(DerWriter.null)])) }
        let from = Date() - 30 * 86400
        let to = issuer.map { $0.cert.notAfter - 86400 } ?? Date() + 5 * 365 * 86400
        let sigAlg = DerWriter.seq([DerWriter.oid("1.2.840.113549.1.1.11"), DerWriter.null])
        let tbs = DerWriter.seq([DerWriter.context(0, DerWriter.int(2)), DerWriter.int(serial), sigAlg, issuer.map { $0.cert.subjectRaw } ?? name,
                                 DerWriter.seq([DerWriter.time(from), DerWriter.time(to)]), name, spki, DerWriter.context(3, DerWriter.seq(exts))])
        let signature = try KeyEncoding.sign(issuer?.key ?? key, tbs, .sha256)
        let cert = try Certificate(der: DerWriter.seq([tbs, sigAlg, DerWriter.bits(signature)]))
        let made = Issued(cert: cert, key: key)
        lock.withLock { issued[cert.thumbprint] = made }
        return made
    }

    /// From now on the OCSP responder and the CRL say this certificate was revoked at that time.
    func revoke(_ c: Issued, at: Date) {
        lock.withLock { revoked[canonicalInteger(c.cert.serial)] = at }
    }

    // MARK: Answers

    /// An OCSP request as the app writes one, for feeding `ocspReply` directly.
    static func ocspRequest(_ cert: Issued, _ issuer: Issued) -> [UInt8] { OcspResponse.request(cert.cert, issuer.cert) }

    /// An OCSP reply to a request, as this authority's responder writes it.
    func ocspReply(_ request: [UInt8], forgedKey: SecKey? = nil, thisUpdate: Date? = nil) throws -> [UInt8] {
        let certId = try Der.parse(request).child(0).child(0).child(0).child(0)
        let parts = try certId.children()
        let nameHash = parts[1].content
        let serial = canonicalInteger(parts[3].content)
        guard let issuer = lock.withLock({ issued.values.first { DigestAlgorithm.sha1.hash($0.cert.subjectRaw) == nameHash } }) else {
            throw SigningError("Unknown issuer asked about")
        }
        let signer = delegateOcsp && issuer.thumbprint == intermediate.thumbprint ? responder! : issuer
        let now = thisUpdate ?? Date()
        let when = lock.withLock { revoked[serial] }
        let status = when.map { DerWriter.context(1, DerWriter.generalized($0)) } ?? [0x80, 0x00]
        let single = DerWriter.seq([certId.raw, status, DerWriter.generalized(now), DerWriter.context(0, DerWriter.generalized(now + 7 * 86400))])
        let tbs = DerWriter.seq([DerWriter.context(2, DerWriter.octets(DigestAlgorithm.sha1.hash(signer.cert.publicKeyBits))),
                                 DerWriter.generalized(now), DerWriter.seq([single])])
        let sig = try KeyEncoding.sign(forgedKey ?? signer.key, tbs, .sha256)
        var basic: [[UInt8]] = [tbs, DerWriter.seq([DerWriter.oid("1.2.840.113549.1.1.11"), DerWriter.null]), DerWriter.bits(sig)]
        if signer.thumbprint != issuer.thumbprint { basic.append(DerWriter.context(0, DerWriter.seq([signer.cert.der]))) }
        return DerWriter.seq([DerWriter.tlv(0x0A, [0]),
                              DerWriter.context(0, DerWriter.seq([DerWriter.oid(Oids.ocspBasic), DerWriter.octets(DerWriter.seq(basic))]))])
    }

    /// The issuer's CRL now, listing what was revoked.
    /// `unreadableDates`: each entry's revocation date is a time no reader can read.
    func crl(_ issuer: Issued, unreadableDates: Bool = false) throws -> [UInt8] {
        let now = Date()
        let listed = lock.withLock { revoked }
        let entries = listed.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map {
            DerWriter.seq([DerWriter.tlv(0x02, $0.key), unreadableDates ? DerWriter.tlv(0x17, Array("99".utf8)) : DerWriter.time($0.value)])
        }
        let sigAlg = DerWriter.seq([DerWriter.oid("1.2.840.113549.1.1.11"), DerWriter.null])
        var tbs: [[UInt8]] = [DerWriter.int(1), sigAlg, issuer.cert.subjectRaw, DerWriter.time(now - 1), DerWriter.time(now + 7 * 86400)]
        if !entries.isEmpty { tbs.append(DerWriter.seq(entries)) }
        tbs.append(DerWriter.context(0, DerWriter.seq([DerWriter.seq([DerWriter.oid("2.5.29.20"), DerWriter.octets(DerWriter.int(1))])])))
        let body = DerWriter.seq(tbs)
        return DerWriter.seq([body, sigAlg, DerWriter.bits(try KeyEncoding.sign(issuer.key, body, .sha256))])
    }

    /// An RFC 3161 reply from the test authority.
    func timestampReply(_ request: [UInt8]) throws -> [UInt8] {
        let req = try Der.parse(request).children()
        let nonce = req.dropFirst(2).first { $0.tag == 0x02 }
        var tst: [[UInt8]] = [DerWriter.int(1), DerWriter.oid("1.2.3.4.5"), req[1].raw, DerWriter.int(Int.random(in: 1..<Int(Int32.max))), DerWriter.generalized(Date())]
        if let nonce { tst.append(nonce.raw) }
        let tsa = self.tsa!
        let cms = try CmsBuilder(DerWriter.seq(tst), encapsulate: true, contentType: Oids.tstInfo, signer: tsa.cert, chain: [root.cert],
                                 digest: .sha256, signingTime: nil) { try KeyEncoding.sign(tsa.key, $0, .sha256) }
        return DerWriter.seq([DerWriter.seq([DerWriter.int(0)]), cms.encode()])
    }

    /// A response as a server sends it: status line, headers, body.
    static func http(_ status: Int, _ body: [UInt8], _ headers: String...) -> [UInt8] {
        var head = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for h in headers { head += h + "\r\n" }
        return Array((head + "\r\n").utf8) + body
    }

    private func serve(_ received: AiLoopbackServer.Received) -> AiLoopbackServer.Answer {
        let path = received.path
        lock.withLock { hitList.append(path) }
        return AiLoopbackServer.Answer(pieces: [(try? answer(path, received.bodyBytes)) ?? Self.http(500, [])])
    }

    private func answer(_ path: String, _ body: [UInt8]) throws -> [UInt8] {
        if let over = lock.withLock({ overrideList[path] }) { return over(body) }
        if path == "/ocsp" { return Self.http(200, try ocspReply(body), "Content-Type: application/ocsp-response") }
        if path == "/tsa" { return Self.http(200, try timestampReply(body), "Content-Type: application/timestamp-reply") }
        if path.hasPrefix("/crl/"), path.hasSuffix(".crl"), let issuer = lock.withLock({ issued[String(path.dropFirst(5).dropLast(4))] }) {
            return Self.http(200, try crl(issuer))
        }
        if path.hasPrefix("/cert/"), path.hasSuffix(".cer"), let cert = lock.withLock({ issued[String(path.dropFirst(6).dropLast(4))] }) {
            return Self.http(200, cert.cert.der)
        }
        return Self.http(404, [])
    }
}
