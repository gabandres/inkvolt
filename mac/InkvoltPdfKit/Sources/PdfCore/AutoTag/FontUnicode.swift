import Foundation

/// Gives characters without a Unicode value one (Matterhorn 31-027, veraPDF 7.21.7-1), so screen readers can read them
/// (the Windows app's `FontUnicode`): each font the pages, their forms and their annotations' appearances use, whose codes
/// have no ToUnicode entry and no glyph name the Adobe Glyph List knows, gets a ToUnicode CMap with every code it can tell:
/// TeX's glyph names and math encodings (`TexGlyphs`: the pdfTeX papers' CMEX, CMSY and CMMI glyphs), and a composite font's
/// empty glyphs as spaces. What a code already said stays as it was. Make Accessible runs it.
enum FontUnicode {
    /// Completes every font that needs it; returns how many were given (or had completed) a ToUnicode.
    @discardableResult
    static func complete(_ doc: MuDoc) throws -> Int {
        var fonts: [PObj] = []
        var seen = Set<UInt>()
        func resources(_ res: PObj?, _ depth: Int) {
            guard let res, depth <= 16, seen.insert(res.identity).inserted else { return }
            if let fs = res.dict("Font") {
                for key in fs.keys {
                    guard let f = fs.dict(key), seen.insert(f.identity).inserted else { continue }
                    fonts.append(f)
                    resources(f.dict("Resources"), depth + 1) // a Type 3 font's glyphs
                }
            }
            if let xs = res.dict("XObject") {
                for key in xs.keys {
                    if let x = xs.dict(key), x.name("Subtype") == "Form" { resources(x.dict("Resources"), depth + 1) }
                }
            }
            if let ps = res.dict("Pattern") {
                for key in ps.keys {
                    if let pattern = ps.dict(key) { resources(pattern.dict("Resources"), depth + 1) }
                }
            }
        }
        for page in try doc.pages() {
            resources(AutoTag.resources(page), 0)
            for annot in page.array("Annots")?.elements ?? [] where annot.isDict {
                guard let ap = annot.dict("AP") else { continue }
                for kind in ["N", "R", "D"] {
                    guard let n = ap.dict(kind) else { continue }
                    if n.isStream {
                        resources(n.dict("Resources"), 1)
                    } else {
                        for key in n.keys {
                            if let st = n.dict(key), st.isStream { resources(st.dict("Resources"), 1) }
                        }
                    }
                }
            }
        }
        return fonts.reduce(0) { $0 + (complete(doc, $1) ? 1 : 0) }
    }

    /// Gives one font a ToUnicode with the codes it couldn't tell before; false when none was missing (or none can be told).
    private static func complete(_ doc: MuDoc, _ font: PObj) -> Bool {
        let tf = TextFont(font)
        let subtype = font.name("Subtype")
        var map: [Int: String] = [:]
        var added = false
        if subtype == "Type1" || subtype == "MMType1" || subtype == "TrueType" || subtype == "Type3" {
            let baseFont = font.name("BaseFont") ?? ""
            // A Type 1 font without an Encoding whose program's encoding isn't read: a TeX math font's codes are its own
            // encoding's (OML, OMS, OMX), whatever StandardEncoding would say.
            let own = (subtype == "Type1" || subtype == "MMType1") && !font.has("Encoding") && !(tf.program is Type1Program)
                && TexGlyphs.nameIn(baseFont, 0) != nil
            for c in 0..<256 {
                if let had = tf.toUnicodeOf(c) {
                    map[c] = had
                    continue
                }
                if own {
                    if let texName = TexGlyphs.nameIn(baseFont, c), let t = TexGlyphs.toUnicode(texName) {
                        map[c] = t
                        added = true
                    }
                    continue
                }
                if let known = tf.unicodeOf(c) {
                    map[c] = known
                } else if let g = tf.glyphNameOf(c), g != ".notdef", let tex = TexGlyphs.toUnicode(g) {
                    map[c] = tex
                    added = true
                }
            }
            if !added { return false }
            font.set("ToUnicode", doc.addStream(cmap(map, 1), deflate: true))
            return true
        }
        let encoding = font.name("Encoding")
        guard subtype == "Type0", encoding == "Identity-H" || encoding == "Identity-V",
              let cid = font.array("DescendantFonts")?[0], cid.isDict,
              let cff = FontProgram.load(cid.dict("FontDescriptor")) as? CffProgram else { return false }
        // A CFF program (CIDFontType0): with Identity the codes are the CIDs, glyph indices in a name-keyed program.
        for (code, text) in tf.toUnicodeMap { map[code] = text }
        let glyphs = cff.isCid ? cff.cidList : Array(stride(from: 1, to: max(1, cff.numGlyphs), by: 1))
        for g in glyphs where map[g] == nil {
            guard let text = cff.nameOfGlyph(g).flatMap(TexGlyphs.toUnicode) ?? (cff.isBlank(g) ? " " : nil) else { continue }
            map[g] = text
            added = true
        }
        if !added { return false }
        font.set("ToUnicode", doc.addStream(cmap(map, 2), deflate: true))
        return true
    }

    /// A ToUnicode CMap of one- or two-byte codes.
    static func cmap(_ map: [Int: String], _ bytes: Int) -> [UInt8] {
        let format = bytes == 1 ? "%02X" : "%04X"
        var s = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        s += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        s += bytes == 1 ? "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" : "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        let entries = map.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        var at = 0
        while at < entries.count {
            let chunk = entries[at..<min(at + 100, entries.count)]
            s += "\(chunk.count) beginbfchar\n"
            for (code, text) in chunk {
                let hex = text.utf16.map { String(format: "%04X", $0) }.joined()
                s += "<\(String(format: format, code))> <\(hex)>\n"
            }
            s += "endbfchar\n"
            at += 100
        }
        s += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Array(s.utf8)
    }
}
