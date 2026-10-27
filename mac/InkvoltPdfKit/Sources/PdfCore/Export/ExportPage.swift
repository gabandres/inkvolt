import Foundation

/// A run of text in one look: font family as the PDF names it, size in points, bold, italic, color (0xRRGGBB).
public struct ExportSpan: Equatable, Sendable {
    public var text: String
    public var font: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var color: UInt32
    public var box: RectD
    /// The font is a serif one (from the PDF's font flags), so a reader without it gets a serif in its place.
    public var serif = false
    /// The font is monospaced.
    public var mono = false

    public init(_ text: String, _ font: String, _ size: Double, _ bold: Bool, _ italic: Bool, _ color: UInt32, _ box: RectD) {
        self.text = text
        self.font = font
        self.size = size
        self.bold = bold
        self.italic = italic
        self.color = color
        self.box = box
    }

    /// Same look as `other` (text and position aside).
    public func sameLook(_ other: ExportSpan) -> Bool {
        font == other.font && abs(size - other.size) < 0.25 && bold == other.bold && italic == other.italic && color == other.color
    }

    func with(text: String) -> ExportSpan {
        var s = self
        s.text = text
        return s
    }

    func with(text: String, box: RectD) -> ExportSpan {
        var s = self
        s.text = text
        s.box = box
        return s
    }
}

/// A line of text on a page (page space: points, top-left of the displayed page). Sideways: not left-to-right; `turn`
/// says which way it reads.
public struct ExportLine: Equatable, Sendable {
    public var spans: [ExportSpan] { didSet { text = spans.map(\.text).joined() } }
    public var box: RectD
    public var sideways: Bool
    /// Quarter turns clockwise from left-to-right: 0 reads left to right, 1 top to bottom, 2 upside down, 3 bottom to
    /// top. Slanted lines take the nearest.
    public var turn = 0
    public private(set) var text: String

    public init(_ spans: [ExportSpan], _ box: RectD, sideways: Bool = false, turn: Int = 0) {
        self.spans = spans
        self.box = box
        self.sideways = sideways
        self.turn = turn
        text = spans.map(\.text).joined()
    }

    /// The turn to read it by: `turn`, or bottom to top (the usual) for a sideways line made without one.
    public var reads: Int { turn != 0 || !sideways ? turn : 3 }

    /// The size most of the line's characters have.
    public var size: Double {
        if spans.isEmpty { return 0 }
        let groups = groupedInOrder(spans) { bankers($0.size * 2) / 2 }
        return groups.max { a, b in a.items.reduce(0) { $0 + $1.text.utf16.count } < b.items.reduce(0) { $0 + $1.text.utf16.count } }!.key
    }

    public static func of(_ spans: [ExportSpan], sideways: Bool = false) -> ExportLine {
        var box = spans[0].box
        for s in spans.dropFirst() { box = box.union(s.box) }
        return ExportLine(spans, box, sideways: sideways)
    }

    /// Where a line's characters split at column gaps: [start, end) ranges. Each character gives its text, where it
    /// starts and ends along the reading direction, and its type size. A gap over 2.5 times the size splits; so does one
    /// over the size between two number-like words ("28.54", "12%", "–"): table columns set close together that MuPDF
    /// reads as one line. Spaces in a gap are dropped.
    public static func splitAtColumnGaps(_ chars: [(text: String, from: Double, to: Double, size: Double)]) -> [(start: Int, end: Int)] {
        var parts: [(start: Int, end: Int)] = []
        var start = 0
        var lastInk = -1
        func blank(_ k: Int) -> Bool { chars[k].text.isBlank }
        func word(_ from: Int, _ step: Int) -> String {
            var k = from
            while k + step >= 0 && k + step < chars.count && !blank(k + step) { k += step }
            let (a, b) = step < 0 ? (k, from) : (from, k)
            return (a...b).map { chars[$0].text }.joined()
        }
        for i in chars.indices {
            if blank(i) { continue }
            if lastInk >= 0 {
                let gap = chars[i].from - chars[lastInk].to
                let size = max(1, max(chars[i].size, chars[lastInk].size))
                if gap > 2.5 * size || (gap > size && numberLike(word(lastInk, -1)) && numberLike(word(i, 1))) {
                    parts.append((start, lastInk + 1))
                    start = i
                }
            }
            lastInk = i
        }
        parts.append((start, chars.count))
        return parts
    }

    /// A number as a table shows it ("28.54", "1,200", "12%", "(3)", "$5"), or a dash standing for none.
    public static func numberLike(_ word: String) -> Bool {
        let w = word.trimmedWS
        let allowed: Set<Unicode.Scalar> = [".", ",", "%", "-", "–", "—", "+", "(", ")", "$", "€", "£", "±"]
        return !w.isEmpty && w.unicodeScalars.allSatisfy { $0.isDecimalDigit || allowed.contains($0) }
            && (w.unicodeScalars.contains { $0.isDecimalDigit } || w == "-" || w == "–" || w == "—")
    }

    /// The quarter turn nearest a baseline direction (MuPDF's line direction, page space, y down).
    public static func turnOf(_ dx: Double, _ dy: Double) -> Int {
        abs(dx) >= abs(dy) ? (dx >= 0 ? 0 : 2) : (dy > 0 ? 1 : 3)
    }
}

/// A picture on a page: encoded bytes (PNG or JPEG, see `ext`) and where it is drawn. `ref`: the name a writer gave it
/// once stored (its bytes are then dropped).
public struct ExportImage: Equatable, Sendable {
    public var data: [UInt8]
    public var ext: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var box: RectD
    public var ref: String?

    public init(_ data: [UInt8], _ ext: String, _ pixelWidth: Int, _ pixelHeight: Int, _ box: RectD, ref: String? = nil) {
        self.data = data
        self.ext = ext
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.box = box
        self.ref = ref
    }
}

/// What an export reads from one page: its text lines, pictures and the thin lines and box outlines it draws (for ruled
/// tables). `fromOcr`: the text came from recognizing a scanned page.
public struct ExportPage: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var lines: [ExportLine]
    public var images: [ExportImage]
    public var rules: [RectD]
    public var fromOcr = false

    public init(_ width: Double, _ height: Double, _ lines: [ExportLine], _ images: [ExportImage], _ rules: [RectD], fromOcr: Bool = false) {
        self.width = width
        self.height = height
        self.lines = lines
        self.images = images
        self.rules = rules
        self.fromOcr = fromOcr
    }

    public var hasText: Bool { lines.contains { l in l.spans.contains { !$0.text.isBlank } } }

    /// The page turned so that text reading `turn` quarter turns clockwise reads left to right: boxes move into the
    /// turned frame (width and height swap for 1 and 3), lines' turns change to match. Pictures keep their pixels (only
    /// their place turns).
    public func turned(_ turn: Int) -> ExportPage {
        let turn = ((turn % 4) + 4) % 4
        if turn == 0 { return self }
        let w = width, h = height
        func p(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            switch turn {
            case 1: (y, w - x)        // read downwards: down the page becomes left to right
            case 2: (w - x, h - y)
            default: (h - y, x)       // read upwards
            }
        }
        func map(_ r: RectD) -> RectD {
            let a = p(r.x, r.y), b = p(r.right, r.bottom)
            return .fromEdges(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        }
        var page = self
        page.lines = lines.map { l in
            let t = (l.reads - turn + 4) % 4
            return ExportLine(l.spans.map { s in
                var s = s
                s.box = map(s.box)
                return s
            }, map(l.box), sideways: t != 0, turn: t)
        }
        (page.width, page.height) = turn == 2 ? (w, h) : (h, w)
        page.images = images.map { i in
            var i = i
            i.box = map(i.box)
            return i
        }
        page.rules = rules.map(map)
        return page
    }

    /// The same page without its pictures (Excel and plain text don't use them).
    public func withoutImages() -> ExportPage {
        if images.isEmpty { return self }
        var p = self
        p.images = []
        return p
    }

    /// A scanned page's recognized words as text lines: words side by side at the same height form a line, split where a
    /// gap is wider than a few letters (columns, table cells). Sizes are estimated from the word heights.
    public static func linesFromOcr(_ words: [OcrWord]) -> [ExportLine] {
        var rows: [[OcrWord]] = []
        for w in words.filter({ !$0.text.isBlank && $0.rect.height > 0 }).sorted(by: { $0.rect.y < $1.rect.y }) {
            var best: Int?
            var bestOverlap = 0.0
            for (k, row) in rows.enumerated() {
                let top = row.map(\.rect.y).min()!, bottom = row.map(\.rect.bottom).max()!
                let overlap = min(bottom, w.rect.bottom) - max(top, w.rect.y)
                let h = min(bottom - top, w.rect.height)
                if overlap < 0.5 * h || overlap <= bestOverlap { continue }
                if row.contains(where: { $0.rect.x < w.rect.right && w.rect.x < $0.rect.right }) { continue } // a word below or above, not beside
                best = k
                bestOverlap = overlap
            }
            if let best { rows[best].append(w) } else { rows.append([w]) }
        }

        var lines: [ExportLine] = []
        for row in rows.sorted(by: { $0.map(\.rect.y).min()! < $1.map(\.rect.y).min()! }) {
            let row = row.sorted { $0.rect.x < $1.rect.x }
            let height = row.map(\.rect.height).max()!
            // Word boxes run from ascenders to descenders, about 0.85 of the font size.
            let size = max(4, bankers(height / 0.85 * 2) / 2)
            var part: [OcrWord] = []
            func flush() {
                if part.isEmpty { return }
                let spans = part.indices.map { i in
                    ExportSpan(i == part.count - 1 ? part[i].text : part[i].text + " ", "", size, false, false, 0, part[i].rect)
                }
                lines.append(.of(spans))
                part.removeAll()
            }
            for w in row {
                if let last = part.last, w.rect.x - last.rect.right > 1.5 * height { flush() }
                part.append(w)
            }
            flush()
        }
        return lines
    }
}

// ---- .NET's text and collection semantics, as the export's rules need them ----

/// .NET's `Math.Round`: to the nearest, halves to even.
@inline(__always) func bankers(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

/// `x` within [lo, hi] (.NET's `Math.Clamp`).
@inline(__always) func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

/// Groups in the order their keys first appear (LINQ's `GroupBy`).
func groupedInOrder<T, K: Hashable>(_ items: [T], by key: (T) -> K) -> [(key: K, items: [T])] {
    var index: [K: Int] = [:]
    var groups: [(key: K, items: [T])] = []
    for item in items {
        let k = key(item)
        if let i = index[k] {
            groups[i].items.append(item)
        } else {
            index[k] = groups.count
            groups.append((k, [item]))
        }
    }
    return groups
}

extension Unicode.Scalar {
    /// .NET's `char.IsWhiteSpace`.
    var isWS: Bool { properties.isWhitespace }
    /// .NET's `char.IsLetter`: a letter of any case, modifier or other.
    var isLetter: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
    /// .NET's `char.IsDigit`.
    var isDecimalDigit: Bool { properties.generalCategory == .decimalNumber }
    var isLetterOrDigit: Bool { isLetter || isDecimalDigit }
    var isLowercase: Bool { properties.generalCategory == .lowercaseLetter }
}

extension String {
    /// .NET's `string.IsNullOrWhiteSpace`.
    var isBlank: Bool { unicodeScalars.allSatisfy(\.isWS) }
    /// The one character of a one-character (one UTF-16 unit, as .NET's `Length == 1`) string.
    var single: Unicode.Scalar? { utf16.count == 1 ? unicodeScalars.first : nil }
    var trimmedWS: String { trimmingStart(\.isWS).trimmingEnd(\.isWS) }
    var trimmedStartWS: String { trimmingStart(\.isWS) }
    var trimmedEndWS: String { trimmingEnd(\.isWS) }

    func trimmingStart(_ drop: (Unicode.Scalar) -> Bool) -> String {
        let s = unicodeScalars
        guard let i = s.firstIndex(where: { !drop($0) }) else { return "" }
        return String(s[i...])
    }

    func trimmingEnd(_ drop: (Unicode.Scalar) -> Bool) -> String {
        let s = unicodeScalars
        guard let i = s.lastIndex(where: { !drop($0) }) else { return "" }
        return String(s[...i])
    }

    /// Runs of letters (the export's `\p{L}+`).
    var letterRuns: [String] {
        var runs: [String] = []
        var cur = String.UnicodeScalarView()
        for c in unicodeScalars {
            if c.isLetter {
                cur.append(c)
            } else if !cur.isEmpty {
                runs.append(String(cur))
                cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { runs.append(String(cur)) }
        return runs
    }

    func countScalars(_ where: (Unicode.Scalar) -> Bool) -> Int { unicodeScalars.reduce(0) { $0 + (`where`($1) ? 1 : 0) } }
}
