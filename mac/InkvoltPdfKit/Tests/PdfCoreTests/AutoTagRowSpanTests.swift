import Foundation
import Testing
@testable import PdfCore

/// Ported from AutoTagRowSpanTests.cs (same names): Make Accessible (roadmap 2.4): a ruled table's cell that spans rows (no
/// rule under it across its columns) is one cell, tagged with RowSpan, its text wherever it sits in it; the cells it covers
/// aren't written. Drawn with `ExportTestPdf.Canvas` (Helvetica, the Windows tests' Arial).
@Suite struct AutoTagRowSpanTests {
    /// A ruled table: "Region" spans the two header rows beside "2025" over "Q1" and "Q2"; "North" spans two rows (its name
    /// drawn in the lower one, as centered text often lands); "South" one.
    static func make() -> [UInt8] {
        table([
            ("Region", 0, 0, true), ("2025", 0, 1, true), ("Q1", 1, 1, true), ("Q2", 1, 2, true),
            ("North", 3, 0, false), ("40", 2, 1, false), ("52", 2, 2, false), ("12", 3, 1, false), ("13", 3, 2, false),
            ("South", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
        ], rows: 5, unruled: [(1, 0), (3, 0)], headerSpan: true) // none under "Region" and "North"
    }

    /// A ruled table of three columns and `rows` rows under a heading and a sentence: each rule between rows drawn across
    /// each column but those `unruled` (row, column: no rule above that row there; a row with none at all keeps a short
    /// tick at its left edge, so the grid still has its line); with `headerSpan` the first row's second cell spans the last
    /// two columns.
    private static func table(_ cells: [(text: String, row: Int, col: Int, bold: Bool)], rows: Int, unruled: [(Int, Int)],
                              headerSpan: Bool = false) -> [UInt8] {
        var p = ExportTestPdf.Canvas()
        p.text("Sales by region", "F2", 16, 72, 80)
        p.text("The table below gives the crates sold in each region by quarter of the year.", "F1", 11, 72, 110)
        let cols: [Double] = [72, 222, 342, 432]
        let top = 140.0, rowH = 20.0
        for c in cells { p.text(c.text, c.bold ? "F2" : "F1", 11, cols[c.col] + 6, top + Double(c.row) * rowH + 14) }
        for r in 0...rows {
            let y = top + Double(r) * rowH
            var drawn = 0
            for c in 0..<3 where !unruled.contains(where: { $0 == (r, c) }) {
                p.line(cols[c], y, cols[c + 1], y)
                drawn += 1
            }
            if drawn == 0 { p.line(cols[0], y, cols[0] + 8, y) }
        }
        for x in cols { p.line(x, headerSpan && x == cols[2] ? top + rowH : top, x, top + Double(rows) * rowH) }
        return ExportTestPdf.written([p])
    }

    private static func tableBlock(_ pdf: [UInt8]) throws -> TagBlock {
        let tables = try TagTest.plan(pdf).blocks.filter { $0.kind == .table }
        try #require(tables.count == 1)
        return tables[0]
    }

    private static func write(_ pdf: [UInt8]) throws -> [UInt8] {
        try AutoTag.write(pdf, nil, TagTest.plan(pdf), AccessibleOptions(title: "A test", language: "en"))
    }

    /// The table's rows as written: each TR's cells (type, RowSpan, the attributes).
    private static func writtenRows(_ tagged: [UInt8]) throws -> [[(type: String, rowSpan: Int, attributes: PObj?)]] {
        let doc = try PdfEdit.openToRead(tagged, nil)
        let tree = TagTest.tree(doc)
        let table = try #require(tree.first { $0.type == "Table" })
        let rows = tree.filter { $0.type == "TR" && $0.depth == table.depth + 1 }.map(\.elem)
        return rows.map { tr in
            let k = tr["K"]
            let kids = k.map { $0.isArray ? $0.elements : [$0] } ?? []
            return kids.filter { $0.isDict && $0.name("Type") == "StructElem" }.map { c in
                (c.name("S") ?? "", c.dict("A")?.int("RowSpan") ?? 1, c.dict("A"))
            }
        }
    }

    @Test func A_cell_spanning_rows_is_one_cell_with_its_text_wherever_it_sits() throws {
        let table = try Self.tableBlock(Self.make())
        try #require(table.rows.count == 5)
        #expect(table.headerRows == 2)
        #expect(table.headerColumn)
        let region = table.rows[0][0]
        #expect(region.text == "Region")
        #expect(region.rowSpan == 2)
        #expect(table.rows[1][0].covered)
        let north = table.rows[2][0]
        #expect(north.text == "North") // drawn in the row it covers
        #expect(north.rowSpan == 2)
        #expect(!north.sources.isEmpty)
        #expect(table.rows[3][0].covered)
        #expect(table.rows[3][0].sources.isEmpty)
        #expect(table.rows[4][0].rowSpan == 1)
        for c in table.rows.flatMap({ $0 }) where !c.covered && c != region && c != north { #expect(c.rowSpan == 1, "\(c.text)") }
    }

    @Test func Row_spans_are_written_as_RowSpan_and_covered_cells_left_out() throws {
        let tagged = try Self.write(Self.make())
        let cells = try Self.writtenRows(tagged)
        try #require(cells.count == 5)
        #expect(cells.map(\.count) == [2, 2, 3, 2, 3])
        #expect(cells[0][0].type == "TH")
        #expect(cells[0][0].rowSpan == 2)
        #expect(cells[0][1].attributes?.int("ColSpan") == 2)
        #expect(cells[2][0].type == "TH") // "North", a row header over two rows
        #expect(cells[2][0].rowSpan == 2)
        #expect(cells[2][0].attributes?.name("Scope") == "Row")
        #expect(cells[3].allSatisfy { $0.type == "TD" })
        #expect(cells[4][0].rowSpan == 1)
        try TagTest.passesTheCheck(tagged)
    }

    @Test func Export_to_Word_keeps_the_table_as_it_was() throws {
        // Row spans are for the tags: the exported table has its five rows of cells as before (text where it was drawn).
        let engine = try PdfEngine.open(Self.make())
        defer { engine.close() }
        let pages = try (0..<engine.pageCount).map { try engine.exportPage($0, images: true) }
        let tables = DocLayout.analyze(pages).flatMap(\.tables)
        try #require(tables.count == 1)
        let table = tables[0]
        try #require(table.rows.count == 5)
        #expect(table.rows[2][0].text == "")
        #expect(table.rows[3][0].text == "North")
        #expect(table.rows[3][0].covered)
        #expect(table.rows[2][0].rowSpan == 2)
    }

    @Test func A_row_all_covered_by_the_cells_above_is_no_row_of_its_own() throws {
        // Row 2 has no rule above it in any column (a tick keeps the grid's line): every cell of it continues row 1's.
        let pdf = Self.table([
            ("Fruit", 0, 0, true), ("Q1", 0, 1, true), ("Q2", 0, 2, true),
            ("Apples", 1, 0, false), ("40", 1, 1, false), ("52", 1, 2, false), ("from the hill", 2, 0, false),
            ("Pears", 3, 0, false), ("12", 3, 1, false), ("13", 3, 2, false),
            ("Plums", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
        ], rows: 5, unruled: [(2, 0), (2, 1), (2, 2)])
        let table = try Self.tableBlock(pdf)
        try #require(table.rows.count == 4)
        #expect(table.rows.allSatisfy { r in r.contains { !$0.covered } })
        #expect(table.rows[1][0].text.contains("from the hill"))
        #expect(table.rows.flatMap { $0 }.allSatisfy { $0.rowSpan == 1 })
        let tagged = try Self.write(pdf)
        #expect(try Self.writtenRows(tagged).allSatisfy { $0.count == 3 })
        try TagTest.passesTheCheck(tagged)
    }

    @Test func A_header_cell_spans_no_further_than_the_header_rows() throws {
        // "Region" has no rule under it down into the first data row: it heads the two header rows, "North" is a row of its own.
        let pdf = Self.table([
            ("Region", 0, 0, true), ("2025", 0, 1, true), ("Q1", 1, 1, true), ("Q2", 1, 2, true),
            ("North", 2, 0, false), ("40", 2, 1, false), ("52", 2, 2, false),
            ("South", 3, 0, false), ("12", 3, 1, false), ("13", 3, 2, false),
            ("East", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
        ], rows: 5, unruled: [(1, 0), (2, 0)], headerSpan: true)
        let table = try Self.tableBlock(pdf)
        #expect(table.headerRows == 2)
        #expect(table.rows[0][0].rowSpan == 2)
        #expect(table.rows[0][0].text == "Region")
        #expect(!table.rows[2][0].covered)
        #expect(table.rows[2][0].text == "North")
        let rows = try Self.writtenRows(Self.write(pdf))
        #expect(rows.map(\.count) == [2, 2, 3, 3, 3])
        #expect(rows.first?.first?.type == "TH")
        #expect(rows.first?.first?.rowSpan == 2)
    }

    @Test func A_bold_row_header_over_two_rows_is_told_by_its_own_column() throws {
        // Words, not numbers, after the bold first column; one cell after it isn't bold, in the row its header covers.
        let pdf = Self.table([
            ("Region", 0, 0, true), ("Spring", 0, 1, true), ("Autumn", 0, 2, true),
            ("North", 1, 0, true), ("high", 1, 1, true), ("low", 1, 2, true),
            ("low", 2, 1, false), ("high", 2, 2, true),
            ("South", 3, 0, true), ("high", 3, 1, true), ("high", 3, 2, true),
        ], rows: 4, unruled: [(2, 0)])
        let table = try Self.tableBlock(pdf)
        #expect(table.headerRows == 1)
        #expect(table.rows[1][0].rowSpan == 2)
        #expect(table.headerColumn)
    }
}
