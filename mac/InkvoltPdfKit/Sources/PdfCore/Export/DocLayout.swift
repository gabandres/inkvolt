import Foundation

/// Bullet: a bulleted item (the bullet becomes Word's own). Marker: "1." / "a)" kept as typed, with a hanging indent.
public enum ListKind: Sendable { case none, bullet, marker }

/// A paragraph: its lines joined into runs (hyphenated line ends rejoined). `indent` and `firstLine` are in points from
/// the left of the column it sits in; `headingLevel` 1-6 (0: body text).
public struct DocParagraph: Equatable, Sendable {
    public var runs: [ExportSpan]
    public var box: RectD
    public var size = 0.0
    public var lineCount = 1
    public var headingLevel = 0
    public var list = ListKind.none
    public var align = TextAlign.left
    public var indent = 0.0
    public var firstLine = 0.0
    /// Where each tab in the text goes, in order (points from the left of the column).
    public var tabs: [DocTab] = []
    /// The distance from one line's top to the next's in the PDF (0 for one line).
    public var linePitch = 0.0
    /// Space above and below (points), as the page leaves it; nil: the writer's usual spacing.
    public var spaceBefore: Double?
    public var spaceAfter: Double?
    /// Where its runs are on the page as shown, in reading order (only from `DocLayout.analyzeForTags`).
    public var sources: [RectD] = []

    public init(_ runs: [ExportSpan], _ box: RectD) {
        self.runs = runs
        self.box = box
    }

    public var text: String { runs.map(\.text).joined() }
    public var allBold: Bool { runs.filter { !$0.text.isBlank }.allSatisfy(\.bold) }
}

/// A tab stop: its position (points from the left of the column), whether text ends there (a leader up to it) or starts
/// there, and what fills the space before it: ".", "_", "-" or nothing ("\0").
public struct DocTab: Equatable, Sendable {
    public var position: Double
    public var right: Bool
    public var leader: Unicode.Scalar
}

/// A table cell: its paragraphs, and any pictures in it (icons, logos).
public struct DocCell: Equatable, Sendable {
    public var paragraphs: [DocParagraph]
    public var colSpan = 1
    public var pictures: [DocPicture] = []

    public init(_ paragraphs: [DocParagraph], colSpan: Int = 1) {
        self.paragraphs = paragraphs
        self.colSpan = colSpan
    }

    public var text: String { paragraphs.map(\.text).joined(separator: "\n") }
}

/// A table: rows of cells (a cell may span columns), column widths in points, drawn with lines or not.
public struct DocTable: Equatable, Sendable {
    public var rows: [[DocCell]]
    public var columnWidths: [Double]
    public var ruled: Bool
    public var box: RectD
    /// Each row's height on the page (points), when its rules give it; nil: as tall as the text needs.
    public var rowHeights: [Double]?

    public init(_ rows: [[DocCell]], _ columnWidths: [Double], _ ruled: Bool, _ box: RectD) {
        self.rows = rows
        self.columnWidths = columnWidths
        self.ruled = ruled
        self.box = box
    }
}

public struct DocPicture: Equatable, Sendable {
    public var image: ExportImage
    public var box: RectD
}

/// A piece of a laid-out page, in reading order (the Windows `DocBlock` and its records).
public enum DocBlock: Equatable, Sendable {
    case paragraph(DocParagraph)
    case table(DocTable)
    case picture(DocPicture)

    public var box: RectD {
        switch self {
        case .paragraph(let p): p.box
        case .table(let t): t.box
        case .picture(let p): p.box
        }
    }

    public var paragraph: DocParagraph? { if case .paragraph(let p) = self { p } else { nil } }
    public var table: DocTable? { if case .table(let t) = self { t } else { nil } }
    public var picture: DocPicture? { if case .picture(let p) = self { p } else { nil } }

    func with(box: RectD) -> DocBlock {
        switch self {
        case .paragraph(var p): p.box = box; return .paragraph(p)
        case .table(var t): t.box = box; return .table(t)
        case .picture(var p): p.box = box; return .picture(p)
        }
    }
}

/// A part of a running header or footer row, at the left, middle or right of the page; its text may hold
/// `DocLayout.pageField`.
public struct RunningPart: Equatable, Sendable {
    public var zone: TextAlign
    public var span: ExportSpan
}

/// A picture in a running header or footer (a logo) and where it sits.
public struct RunningPicture: Equatable, Sendable {
    public var zone: TextAlign
    public var image: ExportImage
}

/// One row of a running header or footer.
public struct DocRunningRow: Equatable, Sendable {
    public var parts: [RunningPart]
}

/// A running header or footer: rows, each with parts at the left, middle or right of the page; pictures (a logo) too.
public struct DocRunning: Equatable, Sendable {
    public var rows: [DocRunningRow]
    public var pictures: [RunningPicture] = []
    /// The pages (0-based) that showed any of it; others (a cover page) get none.
    public var onPages: Set<Int> = []
}

public struct DocLayoutResult: Equatable, Sendable {
    public var pages: [DocPage]
    public var header: DocRunning?
    public var footer: DocRunning?
}

/// A page laid out for export. `content`: the area its text and pictures cover.
public struct DocPage: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var content: RectD
    public var blocks: [DocBlock]
    public var fromOcr = false

    public var paragraphs: [DocParagraph] { blocks.compactMap(\.paragraph) }
    public var tables: [DocTable] { blocks.compactMap(\.table) }
}

/// Turns what a page shows (positioned lines, pictures, rules) into a flow of paragraphs, headings, list items, tables
/// and pictures in reading order. Columns are found by recursive XY-cut (whitespace gutters, then gaps between bands);
/// tables from ruled grids, or from text aligned in columns over several rows; headings from font sizes larger than the
/// document's body text.
public enum DocLayout {
    static let thin = 3.0 // a path this thin (pt) is a rule

    /// Marks where a running header or footer shows the page number.
    public static let pageField: Unicode.Scalar = "\u{E000}"

    public static func analyze(_ pages: [ExportPage]) -> [DocPage] { analyzeDocument(pages).pages }

    /// The laid-out pages, with lines repeated at the top or bottom of most pages taken out as a running header and footer.
    public static func analyzeDocument(_ pages: [ExportPage]) -> DocLayoutResult {
        let (stripped, header, footer) = running(pages)
        let upright = stripped.map(DocLayout.upright)
        let body = bodySize(upright)
        var laid = upright.map { layOut($0, body) }
        laid = assignHeadings(laid, body)
        return DocLayoutResult(pages: dehyphenate(laid, upright), header: header, footer: footer)
    }

    /// `analyzeDocument` for tagging: each paragraph and picture also says where it is on the page as shown
    /// (`DocParagraph.sources`, `ExportImage.pageBox`), whatever turning a page for layout did, and `pages`' running headers
    /// and footers come back as boxes on each page.
    public static func analyzeForTags(_ pages: [ExportPage]) -> (layout: DocLayoutResult, running: [[RectD]]) {
        let marked = pages.map { p -> ExportPage in
            var p = p
            p.lines = p.lines.map { l in
                var l = l
                l.spans = l.spans.map { s in
                    var s = s
                    s.pageBox = s.box
                    return s
                }
                return l
            }
            // The writer's ref tells a repeated logo: without its bytes, the same size at the same place.
            p.images = p.images.map { i in
                var i = i
                i.pageBox = i.box
                i.ref = "\(i.pixelWidth)x\(i.pixelHeight)"
                return i
            }
            return p
        }
        let (stripped, header, footer, runningBoxes) = runningWithBoxes(marked)
        let upright = stripped.map(DocLayout.upright)
        let body = bodySize(upright)
        let laid = assignHeadings(upright.map { layOut($0, body) }, body)
        return (DocLayoutResult(pages: dehyphenate(laid, upright), header: header, footer: footer), runningBoxes)
    }

    /// A page whose text mostly reads sideways (a landscape table set on a portrait page) turned so that it reads left to
    /// right; it then exports as a landscape page.
    public static func upright(_ page: ExportPage) -> ExportPage {
        var counts = [0, 0, 0, 0]
        for l in page.lines { counts[l.reads] += l.text.countScalars { !$0.isWS } }
        let total = counts.reduce(0, +)
        let turn = [1, 2, 3].max { counts[$0] < counts[$1] }!
        return total > 0 && Double(counts[turn]) > 0.6 * Double(total) ? page.turned(turn) : page
    }

    /// The size most of the document's characters have (11 when it has no text).
    public static func bodySize(_ pages: [ExportPage]) -> Double {
        var order: [Double] = []
        var counts: [Double: Int] = [:]
        for p in pages {
            for l in p.lines where !l.sideways {
                for s in l.spans {
                    let n = s.text.countScalars { !$0.isWS }
                    if n == 0 { continue }
                    let key = bankers(s.size * 2) / 2
                    if counts[key] == nil { order.append(key) }
                    counts[key, default: 0] += n
                }
            }
        }
        return order.max { counts[$0]! < counts[$1]! } ?? 11
    }

    /// Thin paths become rules; outlined boxes give their four edges (cell borders are often drawn as rectangles). MuPDF
    /// bounds an outlined box with room for mitered corners (up to the miter limit times the line width, some 11 pt for a
    /// 1 pt frame), so a frame's edges stand off the rules drawn inside it: when rules inside reach equally close to both
    /// sides, the frame is taken in by that much all round.
    public static func rulesFromPaths(_ paths: [(box: RectD, stroked: Bool)]) -> [RectD] {
        var rules: [RectD] = []
        let list = paths.filter { $0.box.width >= 0 && $0.box.height >= 0 && $0.box.width.isFinite && $0.box.height.isFinite }
        let thinBoxes = list.filter { $0.box.width <= thin || $0.box.height <= thin }.map(\.box)
        for (box, stroked) in list {
            var b = box
            if b.width <= thin || b.height <= thin {
                if max(b.width, b.height) >= 4 { rules.append(b) }
            } else if stroked {
                if let pad = framePadding(b, thinBoxes) { b = b.inflate(-pad) }
                rules.append(RectD(b.x, b.y, b.width, 0))
                rules.append(RectD(b.x, b.bottom, b.width, 0))
                rules.append(RectD(b.x, b.y, 0, b.height))
                rules.append(RectD(b.right, b.y, 0, b.height))
            }
        }
        return rules
    }

    /// How far an outlined box's bounds stand off the frame actually drawn: the rules inside it that run across (or down)
    /// it end the same distance (0.5 to 15 pt) short of both sides, two of them at least and all alike. Nil otherwise.
    static func framePadding(_ box: RectD, _ thinBoxes: [RectD]) -> Double? {
        var pads: [Double] = []
        for r in thinBoxes {
            let a: Double, b: Double
            if r.height <= thin && r.width > 0.5 * box.width && r.centerY > box.y && r.centerY < box.bottom {
                (a, b) = (r.x - box.x, box.right - r.right)
            } else if r.width <= thin && r.height > 0.5 * box.height && r.centerX > box.x && r.centerX < box.right {
                (a, b) = (r.y - box.y, box.bottom - r.bottom)
            } else {
                continue
            }
            if (0.5...15).contains(a) && (0.5...15).contains(b) && abs(a - b) <= 2.5 { pads.append((a + b) / 2) }
        }
        // Two rules at least (a single line inset in a box may be inset on purpose).
        if pads.count < 2 { return nil }
        pads.sort()
        if pads[pads.count - 1] - pads[0] > 2.5 { return nil }
        let pad = pads[pads.count / 2]
        return pad < min(box.width, box.height) / 4 ? pad : nil
    }

    // ---- one page ----

    /// Whether a picture goes into the export: not a page-size one behind text (a scan under its own OCR text, or a
    /// background), which would repeat the text as a picture.
    public static func keeps(_ page: ExportPage, _ image: ExportImage) -> Bool {
        !(page.hasText && image.box.width * image.box.height >= 0.85 * page.width * page.height)
    }

    /// An element being ordered: a line, or a finished block (table, picture). `column`: where it sits, once known.
    final class Item {
        let box: RectD
        let line: ExportLine?
        let block: DocBlock?
        var column: RectD?

        init(_ box: RectD, _ line: ExportLine?, _ block: DocBlock?, column: RectD? = nil) {
            self.box = box
            self.line = line
            self.block = block
            self.column = column
        }
    }

    static func layOut(_ page: ExportPage, _ body: Double) -> DocPage {
        var lines = page.lines.filter { !$0.sideways && !$0.text.isBlank }
        if page.fromOcr { lines = snapOcrSizes(lines) }
        lines = mergeRows(lines, page.rules.filter { $0.width <= thin && $0.height > 6 })

        var items: [Item] = []
        var images = page.images.filter { keeps(page, $0) }
        for grid in grids(page.rules) {
            if let t = tableFromGrid(grid, &lines, &images, body) { items.append(Item(t.box, nil, .table(t))) }
        }
        items += images.map { Item($0.box, nil, .picture(DocPicture(image: $0, box: $0.box))) }
        items += lines.map { Item($0.box, $0, nil) }
        let sideways = page.lines.filter { $0.sideways && !$0.text.isBlank }
        if items.isEmpty && sideways.isEmpty { return DocPage(width: page.width, height: page.height, content: .zero, blocks: [], fromOcr: page.fromOcr) }

        let all = items.map(\.box) + sideways.map(\.box)
        let content = all.dropFirst().reduce(all[0]) { $0.union($1) }
        let ordered = order(items, body, 0)
        for i in ordered where i.column == nil { i.column = content }
        var blocks = mergeTables(flow(ordered, body), body)
        // Sideways text (a rotated label, a margin stamp, a turned table on a mostly upright page): each direction's lines
        // are laid out in their own turned frame, so they read as paragraphs, and go in where they start on the page.
        for group in groupedInOrder(sideways, by: \.reads) {
            let top = group.items.map(\.box.y).min()!
            let turned = ExportPage(page.width, page.height, group.items, [], []).turned(group.key)
            let inserted = layOut(turned, body).blocks.map { $0.with(box: RectD($0.box.x, top, $0.box.width, 0)) }
            if let at = blocks.firstIndex(where: { $0.box.y > top }) {
                blocks.insert(contentsOf: inserted, at: at)
            } else {
                blocks += inserted
            }
        }
        return DocPage(width: page.width, height: page.height, content: content, blocks: spaced(blocks), fromOcr: page.fromOcr)
    }

    /// Word's line height for one line of type (single spacing), as a share of the size.
    static let wordLine = 1.17

    /// The space the page leaves above each paragraph, so the export keeps its vertical layout (a form's rows, a gap
    /// before a signature): from the line before's top, one Word line per line it had, the rest as space before; after a
    /// table or picture, the gap under it. A paragraph before a table keeps the gap under it as space after (a table has
    /// no space of its own). The first block, and one placed higher than the block before (a new column), get none. The
    /// gap is measured from the paragraph before's last line, so its line spacing doesn't add to it.
    static func spaced(_ blocks: [DocBlock]) -> [DocBlock] {
        var result: [DocBlock] = []
        result.reserveCapacity(blocks.count)
        for i in blocks.indices {
            guard case .paragraph(var p) = blocks[i] else {
                result.append(blocks[i])
                continue
            }
            var before = 0.0
            if i > 0 {
                let prev = blocks[i - 1]
                // From the top of the paragraph before's last line (its line spacing is its own, not a gap).
                if case .paragraph(let q) = prev {
                    before = p.box.y - (q.box.y + Double(q.lineCount - 1) * q.linePitch) - wordLine * q.size
                } else {
                    before = p.box.y - prev.box.bottom
                }
                // Sideways text placed where it starts has no height: no gap to measure.
                if prev.box.height <= 0 || p.box.height <= 0 { before = 0 }
            }
            var after = 0.0
            if i + 1 < blocks.count, case .table(let t) = blocks[i + 1], t.box.y >= p.box.bottom { after = min(200, t.box.y - p.box.bottom) }
            p.spaceBefore = clamp(before, 0, 200)
            p.spaceAfter = after
            result.append(.paragraph(p))
        }
        return result
    }

    /// OCR sizes are estimates: those within a fifth of the page's usual size are taken as that size.
    static func snapOcrSizes(_ lines: [ExportLine]) -> [ExportLine] {
        if lines.isEmpty { return lines }
        let sizes = lines.map(\.size).sorted()
        let usual = sizes[sizes.count / 2]
        return lines.map { l in
            guard abs(l.size - usual) <= 0.2 * usual else { return l }
            var l = l
            l.spans = l.spans.map { s in
                var s = s
                s.size = usual
                return s
            }
            return l
        }
    }

    /// Joins pieces of one visual line that MuPDF split (a bullet and its text, words spread by justification): same row,
    /// close together. A lone list marker joins its text even across a wide gap. Not across one of `verticals` (a table's
    /// rule between two cells).
    static func mergeRows(_ lines: [ExportLine], _ verticals: [RectD]) -> [ExportLine] {
        let sorted = lines.sorted { $0.box.x < $1.box.x }
        var result: [ExportLine] = []
        // Lines by the height of their middle (8 pt bands), so each looks only at nearby rows, not the whole page.
        var bands: [Int: [Int]] = [:]
        for line in sorted {
            var merged = false
            let band = Int((line.box.centerY / 8).rounded(.down))
            let near = (band - 2...band + 2).flatMap { bands[$0] ?? [] }.sorted(by: >)
            for k in near {
                let prev = result[k]
                let overlap = min(prev.box.bottom, line.box.bottom) - max(prev.box.y, line.box.y)
                if overlap < 0.6 * min(prev.box.height, line.box.height) { continue }
                let gap = line.box.x - prev.box.right
                let size = max(prev.size, line.size)
                let maxGap = isMarkerOnly(prev.text) ? 4 * size : 1.2 * size
                if gap < -1 || gap > maxGap { continue }
                let cy = (prev.box.centerY + line.box.centerY) / 2
                if verticals.contains(where: { $0.centerX >= prev.box.right - 1 && $0.centerX <= line.box.x + 1 && $0.y <= cy && $0.bottom >= cy }) { continue }
                // Two numbers apart are two table columns, not one line.
                if gap > 0.8 * size && ExportLine.numberLike(prev.text) && ExportLine.numberLike(line.text) { continue }
                result[k] = join(prev, line)
                merged = true
                break
            }
            if merged { continue }
            bands[band, default: []].append(result.count)
            result.append(line)
        }
        result.sort { $0.box.y != $1.box.y ? $0.box.y < $1.box.y : $0.box.x < $1.box.x }
        return result

        func join(_ a: ExportLine, _ b: ExportLine) -> ExportLine {
            var spans = a.spans
            // Pieces that touch are one word split by MuPDF (at a capital's accent: "PREDICACIÓ" "N"): no space between.
            let touching = b.box.x - a.box.right < 0.15 * max(a.size, b.size)
            let needsSpace = !touching && !(a.text.unicodeScalars.last?.isWS ?? true) && !(b.text.unicodeScalars.first?.isWS ?? true)
            if needsSpace { spans[spans.count - 1].text += " " }
            spans += b.spans
            return .of(spans)
        }
    }

    // ---- reading order (XY-cut) ----

    static func order(_ items: [Item], _ body: Double, _ depth: Int) -> [Item] {
        if items.count <= 1 || depth > 200 { return sortedItems(items) }
        var columns: [[Item]]?
        if !singleRow(items) {
            let gutters = gaps(items, { ($0.box.x, $0.box.right) }, max(8, 0.9 * body))
            if !gutters.isEmpty {
                let pieces = split(items, gutters) { $0.box.centerX }
                if pieces.count > 1 {
                    if let table = unruledTable(pieces, body) { return [Item(table.box, nil, .table(table))] }
                    columns = formRows(pieces) ? nil : pieces
                    if columns != nil && readAsColumns(pieces, body) {
                        // Text under the columns that sits in one of them only (a list after a two-column part) comes after both.
                        guard let below = textUnderColumns(items, pieces, body) else { return inColumns(pieces) }
                        return split(items, [below]) { $0.box.centerY }.flatMap { order($0, body, depth + 1) }
                    }
                }
            }
        }
        let bands = gaps(items, { ($0.box.y, $0.box.bottom) }, 0.5)
        if !bands.isEmpty {
            // Cut at the widest gaps only (a title's gap, not every line's), then look for columns in each band again.
            let widest = bands.map { $0.end - $0.start }.max()!
            let cuts = bands.filter { $0.end - $0.start >= 0.8 * widest }
            let parts = split(items, cuts) { $0.box.centerY }
            if parts.count > 1 { return parts.flatMap { order($0, body, depth + 1) } }
        }
        if let columns { return inColumns(columns) }
        return sortedItems(items)

        func inColumns(_ pieces: [[Item]]) -> [Item] {
            var result: [Item] = []
            for piece in pieces {
                let bounds = piece.dropFirst().reduce(piece[0].box) { $0.union($1.box) }
                let sub = order(piece, body, depth + 1)
                for i in sub where i.column == nil { i.column = bounds }
                result += sub
            }
            return result
        }
    }

    /// Pieces side by side that line up row for row and fill in a form (a fill-in line in each, with its label under it:
    /// "Signature ......" beside "Date ......"): read across, row by row, not one piece after the other.
    static func formRows(_ pieces: [[Item]]) -> Bool {
        if pieces.contains(where: { $0.contains { $0.line == nil } }) { return false }
        let lines = pieces.enumerated().flatMap { k, p in p.map { (line: $0.line!, col: k) } }
        if !lines.contains(where: { ExportGlyphs.hasLeader($0.line.text) }) { return false }
        return rows(lines).allSatisfy { Set($0.map(\.col)).count >= 2 }
    }

    /// A gap across the whole region below which only one of the pieces has anything, while above it two or more do: the
    /// columns end there and what follows is read after all of them.
    static func textUnderColumns(_ items: [Item], _ pieces: [[Item]], _ body: Double) -> (start: Double, end: Double)? {
        for gap in gaps(items, { ($0.box.y, $0.box.bottom) }, 0.5 * body) {
            let above = pieces.filter { $0.contains { $0.box.centerY < gap.start } }.count
            let under = pieces.filter { $0.contains { $0.box.centerY > gap.end } }.count
            if above >= 2 && under == 1 { return gap }
        }
        return nil
    }

    /// Pieces side by side read as columns unless one has a tall empty stretch (three lines or more) where another has
    /// something: then they are blocks stacked down the page that happen to leave a gutter between them (a table's numbers
    /// beside headings and short lines), and the page is cut across first.
    static func readAsColumns(_ pieces: [[Item]], _ body: Double) -> Bool {
        for k in pieces.indices {
            let spans = pieces[k].map { (y: $0.box.y, bottom: $0.box.bottom) }.sorted { $0.y < $1.y }
            var reach = spans[0].bottom
            for (y, bottom) in spans.dropFirst() {
                let (top, end) = (reach, y)
                if end - top > 3 * body && pieces.indices.contains(where: { j in j != k && pieces[j].contains { $0.box.centerY > top && $0.box.centerY < end } }) {
                    return false
                }
                reach = max(reach, bottom)
            }
        }
        return true
    }

    static func sortedItems(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            let ya = bankers(a.box.y), yb = bankers(b.box.y)
            return ya != yb ? ya < yb : a.box.x < b.box.x
        }
    }

    /// Every element shares one horizontal band (one row of text): nothing to split into columns.
    static func singleRow(_ items: [Item]) -> Bool { items.map(\.box.y).max()! < items.map(\.box.bottom).min()! }

    /// Gaps of at least `minimum` between the elements' extents along one axis (inner gaps only).
    static func gaps(_ items: [Item], _ extent: (Item) -> (Double, Double), _ minimum: Double) -> [(start: Double, end: Double)] {
        let spans = items.map(extent).sorted { $0.0 < $1.0 }
        var result: [(start: Double, end: Double)] = []
        var reach = spans[0].1
        for (start, end) in spans.dropFirst() {
            if start - reach >= minimum { result.append((reach, start)) }
            reach = max(reach, end)
        }
        return result
    }

    static func split(_ items: [Item], _ gaps: [(start: Double, end: Double)], _ center: (Item) -> Double) -> [[Item]] {
        var parts = [[Item]](repeating: [], count: gaps.count + 1)
        for item in items {
            let c = center(item)
            var k = 0
            while k < gaps.count && c > gaps[k].start { k += 1 }
            parts[k].append(item)
        }
        return parts.filter { !$0.isEmpty }
    }
}
