import Foundation
import Testing
@testable import PdfCore

/// Mac additions (fix round 2 of 3.1's review): the pass before a compacting save (`MuDoc.unshareDirectObjects`) on its
/// limits. Past its budget the file is written without renumbering, so its references hold; its cost is linear in the
/// entries it walks; and a key whose name isn't UTF-8 is walked like any other.
@Suite(.serialized) struct UnsharePassTests {
    /// Two pages; object 3 is unused, so a compacting save drops it and renumbers the pages after it. `pageOne` is page
    /// 1's own entries.
    static func pages(_ pageOne: String = "") -> [UInt8] {
        Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>",
            3: "<< /Unused true >>",
            4: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \(pageOne) >>",
            5: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ])
    }

    @Test func aSaveOverItsBudgetIsWrittenWithoutRenumberingAndItsReferencesHold() throws {
        let doc = try PdfEdit.open(Self.pages(), nil)
        let shared = doc.dict([("P", doc.page(1))])
        doc.page(0).set("InkTest", shared)
        doc.page(1).set("InkTest", shared)
        doc.unshareBudget = 3 // far too little for this file
        let saved = try doc.write("garbage=compact")
        #expect(doc.lastWriteUncompacted)
        let back = try Core2Pdf.open(saved)
        for i in 0..<2 {
            #expect(back.page(i).dict("InkTest")?["P"]?.identity == back.page(1).identity, "page \(i + 1)'s /P")
        }
    }

    @Test func aDictionaryOf200000KeysSavesQuickly() throws {
        // A /Dests-like dictionary of 200,000 names, each an inline array (a destination) to page 2.
        let entries = (0..<200_000).map { "/N\($0) [5 0 R /Fit]" }.joined(separator: " ")
        let doc = try PdfEdit.open(Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R /Dests 6 0 R >>",
            2: "<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>",
            3: "<< /Unused true >>",
            4: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            5: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            6: "<< \(entries) >>",
        ]), nil)
        let start = Date()
        let saved = try doc.write("garbage=compact")
        let took = Date().timeIntervalSince(start)
        #expect(took < 30, "\(took) s") // a few seconds in a debug build; quadratic lookups took far longer
        #expect(!doc.lastWriteUncompacted)
        let back = try Core2Pdf.open(saved)
        #expect(back.catalog.dict("Dests")?.array("N199999")?[0]?.identity == back.page(1).identity)
    }

    @Test func anInlineContainerUnderAKeyThatIsntUtf8IsUnshared() throws {
        // /F#E9 is the byte E9: not UTF-8. Its array is put on page 2 too, so the two share it.
        let doc = try PdfEdit.open(Self.pages("/Odd << /F#E9 [5 0 R] >>"), nil)
        let odd = try #require(doc.page(0).dict("Odd"))
        let array = try #require(odd.value(at: 0))
        doc.page(1).set("Other", array)
        let saved = try doc.write("garbage=compact")
        #expect(!doc.lastWriteUncompacted)
        let back = try Core2Pdf.open(saved)
        #expect(back.page(1).array("Other")?[0]?.identity == back.page(1).identity, "page 2's /Other")
        #expect(back.page(0).dict("Odd")?.value(at: 0)?[0]?.identity == back.page(1).identity, "page 1's /Odd /F#E9")
    }
}
