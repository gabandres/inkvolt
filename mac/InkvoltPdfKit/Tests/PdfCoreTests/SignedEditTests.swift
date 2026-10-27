import Foundation
import Testing
@testable import PdfCore

/// Ported from SignedEditTests.cs: edits of signed documents are appended; removed items left in the signed revision.
/// The fixture is signed-looking (a signature field whose /ByteRange and /Contents are placeholders) until digital
/// signatures come to the Mac: appending, reporting and flattening don't read the signature itself. Adapted:
/// AnEditThatCantBeAppendedStopsInsteadOfBreakingTheSignatures (MuPDF appends to an encrypted signed file too, where
/// PDFsharp couldn't: the edit is appended); JunkAfterTheEndOfFileStillAppends checks the appended fill's text, not the
/// signature's state (verification comes later); RemovalsAppended… keeps its page, comment and Fill & Sign parts (attachments, headers and signature
/// verification come with their steps); FindsTheLastValidStartxref finds where the last revision ends (`PdfEdit.lastEnd`, which lets MuPDF
/// read a file with junk after it). Left out: ReadsTheFileIdAsHexOrLiteralStrings and
/// ALiteralFileIdIsCarriedIntoTheUpdate (the Windows incremental writer's own parsing; MuPDF writes the update here) and
/// AnAppendedEditCopiesTheFileOnce (it counts .NET allocations).
struct SignedEditTests {
    private static let placeholder = "[0 0000000000 0000000000 0000000000]"

    /// A signed-looking two-page form (page 2 says "Second page"); `junk` goes after %%EOF.
    static func signed(junk: String = "") -> [UInt8] {
        let objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 6 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 8 0 R >> >> /SigFlags 3 >> >>",
            2: "<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 6 0 R] /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
            4: "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 650 272 700] /V 5 0 R /P 3 0 R /F 4 >>",
            5: "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange \(placeholder) /Contents <\(String(repeating: "0", count: 2048))> >>",
            6: "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
            7: Core1TestPdf.stream("BT /F1 24 Tf 72 720 Td (Hello contract) Tj ET"),
            8: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            9: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 10 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
            10: Core1TestPdf.stream("BT /F1 24 Tf 72 720 Td (Second page) Tj ET"),
        ]
        return Core1TestPdf.build(objects) + Array(junk.utf8)
    }

    /// The same document saved encrypted (still signed-looking: its /ByteRange is in the clear).
    static func encrypted(_ pdf: [UInt8]) -> [UInt8] { Encrypt.with(pdf, "aes-128", user: "user", owner: "owner") }

    private static func appended(_ original: [UInt8], _ edited: [UInt8]) -> Bool {
        edited.count > original.count && Array(edited[0..<original.count]) == original
    }

    private static func contains(_ data: [UInt8], _ text: String) -> Bool { data.firstRange(of: Array(text.utf8)) != nil }

    @Test func anEncryptedSignedFileIsAppendedToo() throws {
        let pdf = Self.encrypted(Self.signed())
        let (rotated, report) = try SignedEdits.run { try PageEditor.rotate(pdf, "owner", [0], 90) }
        #expect(report.appended)
        #expect(Self.appended(pdf, rotated))
        let engine = try PdfEngine.open(rotated, password: "user")
        defer { engine.close() }
        #expect(engine.page(0).width > engine.page(0).height)

        // Unsigned files never ask.
        _ = try PageEditor.rotate(TestPdf.encrypted(2, "pw"), "pw-owner", [0], 90)
    }

    @Test func junkAfterTheEndOfFileStillAppends() throws {
        // More than the 4 KB the Windows app used to search for the last startxref.
        let junk = "\n" + String(repeating: "% padding added by a mail gateway\n", count: 300)
        let pdf = Self.signed(junk: junk)
        let (rotated, report) = try SignedEdits.run { try PageEditor.rotate(pdf, nil, [0], 90) }
        #expect(report.appended)
        #expect(Self.appended(pdf, rotated))
        let (filled, fillReport) = try SignedEdits.run { try FormEditor.setValues(pdf, nil, ["Name": "Ada"]) }
        #expect(fillReport.appended)
        #expect(Self.appended(pdf, filled))
        #expect(try Core2Pdf.allText(filled).contains("Ada"))
    }

    @Test func findsTheLastValidStartxref() {
        let head = "%PDF-1.7\n...startxref\n42\n%%EOF\n"
        let data = Array((head + String(repeating: " ", count: 5000) + "startxref\nnot a number\n").utf8)
        #expect(PdfEdit.lastEnd(data) == head.utf8.count)
        #expect(PdfEdit.lastEnd(Array("%PDF-1.7\nno trailer".utf8)) == nil)
    }

    @Test func removalsAppendedToASignedFileAreReportedAndFlattenRemovesThem() throws {
        let pdf = Self.signed()
        let (deleted, report) = try SignedEdits.run { try PageEditor.delete(pdf, nil, [1]) }
        #expect(report == SignedEditReport(appended: true, removedItemKept: true))
        #expect(Self.contains(deleted, "Second page")) // still in the signed revision
        let engine = try PdfEngine.open(deleted)
        #expect(engine.pageCount == 1)
        engine.close()

        let flat = try SignedEdits.flatten(deleted, nil)
        #expect(!Self.contains(flat, "Second page"))
        #expect(!Self.appended(pdf, flat))

        // Comments too; adding things isn't a removal. Fill & Sign items too.
        let (noted, added) = try SignedEdits.run { try Annotations.addNote(pdf, nil, 0, 100, 100, "Private remark", author: "Me") }
        #expect(added == SignedEditReport(appended: true, removedItemKept: false))
        let id = try #require(try Annotations.read(noted, nil).first { $0.contents == "Private remark" }).id
        #expect(try SignedEdits.run { try Annotations.delete(noted, nil, id) }.1.removedItemKept)
        let typed = try TextStamps.put(pdf, nil, 0, RectD(100, 100, 200, 20), .text, "Private remark", 12)
        let stampId = try #require(try TextStamps.read(typed, nil).first).id
        #expect(try SignedEdits.run { try TextStamps.remove(typed, nil, stampId) }.1.removedItemKept)

        // Unsigned files are rewritten: nothing is left behind.
        #expect(try SignedEdits.run { try PageEditor.delete(TestPdf.make(3), nil, [1]) }.1 == SignedEditReport(appended: false, removedItemKept: false))
        #expect(!Self.contains(try PageEditor.delete(TestPdf.make(3, marker: "gone"), nil, [1]), "Page 2 gone"))
    }
}
