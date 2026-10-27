import Foundation

/// A page's boxes and the mapping between PDF user space and page space (points from the displayed, cropped and turned
/// page's top-left), as the Windows app's `PdfObj` geometry helpers have them.
enum PageBoxes {
    /// A page attribute, inherited from the page tree when the page doesn't have it.
    static func inherited(_ page: PObj, _ key: String) -> PObj? {
        var node: PObj? = page
        var depth = 0
        while let n = node, depth < 32 {
            if let v = n[key] { return v }
            node = n.dict("Parent")
            depth += 1
        }
        return nil
    }

    /// The page's /Rotate: 0, 90, 180 or 270.
    static func rotate(_ page: PObj) -> Int { (((inherited(page, "Rotate")?.int ?? 0) % 360) + 360) % 360 }

    /// A rectangle array as (x1, y1, x2, y2) with x1 ≤ x2, y1 ≤ y2; nil when it isn't one.
    static func rect(_ a: PObj?) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        guard let a, a.isArray, a.count == 4 else { return nil }
        let (ax, ay, bx, by) = (a.num(0), a.num(1), a.num(2), a.num(3))
        return (min(ax, bx), min(ay, by), max(ax, bx), max(ay, by))
    }

    static func mediaBox(_ page: PObj) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        rect(inherited(page, "MediaBox")) ?? (0, 0, 612, 792)
    }

    /// The page's visible area: its CropBox clipped to its MediaBox, as viewers show it (the MediaBox when there is no
    /// CropBox or it lies outside the MediaBox).
    static func visibleBox(_ page: PObj) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let m = mediaBox(page)
        guard let c = rect(inherited(page, "CropBox")) else { return m }
        let x1 = max(m.x1, c.x1), y1 = max(m.y1, c.y1), x2 = min(m.x2, c.x2), y2 = min(m.y2, c.y2)
        return x2 > x1 && y2 > y1 ? (x1, y1, x2, y2) : m
    }

    static func frame(_ page: PObj) -> PageFrame {
        let b = visibleBox(page)
        return PageFrame(bx1: b.x1, by2: b.y2, w: b.x2 - b.x1, h: b.y2 - b.y1, rot: rotate(page))
    }

    /// PDF user space → page space.
    static func toPage(_ page: PObj, _ x: Double, _ y: Double) -> (x: Double, y: Double) { frame(page).toPage(x, y) }

    /// Page space → PDF user space.
    static func toPdf(_ page: PObj, _ px: Double, _ py: Double) -> (x: Double, y: Double) { frame(page).toPdf(px, py) }

    /// The displayed page size in points (rotation applied).
    static func displaySize(_ page: PObj) -> (w: Double, h: Double) {
        let f = frame(page)
        return f.rot == 90 || f.rot == 270 ? (f.h, f.w) : (f.w, f.h)
    }
}

/// A page's visible box and /Rotate, read once: maps PDF user space to page space and back (`PageBoxes.toPage`, `toPdf`).
struct PageFrame: Sendable {
    var bx1: Double, by2: Double, w: Double, h: Double
    var rot: Int

    /// PDF user space → page space.
    func toPage(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let u = x - bx1, v = by2 - y
        switch rot {
        case 90: return (h - v, u)
        case 180: return (w - u, h - v)
        case 270: return (v, w - u)
        default: return (u, v)
        }
    }

    /// Page space → PDF user space.
    func toPdf(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
        let (u, v): (Double, Double)
        switch rot {
        case 90: (u, v) = (py, h - px)
        case 180: (u, v) = (w - px, h - py)
        case 270: (u, v) = (w - py, px)
        default: (u, v) = (px, py)
        }
        return (bx1 + u, by2 - v)
    }
}

/// How a destination shows its page.
public enum ZoomKind: String, Sendable { case XYZ, Fit, FitH, FitV, FitR, FitB, FitBH, FitBV }

/// A destination inside the document (page space: points from the displayed page's top-left); `zoom` 1 = 100 %, nil =
/// keep the current zoom.
public struct PageDestination: Equatable, Sendable {
    public var pageIndex: Int
    public var kind: ZoomKind
    public var x: Double?
    public var y: Double?
    public var zoom: Double?
}

/// Document-level navigation features (the Windows app's `DocumentFeatures`): page labels and destinations.
public enum DocumentFeatures {
    /// Each page's label from the /PageLabels number tree (e.g. "i", "ii", "1", "A-1"), or nil when the file has none.
    public static func pageLabels(_ data: [UInt8], _ password: String?) throws -> [String]? {
        let doc = try PdfEdit.openToRead(data, password)
        guard let tree = doc.catalog.dict("PageLabels") else { return nil }
        let ranges = PdfStructure.numberTree(tree).filter { $0.key >= 0 }.sorted { $0.key < $1.key }
        if ranges.isEmpty { return nil }
        return try (0..<doc.pageCount()).map { i in
            guard let idx = ranges.lastIndex(where: { $0.key <= i }) else { return String(i + 1) }
            let (start, value) = ranges[idx]
            let d = value.flatMap { $0.isDict ? $0 : nil }
            // A hostile /St (or start key) must not overflow, nor make Roman or letter labels huge.
            let first = min(max(d?.int("St") ?? 1, 1), 1_000_000_000)
            let n = min(max(first + i - start, Int(Int32.min)), Int(Int32.max))
            return (d?.text("P") ?? "") + formatNumber(n, d?.name("S"))
        }
    }

    /// A page number in a /PageLabels style (D, R, r, A, a; nil = no number).
    public static func formatNumber(_ n: Int, _ style: String?) -> String {
        switch style {
        case "D": String(n)
        case "R": roman(n)
        case "r": roman(n).lowercased()
        case "A": letters(n)
        case "a": letters(n).lowercased()
        default: ""
        }
    }

    private static func roman(_ n: Int) -> String {
        if n <= 0 || n > 39_999 { return String(n) } // beyond that a Roman numeral is just a wall of M's
        var n = n
        var s = ""
        for (v, r) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"),
                       (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while n >= v {
                s += r
                n -= v
            }
        }
        return s
    }

    /// A…Z, then AA…ZZ, AAA… (the PDF convention: the letter repeated).
    private static func letters(_ n: Int) -> String {
        if n <= 0 || n > 26 * 100 { return String(n) }
        let letter = Character(Unicode.Scalar(UInt8(65 + (n - 1) % 26)))
        return String(repeating: letter, count: (n - 1) / 26 + 1)
    }

    /// Resolves an explicit or named destination to a page and view.
    static func resolveDestination(_ doc: MuDoc, _ dest: PObj?, depth: Int = 0) -> PageDestination? {
        guard depth <= 8, let dest else { return nil }
        switch dest.kind {
        case .array where dest.count > 0:
            guard let page = doc.pageIndex(of: dest[0]) else { return nil }
            let p = doc.page(page)
            let kind = dest.count > 1 ? dest[1]?.name.flatMap(ZoomKind.init(rawValue:)) ?? .Fit : .Fit
            func arg(_ i: Int) -> Double? { i < dest.count ? dest[i]?.number : nil }
            var x: Double?, y: Double?, zoom: Double?
            switch kind {
            case .XYZ:
                (x, y) = point(p, arg(2), arg(3))
                zoom = arg(4).flatMap { $0 > 0 ? $0 : nil }
            case .FitH, .FitBH: (x, y) = point(p, nil, arg(2))
            case .FitV, .FitBV: (x, y) = point(p, arg(2), nil)
            case .FitR: (x, y) = point(p, arg(2), arg(5))
            default: break
            }
            return PageDestination(pageIndex: page, kind: kind, x: x, y: y, zoom: zoom)
        case .dict where dest.has("D"):
            return resolveDestination(doc, dest["D"], depth: depth + 1)
        case .name:
            return resolveDestination(doc, dest.name.flatMap { doc.catalog.dict("Dests")?[$0] }, depth: depth + 1)
        case .string:
            let tree = doc.catalog.dict("Names")?.dict("Dests")
            guard let key = dest.text, let hit = PdfStructure.nameTree(tree).first(where: { $0.key == key }) else { return nil }
            return resolveDestination(doc, hit.value, depth: depth + 1)
        default:
            return nil
        }
    }

    /// A destination point (PDF user space, either coordinate optional) in page space.
    private static func point(_ page: PObj, _ left: Double?, _ top: Double?) -> (Double?, Double?) {
        if left == nil && top == nil { return (nil, nil) }
        let b = PageBoxes.visibleBox(page)
        let p = PageBoxes.toPage(page, left ?? b.x1, top ?? b.y2)
        let rot = PageBoxes.rotate(page)
        // On a page shown sideways the PDF's "top" becomes a horizontal position; report what's meaningful for scrolling.
        return rot == 90 || rot == 270 ? (top == nil ? nil : p.x, left == nil ? nil : p.y) : (left == nil ? nil : p.x, top == nil ? nil : p.y)
    }
}
