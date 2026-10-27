import Foundation
import Testing
@testable import PdfCore

/// Ported from PageStructureTests.cs: page edits keep the file's structure honest (no hidden copies of other pages, page
/// labels, page boxes). The PDFsharp object checks read the same objects through MuPDF (`Core2Pdf.open`). Adapted: the
/// labelled document is written by hand (`TestPdf.make`'s `catalogExtra`) where Windows adds /PageLabels with PDFsharp;
/// `PdfObj.DisplaySize` is `PageBoxes.displaySize`. Left out of ACropBoxBeyondTheMediaBoxIsClipped: its redaction and
/// Fill & Sign text parts (Redaction comes later, text stamps with D4).
struct PageStructureTests {
    /// Page 1 has a form button jumping to page 2 (/A and /AA), a page /AA jumping there, an article thread bead and a
    /// reply to a comment on page 2. Page 2 holds SECRET text and a SECRET comment; the document opens on page 2.
    private static func crossLinked() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] >> /Threads [8 0 R] /OpenAction << /S /GoTo /D [4 0 R /Fit] /Next << /S /GoTo /D [3 0 R /Fit] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Annots [5 0 R 13 0 R] /AA << /O << /S /GoTo /D [4 0 R /Fit] >> >> /B [9 0 R] /Resources << /Font << /F1 10 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Annots [12 0 R] /B [11 0 R] /Resources << /Font << /F1 10 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Next) /Rect [72 72 172 100] /P 3 0 R /A << /S /GoTo /D [4 0 R /XYZ 0 792 0] >> /AA << /E << /S /GoTo /D [4 0 R /Fit] >> /D << /S /JavaScript /JS (app.alert\\(1\\)) >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Visible page) Tj ET"),
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (SECRET page two) Tj ET"),
            "<< /Type /Thread /F 9 0 R >>",
            "<< /Type /Bead /T 8 0 R /N 11 0 R /V 11 0 R /P 3 0 R /R [0 0 100 100] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Bead /N 9 0 R /V 9 0 R /P 4 0 R /R [0 0 100 100] >>",
            "<< /Type /Annot /Subtype /Text /Rect [72 600 92 620] /P 4 0 R /Contents (SECRET note) >>",
            "<< /Type /Annot /Subtype /Text /Rect [72 600 92 620] /P 3 0 R /IRT 12 0 R /Contents (Reply) >>",
        ])
    }

    @Test func extractedPagesDontCarryTheOtherPagesAlong() throws {
        let extracted = try PageEditor.extract(Self.crossLinked(), nil, [0])
        #expect(!(try PdfText.everything(extracted)).contains("SECRET"))

        let doc = try Core2Pdf.open(extracted)
        #expect(try doc.pageCount() == 1)
        let page = doc.page(0)
        let annots = try #require(page.array("Annots"))
        let button = try #require(annots[0])
        #expect(button.text("T") == "Next")
        #expect(!button.has("A"), "the jump to the removed page is gone")
        let triggers = try #require(button.dict("AA"))
        #expect(!triggers.has("E"))
        #expect(triggers.has("D"), "other actions stay")
        #expect(page.dict("AA")?.has("O") != true)
        #expect(annots[1]?.has("IRT") == false)
        #expect(!doc.catalog.has("OpenAction"))
        // The thread keeps its bead on the remaining page, linked to itself.
        let thread = try #require(doc.catalog.array("Threads")?[0])
        let bead = try #require(thread.dict("F"))
        #expect(bead.identity == bead["N"]?.identity)
        #expect(page.num == bead["P"]?.num)

        let engine = try PdfEngine.open(extracted)
        defer { engine.close() }
        #expect(engine.pageCount == 1)
        #expect(try engine.text(0).text.contains("Visible page"))
    }

    @Test func deletingAPageDropsWhatLedToIt() throws {
        let deleted = try PageEditor.delete(Self.crossLinked(), nil, [1])
        #expect(!(try PdfText.everything(deleted)).contains("SECRET"))
        #expect(try Core2Pdf.open(deleted).pageCount() == 1)
    }

    /// A two-page source whose page 1 has a button and a link jumping to page 2 (SECRET).
    private static func source() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Annots [5 0 R 9 0 R] /Resources << /Font << /F1 8 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Go) /Rect [72 72 172 100] /P 3 0 R /A << /S /GoTo /D [4 0 R /Fit] >> /AA << /U << /S /GoTo /D [4 0 R /Fit] >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Cover) Tj ET"),
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (SECRET appendix) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Link /Rect [72 200 172 220] /Dest [4 0 R /Fit] >>",
        ])
    }

    @Test func insertedButtonsDontBringHiddenPagesAlong() throws {
        let inserted = try PageEditor.insert(TestPdf.make(2), nil, PdfSource(Self.source(), nil, "src.pdf"), [0], 1)
        #expect(!(try PdfText.everything(inserted)).contains("SECRET"))
        #expect(TestPdf.pageNumbers(inserted) == [1, 0, 2])
        do {
            let doc = try Core2Pdf.open(inserted)
            let annots = try #require(doc.page(1).array("Annots"))
            try #require(annots.count == 1)
            let button = try #require(annots[0])
            #expect(button.text("T") == "Go")
            #expect(!button.has("A"))
            #expect(button.dict("AA")?.has("U") == false)
        }

        // With its target page imported too, the button jumps to the imported copy.
        let both = try PageEditor.insert(TestPdf.make(2), nil, PdfSource(Self.source(), nil, "src.pdf"), nil, 2)
        do {
            let doc = try Core2Pdf.open(both)
            #expect(try doc.pageCount() == 4)
            let button = try #require(doc.page(2).array("Annots")?[0])
            #expect(button.text("T") == "Go")
            for action in [button.dict("A"), button.dict("AA")?.dict("U")] {
                let dest = try #require(action?.array("D"))
                #expect(dest[0]?.num == doc.page(3).num)
            }
        }
        #expect(try PdfText.everything(both).contains("SECRET"))
    }

    @Test func duplicatedAndMergedPagesDontBringHiddenPagesAlong() throws {
        let merged = try PageEditor.merge([PdfSource(Self.source(), nil, "a.pdf")], false)
        let duplicated = try PageEditor.duplicate(Self.source(), nil, [0])
        for pdf in [merged, duplicated] {
            let doc = try Core2Pdf.open(pdf)
            let pages = Set(try doc.pages().map(\.num))
            // Every page object in the file is one of the document's pages: no hidden copies.
            for n in 1..<doc.objectCount {
                let o = doc.object(n)
                if o.isDict && o.name("Type") == "Page" { #expect(pages.contains(n), "object \(n) is a page outside the page tree") }
            }
        }
    }

    // ---- Page labels ----

    /// Five pages labelled i, ii, then (with `prefix`) numbers from `start`.
    private static func labelled(prefix: String = "", start: Int = 1) -> [UInt8] {
        let p = prefix.isEmpty ? "" : " /P (\(prefix))"
        let st = start == 1 ? "" : " /St \(start)"
        return TestPdf.make(5, catalogExtra: "/PageLabels << /Nums [0 << /S /r >> 2 << /S /D\(p)\(st) >>] >> ")
    }

    private func labels(_ pdf: [UInt8]) throws -> [String] { try #require(try DocumentFeatures.pageLabels(pdf, nil)) }

    @Test func pageLabelsFollowTheirPages() throws {
        let pdf = Self.labelled()
        #expect(try labels(pdf) == ["i", "ii", "1", "2", "3"])
        #expect(try labels(PageEditor.delete(pdf, nil, [1])) == ["i", "1", "2", "3"])
        #expect(try labels(PageEditor.reverse(pdf, nil, 5)) == ["3", "2", "1", "ii", "i"])
        #expect(try labels(PageEditor.move(pdf, nil, 5, [4], 0)) == ["3", "i", "ii", "1", "2"])
        #expect(try labels(PageEditor.extract(pdf, nil, [2, 3])) == ["1", "2"])
        #expect(try labels(PageEditor.extract(pdf, nil, [1, 2])) == ["ii", "1"])
        // New pages continue the numbering of the page before them.
        #expect(try labels(PageEditor.insertBlank(pdf, nil, 2, 1, 612, 792)) == ["i", "ii", "iii", "1", "2", "3"])
        #expect(try labels(PageEditor.insert(pdf, nil, PdfSource(TestPdf.make(2), nil, "x.pdf"), nil, 2)) == ["i", "ii", "iii", "iv", "1", "2", "3"])
        #expect(try labels(PageEditor.duplicate(pdf, nil, [0])) == ["i", "ii", "ii", "1", "2", "3"])
        #expect(try labels(PageEditor.insertBlank(pdf, nil, 0, 1, 612, 792)) == ["1", "i", "ii", "1", "2", "3"])
        // Edits that keep the pages leave the labels alone.
        #expect(try labels(PageEditor.rotate(pdf, nil, [0], 90)) == ["i", "ii", "1", "2", "3"])
    }

    @Test func pageLabelRangesKeepPrefixAndStart() throws {
        let pdf = Self.labelled(prefix: "A-", start: 5)
        #expect(try labels(pdf) == ["i", "ii", "A-5", "A-6", "A-7"])
        let deleted = try PageEditor.delete(pdf, nil, [3])
        #expect(try labels(deleted) == ["i", "ii", "A-5", "A-7"])
        let doc = try Core2Pdf.open(deleted)
        let nums = try #require(doc.catalog.dict("PageLabels")?.array("Nums"))
        #expect(nums.count == 6) // three ranges: i–ii, A-5, A-7
        let last = try #require(nums[5])
        #expect(last.text("P") == "A-")
        #expect(last.int("St") == 7)
    }

    // ---- Page boxes ----

    private static func boxed(_ boxes: String) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \(boxes) /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 30 Tf 50 400 Td (Hello boxes) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
    }

    @Test func uncropKeepsThePrintBoxes() throws {
        let pdf = Self.boxed("/TrimBox [10 10 600 780] /BleedBox [-5 -5 620 800] /ArtBox [700 700 800 800]")
        let cropped = try PageEditor.crop(pdf, nil, [0], Margins(20, 20, 20, 20))
        let uncropped = try PageEditor.uncrop(cropped, nil, [0])
        let page = try Core2Pdf.open(uncropped).page(0)
        func box(_ key: String) -> [Double] { page.array(key)?.elements.map { $0.number ?? .nan } ?? [] }
        #expect(!page.has("CropBox"))
        #expect(box("TrimBox") == [10, 10, 600, 780])
        #expect(box("BleedBox") == [0, 0, 612, 792]) // clipped to the media box
        #expect(!page.has("ArtBox")) // entirely outside it
    }

    @Test func aCropBoxBeyondTheMediaBoxIsClipped() throws {
        // MuPDF (like every viewer) shows the CropBox clipped to the MediaBox: 400 x 500 here, not 500 x 600.
        let pdf = Self.boxed("/CropBox [-100 -100 400 500]")
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        #expect(engine.page(0).width == 400 && engine.page(0).height == 500)
        let size = PageBoxes.displaySize(try Core2Pdf.open(pdf).page(0))
        #expect(size.w == 400 && size.h == 500)
    }
}
