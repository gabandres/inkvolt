import Foundation

extension PdfA.Pass {
    func fonts() {
        // The form's default resources only serve to draw fields anew: a font there that can't be embedded is dropped
        // (the fields keep their appearances), not a reason to refuse.
        let dr = doc.catalog.dict("AcroForm")?.dict("DR")?.dict("Font")
        let used = allFonts(dr)
        let usedIds = Set(used.map(\.identity))
        if let dr {
            for key in dr.keys {
                guard let f = dr.dict(key), !usedIds.contains(f.identity) else { continue }
                let sub = f.name("Subtype") ?? ""
                if sub == "Type3" || Self.isEmbedded(f.dict("FontDescriptor")) ||
                    sub == "Type0" && Self.isEmbedded(f.array("DescendantFonts")?[0]?.dict("FontDescriptor")) { continue }
                if Self.isDingbats(Self.fontName(f)) || substitute(f) != nil { dr.remove(key) }
            }
        }
        for font in used {
            let subtype = font.name("Subtype") ?? ""
            if subtype == "Type3" { continue }
            if subtype == "Type0" {
                if !Self.isEmbedded(font.array("DescendantFonts")?[0]?.dict("FontDescriptor")) {
                    block("The font \(Self.fontName(font)) isn't embedded, and only the standard fonts can be embedded here.")
                }
                continue
            }
            if Self.isEmbedded(font.dict("FontDescriptor")) { continue }
            if let why = substitute(font) { block(why) }
        }
    }

    static func fontName(_ font: PObj) -> String { font.name("BaseFont") ?? "(unnamed)" }

    private static func isDingbats(_ baseFont: String) -> Bool {
        let c = Array(baseFont.utf8)
        return c.count > 7 && c[6] == 0x2B ? String(baseFont.dropFirst(7)) == "ZapfDingbats" : baseFont == "ZapfDingbats"
    }

    static func isEmbedded(_ descriptor: PObj?) -> Bool {
        guard let descriptor else { return false }
        return descriptor.has("FontFile") || descriptor.has("FontFile2") || descriptor.has("FontFile3")
    }

    /// Font dictionaries in the /Font resource dictionaries reachable from the catalog other than `defaults` (the form's
    /// default resources), i.e. the fonts that content and appearances can draw with; each once, in the order found.
    private func allFonts(_ defaults: PObj?) -> [PObj] {
        var fonts: [PObj] = []
        var seen = Set<UInt>()
        walk(doc.catalog) { d in
            guard let resources = d.dict("Font"), resources.identity != defaults?.identity else { return }
            let type = d.name("Type")
            guard type == nil || type == "Resources" else { return }
            for key in resources.keys {
                guard let f = resources.dict(key), seen.insert(f.identity).inserted else { continue }
                let sub = f.name("Subtype")
                if sub != "CIDFontType0" && sub != "CIDFontType2" { fonts.append(f) }
            }
        }
        return fonts
    }

    /// Embeds a non-embedded standard Latin font (`PdfA.standardFace`: Helvetica, Times, Courier and their Windows twins,
    /// in their style) as a TrueType subset of the metric-compatible system face, encoded WinAnsi with differences for the
    /// codes the original encoding maps elsewhere. Nil when done, else why it can't be: another font, the system face
    /// missing, or widths in the document that differ from that face's.
    private func substitute(_ font: PObj) -> String? {
        let subtype = font.name("Subtype")
        let name = font.name("BaseFont") ?? ""
        if Self.isDingbats(name) { return embedDingbats(font) }
        let notEmbedded = "The font \(Self.fontName(font)) isn't embedded, and only the standard Helvetica, Times, Courier and ZapfDingbats faces can be embedded here."
        guard subtype == "Type1" || subtype == "TrueType" || subtype == "MMType1", let std = PdfA.standardFace(name) else { return notEmbedded }
        guard let ttf = std.metrics, let fileData = ttf.fileData else { return "The font \(Self.fontName(font)) isn't embedded, and the Mac's matching font isn't installed." }

        // The original code → glyph name map (its encoding, else StandardEncoding as the standard fonts have).
        let names = Self.glyphNames(font)

        // Unicode of each code, kept only when the system font has the glyph.
        var unicodes = [UInt32](repeating: 0, count: 256)
        for c in 0..<256 {
            guard let gn = names[c], let u = GlyphNames.toUnicode(gn), u.unicodeScalars.count == 1, let cp = u.unicodeScalars.first?.value,
                  ttf.has(cp) else { continue }
            unicodes[c] = cp
        }
        var used: [UInt32] = []
        for u in unicodes where u > 0 && !used.contains(u) { used.append(u) }
        if used.isEmpty { return notEmbedded }

        // The document's own widths (where it has them) must be the system face's, or the text would move.
        if let own = font.array("Widths") {
            let firstOwn = font.int("FirstChar") ?? 0
            for i in 0..<own.count {
                let code = firstOwn + i
                let w = own.num(i)
                if code < 0 || code > 255 || unicodes[code] == 0 || w <= 0 { continue }
                if abs(w - ttf.advance(unicodes[code]) * 1000) > 20 {
                    return "The font \(Self.fontName(font)) isn't embedded, and its letter widths differ from \(Self.faceName(std)), so the text would move."
                }
            }
        }
        guard let program = TrueTypeSubset.subset(fileData, used.map { ($0, ttf.glyphOf($0)) }) else { return notEmbedded }

        let differences = doc.array()
        for c in 0..<256 where unicodes[c] != 0 {
            if GlyphNames.inEncoding("WinAnsiEncoding", c) == names[c] { continue }
            differences.append(doc.int(c))
            differences.append(doc.name(names[c]!))
        }
        let first = unicodes.firstIndex { $0 > 0 }!
        let last = unicodes.lastIndex { $0 > 0 }!
        let widths = doc.array((first...last).map { c in doc.int(unicodes[c] > 0 ? Int((ttf.advance(unicodes[c]) * 1000).rounded(.toNearestOrEven)) : 0) })

        let tag = Self.tag(name + used.map(String.init).joined(separator: ","))
        let style = std.bold ? (std.italic ? "-BoldItalic" : "-Bold") : (std.italic ? "-Italic" : "")
        let postScript = (std.family == .times ? "TimesNewRoman" : std.family == .courier ? "CourierNew" : "Arial") + style
        let baseFont = "\(tag)+\(postScript)"
        let file = doc.addStream(program, dict: doc.dict([("Length1", doc.int(program.count))]), deflate: true)
        func em(_ units: Double) -> Double { (units * 1000 / ttf.unitsPerEm).rounded(.toNearestOrEven) }
        var flags = 32
        if std.family == .courier { flags |= 1 }
        if std.family == .times { flags |= 2 }
        if std.italic { flags |= 64 }
        let descriptor = doc.add(doc.dict([
            ("Type", doc.name("FontDescriptor")),
            ("FontName", doc.name(baseFont)),
            ("Flags", doc.int(flags)),
            ("FontBBox", doc.reals(em(ttf.bbox[0]), em(ttf.bbox[1]), em(ttf.bbox[2]), em(ttf.bbox[3]))),
            ("ItalicAngle", doc.int(std.italic ? -12 : 0)),
            ("Ascent", doc.int(Int((ttf.ascent * 1000).rounded(.toNearestOrEven)))),
            ("Descent", doc.int(Int((ttf.descent * 1000).rounded(.toNearestOrEven)))),
            ("CapHeight", doc.int(Int((ttf.ascent * 1000 * 0.9).rounded(.toNearestOrEven)))),
            ("StemV", doc.int(std.bold ? 120 : 80)),
            ("FontFile2", file),
        ]))

        font.set("Subtype", doc.name("TrueType"))
        font.set("BaseFont", doc.name(baseFont))
        font.set("FirstChar", doc.int(first))
        font.set("LastChar", doc.int(last))
        font.set("Widths", widths)
        font.set("FontDescriptor", descriptor)
        if differences.count == 0 {
            font.set("Encoding", doc.name("WinAnsiEncoding"))
        } else {
            font.set("Encoding", doc.dict([("Type", doc.name("Encoding")), ("BaseEncoding", doc.name("WinAnsiEncoding")), ("Differences", differences)]))
        }
        noteEmbedded()
        return nil
    }

    /// The Unicode value of a code in ZapfDingbats' built-in encoding (Adobe's zdingbat.txt), else 0.
    static func dingbatUnicode(_ code: Int) -> UInt32 {
        switch code {
        case 0x25: 0x260E
        case 0x2A: 0x261B
        case 0x2B: 0x261E
        case 0x48: 0x2605
        case 0x6C: 0x25CF
        case 0x6E: 0x25A0
        case 0x73: 0x25B2
        case 0x74: 0x25BC
        case 0x75: 0x25C6
        case 0x77: 0x25D7
        case 0xA8: 0x2663
        case 0xA9: 0x2666
        case 0xAA: 0x2665
        case 0xAB: 0x2660
        case 0xD5: 0x2192
        case 0xD6: 0x2194
        case 0xD7: 0x2195
        case 0xAC...0xB5: UInt32(0x2460 + code - 0xAC)
        case 0x21...0x7E: UInt32(0x2700 + code - 0x20)
        case 0xA1...0xFE where code != 0xF0: UInt32(0x26C0 + code)
        default: 0
        }
    }

    /// Embeds ZapfDingbats (a Fill & Sign mark, an Acrobat form's check box) from the ZapfDingbats.ttf macOS ships, which has
    /// every symbol of the built-in encoding, at Adobe's widths, and whose embedding bits allow it (Windows has no such font
    /// and uses Segoe UI Symbol). PDF/A accepts only the Adobe Glyph List's names in a TrueType font's differences and these
    /// symbols aren't there, so the font is symbolic: no encoding, its codes in a (3,0) cmap, its text in a ToUnicode. Nil when
    /// done, else why it can't be.
    private func embedDingbats(_ font: PObj) -> String? {
        let name = Self.fontName(font)
        let subtype = font.name("Subtype")
        if subtype != "Type1" && subtype != "TrueType" && subtype != "MMType1" || font.has("Encoding") {
            return "The font \(name) isn't embedded, and it has an encoding of its own, so its symbols can't be matched."
        }
        guard let ttf = SystemFonts.get("ZapfDingbats.ttf"), let fileData = ttf.fileData else {
            return "The font \(name) isn't embedded, and macOS's ZapfDingbats, which has its symbols, isn't installed."
        }
        guard TrueTypeSubset.allowsEmbedding(fileData) else {
            return "The font \(name) isn't embedded, and macOS's ZapfDingbats doesn't allow embedding."
        }
        var unicodes = (0..<256).map { c -> UInt32 in
            let u = Self.dingbatUnicode(c)
            return u > 0 && ttf.has(u) ? u : 0
        }
        unicodes[0x20] = 0x20
        if let own = font.array("Widths") {
            let firstOwn = font.int("FirstChar") ?? 0
            for i in 0..<own.count {
                let code = firstOwn + i
                let w = own.num(i)
                if code < 0 || code > 255 || unicodes[code] == 0 || w <= 0 { continue }
                if abs(w - ttf.advance(unicodes[code]) * 1000) > 20 {
                    return "The font \(name) isn't embedded, and its symbols' widths differ from macOS's ZapfDingbats, so they would move."
                }
            }
        }
        let codes = (0..<256).filter { unicodes[$0] > 0 }
        guard let program = TrueTypeSubset.subset(fileData, codes.map { (UInt32(0xF000 + $0), ttf.glyphOf(unicodes[$0])) }, symbolic: true),
              let first = codes.first, let last = codes.last else {
            return "The font \(name) isn't embedded, and macOS's ZapfDingbats couldn't be cut down to its symbols."
        }
        let file = doc.addStream(program, dict: doc.dict([("Length1", doc.int(program.count))]), deflate: true)
        let baseFont = "\(Self.tag(name + codes.map(String.init).joined(separator: ",")))+ZapfDingbatsITC"
        func em(_ units: Double) -> Double { (units * 1000 / ttf.unitsPerEm).rounded(.toNearestOrEven) }
        let descriptor = doc.add(doc.dict([
            ("Type", doc.name("FontDescriptor")),
            ("FontName", doc.name(baseFont)),
            ("Flags", doc.int(4)),
            ("FontBBox", doc.reals(em(ttf.bbox[0]), em(ttf.bbox[1]), em(ttf.bbox[2]), em(ttf.bbox[3]))),
            ("ItalicAngle", doc.int(0)),
            ("Ascent", doc.int(Int((ttf.ascent * 1000).rounded(.toNearestOrEven)))),
            ("Descent", doc.int(Int((ttf.descent * 1000).rounded(.toNearestOrEven)))),
            ("CapHeight", doc.int(Int((ttf.ascent * 1000 * 0.9).rounded(.toNearestOrEven)))),
            ("StemV", doc.int(80)),
            ("FontFile2", file),
        ]))
        let widths = doc.array((first...last).map { c in doc.int(unicodes[c] > 0 ? Int((ttf.advance(unicodes[c]) * 1000).rounded(.toNearestOrEven)) : 0) })
        var text: [Int: String] = [:]
        for c in codes { if let u = Unicode.Scalar(unicodes[c]) { text[c] = String(Character(u)) } }
        font.set("Subtype", doc.name("TrueType"))
        font.set("BaseFont", doc.name(baseFont))
        font.set("FirstChar", doc.int(first))
        font.set("LastChar", doc.int(last))
        font.set("Widths", widths)
        font.set("FontDescriptor", descriptor)
        font.set("ToUnicode", doc.addStream(FontUnicode.cmap(text, 1), deflate: true))
        noteDingbats()
        return nil
    }

    /// Each code's glyph name: the font's encoding (a name, or a dictionary with differences), else StandardEncoding.
    private static func glyphNames(_ font: PObj) -> [String?] {
        let enc = font["Encoding"]
        var base = enc?.kind == .name ? enc?.name ?? "StandardEncoding" : enc?.isDict == true ? enc?.name("BaseEncoding") ?? "StandardEncoding" : "StandardEncoding"
        if !GlyphNames.isKnownEncoding(base) { base = "StandardEncoding" }
        var names = (0..<256).map { GlyphNames.inEncoding(base, $0) }
        if let enc, enc.isDict, let diffs = enc.array("Differences") {
            var code = 0
            for item in diffs.elements {
                if let n = item.number {
                    code = Int(n)
                } else if let gn = item.name, code >= 0 && code < 256 {
                    names[code] = gn
                    code += 1
                }
            }
        }
        return names
    }

    private static func faceName(_ std: StdFont) -> String {
        let family = std.family == .times ? "Times New Roman" : std.family == .courier ? "Courier New" : "Arial"
        return "\(family)\(std.bold ? " Bold" : "")\(std.italic ? " Italic" : "")"
    }

    /// A subset tag of six capitals from `seed` (the Windows hash, so the same font gets the same tag on both).
    static func tag(_ seed: String) -> String {
        var h: Int32 = 17
        for c in seed.utf16 { h = h &* 31 &+ Int32(c) }
        var hash = UInt32(bitPattern: h)
        var out = ""
        for _ in 0..<6 {
            out.append(Character(Unicode.Scalar(UInt8(65 + hash % 26))))
            hash /= 26
        }
        return out
    }
}
