import Foundation
import Security

public enum SignatureStatus: Sendable, Equatable {
    /// The signature matches the signed bytes and covers the whole file.
    case valid
    /// The signed bytes were altered, or the signature itself is broken.
    case invalid
    /// The signature is intact and the file was changed after signing (later incremental updates), in ways the signature
    /// permits: form filling, comments, more signatures, metadata (see `SignatureChanges`).
    case modifiedAfterSigning
    /// The signed bytes are intact, but later updates changed the document in a way the signature doesn't permit: page
    /// content, pages added or removed, locked fields, or anything at all after a no-changes certification.
    case disallowedChanges
    /// A signature format not verified here (e.g. adbe.x509.rsa_sha1).
    case unsupported
    /// An empty signature field.
    case unsigned
}

/// One signature field and the result of checking it (the Windows app's `SignatureInfo`).
public struct SignatureInfo: Sendable, Equatable {
    public var fieldName: String
    /// Page of the field's widget, or -1 for an invisible signature.
    public var pageIndex: Int
    /// Widget rect in page space (empty for invisible signatures).
    public var rect: RectD
    public var status: SignatureStatus
    /// Common name of the signing certificate (else the /Name entry).
    public var signerName: String?
    /// The verified timestamp's time, else the signed signing-time attribute, else /M (both as the signer claims).
    public var signingTime: Date?
    public var reason: String?
    public var location: String?
    public var subFilter: String?
    public var coversWholeDocument = false
    /// Carries an RFC 3161 timestamp that belongs to this signature (or is a document timestamp); `detail` says when its
    /// authority isn't trusted.
    public var hasTimestamp = false
    /// The certificate may sign documents and its chain builds to a root this Mac trusts (the system's and the user's
    /// keychains), at the time of a timestamp from a trusted authority, else now.
    public var certificateTrusted = false
    /// "OK" or the chain problems (e.g. "UntrustedRoot, NotTimeValid").
    public var certificateStatus = ""
    /// The certificate's validity period includes the signing time (nil when unknown).
    public var certificateValidAtSigningTime: Bool?
    /// Why a signature is invalid or unsupported, or what else to know (an ignored timestamp, disallowed changes).
    public var detail: String?
    public var certificate: Certificate?
    /// For a certifying signature, its DocMDP permission (1 no changes, 2 form filling and signing, 3 also comments).
    public var certificationLevel: Int?
}

/// Verifies digital signatures on the raw file bytes (the Windows app's `Signatures`): /ByteRange digests and CMS
/// signatures (adbe.pkcs7.detached, ETSI.CAdES.detached, adbe.pkcs7.sha1, ETSI.RFC3161 document timestamps). The CMS is
/// read by PdfCore's own DER reader and its signature checked with Security.framework's keys; certificate trust is
/// Security.framework's `SecTrust` (the Mac's trusted roots); revocation is only checked when asked (it goes online).
public enum Signatures {
    /// The signatures that checked out in `original` (the `verify` result kept from when the file was opened) but no
    /// longer do in `current` (the edited bytes), matched by field name: the UI says "changed by your edits" for these.
    public static func brokenByEdits(_ original: [SignatureInfo], _ current: [UInt8], _ password: String? = nil) -> [SignatureInfo] {
        let intact = original.filter { $0.status == .valid || $0.status == .modifiedAfterSigning }
        if intact.isEmpty { return [] }
        let now = verify(current, password)
        return intact.filter { s in
            let n = now.first { $0.fieldName == s.fieldName }?.status
            return n != .valid && n != .modifiedAfterSigning
        }
    }

    public static func verify(_ data: [UInt8], _ password: String? = nil, online: Bool = false) -> [SignatureInfo] {
        guard let doc = try? PdfEdit.openToRead(data, password),
              let fields = try? FormEditor.collect(doc, doc.catalog.dict("AcroForm")),
              let count = try? doc.pageCount() else { return rawScan(data, online) }
        var pageOf: [UInt: Int] = [:]
        var pages: [PObj] = []
        for p in 0..<count {
            let page = doc.page(p)
            pages.append(page)
            for a in page.array("Annots")?.elements ?? [] where a.isDict && pageOf[a.identity] == nil { pageOf[a.identity] = p }
        }
        var results: [SignatureInfo] = []
        for f in fields where f.type == "Sig" {
            var page = -1
            var rect = RectD.zero
            for w in f.widgets {
                guard let p = pageOf[w.identity], let r = w.array("Rect") else { continue }
                page = p
                rect = PageBoxes.rectToPage(pages[p], r)
                break
            }
            let value = FormEditor.inherited(f.dict, "V")
            if let value, value.isRef, !value.isDict {
                // A signature dictionary that can't be read (damaged, or something slipped into it) is no signature.
                results.append(SignatureInfo(fieldName: f.name, pageIndex: page, rect: rect, status: .invalid, detail: "The signature can't be read."))
                continue
            }
            guard let v = value, v.isDict, let br = v.array("ByteRange"), br.count >= 4 else {
                results.append(SignatureInfo(fieldName: f.name, pageIndex: page, rect: rect, status: .unsigned))
                continue
            }
            let range = (0..<4).map { i -> Int in
                guard let n = br[i]?.number, n.isFinite, n >= 0, n <= Double(data.count), n == n.rounded(.down) else { return -1 }
                return Int(n)
            }
            // A signature followed by later updates: what was signed is the revision its byte range ends at. Its own
            // entries (name, time, reason) are read there, since a later update may have replaced them, and every later
            // change is checked against what the signature permits.
            let signedLength = range[2] >= 0 && range[3] >= 0 ? range[2] + range[3] : -1
            var changes: SignatureChanges.Analysis?
            if signedLength > 0 && signedLength < data.count && !isTrailingWhitespace(data, signedLength) {
                changes = SignatureChanges.analyze(data, signedLength, f.name, password)
            }
            let e = changes?.signed ?? SignatureChanges.entries(of: v)
            var info = check(data, range, e.subFilter, f.name, page, rect, e.name, PdfDates.parse(e.m), e.reason, e.location, online)
            info.certificationLevel = e.certificationLevel
            if info.status == .modifiedAfterSigning, let changes, let problem = changes.problem {
                info.status = changes.permitted ? .modifiedAfterSigning : .disallowedChanges
                info.detail = info.detail.map { "\(problem) \($0)" } ?? problem
            }
            results.append(info)
        }
        return results
    }

    /// Fallback when the file can't be parsed: find /ByteRange entries in the raw bytes.
    private static func rawScan(_ data: [UInt8], _ online: Bool) -> [SignatureInfo] {
        let text = latin1(data)
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: #"/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]"#),
              let sub = try? NSRegularExpression(pattern: #"/SubFilter\s*/([\w.]+)"#) else { return [] }
        var list: [SignatureInfo] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard seen.insert(ns.substring(with: m.range)).inserted else { continue }
            let range = (1...4).map { i -> Int in
                guard let v = Int(ns.substring(with: m.range(at: i))), v <= data.count else { return -1 }
                return v
            }
            let start = max(0, m.range.location - 4000)
            let window = NSRange(location: start, length: min(8000, ns.length - start))
            let filter = sub.firstMatch(in: text, range: window).map { ns.substring(with: $0.range(at: 1)) }
            list.append(check(data, range, filter, "Signature\(list.count + 1)", -1, .zero, nil, nil, nil, nil, online))
        }
        return list
    }

    private static func latin1(_ data: [UInt8]) -> String {
        String(data: Data(data), encoding: .isoLatin1) ?? ""
    }

    private static func check(_ data: [UInt8], _ br: [Int], _ subFilter: String?, _ field: String, _ page: Int, _ rect: RectD,
                              _ nameEntry: String?, _ mDate: Date?, _ reason: String?, _ location: String?, _ online: Bool) -> SignatureInfo {
        var info = SignatureInfo(fieldName: field, pageIndex: page, rect: rect, status: .invalid, signerName: nameEntry, signingTime: mDate,
                                 reason: reason, location: location, subFilter: subFilter)
        func result(_ status: SignatureStatus, _ detail: String, covers: Bool = false) -> SignatureInfo {
            var r = info
            r.status = status
            r.detail = detail
            r.coversWholeDocument = covers
            return r
        }
        // Each entry is checked against the file length first, so the sums below can't overflow.
        if br.contains(where: { $0 < 0 || $0 > data.count }) || br[2] < br[0] + br[1] || br[2] + br[3] > data.count {
            return result(.invalid, "The signature's byte range doesn't fit the file.")
        }
        let covers = br[0] == 0 && isTrailingWhitespace(data, br[2] + br[3])
        let signed = Array(data[br[0]..<br[0] + br[1]]) + Array(data[br[2]..<br[2] + br[3]])
        let gap = Array(data[(br[0] + br[1])..<br[2]])
        // The unsigned gap must hold nothing but the hex signature value: anything else there (objects slipped in where
        // the zero padding was) would be unsigned content shown as signed.
        if !isHexStringOnly(gap) { return result(.invalid, "The signature's unsigned gap holds more than the signature value.") }
        guard let contents = hexContents(gap), !contents.isEmpty else { return result(.invalid, "The signature value is missing.") }

        var cert: Certificate?
        var extra: [Certificate] = []
        var claimed: Date?, trustTime: Date?
        var signer: CmsSignerInfo?
        var docTimestamp = false
        var detail: String?
        var ok: Bool
        switch subFilter {
        case "adbe.pkcs7.detached", "ETSI.CAdES.detached", "adbe.pkcs7.sha1":
            guard let cms = try? CmsSignedData(der: contents) else { return result(.invalid, "The signature can't be read: it isn't a CMS signature.", covers: covers) }
            extra = cms.certificates
            guard let si = cms.signers.first else {
                ok = false
                detail = "The signature has no signer."
                break
            }
            signer = si
            claimed = si.signingTime
            let sha1 = subFilter == "adbe.pkcs7.sha1"
            let content = sha1 ? cms.content ?? [] : signed
            let (problem, c) = si.check(content, contentType: cms.contentType, certificates: cms.certificates)
            cert = c ?? si.certificate(in: cms.certificates)
            ok = problem == nil
            if let problem { detail = "The signature doesn't match the document: \(problem)" }
            if ok && sha1 {
                let digest = content.count == 22 && content[0] == 0x04 && content[1] == 20 ? Array(content[2...]) : content
                if digest != DigestAlgorithm.sha1.hash(signed) {
                    ok = false
                    detail = "The document digest doesn't match."
                }
            }
        case "ETSI.RFC3161":
            guard let token = try? Rfc3161.Token(der: contents) else { return result(.invalid, "The timestamp token can't be read.", covers: covers) }
            docTimestamp = true
            claimed = token.time
            trustTime = token.time
            extra = token.cms.certificates
            cert = token.verify(stamping: signed, candidates: extra)
            ok = cert != nil
            if !ok { detail = "The timestamp doesn't match the document." }
        default:
            return result(.unsupported, "Signature format \(subFilter ?? "(none)") isn't supported.", covers: covers)
        }

        // The certificate is judged at a time someone other than the signer vouches for (a verified timestamp), else
        // now: the signing-time attribute and /M are whatever the signer's clock (or a forger) said.
        var hasTimestamp = docTimestamp
        var stamped: Date?
        if ok, let signer {
            let t = verifiedTimestamp(signer, extra, online)
            stamped = t.time
            hasTimestamp = t.time != nil
            if t.trusted { trustTime = t.time }
            if let note = t.problem { detail = detail.map { "\($0) \(note)" } ?? note }
        }
        let time = stamped ?? claimed ?? mDate
        let judged = cert.map { trust($0, extra, at: trustTime, online: online, eku: docTimestamp ? timestampingEku : nil) } ?? (false, "No certificate")
        let trusted = judged.0
        var chainStatus = judged.1
        if !trusted && trustTime == nil && chainStatus.contains("NotTimeValid") {
            chainStatus += ": the certificate has expired (or isn't valid yet), and no trusted timestamp proves it was valid when the document was signed"
        }
        let status: SignatureStatus = !ok ? .invalid : covers ? .valid : .modifiedAfterSigning
        if status == .modifiedAfterSigning && detail == nil { detail = "The document was changed after it was signed." }
        info.status = status
        if let name = cert?.commonName, !name.isEmpty { info.signerName = name }
        info.signingTime = time
        info.coversWholeDocument = covers
        info.hasTimestamp = hasTimestamp
        info.certificateTrusted = trusted
        info.certificateStatus = chainStatus
        info.certificateValidAtSigningTime = cert.flatMap { c in time.map { c.notBefore <= $0 && $0 <= c.notAfter } }
        info.detail = detail
        info.certificate = cert
        return info
    }

    /// The signature's embedded RFC 3161 timestamp, when it belongs to this signature (the token's own signature verifies
    /// and its message imprint is the hash of this signature's value), and whether its authority is trusted. The token
    /// sits in the unsigned attributes, outside what the signer signed, so anyone can put one there: only a trusted one
    /// may vouch for the signing time.
    private static func verifiedTimestamp(_ si: CmsSignerInfo, _ extra: [Certificate], _ online: Bool) -> (time: Date?, trusted: Bool, problem: String?) {
        guard let attr = si.unsignedAttributes.first(where: { $0.oid == Oids.timestampToken && !$0.values.isEmpty }) else { return (nil, false, nil) }
        guard let token = try? Rfc3161.Token(der: attr.values[0].raw) else { return (nil, false, "The embedded timestamp can't be read, so it was ignored.") }
        let candidates = extra + token.cms.certificates
        guard let tsa = token.verify(stamping: si.signature, candidates: candidates) else {
            return (nil, false, "The embedded timestamp doesn't belong to this signature, so it was ignored.")
        }
        let (trusted, status) = trust(tsa, candidates, at: token.time, online: online, eku: timestampingEku)
        return (token.time, trusted,
                trusted ? nil : "The timestamp authority isn't trusted (\(status)), so the certificate was checked at the current time.")
    }

    static let timestampingEku = "1.3.6.1.5.5.7.3.8"

    /// Extended key usages that allow signing documents (a certificate without the extension allows any).
    static let signingEkus: Set<String> = [
        "1.3.6.1.5.5.7.3.4", // email protection (S/MIME), what most personal and smart-card IDs carry
        "1.3.6.1.5.5.7.3.36", // document signing (RFC 9336)
        DigitalIds.documentSigningEku, // Microsoft document signing
        "1.2.840.113583.1.1.5", // Adobe Authentic Documents Trust
        "1.3.6.1.5.5.7.3.3", // code signing
        "2.5.29.37.0", // any
    ]

    /// Builds the chain at `time` (nil: now) with `SecTrust`. Revocation is checked online when asked, and only
    /// "couldn't check" problems are forgiven (a revoked certificate never is). The end certificate must be meant for the
    /// job: document signing (`eku` nil) or timestamping. The problems are named as .NET's chain status names them.
    static func trust(_ cert: Certificate, _ extra: [Certificate], at time: Date?, online: Bool, eku: String? = nil) -> (Bool, String) {
        if let unfit = unfit(cert, eku) { return (false, unfit) }
        let at = time ?? Date()
        guard let first = evaluate(cert, extra, at, online) else { return (false, "Chain can't be built: the certificate can't be read") }
        if first.ok { return (true, "OK") }
        var problems: [String] = []
        let expired = first.chain.contains { at < $0.notBefore || at > $0.notAfter }
        // Judged again inside every certificate's validity period: whatever still fails is the chain itself.
        var chainCode: OSStatus? = first.code
        if expired {
            let start = first.chain.map(\.notBefore).max() ?? cert.notBefore
            let end = first.chain.map(\.notAfter).min() ?? cert.notAfter
            chainCode = start <= end ? evaluate(cert, extra, start + (end.timeIntervalSince(start)) / 2, online).flatMap { $0.ok ? nil : $0.code } : nil
        }
        if let chainCode {
            switch chainCode {
            case errSecCertificateRevoked: problems.append("Revoked")
            case errSecCertificateExpired, errSecCertificateNotValidYet: break
            case incompleteRevocationCheck: problems.append("RevocationStatusUnknown")
            default: problems.append((first.chain.last ?? cert).isSelfIssued ? "UntrustedRoot" : "PartialChain")
            }
        }
        if expired { problems.append("NotTimeValid") }
        if problems == ["RevocationStatusUnknown"] { return (true, "OK (revocation couldn't be checked)") }
        return (false, problems.isEmpty ? "NotTrusted" : problems.joined(separator: ", "))
    }

    /// errSecIncompleteCertRevocationCheck.
    private static let incompleteRevocationCheck: OSStatus = -67635

    private static func evaluate(_ cert: Certificate, _ extra: [Certificate], _ at: Date, _ online: Bool) -> (ok: Bool, code: OSStatus, chain: [Certificate])? {
        guard let sec = cert.secCertificate else { return nil }
        let others = extra.filter { $0 != cert }.compactMap(\.secCertificate)
        var policies: [SecPolicy] = [SecPolicyCreateBasicX509()]
        if online, let revocation = SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationUseAnyAvailableMethod)) { policies.append(revocation) }
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(([sec] + others) as CFArray, policies as CFArray, &made) == errSecSuccess, let trust = made else { return nil }
        SecTrustSetNetworkFetchAllowed(trust, online)
        SecTrustSetVerifyDate(trust, at as CFDate)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? [sec])
            .compactMap { try? Certificate(der: Array(SecCertificateCopyData($0) as Data)) }
        return (ok, OSStatus(truncatingIfNeeded: error.map { CFErrorGetCode($0) } ?? 0), chain.isEmpty ? [cert] : chain)
    }

    /// Why the certificate's key usage or extended key usage rules out this use, else nil.
    static func unfit(_ cert: Certificate, _ eku: String?) -> String? {
        if eku == nil && !cert.allowsSignatures { return "The certificate's key usage doesn't allow signatures" }
        if let oids = cert.extendedKeyUsages {
            if let eku {
                if !oids.contains(eku) && !oids.contains("2.5.29.37.0") { return "The certificate isn't meant for timestamps" }
            } else if !oids.contains(where: signingEkus.contains) {
                return "The certificate isn't meant for signing documents (e.g. a website certificate)"
            }
        }
        return nil
    }

    static func isTrailingWhitespace(_ data: [UInt8], _ from: Int) -> Bool {
        data[min(from, data.count)...].allSatisfy { $0 == 32 || $0 == 13 || $0 == 10 || $0 == 9 || $0 == 0 }
    }

    private static func isHex(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b) }

    /// True when the bytes are exactly one hex string: '<', hex digits (whitespace allowed), '>'.
    static func isHexStringOnly(_ gap: [UInt8]) -> Bool {
        guard gap.count >= 2, gap.first == 60, gap.last == 62 else { return false }
        return gap.dropFirst().dropLast().allSatisfy { isHex($0) || $0 == 32 || $0 == 13 || $0 == 10 || $0 == 9 }
    }

    /// The DER bytes of a /Contents hex string (zero padding after the CMS structure trimmed).
    static func hexContents(_ gap: [UInt8]) -> [UInt8]? {
        guard let open = gap.firstIndex(of: 60), let close = gap.lastIndex(of: 62), close > open else { return nil }
        var digits = gap[(open + 1)..<close].filter(isHex)
        if digits.count % 2 == 1 { digits.append(48) }
        func value(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : (b | 0x20) - 87 }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var i = digits.startIndex
        while i < digits.endIndex {
            bytes.append(value(digits[i]) << 4 | value(digits[i + 1]))
            i += 2
        }
        // DER: 0x30, length → the real size.
        if bytes.count > 2 && bytes[0] == 0x30 {
            var length = 0, header = 0
            if bytes[1] < 0x80 {
                length = Int(bytes[1])
                header = 2
            } else {
                let n = Int(bytes[1] & 0x7F)
                if n == 0 || n > 4 || bytes.count < 2 + n { return bytes }
                for k in 0..<n { length = (length << 8) | Int(bytes[2 + k]) }
                header = 2 + n
            }
            if header + length <= bytes.count { return Array(bytes[..<(header + length)]) }
        }
        return bytes
    }
}
