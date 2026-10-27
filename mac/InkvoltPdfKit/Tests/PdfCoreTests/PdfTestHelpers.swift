import Foundation
import Testing
@testable import PdfCore

/// Hand-written PDFs from a list of objects numbered 1…n, and reading a PDF's objects (the Windows tests' `Core2Pdf`,
/// which reads with PDFsharp; here MuPDF through `PObj`).
enum Core2Pdf {
    static func build(_ objects: [String], trailerExtra: String = "") -> [UInt8] {
        Core1TestPdf.build(Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($0.offset + 1, $0.element) }), trailerExtra: trailerExtra)
    }

    static func stream(_ content: String, _ dict: String = "") -> String { Core1TestPdf.stream(content, dict) }

    /// The PDF opened to read its objects.
    static func open(_ data: [UInt8], password: String? = nil) throws -> MuDoc { try PdfEdit.openToRead(data, password) }
}

/// Everything a PDF holds as text: its raw bytes and every stream decoded (the Windows tests' `PdfText`).
enum PdfText {
    static func everything(_ pdf: [UInt8]) throws -> String {
        var text = String(decoding: pdf.map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
        let doc = try Core2Pdf.open(pdf)
        for n in 1..<max(doc.objectCount, 1) {
            let o = doc.object(n)
            if o.isStream, let data = o.streamData { text += "\n" + String(decoding: data.map { $0 < 128 ? $0 : 63 }, as: UTF8.self) }
        }
        return text
    }
}

/// Synthetic image files for the image tests (the Windows tests' `TestImages`).
enum TestImages {
    /// An RGBA PNG (optionally with a pHYs resolution).
    static func png(_ w: Int, _ h: Int, dpi: Double? = nil, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity(h * (1 + 4 * w))
        for y in 0..<h {
            raw.append(0)
            for x in 0..<w {
                let (r, g, b, a) = pixel(x, y)
                raw += [r, g, b, a]
            }
        }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10]
        var ihdr = be32(UInt32(w)) + be32(UInt32(h))
        ihdr += [8, 6, 0, 0, 0]
        out += chunk("IHDR", ihdr)
        if let dpi {
            let ppm = UInt32((dpi / 0.0254).rounded())
            out += chunk("pHYs", be32(ppm) + be32(ppm) + [1])
        }
        out += chunk("IDAT", zlib(raw))
        out += chunk("IEND", [])
        return out
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return be32(UInt32(data.count)) + body + be32(crc32(body))
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return ~crc
    }

    /// zlib framing around Foundation's raw deflate.
    private static func zlib(_ data: [UInt8]) -> [UInt8] {
        let deflated = (try? (Data(data) as NSData).compressed(using: .zlib) as Data) ?? Data()
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return [0x78, 0x9C] + Array(deflated) + be32(b << 16 | a)
    }

    /// A w × h pixel JPEG (drawn by MuPDF): white with a red top-left quarter.
    static func jpeg(_ w: Int, _ h: Int) -> [UInt8] {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Contents 4 0 R >>",
            Core2Pdf.stream("1 0 0 rg 0 \(h / 2) \(w / 2) \(h - h / 2) re f"),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try! PdfEngine.open(pdf)
        defer { engine.close() }
        try! engine.saveImage(0, dpi: 72, path: url.path, jpeg: true)
        return Array(try! Data(contentsOf: url))
    }

    /// The JPEG with an EXIF APP1 segment (big-endian TIFF, one IFD entry: Orientation) right after SOI.
    static func withExifOrientation(_ jpeg: [UInt8], _ orientation: Int) -> [UInt8] {
        let tiff: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, UInt8(orientation), 0, 0, 0, 0, 0, 0, 0, 0]
        let payload = Array("Exif\0\0".utf8) + tiff
        let len = payload.count + 2
        let seg: [UInt8] = [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 255)] + payload
        return Array(jpeg[0..<2]) + seg + Array(jpeg[2...])
    }

    /// The color at a point of a page (page space) drawn at 1x, as RGB.
    static func pixelAt(_ pdf: [UInt8], _ page: Int, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        let engine = try! PdfEngine.open(pdf)
        defer { engine.close() }
        let img = try! engine.render(page, scale: 1, region: RectD(x, y, 1, 1))
        return (Int(img.pixels[0]), Int(img.pixels[1]), Int(img.pixels[2]))
    }
}

/// Bookmarks as "Title@page" entries, children indented (Core1NavigationTests' `Outline`).
func outlineText(_ data: [UInt8]) throws -> String {
    let e = try PdfEngine.open(data)
    defer { e.close() }
    var s = ""
    func walk(_ nodes: [OutlineNode], _ indent: String) {
        for n in nodes {
            s += "\(indent)\(n.title)@\(n.pageIndex);"
            walk(n.children, indent + ">")
        }
    }
    walk(try e.outline(), "")
    return s
}

func linkTargets(_ data: [UInt8], _ page: Int) throws -> [Int] {
    let e = try PdfEngine.open(data)
    defer { e.close() }
    return try e.links(page).map(\.pageIndex)
}

/// Page objects in the file: stray copies of removed or imported pages would show up here.
func pageObjects(_ data: [UInt8]) -> Int {
    let text = String(decoding: data.map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
    return (try? NSRegularExpression(pattern: #"/Type\s*/Page(?![s\w])"#).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))) ?? 0
}

/// The names of the top-level form fields.
func fieldNames(_ data: [UInt8]) throws -> [String] {
    let doc = try Core2Pdf.open(data)
    return doc.catalog.dict("AcroForm")?.array("Fields")?.elements.map { $0.text("T") ?? "" } ?? []
}

/// The form widgets on the pages, in page order: the field's name (the widget's /T, else its parent's), its page and
/// value (what the Windows tests read with FormEditor.Read, which comes with D5).
func widgets(_ data: [UInt8]) throws -> [(field: String, page: Int, value: String?)] {
    let doc = try Core2Pdf.open(data)
    var out: [(field: String, page: Int, value: String?)] = []
    for i in 0..<(try doc.pageCount()) {
        for a in doc.page(i).array("Annots")?.elements ?? [] where a.name("Subtype") == "Widget" {
            let field = a.has("T") ? a : a.dict("Parent") ?? a
            out.append((field.text("T") ?? "", i, field.text("V") ?? field.name("V")))
        }
    }
    return out
}

extension Core2Pdf {
    typealias Line = (text: String, box: RectD, chars: [(ch: String, box: RectD)])

    /// Text lines MuPDF extracts from a page, annotations (and widget appearances) included, with their boxes in MuPDF's
    /// page space (Core2Pdf.Lines, which reads them with MuPDFCore).
    static func lines(_ data: [UInt8], page: Int = 0, annotations: Bool = true) throws -> [Line] {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        return try engine.textLines(page, annotations: annotations).map { ($0.text, $0.box, $0.chars) }
    }

    static func allText(_ data: [UInt8], page: Int = 0, annotations: Bool = true) throws -> String {
        try lines(data, page: page, annotations: annotations).map(\.text).joined(separator: "\n")
    }

    /// The fraction of dark pixels in a page region rendered at 2x.
    static func ink(_ data: [UInt8], _ page: Int, _ region: RectD) throws -> Double {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let img = try engine.render(page, scale: 2, region: region)
        var dark = 0
        var i = 0
        while i + 2 < img.pixels.count {
            if Int(img.pixels[i]) + Int(img.pixels[i + 1]) + Int(img.pixels[i + 2]) < 384 { dark += 1 }
            i += 3
        }
        return Double(dark) / Double(img.width * img.height)
    }

    /// The last annotation on a page (its dictionary), read through MuPDF.
    static func lastAnnot(_ data: [UInt8], page: Int = 0) throws -> PObj {
        let doc = try open(data)
        return try #require(doc.page(page).array("Annots")?.elements.last)
    }
}

/// The PDF's bytes as text (Latin-1, as the Windows tests' `Encoding.Latin1.GetString`).
func latin1(_ data: [UInt8]) -> String { String(data.map { Character(Unicode.Scalar($0)) }) }

extension Core2Pdf {
    /// A one-page form: the given field objects (numbered from 5) as widgets on page 3, with Helvetica in /DR as 4
    /// (Core2Pdf.Form).
    static func form(_ fields: [String], acroExtra: String = "", pageExtra: String = "", catalogExtra: String = "", more: [String] = [],
                     extraAnnots: String = "") -> [UInt8] {
        let refs = fields.indices.map { "\(5 + $0) 0 R" }.joined(separator: " ")
        return build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(refs)] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> \(acroExtra) >> \(catalogExtra) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [\(refs) \(extraAnnots)] /Resources << >> \(pageExtra) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ] + fields + more)
    }

    /// The same document without /NeedAppearances, so viewers must use the appearance streams written for it.
    static func withoutNeedAppearances(_ data: [UInt8]) throws -> [UInt8] {
        let doc = try open(data)
        doc.catalog.dict("AcroForm")?.remove("NeedAppearances")
        try doc.checkFailure()
        return try doc.write("")
    }

    /// The top-level field named `name`.
    static func field(_ doc: MuDoc, _ name: String) -> PObj? {
        doc.catalog.dict("AcroForm")?.array("Fields")?.elements.first { $0.text("T") == name }
    }
}

/// A form filled with `values` (FormEditor.SetValues in the Windows tests).
func filled(_ form: [UInt8], _ values: [String: String]) throws -> [UInt8] { try FormEditor.setValues(form, nil, values) }
