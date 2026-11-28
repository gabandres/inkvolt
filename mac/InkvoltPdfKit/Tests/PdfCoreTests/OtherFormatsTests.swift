import Foundation
import Testing
@testable import PdfCore

/// XPS, OXPS, EPUB, CBZ, FB2 and pictures, which Windows opens with MuPDF (`PdfEngine.TypeFromPath`, its Open filter;
/// no Windows tests): MuPDF reads them on the Mac and they open as a PDF of their pages. Mac additions; the files are
/// written here (an XPS and a CBZ zipped by the suite's `ZipWriter`).
struct OtherFormatsTests {
    private func file(_ name: String, _ bytes: [UInt8]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    private func zip(_ entries: [(String, [UInt8])]) throws -> [UInt8] {
        let sink = MemorySink()
        let zip = ZipWriter(sink)
        for (name, data) in entries { try zip.add(name, data, compress: true) }
        try zip.finish()
        return sink.bytes
    }

    private func text(_ pdf: [UInt8]) throws -> String {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try (0..<engine.pageCount).map { try engine.text($0).text }.joined(separator: "\n")
    }

    @Test func theFormatsAreWindowsOpenFilters() {
        #expect(OtherFormats.extensions == [".xps", ".oxps", ".epub", ".cbz", ".fb2", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif"])
        #expect(OtherFormats.handles("/a/Book.EPUB") && OtherFormats.handles("scan.tiff") && !OtherFormats.handles("a.pdf") && !OtherFormats.handles("x"))
        #expect(OtherFormats.pdfName("/a/b/Book.epub") == "Book.pdf")
    }

    @Test func aFictionBookBecomesAPdfWithItsText() throws {
        let fb2 = """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section>
        <p>Inkvolt reads FictionBook</p><p>A second paragraph</p>
        </section></body></FictionBook>
        """
        let path = try file("Story.fb2", Array(fb2.utf8))
        let made = try OtherFormats.convert(path: path)
        #expect(made.blank.isEmpty)
        #expect(Array(made.pdf.prefix(5)) == Array("%PDF-".utf8))
        let words = try text(made.pdf)
        #expect(words.contains("Inkvolt reads FictionBook") && words.contains("A second paragraph"))
    }

    @Test func anXpsBecomesAPdfWithItsPageSizeAndText() throws {
        let page = """
        <FixedPage xmlns="http://schemas.microsoft.com/xps/2005/06" Width="816" Height="1056" xml:lang="en-US">
        <Path Data="M 96,96 L 400,96 400,200 96,200 Z" Fill="#FF2050A0" />
        </FixedPage>
        """
        let entries: [(String, [UInt8])] = [
            ("[Content_Types].xml", Array("""
            <?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="fdseq" ContentType="application/vnd.ms-package.xps-fixeddocumentsequence+xml"/>\
            <Default Extension="fdoc" ContentType="application/vnd.ms-package.xps-fixeddocument+xml"/>\
            <Default Extension="fpage" ContentType="application/vnd.ms-package.xps-fixedpage+xml"/></Types>
            """.utf8)),
            ("_rels/.rels", Array("""
            <?xml version="1.0" encoding="utf-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Type="http://schemas.microsoft.com/xps/2005/06/fixedrepresentation" Target="/FixedDocSeq.fdseq" Id="R0"/></Relationships>
            """.utf8)),
            ("FixedDocSeq.fdseq", Array("""
            <FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06"><DocumentReference Source="/Doc.fdoc"/></FixedDocumentSequence>
            """.utf8)),
            ("Doc.fdoc", Array("""
            <FixedDocument xmlns="http://schemas.microsoft.com/xps/2005/06"><PageContent Source="/Page1.fpage"/><PageContent Source="/Page2.fpage"/></FixedDocument>
            """.utf8)),
            ("Page1.fpage", Array(page.utf8)),
            ("Page2.fpage", Array(page.utf8)),
        ]
        let path = try file("Form.xps", try zip(entries))
        let made = try OtherFormats.convert(path: path)
        let engine = try PdfEngine.open(made.pdf)
        defer { engine.close() }
        #expect(engine.pageCount == 2)
        // XPS counts 96 units an inch: 816 × 1056 is Letter, 612 × 792 points.
        #expect(abs(engine.page(0).width - 612) < 1 && abs(engine.page(0).height - 792) < 1)
        let blue = TestImages.pixelAt(made.pdf, 0, 200, 110)
        #expect(blue.b > 120 && blue.r < 80)
    }

    @Test func aComicBookAndAPictureBecomeAPageEach() throws {
        let red = TestImages.png(40, 20) { _, _ in (220, 20, 20, 255) }
        let cbz = try file("Comic.cbz", try zip([("001.png", red), ("002.png", red)]))
        #expect(try PdfEngine.open(OtherFormats.convert(path: cbz).pdf).pageCount == 2)
        let png = try file("Photo.png", red)
        let one = try OtherFormats.convert(path: png).pdf
        let engine = try PdfEngine.open(one)
        defer { engine.close() }
        #expect(engine.pageCount == 1)
        #expect(TestImages.pixelAt(one, 0, engine.page(0).width / 2, engine.page(0).height / 2).r > 180)
    }

    @Test func aFileMuPdfCantReadIsRefused() throws {
        let path = try file("Broken.epub", Array("not a zip".utf8))
        #expect(throws: PdfEngineError.self) { try OtherFormats.convert(path: path) }
    }

    @Test func aCancelStopsTheConversion() throws {
        let path = try file("Story.fb2", Array("<FictionBook><body><section><p>Words</p></section></body></FictionBook>".utf8))
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try OtherFormats.convert(path: path, cancel: cancel) }
    }
}
