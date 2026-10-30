import Foundation
import Security

/// A certificate with its private key, able to sign (.NET's `X509Certificate2` with a private key). On the Mac the key
/// is a Keychain identity's (a software key, or a smart card's through CryptoTokenKit: macOS asks for the PIN or the
/// keychain password when it signs), or one kept in memory only (a test's, a new personal ID before it is saved).
public final class DigitalId: @unchecked Sendable {
    public let certificate: Certificate
    /// The issuers to embed with the signature, end certificate excluded.
    public let chain: [Certificate]
    private let key: SecKey

    init(certificate: Certificate, chain: [Certificate] = [], key: SecKey) {
        self.certificate = certificate
        self.chain = chain
        self.key = key
    }

    /// The signature of `message` hashed with `digest`.
    func sign(_ message: [UInt8], _ digest: DigestAlgorithm) throws -> [UInt8] { try KeyEncoding.sign(key, message, digest) }
}

/// Digital IDs for signing (the Windows app's `DigitalIds`): the user's Keychain identities (software keys, smart
/// cards), .p12 files, and self-signed personal IDs.
public enum DigitalIds {
    public static let documentSigningEku = "1.3.6.1.4.1.311.10.3.12"
    private static let emailProtectionEku = "1.3.6.1.5.5.7.3.4"
    private static let adobeAuthenticDocumentsEku = "1.2.840.113583.1.1.5"
    private static let anyEku = "2.5.29.37.0"

    /// Keychain identities that can sign documents (`isUsable`), by name.
    public static func keychain() -> [DigitalId] {
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [SecIdentity] else { return [] }
        var ids: [DigitalId] = []
        for identity in items {
            var certRef: SecCertificate?, keyRef: SecKey?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let certRef,
                  SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let keyRef,
                  let cert = try? Certificate(der: Array(SecCertificateCopyData(certRef) as Data)), isUsable(cert) else { continue }
            ids.append(DigitalId(certificate: cert, chain: issuers(of: cert), key: keyRef))
        }
        return ids.sorted { ($0.certificate.commonName ?? "").localizedCaseInsensitiveCompare($1.certificate.commonName ?? "") == .orderedAscending }
    }

    /// The issuers SecTrust finds for `cert` (in the keychains), to embed with the signature.
    private static func issuers(of cert: Certificate) -> [Certificate] {
        guard let sec = cert.secCertificate else { return [] }
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(sec, SecPolicyCreateBasicX509(), &made) == errSecSuccess, let trust = made else { return [] }
        SecTrustSetNetworkFetchAllowed(trust, false)
        _ = SecTrustEvaluateWithError(trust, nil)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).compactMap { try? Certificate(der: Array(SecCertificateCopyData($0) as Data)) }
        return chain.filter { $0 != cert }
    }

    /// A certificate fit to sign: currently valid, an RSA or EC key, key usage absent or allowing digital signatures /
    /// non-repudiation, and an extended key usage list (when present) allowing document or email signing (this leaves out
    /// device and login certificates, which only allow client authentication).
    public static func isUsable(_ c: Certificate, now: Date = Date()) -> Bool {
        if c.notBefore > now || c.notAfter < now { return false }
        if c.keyAlgorithm != Oids.rsa && c.keyAlgorithm != Oids.ecPublicKey { return false }
        if !c.allowsSignatures { return false }
        guard let ekus = c.extendedKeyUsages else { return true }
        return ekus.contains { [documentSigningEku, emailProtectionEku, adobeAuthenticDocumentsEku, anyEku].contains($0) }
    }

    /// A new self-signed personal ID (RSA 3072, SHA-256, valid `years`, Document Signing + Email Protection EKUs).
    /// `inKeychain`: the key is made in the login keychain and the certificate added beside it, so the identity is there
    /// for the next signature (and Keychain Access can export it as a .p12 backup); else both stay in memory.
    public static func createPersonal(name: String, email: String?, organization: String?, years: Int = 5, inKeychain: Bool) throws -> DigitalId {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SigningError("A name is required.") }
        let key: SecKey
        if inKeychain {
            let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 3072,
                                          kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrLabel: "\(trimmed) (Inkvolt PDF)"] as CFDictionary]
            var error: Unmanaged<CFError>?
            guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else { throw SigningError(KeyEncoding.failure(error, "The key can't be made").description) }
            key = k
        } else {
            do { key = try KeyEncoding.ephemeral(rsaBits: 3072) } catch { throw SigningError("\(error)") }
        }
        var subject: [(oid: String, value: String)] = [(Oids.commonName, trimmed)]
        let org = organization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !org.isEmpty { subject.append((Oids.organization, org)) }
        if !mail.isEmpty { subject.append((Oids.email, mail)) }
        let now = Date()
        let end = Calendar(identifier: .gregorian).date(byAdding: .year, value: years, to: now) ?? now
        let builder = CertificateBuilder(subject: subject, notBefore: now - 600, notAfter: end, keyUsage: 0xC0,
                                         extendedKeyUsages: [documentSigningEku, emailProtectionEku], endEntity: true, subjectKeyId: true,
                                         email: mail.isEmpty ? nil : mail)
        let cert: Certificate
        do { cert = try builder.selfSigned(key) } catch { throw SigningError("The personal ID can't be made: \(error)") }
        if inKeychain, let sec = cert.secCertificate {
            let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: sec] as CFDictionary, nil)
            if status != errSecSuccess && status != errSecDuplicateItem { throw SigningError("The personal ID can't be saved in the keychain (error \(status)).") }
        }
        return DigitalId(certificate: cert, key: key)
    }

    /// The ID with a private key in a .p12/.pfx file, imported into the login keychain (macOS keeps imported identities
    /// there; Keychain Access shows and removes them).
    public static func importP12(_ data: [UInt8], password: String?) throws -> DigitalId {
        var items: CFArray?
        let status = SecPKCS12Import(Data(data) as CFData, [kSecImportExportPassphrase: password ?? ""] as CFDictionary, &items)
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { throw SigningError("The password for this digital ID file is incorrect.") }
        guard status == errSecSuccess, let list = items as? [[CFString: Any]] else {
            throw SigningError("This file isn't a usable digital ID (error \(status)).")
        }
        for item in list {
            guard let any = item[kSecImportItemIdentity] else { continue }
            let identity = any as! SecIdentity
            var certRef: SecCertificate?, keyRef: SecKey?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let certRef,
                  SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let keyRef,
                  let cert = try? Certificate(der: Array(SecCertificateCopyData(certRef) as Data)) else { continue }
            let chain = (item[kSecImportItemCertChain] as? [SecCertificate] ?? [])
                .compactMap { try? Certificate(der: Array(SecCertificateCopyData($0) as Data)) }.filter { $0 != cert }
            return DigitalId(certificate: cert, chain: chain, key: keyRef)
        }
        throw SigningError("This digital ID file holds no private key.")
    }

    /// A one-line description for pickers: "Name (issuer, expires 2031-10-22)".
    public static func describe(_ c: Certificate) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(c.commonName ?? "") (\(c.isSelfIssued ? "self-signed" : c.issuerCommonName ?? ""), expires \(f.string(from: c.notAfter)))"
    }
}
