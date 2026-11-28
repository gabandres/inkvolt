import Foundation

/// Pixel redaction's answer to glyph-spacing inference (arXiv 2206.02285; the Windows Core's `RedactionLines`): a
/// redacted line keeps its words, not their positions. Left where they were, the text after a black box starts where the
/// removed words ended, a justified line's spaces are as wide as the removed width makes them, and the box is as wide as
/// the area drawn over the words: from the page picture and the font, the removed width can be measured and often the
/// words guessed. So each line an area cuts is laid out again in the page picture (`Redaction.redact`): its words in
/// order from the line's own alignment edge (its start, its end, or its middle for a centred line), one space of a fixed
/// width (`spaceOfHeight` of the line's height) between them, and each box its width rounded to steps of `stepOfHeight`
/// line heights; a line redacted whole is just its rounded box; boxes already there (an earlier redaction's) keep their
/// width and move with the line. A line turned sideways is laid out along its own axis. Nothing on the line then depends
/// on the removed width but that step. A word's own letters move together, unchanged: whole pixels, so their shading
/// keeps the fraction of a pixel where they were (0.24 pt at 300 dpi), a limit of drawing the page once. A line whose
/// space holds something else (a table's rule, a picture) isn't laid out again: its boxes are rounded where they are, as
/// far as the words beside them allow, and it is said (`Relaid.laidOut`).
///
/// Everything about a line is in its own space: along its baseline as x, across it as y (a sideways line's rectangles
/// transposed, `CutLine.vertical`).
enum RedactionLines {
    /// The space put between the words of a line laid out again, in line heights (a space is about a quarter of an em).
    static let spaceOfHeight = 0.25

    /// The steps a box's width is rounded to, in line heights (at least one step).
    static let stepOfHeight = 2.0

    /// Lines longer than this (characters) are left as they are.
    private static let maxChars = 5000

    /// An area this many line heights tall or more takes more than one line.
    private static let tallerThanALine = 1.6

    enum PieceKind {
        /// A word kept: its pixels move.
        case word
        /// A box drawn now: black, its width rounded.
        case box
        /// A box that was there (an earlier redaction's): its pixels move, its width stays.
        case fixed
    }

    enum Alignment { case start, middle, end }

    /// A piece of a line, in order along it. `spaced`: a space came before it (else it touched the piece before, as a comma
    /// after a name).
    struct Piece: Equatable {
        var x: Double, right: Double
        var kind: PieceKind
        var spaced: Bool
        var box: Bool { kind == .box }
    }

    /// A line an area cuts. `band`: the line's characters, all of them; `rows`: the rows laid out again (the band, and the
    /// areas on it up to half a line beyond it); `areas`: the areas on the line.
    struct CutLine {
        var band: RectD
        var rows: RectD
        var pieces: [Piece]
        var areas: [RectD]
        /// The line's baseline runs down the page: its rectangles are transposed (x along it, y across it).
        var vertical = false
        var align = Alignment.start
        /// How far along the line may reach when laid out again (another column's text on its rows), both ways.
        var limit = Double.greatestFiniteMagnitude
        var limitStart = 0.0

        var height: Double { band.height }

        /// The rectangle in page space.
        func toPage(_ r: RectD) -> RectD { vertical ? RedactionLines.transpose(r) : r }
    }

    /// A line laid out again: its boxes drawn now, its fixed boxes where they went, its rows, and the words and fixed boxes
    /// moved (page space). `laidOut` false: it was left in place (its space holds a rule or a picture), its boxes only
    /// rounded.
    struct Relaid {
        var boxes: [RectD] = []
        var fixed: [(was: RectD, now: RectD)] = []
        var rows = RectD.zero
        var moved: [(was: RectD, dx: Double, dy: Double)] = []
        var laidOut = true
    }

    static func transpose(_ r: RectD) -> RectD { RectD(r.y, r.x, r.height, r.width) }

    /// A box's width once rounded: whole steps of `stepOfHeight` line heights, at least one.
    static func boxWidth(_ width: Double, _ height: Double) -> Double {
        let step = stepOfHeight * height
        return max(1, (width / step).rounded(.toNearestOrEven)) * step
    }

    private static func finite(_ r: RectD) -> Bool { (r.x + r.y + r.width + r.height).isFinite }

    private static func isWhite(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isWhitespace ?? false }

    /// Stretches dark across a line's middle (its band, line space; whether sideways), line space.
    typealias DarkRuns = (RectD, Bool) -> [(x: Double, right: Double)]

    /// The lines of a page that areas cut, across the page or turned sideways: an area over at least half the line's
    /// height and over its text or within a line's height beside it. A character whose middle an area covers goes into
    /// the box (as `RedactionCheck`'s values under it are read); one it only touches stays whole, its box ending where it
    /// starts. An area taller than a line counts on the lines whose letters it takes, as rows of lines: one that takes
    /// some of a line and leaves the rest, and the lines it takes whole in between; one that leaves no letter of any line
    /// beside it is a block, as drawn. `darkRuns`: boxes already on a line.
    static func find(_ text: PageText, _ areas: [RectD], _ pageWidth: Double, _ pageHeight: Double, darkRuns: DarkRuns? = nil) -> [CutLine] {
        let cuts = areas.filter { !$0.isEmpty && finite($0) }
        if cuts.isEmpty || text.isEmpty { return [] }
        return [false, true].flatMap { vertical in find(text, cuts, vertical, vertical ? pageHeight : pageWidth, darkRuns) }
    }

    private struct TextLine {
        var start: Int, end: Int
        var band: RectD
        var visible: [Int]
        var reversed: Bool
    }

    private static func takes(_ a: RectD, _ b: RectD) -> Bool {
        a.x <= b.centerX && b.centerX <= a.right && min(a.bottom, b.bottom) - max(a.y, b.y) >= 0.3 * b.height
    }

    private static func find(_ text: PageText, _ pageCuts: [RectD], _ vertical: Bool, _ extent: Double, _ darkRuns: DarkRuns?) -> [CutLine] {
        func box(_ i: Int) -> RectD { vertical ? transpose(text.boxAt(i)) : text.boxAt(i) }
        let cuts = pageCuts.map { vertical ? transpose($0) : $0 }
        var lines: [TextLine] = []
        for (start, end, dx, dy) in text.lineSpans {
            let along = vertical ? dy : dx
            if abs(along) < 0.99 || end - start > maxChars { continue }
            var band = RectD.zero
            var visible: [Int] = []
            for i in start..<end where !isWhite(text.unit(i)) {
                let b = box(i)
                if b.width > 0 && b.height > 0 && finite(b) {
                    band = band.isEmpty ? b : band.union(b)
                    visible.append(i)
                }
            }
            // A line read against its axis (up the page): its start is its far edge.
            if band.height >= 1 && band.height <= 300 { lines.append(TextLine(start: start, end: end, band: band, visible: visible, reversed: along < 0)) }
        }
        func hits(_ band: RectD, _ visible: [Int]) -> [RectD] {
            let h = band.height
            return cuts.filter { a in
                min(a.bottom, band.bottom) - max(a.y, band.y) >= 0.5 * h && a.right >= band.x - h && a.x <= band.right + h
                    && (a.height <= tallerThanALine * h || visible.contains { takes(a, box($0)) })
            }
        }
        // Tall areas that leave letters of some line beside them: rows of lines (the lines they take whole are laid out too).
        var rowAreas = Set<RectD>()
        for l in lines {
            let hit = hits(l.band, l.visible)
            if l.visible.contains(where: { i in !hit.contains { takes($0, box(i)) } }) {
                for a in hit where a.height > tallerThanALine * l.band.height { rowAreas.insert(a) }
            }
        }

        var found: [CutLine] = []
        for l in lines {
            let band = l.band
            let h = band.height
            let hit = hits(band, l.visible)
            if hit.isEmpty { continue }
            func covered(_ b: RectD) -> Bool { hit.contains { takes($0, b) } }
            let kept = l.visible.filter { !covered(box($0)) }.sorted { box($0).x < box($1).x }
            // A line redacted whole: its box, drawn round its words, would give their width away too, so it is laid out the
            // same (only its box). Not when a block takes it (an area taller than a line that leaves no line beside it).
            if kept.isEmpty && hit.contains(where: { $0.height > tallerThanALine * h && !rowAreas.contains($0) }) { continue }

            // Boxes: each area's stretch of the line with the characters it takes, overlapping ones joined.
            var spans: [(x: Double, right: Double)] = hit.map { a in
                var (x, right) = (max(a.x, band.x - h), min(a.right, band.right + h))
                if a.height > tallerThanALine * h { (x, right) = (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude) } // a row area: only what it takes
                for i in l.visible {
                    let b = box(i)
                    if takes(a, b) { (x, right) = (min(x, b.x), max(right, b.right)) }
                }
                return (x, right)
            }.filter { $0.right > $0.x }
            // Boxes already on the line (an earlier redaction's): the areas just painted are dark too, so only what lies
            // outside them counts; a piece of one touching a new box joins it, the others stay as they are.
            var fixedBoxes: [(x: Double, right: Double)] = []
            for run in darkRuns?(band, vertical) ?? [] {
                var rest = [run]
                for a in hit {
                    rest = rest.flatMap { r -> [(x: Double, right: Double)] in
                        if r.right <= a.x || r.x >= a.right { return [r] }
                        return [(r.x, min(r.right, a.x)), (max(r.x, a.right), r.right)].filter { $0.1 > $0.0 }
                    }
                }
                for piece in rest {
                    if piece.right - piece.x < 0.6 * h || kept.contains(where: { box($0).right > piece.x && box($0).x < piece.right }) { continue }
                    if spans.contains(where: { $0.right >= piece.x - 0.5 && $0.x <= piece.right + 0.5 }) {
                        spans.append(piece)
                    } else {
                        fixedBoxes.append(piece)
                    }
                }
            }
            var joined: [(x: Double, right: Double)] = []
            for b in spans.sorted(by: { $0.x < $1.x }) {
                if let last = joined.last, b.x <= last.right {
                    joined[joined.count - 1] = (last.x, max(last.right, b.right))
                } else {
                    joined.append(b)
                }
            }
            if joined.isEmpty { continue }

            // Words: kept characters in order along the line, split at a space, a wide gap or a box.
            var words: [(x: Double, right: Double)] = []
            var last = -1
            for i in kept {
                let b = box(i)
                var split = last < 0
                if !split {
                    let lb = box(last)
                    split = b.x - lb.right > 0.3 * h || abs(i - last) > 64
                        || (min(i, last) + 1..<max(i, last)).contains { isWhite(text.unit($0)) }
                        || (joined + fixedBoxes).contains { $0.x >= lb.centerX && $0.right <= b.centerX }
                }
                if split {
                    words.append((b.x, b.right))
                } else {
                    words[words.count - 1].right = max(words[words.count - 1].right, b.right)
                }
                last = i
            }

            // A box gives way to a word it only touches (an area over the edge of a letter it doesn't take): the letter stays whole.
            for k in joined.indices {
                var (x, right) = joined[k]
                for w in words {
                    if w.x <= x && w.right > x {
                        x = w.right
                    } else if w.x > x && w.x < right && w.right > right {
                        right = w.x
                    }
                }
                joined[k] = (x, max(x, right))
            }

            let all = (words.map { ($0.x, $0.right, PieceKind.word) } + joined.map { ($0.x, $0.right, PieceKind.box) }
                + fixedBoxes.map { ($0.x, $0.right, PieceKind.fixed) }).enumerated().sorted { a, b in
                    a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset // a stable order, as .NET's OrderBy
                }.map(\.element)
            var pieces: [Piece] = []
            for (x0, right, kind) in all {
                // A piece still overlapping the one before starts where that one ends.
                let x = pieces.last.map { max(x0, $0.right) } ?? x0
                if right <= x { continue }
                pieces.append(Piece(x: x, right: right, kind: kind, spaced: pieces.last.map { x0 - $0.right > 0.1 * h } ?? false))
            }
            if !pieces.contains(where: \.box) { continue }

            // Other text on the same rows (another column): the line stays between it.
            func sameRows(_ o: RectD) -> Bool { o != band && min(o.bottom, band.bottom) - max(o.y, band.y) > 0.3 * h }
            let limit = lines.filter { sameRows($0.band) && $0.band.x >= band.right - 0.5 * h }.map { $0.band.x - 0.5 * h }.min() ?? extent
            let limitStart = lines.filter { sameRows($0.band) && $0.band.right <= band.x + 0.5 * h }.map { $0.band.right + 0.5 * h }.max() ?? 0

            // Rows: the band, and the areas of this line on it up to half a line beyond (a tall area's rows between lines
            // become paper), but not into another line above or below.
            let own = hit.filter { $0.height <= tallerThanALine * h }
            var top = max(min(band.y, own.map(\.y).min() ?? band.y), band.y - 0.5 * h)
            var bottom = min(max(band.bottom, own.map(\.bottom).max() ?? band.bottom), band.bottom + 0.5 * h)
            for other in lines.map(\.band) {
                if other == band || other.right < pieces[0].x || other.x > pieces[pieces.count - 1].right { continue }
                if other.bottom <= band.y {
                    top = max(top, other.bottom)
                } else if other.y >= band.bottom {
                    bottom = min(bottom, other.y)
                }
            }
            var line = CutLine(band: band, rows: RectD(band.x, top, band.width, bottom - top), pieces: pieces, areas: hit)
            line.vertical = vertical
            let align = alignmentOf(band, lines.map(\.band).filter { $0 != band }, extent)
            // A line that reads the other way: its start and end swap.
            line.align = !l.reversed ? align : align == .start ? .end : align == .end ? .start : align
            line.limit = max(min(limit, extent), pieces[pieces.count - 1].right)
            line.limitStart = min(max(limitStart, 0), pieces[0].x)
            found.append(line)
        }
        return found
    }

    /// Which edge a line keeps: its start when it starts where a line near it does (left-aligned or justified text), its
    /// end when it ends where one near it ends (right-aligned), its middle when its middle is another's or, alone, the
    /// page's (centred); else its start.
    static func alignmentOf(_ band: RectD, _ others: [RectD], _ extent: Double) -> Alignment {
        let h = band.height
        let near = others.filter { o in
            o.right > band.x && o.x < band.right && abs(o.centerY - band.centerY) <= 4 * h && abs(o.height - h) <= 0.5 * h
        }
        let tol = 0.5 * h
        if near.contains(where: { abs($0.x - band.x) <= tol }) { return .start }
        if near.contains(where: { abs($0.right - band.right) <= tol }) { return .end }
        if near.contains(where: { abs($0.centerX - band.centerX) <= tol }) { return .middle }
        if near.isEmpty && abs(band.centerX - extent / 2) <= h { return .middle }
        return .start
    }

    /// Where each piece goes (its new start and width, line space): kept to the line's alignment edge, each word and
    /// earlier box as wide as it was, each new box `boxWidth`, a space of `spaceOfHeight` line heights where there was one.
    /// A line that would run into the next column or off the page has its spaces narrowed to fit, then its boxes (only then
    /// does anything depend on the removed width).
    static func layout(_ line: CutLine) -> [(x: Double, width: Double)] {
        let h = line.height
        let pieces = line.pieces
        var widths = pieces.map { $0.box ? boxWidth($0.right - $0.x, h) : $0.right - $0.x }
        let spaces = pieces.dropFirst().count { $0.spaced }
        var space = spaceOfHeight * h
        // The edge kept, and the room the line has from it.
        let edge: Double, room: Double
        switch line.align {
        case .end:
            (edge, room) = (line.band.right, line.band.right - line.limitStart)
        case .middle:
            (edge, room) = (line.band.centerX, 2 * min(line.band.centerX - line.limitStart, line.limit - line.band.centerX))
        case .start:
            // Its start: where its text started (a new box first starts there too), or an earlier box that was first.
            let start = pieces[0].box ? max(pieces[0].x, line.band.x) : pieces[0].x
            (edge, room) = (start, line.limit - start)
        }
        var over = widths.reduce(0, +) + Double(spaces) * space - room
        if over > 0 && spaces > 0 {
            let narrowed = max(0, space - over / Double(spaces))
            over -= (space - narrowed) * Double(spaces)
            space = narrowed
        }
        // Still too wide (a box rounded up with no space to take it from): the boxes give back what rounding added.
        var k = 0
        while k < pieces.count && over > 1e-9 {
            if pieces[k].box && widths[k] > pieces[k].right - pieces[k].x {
                let back = min(over, widths[k] - (pieces[k].right - pieces[k].x))
                widths[k] -= back
                over -= back
            }
            k += 1
        }
        let total = widths.reduce(0, +) + Double(spaces) * space
        var x: Double
        switch line.align {
        case .end: x = edge - total
        case .middle: x = edge - total / 2
        case .start: x = edge
        }
        var placed: [(x: Double, width: Double)] = []
        for k in pieces.indices {
            if k > 0 && pieces[k].spaced { x += space }
            placed.append((x, widths[k]))
            x += widths[k]
        }
        return placed
    }

    /// A page picture being redacted (RGB, 3 bytes a pixel): what was there (`before`, every area already black) is read,
    /// the picture written.
    final class Canvas {
        var rgb: [UInt8]
        let before: [UInt8]
        let width: Int, height: Int
        let scale: Double
        /// The areas in pixels, as they were blacked out (out to whole pixels).
        let areas: [(x0: Int, y0: Int, x1: Int, y1: Int)]
        /// The page's most common color (in steps of 16, as its middle; sampled), for what has nothing better.
        let paper: (UInt8, UInt8, UInt8)

        init(_ rgb: [UInt8], _ width: Int, _ height: Int, _ scale: Double, _ areas: [RectD]) {
            self.rgb = rgb
            before = rgb
            self.width = width
            self.height = height
            self.scale = scale
            func clamp(_ v: Double, _ hi: Int) -> Int { Int(exactly: min(max(v, 0), Double(hi)).rounded(.towardZero)) ?? 0 }
            self.areas = areas.map { a in
                (clamp((a.x * scale).rounded(.down), width), clamp((a.y * scale).rounded(.down), height),
                 clamp((a.right * scale).rounded(.up), width), clamp((a.bottom * scale).rounded(.up), height))
            }
            paper = Self.paperOf(rgb, width, height)
        }

        func inArea(_ x: Int, _ y: Int) -> Bool { areas.contains { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 } }

        private static func paperOf(_ rgb: [UInt8], _ width: Int, _ height: Int) -> (UInt8, UInt8, UInt8) {
            var counts = [Int](repeating: 0, count: 4096)
            var firstSeen = [Int](repeating: Int.max, count: 4096)
            let n = width * height
            let step = max(1, n / 200_000)
            var i = 0
            while i < n {
                let key = Int(rgb[i * 3] >> 4) << 8 | Int(rgb[i * 3 + 1] >> 4) << 4 | Int(rgb[i * 3 + 2] >> 4)
                counts[key] += 1
                firstSeen[key] = min(firstSeen[key], i)
                i += step
            }
            // The most common; of equal counts the one seen first (as .NET's dictionary gives it).
            var k = 0xFFF
            for key in 0..<4096 where counts[key] > 0 {
                if k == 0xFFF && counts[k] == 0 || counts[key] > counts[k] || counts[key] == counts[k] && firstSeen[key] < firstSeen[k] { k = key }
            }
            return (UInt8((k >> 8 & 15) * 16 + 8), UInt8((k >> 4 & 15) * 16 + 8), UInt8((k & 15) * 16 + 8))
        }

        /// The paper beside (along, across) in line space: the nearest pixel on its row outside every area, before `from`
        /// or after `to`, else `paper`.
        func paperBeside(_ vertical: Bool, _ from: Int, _ to: Int, _ across: Int) -> (UInt8, UInt8, UInt8) {
            let along = vertical ? height : width
            for d in 2...96 {
                for a in [from - d, to - 1 + d] {
                    if a < 0 || a >= along { continue }
                    let (x, y) = vertical ? (across, a) : (a, across)
                    if inArea(x, y) { continue }
                    let o = (y * width + x) * 3
                    return (before[o], before[o + 1], before[o + 2])
                }
            }
            return paper
        }
    }

    /// Lays the line out again in the canvas: the rows of `CutLine.rows`, from the furthest of the line's old and new edges
    /// and its areas' (not past another column), are drawn anew from `Canvas.before`: each word and earlier box where
    /// `layout` puts it, each new box black, the space between from the space that was there (stretched or squeezed, never
    /// from inside an area), the rest paper. When the line's space holds something that isn't paper (a rule, a picture),
    /// the line stays: each box is rounded where it is as far as the words beside it allow, the rest of it paper.
    static func relay(_ canvas: Canvas, _ line: CutLine, _ placed: [(x: Double, width: Double)]) -> Relaid {
        let scale = canvas.scale
        let vertical = line.vertical
        let along = vertical ? canvas.height : canvas.width
        let acrossMax = vertical ? canvas.width : canvas.height
        func clamp(_ v: Double, _ hi: Int) -> Int { v.isNaN ? 0 : Int(min(max(v, 0), Double(hi))) }
        func px(_ v: Double) -> Int { clamp((v * scale).rounded(.toNearestOrEven), along) }
        func floorPx(_ v: Double, _ hi: Int) -> Int { clamp((v * scale).rounded(.down), hi) }
        func ceilPx(_ v: Double, _ hi: Int) -> Int { clamp((v * scale).rounded(.up), hi) }
        func at(_ a: Int, _ c: Int) -> Int { vertical ? (a * canvas.width + c) * 3 : (c * canvas.width + a) * 3 }
        let y0 = floorPx(line.rows.y, acrossMax)
        let y1 = ceilPx(line.rows.bottom, acrossMax)
        let pieces = line.pieces
        let oldStart = pieces.map { px($0.x) }
        let oldEnd = pieces.map { px($0.right) }
        let newStart = placed.map { px($0.x) }
        let newEnd = placed.map { px($0.x + $0.width) }
        let limitStart = floorPx(line.limitStart, along)
        let limitEnd = ceilPx(line.limit, along)
        // Out to whole pixels and over the areas' width on these rows (up to another column): nothing marks where the line ended.
        let left = min(min(floorPx(pieces[0].x, along), newStart[0]), max(limitStart, floorPx(line.areas.map(\.x).min() ?? 0, along)))
        let right = max(max(ceilPx(pieces[pieces.count - 1].right, along), newEnd[newEnd.count - 1]),
                        min(limitEnd, ceilPx(line.areas.map(\.right).max() ?? 0, along)))
        var result = Relaid()
        if y1 <= y0 || right <= left { return result }
        func rect(_ a0: Int, _ a1: Int) -> RectD {
            line.toPage(RectD(Double(a0) / scale, Double(y0) / scale, Double(a1 - a0) / scale, Double(y1 - y0) / scale))
        }
        let w = right - left
        // What the areas blacked out on these rows (line space, from the line's start to its end).
        var mask = [Bool](repeating: false, count: w * (y1 - y0))
        for (x0, ay0, x1, ay1) in canvas.areas {
            let (a0, a1, c0, c1) = vertical ? (ay0, ay1, x0, x1) : (x0, x1, ay0, ay1)
            var c = max(c0, y0)
            while c < min(c1, y1) {
                var a = max(a0, left)
                while a < min(a1, right) {
                    mask[(c - y0) * w + a - left] = true
                    a += 1
                }
                c += 1
            }
        }
        func blacked(_ a: Int, _ c: Int) -> Bool { a >= left && a < right && mask[(c - y0) * w + a - left] }

        // Paper for each row, from beside the line.
        let paper = (y0..<y1).map { canvas.paperBeside(vertical, left, right, $0) }
        func paint(_ a: Int, _ c: Int) {
            let o = at(a, c)
            (canvas.rgb[o], canvas.rgb[o + 1], canvas.rgb[o + 2]) = paper[c - y0]
        }

        // Its spaces must be paper: a rule or a picture there would be cut up and moved.
        let mid = (y0 + y1) / 2
        var inPiece = [Bool](repeating: false, count: w)
        for k in pieces.indices {
            var a = max(left, oldStart[k] - 1)
            while a < min(right, oldEnd[k] + 1) {
                inPiece[a - left] = true
                a += 1
            }
        }
        var busy = false
        var a = left
        while a < right && !busy {
            defer { a += 1 }
            if inPiece[a - left] || blacked(a, mid) { continue }
            var ink = 0
            for c in y0..<y1 {
                let o = at(a, c)
                let (r, g, b) = paper[c - y0]
                if abs(Int(canvas.before[o]) - Int(r)) + abs(Int(canvas.before[o + 1]) - Int(g)) + abs(Int(canvas.before[o + 2]) - Int(b)) > 120 { ink += 1 }
            }
            busy = Double(ink) > 0.5 * Double(y1 - y0)
        }
        if busy { return inPlace(canvas, line, rect, at, paint, y0, y1, oldStart, oldEnd) }

        let black = -1, background = -2
        var source = [Int](repeating: background, count: w)
        for k in pieces.indices {
            var a = max(left, newStart[k])
            while a < min(right, newEnd[k]) {
                source[a - left] = pieces[k].box ? black : min(max(oldStart[k] + (a - newStart[k]), 0), along - 1)
                a += 1
            }
            if k + 1 == pieces.count { break }
            // The space after it: from the old space's columns outside every area, stretched or squeezed to fit.
            let clean = (oldEnd[k]..<max(oldEnd[k], oldStart[k + 1])).filter { $0 < along && !blacked($0, mid) }
            let gap = newStart[k + 1] - newEnd[k]
            var j = 0
            while j < gap && !clean.isEmpty {
                if newEnd[k] + j >= left && newEnd[k] + j < right { source[newEnd[k] + j - left] = clean[j * clean.count / gap] }
                j += 1
            }
        }
        for c in y0..<y1 {
            for a in left..<right {
                let s = source[a - left]
                let o = at(a, c)
                if s == black {
                    canvas.rgb[o] = 0
                    canvas.rgb[o + 1] = 0
                    canvas.rgb[o + 2] = 0
                } else if s == background || blacked(s, c) {
                    paint(a, c) // nothing of an area moves with a word
                } else {
                    let from = at(s, c)
                    canvas.rgb[o] = canvas.before[from]
                    canvas.rgb[o + 1] = canvas.before[from + 1]
                    canvas.rgb[o + 2] = canvas.before[from + 2]
                }
            }
        }
        for k in pieces.indices where newEnd[k] > newStart[k] {
            if pieces[k].box {
                result.boxes.append(rect(newStart[k], newEnd[k]))
                continue
            }
            let was = line.toPage(RectD(pieces[k].x, Double(y0) / scale, pieces[k].right - pieces[k].x, Double(y1 - y0) / scale))
            if pieces[k].kind == .fixed { result.fixed.append((was, rect(newStart[k], newEnd[k]))) }
            if placed[k].x != pieces[k].x {
                let d = placed[k].x - pieces[k].x
                result.moved.append((was, vertical ? 0 : d, vertical ? d : 0))
            }
        }
        result.rows = rect(left, right)
        return result
    }

    /// A line left where it is: each new box rounded from its start, no further than the next piece, its rest paper.
    private static func inPlace(_ canvas: Canvas, _ line: CutLine, _ rect: (Int, Int) -> RectD, _ at: (Int, Int) -> Int, _ paint: (Int, Int) -> Void,
                                _ y0: Int, _ y1: Int, _ oldStart: [Int], _ oldEnd: [Int]) -> Relaid {
        var result = Relaid()
        result.laidOut = false
        let pieces = line.pieces
        let step = Int((stepOfHeight * line.height * canvas.scale).rounded(.toNearestOrEven))
        let along = line.vertical ? canvas.height : canvas.width
        for k in pieces.indices where pieces[k].box {
            let room = k + 1 < pieces.count ? oldStart[k + 1] - oldStart[k] : Int.max
            let steps = max(1, Int((Double(oldEnd[k] - oldStart[k]) / Double(max(1, step))).rounded(.toNearestOrEven)))
            let width = min(steps * step, room)
            for c in y0..<y1 {
                var a = oldStart[k]
                while a < oldStart[k] + width && a < along {
                    let o = at(a, c)
                    canvas.rgb[o] = 0
                    canvas.rgb[o + 1] = 0
                    canvas.rgb[o + 2] = 0
                    a += 1
                }
                a = oldStart[k] + width
                while a < oldEnd[k] {
                    paint(a, c)
                    a += 1
                }
            }
            result.boxes.append(rect(oldStart[k], oldStart[k] + width))
        }
        result.rows = rect(oldStart[0], oldEnd[oldEnd.count - 1])
        return result
    }
}
