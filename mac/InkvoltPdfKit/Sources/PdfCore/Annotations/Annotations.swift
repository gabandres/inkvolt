import Foundation

public enum AnnotationKind: String, Sendable {
    case text = "Text", freeText = "FreeText", highlight = "Highlight", underline = "Underline", strikeOut = "StrikeOut"
    case squiggly = "Squiggly", line = "Line", square = "Square", circle = "Circle", polygon = "Polygon", polyLine = "PolyLine"
    case ink = "Ink", stamp = "Stamp", caret = "Caret", fileAttachment = "FileAttachment", sound = "Sound", redact = "Redact"
    case other = "Other"
}

public enum TextMarkupKind: String, Sendable { case highlight = "Highlight", underline = "Underline", strikeOut = "StrikeOut", squiggly = "Squiggly" }

/// A markup annotation (a comment) on a page. Rects are in page space.
public struct AnnotationInfo: Equatable, Sendable {
    /// A stable id: the annotation's /NM, else "p<page>:<index>" (valid for the bytes it was read from).
    public var id: String
    public var kind: AnnotationKind
    /// The PDF subtype without its slash ("Highlight", "Text", ...).
    public var subtype: String
    public var pageIndex: Int
    public var rect: RectD
    public var contents: String
    public var author: String?
    public var modified: Date?
    public var subject: String?
    public var color: AnnotColor?
    /// Text markup: the marked line boxes (from /QuadPoints); empty for other kinds.
    public var quadRects: [RectD]
    /// A Fill & Sign stamp (managed by `TextStamps`).
    public var isInkvoltPdfStamp: Bool
    /// The id of the annotation this one replies to (/IRT).
    public var replyTo: String?
    /// The Hidden or NoView flag is set: viewers don't draw it.
    public var hidden: Bool
    public var opacity = 1.0
    /// Drawing annotations (ink, shapes, lines, polygons, FreeText other than Fill & Sign stamps): where they are, for
    /// selecting, moving and resizing (`Annotations.updateGeometry`); nil for other kinds.
    public var geometry: AnnotGeometry?
    /// Drawing annotations: how they look (`Annotations.updateStyle`); nil for other kinds.
    public var style: AnnotStyle?
}

/// Reads and edits comments (markup annotations): highlights, underlines, strike-outs, squiggles and sticky notes, and the
/// drawing annotations (`Annotations+Drawing`). Widgets, links and popups are not listed. Every call takes the document
/// bytes and returns new bytes; new annotations get their own appearance stream, so every viewer draws them the same.
/// Refusals are `PdfEditError`s (.NET's ArgumentException, ArgumentOutOfRangeException and InvalidOperationException).
public enum Annotations {
    static let idPrefix = "inkvoltpdf-annot-"
    /// The id prefix of annotations made before the Inkvolt rename; still recognized.
    private static let legacyIdPrefix = "pdfdesk-annot-"
    static let flagHidden = 2, flagPrint = 4, flagNoView = 32

    /// True for an /NM this app gives the annotations it creates (`newId`), old or new.
    static func isOwnId(_ nm: String?) -> Bool {
        guard let nm else { return false }
        return nm.hasPrefix(idPrefix) || nm.hasPrefix(legacyIdPrefix)
    }

    /// A fresh annotation id (pass it to an add call to know the id of what you created).
    public static func newId() -> String { idPrefix + NewIds.hex() }

    public static func read(_ data: [UInt8], _ password: String?) throws -> [AnnotationInfo] {
        let doc: MuDoc
        do {
            doc = try PdfEdit.openToRead(data, password)
        } catch let e as PdfEditError {
            throw PdfEditError(e.message.replacingOccurrences(of: "This PDF can't be read", with: "This PDF's comments can't be read"))
        }
        var list: [AnnotationInfo] = []
        for p in 0..<(try doc.pageCount()) {
            let page = doc.page(p)
            guard let annots = page.array("Annots") else { continue }
            for (i, a) in annots.elements.enumerated() where a.isDict {
                let subtype = a.name("Subtype") ?? ""
                if subtype == "Widget" || subtype == "Link" || subtype == "Popup" || subtype.isEmpty { continue }
                let rect = PageBoxes.rectToPage(page, a.array("Rect"))
                let flags = a.int("F") ?? 0
                var quads: [RectD] = []
                if let qp = a.array("QuadPoints") {
                    var k = 0
                    while k + 7 < qp.count {
                        let xs = [qp.num(k), qp.num(k + 2), qp.num(k + 4), qp.num(k + 6)]
                        let ys = [qp.num(k + 1), qp.num(k + 3), qp.num(k + 5), qp.num(k + 7)]
                        quads.append(PageBoxes.toPageSpace(page, xs.min()!, ys.min()!, xs.max()!, ys.max()!))
                        k += 8
                    }
                }
                let nm = a.text("NM")
                let drawing = isDrawing(a, subtype) ? describe(page, a, subtype) : nil
                list.append(AnnotationInfo(
                    id: idOf(doc, a, p, i), kind: kindOf(subtype), subtype: subtype, pageIndex: p, rect: rect,
                    contents: a.text("Contents") ?? "", author: a.text("T"), modified: PdfDates.parse(a.text("M")),
                    subject: a.text("Subj"), color: colorOf(a.array("C")), quadRects: quads,
                    isInkvoltPdfStamp: subtype == "FreeText" && TextStamps.isOwnId(nm),
                    replyTo: a.dict("IRT").map { idOf(doc, $0, p, -1) },
                    hidden: flags & (flagHidden | flagNoView) != 0, opacity: a.number("CA") ?? 1,
                    geometry: drawing?.geometry, style: drawing?.style))
            }
        }
        return list
    }

    /// Adds a highlight, underline, strike-out or squiggly over the given text line boxes (page space, one per line, as
    /// `PageText.rects` gives them). `note` becomes the comment's text.
    public static func addTextMarkup(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ kind: TextMarkupKind, _ lineRects: [RectD],
                                     _ color: AnnotColor, note: String?, author: String, id: String? = nil) throws -> [UInt8] {
        if lineRects.allSatisfy(\.isEmpty) { throw PdfEditError("No text to mark.") }
        return try PageEditor.edit(data, password) { doc in
            try checkPage(doc, pageIndex)
            addTextMarkupIn(doc, pageIndex, kind, lineRects, color, note: note, author: author, id: id)
        }
    }

    /// `addTextMarkup` on a document already open for editing (several marks, one save).
    static func addTextMarkupIn(_ doc: MuDoc, _ pageIndex: Int, _ kind: TextMarkupKind, _ lineRects: [RectD], _ color: AnnotColor,
                                note: String?, author: String, id: String? = nil) {
        let page = doc.page(pageIndex)
        typealias P = (x: Double, y: Double)
        // Quad corners in PDF space, in the reading orientation of the displayed page: upper-left, upper-right,
        // lower-left, lower-right.
        var quads: [(ul: P, ur: P, ll: P, lr: P)] = []
        for r in lineRects where !r.isEmpty {
            quads.append((PageBoxes.toPdf(page, r.x, r.y), PageBoxes.toPdf(page, r.right, r.y),
                          PageBoxes.toPdf(page, r.x, r.bottom), PageBoxes.toPdf(page, r.right, r.bottom)))
        }
        let allX = quads.flatMap { [$0.ul.x, $0.ur.x, $0.ll.x, $0.lr.x] }
        let allY = quads.flatMap { [$0.ul.y, $0.ur.y, $0.ll.y, $0.lr.y] }
        let pad: Double = kind == .squiggly ? 2 : 1
        let x1 = allX.min()! - pad, y1 = allY.min()! - pad, x2 = allX.max()! + pad, y2 = allY.max()! + pad

        let c = "\(PdfNum.f(color.r)) \(PdfNum.f(color.g)) \(PdfNum.f(color.b))"
        func pt(_ p: P) -> String { "\(PdfNum.f(p.x)) \(PdfNum.f(p.y))" }
        var ops = ""
        for q in quads {
            // Unit vectors along the line (d) and up from the baseline (u); h = the line's height.
            let dx = q.lr.x - q.ll.x, dy = q.lr.y - q.ll.y, ux = q.ul.x - q.ll.x, uy = q.ul.y - q.ll.y
            let h = (ux * ux + uy * uy).squareRoot()
            let len = (dx * dx + dy * dy).squareRoot()
            let lenSafe = max(len, 1e-6), hSafe = max(h, 1e-6)
            func at(_ along: Double, _ up: Double) -> P {
                let x: Double = q.ll.x + dx * along / lenSafe + ux * up / hSafe
                let y: Double = q.ll.y + dy * along / lenSafe + uy * up / hSafe
                return (x, y)
            }
            switch kind {
            case .highlight:
                ops += "\(c) rg \(pt(q.ul)) m \(pt(q.ur)) l \(pt(q.lr)) l \(pt(q.ll)) l h f\n"
            case .underline, .strikeOut:
                let level = kind == .underline ? h * 0.12 : h * 0.45
                ops += "\(c) RG \(PdfNum.f(max(0.5, h / 14))) w \(pt(at(0, level))) m \(pt(at(len, level))) l S\n"
            case .squiggly:
                let step = max(1.5, h / 6)
                let amp = max(1, h / 12)
                ops += "\(c) RG \(PdfNum.f(max(0.5, h / 18))) w 1 j \(pt(at(0, 0))) m"
                var up = true
                var t = step
                while t < len + step {
                    ops += " \(pt(at(min(t, len), up ? amp : 0))) l"
                    t += step
                    up.toggle()
                }
                ops += " S\n"
            }
        }

        var resources = doc.dict()
        if kind == .highlight {
            let gs = doc.dict([("Type", doc.name("ExtGState")), ("BM", doc.name("Multiply"))])
            resources = doc.dict([("ExtGState", doc.dict([("GS0", gs)]))])
            ops = "/GS0 gs\n" + ops
        }
        let ap = doc.formXObject(Array(ops.utf8), x1, y1, x2, y2, resources)
        let annot = newAnnot(doc, page, kind.rawValue, x1, y1, x2, y2, id, note ?? "", author, color)
        var qp: [Double] = []
        for q in quads { qp += [q.ul.x, q.ul.y, q.ur.x, q.ur.y, q.ll.x, q.ll.y, q.lr.x, q.lr.y] }
        annot.set("QuadPoints", doc.realArray(qp))
        setAppearance(doc, annot, ap)
    }

    /// Adds a sticky note: a /Text annotation drawn as a 20 pt note icon whose top-left is at (x, y), page space.
    public static func addNote(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ x: Double, _ y: Double, _ text: String,
                               author: String, color: AnnotColor? = nil, id: String? = nil) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            try checkPage(doc, pageIndex)
            addNoteIn(doc, pageIndex, x, y, text, author: author, color: color, id: id)
        }
    }

    /// `addNote` on a document already open for editing.
    static func addNoteIn(_ doc: MuDoc, _ pageIndex: Int, _ x: Double, _ y: Double, _ text: String, author: String,
                          color: AnnotColor? = nil, id: String? = nil) {
        let page = doc.page(pageIndex)
        let size = 20.0
        let r = PageBoxes.fromPageSpace(page, RectD(x, y, size, size))
        let col = color ?? .yellow
        let c = "\(PdfNum.f(col.r)) \(PdfNum.f(col.g)) \(PdfNum.f(col.b))"
        // A speech bubble with three text lines, drawn upright on rotated pages.
        let ops = "q 0.35 G 0.8 w \(c) rg 1.5 6 m 1.5 18.5 l 18.5 18.5 l 18.5 6 l 9 6 l 5 1.5 l 6 6 l h B\n"
            + "0.3 G 1 w 5 15 m 15 15 l 5 12 m 15 12 l 5 9 m 12 9 l S Q\n"
        let ap = doc.formXObject(Array(ops.utf8), 0, 0, size, size, doc.dict(), matrix: doc.counterRotation(page))
        let annot = newAnnot(doc, page, "Text", r.x1, r.y1, r.x2, r.y2, id, text, author, col)
        annot.set("Name", doc.name("Comment"))
        annot.set("Open", doc.bool(false))
        setAppearance(doc, annot, ap)
    }

    /// Changes a comment's text. A FreeText box (other than a Fill & Sign stamp) shows the new text: its appearance is
    /// rebuilt.
    public static func setContents(_ data: [UInt8], _ password: String?, _ id: String, _ text: String) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            guard let found = try find(doc, id) else { throw PdfEditError("That comment no longer exists.") }
            let p = found.page, annot = found.annot
            annot.set("Contents", doc.text(text))
            annot.set("M", doc.now())
            if annot.name("Subtype") == "FreeText" && isDrawing(annot, "FreeText"), let ft = describe(doc.page(p), annot, "FreeText") {
                apply(doc, doc.page(p), annot, "FreeText", ft.geometry, ft.style)
            }
        }
    }

    /// Deletes an annotation with its popup and its replies (and theirs).
    public static func delete(_ data: [UInt8], _ password: String?, _ id: String) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            if !(try deleteIn(doc, id)) { throw PdfEditError("That comment no longer exists.") }
        }
    }

    static func deleteIn(_ doc: MuDoc, _ id: String) throws -> Bool {
        guard let found = try find(doc, id) else { return false }
        SignedEdits.noteRemoval()
        let count = try doc.pageCount()
        var all: [PObj] = []
        for p in 0..<count { all += (doc.page(p).array("Annots")?.elements ?? []).filter(\.isDict) }

        var doomed: Set<UInt> = [found.annot.identity]
        var grew = true
        while grew {
            grew = false
            for a in all where !doomed.contains(a.identity) {
                let irt = a.dict("IRT"), parent = a.dict("Parent")
                let replies = irt.map { doomed.contains($0.identity) } ?? false
                let popup = (parent.map { doomed.contains($0.identity) } ?? false) && a.name("Subtype") == "Popup"
                if replies || popup { grew = doomed.insert(a.identity).inserted || grew }
            }
            for a in all where doomed.contains(a.identity) {
                if let popup = a.dict("Popup") { grew = doomed.insert(popup.identity).inserted || grew }
            }
        }

        for p in 0..<count {
            let page = doc.page(p)
            guard page.array("Annots") != nil else { continue }
            let annots = doc.annots(page)
            for i in stride(from: annots.count - 1, through: 0, by: -1) {
                if let a = annots[i], a.isDict, doomed.contains(a.identity) { annots.remove(at: i) }
            }
        }
        return true
    }

    static func find(_ doc: MuDoc, _ id: String) throws -> (page: Int, annot: PObj)? {
        for p in 0..<(try doc.pageCount()) {
            guard let annots = doc.page(p).array("Annots") else { continue }
            for (i, a) in annots.elements.enumerated() where a.isDict && idOf(doc, a, p, i) == id { return (p, a) }
        }
        return nil
    }

    /// The annotation's /NM, else its position ("p<page>:<index in /Annots>"; `index` -1 looks it up, page `page` first).
    static func idOf(_ doc: MuDoc, _ a: PObj, _ page: Int, _ index: Int) -> String {
        if let nm = a.text("NM"), !nm.isEmpty { return nm }
        if index < 0, let count = try? doc.pageCount() {
            let target = a.identity
            for p in [page] + Array(0..<count) where p >= 0 && p < count {
                guard let annots = doc.page(p).array("Annots") else { continue }
                for (i, e) in annots.elements.enumerated() where e.identity == target { return "p\(p):\(i)" }
            }
        }
        return "p\(page):\(index)"
    }

    static func checkPage(_ doc: MuDoc, _ pageIndex: Int) throws {
        let count = try doc.pageCount()
        if pageIndex < 0 || pageIndex >= count { throw PdfEditError("There is no page \(pageIndex + 1).") }
    }

    @discardableResult
    static func newAnnot(_ doc: MuDoc, _ page: PObj, _ subtype: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                         _ id: String?, _ contents: String, _ author: String, _ color: AnnotColor) -> PObj {
        let annot = doc.add(doc.dict([
            ("Type", doc.name("Annot")), ("Subtype", doc.name(subtype)), ("Rect", doc.realArray([x1, y1, x2, y2])),
            ("NM", doc.text(id ?? newId())), ("F", doc.int(flagPrint)), ("C", doc.realArray([color.r, color.g, color.b])),
            ("Contents", doc.text(contents)), ("T", doc.text(author)), ("M", doc.now()), ("CreationDate", doc.now()), ("P", page),
        ]))
        doc.annots(page).append(annot)
        return annot
    }

    static func setAppearance(_ doc: MuDoc, _ annot: PObj, _ form: PObj) {
        annot.set("AP", doc.dict([("N", form)]))
    }

    private static func kindOf(_ subtype: String) -> AnnotationKind {
        guard let k = AnnotationKind(rawValue: subtype), k != .other else { return .other }
        return k
    }

    /// A color array as RGB. MuPDF keeps reals as 32-bit floats, so components are read back rounded to the four
    /// decimals they are written with (0.1 stays 0.1).
    static func colorOf(_ c: PObj?) -> AnnotColor? {
        guard let c, c.isArray else { return nil }
        func v(_ i: Int) -> Double { (c.num(i) * 10000).rounded() / 10000 }
        switch c.count {
        case 1: return AnnotColor(v(0), v(0), v(0))
        case 3: return AnnotColor(v(0), v(1), v(2))
        case 4:
            let k = 1 - v(3)
            return AnnotColor((1 - v(0)) * k, (1 - v(1)) * k, (1 - v(2)) * k)
        default: return nil
        }
    }
}
