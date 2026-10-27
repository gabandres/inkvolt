import Foundation

/// Reads and rewrites the document's bookmarks: add, rename, delete, reorder, nest, restyle, retarget (the Windows app's
/// `Bookmarks`). A signed document gets the change as an incremental update (bookmarks are outside what signatures lock).
public enum Bookmarks {
    private static let flagItalic = 1, flagBold = 2

    /// The bookmarks as a tree (empty when there are none).
    public static func read(_ data: [UInt8], _ password: String?) throws -> [Bookmark] {
        let doc = try PdfEdit.openToRead(data, password)
        var id = 0
        func convert(_ items: [PdfStructure.OutlineItem]) -> [Bookmark] {
            items.map { item in
                id += 1
                let sourceId = id
                let d = item.dict
                let (page, top) = target(doc, d)
                let action = d.dict("A")
                let kind = action == nil || page >= 0 ? nil : action?.name("S")
                let flags = d.int("F") ?? 0
                var b = Bookmark(d.text("Title") ?? "", page, top: top, children: convert(item.children))
                b.sourceId = sourceId
                b.open = item.open
                b.bold = flags & flagBold != 0
                b.italic = flags & flagItalic != 0
                b.color = colorOf(d)
                b.actionKind = kind
                b.uri = kind == "URI" ? action?.text("URI") : nil
                return b
            }
        }
        return convert(PdfStructure.readOutline(doc))
    }

    /// Makes `outline` the document's bookmarks (none: the outline is removed). Bookmarks read by `read` from these bytes
    /// keep their dictionary (and whatever else it holds); the destination is rewritten only when `pageIndex` or `top`
    /// changed.
    /// - Throws: `PdfEditError` when a bookmark leads to a page the document doesn't have.
    public static func setOutline(_ data: [UInt8], _ password: String?, _ outline: [Bookmark]) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        var existing: [PObj] = []
        func flatten(_ items: [PdfStructure.OutlineItem]) {
            for item in items {
                existing.append(item.dict)
                flatten(item.children)
            }
        }
        flatten(PdfStructure.readOutline(doc))
        let pageCount = try doc.pageCount()
        var used = Set<Int>()

        func build(_ nodes: [Bookmark], _ depth: Int) throws -> [PdfStructure.OutlineItem] {
            if depth > 64 { throw PdfEditError("Bookmarks are nested too deeply.") }
            var list: [PdfStructure.OutlineItem] = []
            for node in nodes {
                if node.pageIndex >= pageCount || node.pageIndex < -1 {
                    throw PdfEditError("Bookmark \"\(node.title)\" leads to page \(node.pageIndex + 1), which the document doesn't have.")
                }
                let reuse = node.sourceId > 0 && node.sourceId <= existing.count && used.insert(node.sourceId).inserted
                let d = reuse ? existing[node.sourceId - 1] : doc.add(doc.dict())
                if d.text("Title") != node.title { d.set("Title", doc.text(node.title)) }

                let (page, top) = reuse ? target(doc, d) : (-1, nil)
                if !reuse || page != node.pageIndex || !near(top, node.top) {
                    d.remove("A")
                    d.remove("SE")
                    if node.pageIndex >= 0 { d.set("Dest", destination(doc, node.pageIndex, node.top)) } else { d.remove("Dest") }
                }

                let had = d.int("F") ?? 0
                let flags = (had & ~(flagBold | flagItalic)) | (node.bold ? flagBold : 0) | (node.italic ? flagItalic : 0)
                if flags != had { d.set("F", doc.int(flags)) }
                if flags == 0 { d.remove("F") }

                if colorOf(d) != node.color {
                    if let c = node.color, c != AnnotColor(0, 0, 0) { d.set("C", doc.reals(c.r, c.g, c.b)) } else { d.remove("C") }
                }

                let item = PdfStructure.OutlineItem(d, open: node.open)
                item.children = try build(node.children, depth + 1)
                list.append(item)
            }
            return list
        }

        let items = try build(outline, 0)
        if used.count < existing.count { SignedEdits.noteRemoval() }
        try PdfStructure.writeOutline(doc, items)
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    private static func near(_ a: Double?, _ b: Double?) -> Bool {
        guard let a else { return b == nil }
        guard let b else { return false }
        return abs(a - b) < 0.5
    }

    /// The page (and top, page space) an outline item leads to: its /Dest, or a GoTo action's; -1 when neither.
    private static func target(_ doc: MuDoc, _ item: PObj) -> (page: Int, top: Double?) {
        var dest = item["Dest"]
        if dest == nil, let a = item.dict("A"), a.name("S") == "GoTo" { dest = a["D"] }
        guard let d = DocumentFeatures.resolveDestination(doc, dest) else { return (-1, nil) }
        return (d.pageIndex, d.y)
    }

    private static func colorOf(_ item: PObj) -> AnnotColor? {
        guard let c = item.array("C"), c.count == 3 else { return nil }
        return AnnotColor(c.num(0), c.num(1), c.num(2))
    }

    /// [page /XYZ left top null]: a position on the page (top, in page space), keeping the zoom.
    private static func destination(_ doc: MuDoc, _ pageIndex: Int, _ top: Double?) -> PObj {
        let page = doc.page(pageIndex)
        var left = doc.null, y = doc.null
        if let t = top {
            // Page space runs down the displayed page; on a page shown sideways its "down" is the PDF's x axis.
            let p = PageBoxes.toPdf(page, 0, t)
            let rot = PageBoxes.rotate(page)
            if rot == 90 || rot == 270 { left = doc.real((p.x * 100).rounded() / 100) } else { y = doc.real((p.y * 100).rounded() / 100) }
        }
        return doc.array([page, doc.name("XYZ"), left, y, doc.null])
    }
}
