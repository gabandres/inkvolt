import Foundation
import MuPDFShim

extension AutoTag {
    /// Writes the plan's tags (see the type's remarks). Tags the document already had are replaced. A signed document's edit
    /// is appended after its signed bytes when it can be (`PdfEdit.save`).
    /// - Throws: `SignaturesWouldBreak` for a signed document whose edit can't be appended; `OwnerPasswordRequired` for an
    ///   encrypted document opened without its permissions password; `CancellationError` when `cancel` fired.
    public static func write(_ data: [UInt8], _ password: String?, _ plan: TagPlan, _ options: AccessibleOptions = AccessibleOptions(),
                             cancel: CancelToken? = nil) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password, failure: "This PDF can't be tagged")
        try Writer(doc, plan, options, cancel).run()
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    static func resources(_ page: PObj) -> PObj? {
        guard let r = FormEditor.inherited(page, "Resources"), r.isDict else { return nil }
        return r
    }

    /// A structure element while it is being built: its object and what will be in its /K.
    private final class Node {
        enum Kid {
            case node(Node)
            case mcid(Int)
            case objr(PObj)
        }

        let ref: PObj
        let type: String
        var kids: [Kid] = []
        var leaf: Leaf?

        init(_ ref: PObj, _ type: String) {
            self.ref = ref
            self.type = type
        }
    }

    /// A structure element that holds content directly (P, H1, LBody, TD, Figure…), with where its content is. Without a
    /// node: a decorative figure, whose content becomes an artifact.
    private final class Leaf {
        let node: Node?
        let type: String
        let page: Int
        let sources: [RectD]
        let figure: Bool
        /// Pictures in a table cell (their content goes in the cell).
        let pictures: [RectD]
        /// Everything it holds, to skip what can't overlap (the sums below are over many text runs).
        let bounds: RectD
        /// Link elements inside it, by the link's index on the page.
        var links: [Int: Node] = [:]
        /// Elements after its content: a list nested in a list item's body, contents nested under an entry.
        var tail: [Node] = []

        init(_ node: Node?, _ type: String, _ page: Int, _ sources: [RectD], figure: Bool = false, pictures: [RectD] = []) {
            self.node = node
            self.type = type
            self.page = page
            self.sources = sources
            self.figure = figure
            self.pictures = pictures
            bounds = AutoTag.bounds(sources + pictures)
        }
    }

    /// Where a piece of content goes: an element's leaf (and maybe a link inside it), an artifact, or left as it is.
    private struct Target: Equatable {
        var leaf: Leaf?
        var link = -1
        var artifact = false
        var running = false

        static let leave = Target()
        static let decor = Target(artifact: true)
        static let page = Target(artifact: true, running: true)
        var none: Bool { leaf == nil && !artifact }

        static func == (a: Target, b: Target) -> Bool {
            a.leaf === b.leaf && a.link == b.link && a.artifact == b.artifact && a.running == b.running
        }
    }

    private final class Writer {
        private let doc: MuDoc
        private let plan: TagPlan
        private let options: AccessibleOptions
        private let cancel: CancelToken?
        private var nodes: [Node] = []
        private var leaves: [Int: [Leaf]] = [:]
        private var parentTree: [(key: Int, value: PObj)] = []
        private var root: PObj!
        private var document: Node!
        private var pages: [PObj] = []
        private var nextKey = 0
        private var notes = 0
        private var unmarked = Set<UInt>()
        private let shared: WalkShared

        init(_ doc: MuDoc, _ plan: TagPlan, _ options: AccessibleOptions, _ cancel: CancelToken?) {
            self.doc = doc
            self.plan = plan
            self.options = options
            self.cancel = cancel
            shared = WalkShared(cancel)
        }

        func run() throws {
            let catalog = doc.catalog
            pages = try doc.pages()
            let hadTags = catalog.has("StructTreeRoot")
            if hadTags { try removeTags() }

            root = doc.add(doc.dict([("Type", doc.name("StructTreeRoot"))]))
            document = elem("Document", root)
            root.set("K", doc.array([document.ref]))

            // Top-level elements per page in reading order; what each page adds after its blocks (fields, comments, links
            // without text).
            let blocks = AutoTag.evenHeadings(plan.blocks)
            var top: [(page: Int, node: Node)] = []
            func tableAt(_ k: Int, _ page: Int) -> Bool { blocks.indices.contains(k) && blocks[k].kind == .table && blocks[k].page == page }
            var i = 0
            while i < blocks.count {
                let b = blocks[i]
                // A caption right before or after its table goes inside it (first or last part; one per table); a figure's
                // stands beside the figure (the figure's alternate text replaces what is inside it).
                if b.kind == .caption && tableAt(i + 1, b.page) {
                    i += 1
                    continue
                }
                var above: TagBlock?, below: TagBlock?
                if b.kind == .table {
                    if i > 0 && blocks[i - 1].kind == .caption && blocks[i - 1].page == b.page {
                        above = blocks[i - 1]
                    } else if i + 1 < blocks.count && blocks[i + 1].kind == .caption && blocks[i + 1].page == b.page && !tableAt(i + 2, b.page) {
                        below = blocks[i + 1]
                    }
                }
                // Its page for what each page adds after its blocks: the one it is read with.
                if let e = block(b, above, below) { top.append((AutoTag.readingPage(b), e)) }
                i += below != nil ? 2 : 1
            }

            var extras: [Int: [Node]] = [:]
            for p in pages.indices {
                try cancel?.check()
                let page = pages[p]
                let running = p < plan.running.count ? plan.running[p] : []
                var more: [Node] = []
                try tagPage(page, p, leaves[p] ?? [], running, &more, strip: hadTags)
                extras[p] = more
                page.set("Tabs", doc.name("S"))
            }

            // The Document's kids: each page's blocks, then its extras (also for pages without blocks).
            var flushed = -1
            func flush(_ upTo: Int) {
                var p = flushed + 1
                while p <= upTo {
                    for e in extras[p] ?? [] { document.kids.append(.node(e)) }
                    p += 1
                }
                flushed = max(flushed, upTo)
            }
            for (page, e) in top {
                flush(page - 1)
                document.kids.append(.node(e))
            }
            flush(pages.count - 1)

            for list in leaves.values {
                for leaf in list {
                    for t in leaf.tail { leaf.node?.kids.append(.node(t)) }
                }
            }
            _ = prune(document)
            for n in nodes {
                if n.kids.isEmpty {
                    n.ref.remove("K")
                } else if n.kids.count == 1, case .mcid(let id) = n.kids[0] {
                    n.ref.set("K", doc.int(id))
                } else {
                    n.ref.set("K", doc.array(n.kids.map { kid in
                        switch kid {
                        case .node(let c): c.ref
                        case .mcid(let id): doc.int(id)
                        case .objr(let o): o
                        }
                    }))
                }
            }

            let nums = doc.array()
            for (key, value) in parentTree.sorted(by: { $0.key < $1.key }) {
                nums.append(doc.int(key))
                nums.append(value)
            }
            root.set("ParentTree", doc.add(doc.dict([("Nums", nums)])))
            root.set("ParentTreeNextKey", doc.int(nextKey))
            catalog.set("StructTreeRoot", root)

            catalog.set("MarkInfo", doc.dict([("Marked", doc.bool(true))]))
            if let lang = options.language ?? plan.language, !lang.isEmpty { catalog.set("Lang", doc.text(lang)) }
            if let prefs = catalog.dict("ViewerPreferences") {
                prefs.set("DisplayDocTitle", doc.bool(true))
            } else {
                catalog.set("ViewerPreferences", doc.dict([("DisplayDocTitle", doc.bool(true))]))
            }
            if let title = options.title ?? plan.title, !title.isEmpty { InfoDict.set(doc, "Title", title.trimmedWS) }
            let version = Int(inkv_pdf_version(doc.ctx, doc.doc))
            if version < 14 || version > 17 { // PDF/UA-1 is PDF 1.7
                catalog.remove("Version")
                doc.note { inkv_set_pdf_version(doc.ctx, doc.doc, 17, $0) }
            }
            InfoDict.setDate(doc, "ModDate", Date())
            // PDF/UA wants every font embedded: the standard faces can be, from the Mac's metric twins.
            try PdfA.embedStandardFonts(doc)
            // Characters with no Unicode value (TeX's math glyphs) get one, so they are read aloud.
            try FontUnicode.complete(doc)
            Xmp.markPdfUa(doc)
        }

        // ───────────────────────────── elements ─────────────────────────────

        private func elem(_ type: String, _ parent: PObj) -> Node {
            let ref = doc.add(doc.dict([("Type", doc.name("StructElem")), ("S", doc.name(type)), ("P", parent)]))
            let n = Node(ref, type)
            nodes.append(n)
            return n
        }

        private func child(_ type: String, _ parent: Node) -> Node {
            let e = elem(type, parent.ref)
            parent.kids.append(.node(e))
            return e
        }

        @discardableResult
        private func newLeaf(_ node: Node, _ page: Int, _ sources: [RectD], figure: Bool = false, pictures: [RectD] = []) -> Leaf {
            let leaf = Leaf(node, node.type, page, sources, figure: figure, pictures: pictures)
            node.leaf = leaf
            node.ref.set("Pg", pages[page])
            leaves[page, default: []].append(leaf)
            return leaf
        }

        /// A block's element (not yet in the Document's kids), or nil when it adds none (a decorative figure). A table's
        /// caption comes as `above` or `below` it.
        private func block(_ b: TagBlock, _ above: TagBlock?, _ below: TagBlock?) -> Node? {
            guard pages.indices.contains(b.page) else { return nil }
            switch b.kind {
            case .paragraph, .heading, .caption, .note:
                let type = b.kind == .heading ? "H\(max(1, min(6, b.level)))" : b.kind == .caption ? "Caption" : b.kind == .note ? "Note" : "P"
                let e = elem(type, document.ref)
                if let lang = b.lang, !lang.isEmpty { e.ref.set("Lang", doc.text(lang)) }
                // A note's ID is unique in the document (PDF/UA 7.9).
                if b.kind == .note {
                    notes += 1
                    e.ref.set("ID", doc.text("note-\(notes)"))
                }
                newLeaf(e, b.page, b.sources)
                return e
            case .list:
                return nested(b, "L", "LI", "LBody")
            case .contents:
                return nested(b, "TOC", "TOCI", nil)
            case .formula:
                let e = elem("Formula", document.ref)
                let alt = (b.alt ?? "").isBlank ? b.text : b.alt!
                if !alt.isBlank { e.ref.set("Alt", doc.text(alt.trimmedWS)) }
                e.ref.set("A", layoutBox(b))
                newLeaf(e, b.page, b.sources)
                return e
            case .table:
                let t = elem("Table", document.ref)
                if let above { newLeaf(child("Caption", t), above.page, above.sources) }
                for r in b.rows.indices {
                    let tr = child("TR", t)
                    for k in b.rows[r].indices {
                        let cell = b.rows[r][k]
                        let column = r < b.headerRows
                        let row = !column && k == 0 && b.headerColumn
                        let c = child(column || row ? "TH" : "TD", tr)
                        if column || row || cell.colSpan > 1 {
                            let a = doc.dict([("O", doc.name("Table"))])
                            if column || row { a.set("Scope", doc.name(column ? "Column" : "Row")) }
                            if cell.colSpan > 1 { a.set("ColSpan", doc.int(cell.colSpan)) }
                            c.ref.set("A", a)
                        }
                        newLeaf(c, b.page, cell.sources, pictures: cell.pictures)
                    }
                }
                if let below { newLeaf(child("Caption", t), below.page, below.sources) }
                return t
            case .figure:
                if b.decorative {
                    // Its content becomes an artifact: a leaf that isn't in the tree.
                    leaves[b.page, default: []].append(Leaf(nil, "", b.page, b.sources, figure: true))
                    return nil
                }
                let e = elem("Figure", document.ref)
                if let alt = b.alt, !alt.isBlank { e.ref.set("Alt", doc.text(alt.trimmedWS)) }
                e.ref.set("A", layoutBox(b))
                newLeaf(e, b.page, b.sources, figure: true)
                return e
            }
        }

        /// A Layout attribute with the block's bounding box in the page's PDF space (figures and formulas).
        private func layoutBox(_ b: TagBlock) -> PObj {
            let r = PageBoxes.fromPageSpace(pages[b.page], b.box)
            return doc.dict([("O", doc.name("Layout")), ("Placement", doc.name("Block")), ("BBox", doc.reals(r.x1, r.y1, r.x2, r.y2))])
        }

        /// A list (L › LI › LBody) or table of contents (TOC › TOCI) with its items nested by level: a deeper item starts a
        /// list (or contents) of its own after the content of the item before it, inside that item's body (or entry).
        private func nested(_ b: TagBlock, _ container: String, _ item: String, _ body: String?) -> Node {
            let top = elem(container, document.ref)
            var stack: [(level: Int, container: Node, last: Leaf?)] = [(0, top, nil)]
            for it in b.items {
                while stack.count > 1 && stack[stack.count - 1].level > it.level { stack.removeLast() }
                if it.level > stack[stack.count - 1].level, let last = stack[stack.count - 1].last, let owner = last.node {
                    let inner = elem(container, owner.ref)
                    last.tail.append(inner)
                    stack.append((it.level, inner, nil))
                }
                let li = child(item, stack[stack.count - 1].container)
                let leaf = newLeaf(body.map { child($0, li) } ?? li, b.page, it.sources)
                stack[stack.count - 1].last = leaf
            }
            return top
        }

        /// Removes elements left without content (a paragraph whose text wasn't found); true when `e` is empty.
        private func prune(_ e: Node, _ depth: Int = 0) -> Bool {
            if depth > 64 { return false }
            if let leaf = e.leaf {
                // Its nested list or contents goes when nothing in it was found.
                e.kids.removeAll { kid in
                    guard case .node(let k) = kid, leaf.tail.contains(where: { $0 === k }) else { return false }
                    return prune(k, depth + 1)
                }
                return e.kids.isEmpty
            }
            e.kids.removeAll { kid in
                guard case .node(let k) = kid, prune(k, depth + 1) else { return false }
                // A table keeps its empty cells (rows stay the same length); an empty row or table goes.
                return k.type != "TD" && k.type != "TH"
            }
            if e.type == "TR" && e.kids.allSatisfy({ if case .node(let c) = $0 { c.kids.isEmpty } else { false } }) { return true }
            return e.kids.isEmpty
        }

        // ───────────────────────────── a page ─────────────────────────────

        private func tagPage(_ page: PObj, _ index: Int, _ leaves: [Leaf], _ running: [RectD], _ extras: inout [Node], strip: Bool) throws {
            let annots = page.array("Annots")?.elements.filter(\.isDict) ?? []
            let links: [(annot: PObj, box: RectD)] = annots.filter { $0.name("Subtype") == "Link" && $0.array("Rect") != nil }
                .map { ($0, PageBoxes.rectToPage(page, $0.array("Rect"))) }

            let content = ContentEditor.contentBytes(page)
            let walk = PageWalk(PageBoxes.frame(page), AutoTag.resources(page), shared)
            let ops = try ContentLexer.parse(content, cancel: cancel)
            let items = try walk.items(ops, strip: strip)
            var linkText = [String](repeating: "", count: links.count)

            func assign(_ it: Item) -> Target {
                if it.inArtifact || it.artifactOnly { return .leave }
                switch it.kind {
                case .text, .form where it.hasText:
                    var best: Leaf?
                    var bestScore = 0.0
                    for l in leaves where overlaps(it.box, l.bounds) {
                        var s = 0.0
                        for src in l.sources { s += AutoTag.area(it.box.intersect(src)) }
                        if s > bestScore {
                            bestScore = s
                            best = l
                        }
                    }
                    let runScore = running.reduce(0.0) { $0 + AutoTag.area(it.box.intersect($1)) }
                    if runScore > bestScore { return .page }
                    if best == nil {
                        if it.kind == .text && it.text.isBlank { return .decor }
                        // Not where the layout found text (a stray mark, text it dropped): the nearest text block.
                        let (cx, cy) = (it.box.centerX, it.box.centerY)
                        var nearest = Double.infinity
                        for l in leaves where !l.figure && !l.sources.isEmpty {
                            let d = l.sources.reduce(Double.infinity) { min($0, distance($1, cx, cy)) }
                            if d < 24 && d < nearest {
                                nearest = d
                                best = l
                            }
                        }
                        if best == nil { best = leaves.first { l in l.figure && l.sources.contains { $0.inflate(2).contains(cx, cy) } } }
                        if best == nil { return .decor }
                    }
                    let found = best!
                    if found.type.isEmpty { return .decor }
                    if !found.figure {
                        for k in links.indices where links[k].box.inflate(1).contains(it.box.centerX, it.box.centerY) {
                            linkText[k] += it.text
                            return Target(leaf: found, link: k)
                        }
                    }
                    return Target(leaf: found)
                case .image, .form:
                    let whole = max(1, AutoTag.area(it.box))
                    if running.reduce(0.0, { $0 + AutoTag.area(it.box.intersect($1)) }) > 0.5 * whole { return .page }
                    var best: Leaf?
                    var bestScore = 0.0
                    for l in leaves where overlaps(it.box, l.bounds) {
                        let list = l.figure ? l.sources : l.pictures
                        let s = list.reduce(0.0) { $0 + AutoTag.area(it.box.intersect($1)) }
                        let total = list.reduce(0.0) { $0 + AutoTag.area($1) }
                        if s >= 0.3 * min(whole, max(1, total)) && s > bestScore {
                            bestScore = s
                            best = l
                        }
                    }
                    guard let best, !best.type.isEmpty else { return .decor }
                    return Target(leaf: best)
                case .path, .shading: // part of a chart or diagram, or decoration (rules, backgrounds, underlines)
                    let (cx, cy) = (it.box.centerX, it.box.centerY)
                    let fig = leaves.first { l in
                        l.figure && l.sources.contains { s in
                            let i = s.inflate(2)
                            return i.contains(cx, cy) && i.contains(it.box.x, it.box.y) && i.contains(it.box.right, it.box.bottom)
                        }
                    }
                    guard let fig, !fig.type.isEmpty else { return .decor }
                    return Target(leaf: fig)
                }
            }

            // Marked content around each run of items that go to the same place.
            var output: [UInt8] = []
            output.reserveCapacity(content.count + items.count * 24)
            var cursor = 0
            func emit(_ at: Int, _ text: String, remove: Int = 0) {
                let at = max(cursor, min(at, content.count))
                output += content[cursor..<at]
                output += latin1Bytes(text)
                cursor = min(content.count, at + remove)
            }
            var mcids: [PObj] = []
            var open: Target?
            func close(_ at: Int) {
                guard open != nil else { return }
                emit(at, "\nEMC\n")
                open = nil
            }
            func start(_ at: Int, _ t: Target) {
                if t.artifact {
                    emit(at, t.running ? "\n/Artifact <</Type /Pagination>> BDC\n" : "\n/Artifact BMC\n")
                    open = t
                    return
                }
                let leaf = t.leaf!
                var owner = leaf.node!
                var type = leaf.type
                if t.link >= 0 {
                    if leaf.links[t.link] == nil {
                        let link = elem("Link", owner.ref)
                        link.ref.set("Pg", page)
                        owner.kids.append(.node(link))
                        leaf.links[t.link] = link
                    }
                    owner = leaf.links[t.link]!
                    type = "Link"
                }
                let mcid = mcids.count
                mcids.append(owner.ref)
                owner.kids.append(.mcid(mcid))
                emit(at, "\n/\(type) <</MCID \(mcid)>> BDC\n")
                open = t
            }

            var next = 0
            var spanEnd = -1
            for i in ops.indices {
                let op = ops[i]
                if spanEnd >= 0 {
                    emit(spanEnd, "\nEMC\n")
                    spanEnd = -1
                }
                switch op.name {
                case "BT", "ET", "q", "Q", "BMC", "BDC", "EMC": close(op.start)
                default: break
                }
                if let instead = walk.stripped[i] {
                    emit(op.start, instead, remove: op.end - op.start)
                    continue
                }
                while next < items.count && items[next].startOp < i { next += 1 }
                if next >= items.count || items[next].startOp != i { continue }
                let item = items[next]
                let t = assign(item)
                if let o = open, o != t { close(op.start) }
                if open == nil && !t.none { start(op.start, t) }
                // A form drawn inside our marked content can't mark artifacts of its own (they'd be nested): they go.
                if !t.none, item.hasArtifact, let form = item.form { try unmarkArtifacts(form) }
                // Characters a font maps into the Private Use Area (Word's Symbol and Wingdings bullets) say what they are.
                if !t.none, item.kind == .text, item.startOp == item.endOp, let actual = AutoTag.actualText(item.text) {
                    let hex = actual.utf16.map { String(format: "%04X", $0) }.joined()
                    emit(op.start, "\n/Span <</ActualText <FEFF\(hex)>>> BDC\n")
                    spanEnd = op.end
                }
            }
            if spanEnd >= 0 { emit(spanEnd, "\nEMC\n") }
            close(content.count)
            output += content[cursor...]

            page.set("Contents", doc.addStream(output, deflate: true))
            if !mcids.isEmpty {
                let key = nextKey
                nextKey += 1
                page.set("StructParents", doc.int(key))
                parentTree.append((key, doc.array(mcids)))
            } else {
                page.remove("StructParents")
            }

            // Links: the annotation goes in its Link element (one with text when there is one).
            for k in links.indices {
                let annot = links[k].annot
                var link = leaves.lazy.compactMap { $0.links[k] }.first
                if link == nil {
                    let made = elem("Link", document.ref)
                    made.ref.set("Pg", page)
                    extras.append(made)
                    link = made
                }
                objr(link!, annot, page)
                if (annot.text("Contents") ?? "").isBlank {
                    let text = linkText[k].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    let uri = annot.dict("A")?.text("URI")
                    let say = !text.isEmpty ? text : (uri ?? "").isEmpty ? "Link" : "Link to \(uri!)"
                    annot.set("Contents", doc.text(say))
                }
            }
            // Form fields and comments: Form and Annot elements after the page's blocks.
            for a in annots {
                let sub = a.name("Subtype") ?? ""
                if sub == "Link" || sub == "Popup" || sub == "PrinterMark" || sub.isEmpty { continue }
                let e = elem(sub == "Widget" ? "Form" : "Annot", document.ref)
                e.ref.set("Pg", page)
                objr(e, a, page)
                extras.append(e)
            }
        }

        private func overlaps(_ a: RectD, _ b: RectD) -> Bool {
            a.x < b.right && b.x < a.right && a.y < b.bottom && b.y < a.bottom
        }

        private func distance(_ r: RectD, _ x: Double, _ y: Double) -> Double {
            let dx = max(0, max(r.x - x, x - r.right))
            let dy = max(0, max(r.y - y, y - r.bottom))
            return (dx * dx + dy * dy).squareRoot()
        }

        /// Removes a form's own artifact marked content (its operators, not what they enclose).
        private func unmarkArtifacts(_ form: PObj) throws {
            guard unmarked.insert(form.identity).inserted, let bytes = form.streamData else { return }
            let ops = try ContentLexer.parse(bytes, cancel: cancel)
            var drop: [Int] = []
            var stack: [Bool] = []
            for i in ops.indices {
                if ops[i].name == "BMC" || ops[i].name == "BDC" {
                    let artifact = ops[i].operands.first.map { $0.kind == .name && $0.name == "Artifact" } ?? false
                    stack.append(artifact)
                    if artifact { drop.append(i) }
                } else if ops[i].name == "EMC", let was = stack.popLast(), was {
                    drop.append(i)
                }
            }
            if drop.isEmpty { return }
            form.setStream(rewritten(bytes, drop.map { (ops[$0], " ") }), deflate: true)
        }

        private func rewritten(_ bytes: [UInt8], _ changes: [(COp, String)]) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var at = 0
            for (op, instead) in changes where op.start >= at {
                out += bytes[at..<op.start]
                out += latin1Bytes(instead)
                at = op.end
            }
            out += bytes[at...]
            return out
        }

        private func objr(_ e: Node, _ annot: PObj, _ page: PObj) {
            e.kids.append(.objr(doc.dict([("Type", doc.name("OBJR")), ("Obj", annot), ("Pg", page)])))
            let key = nextKey
            nextKey += 1
            annot.set("StructParent", doc.int(key))
            parentTree.append((key, e.ref))
        }

        /// The tags the document had: the tree, its keys on pages, annotations and forms (their marked content goes as each stream is rewritten).
        private func removeTags() throws {
            doc.catalog.remove("StructTreeRoot")
            var seen = Set<UInt>()
            for page in pages {
                page.remove("StructParents")
                for a in page.array("Annots")?.elements ?? [] where a.isDict { a.remove("StructParent") }
                try stripForms(AutoTag.resources(page), 0, &seen)
            }
        }

        /// Forms drawn on a page that had marked content of their own (StructParents): their MCIDs go.
        private func stripForms(_ resources: PObj?, _ depth: Int, _ seen: inout Set<UInt>) throws {
            guard depth <= 8, let xs = resources?.dict("XObject") else { return }
            for key in xs.keys {
                guard let x = xs.dict(key), x.isStream, seen.insert(x.identity).inserted, x.name("Subtype") == "Form" else { continue }
                let sub = x.dict("Resources")
                if x.has("StructParents") || x.has("StructParent") {
                    x.remove("StructParents")
                    x.remove("StructParent")
                    if let bytes = x.streamData {
                        let ops = try ContentLexer.parse(bytes, cancel: cancel)
                        let walk = PageWalk(nil, sub, shared)
                        _ = try walk.items(ops, strip: true)
                        if !walk.stripped.isEmpty {
                            x.setStream(rewritten(bytes, walk.stripped.sorted { $0.key < $1.key }.map { (ops[$0.key], $0.value) }), deflate: true)
                        }
                    }
                }
                try stripForms(sub, depth + 1, &seen)
            }
        }
    }

    /// Private Use Area characters the symbol fonts use for bullets and marks, as the characters they show.
    private static let puaSymbols: [UInt32: String] = [
        0xF0B7: "\u{2022}", 0xF0A7: "\u{25AA}", 0xF06C: "\u{25CF}", 0xF06E: "\u{25A0}", 0xF0D8: "\u{27A2}", 0xF0FC: "\u{2713}",
        0xF076: "\u{2756}", 0xF0B0: "\u{B0}", 0xF0B4: "\u{D7}", 0xF0B1: "\u{B1}", 0xF0E0: "\u{2192}", 0xF0A8: "\u{25C6}",
    ]

    /// The text with Private Use Area characters replaced (unknown ones dropped), or nil when it has none.
    fileprivate static func actualText(_ text: String) -> String? {
        func isPua(_ u: Unicode.Scalar) -> Bool { (0xE000...0xF8FF).contains(u.value) }
        guard text.unicodeScalars.contains(where: isPua) else { return nil }
        var out = ""
        for u in text.unicodeScalars {
            if isPua(u) {
                out += puaSymbols[u.value] ?? ""
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    // ───────────────────────────── reading content ─────────────────────────────

    fileprivate enum ItemKind { case text, image, path, shading, form }

    /// One thing a content stream draws: from its first operator to its last (a path from its first point to its paint).
    fileprivate struct Item {
        var startOp: Int
        var endOp: Int
        var kind: ItemKind
        var box: RectD
        var text = ""
        var inArtifact: Bool
        var hasText = false
        /// A form whose own content marks some of what it draws as artifacts (all of it: `artifactOnly`).
        var form: PObj?
        var hasArtifact = false
        var artifactOnly = false
    }

    /// What every walk over one document shares: fonts once each, and what each form holds once each. A form that draws
    /// itself, or a chain of forms drawing each other many times over, ends here instead of recursing without end.
    fileprivate final class WalkShared {
        let cancel: CancelToken?
        var fonts: [ObjId: TextFont] = [:]
        var forms: [UInt: (hasText: Bool, hasArtifact: Bool, artifactOnly: Bool)] = [:]
        var walking = Set<UInt>()

        init(_ cancel: CancelToken?) { self.cancel = cancel }
    }

    /// Walks a content stream for what it draws and where (page space as shown): text shown, images, paths, shadings and
    /// forms. Notes the marked content around each item (inside an artifact already, it is left alone), and with `strip` the
    /// BDC operators that carry an MCID and their EMC (tags being replaced) in `stripped`.
    fileprivate final class PageWalk {
        /// Operators to replace (by index): an MCID's BDC and its EMC by nothing, an artifact's BDC with an MCID by a plain BMC.
        private(set) var stripped: [Int: String] = [:]
        private let frame: PageFrame?
        private let resources: PObj?
        private let shared: WalkShared
        private let depth: Int

        init(_ frame: PageFrame?, _ resources: PObj?, _ shared: WalkShared, depth: Int = 0) {
            self.frame = frame
            self.resources = resources
            self.shared = shared
            self.depth = depth
        }

        private struct State {
            var ctm = ContentEditor.Mat.identity
            var font: PObj?
            var size = 12.0, charSpace = 0.0, wordSpace = 0.0, scale = 1.0, leading = 0.0, rise = 0.0
        }

        func items(_ ops: [COp], strip: Bool) throws -> [Item] {
            typealias Mat = ContentEditor.Mat
            var items: [Item] = []
            var st = State()
            var stack: [State] = []
            var tm = Mat.identity, tlm = Mat.identity
            var path: [(Double, Double)] = []
            var pathStart = -1
            var marks: [(artifact: Bool, strip: Bool)] = []
            var artifacts = 0
            for i in ops.indices {
                if i & 4095 == 0 { try shared.cancel?.check() }
                let op = ops[i]
                let inArtifact = artifacts > 0
                let count = op.operands.count
                switch op.name {
                case "q":
                    if stack.count < 256 { stack.append(st) }
                case "Q":
                    if let s = stack.popLast() { st = s }
                case "cm" where count >= 6:
                    st.ctm = Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5)).times(st.ctm)
                case "BMC", "BDC":
                    let tag = op.operands.first.flatMap { $0.kind == .name ? $0.name : nil } ?? ""
                    var hasMcid = false
                    if op.name == "BDC" && count > 1 {
                        let props = op.operands[1]
                        hasMcid = props.kind == .dict ? props["MCID"] != nil
                            : props.kind == .name && resources?.dict("Properties")?.dict(props.name)?.has("MCID") == true
                    }
                    let drop = strip && hasMcid && tag != "Artifact"
                    if drop {
                        stripped[i] = " "
                    } else if strip && hasMcid {
                        stripped[i] = " /Artifact BMC "
                    }
                    marks.append((tag == "Artifact", drop))
                    if tag == "Artifact" { artifacts += 1 }
                case "EMC":
                    if let m = marks.popLast() {
                        if m.strip { stripped[i] = " " }
                        if m.artifact { artifacts -= 1 }
                    }
                case "BT":
                    tm = .identity
                    tlm = .identity
                case "Tf" where count >= 2:
                    st.font = op.operands[0].kind == .name ? resources?.dict("Font")?.dict(op.operands[0].name) : nil
                    st.size = op.n(1)
                case "Tc" where count >= 1: st.charSpace = op.n(0)
                case "Tw" where count >= 1: st.wordSpace = op.n(0)
                case "Tz" where count >= 1: st.scale = op.n(0) / 100
                case "TL" where count >= 1: st.leading = op.n(0)
                case "Ts" where count >= 1: st.rise = op.n(0)
                case "Td" where count >= 2:
                    tlm = Mat(1, 0, 0, 1, op.n(0), op.n(1)).times(tlm)
                    tm = tlm
                case "TD" where count >= 2:
                    st.leading = -op.n(1)
                    tlm = Mat(1, 0, 0, 1, op.n(0), op.n(1)).times(tlm)
                    tm = tlm
                case "Tm" where count >= 6:
                    tlm = Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5))
                    tm = tlm
                case "T*":
                    tlm = Mat(1, 0, 0, 1, 0, -st.leading).times(tlm)
                    tm = tlm
                case "Tj", "'", "\"", "TJ":
                    if op.name == "'" || op.name == "\"" {
                        if op.name == "\"" && count >= 3 {
                            st.wordSpace = op.n(0)
                            st.charSpace = op.n(1)
                        }
                        tlm = Mat(1, 0, 0, 1, 0, -st.leading).times(tlm)
                        tm = tlm
                    }
                    let begin = tm
                    var text = ""
                    for o in op.operands {
                        if o.kind == .string {
                            show(o.bytes, st, &tm, &text)
                        } else if o.kind == .array {
                            for item in o.items {
                                if item.kind == .string {
                                    show(item.bytes, st, &tm, &text)
                                } else if item.kind == .number {
                                    tm = Mat(1, 0, 0, 1, -item.num / 1000 * st.size * st.scale, 0).times(tm)
                                    if item.num < -200 { text += " " } // a gap that reads as a space
                                }
                            }
                        }
                    }
                    items.append(Item(startOp: i, endOp: i, kind: .text, box: textBox(begin, tm, st), text: text, inArtifact: inArtifact))
                case "m", "l":
                    guard count >= 2 else { break }
                    if pathStart < 0 { pathStart = i }
                    path.append((op.n(0), op.n(1)))
                case "c":
                    guard count >= 6 else { break }
                    if pathStart < 0 { pathStart = i }
                    path += [(op.n(0), op.n(1)), (op.n(2), op.n(3)), (op.n(4), op.n(5))]
                case "v", "y":
                    guard count >= 4 else { break }
                    if pathStart < 0 { pathStart = i }
                    path += [(op.n(0), op.n(1)), (op.n(2), op.n(3))]
                case "re":
                    guard count >= 4 else { break }
                    if pathStart < 0 { pathStart = i }
                    path += [(op.n(0), op.n(1)), (op.n(0) + op.n(2), op.n(1) + op.n(3))]
                case "h", "W", "W*":
                    if pathStart < 0 { pathStart = i }
                case "f", "F", "f*", "B", "B*", "b", "b*", "S", "s":
                    items.append(Item(startOp: pathStart < 0 ? i : pathStart, endOp: i, kind: .path, box: box(path, st.ctm), inArtifact: inArtifact))
                    path.removeAll(keepingCapacity: true)
                    pathStart = -1
                case "n":
                    path.removeAll(keepingCapacity: true)
                    pathStart = -1
                case "sh":
                    items.append(Item(startOp: i, endOp: i, kind: .shading, box: box([(0, 0), (1, 1)], st.ctm), inArtifact: inArtifact))
                case "BI":
                    items.append(Item(startOp: i, endOp: i, kind: .image, box: box([(0, 0), (1, 1), (0, 1), (1, 0)], st.ctm), inArtifact: inArtifact))
                case "Do":
                    guard count > 0, op.operands[0].kind == .name, let x = resources?.dict("XObject")?.dict(op.operands[0].name) else { break }
                    let sub = x.name("Subtype")
                    if sub == "Image" {
                        items.append(Item(startOp: i, endOp: i, kind: .image, box: box([(0, 0), (1, 1), (0, 1), (1, 0)], st.ctm), inArtifact: inArtifact))
                    } else if sub == "Form" {
                        var m = Mat.identity
                        if let a = x.array("Matrix"), a.count == 6 { m = Mat(a.num(0), a.num(1), a.num(2), a.num(3), a.num(4), a.num(5)) }
                        var corners: [(Double, Double)] = [(0, 0), (1, 1)]
                        if let b = x.array("BBox"), b.count == 4 {
                            corners = [(b.num(0), b.num(1)), (b.num(2), b.num(3)), (b.num(0), b.num(3)), (b.num(2), b.num(1))]
                        }
                        let info = try formInfo(x)
                        items.append(Item(startOp: i, endOp: i, kind: .form, box: box(corners, m.times(st.ctm)), inArtifact: inArtifact, hasText: info.hasText,
                                          form: x, hasArtifact: info.hasArtifact, artifactOnly: info.artifactOnly))
                    }
                default:
                    break
                }
            }
            return items
        }

        private static let tj = Array("Tj".utf8), tJ = Array("TJ".utf8), artifact = Array("/Artifact".utf8)

        /// What a form holds, read once for each form (a form within itself holds nothing more).
        private func formInfo(_ x: PObj) throws -> (hasText: Bool, hasArtifact: Bool, artifactOnly: Bool) {
            let key = x.identity
            if let known = shared.forms[key] { return known }
            guard depth < 32, shared.walking.insert(key).inserted else { return (false, false, false) }
            defer { shared.walking.remove(key) }
            let bytes = x.streamData ?? []
            var info = (hasText: bytes.firstRange(of: Self.tj) != nil || bytes.firstRange(of: Self.tJ) != nil, hasArtifact: false, artifactOnly: false)
            if bytes.firstRange(of: Self.artifact) != nil {
                let inner = try PageWalk(nil, x.dict("Resources") ?? resources, shared, depth: depth + 1)
                    .items(ContentLexer.parse(bytes, cancel: shared.cancel), strip: false)
                info.hasArtifact = inner.contains(where: \.inArtifact)
                info.artifactOnly = !inner.isEmpty && inner.allSatisfy(\.inArtifact)
            }
            shared.forms[key] = info
            return info
        }

        private func show(_ bytes: [UInt8], _ st: State, _ tm: inout ContentEditor.Mat, _ text: inout String) {
            guard let dict = st.font else {
                tm = ContentEditor.Mat(1, 0, 0, 1, Double(bytes.count) * 0.5 * st.size * st.scale, 0).times(tm)
                return
            }
            let font: TextFont
            if let known = shared.fonts[dict.id] {
                font = known
            } else {
                font = TextFont(dict)
                shared.fonts[dict.id] = font
            }
            var dx = 0.0
            for g in font.decode(bytes) {
                text += g.text
                dx += (g.width * st.size + st.charSpace + (g.length == 1 && g.code == 32 ? st.wordSpace : 0)) * st.scale
            }
            tm = ContentEditor.Mat(1, 0, 0, 1, dx, 0).times(tm)
        }

        private func textBox(_ begin: ContentEditor.Mat, _ end: ContentEditor.Mat, _ st: State) -> RectD {
            let size = st.size == 0 ? 1 : st.size
            let trs = ContentEditor.Mat(size * st.scale, 0, 0, size, 0, st.rise)
            let a = trs.times(begin).times(st.ctm), b = trs.times(end).times(st.ctm)
            let p = [a.apply(0, -0.2), a.apply(0, 0.8), b.apply(0, -0.2), b.apply(0, 0.8)]
            return box(p.map { ($0.x, $0.y) }, .identity)
        }

        private func box(_ pts: [(Double, Double)], _ ctm: ContentEditor.Mat) -> RectD {
            guard let frame, !pts.isEmpty else { return .zero }
            var l = Double.greatestFiniteMagnitude, t = l, r = -l, b = -l
            for (x, y) in pts {
                let u = ctm.apply(x, y)
                let p = frame.toPage(u.x, u.y)
                l = min(l, p.x)
                r = max(r, p.x)
                t = min(t, p.y)
                b = max(b, p.y)
            }
            guard l.isFinite, r.isFinite, t.isFinite, b.isFinite else { return .zero }
            return RectD(l, t, max(r - l, 0.5), max(b - t, 0.5))
        }
    }
}
