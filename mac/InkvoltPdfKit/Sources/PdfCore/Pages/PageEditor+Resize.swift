import Foundation
import PrintCore

/// How Resize Pages fits a page's content on its new paper.
public enum ResizeFit: Sendable {
    /// Scaled up or down to fill the new size as far as it can without being cut, centred.
    case scale
    /// Kept at its size and centred, the rest of the paper left as margins; shrunk only when it wouldn't fit.
    case margins
}

/// Resize Pages (the Windows app's `PageEditor.Resize`, roadmap 4.7): each page on paper of one size (Letter, A4, a size
/// typed), its content scaled to fit or centred with margins added. A page keeps the way it is turned: a page that shows
/// landscape gets the paper sideways. The visible area becomes the page; what lay outside it (a crop) is clipped, and
/// comments, fields and the destinations that lead to the page move and scale with the content.
extension PageEditor {
    /// The smallest and largest paper side accepted, in points (1 inch; 200 inches, PDF's own limit).
    public static let minPaper = 72.0, maxPaper = 14_400.0

    /// - Parameters:
    ///   - width: the paper's width in points, upright (the shorter side for portrait paper).
    ///   - height: the paper's height in points.
    /// - Throws: `PdfEditError` when a side isn't a number between `minPaper` and `maxPaper`, or a page's size in the file
    ///   can't be right (nothing is resized then).
    public static func resize(_ data: [UInt8], _ password: String?, _ pages: [Int], _ width: Double, _ height: Double, _ fit: ResizeFit) throws -> [UInt8] {
        if !width.isFinite || !height.isFinite || width < minPaper || height < minPaper || width > maxPaper || height > maxPaper {
            throw PdfEditError(loc("A side of the paper must be between {0} and {1} inches.", CoreLanguage.number(Int(minPaper / 72)), CoreLanguage.number(Int(maxPaper / 72))))
        }
        return try edit(data, password) { doc in
            let count = try doc.pageCount()
            var moved: [ObjId: (s: Double, e: Double, f: Double)] = [:]
            for i in Array(Set(pages)).sorted() where i >= 0 && i < count {
                let page = doc.page(i)
                // A size no page can have (±1e308 makes the scale nothing and the place NaN): refused, nothing resized.
                guard let box = shownBox(page), isUsableBox(box) else {
                    throw PdfEditError(loc("Page {0} has a size in the file that can't be right, so no page was resized.", CoreLanguage.number(i + 1)))
                }
                if let t = resizePage(doc, page, width, height, fit) { moved[page.id] = t }
            }
            if moved.isEmpty { return }
            forEachDestination(doc) { dest, page in
                if let t = moved[page] { moveDestination(doc, dest, t.s, t.e, t.f) }
            }
        }
    }

    /// A destination on a resized page, its place moved as the content was: /XYZ's left and top, /FitH's and /FitBH's
    /// top, /FitV's and /FitBV's left, /FitR's rectangle (a null stays null: "as it was"). /XYZ's zoom stays.
    static func moveDestination(_ doc: MuDoc, _ dest: PObj, _ s: Double, _ e: Double, _ f: Double) {
        func set(_ i: Int, _ scale: Double, _ offset: Double) {
            guard i < dest.count, let v = dest[i]?.number, v.isFinite else { return }
            let moved = v * scale + offset
            if moved.isFinite && abs(moved) <= Double(Float.greatestFiniteMagnitude) { dest.replace(at: i, with: doc.real(moved)) }
        }
        switch dest[1]?.name {
        case "XYZ":
            set(2, s, e)
            set(3, s, f)
        case "FitH", "FitBH":
            set(2, s, f)
        case "FitV", "FitBV":
            set(2, s, e)
        case "FitR":
            set(2, s, e)
            set(3, s, f)
            set(4, s, e)
            set(5, s, f)
        default:
            break
        }
    }

    /// The farthest a page box's corner is taken to be from the origin (points): about 140 miles, far past any paper.
    static let maxBoxCoordinate = 10_000_000.0

    /// What the page shows, as Resize Pages works from it: its visible box; when its media box has no size (MuPDF reads a
    /// whole number too large for it, as ±1e308 written out, as 0) the crop box alone, if it has one of a size; else nil.
    static func shownBox(_ page: PObj) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        let m = PageBoxes.mediaBox(page)
        if m.x2 - m.x1 >= 1 && m.y2 - m.y1 >= 1 { return PageBoxes.visibleBox(page) }
        if let c = PageBoxes.rect(PageBoxes.inherited(page, "CropBox")), c.x2 - c.x1 >= 1, c.y2 - c.y1 >= 1 { return c }
        return nil
    }

    /// A page box Resize Pages can work from: its corners numbers within `maxBoxCoordinate`.
    static func isUsableBox(_ box: (x1: Double, y1: Double, x2: Double, y2: Double)) -> Bool {
        [box.x1, box.y1, box.x2, box.y2].allSatisfy { $0.isFinite && abs($0) <= maxBoxCoordinate }
    }

    /// The transform that puts the page's visible box on the new paper: scale s, then move by (e, f), the new page w × h;
    /// nil when it is already so.
    static func resizeTransform(_ box: (x1: Double, y1: Double, x2: Double, y2: Double), _ rotate: Int, _ width: Double, _ height: Double,
                                _ fit: ResizeFit) -> (s: Double, e: Double, f: Double, w: Double, h: Double)? {
        let w = box.x2 - box.x1, h = box.y2 - box.y1
        if !(w >= 1 && h >= 1) || !isUsableBox(box) { return nil }
        let sideways = ((rotate % 360) + 360) % 360 == 90 || ((rotate % 360) + 360) % 360 == 270
        let (shownW, shownH) = sideways ? (h, w) : (w, h)
        let small = min(width, height), large = max(width, height)
        let (paperW, paperH) = shownW > shownH ? (large, small) : (small, large) // as the page shows
        let (tw, th) = sideways ? (paperH, paperW) : (paperW, paperH) // in the page's own (unturned) space
        var s = min(tw / w, th / h)
        if fit == .margins { s = min(1, s) }
        let e = (tw - w * s) / 2 - box.x1 * s, f = (th - h * s) / 2 - box.y1 * s
        if abs(s - 1) < 1e-6 && abs(e) < 0.01 && abs(f) < 0.01 && abs(w - tw) < 0.01 && abs(h - th) < 0.01 { return nil }
        return (s, e, f, tw, th)
    }

    /// How the page's content was scaled and moved, or nil when it was left as it was.
    private static func resizePage(_ doc: MuDoc, _ page: PObj, _ width: Double, _ height: Double, _ fit: ResizeFit) -> (s: Double, e: Double, f: Double)? {
        guard let box = shownBox(page) else { return nil }
        guard let t = resizeTransform(box, PageBoxes.rotate(page), width, height, fit) else { return nil }
        let (s, e, f, tw, th) = t

        // The content, scaled and moved, clipped to what showed before.
        let n = PdfNum.f
        let open = "q \(n(s)) 0 0 \(n(s)) \(n(e)) \(n(f)) cm \(n(box.x1)) \(n(box.y1)) \(n(box.x2 - box.x1)) \(n(box.y2 - box.y1)) re W n\n"
        let contents = doc.array([doc.addStream(Array(open.utf8), deflate: false)])
        if let existing = page["Contents"] {
            if existing.isArray {
                for c in existing.elements { contents.append(c) }
            } else if existing.isRef {
                contents.append(existing)
            }
        }
        contents.append(doc.addStream(Array("\nQ\n".utf8), deflate: false))
        page.set("Contents", contents)

        func map(_ x: Double, _ y: Double) -> (Double, Double) { (x * s + e, y * s + f) }
        page.set("MediaBox", doc.reals(0, 0, tw, th))
        page.remove("CropBox")
        for key in ["TrimBox", "BleedBox", "ArtBox"] {
            guard let b = page.array(key), b.count == 4 else { continue }
            let (ax, ay) = map(b.num(0), b.num(1)), (bx, by) = map(b.num(2), b.num(3))
            let x1 = max(0, min(ax, bx)), y1 = max(0, min(ay, by)), x2 = min(tw, max(ax, bx)), y2 = min(th, max(ay, by))
            if !(x2 - x1 >= 1 && y2 - y1 >= 1) { page.remove(key) } else { page.set(key, doc.reals(x1, y1, x2, y2)) }
        }

        // Comments, links and fields: where they are and the points they are drawn through. An appearance fills its
        // /Rect, so it scales with it.
        func moveArray(_ a: PObj) {
            let n = a.count & ~1
            var values: [Double] = []
            values.reserveCapacity(n)
            for k in stride(from: 0, to: n, by: 2) {
                let (x, y) = map(a.num(k), a.num(k + 1))
                values += [x, y]
            }
            // A point no page has (±1e308): left as it was, never written as NaN or past what a PDF number holds.
            if !values.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) }) { return }
            for k in stride(from: a.count - 1, through: 0, by: -1) { a.remove(at: k) }
            for v in values { a.append(doc.real(v)) }
        }
        func movePoints(_ d: PObj, _ key: String) {
            if let a = d.array(key) { moveArray(a) }
        }
        var seen = Set<UInt>()
        for annot in page.array("Annots")?.elements ?? [] where annot.isDict && seen.insert(annot.identity).inserted {
            for key in ["Rect", "QuadPoints", "Vertices", "L", "CL"] { movePoints(annot, key) }
            if let ink = annot.array("InkList") {
                for path in ink.elements where path.isArray { moveArray(path) }
            }
            if let rd = annot.array("RD"), rd.count == 4 {
                annot.set("RD", doc.reals(rd.num(0) * s, rd.num(1) * s, rd.num(2) * s, rd.num(3) * s))
            }
            if let popup = annot.dict("Popup"), seen.insert(popup.identity).inserted { movePoints(popup, "Rect") }
        }
        return (s, e, f)
    }

    /// Calls `visit` with every explicit destination array the document holds ([page /XYZ …], [page /Fit] …, in
    /// bookmarks, links, actions, named destinations, the opening view) and the page object it leads to; each object is
    /// looked at once.
    static func forEachDestination(_ doc: MuDoc, _ visit: (PObj, ObjId) -> Void) {
        var seen = Set<UInt>()
        var todo: [PObj] = []
        func push(_ item: PObj?) {
            guard let item, item.isArray || item.isDict, seen.insert(item.identity).inserted else { return }
            todo.append(item)
        }
        push(doc.catalog)
        for page in (try? doc.pages()) ?? [] { push(page) }
        while let next = todo.popLast() {
            if next.isArray {
                if next.count >= 2, let first = next[0], first.isRef, next[1]?.kind == .name { visit(next, first.id) }
                for e in next.elements { push(e) }
            } else {
                for key in next.keys where key != "Parent" { push(next[key]) }
            }
        }
    }
}
