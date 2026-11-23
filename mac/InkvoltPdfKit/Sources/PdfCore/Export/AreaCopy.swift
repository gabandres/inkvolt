import Foundation
import PrintCore

/// Copy Text from Area and Copy Area as Table for an area boxed with Snapshot (roadmap 4.6; the Windows app's `AreaCopy`).
/// The area's words come from the page's text (its own, or an earlier text recognition's invisible layer) when it has any
/// there, else from reading the area's picture (`recognize`). `text` gives them in reading order as the plain-text export
/// lays them out; `table` as the Excel export finds tables (`DocLayout`), or, where it finds none, as rows of the lines'
/// columns, for the clipboard as tab-separated text and as HTML so a spreadsheet pastes them into cells. Lines end with
/// LF on the Mac (Windows' clipboard text has CR LF).
public enum AreaCopy {
    /// The most pixels an area is read at (a Letter page at 300 dpi is about 8.4 million).
    static let maxRecognizePixels = 25_000_000.0

    /// The most cells (rows × columns) a copied table holds: more is no table a person boxed but a hostile page (one
    /// character a line, each its own row and column, makes hundreds of millions), copied as text instead.
    public static let maxCells = 100_000

    /// The page's lines and rules cut to `area` (page space): a character is kept when its middle is inside (characters
    /// are taken as evenly spread over their run), a line keeps what is left of it, pictures go.
    public static func clip(_ page: ExportPage, _ area: RectD) -> ExportPage {
        var lines: [ExportLine] = []
        for line in page.lines where overlaps(line.box, area) {
            let spans = line.spans.compactMap { cut($0, area, line.reads) }
            if spans.isEmpty || spans.allSatisfy({ $0.text.isBlank }) { continue }
            var kept = ExportLine.of(spans, sideways: line.sideways)
            kept.turn = line.turn
            lines.append(kept)
        }
        var clipped = page
        clipped.lines = lines
        clipped.images = []
        clipped.rules = page.rules.filter { overlaps($0, area) }.map { intersect($0, area) }
        clipped.shapes = []
        return clipped
    }

    /// The page has text in `area` (else its picture is read).
    public static func hasText(_ page: ExportPage, _ area: RectD) -> Bool { clip(page, area).hasText }

    /// The clipped page's words in reading order: a paragraph a line, a table's rows with tab-separated cells, a bullet
    /// item with its bullet, lines ending with LF.
    public static func text(_ clipped: ExportPage) -> String {
        DocumentExport.plainText([clipped]).components(separatedBy: "\r\n")
            .map { $0.trimmingEnd { $0 == " " || $0 == "\t" } }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The clipped page as rows of cells: the tables `DocLayout` finds (as Export to Excel puts them in a sheet), with any
    /// paragraph between them a row of one cell; where it finds none, each row of lines split into the columns their left
    /// and right edges line up in. More than `maxCells` cells: no rows, and `AreaTable.tooLarge` (the caller copies the
    /// text instead, and says so).
    /// - Throws: `CancellationError` when `cancel` fired.
    public static func table(_ clipped: ExportPage, cancel: CancelToken? = nil) throws -> AreaTable {
        if !clipped.hasText { return AreaTable([]) }
        let laid = DocLayout.analyze([clipped])
        try cancel.check()
        let blocks = laid.flatMap(\.blocks)
        if blocks.contains(where: { $0.table != nil }) {
            var rows: [[AreaCell]] = []
            var cells = 0 // as the text pastes: a spanning cell followed by empty ones
            outer: for block in blocks {
                switch block {
                case .table(let t):
                    for row in t.rows {
                        cells += row.reduce(0) { $0 + max(1, $1.colSpan) }
                        if cells > maxCells { break outer }
                        rows.append(row.map { AreaCell($0.covered ? "" : oneLine($0.text), colSpan: $0.colSpan) }) // a spanned cell left empty
                    }
                case .paragraph(let p) where !p.text.isBlank:
                    cells += 1
                    rows.append([AreaCell(oneLine(p.text))])
                default:
                    break
                }
                if cells > maxCells { break }
            }
            return cells > maxCells ? AreaTable([], tooLarge: true) : AreaTable(rows)
        }
        return try columns(clipped.lines.filter { !$0.sideways }, cancel)
    }

    /// The words `recognizer` reads in `area` of the page, drawn at 300 dpi (less for a very large area, more for a small
    /// one, so its letters are tall enough to read), in page space.
    /// - Throws: `CancellationError` when `cancel` fired; what the engine throws for a page it can't draw.
    public static func recognize(_ engine: PdfEngine, _ page: Int, _ area: RectD, _ recognizer: any TextRecognizer,
                                 cancel: CancelToken? = nil) throws -> [OcrWord] {
        guard page >= 0 && page < engine.pageCount, area.width >= 1 && area.height >= 1, area.x.isFinite && area.y.isFinite,
              area.width.isFinite && area.height.isFinite else { return [] }
        let g = engine.page(page)
        let box = intersect(area, RectD(0, 0, g.width, g.height))
        if box.width < 1 || box.height < 1 { return [] }
        var scale = max(300 / 72.0, 40 / box.height) // a one-line area drawn at least 40 pixels tall
        if box.width * box.height * scale * scale > maxRecognizePixels { scale = (maxRecognizePixels / (box.width * box.height)).squareRoot() }
        let image = try engine.render(page, scale: scale, region: box, cancel: cancel, annotations: false)
        let read = try recognizer.recognize(image, cancel: cancel)
        // The rendered region can start a fraction of a pixel before the box: its pixels are counted from the box's corner.
        return read.filter { !$0.text.isBlank }.map { w in
            var word = w
            word.rect = RectD(box.x + w.rect.x / scale, box.y + w.rect.y / scale, w.rect.width / scale, w.rect.height / scale)
            return word
        }
    }

    /// The words recognized in an area as the lines a clipped page holds (`ExportPage.linesFromOcr`).
    public static func fromWords(_ page: ExportPage, _ words: [OcrWord]) -> ExportPage {
        var p = page
        p.lines = ExportPage.linesFromOcr(words)
        p.images = []
        p.shapes = []
        p.fromOcr = true
        return p
    }

    /// A span cut to the characters whose middles are in the area (along the way the line reads), or nil for none.
    /// Characters are UTF-16 units, as Windows counts them.
    private static func cut(_ span: ExportSpan, _ area: RectD, _ reads: Int) -> ExportSpan? {
        let text = Array(span.text.utf16)
        if !overlaps(span.box, area) || text.isEmpty { return nil }
        let horizontal = reads == 0 || reads == 2
        let (start, length) = horizontal ? (span.box.x, span.box.width) : (span.box.y, span.box.height)
        let (across, acrossEnd) = horizontal ? (span.box.y, span.box.bottom) : (span.box.x, span.box.right)
        let (lo, hi) = horizontal ? (area.x, area.right) : (area.y, area.bottom)
        let (crossLo, crossHi) = horizontal ? (area.y, area.bottom) : (area.x, area.right)
        let middle = (across + acrossEnd) / 2
        if middle < crossLo || middle > crossHi { return nil } // the line's middle is outside: a line the box only grazes
        let forward = reads == 0 || reads == 1
        let n = text.count
        let step = length / Double(n)
        var first = -1, last = -1
        for i in 0..<n {
            let k = forward ? i : n - 1 - i // the i-th character along the page's axis
            let at = start + (Double(i) + 0.5) * step
            if at < lo || at > hi { continue }
            if first < 0 || k < first { first = k }
            if k > last { last = k }
        }
        if first < 0 { return nil }
        if first == 0 && last == n - 1 { return span }
        let (from, to) = forward ? (first, last) : (n - 1 - last, n - 1 - first)
        let a = start + Double(from) * step
        let b = start + Double(to + 1) * step
        var kept = span
        kept.text = String(decoding: text[first...last], as: UTF16.self)
        kept.box = horizontal ? RectD(a, span.box.y, b - a, span.box.height) : RectD(span.box.x, a, span.box.width, b - a)
        return kept
    }

    /// Lines in rows (those whose heights overlap by half), each row's lines in the columns their spans across all rows make
    /// (edges that overlap are one column); none, with `AreaTable.tooLarge`, past `maxCells`.
    private static func columns(_ lines: [ExportLine], _ cancel: CancelToken?) throws -> AreaTable {
        // Columns first (the lines' left-to-right extents merged where they overlap): how wide the grid is.
        var columns: [(from: Double, to: Double)] = []
        for (from, to) in lines.map({ ($0.box.x, $0.box.right) }).sorted(by: { $0.0 < $1.0 }) {
            if let last = columns.last, from <= last.to {
                columns[columns.count - 1] = (last.from, max(last.to, to))
            } else {
                columns.append((from, to))
            }
        }
        // Rows, top down. A row whose lowest line ends above this line's top overlaps no line after it either (they are in
        // order of their tops): it is closed, so a page of thousands of rows isn't searched line by line again.
        var rows: [[ExportLine]] = []
        var open: [(row: Int, bottom: Double)] = []
        for line in lines.sorted(by: { $0.box.y < $1.box.y }) {
            try cancel.check()
            open.removeAll { $0.bottom <= line.box.y }
            let at = open.firstIndex { o in
                rows[o.row].contains { x in
                    min(x.box.bottom, line.box.bottom) - max(x.box.y, line.box.y) > 0.5 * min(x.box.height, line.box.height)
                }
            }
            if let at {
                rows[open[at].row].append(line)
                open[at].bottom = max(open[at].bottom, line.box.bottom)
            } else {
                rows.append([line])
                open.append((rows.count - 1, line.box.bottom))
                if rows.count * columns.count > maxCells { return AreaTable([], tooLarge: true) }
            }
        }
        var result: [[AreaCell]] = []
        for row in rows.sorted(by: { $0.map(\.box.y).min()! < $1.map(\.box.y).min()! }) {
            try cancel.check()
            var cells = [String?](repeating: nil, count: columns.count)
            for line in row.sorted(by: { $0.box.x < $1.box.x }) {
                let c = columnOf(columns, line.box)
                if c < 0 { continue }
                let text = oneLine(line.text)
                if let was = cells[c], !was.isEmpty { cells[c] = was + " " + text } else { cells[c] = text }
            }
            result.append(cells.map { AreaCell($0 ?? "") })
        }
        return AreaTable(result)
    }

    /// The first column `box` reaches into, or -1. The columns are apart and in order, so their right edges rise: the first
    /// that ends at or after the box's left edge is the one, if it starts before its right.
    private static func columnOf(_ columns: [(from: Double, to: Double)], _ box: RectD) -> Int {
        var lo = 0, hi = columns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if columns[mid].to < box.x { lo = mid + 1 } else { hi = mid }
        }
        return lo < columns.count && box.right >= columns[lo].from ? lo : -1
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func overlaps(_ a: RectD, _ b: RectD) -> Bool { a.x < b.right && b.x < a.right && a.y < b.bottom && b.y < a.bottom }

    private static func intersect(_ a: RectD, _ b: RectD) -> RectD {
        .fromEdges(max(a.x, b.x), max(a.y, b.y), min(a.right, b.right), min(a.bottom, b.bottom))
    }
}

/// A cell of a copied table: its text on one line, and how many columns it spans.
public struct AreaCell: Equatable, Sendable {
    public var text: String
    public var colSpan: Int

    public init(_ text: String, colSpan: Int = 1) {
        self.text = text
        self.colSpan = colSpan
    }
}

/// An area copied as a table (`AreaCopy.table`): rows of cells, for the clipboard. `tooLarge`: more than
/// `AreaCopy.maxCells` cells, none kept, the area is copied as text.
public struct AreaTable: Equatable, Sendable {
    public var rows: [[AreaCell]]
    public var tooLarge: Bool

    public init(_ rows: [[AreaCell]], tooLarge: Bool = false) {
        self.rows = rows
        self.tooLarge = tooLarge
    }

    public var isEmpty: Bool { rows.allSatisfy { $0.allSatisfy(\.text.isEmpty) } }

    /// Most columns in a row (a cell counted by its span).
    public var columnCount: Int { rows.map { $0.reduce(0) { $0 + max(1, $1.colSpan) } }.max() ?? 0 }

    /// Tab-separated rows (a spanning cell followed by empty ones), LF after each row: what a spreadsheet pastes as cells.
    public func tsv() -> String {
        var out = ""
        for row in rows {
            var cells: [String] = []
            for cell in row {
                cells.append(cell.text.replacingOccurrences(of: "\t", with: " "))
                for _ in stride(from: 1, to: cell.colSpan, by: 1) { cells.append("") }
            }
            out += cells.joined(separator: "\t").trimmingEnd { $0 == "\t" } + "\n"
        }
        return out
    }

    /// The rows as an HTML table (text escaped, spans kept): the pasteboard's HTML, which Numbers, Excel and Pages paste as
    /// cells.
    public func html() -> String {
        var out = "<table>"
        for row in rows {
            out += "<tr>"
            for cell in row {
                out += cell.colSpan > 1 ? "<td colspan=\"\(cell.colSpan)\">" : "<td>"
                out += cell.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;") // UTF-8 as it is
                out += "</td>"
            }
            out += "</tr>"
        }
        return out + "</table>"
    }
}
