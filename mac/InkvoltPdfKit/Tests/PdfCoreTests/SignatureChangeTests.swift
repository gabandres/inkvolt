import Foundation
import Testing
@testable import PdfCore

/// Ported from SignatureChangeTests.cs: later incremental updates are checked against what each signature permits
/// (DocMDP certification, FieldMDP locks, and for approval signatures: nothing that changes the signed pages), and trust
/// doesn't rest on what the signer claims. Adapted: PersonalIdBackupUsesModernEncryption is left out (the Mac keeps a
/// personal ID in the keychain; its backup is Keychain Access's .p12 export, not Inkvolt's); the certificate problems
/// are SecTrust's, named as .NET's chain status names them (NotTimeValid, UntrustedRoot).
struct SignatureChangeTests {
    private static func approval(_ pdf: [UInt8]) throws -> SignatureInfo {
        try #require(Signatures.verify(pdf).first { $0.fieldName == "Approval" })
    }

    private static func only(_ pdf: [UInt8]) throws -> SignatureInfo {
        let all = Signatures.verify(pdf)
        try #require(all.count == 1)
        return all[0]
    }

    private static func lastMatch(_ text: String, _ pattern: String) -> String? {
        let re = try? NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let m = re?.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Appends an incremental update (classic xref table) redefining or adding `objects`.
    private static func append(_ pdf: [UInt8], _ objects: [Int: String]) -> [UInt8] {
        let text = latin1(pdf)
        let prev = lastMatch(text, #"startxref\s+(\d+)"#) ?? "0"
        let ns = text as NSString
        let sizes = (try? NSRegularExpression(pattern: #"/Size (\d+)"#))?.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) } ?? []
        let root = lastMatch(text, #"/Root (\d+ \d+ R)"#) ?? "1 0 R"
        var out = Array("\n".utf8)
        var offsets: [Int: Int] = [:]
        for (n, body) in objects.sorted(by: { $0.key < $1.key }) {
            offsets[n] = pdf.count + out.count
            out += Array("\(n) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xref = pdf.count + out.count
        var table = "xref\n"
        for (n, at) in offsets.sorted(by: { $0.key < $1.key }) { table += "\(n) 1\n\(String(format: "%010d", at)) 00000 n \n" }
        table += "trailer\n<< /Size \(max(sizes.max() ?? 0, (offsets.keys.max() ?? 0) + 1)) /Root \(root) /Prev \(prev) >>\nstartxref\n\(xref)\n%%EOF\n"
        return pdf + out + Array(table.utf8)
    }

    /// The body of object `n` as it is in the file (between "n 0 obj" and "endobj").
    private static func body(_ pdf: [UInt8], _ n: Int) throws -> String {
        let text = latin1(pdf)
        let start = try #require(text.range(of: "\n\(n) 0 obj", options: .backwards)).upperBound
        let end = try #require(text[start...].range(of: "endobj")).lowerBound
        return text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func replacedPageContentIsNotPermitted() throws {
        // A "shadow attack": the signed content stream is redefined in a later update.
        let pdf = try IncrSignatureTests.signedForm()
        let forged = Self.append(pdf, [7: Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Pay 1,000,000) Tj ET")])
        let s = try Self.approval(forged)
        #expect(s.status == .disallowedChanges, "\(s.detail ?? "")")
        #expect(s.detail?.contains("content of page 1") == true)
        #expect(Signatures.brokenByEdits(Signatures.verify(pdf), forged).contains { $0.fieldName == "Approval" })
    }

    @Test func hidingContentWithLayersIsNotPermitted() throws {
        let pdf = try IncrSignatureTests.signedForm()
        let catalog = try Self.body(pdf, 1)
        let hidden = Self.append(pdf, [
            1: String(catalog.dropLast(2)) + " /OCProperties << /OCGs [20 0 R] /D << /OFF [20 0 R] >> >> >>",
            20: "<< /Type /OCG /Name (Hidden) >>",
        ])
        let s = try Self.approval(hidden)
        #expect(s.status == .disallowedChanges, "\(s.detail ?? "")")
        #expect(s.detail?.contains("layers") == true)
    }

    @Test func aLaterUpdateCantRewriteTheSignaturesOwnEntries() throws {
        let pdf = try IncrSignatureTests.signedForm()
        let sig = try Self.body(pdf, 5).replacingOccurrences(of: "/M (D:20260101120000Z)", with: "/M (D:20990101120000Z) /Reason (Forged)")
        let spoofed = Self.append(pdf, [5: sig])
        let s = try Self.approval(spoofed)
        #expect(s.status == .disallowedChanges, "\(s.detail ?? "")")
        #expect(s.detail?.contains("earlier signature") == true)
        // What is shown is what was signed.
        #expect(s.reason == nil)
        let time = try #require(s.signingTime)
        #expect(Calendar(identifier: .gregorian).component(.year, from: time) == 2026)
    }

    @Test func newCommentsAreFineForApprovalButNotUnderFormFillingCertification() async throws {
        let id = try SigningTests.rsaId()
        let approved = try await SigningTests.sign(TestPdf.make(1), id)
        let noted = try Annotations.addNote(approved, nil, 0, 100, 100, "Looks good", author: "Reviewer")
        #expect(try Self.only(noted).status == .modifiedAfterSigning)

        let certified = try await SigningTests.sign(TestPdf.make(1), id) { $0.certify = .formFilling }
        let s = try Self.only(try Annotations.addNote(certified, nil, 0, 100, 100, "Looks good", author: "Reviewer"))
        #expect(s.status == .disallowedChanges, "\(s.detail ?? "")")
        #expect(s.certificationLevel == 2)
        #expect(s.detail?.contains("certification") == true)

        let commentsAllowed = try await SigningTests.sign(TestPdf.make(1), id) { $0.certify = .formFillingAndComments }
        #expect(try Self.only(try Annotations.addNote(commentsAllowed, nil, 0, 100, 100, "ok", author: "Reviewer")).status == .modifiedAfterSigning)
    }

    @Test func noChangesCertificationRejectsEvenFormFilling() async throws {
        let id = try SigningTests.rsaId()
        let form = Self.formWithEmptySignatureField()
        let locked = try await SigningTests.sign(form, id) { $0.certify = .noChanges }
        let filled = try FormEditor.setValues(locked, nil, ["Name": "Ada"])
        let s = try #require(Signatures.verify(filled).first { $0.certificationLevel == 1 })
        #expect(s.status == .disallowedChanges, "\(s.detail ?? "")")
        #expect(s.detail?.contains("no changes allowed") == true)

        let formFilling = try await SigningTests.sign(form, id) { $0.certify = .formFilling }
        let ok = try FormEditor.setValues(formFilling, nil, ["Name": "Ada"])
        let t = try #require(Signatures.verify(ok).first { $0.certificationLevel == 2 })
        #expect(t.status == .modifiedAfterSigning, "\(t.detail ?? "")")
    }

    @Test func formFillingCertificationAllowsOnlyItsOwnSignatureFields() async throws {
        let id = try SigningTests.rsaId()
        let certified = try await SigningTests.sign(Self.formWithEmptySignatureField(), id) { $0.certify = .formFilling }
        // A new signature field would break the certification: refused.
        await #expect { try await SigningTests.sign(certified, id) } throws: {
            ($0 as? SigningError)?.message.contains("existing signature fields") == true
        }
        // Signing the empty field the certifier left is permitted.
        let signed = try await SigningTests.sign(certified, id) { $0.fieldName = "Witness" }
        let all = Signatures.verify(signed)
        let cert = try #require(all.first { $0.certificationLevel == 2 })
        #expect(cert.status == .modifiedAfterSigning, "\(cert.detail ?? "")")
        let witness = try #require(all.first { $0.fieldName == "Witness" })
        #expect(witness.status == .valid, "\(witness.detail ?? "")")
    }

    @Test func lockedFieldsAreLockedAndTheirChangesDetected() async throws {
        let id = try SigningTests.rsaId()
        let form = Self.formWithEmptySignatureField(lockName: true)
        let filled = try FormEditor.setValues(form, nil, ["Name": "Ada"])
        let signed = try await SigningTests.sign(filled, id) { $0.fieldName = "Witness" }
        #expect(latin1(Array(signed[filled.count...])).contains("/FieldMDP"))
        #expect(try FormEditor.read(signed, nil).first { $0.fieldName == "Name" }?.readOnly == true)

        // Changing the locked field afterwards (another tool could ignore the read-only flag) is caught.
        let doc = try Core2Pdf.open(signed)
        let name = try #require((1..<doc.objectCount).last { doc.object($0).isDict && doc.object($0).text("T") == "Name" })
        let original = try Self.body(signed, name)
        let re = try NSRegularExpression(pattern: #"/V\s*(\([^)]*\)|<[^>]*>)"#)
        let replaced = re.stringByReplacingMatches(in: original, range: NSRange(location: 0, length: (original as NSString).length), withTemplate: "/V (Eve)")
        let changed = Self.append(signed, [name: replaced])
        #expect(try FormEditor.read(changed, nil).first { $0.fieldName == "Name" }?.value == "Eve")
        let s = try #require(Signatures.verify(changed).first { $0.fieldName == "Witness" })
        #expect(s.status == .disallowedChanges, "\(s.detail ?? "")")
        #expect(s.detail?.contains("locked field") == true)
    }

    @Test func aCertificateForWebsitesCantSignDocuments() async throws {
        let id = try SigningTests.rsaId("www.example.com", keyUsage: nil, ekus: ["1.3.6.1.5.5.7.3.1"]) // TLS server only
        let signed = try await SigningTests.sign(TestPdf.make(1), id)
        let s = try Self.only(signed)
        #expect(s.status == .valid) // the bytes check out…
        #expect(!s.certificateTrusted) // …but the certificate isn't one for signing documents
        #expect(s.certificateStatus.contains("isn't meant for signing documents"))
    }

    @Test func anExpiredCertificateIsJudgedNowWithoutATrustedTimestamp() async throws {
        let year = 365.0 * 86400
        let id = try SigningTests.rsaId("Expired", keyUsage: nil, from: Date() - 3 * year, to: Date() - 2 * year)
        // Signed "back then" by the signer's own (claimed) clock.
        let signed = try await SigningTests.sign(TestPdf.make(1), id) { $0.time = Date() - 2 * year - 30 * 86400 }
        let s = try Self.only(signed)
        #expect(s.certificateValidAtSigningTime == true) // by the claimed time…
        #expect(s.certificateStatus.contains("NotTimeValid"), "\(s.certificateStatus)") // …but that claim doesn't count: the chain is built today
        #expect(s.certificateStatus.contains("no trusted timestamp"))
    }

    @Test func aTimestampTakenFromAnotherSignatureIsIgnored() async throws {
        // The token sits outside what the signer signed: copy a genuine token from another signature into this one.
        let id = try SigningTests.rsaId()
        let tsa = try FakeTsa()
        let a = try await SigningTests.sign(TestPdf.make(1), id) { $0.timestamp = tsa.respond }
        let b = try await SigningTests.sign(TestPdf.make(2), id) { $0.timestamp = tsa.respond }
        #expect(try Self.only(a).hasTimestamp)

        let (aStart, aDer) = try SigningTests.contents(a)
        let (_, bDer) = try SigningTests.contents(b)
        let stolen = try Self.timestampAttribute(bDer)
        let forgedCms = try Self.replacingTimestamp(aDer, with: stolen)
        var forged = a
        let hex = Array(forgedCms.map { String(format: "%02X", $0) }.joined().utf8)
        var i = aStart
        while forged[i] != 62 {
            forged[i] = i - aStart < hex.count ? hex[i - aStart] : 48
            i += 1
        }

        let s = try Self.only(forged)
        #expect(s.status == .valid, "\(s.detail ?? "")") // the signature itself still checks out…
        #expect(!s.hasTimestamp) // …but the transplanted token is ignored
        #expect(s.detail?.contains("doesn't belong to this signature") == true, "\(s.detail ?? "")")
    }

    /// The signer's timestamp-token attribute (its whole encoding).
    private static func timestampAttribute(_ cms: [UInt8]) throws -> [UInt8] {
        let signer = try signerInfo(cms)
        let unsigned = try #require(try signer.children().last { $0.context == 1 })
        return try #require(try unsigned.children().first { try $0.child(0).oid() == Oids.timestampToken }).raw
    }

    private static func signerInfo(_ cms: [UInt8]) throws -> Der {
        let sd = try Der.parse(cms).child(1).child(0).children()
        return try #require(sd.last).child(0)
    }

    /// The CMS with its signer's unsigned attributes replaced by `attribute`.
    private static func replacingTimestamp(_ cms: [UInt8], with attribute: [UInt8]) throws -> [UInt8] {
        let info = try Der.parse(cms).children()
        let sd = try info[1].child(0).children()
        let si = try #require(sd.last).child(0).children()
        let signer = DerWriter.seq(si.filter { $0.context != 1 }.map(\.raw) + [DerWriter.tlv(0xA1, attribute)])
        let signedData = DerWriter.seq(sd.dropLast().map(\.raw) + [DerWriter.setOf([signer])])
        return DerWriter.seq([info[0].raw, DerWriter.context(0, signedData)])
    }

    /// A one-page form: text field "Name", an empty signature field "Witness" (optionally locking "Name").
    private static func formWithEmptySignatureField(lockName: Bool = false) -> [UInt8] {
        let lock = lockName ? " /Lock << /Type /SigFieldLock /Action /Include /Fields [(Name)] >>" : ""
        return Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 7 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 5 0 R] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Witness) /Rect [72 400 272 450] /P 3 0 R /F 4\(lock) >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Form) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
    }
}
