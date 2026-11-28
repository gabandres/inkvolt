import Foundation

/// A translated paragraph's plain underlines (roadmap 3.1; the Windows app's `ContentEditor.TranslateUnderlines`): a rule
/// the page draws under some of a line's words, no link's. The words it underlines go to the model as <u>
/// (`TranslationMarkup`); the copy takes the rule off the page and draws one, in its color, at its distance below the
/// baseline and its thickness (scaled with the text), under the words of the translation the answer's markup underlines.
extension ContentEditor {
    /// A rule under a line's words: its box (page as shown), its painting operator in the page's content, its color, and
    /// the runs it underlines (on that line, half of each at least over it).
    struct Underline: Sendable {
        var box: RectD
        var id: Int
        var color: Int
        var runs: [TextRun]
    }

    /// The most filled rectangles a page may have for its underlines to be looked for: more is a chart or a crafted page.
    private static let maxUnderlineCandidates = 4_000

    /// The most runs one rectangle is compared with (a crafted page's thousands of runs on one baseline).
    private static let maxRunsUnderOne = 256

    /// The most runs looked at on one rectangle's baseline band, and on all of a page's: past them, no more underlines are
    /// looked for.
    private static let maxRunsScannedForOne = 2_048, maxRunsScanned = 1_000_000

    /// How much of a rule the words above it must cover for it to be their underline, not a table's rule or a field's line.
    private static let underlineCovered = 0.7

    /// What a walk read of a page, with its plain underlines.
    static func translationContent(_ page: PObj, _ walked: Walked, _ ops: [COp]) -> PageContent {
        var content = walked.content
        if !walked.paintsCut { content.underlines = plainUnderlines(page, content, walked.paints, ops) }
        return content
    }

    /// The page's plain underlines: each rectangle its own content fills in a plain color (one rectangle, one operator, so
    /// it can be taken off and drawn again) that is thin (a sixth of the text at most, or a point), at least half an em
    /// wide, its top from just above the baseline of the words over it to 0.4 em below it, inside no link (a link's
    /// underline moves with the link, `linkUnderline`), and covered for `underlineCovered` of its width by upright text on
    /// that baseline. Where it sits is what tells it from a strike-out (through the words), a table's rule (wider than the
    /// text over it) and a field's line (nothing over it). Each run goes with one underline at most.
    static func plainUnderlines(_ page: PObj, _ content: PageContent, _ paints: [Paint], _ ops: [COp]) -> [Underline] {
        var found: [Underline] = []
        let candidates = paints.filter { p in
            guard p.rect, p.color != nil, let b = p.box, p.id >= 0, p.id < ops.count, ["f", "F", "f*"].contains(ops[p.id].name) else { return false }
            let edges: Double = b.x + b.y + b.width + b.height
            return edges.isFinite && b.width > 0 && b.height > 0
        }
        if candidates.isEmpty || candidates.count > maxUnderlineCandidates { return found }
        let runs = content.runs.enumerated().filter { e in
            let r = e.element
            let at: Double = r.origin.y + r.box.x + r.box.width
            return abs(r.angle) < 0.5 && r.info != nil && r.blocked != hiddenLayerBlocked && r.fontSize > 0.5 && r.fontSize.isFinite && at.isFinite
                && r.text.utf16.contains(where: isLetterOrDigitUnit)
        }.sorted { ($0.element.origin.y, $0.offset) < ($1.element.origin.y, $1.offset) }.map(\.element)
        if runs.isEmpty { return found }
        let biggest = min(runs.map(\.fontSize).max()!, 500)
        let links = pageLinks(page).map(\.box)
        var taken = Set<Int>() // run keys
        var scanned = 0
        for paint in candidates {
            if scanned > maxRunsScanned { break } // a crafted page's rectangles over a baseline of a hundred thousand runs
            let b = paint.box!
            // The runs whose baseline is near enough above it, sorted by baseline: from 0.4 of the biggest text above its
            // top to just below it.
            var lo = 0, hi = runs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if runs[mid].origin.y < b.y - 0.4 * biggest { lo = mid + 1 } else { hi = mid }
            }
            var near: [TextRun] = []
            var looked = 0
            var k = lo
            while k < runs.count && runs[k].origin.y <= b.y + 0.05 * biggest && near.count <= maxRunsUnderOne {
                defer { k += 1 }
                // Every run on the band counts, kept or not: what bounds the work is how many are looked at.
                scanned += 1
                looked += 1
                if looked > maxRunsScannedForOne { break }
                let r = runs[k]
                let em = r.fontSize
                if b.y < r.origin.y - 0.05 * em || b.y > r.origin.y + 0.4 * em || r.box.right <= b.x || r.box.x >= b.right { continue }
                near.append(r)
            }
            if near.isEmpty || near.count > maxRunsUnderOne || looked > maxRunsScannedForOne { continue }
            // The words over it: the baseline nearest above its top.
            let baseline = near.map(\.origin.y).max()!
            let over = near.enumerated().filter { baseline - $0.element.origin.y < 0.25 * $0.element.fontSize }
                .sorted { ($0.element.box.x, $0.offset) < ($1.element.box.x, $1.offset) }.map(\.element)
            let size = over.map(\.fontSize).max()!
            if b.height > max(1, size / 6) || b.width < 0.5 * size { continue }
            if links.contains(where: { $0.inflate(0.3 * size).contains(b.centerX, b.centerY) }) { continue }
            // How much of its width the words over it cover (their boxes joined where they overlap).
            var covered = 0.0, reach = b.x
            for r in over {
                let from = max(reach, max(b.x, r.box.x)), to = min(b.right, r.box.right)
                if to > from { covered += to - from }
                reach = max(reach, to)
            }
            if covered < underlineCovered * b.width { continue }
            let under = over.filter { r in !taken.contains(r.key) && min(b.right, r.box.right) - max(b.x, r.box.x) >= 0.5 * r.box.width }
            if under.isEmpty { continue }
            for r in under { taken.insert(r.key) }
            found.append(Underline(box: b, id: paint.id, color: paint.color! & 0xFFFFFF, runs: under))
        }
        return found
    }

    /// A written paragraph's new underlines: its text's underlined stretches (`ParagraphLayout.underlined`) drawn as the
    /// first of the page's rules under its old words was (`underlines`), at its distance below the baseline and thickness
    /// scaled with the text, in its color: page operators to add after the content (empty when there is nothing to draw).
    /// The old rules go in `takeOffUnderlines`, once every paragraph is written.
    static func newUnderlines(_ page: PObj, _ p: TextParagraph, _ underlines: [Underline], _ layout: ParagraphLayout, _ fit: Double) -> String {
        if layout.underlined.isEmpty { return "" }
        let mine = Set(p.runs.map(\.key))
        guard let first = underlines.first(where: { $0.runs.contains { mine.contains($0.key) } }) else { return "" }
        let em = p.fontSize
        if !(em > 0) { return "" }
        // Its place and thickness in ems of the paragraph's text, from the baseline of the words it was under.
        let below = (first.box.y - first.runs.map(\.origin.y).max()!) / em
        let thick = first.box.height / em
        var sb = ""
        for (left, right, baseline) in layout.underlined {
            let top = baseline + below * em * fit
            sb += filled(page, RectD.fromEdges(left, top, right, top + max(0.25, thick * em * fit)), first.color)
        }
        return sb
    }

    /// The page's plain underlines under words that were written (`written`, run keys) taken off, each operator becoming
    /// "n" (in `pageEdits`); a rule also under words that weren't (a paragraph whose answer was refused, one beside it on
    /// the line) is drawn again over just those words' width, as it was: page operators to add after the content.
    static func takeOffUnderlines(_ page: PObj, _ underlines: [Underline], _ written: Set<Int>, _ ops: [COp], _ pageEdits: inout Edits) -> String {
        var sb = ""
        for u in underlines where u.runs.contains(where: { written.contains($0.key) }) {
            pageEdits.append((ops[u.id].start, ops[u.id].end, latin1Bytes("n")))
            // The rest, run by run (runs side by side make one piece), within the rule's own width.
            var from: Double?, to: Double?
            for r in u.runs.enumerated().sorted(by: { ($0.element.box.x, $0.offset) < ($1.element.box.x, $1.offset) }).map(\.element) {
                if written.contains(r.key) {
                    if let f = from, let t = to { sb += filled(page, RectD.fromEdges(f, u.box.y, t, u.box.bottom), u.color) }
                    from = nil
                    to = nil
                    continue
                }
                if from == nil { from = max(u.box.x, r.box.x) }
                to = min(u.box.right, r.box.right)
            }
            if let f = from, let t = to, t > f { sb += filled(page, RectD.fromEdges(f, u.box.y, t, u.box.bottom), u.color) }
        }
        return sb
    }

    /// The underlined stretches of a laid line (parts with a look that is `TextLook.underline`, the adjustments between
    /// them included): from the first one's start to the last one's ink, page as shown.
    static func underlinedIn(_ m: TextRun, _ origin: PointD, _ parts: [Part]) -> [(left: Double, right: Double, baseline: Double)] {
        var result: [(left: Double, right: Double, baseline: Double)] = []
        var from: Double?, to: Double?
        for (k, e) in m.extents(parts).enumerated() {
            let under = parts[k].look?.asked.underline == true
            if under && e.ink {
                if from == nil { from = e.start }
                to = e.end
            } else if !under, let f = from, let t = to {
                result.append((origin.x + f * m.scale, origin.x + t * m.scale, origin.y))
                from = nil
                to = nil
            }
        }
        if let f = from, let t = to { result.append((origin.x + f * m.scale, origin.x + t * m.scale, origin.y)) }
        return result
    }
}
