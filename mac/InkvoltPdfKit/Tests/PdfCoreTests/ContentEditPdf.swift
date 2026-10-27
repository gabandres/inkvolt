import Foundation
import Testing
@testable import PdfCore

/// PDFs with hand-written page content for Edit Text & Images (the Windows tests' `ContentEditPdf`). The Windows tests
/// draw their fonts with PDFsharp (Arial, embedded as subsets); here the fonts are written by hand from the system's
/// Arial with every glyph outside `fontText` emptied (`ArialSubset`), as PDFsharp's subsets keep the glyph slots and drop
/// the outlines: /FA is a simple TrueType font (WinAnsi), /FU a Type0 Identity-H font (CIDFontType2, CIDs = glyph ids)
/// with a ToUnicode CMap. /Im1 is a 4 x 2 red image, /Fm1 a form XObject with the given content. Built through MuPDF
/// (`MuDoc.create`), so binary streams need no hand-written cross-reference table.
enum ContentEditPdf {
    static let fontText = "Hello World draft, 2024! Ünï"

    /// - Parameters:
    ///   - formInherits: /Fm1 has no /Resources of its own (it borrows the page's).
    ///   - damagedPart: a last content stream that claims Flate but holds bytes that don't inflate.
    static func make(_ content: String, rotate: Int = 0, form: String? = nil, extraStreams: [String]? = nil, formInherits: Bool = false,
                     damagedPart: Bool = false) -> [UInt8] {
        let doc = try! MuDoc.create()
        let (fa, fu) = fonts(doc)
        let red = [UInt8](repeating: 0, count: 24).enumerated().map { $0.offset % 3 == 0 ? UInt8(255) : 0 }
        let image = ImageImport.imageStream(doc, 4, 2, red, "DeviceRGB")
        let xobjects = doc.dict([("Im1", image)])
        if let form {
            var entries: [(String, PObj)] = [("Type", doc.name("XObject")), ("Subtype", doc.name("Form")), ("BBox", doc.reals(0, 0, 612, 792))]
            if !formInherits {
                entries.append(("Resources", doc.dict([("Font", doc.dict([("FA", fa)])), ("XObject", doc.dict([("Im1", image)]))])))
            }
            xobjects.set("Fm1", doc.addStream(latin1Bytes(form), dict: doc.dict(entries), deflate: false))
        }
        let resources = doc.dict([("Font", doc.dict([("FA", fa), ("FU", fu)])), ("XObject", xobjects)])
        let contents: PObj
        if let extraStreams {
            contents = doc.array(([content] + extraStreams).map { doc.addStream(latin1Bytes($0), deflate: false) })
            if damagedPart {
                let bad: [UInt8] = [0x78, 0x9C, 0xFF, 0xFE, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
                contents.append(doc.addStream(bad, dict: doc.dict([("Filter", doc.name("FlateDecode"))]), deflate: false))
            }
        } else {
            contents = doc.addStream(latin1Bytes(content), deflate: true)
        }
        var page: [(String, PObj)] = [("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, 612, 792)), ("Resources", resources),
                                      ("Contents", contents)]
        if rotate != 0 { page.append(("Rotate", doc.int(rotate))) }
        doc.insertPage(doc.add(doc.dict(page)), at: 0)
        try! doc.checkFailure()
        return try! doc.write("")
    }

    /// /FA and /FU (references), sharing one descriptor and font program.
    private static func fonts(_ doc: MuDoc) -> (PObj, PObj) {
        let font = ArialSubset.shared
        let program = doc.addStream(font.bytes, dict: doc.dict([("Length1", doc.int(font.bytes.count))]), deflate: true)
        let descriptor = doc.add(doc.dict([
            ("Type", doc.name("FontDescriptor")), ("FontName", doc.name("AAAAAA+ArialMT")), ("Flags", doc.int(32)),
            ("FontBBox", doc.reals(-665, -325, 2000, 1040)), ("ItalicAngle", doc.int(0)), ("Ascent", doc.int(905)),
            ("Descent", doc.int(-212)), ("CapHeight", doc.int(716)), ("StemV", doc.int(80)), ("FontFile2", program),
        ]))
        let widths = (32...255).map { code -> PObj in
            let text = GlyphNames.inEncoding("WinAnsiEncoding", code).flatMap(GlyphNames.toUnicode)
            return doc.int(text.map { font.width(font.gid(Int($0.unicodeScalars.first!.value))) } ?? 0)
        }
        let fa = doc.add(doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("TrueType")), ("BaseFont", doc.name("AAAAAA+ArialMT")),
            ("FirstChar", doc.int(32)), ("LastChar", doc.int(255)), ("Widths", doc.array(widths)),
            ("Encoding", doc.name("WinAnsiEncoding")), ("FontDescriptor", descriptor),
        ]))
        let gids = Set(fontText.unicodeScalars.map { font.gid(Int($0.value)) }).sorted()
        var w: [PObj] = []
        for g in gids {
            w.append(doc.int(g))
            w.append(doc.array([doc.int(font.width(g))]))
        }
        var cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            + "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
            + "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n\(gids.count) beginbfrange\n"
        for g in gids {
            let ch = fontText.unicodeScalars.first { font.gid(Int($0.value)) == g }!
            cmap += String(format: "<%04X> <%04X> <%04X>\n", g, g, ch.value)
        }
        cmap += "endbfrange\nendcmap\nCMapName currentdict /CMapResource defineresource pop\nend\nend\n"
        let cid = doc.add(doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("CIDFontType2")), ("BaseFont", doc.name("AAAAAA+ArialMT")),
            ("CIDSystemInfo", doc.dict([("Registry", doc.string(Array("Adobe".utf8))), ("Ordering", doc.string(Array("Identity".utf8))),
                                        ("Supplement", doc.int(0))])),
            ("FontDescriptor", descriptor), ("DW", doc.int(1000)), ("W", doc.array(w)), ("CIDToGIDMap", doc.name("Identity")),
        ]))
        let fu = doc.add(doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("Type0")), ("BaseFont", doc.name("AAAAAA+ArialMT")),
            ("Encoding", doc.name("Identity-H")), ("DescendantFonts", doc.array([cid])),
            ("ToUnicode", doc.addStream(Array(cmap.utf8), deflate: true)),
        ]))
        return (fa, fu)
    }

    /// The same PDF with the space taken out of /FU's ToUnicode CMap.
    static func withoutSpace(_ pdf: [UInt8]) -> [UInt8] {
        let doc = try! Core2Pdf.open(pdf)
        let tu = doc.page(0).dict("Resources")!.dict("Font")!.dict("FU")!.dict("ToUnicode")!
        let cmap = latin1String(tu.streamData!)
        let cut = cmap.replacingOccurrences(of: #"<0003>\s*<0003>\s*<0020>\s*"#, with: "", options: .regularExpression)
        #expect(cut != cmap)
        tu.setStream(latin1Bytes(cut), deflate: false)
        try! doc.checkFailure()
        return try! doc.write("")
    }

    /// The page's content (all streams, decoded) as text.
    static func content(_ pdf: [UInt8], page: Int = 0) -> String {
        let doc = try! Core2Pdf.open(pdf)
        return latin1String(ContentEditor.contentBytes(doc.page(page)))
    }

    static func text(_ pdf: [UInt8], page: Int = 0) -> String {
        let engine = try! PdfEngine.open(pdf)
        defer { engine.close() }
        return try! engine.text(page, cache: false).text
    }

    /// A string in the Unicode font /FU (glyph ids of the subset), as a hex string. (The Windows helper encodes it with
    /// the font of a seed PDF; the subset here is the same for every PDF.)
    static func cid(_ text: String) -> String {
        let font = ArialSubset.shared
        return "<" + text.unicodeScalars.map { String(format: "%04X", font.gid(Int($0.value))) }.joined() + ">"
    }
}

/// The system's Arial with every glyph but those of `ContentEditPdf.fontText` (and the glyphs they are built from)
/// emptied, as PDFsharp writes its subsets: the glyph ids and the cmap stay, the outlines of unused glyphs go.
final class ArialSubset: Sendable {
    static let shared = ArialSubset()

    let bytes: [UInt8]
    private let program: TrueTypeProgram

    private init() {
        let path = "/System/Library/Fonts/Supplemental/Arial.ttf"
        let full = Array(try! Data(contentsOf: URL(fileURLWithPath: path)))
        let source = TrueTypeProgram.read(full)!
        let keep = Set([0] + ContentEditPdf.fontText.unicodeScalars.map { source.lookupUnicode(Int($0.value)) })
        bytes = Self.subset(full, keep)
        program = TrueTypeProgram.read(bytes)!
    }

    func gid(_ cp: Int) -> Int { program.lookupUnicode(cp) }

    /// A glyph's advance in thousandths of an em, rounded (PDFsharp's widths).
    func width(_ gid: Int) -> Int { Int((program.advance(gid) ?? 0).rounded()) }

    private static func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
    private static func u32(_ b: [UInt8], _ at: Int) -> Int { u16(b, at) << 16 | u16(b, at + 2) }
    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
    private static func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xFFFF) }

    /// The font with only `keep` (and their components) left in glyf, a long loca, and the tables viewers need.
    private static func subset(_ b: [UInt8], _ keepGlyphs: Set<Int>) -> [UInt8] {
        let tables = TrueTypeProgram.tables(b)!
        let head = tables["head"]!, maxp = tables["maxp"]!, loca = tables["loca"]!, glyf = tables["glyf"]!
        let numGlyphs = u16(b, maxp.offset + 4)
        let long = u16(b, head.offset + 50) == 1
        let offsets = (0...numGlyphs).map { long ? u32(b, loca.offset + 4 * $0) : 2 * u16(b, loca.offset + 2 * $0) }
        func data(_ g: Int) -> ArraySlice<UInt8> { b[glyf.offset + offsets[g]..<glyf.offset + offsets[g + 1]] }
        // Composite glyphs bring their components.
        var keep = keepGlyphs
        var queue = Array(keepGlyphs)
        while let g = queue.popLast() {
            let d = Array(data(g))
            guard d.count > 10, Int16(bitPattern: UInt16(u16(d, 0))) < 0 else { continue }
            var p = 10
            while p + 4 <= d.count {
                let flags = u16(d, p), component = u16(d, p + 2)
                if keep.insert(component).inserted { queue.append(component) }
                p += 4 + (flags & 1 != 0 ? 4 : 2) + (flags & 8 != 0 ? 2 : flags & 0x40 != 0 ? 4 : flags & 0x80 != 0 ? 8 : 0)
                if flags & 0x20 == 0 { break }
            }
        }
        var newGlyf: [UInt8] = []
        var newLoca: [UInt8] = []
        for g in 0..<numGlyphs {
            newLoca += be32(newGlyf.count)
            if keep.contains(g) {
                newGlyf += data(g)
                while newGlyf.count % 4 != 0 { newGlyf.append(0) }
            }
        }
        newLoca += be32(newGlyf.count)
        var newHead = Array(b[head.offset..<head.offset + head.length])
        newHead[50] = 0
        newHead[51] = 1
        let wanted = ["OS/2", "cmap", "cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post", "prep"]
        let tags = wanted.filter { tables[$0] != nil }
        var bodies: [(String, [UInt8])] = []
        for tag in tags {
            switch tag {
            case "glyf": bodies.append((tag, newGlyf))
            case "loca": bodies.append((tag, newLoca))
            case "head": bodies.append((tag, newHead))
            default:
                let t = tables[tag]!
                bodies.append((tag, Array(b[t.offset..<t.offset + t.length])))
            }
        }
        var out: [UInt8] = [0, 1, 0, 0] + be16(tags.count) + be16(0) + be16(0) + be16(0)
        var at = 12 + 16 * tags.count
        var tail: [UInt8] = []
        for (tag, body) in bodies {
            out += Array(tag.utf8) + be32(0) + be32(at) + be32(body.count)
            tail += body
            while tail.count % 4 != 0 { tail.append(0) }
            at = 12 + 16 * tags.count + tail.count
        }
        return out + tail
    }
}
