import Compression
import Foundation
import Testing
@testable import PdfCore

/// Synthetic PDFs for Word / Excel export (the Windows tests' `ExportTestPdf`, drawn there with PDFsharp in Arial):
/// headings, paragraphs, a bullet list, a ruled table, an image, two columns. Built through MuPDF with the system's
/// Arial, Arial Bold and Arial Italic embedded whole (simple TrueType fonts, WinAnsi), as PDFsharp embeds Arial. MuPDF's
/// character boxes come from the descriptor's /Ascent and /Descent, and PDFsharp writes /Descent 212 (positive: its boxes
/// end above the baseline), so the descriptor does too: the layout then sees the gaps it sees on Windows (with a proper
/// descent, or the base-14 Helvetica, the heading over the unruled table sits close enough to join it).
enum ExportTestPdf {
    static let para1 = "Inkvolt keeps every page on this computer. The viewer opens large files quickly and the organizer moves pages "
        + "around without changing their content. This paragraph runs over several lines so it has to be joined back."

    static let para2 = "A second paragraph starts after a gap and ends on the same page."

    static let bullets = ["First point in the list", "Second point in the list", "Third point"]

    static let table = [
        ["Item", "Qty", "Price"],
        ["Apples", "4", "1.20"],
        ["Pears", "12", "3.05"],
        ["Plums", "7", "0.99"],
    ]

    /// The system's Arial faces, embedded whole: resource name, PDF font name, file, descriptor flags, italic angle.
    private static let faces = [("F1", "ArialMT", "Arial.ttf", 32, 0), ("F2", "Arial-BoldMT", "Arial Bold.ttf", 32, 0),
                                ("F3", "Arial-ItalicMT", "Arial Italic.ttf", 96, -12)]

    /// Each face's program and its WinAnsi widths (thousandths of an em, codes 32-255).
    private static let programs: [String: (bytes: [UInt8], widths: [Int])] = {
        var result: [String: (bytes: [UInt8], widths: [Int])] = [:]
        for (res, _, file, _, _) in faces {
            let bytes = Array(try! Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/" + file)))
            let program = TrueTypeProgram.read(bytes)!
            let widths = (32...255).map { code -> Int in
                guard let text = GlyphNames.inEncoding("WinAnsiEncoding", code).flatMap(GlyphNames.toUnicode) else { return 0 }
                return Int((program.advance(program.lookupUnicode(Int(text.unicodeScalars.first!.value))) ?? 0).rounded())
            }
            result[res] = (bytes, widths)
        }
        return result
    }()

    /// The width of `text` in a face at `size` (PDFsharp's MeasureString).
    static func width(_ text: String, _ size: Double, _ font: String = "F1") -> Double {
        let widths = programs[font]!.widths
        return Double(latin1Bytes(text).reduce(0) { $0 + ($1 >= 32 ? widths[Int($1) - 32] : 0) }) * size / 1000
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var made: [String: [UInt8]] = [:]
    }

    private static let cache = Cache()

    /// Page 1: title, heading, two paragraphs, a bullet list, a ruled table and an image. Page 2: two columns. `logo`: the
    /// same small logo at the top right of both pages, and an icon in the table's "Pears" row.
    static func make(ruledTable: Bool = true, logo: Bool = false) -> [UInt8] {
        let key = "\(ruledTable) \(logo)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let made = cache.made[key] { return made }
        var p1 = Canvas()
        if logo { p1.image("/Logo", 492, 24, 48, 24) }
        var y = 80.0
        p1.text("Quarterly Report", "F2", 24, 72, y)
        y += 40
        p1.text("Summary", "F2", 16, 72, y)
        y += 24
        y = p1.wrap(para1, "F1", 11, 72, y, 468)
        y += 10
        let start = "A second paragraph starts after a gap and ends on the "
        p1.text(start, "F1", 11, 72, y)
        p1.text("same page.", "F3", 11, 72 + width(start, 11), y)
        y += 24
        for b in bullets {
            p1.text("\u{2022}", "F1", 11, 84, y)
            p1.text(b, "F1", 11, 100, y)
            y += 15
        }
        y += 20
        p1.text("Prices", "F2", 16, 72, y)
        y += 14
        let cols: [Double] = [72, 252, 342, 432]
        let rowH = 20.0
        let top = y
        for r in table.indices {
            for c in 0..<3 { p1.text(table[r][c], r == 0 ? "F2" : "F1", 11, cols[c] + 6, top + Double(r) * rowH + 14) }
        }
        if ruledTable {
            for r in 0...table.count { p1.line(cols[0], top + Double(r) * rowH, cols[3], top + Double(r) * rowH) }
            for x in cols { p1.line(x, top, x, top + Double(table.count) * rowH) }
        }
        if logo { p1.image("/Icon", cols[0] + 60, top + 2 * rowH + 5, 10, 10) }
        y = top + Double(table.count) * rowH + 30
        p1.image("/Fig", 72, y, 160, 120)
        p1.text("Figure 1. A picture.", "F1", 11, 72, y + 136)

        var p2 = Canvas()
        if logo { p2.image("/Logo", 492, 24, 48, 24) }
        p2.text("Two Columns", "F2", 16, 72, 80)
        _ = p2.wrap("The left column talks about apples and how they grow in orchards on the hills around the town every autumn.", "F1", 11, 72, 110, 216)
        _ = p2.wrap("The right column talks about pears, which ripen later and keep for weeks in a cool dark cellar room.", "F1", 11, 324, 110, 216)
        let made = written([p1, p2])
        cache.made[key] = made
        return made
    }

    /// Pages drawn on `Canvas`es, over the faces and pictures `make` uses. `greek`: also "F4", Arial with codes E1 and E2 as
    /// alpha and beta (PDFsharp writes Unicode text as a composite font; here only those two letters are needed).
    static func written(_ canvases: [Canvas], greek: Bool = false) -> [UInt8] {
        let doc = try! MuDoc.create()
        var fonts: [(String, PObj)] = []
        for (res, name, _, flags, angle) in faces {
            let program = programs[res]!
            let file = doc.addStream(program.bytes, dict: doc.dict([("Length1", doc.int(program.bytes.count))]), deflate: true)
            let descriptor = doc.add(doc.dict([
                ("Type", doc.name("FontDescriptor")), ("FontName", doc.name(name)), ("Flags", doc.int(flags)),
                ("FontBBox", doc.reals(-665, -325, 2000, 1040)), ("ItalicAngle", doc.int(angle)), ("Ascent", doc.int(905)),
                ("Descent", doc.int(212)), ("CapHeight", doc.int(716)), ("StemV", doc.int(80)), ("FontFile2", file),
            ]))
            fonts.append((res, doc.add(doc.dict([
                ("Type", doc.name("Font")), ("Subtype", doc.name("TrueType")), ("BaseFont", doc.name(name)), ("FirstChar", doc.int(32)),
                ("LastChar", doc.int(255)), ("Widths", doc.array(program.widths.map { doc.int($0) })),
                ("Encoding", doc.name("WinAnsiEncoding")), ("FontDescriptor", descriptor),
            ]))))
            if greek && res == "F1" {
                let encoding = doc.dict([("Type", doc.name("Encoding")), ("BaseEncoding", doc.name("WinAnsiEncoding")),
                                         ("Differences", doc.array([doc.int(0xE1), doc.name("alpha"), doc.name("beta")]))])
                fonts.append(("F4", doc.add(doc.dict([
                    ("Type", doc.name("Font")), ("Subtype", doc.name("TrueType")), ("BaseFont", doc.name(name)), ("FirstChar", doc.int(32)),
                    ("LastChar", doc.int(255)), ("Widths", doc.array(program.widths.map { doc.int($0) })),
                    ("Encoding", encoding), ("FontDescriptor", descriptor),
                ]))))
            }
        }
        func rgb(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> PObj {
            var samples: [UInt8] = []
            for yy in 0..<h {
                for x in 0..<w {
                    let (r, g, b) = pixel(x, yy)
                    samples += [r, g, b]
                }
            }
            return ImageImport.imageStream(doc, w, h, samples, "DeviceRGB")
        }
        let xobjects = doc.dict([
            ("Logo", rgb(24, 12) { x, _ in (200, UInt8(x * 10), 40) }), ("Icon", rgb(8, 8) { _, _ in (20, 160, 20) }),
            ("Fig", rgb(40, 30) { x, yy in (UInt8(x * 6), UInt8(yy * 8), 200) }),
        ])
        let resources = doc.dict([("Font", doc.dict(fonts)), ("XObject", xobjects)])
        for (i, canvas) in canvases.enumerated() {
            let page = doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, 612, 792)), ("Resources", resources),
                                 ("Contents", doc.addStream(latin1Bytes(canvas.content), deflate: true))])
            doc.insertPage(doc.add(page), at: i)
        }
        try! doc.checkFailure()
        return try! doc.write("")
    }

    /// Pages without any text (a scan without its text layer, say).
    static func blank(_ pages: Int) -> [UInt8] {
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [\((0..<pages).map { "\(3 + $0) 0 R" }.joined(separator: " "))] /Count \(pages) >>",
        ]
        for i in 0..<pages { objects[3 + i] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>" }
        return Core1TestPdf.build(objects)
    }

    /// An RGB image XObject (ASCII hex, so the file stays text), optionally with a soft mask object number.
    static func image(_ w: Int, _ h: Int, sMask: Int? = nil, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> String {
        var hex = ""
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = pixel(x, y)
                hex += String(format: "%02X%02X%02X", r, g, b)
            }
        }
        let mask = sMask.map { " /SMask \($0) 0 R" } ?? ""
        return Core1TestPdf.stream(hex + ">", "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode\(mask)")
    }

    /// A gray image XObject (a soft mask).
    static func grayImage(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> UInt8) -> String {
        var hex = ""
        for y in 0..<h { for x in 0..<w { hex += String(format: "%02X", pixel(x, y)) } }
        return Core1TestPdf.stream(hex + ">", "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode")
    }

    /// A page's content stream, drawn in PDFsharp's coordinates (points from the top-left; text at its baseline).
    struct Canvas {
        var content = ""

        mutating func text(_ s: String, _ font: String, _ size: Double, _ x: Double, _ y: Double) {
            content += "BT /\(font) \(size) Tf \(x) \(792 - y) Td (\(ExportTestPdf.pdfString(s))) Tj ET\n"
        }

        mutating func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            content += "0.75 w 0 G \(x1) \(792 - y1) m \(x2) \(792 - y2) l S\n"
        }

        mutating func image(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            content += "q \(w) 0 0 \(h) \(x) \(792 - y - h) cm \(name) Do Q\n"
        }

        /// Draws `text` word-wrapped to `width`; returns the baseline after the last line.
        mutating func wrap(_ text: String, _ font: String, _ size: Double, _ x: Double, _ y: Double, _ maxWidth: Double) -> Double {
            var y = y
            var line = ""
            for word in text.split(separator: " ") {
                let next = line.isEmpty ? String(word) : line + " " + word
                if ExportTestPdf.width(next, size, font) > maxWidth && !line.isEmpty {
                    self.text(line, font, size, x, y)
                    y += 14
                    line = String(word)
                } else {
                    line = next
                }
            }
            if !line.isEmpty { self.text(line, font, size, x, y) }
            return y + 14
        }
    }

    /// A PDF string's contents in WinAnsi: parentheses and backslashes escaped, the bullet as its octal code.
    static func pdfString(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "(", ")", "\\": out += "\\" + String(c)
            case "\u{2022}": out += "\\225"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}

/// A .docx or .xlsx read back (the Windows tests use the Open XML SDK): its parts, parsed XML, and the checks that stand
/// in for the SDK's validator (see `ExportTests`).
struct OpenXmlPackage {
    let bytes: [UInt8]
    let parts: [String: [UInt8]]

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        parts = try Self.unzip(bytes)
    }

    func xml(_ part: String) throws -> XMLDocument {
        guard let data = parts[part] else { throw PdfEngineError(message: "No part \(part)") }
        return try XMLDocument(data: Data(data), options: [])
    }

    /// Every element named `name` (with its prefix, "w:p") under `node`, in document order.
    static func elements(_ node: XMLNode, _ name: String) -> [XMLElement] {
        var found: [XMLElement] = []
        func walk(_ n: XMLNode) {
            for child in n.children ?? [] {
                if let e = child as? XMLElement {
                    if e.name == name { found.append(e) }
                    walk(e)
                }
            }
        }
        walk(node)
        return found
    }

    /// The element's child elements named `name`.
    static func children(_ e: XMLElement, _ name: String) -> [XMLElement] {
        (e.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
    }

    static func attr(_ e: XMLElement?, _ name: String) -> String? {
        e?.attributes?.first { $0.name == name }?.stringValue
    }

    /// All the text under the element (Open XML SDK's `InnerText`).
    static func text(_ e: XMLElement) -> String { e.stringValue ?? "" }

    /// The package's targets of the relationships of `part` ("word/document.xml"), by id.
    func relationships(of part: String) throws -> [String: String] {
        let dir = (part as NSString).deletingLastPathComponent
        let relsPart = (dir.isEmpty ? "" : dir + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
        guard parts[relsPart] != nil else { return [:] }
        var result: [String: String] = [:]
        for r in Self.elements(try xml(relsPart), "Relationship") {
            let target = Self.attr(r, "Target") ?? ""
            result[Self.attr(r, "Id") ?? ""] = target.hasPrefix("/") ? String(target.dropFirst())
                : ((dir.isEmpty ? target : dir + "/" + target) as NSString).standardizingPath
        }
        return result
    }

    /// What stands in for the Open XML SDK's validator: every XML part is well formed, every part has a content type,
    /// every relationship points at a part, and `unzip -t` finds the archive sound.
    func validate() throws -> [String] {
        var problems: [String] = []
        let types = try xml("[Content_Types].xml")
        let overrides = Set(Self.elements(types, "Override").compactMap { Self.attr($0, "PartName") })
        let defaults = Set(Self.elements(types, "Default").compactMap { Self.attr($0, "Extension") })
        for (name, data) in parts {
            let ext = name.split(separator: ".").last.map(String.init) ?? "" // "_rels/.rels" too
            if ext == "xml" || ext == "rels" {
                do { _ = try XMLDocument(data: Data(data), options: []) } catch { problems.append("\(name): not well formed") }
            }
            if name != "[Content_Types].xml" && !overrides.contains("/" + name) && !defaults.contains(ext) { problems.append("\(name): no content type") }
            if ext == "rels" {
                let source = name.replacingOccurrences(of: "_rels/", with: "").replacingOccurrences(of: ".rels", with: "")
                for (id, target) in try relationships(of: source) where parts[target] == nil { problems.append("\(name) \(id): no part \(target)") }
            }
        }
        for o in overrides where parts[String(o.dropFirst())] == nil { problems.append("\(o): overridden but missing") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-zip-\(UUID().uuidString).zip")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        if try Self.run("/usr/bin/unzip", ["-tq", url.path]).status != 0 { problems.append("unzip -t failed") }
        return problems
    }

    /// The text `textutil` (Apple's converter, which reads .docx) gets from a Word file.
    static func textutil(_ docx: [UInt8]) throws -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-\(UUID().uuidString).docx")
        try Data(docx).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        return r.status == 0 ? r.output : nil
    }

    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A ZIP's entries (stored or deflated).
    static func unzip(_ b: [UInt8]) throws -> [String: [UInt8]] {
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard b.count >= 22, let end = stride(from: b.count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4B50 }) else {
            throw PdfEngineError(message: "Not a ZIP")
        }
        var at = u32(end + 16)
        var result: [String: [UInt8]] = [:]
        for _ in 0..<u16(end + 10) {
            guard u32(at) == 0x0201_4B50 else { throw PdfEngineError(message: "Bad central directory") }
            let method = u16(at + 10), csize = u32(at + 20), usize = u32(at + 24)
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32), local = u32(at + 42)
            let name = String(decoding: b[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            let dataAt = local + 30 + u16(local + 26) + u16(local + 28)
            let raw = Array(b[dataAt..<(dataAt + csize)])
            result[name] = method == 0 ? raw : try inflate(raw, usize)
            at += 46 + nameLength + extra + comment
        }
        return result
    }

    static func inflate(_ data: [UInt8], _ size: Int) throws -> [UInt8] {
        if size == 0 { return [] }
        var out = [UInt8](repeating: 0, count: size)
        let n = data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw PdfEngineError(message: "Bad deflate data") }
        return out
    }
}

/// A Word file read back.
struct WordDoc {
    let package: OpenXmlPackage
    let document: XMLDocument

    init(_ bytes: [UInt8]) throws {
        package = try OpenXmlPackage(bytes)
        document = try package.xml("word/document.xml")
    }

    var body: XMLElement { OpenXmlPackage.elements(document, "w:body")[0] }

    /// The body's own paragraphs that hold text.
    var bodyParagraphs: [XMLElement] { OpenXmlPackage.children(body, "w:p").filter { !OpenXmlPackage.text($0).isEmpty } }

    var tables: [XMLElement] { OpenXmlPackage.children(body, "w:tbl") }

    var mediaCount: Int { package.parts.keys.filter { $0.hasPrefix("word/media/") }.count }

    static func style(_ p: XMLElement) -> String {
        OpenXmlPackage.attr(OpenXmlPackage.elements(p, "w:pStyle").first, "w:val") ?? ""
    }

    /// Cell texts, row by row.
    static func cells(_ table: XMLElement) -> [[String]] {
        OpenXmlPackage.children(table, "w:tr").map { OpenXmlPackage.children($0, "w:tc").map(OpenXmlPackage.text) }
    }
}

/// Thread-safe list for callbacks (progress).
final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Decodes a PNG written without row filters (as Core's encoder writes them; MuPDF's own PNGs filter rows).
func decodeUnfilteredPng(_ png: [UInt8]) throws -> (width: Int, height: Int, colorType: Int, pixels: [UInt8]) {
    func be32(_ at: Int) -> Int { Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3]) }
    var w = 0, h = 0, type = 0
    var idat: [UInt8] = []
    var at = 8
    while at < png.count {
        let length = be32(at)
        let kind = String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self)
        if kind == "IHDR" {
            (w, h, type) = (be32(at + 8), be32(at + 12), Int(png[at + 17]))
        } else if kind == "IDAT" {
            idat += png[(at + 8)..<(at + 8 + length)]
        }
        at += 12 + length
    }
    let bpp = type == 6 ? 4 : 3
    let raw = try OpenXmlPackage.inflate(Array(idat.dropFirst(2).dropLast(4)), h * (w * bpp + 1))
    var pixels = [UInt8](repeating: 0, count: w * h * bpp)
    for y in 0..<h {
        #expect(raw[y * (w * bpp + 1)] == 0) // no filter
        pixels.replaceSubrange((y * w * bpp)..<((y + 1) * w * bpp), with: raw[(y * (w * bpp + 1) + 1)..<((y + 1) * (w * bpp + 1))])
    }
    return (w, h, type, pixels)
}
