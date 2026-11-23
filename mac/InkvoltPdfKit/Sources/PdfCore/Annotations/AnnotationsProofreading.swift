import Foundation
import PrintCore

/// What a proofreading mark asks for: text put in at a caret, or the struck-out text replaced.
public enum ProofMarkKind: Sendable { case insertText, replaceText }

/// Proofreading marks as Acrobat makes them (roadmap 4.17; the Windows app's `Annotations.Proofreading`). Insert Text is a
/// /Caret annotation at the insertion point, the text to insert as its contents. Replace Text is a /Caret after the
/// struck-out words, the new text as its contents, and a /StrikeOut over them bound to it as one group (/IRT the caret,
/// /RT /Group): viewers list the pair as one comment, and deleting the caret or the strike-out takes the whole group
/// (`groupHeadIn`). Both are blue, with their own appearance, so every viewer draws them alike.
extension Annotations {
    /// The blue Acrobat gives its text edits.
    public static let proofBlue = AnnotColor(0, 0, 1)

    /// The caret's subject (Acrobat's words, which other viewers read).
    static let insertedTextSubject = "Inserted Text", crossOutSubject = "Cross-Out"

    /// The longest text a proofreading mark carries (what a paste or a tampered call can give).
    public static let maxProofText = 20_000

    /// The most steps from a group's member to its head (a hostile file can chain or loop them).
    static let maxGroupHops = 16

    /// The insertion point before character `caret` of the page's text (after the last one at its end), as a zero-width
    /// box as tall as its line (page space); nil where the text has no box there.
    public static func caretAt(_ text: PageText, _ caret: Int) -> RectD? {
        let caret = min(max(caret, 0), text.length)
        if caret < text.length, text.string(caret, caret + 1) != "\n", let r = text.rects(caret, caret + 1).first {
            return RectD(r.x, r.y, 0, r.height)
        }
        if caret > 0, let l = text.rects(caret - 1, caret).first { return RectD(l.right, l.y, 0, l.height) }
        return nil
    }

    /// Adds an Insert Text mark: a caret at `at` (page space: its left edge is the insertion point, its height the
    /// line's, as `caretAt` gives), `text` the words to insert. Throws `PdfEditError` for no text, too much, or no page.
    public static func addInsertText(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ at: RectD, _ text: String,
                                     author: String, id: String? = nil) throws -> [UInt8] {
        let text = try checkProofText(text)
        return try PageEditor.edit(data, password, userEdit: .annotate) { doc in
            _ = try addCaretIn(doc, pageIndex, at, text, author: author, id: id)
        }
    }

    /// Adds a Replace Text mark: the words on `lineRects` (page space, one box per line, as `PageText.rects` gives)
    /// struck out, and a caret after the last one carrying `text`, the two grouped. `id` names the caret (the comment the
    /// Comments list shows).
    public static func addReplaceText(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ lineRects: [RectD], _ text: String,
                                      author: String, id: String? = nil) throws -> [UInt8] {
        let text = try checkProofText(text)
        let lines = lineRects.filter { !$0.isEmpty }
        guard let last = lines.last else { throw PdfEditError(loc("No text to mark.")) }
        return try PageEditor.edit(data, password, userEdit: .annotate) { doc in
            let caret = try addCaretIn(doc, pageIndex, RectD(last.right, last.y, 0, last.height), text, author: author, id: id)
            let strikeId = newId()
            addTextMarkupIn(doc, pageIndex, .strikeOut, lines, proofBlue, note: nil, author: author, id: strikeId)
            guard let strike = try find(doc, strikeId)?.annot else { return }
            strike.set("IRT", caret)
            strike.set("RT", doc.name("Group"))
            strike.set("Subj", doc.text(crossOutSubject))
        }
    }

    /// What a caret is: Replace Text when a strike-out is grouped with it (its id in `replaced`, from `replacedCarets`),
    /// else Insert Text; nil for any other comment.
    public static func proofKindOf(_ a: AnnotationInfo, _ replaced: Set<String>) -> ProofMarkKind? {
        a.kind != .caret ? nil : replaced.contains(a.id) ? .replaceText : .insertText
    }

    /// The ids of the carets a strike-out is grouped with: Replace Text marks (for `proofKindOf`), in one pass.
    public static func replacedCarets(_ all: [AnnotationInfo]) -> Set<String> {
        Set(all.compactMap { $0.grouped && $0.kind == .strikeOut ? $0.replyTo : nil })
    }

    /// True for a comment that is part of another's group (/RT /Group) whose head is among `ids`: the lists show the head
    /// only, as one comment.
    public static func isGroupMember(_ a: AnnotationInfo, _ ids: Set<String>) -> Bool {
        guard a.grouped, let head = a.replyTo else { return false }
        return head != a.id && ids.contains(head)
    }

    /// The comments as the Comments list and the comment summary list them: a group's members left out
    /// (`isGroupMember`: their head stands for them), and a comment whose own chain of groups or replies leads back to it
    /// (a hostile file's A in B's group and B in A's, or a reply to itself) listed as a comment of its own, its /IRT link
    /// dropped, so a loop never hides what it holds.
    public static func asListed(_ all: [AnnotationInfo]) -> [AnnotationInfo] {
        var byId: [String: AnnotationInfo] = [:]
        var order: [String] = []
        for a in all where byId[a.id] == nil {
            byId[a.id] = a
            order.append(a.id)
        }
        // Each comment points to at most one other (/IRT): the ones on a loop, found in one walk each from where it starts.
        var looped = Set<String>()
        var state: [String: Bool] = [:] // false: on the walk now; true: done
        for start in order where state[start] == nil {
            var path: [String] = []
            var at: String? = start
            while let id = at, let x = byId[id], state[id] == nil {
                state[id] = false
                path.append(id)
                at = x.replyTo
            }
            if let id = at, state[id] == false, let from = path.firstIndex(of: id) {
                for p in path[from...] { looped.insert(p) }
            }
            for p in path { state[p] = true }
        }
        let ids = Set(order)
        var listed: [AnnotationInfo] = []
        for a in all {
            if looped.contains(a.id) {
                var plain = a
                plain.replyTo = nil
                plain.grouped = false
                listed.append(plain)
            } else if !isGroupMember(a, ids) {
                listed.append(a)
            }
        }
        return listed
    }

    /// The comment `a` is part of: its group's head when it is a member (/RT /Group), else itself. A chain of groups is
    /// climbed a few steps at most; one that loops stops.
    public static func groupHead(_ a: AnnotationInfo, _ all: [AnnotationInfo]) -> AnnotationInfo {
        var byId: [String: AnnotationInfo] = [:]
        for x in all where byId[x.id] == nil { byId[x.id] = x }
        var head = a
        var hops = 0
        while hops < maxGroupHops, head.grouped, let to = head.replyTo, let up = byId[to], up.id != head.id {
            head = up
            hops += 1
        }
        return head
    }

    /// `groupHead` on the document itself: what a delete takes as one comment.
    static func groupHeadIn(_ annot: PObj) -> PObj {
        var head = annot
        var hops = 0
        while hops < maxGroupHops, head.name("RT") == "Group", let up = head.dict("IRT"),
              up.identity != head.identity, up.identity != annot.identity {
            head = up
            hops += 1
        }
        return head
    }

    private static func checkProofText(_ text: String) throws -> String {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw PdfEditError(loc("There's no text to insert.")) }
        // .NET's Length: UTF-16 units.
        if text.utf16.count > maxProofText {
            throw PdfEditError(loc("The text is too long (more than {0} characters).", CoreLanguage.number(maxProofText)))
        }
        return text
    }

    /// A caret at `at`'s left edge, under the line, pointing up into it.
    private static func addCaretIn(_ doc: MuDoc, _ pageIndex: Int, _ at: RectD, _ text: String, author: String, id: String?) throws -> PObj {
        try checkPage(doc, pageIndex)
        if !at.x.isFinite || !at.y.isFinite || !at.height.isFinite || at.height <= 0 { throw PdfEditError(loc("No text to mark.")) }
        let page = doc.page(pageIndex)
        let (x1, y1, x2, y2, form) = caretAppearance(doc, page, at, proofBlue)
        let annot = newAnnot(doc, page, "Caret", x1, y1, x2, y2, id, text, author, proofBlue)
        annot.set("Subj", doc.text(insertedTextSubject))
        annot.set("Sy", doc.name("None"))
        annot.set("RD", doc.realArray([0, 0, 0, 0]))
        setAppearance(doc, annot, form)
        return annot
    }

    /// The caret's shape (a filled chevron, its tip at the baseline) in PDF space, upright as the page is shown, with the
    /// rectangle it covers.
    private static func caretAppearance(_ doc: MuDoc, _ page: PObj, _ at: RectD, _ color: AnnotColor)
        -> (x1: Double, y1: Double, x2: Double, y2: Double, form: PObj) {
        let h = min(max(at.height, 4), 72)
        let w = h * 0.55, x = at.x, tipY = at.bottom - h * 0.3, baseY = at.bottom + h * 0.2, notch = at.bottom + h * 0.08
        let shape = [PageBoxes.toPdf(page, x, tipY), PageBoxes.toPdf(page, x + w / 2, baseY), PageBoxes.toPdf(page, x, notch),
                     PageBoxes.toPdf(page, x - w / 2, baseY)]
        let xs = shape.map(\.x), ys = shape.map(\.y)
        let x1 = xs.min()! - 1, y1 = ys.min()! - 1, x2 = xs.max()! + 1, y2 = ys.max()! + 1
        var ops = "\(PdfNum.f(color.r)) \(PdfNum.f(color.g)) \(PdfNum.f(color.b)) rg "
        for (i, p) in shape.enumerated() { ops += "\(PdfNum.f(p.x)) \(PdfNum.f(p.y)) \(i == 0 ? "m" : "l") " }
        ops += "h f\n"
        return (x1, y1, x2, y2, doc.formXObject(Array(ops.utf8), x1, y1, x2, y2, doc.dict()))
    }

    /// An imported caret's appearance from its rectangle (XFDF carries none): the chevron filling its lower part.
    static func caretFromRect(_ doc: MuDoc, _ page: PObj, _ annot: PObj, _ color: AnnotColor) {
        guard let r = annot.array("Rect"), r.count == 4 else { return }
        let box = PageBoxes.rectToPage(page, r)
        if box.isEmpty || !box.width.isFinite || !box.height.isFinite { return }
        // The rectangle Acrobat gives a caret is the chevron's own: its tip a third of the way down, its base at the bottom.
        let h = box.height / 0.5
        let at = RectD(box.centerX, box.bottom - 0.2 * h - h, 0, h)
        setAppearance(doc, annot, caretAppearance(doc, page, at, color).form)
    }
}
