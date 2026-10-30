import Foundation
import Testing
@testable import PdfCore

/// Ported from Core2SignatureTests.cs: signatures written by hand into a hand-written PDF are verified. The CMS is made
/// by PdfCore's `CmsBuilder` with an in-memory key (the Windows tests use .NET's `SignedCms`), so it also carries the
/// signing-certificate-v2 attribute .NET's test signer leaves out.
struct Core2SignatureTests {
    static let contentsHexLength = 16384

    /// Fills the /ByteRange placeholder and the /Contents gap of a hand-written PDF with a real signature by
    /// `cn` (adbe.pkcs7.sha1: the SHA-1 digest encapsulated, else detached).
    static func sign(_ pdf: [UInt8], _ placeholderRange: String, cn: String, subFilter: String = "adbe.pkcs7.detached") throws -> [UInt8] {
        var pdf = pdf
        let gapStart = try #require(pdf.firstRange(of: Array("/Contents <".utf8))).lowerBound + "/Contents ".count
        let gapEnd = try #require(pdf[gapStart...].firstIndex(of: 62)) + 1
        let at = try #require(pdf.firstRange(of: Array(placeholderRange.utf8)))
        let range = String(format: "[0 %010d %010d %010d]", gapStart, gapEnd, pdf.count - gapEnd)
        pdf.replaceSubrange(at, with: Array(range.utf8))
        let signed = Array(pdf[..<gapStart]) + Array(pdf[gapEnd...])
        let key = try KeyEncoding.ephemeral(rsaBits: 2048)
        let names = cn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.map { part -> (oid: String, value: String) in
            part.hasPrefix("O=") ? (Oids.organization, String(part.dropFirst(2))) : (Oids.commonName, String(part.dropFirst(3)))
        }
        let cert = try CertificateBuilder(subject: names, notBefore: Date() - 86400, notAfter: Date() + 365 * 86400).selfSigned(key)
        let sha1 = subFilter == "adbe.pkcs7.sha1"
        let cms = try CmsBuilder(sha1 ? DigestAlgorithm.sha1.hash(signed) : signed, encapsulate: sha1, signer: cert, chain: [], digest: .sha256,
                                 signingTime: Date()) { try KeyEncoding.sign(key, $0, .sha256) }
        let hex = Array(cms.encode().map { String(format: "%02X", $0) }.joined().utf8)
        #expect(hex.count <= contentsHexLength)
        pdf.replaceSubrange((gapStart + 1)..<(gapStart + 1 + hex.count), with: hex)
        return pdf
    }

    /// A one-page PDF signed (SHA-256) by a self-signed certificate, plus an empty signature field.
    static func signed(_ subFilter: String = "adbe.pkcs7.detached") throws -> [UInt8] {
        let placeholderRange = "[0 0000000000 0000000000 0000000000]"
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 6 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 6 0 R] /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 650 272 700] /V 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /\(subFilter) /ByteRange \(placeholderRange) /Contents <\(String(repeating: "0", count: contentsHexLength))> /M (D:20260101120000Z) /Reason (Approved) /Location (San Juan) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Witness) /Rect [300 650 500 700] /P 3 0 R /F 4 >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Hello contract) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
        return try sign(pdf, placeholderRange, cn: "CN=Test Signer, O=Inkvolt PDF Tests", subFilter: subFilter)
    }

    @Test(arguments: ["adbe.pkcs7.detached", "ETSI.CAdES.detached", "adbe.pkcs7.sha1"])
    func validSignatureVerifies(_ subFilter: String) throws {
        let sigs = Signatures.verify(try Self.signed(subFilter))
        #expect(sigs.count == 2)
        let s = try #require(sigs.first { $0.fieldName == "Approval" })
        #expect(s.status == .valid, "\(s.detail ?? "")")
        #expect(s.signerName == "Test Signer")
        #expect(s.reason == "Approved")
        #expect(s.location == "San Juan")
        #expect(s.pageIndex == 0)
        #expect(s.rect == RectD(72, 92, 200, 50))
        #expect(s.coversWholeDocument)
        #expect(s.signingTime != nil)
        #expect(s.certificateValidAtSigningTime == true)
        #expect(!s.certificateTrusted) // self-signed: not chained to a root the Mac trusts
        #expect(s.certificateStatus != "OK")
        #expect(sigs.first { $0.fieldName == "Witness" }?.status == .unsigned)
    }

    @Test func editsThatBreakASignatureAreReportedAgainstTheOpenedFile() throws {
        let pdf = try Self.signed()
        let original = Signatures.verify(pdf)
        #expect(Signatures.brokenByEdits(original, pdf).isEmpty)
        // Most edits are appended (the signature stays intact); redaction rewrites the file. Rotating a signed page is
        // appended too, but it changes what was signed.
        #expect(Signatures.brokenByEdits(original, try Annotations.addNote(pdf, nil, 0, 300, 100, "ok", author: "me")).isEmpty)
        let rotated = Signatures.brokenByEdits(original, try PageEditor.rotate(pdf, nil, [0], 90))
        #expect(rotated.map(\.fieldName) == ["Approval"])
        let edited = try Redaction.apply(pdf, nil, [0: [RectD(72, 60, 100, 20)]], dpi: 72)
        #expect(Signatures.brokenByEdits(original, edited).map(\.fieldName) == ["Approval"]) // the unsigned "Witness" field isn't reported
    }

    @Test func changedBytesMakeItInvalid() throws {
        var pdf = try Self.signed()
        let at = try #require(pdf.firstRange(of: Array("Hello contract".utf8))).lowerBound
        pdf[at] = UInt8(ascii: "J")
        let s = try #require(Signatures.verify(pdf).first { $0.fieldName == "Approval" })
        #expect(s.status == .invalid)
        #expect(s.detail != nil)
    }

    @Test func laterIncrementalUpdatesAreReported() throws {
        var pdf = try Self.signed()
        let after = latin1(Array(pdf[try #require(pdf.lastRange(of: Array("startxref".utf8))).upperBound...]))
        let prev = try #require(Int(after.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")[0]))
        let objAt = pdf.count
        pdf += Array("9 0 obj\n<< /Title (Changed later) >>\nendobj\n".utf8)
        let xref = pdf.count
        pdf += Array("xref\n9 1\n\(String(format: "%010d", objAt)) 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R /Info 9 0 R /Prev \(prev) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let s = try #require(Signatures.verify(pdf).first { $0.fieldName == "Approval" })
        #expect(s.status == .modifiedAfterSigning, "\(s.detail ?? "")")
        #expect(!s.coversWholeDocument)
    }

    @Test func contentSlippedIntoTheSignaturePaddingIsNotValid() throws {
        var pdf = try Self.signed()
        let open = try #require(pdf.firstRange(of: Array("/Contents <".utf8))).upperBound
        let gapEnd = try #require(pdf[open...].firstIndex(of: 62))
        let junk = Array(">\n9 0 obj\n<< /Unsigned (evil) >>\nendobj\n<".utf8)
        pdf.replaceSubrange((gapEnd - junk.count - 2)..<(gapEnd - 2), with: junk) // inside the zero padding
        let sigs = Signatures.verify(pdf)
        #expect(sigs.allSatisfy { $0.status != .valid })
        #expect(sigs.contains { $0.status == .invalid }, "\(sigs.map { "\($0.fieldName) \($0.status) \($0.detail ?? "")" })")
    }

    @Test(arguments: [("9223372036854775000", "9223372036854775000"), ("99999999999999999999999", "5"), ("-5", "10"), ("1.5", "2")])
    func hostileByteRangesNeverThrowNorValidate(_ second: String, _ fourth: String) throws {
        var pdf = try Self.signed()
        let start = try #require(pdf.firstRange(of: Array("/ByteRange [".utf8)))
        let end = try #require(pdf[start.upperBound...].firstIndex(of: 93))
        let parts = latin1(Array(pdf[start.upperBound..<end])).split(separator: " ")
        // Same length when it fits (the xref stays valid), else MuPDF repairs the file or the raw-scan fallback runs.
        let width = end - start.lowerBound
        let range = "/ByteRange [0 \(second) \(parts[2]) \(fourth)"
        let padded = range.count < width ? range.padding(toLength: width, withPad: " ", startingAt: 0) : range
        pdf.replaceSubrange(start.lowerBound..<end, with: Array(padded.utf8))
        let sigs = Signatures.verify(pdf)
        #expect(sigs.allSatisfy { $0.status != .valid })
        #expect(sigs.contains { $0.status == .invalid })
    }

    @Test func unsupportedFormatsAndUnsignedFiles() throws {
        let text = latin1(try Self.signed()).replacingOccurrences(of: "/adbe.pkcs7.detached", with: "/adbe.x509.rsa_sha1 ")
        let pdf = text.unicodeScalars.map { UInt8($0.value) }
        #expect(Signatures.verify(pdf).first { $0.fieldName == "Approval" }?.status == .unsupported)
        #expect(Signatures.verify(TestPdf.make(1)).isEmpty)
    }
}
