import Foundation
import PrintCore

/// How a paragraph's lines sit in its box. Justified: every line but the last reaches both edges.
public enum ParagraphAlign: Sendable, Equatable { case left, center, right, justified }

/// A paragraph of a page's text, for Edit Text & Images (roadmap 2.1; the Windows app's `TextParagraph`): lines of one
/// font, size and color, one under the other at a steady line step, their edges lined up (see
/// `ContentEditor.groupParagraphs`). Page space (points, top-left origin of the page as shown).
public struct TextParagraph: Sendable {
    public let pageIndex: Int
    /// Its text runs (line by line, left to right).
    public internal(set) var runs: [TextRun]
    /// Each line's box, top to bottom.
    public internal(set) var lines: [RectD]
    /// Its text, the lines joined by a space (a line ending in a hyphen joins the next without one).
    public let text: String
    /// The lines' boxes together: the box new text wraps in (its width) and grows from (downward).
    public internal(set) var box: RectD
    public internal(set) var align: ParagraphAlign
    /// From one baseline to the next (points); for a single line, 1.2 times its size.
    public let lineStep: Double
    /// How much further right the first line starts than the others (left and justified text).
    public let firstIndent: Double
    /// Why it can't be rewritten as one paragraph ("it is …"); nil when it can.
    public let blocked: String?
    /// The nearest text or picture below the paragraph, across its width: what a longer text would run into.
    public internal(set) var below: RectD?
    /// The direction of its baselines on the page, degrees clockwise from left-to-right (0: upright text).
    public internal(set) var angle = 0.0
    /// Turned text: the paragraph in its own direction (page space turned by -`angle` about the page's origin, so its
    /// text reads upright there), where it is grouped and laid out; `lines`, `box` and `below` are their bounding boxes
    /// on the page. Empty for upright text.
    var uprightStore: [TextParagraph] = []
    var upright: TextParagraph? { uprightStore.first }
    /// Runs of spaces only drawn on its lines (some generators draw each space on its own): they go with its text.
    var spaces: [TextRun] = []
    /// The stretches of `text` an earlier edit gave a look of their own (font, size, color, bold, italic).
    public internal(set) var spans: [TextSpan] = []
    /// The line edges new text is laid out between (the box but the first line's indent); how far its own text reaches
    /// above and below its baseline (points).
    var left = 0.0, right = 0.0, center = 0.0, ascent = 0.0, descent = 0.0
    /// The kerning its own text carried, by pair of codes (see `ContentEditor.kerning`): rewritten lines keep it where
    /// the pair survives.
    var kerning: [ContentEditor.CodePair: Double]?

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

    /// Its run in its own font and look (see `ContentEditor.plainRun`): its font, style and color.
    public var lead: TextRun { ContentEditor.plainRun(runs) }

    /// What `text` would look like here, its stretches with the looks `spans` give them: its box, line count, missing
    /// characters and what it would run into.
    public func check(_ text: String, spans: [TextSpan]? = nil) -> ParagraphCheck {
        if blocked != nil { return ParagraphCheck(box: box, lineCount: lines.count, missing: [], overlaps: nil) }
        return ContentEditor.layOut(self, runs, ContentEditor.paragraphText(text), spans).check
    }
}

/// New text for a paragraph: the box it would take, its line count, characters no font here can draw, and what it would
/// run into below (nil: nothing).
public struct ParagraphCheck: Sendable {
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

func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

extension ContentEditor {
    static func withParagraphs(_ content: PageContent) -> PageContent {
        var c = content
        c.paragraphs = groupParagraphs(content)
        return c
    }

    // ---- Grouping ----

    /// A line of text: runs on one baseline, left to right, with no column gap between them.
    final class PLine {
        var runs: [TextRun]
        var box: RectD
        var baseline: Double
        /// Its text (UTF-16).
        var text: [UInt16]
        /// Where each run's text starts in `text`.
        var starts: [Int] = [0]
        private var leadRun: TextRun?

        init(_ first: TextRun) {
            runs = [first]
            box = first.box
            baseline = first.origin.y
            text = Array(first.text.utf16)
        }

        /// Its run in its own look: the font most of its text is in (see `plainRun`), so a line that begins with a word in
        /// another family (a symbol, a name set apart) is still a line of the paragraph's font.
        var lead: TextRun {
            if let main { return main }
            if let leadRun { return leadRun }
            let l = plainRun(runs)
            leadRun = l
            return l
        }

        /// For a translated copy: the run with most of its text, what the line is like when a link or a mark starts it.
        var main: TextRun?

        var size: Double { lead.fontSize }

        /// Its text as a string.
        var string: String { String(decoding: text, as: UTF16.self) }

        /// Its biggest text against its own: 1 unless an edit made part of it bigger.
        var scale: Double { max(1, (runs.map(\.fontSize).max() ?? 0) / max(0.1, size)) }

        func add(_ r: TextRun) {
            let gap = r.box.x - box.right
            if gap > 0.15 * size && text.last != 32 && r.text.utf16.first != 32 { text.append(32) }
            starts.append(text.count)
            text += r.text.utf16
            runs.append(r)
            leadRun = nil
            box = box.union(r.box)
        }
    }

    /// Lines stacked one under the other, and which alignments they still allow.
    final class PStack {
        var lines: [PLine]
        var canLeft = true, canCenter = true, canRight = true
        var step = 0.0

        init(_ first: PLine) { lines = [first] }
    }

    /// The page's upright text runs as paragraphs, joined the way Export to Word joins lines: runs on one baseline with
    /// less than 2.5 ems between them make a line; a line carries on the paragraph above it when it is in the same font,
    /// size (within 5%) and color, below it with at most 0.65 ems between them and the same line step as the lines before
    /// (within 10%), overlapping it across, with its left edges (a first-line indent allowed), centers or right edges
    /// lined up; and when the line above didn't end short (its next first word would have fit on it). Runs of spaces only
    /// are left out. Turned text is grouped the same way in its own direction, each direction apart (see
    /// `TextParagraph.upright`).
    static func groupParagraphs(_ content: PageContent) -> [TextParagraph] {
        var result = groupUpright(content)
        for (angle, mine) in directions(content) {
            let (framedContent, page) = framed(content, angle, mine)
            result += groupUpright(framedContent).map { turned($0, angle, page) }
        }
        return result
    }

    /// The upright text runs of `content` as paragraphs (see `groupParagraphs`).
    private static func groupUpright(_ content: PageContent) -> [TextParagraph] {
        let runs = content.runs.filter { abs($0.angle) < 0.5 && !trimmed($0.text).isEmpty && $0.fontSize > 0.5 && $0.box.width > 0 }
        if runs.isEmpty { return [] }
        var result: [TextParagraph] = []
        for stack in stacks(linesOf(runs)) {
            for part in splitShort(stack) { result.append(paragraph(content, part)) }
        }
        return result
    }

    static func linesOf(_ runs: [TextRun]) -> [PLine] {
        var lines: [PLine] = []
        let sorted = runs.enumerated().sorted { ($0.element.origin.y, $0.offset) < ($1.element.origin.y, $1.offset) }.map(\.element)
        var i = 0
        while i < sorted.count {
            // A band of runs on one baseline, then left to right.
            let y0 = sorted[i].origin.y
            var j = i + 1
            while j < sorted.count && sorted[j].origin.y - y0 <= 0.25 * max(sorted[i].fontSize, sorted[j].fontSize) { j += 1 }
            var cur: PLine?
            let band = sorted[i..<j].enumerated().sorted { ($0.element.box.x, $0.offset) < ($1.element.box.x, $1.offset) }.map(\.element)
            for r in band {
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

    static func stacks(_ lines: [PLine]) -> [PStack] {
        var stacks: [PStack] = []
        // Lines come top to bottom, so a stack whose last line is far above this one takes no more: a crafted page's many
        // thousand lines don't each try every earlier one.
        var open: [PStack] = []
        let ordered = lines.enumerated().sorted { ($0.element.baseline, $0.element.box.x, $0.offset) < ($1.element.baseline, $1.element.box.x, $1.offset) }
        for line in ordered.map(\.element) {
            var best: PStack?
            var bestGap = Double.greatestFiniteMagnitude
            open.removeAll { line.baseline - $0.lines[$0.lines.count - 1].baseline > 6 * max($0.lines[$0.lines.count - 1].size, line.size) }
            for s in open {
                guard let gap = joins(s, line), gap < bestGap else { continue }
                best = s
                bestGap = gap
            }
            guard let best else {
                let added = PStack(line)
                stacks.append(added)
                open.append(added)
                continue
            }
            let fit = fits(best, line)
            best.canLeft = fit.left
            best.canCenter = fit.center
            best.canRight = fit.right
            if best.lines.count == 1 { best.step = plainStep(best.lines[0], line, line.baseline - best.lines[0].baseline) }
            best.lines.append(line)
        }
        return stacks
    }

    /// Same font family, size (within 5%) and color; a stand-in run (characters an edit drew from another font) only
    /// needs the size and color, and text an edit gave a look of its own goes with anything.
    private static func sameLook(_ a: TextRun, _ b: TextRun) -> Bool {
        sameSizeAndColor(a, b) && (restyled(a, b) || a.standIn || b.standIn || sameFamily(a, b))
    }

    /// Size within 5% and the same color: what text in another family needs to be part of a paragraph's lines (text an
    /// edit gave a look of its own goes with anything).
    private static func sameSizeAndColor(_ a: TextRun, _ b: TextRun) -> Bool {
        restyled(a, b) || (abs(a.fontSize - b.fontSize) <= max(0.3, 0.05 * a.fontSize) && a.color == b.color)
    }

    /// Either is text an edit gave a look of its own (`TextRun.styled`), which joins any.
    private static func restyled(_ a: TextRun, _ b: TextRun) -> Bool { a.styled || b.styled }

    /// The same font, or two faces of one family (regular and bold, as Word's PDFs draw a bold word).
    static func sameFamily(_ a: TextRun, _ b: TextRun) -> Bool {
        (a.font != nil && a.font === b.font) || FontNames.family(a.fontName).caseInsensitiveCompare(FontNames.family(b.fontName)) == .orderedSame
    }

    /// A paragraph's own font among its runs: of those in a page font (not a stand-in, not a look an edit gave), the font
    /// with the most text, a regular face before a bold or italic one on a tie, as its first run in content order; else
    /// the first run that isn't a stand-in, else the first.
    static func plainRun(_ runs: [TextRun]) -> TextRun {
        var groups: [(font: TextFont, runs: [TextRun])] = []
        for r in runs where !r.standIn && !r.styled {
            guard let f = r.font else { continue }
            if let at = groups.firstIndex(where: { $0.font === f }) {
                groups[at].runs.append(r)
            } else {
                groups.append((f, [r]))
            }
        }
        func weight(_ g: (font: TextFont, runs: [TextRun])) -> (Int, Int, Int) {
            let chars = g.runs.reduce(0) { $0 + trimmed($1.text).utf16.count }
            let styled = g.font.bold || g.font.italic ? 1 : 0
            return (-chars, styled, g.runs.map { order($0.id) }.min() ?? 0)
        }
        if let best = groups.min(by: { weight($0) < weight($1) }) { return best.runs.min(by: before)! }
        return runs.first { !$0.standIn && !$0.styled } ?? runs.first { !$0.standIn } ?? runs[0]
    }

    /// A run's place in its content's order: page operators count up from 0, operators inside forms down from -1 (the
    /// walk numbers them as it meets them), so the first in a form is the one nearest 0.
    static func order(_ id: Int) -> Int { id < 0 ? -id : id }

    /// Whether `a` comes before `b` in their content.
    static func before(_ a: TextRun, _ b: TextRun) -> Bool { order(a.id) < order(b.id) }

    /// The step from one baseline to the next as the paragraph's own (see `layOut`: bigger text widens it).
    static func plainStep(_ above: PLine, _ below: PLine, _ step: Double) -> Double {
        step / (rise * above.scale + (1 - rise) * below.scale)
    }

    /// How much of a line step is the line above's depth (the rest is the next line's height).
    private static let rise = 0.25

    /// The gap between the stack's last line and `line` when the line carries the stack on; else nil.
    private static func joins(_ s: PStack, _ line: PLine) -> Double? {
        let last = s.lines[s.lines.count - 1]
        let size = last.size
        if !sameLook(last.lead, line.lead) { return nil }
        // Two drawings of one form (or two forms) are two pieces of content: their lines are paragraphs of their own. A
        // form's lines and the page's still join (they are edited line by line, see `paragraph`).
        if let a = last.lead.info?.form, let b = line.lead.info?.form, a != b { return nil }
        let step = plainStep(last, line, line.baseline - last.baseline)
        if step < 0.6 * size { return nil }
        let gap = line.box.y - last.box.bottom
        if gap > 0.65 * size { return nil }
        if s.lines.count >= 2 && abs(step - s.step) > max(0.5, 0.1 * size) { return nil }
        if line.box.x >= last.box.right || line.box.right <= last.box.x { return nil }
        let f = fits(s, line)
        return f.left || f.center || f.right ? max(0, gap) : nil
    }

    static func tolerance(_ size: Double) -> Double { max(1.5, 0.12 * size) }

    /// The alignments the stack still allows with `line` under it.
    private static func fits(_ s: PStack, _ line: PLine) -> (left: Bool, center: Bool, right: Bool) {
        let first = s.lines[0]
        let tol = tolerance(first.size)
        let left: Bool
        if s.lines.count == 1 {
            let indent = first.box.x - line.box.x
            left = abs(indent) <= tol || (indent >= 0.5 * first.size && indent <= 8 * first.size)
        } else {
            left = abs(line.box.x - s.lines[1].box.x) <= tol
        }
        let center = abs(line.box.centerX - first.box.centerX) <= tol
        let right = abs(line.box.right - first.box.right) <= tol
        return (s.canLeft && left, s.canCenter && center, s.canRight && right)
    }

    /// Splits a stack after each line that ended short: the next line's first word would have fit on it. `translating`:
    /// ragged text in a narrow column often ends a line short mid-sentence: for a translator a line going on in
    /// lowercase, after no end of sentence, stays with the one above; two short labels one under the other go apart.
    static func splitShort(_ s: PStack, translating: Bool = false) -> [[PLine]] {
        var parts: [[PLine]] = []
        var cur = [s.lines[0]]
        let width = s.lines.map(\.box.width).max() ?? 0
        let right = s.lines.map(\.box.right).max() ?? 0
        let indented = s.canLeft && s.lines.count > 1 && s.lines[0].box.x - s.lines[1].box.x > tolerance(s.lines[0].size)
        for i in 1..<max(1, s.lines.count) {
            let prev = s.lines[i - 1]
            let line = s.lines[i]
            let room = i == 1 && indented ? right - prev.box.x : width
            let words = String(decoding: line.text, as: UTF16.self).drop { $0 == " " }
            let word = words.split(separator: " ", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let need = prev.box.width + widthOf(line.lead, " " + word, line)
            let short = need < room - 0.5 * prev.size && !(translating && goesOn(prev.string, line.string))
            if short || (translating && labels(prev.string, line.string)) {
                parts.append(cur)
                cur = []
            }
            cur.append(line)
        }
        parts.append(cur)
        return parts
    }

    /// A line starting in lowercase after one that ends in no sentence-ending punctuation.
    private static func goesOn(_ above: String, _ below: String) -> Bool {
        let a = Array(TranslationText.trim(above).unicodeScalars), b = Array(TranslationText.trim(below).unicodeScalars)
        guard let last = a.last, let first = b.first else { return false }
        return !".!?:;".unicodeScalars.contains(last) && first.properties.isLowercase
    }

    /// Two short lines, the second starting in capitals, or the first ending in a colon and the second not going on in
    /// lowercase (a table's "Income percentile ratios:" above its "90th/10th" row; not "as follows:" above "accuracy
    /// rose"), nothing carrying over: entries of a list or a table's labels, not a sentence wrapped.
    private static func labels(_ above: String, _ below: String) -> Bool {
        let a = Array(TranslationText.trim(above).utf16), b = Array(TranslationText.trim(below).utf16)
        guard (1...28).contains(a.count), (1...28).contains(b.count), let first = Unicode.Scalar(b[0]) else { return false }
        let last = a[a.count - 1]
        let upper = first.properties.isUppercase
        return (upper || (last == 58 && !first.properties.isLowercase)) && last != 44 && last != 45
    }

    /// How wide text is in a run's font and spacing (points); estimated from the line's characters when the font can't
    /// tell.
    private static func widthOf(_ run: TextRun, _ text: String, _ line: PLine) -> Double {
        if let font = run.font {
            let enc = font.encode(text)
            if enc.missing.isEmpty { return run.width(partsOf(run, enc.codes)) * run.scale }
        }
        return Double(text.utf16.count) * line.box.width / Double(max(1, line.text.count))
    }

    /// A pair of neighboring codes (the kerning table's key).
    struct CodePair: Hashable, Sendable {
        var a: Int, b: Int
    }

    /// Codes as parts (a gap as an adjustment), with the kerning `kerning` gives each pair of neighbors.
    static func partsOf(_ run: TextRun, _ codes: [Int], _ kerning: [CodePair: Double]? = nil, _ look: PartLook? = nil) -> [Part] {
        var parts: [Part] = []
        parts.reserveCapacity(codes.count * 2)
        for (i, c) in codes.enumerated() {
            if i > 0, let kerning, let k = kerning[CodePair(a: codes[i - 1], b: c)] { parts.append(Part(nil, k, nil, look)) }
            parts.append(c == TextFont.gap ? Part(nil, -run.gapEms * 1000, nil, look) : Part(c, 0, nil, look))
        }
        return parts
    }

    /// The kerning the original text carried: each TJ adjustment between two glyphs of a word (not a word gap, not one
    /// after the last glyph, at most 0.25 em either way), by the pair of codes around it; the first seen wins.
    static func kerning(_ runs: [RunInfo]) -> [CodePair: Double] {
        var table: [CodePair: Double] = [:]
        for info in runs {
            let items = info.items
            if items.count < 3 { continue }
            for i in 1..<(items.count - 1) {
                let it = items[i]
                if !it.isNumber || it.trailing || !it.units.isEmpty || abs(it.number) > 250 || abs(it.number) < 0.5 { continue }
                let before = items[i - 1], after = items[i + 1]
                if before.isNumber || after.isNumber || before.units == [32] || after.units == [32] { continue }
                let key = CodePair(a: before.code, b: after.code)
                if table[key] == nil { table[key] = it.number }
            }
        }
        return table
    }

    private static func isLetter(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { $0.properties.isAlphabetic } ?? false }
    private static func isLower(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { $0.properties.isLowercase } ?? false }

    /// Trimmed of white space at both ends (UTF-16).
    private static func trim(_ t: [UInt16]) -> [UInt16] {
        func white(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isWhitespace ?? false }
        guard let lo = t.firstIndex(where: { !white($0) }), let hi = t.lastIndex(where: { !white($0) }) else { return [] }
        return Array(t[lo...hi])
    }

    /// `translating`: for a translated copy (see ContentEditor+Translate): every run of it goes and new text takes its
    /// place in its own font, so mixed looks, right-to-left text and marks on its lines don't stop it, a hanging first
    /// line stays where it hangs, and its bold, italic, subscript and superscript stretches are its spans
    /// (`translationLook`).
    static func paragraph(_ content: PageContent, _ lines: [PLine], translating: Bool = false) -> TextParagraph {
        let first = lines[0]
        let size = first.size
        let tol = tolerance(size)
        let n = lines.count
        let rest = n > 1 ? Array(lines.dropFirst()) : lines
        var left = rest.map(\.box.x).min()!
        let right = lines.map(\.box.right).max()!
        let lefts = rest.allSatisfy { abs($0.box.x - left) <= tol }
        var indent = n > 1 && lefts ? first.box.x - left : 0
        if indent < 0.5 * size && !(translating && indent < -0.5 * size) { indent = 0 }
        let flushLeft = lefts && (indent > 0 || abs(first.box.x - left) <= tol)
        let center = lines.reduce(0.0) { $0 + $1.box.centerX } / Double(n)
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
        // A justified paragraph with a line or two that starts elsewhere (a formula, an inset) isn't right-aligned.
        if translating && align == .right && n >= 3 {
            let xs = rest.map(\.box.x).sorted()
            let usual = xs[xs.count / 2]
            if Double(xs.filter { abs($0 - usual) <= tol }.count) >= 0.7 * Double(xs.count) {
                align = .justified
                left = usual
            }
        }
        if align == .center || align == .right {
            indent = 0
            left = lines.map(\.box.x).min()!
        }

        let runs = lines.flatMap(\.runs)
        let mine = Set(runs.map(\.id))
        var blocked = runs.lazy.compactMap(\.blocked).first
        // Its own look: the font most of it is in (a bold or italic word in another face of the family, or a word in
        // another family, is a stretch with a look of its own); else (an edit gave all of it another look) its first
        // run's. Another size or color on its lines can't be rewrapped with it.
        let own = plainRun(runs)
        if blocked == nil && !translating && runs.contains(where: { !sameSizeAndColor(own, $0) }) {
            blocked = loc("it mixes fonts, sizes or colors, and this version rewrites a paragraph in one font family only")
        }
        // A run whose font can't be used (none was read for it): its words couldn't be written in it again.
        if blocked == nil && !translating && runs.contains(where: { $0.font == nil }) { blocked = loc("its font is missing from the page") }
        if blocked == nil && runs.contains(where: { $0.info == nil }) { blocked = loc("part of it can't be read for editing") }
        // Lines drawn by different content (the page's own and a form XObject's, or two forms) can't be rewritten as one.
        if blocked == nil && runs.contains(where: { $0.info!.form != own.info!.form }) {
            blocked = loc("part of it is inside a form XObject (a drawing the page reuses) and part outside, and a paragraph is rewritten in one piece of content only")
        }
        // Rewrapping lays words out left to right, so right-to-left text would come out in the wrong order.
        if blocked == nil && !translating && runs.contains(where: { r in r.text.unicodeScalars.contains { [.R, .AL].contains(Bidi.classify($0.value)) } }) {
            blocked = loc("it is written right to left, and this version rewraps left-to-right text only")
        }

        var text: [UInt16] = []
        var at: [(run: TextRun, start: Int, length: Int)] = [] // where each run's text is in the paragraph's
        var looks: [TextSpan]? = translating ? [] : nil
        var soft = false // the line before ended with a soft hyphen
        for (li, l) in lines.enumerated() {
            var t = trim(l.text)
            if !text.isEmpty && !soft {
                // A hyphen typed into the word ("respon-sible") stays as typed; the lines join without a space.
                let hyphen = text.count >= 2 && text[text.count - 1] == 45 && isLetter(text[text.count - 2]) && !t.isEmpty && isLower(t[0])
                if !hyphen {
                    text.append(32)
                } else if translating {
                    // For a translator the line break's hyphen would be part of the word; the stretch it ended goes without it.
                    text.removeLast()
                    if let last = looks?.last, last.end > text.count { looks![looks!.count - 1].length = text.count - last.start }
                    if let last = looks?.last, last.length <= 0 { looks!.removeLast() }
                }
            }
            // A soft hyphen (U+00AD) ending a line was added by the line break: it goes, and the word joins the next line's.
            soft = li != lines.count - 1 && t.last == 0xAD
            if soft { t.removeLast() }
            let leadCount = l.text.count - (l.text.firstIndex { !(Unicode.Scalar($0)?.properties.isWhitespace ?? false) } .map { l.text.count - $0 } ?? 0)
            let baseline = looks != nil ? lineBaseline(l) : (y: 0, size: 0)
            for (i, r) in l.runs.enumerated() {
                let from = min(max(l.starts[i] - leadCount, 0), t.count)
                let to = min(max(l.starts[i] + r.text.utf16.count - leadCount, 0), t.count)
                at.append((r, text.count + from, to - from))
                if looks != nil && to > from, let look = translationLook(own, baseline, r) {
                    // One stretch over the space between two of the same look ("<b>brown fox</b>", not "<b>brown</b> <b>fox</b>").
                    let start = text.count + from
                    let base = text.count
                    if let last = looks!.last, last.look == look, joinsAcrossSpace(last.end, start, { $0 < base ? text[$0] : t[$0 - base] }) {
                        looks![looks!.count - 1].length = base + to - last.start
                    } else {
                        looks!.append(TextSpan(start, to - from, look))
                    }
                }
            }
            text += t
        }
        let box = lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) }
        // Other text on its lines (a raised footnote mark, a symbol in another font): rewrapping would leave it behind.
        // Spaces drawn on their own on its lines go with it.
        var spaces: [TextRun] = []
        for r in content.runs {
            if r.box.right <= box.x || r.box.x >= box.right || r.box.bottom <= box.y || r.box.y >= box.bottom || mine.contains(r.id) { continue }
            let cy = r.box.centerY
            // On a line: its middle inside the line's height, across from the line or right after its end (a mark after the
            // last word).
            let onLine = lines.contains { l in cy > l.box.y && cy < l.box.bottom && r.box.right > l.box.x && r.box.x < l.box.right + 0.3 * l.size }
            if !onLine { continue }
            if !trimmed(r.text).isEmpty {
                if translating { continue }
                if blocked == nil {
                    blocked = loc("it has other text inside it (a raised mark, a symbol or words in another font), and this version rewrites a paragraph in one font only")
                }
            } else if r.info != nil && abs(r.angle) < 0.5 {
                spaces.append(r)
            }
        }
        // The line step as the paragraph's own: bigger text an edit gave part of it widened the steps around it.
        var step = 1.2 * size
        if n > 1 {
            var sum = 0.0
            for i in 1..<n { sum += plainStep(lines[i - 1], lines[i], lines[i].baseline - lines[i - 1].baseline) }
            step = sum / Double(n - 1)
        }

        // What follows below: the nearest other text or picture across the paragraph's width.
        var below: RectD?
        if !translating {
            let others = content.runs.filter { !mine.contains($0.id) && !trimmed($0.text).isEmpty }.map(\.box) + content.images.map(\.box)
            for b in others {
                if b.y < box.bottom - 1 || b.right <= box.x + 1 || b.x >= box.right - 1 { continue }
                if below == nil || b.y < below!.y { below = b }
            }
        }

        let paragraphText = String(decoding: text, as: UTF16.self)
        var p = TextParagraph(pageIndex: runs[0].pageIndex, runs: runs, lines: lines.map(\.box), text: paragraphText, box: box,
                              align: align, lineStep: step, firstIndent: indent, blocked: blocked)
        p.below = below
        p.spaces = spaces
        p.spans = looks ?? spansOf(own, text, at)
        if blocked == nil {
            let kerned = runs.filter { !$0.standIn && !$0.styled && $0.info != nil && $0.font === own.font }.map { $0.info! }
            p.kerning = kerning(kerned)
        }
        p.left = left
        p.right = right
        p.center = center
        p.ascent = own.origin.y - own.box.y
        p.descent = own.box.bottom - own.origin.y
        return p
    }

    // ---- Laying out new text ----

    /// A paragraph's new text as typed: Windows line ends and tabs made plain, trailing space dropped.
    static func paragraphText(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        var u = Array(t.utf16)
        while let last = u.last, Unicode.Scalar(last)?.properties.isWhitespace ?? false { u.removeLast() }
        return String(decoding: u, as: UTF16.self)
    }

    /// The lines placed; the check; for each page font written, its codes and the text they stand for (for
    /// `TextFont.prepare`).
    struct ParagraphLayout {
        var lines: [(origin: PointD, parts: [Part])]
        var check: ParagraphCheck
        var fonts: [(font: TextFont, codes: [Int], text: String)]
    }

    /// New text laid out in a paragraph's box, in its own font (`plainRun`), size and spacing: words wrapped at the box's
    /// width (a single line doesn't wrap), a new line at each line break, the paragraph's alignment (a justified
    /// paragraph's last line, and each line before a break, start left), its line step. Stretches `spans` give a look of
    /// their own are drawn in it: the page's own bold or italic face when the paragraph has one, else an installed font
    /// for another family, bold or italic; another size (a line with bigger text moves down as far as it needs); another
    /// color. `fit`: for a translated copy, the text's size against the paragraph's own; it always wraps, wherever it can
    /// (`fitLines`), in one font (`MixedText`'s `oneFace`), right to left when most of it reads so (`layOutRightToLeft`).
    /// Nil: as typed in the editor.
    static func layOut(_ p: TextParagraph, _ runs: [TextRun], _ text: String, _ spans: [TextSpan]? = nil, fit: Double? = nil) -> ParagraphLayout {
        if let upright = p.upright { return onPage(layOut(upright, runs, text, spans, fit: fit), p) }
        let anchor = anchorRun(runs)
        let plain = plainRun(runs)
        let font = plain.font!
        var m = plain
        m.wordSpacing = 0 // the lines are written with Tw 0 (justification goes into adjustments)
        let shrink = fit ?? 1
        m.size *= shrink
        if fit != nil && mostlyRightToLeft(text) { return layOutRightToLeft(p, m, text, shrink) }
        let u = Array(text.utf16)
        let enc = MixedText(p, font, m, text, looksOf(u, spans ?? carry(p.text, text, p.spans)), oneFace: fit != nil)
        if !enc.missing.isEmpty {
            return ParagraphLayout(lines: [], check: ParagraphCheck(box: p.box, lineCount: p.lines.count, missing: enc.missing, overlaps: nil), fonts: [])
        }

        func w(_ parts: [Part]) -> Double { parts.isEmpty ? 0 : m.width(parts) * m.scale }
        let wrap = p.lines.count > 1
        var lines: [(parts: [Part], spaces: [Int], last: Bool)] = []
        var cur: [Part] = []
        var curAdvance = 0.0 // how far cur advances (text space): a word's width after it is that plus its own
        var spaceEnds: [Int] = [] // the index of each word space's last part in cur
        var space: [Part]?
        var pos = 0
        if fit != nil { lines = fitLines(p, enc, u, w) }
        while fit == nil && pos <= u.count {
            if pos == u.count || u[pos] == 10 {
                lines.append((cur, spaceEnds, true))
                cur = []
                curAdvance = 0
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
            let word = m.measure(parts)
            pos = end
            guard !cur.isEmpty, let sp = space else {
                cur += parts
                curAdvance += word.advance
                continue
            }
            let avail = p.right - p.left - (lines.isEmpty ? p.firstIndent : 0)
            let gap = m.measure(sp).advance
            // The line with the word on it, to its last glyph's ink (the word always has some).
            let joined: Double = word.inked ? (curAdvance + gap + word.end) * m.scale : w(cur + sp + parts)
            if !wrap || joined <= avail + 0.01 {
                spaceEnds.append(cur.count + sp.count - 1)
                cur += sp
                cur += parts
                curAdvance += gap + word.advance
            } else {
                lines.append((cur, spaceEnds, false))
                cur = parts
                curAdvance = word.advance
                spaceEnds = []
            }
            space = nil
        }
        if lines.count == 1 && lines[0].parts.isEmpty { lines.removeAll() } // no text: the paragraph goes

        var placed: [(origin: PointD, parts: [Part])] = []
        var maxRight = p.box.right
        var minLeft = p.box.x
        var baseline = 0.0, scale = 1.0, below = 0.0
        for (i, line) in lines.enumerated() {
            var parts = line.parts
            // A line with bigger text sits lower: the step to it grows with its biggest text, the step after it with its depth.
            let drawn = parts.filter { $0.code != nil || $0.standIn != nil }.map { $0.look?.scale ?? 1 }
            let s = max(1, drawn.max() ?? 1)
            // A superscript's top and a subscript's foot reach past the line's own height and depth: the first line sits
            // low enough for the one, the box ends low enough for the other.
            var above = 0.0
            below = 0
            for q in parts where q.code != nil || q.standIn != nil {
                guard let look = q.look, look.rise != 0 else { continue }
                above = max(above, (look.rise * p.fontSize + look.scale * p.ascent) * shrink)
                below = max(below, (-look.rise * p.fontSize + look.scale * p.descent) * shrink)
            }
            if i == 0 {
                baseline = p.box.y + max(p.ascent * shrink * s, above)
            } else {
                let grow: Double = rise * scale + (1 - rise) * s
                baseline += p.lineStep * shrink * grow
            }
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
                let room: Double = p.right - x0 - width
                let extra: Double = -room / Double(line.spaces.count) / m.scale * 1000 / (m.size * m.hScale)
                var spread: [Part] = []
                spread.reserveCapacity(parts.count + line.spaces.count)
                let at = Set(line.spaces)
                for (k, part) in parts.enumerated() {
                    spread.append(part)
                    if at.contains(k) { spread.append(Part(nil, extra / (part.look?.scale ?? 1), nil, part.look)) }
                }
                parts = spread
                width = w(parts)
            }
            placed.append((PointD(x, baseline), merged(parts)))
            maxRight = max(maxRight, x + width)
            minLeft = min(minLeft, x)
        }
        let bottom = placed.isEmpty ? p.box.y + p.ascent + p.descent : baseline + max(p.descent * shrink * scale, below)
        let box = RectD.fromEdges(minLeft, p.box.y, maxRight, max(bottom, p.box.y + 1))
        var overlaps: RectD?
        if let b = p.below, box.bottom > b.y + 0.5 && b.right > box.x && b.x < box.right { overlaps = b }
        let problem: String? = enc.colored && anchor.info?.fillOp == nil
            ? loc("this paragraph's color is a special ink (a pattern or spot color), so part of it can't be given another color")
            : nil
        var check = ParagraphCheck(box: box, lineCount: placed.count, missing: [], overlaps: overlaps)
        check.borrowed = enc.borrowed
        check.standIns = enc.names
        check.faces = enc.faces
        check.lookProblem = problem
        return ParagraphLayout(lines: placed, check: check, fonts: enc.written.map { ($0.font, $0.codes, $0.text) })
    }

    /// A line's parts with stretches in other fonts next to each other (words and the spaces between them, the adjustments
    /// that justify them) joined into one, so each is drawn by one operator.
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
                while k < parts.count, parts[k].code == nil, parts[k].standIn == nil, parts[k].look === look {
                    room -= parts[k].number / 1000
                    k += 1
                }
                guard k < parts.count, let b = parts[k].standIn, parts[k].look === look, !b.rtl, !a.rtl, !b.mixed, !a.mixed else { break }
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
            result.append(j == i + 1 ? parts[i] : Part(nil, 0, ShapedLine(text: text, glyphs: glyphs, width: width, rtl: false), look))
            i = j
        }
        return result
    }

    /// Where a paragraph's new text is written: its first run in content order in its own font and look.
    static func anchorRun(_ runs: [TextRun]) -> TextRun {
        runs.filter { !$0.standIn && !$0.styled }.min(by: before) ?? runs.filter { !$0.standIn }.min(by: before) ?? runs.min(by: before)!
    }

    /// A paragraph's new text in its own font's codes (a stretch in another face the page has, in that face's); the
    /// characters a font lacks drawn from the closest installed font (`StandInFonts`), each stretch shaped as one
    /// `Part.standIn`; stretches with a look of their own carry it (`Part.look`), drawn in an installed font when the look
    /// asks for another family, or for bold or italic the page has no face for.
    final class MixedText {
        private let p: TextParagraph
        private let font: TextFont
        private let run: TextRun
        private let looks: [TextLook?]
        /// The text elements (a character with its marks, a surrogate pair), with where each starts (UTF-16).
        private let elements: [(element: String, at: Int)]
        /// For each UTF-16 offset of the text, the first element starting there or after (so a range's elements are found
        /// at once: laying out walks each word once, not the whole text for each word).
        private let firstAt: [Int]
        /// Per page font: the text elements it lacks that a stand-in draws, and which stand-in draws each code point.
        private var lacking: [ObjectIdentifier: Set<String>] = [:]
        private var standIns: [ObjectIdentifier: [UInt32: StandInFont]] = [:]
        private var resolved: [TextLook: PartLook?] = [:]

        /// Per page font written: its codes and the text they stand for (for `TextFont.prepare`).
        var written: [(font: TextFont, codes: [Int], text: String)] = []
        var missing: [String] = []
        var borrowed: [String] = []
        var names: [String] = []
        var faces: [String] = []
        /// A look asks for another color.
        var colored = false

        /// `oneFace`: when the font lacks any character, the whole text, its spaces too, is drawn from one installed font,
        /// not a letter here and there: a translation shares few letters with the subset a page's font holds.
        init(_ p: TextParagraph, _ font: TextFont, _ run: TextRun, _ text: String, _ looks: [TextLook?], oneFace: Bool = false) {
            self.p = p
            self.font = font
            self.run = run
            self.looks = looks
            var els: [(element: String, at: Int)] = []
            var at = 0
            var first: [Int] = []
            first.reserveCapacity(text.utf16.count + 1)
            for ch in text {
                let s = String(ch)
                let n = s.utf16.count
                // The group's own start finds it; an offset inside it (an accent after a space), the next group.
                for k in 0..<n { first.append(k == 0 ? els.count : els.count + 1) }
                els.append((s, at))
                at += n
            }
            first.append(els.count)
            elements = els
            firstAt = first
            var lackingList: [(font: TextFont, els: [String], seen: Set<String>)] = []
            var missingSeen = Set<String>()
            // For one face: the page's other faces a look draws in (a bold word in the page's bold), with the elements each draws.
            var otherFaces: [(font: TextFont, els: [String], seen: Set<String>)] = []
            for (el, at) in elements {
                if oneFace && el != "\n", let look = resolve(at), look.face == nil, let other = look.page?.font, other !== font {
                    if let i = otherFaces.firstIndex(where: { $0.font === other }) {
                        if otherFaces[i].seen.insert(el).inserted { otherFaces[i].els.append(el) }
                    } else {
                        otherFaces.append((other, [el], [el]))
                    }
                }
                if ContentEditor.isBlank(el) { continue }
                let look = resolve(at)
                if let face = look?.face {
                    // In a font a look asked for: what it lacks comes from the system's fallbacks, else nothing.
                    // (Core Text's shaping falls back for what the face lacks: every glyph it picks must have an outline.)
                    if !StandInFonts.drawable(el, face.font) && missingSeen.insert(el).inserted { missing.append(el) }
                    continue
                }
                let pageFont = look?.page?.font ?? font
                if pageFont.encode(el).missing.isEmpty { continue }
                if let i = lackingList.firstIndex(where: { $0.font === pageFont }) {
                    if lackingList[i].seen.insert(el).inserted { lackingList[i].els.append(el) }
                } else {
                    lackingList.append((pageFont, [el], [el]))
                }
            }
            if oneFace && !lackingList.isEmpty {
                // Then all of it from installed fonts: its own font's text, and each other face's from the installed font closest to that face.
                var all: [String] = []
                var seen = Set<String>()
                for (el, _) in elements where el != "\n" && seen.insert(el).inserted { all.append(el) }
                lackingList = [(font, all, seen)] + otherFaces
            }
            for (pageFont, els, _) in lackingList {
                var cps: [UInt32] = []
                for cp in els.flatMap(TrueTypeFont.codePoints) where !cps.contains(cp) { cps.append(cp) }
                let map = StandInFonts.forFont(pageFont, cps)
                standIns[ObjectIdentifier(pageFont)] = map
                for el in els {
                    let points = TrueTypeFont.codePoints(el)
                    if points.allSatisfy({ map[$0] != nil }), let face = map[StandInFonts.key(el)], StandInFonts.drawable(el, face.font) {
                        lacking[ObjectIdentifier(pageFont), default: []].insert(el)
                        if !borrowed.contains(el) { borrowed.append(el) }
                        for cp in points where !StandInFonts.inkless(cp) && !names.contains(map[cp]!.name) { names.append(map[cp]!.name) }
                    } else if missingSeen.insert(el).inserted {
                        missing.append(el)
                    }
                }
            }
        }

        /// The look at a place of the text, resolved; nil where it is the paragraph's own.
        private func resolve(_ at: Int) -> PartLook? {
            guard at < looks.count, let look = looks[at], !look.isPlain else { return nil }
            if let known = resolved[look] { return known }
            let lead = p.lead
            var scale = 1.0
            if let size = look.size, size > 0, abs(size - p.fontSize) > 0.01 { scale = size / p.fontSize }
            var r = 0.0
            if let script = look.script {
                r = script == .sub ? ContentEditor.subRise : ContentEditor.superRise
                scale *= ContentEditor.scriptScale
            }
            let color: Int? = look.color.flatMap { $0 != lead.color ? $0 : nil }
            let bold = look.bold ?? lead.bold
            let italic = look.italic ?? lead.italic
            var face: StandInFont?
            var page: TextRun?
            var family: String?
            if let f = look.font, f.caseInsensitiveCompare(FontNames.family(lead.fontName)) != .orderedSame { family = f }
            let restyle = bold != lead.bold || italic != lead.italic
            if family == nil && restyle {
                // The page's own face for it, when the paragraph has one (a bold word as the generator drew it).
                page = p.runs.filter { r in
                    !r.standIn && !r.styled && r.font != nil && r.font !== lead.font && ContentEditor.sameFamily(r, lead) && r.bold == bold && r.italic == italic
                }.min(by: ContentEditor.before)
            } else if let family {
                // Another family the paragraph has in a font of the page's (a word in Times, a symbol font): that font.
                page = p.runs.filter { r in
                    !r.standIn && !r.styled && r.font != nil && FontNames.family(r.fontName).caseInsensitiveCompare(family) == .orderedSame
                        && r.bold == bold && r.italic == italic
                }.min(by: ContentEditor.before)
            }
            if page == nil && (family != nil || restyle), let f = StandInFonts.styled(font, family, bold, italic) {
                face = f
                if !faces.contains(f.name) { faces.append(f.name) }
            }
            if color != nil { colored = true }
            let plainLook = scale == 1 && r == 0 && color == nil && face == nil && page == nil
            let result: PartLook? = plainLook ? nil : PartLook(scale, color, face, look, page, r)
            resolved[look] = .some(result)
            return result
        }

        /// A stretch in a page font: the paragraph's own, or the face its look resolved to.
        private func own(_ chunk: String, _ look: PartLook?) -> [Part] {
            let f = look?.page?.font ?? font
            let codes = f.encode(chunk).codes
            if let i = written.firstIndex(where: { $0.font === f }) {
                written[i].codes += codes
                written[i].text += chunk
            } else {
                written.append((f, codes, chunk))
            }
            return ContentEditor.partsOf(run, codes, f === font ? p.kerning : nil, look)
        }

        /// The parts of [start, end) (UTF-16): stretches in its own font, and stretches of each other font shaped, each
        /// with its look.
        func encode(_ start: Int, _ end: Int) -> [Part] {
            var parts: [Part] = []
            var chunk = ""
            var curLook: PartLook?
            var curFace: StandInFont? // nil: a page font
            var started = false
            func flush() {
                if chunk.isEmpty { return }
                if let f = curFace {
                    parts.append(Part(nil, 0, StandInFonts.shape(chunk, f.font), curLook))
                } else {
                    parts += own(chunk, curLook)
                }
                chunk = ""
            }
            let lo = start < firstAt.count ? firstAt[max(0, start)] : elements.count
            for (el, at) in elements[lo...] {
                if at >= end { break }
                let look = resolve(at)
                let pageFont = look?.page?.font ?? font
                var face = look?.face
                if face == nil, lacking[ObjectIdentifier(pageFont)]?.contains(el) == true {
                    face = standIns[ObjectIdentifier(pageFont)]?[StandInFonts.key(el)]
                }
                if !started || look !== curLook || face !== curFace { flush() }
                started = true
                curLook = look
                curFace = face
                chunk += el
            }
            flush()
            return parts
        }
    }

    // ---- Writing ----

    /// Replaces a paragraph's text: its show operators are taken out (each leaves the text position where it found it, so
    /// what follows stays in place) and the new text is written where the first of them was, in the paragraph's own font,
    /// laid out by `layOut`. A box that would grow into what follows below is refused unless `allowOverlap` (the caller
    /// has warned). Bytes in → bytes out, as `replaceText`.
    /// - Throws: `ContentEditError` when no font can draw the text (the message names the missing characters), the new
    ///   text would run into what follows (`ContentEditError.overlaps`), the paragraph can't be edited, or the page changed.
    public static func replaceParagraph(_ data: [UInt8], _ password: String?, _ paragraph: TextParagraph, _ newText: String,
                                        allowOverlap: Bool = false, spans newSpans: [TextSpan]? = nil) throws -> [UInt8] {
        if let why = paragraph.blocked { throw ContentEditError(loc("This paragraph can't be edited: {0}.", why)) }
        let text = paragraphText(newText)
        let spans = newSpans ?? carry(paragraph.text, text, paragraph.spans)
        if same(text, paragraph.text) && sameSpans(text, spans, paragraph.spans) { return data }
        let doc = try PdfEdit.open(data, password, failure: loc("This PDF can't be edited"))
        let page = try pageOf(doc, paragraph.pageIndex)
        let streams = streams(page)
        let ops = ContentLexer.parse(streams.bytes)
        let walked = try walk(doc, page, paragraph.pageIndex, ops, nil)
        let changed = loc("The page changed since this paragraph was picked. Pick it again.")
        let (now, fresh) = try rematch(paragraph, walked)
        let anchor = anchorRun(now)
        let plain = plainRun(now)
        if now.contains(where: { $0.info!.form != anchor.info!.form }) { throw ContentEditError(changed) }
        // Spaces drawn on their own on its lines go too (when they are still there, in the same content).
        let spaces = paragraph.spaces.compactMap { s in walked.textRuns.first { $0.id == s.id && same($0.text, s.text) && $0.info != nil } }
            .filter { r in !now.contains { $0.id == r.id } && r.info!.form == anchor.info!.form }
        let target = try targetOf(doc, page, streams, ops, walked, anchor)
        // One operator per run: two runs drawn by one operator (a form drawn twice) can't both be rewritten.
        if Set(now.map { ObjectIdentifier(target.opOf($0, walked)) }).count != now.count { throw ContentEditError(changed) }
        let layout = layOut(fresh, now, text, spans)
        if !layout.check.missing.isEmpty {
            let list = layout.check.missing.prefix(12).map(shownCharacter).joined(separator: ", ")
            let message = layout.check.missing.count == 1
                ? loc("Neither this paragraph's font nor any font on this Mac has {0}, so it can't be written. Leave it out, or add a text box instead.", list)
                : loc("Neither this paragraph's font nor any font on this Mac has {0}, so it can't be written. Leave them out, or add a text box instead.", list)
            throw ContentEditError(message, missing: layout.check.missing)
        }
        if let lp = layout.check.lookProblem { throw ContentEditError(loc("This can't be written: {0}.", lp)) }
        if let o = layout.check.overlaps, !allowOverlap {
            let message = loc("The new text takes {0} lines and would run into what follows below it. Shorten it, or confirm to write it anyway.",
                              CoreLanguage.number(layout.check.lineCount))
            throw ContentEditError(message, overlaps: o)
        }
        for (font, codes, written) in layout.fonts {
            if let dict = walked.fontDicts[ObjectIdentifier(font)] { font.prepare(doc, dict, codes, written) }
        }

        // Characters the font lacks: drawn in stand-in fonts, embedded under names no font of the content has.
        let writer = Type3FontWriter(namePrefix: standInPrefix(target), standIn: true)
        let frame = PageBoxes.frame(page)
        var edits: Edits = []
        for run in now {
            let op = target.opOf(run, walked)
            let replacement = run.id == anchor.id ? try writeParagraph(frame, op, run, plain, layout, writer) : removed(op, run)
            edits.append((op.start, op.end, latin1Bytes(replacement)))
        }
        if !writer.isEmpty { addFonts(doc, target.resourceOwner, writer.buildFonts(doc)) }
        for run in spaces {
            let op = target.opOf(run, walked)
            edits.append((op.start, op.end, latin1Bytes(removed(op, run))))
        }
        try writeTarget(doc, page, target, edits)
        SignedEdits.noteRemoval() // the old text stays in a signed file's earlier revision
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// A paragraph's runs found again in a new reading of the page (by id, else by text and place), and the paragraph as
    /// read before with its runs' fonts and readings from the new one (a look's page face is written in it).
    static func rematch(_ paragraph: TextParagraph, _ walked: Walked) throws -> (now: [TextRun], fresh: TextParagraph) {
        let changed = loc("The page changed since this paragraph was picked. Pick it again.")
        var now: [TextRun] = []
        var byId: [Int: TextRun] = [:]
        for run in paragraph.runs {
            let found = walked.textRuns.first { $0.id == run.id && same($0.text, run.text) }
                ?? walked.textRuns.filter { same($0.text, run.text) && near($0.box, run.box) }.min { distance($0.box, run.box) < distance($1.box, run.box) }
            if let why = found?.blocked { throw ContentEditError(loc("This text can't be edited: {0}.", why)) }
            guard let found, found.info != nil, !now.contains(where: { $0.id == found.id }) else { throw ContentEditError(changed) }
            now.append(found)
            byId[run.id] = found // by the id the paragraph knows it by: found by its place, it may have another now
        }
        return (now, refreshed(paragraph, byId))
    }

    /// A paragraph with its runs' fonts and readings from another walk of the page (by id), its geometry kept.
    private static func refreshed(_ p: TextParagraph, _ now: [Int: TextRun]) -> TextParagraph {
        var q = p
        q.runs = p.runs.map { r in
            guard let n = now[r.id] else { return r }
            var x = r
            x.font = n.font
            x.info = n.info
            return x
        }
        q.uprightStore = p.uprightStore.map { refreshed($0, now) }
        return q
    }

    /// Whether two sets of spans give every character of `text` the same look.
    private static func sameSpans(_ text: String, _ a: [TextSpan], _ b: [TextSpan]) -> Bool {
        let u = Array(text.utf16)
        let x = looksOf(u, a), y = looksOf(u, b)
        for i in u.indices {
            let l: TextLook? = x[i].flatMap { $0.isPlain ? nil : $0 }
            let r: TextLook? = y[i].flatMap { $0.isPlain ? nil : $0 }
            if l != r { return false }
        }
        return true
    }

    /// A TJ adjustment that moves the text position as far as `advance` (text space) without drawing.
    static func move(_ run: TextRun, _ advance: Double) -> String {
        let k: Double = run.size * run.hScale
        if abs(k) < 1e-9 || abs(advance) < 1e-9 { return "" }
        return "[\(ContentLexer.number(-advance * 1000 / k))] TJ"
    }

    /// A show operator taken out: what it set and moved stays (' and " go to the next line, " sets the spacing).
    static func removed(_ op: COp, _ run: TextRun) -> String {
        let m = move(run, run.info!.advance)
        let first = nextLine(op, run)
        return !first.isEmpty ? first + m : !m.isEmpty ? m : " "
    }

    /// What a show operator does before it draws, as operators of its own (' and " go to the next line, " sets the
    /// spacing); nothing for any other operator, or for a column of an operator after its first (that is done by then).
    static func nextLine(_ op: COp, _ run: TextRun? = nil) -> String {
        if (run?.info?.column ?? 0) > 0 { return "" }
        switch op.name {
        case "'": return "T* "
        case "\"": return "\(setsSpacing(op, run))T* "
        default: return ""
        }
    }

    /// The word and character spacing a " operator sets, as operators of their own; nothing for any other, or for a
    /// column after its first.
    static func setsSpacing(_ op: COp, _ run: TextRun? = nil) -> String {
        op.name == "\"" && (run?.info?.column ?? 0) == 0 ? "\(ContentLexer.number(op.n(0))) Tw \(ContentLexer.number(op.n(1))) Tc " : ""
    }

    /// The paragraph's new lines in place of its first show operator (`run`), in the paragraph's own font (`plain`): each
    /// line placed with Tm (word spacing 0 while they are written), then the line matrix and text position the operator
    /// left, so the rest of the content draws where it did.
    static func writeParagraph(_ frame: PageFrame, _ op: COp, _ run: TextRun, _ plain: TextRun, _ layout: ParagraphLayout,
                               _ writer: Type3FontWriter) throws -> String {
        let info = run.info!
        var sb = setsSpacing(op, run)
        let tw = run.wordSpacing
        if abs(tw) > 1e-9 { sb += "0 Tw " }
        guard let toText = info.tm.times(info.ctm).inverted() else {
            throw ContentEditError(loc("This text is drawn squashed flat, so it can't be rewritten."))
        }
        for (origin, parts) in layout.lines where !parts.isEmpty {
            let user = frame.toPdf(origin.x, origin.y)
            let t = toText.apply(user.x, user.y)
            let lineTm = Mat(1, 0, 0, 1, t.x, t.y - info.rise).times(info.tm)
            sb += lineTm.write() + " Tm "
            writeLine(&sb, info.hex, plain, parts, run, writer, wordSpacing: 0)
        }
        if abs(tw) > 1e-9 { sb += ContentLexer.number(tw) + " Tw " }
        return sb + backAfter(run)
    }

    /// Back where a run's operator left things: the line matrix after it, the text position moved along its baseline.
    private static func backAfter(_ run: TextRun) -> String {
        let info = run.info!
        let tlm = info.tlmAfter
        var along = 0.0
        if abs(tlm.a) >= abs(tlm.b) && abs(tlm.a) > 1e-12 {
            along = (info.tm.e - tlm.e) / tlm.a
        } else if abs(tlm.b) > 1e-12 {
            along = (info.tm.f - tlm.f) / tlm.b
        }
        return tlm.write() + " Tm " + move(run, along + info.advance)
    }

    /// A line's parts as TJ arrays of codes and adjustments in the paragraph's own font (`plain`) or another face of the
    /// page's the part's look names; stretches in installed fonts in between, drawn by `writer` with no character spacing;
    /// a stretch with a look of its own inside a marked-content tag (`lookTagName`), at its size and in its color. The
    /// font, size, spacing, rise and color the operator (`run`) had are set back after. `wordSpacing`: the Tw in effect,
    /// which is 0 around a stand-in (a Type 3 font's code 32 is a space to Tw, whatever glyph it draws).
    static func writeLine(_ sb: inout String, _ hex: Bool, _ plain: TextRun, _ parts: [Part], _ run: TextRun, _ writer: Type3FontWriter,
                          wordSpacing: Double) {
        let info = run.info!
        var tokens: [String] = []
        var codes: [Int] = []
        var tag: PartLook?
        var color: Int? // nil: the run's own
        // The page font and size in effect: the operator's own to begin with; false once a stand-in's Tf replaced it.
        var cur = (font: run.font!, hex: hex, size: run.size)
        var ownFont = true
        func flush() {
            if codes.isEmpty { return }
            let bytes = cur.font.toBytes(codes)
            tokens.append(cur.hex ? ContentLexer.hexString(bytes) : ContentLexer.literal(bytes))
            codes.removeAll()
        }
        func close() {
            flush()
            if !tokens.isEmpty { sb += "[" + tokens.joined(separator: " ") + "] TJ " }
            tokens.removeAll()
        }
        func setLook(_ look: PartLook?) {
            if look !== tag {
                close()
                if tag != nil { sb += "EMC " }
                if let look { sb += LookTag.write(look.asked) }
                tag = look
            }
            if look?.color != color {
                close()
                if let c = look?.color {
                    sb += rgbOp(c)
                } else {
                    sb += (info.fillOp ?? "") + " "
                }
                color = look?.color
            }
        }
        func use(_ face: TextRun, _ h: Bool, _ size: Double) {
            if ownFont && face.font === cur.font && abs(size - cur.size) < 1e-9 { return }
            close()
            sb += "/\(escapeName(face.fontKey)) \(ContentLexer.number(size)) Tf "
            ownFont = true
            cur = (face.font!, h, size)
        }
        var ts = info.rise // the text rise in effect
        func setRise(_ want: Double) {
            if abs(want - ts) < 1e-9 { return }
            close()
            sb += ContentLexer.number(want) + " Ts "
            ts = want
        }
        for part in parts {
            setLook(part.look)
            let s = part.look?.scale ?? 1
            // A subscript or superscript: its baseline moved by the text rise, in ems of the paragraph's text.
            setRise(info.rise + (part.look?.rise ?? 0) * plain.size)
            if let standIn = part.standIn {
                close()
                let tc = abs(run.charSpacing) > 1e-9, tw = abs(wordSpacing) > 1e-9
                if tc { sb += "0 Tc " }
                if tw { sb += "0 Tw " }
                writer.emit(&sb, standIn, size: plain.size * s, baseRise: ts)
                ownFont = false
                if tc { sb += ContentLexer.number(run.charSpacing) + " Tc " }
                if tw { sb += ContentLexer.number(wordSpacing) + " Tw " }
                continue
            }
            let face = part.look?.page ?? plain
            use(face, face.font === run.font ? hex : true, plain.size * s)
            if let code = part.code {
                codes.append(code)
            } else if abs(part.number) > 1e-9 {
                flush()
                tokens.append(ContentLexer.number(part.number))
            }
        }
        setLook(nil)
        setRise(info.rise)
        use(run, hex, run.size) // the font and size the operator had
        close()
    }
}
