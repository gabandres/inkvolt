import Foundation

/// Moving and recoloring sticky notes and text marks in place (drawings have `updateGeometry` and `updateStyle`): the
/// annotation keeps its id, text, author and replies. A Mac addition; the Windows app doesn't move or recolor these yet.
extension Annotations {
    static let markupSubtypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]

    /// Moves a note or a text mark by (`dx`, `dy`) page points on its page. Its /Rect and /QuadPoints (and a note's popup)
    /// shift; the appearance follows /Rect, so it looks the same where it lands.
    /// - Throws: `PdfEditError` when there is no such comment, or it is another kind.
    public static func move(_ data: [UInt8], _ password: String?, _ id: String, dx: Double, dy: Double) throws -> [UInt8] {
        let doc = try PdfEdit.openToRead(data, password)
        guard let found = try find(doc, id) else { throw PdfEditError("That comment no longer exists.") }
        try checkMovable(found.annot)
        if dx == 0 && dy == 0 { return data }
        return try PageEditor.edit(data, password) { doc in
            guard let found = try find(doc, id) else { throw PdfEditError("That comment no longer exists.") }
            let page = doc.page(found.page), a = found.annot
            let o = PageBoxes.toPdf(page, 0, 0), d = PageBoxes.toPdf(page, dx, dy)
            let vx = d.x - o.x, vy = d.y - o.y
            func shifted(_ arr: PObj?) -> PObj? {
                guard let arr, arr.isArray, arr.count >= 2 else { return nil }
                return doc.realArray((0..<arr.count).map { i in arr.num(i) + (i % 2 == 0 ? vx : vy) })
            }
            func shift(_ annot: PObj) {
                if let r = shifted(annot.array("Rect")) { annot.set("Rect", r) }
                if let q = shifted(annot.array("QuadPoints")) { annot.set("QuadPoints", q) }
                if let popup = annot.dict("Popup"), let r = shifted(popup.array("Rect")) { popup.set("Rect", r) }
            }
            shift(a)
            a.set("M", doc.now())
            // Replies sit on their comment (and replies to them on theirs): they come along.
            let all = (page.array("Annots")?.elements ?? []).enumerated().filter { $0.element.isDict }
            var parents: Set<String> = [id]
            var moved: Set<String> = [id]
            while !parents.isEmpty {
                var next: Set<String> = []
                for (i, r) in all where r.name("Subtype") == "Text" {
                    guard let irt = r.dict("IRT"), parents.contains(idOf(doc, irt, found.page, -1)) else { continue }
                    let rid = idOf(doc, r, found.page, i)
                    guard moved.insert(rid).inserted else { continue }
                    shift(r)
                    next.insert(rid)
                }
                parents = next
            }
        }
    }

    /// Recolors a note or a text mark: /C and its appearance, drawn again in `color`.
    /// - Throws: `PdfEditError` when there is no such comment, or it is another kind.
    public static func setColor(_ data: [UInt8], _ password: String?, _ id: String, _ color: AnnotColor) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            guard let found = try find(doc, id) else { throw PdfEditError("That comment no longer exists.") }
            let page = doc.page(found.page), a = found.annot
            try checkMovable(a)
            let subtype = a.name("Subtype") ?? ""
            a.set("C", doc.realArray([color.r, color.g, color.b]))
            a.set("M", doc.now())
            if subtype == "Text" {
                setAppearance(doc, a, noteForm(doc, page, color))
                return
            }
            guard let kind = TextMarkupKind(rawValue: subtype), let qp = a.array("QuadPoints"), qp.count >= 8 else { return }
            var quads: [Quad] = []
            var k = 0
            while k + 7 < qp.count {
                quads.append(((qp.num(k), qp.num(k + 1)), (qp.num(k + 2), qp.num(k + 3)), (qp.num(k + 4), qp.num(k + 5)), (qp.num(k + 6), qp.num(k + 7))))
                k += 8
            }
            let (form, x1, y1, x2, y2) = markupForm(doc, kind, quads, color)
            a.set("Rect", doc.realArray([x1, y1, x2, y2]))
            setAppearance(doc, a, form)
        }
    }

    private static func checkMovable(_ a: PObj) throws {
        let subtype = a.name("Subtype") ?? ""
        if subtype != "Text" && !markupSubtypes.contains(subtype) {
            throw PdfEditError("Only notes and text marks (highlight, underline, strike-out) move and change color this way.")
        }
    }
}
