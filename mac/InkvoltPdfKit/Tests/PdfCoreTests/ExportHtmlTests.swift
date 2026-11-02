import Foundation
import Testing
@testable import PdfCore

/// Ported from ExportHtmlTests.cs, every test (E15): one file that reflows, and nothing from the PDF comes through as
/// markup. Adapted: the file is read as a tree with Foundation's XMLDocument (void elements closed first, as the Windows
/// test does for XDocument); the tagged test PDF is written by hand where Windows draws it with PDFsharp; the forbidden
/// characters have no lone surrogate (a Swift string can't hold one); ExportSamples is left out.
struct ExportHtmlTests {
    static func html(_ pdf: [UInt8], title: String? = "Sample", options: ExportOptions = ExportOptions()) throws -> String {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let sink = MemorySink()
        var options = options
        options.title = title
        let report = try DocumentExport.export(engine, .html, to: sink, options: options)
        #expect(report.saved)
        return String(decoding: sink.bytes, as: UTF8.self)
    }

    static func html(_ pages: [ExportPage], title: String? = "Sample", language: String? = nil) throws -> String {
        let sink = MemorySink()
        try DocumentExport.writeHtml(sink, pages, title, language)
        return String(decoding: sink.bytes, as: UTF8.self)
    }

    /// The file read as a tree: the writer's markup is well formed with its void elements closed here.
    static func dom(_ html: String) throws -> XMLElement {
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        var body = String(html.dropFirst("<!DOCTYPE html>".count))
        let void = try NSRegularExpression(pattern: #"<(meta|img|br|hr)\b([^>]*)>"#)
        body = void.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "<$1$2/>")
        return try #require(try XMLDocument(xmlString: body, options: []).rootElement())
    }

    static func all(_ root: XMLElement, _ name: String) -> [XMLElement] { OpenXmlPackage.elements(root, name) }

    static func textOf(_ e: XMLElement) -> String { e.stringValue ?? "" }

    static func attr(_ e: XMLElement?, _ name: String) -> String? { OpenXmlPackage.attr(e, name) }

    static func children(_ e: XMLElement, _ name: String) -> [XMLElement] { OpenXmlPackage.children(e, name) }

    /// What no export may hold: anything that runs or fetches.
    static func assertInert(_ root: XMLElement) throws {
        let banned: Set<String> = ["script", "iframe", "object", "embed", "link", "base", "form", "svg", "math", "video", "audio", "source", "a", "input",
                                   "button", "frame", "applet"]
        let src = try NSRegularExpression(pattern: "^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$")
        for e in [root] + descendants(root) {
            #expect(!banned.contains(e.name ?? ""))
            for a in e.attributes ?? [] {
                let name = a.name ?? ""
                #expect(!name.lowercased().hasPrefix("on"), "\(e.name ?? "") has \(name)")
                #expect(name != "href")
                #expect(name != "srcset")
                if name == "src" {
                    let v = a.stringValue ?? ""
                    #expect(src.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil)
                }
            }
        }
        let styles = all(root, "style")
        try #require(styles.count == 1)
        #expect(!textOf(styles[0]).contains("url("))
        #expect(!textOf(styles[0]).contains("@import"))
        let csp = all(root, "meta").first { attr($0, "http-equiv") == "Content-Security-Policy" }
        #expect(attr(csp, "content")?.contains("default-src 'none'") == true)
    }

    static func descendants(_ e: XMLElement) -> [XMLElement] {
        (e.children ?? []).compactMap { $0 as? XMLElement }.flatMap { [$0] + descendants($0) }
    }

    /// A PDF string as UTF-16BE hex with its byte order mark (PDFsharp's Unicode encoding).
    static func unicodeHex(_ s: String) -> String {
        "<FEFF" + s.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    /// A page with a picture, and a Figure tag saying what it is (with a box: `withBox`), the document's language es-PR.
    static func taggedPdf(_ alt: String, withBox: Bool = true) -> [UInt8] {
        let image = ExportTestPdf.image(40, 30) { x, y in (UInt8(x * 6), UInt8(y * 8), 200) }
        // PDF space: y up from the bottom of the 792 pt page; the picture at (72, 100) from the top, 160 x 120.
        let attributes = withBox ? " /A << /O /Layout /BBox [72 572 232 692] >>" : ""
        return Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 7 0 R /Lang (es-PR) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 "
                + "/BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> /XObject << /Im1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 11 Tf 72 720 Td (Sales report for the year) Tj ET q 160 0 0 120 72 572 cm /Im1 Do Q"),
            image,
            "<< /Type /StructElem /S /Figure /Alt \(unicodeHex(alt)) /Pg 3 0 R /P 7 0 R\(attributes) >>",
            "<< /Type /StructTreeRoot /K 6 0 R >>",
        ])
    }

    static func line(_ s: String, _ x: Double, _ y: Double, size: Double = 11, bold: Bool = false, mono: Bool = false) -> ExportLine {
        var span = ExportSpan(s, mono ? "Courier" : "Arial", size, bold, false, 0, RectD(x, y, Double(s.utf16.count) * size * 0.5, size * 1.2))
        span.mono = mono
        return ExportLine([span], span.box)
    }

    static func page(_ lines: [ExportLine], _ images: [ExportImage] = []) -> ExportPage { ExportPage(612, 792, lines, images, []) }

    @Test func oneFileWithRealHeadingsParagraphsListsTablesAndPictures() throws {
        let html = try Self.html(ExportTestPdf.make())
        let root = try Self.dom(html)
        try Self.assertInert(root)
        #expect(root.name == "html")
        #expect(!html.contains("http:"))
        #expect(!html.contains("https:"))
        #expect(Self.all(root, "title").map(Self.textOf) == ["Sample"])
        #expect(Self.attr(Self.all(root, "meta").first, "charset") == "utf-8")

        #expect(Self.all(root, "h1").map(Self.textOf) == ["Quarterly Report"])
        #expect(Self.all(root, "h2").map(Self.textOf) == ["Summary", "Prices", "Two Columns"])
        #expect(Self.all(root, "p").map(Self.textOf).contains(ExportTestPdf.para1))
        let lists = Self.all(root, "ul")
        try #require(lists.count == 1)
        #expect(Self.children(lists[0], "li").map(Self.textOf) == ExportTestPdf.bullets)

        let tables = Self.all(root, "table")
        try #require(tables.count == 1)
        let thead = try #require(Self.children(tables[0], "thead").first), tbody = try #require(Self.children(tables[0], "tbody").first)
        #expect(Self.all(thead, "th").map(Self.textOf) == ExportTestPdf.table[0])
        #expect(Self.all(thead, "th").allSatisfy { Self.attr($0, "scope") == "col" })
        #expect(Self.children(Self.children(tbody, "tr")[1], "td").map(Self.textOf) == ExportTestPdf.table[2])

        let images = Self.all(root, "img")
        try #require(images.count == 1)
        #expect(Self.attr(images[0], "src")?.hasPrefix("data:image/png;base64,") == true)
        #expect(Self.attr(images[0], "alt") != nil)
        #expect(Self.attr(images[0], "width") == "213") // 160 pt
    }

    @Test func readsInOrderAcrossColumnsAndPages() throws {
        let root = try Self.dom(try Self.html(ExportTestPdf.make()))
        let text = Self.textOf(try #require(Self.children(root, "body").first))
        let order = ["Quarterly Report", "Summary", ExportTestPdf.para1, ExportTestPdf.bullets[2], "Prices", "Apples", "Figure 1. A picture.", "Two Columns"]
            .map { text.range(of: $0).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? -1 }
        #expect(!order.contains(-1))
        #expect(order == order.sorted())
    }

    @Test func reflowsWithNoFixedWidths() throws {
        let html = try Self.html(ExportTestPdf.make())
        let root = try Self.dom(html)
        #expect(Self.all(root, "style").map(Self.textOf).first?.contains("max-width:100%") == true)
        #expect(Self.attr(Self.all(root, "meta").first { Self.attr($0, "name") == "viewport" }, "content") == "width=device-width, initial-scale=1")
        #expect(!html.contains("position:"))
        #expect(!Self.all(root, "p").contains { Self.attr($0, "style") != nil })
    }

    @Test func everythingFromThePdfIsEscaped() throws {
        let evil = "<script>alert(1)</script> <img src=x onerror=alert(2)> \"quoted\" 'single' & &amp; ]]> <!-- javascript:alert(3)"
        let alt = "\"><script>alert(4)</script><img src=http://example.com/x onerror=alert(5)>"
        let title = "</title><script>alert(6)</script>"
        var picture = ExportImage(TestImages.png(4, 4) { _, _ in (1, 2, 3, 255) }, "png", 4, 4, RectD(72, 200, 40, 40))
        picture.alt = alt
        let html = try Self.html([Self.page([Self.line(evil, 72, 72), Self.line(evil, 72, 120, size: 30, bold: true)], [picture])], title: title)
        let root = try Self.dom(html)
        try Self.assertInert(root)
        #expect(Self.all(root, "title").map(Self.textOf) == [title])
        #expect(Self.all(root, "img").map { Self.attr($0, "alt") } == [alt])
        #expect(Self.textOf(try #require(Self.children(root, "body").first)).contains(evil))
    }

    @Test func aTableOrListFromThePdfCantBreakOutEither() throws {
        let evil = "</td></tr></table><script>alert(1)</script>"
        func l(_ x: Double, _ y: Double) -> ExportLine { Self.line(String(evil.prefix(8)) + "\(Int(x))\(Int(y))", x, y) }
        let rows = (0..<4).flatMap { r in [l(72, 100 + Double(r) * 20), l(300, 100 + Double(r) * 20), l(500, 100 + Double(r) * 20)] }
        let list = [Self.line("\u{2022} </li><script>alert(2)</script>", 72, 300), Self.line("\u{2022} second", 72, 316)]
        try Self.assertInert(try Self.dom(try Self.html([Self.page(rows + list)])))
    }

    @Test func charactersHtmlForbidsAreDropped() throws {
        // Swift's literals refuse noncharacters, so they are made from their numbers.
        func c(_ v: UInt32) -> String { String(Character(Unicode.Scalar(v)!)) }
        let bad = "a\u{1}b\u{8}c\u{7F}d\u{85}e" + c(0xFDD0) + "f" + c(0xFFFE) + "gh" + c(0x10FFFE) + "ij"
        let root = try Self.dom(try Self.html([Self.page([Self.line(bad, 72, 72)])], title: "t\u{1}i"))
        #expect(Self.textOf(try #require(Self.children(root, "body").first)).contains("abcdefgh" + "ij"))
        #expect(Self.all(root, "title").map(Self.textOf) == ["ti"])
    }

    @Test func anEmptyTitleStillGivesATitle() throws {
        let root = try Self.dom(try Self.html([Self.page([Self.line("Some words on the page", 72, 72)])], title: "  "))
        #expect(!(Self.all(root, "title").first.map(Self.textOf) ?? "").isBlank)
    }

    @Test func numberedItemsAreAnOrderedListThatKeepsItsNumbers() throws {
        let lines = [
            Self.line("3. Third step of the job", 72, 100), Self.line("4. Fourth step of the job", 72, 116),
            Self.line("Some paragraph between the lists, long enough to be a paragraph of its own.", 72, 150),
            Self.line("a) Letter item one", 72, 190), Self.line("b) Letter item two", 72, 206),
            Self.line("(iv) Roman typed item", 72, 240), Self.line("(v) Roman typed item two", 72, 256),
        ]
        let root = try Self.dom(try Self.html([Self.page(lines)]))
        let ols = Self.all(root, "ol")
        try #require(ols.count >= 2)
        #expect(Self.children(ols[0], "li").map(Self.textOf) == ["Third step of the job", "Fourth step of the job"])
        #expect(Self.children(ols[0], "li").map { Self.attr($0, "value") } == ["3", "4"])
        #expect(Self.attr(ols[1], "type") == "a")
        #expect(Self.children(ols[1], "li").map(Self.textOf) == ["Letter item one", "Letter item two"])
        // Markers no list can show stay as typed.
        let typed = Self.all(root, "ul")
        try #require(typed.count == 1)
        #expect(Self.children(typed[0], "li").map(Self.textOf) == ["(iv) Roman typed item", "(v) Roman typed item two"])
        #expect(Self.attr(typed[0], "class") == "typed")
    }

    @Test func digitsOfOtherScriptsStayAsTyped() throws {
        // "٣." isn't a letter list numbered 1571, and "1٣." mustn't stop the export.
        let lines = [Self.line("\u{663}. Arabic numbered item", 72, 100), Self.line("1\u{663}. Mixed numbered item", 72, 116)]
        let root = try Self.dom(try Self.html([Self.page(lines)]))
        #expect(Self.all(root, "ol").isEmpty)
        #expect(Self.textOf(root).contains("\u{663}. Arabic numbered item"))
    }

    @Test func stressTagsAlwaysNest() throws {
        // Bold ends before italic does: "<strong><em>alpha </strong>beta</em>" isn't HTML.
        func span(_ s: String, _ x: Double, _ bold: Bool, _ italic: Bool) -> ExportSpan {
            ExportSpan(s, "Arial", 11, bold, italic, 0, RectD(x, 300, Double(s.utf16.count) * 5.5, 13.2))
        }
        let spans = [span("Plain words then ", 72, false, false), span("alpha ", 160, true, true), span("beta", 193, false, true), span(" and the end of it.", 215, false, false)]
        let lines = (0..<6).map { Self.line("Body text in the document fills this line.", 72, 100 + Double($0) * 14) }
            + [ExportLine(spans, .fromEdges(72, 300, 320, 313.2))]
        let root = try Self.dom(try Self.html([Self.page(lines)]))
        #expect(Self.all(root, "em").map(Self.textOf).joined() == "alpha beta")
        #expect(Self.all(root, "strong").map(Self.textOf) == ["alpha "])
    }

    @Test func aDeeperIndentNestsTheList() throws {
        let lines = [Self.line("\u{2022} Outer one here", 72, 100), Self.line("\u{2022} Inner one here", 100, 116),
                     Self.line("\u{2022} Inner two here", 100, 132), Self.line("\u{2022} Outer two here", 72, 148)]
        let root = try Self.dom(try Self.html([Self.page(lines)]))
        let outer = try #require(Self.all(root, "ul").first)
        #expect(Self.children(outer, "li").count == 2)
        let inner = try #require(Self.children(Self.children(outer, "li")[0], "ul").first)
        #expect(Self.children(inner, "li").map(Self.textOf) == ["Inner one here", "Inner two here"])
    }

    @Test func headingsNeverSkipALevel() throws {
        let lines = [Self.line("Small heading here", 72, 60, size: 16, bold: true), Self.line("Bigger heading here", 72, 100, size: 32, bold: true),
                     Self.line("Second bigger heading", 72, 160, size: 32, bold: true)]
            + (0..<20).map { Self.line("Body text in the document fills this line.", 72, 220 + Double($0) * 14) }
        let root = try Self.dom(try Self.html([Self.page(lines)]))
        let levels = Self.descendants(root).compactMap { e -> Int? in
            guard let n = e.name, n.count == 2, n.first == "h", let d = Int(n.dropFirst()), (1...6).contains(d) else { return nil }
            return d
        }
        #expect(levels.first == 1)
        for i in levels.indices.dropFirst() { #expect(levels[i] <= levels[i - 1] + 1) }
    }

    private static func cell(_ s: String, colSpan: Int = 1) -> DocCell {
        DocCell([DocParagraph([ExportSpan(s, "Arial", 11, false, false, 0, RectD(0, 0, 10, 10))], RectD(0, 0, 10, 10))], colSpan: colSpan)
    }

    private static func write(_ table: DocTable) throws -> String {
        let page = DocPage(width: 612, height: 792, content: RectD(72, 72, 300, 80), blocks: [.table(table)])
        return HtmlWriter.html(DocLayoutResult(pages: [page], header: nil, footer: nil), "T", nil)
    }

    @Test func aTablesEveryRowCoversEveryColumn() throws {
        let table = DocTable([
            [Self.cell("spans two", colSpan: 2), Self.cell("c")],
            [Self.cell("short")],
            [Self.cell("spans two more", colSpan: 2), Self.cell("x"), Self.cell("over the edge")],
            [],
        ], [100, 100, 100], true, RectD(72, 72, 300, 80))
        let root = try Self.dom(try Self.write(table))
        let rows = Self.all(root, "tr")
        #expect(rows.count == 4)
        // The second column never starts a cell except where padding does: every row adds up to the same width.
        let widths = rows.map { r in (r.children ?? []).compactMap { $0 as? XMLElement }.reduce(0) { $0 + (Int(Self.attr($1, "colspan") ?? "1") ?? 1) } }
        #expect(Set(widths).count == 1)
    }

    @Test func aColumnNoCellStartsInIsTakenOut() throws {
        let table = DocTable([[Self.cell("a", colSpan: 2), Self.cell("b")], [Self.cell("c", colSpan: 2), Self.cell("d")]], [100, 100, 100], true, RectD(72, 72, 300, 80))
        let root = try Self.dom(try Self.write(table))
        #expect(Self.all(root, "td").allSatisfy { Self.attr($0, "colspan") == nil })
    }

    @Test func aRunningHeaderAndFooterAppearOnce() throws {
        let pages = (1...4).map { i in
            Self.page([Self.line("The Document Name", 72, 30, size: 9), Self.line("Chapter text on page \(i) that goes on for a while.", 72, 100),
                       Self.line("Page \(i)", 72, 750, size: 9)])
        }
        let root = try Self.dom(try Self.html(pages))
        let body = Self.textOf(try #require(Self.children(root, "body").first))
        #expect(Self.all(root, "header").map(Self.textOf).first?.contains("The Document Name") == true)
        #expect(body.components(separatedBy: "The Document Name").count == 2)
        #expect(!body.contains("Page 2"))
        #expect(Self.all(root, "main").map(Self.textOf).first?.contains("Chapter text on page 3") == true)
    }

    @Test func theLanguageIsThePdfsOrIsLeftOutWhenItCantBeTrusted() throws {
        let tagged = Self.taggedPdf("alt")
        let root = try Self.dom(try Self.html(tagged, options: ExportOptions(source: tagged)))
        #expect(Self.attr(root, "lang") == "es-PR")
        let bad = try Self.dom(try Self.html([Self.page([Self.line("x y z", 72, 72)])], language: "\"><script>"))
        #expect(Self.attr(bad, "lang") == nil)
    }

    @Test(arguments: [true, false]) func altTextComesFromTheTags(_ withBox: Bool) throws {
        let alt = "A chart of sales & <costs>"
        let pdf = Self.taggedPdf(alt, withBox: withBox)
        let root = try Self.dom(try Self.html(pdf, options: ExportOptions(source: pdf)))
        #expect(Self.all(root, "img").map { Self.attr($0, "alt") } == [alt])
    }

    @Test func withoutTagsAPictureHasAnEmptyAlt() throws {
        let pdf = ExportTestPdf.make()
        let root = try Self.dom(try Self.html(pdf, options: ExportOptions(source: pdf)))
        #expect(Self.all(root, "img").map { Self.attr($0, "alt") } == [""])
    }

    @Test func anUnreadableSourceOnlyLosesTheAltText() throws {
        let root = try Self.dom(try Self.html(ExportTestPdf.make(), options: ExportOptions(source: [1, 2, 3])))
        #expect(!Self.all(root, "h1").isEmpty)
    }
}
