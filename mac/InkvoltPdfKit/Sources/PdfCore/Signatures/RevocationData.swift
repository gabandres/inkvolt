import Foundation
import PrintCore
import Security

/// What a certificate names and how it was signed, read from its bytes (the Windows app's `CertFacts`). Nothing here goes online.
enum CertFacts {
    /// Issued by itself: nobody else can say it was revoked, whoever trusts it does so directly.
    static func isSelfSigned(_ c: Certificate) -> Bool { c.isSelfIssued && signedBy(c, c) }

    /// True when `issuer`'s key signed `cert`.
    static func signedBy(_ cert: Certificate, _ issuer: Certificate) -> Bool {
        DerSignature.verify(issuer, cert.signatureAlgorithm, cert.tbs, cert.signatureValue)
    }

    static func hasEku(_ c: Certificate, _ eku: String) -> Bool { c.extendedKeyUsages?.contains(eku) == true }

    /// The name shown for a certificate: its common name, else its subject, shortened (a file's certificate can say anything).
    static func name(_ c: Certificate) -> String {
        let n = c.commonName.flatMap { $0.isEmpty ? nil : $0 } ?? c.subject
        return n.count > 120 ? String(n.prefix(120)) + "…" : n
    }
}

/// Checks an AlgorithmIdentifier-style signature with a certificate's public key: RSA (PKCS #1, PSS) and ECDSA (the
/// Windows app's `DerSignature`).
enum DerSignature {
    static func verify(_ signer: Certificate, _ algorithm: [UInt8], _ signed: [UInt8], _ signature: [UInt8]) -> Bool {
        guard let alg = try? Der.parse(algorithm).children(), let oid = try? alg.first?.oid(), let key = signer.publicKey else { return false }
        let method: SecKeyAlgorithm
        switch oid {
        case "1.2.840.113549.1.1.5": method = .rsaSignatureMessagePKCS1v15SHA1
        case "1.2.840.113549.1.1.11": method = .rsaSignatureMessagePKCS1v15SHA256
        case "1.2.840.113549.1.1.12": method = .rsaSignatureMessagePKCS1v15SHA384
        case "1.2.840.113549.1.1.13": method = .rsaSignatureMessagePKCS1v15SHA512
        case Oids.rsaPss:
            guard let hash = pssHash(alg) else { return false }
            method = hash.rsaPss
        case "1.2.840.10045.4.1": method = .ecdsaSignatureMessageX962SHA1
        case "1.2.840.10045.4.3.2": method = .ecdsaSignatureMessageX962SHA256
        case "1.2.840.10045.4.3.3": method = .ecdsaSignatureMessageX962SHA384
        case "1.2.840.10045.4.3.4": method = .ecdsaSignatureMessageX962SHA512
        default: return false
        }
        return KeyEncoding.verify(key, method, signed, signature)
    }

    /// The hash of RSASSA-PSS parameters (RFC 4055: [0] hashAlgorithm, SHA-1 when left out).
    private static func pssHash(_ alg: [Der]) -> DigestAlgorithm? {
        guard alg.count > 1, alg[1].tag == 0x30, let pars = try? alg[1].children(), let first = pars.first, first.tag == 0xA0 else { return .sha1 }
        guard let oid = try? first.child(0).child(0).oid() else { return nil }
        return DigestAlgorithm(oid: oid)
    }
}

/// An INTEGER's content bytes in their shortest form, so two encodings of one number compare equal.
func canonicalInteger(_ b: [UInt8]) -> [UInt8] {
    var s = b[...]
    while s.count > 1 && ((s[s.startIndex] == 0 && s[s.startIndex + 1] & 0x80 == 0) || (s[s.startIndex] == 0xFF && s[s.startIndex + 1] & 0x80 != 0)) {
        s = s.dropFirst()
    }
    return Array(s)
}

enum OcspCertStatus { case good, revoked, unknown }

/// One certificate's answer in an OCSP response.
struct OcspSingle {
    let hashOid: String
    let issuerNameHash: [UInt8]
    let issuerKeyHash: [UInt8]
    let serial: [UInt8]
    let status: OcspCertStatus
    let thisUpdate: Date
    let nextUpdate: Date?
    let revokedAt: Date?
}

/// A parsed OCSP response (RFC 6960), whole so it can be stored as is (the Windows app's `OcspResponse`).
final class OcspResponse {
    private static let maxSingles = 64
    private static let maxCerts = 8

    let der: [UInt8]
    let tbs: [UInt8]
    let algorithm: [UInt8]
    let signature: [UInt8]
    let producedAt: Date
    let singles: [OcspSingle]
    let certs: [Certificate]

    private init(der: [UInt8], tbs: [UInt8], algorithm: [UInt8], signature: [UInt8], producedAt: Date, singles: [OcspSingle], certs: [Certificate]) {
        self.der = der
        self.tbs = tbs
        self.algorithm = algorithm
        self.signature = signature
        self.producedAt = producedAt
        self.singles = singles
        self.certs = certs
    }

    /// The DER of a request for one certificate: SHA-1 CertID, as RFC 5019 asks, and no nonce (the answer is kept as
    /// evidence and judged by its dates).
    static func request(_ cert: Certificate, _ issuer: Certificate) -> [UInt8] {
        let id = DerWriter.seq([DerWriter.seq([DerWriter.oid(DigestAlgorithm.sha1.oid), DerWriter.null]),
                                DerWriter.octets(DigestAlgorithm.sha1.hash(cert.issuerRaw)),
                                DerWriter.octets(DigestAlgorithm.sha1.hash(issuer.publicKeyBits)),
                                DerWriter.tlv(0x02, cert.serial)])
        return DerWriter.seq([DerWriter.seq([DerWriter.seq([DerWriter.seq([id])])])])
    }

    /// The response, or the problem when it isn't a successful basic response or can't be read.
    static func parse(_ der: [UInt8]) -> (response: OcspResponse?, problem: String?) {
        do {
            let outer = try Der.parse(der).children()
            guard outer.count >= 1, outer[0].tag == 0x0A, outer[0].content.count == 1 else { return (nil, loc("the response can't be read")) }
            switch outer[0].content[0] {
            case 0: break
            case 3: return (nil, loc("the responder says to try later"))
            case 6: return (nil, loc("the responder doesn't answer for this certificate"))
            default: return (nil, loc("the responder reported an error"))
            }
            guard outer.count >= 2, outer[1].tag == 0xA0 else { return (nil, loc("the response can't be read")) }
            let bytes = try outer[1].child(0).children()
            guard bytes.count >= 2, try bytes[0].oid() == Oids.ocspBasic else { return (nil, loc("the response is of an unknown kind")) }
            let basic = try Der.parse(try bytes[1].octets()).children()
            guard basic.count >= 3, basic[2].tag == 0x03 else { throw Der.Malformed() }
            var certs: [Certificate] = []
            if basic.count > 3, basic[3].tag == 0xA0 {
                for c in try basic[3].child(0).children().prefix(maxCerts) { certs.append(try Certificate(der: c.raw)) }
            }
            var tbs = try basic[0].children()
            if tbs.first?.tag == 0xA0 { tbs.removeFirst() } // version
            guard tbs.count >= 3 else { throw Der.Malformed() }
            // tbs[0] is the responderID: the signature check is what counts.
            let produced = try tbs[1].time()
            var singles: [OcspSingle] = []
            for s in try tbs[2].children().prefix(maxSingles) { singles.append(try single(s)) }
            return (OcspResponse(der: der, tbs: basic[0].raw, algorithm: basic[1].raw, signature: Array(basic[2].content.dropFirst()),
                                 producedAt: produced, singles: singles, certs: certs), nil)
        } catch {
            return (nil, loc("the response can't be read"))
        }
    }

    private static func single(_ node: Der) throws -> OcspSingle {
        let s = try node.children()
        guard s.count >= 3 else { throw Der.Malformed() }
        let id = try s[0].children()
        guard id.count == 4, id[1].tag == 0x04, id[2].tag == 0x04, id[3].tag == 0x02 else { throw Der.Malformed() }
        let hashOid = try id[0].child(0).oid()
        var status = OcspCertStatus.unknown
        var revokedAt: Date?
        switch s[1].tag {
        case 0x80: status = .good
        case 0xA1:
            status = .revoked
            revokedAt = try s[1].child(0).time()
        default: break
        }
        let thisUpdate = try s[2].time()
        let nextUpdate = s.count > 3 && s[3].tag == 0xA0 ? try s[3].child(0).time() : nil
        return OcspSingle(hashOid: hashOid, issuerNameHash: id[1].content, issuerKeyHash: id[2].content, serial: canonicalInteger(id[3].content),
                          status: status, thisUpdate: thisUpdate, nextUpdate: nextUpdate, revokedAt: revokedAt)
    }

    /// The answer about `cert` issued by `issuer`, when this response holds one.
    func answer(for cert: Certificate, _ issuer: Certificate) -> OcspSingle? {
        let serial = canonicalInteger(cert.serial)
        for s in singles where s.serial == serial {
            guard let hash = DigestAlgorithm(oid: s.hashOid) else { continue }
            if s.issuerNameHash == hash.hash(cert.issuerRaw) && s.issuerKeyHash == hash.hash(issuer.publicKeyBits) { return s }
        }
        return nil
    }

    /// Who signed this response for `issuer`: the issuer itself (`responder` nil), or a responder it delegated to
    /// (issued by it, for OCSP signing, valid when the response was made). Nil `signed` when neither did.
    func signed(for issuer: Certificate, known: [Certificate]) -> (signed: Bool, responder: Certificate?) {
        if DerSignature.verify(issuer, algorithm, tbs, signature) { return (true, nil) }
        // Only those its issuer issued for OCSP signing, then a few: many unrelated certificates in a store can't push the
        // responder out of reach.
        let candidates = (certs + known).filter { $0.issuerRaw == issuer.subjectRaw && CertFacts.hasEku($0, Oids.ocspSigning) }
        for c in candidates.prefix(Self.maxCerts * 4) {
            guard producedAt >= c.notBefore && producedAt <= c.notAfter else { continue }
            if DerSignature.verify(c, algorithm, tbs, signature) && CertFacts.signedBy(c, issuer) { return (true, c) }
        }
        return (false, nil)
    }
}

/// A parsed certificate revocation list (RFC 5280), whole so it can be stored as is. Its entries are scanned when asked,
/// not kept (the Windows app's `CrlDocument`).
final class CrlDocument {
    let der: [UInt8]
    let tbs: [UInt8]
    let algorithm: [UInt8]
    let signature: [UInt8]
    let issuerName: [UInt8]
    let thisUpdate: Date
    let nextUpdate: Date?
    private let entries: [UInt8]?
    private let onlyUsers: Bool
    private let onlyCas: Bool
    private let unusable: Bool

    private init(der: [UInt8], tbs: [UInt8], algorithm: [UInt8], signature: [UInt8], issuerName: [UInt8], thisUpdate: Date, nextUpdate: Date?,
                 entries: [UInt8]?, onlyUsers: Bool, onlyCas: Bool, unusable: Bool) {
        self.der = der
        self.tbs = tbs
        self.algorithm = algorithm
        self.signature = signature
        self.issuerName = issuerName
        self.thisUpdate = thisUpdate
        self.nextUpdate = nextUpdate
        self.entries = entries
        self.onlyUsers = onlyUsers
        self.onlyCas = onlyCas
        self.unusable = unusable
    }

    static func parse(_ der: [UInt8]) -> CrlDocument? {
        do {
            let outer = try Der.parse(der)
            // The list itself, then its algorithm and signature: read one at a time, so a large list isn't copied per child.
            let (tbsNode, afterTbs) = try Der.read(outer.content, at: 0)
            let (algNode, afterAlg) = try Der.read(outer.content, at: afterTbs)
            let (sigNode, _) = try Der.read(outer.content, at: afterAlg)
            guard outer.tag == 0x30, tbsNode.tag == 0x30, sigNode.tag == 0x03 else { return nil }
            var at = 0
            let body = tbsNode.content
            func next() throws -> Der? {
                guard at < body.count else { return nil }
                let (d, n) = try Der.read(body, at: at)
                at = n
                return d
            }
            var item = try next()
            if item?.tag == 0x02 { item = try next() } // version
            // item: the signature's algorithm, again
            guard let issuer = try next(), issuer.tag == 0x30, let first = try next(), first.tag == 0x17 || first.tag == 0x18 else { return nil }
            let thisUpdate = try first.time()
            var nextUpdate: Date?
            item = try next()
            if let t = item, t.tag == 0x17 || t.tag == 0x18 {
                nextUpdate = try t.time()
                item = try next()
            }
            var entries: [UInt8]?
            if let e = item, e.tag == 0x30 {
                entries = e.content
                item = try next()
            }
            var onlyUsers = false, onlyCas = false, unusable = false
            if let x = item, x.tag == 0xA0 {
                for ext in try x.child(0).children() {
                    let p = try ext.children()
                    guard p.count >= 2 else { continue }
                    let oid = try p[0].oid()
                    let critical = p.count == 3 && p[1].tag == 0x01 && p[1].content.first.map { $0 != 0 } == true
                    let value = p[p.count - 1]
                    if oid == "2.5.29.27" { unusable = true } // a delta list says nothing alone
                    else if oid == "2.5.29.28" { readScope(try value.octets(), &onlyUsers, &onlyCas, &unusable) }
                    else if critical { unusable = true }
                }
            }
            return CrlDocument(der: der, tbs: tbsNode.raw, algorithm: algNode.raw, signature: Array(sigNode.content.dropFirst()), issuerName: issuer.raw,
                               thisUpdate: thisUpdate, nextUpdate: nextUpdate, entries: entries, onlyUsers: onlyUsers, onlyCas: onlyCas, unusable: unusable)
        } catch {
            return nil
        }
    }

    /// IssuingDistributionPoint: which certificates the list speaks for (attribute and indirect lists aren't used).
    private static func readScope(_ value: [UInt8], _ onlyUsers: inout Bool, _ onlyCas: inout Bool, _ unusable: inout Bool) {
        guard let idp = try? Der.parse(value).children() else {
            unusable = true
            return
        }
        for d in idp {
            let on = d.content.first.map { $0 != 0 } == true
            switch d.tag {
            case 0x81: onlyUsers = on
            case 0x82: onlyCas = on
            case 0x83, 0xA3: unusable = true // only some reasons: can't vouch for a certificate alone
            case 0x84, 0x85: if on { unusable = true }
            default: break
            }
        }
    }

    /// The list was issued by `issuer`'s name and key, and speaks for `cert`.
    func speaks(for cert: Certificate, _ issuer: Certificate) -> Bool {
        if unusable || issuerName != issuer.subjectRaw { return false }
        if onlyUsers && cert.isCa { return false }
        if onlyCas && !cert.isCa { return false }
        return DerSignature.verify(issuer, algorithm, tbs, signature)
    }

    /// Whether the list names `cert` as revoked (not when taken off hold), and when; a date that can't be read is nil.
    func revocation(of cert: Certificate) -> (listed: Bool, at: Date?) {
        guard let entries else { return (false, nil) }
        let wanted = canonicalInteger(cert.serial)
        var at = 0
        // The signature checked out, so the issuer wrote this; an entry that can't be read says nothing.
        while at < entries.count {
            guard let (entry, next) = try? Der.read(entries, at: at), let parts = try? entry.children(), parts.count >= 2 else { return (false, nil) }
            at = next
            guard parts[0].tag == 0x02, canonicalInteger(parts[0].content) == wanted else { continue }
            if parts.count > 2 && Self.removedFromHold(parts[2]) { return (false, nil) }
            return (true, try? parts[1].time())
        }
        return (false, nil)
    }

    private static func removedFromHold(_ exts: Der) -> Bool {
        guard exts.tag == 0x30 else { return false }
        for ext in (try? exts.children()) ?? [] {
            guard let p = try? ext.children(), p.count >= 2, (try? p[0].oid()) == "2.5.29.21", let value = try? p[p.count - 1].octets() else { continue }
            return value.count == 3 && value[2] == 8 // removeFromCRL
        }
        return false
    }
}

/// What is known about one certificate's revocation.
enum RevocationAnswer {
    /// No usable data.
    case none
    /// A verified response or list says it wasn't revoked at the time asked about.
    case good
    /// A verified response or list says it was revoked at or before the time asked about.
    case revoked
    /// A verified response or list says it was revoked, after the time asked about.
    case revokedLater
    /// The responder doesn't know the certificate.
    case unknown
    /// There is data, but too old to speak for the time asked about.
    case stale

    var settles: Bool { self == .good || self == .revoked || self == .revokedLater }
}

/// One check's outcome: the answer, when revoked, the delegated responder that answered, and the data it came from.
struct RevocationVerdict {
    var answer: RevocationAnswer
    var revokedAt: Date?
    var responder: Certificate?
    var evidence: [UInt8]?
}

/// The certificates, OCSP responses and CRLs a check may use: from the file's /DSS, a signature's own archived data, or
/// asked for online by the person (the Windows app's `RevocationPool`). Everything in here came from the file or from a
/// server that a file's certificate named, so it is treated as hostile: sizes and counts are limited on the way in,
/// nothing counts until its signature checks out against the issuer of the certificate it speaks for, and a time budget
/// ends the work on a file built to make it long.
final class RevocationPool: @unchecked Sendable {
    static let maxCertBytes = 64 * 1024
    static let maxOcspBytes = 256 * 1024
    static let maxCrlBytes = 16 * 1024 * 1024
    private static let maxTotalBytes = 64 * 1024 * 1024
    private static let maxCerts = 256
    private static let maxResponses = 256
    private static let maxChecksPerCertificate = 8
    /// How long one file's data may keep a check busy.
    private static let budget: Double = 20

    private(set) var certs: [Certificate] = []
    private var certHashes = Set<[UInt8]>()
    private(set) var ocsps: [OcspResponse] = []
    private(set) var crls: [CrlDocument] = []
    private var hashes = Set<[UInt8]>()
    private var memo: [String: RevocationVerdict] = [:]
    private var started = DispatchTime.now().uptimeNanoseconds
    private var bytes = 0
    /// Data the limits or a parse left out.
    private(set) var skipped = 0

    /// The file asked for more work than a check does, so what is reported isn't complete.
    var outOfBudget: Bool { Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9 > Self.budget }

    /// The budget is for this data, not for whatever else a large file took to read first.
    func restartBudget() { started = DispatchTime.now().uptimeNanoseconds }

    func addCert(_ der: [UInt8]) {
        if der.count > Self.maxCertBytes || certs.count >= Self.maxCerts {
            skipped += 1
            return
        }
        guard certHashes.insert(DigestAlgorithm.sha256.hash(der)).inserted else { return }
        if let c = try? Certificate(der: der) {
            certs.append(c)
            memo.removeAll() // a new certificate can make an answer verify (a delegated responder)
        } else {
            skipped += 1
        }
    }

    func addCert(_ cert: Certificate) { addCert(cert.der) }

    func addOcsp(_ der: [UInt8]) {
        guard room(der, Self.maxOcspBytes) else { return }
        if let r = OcspResponse.parse(der).response {
            ocsps.append(r)
            for c in r.certs { addCert(c) }
        } else {
            skipped += 1
        }
    }

    func addCrl(_ der: [UInt8]) {
        guard room(der, Self.maxCrlBytes) else { return }
        if let c = CrlDocument.parse(der) { crls.append(c) } else { skipped += 1 }
    }

    private func room(_ der: [UInt8], _ max: Int) -> Bool {
        if der.count > max || ocsps.count + crls.count >= Self.maxResponses || bytes + der.count > Self.maxTotalBytes {
            skipped += 1
            return false
        }
        guard hashes.insert(DigestAlgorithm.sha256.hash(der)).inserted else { return false }
        bytes += der.count
        memo.removeAll()
        return true
    }

    func addFrom(_ other: RevocationPool) {
        for c in other.certs { addCert(c) }
        for o in other.ocsps { addOcsp(o.der) }
        for c in other.crls { addCrl(c.der) }
    }

    /// Reads Adobe's revocationInfoArchival value (a signed attribute many Acrobat-made signatures carry): [0] CRLs, [1] OCSP responses.
    func addArchival(_ value: Der) {
        guard let parts = try? value.children() else {
            skipped += 1
            return
        }
        for p in parts where p.tag == 0xA0 || p.tag == 0xA1 {
            guard let items = try? p.child(0).children() else {
                skipped += 1
                continue
            }
            for item in items {
                if p.tag == 0xA0 { addCrl(item.raw) } else { addOcsp(item.raw) }
            }
        }
    }

    /// What the verified data says about `cert` at `when`; a revocation at or before that time, or after it, wins over any
    /// good answer. Also which responder answered, when one was delegated, and the data it came from.
    func check(_ cert: Certificate, _ issuer: Certificate, _ when: Date) -> RevocationVerdict {
        let key = "\(cert.thumbprint)|\(issuer.thumbprint)|\(when.timeIntervalSince1970.bitPattern)"
        if let seen = memo[key] { return seen }
        let result = checkCore(cert, issuer, when)
        memo[key] = result
        return result
    }

    private func checkCore(_ cert: Certificate, _ issuer: Certificate, _ when: Date) -> RevocationVerdict {
        var best = RevocationVerdict(answer: .none)
        let now = Date() + 300
        var checks = 0
        for r in ocsps {
            if outOfBudget || checks >= Self.maxChecksPerCertificate { break }
            guard let a = r.answer(for: cert, issuer), a.thisUpdate <= now else { continue }
            let signed = r.signed(for: issuer, known: certs)
            guard signed.signed else { continue }
            checks += 1 // only what verifies: forgeries can't use up the turns of a real answer (the time budget ends a file full of them)
            switch a.status {
            case .revoked:
                if let at = a.revokedAt, at > when {
                    best = Self.rank(best, RevocationVerdict(answer: .revokedLater, revokedAt: at, responder: signed.responder, evidence: r.der))
                } else {
                    return RevocationVerdict(answer: .revoked, revokedAt: a.revokedAt, responder: signed.responder, evidence: r.der)
                }
            case .unknown:
                best = Self.rank(best, RevocationVerdict(answer: .unknown, responder: signed.responder, evidence: r.der))
            case .good:
                best = Self.rank(best, RevocationVerdict(answer: Self.covers(a.thisUpdate, a.nextUpdate, when) ? .good : .stale, responder: signed.responder, evidence: r.der))
            }
        }
        checks = 0
        for c in crls {
            if outOfBudget || checks >= Self.maxChecksPerCertificate { break }
            guard c.issuerName == issuer.subjectRaw, c.thisUpdate <= now, c.speaks(for: cert, issuer) else { continue }
            checks += 1
            let listed = c.revocation(of: cert)
            if listed.listed, let at = listed.at {
                if at > when {
                    best = Self.rank(best, RevocationVerdict(answer: .revokedLater, revokedAt: at, evidence: c.der))
                } else {
                    return RevocationVerdict(answer: .revoked, revokedAt: at, evidence: c.der)
                }
            } else if listed.listed {
                // Listed, its date unreadable: revoked, when unknown.
                return RevocationVerdict(answer: .revoked, evidence: c.der)
            } else {
                best = Self.rank(best, RevocationVerdict(answer: Self.covers(c.thisUpdate, c.nextUpdate, when) ? .good : .stale, evidence: c.der))
            }
        }
        return best
    }

    /// The data was issued after the time asked about, or was still in force then.
    private static func covers(_ thisUpdate: Date, _ nextUpdate: Date?, _ when: Date) -> Bool {
        thisUpdate >= when || (nextUpdate.map { $0 >= when } ?? false)
    }

    private static func rank(_ a: RevocationVerdict, _ b: RevocationVerdict) -> RevocationVerdict {
        func weight(_ x: RevocationAnswer) -> Int {
            switch x {
            case .revokedLater: 4
            case .good: 3
            case .unknown: 2
            case .stale: 1
            default: 0
            }
        }
        return weight(b.answer) > weight(a.answer) ? b : a
    }

    /// The certificates in `pool` that can be part of `cert`'s chain (their subject is an issuer on the way up), so that
    /// a thousand unrelated or looping certificates in a hostile file never reach the chain builder.
    static func chainCandidates(_ cert: Certificate, _ pool: [Certificate]) -> [Certificate] {
        let maxCandidates = 32
        var bySubject: [[UInt8]: [Certificate]] = [:]
        for c in pool where (bySubject[c.subjectRaw]?.count ?? 0) < 4 { bySubject[c.subjectRaw, default: []].append(c) }
        var result: [Certificate] = []
        var names = [cert.issuerRaw]
        var seen = Set<[UInt8]>()
        var i = 0
        while i < names.count && result.count < maxCandidates {
            let name = names[i]
            i += 1
            guard seen.insert(name).inserted, let found = bySubject[name] else { continue }
            for c in found {
                result.append(c)
                names.append(c.issuerRaw)
            }
        }
        return result
    }

    /// `cert`'s chain as far as what is at hand and the Mac's keychains reach, end certificate first. Never goes online:
    /// a chain build is the one thing that would otherwise follow addresses a file's certificates name.
    static func buildChain(_ cert: Certificate, _ pool: [Certificate], at: Date? = nil, anchors: [Certificate]? = nil) -> [Certificate] {
        guard let sec = cert.secCertificate else { return [cert] }
        let others = chainCandidates(cert, pool).filter { $0 != cert }.compactMap(\.secCertificate)
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(([sec] + others) as CFArray, SecPolicyCreateBasicX509(), &made) == errSecSuccess, let trust = made else { return [cert] }
        Signatures.forbidNetwork(trust)
        if let at { SecTrustSetVerifyDate(trust, at as CFDate) }
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors.compactMap(\.secCertificate) as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        _ = SecTrustEvaluateWithError(trust, &error)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).compactMap { try? Certificate(der: Array(SecCertificateCopyData($0) as Data)) }
        return chain.isEmpty ? [cert] : chain
    }
}
