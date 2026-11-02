import Foundation
import Testing
@testable import PdfCore

/// Ported from ExportPptxTests.cs, every test (E15). Adapted: the Open XML SDK isn't available, so a presentation is read
/// back with our own ZIP reader and Foundation's XMLDocument, and its validator is stood in for by
/// `OpenXmlPackage.validate` (every XML part well formed, every part with a content type, every relationship's target
/// there, `unzip -t` clean); the Windows test PDFs drawn with PDFsharp are written by hand here (Helvetica for Arial,
/// ellipses as four Bézier curves as PDFsharp draws them); the evil text has no lone surrogate (a Swift string can't hold
/// one); ExportSamples (files written for a person to open) is left out.
struct ExportPptxTests {
    static let emu = 12700.0

    static func pptx(_ pdf: [UInt8], title: String? = "Sample", options: ExportOptions = ExportOptions()) throws -> [UInt8] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let sink = MemorySink()
        var options = options
        options.title = title
        let report = try DocumentExport.export(engine, .powerPoint, to: sink, options: options)
        #expect(report.saved)
        return sink.bytes
    }

    static func pptx(_ pages: [ExportPage], title: String? = nil) throws -> [UInt8] {
        let sink = MemorySink()
        try DocumentExport.writePptx(sink, pages, title, nil)
        return sink.bytes
    }

    static func assertValid(_ bytes: [UInt8]) throws {
        let problems = try OpenXmlPackage(bytes).validate()
        #expect(problems.isEmpty, "\(problems.prefix(10).joined(separator: "\n"))")
    }

    private typealias X = OpenXmlPackage

    /// EMU as points, rounded half to even: what xUnit's `Assert.Equal(expected, actual, 0)` compares on Windows.
    static func points(_ emu: Double) -> Double { bankers(emu / Self.emu) }

    /// A presentation read back: its slides in the presentation's order.
    struct Deck {
        let package: OpenXmlPackage
        let presentation: XMLDocument
        let slideParts: [String]

        init(_ bytes: [UInt8]) throws {
            package = try OpenXmlPackage(bytes)
            presentation = try package.xml("ppt/presentation.xml")
            let rels = try package.relationships(of: "ppt/presentation.xml")
            slideParts = X.elements(presentation, "p:sldId").compactMap { rels[X.attr($0, "r:id") ?? ""] }
        }

        var slides: [XMLDocument] { slideParts.compactMap { try? package.xml($0) } }

        var size: (cx: Double, cy: Double) {
            let s = X.elements(presentation, "p:sldSz").first
            return (Double(X.attr(s, "cx") ?? "") ?? 0, Double(X.attr(s, "cy") ?? "") ?? 0)
        }

        var title: String? {
            guard let t = X.elements(try! package.xml("docProps/core.xml"), "dc:title").first else { return nil }
            return X.text(t)
        }
    }

    static func titleOf(_ slide: XMLDocument) -> XMLElement? {
        X.elements(slide, "p:sp").first { sp in X.elements(sp, "p:ph").contains { X.attr($0, "type") == "title" } }
    }

    static func textBoxes(_ slide: XMLDocument) -> [XMLElement] { X.elements(slide, "p:sp").filter { !X.elements($0, "p:txBody").isEmpty } }

    static func text(_ sp: XMLElement) -> String {
        X.elements(sp, "a:p").map { p in X.elements(p, "a:t").map(X.text).joined() }.joined(separator: "\n")
    }

    static func off(_ e: XMLElement) -> (x: Double, y: Double) {
        let o = X.elements(e, "a:off").first
        return (Double(X.attr(o, "x") ?? "") ?? .nan, Double(X.attr(o, "y") ?? "") ?? .nan)
    }

    static func ext(_ e: XMLElement) -> (cx: Double, cy: Double) {
        let o = X.elements(e, "a:ext").first
        return (Double(X.attr(o, "cx") ?? "") ?? .nan, Double(X.attr(o, "cy") ?? "") ?? .nan)
    }

    /// The child elements of `e`'s spPr.
    static func spPr(_ e: XMLElement) -> XMLElement? { X.elements(e, "p:spPr").first }

    static func preset(_ e: XMLElement) -> String? { X.attr(spPr(e).flatMap { X.children($0, "a:prstGeom").first }, "prst") }

    static func fill(_ e: XMLElement) -> String? {
        X.attr(spPr(e).flatMap { X.children($0, "a:solidFill").first }.flatMap { X.children($0, "a:srgbClr").first }, "val")
    }

    static func lineColor(_ e: XMLElement) -> String? {
        X.attr(spPr(e).flatMap { X.children($0, "a:ln").first }.flatMap { X.children($0, "a:solidFill").first }.flatMap { X.children($0, "a:srgbClr").first }, "val")
    }

    /// The shapes that aren't text boxes (p:sp without a txBody).
    static func shapes(_ slide: XMLDocument) -> [XMLElement] { X.elements(slide, "p:sp").filter { X.elements($0, "p:txBody").isEmpty } }

    // ---- the test PDFs ----

    /// An ellipse as PDFsharp draws one: four Bézier curves (PDF space).
    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> String {
        let k = 0.5522847498
        return "\(cx + rx) \(cy) m \(cx + rx) \(cy + ry * k) \(cx + rx * k) \(cy + ry) \(cx) \(cy + ry) c "
            + "\(cx - rx * k) \(cy + ry) \(cx - rx) \(cy + ry * k) \(cx - rx) \(cy) c "
            + "\(cx - rx) \(cy - ry * k) \(cx - rx * k) \(cy - ry) \(cx) \(cy - ry) c "
            + "\(cx + rx * k) \(cy - ry) \(cx + rx) \(cy - ry * k) \(cx + rx) \(cy) c "
    }

    /// One PDF with a page per (width, height, content), Helvetica as /F1.
    static func pages(_ list: [(w: Double, h: Double, content: String)]) -> [UInt8] {
        let n = list.count
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\((0..<n).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(n) >>"]
        for (i, page) in list.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(page.w) \(page.h)] /Contents \(4 + 2 * i) 0 R "
                + "/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> >> >>")
            objects.append(Core2Pdf.stream(page.content))
        }
        return Core2Pdf.build(objects)
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String {
        String(format: "%.6f %.6f %.6f", Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    /// A page with one each of the simple shapes, a polygon and a label (ShapesPdf, in PDF space: y from the bottom).
    static func shapesPdf() -> [UInt8] {
        pages([(612, 792, """
        q \(rgb(200, 30, 40)) rg 72 632 120 60 re f Q
        q \(rgb(10, 120, 50)) RG 2 w 240 632 120 60 re S Q
        q \(rgb(20, 60, 200)) rg \(ellipse(450, 662, 50, 30))f Q
        q \(rgb(90, 20, 150)) RG 1.5 w 72 572 m 500 572 l S Q
        q \(rgb(240, 160, 0)) rg 100 492 m 200 492 l 150 412 l h f Q
        BT /F1 11 Tf 72 292 Td (A label beside the shapes) Tj ET
        """)])
    }

    static func mixedSizesPdf() -> [UInt8] {
        pages([(612.0, 792.0, "First"), (612.0, 792.0, "Second"), (792.0, 612.0, "Wide page"), (2000.0, 3000.0, "Huge page")].map { w, h, text in
            (w, h, "BT /F1 14 Tf \(w - 150) 60 Td (\(text)) Tj ET")
        })
    }

    /// A page with a label and `draw`, each in its own graphics state.
    static func drawnPdf(_ draw: String...) -> [UInt8] {
        pages([(612, 792, "BT /F1 12 Tf 72 700 Td (A label on the page) Tj ET " + draw.map { "q \($0) Q " }.joined())])
    }

    // ---- the tests ----

    @Test func oneValidSlidePerPageAtThePagesSize() throws {
        let bytes = try Self.pptx(ExportTestPdf.make())
        try Self.assertValid(bytes)
        let deck = try Deck(bytes)
        #expect(deck.slides.count == 2)
        #expect(deck.size.cx == 612 * Self.emu)
        #expect(deck.size.cy == 792 * Self.emu)
        #expect(deck.title == "Sample")
    }

    @Test func headingsTitleTheSlidesAndTextIsEditableBoxesInReadingOrder() throws {
        let slides = try Deck(Self.pptx(ExportTestPdf.make())).slides
        #expect(Self.titleOf(slides[0]).map(Self.text) == "Quarterly Report")
        #expect(Self.titleOf(slides[1]).map(Self.text) == "Two Columns")

        let page1 = Self.textBoxes(slides[0]).map(Self.text)
        #expect(page1.contains(ExportTestPdf.para1))
        // In PowerPoint the order on the slide is the reading order.
        let summary = try #require(page1.firstIndex(of: "Summary"))
        let p1 = try #require(page1.firstIndex(of: ExportTestPdf.para1)), p2 = try #require(page1.firstIndex(of: ExportTestPdf.para2))
        #expect(summary < p1 && p1 < p2)

        // Where it is on the page, at its size, in its font.
        let heading = try #require(Self.textBoxes(slides[0]).first { Self.text($0) == "Summary" })
        #expect(Self.points(Self.off(heading).x) == 72)
        let run = try #require(X.elements(heading, "a:rPr").first)
        #expect(X.attr(run, "sz") == "1600")
        #expect(X.attr(run, "b") == "1")
        #expect(X.attr(X.children(run, "a:latin").first, "typeface") == "Arial")
    }

    @Test func aListIsOneBoxWithRealBullets() throws {
        let slides = try Deck(Self.pptx(ExportTestPdf.make())).slides
        let box = try #require(Self.textBoxes(slides[0]).first { Self.text($0).contains(ExportTestPdf.bullets[0]) })
        let paragraphs = X.elements(box, "a:p")
        #expect(paragraphs.map { X.elements($0, "a:t").map(X.text).joined() } == ExportTestPdf.bullets)
        #expect(paragraphs.allSatisfy { X.attr(X.elements($0, "a:buChar").first, "char") == "\u{2022}" })
    }

    @Test func picturesArePicturesStoredOnceAndTablesAreTables() throws {
        let bytes = try Self.pptx(ExportTestPdf.make(logo: true))
        try Self.assertValid(bytes)
        let deck = try Deck(bytes)
        let slides = deck.slides
        // The logo on both pages is one picture in the file.
        #expect(X.elements(slides[0], "p:pic").count >= 2)
        #expect(X.elements(slides[1], "p:pic").count == 1)
        let logo1 = try #require(X.elements(slides[0], "p:pic").first { Self.off($0).x == 492 * Self.emu })
        let logo2 = try #require(X.elements(slides[1], "p:pic").first)
        let rels1 = try deck.package.relationships(of: deck.slideParts[0]), rels2 = try deck.package.relationships(of: deck.slideParts[1])
        let target1 = rels1[X.attr(X.elements(logo1, "a:blip").first, "r:embed") ?? ""]
        let target2 = rels2[X.attr(X.elements(logo2, "a:blip").first, "r:embed") ?? ""]
        #expect(target1 != nil && target1 == target2)

        let tables = X.elements(slides[0], "a:tbl")
        try #require(tables.count == 1)
        let rows = X.elements(tables[0], "a:tr")
        #expect(rows.count == ExportTestPdf.table.count)
        #expect(X.elements(rows[2], "a:tc").map { X.text($0).trimmedWS } == ExportTestPdf.table[2])
        #expect(X.elements(tables[0], "a:gridCol").count == 3)
    }

    @Test func simpleShapesAreShapesWithTheirColorsAndOthersArePictures() throws {
        let bytes = try Self.pptx(Self.shapesPdf())
        try Self.assertValid(bytes)
        let slide = try #require(try Deck(bytes).slides.first)
        let shapes = Self.shapes(slide)

        let filled = shapes.filter { Self.preset($0) == "rect" && Self.fill($0) != nil }
        try #require(filled.count == 1)
        #expect(Self.fill(filled[0]) == "C81E28")
        #expect(Self.points(Self.off(filled[0]).x) == 72)
        #expect(Self.points(Self.ext(filled[0]).cx) == 120)

        let outline = shapes.filter { Self.preset($0) == "rect" && Self.spPr($0).map { !X.children($0, "a:noFill").isEmpty } == true }
        try #require(outline.count == 1)
        #expect(Self.lineColor(outline[0]) == "0A7832")
        #expect(Self.points(Self.off(outline[0]).x) == 240)
        #expect(Self.points(Self.ext(outline[0]).cx) == 120)
        let width = Double(X.attr(Self.spPr(outline[0]).flatMap { X.children($0, "a:ln").first }, "w") ?? "") ?? 0
        #expect(abs(width - 2 * Self.emu) <= 3000)

        let ellipse = shapes.filter { Self.preset($0) == "ellipse" }
        try #require(ellipse.count == 1)
        #expect(Self.fill(ellipse[0]) == "143CC8")

        let lines = X.elements(slide, "p:cxnSp")
        try #require(lines.count == 1)
        #expect(Self.preset(lines[0]) == "line")
        #expect(Self.lineColor(lines[0]) == "5A1496")

        // The triangle isn't a simple shape: it stays as it looks, a picture.
        #expect(X.elements(slide, "p:pic").count == 1)
        #expect(Self.textBoxes(slide).map(Self.text).contains("A label beside the shapes"))

        // Shapes lie behind the text and pictures.
        let tree = try #require(X.elements(slide, "p:spTree").first)
        let order = (tree.children ?? []).compactMap { $0 as? XMLElement }
        let label = try #require(Self.textBoxes(slide).first)
        let shapeAt = try #require(order.firstIndex(of: filled[0])), labelAt = try #require(order.firstIndex(of: label))
        #expect(shapeAt < labelAt)
    }

    @Test func aThinFrameIsARectangleAndASmallDotAnEllipse() throws {
        let pdf = Self.pages([(612, 792, """
        q 0 0 0 RG 0.5 w 50 442 400 300 re S Q
        q \(Self.rgb(10, 150, 170)) rg \(Self.ellipse(202.5, 289.5, 2.5, 2.5))f Q
        q \(Self.rgb(150, 0, 0)) RG 1 w \(Self.ellipse(340, 272, 40, 20))S Q
        BT /F1 11 Tf 100 592 Td (Words inside the frame) Tj ET
        """)])
        let slide = try #require(try Deck(Self.pptx(pdf)).slides.first)
        let shapes = Self.shapes(slide)
        let frames = shapes.filter { Self.preset($0) == "rect" }
        try #require(frames.count == 1)
        #expect(Self.points(Self.ext(frames[0]).cx) == 400)
        #expect(shapes.filter { Self.preset($0) == "ellipse" }.count == 2)
        #expect(X.elements(slide, "p:pic").isEmpty)
    }

    @Test func aMissingFontIsReplacedByOneOfItsKind() throws {
        var serif = ExportSpan("Serif words on the page", "Missing Serif", 12, false, false, 0, RectD(72, 72, 200, 14))
        serif.serif = true
        let slide = try #require(try Deck(Self.pptx([ExportPage(612, 792, [ExportLine([serif], serif.box)], [], [])])).slides.first)
        let box = try #require(Self.textBoxes(slide).first)
        #expect(X.attr(X.elements(box, "a:latin").first, "pitchFamily") == "18")
    }

    @Test func aPagesTableRulesAreTheTablesNotLooseLines() throws {
        let slide = try #require(try Deck(Self.pptx(ExportTestPdf.make())).slides.first)
        #expect(X.elements(slide, "p:cxnSp").isEmpty)
    }

    @Test func pagesOfOtherSizesFitTheSlideCentered() throws {
        let bytes = try Self.pptx(Self.mixedSizesPdf())
        try Self.assertValid(bytes)
        let deck = try Deck(bytes)
        // The size most pages have.
        #expect(deck.size.cx == 612 * Self.emu)
        #expect(deck.size.cy == 792 * Self.emu)
        let slides = deck.slides
        #expect(slides.count == 4)
        for slide in slides {
            for t in Self.textBoxes(slide) {
                let o = Self.off(t), e = Self.ext(t)
                #expect(o.x >= 0 && o.x <= deck.size.cx)
                #expect(o.y >= 0 && o.y <= deck.size.cy)
                #expect(o.x + e.cx >= 0 && o.x + e.cx <= deck.size.cx)
            }
        }
        // Scaled pages' type is scaled with them.
        let huge = try #require(Self.textBoxes(slides[3]).first)
        #expect((Int(X.attr(X.elements(huge, "a:rPr").first, "sz") ?? "") ?? 9999) < 1400)
        #expect(X.attr(X.elements(try #require(Self.textBoxes(slides[0]).first), "a:rPr").first, "sz") == "1400")
    }

    @Test(arguments: [(20.0, 30.0), (5000.0, 300.0)]) // under PowerPoint's 1 inch; over its 56 inches
    func theSlideStaysWithinWhatPowerPointAllows(_ size: (Double, Double)) throws {
        let (w, h) = size
        let bytes = try Self.pptx(Self.pages([(w, h, "BT /F1 6 Tf 2 \(h - 10) Td (Text) Tj ET")]))
        try Self.assertValid(bytes)
        let s = try Deck(bytes).size
        #expect(s.cx >= 914_400 && s.cx <= 51_206_400)
        #expect(s.cy >= 914_400 && s.cy <= 51_206_400)
    }

    @Test func textFromThePdfIsOnlyEverText() throws {
        // Swift's literals refuse noncharacters, so U+FFFE is made from its number.
        let evil = "</a:t><p:sp xmlns:p=\"x\">&amp;<script>\u{1}\u{8}" + String(Character(Unicode.Scalar(UInt32(0xFFFE))!)) + " end"
        let span = ExportSpan(evil, "Evil\"Font<&\u{2}", 12, false, false, 0, RectD(72, 72, 300, 14))
        let page = ExportPage(612, 792, [ExportLine([span], span.box)], [], [])
        let bytes = try Self.pptx([page], title: "T</dc:title>\u{1}<x>")
        try Self.assertValid(bytes)
        let deck = try Deck(bytes)
        let text = Self.text(try #require(Self.textBoxes(deck.slides[0]).first))
        #expect(text.contains("<script>"))
        #expect(text.contains("</a:t>"))
        #expect(!text.contains("\u{1}"))
        // Nothing in the file points outside it.
        for part in deck.slideParts {
            let rels = try deck.package.xml((part as NSString).deletingLastPathComponent + "/_rels/" + (part as NSString).lastPathComponent + ".rels")
            for r in X.elements(rels, "Relationship") {
                #expect(X.attr(r, "TargetMode") == nil)
                #expect(!(X.attr(r, "Type") ?? "").hasSuffix("/hyperlink"))
            }
        }
    }

    @Test func aLineSetSidewaysIsATurnedTextBox() throws {
        let up = ExportSpan("Sideways stamp", "Arial", 10, false, false, 0, RectD(20, 200, 12, 100))
        let body = ExportSpan("Body text on the page", "Arial", 12, false, false, 0, RectD(72, 72, 200, 14))
        let page = ExportPage(612, 792, [ExportLine([up], up.box, sideways: true, turn: 3), ExportLine([body], body.box)], [], [])
        let bytes = try Self.pptx([page])
        try Self.assertValid(bytes)
        let slide = try #require(try Deck(bytes).slides.first)
        let box = try #require(Self.textBoxes(slide).first { Self.text($0) == "Sideways stamp" })
        let xfrm = try #require(X.elements(box, "a:xfrm").first)
        #expect(X.attr(xfrm, "rot") == String(270 * 60000))
        // Unturned its box is as long as the line; turned about its center it lands where the page has it.
        let o = Self.off(xfrm), e = Self.ext(xfrm)
        #expect(e.cx == 100 * Self.emu)
        #expect(e.cy == 12 * Self.emu)
        #expect(o.x + e.cx / 2 == 26 * Self.emu)
        #expect(o.y + e.cy / 2 == 250 * Self.emu)
    }

    @Test func aBlankPageIsAnEmptySlideAndASlideWithoutAHeadingHasNoTitle() throws {
        let text = ExportSpan("Only body text here on this page and more of it.", "Arial", 11, false, false, 0, RectD(72, 72, 300, 14))
        let bytes = try Self.pptx([ExportPage(612, 792, [ExportLine([text], text.box)], [], []), ExportPage(612, 792, [], [], [])])
        try Self.assertValid(bytes)
        let slides = try Deck(bytes).slides
        #expect(slides.count == 2)
        #expect(Self.titleOf(slides[0]) == nil)
        #expect(Self.textBoxes(slides[1]).isEmpty)
    }

    @Test func aRunningHeadNeverTitlesTheSlide() throws {
        func line(_ s: String, _ y: Double, _ size: Double, bold: Bool = false) -> ExportLine {
            let span = ExportSpan(s, "Arial", size, bold, false, 0, RectD(72, y, 200, size * 1.2))
            return ExportLine([span], span.box)
        }
        let pages = (1...4).map { i in
            ExportPage(612, 792, [line("The Big Running Head", 30, 18, bold: true), line("Chapter \(i)", 100, 24, bold: true)]
                + (0..<10).map { k in line("Body line number \(k) of the page with enough words.", 150 + Double(k) * 16, 11) }, [], [])
        }
        let slides = try Deck(Self.pptx(pages)).slides
        for i in 0..<4 {
            #expect(Self.titleOf(slides[i]).map(Self.text) == "Chapter \(i + 1)")
            // The head stays on each slide, as the page has it.
            #expect(Self.textBoxes(slides[i]).map(Self.text).contains("The Big Running Head"))
        }
    }

    @Test func altTextFromTheTagsGoesOnThePicture() throws {
        let tagged = ExportHtmlTests.taggedPdf("A chart of sales & <costs>")
        let bytes = try Self.pptx(tagged, options: ExportOptions(source: tagged))
        try Self.assertValid(bytes)
        let slide = try #require(try Deck(bytes).slides.first)
        let pic = try #require(X.elements(slide, "p:pic").first)
        #expect(X.attr(X.elements(pic, "p:cNvPr").first, "descr") == "A chart of sales & <costs>")
    }

    @Test(arguments: [ExportFormat.powerPoint, .word])
    func aShapeFarBiggerThanThePageTakesNoLongerThanThePage(_ format: ExportFormat) throws {
        // About 1e10 pt wide: walking in from its sides, half a point at a time, never ended.
        let pdf = Self.drawnPdf("1 0 0 RG 1000 0 0 1000 0 0 cm 0 0 10000000 10000000 re S", "0 0 1 rg 1000 0 0 1000 0 0 cm -5000000 -5000000 10000000 10000000 re f")
        let started = Date()
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        #expect(try DocumentExport.export(engine, format, to: MemorySink()).saved)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func readingShapesStopsWhenCancelled() throws {
        let paths = (0..<10).map { ExportPath(RectD(10 + Double($0), 10, 100, 100), true, 0xFF0000) }
        let token = CancelToken()
        token.cancel()
        #expect(throws: CancellationError.self) { _ = try ExportShapes.read(paths, nil, [], [], 612, 792, cancel: token) }
    }

    @Test func aLineFarOffThePageKeepsTheFileValid() throws {
        // 1e10 pt long, 1 pt thick: one across the page and one wholly off it.
        let bytes = try Self.pptx(Self.drawnPdf("0 0 1 RG 1000 0 0 1000 0 0 cm 0.001 w -5000000 0.4 m 5000000 0.4 l S",
                                                "0 1 0 RG 1000 0 0 1000 0 0 cm 0.001 w -5000000 -3 m 5000000 -3 l S"))
        try Self.assertValid(bytes)
        let slide = try #require(try Deck(bytes).slides.first)
        let lines = X.elements(slide, "p:cxnSp")
        try #require(lines.count == 1)
        #expect(Self.ext(lines[0]).cx == 612 * Self.emu)
    }
}
