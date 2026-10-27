import Foundation

/// Bookmarks, destinations, page labels and form fields at the PDF object level (the Windows app's `PdfStructure`).
/// Objects are told apart by object number (or, for direct ones, by the object itself), never by wrapper.
enum PdfStructure {
    static let maxDepth = 64

    /// A bookmark and its children, before /First, /Next, /Count and the rest are written.
    final class OutlineItem {
        var dict: PObj
        let open: Bool
        var children: [OutlineItem] = []

        init(_ dict: PObj, open: Bool) {
            self.dict = dict
            self.open = open
        }
    }

    static func isWidget(_ d: PObj) -> Bool { d.name("Subtype") == "Widget" }
    static func isLink(_ d: PObj) -> Bool { d.name("Subtype") == "Link" }
    static func annots(_ page: PObj) -> [PObj] { page.array("Annots")?.elements ?? [] }

    /// The page object an explicit destination array leads to.
    static func targetOf(_ dest: PObj?) -> ObjId? {
        guard let dest, dest.isArray, dest.count > 0, let first = dest[0], first.isRef else { return nil }
        return first.id
    }

    /// The resolved object's address, for cycle checks (the same object read twice is the same address).
    static func identity(_ o: PObj) -> UInt { o.identity }

    // ---- Page labels ----

    /// A page's label as its /PageLabels range makes it: style (D, R, r, A, a; nil = prefix only), prefix, number.
    struct PageLabel: Equatable {
        var style: String?
        var prefix: String
        var number: Int
    }

    /// The (key, value) pairs of a number tree, each node visited once.
    static func numberTree(_ root: PObj?) -> [(key: Int, value: PObj?)] {
        treeNodes(root).flatMap { node -> [(key: Int, value: PObj?)] in
            guard let a = node.array("Nums") else { return [] }
            return stride(from: 0, to: a.count - 1, by: 2).compactMap { i in a[i]?.int.map { ($0, a[i + 1]) } }
        }
    }

    /// The (key, value) pairs of a name tree, each node visited once.
    static func nameTree(_ root: PObj?) -> [(key: String, value: PObj?)] {
        treeNodes(root).flatMap { node -> [(key: String, value: PObj?)] in
            guard let a = node.array("Names") else { return [] }
            return stride(from: 0, to: a.count - 1, by: 2).compactMap { i in a[i]?.text.map { ($0, a[i + 1]) } }
        }
    }

    /// A tree's nodes in order, each once (a hostile file's /Kids may repeat or point back).
    private static func treeNodes(_ root: PObj?) -> [PObj] {
        guard let root else { return [] }
        var seen = Set<UInt>()
        var out: [PObj] = []
        var stack: [(PObj, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            guard seen.insert(identity(node)).inserted else { continue }
            out.append(node)
            if depth < maxDepth, let kids = node.array("Kids") {
                for kid in kids.elements.reversed() where kid.isDict { stack.append((kid, depth + 1)) }
            }
        }
        return out
    }

    /// Each page's label (by page), in page order, or nil when the document has no /PageLabels.
    static func readLabels(_ doc: MuDoc) throws -> [(page: ObjId, label: PageLabel)]? {
        guard let tree = doc.catalog.dict("PageLabels") else { return nil }
        let ranges = numberTree(tree).filter { $0.key >= 0 }.sorted { $0.key < $1.key }
        let pages = try doc.pages()
        var list: [(page: ObjId, label: PageLabel)] = []
        var r = -1
        for (i, page) in pages.enumerated() {
            while r + 1 < ranges.count && ranges[r + 1].key <= i { r += 1 }
            if r < 0 {
                list.append((page.id, PageLabel(style: "D", prefix: "", number: i + 1))) // before the first range: plain numbers
                continue
            }
            let d = ranges[r].value.flatMap { $0.isDict ? $0 : nil }
            let first = min(max(d?.int("St") ?? 1, 1), 1_000_000_000)
            list.append((page.id, PageLabel(style: d?.name("S"), prefix: d?.text("P") ?? "", number: min(Int(Int32.max), first + i - ranges[r].key))))
        }
        return list
    }

    /// Rewrites /PageLabels after pages were removed, added or reordered: every page keeps the label it had, a new page
    /// continues the numbering of the page before it, written as the fewest ranges. Nothing changes when the pages are as
    /// they were.
    static func writeLabels(_ doc: MuDoc, _ before: [(page: ObjId, label: PageLabel)]) throws {
        let pages = try doc.pages()
        if pages.count == before.count && pages.indices.allSatisfy({ pages[$0].id == before[$0].page }) { return }
        var known: [ObjId: PageLabel] = [:]
        for (page, label) in before where known[page] == nil { known[page] = label }

        let nums = doc.array()
        var previous: PageLabel?
        for (i, page) in pages.enumerated() {
            let label = known[page.id]
                ?? previous.map { PageLabel(style: $0.style, prefix: $0.prefix, number: $0.number == Int(Int32.max) ? $0.number : $0.number + 1) }
                ?? PageLabel(style: "D", prefix: "", number: 1)
            if previous == nil || previous!.style != label.style || previous!.prefix != label.prefix
                || (label.style != nil && label.number != previous!.number + 1) {
                let range = doc.dict()
                if let style = label.style { range.set("S", doc.name(style)) }
                if !label.prefix.isEmpty { range.set("P", doc.text(label.prefix)) }
                if label.style != nil && label.number != 1 { range.set("St", doc.int(label.number)) }
                nums.append(doc.int(i))
                nums.append(range)
            }
            previous = label
        }
        doc.catalog.set("PageLabels", doc.dict([("Nums", nums)]))
    }

    // ---- Removing pages ----

    /// Removes pages along with the bookmarks, links, named destinations, form widgets, article beads and actions (any
    /// annotation's /A and /AA, the page and document /AA, /OpenAction) that lead to them; whatever else still refers to
    /// them is cut too (`dropStrayReferences`), so a file saved from the result can't carry a removed page's content along.
    static func removePages(_ doc: MuDoc, _ indices: [Int]) throws {
        var removedPages = Set<ObjId>()
        var removedAnnots = Set<ObjId>()
        let distinct = Array(Set(indices)).sorted(by: >)
        for i in distinct {
            let page = doc.page(i)
            removedPages.insert(page.id)
            for a in annots(page) { removedAnnots.insert(a.id) }
        }
        if removedPages.isEmpty { return }
        try doc.deletePages(distinct)

        let names = NamedDests(doc)
        func dead(_ dest: PObj?) -> Bool { targetOf(dest).map { removedPages.contains($0) } ?? false }

        try writeOutline(doc, prune(readOutline(doc)) { dead(names.of($0.dict)) })

        // A jump (or a chain of actions with one) to a removed page: the action goes. Each action is looked at once (chains
        // can share or loop back to actions), at most maxDepth deep along any chain.
        func deadAction(_ item: PObj?) -> Bool {
            var seen = Set<UInt>()
            return deadChain(item, &seen, 0)
        }
        func deadChain(_ start: PObj?, _ seen: inout Set<UInt>, _ depth: Int) -> Bool {
            var item = start
            var depth = depth
            while depth < maxDepth, let action = item, action.isDict, seen.insert(identity(action)).inserted {
                if action.name("S") == "GoTo" && dead(names.explicit(action["D"])) { return true }
                if let next = action.array("Next") {
                    for e in next.elements where deadChain(e, &seen, depth + 1) { return true }
                    return false
                }
                item = action["Next"]
                depth += 1
            }
            return false
        }
        func dropDeadTriggers(_ owner: PObj) {
            guard let aa = owner.dict("AA") else { return }
            for key in aa.keys where deadAction(aa[key]) { aa.remove(key) }
        }

        for page in try doc.pages() {
            dropDeadTriggers(page)
            guard let list = page.array("Annots") else { continue }
            for k in stride(from: list.count - 1, through: 0, by: -1) {
                guard let a = list[k], a.isDict else { continue }
                if isLink(a) && dead(names.of(a)) {
                    list.remove(at: k)
                    continue
                }
                // Form buttons, widgets and other annotations jump with actions (a /Dest is only for links).
                if deadAction(a["A"]) { a.remove("A") }
                if !isLink(a) && dead(names.explicit(a["Dest"])) { a.remove("Dest") }
                dropDeadTriggers(a)
            }
        }

        let catalog = doc.catalog
        if let open = catalog["OpenAction"], (open.isArray && dead(open)) || (open.isDict && deadAction(open)) {
            catalog.remove("OpenAction")
        }
        dropDeadTriggers(catalog)

        names.removeWhere(dead)
        dropWidgets(doc) { removedAnnots.contains($0) }
        try pruneThreads(doc)
        try dropStrayReferences(doc) { removedPages.contains($0) || removedAnnots.contains($0) }
    }

    /// Article threads: beads on pages no longer in the document are unlinked from their thread's ring, and a thread left
    /// without beads is dropped.
    static func pruneThreads(_ doc: MuDoc) throws {
        let catalog = doc.catalog
        guard let threads = catalog.array("Threads") else { return }
        let live = Set(try doc.pages().map(\.id))
        for t in stride(from: threads.count - 1, through: 0, by: -1) {
            guard let thread = threads[t], thread.isDict else {
                threads.remove(at: t)
                continue
            }
            var beads: [PObj] = []
            var seen = Set<UInt>()
            var bead = thread["F"]
            while let b = bead, b.isDict, beads.count < 100_000, seen.insert(identity(b)).inserted {
                if let p = b["P"], live.contains(p.id) { beads.append(b) }
                bead = b["N"]
            }
            if beads.isEmpty {
                threads.remove(at: t)
                continue
            }
            if beads.count == seen.count { continue }
            beads = beads.map { $0.isRef ? $0 : doc.add($0) }
            for k in beads.indices {
                beads[k].set("N", beads[(k + 1) % beads.count])
                beads[k].set("V", beads[(k + beads.count - 1) % beads.count])
                if k > 0 { beads[k].remove("T") }
            }
            if thread.isRef { beads[0].set("T", thread) }
            thread.set("F", beads[0])
        }
        if threads.count == 0 { catalog.remove("Threads") }
    }

    /// Cuts every remaining reference to a page that isn't in the document (a removed page, or a stray copy an imported
    /// annotation pointed at) and to the objects `gone` picks, so the saved file can't carry their content along. A
    /// destination or GoTo action leading to such a page is dropped from whatever holds it (an /A or /AA entry, an
    /// action's /Next, a name or number tree pair, an array), and so is an annotation or bead whose /P is such a page.
    /// References elsewhere (a structure element's /Pg, a reply's /IRT) are removed.
    static func dropStrayReferences(_ doc: MuDoc, gone: ((ObjId) -> Bool)? = nil) throws {
        let pages = Set(try doc.pages().map(\.id))
        var memo: [Int: Bool] = [:]

        func dead(_ item: PObj, _ depth: Int) -> Bool {
            if depth > 512 { return false }
            if item.isRef {
                let id = item.id
                if gone?(id) == true { return true }
                if let known = memo[item.num] { return known }
                if item.isDict && item.name("Type") == "Page" && !pages.contains(id) {
                    memo[item.num] = true
                    return true
                }
                memo[item.num] = false
                let result = container(item, depth + 1)
                memo[item.num] = result
                return result
            }
            return item.isDict || item.isArray ? container(item, depth + 1) : false
        }

        // Prunes what a dictionary or array holds; true when the container itself must go.
        func container(_ obj: PObj, _ depth: Int) -> Bool {
            if obj.isDict {
                for key in obj.keys {
                    guard let value = obj[key] else { continue }
                    if (key == "Names" || key == "Nums") && value.isArray {
                        for i in stride(from: (value.count & ~1) - 2, through: 0, by: -2) {
                            if let v = value[i + 1], dead(v, depth) {
                                value.remove(at: i + 1)
                                value.remove(at: i)
                            }
                        }
                        continue
                    }
                    if !dead(value, depth) { continue }
                    if key == "P" && value.isRef && value.isDict && value.name("Type") == "Page" { return true } // an annotation or bead of a gone page
                    obj.remove(key)
                    if key == "D" && obj.name("S") == "GoTo" { return true } // a jump to a gone page
                }
                return false
            }
            if obj.isArray {
                // A destination: [page /XYZ left top zoom], [page /Fit]…
                if obj.count > 1, obj[1]?.kind == .name, let first = obj[0], first.isRef, dead(first, depth) { return true }
                for i in stride(from: obj.count - 1, through: 0, by: -1) {
                    if let e = obj[i], dead(e, depth) { obj.remove(at: i) }
                }
            }
            return false
        }

        _ = container(doc.catalog, 0)
        if let info = doc.trailer.dict("Info") { _ = container(info, 0) }
    }

    // ---- Outline ----

    /// The document's bookmarks as a tree (empty if none).
    static func readOutline(_ doc: MuDoc) -> [OutlineItem] {
        var seen = Set<ObjId>()
        func children(_ parent: PObj, _ depth: Int) -> [OutlineItem] {
            var list: [OutlineItem] = []
            var item = parent["First"]
            while depth < maxDepth, let d = item, d.isDict, seen.insert(d.id).inserted {
                let node = OutlineItem(d, open: (d.int("Count") ?? 0) > 0)
                node.children = children(d, depth + 1)
                list.append(node)
                item = d["Next"]
            }
            return list
        }
        guard let root = doc.catalog.dict("Outlines") else { return [] }
        return children(root, 0)
    }

    /// Makes `items` the document's bookmarks (removing the outline when there are none).
    static func writeOutline(_ doc: MuDoc, _ items: [OutlineItem]) throws {
        let catalog = doc.catalog
        if items.isEmpty {
            if !catalog.has("Outlines") { return }
            catalog.remove("Outlines")
            if catalog.name("PageMode") == "UseOutlines" { catalog.remove("PageMode") }
            return
        }
        var root = catalog.dict("Outlines")
        if root == nil {
            let made = doc.dict([("Type", doc.name("Outlines"))])
            if !catalog.has("PageMode") { catalog.set("PageMode", doc.name("UseOutlines")) }
            root = made
        }
        var r = root!
        if !r.isRef { r = doc.add(r) }
        catalog.set("Outlines", r)
        r.set("Count", doc.int(link(doc, r, items)))
    }

    /// Links `items` under `parent`; returns how many show when it is open.
    private static func link(_ doc: MuDoc, _ parent: PObj, _ items: [OutlineItem]) -> Int {
        if items.isEmpty {
            parent.remove("First")
            parent.remove("Last")
            return 0
        }
        for item in items where !item.dict.isRef { item.dict = doc.add(item.dict) }
        parent.set("First", items[0].dict)
        parent.set("Last", items[items.count - 1].dict)
        var visible = 0
        for (i, item) in items.enumerated() {
            let d = item.dict
            d.set("Parent", parent)
            if i > 0 { d.set("Prev", items[i - 1].dict) } else { d.remove("Prev") }
            if i < items.count - 1 { d.set("Next", items[i + 1].dict) } else { d.remove("Next") }
            let below = link(doc, d, item.children)
            if !item.children.isEmpty { d.set("Count", doc.int(item.open ? below : -below)) } else { d.remove("Count") }
            visible += 1 + (item.open ? below : 0)
        }
        return visible
    }

    /// Drops the items `dead` picks, moving their children up in their place.
    static func prune(_ items: [OutlineItem], _ dead: (OutlineItem) -> Bool) -> [OutlineItem] {
        var kept: [OutlineItem] = []
        for item in items {
            item.children = prune(item.children, dead)
            if dead(item) { kept += item.children } else { kept.append(item) }
        }
        return kept
    }

    /// A new bookmark; without a page it is a plain heading.
    static func newOutlineItem(_ doc: MuDoc, _ title: String, _ page: PObj?, viewLike: PObj? = nil, open: Bool = true) -> OutlineItem {
        let d = doc.add(doc.dict([("Title", doc.text(title))]))
        if let page { d.set("Dest", dest(doc, page, viewLike)) }
        return OutlineItem(d, open: open)
    }

    /// A destination on `page` with the view (/XYZ left top zoom, /Fit…) of `like`.
    static func dest(_ doc: MuDoc, _ page: PObj, _ like: PObj?) -> PObj {
        let a = doc.array([page])
        if let like, like.isArray, like.count > 1, like[1]?.kind == .name {
            for i in 1..<like.count {
                let v = like[i]
                switch v?.kind {
                case .name: a.append(doc.name(v!.name!))
                case .int: a.append(doc.int(v!.int!))
                case .real: a.append(doc.real(v!.number!))
                case .bool: a.append(doc.bool(v!.bool))
                default: a.append(doc.null)
                }
            }
        } else {
            a.append(doc.name("XYZ"))
            a.append(doc.null)
            a.append(doc.null)
            a.append(doc.null)
        }
        return a
    }

    // ---- Form fields ----

    /// Unregisters form widgets `dead` picks, and fields left without widgets.
    static func dropWidgets(_ doc: MuDoc, _ dead: (ObjId) -> Bool) {
        guard let acro = doc.catalog.dict("AcroForm"), let fields = acro.array("Fields") else { return }
        var dropped = Set<ObjId>()
        pruneFields(fields, dead, &dropped, 0)
        if !dropped.isEmpty, let order = acro.array("CO") {
            for k in stride(from: order.count - 1, through: 0, by: -1) where order[k].map({ dropped.contains($0.id) }) == true {
                order.remove(at: k)
            }
        }
    }

    static func pruneFields(_ kids: PObj, _ dead: (ObjId) -> Bool, _ dropped: inout Set<ObjId>, _ depth: Int) {
        for k in stride(from: kids.count - 1, through: 0, by: -1) {
            guard let field = kids[k], field.isDict else { continue }
            let id = field.id
            var drop = false
            if isWidget(field) && dead(id) {
                drop = true
            } else if depth < maxDepth, let sub = field.array("Kids"), sub.count > 0 {
                pruneFields(sub, dead, &dropped, depth + 1)
                drop = sub.count == 0
            }
            if !drop { continue }
            kids.remove(at: k)
            dropped.insert(id)
        }
    }

    // ---- Named destinations ----

    /// A document's named destinations: the /Names /Dests tree and the PDF 1.1 /Dests dictionary.
    final class NamedDests {
        private var strings: [String: PObj] = [:]
        private var leaves: [PObj] = []
        private let old: PObj?

        init(_ doc: MuDoc) {
            let catalog = doc.catalog
            old = catalog.dict("Dests")
            if let tree = catalog.dict("Names")?.dict("Dests") {
                var seen = Set<UInt>()
                walk(tree, 0, &seen)
            }
        }

        private func walk(_ node: PObj, _ depth: Int, _ seen: inout Set<UInt>) {
            if depth > PdfStructure.maxDepth || !seen.insert(PdfStructure.identity(node)).inserted { return }
            if let pairs = node.array("Names") {
                leaves.append(pairs)
                for i in stride(from: 0, to: pairs.count - 1, by: 2) {
                    if let key = pairs[i]?.text, strings[key] == nil, let v = pairs[i + 1] { strings[key] = v }
                }
            }
            if let kids = node.array("Kids") {
                for kid in kids.elements where kid.isDict { walk(kid, depth + 1, &seen) }
            }
        }

        /// The explicit destination array behind a /Dest or GoTo /D value (array, name or string).
        func explicit(_ dest: PObj?) -> PObj? {
            guard let dest else { return nil }
            let d: PObj?
            switch dest.kind {
            case .string: d = dest.text.flatMap { strings[$0] }
            case .name: d = dest.name.flatMap { old?[$0] }
            default: d = dest
            }
            guard let d else { return nil }
            if d.isArray { return d }
            return d.isDict ? d.array("D") : nil
        }

        /// The explicit destination of a bookmark or link: its /Dest, or the /D of its GoTo action.
        func of(_ item: PObj) -> PObj? {
            if let dest = item["Dest"] { return explicit(dest) }
            guard let action = item.dict("A"), action.name("S") == "GoTo" else { return nil }
            return explicit(action["D"])
        }

        func removeWhere(_ dead: (PObj) -> Bool) {
            for pairs in leaves {
                for i in stride(from: (pairs.count & ~1) - 2, through: 0, by: -2) {
                    if let a = explicit(pairs[i + 1]), dead(a) {
                        pairs.remove(at: i + 1)
                        pairs.remove(at: i)
                    }
                }
            }
            if let old {
                for key in old.keys {
                    if let a = explicit(old[key]), dead(a) { old.remove(key) }
                }
            }
        }
    }

    // ---- Importing pages ----

    /// Pages just imported from another document (opened in the same context). MuPDF's page graft copies a page's
    /// contents, resources and boxes but not its annotations; `copyAnnotations` brings them, `fixLinks` points their jumps
    /// at the imported pages (dropping those to pages left behind), `outline` recreates the source's bookmarks and
    /// `registerFields` the form fields (the Windows app's `Import`, which mends the same gaps in PDFsharp's import).
    final class Import {
        private let doc: MuDoc
        private let src: MuDoc
        private let graft: Graft
        private let pages: [(source: Int, page: PObj)]
        private let target: (Int) -> PObj?
        private var srcIndex: [ObjId: Int] = [:]
        private let srcNames: NamedDests

        /// - Parameters:
        ///   - pages: (source page index, imported page) pairs.
        ///   - target: where a jump to source page i should land; default: its imported copy, if any.
        init(_ doc: MuDoc, _ src: MuDoc, _ graft: Graft, _ pages: [(source: Int, page: PObj)], target: ((Int) -> PObj?)? = nil) throws {
            self.doc = doc
            self.src = src
            self.graft = graft
            self.pages = pages
            var first: [Int: PObj] = [:]
            for (s, p) in pages where first[s] == nil { first[s] = p }
            self.target = target ?? { first[$0] }
            for (i, p) in try src.pages().enumerated() where srcIndex[p.id] == nil { srcIndex[p.id] = i }
            srcNames = NamedDests(src)
        }

        /// Where a source destination lands: (false, _) when it isn't a page of the source, (true, nil) when that page
        /// wasn't imported.
        private func map(_ dest: PObj?) -> (isPage: Bool, page: PObj?) {
            guard let id = targetOf(dest), let index = srcIndex[id] else { return (false, nil) }
            return (true, target(index))
        }

        /// Copies each imported page's annotations (MuPDF's graft leaves them behind), pointed at their new page. The
        /// source's annotations lose their /P first (the source is ours, never saved), so copying one doesn't drag a copy
        /// of its page along.
        func copyAnnotations() throws {
            for page in try src.pages() {
                for a in PdfStructure.annots(page) where a.isDict && a.has("P") {
                    a.set("NewP", src.bool(true))
                    a.remove("P")
                }
            }
            for (source, page) in pages {
                let from = src.page(source).array("Annots")?.elements ?? []
                if from.isEmpty { continue }
                let copies = doc.array()
                for annot in from {
                    let copy = graft.object(annot)
                    if copy.isDict, copy.has("NewP") {
                        copy.remove("NewP")
                        copy.set("P", page)
                    }
                    copies.append(copy)
                }
                page.set("Annots", copies)
            }
        }

        /// Points internal links on the imported pages at the imported pages and drops links to pages left behind; the
        /// same for the GoTo actions of other annotations (form buttons' /A, the /AA triggers).
        func fixLinks() {
            for (source, page) in pages {
                guard let from = src.page(source).array("Annots"), let to = page.array("Annots"), from.count == to.count else { continue }
                for k in stride(from: to.count - 1, through: 0, by: -1) {
                    guard let annot = from[k], annot.isDict, let copy = to[k], copy.isDict else { continue }
                    if !isLink(annot) {
                        retarget(annot, copy, "A")
                        if let triggers = annot.dict("AA"), let copied = copy.dict("AA") {
                            for key in triggers.keys { retarget(triggers, copied, key) }
                        }
                        continue
                    }
                    let dest = srcNames.of(annot)
                    let (isPage, target) = map(dest)
                    if !isPage { continue }
                    guard let target else {
                        to.remove(at: k)
                        continue
                    }
                    copy.remove("A")
                    copy.set("Dest", PdfStructure.dest(doc, target, dest))
                }
            }
        }

        /// A copied GoTo action (`key` of `to`) aimed at the imported page, or dropped when its page wasn't imported.
        private func retarget(_ from: PObj, _ to: PObj, _ key: String) {
            guard let action = from.dict(key), action.name("S") == "GoTo" else { return }
            let dest = srcNames.explicit(action["D"])
            let (isPage, target) = map(dest)
            if !isPage { return }
            guard let target else {
                to.remove(key)
                return
            }
            to.set(key, doc.dict([("S", doc.name("GoTo")), ("D", PdfStructure.dest(doc, target, dest))]))
        }

        /// The source's bookmarks, recreated for the imported pages (those to pages left behind are dropped, their
        /// children kept).
        func outline() -> [OutlineItem] { copy(readOutline(src)) }

        private func copy(_ items: [OutlineItem]) -> [OutlineItem] {
            var list: [OutlineItem] = []
            for item in items {
                let children = copy(item.children)
                let s = item.dict
                let dest = srcNames.of(s)
                let (isPage, target) = map(dest)
                if isPage && target == nil {
                    list += children
                    continue
                }
                let c = newOutlineItem(doc, s.text("Title") ?? "", target, viewLike: dest, open: item.open)
                if !isPage, let action = s.dict("A"), action.name("S") == "URI", let uri = action["URI"]?.bytes {
                    c.dict.set("A", doc.dict([("S", doc.name("URI")), ("URI", doc.string(uri))]))
                }
                if let color = s.array("C"), color.count == 3, color.elements.allSatisfy({ $0.number != nil }) {
                    c.dict.set("C", doc.reals(color.num(0), color.num(1), color.num(2)))
                }
                if let f = s.int("F") { c.dict.set("F", doc.int(f)) }
                c.children = children
                list.append(c)
            }
            return list
        }

        /// Registers the form fields of the imported widgets in the target's /AcroForm (renaming a field whose name is
        /// taken, e.g. "name" to "name_2"), keeping only the widgets that came along, plus the form's default appearance
        /// resources.
        func registerFields() throws {
            var roots: [PObj] = []
            var seenRoots = Set<ObjId>()
            for (_, page) in pages {
                for annot in PdfStructure.annots(page) where annot.isDict && isWidget(annot) {
                    var root = annot
                    var depth = 0
                    while depth < maxDepth, let parent = root["Parent"], parent.isDict {
                        root = parent
                        depth += 1
                    }
                    if root.isRef && seenRoots.insert(root.id).inserted { roots.append(root) }
                }
            }
            if roots.isEmpty { return }

            var live = Set<ObjId>()
            for page in try doc.pages() { for a in PdfStructure.annots(page) { live.insert(a.id) } }

            let catalog = doc.catalog
            var acro = catalog.dict("AcroForm")
            if acro == nil {
                let made = doc.add(doc.dict())
                catalog.set("AcroForm", made)
                acro = made
            }
            var fields = acro!.array("Fields")
            if fields == nil {
                let made = doc.array()
                acro!.set("Fields", made)
                fields = acro!.array("Fields")
            }
            var registered = Set<ObjId>()
            var names = Set<String>()
            for f in fields!.elements {
                registered.insert(f.id)
                if let t = f.text("T"), !t.isEmpty { names.insert(t) }
            }

            var added = false
            for root in roots {
                if registered.contains(root.id) || !root.isDict { continue }
                if isWidget(root) && !live.contains(root.id) { continue }
                if let kids = root.array("Kids"), kids.count > 0 {
                    var dropped = Set<ObjId>()
                    pruneFields(kids, { !live.contains($0) }, &dropped, 0)
                    if kids.count == 0 { continue }
                }
                if let name = root.text("T"), !name.isEmpty {
                    var unique = name
                    var n = 2
                    while names.contains(unique) {
                        unique = "\(name)_\(n)"
                        n += 1
                    }
                    if unique != name { root.set("T", doc.text(unique)) }
                    names.insert(unique)
                }
                fields!.append(root)
                added = true
            }
            if added { copyFormDefaults(acro!) }
        }

        /// Brings the source form's /DA, /NeedAppearances and the /DR resources the target lacks.
        private func copyFormDefaults(_ acro: PObj) {
            guard let from = src.catalog.dict("AcroForm") else { return }
            if !acro.has("DA"), let da = from["DA"]?.bytes, !da.isEmpty { acro.set("DA", doc.string(da)) }
            if from["NeedAppearances"]?.bool == true { acro.set("NeedAppearances", doc.bool(true)) }
            guard let fromDr = from.dict("DR") else { return }
            var dr = acro.dict("DR")
            if dr == nil {
                acro.set("DR", doc.dict())
                dr = acro.dict("DR")
            }
            for key in fromDr.keys {
                guard let value = fromDr[key] else { continue }
                guard value.isDict else {
                    if !dr!.has(key) { dr!.set(key, graft.object(value)) }
                    continue
                }
                var sub = dr!.dict(key)
                if sub == nil {
                    dr!.set(key, doc.dict())
                    sub = dr!.dict(key)
                }
                for name in value.keys where !sub!.has(name) {
                    if let v = value[name] { sub!.set(name, graft.object(v)) }
                }
            }
        }
    }
}
