import Foundation

/// The phone scan's and the shared scanner's self-signed TLS certificate, as DER (roadmap 4.6, 3.1; the Windows Core's `ShareCertificate.Create`, which
/// .NET's `CertificateRequest` writes): X.509 v3 for an ECDSA P-256 key, signed with ECDSA-SHA256, the subject and issuer
/// `subject`, valid from a day before it's made for `life` (Apple's limit for a TLS server certificate, so an Apple client
/// never refuses it for its length), not a CA, for digital signatures and TLS servers only, named for this Mac's `.local`
/// name. PrintMac makes the key in the keychain and signs `tbs`; a phone can't check it against anyone, so the Mac shows
/// its fingerprint beside the code.
public enum PhoneCertificateDer {
    /// One certificate serves the phone scan and the shared scanner, as on Windows. **Mac difference:** its subject stays
    /// the phone scan's (Windows': "Inkvolt Print scanner sharing"): the keychain finds a kept certificate by its label,
    /// which macOS takes from the subject (`PhoneCertificateKeychain.label`), so another subject would orphan the one kept.
    public static let subject = "Inkvolt Print phone scan"
    public static let life: TimeInterval = 825 * 86_400
    /// A certificate this close to its end is made anew (with a new fingerprint).
    public static let renewBefore: TimeInterval = 30 * 86_400

    private static let ecPublicKey: Oid = "1.2.840.10045.2.1", prime256v1: Oid = "1.2.840.10045.3.1.7"
    private static let ecdsaWithSha256: Oid = "1.2.840.10045.4.3.2", commonName: Oid = "2.5.4.3"
    private static let basicConstraints: Oid = "2.5.29.19", keyUsage: Oid = "2.5.29.15", extendedKeyUsage: Oid = "2.5.29.37"
    private static let subjectAltName: Oid = "2.5.29.17", serverAuth: Oid = "1.3.6.1.5.5.7.3.1"

    /// The part that's signed. `publicKey`: the key's X9.63 form (0x04, X, Y: 65 bytes); `serial`: random bytes (made
    /// positive here).
    public static func tbs(publicKey: [UInt8], hostName: String, serial: [UInt8], now: Date) -> [UInt8] {
        precondition(publicKey.count == 65 && publicKey.first == 4, "an uncompressed P-256 point")
        var serialBytes = serial.isEmpty ? [1] : serial
        serialBytes[0] &= 0x7F
        if serialBytes[0] == 0 { serialBytes[0] = 1 }
        let version = Ber.tlv(0xA0, Ber.integer32(2))
        let name = Ber.constructed(Ber.sequence, Ber.tlv(0x31, Ber.constructed(Ber.sequence, Ber.objectId(commonName), Ber.tlv(0x0C, Array(subject.utf8)))))
        let validity = Ber.constructed(Ber.sequence, time(now.addingTimeInterval(-86_400)), time(now.addingTimeInterval(life)))
        let algorithm = Ber.constructed(Ber.sequence, Ber.objectId(ecPublicKey), Ber.objectId(prime256v1))
        let keyInfo = Ber.constructed(Ber.sequence, algorithm, Ber.tlv(0x03, [0] + publicKey))
        let extensions = Ber.tlv(0xA3, Ber.constructed(Ber.sequence, parts: [
            ext(basicConstraints, critical: true, Ber.constructed(Ber.sequence, parts: [])),
            ext(keyUsage, critical: true, Ber.tlv(0x03, [7, 0x80])), // digitalSignature
            ext(extendedKeyUsage, critical: false, Ber.constructed(Ber.sequence, Ber.objectId(serverAuth))),
            ext(subjectAltName, critical: false, Ber.constructed(Ber.sequence, Ber.tlv(0x82, Array(hostName.utf8)))),
        ]))
        return Ber.constructed(Ber.sequence, parts: [version, Ber.tlv(Ber.integer, serialBytes), signatureAlgorithm, name, validity, name, keyInfo, extensions])
    }

    /// The certificate: `tbs`, the algorithm, and the signature (DER ECDSA, as `SecKeyCreateSignature` gives it).
    public static func certificate(tbs: [UInt8], signature: [UInt8]) -> [UInt8] {
        Ber.constructed(Ber.sequence, tbs, signatureAlgorithm, Ber.tlv(0x03, [0] + signature))
    }

    /// Still good to use at `now`: begun, and not yet within `renewBefore` of its end.
    public static func usable(notBefore: Date, notAfter: Date, now: Date) -> Bool {
        notBefore <= now && now.addingTimeInterval(renewBefore) < notAfter
    }

    /// SHA-256 bytes as pairs of hex digits joined by colons.
    public static func fingerprint(_ sha256: [UInt8]) -> String { sha256.map { String(format: "%02X", $0) }.joined(separator: ":") }

    private static var signatureAlgorithm: [UInt8] { Ber.constructed(Ber.sequence, Ber.objectId(ecdsaWithSha256)) }

    private static func ext(_ oid: Oid, critical: Bool, _ value: [UInt8]) -> [UInt8] {
        let parts = [Ber.objectId(oid)] + (critical ? [Ber.tlv(0x01, [0xFF])] : []) + [Ber.octets(value)]
        return Ber.constructed(Ber.sequence, parts: parts)
    }

    /// UTCTime (YYMMDDHHMMSSZ) through 2049, GeneralizedTime after (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 2000
        let rest = [c.month, c.day, c.hour, c.minute, c.second].map { String(format: "%02d", $0 ?? 0) }.joined()
        if year < 2050 { return Ber.tlv(0x17, Array((String(format: "%02d", year % 100) + rest + "Z").utf8)) }
        return Ber.tlv(0x18, Array((String(format: "%04d", year) + rest + "Z").utf8))
    }
}
