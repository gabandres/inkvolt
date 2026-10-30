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
                if substitute(f) != nil { dr.remove(key) }
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
        let notEmbedded = "The font \(Self.fontName(font)) isn't embedded, and only the standard Helvetica, Times and Courier faces can be embedded here."
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
