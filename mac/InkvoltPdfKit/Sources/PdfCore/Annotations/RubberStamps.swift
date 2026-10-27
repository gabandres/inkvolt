import Foundation

/// How a stamp looks: `title` in bold capitals in a rounded frame, an optional `detail` line under it (who and when), all
/// in `color`. `name` is the PDF stamp name (/Name: Approved, NotApproved, Draft, …), which other viewers may know;
/// `label` is what it is called in lists and the Comments pane ("Approved", "Rejected", …).
public struct StampDesign: Equatable, Sendable {
    public var name: String
    public var label: String
    public var title: String
    public var detail: String?
    public var color: AnnotColor

    public init(_ name: String, _ label: String, _ title: String, _ detail: String?, _ color: AnnotColor) {
        self.name = name
        self.label = label
        self.title = title
        self.detail = detail
        self.color = color
    }

    public static let green = AnnotColor(0.12, 0.5, 0.2)
    public static let red = AnnotColor(0.8, 0.12, 0.12)
    public static let blue = AnnotColor(0.12, 0.3, 0.75)
}

/// Stamps (Review › Stamp; the Windows app's `RubberStamps`): built-in ones (Approved, Rejected, Draft, Final,
/// Confidential, For Comment, Received, and "Approved by <user> on <date>") drawn as vector appearances, and custom stamps
/// from an image. Each is a standard Stamp annotation with its own appearance stream, so every viewer shows and prints it
/// the same; it lists in the Comments pane, and Inkvolt PDF moves, resizes and deletes it like a placed signature (read
/// back by `SignatureStamps.read` as `.stamp`). A vector stamp keeps its design in a private entry (/InkvoltPdfStamp), so
/// a resize redraws it sharp.
public enum RubberStamps {
    static let idPrefix = "InkvoltPdf-stamp-"
    private static let designKey = "InkvoltPdfStamp"
    /// The title's size in the stamp's own layout (points); the stamp scales to its rectangle.
    private static let titleSize = 24.0

    public static let builtIn: [StampDesign] = [
        StampDesign("Approved", "Approved", "APPROVED", nil, StampDesign.green),
        StampDesign("NotApproved", "Rejected", "REJECTED", nil, StampDesign.red),
        StampDesign("Draft", "Draft", "DRAFT", nil, StampDesign.blue),
        StampDesign("Final", "Final", "FINAL", nil, StampDesign.green),
        StampDesign("Confidential", "Confidential", "CONFIDENTIAL", nil, StampDesign.red),
        StampDesign("ForComment", "For Comment", "FOR COMMENT", nil, StampDesign.blue),
        StampDesign("Received", "Received", "RECEIVED", nil, StampDesign.blue),
    ]

    /// "APPROVED / By <user> on <date>", the date and time written the way `locale` writes them (short date and time).
    public static func approvedBy(_ user: String, _ when: Date, locale: Locale = .current) -> StampDesign {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .short
        f.timeStyle = .short
        return StampDesign("Approved", "Approved", "APPROVED", "By \(user) on \(f.string(from: when))", StampDesign.green)
    }

    /// The stamp's natural size in points (its layout at a 24 pt title); placing it at another size scales it.
    public static func naturalSize(_ design: StampDesign) -> (width: Double, height: Double) { layout(design).size }

    private struct StampLayout {
        var size: (width: Double, height: Double)
        var pad: Double
        var line: Double
        var detailSize: Double
        var title: TextPainter
        var detail: TextPainter?
    }

    private static func layout(_ d: StampDesign) -> StampLayout {
        let title = TextPainter(StdFont(.helvetica, true, false), [d.title])
        let detailText = d.detail ?? ""
        let detail = detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TextPainter(.helvetica, [detailText])
        let detailSize = titleSize * 0.42
        let pad = titleSize * 0.55
        let line = titleSize * 0.11
        let detailWidth = detail.map { $0.measure(detailText) * detailSize } ?? 0
        let width = max(title.measure(d.title) * titleSize, detailWidth) + 2 * pad
        let detailBand = detail == nil ? 0 : detailSize * 1.35
        let height = (title.ascent - title.descent) * titleSize + detailBand + pad * 0.9
        return StampLayout(size: (width, height), pad: pad, line: line, detailSize: detailSize, title: title, detail: detail)
    }

    /// The appearance's drawing for a stamp in a `width` × `height` box (the natural layout scaled to fit) and the
    /// resources it uses (fonts).
    static func appearance(_ doc: MuDoc, _ d: StampDesign, _ width: Double, _ height: Double) -> (ops: [UInt8], resources: PObj) {
        let l = layout(d)
        let (nw, nh) = l.size
        let color = PdfColorValue(c: [d.color.r, d.color.g, d.color.b])
        var ops = "q \(PdfNum.f(width / nw)) 0 0 \(PdfNum.f(height / nh)) 0 0 cm\n"
        // The frame: a rounded rectangle inside the box, its line fully inside.
        let half = l.line / 2
        ops += "\(color.stroke) \(PdfNum.f(l.line)) w "
        ops += roundedRect(half, half, nw - l.line, nh - l.line, min(nh * 0.22, titleSize * 0.4)) + " S\n"

        let titleWidth = l.title.measure(d.title) * titleSize
        let detailBand = l.detail == nil ? 0 : l.detailSize * 1.35
        // The title centered in what's above the detail line.
        let em = (l.title.ascent - l.title.descent) * titleSize
        let titleBase = detailBand + (nh - detailBand - em) / 2 - l.title.descent * titleSize
        l.title.draw(d.title, (nw - titleWidth) / 2, titleBase, titleSize)
        let (titleOps, resources) = l.title.build(doc, nw, nh, "/HeBo", color)
        var out = Array(ops.utf8) + titleOps
        if let detail = l.detail, let text = d.detail {
            let dw = detail.measure(text) * l.detailSize
            detail.draw(text, (nw - dw) / 2, l.pad * 0.45 + detailBand * 0.15, l.detailSize)
            let (detailOps, detailRes) = detail.build(doc, nw, nh, "/Helv", color)
            out += detailOps
            // Both painters' fonts in one resource dictionary (their names differ: /HeBo and /Helv, or the embedded ones').
            if let more = detailRes.dict("Font"), let fonts = resources.dict("Font") {
                for key in more.keys where !fonts.has(key) { if let v = more[key] { fonts.set(key, v) } }
            }
        }
        out += Array("Q\n".utf8)
        return (out, resources)
    }

    private static func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> String {
        let k = 0.5523
        func p(_ px: Double, _ py: Double) -> String { "\(PdfNum.f(px)) \(PdfNum.f(py))" }
        let x2 = x + w, y2 = y + h, rk = r * k
        var s = "\(p(x + r, y)) m \(p(x2 - r, y)) l \(p(x2 - r + rk, y)) \(p(x2, y + r - rk)) \(p(x2, y + r)) c "
        s += "\(p(x2, y2 - r)) l \(p(x2, y2 - r + rk)) \(p(x2 - r + rk, y2)) \(p(x2 - r, y2)) c "
        s += "\(p(x + r, y2)) l \(p(x + r - rk, y2)) \(p(x, y2 - r + rk)) \(p(x, y2 - r)) c "
        s += "\(p(x, y + r)) l \(p(x, y + r - rk)) \(p(x + r - rk, y)) \(p(x + r, y)) c h"
        return s
    }

    /// Places a stamp of `design` in `rect` (page space), or with `replaceId` moves or resizes an existing one (redrawn at
    /// its new size; its own design and author kept).
    public static func put(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ design: StampDesign, author: String?,
                           replaceId: String? = nil) throws -> [UInt8] {
        if rect.isEmpty { throw PdfEditError("The stamp needs a size.") }
        return try PageEditor.edit(data, password) { doc in
            try Annotations.checkPage(doc, pageIndex)
            var design = design
            var old: (page: Int, annot: PObj)?
            if let replaceId {
                guard let found = try Annotations.find(doc, replaceId) else { throw PdfEditError("The stamp is no longer in the document.") }
                old = found
                design = designOf(found.annot) ?? design
            }
            let page = doc.page(pageIndex)
            let r = PageBoxes.fromPageSpace(page, rect)
            let (ops, resources) = appearance(doc, design, rect.width, rect.height)
            let ap = doc.formXObject(ops, 0, 0, rect.width, rect.height, resources, matrix: doc.counterRotation(page))
            if let old {
                // Redrawn at its new size in place: the same annotation, everything else about it kept.
                try SignatureStamps.moveAnnotation(doc, old.annot, old.page, pageIndex, r, ap)
                return
            }
            var stored: [(String, PObj)] = [("Title", doc.text(design.title))]
            if let detail = design.detail { stored.append(("Detail", doc.text(detail))) }
            stored.append(("Label", doc.text(design.label)))
            var entries: [(String, PObj)] = [
                ("Type", doc.name("Annot")), ("Subtype", doc.name("Stamp")), ("Name", doc.name(pdfName(design.name))),
                ("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2])),
                ("Contents", doc.text(design.detail.map { "\(design.title)\n\($0)" } ?? design.title)),
                ("Subj", doc.text(design.label)), ("NM", doc.text(idPrefix + NewIds.hex())),
                ("C", doc.realArray([design.color.r, design.color.g, design.color.b])), ("F", doc.int(4)),
            ]
            if let author { entries.append(("T", doc.text(author))) }
            entries += [("M", doc.now()), ("CreationDate", doc.now()), (designKey, doc.dict(stored)), ("AP", doc.dict([("N", ap)])), ("P", page)]
            doc.annots(page).append(doc.add(doc.dict(entries)))
        }
    }

    /// Places a custom stamp made from an image (moved later with `move`).
    public static func putImage(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ image: StampImage, label: String,
                                author: String?) throws -> [UInt8] {
        try SignatureStamps.place(data, password, pageIndex, rect, image, nil, label, idPrefix, pdfName(label), author, subject: label)
    }

    /// Moves or resizes a stamp: a vector one is redrawn at its new size, an image one keeps its picture.
    public static func move(_ data: [UInt8], _ password: String?, _ id: String, _ pageIndex: Int, _ rect: RectD) throws -> [UInt8] {
        let doc = try PdfEdit.openToRead(data, password)
        guard let found = try Annotations.find(doc, id) else { throw PdfEditError("The stamp is no longer in the document.") }
        if let design = designOf(found.annot) { return try put(data, password, pageIndex, rect, design, author: nil, replaceId: id) }
        return try SignatureStamps.put(data, password, pageIndex, rect, nil, replaceId: id)
    }

    /// The design a vector stamp was made with (nil for an image stamp or another app's).
    static func designOf(_ annot: PObj) -> StampDesign? {
        guard let d = annot.dict(designKey), let title = d.text("Title") else { return nil }
        let c = annot.array("C")
        let color = c.flatMap { $0.count == 3 ? Annotations.colorOf($0) : nil } ?? StampDesign.blue
        return StampDesign(annot.name("Name") ?? "Stamp", d.text("Label") ?? title, title, d.text("Detail"), color)
    }

    /// A stamp name usable as a PDF name: ASCII letters and digits only.
    private static func pdfName(_ name: String) -> String {
        let clean = String(name.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) }.map(Character.init))
        return clean.isEmpty ? "Stamp" : clean
    }
}
