import Foundation
import MuPDFShim

/// Page size for images turned into PDF pages.
public enum PageSizeOption: Sendable {
    /// Each page the size of its image at the image's resolution (96 dpi when the file doesn't say).
    case fitImage
    /// US Letter, turned to landscape for wide images, the image centered within half-inch margins.
    case letter
    /// A4, turned to landscape for wide images, the image centered within half-inch margins.
    case a4
}

/// Turns image files into a PDF, one page per image (per frame of a multi-page TIFF), as the Windows app's `ImageImport`
/// does. JPEG files are embedded as they are (DCTDecode, no recompression), turned upright as their EXIF orientation
/// says. PNG, BMP, GIF and TIFF are decoded by MuPDF and stored losslessly (Flate), with an /SMask when they have
/// transparency. On Letter or A4 pages an image is shrunk to fit the margins but never enlarged.
public enum ImageImport {
    /// Resolution assumed when an image file doesn't state one.
    public static let defaultDpi = 96.0
    private static let margin = 36.0

    private struct Picture {
        var image: PObj
        var width: Int, height: Int
        var dpiX: Double, dpiY: Double
        var orientation: Int
    }

    enum ImageType { case jpeg, png, gif, bmp, tiff }

    /// - Throws: `PdfEditError` when there are no images, or a file isn't an image that can be read (the message names it).
    public static func imagesToPdf(_ images: [(bytes: [UInt8], name: String)], pageSize: PageSizeOption = .fitImage) throws -> [UInt8] {
        if images.isEmpty { throw PdfEditError("There are no images to convert.") }
        let doc = try MuDoc.create()
        for (bytes, name) in images {
            let pictures: [Picture]
            switch sniff(bytes, name) {
            case .jpeg?:
                if let jpeg = jpeg(doc, bytes) { pictures = [jpeg] } else { pictures = try decoded(doc, bytes, .jpeg, name) }
            case let type?:
                pictures = try decoded(doc, bytes, type, name)
            case nil:
                throw PdfEditError("\"\(name)\" isn't an image Inkvolt PDF can read (JPEG, PNG, BMP, GIF, TIFF).")
            }
            for p in pictures { try addPage(doc, p, pageSize) }
        }
        InfoDict.setDate(doc, "CreationDate", Date())
        try doc.checkFailure()
        return try doc.write("garbage=compact")
    }

    /// An image file stored in `doc` as an image XObject (its first frame), with its pixel size, resolution and EXIF
    /// orientation (Edit Text & Images' Replace Picture).
    /// - Throws: `PdfEditError` when the file isn't an image that can be read.
    static func storeImage(_ doc: MuDoc, _ bytes: [UInt8], _ name: String) throws
        -> (image: PObj, width: Int, height: Int, dpiX: Double, dpiY: Double, orientation: Int) {
        let p: Picture
        switch sniff(bytes, name) {
        case .jpeg?:
            if let jpeg = jpeg(doc, bytes) { p = jpeg } else { p = try decoded(doc, bytes, .jpeg, name)[0] }
        case let type?:
            p = try decoded(doc, bytes, type, name)[0]
        case nil:
            throw PdfEditError("\"\(name)\" isn't an image Inkvolt PDF can read (JPEG, PNG, BMP, GIF, TIFF).")
        }
        return (p.image, p.width, p.height, p.dpiX, p.dpiY, p.orientation)
    }

    private static func addPage(_ doc: MuDoc, _ p: Picture, _ size: PageSizeOption) throws {
        let w = Double(p.width) * 72 / p.dpiX
        let h = Double(p.height) * 72 / p.dpiY
        let sideways = (5...8).contains(p.orientation)
        var (dw, dh) = sideways ? (h, w) : (w, h)
        var pw: Double, ph: Double, x = 0.0, y = 0.0
        if size == .fitImage {
            (pw, ph) = (dw, dh)
        } else {
            (pw, ph) = size == .a4 ? (595.28, 841.89) : (612, 792)
            if dw > dh { (pw, ph) = (ph, pw) }
            let scale = min(1, min((pw - 2 * margin) / dw, (ph - 2 * margin) / dh))
            (dw, dh) = (dw * scale, dh * scale)
            (x, y) = ((pw - dw) / 2, (ph - dh) / 2)
        }
        let m = placement(p.orientation, x, y, dw, dh)
        let ops = "q " + m.map(format).joined(separator: " ") + " cm /Im0 Do Q\n"
        let contents = doc.addStream(Array(ops.utf8), deflate: false)
        let resources = doc.dict([("XObject", doc.dict([("Im0", p.image)]))])
        let page = doc.add(doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, pw, ph)), ("Contents", contents),
                                     ("Resources", resources)]))
        doc.insertPage(page, at: try doc.pageCount())
    }

    /// A number as content streams write it (up to four decimals, no trailing zeros).
    private static func format(_ v: Double) -> String {
        let r = (v * 10000).rounded() / 10000
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.4f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    /// The image matrix drawing a stored image upright in the box (x, y, w, h) for EXIF orientation 1-8.
    static func placement(_ orientation: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Double] {
        // Displayed fractions (X right, T down) from stored fractions (s right, t down): X = ax s + bx t + cx, T = at s + bt t + ct.
        let (ax, bx, cx, at, bt, ct): (Double, Double, Double, Double, Double, Double)
        switch orientation {
        case 2: (ax, bx, cx, at, bt, ct) = (-1, 0, 1, 0, 1, 0)
        case 3: (ax, bx, cx, at, bt, ct) = (-1, 0, 1, 0, -1, 1)
        case 4: (ax, bx, cx, at, bt, ct) = (1, 0, 0, 0, -1, 1)
        case 5: (ax, bx, cx, at, bt, ct) = (0, 1, 0, 1, 0, 0)
        case 6: (ax, bx, cx, at, bt, ct) = (0, -1, 1, 1, 0, 0)
        case 7: (ax, bx, cx, at, bt, ct) = (0, -1, 1, -1, 0, 1)
        case 8: (ax, bx, cx, at, bt, ct) = (0, 1, 0, -1, 0, 1)
        default: (ax, bx, cx, at, bt, ct) = (1, 0, 0, 0, 1, 0)
        }
        // Image space: u = s, v = 1 - t (the first row is at the top); page: px = x + w X, py = y + h (1 - T).
        return [w * ax, -h * at, -w * bx, h * bt, x + w * (bx + cx), y + h - h * (bt + ct)]
    }

    // ---- JPEG: embedded as is ----

    private static func jpeg(_ doc: MuDoc, _ b: [UInt8]) -> Picture? {
        guard let info = readJpeg(b) else { return nil }
        var entries: [(String, PObj)] = [
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(info.width)), ("Height", doc.int(info.height)),
            ("BitsPerComponent", doc.int(8)), ("ColorSpace", doc.name(info.components == 1 ? "DeviceGray" : info.components == 4 ? "DeviceCMYK" : "DeviceRGB")),
            ("Filter", doc.name("DCTDecode")),
        ]
        // Adobe (Photoshop) CMYK JPEGs store inverted values.
        if info.components == 4 && info.adobe { entries.append(("Decode", doc.reals(1, 0, 1, 0, 1, 0, 1, 0))) }
        let image = doc.addStream(b, dict: doc.dict(entries), deflate: false)
        return Picture(image: image, width: info.width, height: info.height, dpiX: info.dpiX ?? defaultDpi,
                       dpiY: info.dpiY ?? info.dpiX ?? defaultDpi, orientation: info.orientation)
    }

    struct JpegInfo: Equatable {
        var width: Int, height: Int, components: Int
        var dpiX: Double?, dpiY: Double?
        var orientation: Int
        var adobe: Bool
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> Int { at + 2 <= b.count ? Int(b[at]) << 8 | Int(b[at + 1]) : 0 }

    /// Size, components, resolution and EXIF orientation from a JPEG's markers (nil if it isn't a usable JPEG).
    static func readJpeg(_ b: [UInt8]) -> JpegInfo? {
        if b.count < 4 || b[0] != 0xFF || b[1] != 0xD8 { return nil }
        var width = 0, height = 0, comps = 0, orientation = 1
        var dpiX: Double?, dpiY: Double?, exifX: Double?, exifY: Double?
        var adobe = false
        var i = 2
        while i + 4 <= b.count {
            if b[i] != 0xFF {
                i += 1
                continue
            }
            let marker = b[i + 1]
            if marker == 0xFF {
                i += 1
                continue
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            if marker == 0xD9 { break }
            let len = u16(b, i + 2)
            if len < 2 || i + 2 + len > b.count { break }
            let seg = Array(b[(i + 4)..<(i + 2 + len)])
            switch marker {
            case 0xE0 where seg.count >= 12 && Array(seg[0..<5]) == Array("JFIF\0".utf8):
                let unit = seg[7]
                let xd = Double(u16(seg, 8)), yd = Double(u16(seg, 10))
                let f = unit == 1 ? 1.0 : unit == 2 ? 2.54 : 0
                if f > 0 && xd > 0 && yd > 0 { (dpiX, dpiY) = (xd * f, yd * f) }
            case 0xE1 where seg.count >= 14 && Array(seg[0..<6]) == Array("Exif\0\0".utf8):
                let tiff = Tiff.read(Array(seg[6...]))
                if (1...8).contains(tiff.orientation) { orientation = tiff.orientation }
                (exifX, exifY) = (tiff.dpiX, tiff.dpiY)
            case 0xEE where seg.count >= 12 && Array(seg[0..<5]) == Array("Adobe".utf8):
                adobe = true
            case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC && seg.count >= 6:
                if seg[0] != 8 { return nil } // 12-bit and lossless JPEGs: PDF's DCTDecode wants 8 bits
                height = u16(seg, 1)
                width = u16(seg, 3)
                comps = Int(seg[5])
            default:
                break
            }
            if marker == 0xDA { break }
            i += 2 + len
        }
        if width <= 0 || height <= 0 || ![1, 3, 4].contains(comps) { return nil }
        return JpegInfo(width: width, height: height, components: comps, dpiX: dpiX ?? exifX, dpiY: dpiY ?? exifY, orientation: orientation, adobe: adobe)
    }

    // ---- Other formats: decoded by MuPDF ----

    private static func decoded(_ doc: MuDoc, _ bytes: [UInt8], _ type: ImageType, _ name: String) throws -> [Picture] {
        let header = self.header(bytes, type)
        let magic: String
        switch type {
        case .png: magic = "image/png"
        case .gif: magic = "image/gif"
        case .bmp: magic = "image/bmp"
        case .tiff: magic = "image/tiff"
        case .jpeg: magic = "image/jpeg"
        }
        let image: MuDoc
        do {
            image = try MuDoc.openImage(bytes, magic: magic, in: doc)
        } catch let e as PdfEngineError {
            throw PdfEditError("\"\(name)\" can't be read as an image: \(e.message)")
        }
        var list: [Picture] = []
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let count = Int(inkv_count_pages(image.ctx, image.doc, &err))
        for i in 0..<max(count, 0) {
            var b = [Float](repeating: 0, count: 4)
            guard inkv_page_bounds(image.ctx, image.doc, Int32(i), &b, &err) != 0 else { continue }
            let bw = Double(b[2] - b[0]), bh = Double(b[3] - b[1])
            if bw <= 0 || bh <= 0 { continue }
            // Native pixels: MuPDF sizes an image page from the image's resolution, which the header tells.
            let scale = header.width > 0 ? Double(header.width) / bw : 1
            if (bw * scale) * (bh * scale) > PdfEngine.maxPixels {
                throw PdfEditError("\"\(name)\" is too large (\(Int(bw * scale)) x \(Int(bh * scale)) pixels).")
            }
            var px: UnsafeMutablePointer<UInt8>?
            var w: Int32 = 0, h: Int32 = 0
            guard inkv_render_rgba(image.ctx, image.doc, Int32(i), Float(scale), &px, &w, &h, &err) != 0, let px else { continue }
            let rgba = Array(UnsafeBufferPointer(start: px, count: Int(w) * Int(h) * 4))
            inkv_free(px)
            let dx = header.dpiX ?? (header.width > 0 ? defaultDpi : 72)
            let dy = header.dpiY ?? header.dpiX ?? (header.width > 0 ? defaultDpi : 72)
            list.append(Picture(image: store(doc, Int(w), Int(h), rgba), width: Int(w), height: Int(h), dpiX: dx, dpiY: dy, orientation: 1))
        }
        if list.isEmpty { throw PdfEditError("\"\(name)\" has no image MuPDF can draw.") }
        return list
    }

    /// An image XObject (Flate; gray when every pixel is) from straight RGBA, with an /SMask for any transparency.
    static func store(_ doc: MuDoc, _ width: Int, _ height: Int, _ rgba: [UInt8]) -> PObj {
        let n = width * height
        var alpha = [UInt8](repeating: 0, count: n)
        var opaque = true, gray = true
        for k in 0..<n {
            alpha[k] = rgba[4 * k + 3]
            if alpha[k] != 255 { opaque = false }
            if gray && !(rgba[4 * k] == rgba[4 * k + 1] && rgba[4 * k] == rgba[4 * k + 2]) { gray = false }
        }
        var samples = [UInt8](repeating: 0, count: gray ? n : n * 3)
        for k in 0..<n {
            if gray {
                samples[k] = rgba[4 * k]
            } else {
                samples[3 * k] = rgba[4 * k]
                samples[3 * k + 1] = rgba[4 * k + 1]
                samples[3 * k + 2] = rgba[4 * k + 2]
            }
        }
        let image = imageStream(doc, width, height, samples, gray ? "DeviceGray" : "DeviceRGB", mask: opaque ? nil : imageStream(doc, width, height, alpha, "DeviceGray"))
        return image
    }

    static func imageStream(_ doc: MuDoc, _ width: Int, _ height: Int, _ samples: [UInt8], _ colorSpace: String, mask: PObj? = nil) -> PObj {
        var entries: [(String, PObj)] = [
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(width)), ("Height", doc.int(height)),
            ("ColorSpace", doc.name(colorSpace)), ("BitsPerComponent", doc.int(8)),
        ]
        if let mask { entries.append(("SMask", mask)) }
        return doc.addStream(samples, dict: doc.dict(entries), deflate: true)
    }

    /// The image type from the file's magic bytes, else its extension.
    static func sniff(_ b: [UInt8], _ name: String) -> ImageType? {
        func starts(_ p: [UInt8]) -> Bool { b.count >= p.count && Array(b[0..<p.count]) == p }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if starts(Array("GIF8".utf8)) { return .gif }
        if starts(Array("BM".utf8)) { return .bmp }
        if starts(Array("II*\0".utf8)) || starts(Array("MM\0*".utf8)) { return .tiff }
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "bmp": return .bmp
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    /// Pixel size and resolution from the file header (0 / nil where it doesn't say or can't be read).
    private static func header(_ b: [UInt8], _ type: ImageType) -> (width: Int, height: Int, dpiX: Double?, dpiY: Double?) {
        func be32(_ at: Int) -> Int { at + 4 <= b.count ? Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) : 0 }
        func le16(_ at: Int) -> Int { at + 2 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 : 0 }
        func le32(_ at: Int) -> Int32 { at + 4 <= b.count ? Int32(bitPattern: UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24) : 0 }
        switch type {
        case .png where b.count >= 24:
            let w = be32(16), h = be32(20)
            var dx: Double?, dy: Double?
            var i = 8
            while i + 8 <= b.count {
                let len = be32(i)
                if len < 0 || i + 12 + len > b.count { break }
                let kind = Array(b[(i + 4)..<(i + 8)])
                if kind == Array("pHYs".utf8) && len >= 9 && b[i + 16] == 1 {
                    dx = Double(be32(i + 8)) * 0.0254
                    dy = Double(be32(i + 12)) * 0.0254
                }
                if kind == Array("IDAT".utf8) { break }
                i += 12 + len
            }
            return (w, h, sane(dx), sane(dy))
        case .gif where b.count >= 10:
            return (le16(6), le16(8), nil, nil)
        case .bmp where b.count >= 26:
            let size = le32(14)
            if size == 12 { return (le16(18), le16(20), nil, nil) }
            if size < 40 || b.count < 46 { return (0, 0, nil, nil) }
            return (Int(le32(18)), Int(abs(le32(22))), sane(Double(le32(38)) * 0.0254), sane(Double(le32(42)) * 0.0254))
        case .tiff:
            let t = Tiff.read(b)
            return (t.width, t.height, sane(t.dpiX), sane(t.dpiY))
        default:
            return (0, 0, nil, nil)
        }
    }

    private static func sane(_ dpi: Double?) -> Double? { dpi.flatMap { (10...10_000).contains($0) ? $0 : nil } }

    /// The first IFD of a TIFF structure (a TIFF file, or the EXIF block of a JPEG).
    enum Tiff {
        struct Info {
            var width = 0, height = 0
            var dpiX: Double?, dpiY: Double?
            var orientation = 1
        }

        static func read(_ b: [UInt8]) -> Info {
            if b.count < 8 { return Info() }
            let little = b[0] == UInt8(ascii: "I")
            if !little && b[0] != UInt8(ascii: "M") { return Info() }
            func u32(_ at: Int) -> UInt32 {
                guard at >= 0, at + 4 <= b.count else { return 0 }
                let v = (0..<4).map { UInt32(b[at + $0]) }
                return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
            }
            func u16(_ at: Int) -> UInt32 {
                guard at >= 0, at + 2 <= b.count else { return 0 }
                return little ? UInt32(b[at]) | UInt32(b[at + 1]) << 8 : UInt32(b[at]) << 8 | UInt32(b[at + 1])
            }
            let ifd = Int(u32(4))
            let count = Int(u16(ifd))
            var info = Info()
            var unit: UInt32 = 2
            var dx: Double?, dy: Double?
            for k in 0..<min(count, 512) {
                let e = ifd + 2 + 12 * k
                if e + 12 > b.count { break }
                let tag = u16(e)
                let fieldType = u16(e + 2)
                func value() -> UInt32 { fieldType == 3 ? u16(e + 8) : u32(e + 8) }
                func rational() -> Double? {
                    let at = Int(u32(e + 8))
                    let den = u32(at + 4)
                    return den == 0 ? nil : Double(u32(at)) / Double(den)
                }
                switch tag {
                case 256: info.width = Int(value())
                case 257: info.height = Int(value())
                case 274: info.orientation = Int(value())
                case 282: dx = rational()
                case 283: dy = rational()
                case 296: unit = value()
                default: break
                }
            }
            let f = unit == 2 ? 1.0 : unit == 3 ? 2.54 : 0
            info.dpiX = f > 0 ? dx.map { $0 * f } : nil
            info.dpiY = f > 0 ? dy.map { $0 * f } : nil
            return info
        }
    }
}
