import Foundation
import PrintCore

/// What a font is used for: the codes drawn (and of those, the ones that show), where it is first used.
final class AccessibilityFontUse {
    let font: PObj
    var codes = Set<Int>()
    var shown = Set<Int>()
    let page: Int
    let box: RectD

    init(_ font: PObj, page: Int, box: RectD) {
        self.font = font
        self.page = page
        self.box = box
    }
}

/// A form XObject drawn from page content: how often, whether it holds marked-content ids, where first.
struct AccessibilityFormUse {
    var uses: Int
    var tagged: Bool
    var page: Int
}

/// An XObject as a `Do` finds it, read once: a crafted page draws the same one millions of times.
final class AccessibilityXObject {
    let identity: UInt
    let isImage: Bool
    let isForm: Bool
    let isReference: Bool
    let matrix: ContentEditor.Mat
    let structParents: Int?
    let resources: PObj?
    let obj: PObj
    /// Its drawing steps, once parsed (nil also when too many were cached already).
    var ops: [COp]?

    init(_ x: PObj) {
        obj = x
        identity = x.identity
        let subtype = x.name("Subtype")
        isImage = subtype == "Image"
        isForm = subtype == "Form"
        isReference = x.has("Ref")
        if let a = x.array("Matrix"), a.count == 6 {
            matrix = ContentEditor.Mat(a.num(0), a.num(1), a.num(2), a.num(3), a.num(4), a.num(5))
        } else {
            matrix = .identity
        }
        structParents = x.int("StructParents")
        resources = x.dict("Resources")
    }
}

extension AccessibilityChecker {
    static let maxOperators = 2_000_000, maxFormDepth = 12
    /// Most drawing steps of forms kept parsed: a form past it is read again each time it is drawn, which `read` counts.
    static let maxParsedOps = 2_500_000
    /// Bytes of content read for one drawing step counted: content of nothing but spaces has no steps to count.
    static let bytesPerOperator = 64
    /// Drawing steps one annotation counts as: every page can list the same long array of them.
    static let operatorsPerAnnotation = 32

    func pages() throws {
        for p in 0..<pageCount {
            try cancel.check()
            if totalOps > maxDocumentOperators {
                notes.append(loc("The document's content is very long: pages {0} to {1} weren't checked.", p + 1, pageCount))
                break
            }
            let page = pageObjects[p]
            let walk = AccessibilityWalk(self, p, page)
            let bytes = ContentEditor.contentBytes(page)
            walk.read(bytes.count)
            let ops = try ContentLexer.parse(bytes, cancel: cancel, limit: Self.maxOperators + 1)
            var marks: [AccessibilityWalk.Mc] = []
            try walk.run(ops, PageBoxes.inherited(page, "Resources"), .identity, page.int("StructParents"), &marks, 0, false)
            if walk.stopped { notes.append(loc("Page {0}: its content is very long; only the first part of it was checked.", p + 1)) }
            report(walk, p)
            try annotations(p, page)
            step(p + 1)
        }
        for id in formOrder {
            guard let use = forms[id], use.tagged, use.uses > 1 else { continue }
            add("30-002", loc("A form XObject with tagged content is drawn {0} times, so its tags would stand for several places at once.", use.uses), page: use.page, element: loc("Form XObject"))
        }
        for _ in refForms { add("30-001", loc("The document draws content taken from another file (a reference XObject)."), element: loc("Form XObject")) }
        formFields()
    }

    private func report(_ walk: AccessibilityWalk, _ p: Int) {
        let content = loc("Page content")
        if walk.untagged > 0 {
            let n = walk.untagged
            let problem = n == 1 ? loc("{0} content item on this page is neither tagged nor marked as an artifact (text, pictures or drawings a screen reader can't place).", n)
                : loc("{0} content items on this page are neither tagged nor marked as an artifact (text, pictures or drawings a screen reader can't place).", n)
            add("01-005", problem, page: p, box: walk.untaggedBox, element: content, count: n)
        }
        if walk.artifactInTagged > 0 {
            let n = walk.artifactInTagged
            let problem = n == 1 ? loc("{0} artifact on this page is inside tagged content.", n) : loc("{0} artifacts on this page are inside tagged content.", n)
            add("01-003", problem, page: p, element: content, count: n)
        }
        if walk.taggedInArtifact > 0 {
            let n = walk.taggedInArtifact
            let problem = n == 1 ? loc("{0} piece of tagged content on this page is inside an artifact.", n) : loc("{0} pieces of tagged content on this page are inside an artifact.", n)
            add("01-004", problem, page: p, element: content, count: n)
        }
        if walk.noLang > 0 {
            let n = walk.noLang
            let problem = n == 1 ? loc("The language of {0} piece of text on this page can't be told: the document, its tags and its marked content give none.", n)
                : loc("The language of {0} pieces of text on this page can't be told: the document, its tags and its marked content give none.", n)
            add("11-001", problem, page: p, box: walk.noLangBox, element: loc("Page text"), count: n)
        }
        if walk.spanNoLang > 0 {
            let n = walk.spanNoLang
            let problem = n == 1 ? loc("{0} span of marked content on this page has alternate, actual or expansion text without a language.", n)
                : loc("{0} spans of marked content on this page have alternate, actual or expansion text without a language.", n)
            add("11-002", problem, page: p, element: content, count: n)
        }
        for lang in walk.badLangs.sorted() {
            add("UA 7.2-Lang", loc("Marked content on this page has the language “{0}”, which isn't a language code.", Self.short(lang)), page: p, element: content)
        }
    }

    func textFont(_ font: PObj) -> TextFont {
        if let known = textFonts[font.identity] { return known }
        let made = TextFont(font)
        textFonts[font.identity] = made
        return made
    }

    func useFont(_ font: PObj, _ codes: [Int], shown: Bool, page: Int, box: RectD) {
        let id = font.identity
        let use: AccessibilityFontUse
        if let known = fonts[id] {
            use = known
        } else {
            use = AccessibilityFontUse(font, page: page, box: box)
            fonts[id] = use
            fontOrder.append(use)
        }
        use.codes.formUnion(codes)
        if shown { use.shown.formUnion(codes) }
    }

    /// The element a marked-content id stands for (through the parent tree), and whether it stands for any.
    func byMcid(_ key: Int?, _ mcid: Int) -> (tagged: Bool, elem: AccessibilityElem?) {
        guard let key, let entry = parentTree[key], let value = entry, value.isArray, mcid >= 0, mcid < value.count else { return (false, nil) }
        // Tagged only when the element is in the tree: one the root doesn't lead to tags nothing.
        guard let d = value[mcid], d.isDict, let e = elems[d.identity] else { return (false, nil) }
        return (true, e)
    }

    /// The XObject called `name` in `resources`, read once.
    func xobject(_ resources: PObj?, _ name: String) -> AccessibilityXObject? {
        guard let resources else { return nil }
        let id = resources.identity
        if let known = xobjects[id]?[name] { return known }
        var made: AccessibilityXObject?
        if let x = Self.entry(resources.dict("XObject"), name), x.isDict { made = AccessibilityXObject(x) }
        xobjects[id, default: [:]][name] = .some(made)
        return made
    }

    /// A form's drawing steps from its bytes; kept while they fit `maxParsedOps`, so a form drawn again isn't read again.
    func parse(_ x: AccessibilityXObject, _ bytes: [UInt8]) throws -> [COp] {
        let ops = try ContentLexer.parse(bytes, cancel: cancel, limit: Self.maxOperators + 1)
        if parsedOps + ops.count <= Self.maxParsedOps {
            parsedOps += ops.count
            x.ops = ops
        }
        return ops
    }

    // MARK: Annotations and fields

    private func annotations(_ p: Int, _ page: PObj) throws {
        guard let annots = page.array("Annots"), annots.count > 0 else { return }
        let tabs = page.name("Tabs")
        if tabs == nil {
            add("28-008", loc("This page has comments, links or form fields but doesn't set its tab order (no Tabs entry)."), page: p, element: loc("Page"))
        } else if tabs != "S" {
            add("28-009", loc("This page's tab order is “{0}”, not the order of the tags (S).", tabs ?? ""), page: p, element: loc("Page"))
        }
        let clip = PageBoxes.visibleBox(page)
        totalOps += min(annots.count, 20_000) * Self.operatorsPerAnnotation
        if annots.count > 20_000 { notes.append(loc("Page {0}: it has very many annotations; only the first 20,000 were checked.", p + 1)) }
        for (i, a) in annots.elements.lazy.filter(\.isDict).prefix(20_000).enumerated() {
            if i & 255 == 255 { try cancel.check() }
            let subtype = a.name("Subtype") ?? ""
            let rect = a.array("Rect")
            let box = PageBoxes.rectToPage(page, rect)
            let hidden = (a.int("F") ?? 0) & 2 != 0
            var outside = false
            if let rect, rect.count >= 4 {
                outside = max(rect.num(0), rect.num(2)) < clip.x1 || min(rect.num(0), rect.num(2)) > clip.x2
                    || max(rect.num(1), rect.num(3)) < clip.y1 || min(rect.num(1), rect.num(3)) > clip.y2
            }
            let parent = a.int("StructParent").flatMap { parentTree[$0] ?? nil }.flatMap { $0.isDict ? $0 : nil }
            let elem = parent.flatMap { elems[$0.identity] }
            let std = elem?.kind ?? parent.flatMap { mapRole($0.name("S") ?? "").std }
            let alt = parent.map { Self.hasText($0, "Alt") } ?? false
            let contents = Self.hasText(a, "Contents")
            let label = Self.annotName(subtype)
            let capital = Self.cap(label)
            let this = Self.thisName(subtype)
            let inTag = std.map { loc(" (it is in a {0} tag)", $0) } ?? loc(" (it isn't tagged)")

            if !hidden && !outside && subtype != "Popup" { // a pop-up belongs to its comment and isn't read on its own
                if !["Widget", "PrinterMark", "Link"].contains(subtype) && std != "Annot" {
                    add("28-002", Self.cap(loc("{0} isn't inside an Annot tag{1}.", this, inTag)), page: p, box: box, element: capital)
                }
                if subtype != "Widget" && !contents && !alt {
                    add("28-004", Self.cap(loc("{0} has no description: no text (Contents) and no alternate text on its tag.", this)), page: p, box: box, element: capital)
                }
                if subtype == "Widget" && Self.isFieldWidget(a) && !Self.hasFieldTooltip(a) && !alt {
                    add("28-005", loc("The form field “{0}” has no tooltip and no alternate text, so a screen reader can't say what to fill in.", Self.short(Self.fieldName(a))), page: p, box: box, element: loc("Form field"))
                }
                if subtype == "Widget" && std != "Form" {
                    add("28-010", loc("The form field “{0}” isn't inside a Form tag{1}.", Self.short(Self.fieldName(a)), std == nil ? loc(" (it isn't tagged)") : ""), page: p, box: box, element: loc("Form field"))
                }
                if subtype == "Link" {
                    if std != "Link" { add("28-011", loc("This link isn't inside a Link tag{0}.", inTag), page: p, box: box, element: loc("Link")) }
                    if !contents { add("28-012", loc("This link has no description of where it goes (Contents)."), page: p, box: box, element: loc("Link")) }
                }
                if subtype == "TrapNet" { add("28-007", loc("This page has a trap network annotation (TrapNet)."), page: p, box: box, element: loc("Trap network")) }
                if subtype == "PrinterMark" && parent != nil { add("28-017", loc("This printer's mark is in the tags."), page: p, box: box, element: loc("Printer's mark")) }
            }
            if contents && !docLang && !a.has("Lang") && parent?.has("Lang") != true {
                add("11-004", Self.cap(loc("{0}'s text has no language, and the document has none.", this)), page: p, box: box, element: capital)
            }
            if subtype == "FileAttachment", let fs = a.dict("FS"), fs.has("EF"), !Self.hasBothNames(fs) {
                add("28-016", loc("This attached file lacks one of its file names (F and UF)."), page: p, box: box, element: loc("Attached file"))
            }
            mediaClips(a, p, box)
            if !hidden { try appearance(a, p, page) }
        }
    }

    private static func annotName(_ subtype: String) -> String {
        switch subtype {
        case "Text": loc("note")
        case "Link": loc("link")
        case "Widget": loc("form field")
        case "FreeText": loc("text box")
        case "Highlight", "Underline", "StrikeOut", "Squiggly": loc("text markup comment")
        case "Stamp": loc("stamp")
        case "FileAttachment": loc("attached-file comment")
        case "Popup": loc("pop-up note")
        case "Ink": loc("drawing")
        case "Square", "Circle", "Line", "Polygon", "PolyLine": loc("shape comment")
        case "": loc("annotation")
        default: loc("{0} annotation", subtype)
        }
    }

    /// "this note", "this link"…: the start of a sentence about one annotation (Windows' `This`).
    private static func thisName(_ subtype: String) -> String {
        switch subtype {
        case "Text": loc("this note")
        case "Link": loc("this link")
        case "Widget": loc("this form field")
        case "FreeText": loc("this text box")
        case "Highlight", "Underline", "StrikeOut", "Squiggly": loc("this text markup comment")
        case "Stamp": loc("this stamp")
        case "FileAttachment": loc("this attached-file comment")
        case "Popup": loc("this pop-up note")
        case "Ink": loc("this drawing")
        case "Square", "Circle", "Line", "Polygon", "PolyLine": loc("this shape comment")
        case "": loc("this annotation")
        default: loc("this {0} annotation", subtype)
        }
    }

    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static func isFieldWidget(_ a: PObj) -> Bool {
        var d: PObj? = a
        var i = 0
        while let x = d, i < 32 {
            if x.has("FT") { return true }
            d = x.dict("Parent")
            i += 1
        }
        return false
    }

    /// The widget's field has a tooltip: the widget itself when it is the field (it has a name), else its parent. A
    /// tooltip on a widget that is only one of a field's buttons isn't the field's.
    private static func hasFieldTooltip(_ a: PObj) -> Bool {
        let field = a.has("T") ? a : a.dict("Parent") ?? a
        return hasText(field, "TU")
    }

    private static func fieldName(_ a: PObj) -> String {
        var parts: [String] = []
        var d: PObj? = a
        var i = 0
        while let x = d, i < 32 {
            if let t = text(x["T"]), !t.isEmpty { parts.insert(t, at: 0) }
            d = x.dict("Parent")
            i += 1
        }
        return parts.isEmpty ? "(unnamed)" : parts.joined(separator: ".")
    }

    /// Media clips reached from a screen annotation's rendition actions: each needs its type (CT) and an alternate description.
    private func mediaClips(_ a: PObj, _ p: Int, _ box: RectD) {
        var actions: [PObj] = []
        if let act = a.dict("A") { actions.append(act) }
        // A real one has a few triggers; a crafted one shared by every annotation could hold a million.
        if let aa = a.dict("AA"), aa.count <= 32 { actions += aa.keys.compactMap { aa.dict($0) } }
        for action in actions where action.name("S") == "Rendition" { rendition(action.dict("R"), p, box, 0) }
    }

    private func rendition(_ r: PObj?, _ p: Int, _ box: RectD, _ depth: Int) {
        guard let r, depth <= 8 else { return }
        if r.name("S") == "SR", let list = r.array("R") {
            // Each selector once in the document: one listing itself 100 times would be 100^8 walks, and thousands of
            // annotations may share one. A clip it leads to is reported where it is first reached.
            guard walkedSelectors.insert(r.identity).inserted else { return }
            for sub in list.elements where sub.isDict { rendition(sub, p, box, depth + 1) }
            return
        }
        guard let clip = r.dict("C"), clip.name("S") == "MCD" else { return }
        if !clip.has("CT") { add("28-014", loc("A media clip on this page doesn't say its type (CT)."), page: p, box: box, element: loc("Media clip")) }
        // Alt: language and text pairs, every one a string, no text empty.
        var usable = false
        if let alt = clip.array("Alt"), alt.count % 2 == 0 {
            usable = true
            for i in 0..<alt.count {
                guard let s = alt[i]?.text, i % 2 == 0 || !s.isEmpty else {
                    usable = false
                    break
                }
            }
        }
        if !usable { add("28-015", loc("A media clip on this page has no usable alternate description (Alt: pairs of a language and a text)."), page: p, box: box, element: loc("Media clip")) }
    }

    /// The fonts an annotation's appearance draws with (they must meet the font rules too). Each stream once: walking it
    /// again adds no fonts, and thousands of annotations may share one.
    private func appearance(_ a: PObj, _ p: Int, _ page: PObj) throws {
        guard let n = a.dict("AP")?.dict("N"), walkedAppearances.insert(n.identity).inserted else { return }
        var streams: [PObj] = []
        if n.isStream {
            streams.append(n)
        } else {
            streams = Array(n.keys.compactMap { n.dict($0) }.filter(\.isStream).prefix(8)) // every state (a check box's on and off)
            if n.keys.count > 8 { noteOnce(loc("An annotation has very many appearances; only the first 8 were checked.")) }
        }
        for s in streams where (s.identity == n.identity || walkedAppearances.insert(s.identity).inserted) && totalOps <= maxDocumentOperators {
            let bytes = s.streamData ?? []
            let walk = AccessibilityWalk(self, p, page)
            walk.read(bytes.count)
            do {
                let ops = try ContentLexer.parse(bytes, cancel: cancel, limit: Self.maxOperators + 1)
                var marks: [AccessibilityWalk.Mc] = []
                try walk.run(ops, s.dict("Resources"), .identity, nil, &marks, 0, true)
            } catch let e as CancellationError {
                throw e
            } catch {
                noteOnce(loc("An annotation's appearance couldn't be read, so its fonts weren't checked."))
                continue
            }
            if walk.stopped { notes.append(loc("Page {0}: an annotation's appearance is very long; only the first part of it was checked.", p + 1)) }
        }
    }

    /// A field's widget (the field itself, or a widget among its kids) is in a tag that has a language.
    private func widgetLang(_ field: PObj) -> Bool {
        var widgets: [PObj] = []
        if field.name("Subtype") == "Widget" { widgets.append(field) }
        if let kids = field.array("Kids") {
            widgets += kids.elements.lazy.filter { $0.isDict && $0.name("Subtype") == "Widget" }.prefix(64)
        }
        for w in widgets {
            // The widget's own tag; languages further up don't count here (as veraPDF reads it).
            if let k = w.int("StructParent"), let entry = parentTree[k], let d = entry, d.isDict, d.has("Lang") { return true }
        }
        return false
    }

    /// Form fields' tooltips need a language too (the document's, or the field's).
    private func formFields() {
        guard !docLang, let fields = catalog.dict("AcroForm")?.array("Fields") else { return }
        var seen = Set<UInt>()
        var stack: [(field: PObj, depth: Int)] = fields.elements.filter(\.isDict).map { ($0, 0) }
        var count = 0
        while let (f, depth) = stack.popLast(), seen.count < 50_000 {
            guard depth <= 32, seen.insert(f.identity).inserted else { continue }
            if Self.hasText(f, "TU") && !f.has("Lang") && !widgetLang(f) { count += 1 }
            if let kids = f.array("Kids") {
                for kid in kids.elements where kid.isDict { stack.append((kid, depth + 1)) }
            }
        }
        if !stack.isEmpty { noteOnce(loc("The file has very many form fields; only the first 50,000 were checked.")) }
        if count > 0 {
            let problem = count == 1 ? loc("The tooltips of {0} form field have no language, and the document has none.", count)
                : loc("The tooltips of {0} form fields have no language, and the document has none.", count)
            add("11-005", problem, element: loc("Form fields"), count: count)
        }
    }
}

/// Walks a page's content and the forms it draws: every item tagged or artifact, languages, fonts used.
final class AccessibilityWalk {
    typealias Mat = ContentEditor.Mat

    /// One marked-content sequence open around what is drawn.
    struct Mc {
        var tag: String
        var tagged: Bool
        var elem: AccessibilityElem?
        var lang: Bool
    }

    private struct State {
        var ctm = Mat.identity
        var font: PObj?
        var size = 12.0, charSpace = 0.0, wordSpace = 0.0, scale = 1.0, leading = 0.0, rise = 0.0
        var mode = 0
    }

    private let c: AccessibilityChecker
    private let pageIndex: Int
    private let frame: PageFrame
    private let size: (w: Double, h: Double)

    var untagged = 0, artifactInTagged = 0, taggedInArtifact = 0, noLang = 0, spanNoLang = 0
    var untaggedBox = RectD.zero, noLangBox = RectD.zero
    var badLangs = Set<String>()
    var stopped = false
    private var opCount = 0
    private var active = Set<UInt>()
    private var form: UInt?

    init(_ c: AccessibilityChecker, _ pageIndex: Int, _ page: PObj) {
        self.c = c
        self.pageIndex = pageIndex
        frame = PageBoxes.frame(page)
        size = PageBoxes.displaySize(page)
    }

    private static func mat(_ op: COp) -> Mat { Mat(op.n(0), op.n(1), op.n(2), op.n(3), op.n(4), op.n(5)) }

    /// Counts content read against the limits: a form of nothing but spaces has no drawing steps to count, however often it is read.
    func read(_ bytes: Int) {
        let steps = bytes / AccessibilityChecker.bytesPerOperator
        opCount += steps
        c.totalOps += steps
    }

    /// A form's drawing steps; only reading its bytes counts, not drawing what was kept.
    private func formOps(_ x: AccessibilityXObject) throws -> [COp] {
        if let ops = x.ops { return ops }
        let bytes = x.obj.streamData ?? []
        read(bytes.count)
        return try c.parse(x, bytes)
    }

    /// - Parameter contentOnly: an annotation's appearance: only its fonts count.
    func run(_ ops: [COp], _ resources: PObj?, _ ctm: Mat, _ key: Int?, _ marks: inout [Mc], _ depth: Int, _ contentOnly: Bool) throws {
        var st = State(ctm: ctm)
        var stack: [State] = []
        var tm = Mat.identity, tlm = Mat.identity
        var path: [(x: Double, y: Double)] = []
        let depthAtStart = marks.count
        for op in ops {
            opCount += 1
            c.totalOps += 1
            if opCount > AccessibilityChecker.maxOperators || c.totalOps > c.maxDocumentOperators {
                stopped = true
                break
            }
            if opCount & 4095 == 0 { try c.cancel.check() }
            let count = op.operands.count
            switch op.name {
            case "q":
                if stack.count < 256 { stack.append(st) }
            case "Q":
                if let top = stack.popLast() { st = top }
            case "cm" where count >= 6:
                st.ctm = Self.mat(op).times(st.ctm)
            case "BMC", "BDC":
                begin(op, resources, key, &marks, contentOnly)
            case "EMC":
                if marks.count > depthAtStart { marks.removeLast() }
            case "BT":
                tm = .identity
                tlm = .identity
            case "Tf" where count >= 2:
                let name = op.operands[0]
                let found = name.kind == .name ? AccessibilityChecker.entry(resources?.dict("Font"), name.name) : nil
                st.font = found?.isDict == true ? found : nil
                st.size = op.n(1)
            case "Tc" where count >= 1: st.charSpace = op.n(0)
            case "Tw" where count >= 1: st.wordSpace = op.n(0)
            case "Tz" where count >= 1: st.scale = op.n(0) / 100
            case "TL" where count >= 1: st.leading = op.n(0)
            case "Ts" where count >= 1: st.rise = op.n(0)
            case "Tr" where count >= 1: st.mode = Int(exactly: op.n(0).rounded(.towardZero)) ?? 0
            case "Td" where count >= 2:
                tlm = Mat(1, 0, 0, 1, op.n(0), op.n(1)).times(tlm)
                tm = tlm
            case "TD" where count >= 2:
                st.leading = -op.n(1)
                tlm = Mat(1, 0, 0, 1, op.n(0), op.n(1)).times(tlm)
                tm = tlm
            case "Tm" where count >= 6:
                tlm = Self.mat(op)
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
                let start = tm
                var codes: [Int] = []
                for o in op.operands {
                    if o.kind == .string {
                        show(o.bytes, st, &tm, &codes)
                    } else if o.kind == .array {
                        for item in o.items {
                            if item.kind == .string {
                                show(item.bytes, st, &tm, &codes)
                            } else if item.kind == .number {
                                tm = Mat(1, 0, 0, 1, -item.num / 1000 * st.size * st.scale, 0).times(tm)
                            }
                        }
                    }
                }
                if codes.isEmpty { break }
                let box = textBox(start, tm, st)
                if let font = st.font { c.useFont(font, codes, shown: st.mode != 3, page: pageIndex, box: box) }
                if contentOnly { break }
                item(marks, box)
                if !c.docLang && !marks.contains(where: { $0.lang }) && !marks.contains(where: { AccessibilityChecker.hasLang($0.elem) }) {
                    noLang += 1
                    if noLang <= 8 { noLangBox = noLangBox.union(box) }
                }
            case "m" where count >= 2, "l" where count >= 2:
                path.append((op.n(0), op.n(1)))
            case "c" where count >= 6:
                path.append((op.n(0), op.n(1)))
                path.append((op.n(2), op.n(3)))
                path.append((op.n(4), op.n(5)))
            case "v" where count >= 4, "y" where count >= 4:
                path.append((op.n(0), op.n(1)))
                path.append((op.n(2), op.n(3)))
            case "re" where count >= 4:
                path.append((op.n(0), op.n(1)))
                path.append((op.n(0) + op.n(2), op.n(1) + op.n(3)))
            case "f", "F", "f*", "B", "B*", "b", "b*", "S", "s":
                if !contentOnly && !path.isEmpty { item(marks, box(path, st.ctm)) }
                path.removeAll(keepingCapacity: true)
            case "n":
                path.removeAll(keepingCapacity: true)
            case "sh":
                if !contentOnly { item(marks, box([(0, 0), (1, 1)], st.ctm)) }
            case "BI":
                if !contentOnly { item(marks, box([(0, 0), (1, 1), (0, 1), (1, 0)], st.ctm)) }
            case "Do" where count > 0 && op.operands[0].kind == .name:
                guard let x = c.xobject(resources, op.operands[0].name) else { break }
                if x.isImage {
                    if !contentOnly { item(marks, box([(0, 0), (1, 1), (0, 1), (1, 0)], st.ctm)) }
                } else if x.isForm {
                    if x.isReference { c.refForms.insert(x.identity) }
                    if !contentOnly {
                        if var use = c.forms[x.identity] {
                            use.uses += 1
                            c.forms[x.identity] = use
                        } else {
                            c.forms[x.identity] = AccessibilityFormUse(uses: 1, tagged: false, page: pageIndex)
                            c.formOrder.append(x.identity)
                        }
                    }
                    if depth >= AccessibilityChecker.maxFormDepth {
                        c.noteOnce(loc("Forms nested more than {0} deep weren't checked.", AccessibilityChecker.maxFormDepth))
                        break
                    }
                    if !active.insert(x.identity).inserted { break }
                    let outer = form
                    form = x.identity
                    try run(try formOps(x), x.resources ?? resources, x.matrix.times(st.ctm), x.structParents ?? key, &marks, depth + 1, contentOnly)
                    form = outer
                    active.remove(x.identity)
                }
            default:
                break
            }
        }
        // Sequences left open at the end of a stream close with it.
        if marks.count > depthAtStart { marks.removeLast(marks.count - depthAtStart) }
    }

    private func begin(_ op: COp, _ resources: PObj?, _ key: Int?, _ marks: inout [Mc], _ contentOnly: Bool) {
        let tag = op.operands.first?.kind == .name ? op.operands[0].name : ""
        var mcid: Int?
        var lang = false
        var alt = false
        if op.name == "BDC" && op.operands.count > 1 {
            let props = op.operands[1]
            if props.kind == .dict {
                if let n = props["MCID"], n.kind == .number { mcid = Int(exactly: n.num.rounded(.towardZero)) }
                if let l = props["Lang"] {
                    lang = true
                    if l.kind == .string {
                        let s = latin1String(l.bytes)
                        if !AccessibilityCheck.isLanguage(s) { badLangs.insert(s) }
                    }
                }
                alt = props["Alt"] != nil || props["ActualText"] != nil || props["E"] != nil
            } else if props.kind == .name, let pd = AccessibilityChecker.entry(resources?.dict("Properties"), props.name), pd.isDict {
                mcid = pd.int("MCID")
                if pd.has("Lang") {
                    lang = true
                    if let s = AccessibilityChecker.text(pd["Lang"]), !AccessibilityCheck.isLanguage(s) { badLangs.insert(s) }
                }
                alt = pd.has("Alt") || pd.has("ActualText") || pd.has("E")
            }
        }
        let (tagged, elem) = mcid.map { c.byMcid(key, $0) } ?? (false, nil)
        if mcid != nil, let form, c.forms[form] != nil { c.forms[form]?.tagged = true }
        if !contentOnly {
            // An artifact with a marked-content id of its own is both at once.
            let insideTagged = tagged || marks.contains { $0.tagged }
            let insideArtifact = tag == "Artifact" || marks.contains { $0.tag == "Artifact" }
            if tag == "Artifact" && insideTagged { artifactInTagged += 1 }
            if insideTagged && insideArtifact { taggedInArtifact += 1 } // (an artifact inside tagged content is both, as veraPDF counts it)
            if tag == "Span" && alt && !lang && !c.docLang && !marks.contains(where: { $0.lang }) && !marks.contains(where: { AccessibilityChecker.hasLang($0.elem) }) { spanNoLang += 1 }
        }
        marks.append(Mc(tag: tag, tagged: tagged, elem: elem, lang: lang))
    }

    /// A content item: tagged (in marked content an element stands for), an artifact, or neither.
    private func item(_ marks: [Mc], _ box: RectD) {
        var elem: AccessibilityElem?
        var tagged = false, artifact = false
        for m in marks {
            if m.tag == "Artifact" { artifact = true }
            if m.tagged {
                tagged = true
                elem = m.elem ?? elem
            }
        }
        if let elem, !box.isEmpty, elem.content.count < 64 { elem.content.append((pageIndex, box)) }
        if tagged || artifact { return }
        untagged += 1
        if untagged <= 8 { untaggedBox = untaggedBox.union(box) }
    }

    private func show(_ bytes: [UInt8], _ st: State, _ tm: inout Mat, _ codes: inout [Int]) {
        guard let font = st.font else {
            // No font set: still something drawn (one item), advanced roughly.
            codes.append(-1)
            tm = Mat(1, 0, 0, 1, Double(bytes.count) * 0.5 * st.size * st.scale, 0).times(tm)
            return
        }
        for g in c.textFont(font).decode(bytes) {
            codes.append(g.code)
            let word = g.length == 1 && g.code == 32 ? st.wordSpace : 0
            let tx: Double = (g.width * st.size + st.charSpace + word) * st.scale
            tm = Mat(1, 0, 0, 1, tx, 0).times(tm)
        }
    }

    private func textBox(_ start: Mat, _ end: Mat, _ st: State) -> RectD {
        let size = st.size == 0 ? 1 : st.size
        let trs = Mat(size * st.scale, 0, 0, size, 0, st.rise)
        let a = trs.times(start).times(st.ctm), b = trs.times(end).times(st.ctm)
        return box([a.apply(0, -0.2), a.apply(0, 0.8), b.apply(0, -0.2), b.apply(0, 0.8)], .identity)
    }

    private func box(_ pts: [(x: Double, y: Double)], _ ctm: Mat) -> RectD {
        var l = Double.greatestFiniteMagnitude, t = Double.greatestFiniteMagnitude
        var r = -Double.greatestFiniteMagnitude, b = -Double.greatestFiniteMagnitude
        for p in pts {
            let u = ctm.apply(p.x, p.y)
            let q = frame.toPage(u.x, u.y)
            l = min(l, q.x)
            r = max(r, q.x)
            t = min(t, q.y)
            b = max(b, q.y)
        }
        guard l.isFinite, r.isFinite, t.isFinite, b.isFinite else { return .zero }
        let edges = RectD.fromEdges(max(l, -10), max(t, -10), min(r, size.w + 10), min(b, size.h + 10))
        return edges.width <= 0 && edges.height <= 0 ? .zero : RectD(edges.x, edges.y, max(edges.width, 1), max(edges.height, 1))
    }
}
