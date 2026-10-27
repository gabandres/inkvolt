import Foundation

/// The object helpers comments, stamps and links share (the Windows app's `PdfObj` helpers for PDFsharp).
extension MuDoc {
    /// Numbers as an array of reals rounded to four decimals (.NET's `PdfObj.Reals`).
    func realArray(_ values: [Double]) -> PObj { array(values.map { real(($0 * 10000).rounded() / 10000) }) }

    /// A form XObject (its reference) drawing `content` in the box (x1, y1, x2, y2); deflated when longer than 64 bytes.
    func formXObject(_ content: [UInt8], _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ resources: PObj?,
                     matrix: PObj? = nil, deflate: Bool = true) -> PObj {
        var entries: [(String, PObj)] = [("Type", name("XObject")), ("Subtype", name("Form")), ("BBox", realArray([x1, y1, x2, y2]))]
        if let matrix { entries.append(("Matrix", matrix)) }
        entries.append(("Resources", resources ?? dict()))
        return addStream(content, dict: dict(entries), deflate: deflate && content.count > 64)
    }

    /// The /Matrix that keeps an appearance upright in the viewer on a page with /Rotate; nil on an upright page.
    func counterRotation(_ page: PObj) -> PObj? {
        let m: [Int]
        switch PageBoxes.rotate(page) {
        case 90: m = [0, 1, -1, 0, 0, 0]
        case 180: m = [-1, 0, 0, -1, 0, 0]
        case 270: m = [0, -1, 1, 0, 0, 0]
        default: return nil
        }
        return array(m.map { int($0) })
    }

    /// The page's /Annots array, made when missing; an indirect one (which pages may share) is replaced by a copy of
    /// its own first.
    func annots(_ page: PObj) -> PObj {
        if let a = page["Annots"], a.isArray {
            if !a.isRef { return a }
            let copy = array(a.elements)
            page.set("Annots", copy)
            return copy
        }
        let made = array()
        page.set("Annots", made)
        return made
    }

    /// The current time as a PDF date string.
    func now() -> PObj { text(PdfDates.format(Date())) }
}

extension PageBoxes {
    /// A page-space rectangle in PDF user space: (x1, y1, x2, y2) with x1 ≤ x2, y1 ≤ y2 (.NET's `TextStamps.FromPageSpace`).
    static func fromPageSpace(_ page: PObj, _ r: RectD) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let a = toPdf(page, r.x, r.y), b = toPdf(page, r.right, r.bottom)
        return (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
    }

    /// A rectangle in PDF user space as a page-space rectangle (.NET's `FormEditor.ToPageSpace`).
    static func toPageSpace(_ page: PObj, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> RectD {
        let a = toPage(page, x1, y1), b = toPage(page, x2, y2)
        return .fromEdges(a.x, a.y, b.x, b.y)
    }

    /// A /Rect array in page space (empty when it isn't a rectangle; .NET's `PdfObj.RectToPage`).
    static func rectToPage(_ page: PObj, _ r: PObj?) -> RectD {
        guard let r, r.isArray, r.count >= 4 else { return .zero }
        return toPageSpace(page, r.num(0), r.num(1), r.num(2), r.num(3))
    }
}

/// New ids for what an edit creates (.NET's `Guid.NewGuid():N`).
enum NewIds {
    static func hex() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}
