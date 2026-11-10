import Foundation

/// A translated paragraph's links and underlines (roadmap 3.1; the Windows app's ContentEditor.TranslateLinks.cs). The
/// words move, so what marked them where they were would mark the middle of other words: a link (/Link) whose words the
/// translation keeps as they were (an identifier, a document number: "SP 800-63A", "(SP) 800-63A") moves onto them, a
/// copy for each further line they reach, with its underline redrawn under them; a link whose words were translated is
/// taken off the page (it can't be told what they became), with its underline. An underline that is no link's, or that
/// can't be drawn again, stays as drawn.
extension ContentEditor {
    /// The most links on a page looked at: more is a crafted page, and they stay as they are.
    private static let maxLinksToFollow = 2_000

    /// The most words of a link matched against its new text.
    private static let maxLinkWords = 64

    /// The most words of a paragraph's new text a link is looked for in.
    private static let maxWordsToSearch = 4_000

    /// The longest word (characters, spaces apart) a link is followed by: a line holds fewer. A link with a longer one is
    /// dropped, and a longer new word is never part of where a link goes.
    private static let maxLinkWordChars = 256

    /// A link on a translated paragraph's lines (`slot`): its annotation, where it was, its words then, its underline
    /// (`linkUnderline`; nil: none to move) and the baseline of its line; where the new text is, where its lines start
    /// (page as shown) and how far it shrank (`placed` nil: a turned paragraph, whose link is dropped), and the
    /// paragraph's size.
    struct LinkFix {
        var slot: Int
        var annot: PObj
        var box: RectD
        var words: [String]
        var underline: Paint?
        var baseline: Double
        var placed: RectD?
        var lines: [PointD]
        var fit: Double
        var fontSize: Double
    }

    /// The page's /Link annotations and where they are (none past `maxLinksToFollow`).
    private static func pageLinks(_ page: PObj) -> [(annot: PObj, box: RectD)] {
        guard let annots = page.array("Annots"), annots.count <= maxLinksToFollow else { return [] }
        var links: [(annot: PObj, box: RectD)] = []
        for a in annots.elements where a.isDict && a.name("Subtype") == "Link" {
            guard let rect = a.array("Rect"), rect.count >= 4 else { continue }
            let box = PageBoxes.rectToPage(page, rect)
            let edges: Double = box.x + box.y + box.width + box.height
            if box.width > 0 && box.height > 0 && edges.isFinite { links.append((a, box)) }
        }
        return links
    }

    /// The line of a paragraph a box sits on: its center within the line's height (a little more), and inside its width.
    private static func lineOf(_ p: TextParagraph, _ box: RectD) -> Int {
        let tol = 0.25 * p.fontSize
        for (k, l) in p.lines.enumerated()
            where box.centerY >= l.y - tol && box.centerY <= l.bottom + tol && box.centerX >= l.x - 1 && box.centerX <= l.right + 1 { return k }
        return -1
    }

    /// A link's underline on an upright paragraph's line: one rectangle filled in a plain color (so it can be drawn again,
    /// and no other link's or line's mark is in the same operator), no thicker than a sixth of the text, its top between
    /// the line's middle and a third of an em below it, and within the link's own width. Nil when there is none.
    /// `gone`: underlines already a link's.
    private static func linkUnderline(_ p: TextParagraph, _ line: RectD, _ link: RectD, _ paints: [Paint], _ ops: [COp], _ gone: inout Set<Int>) -> Paint? {
        let em = p.fontSize
        let tol = 0.3 * em
        for u in paints {
            guard u.rect, u.color != nil, let b = u.box, u.id >= 0, u.id < ops.count, ["f", "F", "f*"].contains(ops[u.id].name), !gone.contains(u.id) else { continue }
            if b.height > max(1, em / 6) || b.width < 0.5 * em || b.x < link.x - tol || b.right > link.right + tol || b.y < line.centerY || b.y > line.bottom + em / 3 { continue }
            gone.insert(u.id)
            return u
        }
        return nil
    }

    /// The words of a paragraph's runs inside a box, in order (upright runs only, where their glyphs are).
    private static func wordsIn(_ runs: [TextRun], _ box: RectD) -> [String] {
        var words: [String] = []
        let inBox = runs.enumerated().filter { abs($0.element.angle) < 0.5 && $0.element.box.centerY >= box.y && $0.element.box.centerY <= box.bottom }
            .sorted { ($0.element.origin.y, $0.element.box.x, $0.offset) < ($1.element.origin.y, $1.element.box.x, $1.offset) }.map(\.element)
        for r in inBox {
            for w in lineWordsOf(r) where (w.start + w.end) / 2 >= box.x && (w.start + w.end) / 2 <= box.right {
                words += w.text.split(separator: " ").map(String.init)
            }
        }
        return Array(words.prefix(maxLinkWords))
    }

    private static let aroundWords = Set(",.;:!?\"'“”‘’()[]«»".unicodeScalars)

    /// A word as compared: without the punctuation around it.
    private static func bare(_ word: String) -> String {
        let v = Array(word.unicodeScalars)
        guard let lo = v.firstIndex(where: { !aroundWords.contains($0) }), let hi = v.lastIndex(where: { !aroundWords.contains($0) }) else { return "" }
        return String(String.UnicodeScalarView(v[lo...hi]))
    }

    private static func trimStartAround(_ v: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> { v.drop { aroundWords.contains($0) } }

    /// A bare word worth following a link by: with a figure, or of 4 letters or more (not "the" or "and").
    private static func telling(_ bare: String) -> Bool {
        bare.unicodeScalars.contains { $0.properties.generalCategory == .decimalNumber } || bare.unicodeScalars.filter(TranslationText.isLetter).count >= 4
    }

    /// Where a link's words are in the new text: each place (its first word, how many) the new words have the longest
    /// stretch of them, in their order, as they were (not already taken by another link), worth following (`telling`);
    /// none when there is none. Spaces don't count, so "800-" "63A," (a line's gaps fall where its maker spaced it) is
    /// "800-63A," as one word. A place starts at a new word whose bare form begins the stretch: the new words are indexed
    /// by their bare forms, looked up by the stretch's beginnings. No word longer than `maxLinkWordChars` takes part.
    static func follow(_ linkWords: [String], _ newWords: [String], _ taken: Set<Int>) -> [(start: Int, count: Int)] {
        var found: [(start: Int, count: Int)] = []
        if linkWords.contains(where: { $0.utf16.count > maxLinkWordChars }) { return found }
        var placesFound = Set<Int>()
        let tells = linkWords.map { telling(bare($0)) }
        var byBare: [[Unicode.Scalar]: [Int]] = [:]
        var longest = 0
        let words = newWords.map { Array($0.unicodeScalars) }
        for (i, w) in newWords.enumerated() {
            if w.utf16.count > maxLinkWordChars { continue }
            let b = Array(bare(w).unicodeScalars)
            if b.isEmpty { continue }
            byBare[b, default: []].append(i)
            longest = max(longest, b.count)
        }
        var len = linkWords.count
        while len >= 1 && found.isEmpty {
            defer { len -= 1 }
            for from in 0...(linkWords.count - len) {
                if !tells[from..<(from + len)].contains(true) { continue }
                let want = Array(bare(linkWords[from..<(from + len)].joined()).unicodeScalars)
                if want.count < 2 { continue }
                // The stretch, without the punctuation before it, starts with its first word's bare form.
                for k in 1...max(1, min(want.count, longest)) where k <= want.count {
                    guard let starts = byBare[Array(want[0..<k])] else { continue }
                    for at in starts {
                        if taken.contains(at) || placesFound.contains(at) { continue }
                        var joined: [Unicode.Scalar] = []
                        var end = at
                        while end < newWords.count && !taken.contains(end) && newWords[end].utf16.count <= maxLinkWordChars {
                            joined += words[end]
                            let got = trimStartAround(joined[...])
                            let core = Array(got.reversed().drop { aroundWords.contains($0) }.reversed())
                            if core == want {
                                found.append((at, end - at + 1))
                                placesFound.insert(at)
                                break
                            }
                            // More words only add to the end: once it isn't how the stretch begins, it never is.
                            if !want.starts(with: got) { break }
                            end += 1
                        }
                    }
                }
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// Of the places a link's words are in its paragraph's new text (`follow`), the one nearest where the link was (its
    /// first word's start and line against the link's left edge and middle); nil when there is none or another is as
    /// near (within half an em): the link would then be on words that may not be its own.
    private static func nearest(_ found: [(start: Int, count: Int)], _ words: [(text: String, start: Double, end: Double, run: TextRun)], _ was: RectD,
                                _ em: Double) -> (start: Int, count: Int)? {
        var best: (start: Int, count: Int)?
        var near = Double.greatestFiniteMagnitude, next = Double.greatestFiniteMagnitude
        for f in found {
            let w = words[f.start]
            let dx = w.start - was.x, dy = w.run.box.centerY - was.centerY
            let d = (dx * dx + dy * dy).squareRoot()
            if d < near {
                (next, near, best) = (near, d, f)
            } else {
                next = min(next, d)
            }
        }
        return next - near > 0.5 * em ? best : nil
    }

    /// A run's words where the page shows them (x along its line), for links.
    private static func lineWordsOf(_ r: TextRun) -> [(start: Double, end: Double, text: String)] {
        guard let info = r.info, r.scale > 0 else { return [(r.box.x, r.box.right, r.text)] }
        var out: [(start: Double, end: Double, text: String)] = []
        let em = abs(r.size * r.hScale)
        var first = -1, last = -1
        var i = 0
        let items = info.items
        while i <= items.count {
            defer { i += 1 }
            if i < items.count && !inkedItem(items[i]) { continue }
            if last >= 0 && (i == items.count || items[i].at - items[last].inkEnd > 0.15 * em) {
                var units: [UInt16] = []
                for k in first...last { units += items[k].units }
                out.append((r.origin.x + (items[first].at - info.start) * r.scale, r.origin.x + (items[last].inkEnd - info.start) * r.scale,
                            String(decoding: units, as: UTF16.self)))
                first = -1
            }
            if i == items.count { break }
            if first < 0 { first = i }
            last = i
        }
        return out
    }

    /// The links of the paragraphs just written on a page, to be moved with their underlines or dropped once the page's
    /// fonts are in the document (`fixLinks`); nothing on the page changes yet. `placed`: where each upright paragraph's
    /// new text is, where its lines start and how far it shrank. Turned paragraphs' links are dropped, their underlines left.
    static func linksOfWritten(_ page: PObj, _ slots: [TranslationSlot], _ written: [TranslationWritten], _ placed: [Int: (box: RectD, fit: Double, lines: [PointD])],
                               _ ops: [COp], _ paints: [Paint]?) -> [LinkFix] {
        var found: [LinkFix] = []
        let links = pageLinks(page)
        var claimed = Set<ObjId>()
        var gone = Set<Int>()
        for w in written {
            let p = slots[w.slot].paragraph
            let upright = p.upright == nil
            for (annot, box) in links {
                if claimed.contains(annot.id) { continue }
                let line = lineOf(p, box)
                if line < 0 { continue }
                claimed.insert(annot.id)
                let words = upright ? wordsIn(p.runs, box) : []
                let l = p.lines[line]
                let baseline = p.runs.filter { $0.box.centerY >= l.y && $0.box.centerY <= l.bottom }.map(\.origin.y).max() ?? l.bottom
                let underline = upright && paints != nil ? linkUnderline(p, l, box, paints!, ops, &gone) : nil
                let to = upright ? placed[w.slot] : nil
                found.append(LinkFix(slot: w.slot, annot: annot, box: box, words: words, underline: underline, baseline: baseline,
                                     placed: to?.box, lines: to?.lines ?? [], fit: to?.fit ?? 1, fontSize: p.fontSize))
            }
        }
        return found
    }

    /// A paragraph's new words where they are now, line by line: those of the runs written on its new lines (starting on
    /// one of their baselines, at or after its start) inside where it was placed, so no other text there is taken for it.
    private static func writtenWords(_ after: PageContent, _ placed: RectD, _ lines: [PointD], _ em: Double) -> [(text: String, start: Double, end: Double, run: TextRun)] {
        let area = placed.inflate(0.25 * em)
        var words: [(text: String, start: Double, end: Double, run: TextRun)] = []
        let mine = after.runs.enumerated().filter { e in
            let r = e.element
            return abs(r.angle) < 0.5 && !trimmed(r.text).isEmpty && area.contains(r.box.centerX, r.box.centerY)
                && lines.contains { abs(r.origin.y - $0.y) < 0.5 && r.origin.x >= $0.x - 1 }
        }.sorted { a, b in
            let ya = (a.element.origin.y * 10).rounded() / 10, yb = (b.element.origin.y * 10).rounded() / 10
            return (ya, a.element.box.x, a.offset) < (yb, b.element.box.x, b.offset)
        }.map(\.element)
        for r in mine {
            for w in lineWordsOf(r) {
                for part in w.text.split(separator: " ") where words.count < maxWordsToSearch { words.append((String(part), w.start, w.end, r)) }
            }
        }
        return words
    }

    /// Once a page's translated paragraphs are written and the fonts they use are in the document: each link
    /// (`linksOfWritten`) is moved onto its words where its paragraph's new text keeps them (its /Rect around them, a copy
    /// for each further line they reach), with its underline redrawn under them as it was (its distance from the baseline
    /// and thickness scaled with the text, its color), or else taken off the page, and out of the structure tree, with
    /// its underline. The page is read first and changed after: if it can't be read, its links and underlines stay as
    /// they were; an underline not found again as it was drawn stays, and isn't drawn again.
    static func fixLinks(_ doc: MuDoc, _ pageIndex: Int, _ links: [LinkFix]) throws {
        if links.isEmpty { return }
        let page = try pageOf(doc, pageIndex)
        let pageStreams = streams(page)
        let ops = try ContentLexer.parse(pageStreams.bytes, cancel: nil)
        let walked = try walk(doc, page, pageIndex, ops, nil)
        let paints = walked.paintsCut ? nil : walked.paints
        var drop = Set<ObjId>()
        var blank: Edits = []
        var underlines = ""
        var moves: [(annot: PObj, boxes: [RectD])] = []

        // A link's underline in the page's content now: the one filled rectangle of its color where it was (unchanged by
        // the paragraph's rewrite), its operator to become "n" (the path ends unpainted). False: not found, or not alone.
        func blankOut(_ underline: Paint?) -> Bool {
            guard let underline, let was = underline.box, let color = underline.color, let paints else { return false }
            var hit = -1
            for x in paints {
                guard x.rect, let b = x.box, x.color == color, x.id >= 0, x.id < ops.count, ["f", "F", "f*"].contains(ops[x.id].name) else { continue }
                if abs(b.x - was.x) < 0.01 && abs(b.y - was.y) < 0.01 && abs(b.right - was.right) < 0.01 && abs(b.bottom - was.bottom) < 0.01 {
                    if hit >= 0 { return false }
                    hit = x.id
                }
            }
            if hit < 0 { return false }
            blank.append((ops[hit].start, ops[hit].end, Array("n".utf8)))
            return true
        }

        var bySlot: [Int: [LinkFix]] = [:]
        var slotOrder: [Int] = []
        for l in links {
            if bySlot[l.slot] == nil { slotOrder.append(l.slot) }
            bySlot[l.slot, default: []].append(l)
        }
        for slot in slotOrder {
            let group = bySlot[slot]!
            let first = group[0]
            guard let placed = first.placed else {
                for l in group { drop.insert(l.annot.id) }
                continue
            }
            let words = writtenWords(walked.content, placed, first.lines, first.fontSize)
            let texts = words.map(\.text)
            var taken = Set<Int>()
            let ordered = group.enumerated().sorted { ($0.element.box.y, $0.element.box.x, $0.offset) < ($1.element.box.y, $1.element.box.x, $1.offset) }.map(\.element)
            for l in ordered {
                guard !l.words.isEmpty, let (at, count) = nearest(follow(l.words, texts, taken), words, l.box, l.fontSize) else {
                    drop.insert(l.annot.id)
                    _ = blankOut(l.underline)
                    continue
                }
                for k in at..<(at + count) { taken.insert(k) }
                // A box for each line the words reach.
                var boxes: [(box: RectD, run: TextRun)] = []
                for k in at..<(at + count) {
                    let (_, start, end, run) = words[k]
                    if let last = boxes.last, abs(last.run.origin.y - run.origin.y) < 0.5 {
                        boxes[boxes.count - 1] = (.fromEdges(last.box.x, min(last.box.y, run.box.y), max(last.box.right, end), max(last.box.bottom, run.box.bottom)), run)
                    } else {
                        boxes.append((.fromEdges(start, run.box.y, end, run.box.bottom), run))
                    }
                }
                moves.append((l.annot, boxes.map(\.box)))
                if let u = l.underline, let was = u.box, let color = u.color, blankOut(l.underline) {
                    let below = (was.y - l.baseline) * l.fit
                    let thick = max(0.25, was.height * l.fit)
                    for (box, run) in boxes {
                        underlines += filled(page, .fromEdges(box.x, run.origin.y + below, box.right, run.origin.y + below + thick), color)
                    }
                }
            }
        }

        // Read and worked out: now the page changes (a damaged page refuses the first write, before anything else).
        if !blank.isEmpty { try writeContent(doc, page, pageStreams, ops, blank) }
        if !underlines.isEmpty { appendDrawing(doc, page, underlines) }
        var added: [PObj] = []
        for (annot, boxes) in moves { added += place(doc, page, annot, boxes) }
        if drop.isEmpty && added.isEmpty { return }
        var keys: [Int] = []
        if let annots = page.array("Annots") {
            let kept = doc.array() // the page's own: another page may share the old one
            for item in annots.elements {
                if drop.contains(item.id) {
                    if let key = item.int("StructParent") { keys.append(key) }
                    continue
                }
                kept.append(item)
            }
            for a in added { kept.append(a) }
            page.set("Annots", kept)
        }
        if !drop.isEmpty { StructTree.prune(doc, gonePages: [], goneKeys: keys, objectGone: { drop.contains($0.id) }) }
    }

    /// A link annotation set around the first of some boxes of the page as shown, and a copy of it around each other one
    /// (returned, for the page's /Annots): one box spanning two lines would make the lines' whole width a link where
    /// /QuadPoints aren't read. A copy has no place in the structure tree or name of its own.
    private static func place(_ doc: MuDoc, _ page: PObj, _ annot: PObj, _ boxes: [RectD]) -> [PObj] {
        func rect(_ b: RectD) -> PObj {
            let r = PageBoxes.fromPageSpace(page, b)
            return doc.reals(r.x1, r.y1, r.x2, r.y2)
        }
        annot.set("Rect", rect(boxes[0]))
        annot.remove("QuadPoints")
        var copies: [PObj] = []
        for box in boxes.dropFirst() {
            let copy = doc.dict()
            for key in annot.keys where key != "StructParent" && key != "NM" {
                if let v = annot[key] { copy.set(key, v) }
            }
            copy.set("Rect", rect(box))
            copies.append(doc.add(copy))
        }
        return copies
    }

    /// A rectangle of the page as shown filled in a color, as operators in the page's default space.
    private static func filled(_ page: PObj, _ box: RectD, _ color: Int) -> String {
        let r = PageBoxes.fromPageSpace(page, box)
        func n(_ v: Double) -> String { ContentLexer.number(v) }
        let rgb = "\(n(Double(color >> 16 & 0xFF) / 255)) \(n(Double(color >> 8 & 0xFF) / 255)) \(n(Double(color & 0xFF) / 255)) rg"
        return "\(rgb) \(n(r.x1)) \(n(r.y1)) \(n(r.x2 - r.x1)) \(n(r.y2 - r.y1)) re f\n"
    }

    /// Appends drawing after the page's content, which is wrapped in q/Q so its graphics state can't leak.
    private static func appendDrawing(_ doc: MuDoc, _ page: PObj, _ ops: String) {
        var contents: [PObj] = [doc.addStream(Array("q\n".utf8), deflate: false)]
        if let existing = page["Contents"] { contents += existing.isArray ? existing.elements : [existing] }
        contents.append(doc.addStream(Array(("Q\n" + ops).utf8), deflate: false))
        page.set("Contents", doc.array(contents))
    }
}
