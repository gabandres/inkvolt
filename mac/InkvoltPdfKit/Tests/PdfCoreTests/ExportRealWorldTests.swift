import Foundation
import Testing
@testable import PdfCore

/// Ported from ExportRealWorldTests.cs, every test: export fixes found on real documents (turned tables, transparent
/// pictures, hyphens, indented blocks, charts, close number columns). Adapted: the transparent picture's PDF is written by
/// hand (an RGB image with a gray /SMask, what PDFsharp writes for a PNG with alpha); the Excel check reads the sheet with
/// `OpenXmlPackage`.
struct ExportRealWorldTests {
    private func line(_ text: String, _ x: Double, _ y: Double, _ size: Double = 10, turn: Int = 0) -> ExportLine {
        let w = Double(text.utf16.count) * size * 0.5
        let h = size * 1.15
        // A turned line's box stands across the page: tall and narrow.
        let box = turn == 1 || turn == 3 ? RectD(x, y, h, w) : RectD(x, y, w, h)
        var l = ExportLine.of([ExportSpan(text, "Arial", size, false, false, 0, box)], sideways: turn != 0)
        l.turn = turn
        return l
    }

    private func paragraphs(_ page: DocPage) -> [String] { page.paragraphs.map(\.text) }

    @Test func aPageOfTextTurnedSidewaysIsLaidOutTurnedBackAsALandscapePage() throws {
        // A portrait page whose text reads bottom to top (a landscape table set on its side), with an upright footer.
        // Lines read upward: the first line is leftmost, each line's text runs up the page.
        let lines = [
            line("Table A-2. Households by income", 60, 300, 12, turn: 3),
            line("The first paragraph of the turned page runs over", 90, 200, 10, turn: 3),
            line("two lines that belong together in one paragraph.", 102, 200, 10, turn: 3),
            line("U.S. Census Bureau", 400, 760, 8),
        ]
        let page = ExportPage(612, 792, lines, [], [])
        let up = DocLayout.upright(page)
        #expect(up.width == 792 && up.height == 612)
        #expect(up.lines.filter { $0.text.hasPrefix("T") }.allSatisfy { !$0.sideways })

        let laid = DocLayout.analyze([page])[0]
        #expect(laid.width > laid.height) // exported as a landscape section
        let paras = paragraphs(laid)
        let joined = "The first paragraph of the turned page runs over two lines that belong together in one paragraph."
        #expect(paras.contains(joined))
        #expect(paras.contains("U.S. Census Bureau")) // the upright footer is now the sideways part: one paragraph
        let title = try #require(paras.firstIndex(of: "Table A-2. Households by income"))
        #expect(title < paras.firstIndex(of: joined)!)
    }

    @Test func aFewSidewaysLinesOnAnUprightPageReadAsOneParagraph() {
        let body = Array(repeating: "upright body text", count: 4).joined(separator: " ")
        let lines = [
            line(body, 72, 100), line(body, 72, 114), line(body, 72, 128),
            // A margin stamp of two lines reading upward.
            line("arXiv:1512.03385v1 [cs.CV] 10 Dec", 20, 300, 10, turn: 3),
            line("2015 submitted version", 32, 360, 10, turn: 3), // both lines start at the same bottom
        ]
        let laid = DocLayout.analyze([ExportPage(612, 792, lines, [], [])])[0]
        #expect(laid.width < laid.height)
        let paras = paragraphs(laid)
        #expect(paras.count == 2)
        #expect(paras.contains("arXiv:1512.03385v1 [cs.CV] 10 Dec 2015 submitted version"))
    }

    @Test func turningAPageMapsBoxesIntoTheTurnedFrame() {
        let page = ExportPage(600, 800, [line("x", 10, 20, 10, turn: 3)], [], [RectD(100, 200, 50, 0)])
        let up = page.turned(3)
        #expect(up.width == 800 && up.height == 600)
        // (x, y) -> (h - y, x): the rule at y 200 from x 100 to 150 becomes a vertical rule at x 600.
        #expect(up.rules[0] == RectD(600, 100, 0, 50))
        #expect(up.lines[0].turn == 0)
        #expect(page.turned(1).rules[0] == RectD(200, 450, 0, 50)) // (x, y) -> (y, w - x)
    }

    @Test(arguments: [(1.0, 0.0, 0), (0.99, 0.05, 0), (0.0, -1.0, 3), (0.0, 1.0, 1), (-1.0, 0.0, 2)])
    func turnsFromBaselineDirections(_ dx: Double, _ dy: Double, _ turn: Int) { #expect(ExportLine.turnOf(dx, dy) == turn) }

    private func layout(_ lines: ExportLine...) -> DocLayoutResult { DocLayout.analyzeDocument([ExportPage(612, 792, lines, [], [])]) }

    @Test func softHyphensAtLineEndsRejoinTheWordAndHardHyphensStayInSuchDocuments() {
        let r = layout(
            line("Income inequality and access to educa\u{AD}", 72, 100),
            line("tion changed little for the equivalence-", 72, 112),
            line("adjusted measure in this ex\u{AD}ample year.", 72, 124))
        #expect(paragraphs(r.pages[0]) == [
            "Income inequality and access to education changed little for the equivalence-adjusted measure in this example year.",
        ])
    }

    @Test func hardHyphensAtLineEndsAreDroppedUnlessBothHalvesAreWordsTheDocumentUses() throws {
        let r = layout(
            line("The rate of change was measured in the study with an exam-", 72, 100),
            line("ple of the method; the result was fairly steady and well-", 72, 112),
            line("known. Readers know the well known steady example well.", 72, 124))
        let paras = paragraphs(r.pages[0])
        try #require(paras.count == 1)
        #expect(paras[0].contains("an example of the method"))
        #expect(paras[0].contains("well-known."))
    }

    @Test func anIndentedJustifiedBlockStaysOneParagraphBesideWiderText() {
        // An abstract indented on both sides (right edge 480) above a wider footnote (right edge 560): its lines end at
        // 480, short of the column's edge, but they fill the block.
        func l(_ n: Int) -> String { String(repeating: "a", count: n) }
        let r = layout(
            line("\(l(30)) \(l(30)) \(l(9))", 120, 100),  // 70 chars x 5 = 350 wide: 120..470
            line("\(l(30)) \(l(31)) \(l(8))", 120, 112),
            line("\(l(30)) \(l(30)) \(l(9))", 120, 124),
            line("\(l(1)) \(l(30)) \(l(30)) end.", 120, 136), // its first word is short enough to fit the column's edge
            line("\(l(20)) last line.", 120, 148),
            line("Footnote " + String(repeating: "f", count: 88), 72, 200))
        let paras = paragraphs(r.pages[0])
        #expect(paras.count == 2)
        #expect(paras.first?.hasSuffix("last line.") == true)
    }

    @Test func shortLinesOfAnAddressStayApart() {
        let r = layout(
            line("Bermuda Supplies Ltd.", 72, 100),
            line("12 Harbour Road", 72, 112),
            line("Hamilton", 72, 124),
            line("Thank you for your order, which ships on Monday with the usual courier service.", 72, 150))
        #expect(paragraphs(r.pages[0]).count == 4)
    }

    @Test func aChartDrawnWithManyPathsAndFewLabelsIsAFigureAndARuledTableIsNot() throws {
        // A bar chart: 12 bars and 2 axes, with a few labels.
        var chart: [(box: RectD, stroked: Bool)] = [(RectD(100, 100, 0.5, 200), true), (RectD(100, 300, 300, 0.5), true)]
        for i in 0..<12 { chart.append((RectD(110 + Double(i) * 24, 300 - 10 * Double(i + 3), 18, 10 * Double(i + 3)), false)) }
        let labels = [line("2010", 110, 304, 8), line("2020", 360, 304, 8), line("Income", 86, 180, 8)]
        let figures = DocLayout.figureRegions(chart, labels, 612, 792)
        try #require(figures.count == 1)
        let f = figures[0]
        #expect(f.contains(100, 100) && f.contains(400, 300) && f.contains(88, 182)) // the labels go with it

        // A ruled 4 x 4 table with text in every cell: rules but not a figure.
        var grid: [(box: RectD, stroked: Bool)] = []
        for k in 0...4 {
            grid.append((RectD(100, 400 + Double(k) * 20, 320, 0.5), true))
            grid.append((RectD(100 + Double(k) * 80, 400, 0.5, 80), true))
        }
        for k in 0..<4 { grid.append((RectD(100 + Double(k) * 80, 400, 80, 20), false)) } // header shading
        let cells = (0..<16).map { i in line("v\(i)", 105 + Double(i % 4) * 80, 404 + Double(i / 4) * 20, 8) }
        #expect(DocLayout.figureRegions(grid, cells, 612, 792).isEmpty)
    }

    @Test func numberColumnsSetCloseTogetherSplitButWordsWithWideSpacesDoNot() {
        // "28.54" then "10.02" 14 pt later (size 9): two columns.
        var chars: [(text: String, from: Double, to: Double, size: Double)] = []
        func word(_ w: String, _ x: Double) {
            var x = x
            for c in w {
                chars.append((String(c), x, x + 4.5, 9))
                x += 4.5
            }
        }
        word("28.54", 100)
        chars.append((" ", 122.5, 136, 9))
        word("10.02", 136.5)
        #expect(ExportLine.splitAtColumnGaps(chars).map { [$0.start, $0.end] } == [[0, 5], [6, 11]])

        chars.removeAll()
        word("hello", 100)
        chars.append((" ", 122.5, 136, 9))
        word("world", 136.5) // the same gap between words: justified text, one line
        #expect(ExportLine.splitAtColumnGaps(chars).map { [$0.start, $0.end] } == [[0, 11]])
        #expect(ExportLine.numberLike("\u{2013}") && ExportLine.numberLike("(3.5)") && !ExportLine.numberLike("top-1"))
    }

    @Test func aLongTableCutIntoRowGroupsIsOneTableAndLeadersAreDroppedInExcel() throws {
        // Two groups of rows with a gap between them, as long statistical tables are set.
        let page = ExportPage(612, 792, [
            line("2023 . . . . .", 72, 100, 9), line("12", 160, 100, 9), line("7.5", 200, 100, 9),
            line("2022 . . . . .", 72, 112, 9), line("11", 160, 112, 9), line("7.1", 200, 112, 9),
            line("2021 . . . . .", 72, 124, 9), line("10", 160, 124, 9), line("6.8", 200, 124, 9),
            line("2019 . . . . .", 72, 150, 9), line("9", 160, 150, 9), line("6.0", 200, 150, 9),
            line("2018 . . . . .", 72, 162, 9), line("8", 160, 162, 9), line("5.5", 200, 162, 9),
            line("2017 . . . . .", 72, 174, 9), line("7", 160, 174, 9), line("5.1", 200, 174, 9),
        ], [], [])
        let tables = DocumentExport.tables([(1, page)])
        try #require(tables.count == 1)
        #expect(tables[0].table.rows.count == 6)

        let sink = MemorySink()
        try XlsxWriter.write(sink, tables, nil)
        let sheet = try OpenXmlPackage(sink.bytes).xml("xl/worksheets/sheet1.xml")
        let first = OpenXmlPackage.elements(sheet, "c")[0]
        #expect(OpenXmlPackage.elements(first, "v").first.map(OpenXmlPackage.text) == "2023") // leaders gone, so it is a number
    }

    @Test func aTransparentPictureKeepsItsTransparency() throws {
        // Left half fully transparent, right half opaque red: an RGB image with a gray soft mask.
        let pdf = Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>",
            4: Core1TestPdf.stream("q 80 0 0 80 100 662 cm /Im Do Q"),
            5: ExportTestPdf.image(40, 40, sMask: 6) { x, _ in x < 20 ? (0, 0, 0) : (220, 20, 20) },
            6: ExportTestPdf.grayImage(40, 40) { x, _ in x < 20 ? 0 : 255 },
        ])
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let images = try engine.exportPage(0, images: true).images
        try #require(images.count == 1)
        #expect(images[0].ext == "png")
        let (w, h, colorType, pixels) = try decodeUnfilteredPng(images[0].data)
        #expect(colorType == 6) // RGBA
        #expect(pixels[(h / 2 * w + 2) * 4 + 3] == 0)                                     // left: transparent
        #expect(pixels[(h / 2 * w + w - 3) * 4 + 3] == 255 && pixels[(h / 2 * w + w - 3) * 4] > 200) // right: opaque red
    }
}
