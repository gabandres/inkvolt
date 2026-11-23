import Foundation
import Testing
@testable import PdfCore

/// Ported from AreaCopyTests.cs: Copy Text and Copy as Table from an area boxed with Snapshot (roadmap 4.6, `AreaCopy`).
/// The Mac's lines end with LF (Windows' with CR LF); TheClipboardsHtmlHeaderPointsAtTheFragment keeps its HTML and tab
/// checks only, as the Mac's pasteboard takes HTML without Windows' CF_HTML header (`ClipboardHtml`).
struct AreaCopyTests {
    private static func page(_ pdf: [UInt8], _ page: Int = 0) throws -> ExportPage {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.exportPage(page, images: false)
    }

    private static func line(_ text: String, _ x: Double, _ y: Double, _ size: Double = 10) -> ExportLine {
        let w = Double(text.count) * size * 0.5
        return ExportLine.of([ExportSpan(text, "Arial", size, false, false, 0, RectD(x, y, w, size * 1.15))])
    }

    private static func tableBox(_ page: ExportPage) throws -> RectD {
        let tables = DocLayout.analyze([page]).flatMap(\.blocks).compactMap(\.table)
        return try #require(tables.count == 1 ? tables[0].box : nil)
    }

    private static func cells(_ table: AreaTable) -> [[String]] { table.rows.map { $0.map(\.text) } }

    @Test func TheTableTheExcelExportFindsIsCopiedCellForCell() throws {
        let page = try Self.page(ExportTestPdf.make())
        let box = try Self.tableBox(page)
        let table = try AreaCopy.table(AreaCopy.clip(page, RectD(box.x - 6, box.y - 6, box.width + 12, box.height + 12)))
        #expect(Self.cells(table) == ExportTestPdf.table)
        #expect(table.tsv() == "Item\tQty\tPrice\nApples\t4\t1.20\nPears\t12\t3.05\nPlums\t7\t0.99\n")
        #expect(table.html().hasPrefix("<table><tr><td>Item</td><td>Qty</td>"))
        #expect(table.columnCount == 3)

        // The same table without its rules: found by its columns, as the export finds it.
        let bare = try Self.page(ExportTestPdf.make(ruledTable: false))
        var bareBox = try Self.tableBox(bare)
        bareBox.x -= 4
        bareBox.width += 8
        #expect(Self.cells(try AreaCopy.table(AreaCopy.clip(bare, bareBox))) == ExportTestPdf.table)
    }

    @Test func ColumnsTheTableFinderDoesntTakeAreStillCells() throws {
        // Two rows of three short columns: too few for a table, still cells when copied as one.
        let page = ExportPage(612, 792, [Self.line("Name", 72, 100), Self.line("Qty", 200, 100), Self.line("Total", 300, 100),
                                         Self.line("Bolts", 72, 120), Self.line("40", 200, 120), Self.line("$12.00", 300, 120),
                                         Self.line("Far away", 72, 600)], [], [])
        let table = try AreaCopy.table(AreaCopy.clip(page, RectD(60, 90, 300, 50)))
        #expect(table.tsv() == "Name\tQty\tTotal\nBolts\t40\t$12.00\n")
        #expect(try AreaCopy.table(AreaCopy.clip(page, RectD(0, 300, 50, 50))).isEmpty)
    }

    @Test func OneCharacterLinesOnADiagonal_AreNoTableOfMillionsOfCells_ButText() throws {
        // Lines each its own row and its own column: 20,000 made 400 million cells, out of memory in Html(); 6,000 make 36 million.
        let lines = (0..<6_000).map { i in
            ExportLine.of([ExportSpan("x", "Arial", 1, false, false, 0, RectD(Double(i) * 0.1, Double(i) * 0.13, 0.05, 0.05))])
        }
        let page = ExportPage(612, 792, lines, [], [])
        let clock = ContinuousClock.now
        let table = try AreaCopy.table(AreaCopy.clip(page, RectD(0, 0, 612, 792)))
        #expect(ContinuousClock.now - clock < .seconds(30))
        #expect(table.tooLarge)
        #expect(table.rows.isEmpty)
        #expect(table.html() == "<table></table>")
        #expect(AreaCopy.text(AreaCopy.clip(page, RectD(0, 0, 612, 792))).contains("x")) // what is copied instead

        // At the limit's edge a table is still a table: 300 rows of 300 columns is 90,000 cells.
        let grid = (0..<300).map { i in
            ExportLine.of([ExportSpan("y", "Arial", 1, false, false, 0, RectD(Double(i) * 2, Double(i) * 2.6, 1, 1))])
        }
        let square = try AreaCopy.table(ExportPage(612, 792, grid, [], []))
        #expect(!square.tooLarge)
        #expect(square.rows.count == 300)
        #expect(square.columnCount == 300)
        let stop = CancelToken()
        stop.cancel()
        #expect(throws: CancellationError.self) { try AreaCopy.table(ExportPage(612, 792, grid, [], []), cancel: stop) }
    }

    @Test func TextIsCutToTheBoxAndReadInOrder() throws {
        let page = try Self.page(ExportTestPdf.make())
        let all = AreaCopy.text(AreaCopy.clip(page, RectD(0, 0, page.width, page.height)))
        #expect(all.contains(ExportTestPdf.para1))
        #expect(!all.contains("\n\n") && !all.contains("\r"))

        // Half a line: the characters whose middles are in the box, the line it only grazes left out.
        let line = ExportPage(612, 792, [Self.line("Hello brave new world", 100, 100), Self.line("Next line", 100, 115)], [], [])
        let span = line.lines[0].spans[0].box
        let text = AreaCopy.text(AreaCopy.clip(line, RectD(span.x + span.width * 6 / 21.0 - 1, span.y, span.width * 5 / 21.0 + 2, span.height + 2)))
        #expect(text.trimmingCharacters(in: .whitespaces) == "brave")
        #expect(!AreaCopy.hasText(line, RectD(100, 300, 100, 100)))
        #expect(AreaCopy.hasText(line, RectD(90, 95, 30, 15)))
    }

    @Test func ALineReadingUpwardsIsCutAlongItsOwnDirection() {
        // A sideways label reading bottom to top: "ABCDEF" with A at the bottom.
        let span = ExportSpan("ABCDEF", "Arial", 10, false, false, 0, RectD(100, 100, 12, 60))
        let page = ExportPage(612, 792, [ExportLine([span], span.box, sideways: true, turn: 3)], [], [])
        let clipped = AreaCopy.clip(page, RectD(90, 130, 40, 40)) // the lower half: A, B, C
        #expect(clipped.lines.map(\.text) == ["ABC"])
    }

    /// Reads a dark box as one word, wherever it is in the picture it's given.
    private final class BoxReader: TextRecognizer, @unchecked Sendable {
        var seen = (width: 0, height: 0)

        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            seen = (image.width, image.height)
            var x0 = image.width, y0 = image.height, x1 = -1, y1 = -1
            for y in 0..<image.height {
                for x in 0..<image.width where image.pixels[(y * image.width + x) * 3] < 100 {
                    (x0, y0, x1, y1) = (min(x0, x), min(y0, y), max(x1, x), max(y1, y))
                }
            }
            return x1 < 0 ? [] : [OcrWord("Total", RectD(Double(x0), Double(y0), Double(x1 - x0 + 1), Double(y1 - y0 + 1)))]
        }
    }

    @Test func AnAreaWithoutTextIsReadFromItsPictureAndItsWordsLandWhereTheyAre() throws {
        // A scan's stand-in: a black box drawn at (200, 300) 80 × 20 points, no text.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.stream("0 g 200 472 80 20 re f"),
        ])
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let page = try engine.exportPage(0, images: false)
        let area = RectD(150, 280, 200, 60)
        #expect(!AreaCopy.hasText(page, area))
        let reader = BoxReader()
        let words = try AreaCopy.recognize(engine, 0, area, reader)
        let word = try #require(words.count == 1 ? words[0] : nil)
        #expect(word.text == "Total")
        #expect(abs(word.rect.x - 200) < 1.0)
        #expect(abs(word.rect.y - 300) < 1.0)
        #expect(abs(word.rect.width - 80) < 1.0)
        #expect((830...836).contains(reader.seen.width)) // 200 points at 300 dpi
        #expect(AreaCopy.text(AreaCopy.fromWords(page, [word])) == "Total")

        // Out of the page, or no area: nothing read.
        #expect(try AreaCopy.recognize(engine, 0, RectD(700, 900, 50, 50), reader).isEmpty)
        #expect(try AreaCopy.recognize(engine, 3, area, reader).isEmpty)
        #expect(try AreaCopy.recognize(engine, 0, RectD(.nan, 0, 10, 10), reader).isEmpty)
    }

    @Test func TheClipboardsHtmlHeaderPointsAtTheFragment() {
        let fragment = AreaTable([[AreaCell("Año <1>"), AreaCell("€ & co", colSpan: 2)]]).html()
        #expect(fragment == "<table><tr><td>Año &lt;1&gt;</td><td colspan=\"2\">€ &amp; co</td></tr></table>")

        // A tab in a cell can't split it.
        #expect(AreaTable([[AreaCell("a\tb"), AreaCell("c")]]).tsv() == "a b\tc\n")
    }
}
