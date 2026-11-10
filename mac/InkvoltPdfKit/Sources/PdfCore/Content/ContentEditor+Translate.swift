import Foundation
import PrintCore

/// A paragraph of a page as a translated copy sees it, and the table cell it stays in (nil: not in a table). Turned text:
/// `part` is the part of the page it is in; nil for upright text.
struct TranslationSlot {
    var paragraph: TextParagraph
    var cell: RectD?
    var part: TurnedPart?

    /// Turned text: the slot in its part's frame, where it is laid out (its paragraph's `upright`, its cell turned there);
    /// nil for upright text.
    var upright: TranslationSlot? {
        guard let part, let framed = paragraph.upright else { return nil }
        return TranslationSlot(paragraph: framed, cell: cell.map(part.frame.into), part: nil)
    }
}

/// What was written for one paragraph of a page: its place among the page's slots, how far it shrank, whether it fits,
/// the characters left out.
struct TranslationWritten {
    var slot: Int
    var fit: Double
    var fits: Bool
    var dropped: [String]
}

/// A paragraph that wasn't written, and why (as the end of a sentence: "it is …").
struct TranslationRefused {
    var slot: Int
    var why: String
}

/// The paragraph editor's reflow for a translated copy (roadmap 3.1; the Windows app's ContentEditor.Translate.cs): a
/// whole page's paragraphs are found once and rewritten together, in one pass over a document kept open, so a long
/// report isn't reopened for each paragraph. Text goes in its paragraph's box, wrapped wherever the language allows, and
/// shrinks to fit; drawn in the page's own font when that has every character, else in one installed font (a subset
/// rarely holds a translation's letters).
extension ContentEditor {
    /// The most pieces of text a page may have for its paragraphs to be worked out: more is a map or a crafted page, left
    /// as it is and reported.
    static let maxRunsToTranslate = 20_000

    /// The smallest text a paragraph shrinks to: half its size, and not under 5 points unless it was already.
    static func smallestFit(_ size: Double) -> Double { !(size > 5) ? 1 : min(max(5 / size, 0.5), 1) }

    private static let fitStep = 0.05

    /// More text than this can't fit on a page at any size allowed: not laid out.
    static let maxTextToLayOut = 60_000

    // ---- Finding the paragraphs ----

    /// A page's text runs (an operator drawing columns a run for each, `columnStarts`) and pictures, for
    /// `translationSlots`.
    /// - Throws: `ContentEditError` when its forms draw each other beyond any sensible amount: not all of it was read.
    static func readRaw(_ doc: MuDoc, _ page: PObj, _ pageIndex: Int, _ cancel: CancelToken?) throws -> PageContent {
        let walked = try walk(doc, page, pageIndex, ContentLexer.parse(streams(page).bytes, cancel: cancel), cancel, columns: true)
        if walked.cutShort { throw ContentEditError(loc("This page's drawings draw each other too many times to be read in full.")) }
        return walked.content
    }

    /// A page's paragraphs for translating, in reading order of their first line: each table cell's text apart from its
    /// neighbors', raised marks taken into the line they sit on, a bullet in front of a line left where it is. Turned
    /// text (`turned`, see `turnedParts`) is found the same way in its own frame.
    static func translationSlots(_ content: PageContent, _ cells: [RectD], _ cancel: CancelToken?, _ turned: [TurnedPart] = []) throws -> [TranslationSlot] {
        var slots = try uprightSlots(content, cells, cancel)
        for part in turned {
            for s in try uprightSlots(part.content, part.cells, cancel) {
                slots.append(TranslationSlot(paragraph: onPage(s.paragraph, part), cell: s.cell.map(part.frame.out), part: part))
            }
        }
        // The same order however the page's runs were grouped.
        func order(_ s: TranslationSlot) -> (Double, Double, Int) { (s.paragraph.box.y, s.paragraph.box.x, s.paragraph.runs.map(\.id).min() ?? 0) }
        return slots.sorted { order($0) < order($1) }
    }

    /// The paragraphs of a page's upright text (or a turned part's, in its frame), in no particular order.
    private static func uprightSlots(_ content: PageContent, _ cells: [RectD], _ cancel: CancelToken?) throws -> [TranslationSlot] {
        var groups: [Int: [TextRun]] = [:]
        var order: [Int] = []
        for r in content.runs {
            if !(abs(r.angle) < 0.5) || trimmed(r.text).isEmpty || r.fontSize <= 0.5 || r.box.width <= 0 || r.blocked == hiddenLayerBlocked { continue }
            let edges: Double = r.box.x + r.box.y + r.box.width + r.box.height
            if !r.fontSize.isFinite || !edges.isFinite { continue } // a crafted matrix
            let cell = cells.firstIndex { $0.contains(r.box.centerX, r.box.centerY) } ?? -1
            if groups[cell] == nil { order.append(cell) }
            groups[cell, default: []].append(r)
        }
        // A paragraph looks through the page's runs for spaces drawn on their own: only those, or a crowded page takes
        // its count squared.
        let spacesOnly = PageContent(runs: content.runs.filter { trimmed($0.text).isEmpty }, images: [])
        var slots: [TranslationSlot] = []
        for cell in order {
            try cancel?.check()
            let lines = withoutMarkers(withMarksInLine(splitAtColumns(linesOf(groups[cell]!))))
            for line in lines { line.main = line.runs.max { trimmed($0.text).utf16.count < trimmed($1.text).utf16.count } }
            for stack in stacks(lines) {
                try cancel?.check()
                for part in splitShort(stack, translating: true) {
                    slots.append(TranslationSlot(paragraph: paragraph(spacesOnly, part, translating: true), cell: cell >= 0 ? cells[cell] : nil))
                }
            }
        }
        return slots
    }

    /// A line the editor keeps whole comes apart where it is really two things: at a gap wider than word spacing goes (a
    /// label and what it labels, columns no rules mark), and where the size changes (a form's big title beside its small
    /// print), or one size would be forced on both. A small mark (a footnote number) stays on its line. Columns are told
    /// apart as inside one operator (`columnGap`).
    private static func splitAtColumns(_ lines: [PLine]) -> [PLine] {
        var result: [PLine] = []
        result.reserveCapacity(lines.count)
        for l in lines {
            var cur = PLine(l.runs[0])
            result.append(cur)
            let wordGap = l.runs.map { wordSpacing(lineWords($0), $0.fontSize) }.reduce(Double?.none) { a, b in
                guard let b else { return a } // .NET's Min over nullable values skips the nulls
                return a.map { min($0, b) } ?? b
            }
            for i in 1..<max(1, l.runs.count) {
                let prev = l.runs[i - 1], r = l.runs[i]
                let bigger = max(prev.fontSize, r.fontSize)
                let smaller = r.fontSize < prev.fontSize ? r : prev
                let gap = r.box.x - cur.box.right
                // Sizes touching are one word (small capitals: a big D, then "IGITAL"), or go on after a subscript.
                let sizes = bigger - smaller.fontSize > 0.15 * bigger && trimmed(smaller.text).utf16.count > 4 && gap > 0.4 * bigger
                // Figures after a gap are a column of their own, and stay where they are: nothing to translate, and a
                // model would run them into the label.
                if columnGap(gap, bigger, wordGap, prev.text, r.text) || sizes {
                    cur = PLine(r)
                    result.append(cur)
                } else {
                    cur.add(r)
                }
            }
        }
        return result
    }

    // ---- Columns: a label and its figures, set apart on one line ----

    /// A gap this wide (ems) sets columns apart whatever is on either side.
    private static let columnGapEms = 1.5
    /// A gap this wide (ems) sets figures apart from what is beside them, when it is also well beyond the line's word
    /// spacing (`wordGapsToColumn` times).
    private static let figureGapEms = 0.6
    private static let wordGapsToColumn = 1.8
    /// The widest a justified line stretches the space after a sentence (ems).
    private static let sentenceGapEms = 1.0
    /// A gap this wide (ems) is between words, not inside one (a kern).
    private static let wordGapEms = 0.15
    /// The most columns one operator comes apart into: more is a crafted operator, kept whole.
    private static let maxColumnsInRun = 64

    private static func letter(_ c: Character) -> Bool { c.unicodeScalars.contains { TranslationText.isLetter($0) } }

    /// Something with no letters: figures, a dash standing for none, a leader's dot, or a sentence's last "].".
    private static func noLetters(_ s: String) -> Bool { !trimmed(s).isEmpty && !s.contains(where: letter) }

    /// Figures: no letters, and something a sentence doesn't end with: a digit, a sign, a dash standing for none ("27.3",
    /// "-0.5%", "—"); not "]." or ")." alone.
    private static func figures(_ s: String) -> Bool {
        noLetters(s) && s.unicodeScalars.contains { u in
            switch u.properties.generalCategory {
            case .decimalNumber, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol, .dashPunctuation: return true
            default: return false
            }
        }
    }

    /// Whether a gap between `left` and `right` on one line sets columns apart: over 1.5 ems, or over 0.6 ems with figures
    /// on one side and well beyond how far the line's words are apart (`wordGap`, nil: not known), so a justified line's
    /// stretched spaces keep a year in its sentence. After the gap, anything with no letters counts as figures (a
    /// leader's dots); before it, punctuation alone ends a sentence ("]. Our") unless the gap is wider than a sentence's
    /// space stretches (a table's "VGG’s [41]   VGG-16").
    private static func columnGap(_ gap: Double, _ em: Double, _ wordGap: Double?, _ left: String, _ right: String) -> Bool {
        if gap > columnGapEms * em { return true }
        if !(gap > max(figureGapEms * em, wordGapsToColumn * (wordGap ?? 0))) { return false }
        return figures(left) || noLetters(right) || (noLetters(left) && gap > sentenceGapEms * em)
    }

    /// How far one operator's words with letters are apart (`words`, left to right): the narrowest gap between two, under
    /// a column's; nil when there is none. A gap between operators isn't counted: on a table's line that is a column's.
    private static func wordSpacing(_ words: [(start: Double, end: Double, text: String)], _ em: Double) -> Double? {
        var least: Double?
        var before: (end: Double, letters: Bool)?
        for w in words {
            let letters = w.text.contains(where: letter)
            let gap = w.start - (before?.end ?? 0)
            if let b = before, b.letters && letters && gap > wordGapEms * em && gap <= columnGapEms * em { least = min(least ?? .greatestFiniteMagnitude, gap) }
            before = (w.end, letters)
        }
        return least
    }

    /// A run's words where the page shows them (x along its line): from its glyphs when they are known, else the run as one.
    private static func lineWords(_ r: TextRun) -> [(start: Double, end: Double, text: String)] {
        guard let info = r.info, r.scale > 0 else { return [(r.box.x, r.box.right, r.text)] }
        return words(info.items, abs(r.size * r.hScale)).map { w in
            (r.origin.x + (w.start - info.start) * r.scale, r.origin.x + (w.end - info.start) * r.scale, w.text)
        }
    }

    /// A glyph that draws something: not an adjustment, not a space (a glyph with no text may be a leader's dot).
    static func inkedItem(_ item: RunItem) -> Bool {
        !item.isNumber && (item.units.isEmpty || !trimmed(String(decoding: item.units, as: UTF16.self)).isEmpty)
    }

    /// An operator's words as its items place them (text space): split where the ink is apart by more than a kern.
    private static func words(_ items: [RunItem], _ em: Double) -> [(first: Int, start: Double, end: Double, text: String)] {
        var out: [(first: Int, start: Double, end: Double, text: String)] = []
        var first = -1, last = -1
        var i = 0
        while i <= items.count {
            defer { i += 1 }
            if i < items.count && !inkedItem(items[i]) { continue }
            if last >= 0 && (i == items.count || items[i].at - items[last].inkEnd > wordGapEms * em) {
                var units: [UInt16] = []
                for k in first...last { units += items[k].units }
                out.append((first, items[first].at, items[last].inkEnd, String(decoding: units, as: UTF16.self)))
                first = -1
            }
            if i == items.count { break }
            if first < 0 { first = i }
            last = i
        }
        return out
    }

    /// Where an operator that draws columns (a table row's label and its figures set apart by TJ adjustments, as pdfTeX
    /// and the census's tables write them) has each start: the item each column's first glyph is, the first column at 0.
    /// Columns are told apart as `splitAtColumns` tells runs apart (`columnGap`); nil when it has one.
    static func columnStarts(_ items: [RunItem], _ size: Double) -> [Int]? {
        let em = abs(size)
        if items.count < 3 || !(em > 1e-9) || !em.isFinite { return nil }
        let ws = words(items, em)
        if ws.count < 2 { return nil }
        let wordGap = wordSpacing(ws.map { ($0.start, $0.end, $0.text) }, em)
        // Cut at each gap wide enough to be one; joined back where it isn't, with what is on each side then.
        var cuts: [Int] = []
        let cutAt: Double = min(columnGapEms * em, max(figureGapEms * em, wordGapsToColumn * (wordGap ?? 0)))
        for k in 1..<ws.count where ws[k].start - ws[k - 1].end > cutAt {
            cuts.append(k)
            if cuts.count > maxColumnsInRun { return nil }
        }
        if cuts.isEmpty { return nil }
        func textOf(_ from: Int, _ to: Int) -> String { ws[from..<to].map(\.text).joined() }
        var starts = [0]
        var column = 0 // the first word of the column being made
        for (c, k) in cuts.enumerated() {
            let next = c + 1 < cuts.count ? cuts[c + 1] : ws.count
            if !columnGap(ws[k].start - ws[k - 1].end, em, wordGap, textOf(column, k), textOf(k, next)) { continue }
            starts.append(ws[k].first)
            column = k
        }
        return starts.count < 2 ? nil : starts
    }

    /// A column of an operator kept as it was, drawn from where the column before it left the text position: what the
    /// operator does first (' and " go to the next line, " sets the spacing) with the first column, then its glyphs and
    /// adjustments.
    private static func kept(_ op: COp, _ column: TextRun) -> String {
        let info = column.info!
        var sb = nextLine(op, column) + "["
        var codes: [Int] = []
        func flush() {
            if codes.isEmpty { return }
            let bytes = column.font!.toBytes(codes)
            sb += (info.hex ? ContentLexer.hexString(bytes) : ContentLexer.literal(bytes)) + " "
            codes.removeAll()
        }
        for item in info.items {
            if !item.isNumber {
                codes.append(item.code)
            } else {
                flush()
                sb += ContentLexer.number(item.number) + " "
            }
        }
        flush()
        return sb + "] TJ"
    }

    /// A short "line" that sits on another (a raised footnote mark, a symbol in another font) goes into that line, in its
    /// place from left to right.
    private static func withMarksInLine(_ lines: [PLine]) -> [PLine] {
        let byBaseline = lines.enumerated().sorted { ($0.element.baseline, $0.offset) < ($1.element.baseline, $1.offset) }.map(\.element)
        var removed = Set<ObjectIdentifier>()
        var joined: [(host: PLine, marks: [PLine])] = []
        for (i, mark) in byBaseline.enumerated() {
            if trimmed(mark.string).utf16.count > 4 { continue }
            let reach = 1.2 * max(mark.size, 1)
            var host: PLine?
            func consider(_ m: PLine) {
                if m === mark || trimmed(m.string).utf16.count <= 4 || m.size < mark.size { return }
                if mark.box.centerY <= m.box.y || mark.box.centerY >= m.box.bottom { return }
                if mark.box.right <= m.box.x || mark.box.x >= m.box.right + 0.5 * m.size { return }
                if host == nil { host = m }
            }
            var k = i - 1
            while k >= 0 && mark.baseline - byBaseline[k].baseline <= reach * 2 {
                consider(byBaseline[k])
                k -= 1
            }
            k = i + 1
            while k < byBaseline.count && byBaseline[k].baseline - mark.baseline <= reach * 2 {
                consider(byBaseline[k])
                k += 1
            }
            guard let host else { continue }
            if let at = joined.firstIndex(where: { $0.host === host }) {
                joined[at].marks.append(mark)
            } else {
                joined.append((host, [mark]))
            }
            removed.insert(ObjectIdentifier(mark))
        }
        if joined.isEmpty { return lines }
        var replaced: [ObjectIdentifier: PLine] = [:]
        for (host, marks) in joined {
            let runs = (host.runs + marks.flatMap(\.runs)).enumerated().sorted { ($0.element.box.x, $0.offset) < ($1.element.box.x, $1.offset) }.map(\.element)
            let line = PLine(runs[0])
            for r in runs.dropFirst() { line.add(r) }
            line.baseline = host.baseline
            replaced[ObjectIdentifier(host)] = line
            removed.remove(ObjectIdentifier(host))
        }
        var result: [PLine] = []
        for l in lines {
            if let r = replaced[ObjectIdentifier(l)] {
                result.append(r)
            } else if !removed.contains(ObjectIdentifier(l)) {
                result.append(l)
            }
        }
        return result
    }

    /// A bullet or dash in front of a line, its own piece of text, isn't translated or moved: the line starts after it.
    /// An opening bracket or quote drawn on its own (pdfTeX's "(" before an italic "i.e.") is the sentence's, not a bullet.
    private static func withoutMarkers(_ lines: [PLine]) -> [PLine] {
        lines.map { l in
            guard l.runs.count > 1 else { return l }
            let first = l.runs[0]
            let t = trimmed(first.text)
            // Or a note's number, smaller than what follows: read as the line's size, the line would fall out of its paragraph.
            let note = t.utf16.count <= 3 && first.fontSize < 0.85 * l.runs[1].fontSize
            let marker = (1...2).contains(t.utf16.count) && !t.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                && !t.unicodeScalars.contains(where: opens)
            guard note || marker else { return l }
            let line = PLine(l.runs[1])
            for r in l.runs.dropFirst(2) { line.add(r) }
            return line
        }
    }

    /// An opening bracket or quote: "(", "[", "{", "“", "‘", "«", and the straight quotes.
    private static func opens(_ c: Unicode.Scalar) -> Bool {
        c == "\"" || c == "'" || c.properties.generalCategory == .openPunctuation || c.properties.generalCategory == .initialPunctuation
    }

    // ---- The room a paragraph has ----

    /// What a page's new text must keep clear of, and how far its upright text reaches across.
    final class PageThings {
        var boxes: [(box: RectD, run: Int?)] = [] // the run's key; nil: a picture or obstacle
        var textLeft = Double.greatestFiniteMagnitude, textRight = -Double.greatestFiniteMagnitude
        /// A page too crowded to look around each paragraph on its lines: it stays as wide as it was.
        var crowded: Bool { boxes.count > 5_000 }

        init(_ content: PageContent, _ obstacles: [RectD]) {
            for r in content.runs {
                if trimmed(r.text).isEmpty { continue }
                if abs(r.angle) < 0.5 {
                    textLeft = min(textLeft, r.box.x)
                    textRight = max(textRight, r.box.right)
                }
                // Text of another direction (a margin's turned stamp; in a turned frame, the page's other text, NaN or
                // turned there): in the way where it is drawn, not where the text column ends.
                boxes.append((r.box, r.key))
            }
            for i in content.images { boxes.append((i.box, nil)) }
            for o in obstacles { boxes.append((o, nil)) }
            boxes = boxes.enumerated().sorted { ($0.element.box.y, $0.offset) < ($1.element.box.y, $1.offset) }.map(\.element)
            if textLeft > textRight { (textLeft, textRight) = (0, 0) }
        }

        /// The first box that starts at or below `y`.
        func firstBelow(_ y: Double) -> Int {
            var lo = 0, hi = boxes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if boxes[mid].box.y < y { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    /// A paragraph as it will be written: the edges its lines stay between, its alignment as the page shows it (a single
    /// line can't tell, so its place on the page or in its cell does), and how far down it may go. `fills`: rectangles the
    /// page fills, with their place in its content (one filled after the paragraph is drawn would paint over text that
    /// grows into it); `paints`: everything the page's own content paints, in order (nil: not known; what the text sits on
    /// is the last before it). Returns the paragraph framed, how far down it may go, for a centered one with more room on
    /// one side the room it may move into (nil: none), and how far down it may go there.
    static func room(_ slot: TranslationSlot, _ page: PageThings, _ obstacles: [RectD], _ pageWidth: Double, _ pageHeight: Double,
                     _ fills: [(box: RectD, id: Int)] = [], _ paints: [Paint]? = nil) -> (framed: TextParagraph, bottom: Double, wide: TextParagraph?, wideBottom: Double) {
        let p = slot.paragraph
        var framed = p
        var wide: TextParagraph?
        let mine = Set(p.runs.map(\.key))
        let pageArea: Double = pageWidth * pageHeight

        // A panel the text sits in (a shaded box, a callout) holds it unless it is about the whole page.
        var panel = obstacles.filter { o in
            o.width * o.height < 0.8 * pageArea && o.contains(p.box.centerX, p.box.centerY) && o.contains(p.box.x + 0.5, p.box.y + 0.5)
                && o.contains(p.box.right - 0.5, p.box.bottom - 0.5)
        }.min { $0.width * $0.height < $1.width * $1.height }

        // Light text sits on something dark: past its box it would be white on white, unless that is a dark band the page
        // filled right under it (NIST's headings), which then holds it as a panel does.
        var light = slot.cell == nil && luma(p.lead.color) > 0.85 * 255
        if light, let band = lightsBand(p, paints, pageWidth, pageHeight) {
            panel = band
            light = false
        }
        let holder = slot.cell ?? panel

        if (p.lines.count == 1 || slot.cell != nil) && !page.crowded && !light {
            // Across: to the next thing on its line, inside what holds it. Its text column on the page is what the page's
            // other text reaches.
            var reachLeft = holder?.x ?? min(p.left, page.textLeft)
            // To the right margin: as far as the page's text goes, or the left margin mirrored when no text on it is that long.
            var reachRight = holder?.right ?? max(p.right, min(pageWidth - 18, max(page.textRight, pageWidth - page.textLeft)))
            for (b, run) in page.boxes {
                if b.y >= p.box.bottom { break }
                if b.bottom <= p.box.y { continue } // not on its lines
                if let run, mine.contains(run) { continue }
                if b.width > 0.8 * (reachRight - reachLeft) && b.x < p.box.x && b.right > p.box.right { continue } // behind it
                // Text beside it may grow toward it too: each gets half the gap.
                if b.x >= p.box.right - 1 && b.x < reachRight { reachRight = b.x - max(0.5 * p.fontSize, run == nil ? 0 : (b.x - p.box.right) / 2) }
                if b.right <= p.box.x + 1 && b.right > reachLeft { reachLeft = b.right + max(0.5 * p.fontSize, run == nil ? 0 : (p.box.x - b.right) / 2) }
            }
            reachRight = max(reachRight, p.right)
            reachLeft = min(reachLeft, p.left)
            if holder != nil {
                reachLeft = min(p.left, reachLeft + 1.5)
                reachRight = max(p.right, reachRight - 1.5)
            }
            let tol = max(2, 0.2 * p.fontSize)
            let off = max(20, 2 * p.fontSize)
            var align = p.align
            if p.lines.count == 1 {
                // What it could be centered on or end at: what holds it; else the page's text or the page itself.
                let (left, right) = holder.map { ($0.x, $0.right) } ?? (page.textLeft, page.textRight)
                let centered = abs(p.box.centerX - (left + right) / 2) <= tol || (holder == nil && abs(p.box.centerX - pageWidth / 2) <= tol)
                let ended = abs(p.box.right - right) <= tol || (holder == nil && abs(p.box.right - (pageWidth - page.textLeft)) <= tol)
                if centered && p.box.x - left > (holder == nil ? off : 2) {
                    align = .center
                } else if ended && p.box.x - left > off {
                    align = .right
                }
            }
            framed.align = align
            switch align {
            case .center:
                let half = min(p.box.centerX - reachLeft, reachRight - p.box.centerX)
                framed.left = p.box.centerX - half
                framed.right = p.box.centerX + half
                framed.center = p.box.centerX
                // More room on one side than the other: what it may move into rather than shrink (fitText).
                if reachRight - reachLeft > 2 * half + 1 {
                    var w = framed
                    w.left = reachLeft
                    w.right = reachRight
                    w.center = p.box.centerX
                    wide = w
                }
            case .right:
                framed.left = reachLeft
                framed.right = p.right
            default:
                framed.left = p.left
                framed.right = reachRight
            }
        }

        // Down: to the next thing below it across its width, and no lower than what holds it or the page's foot.
        func down(_ f: TextParagraph) -> Double {
            var bottom = light ? p.box.bottom : slot.cell?.bottom ?? panel?.bottom ?? max(p.box.bottom, pageHeight - 36)
            var i = page.firstBelow(p.box.bottom - 1)
            while i < page.boxes.count {
                let (b, run) = page.boxes[i]
                i += 1
                if b.y >= bottom { break } // sorted: nothing later comes nearer
                if b.right <= f.left + 1 || b.x >= f.right - 1 { continue }
                if let run, mine.contains(run) { continue }
                // Some of the gap the page left stays, so a paragraph doesn't read as part of the next.
                bottom = b.y - max(0.1 * p.fontSize, min(b.y - p.box.bottom, 0.35 * p.fontSize))
                break
            }
            // Filled after this paragraph is written: a band under some later line reaches across, even where no text is.
            if !fills.isEmpty && p.runs.allSatisfy({ $0.info?.form == nil }) {
                let last = p.runs.map(drawOrder).max() ?? 0
                for (box, id) in fills where id > last && box.y >= p.box.bottom - 1 && box.y < bottom && box.right > f.left + 1 && box.x < f.right - 1 {
                    bottom = box.y
                }
            }
            return max(bottom, p.box.bottom)
        }
        var bottom = down(framed)
        // Moved into the wider room, it goes only as low as that room allows: text under it there is overdrawn otherwise.
        var wideBottom = wide.map { min(bottom, down($0)) } ?? bottom
        // What the page clips to hides whatever goes past it: new text stays inside, or is flagged. Each line is written
        // where one of the old lines was drawn, so what counts is what they clip to together.
        let drawnAt = lineRuns(p, plainRun(p.runs))
        // Lines below the old ones are written with the last: whatever clips that clips them, whatever the others do.
        if let lowest = drawnAt.last?.info?.clip {
            bottom = min(bottom, max(lowest.bottom, p.box.bottom))
            wideBottom = min(wideBottom, bottom)
        }
        let clips = drawnAt.compactMap { $0.info?.clip }
        if !clips.isEmpty && clips.count == drawnAt.count {
            let clip = clips.dropFirst().reduce(clips[0]) { $0.union($1) }
            bottom = min(bottom, max(clip.bottom, p.box.bottom)) // a font's descent may reach past a tight clip: its own text was shown there
            wideBottom = min(wideBottom, bottom)
            func inClip(_ f: inout TextParagraph) {
                f.right = max(min(f.right, clip.right), min(p.right, f.right))
                f.left = min(max(f.left, clip.x), max(p.left, f.left))
            }
            inClip(&framed)
            if wide != nil { inClip(&wide!) }
        }
        return (framed, bottom, wide, wideBottom)
    }

    /// How light a color looks, 0 to 255.
    private static func luma(_ color: Int) -> Double {
        let r = Double(color >> 16 & 0xFF), g = Double(color >> 8 & 0xFF), b = Double(color & 0xFF)
        return 0.3 * r + 0.59 * g + 0.11 * b
    }

    /// The band light text sits on: the last thing the page's own content painted where the paragraph is, before it, when
    /// that is a rectangle filled in a dark color under all of it (a font's box may reach a little past a tight band), not
    /// about the whole page; nil when it is anything else (a picture, a stroke, a light card), not known, or the paragraph
    /// is in a form.
    private static func lightsBand(_ p: TextParagraph, _ paints: [Paint]?, _ pageWidth: Double, _ pageHeight: Double) -> RectD? {
        guard let paints, !paints.isEmpty, !p.runs.contains(where: { $0.info?.form != nil }) else { return nil }
        let first = p.runs.map(drawOrder).min() ?? 0
        let tol = 0.25 * p.fontSize
        let under = RectD.fromEdges(p.box.x, p.box.y + tol, p.box.right, p.box.bottom - tol)
        var top: Paint?
        for paint in paints {
            if paint.id >= first { break } // in the order they are painted
            if let b = paint.box {
                if b.x < under.right && b.right > under.x && b.y < under.bottom && b.bottom > under.y { top = paint }
            } else {
                top = paint
            }
        }
        guard let top, top.rect, let f = top.box, let color = top.color, luma(color) < 0.5 * 255, f.width * f.height < 0.8 * pageWidth * pageHeight else { return nil }
        let covers = f.x <= p.box.x + 0.5 && f.right >= p.box.right - 0.5 && f.y <= p.box.y + tol && f.bottom >= p.box.bottom - tol
        return covers ? f : nil
    }

    /// The new text laid out at the largest size that fits its room (steps of 5%); at the smallest allowed when none does.
    /// Characters no font here has are left out and named. At each size, a centered paragraph that doesn't fit centered
    /// in its room may move off center into `wide` (`room`), just as far as it must, and as low as `wideBottom`. `most`:
    /// the largest size tried, of its own (`oneSizePerColumn`); `spans`: the text's looks (bold, italic, sub and
    /// superscripts its answer's markup gave it).
    static func fitText(_ framed: TextParagraph, _ bottom: Double, _ text: String, wide: TextParagraph? = nil, wideBottom: Double = .nan,
                        most: Double = 1, spans: [TextSpan] = []) -> (layout: ParagraphLayout, fit: Double, fits: Bool, dropped: [String]) {
        let wideBottom = wideBottom.isNaN ? bottom : wideBottom
        func inside(_ l: ParagraphLayout, _ f: TextParagraph, _ bottom: Double) -> Bool {
            let box = l.check.box
            return box.bottom <= bottom + 0.5 && box.right <= max(f.right, f.box.right) + 1 && box.x >= min(f.left, f.box.x) - 1
        }
        var text = text
        var spans = spans
        // Laid out in the wide room's width, centered where it was, then moved back inside it. Moving it doesn't change its
        // lines, so a layout too tall or too wide for the room isn't laid out again (nil: it doesn't fit there).
        func moved(_ f: TextParagraph, _ size: Double) -> ParagraphLayout? {
            let l = layOut(f, f.runs, text, spans, fit: size)
            let box = l.check.box
            let span: Double = max(f.right, f.box.right) - min(f.left, f.box.x) + 2
            if box.bottom > wideBottom + 0.5 || box.width > span { return nil }
            let shift = box.right > f.right ? f.right - box.right : box.x < f.left ? f.left - box.x : 0
            if abs(shift) < 0.01 || !shift.isFinite { return l }
            var m = f
            m.center = f.center + shift
            return layOut(m, m.runs, text, spans, fit: size)
        }
        var dropped: [String] = []
        let smallest = smallestFit(framed.lead.fontSize) // of the size it is written in: its first run may be a mark or a big initial
        var fit = most > 0 && most < 1 ? max(smallest, most) : 1.0
        var tries = 0
        while true {
            if Double(tries) > 2 / fitStep { fit = smallest } // whatever a crafted page's numbers make of the steps below
            var best = layOut(framed, framed.runs, text, spans, fit: fit)
            if !best.check.missing.isEmpty {
                dropped += best.check.missing
                (text, spans) = without(text, spans, best.check.missing)
                if text.isEmpty { return (best, 1, false, dropped) }
                best = layOut(framed, framed.runs, text, spans, fit: fit)
                if !best.check.missing.isEmpty { return (best, 1, false, dropped) }
            }
            let box = best.check.box
            if inside(best, framed, bottom) { return (best, fit, true, dropped) }
            // Only when it wraps or runs past its room: one line that is only too tall is as tall in the wider room.
            let spills = best.lines.count > 1 || box.right > max(framed.right, framed.box.right) + 1 || box.x < min(framed.left, framed.box.x) - 1
            if let wide, spills, let off = moved(wide, fit), inside(off, wide, wideBottom) { return (off, fit, true, dropped) }
            if fit <= smallest || Double(tries) > 2 / fitStep { return (best, fit, false, dropped) }
            // Far too tall: text takes room with the square of its size, so jump near where it will fit.
            let ratio = (bottom - framed.box.y) / max(1, box.bottom - framed.box.y)
            if ratio.isFinite {
                let jump: Double = (max(ratio, 0.01).squareRoot() * fit / fitStep).rounded() * fitStep + 2 * fitStep
                fit = min(fit, jump)
            }
            tries += 1
            fit = max(smallest, fit - fitStep)
        }
    }

    /// Text with every one of `missing` left out and its spaces collapsed, its looks staying on the characters that stay.
    private static func without(_ text: String, _ spans: [TextSpan], _ missing: [String]) -> (String, [TextSpan]) {
        let u = Array(text.utf16)
        var keep = [Bool](repeating: true, count: u.count)
        let ns = text as NSString
        for m in missing where !m.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: m, options: .literal, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                for k in r.location..<(r.location + r.length) { keep[k] = false }
                from = r.location + r.length
            }
        }
        let looks = looksOf(u, spans)
        var out: [UInt16] = []
        var now: [TextLook?] = []
        for i in u.indices {
            if !keep[i] || (u[i] == 32 && (out.isEmpty || out.last == 32)) { continue }
            out.append(u[i])
            now.append(looks[i])
        }
        if out.last == 32 {
            out.removeLast()
            now.removeLast()
        }
        var result: [TextSpan] = []
        var i = 0
        while i < now.count {
            var j = i + 1
            while j < now.count && now[j] == now[i] { j += 1 }
            if let look = now[i], !look.isPlain { result.append(TextSpan(i, j - i, look)) }
            i = j
        }
        return (String(decoding: out, as: UTF16.self), result)
    }

    /// A paragraph's new text laid out in its room (`room`, `fitText`), before it is written.
    struct Laid {
        var text: String
        var spans: [TextSpan]
        var framed: TextParagraph
        var bottom: Double
        var wide: TextParagraph?
        var wideBottom: Double
        var layout: ParagraphLayout
        var fit: Double
        var fits: Bool
        var dropped: [String]
    }

    /// A column's body text shrinks no further than this (of its size) to take the size another of its paragraphs needs.
    private static let columnFloor = 0.8

    /// Body text in one column comes out in one size: its paragraphs (two lines or more, not in a table cell, in the same
    /// font, size and color, starting at the same left edge) all take the size the one that shrank most needs, but no
    /// smaller than `columnFloor`; one that needs less keeps its own. A paragraph that fits nowhere (written at the
    /// smallest size and flagged) sets no size for the rest; one that wouldn't fit at the column's size keeps its own.
    private static func oneSizePerColumn(_ slots: [TranslationSlot], _ laid: inout [Laid?], _ cancel: CancelToken?) throws {
        // Grouped by the text's look, then by left edge: no paragraph is compared with every other.
        struct Look: Hashable {
            var size: Double, color: Int, family: String
        }
        var looks: [Look: [Int]] = [:]
        var order: [Look] = []
        for (i, s) in slots.enumerated() {
            let p = s.paragraph
            if laid[i] == nil || s.cell != nil || p.lines.count < 2 || p.upright != nil { continue }
            let lead = p.lead
            if !p.left.isFinite || !(lead.fontSize > 0) || !lead.fontSize.isFinite { continue }
            let key = Look(size: (lead.fontSize * 20).rounded(), color: lead.color, family: FontNames.family(lead.fontName))
            if looks[key] == nil { order.append(key) }
            looks[key, default: []].append(i)
        }
        func oneSize(_ column: [Int]) {
            let fitting = column.filter { laid[$0]!.fits }
            if column.count < 2 || fitting.isEmpty { return }
            let size = max(columnFloor, fitting.map { laid[$0]!.fit }.min()!)
            for i in fitting {
                let was = laid[i]!
                if was.fit <= size + 1e-6 { continue }
                let (layout, fit, fits, dropped) = fitText(was.framed, was.bottom, was.text, wide: was.wide, wideBottom: was.wideBottom, most: size, spans: was.spans)
                if fits && fit >= size - 1e-6 && layout.check.missing.isEmpty && !layout.lines.isEmpty {
                    var now = was
                    now.layout = layout
                    now.fit = fit
                    now.fits = true
                    now.dropped = dropped
                    laid[i] = now
                }
            }
        }
        for key in order {
            // A column: left edges each within 3 pt of the one before, from left to right (73.4 and 73.6 pt are one).
            let look = looks[key]!.enumerated().sorted { (slots[$0.element].paragraph.left, $0.offset) < (slots[$1.element].paragraph.left, $1.offset) }.map(\.element)
            var from = 0
            while from < look.count {
                var to = from + 1
                while to < look.count && slots[look[to]].paragraph.left - slots[look[to - 1]].paragraph.left <= 3 { to += 1 }
                try cancel?.check()
                oneSize(Array(look[from..<to]))
                from = to
            }
        }
    }

    // ---- Right to left ----

    /// Whether most of the text's letters read right to left (the paragraph then does).
    static func mostlyRightToLeft(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for cp in text.unicodeScalars {
            switch Bidi.classify(cp.value) {
            case .R, .AL: rtl += 1
            case .L: ltr += 1
            default: break
            }
        }
        return rtl > ltr
    }

    /// The UTF-16 offsets where `s`'s text elements (a character with its marks, a surrogate pair) start.
    private static func elementStarts(_ s: [UInt16]) -> [Int] {
        var starts: [Int] = []
        var at = 0
        for ch in String(decoding: s, as: UTF16.self) {
            starts.append(at)
            at += ch.utf16.count
        }
        return starts
    }

    /// Right-to-left text in an installed font: words go on a line as long as it fits, each line shaped whole so its words
    /// come out in reading order, and it sits against the box's right edge (or its center, if centered).
    static func layOutRightToLeft(_ p: TextParagraph, _ m: TextRun, _ text: String, _ shrink: Double) -> ParagraphLayout {
        var cps: [UInt32] = []
        for c in text.unicodeScalars where c.value > 32 && !cps.contains(c.value) { cps.append(c.value) }
        let ranked = StandInFonts.rankFor(m.font!).first { f in cps.allSatisfy { f.font.drawsOutline($0) } }
        let primary = ranked?.font
        var missing: [String] = []
        for c in text.unicodeScalars where c.value > 32 {
            let drawn = primary?.drawsOutline(c.value) == true || SystemFonts.forCodePoint(c.value, primary).map { $0.drawsOutline(c.value) } == true
            if !drawn && !missing.contains(String(c)) { missing.append(String(c)) }
        }
        if !missing.isEmpty {
            return ParagraphLayout(lines: [], check: ParagraphCheck(box: p.box, lineCount: p.lines.count, missing: missing, overlaps: nil), fonts: [])
        }
        func w(_ line: [UInt16]) -> Double { TextShaper.measure(String(decoding: line, as: UTF16.self), primary) * m.size * m.hScale * m.scale }
        // A word with no spaces can be the whole answer: longer than any line, it isn't measured whole for every line it breaks into.
        let longest = 1024
        var lines: [[UInt16]] = []
        var cur: [UInt16] = []
        let avail = p.right - p.left
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map({ Array($0.utf16) }) {
            let joined = cur.isEmpty ? word : cur + [32] + word
            if w(joined) <= avail + 0.01 {
                cur = joined
                continue
            }
            if !cur.isEmpty { lines.append(cur) }
            cur = word
            while cur.count > 1 && (cur.count > longest || w(cur) > avail + 0.01) {
                // A word wider than the line is broken: as much of it as fits.
                let els = elementStarts(cur.count > longest ? Array(cur[0..<longest]) : cur)
                var n = els.count - 1
                while n > 1 && w(Array(cur[0..<els[n]])) > avail + 0.01 { n = n * 3 / 4 }
                if n < 1 || els[n] == 0 { break }
                lines.append(Array(cur[0..<els[n]]))
                cur = Array(cur[els[n]...])
            }
        }
        if !cur.isEmpty { lines.append(cur) }

        var placed: [(origin: PointD, parts: [Part])] = []
        var names: [String] = []
        var baseline = p.box.y + p.ascent * shrink
        var minLeft = p.box.x, maxRight = p.box.right
        for line in lines {
            let shaped = TextShaper.shape(String(decoding: line, as: UTF16.self), primary)
            for g in shaped.glyphs {
                let known = g.font === primary ? ranked!.name : g.font.family
                if !names.contains(known) { names.append(known) }
            }
            let width: Double = shaped.width * m.size * m.hScale * m.scale
            let x = p.align == .center ? p.center - width / 2 : p.right - width
            placed.append((PointD(x, baseline), [Part(nil, 0, shaped)]))
            minLeft = min(minLeft, x)
            maxRight = max(maxRight, x + width)
            baseline += p.lineStep * shrink
        }
        let bottom = baseline - p.lineStep * shrink + p.descent * shrink
        var check = ParagraphCheck(box: .fromEdges(minLeft, p.box.y, maxRight, max(bottom, p.box.y + 1)), lineCount: placed.count, missing: [], overlaps: nil)
        check.standIns = names
        return ParagraphLayout(lines: placed, check: check, fonts: [])
    }

    // ---- Wrapping ----

    /// Words on lines as wide as the paragraph's box: between words; in Chinese and Japanese between any two characters
    /// (not before closing punctuation or after opening punctuation); and a word wider than the whole line between its
    /// characters, so nothing runs off the box's edge.
    static func fitLines(_ p: TextParagraph, _ enc: MixedText, _ text: [UInt16], _ width: ([Part]) -> Double) -> [(parts: [Part], spaces: [Int], last: Bool)] {
        var lines: [(parts: [Part], spaces: [Int], last: Bool)] = []
        var cur: [Part] = []
        var ends: [Int] = []
        func avail() -> Double { p.right - p.left - (lines.isEmpty ? p.firstIndent : 0) }
        func lineBreak() {
            lines.append((cur, ends, false))
            cur = []
            ends = []
        }
        for (start, end, spaced) in fitTokens(text) {
            let parts = enc.encode(start, end)
            let space = spaced && !cur.isEmpty ? enc.encode(start - 1, start) : nil
            let joined = cur.isEmpty ? parts : cur + (space ?? []) + parts
            if width(joined) <= avail() + 0.01 {
                if let space, !cur.isEmpty { ends.append(cur.count + space.count - 1) }
                cur = joined
                continue
            }
            if !cur.isEmpty { lineBreak() }
            if width(parts) <= avail() + 0.01 {
                cur = parts
                continue
            }
            // Too wide for a line of its own: broken between its characters.
            var chunk = start
            let els = elementStarts(Array(text[start..<end]))
            for e in 1..<max(1, els.count) {
                let to = e + 1 < els.count ? start + els[e + 1] : end
                if width(enc.encode(chunk, to)) <= avail() + 0.01 { continue }
                cur = enc.encode(chunk, start + els[e])
                lineBreak()
                chunk = start + els[e]
            }
            cur = enc.encode(chunk, end)
        }
        lines.append((cur, ends, true))
        if lines.count == 1 && lines[0].parts.isEmpty { lines.removeAll() }
        return lines
    }

    private static let noBreakBefore = Set("、。，．・：；？！）〕］｝〉》」』】…ーゝゞ々ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ.,;:!?)]}%".utf16)
    private static let noBreakAfter = Set("（〔［｛〈《「『【([{".utf16)

    private static func isWhiteUnit(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isWhitespace ?? false }

    /// Where a line may break (UTF-16): stretches of text, whether a space comes before each. Runs of spaces count as one.
    static func fitTokens(_ text: [UInt16]) -> [(start: Int, end: Int, spaced: Bool)] {
        var out: [(start: Int, end: Int, spaced: Bool)] = []
        var spaced = false
        var i = 0
        func step(_ i: Int) -> Int { UTF16.isLeadSurrogate(text[i]) && i + 1 < text.count ? 2 : 1 }
        while i < text.count {
            if isWhiteUnit(text[i]) {
                spaced = true
                i += 1
                continue
            }
            let start = i
            var ideographs = isIdeograph(text, i)
            i += step(i)
            while i < text.count && !isWhiteUnit(text[i]) {
                // A break between two characters when either is an ideograph, unless punctuation holds them together.
                let next = isIdeograph(text, i)
                if (ideographs || next) && !noBreakBefore.contains(text[i]) && !noBreakAfter.contains(text[i - 1]) { break }
                ideographs = next
                i += step(i)
            }
            out.append((start, i, spaced))
            spaced = false
        }
        return out
    }

    private static func isIdeograph(_ text: [UInt16], _ i: Int) -> Bool {
        let u = text[i]
        var cp = UInt32(u)
        if UTF16.isLeadSurrogate(u), i + 1 < text.count, UTF16.isTrailSurrogate(text[i + 1]) {
            cp = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(text[i + 1]) - 0xDC00)
        }
        let cjk = (0x2E80...0x9FFF).contains(cp) || (0xF900...0xFAFF).contains(cp) || (0x20000...0x3FFFF).contains(cp)
        return cjk && !(0x3000...0x303F).contains(cp)
    }

    // ---- Where each new line is drawn ----

    /// A run's place in the order its content draws things (page operators by index; a form's in the order the walk met them).
    static func drawOrder(_ run: TextRun) -> Int { order(run.id) }

    /// For each of a paragraph's old lines, the run a new line there is written at: its last one in the paragraph's color
    /// (what the line draws last has nothing of the line painted over it); a line with none takes the one above's.
    static func lineRuns(_ p: TextParagraph, _ plain: TextRun) -> [TextRun] {
        // New text takes the color of the run it is written at: the color most of the paragraph is in, not a link's.
        var byColor: [(color: Int, chars: Int)] = []
        for r in p.runs where r.info != nil {
            let n = trimmed(r.text).utf16.count
            if let i = byColor.firstIndex(where: { $0.color == r.color }) { byColor[i].chars += n } else { byColor.append((r.color, n)) }
        }
        let color = byColor.max { $0.chars < $1.chars }?.color ?? plain.color
        var chosen = [TextRun?](repeating: nil, count: p.lines.count)
        for run in p.runs {
            var at = 0
            for k in 1..<max(1, p.lines.count) where abs(run.box.centerY - p.lines[k].centerY) < abs(run.box.centerY - p.lines[at].centerY) { at = k }
            if run.color == color && run.info != nil && (chosen[at].map { drawOrder(run) > drawOrder($0) } ?? true) { chosen[at] = run }
        }
        var fallback = chosen.compactMap { $0 }.first ?? anchorRun(p.runs)
        return chosen.map { c in
            fallback = c ?? fallback
            return fallback
        }
    }

    /// Which run each new line is written at (by the run's key). A page may paint under each line as it comes (a white
    /// band for every line, as Word and Acrobat exports do) or clip to it, so a new line goes where the lowest old line it
    /// reaches was drawn: with everything painted for it already down, and nothing later over it. Lines below the old
    /// ones go with the last.
    static func linesToRuns(_ p: TextParagraph, _ oldLines: [TextRun], _ layout: ParagraphLayout, _ fit: Double) -> [Int: (run: TextRun, lines: [(origin: PointD, parts: [Part])])] {
        var result: [Int: (run: TextRun, lines: [(origin: PointD, parts: [Part])])] = [:]
        for line in layout.lines {
            let bottom = line.origin.y + p.descent * fit
            var at = 0
            for k in 1..<max(1, oldLines.count) where p.lines[k].y < bottom - 1 { at = k }
            var run = oldLines[at]
            // Clipped to a rectangle this line isn't in: to one it is in.
            if let clip = run.info?.clip, line.origin.y <= clip.y || line.origin.y >= clip.bottom,
               let inside = oldLines.first(where: { r in r.info?.clip.map { line.origin.y > $0.y && line.origin.y < $0.bottom } ?? false }) {
                run = inside
            }
            result[run.key, default: (run, [])].lines.append(line)
        }
        return result
    }

    /// New lines written at a run that may not be in the paragraph's own state: its spacing and horizontal scale are set
    /// for them, and its size made up for when the run's text matrix scales differently, so they come out as they were
    /// laid out.
    private static func writeLinesAt(_ frame: PageFrame, _ op: COp, _ run: TextRun, _ plain: TextRun, _ layout: ParagraphLayout,
                                     _ writer: Type3FontWriter) throws -> String {
        var face = plain
        if run.scale > 0 && plain.scale > 0 && abs(run.scale / plain.scale - 1) > 1e-6 { face.size = plain.size * plain.scale / run.scale }
        var before = "", after = ""
        if setsSpacing(op, run).isEmpty && abs(run.charSpacing - plain.charSpacing) > 1e-9 {
            before += ContentLexer.number(plain.charSpacing) + " Tc "
            after += " " + ContentLexer.number(run.charSpacing) + " Tc"
        }
        if abs(run.hScale - plain.hScale) > 1e-9 {
            before += ContentLexer.number(plain.hScale * 100) + " Tz "
            after += " " + ContentLexer.number(run.hScale * 100) + " Tz"
        }
        return before + (try writeParagraph(frame, op, run, face, layout, writer)) + after
    }

    // ---- Writing a page ----

    /// What a run over a whole document shares: one font writer (a face is embedded once, however many pages use it),
    /// which dictionaries need its fonts, which form XObjects more than one page can reach, and the links to move once
    /// the fonts are in.
    final class TranslationWriter {
        let doc: MuDoc
        let fonts: Type3FontWriter
        private var owners: [PObj] = []
        private var seen = Set<ObjId>()
        private var shared: Set<ObjId>?
        /// The installed fonts text was drawn in, as people know them.
        var fontNames: [String] = []
        private var links: [(page: Int, links: [LinkFix])] = []

        /// `unique` makes its fonts' resource names different from any earlier run's (a translated copy translated again).
        init(_ doc: MuDoc, _ unique: String) {
            self.doc = doc
            fonts = Type3FontWriter(namePrefix: "/\(standInKey)T\(unique)_", standIn: true)
        }

        func needsFonts(_ owner: PObj) {
            if seen.insert(owner.id).inserted { owners.append(owner) }
        }

        /// A page's links to move onto their words or drop, once its fonts are in the document (`fixLinks`).
        func linksAfter(_ page: Int, _ list: [LinkFix]) { links.append((page, list)) }

        /// The installed fonts drawn from go into the document and the resources of everything that uses them; then the
        /// translated paragraphs' links are moved or dropped (their new words can be read only once the fonts are there).
        func finish() {
            if !fonts.isEmpty {
                // Each font one object, the pages referring to it: a face is in the file once however many pages use it.
                let built = fonts.buildFonts(doc)
                let shared = doc.dict()
                for key in built.keys {
                    if let font = built[key] { shared.set(key, font.isRef ? font : doc.add(font)) }
                }
                for owner in owners { addFonts(doc, owner, shared) }
            }
            for (page, list) in links {
                // A page whose new content can't be read again keeps its links and their underlines as they were.
                try? fixLinks(doc, page, list)
            }
        }

        /// Forms reachable from more than one page's resources, found once: asking per form and per page would take page
        /// count squared.
        func isShared(_ place: FormPlace) -> Bool {
            if shared == nil {
                var both = Set<ObjId>()
                var once = Set<ObjId>()
                let count = (try? doc.pageCount()) ?? 0
                for i in 0..<count {
                    var onPage = Set<ObjId>()
                    func visit(_ xo: PObj?, _ depth: Int) {
                        guard let xo, depth <= maxDepth else { return }
                        for key in xo.keys {
                            guard let form = xo.dict(key), form.name("Subtype") == "Form", onPage.insert(form.id).inserted else { continue }
                            visit(form.dict("Resources")?.dict("XObject"), depth + 1)
                        }
                    }
                    visit(PageBoxes.inherited(doc.page(i), "Resources")?.dict("XObject"), 0)
                    for f in onPage where !once.insert(f).inserted { both.insert(f) }
                }
                shared = both
            }
            return place.chain.contains { shared!.contains($0.id) }
        }
    }

    /// Writes one page's translated paragraphs. `textOf` gives a paragraph's new text (nil: it stays as it is).
    /// Everything is worked out first and the page's content changes only at the end, so a page that fails partway stays
    /// as it was (the error goes to the caller). Turned text is laid out in its frame (`turnedParts`, with the cells
    /// `turnedCells` found there) and written turned back.
    static func translatePage(_ writer: TranslationWriter, _ pageIndex: Int, _ cells: [RectD], _ obstacles: [RectD],
                              _ textOf: (Int, TextParagraph) -> String?, _ cancel: CancelToken?, turnedCells: [Int: [RectD]] = [:])
        throws -> (slots: [TranslationSlot], written: [TranslationWritten], refused: [TranslationRefused]) {
        let doc = writer.doc
        let page = try pageOf(doc, pageIndex)
        let pageStreams = streams(page)
        let ops = try ContentLexer.parse(pageStreams.bytes, cancel: cancel)
        let walked = try walk(doc, page, pageIndex, ops, cancel, columns: true)
        let content = walked.content
        let frame = PageBoxes.frame(page)
        let (pageWidth, pageHeight) = displaySize(page)
        let turned = turnedParts(content, pageWidth, pageHeight, turnedCells)
        let slots = try translationSlots(content, cells, cancel, turned)
        var written: [TranslationWritten] = []
        var refused: [TranslationRefused] = []

        // The contents edited: the page's (0) and each drawing of a form that holds a paragraph.
        var targets = [Target(ops: ops, bytes: pageStreams.bytes, streams: pageStreams, form: nil, formObject: nil, resourceOwner: page,
                              resources: PageBoxes.inherited(page, "Resources").flatMap { $0.isDict ? $0 : nil })]
        var edits: [Edits] = [[]]
        var formTargets: [FormDraw: Int] = [:]
        var fonts: [(font: TextFont, codes: [Int], text: String)] = []
        var owners: [PObj] = []
        var taken = Set<[Int]>() // (target, operator start)
        let things = PageThings(content, obstacles)
        let paints = walked.paintsCut ? nil : walked.paints
        // A turned part's surroundings in its frame, worked out once it has a paragraph to lay out.
        var framedThings: [Int: (things: PageThings, obstacles: [RectD], fills: [(box: RectD, id: Int)], paints: [Paint]?)] = [:]
        // Where each upright paragraph's new text went, and how far it shrank, where its lines start: its links follow it.
        var placed: [Int: (box: RectD, fit: Double, lines: [PointD])] = [:]
        // Operators drawing columns, what each translated column of theirs became: written whole once the page is done,
        // each column as what became of it: new lines, nothing, or itself as it was.
        var columned: [[Int]: (target: Int, op: COp, id: Int, parts: [String?])] = [:]
        var columnedOrder: [[Int]] = []

        // Every paragraph laid out first: a column's then take one size (oneSizePerColumn) before any is written.
        var laid = [Laid?](repeating: nil, count: slots.count)
        for (i, slot) in slots.enumerated() {
            try cancel?.check()
            let p = slot.paragraph
            guard let answer = textOf(i, p), !answer.isEmpty else { continue }
            if let blocked = p.blocked {
                refused.append(TranslationRefused(slot: i, why: blocked))
                continue
            }
            // Its looks, as far as the answer's markup can be trusted; else it is plain, and no tag is left in it.
            let (text, spans) = TranslationMarkup.read(answer, p.text, p.spans)
            if text.isEmpty {
                refused.append(TranslationRefused(slot: i, why: loc("its answer was empty")))
                continue
            }
            if text.utf16.count > maxTextToLayOut {
                refused.append(TranslationRefused(slot: i, why: loc("its translation is far too long for any box")))
                continue
            }
            let r: (framed: TextParagraph, bottom: Double, wide: TextParagraph?, wideBottom: Double)
            if let part = slot.part, let upright = slot.upright {
                let turn = part.frame.turn
                if framedThings[turn] == nil {
                    let o = obstacles.map(part.frame.into)
                    let fills = walked.fills.map { (part.frame.into($0.box), $0.id) }
                    let framedPaints = paints?.map { x -> Paint in
                        var t = x
                        t.box = x.box.map(part.frame.into)
                        return t
                    }
                    framedThings[turn] = (PageThings(part.content, o), o, fills, framedPaints)
                }
                let f = framedThings[turn]!
                r = room(upright, f.things, f.obstacles, part.frame.width, part.frame.height, f.fills, f.paints)
            } else {
                r = room(slot, things, obstacles, pageWidth, pageHeight, walked.fills, paints)
            }
            let (layout, fit, fits, dropped) = fitText(r.framed, r.bottom, text, wide: r.wide, wideBottom: r.wideBottom, spans: spans)
            if !layout.check.missing.isEmpty || layout.lines.isEmpty {
                refused.append(TranslationRefused(slot: i, why: loc("no font on this Mac can draw it")))
                continue
            }
            laid[i] = Laid(text: text, spans: spans, framed: r.framed, bottom: r.bottom, wide: r.wide, wideBottom: r.wideBottom,
                           layout: layout, fit: fit, fits: fits, dropped: dropped)
        }
        try oneSizePerColumn(slots, &laid, cancel)

        for (i, slot) in slots.enumerated() {
            try cancel?.check()
            guard let done = laid[i] else { continue }
            let p = slot.paragraph
            let anchor = anchorRun(p.runs)
            var plain = plainRun(p.runs)
            // Turned text: which old line each new one goes at is told in its frame, where it was laid out.
            let newLines: [Int: (run: TextRun, lines: [(origin: PointD, parts: [Part])])]
            if let part = slot.part, let inFrame = slot.upright?.paragraph {
                newLines = onPage(linesToRuns(inFrame, lineRuns(inFrame, plainRun(inFrame.runs)), done.layout, done.fit), part)
            } else {
                newLines = linesToRuns(p, lineRuns(p, plain), done.layout, done.fit)
            }
            plain.size *= done.fit
            let t: Int
            if let draw = anchor.info!.form, let place = walked.formOf[anchor.id]?.place {
                if let known = formTargets[draw] {
                    t = known
                } else {
                    var form = place.form
                    if (walked.formUses[place.form.id] ?? 0) > 1 || writer.isShared(place) {
                        if place.outer != nil {
                            refused.append(TranslationRefused(slot: i, why: loc("it is inside a drawing that other pages share, drawn through another drawing")))
                            continue
                        }
                        let (copy, name) = copiedForm(doc, page, place)
                        let op = ops[place.doId]
                        edits[0].append((op.start, op.end, latin1Bytes("/\(name) Do")))
                        form = copy
                    }
                    var owner = page
                    if form.dict("Resources") != nil {
                        owner = form
                    } else {
                        var f = place.outer
                        while let o = f {
                            if o.form.dict("Resources") != nil {
                                owner = o.form
                                break
                            }
                            f = o.outer
                        }
                    }
                    targets.append(Target(ops: place.ops, bytes: place.bytes, streams: nil, form: place, formObject: form, resourceOwner: owner,
                                          resources: place.resources))
                    edits.append([])
                    t = targets.count - 1
                    formTargets[draw] = t
                }
            } else {
                t = 0
            }
            let target = targets[t]

            for run in p.runs {
                let op = target.opOf(run, walked)
                taken.insert([t, op.start])
                let now: String
                if let lines = newLines[run.key]?.lines {
                    var l = done.layout
                    l.lines = lines
                    now = try writeLinesAt(frame, op, run, plain, l, writer.fonts)
                } else {
                    now = removed(op, run)
                }
                let info = run.info!
                if info.columns == 1 {
                    edits[t].append((op.start, op.end, latin1Bytes(now)))
                } else {
                    let key = [t, op.start]
                    if columned[key] == nil {
                        columned[key] = (t, op, run.id, [String?](repeating: nil, count: info.columns))
                        columnedOrder.append(key)
                    }
                    columned[key]!.parts[info.column] = now
                }
            }
            // Spaces drawn on their own go too; one on the lines of two paragraphs only once.
            for run in p.spaces where run.info?.form == anchor.info!.form {
                let op = target.opOf(run, walked)
                if taken.insert([t, op.start]).inserted { edits[t].append((op.start, op.end, latin1Bytes(removed(op, run)))) }
            }
            fonts += done.layout.fonts
            owners.append(target.resourceOwner)
            for name in done.layout.check.standIns where !writer.fontNames.contains(name) { writer.fontNames.append(name) }
            written.append(TranslationWritten(slot: i, fit: done.fit, fits: done.fits, dropped: done.dropped))
            if slot.part == nil { placed[i] = (done.layout.check.box, done.fit, done.layout.lines.map(\.origin)) }
        }

        if !columned.isEmpty {
            // Each column leaves the text position where the next one starts, as the operator did.
            var columnsOf: [Int: [TextRun]] = [:]
            for r in content.runs where (r.info?.columns ?? 1) > 1 { columnsOf[r.id, default: []].append(r) }
            for key in columnedOrder {
                let c = columned[key]!
                let parts = (columnsOf[c.id] ?? []).sorted { $0.info!.column < $1.info!.column }.map { c.parts[$0.info!.column] ?? kept(c.op, $0) }
                edits[c.target].append((c.op.start, c.op.end, latin1Bytes(parts.joined(separator: " "))))
            }
        }
        // Links, and their underlines, are moved once the page and its fonts are written.
        let links = written.isEmpty ? [] : linksOfWritten(page, slots, written, placed, ops, paints)
        if written.isEmpty && edits[0].isEmpty { return (slots, written, refused) }
        for (font, codes, text) in fonts {
            if let dict = walked.fontDicts[ObjectIdentifier(font)] { font.prepare(doc, dict, codes, text) }
        }
        for k in 1..<max(1, targets.count) { try writeTarget(doc, page, targets[k], edits[k]) }
        if !edits[0].isEmpty { try writeTarget(doc, page, targets[0], edits[0]) }
        for owner in owners { writer.needsFonts(owner) }
        if !links.isEmpty { writer.linksAfter(pageIndex, links) }
        SignedEdits.noteRemoval()
        return (slots, written, refused)
    }

    /// A copy of a form the page draws directly, under a name of its own; the caller changes the Do.
    private static func copiedForm(_ doc: MuDoc, _ page: PObj, _ place: FormPlace) -> (copy: PObj, name: String) {
        let dict = doc.dict()
        for key in place.form.keys where !["Filter", "DecodeParms", "Length"].contains(key) {
            if let v = place.form[key] { dict.set(key, v) }
        }
        let copy = doc.addStream(place.bytes, dict: dict, deflate: true)
        return (copy, addXObject(doc, page, copy, prefix: "InkFm"))
    }

    /// A page's size as shown (its visible box turned by its /Rotate).
    static func displaySize(_ page: PObj) -> (width: Double, height: Double) {
        let s = PageBoxes.displaySize(page)
        return (s.w, s.h)
    }
}
