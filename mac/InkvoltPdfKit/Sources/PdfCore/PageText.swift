import Foundation

/// The text layer of one page: a flat string (lines joined by "\n") with a box per UTF-16 unit, so selection, copy and
/// search work on plain UTF-16 offsets, as the Windows app's `PageText` does on .NET string indices. A "caret" is a
/// position between UTF-16 units (0...count).
public final class PageText: @unchecked Sendable {
    /// A line: its units [start, end), its box, its baseline direction (a unit vector; (1, 0) for normal text, vertical
    /// for text turned sideways) and the box of its column (the run of lines stacked with it in reading order), grown by
    /// a line's thickness so the gaps between lines count as inside.
    private struct Line {
        var start: Int, end: Int
        var box: RectD
        var dx: Double, dy: Double
        var column: RectD
    }

    private static let eps = 0.01

    private let boxes: [RectD]
    private let lineOf: [Int]
    private let lines: [Line]
    /// The text as UTF-16 units: the offsets everything here uses.
    private let units: [UInt16]
    /// The text as search reads it (hyphens at line breaks dropped).
    private let searchView: SearchView

    public static let empty = PageText([])

    public let text: String
    public var isEmpty: Bool { units.isEmpty }
    /// The text's length in UTF-16 units (the largest caret).
    public var length: Int { units.count }

    /// - Parameters:
    ///   - lines: each line is a list of (character string, box) in reading order.
    ///   - directions: per line, its baseline direction, e.g. (1, 0) for normal text and (0, 1) for text turned
    ///     clockwise. Missing or zero: taken from where the line's characters sit.
    public init(_ lines: [[(String, RectD)]], directions: [(Double, Double)]? = nil) {
        var units: [UInt16] = []
        var boxes: [RectD] = []
        var lineOf: [Int] = []
        var spans: [Line] = []
        for (li, line) in lines.enumerated() where !line.isEmpty {
            if !units.isEmpty {
                // A line break: a zero-width box at the end of the previous line.
                let prev = boxes[boxes.count - 1]
                units.append(10)
                boxes.append(RectD(prev.right, prev.y, 0, prev.height))
                lineOf.append(spans.count - 1)
            }
            let start = units.count
            var lineBox = RectD.zero
            for (ch, box) in line {
                for unit in ch.utf16 {
                    units.append(unit)
                    boxes.append(box)
                    lineOf.append(spans.count)
                }
                lineBox = lineBox.union(box)
            }
            let given = directions.flatMap { li < $0.count ? $0[li] : nil } ?? (0, 0)
            let (dx, dy) = Self.direction(line, given)
            spans.append(Line(start: start, end: units.count, box: lineBox, dx: dx, dy: dy, column: lineBox))
        }
        self.units = units
        searchView = SearchView(units)
        self.boxes = boxes
        self.lineOf = lineOf
        text = String(decoding: units, as: UTF16.self)
        Self.findColumns(&spans)
        self.lines = spans
    }

    /// A line's baseline direction as a unit vector: the given one, else the axis its characters run along.
    private static func direction(_ line: [(String, RectD)], _ given: (Double, Double)) -> (Double, Double) {
        let len = (given.0 * given.0 + given.1 * given.1).squareRoot()
        if len > 1e-6 && len.isFinite { return (given.0 / len, given.1 / len) }
        if line.count < 2 { return (1, 0) }
        let vx = line[line.count - 1].1.centerX - line[0].1.centerX
        let vy = line[line.count - 1].1.centerY - line[0].1.centerY
        return abs(vy) > abs(vx) ? (0, 1) : (1, 0)
    }

    /// Groups lines that follow each other in reading order, run the same way, overlap along it and sit at most 1.5
    /// lines apart into columns, and gives each line its column's box.
    private static func findColumns(_ lines: inout [Line]) {
        func sameColumn(_ a: Line, _ b: Line) -> Bool {
            if abs(a.dx * b.dx + a.dy * b.dy) < 0.9 { return false }
            let (a0, a1) = span(a.box, a.dx, a.dy)
            let (b0, b1) = span(b.box, a.dx, a.dy)
            if b0 > a1 || b1 < a0 { return false }
            let (c0, c1) = span(a.box, -a.dy, a.dx)
            let (d0, d1) = span(b.box, -a.dy, a.dx)
            let gap = max(d0 - c1, c0 - d1)
            return gap <= 1.5 * max(c1 - c0, d1 - d0)
        }
        var first = 0
        var i = 1
        while i <= lines.count {
            if i < lines.count && sameColumn(lines[i - 1], lines[i]) {
                i += 1
                continue
            }
            var box = RectD.zero
            var thick = 0.0
            for j in first..<i {
                box = box.union(lines[j].box)
                let (a, b) = span(lines[j].box, -lines[j].dy, lines[j].dx)
                thick = max(thick, b - a)
            }
            box = box.inflate(thick)
            for j in first..<i { lines[j].column = box }
            first = i
            i += 1
        }
    }

    /// A box's extent along the direction (ux, uy): the smallest and largest projection of its corners.
    private static func span(_ b: RectD, _ ux: Double, _ uy: Double) -> (Double, Double) {
        let p = b.x * ux + b.y * uy
        let w = b.width * ux
        let h = b.height * uy
        return (p + min(0, w) + min(0, h), p + max(0, w) + max(0, h))
    }

    private static func distance(_ v: Double, _ span: (Double, Double)) -> Double {
        v < span.0 ? span.0 - v : v > span.1 ? v - span.1 : 0
    }

    /// Nearest caret position to a point in page space (always succeeds when the page has text).
    public func hitTest(_ x: Double, _ y: Double) -> Int { lines.isEmpty ? 0 : caretInLine(pickLine(x, y), x, y) }

    /// The line a point belongs to: the nearest across the text direction (then along it), preferring lines whose
    /// column contains the point.
    private func pickLine(_ x: Double, _ y: Double) -> Int {
        var best = -1, bestAny = 0
        var bestScore = Double.greatestFiniteMagnitude, bestAnyScore = Double.greatestFiniteMagnitude
        for (i, l) in lines.enumerated() {
            let along = Self.distance(x * l.dx + y * l.dy, Self.span(l.box, l.dx, l.dy))
            let across = Self.distance(-x * l.dy + y * l.dx, Self.span(l.box, -l.dy, l.dx))
            let score = across * 1000 + along
            if score < bestAnyScore {
                bestAnyScore = score
                bestAny = i
            }
            if score < bestScore && l.column.contains(x, y) {
                bestScore = score
                best = i
            }
        }
        return best >= 0 ? best : bestAny
    }

    /// The caret in the line holding `caretOnLine` nearest to a point (for moving the caret between lines), measured
    /// along the line's own direction, so it works for sideways and right-to-left text too.
    public func nearestCaretInLine(_ caretOnLine: Int, _ x: Double, _ y: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        return caretInLine(lineOf.isEmpty ? 0 : lineOf[min(max(caretOnLine, 0), lineOf.count - 1)], x, y)
    }

    /// The caret in a line nearest to a point: projected on the line's direction, before or after the nearest character,
    /// whichever half it is in. Characters running against the direction count from their far side.
    private func caretInLine(_ line: Int, _ x: Double, _ y: Double) -> Int {
        let l = lines[line]
        let p = x * l.dx + y * l.dy
        var best = -1
        var bestDist = Double.greatestFiniteMagnitude, bestOff = Double.greatestFiniteMagnitude
        var i = l.start
        while i < l.end {
            let span = Self.span(boxes[i], l.dx, l.dy)
            let dist = Self.distance(p, span)
            let off = abs(p - (span.0 + span.1) / 2)
            if dist < bestDist - Self.eps || (abs(dist - bestDist) <= Self.eps && off < bestOff) {
                bestDist = dist
                bestOff = off
                best = i
            }
            i = next(i, l.end)
        }
        if best < 0 { return l.start }
        let before = p < center(best, l)
        return before != isReversed(best, l) ? best : next(best, l.end)
    }

    private func center(_ i: Int, _ l: Line) -> Double {
        let (a, b) = Self.span(boxes[i], l.dx, l.dy)
        return (a + b) / 2
    }

    /// The offset after the unit at `i` (a surrogate pair is one character).
    private func next(_ i: Int, _ end: Int) -> Int {
        i + 1 < end && UTF16.isLeadSurrogate(units[i]) && UTF16.isTrailSurrogate(units[i + 1]) ? i + 2 : i + 1
    }

    private func previous(_ i: Int, _ start: Int) -> Int {
        i - 2 >= start && UTF16.isTrailSurrogate(units[i - 1]) && UTF16.isLeadSurrogate(units[i - 2]) ? i - 2 : i - 1
    }

    /// True when the character runs against the line's direction (the next character in reading order sits before it, or
    /// the previous one after it, as in a right-to-left run); a lone character goes by its script.
    private func isReversed(_ i: Int, _ l: Line) -> Bool {
        let c = center(i, l)
        let n = next(i, l.end)
        if n < l.end {
            let nc = center(n, l)
            if nc < c - Self.eps { return true }
            if nc > c + Self.eps { return false }
        }
        if i > l.start {
            let pc = center(previous(i, l.start), l)
            if pc > c + Self.eps { return true }
            if pc < c - Self.eps { return false }
        }
        return Self.isRightToLeft(codePoint(at: i))
    }

    private func codePoint(at i: Int) -> UInt32 {
        if i + 1 < units.count && UTF16.isLeadSurrogate(units[i]) && UTF16.isTrailSurrogate(units[i + 1]) {
            return 0x10000 + ((UInt32(units[i]) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
        }
        return UInt32(units[i])
    }

    /// Letters of right-to-left scripts (Hebrew, Arabic, Syriac, Thaana, N'Ko… and their presentation forms).
    static func isRightToLeft(_ cp: UInt32) -> Bool {
        (0x0590...0x08FF).contains(cp) || (0xFB1D...0xFDFF).contains(cp) || (0xFE70...0xFEFF).contains(cp)
            || (0x10800...0x10FFF).contains(cp) || (0x1E800...0x1EFFF).contains(cp)
    }

    /// True when the point is over a line of text (for the I-beam cursor).
    public func isOverText(_ x: Double, _ y: Double) -> Bool { lines.contains { $0.box.inflate(1).contains(x, y) } }

    /// The box of the UTF-16 unit at `index` (a line break's is zero-width, at its line's end).
    public func boxAt(_ index: Int) -> RectD { boxes[index] }

    public func string(_ start: Int, _ end: Int) -> String {
        let (s, e) = order(start, end)
        return String(decoding: units[s..<e], as: UTF16.self)
    }

    /// One rectangle per line covering the characters in [start, end).
    public func rects(_ start: Int, _ end: Int) -> [RectD] {
        let (s, e) = order(start, end)
        var rects: [RectD] = []
        var i = s
        while i < e {
            let line = lineOf[i]
            var r = RectD.zero
            while i < e && lineOf[i] == line {
                if units[i] != 10 { r = r.union(boxes[i]) }
                i += 1
            }
            if !r.isEmpty { rects.append(r) }
        }
        return rects
    }

    /// Expands a caret to the surrounding word (for a double-click).
    public func wordAt(_ caret: Int) -> (start: Int, end: Int) {
        if units.isEmpty { return (0, 0) }
        var i = min(max(caret, 0), units.count - 1)
        if !Self.isWordChar(units[i]) && i > 0 && Self.isWordChar(units[i - 1]) { i -= 1 }
        if !Self.isWordChar(units[i]) { return (i, i + 1) }
        var s = i, e = i
        while s > 0 && Self.isWordChar(units[s - 1]) { s -= 1 }
        while e < units.count && Self.isWordChar(units[e]) { e += 1 }
        return (s, e)
    }

    /// Expands a caret to its whole line (for a triple-click).
    public func lineAt(_ caret: Int) -> (start: Int, end: Int) {
        guard !lines.isEmpty else { return (0, 0) }
        let line = lineOf[min(max(caret, 0), lineOf.count - 1)]
        return (lines[line].start, lines[line].end)
    }


    /// Every occurrence of `query`: whitespace in the query matches any run of whitespace, line breaks included, and
    /// words hyphenated across a line break ("exam-" / "ple") match unhyphenated. Matching is Foundation's (canonical
    /// equivalence, case and diacritics as asked), so the match lengths are its own: a decomposed "é" in the page matches
    /// a composed one in the query and highlights whole.
    public func find(_ query: String, matchCase: Bool, wholeWord: Bool, ignoreAccents: Bool = false) -> [(start: Int, end: Int)] {
        var hits: [(Int, Int)] = []
        let terms = Self.splitOnWhitespace(query)
        if terms.isEmpty || units.isEmpty { return hits }
        let view = searchView
        let text = view.text
        let length = text.length
        var options: NSString.CompareOptions = []
        if !matchCase { options.insert(.caseInsensitive) }
        if ignoreAccents { options.insert(.diacriticInsensitive) }
        var pos = 0
        while pos < length {
            let found = text.range(of: terms[0], options: options, range: NSRange(location: pos, length: length - pos))
            if found.location == NSNotFound || found.length == 0 { break }
            let first = found.location
            var end = first + found.length
            var ok = true
            var t = 1
            while t < terms.count && ok {
                var ws = end
                while ws < length && Self.isWhiteSpace(view.units[ws]) { ws += 1 }
                let next = ws == end ? NSRange(location: NSNotFound, length: 0)
                    : text.range(of: terms[t], options: options.union(.anchored), range: NSRange(location: ws, length: length - ws))
                if next.location == NSNotFound || next.length == 0 {
                    ok = false
                } else {
                    end = ws + next.length
                }
                t += 1
            }
            if ok && wholeWord && ((first > 0 && Self.isWordChar(view.units[first - 1])) || (end < length && Self.isWordChar(view.units[end]))) {
                ok = false
            }
            if ok {
                hits.append(view.toText(first, end))
                pos = end
            } else {
                pos = first + 1
            }
        }
        return hits
    }

    /// The text as search sees it: a hyphen at a line break between two letters ("exam-\nple") and soft hyphens (with a
    /// line break after them) are dropped, so the word reads whole; `map` holds each unit's offset in the page text
    /// (nil when nothing was dropped).
    private struct SearchView {
        let units: [UInt16]
        let text: NSString
        let map: [Int]?

        init(_ source: [UInt16]) {
            let soft: UInt16 = 0xAD, hyphen: UInt16 = 0x2D, newline: UInt16 = 10
            var needed = source.contains(soft)
            if !needed {
                for i in 0..<max(source.count - 1, 0) where source[i] == hyphen && source[i + 1] == newline {
                    needed = true
                    break
                }
            }
            if !needed {
                units = source
                text = String(decoding: source, as: UTF16.self) as NSString
                map = nil
                return
            }
            var kept: [UInt16] = []
            var map: [Int] = []
            var i = 0
            while i < source.count {
                let c = source[i]
                let dropped = c == soft || (c == hyphen && i > 0 && PageText.isLetter(source[i - 1]) && i + 2 < source.count
                                            && source[i + 1] == newline && PageText.isLetter(source[i + 2]))
                if dropped {
                    if i + 1 < source.count && source[i + 1] == newline { i += 1 }
                    i += 1
                    continue
                }
                kept.append(c)
                map.append(i)
                i += 1
            }
            units = kept
            text = NSString(characters: kept, length: kept.count)
            self.map = map
        }

        /// A [start, end) range of this view as a range of the page text.
        func toText(_ start: Int, _ end: Int) -> (Int, Int) {
            guard let map else { return (start, end) }
            return (map[start], end > start ? map[end - 1] + 1 : map[start])
        }
    }

    /// A short excerpt around a match, for the search results list.
    public func excerpt(_ start: Int, _ end: Int, context: Int = 40) -> String {
        let s = max(0, start - context)
        let e = min(units.count, end + context)
        let body = String(decoding: units[s..<e], as: UTF16.self)
        return ((s > 0 ? "…" : "") + body + (e < units.count ? "…" : "")).replacingOccurrences(of: "\n", with: " ")
    }

    private func order(_ a: Int, _ b: Int) -> (Int, Int) {
        let a = min(max(a, 0), units.count), b = min(max(b, 0), units.count)
        return a <= b ? (a, b) : (b, a)
    }

    // .NET's char tests, on one UTF-16 unit (a surrogate half is none of them).

    static func isLetter(_ u: UInt16) -> Bool {
        guard let s = Unicode.Scalar(u) else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isWordChar(_ u: UInt16) -> Bool {
        if u == 0x5F || u == 0x27 || u == 0x2019 { return true } // _ ' ’
        guard let s = Unicode.Scalar(u) else { return false }
        return isLetter(u) || s.properties.generalCategory == .decimalNumber
    }

    static func isWhiteSpace(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isWhitespace ?? false }

    /// `query.Split(null, RemoveEmptyEntries)`: the runs between whitespace.
    private static func splitOnWhitespace(_ query: String) -> [String] {
        var terms: [String] = []
        var current: [UInt16] = []
        for u in query.utf16 {
            if isWhiteSpace(u) {
                if !current.isEmpty { terms.append(String(decoding: current, as: UTF16.self)) }
                current.removeAll()
            } else {
                current.append(u)
            }
        }
        if !current.isEmpty { terms.append(String(decoding: current, as: UTF16.self)) }
        return terms
    }
}
