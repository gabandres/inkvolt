import Foundation

extension Annotations {
    /// Adds a reply to a comment: a note bound to it (/IRT, reply type R) at its top-left corner, drawn as the note icon,
    /// as Acrobat makes them (the Windows app's `Annotations.AddReply`). Replies list under their comment and go with it
    /// when it is deleted.
    public static func addReply(_ data: [UInt8], _ password: String?, _ parentId: String, _ text: String, author: String,
                                id: String? = nil) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            guard let found = try find(doc, parentId) else { throw PdfEditError("That comment no longer exists.") }
            let parent = found.annot
            if !parent.isRef { throw PdfEditError("That comment can't be replied to.") }
            let page = doc.page(found.page)
            var x = 0.0, top = 20.0
            if let r = parent.array("Rect"), r.count >= 4 {
                x = min(r.num(0), r.num(2))
                top = max(r.num(1), r.num(3))
            }
            let color = colorOf(parent.array("C")) ?? .yellow
            let annot = newAnnot(doc, page, "Text", x, top - 20, x + 20, top, id, text, author, color)
            annot.set("IRT", parent)
            annot.set("RT", doc.name("R"))
            annot.set("Name", doc.name("Comment"))
            annot.set("F", doc.int(flagPrint | 8 | 16)) // no zoom, no rotate: stays an icon
            let c = "\(PdfNum.f(color.r)) \(PdfNum.f(color.g)) \(PdfNum.f(color.b))"
            let ops = "q 0.35 G 0.8 w \(c) rg 1.5 6 m 1.5 18.5 l 18.5 18.5 l 18.5 6 l 9 6 l 5 1.5 l 6 6 l h B\n"
                + "0.3 G 1 w 5 15 m 15 15 l 5 12 m 15 12 l 5 9 m 12 9 l S Q\n"
            setAppearance(doc, annot, doc.formXObject(Array(ops.utf8), 0, 0, 20, 20, doc.dict(), matrix: doc.counterRotation(page)))
        }
    }
}
