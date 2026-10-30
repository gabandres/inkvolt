import Foundation

/// A form field `FieldDetection` proposes: where, what kind, and a name taken from its label. `source`: what it was found
/// from: "underscores", "line", "box", "square" or "box character".
public struct FieldSuggestion: Equatable, Sendable {
    public var pageIndex: Int
    public var rect: RectD
    public var kind: DesignFieldKind
    public var name: String
    public var multiline: Bool
    public var source: String

    public init(pageIndex: Int, rect: RectD, kind: DesignFieldKind, name: String, multiline: Bool, source: String) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.kind = kind
        self.name = name
        self.multiline = multiline
        self.source = source
    }
}

/// Proposes form fields from what a page shows (the Windows app's `FieldDetection`): runs of underscores ("Name: ______")
/// and ruled lines become text fields (signature fields when their label says "signature"), empty boxes become text fields
/// (multi-line when tall), and small squares (drawn, or ☐ characters) become check boxes. Each is named after the text
/// beside it (left, else above or below; right of a check box). Boxes holding text, lines underlining text, page frames and
/// places already holding a field are skipped. Pure geometry over the page's text and `VectorShapes`.
public enum FieldDetection {
    private static let boxGlyphs: Set<UInt16> = [0x2610, 0x25A1, 0x274F, 0x2750, 0x2751, 0x2752, 0x25A2, 0x25FB, 0x2B1C]
    private static let underscore: UInt16 = 0x5F
    private static let newline: UInt16 = 0x0A

    /// A character of the page's text, one UTF-16 unit as `PageText` keeps them.
    private struct Ch {
        var c: UInt16
        var box: RectD
        var line: Int
    }

    private struct Found {
        var rect: RectD
        var kind: DesignFieldKind
        var label: String
        var multiline: Bool
        var source: String
    }

    /// Suggestions for `pages` of an open document (its text from `engine`, its shapes from `data`), skipping places
    /// `existing` fields cover; names are unique across them. `progress`: (pages done, pages).
    public static func suggest(_ engine: PdfEngine, _ data: [UInt8], _ password: String?, _ pages: [Int], _ existing: [DesignField],
                               cancel: CancelToken? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> [FieldSuggestion] {
        var names = existing.map(\.name)
        var result: [FieldSuggestion] = []
        let doc = try PdfEdit.openToRead(data, password)
        for (done, p) in pages.enumerated() {
            try cancel?.check()
            progress?(done, pages.count)
            let g = engine.page(p)
            let found = try suggest(p, g.width, g.height, engine.text(p, cache: false, cancel: cancel), VectorShapes.read(doc, p, cancel: cancel),
                                    existing.filter { $0.pageIndex == p }.map(\.rect), names, cancel: cancel)
            names += found.map(\.name)
            result += found
        }
        return result
    }

    /// Suggestions for one page, in reading order, named uniquely among `existingNames` and each other.
    public static func suggest(_ pageIndex: Int, _ pageWidth: Double, _ pageHeight: Double, _ text: PageText, _ shapes: [PageShape],
                               _ existingFields: [RectD], _ existingNames: [String], cancel: CancelToken? = nil) throws -> [FieldSuggestion] {
        let chars = CharIndex(characters(text))
        var found: [Found] = []
        var captions = Set<String>() // labels read right of their field (their first words count)
        func caption(_ label: String?) -> String? {
            if let label { captions.insert(label) }
            return label
        }

        // Boxes first: they decide which rules are only their edges.
        let boxGrid = RectGrid()
        for b in try boxes(shapes, pageWidth, pageHeight, cancel) {
            try cancel?.check()
            boxGrid.add(b)
            let inner = b.inflate(-1)
            if chars.near(b).contains(where: { !isWhitespace($0.c) && inner.contains($0.box.centerX, $0.box.centerY) }) { continue } // holds text
            if isSquare(b) {
                let label = caption(labelRight(chars, b)) ?? labelLeft(chars, b, 120) ?? ""
                found.append(Found(rect: b, kind: .checkBox, label: label, multiline: false, source: "square"))
            } else if b.height >= 10 && b.width >= 24 && b.height <= min(400, pageHeight * 0.6) {
                let label = labelLeft(chars, b, 150) ?? labelAbove(chars, b) ?? ""
                found.append(Found(rect: b, kind: kindFor(label), label: label, multiline: b.height >= 36, source: "box"))
            }
        }

        // ☐ characters.
        for c in chars.all where boxGlyphs.contains(c.c) {
            try cancel?.check()
            let side = max(6, min(c.box.width, c.box.height) * 0.9)
            let r = RectD(c.box.centerX - side / 2, c.box.centerY - side / 2, side, side)
            let label = caption(labelRight(chars, r)) ?? labelLeft(chars, r, 120) ?? ""
            found.append(Found(rect: r, kind: .checkBox, label: label, multiline: false, source: "box character"))
        }

        // Runs of underscores: a field on the run, named after the text before it on the line.
        let all = chars.all
        var i = 0
        while i < all.count {
            if all[i].c != underscore {
                i += 1
                continue
            }
            try cancel?.check()
            var j = i
            while j + 1 < all.count && all[j + 1].c == underscore && all[j + 1].line == all[i].line { j += 1 }
            if j - i + 1 >= 3 {
                var run = all[i].box
                for k in (i + 1)...j { run = run.union(all[k].box) }
                // The rule of an underscore lies near the baseline; character boxes end at the descender or, with some
                // embedded fonts, above the baseline: reach a little below the box either way.
                let bottom = run.bottom + run.height * 0.3
                let height = min(max(run.height * 1.3, 12), 24)
                let r = RectD.fromEdges(run.x, bottom - height, run.right, bottom)
                let label = textBefore(all, i) ?? labelBelow(chars, r) ?? labelAbove(chars, r) ?? ""
                found.append(Found(rect: r, kind: kindFor(label), label: label, multiline: false, source: "underscores"))
            }
            i = j + 1
        }

        // Ruled lines: a field standing on the line.
        for line in try rules(shapes, cancel) {
            try cancel?.check()
            if line.width < 30 { continue }
            if boxGrid.near(line.inflate(2)).contains(where: { onEdge(line, $0) }) { continue }
            // Underlined text, or a rule just below a line of text: not a blank to fill.
            let above = chars.near(RectD.fromEdges(line.x, line.y - 24, line.right, line.y + 2)).filter {
                !isWhitespace($0.c) && $0.box.right > line.x && $0.box.x < line.right && $0.box.bottom <= line.y + 2 && $0.box.bottom > line.y - 24
            }
            let covered = above.filter { $0.box.bottom > line.y - 6 }.reduce(0.0) { $0 + min($1.box.right, line.right) - max($1.box.x, line.x) }
            if covered > line.width * 0.2 { continue }
            let free = above.isEmpty ? 24 : line.y - above.map(\.box.bottom).max()!
            let height = min(20, free - 2)
            if height < 9 { continue }
            let r = RectD.fromEdges(line.x, line.y - height, line.right, line.y)
            let left = labelLeft(chars, r, 90)
            if left == nil && line.width > pageWidth * 0.75 { continue } // a separator across the page
            let label = left ?? labelBelow(chars, r) ?? ""
            found.append(Found(rect: r, kind: kindFor(label), label: label, multiline: false, source: "line"))
        }

        // Drop what overlaps an existing field or an earlier suggestion (boxes win over the rules and runs inside them).
        let taken = RectGrid()
        for e in existingFields { taken.add(e) }
        var kept: [Found] = []
        for s in found {
            try cancel?.check()
            if taken.near(s.rect).contains(where: { overlaps($0, s.rect, 0.3) }) { continue }
            taken.add(s.rect)
            kept.append(s)
        }

        func order(_ f: Found) -> (Double, Double) { ((f.rect.y / 6).rounded(.toNearestOrEven), f.rect.x) }
        let reading = kept.enumerated().sorted { a, b in
            let ka = order(a.element), kb = order(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        var names = existingNames
        var result: [FieldSuggestion] = []
        for s in reading {
            let clean = cleanLabel(s.label, leading: captions.contains(s.label))
            let name = clean.isEmpty ? FormDesign.nextName(names, s.kind) : FormDesign.uniqueName(names, clean)
            names.append(name)
            result.append(FieldSuggestion(pageIndex: pageIndex, rect: s.rect, kind: s.kind, name: name, multiline: s.multiline, source: s.source))
        }
        return result
    }

    private static let bracketed = try! NSRegularExpression(pattern: #"\([^)]*\)?"#)
    private static let numbering = try! NSRegularExpression(pattern: #"^\s*(\d+|[A-Za-z]|[ivxIVX]+)[.)]\s+"#)

    /// A field name from a label: "1. Date of birth (dd/mm):" → "Date of birth"; dots (which nest names) and stray
    /// punctuation go. A long label keeps the five words nearest the field: its last words, or with `leading` (a caption
    /// right of the field) its first.
    public static func cleanLabel(_ label: String, leading: Bool = false) -> String {
        // "(mm/dd/yyyy)" and list numbering ("1.", "b)") aren't part of the name.
        var text = bracketed.stringByReplacingMatches(in: label, range: NSRange(label.startIndex..., in: label), withTemplate: " ")
        text = numbering.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        var kept = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if isLetterOrDigit(s) || "-'/&#".unicodeScalars.contains(s) {
                kept.append(s)
            } else if s.properties.isWhitespace || ".,_()".unicodeScalars.contains(s) {
                kept.append(" ")
            }
        }
        let words = String(kept).split(separator: " ").map(String.init)
        // The words nearest the field: at most five (a long instruction sentence makes a poor name).
        let chosen = leading ? words.prefix(5) : words.suffix(5)
        let name = chosen.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-/&'# "))
        if name.utf16.count <= 40 { return name }
        let cut = String(name.utf16.prefix(40)) ?? String(name.prefix(40))
        return cut.trimmingCharacters(in: .whitespaces)
    }

    private static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }

    private static func isWhitespace(_ c: UInt16) -> Bool { Unicode.Scalar(c)?.properties.isWhitespace ?? false }

    private static func kindFor(_ label: String) -> DesignFieldKind {
        label.range(of: "signature", options: .caseInsensitive) != nil || label.range(of: "sign here", options: .caseInsensitive) != nil ? .signature : .text
    }

    private static func characters(_ text: PageText) -> [Ch] {
        var list: [Ch] = []
        var line = 0
        for (i, c) in text.text.utf16.enumerated() {
            if c == newline {
                line += 1
                continue
            }
            let box = text.boxAt(i)
            if box.width <= 0 && box.height <= 0 { continue }
            list.append(Ch(c: c, box: box, line: line))
        }
        return list
    }

    /// Distinct boxes, without page frames and without boxes that hold other boxes (tables, panels).
    private static func boxes(_ shapes: [PageShape], _ pageWidth: Double, _ pageHeight: Double, _ cancel: CancelToken?) throws -> [RectD] {
        var all: [RectD] = []
        let grid = RectGrid()
        for s in shapes where !s.isLine {
            try cancel?.check()
            let b = s.box
            if b.width * b.height > pageWidth * pageHeight * 0.4 || b.width > pageWidth * 0.95 { continue }
            if b.width < 5 || b.height < 5 { continue }
            if grid.near(b.inflate(1)).contains(where: { same($0, b) }) { continue }
            grid.add(b)
            all.append(b)
        }
        var result: [RectD] = []
        for b in all {
            try cancel?.check()
            if !grid.near(b).contains(where: { !same($0, b) && inside($0, b) }) { result.append(b) }
        }
        return result
    }

    private static func rules(_ shapes: [PageShape], _ cancel: CancelToken?) throws -> [RectD] {
        let seen = RectGrid()
        var result: [RectD] = []
        for s in shapes where s.isLine {
            try cancel?.check()
            let b = s.box
            if seen.near(b.inflate(1.5)).contains(where: { abs($0.x - b.x) < 1 && abs($0.right - b.right) < 1 && abs($0.y - b.y) < 1.5 }) { continue }
            seen.add(b)
            result.append(b)
        }
        return result
    }

    private static func isSquare(_ b: RectD) -> Bool {
        (5...24).contains(b.width) && (5...24).contains(b.height) && abs(b.width - b.height) <= max(1.5, 0.15 * max(b.width, b.height))
    }

    private static func same(_ a: RectD, _ b: RectD) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.right - b.right) < 1 && abs(a.bottom - b.bottom) < 1
    }

    /// `inner` lies within `outer`.
    private static func inside(_ inner: RectD, _ outer: RectD) -> Bool {
        inner.x >= outer.x - 0.5 && inner.right <= outer.right + 0.5 && inner.y >= outer.y - 0.5 && inner.bottom <= outer.bottom + 0.5
    }

    /// A rule that is the top or bottom edge of a box (or a line across its inside, as in a comb).
    private static func onEdge(_ line: RectD, _ box: RectD) -> Bool {
        line.x >= box.x - 2 && line.right <= box.right + 2 && line.y >= box.y - 2 && line.bottom <= box.bottom + 2
    }

    private static func overlaps(_ a: RectD, _ b: RectD, _ share: Double) -> Bool {
        let i = a.intersect(b)
        if i.isEmpty { return false }
        return i.width * i.height > share * min(a.width * a.height, b.width * b.height)
    }

    /// Text on the same line before character `index` (back to the previous run of underscores).
    private static func textBefore(_ chars: [Ch], _ index: Int) -> String? {
        let line = chars[index].line
        var start = index
        while start > 0 && chars[start - 1].line == line && chars[start - 1].c != underscore { start -= 1 }
        return join(chars[start..<index])
    }

    /// Words on the same row ending at most `reach` points left of `r`.
    private static func labelLeft(_ chars: CharIndex, _ r: RectD, _ reach: Double) -> String? {
        let row = chars.near(RectD.fromEdges(r.x - reach, r.y, r.x + 2, r.bottom)).filter {
            $0.box.right <= r.x + 2 && $0.box.right > r.x - reach && verticalOverlap($0.box, r) > min($0.box.height, r.height) * 0.5
        }
        guard !row.isEmpty else { return nil }
        // Only the stretch nearest the field: stop at a wide gap.
        let ordered = stableSorted(row) { $0.box.x > $1.box.x }
        var taken = [ordered[0]]
        for c in ordered.dropFirst() {
            if taken[taken.count - 1].box.x - c.box.right > max(12, c.box.height * 1.5) { break }
            taken.append(c)
        }
        if r.x - ordered[0].box.right > reach { return nil }
        return join(stableSorted(taken) { $0.box.x < $1.box.x })
    }

    /// Words on the same row starting just right of `r` (a check box's caption).
    private static func labelRight(_ chars: CharIndex, _ r: RectD) -> String? {
        let row = stableSorted(chars.near(RectD.fromEdges(r.right - 1, r.y, r.right + 200, r.bottom)).filter {
            $0.box.x >= r.right - 1 && $0.box.x < r.right + 200 && verticalOverlap($0.box, r) > min($0.box.height, r.height) * 0.4
        }) { $0.box.x < $1.box.x }
        guard let first = row.first, first.box.x - r.right <= 30 else { return nil }
        var taken = [first]
        for c in row.dropFirst() {
            if c.box.x - taken[taken.count - 1].box.right > max(12, c.box.height * 1.5) || boxGlyphs.contains(c.c) { break }
            taken.append(c)
        }
        return join(taken)
    }

    /// The line of text just above `r` (within 20 points), over its left part.
    private static func labelAbove(_ chars: CharIndex, _ r: RectD) -> String? {
        let near = chars.near(RectD.fromEdges(r.x - 4, r.y - 20, r.right, r.y + 2)).filter {
            $0.box.bottom <= r.y + 2 && $0.box.bottom > r.y - 20 && $0.box.right > r.x - 4 && $0.box.x < r.right
        }
        guard let lowest = near.max(by: { $0.box.bottom < $1.box.bottom }) else { return nil }
        return join(stableSorted(near.filter { $0.line == lowest.line }) { $0.box.x < $1.box.x })
    }

    /// A caption just below `r` (within 16 points), as under a signature line.
    private static func labelBelow(_ chars: CharIndex, _ r: RectD) -> String? {
        let near = chars.near(RectD.fromEdges(r.x, r.bottom - 1, r.right, r.bottom + 16)).filter {
            $0.box.y >= r.bottom - 1 && $0.box.y < r.bottom + 16 && $0.box.right > r.x && $0.box.x < r.right
        }
        guard let highest = near.min(by: { $0.box.y < $1.box.y }) else { return nil }
        return join(stableSorted(near.filter { $0.line == highest.line }) { $0.box.x < $1.box.x })
    }

    private static func verticalOverlap(_ a: RectD, _ b: RectD) -> Double { min(a.bottom, b.bottom) - max(a.y, b.y) }

    /// .NET's OrderBy: ties keep their order.
    private static func stableSorted(_ list: [Ch], _ before: (Ch, Ch) -> Bool) -> [Ch] {
        list.enumerated().sorted { a, b in
            if before(a.element, b.element) { return true }
            if before(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func join<S: Sequence>(_ chars: S) -> String? where S.Element == Ch {
        let s = String(decoding: chars.map(\.c), as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// The page's characters with a `RectGrid` over their boxes.
    private final class CharIndex {
        let all: [Ch]
        private let grid = RectGrid()

        init(_ chars: [Ch]) {
            all = chars
            for c in chars { grid.add(c.box) }
        }

        /// The characters whose boxes touch `region`, in text order.
        func near(_ region: RectD) -> [Ch] { grid.nearIndices(region).map { all[$0] } }
    }
}

/// Rectangles bucketed in a uniform grid, so "which boxes touch this region" costs the boxes nearby instead of all of them.
/// Boxes spanning more than a few hundred cells go into one list every query looks at.
final class RectGrid {
    private static let maxCells = 256
    private let cell: Double
    private var rects: [RectD] = []
    private var cells: [Int: [Int]] = [:]
    private var large: [Int] = []

    init(cell: Double = 48) { self.cell = cell }

    var count: Int { rects.count }

    func add(_ r: RectD) {
        let i = rects.count
        rects.append(r)
        let s = span(r)
        if (s.x1 - s.x0 + 1) * (s.y1 - s.y0 + 1) > Self.maxCells {
            large.append(i)
            return
        }
        for x in s.x0...s.x1 {
            for y in s.y0...s.y1 { cells[Self.key(x, y), default: []].append(i) }
        }
    }

    /// Indices (in the order added) of the rectangles touching `region`.
    func nearIndices(_ region: RectD) -> [Int] {
        let s = span(region)
        var hits = large
        if (s.x1 - s.x0 + 1) * (s.y1 - s.y0 + 1) > cells.count {
            for list in cells.values { hits += list }
        } else {
            for x in s.x0...s.x1 {
                for y in s.y0...s.y1 {
                    if let list = cells[Self.key(x, y)] { hits += list }
                }
            }
        }
        hits.sort()
        var out: [Int] = []
        var last = -1
        for i in hits where i != last {
            last = i
            if Self.touches(rects[i], region) { out.append(i) }
        }
        return out
    }

    func near(_ region: RectD) -> [RectD] { nearIndices(region).map { rects[$0] } }

    private static func key(_ x: Int, _ y: Int) -> Int { x << 32 ^ (y & 0xFFFF_FFFF) }

    private static func touches(_ a: RectD, _ b: RectD) -> Bool { a.x <= b.right && a.right >= b.x && a.y <= b.bottom && a.bottom >= b.y }

    private func span(_ r: RectD) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        func c(_ v: Double) -> Int { Int((min(max(v, -1e6), 1e6) / cell).rounded(.down)) }
        return (c(r.x), c(r.y), c(r.right), c(r.bottom))
    }
}
