import Foundation
import PrintCore

/// Crop Picture (Edit Text & Images, roadmap 2.1; the Windows app's `ContentEditor.Crop`): a picture cut down to part of
/// itself for real. The part kept is drawn by MuPDF from the picture as the page has it (any filter, color space, decode
/// array or mask), at the picture's own pixels, and stored as a new picture (Flate, RGB, with a soft mask when it had one)
/// placed where that part was; the old picture leaves the page, so the pixels cut off are no longer in the file (a signed
/// file's earlier revision keeps them, as any removal there).
extension ContentEditor {
    /// The most pixels a crop writes (the part kept): a hostile picture's size is bounded before it is drawn.
    static let maxCropPixels = 50_000_000

    /// Crops a picture to `crop` (page space; held to the whole picture, and out to whole pixels of it): the part kept
    /// becomes the picture and the rest is gone from the file. Upright pictures and quarter turns only; a stencil (one color
    /// painted through the picture) or a picture masked by color isn't cropped.
    /// - Throws: `ContentEditError` when the crop can't be made (why, as a sentence).
    public static func cropImage(_ data: [UInt8], _ password: String?, _ image: PageImage, _ crop: RectD) throws -> [UInt8] {
        if image.turned { throw ContentEditError(loc("Only an upright picture, or one turned a quarter, can be cropped.")) }
        let tooSmall = loc("A picture can't be made that small.")
        if !(crop.x + crop.y + crop.width + crop.height).isFinite { throw ContentEditError(tooSmall) }
        return try editImage(data, password, image, dropName: true) { doc, page, found, op, ctm, ops, content in
            let whole = found.uncropped ?? found.box
            let c = crop.intersect(whole)
            if c.width < 1 || c.height < 1 { throw ContentEditError(tooSmall) }
            guard let inv = ctm.inverted() else { throw ContentEditError(loc("This picture is drawn squashed flat, so it can't be moved.")) }
            let toUnit = pageToUser(PageBoxes.frame(page)).times(inv)
            let a = toUnit.apply(c.x, c.y), b = toUnit.apply(c.right, c.bottom)
            func unit(_ v: Double) -> Double { min(max(v, 0), 1) }
            let x0 = unit(min(a.x, b.x)), x1 = unit(max(a.x, b.x))
            let y0 = unit(min(a.y, b.y)), y1 = unit(max(a.y, b.y))
            guard let at = ops.firstIndex(where: { $0 === op }) else {
                throw ContentEditError(loc("The page changed since this picture was picked. Pick it again."))
            }
            guard let source = cropSource(page, op) else { throw ContentEditError(cropFailed) }
            // Out to whole pixels: image space has its first row at the top (y = 1).
            let w = source.width, h = source.height
            let dw = Double(w), dh = Double(h)
            let cx0 = min(max(Int(exactly: (x0 * dw + 1e-6).rounded(.down)) ?? 0, 0), w)
            let cx1 = min(max(Int(exactly: (x1 * dw - 1e-6).rounded(.up)) ?? 0, 0), w)
            let ry0 = min(max(Int(exactly: ((1 - y1) * dh + 1e-6).rounded(.down)) ?? 0, 0), h)
            let ry1 = min(max(Int(exactly: ((1 - y0) * dh - 1e-6).rounded(.up)) ?? 0, 0), h)
            let cw = cx1 - cx0, ch = ry1 - ry0
            if cw < 1 || ch < 1 { throw ContentEditError(tooSmall) }
            let placedAt = placed(ops, at)
            if cw == w && ch == h {
                // All of it: only a clip of the picture's own (inside its q … Q) goes; one drawn outside such a group clips
                // what follows it too, so it stays.
                if let p = placedAt, p.clip >= 0 { return [(ops[p.clip].start, ops[p.clip + 2].end, [])] }
                return []
            }
            if source.stencil {
                throw ContentEditError(loc("This picture is one color painted through a stencil (or masked by a color), so it can't be cropped."))
            }
            if source.oddTransparency {
                throw ContentEditError(loc("This picture keeps its transparency in a way a crop can't keep (inside its JPEG 2000 data, or blended with a background color), so it can't be cropped."))
            }
            // MuPDF decodes the whole picture to draw a part of it: the picture's own size is bounded too.
            if cw * ch > maxCropPixels || dw * dh > PdfEngine.maxPixels {
                throw ContentEditError(loc("The part of the picture to keep is too large to crop (more than 50 million pixels)."))
            }
            let (rgb, alpha) = try renderCrop(data, password, found.pageIndex, source, slice(op, content), cx0, ry0, cw, ch)
            let picture = ImageImport.imageStream(doc, cw, ch, rgb, "DeviceRGB",
                                                  mask: alpha.map { ImageImport.imageStream(doc, cw, ch, $0, "DeviceGray") })
            if source.interpolate { picture.set("Interpolate", doc.bool(true)) }
            // What else the picture said of itself: the layer it is in, its rendering intent, its alternate text.
            if let old = source.dict {
                for key in ["OC", "Intent", "Alt"] { // not /Alternates: those are the whole picture again
                    if let v = old[key] { picture.set(key, v) }
                }
            }
            let name = addXObject(doc, page, picture)
            // The new picture's unit square onto the part of the old one's it shows.
            let s = Mat(Double(cw) / dw, 0, 0, Double(ch) / dh, Double(cx0) / dw, Double(h - ry1) / dh)
            SignedEdits.noteRemoval()
            if let p = placedAt {
                var m = s
                if p.cm >= 0 {
                    let cm = ops[p.cm]
                    m = s.times(Mat(cm.n(0), cm.n(1), cm.n(2), cm.n(3), cm.n(4), cm.n(5)))
                }
                return [(ops[p.q].start, ops[p.end].end, latin1Bytes("q \(m.write()) cm /\(name) Do Q"))]
            }
            // Drawn without a q … Q of its own: only the drawing is replaced; a clip before it (which may clip what follows
            // too) stays.
            return [(op.start, op.end, latin1Bytes("q \(s.write()) cm /\(name) Do Q"))]
        }
    }

    private static var cropFailed: String { loc("The picture couldn't be cropped: its image couldn't be read.") }

    /// What a crop needs of a picture: its pixel size (1 to 65,535 each way), its resource name (nil: an inline image),
    /// whether it is a stencil or masked by color, has a soft mask or a mask image, or keeps its transparency where a crop
    /// can't (inside JPEG 2000 data, /SMaskInData; colors blended with a matte color, a soft mask's /Matte); the image
    /// XObject (nil: an inline image).
    private struct CropPicture {
        var width: Int, height: Int
        var name: String?
        var stencil = false, softMask = false, maskImage = false, interpolate = false
        var oddTransparency = false
        var dict: PObj?
    }

    /// Nil when it can't be read.
    private static func cropSource(_ page: PObj, _ op: COp) -> CropPicture? {
        func size(_ w: Double, _ h: Double) -> (Int, Int)? {
            guard (1...65535).contains(w), (1...65535).contains(h), let iw = Int(exactly: w), let ih = Int(exactly: h) else { return nil }
            return (iw, ih)
        }
        if op.name == "BI" {
            guard let d = op.operands.first, d.kind == .dict else { return nil }
            let w = (d["W"] ?? d["Width"]).flatMap { $0.kind == .number ? $0.num : nil } ?? 0
            let h = (d["H"] ?? d["Height"]).flatMap { $0.kind == .number ? $0.num : nil } ?? 0
            guard let (iw, ih) = size(w, h) else { return nil }
            func flag(_ a: String, _ b: String) -> Bool { (d[a] ?? d[b]).map { $0.kind == .bool && $0.name == "true" } ?? false }
            return CropPicture(width: iw, height: ih, name: nil, stencil: flag("IM", "ImageMask"), interpolate: flag("I", "Interpolate"))
        }
        guard let name = op.operands.first?.name,
              let image = (page.dict("Resources") ?? PageBoxes.inherited(page, "Resources"))?.dict("XObject")?.dict(name),
              let (iw, ih) = size(image.number("Width") ?? 0, image.number("Height") ?? 0) else { return nil }
        let mask = image["Mask"]
        let smask = image.dict("SMask")
        func on(_ key: String) -> Bool { image[key].map { $0.kind == .bool && $0.bool } ?? false }
        var p = CropPicture(width: iw, height: ih, name: name)
        p.stencil = on("ImageMask") || mask?.isArray == true // a color key: stencil-like, not kept
        p.softMask = smask != nil
        p.maskImage = mask?.isDict == true
        p.interpolate = on("Interpolate")
        p.oddTransparency = (image.number("SMaskInData") ?? 0) != 0 || smask?["Matte"] != nil
        p.dict = image
        return p
    }

    /// The part kept, drawn by MuPDF from a copy of the document whose page shows only it, pixel for pixel: its colors (on
    /// their own, masks taken off) as RGB, and its mask (a soft mask's gray, a stencil mask's coverage) as alpha.
    private static func renderCrop(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ source: CropPicture, _ drawn: [UInt8],
                                   _ cx0: Int, _ ry0: Int, _ cw: Int, _ ch: Int) throws -> (rgb: [UInt8], alpha: [UInt8]?) {
        // The picture's unit square on a cw x ch page, its part (cx0, ry0) at the page's top left (PDF space: y up).
        let place = "\(source.width) 0 0 \(source.height) \(-cx0) \(-(source.height - ry0 - ch)) cm"
        let colors = try draw(latin1Bytes("q \(place) ") + drawn + latin1Bytes(" Q"), mask: nil)
        var alpha: [UInt8]?
        if source.softMask || source.maskImage {
            let gray = try draw(latin1Bytes("q \(place) /InkCropMask Do Q"), mask: source.softMask ? "SMask" : "Mask")
            // A soft mask's gray is its alpha; a stencil mask paints black where the picture shows.
            alpha = (0..<(cw * ch)).map { source.softMask ? gray[3 * $0] : 255 - gray[3 * $0] }
        }
        return (colors, alpha)

        func draw(_ content: [UInt8], mask maskKey: String?) throws -> [UInt8] {
            let pdf: [UInt8]
            do {
                let copy = try PdfEdit.open(data, password)
                let page = try pageOf(copy, pageIndex)
                for key in ["BleedBox", "TrimBox", "ArtBox", "Annots", "UserUnit", "Group"] { page.remove(key) }
                // Set, not taken out: a page may inherit them from its page tree.
                page.set("MediaBox", copy.reals(0, 0, Double(cw), Double(ch)))
                page.set("CropBox", copy.reals(0, 0, Double(cw), Double(ch)))
                page.set("Rotate", copy.int(0))
                if let name = source.name, let res = page.dict("Resources") ?? PageBoxes.inherited(page, "Resources"),
                   let xo = res.dict("XObject"), let image = xo.dict(name) {
                    if let maskKey, let m = image[maskKey] {
                        // The mask drawn on its own, as the picture: under a name of its own in a copy of the resources.
                        let xo2 = copy.dict()
                        for k in xo.keys { if let v = xo[k] { xo2.set(k, v) } }
                        xo2.set("InkCropMask", m)
                        let res2 = copy.dict()
                        for k in res.keys { if let v = res[k] { res2.set(k, v) } }
                        res2.set("XObject", xo2)
                        page.set("Resources", res2)
                    } else {
                        // Its colors on their own: its masks off (in this copy only).
                        image.remove("SMask")
                        image.remove("Mask")
                    }
                }
                page.set("Contents", copy.addStream(content, deflate: false))
                try copy.checkFailure()
                pdf = try copy.write("encrypt=keep")
            } catch {
                throw ContentEditError(cropFailed)
            }
            do {
                let engine = try PdfEngine.open(pdf, password: password)
                defer { engine.close() }
                let img = try engine.render(pageIndex, scale: 1, annotations: false)
                // The page is cw x ch points, so as many pixels (a pixel short at an edge is white).
                var rgb = [UInt8](repeating: 255, count: cw * ch * 3)
                for y in 0..<min(ch, img.height) {
                    for x in 0..<min(cw, img.width) {
                        let from = y * img.stride + 3 * x, to = 3 * (y * cw + x)
                        rgb[to] = img.pixels[from]
                        rgb[to + 1] = img.pixels[from + 1]
                        rgb[to + 2] = img.pixels[from + 2]
                    }
                }
                return rgb
            } catch {
                throw ContentEditError(cropFailed)
            }
        }
    }
}
