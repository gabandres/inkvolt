import Foundation
import Security

/// A CMS SignedData (RFC 5652) read from a ContentInfo (.NET's `SignedCms` on Windows).
struct CmsSignedData {
    let contentType: String
    /// The encapsulated content; nil for a detached signature.
    let content: [UInt8]?
    let certificates: [Certificate]
    let signers: [CmsSignerInfo]

    init(der: [UInt8]) throws {
        let info = try Der.parse(der).children()
        guard info.count == 2, try info[0].oid() == Oids.signedData, info[1].context == 0 else { throw Der.Malformed() }
        let sd = try info[1].child(0).children()
        guard sd.count >= 4 else { throw Der.Malformed() }
        let encap = try sd[2].children()
        contentType = try encap[0].oid()
        content = encap.count > 1 && encap[1].context == 0 ? try encap[1].child(0).octets() : nil
        var certs: [Certificate] = []
        var i = 3
        if sd[i].context == 0 {
            for c in try sd[i].children() where c.tag == 0x30 { if let cert = try? Certificate(der: c.raw) { certs.append(cert) } }
            i += 1
        }
        if i < sd.count && sd[i].context == 1 { i += 1 } // CRLs
        guard i < sd.count else { throw Der.Malformed() }
        certificates = certs
        signers = try sd[i].children().map { try CmsSignerInfo($0) }
    }
}

struct CmsSignerInfo {
    let issuer: [UInt8]?
    let serial: [UInt8]?
    let keyId: [UInt8]?
    let digestOid: String
    /// The [0] signed attributes as encoded; nil when the signature is over the content itself.
    let signedAttributes: Der?
    let signatureAlgorithm: String
    let signature: [UInt8]
    let unsignedAttributes: [(oid: String, values: [Der])]

    init(_ node: Der) throws {
        let p = try node.children()
        guard p.count >= 5 else { throw Der.Malformed() }
        if p[1].tag == 0x30 {
            let ias = try p[1].children()
            guard ias.count == 2 else { throw Der.Malformed() }
            issuer = ias[0].raw
            serial = ias[1].content
            keyId = nil
        } else {
            issuer = nil
            serial = nil
            keyId = p[1].content
        }
        digestOid = try p[2].child(0).oid()
        var i = 3
        if p[i].context == 0 {
            signedAttributes = p[i]
            i += 1
        } else {
            signedAttributes = nil
        }
        guard i + 1 < p.count else { throw Der.Malformed() }
        signatureAlgorithm = try p[i].child(0).oid()
        signature = p[i + 1].content
        var unsigned: [(String, [Der])] = []
        if i + 2 < p.count, p[i + 2].context == 1 {
            for a in try p[i + 2].children() {
                let parts = try a.children()
                guard parts.count == 2 else { continue }
                unsigned.append((try parts[0].oid(), try parts[1].children()))
            }
        }
        unsignedAttributes = unsigned
    }

    var digest: DigestAlgorithm? { DigestAlgorithm(oid: digestOid) }

    /// The values of a signed attribute.
    func signed(_ oid: String) -> [Der]? {
        guard let attrs = try? signedAttributes?.children() else { return nil }
        for a in attrs {
            guard let parts = try? a.children(), parts.count == 2, (try? parts[0].oid()) == oid else { continue }
            return try? parts[1].children()
        }
        return nil
    }

    /// The signing-time signed attribute (what the signer's clock said).
    var signingTime: Date? { (try? signed(Oids.signingTime)?.first?.time()) ?? nil }

    /// The signer's certificate among `certificates` (by issuer and serial number, or subject key identifier).
    func certificate(in certificates: [Certificate]) -> Certificate? {
        func trimmed(_ b: [UInt8]) -> [UInt8] { Array(b.drop { $0 == 0 }) }
        return certificates.first { c in
            if let issuer, let serial { return c.issuerRaw == issuer && trimmed(c.serial) == trimmed(serial) }
            return keyId != nil && c.subjectKeyId == keyId
        }
    }

    /// Checks the signature over `content` (the detached data or the encapsulated content) with the signer's
    /// certificate; nil when it holds, else why not.
    func check(_ content: [UInt8], contentType: String, certificates: [Certificate]) -> (problem: String?, certificate: Certificate?) {
        guard let cert = certificate(in: certificates) else { return ("The signer's certificate isn't in the signature.", nil) }
        guard let digest else { return ("The signature's hash algorithm (\(digestOid)) isn't supported.", cert) }
        var message = content
        if let attrs = signedAttributes {
            guard let md = signed(Oids.messageDigest)?.first, md.tag == 0x04 else { return ("The signature has no message digest.", cert) }
            if md.content != digest.hash(content) { return ("The hash value is not correct.", cert) }
            if let ct = signed(Oids.contentType)?.first, (try? ct.oid()) != contentType { return ("The content type doesn't match.", cert) }
            message = DerWriter.tlv(0x31, attrs.content)
        }
        guard let key = cert.publicKey else { return ("The certificate's key can't be read.", cert) }
        let algorithm: SecKeyAlgorithm = cert.isEc ? digest.ecdsa : signatureAlgorithm == Oids.rsaPss ? digest.rsaPss : digest.rsa
        return KeyEncoding.verify(key, algorithm, message, signature) ? (nil, cert) : ("The signature is not valid.", cert)
    }
}

/// Writes a CMS SignedData with one signer (.NET's `SignedCms.ComputeSignature` with a `CmsSigner`).
struct CmsBuilder {
    let contentType: String
    let encapsulated: [UInt8]?
    let certificates: [Certificate]
    let digest: DigestAlgorithm
    let signer: Certificate
    /// The signed attributes' contents, in DER order (signed as a SET, stored as [0]).
    private let signedAttributes: [UInt8]
    let signature: [UInt8]

    /// Signs `content`: detached unless `encapsulate`. The signed attributes: content type, message digest,
    /// signing-certificate-v2, and the signing time when given.
    init(_ content: [UInt8], encapsulate: Bool = false, contentType: String = Oids.data, signer: Certificate, chain: [Certificate],
         digest: DigestAlgorithm, signingTime: Date?, sign: ([UInt8]) throws -> [UInt8]) throws {
        self.contentType = contentType
        encapsulated = encapsulate ? content : nil
        certificates = [signer] + chain.filter { $0 != signer }
        self.digest = digest
        self.signer = signer
        var attrs = [CmsBuilder.attribute(Oids.contentType, DerWriter.oid(contentType)),
                     CmsBuilder.attribute(Oids.messageDigest, DerWriter.octets(digest.hash(content))),
                     CmsBuilder.attribute(Oids.signingCertificateV2, Signing.signingCertificateV2(signer, digest))]
        if let signingTime { attrs.append(CmsBuilder.attribute(Oids.signingTime, DerWriter.time(signingTime))) }
        let content = attrs.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }
        signedAttributes = content
        signature = try sign(DerWriter.tlv(0x31, content))
    }

    static func attribute(_ oid: String, _ value: [UInt8]) -> [UInt8] { DerWriter.seq([DerWriter.oid(oid), DerWriter.setOf([value])]) }

    /// The ContentInfo, with `unsigned` attributes (a timestamp token) on the signer.
    func encode(unsigned: [[UInt8]] = []) -> [UInt8] {
        let digestAlg = DerWriter.seq([DerWriter.oid(digest.oid)])
        let sigAlg = signer.isEc ? DerWriter.seq([DerWriter.oid(digest.signatureOid(ec: true))]) : DerWriter.seq([DerWriter.oid(Oids.rsa), DerWriter.null])
        let issuerSerial = DerWriter.seq([signer.issuerRaw, DerWriter.tlv(0x02, signer.serial)])
        var info: [[UInt8]] = [DerWriter.int(1), issuerSerial, digestAlg,
                               DerWriter.tlv(0xA0, signedAttributes),
                               sigAlg, DerWriter.octets(signature)]
        if !unsigned.isEmpty { info.append(DerWriter.tlv(0xA1, unsigned.flatMap { $0 })) }
        var encap: [[UInt8]] = [DerWriter.oid(contentType)]
        if let encapsulated { encap.append(DerWriter.context(0, DerWriter.octets(encapsulated))) }
        let sd = DerWriter.seq([DerWriter.int(contentType == Oids.data ? 1 : 3), DerWriter.setOf([digestAlg]), DerWriter.seq(encap),
                                DerWriter.tlv(0xA0, certificates.flatMap(\.der)), DerWriter.setOf([DerWriter.seq(info)])])
        return DerWriter.seq([DerWriter.oid(Oids.signedData), DerWriter.context(0, sd)])
    }
}

/// RFC 3161 timestamps: requests, replies and tokens (.NET's `Rfc3161TimestampRequest` and `Rfc3161TimestampToken`).
enum Rfc3161 {
    struct Token {
        let time: Date
        let cms: CmsSignedData
        let signer: CmsSignerInfo
        let imprintDigest: DigestAlgorithm?
        let imprint: [UInt8]
        let nonce: [UInt8]?

        init(der: [UInt8]) throws {
            cms = try CmsSignedData(der: der)
            guard cms.contentType == Oids.tstInfo, let content = cms.content, let first = cms.signers.first else { throw Der.Malformed() }
            signer = first
            let tst = try Der.parse(content).children()
            guard tst.count >= 5 else { throw Der.Malformed() }
            let mi = try tst[2].children()
            imprintDigest = DigestAlgorithm(oid: try mi[0].child(0).oid())
            imprint = mi[1].content
            time = try tst[4].time()
            nonce = tst.dropFirst(5).first { $0.tag == 0x02 }?.content
        }

        /// The token's own signature holds and it stamps `data` (its message imprint is data's hash): the authority's
        /// certificate, else nil.
        func verify(stamping data: [UInt8], candidates: [Certificate]) -> Certificate? {
            guard let d = imprintDigest, d.hash(data) == imprint, let content = cms.content else { return nil }
            let (problem, cert) = signer.check(content, contentType: Oids.tstInfo, certificates: cms.certificates + candidates)
            return problem == nil ? cert : nil
        }
    }

    /// A TimeStampReq for `data`'s SHA-256 hash, asking for the authority's certificate.
    static func request(_ data: [UInt8], nonce: [UInt8]) -> [UInt8] {
        let imprint = DerWriter.seq([DerWriter.seq([DerWriter.oid(DigestAlgorithm.sha256.oid), DerWriter.null]),
                                     DerWriter.octets(DigestAlgorithm.sha256.hash(data))])
        return DerWriter.seq([DerWriter.int(1), imprint, DerWriter.unsigned(nonce), DerWriter.bool(true)])
    }

    /// The token in a TimeStampResp, checked against the request (granted, the same hash and nonce).
    static func token(fromReply reply: [UInt8], stamping data: [UInt8], nonce: [UInt8]) throws -> (der: [UInt8], token: Token) {
        let resp = try Der.parse(reply).children()
        guard resp.count >= 2 else { throw SigningError("The timestamp server refused the request.") }
        let status = try resp[0].child(0).int()
        guard status == 0 || status == 1 else { throw SigningError("The timestamp server refused the request (status \(status)).") }
        let token = try Token(der: resp[1].raw)
        guard token.imprintDigest?.hash(data) == token.imprint else { throw SigningError("The timestamp is for something else.") }
        if let n = token.nonce, Array(n.drop { $0 == 0 }) != Array(nonce.drop { $0 == 0 }) { throw SigningError("The timestamp's nonce doesn't match.") }
        return (resp[1].raw, token)
    }
}
