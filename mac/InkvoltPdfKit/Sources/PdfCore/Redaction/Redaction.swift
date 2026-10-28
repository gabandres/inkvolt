import Foundation

/// True redaction (the Windows app's `Redaction`): every page with areas to redact is drawn (with its annotations and
/// form fields) as a picture, the areas are painted solid black in the pixels, and the page's content is replaced by that
/// picture. Nothing from the original page (text, vector art, images, annotations, form widgets, thumbnails, alternate
/// text in the structure tree) survives, so the redacted content can't be recovered or copied. Redacted pages become
/// pictures: their text is no longer selectable or searchable (the app lays recognized text back over them). A form
/// field an area touches is emptied on every page (its value would otherwise survive in its other widgets). Tagged PDFs
/// lose the redacted page's part of the structure tree. Other pages and the document metadata are left untouched.
public enum Redaction {
    /// - Parameters:
    ///   - areasByPage: areas to black out per page index, in page space (points, displayed page's top-left).
    ///   - dpi: resolution of the replacement page pictures.
    /// - Returns: the same bytes when there is nothing to redact.
    /// - Throws: `PdfEditError` for a page that isn't there or a PDF that can't be edited; `OwnerPasswordRequired`.
    public static func apply(_ data: [UInt8], _ password: String?, _ areasByPage: [Int: [RectD]], dpi: Double = 300,
                             cancel: CancelToken? = nil) throws -> [UInt8] {
        let pages = areasByPage.filter { $0.value.contains { !$0.isEmpty } }.sorted { $0.key < $1.key }
        if pages.isEmpty { return data }
        let dpi = min(max(dpi, 36), 1200)
        let cleared = try clearRedactedFields(data, password, pages)

        let engine = try PdfEngine.open(cleared, password: password)
        defer { engine.close() }
        return try PageEditor.edit(cleared, password, rewrite: true) { doc in
            let count = try doc.pageCount()
            for (index, areas) in pages {
                guard index >= 0 && index < count && index < engine.pageCount else { throw PdfEditError("There is no page \(index + 1).") }
                try cancel.check()
                let scale = dpi / 72
                let img = try engine.render(index, scale: scale, cancel: cancel)
                var rgb = img.pixels
                for a in areas where !a.isEmpty {
                    let x0 = clamp(Int((a.x * scale).rounded(.down)), img.width), x1 = clamp(Int((a.right * scale).rounded(.up)), img.width)
                    let y0 = clamp(Int((a.y * scale).rounded(.down)), img.height), y1 = clamp(Int((a.bottom * scale).rounded(.up)), img.height)
                    if x1 <= x0 { continue }
                    for y in y0..<max(y0, y1) {
                        let row = (y * img.width + x0) * 3
                        for i in row..<row + (x1 - x0) * 3 { rgb[i] = 0 }
                    }
                }
                replacePage(doc, doc.page(index), img.width, img.height, rgb)
            }
        }
    }

    private static func clamp(_ v: Int, _ hi: Int) -> Int { min(max(v, 0), hi) }

    /// A form field whose widget an area covers loses its value everywhere: its widgets on other pages would otherwise
    /// keep showing it (and /V would keep it in the file). Done first, so the drawn pages already show the field empty.
    private static func clearRedactedFields(_ data: [UInt8], _ password: String?, _ pages: [(key: Int, value: [RectD])]) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        let count = try doc.pageCount()
        var hit = Set<UInt>()
        for (index, areas) in pages where index >= 0 && index < count {
            let page = doc.page(index)
            for w in page.array("Annots")?.elements ?? [] where w.isDict {
                guard w.name("Subtype") == "Widget", let r = w.array("Rect") else { continue }
                let rect = PageBoxes.rectToPage(page, r)
                if areas.contains(where: { !$0.isEmpty && !$0.intersect(rect).isEmpty }) { hit.insert(w.identity) }
            }
        }
        guard !hit.isEmpty, try FormEditor.clearFields(doc, hit) else { return data }
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password, rewrite: true)
    }

    private static func replacePage(_ doc: MuDoc, _ page: PObj, _ width: Int, _ height: Int, _ rgb: [UInt8]) {
        let image = doc.addStream(rgb, dict: doc.dict([
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(width)), ("Height", doc.int(height)),
            ("ColorSpace", doc.name("DeviceRGB")), ("BitsPerComponent", doc.int(8)),
        ]), deflate: true)

        // The picture is upright as displayed; map its unit square onto the (turned) visible box.
        let (dw, dh) = PageBoxes.displaySize(page)
        let o = PageBoxes.toPdf(page, 0, dh), u = PageBoxes.toPdf(page, dw, dh), v = PageBoxes.toPdf(page, 0, 0)
        let f = PdfNum.f
        let ops = "q \(f(u.x - o.x)) \(f(u.y - o.y)) \(f(v.x - o.x)) \(f(v.y - o.y)) \(f(o.x)) \(f(o.y)) cm /PdRedacted Do Q\n"
        let parentKeys = StructTree.parentKeys(page)
        page.set("Contents", doc.addStream(Array(ops.utf8), deflate: false))
        page.set("Resources", doc.dict([("XObject", doc.dict([("PdRedacted", image)]))]))

        var removed = Set<UInt>()
        if let annots = page.array("Annots") {
            let acro = doc.catalog.dict("AcroForm")
            var widgets = false
            for a in annots.elements where a.isDict {
                removed.insert(a.identity)
                if a.name("Subtype") != "Widget" { continue }
                removeWidget(acro, a, &removed)
                widgets = true
            }
            if let acro {
                // Fields dropped above must not stay reachable through the calculation order (with their /V)...
                if let co = acro.array("CO") {
                    for i in stride(from: co.count - 1, through: 0, by: -1) where co[i].map({ $0.isDict && removed.contains($0.identity) }) == true {
                        co.remove(at: i)
                    }
                }
                // ...and an XFA form keeps its own copy of every value (datasets): once a field went, AcroForm fields are
                // what remains. Comments and links alone leave the form (and its XFA) as it was.
                if widgets { acro.remove("XFA") }
            }
            // Annotations elsewhere pointing at removed ones (a popup's /Parent, a reply's /IRT) would keep them reachable.
            if let count = try? doc.pageCount() {
                for i in 0..<count {
                    let other = doc.page(i)
                    if other.identity == page.identity { continue }
                    for a in other.array("Annots")?.elements ?? [] where a.isDict {
                        for key in ["Parent", "IRT"] {
                            if let target = a.dict(key), removed.contains(target.identity) { a.remove(key) }
                        }
                    }
                }
            }
        }
        // What else a page can carry of its old content: thumbnail picture, application data (PieceInfo), separations,
        // article beads, actions, its XMP, and PDF 2.0 associated files (/AF: e.g. the source the page was made from).
        for key in ["Annots", "Thumb", "PieceInfo", "StructParents", "Group", "B", "Metadata", "SeparationInfo", "AA", "AF"] {
            page.remove(key)
        }
        scrubStructure(doc, page, removed)
        StructTree.prune(doc, gonePages: [page], goneKeys: parentKeys) { removed.contains($0.identity) }
    }

    /// Takes a widget out of the field tree, dropping fields left without widgets.
    static func removeWidget(_ acro: PObj?, _ widget: PObj, _ removed: inout Set<UInt>) {
        var node = widget
        for _ in 0..<64 {
            let parent = node.dict("Parent")
            guard let list = parent.map({ $0.array("Kids") }) ?? acro?.array("Fields") else { return }
            for i in stride(from: list.count - 1, through: 0, by: -1) where list[i]?.identity == node.identity && list[i]?.isDict == true {
                list.remove(at: i)
            }
            guard let parent, list.count == 0 else { return }
            node = parent
            removed.insert(node.identity)
        }
    }

    /// Drops what the structure tree keeps of the page: alternate/actual text (it can repeat the redacted words), and
    /// references to its annotations (OBJR, which would keep a widget and its value reachable) and to marked-content
    /// streams (MCR /Stm).
    private static func scrubStructure(_ doc: MuDoc, _ page: PObj, _ removed: Set<UInt>) {
        // Each dictionary and array once: a tree can share them (or loop), and walking every path can take forever.
        var seen = Set<UInt>()
        func visit(_ item: PObj?, _ onPage: Bool, _ depth: Int) {
            guard let item, depth <= 128 else { return }
            if item.isArray {
                guard seen.insert(item.identity).inserted else { return }
                for e in item.elements { visit(e, onPage, depth + 1) }
            } else if item.isDict {
                guard seen.insert(item.identity).inserted else { return }
                var onPage = onPage
                if item.has("Pg") { onPage = item["Pg"]?.identity == page.identity }
                if onPage { for key in ["Alt", "ActualText", "E", "Stm", "StmOwn"] { item.remove(key) } }
                if let obj = item.dict("Obj"), onPage || removed.contains(obj.identity) { item.remove("Obj") }
                visit(item["K"], onPage, depth + 1)
            }
        }
        visit(doc.catalog.dict("StructTreeRoot")?["K"], false, 0)
    }
}

/// Keeps a tagged PDF's structure tree (/StructTreeRoot) consistent when pages lose their content (the Windows app's
/// `StructTree`): marked-content references (MCIDs, MCRs) and object references (OBJR) to those pages are removed,
/// structure elements left without content go too, and the /ParentTree and /IDTree entries that pointed at them are
/// dropped. Nothing in the tree then leads to the removed content, so saving no longer carries it along.
enum StructTree {
    private static let maxDepth = 256

    /// The /ParentTree keys a page uses: its /StructParents and its annotations' /StructParent.
    static func parentKeys(_ page: PObj) -> [Int] {
        var keys: [Int] = []
        if let k = page.int("StructParents") { keys.append(k) }
        for a in page.array("Annots")?.elements ?? [] where a.isDict {
            if let k = a.int("StructParent") { keys.append(k) }
        }
        return keys
    }

    /// - Parameters:
    ///   - gonePages: pages whose content no longer exists.
    ///   - goneKeys: the `parentKeys` of those pages, collected before they were changed.
    ///   - objectGone: objects (annotations) that were removed; OBJRs to them are dropped.
    static func prune(_ doc: MuDoc, gonePages: [PObj], goneKeys: [Int], objectGone: ((PObj) -> Bool)? = nil) {
        guard let root = doc.catalog.dict("StructTreeRoot") else { return }
        var live = Set<UInt>(), liveIds = Set<Int>()
        for i in 0..<((try? doc.pageCount()) ?? 0) {
            let p = doc.page(i)
            live.insert(p.identity)
            if p.isRef { liveIds.insert(p.num) }
        }
        let gone = Set(gonePages.map(\.identity))
        func pageGone(_ pg: PObj?) -> Bool {
            guard let pg, pg.isDict else { return false }
            if gone.contains(pg.identity) { return true }
            if live.contains(pg.identity) { return false }
            return !(pg.isRef && liveIds.contains(pg.num))
        }

        var removed = Set<UInt>()
        var seen = Set<UInt>()

        // Prunes the kids of a node; true when the node had content and has none left.
        func pruneKids(_ node: PObj, _ page: PObj?, _ depth: Int) -> Bool {
            guard let k = node["K"] else { return false }
            if k.isArray {
                if k.count == 0 { return false }
                for i in stride(from: k.count - 1, through: 0, by: -1) where !keep(k[i], page, depth + 1) { k.remove(at: i) }
                if k.count > 0 { return false }
            } else if keep(k, page, depth + 1) {
                return false
            }
            node.remove("K")
            return true
        }

        func keep(_ item: PObj?, _ page: PObj?, _ depth: Int) -> Bool {
            guard let item, depth <= maxDepth else { return true }
            if item.kind == .int { return !pageGone(page) }
            guard item.isDict else { return true }
            let type = item.name("Type")
            let pg = item.has("Pg") ? item["Pg"] : page
            if type == "MCR" { return !pageGone(pg) }
            if type == "OBJR" {
                if pageGone(pg) { return false }
                guard let obj = item.dict("Obj") else { return false }
                return !(objectGone?(obj) == true || (obj.has("P") && pageGone(obj["P"])))
            }
            if !seen.insert(item.identity).inserted { return !removed.contains(item.identity) }
            let empty = pruneKids(item, pg, depth)
            let ownGone = item.has("Pg") && pageGone(item["Pg"])
            if empty || (ownGone && !item.has("K")) {
                removed.insert(item.identity)
                // Still referenced elsewhere (an outline's /SE, a stale parent tree)? Then at least lead nowhere.
                item.remove("Pg")
                item.remove("K")
                return false
            }
            if ownGone { item.remove("Pg") } // its remaining content names its own pages
            return true
        }

        _ = pruneKids(root, nil, 0)

        let keys = Set(goneKeys)
        editTree(root.dict("ParentTree"), "Nums") { key, value in
            if let n = key.int, keys.contains(n) { return false }
            guard let value else { return true }
            if value.isArray {
                var any = false
                for i in 0..<value.count {
                    if let e = value[i], e.isDict, removed.contains(e.identity) {
                        value.replace(at: i, with: doc.null)
                    } else if let e = value[i], e.kind != .null {
                        any = true
                    }
                }
                return any
            }
            if value.isDict { return !removed.contains(value.identity) }
            return true
        }
        editTree(root.dict("IDTree"), "Names") { _, value in
            guard let value, value.isDict else { return true }
            return !removed.contains(value.identity)
        }
    }

    /// Removes the key/value pairs of a name or number tree that `keep` rejects.
    private static func editTree(_ node: PObj?, _ pairsKey: String, _ depth: Int = 0, _ keep: (PObj, PObj?) -> Bool) {
        guard let node, depth <= 64 else { return }
        if let pairs = node.array(pairsKey) {
            for i in stride(from: (pairs.count & ~1) - 2, through: 0, by: -2) {
                guard let key = pairs[i] else { continue }
                if !keep(key, pairs[i + 1]) {
                    pairs.remove(at: i + 1)
                    pairs.remove(at: i)
                }
            }
        }
        for kid in node.array("Kids")?.elements ?? [] where kid.isDict { editTree(kid, pairsKey, depth + 1, keep) }
    }
}
