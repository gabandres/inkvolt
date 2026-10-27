import Foundation

/// A TrueType font whose glyphs draw nothing (the text layer's font; Tesseract and OCRmyPDF use the same idea): two
/// empty glyphs, each half an em wide, ascent 0.8 and descent 0.2 of an em. Every code maps to glyph 1, so the font
/// serves any script; /ToUnicode gives the text. Nothing can show even in a viewer that ignores render mode 3, and the
/// font program is a few hundred bytes, embedded once per document.
enum GlyphlessFont {
    static let name = "InkvoltGlyphless"
    /// In thousandths of an em.
    static let advance = 500, ascent = 800, descent = -200

    /// The font file (an sfnt with the tables FreeType and Core Graphics expect).
    static let program: [UInt8] = build()

    private static func build() -> [UInt8] {
        let head: [UInt8] = be32(0x0001_0000) + be32(0x0001_0000) + be32(0) /* checkSumAdjustment, set below */ + be32(0x5F0F_3CF5)
            + be16(0x000B) + be16(1000) + [UInt8](repeating: 0, count: 16) /* created, modified */
            + be16(0) + be16(descent) + be16(advance) + be16(ascent) /* xMin yMin xMax yMax */
            + be16(0) + be16(3) + be16(2) + be16(0) /* short loca */ + be16(0)
        let hhea: [UInt8] = be32(0x0001_0000) + be16(ascent) + be16(descent) + be16(0) + be16(advance) + be16(0) + be16(0)
            + be16(0) + be16(1) + be16(0) + be16(0) + [UInt8](repeating: 0, count: 8) + be16(0) + be16(2)
        let maxp: [UInt8] = be32(0x0001_0000) + be16(2) + [UInt8](repeating: 0, count: 8) + be16(2)
            + [UInt8](repeating: 0, count: 16)
        let hmtx: [UInt8] = be16(advance) + be16(0) + be16(advance) + be16(0)
        let loca: [UInt8] = be16(0) + be16(0) + be16(0)
        let glyf: [UInt8] = [0, 0, 0, 0]
        // A format 4 subtable with only its closing segment: no character codes (the PDF maps codes to glyphs).
        let cmap: [UInt8] = be16(0) + be16(1) + be16(3) + be16(1) + be32(12)
            + be16(4) + be16(24) + be16(0) + be16(2) + be16(2) + be16(0) + be16(0)
            + be16(0xFFFF) + be16(0) + be16(0xFFFF) + be16(1) + be16(0)
        var os2: [UInt8] = be16(3) + be16(advance) + be16(400) + be16(5) + be16(0)
        os2 += be16(650) + be16(600) + be16(0) + be16(75) + be16(650) + be16(600) + be16(0) + be16(350) + be16(50) + be16(300)
        os2 += be16(0) + [UInt8](repeating: 0, count: 10) + [UInt8](repeating: 0, count: 16) + Array("INKV".utf8)
        os2 += be16(0x40) + be16(0x20) + be16(0xFFFF) + be16(ascent) + be16(descent) + be16(0) + be16(ascent) + be16(-descent)
        os2 += be32(1) + be32(0) + be16(500) + be16(700) + be16(0) + be16(32) + be16(0)
        let post: [UInt8] = be32(0x0003_0000) + be32(0) + be16(-100) + be16(50) + be32(0) + [UInt8](repeating: 0, count: 16)
        let names = [(1, name), (2, "Regular"), (3, name), (4, name), (6, name)]
        var nameTable = be16(0) + be16(names.count) + be16(6 + 12 * names.count)
        var strings: [UInt8] = []
        for (id, s) in names {
            let bytes = s.utf16.flatMap { be16(Int($0)) }
            nameTable += be16(3) + be16(1) + be16(0x409) + be16(id) + be16(bytes.count) + be16(strings.count)
            strings += bytes
        }
        nameTable += strings

        let tables: [(String, [UInt8])] = [("OS/2", os2), ("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea),
                                           ("hmtx", hmtx), ("loca", loca), ("maxp", maxp), ("name", nameTable), ("post", post)]
        var out = be32(0x0001_0000) + be16(tables.count) + be16(128) + be16(3) + be16(tables.count * 16 - 128)
        var offset = 12 + 16 * tables.count
        var body: [UInt8] = []
        var headAt = 0
        for (tag, data) in tables {
            if tag == "head" { headAt = offset }
            out += Array(tag.utf8) + be32(checksum(data)) + be32(offset) + be32(data.count)
            let padded = data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
            body += padded
            offset += padded.count
        }
        out += body
        let adjust = 0xB1B0_AFBA &- checksum(out)
        out.replaceSubrange(headAt + 8..<headAt + 12, with: be32(Int(adjust)))
        return out
    }

    private static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < data.count {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | UInt32(i + k < data.count ? data[i + k] : 0) }
            sum = sum &+ word
            i += 4
        }
        return sum
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 255), UInt8(v & 255)] }
    private static func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xFFFF) }
    private static func be32(_ v: UInt32) -> [UInt8] { be32(Int(v)) }

    /// The document's shared objects: the descendant CIDFont (every code to glyph 1) with the embedded program. Each
    /// page's Type 0 font adds its own /ToUnicode.
    static func descendant(_ doc: MuDoc) -> PObj {
        let file = doc.addStream(program, dict: doc.dict([("Length1", doc.int(program.count))]), deflate: true)
        var map = [UInt8](repeating: 0, count: 65536 * 2)
        for cid in 1..<65536 { map[cid * 2 + 1] = 1 }
        let descriptor = doc.add(doc.dict([
            ("Type", doc.name("FontDescriptor")), ("FontName", doc.name(name)), ("Flags", doc.int(4)),
            ("FontBBox", doc.array([doc.int(0), doc.int(descent), doc.int(advance), doc.int(ascent)])),
            ("ItalicAngle", doc.int(0)), ("Ascent", doc.int(ascent)), ("Descent", doc.int(descent)),
            ("CapHeight", doc.int(700)), ("StemV", doc.int(80)), ("FontFile2", file),
        ]))
        return doc.add(doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("CIDFontType2")), ("BaseFont", doc.name(name)),
            ("CIDSystemInfo", doc.dict([("Registry", doc.text("Adobe")), ("Ordering", doc.text("Identity")), ("Supplement", doc.int(0))])),
            ("FontDescriptor", descriptor), ("DW", doc.int(advance)),
            ("CIDToGIDMap", doc.addStream(map, deflate: true)),
        ]))
    }

    /// A page's font: the shared descendant with /ToUnicode for the page's codes (code n is `units[n - 1]`).
    static func font(_ doc: MuDoc, _ descendant: PObj, _ units: [String]) -> PObj {
        var cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        cmap += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        cmap += "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        var at = 0
        while at < units.count {
            let end = min(at + 100, units.count)
            cmap += "\(end - at) beginbfchar\n"
            for i in at..<end { cmap += "<\(hex4(i + 1))> <\(units[i].utf16.map { hex4(Int($0)) }.joined())>\n" }
            cmap += "endbfchar\n"
            at = end
        }
        cmap += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return doc.add(doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("Type0")), ("BaseFont", doc.name(name)),
            ("Encoding", doc.name("Identity-H")), ("DescendantFonts", doc.array([descendant])),
            ("ToUnicode", doc.addStream(Array(cmap.utf8), deflate: true)),
        ]))
    }

    static func hex4(_ v: Int) -> String { String(format: "%04X", v) }
}
