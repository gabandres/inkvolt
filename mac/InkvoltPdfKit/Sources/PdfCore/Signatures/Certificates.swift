import CryptoKit
import Foundation
import Security

/// The hash algorithms signatures use, with their identifiers and Security.framework's signature algorithms.
public enum DigestAlgorithm: String, Sendable, CaseIterable {
    case sha1, sha256, sha384, sha512

    var oid: String {
        switch self {
        case .sha1: "1.3.14.3.2.26"
        case .sha256: "2.16.840.1.101.3.4.2.1"
        case .sha384: "2.16.840.1.101.3.4.2.2"
        case .sha512: "2.16.840.1.101.3.4.2.3"
        }
    }

    init?(oid: String) {
        guard let d = DigestAlgorithm.allCases.first(where: { $0.oid == oid }) else { return nil }
        self = d
    }

    func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        case .sha256: Array(SHA256.hash(data: data))
        case .sha384: Array(SHA384.hash(data: data))
        case .sha512: Array(SHA512.hash(data: data))
        }
    }

    var rsa: SecKeyAlgorithm {
        switch self {
        case .sha1: .rsaSignatureMessagePKCS1v15SHA1
        case .sha256: .rsaSignatureMessagePKCS1v15SHA256
        case .sha384: .rsaSignatureMessagePKCS1v15SHA384
        case .sha512: .rsaSignatureMessagePKCS1v15SHA512
        }
    }

    var rsaPss: SecKeyAlgorithm {
        switch self {
        case .sha1: .rsaSignatureMessagePSSSHA1
        case .sha256: .rsaSignatureMessagePSSSHA256
        case .sha384: .rsaSignatureMessagePSSSHA384
        case .sha512: .rsaSignatureMessagePSSSHA512
        }
    }

    var ecdsa: SecKeyAlgorithm {
        switch self {
        case .sha1: .ecdsaSignatureMessageX962SHA1
        case .sha256: .ecdsaSignatureMessageX962SHA256
        case .sha384: .ecdsaSignatureMessageX962SHA384
        case .sha512: .ecdsaSignatureMessageX962SHA512
        }
    }

    /// The signature algorithm identifier a certificate signed with this hash names (sha256WithRSAEncryption …).
    func signatureOid(ec: Bool) -> String {
        switch self {
        case .sha1: ec ? "1.2.840.10045.4.1" : "1.2.840.113549.1.1.5"
        case .sha256: ec ? "1.2.840.10045.4.3.2" : "1.2.840.113549.1.1.11"
        case .sha384: ec ? "1.2.840.10045.4.3.3" : "1.2.840.113549.1.1.12"
        case .sha512: ec ? "1.2.840.10045.4.3.4" : "1.2.840.113549.1.1.13"
        }
    }
}

/// An X.509 certificate, read from its DER (the parts .NET's `X509Certificate2` gives the Windows app).
public struct Certificate: Sendable, Hashable {
    public let der: [UInt8]
    /// The INTEGER's content bytes, as encoded.
    let serial: [UInt8]
    let issuerRaw: [UInt8]
    let subjectRaw: [UInt8]
    public let notBefore: Date
    public let notAfter: Date
    /// rsaEncryption or ecPublicKey.
    let keyAlgorithm: String
    let curve: String?
    /// The RSA modulus or the EC curve size in bits.
    public let keyBits: Int
    /// The KeyUsage bits (bit 0, digitalSignature, is 0x80 of the first byte), nil without the extension.
    let keyUsage: [UInt8]?
    /// The extended key usages, nil without the extension.
    public let extendedKeyUsages: [String]?
    let subjectKeyId: [UInt8]?
    let subjectNames: [(oid: String, value: String)]
    let issuerNames: [(oid: String, value: String)]

    public init(der: [UInt8]) throws {
        self.der = der
        let cert = try Der.parse(der)
        let tbs = try cert.child(0).children()
        var i = 0
        if tbs.first?.context == 0 { i = 1 }
        guard tbs.count >= i + 6 else { throw Der.Malformed() }
        serial = tbs[i].content
        issuerRaw = tbs[i + 2].raw
        let validity = try tbs[i + 3].children()
        guard validity.count == 2 else { throw Der.Malformed() }
        notBefore = try validity[0].time()
        notAfter = try validity[1].time()
        subjectRaw = tbs[i + 4].raw
        subjectNames = try Certificate.names(tbs[i + 4])
        issuerNames = try Certificate.names(tbs[i + 2])
        let spki = try tbs[i + 5].children()
        let alg = try spki[0].children()
        keyAlgorithm = try alg[0].oid()
        curve = alg.count > 1 && alg[1].tag == 0x06 ? try alg[1].oid() : nil
        if keyAlgorithm == Oids.rsa, spki.count > 1, spki[1].content.count > 1 {
            let modulus = try Der.parse(Array(spki[1].content.dropFirst())).child(0).content.drop { $0 == 0 }
            keyBits = modulus.count * 8 - (modulus.first.map { $0.leadingZeroBitCount } ?? 0)
        } else {
            keyBits = curve == Oids.p384 ? 384 : curve == Oids.p521 ? 521 : 256
        }
        var ku: [UInt8]?, eku: [String]?, ski: [UInt8]?
        if let ext = tbs.dropFirst(i + 6).first(where: { $0.context == 3 }) {
            for e in try ext.child(0).children() {
                let parts = try e.children()
                guard let id = try? parts.first?.oid(), let value = parts.last, value.tag == 0x04 else { continue }
                let inner = try Der.parse(value.content)
                switch id {
                case Oids.keyUsage: ku = Array(inner.content.dropFirst())
                case Oids.extendedKeyUsage: eku = try inner.children().map { try $0.oid() }
                case Oids.subjectKeyId: ski = inner.content
                default: break
                }
            }
        }
        keyUsage = ku
        extendedKeyUsages = eku
        subjectKeyId = ski
    }

    public static func == (a: Certificate, b: Certificate) -> Bool { a.der == b.der }
    public func hash(into h: inout Hasher) { h.combine(der) }

    private static func names(_ name: Der) throws -> [(oid: String, value: String)] {
        var list: [(String, String)] = []
        for rdn in try name.children() {
            for atv in try rdn.children() {
                let p = try atv.children()
                guard p.count == 2 else { continue }
                list.append((try p[0].oid(), p[1].string() ?? ""))
            }
        }
        return list
    }

    /// The subject's common name (.NET's `GetNameInfo(SimpleName)`: else the organization, else the email).
    public var commonName: String? { Certificate.simple(subjectNames) }
    public var issuerCommonName: String? { Certificate.simple(issuerNames) }

    private static func simple(_ names: [(oid: String, value: String)]) -> String? {
        for oid in [Oids.commonName, "2.5.4.11", Oids.organization, Oids.email] {
            if let v = names.last(where: { $0.oid == oid })?.value, !v.isEmpty { return v }
        }
        return nil
    }

    /// The subject as .NET writes it: "CN=Ada, O=Example" (the last name first).
    public var subject: String { Certificate.distinguished(subjectNames) }

    private static func distinguished(_ names: [(oid: String, value: String)]) -> String {
        let short = [Oids.commonName: "CN", Oids.organization: "O", "2.5.4.11": "OU", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "S",
                     Oids.email: "E"]
        return names.reversed().map { "\(short[$0.oid] ?? "OID.\($0.oid)")=\($0.value)" }.joined(separator: ", ")
    }

    var isSelfIssued: Bool { subjectRaw == issuerRaw }

    /// The SHA-1 fingerprint Keychain Access shows ("AB CD …").
    public var fingerprint: String { DigestAlgorithm.sha1.hash(der).map { String(format: "%02X", $0) }.joined(separator: " ") }
    var isEc: Bool { keyAlgorithm == Oids.ecPublicKey }

    /// May sign (KeyUsage absent, or digitalSignature or nonRepudiation set).
    var allowsSignatures: Bool {
        guard let ku = keyUsage else { return true }
        return (ku.first ?? 0) & 0xC0 != 0
    }

    var secCertificate: SecCertificate? { SecCertificateCreateWithData(nil, Data(der) as CFData) }
    var publicKey: SecKey? { secCertificate.flatMap { SecCertificateCopyKey($0) } }

    /// SHA-256, or SHA-384/512 for EC keys on P-384/P-521 (matching the curve's strength; .NET's `Signing.DigestFor`).
    var digest: DigestAlgorithm { isEc && keyBits == 384 ? .sha384 : isEc && keyBits == 521 ? .sha512 : .sha256 }
}

/// Makes certificates (.NET's `CertificateRequest`): personal IDs, and the tests' signers and timestamp authority.
struct CertificateBuilder {
    /// The subject, most specific first ("CN" before "O"), as .NET's distinguished-name strings read.
    var subject: [(oid: String, value: String)]
    var notBefore: Date
    var notAfter: Date
    /// KeyUsage bits (0x80 digitalSignature, 0x40 nonRepudiation), critical; nil leaves the extension out.
    var keyUsage: UInt8?
    var extendedKeyUsages: [String]?
    var ekuCritical = false
    var endEntity = false
    var subjectKeyId = false
    var email: String?

    func selfSigned(_ key: SecKey) throws -> Certificate {
        let spki = try KeyEncoding.subjectPublicKeyInfo(key)
        let ec = KeyEncoding.isEc(key)
        let digest: DigestAlgorithm = ec && KeyEncoding.bits(key) == 384 ? .sha384 : ec && KeyEncoding.bits(key) == 521 ? .sha512 : .sha256
        let sigAlg = DerWriter.seq(ec ? [DerWriter.oid(digest.signatureOid(ec: true))] : [DerWriter.oid(digest.signatureOid(ec: false)), DerWriter.null])
        let name = DerWriter.seq(subject.reversed().map { n in
            DerWriter.setOf([DerWriter.seq([DerWriter.oid(n.oid), n.oid == Oids.email ? DerWriter.ia5(n.value) : DerWriter.utf8(n.value)])])
        })
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] = (serial[0] & 0x7F) | 0x01
        var exts: [[UInt8]] = []
        func ext(_ oid: String, _ critical: Bool, _ value: [UInt8]) {
            exts.append(DerWriter.seq([DerWriter.oid(oid)] + (critical ? [DerWriter.bool(true)] : []) + [DerWriter.octets(value)]))
        }
        if endEntity { ext(Oids.basicConstraints, true, DerWriter.seq([])) }
        if let ku = keyUsage {
            let unused = UInt8(ku.trailingZeroBitCount)
            ext(Oids.keyUsage, true, DerWriter.bits([ku], unused: unused))
        }
        if let ekus = extendedKeyUsages { ext(Oids.extendedKeyUsage, ekuCritical, DerWriter.seq(ekus.map(DerWriter.oid))) }
        if subjectKeyId {
            let bits = try Der.parse(spki).child(1).content.dropFirst()
            ext(Oids.subjectKeyId, false, DerWriter.octets(DigestAlgorithm.sha1.hash(Array(bits))))
        }
        if let email { ext(Oids.subjectAltName, false, DerWriter.seq([DerWriter.tlv(0x81, Array(email.utf8))])) }
        var tbs: [[UInt8]] = [DerWriter.context(0, DerWriter.int(2)), DerWriter.unsigned(serial), sigAlg, name,
                              DerWriter.seq([DerWriter.time(notBefore), DerWriter.time(notAfter)]), name, spki]
        if !exts.isEmpty { tbs.append(DerWriter.context(3, DerWriter.seq(exts))) }
        let tbsDer = DerWriter.seq(tbs)
        let signature = try KeyEncoding.sign(key, tbsDer, digest)
        return try Certificate(der: DerWriter.seq([tbsDer, sigAlg, DerWriter.bits(signature)]))
    }
}

/// Keys through Security.framework: their public halves as X.509 encodes them, and signing.
enum KeyEncoding {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        let cancelled: Bool
    }

    static func isEc(_ key: SecKey) -> Bool {
        let attrs = SecKeyCopyAttributes(key) as? [CFString: Any]
        return (attrs?[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String)
    }

    static func bits(_ key: SecKey) -> Int {
        let attrs = SecKeyCopyAttributes(key) as? [CFString: Any]
        return (attrs?[kSecAttrKeySizeInBits] as? Int) ?? 0
    }

    /// A new key kept in memory only (not in a keychain).
    static func ephemeral(rsaBits: Int? = nil, ecBits: Int? = nil) throws -> SecKey {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: ecBits != nil ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: ecBits ?? rsaBits ?? 2048,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else { throw failure(error, "The key can't be made") }
        return key
    }

    static func subjectPublicKeyInfo(_ key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        let pub = SecKeyCopyPublicKey(key) ?? key
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw failure(error, "The key can't be read") }
        if isEc(key) {
            let curve = switch bits(key) {
            case 384: Oids.p384
            case 521: Oids.p521
            default: Oids.p256
            }
            return DerWriter.seq([DerWriter.seq([DerWriter.oid(Oids.ecPublicKey), DerWriter.oid(curve)]), DerWriter.bits(Array(data))])
        }
        return DerWriter.seq([DerWriter.seq([DerWriter.oid(Oids.rsa), DerWriter.null]), DerWriter.bits(Array(data))])
    }

    /// The signature of `message` hashed with `digest` (PKCS #1 v1.5 for RSA, X9.62 DER for EC).
    static func sign(_ key: SecKey, _ message: [UInt8], _ digest: DigestAlgorithm) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, isEc(key) ? digest.ecdsa : digest.rsa, Data(message) as CFData, &error) as Data? else {
            throw failure(error, "The digital ID couldn't sign")
        }
        return Array(sig)
    }

    static func verify(_ key: SecKey, _ algorithm: SecKeyAlgorithm, _ message: [UInt8], _ signature: [UInt8]) -> Bool {
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(key, algorithm, Data(message) as CFData, Data(signature) as CFData, &error)
    }

    static func failure(_ error: Unmanaged<CFError>?, _ what: String) -> Failure {
        let e = error?.takeRetainedValue()
        let code = e.map { CFErrorGetCode($0) } ?? 0
        let text = e.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
        return Failure(description: "\(what): \(text)", cancelled: code == Int(errSecUserCanceled))
    }
}
