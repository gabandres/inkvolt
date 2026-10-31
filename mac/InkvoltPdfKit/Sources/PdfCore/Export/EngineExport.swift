import Foundation

/// What lone accents draw, per font, text and size (a glyph of one font at one size draws the same everywhere).
final class DrawnAsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: String?] = [:]

    func get(_ key: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return known[key]
    }

    func set(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        known[key] = .some(value)
    }
}

extension PdfEngine {
    /// Most vector paths a page may draw for its thin lines to be read as table rules (maps and charts draw thousands).
    static let maxRulePaths = 4000

    /// Pictures larger than this many pixels are exported as JPEG (scans, photos), smaller ones as PNG.
    static let jpegAbovePixels = 1_500_000

    /// Largest picture rendered again to keep its transparency, and largest rendering of a vector figure (pixels).
    static let maxRenderedPicture = 4_000_000.0

    /// What Export to Word / Excel / text reads from a page: text lines with their fonts, sizes, colors and direction,
    /// the pictures (encoded, when `images`; transparent ones as PNG with their transparency) and the thin lines and box
    /// outlines the page draws. Charts and diagrams drawn with vectors (`DocLayout.figureRegions`) become one picture
    /// each, rendered as shown, and their labels and lines are left out of the text. Not cached.
    /// `boxesOnly`: pictures and figures say where they are, without their pixels (tagging needs no more).
    /// - Throws: `CancellationError` when `cancel` fired; `PdfEngineError` when MuPDF can't read the page.
    public func exportPage(_ page: Int, images: Bool, cancel: CancelToken? = nil, boxesOnly: Bool = false) throws -> ExportPage {
        let read = try exportRead(page, images: images, boxesOnly: boxesOnly, jpegAbovePixels: Self.jpegAbovePixels, cancel: cancel)
        let g = read.geometry
        var pictures: [ExportImage] = []
        for img in read.images {
            var img = img
            img.box = img.box.intersect(RectD(0, 0, g.width, g.height))
            if img.box.width < 2 || img.box.height < 2 { continue } // clipped away or a hairline
            pictures.append(img)
        }
        let tooManyPaths = read.paths.count > Self.maxRulePaths
        let paths = Array(read.paths.prefix(Self.maxRulePaths))

        var rules: [RectD] = tooManyPaths ? [] : DocLayout.rulesFromPaths(paths)
        // Accents joined to their letters and leaders found across the page (a capital's accent is a line of its own);
        // lines split where a table's vertical rule passes between two characters (cells MuPDF read as one line).
        var composed = ExportGlyphs.compose(read.lines.map(\.glyphs)) { read.lines[$0].turn == 0 && !read.lines[$0].sideways }
        // An accent standing alone may be another shape under an accent's name (a form's "=" named "dotaccent"): what it
        // draws decides.
        for i in composed.indices {
            for k in composed[i].indices where ExportGlyphs.isLoneAccent(composed[i], k) {
                let glyph = composed[i][k]
                let key = "\(glyph.look.font)\u{0}\(glyph.text)\u{0}\(bankers(glyph.look.size * 10) / 10)"
                let drawn: String?
                if let known = drawnAs.get(key) {
                    drawn = known
                } else {
                    let ppp = 8.0
                    guard let r = try renderRegion(page, glyph.rect, scale: ppp, cancel: cancel) else { continue }
                    var alpha = [UInt8](repeating: 0, count: r.width * r.height)
                    for p in alpha.indices { alpha[p] = r.rgba[p * 4 + 3] }
                    drawn = ExportGlyphs.drawnAs(alpha, r.width, r.height, Double(r.width) / max(0.01, glyph.rect.width), glyph.look.size)
                    drawnAs.set(key, drawn)
                }
                if let drawn, !(drawn == "\u{2212}" && glyph.text == "\u{AF}") { composed[i][k].text = drawn }
            }
        }
        let verticals = rules.filter { $0.width <= 3 && $0.height > 6 }
        var lines: [ExportLine] = []
        for i in composed.indices where !composed[i].isEmpty {
            lines += Self.linesOf(composed[i], read.lines[i].turn, read.lines[i].sideways, verticals)
        }

        let figures = DocLayout.figureRegions(paths, lines, g.width, g.height)
        if !figures.isEmpty {
            func inFigure(_ r: RectD) -> Bool { figures.contains { $0.inflate(1).contains(r.centerX, r.centerY) } }
            lines.removeAll { inFigure($0.box) }
            rules = rules.filter { !inFigure($0) }
            pictures.removeAll { inFigure($0.box) }
        }
        if images && boxesOnly {
            pictures += figures.map { ExportImage([], "png", 0, 0, $0) }
        } else if images {
            // Rendered again where the picture stands: what MuPDF draws applies its soft mask, so a transparent logo keeps
            // its transparency (the picture's own pixels have none). Not where text lies over it (it would be doubled).
            for i in pictures.indices.reversed() {
                let p = pictures[i]
                let covered = lines.contains { overlap($0.box, p.box) > 0.2 * $0.box.width * $0.box.height }
                let tooBig = Double(p.pixelWidth) * Double(p.pixelHeight) > Self.maxRenderedPicture
                if covered || (tooBig && !p.data.isEmpty) {
                    if p.data.isEmpty { pictures.remove(at: i) }
                    continue
                }
                let scale = clamp(max(Double(p.pixelWidth) / p.box.width, Double(p.pixelHeight) / p.box.height), 0.5, 8)
                guard let r = try renderRegion(page, p.box, scale: scale, cancel: cancel) else {
                    if p.data.isEmpty { pictures.remove(at: i) }
                    continue
                }
                if hasTransparency(r.rgba) || p.data.isEmpty {
                    pictures[i] = ExportImage(PngEncoder.encode(r.width, r.height, r.rgba, alpha: true), "png", r.width, r.height, p.box)
                }
            }
            for f in figures {
                if let r = try renderRegion(page, f, scale: 2, cancel: cancel) {
                    pictures.append(ExportImage(PngEncoder.encode(r.width, r.height, r.rgba, alpha: hasTransparency(r.rgba)), "png", r.width, r.height, f))
                }
            }
        }
        return ExportPage(g.width, g.height, lines, pictures, rules)

        func overlap(_ a: RectD, _ b: RectD) -> Double {
            max(0, min(a.right, b.right) - max(a.x, b.x)) * max(0, min(a.bottom, b.bottom) - max(a.y, b.y))
        }

        func hasTransparency(_ rgba: [UInt8]) -> Bool {
            var k = 3
            while k < rgba.count {
                if rgba[k] != 255 { return true }
                k += 4
            }
            return false
        }
    }

    /// A region drawn as straight RGBA at `scale` pixels per point or less (at most `maxRenderedPicture` pixels); nil
    /// when MuPDF can't draw it.
    private func renderRegion(_ page: Int, _ region: RectD, scale: Double, cancel: CancelToken?) throws -> (rgba: [UInt8], width: Int, height: Int)? {
        try cancel.check()
        let area = region.width * region.height
        if area <= 0 { return nil }
        var scale = scale
        if area * scale * scale > Self.maxRenderedPicture { scale = (Self.maxRenderedPicture / area).squareRoot() }
        return try renderRegionRgba(page, region, scale: scale, cancel: cancel)
    }

    /// A line's characters as spans of one look each, split where a left-to-right line has a gap wide enough to be a
    /// column gap: over 2.5 times the type size, or over its size between two numbers (table columns set close together,
    /// which MuPDF reads as one line), and where one of `verticals` (a table's rules) passes between two characters. A
    /// leader is a span of its own. Empty when it holds no characters.
    static func linesOf(_ chars: [ExportGlyph], _ turn: Int, _ sideways: Bool, _ verticals: [RectD]) -> [ExportLine] {
        var result: [ExportLine] = []
        // Positions along the reading direction, whichever way the line runs.
        let along = chars.map { c -> (text: String, from: Double, to: Double, size: Double) in
            switch turn {
            case 0: (c.text, c.rect.x, c.rect.right, c.look.size)
            case 1: (c.text, c.rect.y, c.rect.bottom, c.look.size)
            case 2: (c.text, -c.rect.right, -c.rect.x, c.look.size)
            default: (c.text, -c.rect.bottom, -c.rect.y, c.look.size)
            }
        }
        var parts = ExportLine.splitAtColumnGaps(along)
        if turn == 0 && !verticals.isEmpty { parts = parts.flatMap { splitAtRules(chars, $0, verticals) } }
        for part in parts {
            var spans: [ExportSpan] = []
            var text = ""
            var look: ExportSpan?
            var box = RectD.zero
            var leader = false
            for i in part.start..<part.end {
                let (s, rect, c) = (chars[i].text, chars[i].rect, chars[i].look)
                let isLeader = s.single.map(ExportGlyphs.isLeader) ?? false
                if look == nil || !look!.sameLook(c) || isLeader || leader {
                    if let look, !text.isEmpty { spans.append(look.with(text: text, box: box)) }
                    text = ""
                    look = c
                    box = rect
                } else {
                    box = box.union(rect)
                }
                leader = isLeader
                text += s
            }
            if let look, !text.isEmpty { spans.append(look.with(text: text, box: box)) }
            if !spans.isEmpty {
                var line = ExportLine.of(spans, sideways: sideways)
                line.turn = turn
                result.append(line)
            }
        }
        return result
    }

    /// A left-to-right part of a line cut where a vertical rule runs between two of its characters, at their height.
    private static func splitAtRules(_ chars: [ExportGlyph], _ part: (start: Int, end: Int), _ verticals: [RectD]) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        var start = part.start
        var lastInk = -1
        for i in part.start..<part.end {
            if chars[i].text.isBlank { continue }
            if lastInk >= 0 {
                let a = chars[lastInk].rect, b = chars[i].rect
                let cy = (a.centerY + b.centerY) / 2
                if verticals.contains(where: { $0.centerX >= a.centerX && $0.centerX <= b.centerX && $0.y <= cy && $0.bottom >= cy }) {
                    out.append((start, lastInk + 1))
                    start = i
                }
            }
            lastInk = i
        }
        out.append((start, part.end))
        return out
    }
}
