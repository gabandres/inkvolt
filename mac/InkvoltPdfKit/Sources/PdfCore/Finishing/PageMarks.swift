import Foundation

/// Content Inkvolt PDF adds to pages (headers and footers, watermarks): real page content, so it prints in every viewer,
/// yet removable again (the Windows app's `PageMarks`). Each is a form XObject drawn by content streams of its own; the
/// XObject and those streams carry a private key (`key`, e.g. /InkvoltPdfMark /HeaderFooter) by which they are found
/// later. Drawn over the page, the page's own content is wrapped in q/Q (a "q" stream first, "Q" and the drawing last) so
/// its graphics state can't leak into the drawing; drawn behind, the drawing is one self-contained stream before the
/// page's own. Wrappers of different kinds nest, so either kind can be removed without the other. Page content that
/// leaves q/Q unbalanced (an unclosed q, or a Q with nothing to restore) is first wrapped in a balancing pair of its own
/// (/Balance), so a mark drawn over it starts from the page's own coordinates. The drawing is a pagination artifact
/// (marked content), so screen readers and reflow skip it.
enum PageMarks {
    static let key = "InkvoltPdfMark"
    private static let balanceKind = "Balance"

    /// The page as shown (rotation and crop applied): its size, and the /Matrix that maps a form drawn in displayed-page
    /// coordinates (origin at the bottom-left of the page as shown, y up) into the page's user space. Sizes are in points:
    /// on a page with a /UserUnit (one unit is that many points) the form is drawn in points and scaled into the page's
    /// units, so margins, font sizes and tiles are the same on paper as on any other page.
    static func frame(_ doc: MuDoc, _ page: PObj) -> (w: Double, h: Double, matrix: PObj) {
        let (w, h) = PageBoxes.displaySize(page)
        let u = userUnit(page)
        let m = displayMatrix(page)
        return (w * u, h * u, doc.realArray([m[0] / u, m[1] / u, m[2] / u, m[3] / u, m[4], m[5]]))
    }

    /// The page's /UserUnit (points per unit; 1 when absent or unusable).
    static func userUnit(_ page: PObj) -> Double {
        let u = page.number("UserUnit") ?? 1
        return u.isFinite && u >= 0.001 && u <= 75000 ? u : 1
    }

    /// [a b c d e f]: displayed-page coordinates (bottom-left origin, y up) to user space.
    static func displayMatrix(_ page: PObj) -> [Double] {
        let (_, h) = PageBoxes.displaySize(page)
        // Page space has its origin top-left with y down: displayed (x, y) is page space (x, h - y). The map is affine,
        // so three points give it.
        let o = PageBoxes.toPdf(page, 0, h)
        let x = PageBoxes.toPdf(page, 1, h)
        let y = PageBoxes.toPdf(page, 0, h - 1)
        return [x.x - o.x, x.y - o.y, y.x - o.x, y.y - o.y, o.x, o.y]
    }

    /// Draws `form` on `page` as a mark of `kind` (over or behind the content); `artifact` is the artifact's property
    /// list, e.g. "<</Type /Pagination /Subtype /Watermark>>".
    static func add(_ doc: MuDoc, _ page: PObj, _ form: PObj, _ kind: String, behind: Bool, _ artifact: String) {
        form.set(key, doc.name(kind))
        let xobjects = ownXObjects(doc, page)
        var i = 0
        while xobjects.has("Iv\(kind)\(i)") { i += 1 }
        let name = "Iv\(kind)\(i)"
        xobjects.set(name, form)

        let draw = "/Artifact \(artifact) BDC q /\(name) Do Q EMC\n"
        if !behind { balance(doc, page) }
        var contents: [PObj] = []
        contents.append(stream(doc, kind, behind ? "q\n" + draw + "Q\n" : "q\n"))
        contents += parts(page)
        if !behind { contents.append(stream(doc, kind, "Q\n" + draw)) }
        page.set("Contents", doc.array(contents))
    }

    /// Takes the marks of `kind` off the page (its streams and XObjects). False when it had none.
    @discardableResult
    static func remove(_ doc: MuDoc, _ page: PObj, _ kind: String) -> Bool {
        guard let arr = page.array("Contents") else { return false }
        var keep: [PObj] = []
        var removed = false
        for e in arr.elements {
            if isMark(e, kind) { removed = true } else { keep.append(e) }
        }
        if !removed { return false }
        // The balancing pair goes with the last mark: the page is left as it was.
        if !keep.contains(where: { $0.isDict && $0.has(key) && !isMark($0, balanceKind) }) {
            keep.removeAll { isMark($0, balanceKind) }
        }
        page.set("Contents", doc.array(keep))
        SignedEdits.noteRemoval()
        // Add gave the page its own XObject dictionary, so these entries are this page's.
        if let xobjects = page.dict("Resources")?.dict("XObject") {
            for k in xobjects.keys where isMark(xobjects[k], kind) { xobjects.remove(k) }
        }
        return true
    }

    /// True when any page has a mark of `kind`.
    static func has(_ doc: MuDoc, _ kind: String) -> Bool {
        for page in (try? doc.pages()) ?? [] {
            if page.array("Contents")?.elements.contains(where: { isMark($0, kind) }) == true { return true }
        }
        return false
    }

    /// The page's content streams in order (one, or the array's).
    private static func parts(_ page: PObj) -> [PObj] {
        guard let c = page["Contents"] else { return [] }
        return c.isArray ? c.elements : [c]
    }

    /// Wraps the page's own content (the streams that aren't marks) in a balancing pair when its q/Q don't match: a "q"
    /// stream before it for each Q that has nothing to restore, and a "Q" stream after it closing everything still open.
    /// Afterwards the content leaves the graphics state as it found it, so a mark drawn after it lands where it should.
    private static func balance(_ doc: MuDoc, _ page: PObj) {
        let items = parts(page)
        // The page's own streams (and an earlier balancing pair), in order: the q/Q of marks balance themselves.
        let own = items.enumerated().filter { $0.element.isDict && (!$0.element.has(key) || isMark($0.element, balanceKind)) }
        guard let first = own.first, let last = own.last else { return }
        let (depth, lowest) = saveDepth(own.map { $0.element.streamData ?? [] })
        if depth == 0 && lowest == 0 { return }
        let open = -lowest
        var list: [PObj] = []
        for (i, item) in items.enumerated() {
            if i == first.offset && open > 0 { list.append(stream(doc, balanceKind, String(repeating: "q ", count: open) + "\n")) }
            list.append(item)
            if i == last.offset && open + depth > 0 { list.append(stream(doc, balanceKind, "\n" + String(repeating: "Q ", count: open + depth) + "\n")) }
        }
        page.set("Contents", doc.array(list))
    }

    /// The q/Q nesting of content streams read in a row: where it ends (q minus Q) and the lowest it gets (0, or less when
    /// a Q comes with nothing to restore). Strings, comments and inline image data are skipped.
    static func saveDepth(_ streams: [[UInt8]]) -> (end: Int, lowest: Int) {
        var depth = 0, lowest = 0
        for s in streams {
            var i = 0
            while i < s.count {
                let c = s[i]
                if isSpace(c) {
                    i += 1
                } else if c == 37 { // %
                    while i < s.count && s[i] != 13 && s[i] != 10 { i += 1 }
                } else if c == 40 { // ( a literal string: balanced parentheses, backslash escapes
                    var nest = 0
                    while i < s.count {
                        if s[i] == 92 { i += 1 } else if s[i] == 40 { nest += 1 } else if s[i] == 41 {
                            nest -= 1
                            if nest == 0 { break }
                        }
                        i += 1
                    }
                    i += 1
                } else if c == 60 && i + 1 < s.count && s[i + 1] != 60 { // < a hex string
                    while i < s.count && s[i] != 62 { i += 1 }
                    i += 1
                } else if c == 47 { // / a name (/Q is a resource name, not an operator)
                    i += 1
                    while i < s.count && !isSpace(s[i]) && !isDelimiter(s[i]) { i += 1 }
                } else if isDelimiter(c) {
                    i += 1
                } else {
                    let start = i
                    i += 1
                    while i < s.count && !isSpace(s[i]) && !isDelimiter(s[i]) { i += 1 }
                    let len = i - start
                    if len == 1 && c == 113 { // q
                        depth += 1
                    } else if len == 1 && c == 81 { // Q
                        depth -= 1
                        lowest = min(lowest, depth)
                    } else if len == 2 && c == 66 && s[start + 1] == 73 { // BI
                        i = afterInlineImage(s, i)
                    }
                }
            }
        }
        return (depth, lowest)
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }

    private static func isDelimiter(_ b: UInt8) -> Bool {
        b == 40 || b == 41 || b == 60 || b == 62 || b == 91 || b == 93 || b == 123 || b == 125 || b == 47 || b == 37
    }

    /// Past an inline image's data: the "EI" (between white space) after its "ID".
    private static func afterInlineImage(_ s: [UInt8], _ from: Int) -> Int {
        var i = from
        while i + 2 < s.count {
            if s[i] == 73 && s[i + 1] == 68 && i > 0 && isSpace(s[i - 1]) && isSpace(s[i + 2]) {
                i += 3
                break
            }
            i += 1
        }
        while i + 1 < s.count {
            if s[i] == 69 && s[i + 1] == 73 && i > 0 && isSpace(s[i - 1]) && (i + 2 == s.count || isSpace(s[i + 2]) || isDelimiter(s[i + 2])) {
                return i + 2
            }
            i += 1
        }
        return s.count
    }

    private static func isMark(_ d: PObj?, _ kind: String) -> Bool { d?.isDict == true && d?.name(key) == kind }

    private static func stream(_ doc: MuDoc, _ kind: String, _ ops: String) -> PObj {
        doc.addStream(Array(ops.utf8), dict: doc.dict([(key, doc.name(kind))]), deflate: false)
    }

    /// The page's XObject dictionary, made its own first (resources, and their XObject dictionary, may be shared between
    /// pages, or inherited from the page tree: an entry added for one page must not show up in, or be removed from,
    /// another).
    private static func ownXObjects(_ doc: MuDoc, _ page: PObj) -> PObj {
        let resources = copy(doc, PageBoxes.inherited(page, "Resources"))
        page.set("Resources", resources)
        let xobjects = copy(doc, resources.dict("XObject"))
        resources.set("XObject", xobjects)
        return xobjects
    }

    private static func copy(_ doc: MuDoc, _ from: PObj?) -> PObj {
        let d = doc.dict()
        if let from, from.isDict {
            for k in from.keys { d.set(k, from[k]) }
        }
        return d
    }
}
