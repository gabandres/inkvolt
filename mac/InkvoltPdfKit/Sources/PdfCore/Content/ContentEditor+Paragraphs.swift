import Foundation

/// How a paragraph's lines sit in its box. Justified: every line but the last reaches both edges.
public enum ParagraphAlign: Sendable, CaseIterable { case left, center, right, justified }

/// A paragraph of a page's text, for Edit Text & Images: lines of one font, size and color, one under the other at a
/// steady line step, their edges lined up (see `ContentEditor.groupParagraphs`). Page space (points, top-left origin of
/// the page as shown). The Windows app's `TextParagraph`.
public struct TextParagraph: Sendable {
    public let pageIndex: Int
    /// Its text runs (line by line, left to right).
    public let runs: [TextRun]
    /// Each line's box, top to bottom.
    public let lines: [RectD]
    /// Its text, the lines joined by a space (a line ending in a hyphen joins the next without one).
    public let text: String
    /// The lines' boxes together: the box new text wraps in (its width) and grows from (downward).
    public let box: RectD
    public let align: ParagraphAlign
    /// From one baseline to the next (points); for a single line, 1.2 times its size.
    public let lineStep: Double
    /// How much further right the first line starts than the others (left and justified text).
    public let firstIndent: Double
    /// Why it can't be rewritten as one paragraph ("it is …"); nil when it can.
    public let blocked: String?
    /// The nearest text or picture below the paragraph, across its width: what a longer text would run into.
    public internal(set) var below: RectD?
    /// Runs of spaces only drawn on its lines (some generators draw each space on its own): they go with its text.
    var spaces: [TextRun] = []
    /// The stretches of `text` an earlier edit gave a look of their own (font, size, color, bold, italic).
    public internal(set) var spans: [TextSpan] = []
    /// The line edges new text is laid out between (the box but the first line's indent); how far its own text reaches
    /// above and below its baseline (points).
    var left = 0.0, right = 0.0, center = 0.0, ascent = 0.0, descent = 0.0

    init(pageIndex: Int, runs: [TextRun], lines: [RectD], text: String, box: RectD, align: ParagraphAlign, lineStep: Double,
         firstIndent: Double, blocked: String?) {
        self.pageIndex = pageIndex
        self.runs = runs
        self.lines = lines
        self.text = text
        self.box = box
        self.align = align
        self.lineStep = lineStep
        self.firstIndent = firstIndent
        self.blocked = blocked
    }

    /// Its type size on the page (points).
    public var fontSize: Double { runs.first?.fontSize ?? 0 }

    /// Its first run in its own font and look (not a stand-in or a look an earlier edit added): its font, style and color.
    public var lead: TextRun { runs.first { !$0.standIn && !$0.styled } ?? runs.first { !$0.standIn } ?? runs[0] }

    /// What `text` would look like here, its stretches with the looks `spans` give them: its box, line count, missing
    /// characters and what it would run into.
    public func check(_ text: String, _ spans: [TextSpan]? = nil) -> ParagraphCheck {
        if blocked != nil { return ParagraphCheck(box: box, lineCount: lines.count, missing: [], overlaps: nil) }
        return ContentEditor.layOut(self, runs, ContentEditor.paragraphText(text), spans).check
    }
}

/// New text for a paragraph: the box it would take, its line count, characters no font here can draw, and what it
/// would run into below (nil: nothing).
public struct ParagraphCheck: Sendable, Equatable {
    public var box: RectD
    public var lineCount: Int
    public var missing: [String]
    public var overlaps: RectD?
    /// Characters the paragraph's own font lacks, drawn from installed fonts (`standIns`).
    public var borrowed: [String] = []
    /// The installed fonts they come from ("Arial Bold"), closest first.
    public var standIns: [String] = []
    /// The installed fonts the looks asked for are drawn in ("Georgia Bold"); a family not installed shows as the font
    /// used instead.
    public var faces: [String] = []
    /// Why the looks asked for can't be written (a color over a special ink); nil when they can.
    public var lookProblem: String?
}

/// Sorting that keeps equal elements in their order (.NET's OrderBy).
private func stableSorted<T>(_ items: [T], _ before: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { a, b in
        if before(a.element, b.element) { return true }
        if before(b.element, a.element) { return false }
        return a.offset < b.offset
    }.map(\.element)
}

private func isBlank(_ s: String) -> Bool { s.unicodeScalars.allSatisfy(\.properties.isWhitespace) }

private func trimStart(_ s: String) -> String { String(s.unicodeScalars.drop { $0.properties.isWhitespace }) }

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

extension ContentEditor {
    static func withParagraphs(_ content: PageContent) -> PageContent {
        var c = content
        c.paragraphs = groupParagraphs(content)
        return c
    }

    // ---- Grouping ----

    /// A line of text: runs on one baseline, left to right, with no column gap between them.
    private final class PLine {
        var runs: [TextRun]
        var box: RectD
        let baseline: Double
        var text: String
        /// Where each run's text starts in `text` (UTF-16).
        var starts: [Int] = [0]

        init(_ first: TextRun) {
            runs = [first]
            box = first.box
            baseline = first.origin.y
            text = first.text
        }

        /// Its first run in its own look (not a stand-in or a look an edit gave it), else its first.
        var lead: TextRun { runs.first { !$0.standIn && !$0.styled } ?? runs[0] }
        var size: Double { lead.fontSize }
        /// Its biggest text against its own: 1 unless an edit made part of it bigger.
        var scale: Double { max(1, (runs.map(\.fontSize).max() ?? 0) / max(0.1, size)) }

        func add(_ r: TextRun) {
            let gap = r.box.x - box.right
            // A word space can also be a wide adjustment at the start of the run (its box starts before it): a font with no
            // space glyph, after a stretch an edit drew in another font or look. Windows misses this one (its text loses
            // the space); a Mac fix to port back.
            let leading = r.info?.items.prefix(while: \.isNumber).reduce(0.0) { $0 - $1.number } ?? 0
            if (gap > 0.15 * size || leading > 180) && !text.hasSuffix(" ") && !r.text.hasPrefix(" ") { text += " " }
            starts.append(text.utf16.count)
            text += r.text
            runs.append(r)
            box = box.union(r.box)
        }
    }

    /// Lines stacked one under the other, and which alignments they still allow.
    private final class PStack {
        var lines: [PLine]
        var canLeft = true, canCenter = true, canRight = true
        var step = 0.0
        init(_ first: PLine) { lines = [first] }
    }

    /// The page's upright text runs as paragraphs, joined the way Export to Word joins lines (`DocLayout`): runs on one
    /// baseline with less than 2.5 ems between them make a line; a line carries on the paragraph above it when it is in
    /// the same font, size (within 5%) and color, below it with at most 0.65 ems between them and the same line step as
    /// the lines before (within 10%), overlapping it across, with its left edges (a first-line indent allowed), centers
    /// or right edges lined up; and when the line above didn't end short (its next first word would have fit on it).
    /// Turned text and runs of spaces only are left out.
    static func groupParagraphs(_ content: PageContent) -> [TextParagraph] {
        let runs = content.runs.filter { abs($0.angle) < 0.5 && !isBlank($0.text) && $0.fontSize > 0.5 && $0.box.width > 0 }
        if runs.isEmpty { return [] }
        var result: [TextParagraph] = []
        for stack in stacks(linesOf(runs)) {
            for part in splitShort(stack) { result.append(paragraph(content, part)) }
        }
        return result
    }

    private static func linesOf(_ runs: [TextRun]) -> [PLine] {
        var lines: [PLine] = []
        let sorted = stableSorted(runs) { $0.origin.y < $1.origin.y }
        var i = 0
        while i < sorted.count {
            // A band of runs on one baseline, then left to right.
            let y0 = sorted[i].origin.y
            var j = i + 1
            while j < sorted.count && sorted[j].origin.y - y0 <= 0.25 * max(sorted[i].fontSize, sorted[j].fontSize) { j += 1 }
            var cur: PLine?
            for r in stableSorted(Array(sorted[i..<j]), { $0.box.x < $1.box.x }) {
                let size = max(r.fontSize, cur?.size ?? 0)
                if let c = cur, r.box.x - c.box.right <= 2.5 * size && r.box.x >= c.box.right - 0.5 * size {
                    c.add(r)
                } else {
                    let line = PLine(r)
                    cur = line
                    lines.append(line)
                }
            }
            i = j
        }
        return lines
    }

    private static func stacks(_ lines: [PLine]) -> [PStack] {
        var stacks: [PStack] = []
        let ordered = stableSorted(lines) { $0.baseline < $1.baseline || ($0.baseline == $1.baseline && $0.box.x < $1.box.x) }
        for line in ordered {
            var best: PStack?
            var bestGap = Double.greatestFiniteMagnitude
            for s in stacks {
                guard let gap = joins(s, line), gap < bestGap else { continue }
                best = s
                bestGap = gap
            }
            guard let best else {
                stacks.append(PStack(line))
                continue
            }
            let (l, c, r) = fits(best, line)
            best.canLeft = l
            best.canCenter = c
            best.canRight = r
            if best.lines.count == 1 { best.step = plainStep(best.lines[0], line, line.baseline - best.lines[0].baseline) }
            best.lines.append(line)
        }
        return stacks
    }

    /// Same font, size (within 5%) and color; a stand-in run (characters an edit drew from another font) only needs the
    /// size and color, and text an edit gave a look of its own goes with anything.
    private static func sameLook(_ a: TextRun, _ b: TextRun) -> Bool {
        if a.styled || b.styled { return true }
        let sameFont = a.standIn || b.standIn || (a.fontName == b.fontName && a.font === b.font)
        return sameFont && abs(a.fontSize - b.fontSize) <= max(0.3, 0.05 * a.fontSize) && a.color == b.color
    }

    /// How much of a line step is the line above's depth (the rest is the next line's height).
    private static let rise = 0.25

    /// The step from one baseline to the next as the paragraph's own (see `layOut`: bigger text widens it).
    private static func plainStep(_ above: PLine, _ below: PLine, _ step: Double) -> Double {
        step / (rise * above.scale + (1 - rise) * below.scale)
    }

    /// The gap between the stack's last line and `line` when the line carries the stack on; else nil.
    private static func joins(_ s: PStack, _ line: PLine) -> Double? {
        let last = s.lines[s.lines.count - 1]
        let size = last.size
        if !sameLook(last.lead, line.lead) { return nil }
        let step = plainStep(last, line, line.baseline - last.baseline)
        if step < 0.6 * size { return nil }
        let gap = line.box.y - last.box.bottom
        if gap > 0.65 * size { return nil }
        if s.lines.count >= 2 && abs(step - s.step) > max(0.5, 0.1 * size) { return nil }
        if line.box.x >= last.box.right || line.box.right <= last.box.x { return nil }
        let (l, c, r) = fits(s, line)
        return l || c || r ? max(0, gap) : nil
    }

    private static func tolerance(_ size: Double) -> Double { max(1.5, 0.12 * size) }

    /// The alignments the stack still allows with `line` under it.
    private static func fits(_ s: PStack, _ line: PLine) -> (Bool, Bool, Bool) {
        let first = s.lines[0]
        let tol = tolerance(first.size)
        let left: Bool
        if s.lines.count == 1 {
            let indent = first.box.x - line.box.x
            left = abs(indent) <= tol || (indent >= 0.5 * first.size && indent <= 8 * first.size)
        } else {
            left = abs(line.box.x - s.lines[1].box.x) <= tol
        }
        return (s.canLeft && left, s.canCenter && abs(line.box.centerX - first.box.centerX) <= tol,
                s.canRight && abs(line.box.right - first.box.right) <= tol)
    }

    /// Splits a stack after each line that ended short: the next line's first word would have fit on it.
    private static func splitShort(_ s: PStack) -> [[PLine]] {
        var parts: [[PLine]] = []
        var cur = [s.lines[0]]
        let width = s.lines.map(\.box.width).max() ?? 0
        let right = s.lines.map(\.box.right).max() ?? 0
        let indented = s.canLeft && s.lines.count > 1 && s.lines[0].box.x - s.lines[1].box.x > tolerance(s.lines[0].size)
        for i in 1..<max(1, s.lines.count) where i < s.lines.count {
            let prev = s.lines[i - 1]
            let line = s.lines[i]
            let room = i == 1 && indented ? right - prev.box.x : width
            let word = trimStart(line.text).split(separator: " ", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let need = prev.box.width + widthOf(line.lead, " " + word, line)
            if need < room - 0.5 * prev.size {
                parts.append(cur)
                cur = []
            }
            cur.append(line)
        }
        parts.append(cur)
        return parts
    }

    /// How wide text is in a run's font and spacing (points); estimated from the line's characters when the font can't tell.
    private static func widthOf(_ run: TextRun, _ text: String, _ line: PLine) -> Double {
        if let font = run.font {
            let enc = font.encode(text)
            if enc.missing.isEmpty { return run.width(parts(run, enc.codes)) * run.scale }
        }
        return Double(text.utf16.count) * line.box.width / max(1, Double(line.text.utf16.count))
    }

    static func parts(_ run: TextRun, _ codes: [Int]) -> [Part] {
        codes.map { $0 == TextFont.gap ? Part(code: nil, number: -run.gapEms * 1000) : Part(code: $0, number: 0) }
    }

    private static func isRtl(_ text: String) -> Bool {
        TrueTypeFont.codePoints(text).contains { let c = Bidi.classify($0); return c == .R || c == .AL }
    }

    private static func paragraph(_ content: PageContent, _ lines: [PLine]) -> TextParagraph {
        let first = lines[0]
        let size = first.size
        let tol = tolerance(size)
        let n = lines.count
        let rest = n > 1 ? Array(lines.dropFirst()) : lines
        var left = rest.map(\.box.x).min()!
        let right = lines.map(\.box.right).max()!
        let lefts = rest.allSatisfy { abs($0.box.x - left) <= tol }
        var indent = n > 1 && lefts ? first.box.x - left : 0
        if indent < 0.5 * size { indent = 0 }
        let flushLeft = lefts && (indent > 0 || abs(first.box.x - left) <= tol)
        let center = lines.map(\.box.centerX).reduce(0, +) / Double(n)
        let centers = lines.allSatisfy { abs($0.box.centerX - center) <= tol }
        let rights = lines.allSatisfy { abs($0.box.right - right) <= tol }
        let allLeft = flushLeft && indent == 0
        var align = ParagraphAlign.left
        if n >= 3 && flushLeft && lines.prefix(n - 1).allSatisfy({ abs($0.box.right - right) <= tol }) {
            align = .justified
        } else if n >= 2 && !allLeft && centers {
            align = .center
        } else if n >= 2 && !allLeft && rights {
            align = .right
        }
        if align == .center || align == .right {
            indent = 0
            left = lines.map(\.box.x).min()!
        }

        let runs = lines.flatMap(\.runs)
        let mine = Set(runs.map(\.id))
        var blocked = runs.lazy.compactMap(\.blocked).first
        // Its own look: a run in its own font as it was; else (an edit gave all of it another look) its first run's.
        let own = runs.first { !$0.standIn && !$0.styled } ?? runs.first { !$0.standIn } ?? runs[0]
        if blocked == nil && runs.contains(where: { !sameLook(own, $0) || (!$0.standIn && !$0.styled && ($0.bold != own.bold || $0.italic != own.italic)) }) {
            blocked = "it mixes fonts, sizes or colors, and this version rewrites a paragraph in one font only"
        }
        if blocked == nil && runs.contains(where: { $0.info == nil }) { blocked = "part of it can't be read for editing" }
        // Rewrapping lays words out left to right, so right-to-left text would come out in the wrong order.
        if blocked == nil && runs.contains(where: { isRtl($0.text) }) {
            blocked = "it is written right to left, and this version rewraps left-to-right text only"
        }

        var text = ""
        var at: [(run: TextRun, start: Int, length: Int)] = [] // where each run's text is in the paragraph's
        for l in lines {
            let t = trimmed(l.text)
            let tu = Array(t.utf16)
            if !text.isEmpty {
                let u = Array(text.utf16.suffix(2))
                let letter = u.count == 2 && (Unicode.Scalar(u[0])?.properties.isAlphabetic ?? false)
                let lower = tu.first.flatMap { Unicode.Scalar($0)?.properties.isLowercase } ?? false
                let hyphen = u.count == 2 && u[1] == 45 && letter && lower
                if !hyphen { text += " " }
            }
            let lead = l.text.utf16.count - trimStart(l.text).utf16.count
            let base = text.utf16.count
            for (i, r) in l.runs.enumerated() {
                let from = min(max(l.starts[i] - lead, 0), tu.count)
                let to = min(max(l.starts[i] + r.text.utf16.count - lead, 0), tu.count)
                at.append((r, base + from, to - from))
            }
            text += t
        }
        let box = lines.map(\.box).dropFirst().reduce(lines[0].box) { $0.union($1) }
        // Other text on its lines (a raised footnote mark, a symbol in another font): rewrapping would leave it behind.
        // Spaces drawn on their own on its lines go with it.
        var spaces: [TextRun] = []
        for r in content.runs {
            if mine.contains(r.id) || r.box.right <= box.x || r.box.x >= box.right || r.box.bottom <= box.y || r.box.y >= box.bottom { continue }
            let cy = r.box.centerY
            // On a line: its middle inside the line's height, across from the line or right after its end (a mark after the last word).
            if !lines.contains(where: { cy > $0.box.y && cy < $0.box.bottom && r.box.right > $0.box.x && r.box.x < $0.box.right + 0.3 * $0.size }) {
                continue
            }
            if !isBlank(r.text) {
                if blocked == nil {
                    blocked = "it has other text inside it (a raised mark, a symbol or words in another font), and this version rewrites "
                        + "a paragraph in one font only"
                }
            } else if r.info != nil && abs(r.angle) < 0.5 {
                spaces.append(r)
            }
        }
        // The line step as the paragraph's own: bigger text an edit gave part of it widened the steps around it.
        var step = 1.2 * size
        if n > 1 {
            let steps = (1..<n).map { plainStep(lines[$0 - 1], lines[$0], lines[$0].baseline - lines[$0 - 1].baseline) }
            step = steps.reduce(0, +) / Double(steps.count)
        }
        let plain = own

        // What follows below: the nearest other text or picture across the paragraph's width.
        var below: RectD?
        let others = content.runs.filter { !mine.contains($0.id) && !isBlank($0.text) }.map(\.box) + content.images.map(\.box)
        for b in others {
            if b.y < box.bottom - 1 || b.right <= box.x + 1 || b.x >= box.right - 1 { continue }
            if below == nil || b.y < below!.y { below = b }
        }

        var p = TextParagraph(pageIndex: runs[0].pageIndex, runs: runs, lines: lines.map(\.box), text: text, box: box, align: align,
                              lineStep: step, firstIndent: indent, blocked: blocked)
        p.below = below
        p.spaces = spaces
        p.spans = spansOf(plain, at)
        p.left = left
        p.right = right
        p.center = center
        p.ascent = plain.origin.y - plain.box.y
        p.descent = plain.box.bottom - plain.origin.y
        return p
    }

    // ---- Laying out new text ----

    /// A paragraph's new text as typed: Windows line ends and tabs made plain, trailing space dropped.
    static func paragraphText(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\t", with: " ")
        var scalars = Array(t.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        var out = ""
        out.unicodeScalars.append(contentsOf: scalars)
        return out
    }

    struct ParagraphLayout {
        var lines: [(origin: PointD, parts: [Part])]
        var check: ParagraphCheck
        var codes: [Int]
        var encoded: String
    }

    /// New text laid out in a paragraph's box, in the font, size and spacing of its first run in content order (where it
    /// is written): words wrapped at the box's width (a single line doesn't wrap), a new line at each line break, the
    /// paragraph's alignment (a justified paragraph's last line, and each line before a break, start left), its line
    /// step. Stretches `spans` give a look of their own are drawn in it: an installed font for another family, bold or
    /// italic, another size (a line with bigger text moves down as far as it needs), another color.
    static func layOut(_ p: TextParagraph, _ runs: [TextRun], _ text: String, _ spans: [TextSpan]? = nil) -> ParagraphLayout {
        let anchor = anchorOf(runs)
        let font = anchor.font!
        var m = anchor
        m.wordSpacing = 0 // the lines are written with Tw 0 (justification goes into adjustments)
        let u = Array(text.utf16)
        let enc = MixedText(p, font, m, text, looksOf(text, spans ?? carry(p.text, text, p.spans)))
        if !enc.missing.isEmpty {
            return ParagraphLayout(lines: [], check: ParagraphCheck(box: p.box, lineCount: p.lines.count, missing: enc.missing, overlaps: nil),
                                   codes: [], encoded: "")
        }

        func w(_ parts: [Part]) -> Double { parts.isEmpty ? 0 : m.width(parts) * m.scale }
        let wrap = p.lines.count > 1
        var lines: [(parts: [Part], spaces: [Int], last: Bool)] = []
        var cur: [Part] = []
        var spaceEnds: [Int] = [] // the index of each word space's last part in cur
        var space: [Part]?
        var pos = 0
        while pos <= u.count {
            if pos == u.count || u[pos] == 10 {
                lines.append((cur, spaceEnds, true))
                cur = []
                spaceEnds = []
                space = nil
                pos += 1
                continue
            }
            if u[pos] == 32 {
                if !cur.isEmpty && space == nil { space = enc.encode(pos, pos + 1) }
                pos += 1
                continue
            }
            var end = pos
            while end < u.count && u[end] != 32 && u[end] != 10 { end += 1 }
            let parts = enc.encode(pos, end)
            pos = end
            guard !cur.isEmpty, let sp = space else {
                cur += parts
                continue
            }
            let avail = p.right - p.left - (lines.isEmpty ? p.firstIndent : 0)
            let joined = cur + sp + parts
            if !wrap || w(joined) <= avail + 0.01 {
                spaceEnds.append(cur.count + sp.count - 1)
                cur = joined
            } else {
                lines.append((cur, spaceEnds, false))
                cur = parts
                spaceEnds = []
            }
            space = nil
        }
        if lines.count == 1 && lines[0].parts.isEmpty { lines.removeAll() } // no text: the paragraph goes

        var placed: [(origin: PointD, parts: [Part])] = []
        var maxRight = p.box.right
        var minLeft = p.box.x
        var baseline = 0.0, scale = 1.0
        for (i, line) in lines.enumerated() {
            var parts = line.parts
            // A line with bigger text sits lower: the step to it grows with its biggest text, the step after it with its depth.
            let s = max(1, parts.filter { $0.code != nil || $0.standIn != nil }.map { $0.look?.scale ?? 1 }.max() ?? 1)
            baseline = i == 0 ? p.box.y + p.ascent * s : baseline + p.lineStep * (rise * scale + (1 - rise) * s)
            scale = s
            var width = w(parts)
            let x0 = p.left + (i == 0 ? p.firstIndent : 0)
            let x: Double
            switch p.align {
            case .right: x = p.right - width
            case .center: x = p.center - width / 2
            default: x = x0
            }
            if p.align == .justified && !line.last && !line.spaces.isEmpty && p.right - x0 - width > 0.01 {
                // The room left over goes into the word spaces, as adjustments after each space (at the space's size).
                let extra = -(p.right - x0 - width) / Double(line.spaces.count) / m.scale * 1000 / (m.size * m.hScale)
                let at = Set(line.spaces)
                var spread: [Part] = []
                spread.reserveCapacity(parts.count + at.count)
                for (k, part) in parts.enumerated() {
                    spread.append(part)
                    if at.contains(k) { spread.append(Part(code: nil, number: extra / (part.look?.scale ?? 1), standIn: nil, look: part.look)) }
                }
                parts = spread
                width = w(parts)
            }
            placed.append((PointD(x, baseline), merged(parts)))
            maxRight = max(maxRight, x + width)
            minLeft = min(minLeft, x)
        }
        let bottom = placed.isEmpty ? p.box.y + p.ascent + p.descent : baseline + p.descent * scale
        let box = RectD.fromEdges(minLeft, p.box.y, maxRight, max(bottom, p.box.y + 1))
        var overlaps: RectD?
        if let b = p.below, box.bottom > b.y + 0.5 && b.right > box.x && b.x < box.right { overlaps = b }
        let problem = enc.colored && anchor.info?.fillOp == nil
            ? "this paragraph's color is a special ink (a pattern or spot color), so part of it can't be given another color"
            : nil
        var check = ParagraphCheck(box: box, lineCount: placed.count, missing: [], overlaps: overlaps)
        check.borrowed = enc.borrowed
        check.standIns = enc.names
        check.faces = enc.faces
        check.lookProblem = problem
        return ParagraphLayout(lines: placed, check: check, codes: enc.codes, encoded: enc.text)
    }

    /// A line's parts with stretches in other fonts next to each other (words and the spaces between them, the
    /// adjustments that justify them) joined into one, so each is drawn by one operator.
    private static func merged(_ parts: [Part]) -> [Part] {
        var result: [Part] = []
        result.reserveCapacity(parts.count)
        var i = 0
        while i < parts.count {
            guard let a = parts[i].standIn else {
                result.append(parts[i])
                i += 1
                continue
            }
            let look = parts[i].look
            var glyphs = a.glyphs
            var text = a.text
            var width = a.width
            var j = i + 1
            while true {
                // Adjustments of the same look in between become room, then the next stretch of the same look follows.
                var k = j
                var room = 0.0
                while k < parts.count && parts[k].code == nil && parts[k].standIn == nil && parts[k].look === look {
                    room -= parts[k].number / 1000
                    k += 1
                }
                guard k < parts.count, let b = parts[k].standIn, parts[k].look === look, !b.rtl, !a.rtl else { break }
                let off = width + room
                glyphs += b.glyphs.map { g in
                    var moved = g
                    moved.x += off
                    return moved
                }
                text += b.text
                width = off + b.width
                j = k + 1
            }
            result.append(j == i + 1 ? parts[i] : Part(code: nil, number: 0, standIn: ShapedLine(text: text, glyphs: glyphs, width: width, rtl: false), look: look))
            i = j
        }
        return result
    }

    /// Where a paragraph's new text is written: its first run in content order in its own font and look.
    private static func anchorOf(_ runs: [TextRun]) -> TextRun {
        runs.filter { !$0.standIn && !$0.styled }.min { $0.id < $1.id }
            ?? runs.filter { !$0.standIn }.min { $0.id < $1.id } ?? runs.min { $0.id < $1.id }!
    }

    /// A paragraph's new text in its own font's codes; the characters that font lacks drawn from the closest installed
    /// font (`StandInFonts`), each stretch shaped as one `Part.standIn`; stretches with a look of their own carry it
    /// (`Part.look`), drawn in an installed font when the look asks for another family, bold or italic.
    private final class MixedText {
        private let p: TextParagraph
        private let font: TextFont
        private let run: TextRun
        private let u: [UInt16]
        private let looks: [TextLook?]
        private var lacking = Set<String>()
        private var standIns: [UInt32: StandInFont] = [:]
        private var resolved: [TextLook: PartLook?] = [:]

        /// The own font's codes written, and the text they stand for (for `TextFont.prepare`).
        var codes: [Int] = []
        var text = ""
        var missing: [String] = []
        var borrowed: [String] = []
        var names: [String] = []
        var faces: [String] = []
        /// A look asks for another color.
        var colored = false

        init(_ p: TextParagraph, _ font: TextFont, _ run: TextRun, _ text: String, _ looks: [TextLook?]) {
            self.p = p
            self.font = font
            self.run = run
            u = Array(text.utf16)
            self.looks = looks
            var lacking: [String] = []
            for (el, at) in elements(0, u.count) {
                if isBlank(el) { continue }
                if let look = resolve(at), let face = look.face {
                    // In a font a look asked for: what it lacks comes from Core Text's fallbacks, else nothing.
                    let drawable = TrueTypeFont.codePoints(el).allSatisfy { face.font.has($0) || StandInFonts.fallback($0, face.font) != nil }
                    if !drawable && !missing.contains(el) { missing.append(el) }
                } else if !font.encode(el).missing.isEmpty && !lacking.contains(el) {
                    lacking.append(el)
                }
            }
            var cps: [UInt32] = []
            for cp in lacking.flatMap(TrueTypeFont.codePoints) where !cps.contains(cp) { cps.append(cp) }
            standIns = StandInFonts.forCodePoints(font, cps)
            for el in lacking {
                if TrueTypeFont.codePoints(el).allSatisfy({ standIns[$0] != nil }) {
                    self.lacking.insert(el)
                    borrowed.append(el)
                    for cp in TrueTypeFont.codePoints(el) where !names.contains(standIns[cp]!.name) { names.append(standIns[cp]!.name) }
                } else if !missing.contains(el) {
                    missing.append(el)
                }
            }
        }

        /// The text elements (a character with its marks, a surrogate pair) of [start, end), with where each starts.
        private func elements(_ start: Int, _ end: Int) -> [(String, Int)] {
            let sub = String(decoding: u[start..<end], as: UTF16.self)
            var out: [(String, Int)] = []
            var at = start
            for ch in sub {
                let s = String(ch)
                out.append((s, at))
                at += s.utf16.count
            }
            return out
        }

        /// The look at a place of the text, resolved; nil where it is the paragraph's own.
        private func resolve(_ at: Int) -> PartLook? {
            guard at < looks.count, let look = looks[at], !look.isPlain else { return nil }
            if let known = resolved[look] { return known }
            let lead = p.lead
            var scale = 1.0
            if let size = look.size, size > 0, abs(size - p.fontSize) > 0.01 { scale = size / p.fontSize }
            let color: Int? = look.color.flatMap { $0 != lead.color ? $0 : nil }
            let bold = look.bold ?? lead.bold
            let italic = look.italic ?? lead.italic
            var face: StandInFont?
            let family = look.font.flatMap { $0.caseInsensitiveCompare(FontNames.family(lead.fontName)) == .orderedSame ? nil : $0 }
            if family != nil || bold != lead.bold || italic != lead.italic {
                face = StandInFonts.styled(font, family, bold, italic)
                if let face, !faces.contains(face.name) { faces.append(face.name) }
            }
            colored = colored || color != nil
            let made: PartLook? = scale == 1 && color == nil && face == nil ? nil : PartLook(scale, color, face, look)
            resolved[look] = .some(made)
            return made
        }

        private func own(_ chunk: String, _ look: PartLook?) -> [Part] {
            let c = font.encode(chunk).codes
            codes += c
            text += chunk
            var parts = ContentEditor.parts(run, c)
            if let look { for i in parts.indices { parts[i].look = look } }
            return parts
        }

        /// The parts of [start, end): stretches in its own font, and stretches of each other font shaped, each with its look.
        func encode(_ start: Int, _ end: Int) -> [Part] {
            var parts: [Part] = []
            var chunk = ""
            var curLook: PartLook?
            var curFace: StandInFont? // nil: the own font
            func flush() {
                if chunk.isEmpty { return }
                if let face = curFace {
                    parts.append(Part(code: nil, number: 0, standIn: TextShaper.shape(chunk, face.font), look: curLook))
                } else {
                    parts += own(chunk, curLook)
                }
                chunk = ""
            }
            for (el, at) in elements(start, end) {
                let look = resolve(at)
                let face = look?.face ?? (lacking.contains(el) ? standIns[TrueTypeFont.codePoints(el)[0]] : nil)
                if look !== curLook || face != curFace { flush() }
                curLook = look
                curFace = face
                chunk += el
            }
            flush()
            return parts
        }
    }

    // ---- Writing ----

    /// Replaces a paragraph's text: its show operators are taken out (each leaves the text position where it found it,
    /// so what follows stays in place) and the new text is written where the first of them was, in the paragraph's own
    /// font, laid out by `layOut`. A box that would grow into what follows below is refused unless `allowOverlap` (the
    /// caller has warned). Bytes in → bytes out, as `replaceText`.
    /// - Throws: `ContentEditError` when no font can draw the text (the message names the missing characters), the new
    ///   text would run into what follows (`overlaps`), the paragraph can't be edited, or the page changed.
    public static func replaceParagraph(_ data: [UInt8], _ password: String?, _ paragraph: TextParagraph, _ newText: String,
                                        allowOverlap: Bool = false, spans: [TextSpan]? = nil) throws -> [UInt8] {
        if let why = paragraph.blocked { throw ContentEditError("This paragraph can't be edited: \(why).") }
        let text = paragraphText(newText)
        let spans = spans ?? carry(paragraph.text, text, paragraph.spans)
        if same(text, paragraph.text) && sameSpans(text, spans, paragraph.spans) { return data }
        let doc = try PdfEdit.open(data, password, failure: "This PDF can't be edited")
        let page = try pageOf(doc, paragraph.pageIndex)
        let content = streams(page)
        let ops = ContentLexer.parse(content.bytes)
        let walked = try walk(page, paragraph.pageIndex, ops, nil)
        var now: [TextRun] = []
        for run in paragraph.runs {
            let found = walked.textRuns.first { $0.id == run.id && same($0.text, run.text) }
                ?? walked.textRuns.filter { same($0.text, run.text) && near($0.box, run.box) }.min { distance($0.box, run.box) < distance($1.box, run.box) }
            if let why = found?.blocked, found?.info == nil { throw ContentEditError("This text can't be edited: \(why).") }
            guard let found, found.info != nil, !now.contains(where: { $0.id == found.id }) else {
                throw ContentEditError("The page changed since this paragraph was picked. Pick it again.")
            }
            now.append(found)
        }
        // Spaces drawn on their own on its lines go too (when they are still there).
        let spaces = paragraph.spaces.compactMap { s in walked.textRuns.first { $0.id == s.id && same($0.text, s.text) && $0.info != nil } }
            .filter { r in !now.contains { $0.id == r.id } }
        let anchor = anchorOf(now)
        guard let font = anchor.font, let fontDict = walked.fontDicts[ObjectIdentifier(font)] else {
            throw ContentEditError("The page changed since this paragraph was picked. Pick it again.")
        }
        let layout = layOut(paragraph, now, text, spans)
        let missing = layout.check.missing
        if !missing.isEmpty {
            func show(_ c: String) -> String {
                let cp = c.unicodeScalars.first!
                let cat = cp.properties.generalCategory
                return cat == .control || cat == .privateUse || cat == .surrogate ? String(format: "U+%04X", cp.value) : "“\(c)”"
            }
            let list = missing.prefix(12).map(show).joined(separator: ", ")
            throw ContentEditError("Neither this paragraph's font nor any font on this Mac has \(list), so it can't be written. Leave "
                                   + "\(missing.count == 1 ? "it" : "them") out, or add a text box instead.", missing: missing)
        }
        if let lp = layout.check.lookProblem { throw ContentEditError("This can't be written: \(lp).") }
        if let o = layout.check.overlaps, !allowOverlap {
            throw ContentEditError("The new text takes \(layout.check.lineCount) lines and would run into what follows below it. Shorten it, "
                                   + "or confirm to write it anyway.", overlaps: o)
        }
        font.prepare(doc, fontDict, layout.codes, layout.encoded)

        // Characters the font lacks: drawn in stand-in fonts (Type 3, from Core Text's outlines) under names no page font has.
        let fontRes = PageBoxes.inherited(page, "Resources")?.dict("Font")
        var k = 1
        while fontRes?.keys.contains(where: { $0.hasPrefix("\(standInKey)\(k)_") }) == true { k += 1 }
        let writer = Type3FontWriter(namePrefix: "/\(standInKey)\(k)_", describe: true)

        var edits: Edits = []
        for run in now {
            let op = ops[run.id]
            let replacement = run.id == anchor.id ? try writeParagraph(page, op, run, font, layout, writer) : removed(op, run)
            edits.append((op.start, op.end, latin1Bytes(replacement)))
        }
        if !writer.isEmpty { addFonts(doc, page, writer.buildFonts(doc)) }
        for run in spaces { edits.append((ops[run.id].start, ops[run.id].end, latin1Bytes(removed(ops[run.id], run)))) }
        _ = try writeContent(doc, page, content, ops, edits)
        SignedEdits.noteRemoval() // the old text stays in a signed file's earlier revision
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// Whether two sets of spans give every character of `text` the same look.
    private static func sameSpans(_ text: String, _ a: [TextSpan], _ b: [TextSpan]) -> Bool {
        let x = looksOf(text, a), y = looksOf(text, b)
        for i in x.indices {
            let l = x[i].flatMap { $0.isPlain ? nil : $0 }, r = y[i].flatMap { $0.isPlain ? nil : $0 }
            if l != r { return false }
        }
        return true
    }

    /// A TJ adjustment that moves the text position as far as `advance` (text space) without drawing.
    private static func move(_ run: TextRun, _ advance: Double) -> String {
        let k = run.size * run.hScale
        if abs(k) < 1e-9 || abs(advance) < 1e-9 { return "" }
        return "[\(ContentLexer.number(-advance * 1000 / k))] TJ"
    }

    /// A show operator taken out: what it set and moved stays (' and " go to the next line, " sets the spacing).
    private static func removed(_ op: COp, _ run: TextRun) -> String {
        let mv = move(run, run.info!.advance)
        switch op.name {
        case "'": return "T* \(mv)"
        case "\"": return "\(ContentLexer.number(op.n(0))) Tw \(ContentLexer.number(op.n(1))) Tc T* \(mv)"
        default: return mv.isEmpty ? " " : mv
        }
    }

    /// The paragraph's new lines in place of its first show operator: each line placed with Tm (word spacing 0 while they
    /// are written), then the line matrix and text position the operator left, so the rest of the content draws where it
    /// did.
    private static func writeParagraph(_ page: PObj, _ op: COp, _ run: TextRun, _ font: TextFont, _ layout: ParagraphLayout,
                                       _ writer: Type3FontWriter) throws -> String {
        let info = run.info!
        var sb = ""
        if op.name == "\"" { sb += "\(ContentLexer.number(op.n(0))) Tw \(ContentLexer.number(op.n(1))) Tc " }
        let tw = run.wordSpacing
        if abs(tw) > 1e-9 { sb += "0 Tw " }
        guard let toText = info.tm.times(info.ctm).inverted() else {
            throw ContentEditError("This text is drawn squashed flat, so it can't be rewritten.")
        }
        for (origin, parts) in layout.lines where !parts.isEmpty {
            let user = PageBoxes.toPdf(page, origin.x, origin.y)
            let t = toText.apply(user.x, user.y)
            let lineTm = Mat(1, 0, 0, 1, t.x, t.y - info.rise).times(info.tm)
            sb += lineTm.write() + " Tm "
            writeLine(&sb, info.hex, font, parts, run, writer)
        }
        if abs(tw) > 1e-9 { sb += ContentLexer.number(tw) + " Tw " }
        // Back where the operator left things: the line matrix after it, the text position moved along its baseline.
        let tlm = info.tlmAfter
        var along = 0.0
        if abs(tlm.a) >= abs(tlm.b) && abs(tlm.a) > 1e-12 {
            along = (info.tm.e - tlm.e) / tlm.a
        } else if abs(tlm.b) > 1e-12 {
            along = (info.tm.f - tlm.f) / tlm.b
        }
        sb += tlm.write() + " Tm " + move(run, along + info.advance)
        return sb
    }

    /// A line's parts as TJ arrays of codes and adjustments; stretches in other fonts in between, drawn by `writer` with no
    /// character spacing; a stretch with a look of its own inside a marked-content tag (`lookTagName`), at its size and in
    /// its color. The run's font, size, spacing, rise and color are set back after.
    private static func writeLine(_ sb: inout String, _ hex: Bool, _ font: TextFont, _ parts: [Part], _ run: TextRun, _ writer: Type3FontWriter) {
        let info = run.info!
        var tokens: [String] = []
        var codes: [Int] = []
        var tag: PartLook?
        var color: Int? // nil: the run's own
        var scale = 1.0
        var ownFont = true
        func flush() {
            if codes.isEmpty { return }
            let bytes = font.toBytes(codes)
            tokens.append(hex ? ContentLexer.hexString(bytes) : ContentLexer.literal(bytes))
            codes.removeAll()
        }
        func close(_ sb: inout String) {
            flush()
            if !tokens.isEmpty { sb += "[" + tokens.joined(separator: " ") + "] TJ " }
            tokens.removeAll()
        }
        func setLook(_ sb: inout String, _ look: PartLook?) {
            if look !== tag {
                close(&sb)
                if tag != nil { sb += "EMC " }
                if let look { sb += LookTag.write(look.asked) }
                tag = look
            }
            if look?.color != color {
                close(&sb)
                sb += look?.color.map(rgbOp) ?? ((info.fillOp ?? "") + " ")
                color = look?.color
            }
        }
        func setOwnFont(_ sb: inout String, _ s: Double) {
            if ownFont && abs(s - scale) < 1e-9 { return }
            close(&sb)
            sb += "/\(escapeName(run.fontKey)) \(ContentLexer.number(run.size * s)) Tf "
            ownFont = true
            scale = s
        }
        for part in parts {
            setLook(&sb, part.look)
            let s = part.look?.scale ?? 1
            if let standIn = part.standIn {
                close(&sb)
                let tc = abs(run.charSpacing) > 1e-9
                if tc { sb += "0 Tc " }
                writer.emit(&sb, standIn, size: run.size * s)
                sb += " "
                ownFont = false
                if tc { sb += ContentLexer.number(run.charSpacing) + " Tc " }
                if abs(info.rise) > 1e-9 { sb += ContentLexer.number(info.rise) + " Ts " }
                continue
            }
            setOwnFont(&sb, s)
            if let code = part.code {
                codes.append(code)
            } else if abs(part.number) > 1e-9 {
                flush()
                tokens.append(ContentLexer.number(part.number))
            }
        }
        setLook(&sb, nil)
        setOwnFont(&sb, 1)
        close(&sb)
    }

    /// Adds fonts to the page's own font resources (copying shared dictionaries first).
    private static func addFonts(_ doc: MuDoc, _ page: PObj, _ fonts: PObj) {
        let res = ownDict(doc, page, "Resources", PageBoxes.inherited(page, "Resources"))
        let fd = ownDict(doc, res, "Font")
        for key in fonts.keys {
            if let v = fonts[key] { fd.set(key, v) }
        }
    }
}
