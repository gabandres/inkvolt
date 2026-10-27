import Foundation

/// Decoded image pixels: 8-bit RGB (row-major, no padding) and optional 8-bit alpha (transparency).
public struct StampImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgb: [UInt8]
    public var alpha: [UInt8]?

    public init(_ width: Int, _ height: Int, _ rgb: [UInt8], _ alpha: [UInt8]?) {
        self.width = width
        self.height = height
        self.rgb = rgb
        self.alpha = alpha
    }

    func validate() throws {
        if width <= 0 || height <= 0 || width > 8192 || height > 8192 { throw PdfEditError("The image size isn't usable.") }
        if rgb.count != width * height * 3 || (alpha.map { $0.count != width * height } ?? false) {
            throw PdfEditError("The image data doesn't match its size.")
        }
    }
}

/// Fill & Sign's handwritten signatures and initials, and pictures placed with the Image tool (the Windows app's
/// `SignatureStamps`): an image placed on a page as a standard Stamp annotation with an image appearance (transparency
/// kept with a soft mask), so every viewer shows it. Not a digital signature. Read back as `TextStamp`s of kind
/// `.signature` or `.image` (and `.stamp` for `RubberStamps`); moved and resized with `put`, removed with
/// `TextStamps.remove`.
public enum SignatureStamps {
    private static let idPrefix = "InkvoltPdf-signature-"
    /// The id prefix of pictures placed with the Image tool.
    private static let imagePrefix = "InkvoltPdf-image-"
    /// The id prefix of signature stamps made before the Inkvolt rename; still recognized.
    private static let legacyIdPrefix = "PdfDesk-signature-"

    public static func read(_ data: [UInt8], _ password: String?) throws -> [TextStamp] {
        let doc = try PdfEdit.openToRead(data, password)
        var list: [TextStamp] = []
        for p in 0..<(try doc.pageCount()) {
            let page = doc.page(p)
            for a in page.array("Annots")?.elements ?? [] where a.isDict && a.name("Subtype") == "Stamp" {
                guard let nm = a.text("NM"), let kind = kindOf(nm), let r = a.array("Rect"), r.count >= 4 else { continue }
                list.append(TextStamp(id: nm, pageIndex: p, rect: PageBoxes.rectToPage(page, r), kind: kind, text: a.text("Contents") ?? "", fontSize: 0))
            }
        }
        return list
    }

    /// The kind of stamp an /NM this app gives belongs to; nil for any other.
    static func kindOf(_ nm: String) -> StampKind? {
        if nm.hasPrefix(idPrefix) || nm.hasPrefix(legacyIdPrefix) { return .signature }
        if nm.hasPrefix(imagePrefix) { return .image }
        if nm.hasPrefix(RubberStamps.idPrefix) { return .stamp }
        return nil
    }

    /// Places `image` in `rect` (page space). With `replaceId` the existing stamp (a signature or a picture) is moved or
    /// resized instead (its image kept when `image` is nil).
    public static func put(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ image: StampImage?,
                           replaceId: String? = nil, label: String = "Signature") throws -> [UInt8] {
        try place(data, password, pageIndex, rect, image, replaceId, label, idPrefix, "InkvoltPdfSignature", nil)
    }

    /// Places a picture (the Image tool) in `rect` (page space); `put` moves it later.
    public static func putImage(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ image: StampImage, label: String,
                                author: String? = nil) throws -> [UInt8] {
        try place(data, password, pageIndex, rect, image, nil, label, imagePrefix, "InkvoltPdfImage", author, subject: "Image")
    }

    /// Places an image stamp. `idPrefix`, `name` (/Name), `author` (/T) and `subject` (/Subj) are for a new stamp; a
    /// replaced one keeps its own, and its creation date.
    static func place(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ image: StampImage?, _ replaceId: String?,
                      _ label: String, _ idPrefix: String, _ name: String, _ author: String?, subject: String? = nil) throws -> [UInt8] {
        if rect.isEmpty { throw PdfEditError("The stamp needs a size.") }
        if let image { try image.validate() }
        return try PageEditor.edit(data, password) { doc in
            try Annotations.checkPage(doc, pageIndex)
            var imageRef: PObj?
            var old: (page: Int, annot: PObj)?
            if let replaceId {
                guard let found = try find(doc, replaceId) else { throw PdfEditError("The stamp is no longer in the document.") }
                old = found
                if image == nil { imageRef = found.annot.dict("AP")?.dict("N")?.dict("Resources")?.dict("XObject")?["Im1"] }
            }
            if let image { imageRef = imageXObject(doc, image) }
            guard let imageRef else { throw PdfEditError("The stamp's image is missing.") }

            let page = doc.page(pageIndex)
            let r = PageBoxes.fromPageSpace(page, rect)
            let res = doc.dict([("XObject", doc.dict([("Im1", imageRef)]))])
            let content = Array("q \(PdfNum.f(rect.width)) 0 0 \(PdfNum.f(rect.height)) 0 0 cm /Im1 Do Q".utf8)
            let ap = doc.formXObject(content, 0, 0, rect.width, rect.height, res, matrix: doc.counterRotation(page))

            if let old {
                // Moved or resized in place: the same annotation (replies, its popup, structure, layer, opacity and its
                // place among the page's annotations stay), with a new rectangle and appearance.
                try moveAnnotation(doc, old.annot, old.page, pageIndex, r, ap)
                return
            }
            var entries: [(String, PObj)] = [
                ("Type", doc.name("Annot")), ("Subtype", doc.name("Stamp")), ("Name", doc.name(name)),
                ("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2])), ("Contents", doc.text(label)),
                ("NM", doc.text(idPrefix + NewIds.hex())),
            ]
            if let author { entries.append(("T", doc.text(author))) }
            if let subject { entries.append(("Subj", doc.text(subject))) }
            entries += [("F", doc.int(4)), ("M", doc.now()), ("AP", doc.dict([("N", ap)])), ("P", page)]
            doc.annots(page).append(doc.add(doc.dict(entries)))
        }
    }

    /// Gives a placed annotation a new rectangle (PDF coordinates) and normal appearance, and the time of the change. On
    /// another page it moves into that page's annotations (its popup with it), at the end, as one placed there would be.
    static func moveAnnotation(_ doc: MuDoc, _ annot: PObj, _ fromPage: Int, _ toPage: Int,
                               _ r: (x1: Double, y1: Double, x2: Double, y2: Double), _ ap: PObj) throws {
        annot.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
        let appearance = annot.dict("AP") ?? doc.dict()
        appearance.set("N", ap)
        // /D (down) and /R (rollover) would show the old size; /AS names a state of the old /N.
        appearance.remove("D")
        appearance.remove("R")
        annot.set("AP", appearance)
        annot.remove("AS")
        annot.set("M", doc.now())
        if fromPage == toPage { return }

        let from = doc.annots(doc.page(fromPage))
        let to = doc.annots(doc.page(toPage))
        var moving = [annot]
        if let popup = annot.dict("Popup") { moving.append(popup) }
        for a in moving {
            var keep: PObj?
            for i in stride(from: from.count - 1, through: 0, by: -1) {
                if let e = from[i], e.identity == a.identity {
                    keep = keep ?? e
                    from.remove(at: i)
                }
            }
            to.append(keep ?? a)
            a.set("P", doc.page(toPage))
        }
    }

    private static func find(_ doc: MuDoc, _ id: String) throws -> (page: Int, annot: PObj)? {
        for p in 0..<(try doc.pageCount()) {
            for a in doc.page(p).array("Annots")?.elements ?? [] where a.isDict && a.text("NM") == id { return (p, a) }
        }
        return nil
    }

    /// An image XObject (its reference): Flate RGB, the alpha as a soft mask.
    static func imageXObject(_ doc: MuDoc, _ img: StampImage) -> PObj {
        func image(_ samples: [UInt8], _ colorSpace: String) -> PObj {
            let d = doc.dict([("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(img.width)),
                              ("Height", doc.int(img.height)), ("ColorSpace", doc.name(colorSpace)), ("BitsPerComponent", doc.int(8))])
            return doc.addStream(samples, dict: d, deflate: true)
        }
        let made = image(img.rgb, "DeviceRGB")
        // Alpha that hides every pixel isn't transparency but a missing alpha channel (32-bit clipboard bitmaps): opaque.
        if let alpha = img.alpha, alpha.contains(where: { $0 != 255 }), alpha.contains(where: { $0 != 0 }) {
            made.set("SMask", image(alpha, "DeviceGray"))
        }
        return made
    }
}
