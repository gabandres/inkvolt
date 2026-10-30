import Foundation

/// One glyph of a text-showing string: its code, how many bytes it took, the text it stands for and its advance (ems).
struct Glyph: Sendable {
    var code: Int
    var length: Int
    var text: String
    var width: Double
}

/// New text in a font's codes. A code of `TextFont.gap` is a word space the font has no glyph for.
struct EncodedText: Sendable {
    var codes: [Int]
    var missing: [String]
}

/// Text as UTF-16 units, the way the Windows code indexes it.
private func utf16(_ s: String) -> [UInt16] { Array(s.utf16) }
private func text(_ units: ArraySlice<UInt16>) -> String { String(decoding: units, as: UTF16.self) }
private func isHighSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }

/// The first code point of UTF-16 text (.NET's `char.ConvertToUtf32(text, 0)`).
private func firstCodePoint(_ s: String) -> Int { Int(s.unicodeScalars.first?.value ?? 0) }

private func isWhiteSpace(_ s: String) -> Bool { s.unicodeScalars.allSatisfy(\.properties.isWhitespace) }

/// A page font as text editing needs it (the Windows app's `TextFont`): decoding a string's bytes into glyphs (codes,
/// Unicode text, widths) and encoding new text back into the same font's codes, refusing characters the font can't draw.
/// Simple fonts map text to codes through their ToUnicode CMap, else their /Encoding (+ /Differences) and glyph names;
/// composite fonts (Type0, Identity-H) through the inverse ToUnicode CMap, else the embedded TrueType cmap. A code
/// counts only when its glyph is really in the embedded program (subset fonts keep only the glyphs the document used)
/// and it has a width. Everything is read when it is made, so it outlives the document it came from; `prepare` writes to
/// the font dictionary of the document being edited.
final class TextFont: @unchecked Sendable {
    /// Stands for a word space drawn as a gap (a TJ adjustment), when the font has no space glyph.
    static let gap = -1

    private let lock = NSRecursiveLock()
    /// The embedded font program, when there is a readable one.
    let program: FontProgram?
    private var toUnicode: [Int: String] = [:]
    private var hasToUnicode = false
    private var names = [String?](repeating: nil, count: 256)
    private var simpleText = [String?](repeating: nil, count: 256)
    private var widths = [Double?](repeating: nil, count: 256)
    private var cidWidths: [Int: Double] = [:]
    private var dw = 1000.0
    private var missingWidth = 0.0 // a simple font's width for codes its /Widths doesn't list
    private var cidToGid: [Int]? // nil: identity
    private let symbolic: Bool
    private var standard14 = false
    private let hasDescriptor: Bool, embedded: Bool, hasWidths: Bool
    private var glyphKnown: [Int: Bool] = [:]
    private var inverseMap: [String: [Int]]?
    private var gidToCid: [Int: Int]?

    let name: String
    private(set) var twoByte = false
    /// Why text in this font can't be edited (nil: it can).
    private(set) var blocked: String?
    /// Ascent and descent in ems (descent negative).
    private(set) var ascent = 0.8
    private(set) var descent = -0.2
    let bold: Bool
    let italic: Bool

    init(_ font: PObj) {
        let subtype = font.name("Subtype")
        var n = (font.name("BaseFont") ?? "").trimmingCharacters(in: .whitespaces)
        let chars = Array(n.utf16)
        if chars.count > 7 && chars[6] == 43 && chars.prefix(6).allSatisfy({ (65...90).contains($0) }) { n = String(n.dropFirst(7)) }
        let name = n.replacingOccurrences(of: ",", with: " ") // "Arial,Bold" → "Arial Bold"
        self.name = name
        var unicode: [Int: String] = [:]
        if let tu = font.dict("ToUnicode"), tu.isStream { Self.readCMap(tu.streamData ?? [], into: &unicode) }
        toUnicode = unicode
        hasToUnicode = !unicode.isEmpty

        var descriptor: PObj?
        if subtype == "Type0" {
            twoByte = true
            let cidFont = font.array("DescendantFonts")?[0].flatMap { $0.isDict ? $0 : nil }
            descriptor = cidFont?.dict("FontDescriptor")
            let encoding = font.name("Encoding")
            if cidFont == nil {
                blocked = "its font is damaged"
            } else if encoding == "Identity-V" {
                blocked = "it is vertical text"
            } else if encoding != "Identity-H" {
                blocked = "its font uses a character map (CMap) that can't be written to yet"
                twoByte = encoding.map { $0.contains("UCS2") || $0.contains("UTF16") } ?? false
            }
            if let cidFont {
                dw = cidFont.number("DW") ?? 1000
                cidWidths = Self.readW(cidFont.array("W"))
                if let map = cidFont.dict("CIDToGIDMap"), map.isStream {
                    let b = map.streamData ?? []
                    cidToGid = (0..<b.count / 2).map { Int(b[2 * $0]) << 8 | Int(b[2 * $0 + 1]) }
                }
            }
            if blocked == nil && unicode.isEmpty { blocked = "its font doesn't say which characters its glyphs are" }
        } else {
            descriptor = font.dict("FontDescriptor")
            if subtype == "Type3" { blocked = "it is drawn with a Type 3 font (glyphs drawn as pictures)" }
            let first = Int(font.number("FirstChar") ?? 0)
            if let w = font.array("Widths") {
                for i in 0..<w.count where (0..<256).contains(first + i) { widths[first + i] = w.num(i) }
            }
            let plain = Self.stripStyle(name)
            standard14 = descriptor == nil
                && ["Helvetica", "Arial", "Times", "TimesNewRoman", "Times-Roman", "Courier", "CourierNew"].contains(plain)
            if descriptor == nil && (name.hasPrefix("Symbol") || name.hasPrefix("ZapfDingbats")) && blocked == nil {
                blocked = "its font is a symbol font"
            }
        }

        hasDescriptor = descriptor != nil
        embedded = descriptor.map { $0.has("FontFile") || $0.has("FontFile2") || $0.has("FontFile3") } ?? false
        hasWidths = font.array("Widths") != nil
        let flags = Int(descriptor?.number("Flags") ?? 0)
        symbolic = flags & 4 != 0 && flags & 32 == 0
        if let descriptor {
            let asc = descriptor.number("Ascent") ?? 0
            let desc = descriptor.number("Descent") ?? 0
            if asc > 0 { ascent = min(asc, 1500) / 1000 }
            if desc < 0 {
                descent = max(desc, -1000) / 1000
            } else if desc > 0 {
                descent = -min(desc, 1000) / 1000 // positive descents turn up (PDFsharp writes them)
            }
            program = FontProgram.load(descriptor)
            missingWidth = descriptor.number("MissingWidth") ?? 0
        } else {
            program = nil
        }
        bold = FontNames.looksBold(name) || flags & 0x40000 != 0
        italic = FontNames.looksItalic(name) || flags & 64 != 0
        if !twoByte { readSimpleEncoding(font, subtype ?? "") }
    }

    private static func stripStyle(_ name: String) -> String {
        if name.hasPrefix("Times-Roman") { return "Times-Roman" }
        guard let cut = name.firstIndex(where: { $0 == "," || $0 == "-" || $0 == " " }), cut > name.startIndex else { return name }
        return String(name[..<cut])
    }

    // ---- Reading ----

    private func readSimpleEncoding(_ font: PObj, _ subtype: String) {
        var baseEncoding: String?
        var differences: PObj?
        if let e = font["Encoding"] {
            if e.kind == .name {
                baseEncoding = e.name
            } else if e.isDict {
                baseEncoding = e.name("BaseEncoding")
                differences = e.array("Differences")
            }
        }
        let builtIn = (program as? Type1Program)?.builtIn
        if baseEncoding.map({ !GlyphNames.isKnownEncoding($0) }) ?? true {
            // No (usable) base encoding: the font's own. Type 1 programs carry one; otherwise Standard for text fonts.
            baseEncoding = builtIn != nil || (symbolic && subtype == "TrueType") ? nil : "StandardEncoding"
        }
        for c in 0..<256 { names[c] = baseEncoding.map { GlyphNames.inEncoding($0, c) } ?? builtIn?[c] }
        if let differences {
            var code = 0
            for item in differences.elements {
                if item.kind == .int || item.kind == .real {
                    code = item.int ?? 0
                } else if item.kind == .name {
                    if (0..<256).contains(code) { names[code] = item.name }
                    code += 1
                }
            }
        }
        for c in 0..<256 { simpleText[c] = toUnicode[c] ?? names[c].flatMap(GlyphNames.toUnicode) }
    }

    private static func readW(_ w: PObj?) -> [Int: Double] {
        var cidWidths: [Int: Double] = [:]
        guard let w else { return cidWidths }
        let e = w.elements
        var i = 0
        while i < e.count {
            guard e[i].kind == .int, let first = e[i].int else { break }
            if i + 1 < e.count, e[i + 1].isArray {
                let list = e[i + 1]
                for k in 0..<list.count { cidWidths[first + k] = list.num(k) }
                i += 2
            } else if i + 2 < e.count, e[i + 1].kind == .int, let last = e[i + 1].int {
                let width = e[i + 2].number ?? 0
                var c = first
                while c <= last && c - first < 65536 {
                    cidWidths[c] = width
                    c += 1
                }
                i += 3
            } else {
                break
            }
        }
        return cidWidths
    }

    /// Reads a ToUnicode CMap's bfchar and bfrange entries (codes as integers, targets as UTF-16BE text).
    static func readCMap(_ data: [UInt8], into: inout [Int: String]) {
        for op in ContentLexer.parse(data) {
            let o = op.operands
            if op.name == "endbfchar" {
                var i = 0
                while i + 1 < o.count {
                    if o[i].kind == .string, let t = target(o[i + 1]) { into[code(o[i].bytes)] = t }
                    i += 2
                }
            } else if op.name == "endbfrange" {
                var i = 0
                while i + 2 < o.count {
                    defer { i += 3 }
                    if o[i].kind != .string || o[i + 1].kind != .string { continue }
                    let lo = code(o[i].bytes), hi = code(o[i + 1].bytes)
                    if hi < lo || hi - lo > 65535 || into.count > 200_000 { continue }
                    if o[i + 2].kind == .array {
                        var k = 0
                        while k < o[i + 2].items.count && lo + k <= hi {
                            if let t = target(o[i + 2].items[k]) { into[lo + k] = t }
                            k += 1
                        }
                    } else if o[i + 2].kind == .string && o[i + 2].bytes.count >= 2 {
                        let start = o[i + 2].bytes
                        for c in lo...hi {
                            var b = start
                            // The last byte counts up (carrying into the one before, as most readers do).
                            let v = (Int(b[b.count - 2]) << 8 | Int(b[b.count - 1])) + c - lo
                            b[b.count - 2] = UInt8(truncatingIfNeeded: v >> 8)
                            b[b.count - 1] = UInt8(truncatingIfNeeded: v)
                            into[c] = utf16BE(b)
                        }
                    }
                }
            }
        }
    }

    private static func code(_ b: [UInt8]) -> Int { b.prefix(4).reduce(0) { $0 << 8 | Int($1) } }

    /// UTF-16BE bytes as text (an odd last byte dropped; lone surrogates become U+FFFD).
    static func utf16BE(_ b: [UInt8]) -> String {
        String(decoding: (0..<b.count / 2).map { UInt16(b[2 * $0]) << 8 | UInt16(b[2 * $0 + 1]) }, as: UTF16.self)
    }

    private static func target(_ o: CObj) -> String? {
        if o.kind == .name { return GlyphNames.toUnicode(o.name) }
        if o.kind != .string || o.bytes.isEmpty { return nil }
        if o.bytes.count == 1 { return String(Unicode.Scalar(o.bytes[0])) }
        let s = utf16BE(o.bytes)
        return s.isEmpty ? nil : s
    }

    /// The glyphs a string shows (1-byte codes for simple fonts, 2-byte for composite ones).
    func decode(_ bytes: [UInt8]) -> [Glyph] {
        lock.lock()
        defer { lock.unlock() }
        var list: [Glyph] = []
        list.reserveCapacity(bytes.count)
        if twoByte {
            var i = 0
            while i + 1 < bytes.count {
                let code = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                list.append(Glyph(code: code, length: 2, text: textOf(code) ?? "\u{FFFD}", width: widthOf(code) / 1000))
                i += 2
            }
        } else {
            for b in bytes {
                let code = Int(b)
                list.append(Glyph(code: code, length: 1, text: textOf(code) ?? "\u{FFFD}", width: widthOf(code) / 1000))
            }
        }
        return list
    }

    private func textOf(_ code: Int) -> String? {
        twoByte ? toUnicode[code] : (0..<256).contains(code) ? simpleText[code] : nil
    }

    /// A simple font's glyph name for a code (nil for composite fonts and codes without one).
    func glyphNameOf(_ code: Int) -> String? { !twoByte && (0..<256).contains(code) ? names[code] : nil }

    /// The text a code stands for, from any source (ToUnicode, encoding, glyph names).
    func unicodeOf(_ code: Int) -> String? { textOf(code) }

    /// The ToUnicode CMap's own value for a code, or nil when it has none.
    func toUnicodeOf(_ code: Int) -> String? { toUnicode[code] }

    /// Every code the ToUnicode CMap maps, with its text.
    var toUnicodeMap: [Int: String] { toUnicode }

    /// A code's width in thousandths of an em (as the PDF says, else the program's, else a fallback).
    func widthOf(_ code: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if twoByte { return cidWidths[code] ?? programAdvance(code) ?? dw }
        let inRange = (0..<256).contains(code)
        if inRange, let w = widths[code], w > 0 { return w }
        if let pa = programAdvance(code) { return pa }
        if standard14, inRange, let t = simpleText[code], t.utf16.count == 1 {
            return StdFont.fromName(name).advance(UInt32(t.utf16.first!)) * 1000
        }
        if inRange, let z = widths[code] { return z }
        return hasWidths ? missingWidth : 500
    }

    private func hasWidth(_ code: Int) -> Bool {
        if twoByte { return cidWidths[code] != nil }
        guard (0..<256).contains(code), let w = widths[code] else { return false }
        return w > 0
    }

    // ---- Glyphs ----

    private func gidOf(_ code: Int) -> Int {
        guard let tt = program as? TrueTypeProgram else { return -1 }
        if twoByte {
            guard let map = cidToGid else { return code }
            return code < map.count ? map[code] : 0
        }
        guard (0..<256).contains(code) else { return 0 }
        // PDF 32000 9.6.6.4: a (3,1) cmap is reached through the glyph name's Unicode value, else (3,0) and (1,0) by code.
        if tt.hasCmap(3, 1) && !symbolic {
            let t = names[code].map { GlyphNames.toUnicode($0) } ?? simpleText[code]
            if let t, !t.isEmpty {
                let g = tt.lookup(3, 1, firstCodePoint(t))
                if g > 0 { return g }
            }
        }
        if tt.hasCmap(3, 0) {
            for c in [code, 0xF000 + code, 0xF100 + code, 0xF200 + code] {
                let g = tt.lookup(3, 0, c)
                if g > 0 { return g }
            }
        }
        if tt.hasCmap(1, 0) {
            let m = tt.lookup(1, 0, code)
            if m > 0 { return m }
        }
        if tt.hasCmap(3, 1), let st = simpleText[code], !st.isEmpty {
            let u = tt.lookup(3, 1, firstCodePoint(st))
            if u > 0 { return u }
        }
        return 0
    }

    private func programAdvance(_ code: Int) -> Double? {
        guard let tt = program as? TrueTypeProgram else { return nil }
        let g = gidOf(code)
        return g > 0 ? tt.advance(g) : nil
    }

    /// Whether the font can draw a code: its glyph is in the embedded program, or the font isn't embedded.
    func hasGlyph(_ code: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let known = glyphKnown[code] { return known }
        let blank = textOf(code).map(isWhiteSpace) ?? false
        var has: Bool
        if twoByte {
            switch program {
            case let tt as TrueTypeProgram: has = tt.hasGlyph(gidOf(code), blank: blank)
            case let cff as CffProgram: has = cff.hasCid(code)
            default: has = toUnicode[code] != nil && hasWidth(code) // not embedded or unreadable: only codes the font already maps
            }
        } else if !(0..<256).contains(code) {
            has = false
        } else {
            let glyphName = names[code]
            switch program {
            case let tt as TrueTypeProgram:
                has = tt.hasGlyph(gidOf(code), blank: blank)
            case let t1 as Type1Program where glyphName != nil:
                has = t1.hasName(glyphName!)
            case let cff as CffProgram where !cff.isCid && glyphName != nil:
                has = cff.hasName(glyphName!)
            case nil where hasDescriptor && !embedded:
                has = glyphName != nil || simpleText[code] != nil
            case nil where !hasDescriptor:
                has = glyphName != nil
            default:
                has = hasWidth(code) && (!hasToUnicode || toUnicode[code] != nil) // program unreadable: the PDF's tables
            }
            // A width is needed to place it; an embedded TrueType glyph's width can be added from the program.
            if has && !hasWidth(code) && !(standard14 && !hasWidths) && programAdvance(code) == nil { has = false }
        }
        glyphKnown[code] = has
        return has
    }

    // ---- Encoding ----

    private func inverse() -> [String: [Int]] {
        if let inverseMap { return inverseMap }
        var inv: [String: [Int]] = [:]
        func add(_ text: String, _ code: Int) {
            let key = text.precomposedStringWithCanonicalMapping
            if !(inv[key]?.contains(code) ?? false) { inv[key, default: []].append(code) }
        }
        if twoByte {
            for code in toUnicode.keys.sorted() { add(toUnicode[code]!, code) }
        } else {
            for c in 0..<256 {
                if let t = simpleText[c], !t.isEmpty { add(t, c) }
            }
        }
        inverseMap = inv
        return inv
    }

    /// The codes for `text`, longest match first (ligatures such as "fi" when the font maps one), or the characters the
    /// font can't draw. A space the font has no glyph for becomes a `gap`.
    func encode(_ s: String) -> EncodedText {
        lock.lock()
        defer { lock.unlock() }
        var codes: [Int] = []
        var missing: [String] = []
        let inv = inverse()
        let t = utf16(s.precomposedStringWithCanonicalMapping)
        var i = 0
        while i < t.count {
            var found = false
            var len = min(4, t.count - i)
            while len >= 1 && !found {
                defer { len -= 1 }
                if len < t.count - i && isHighSurrogate(t[i + len - 1]) { continue } // don't split a pair
                if let list = inv[text(t[i..<i + len])], let code = list.first(where: hasGlyph) {
                    codes.append(code)
                    i += len
                    found = true
                }
            }
            if found { continue }
            let step = isHighSurrogate(t[i]) && i + 1 < t.count ? 2 : 1
            let ch = text(t[i..<i + step])
            if let c2 = fromProgram(ch) {
                codes.append(c2)
            } else if step == 1 && isWhiteSpace(ch) {
                codes.append(Self.gap)
            } else if !missing.contains(ch) {
                missing.append(ch)
            }
            i += step
        }
        return EncodedText(codes: codes, missing: missing)
    }

    /// A composite TrueType font's code for a character through the program's own Unicode cmap (the PDF doesn't map it
    /// yet).
    private func fromProgram(_ ch: String) -> Int? {
        guard twoByte, blocked == nil, let tt = program as? TrueTypeProgram, tt.hasUnicodeCmap else { return nil }
        let gid = tt.lookupUnicode(firstCodePoint(ch))
        if gid <= 0 { return nil }
        var cid = gid
        if let map = cidToGid {
            if gidToCid == nil {
                var reverse: [Int: Int] = [:]
                for c in stride(from: map.count - 1, through: 0, by: -1) { reverse[map[c]] = c }
                gidToCid = reverse
            }
            guard let c = gidToCid?[gid] else { return nil }
            cid = c
        }
        if cid > 0xFFFF || !tt.hasGlyph(gid, blank: ch.unicodeScalars.first?.properties.isWhitespace ?? false) { return nil }
        return cid
    }

    func toBytes(_ codes: [Int]) -> [UInt8] {
        var list: [UInt8] = []
        for c in codes where c >= 0 {
            if twoByte { list.append(UInt8(truncatingIfNeeded: c >> 8)) }
            list.append(UInt8(truncatingIfNeeded: c))
        }
        return list
    }

    /// Before codes the PDF didn't use are written: their widths go into /Widths or /W (from the program), and their text
    /// into the ToUnicode CMap, so the new text is spaced right and still copies and searches as typed. `font` is this
    /// font's dictionary in the document being edited.
    func prepare(_ doc: MuDoc, _ font: PObj, _ codes: [Int], _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<Int>()
        let fresh = codes.filter { $0 >= 0 && seen.insert($0).inserted }
            .filter { !hasWidth($0) || (hasToUnicode && toUnicode[$0] == nil) }
        if fresh.isEmpty { return }
        let needW = fresh.filter { !hasWidth($0) && programAdvance($0) != nil }
        if !needW.isEmpty {
            let cidFont = font.array("DescendantFonts")?[0].flatMap { $0.isDict ? $0 : nil }
            if twoByte, let cidFont {
                let w = doc.array(cidFont.array("W")?.elements ?? [])
                for c in needW {
                    let adv = programAdvance(c)!.rounded(.toNearestOrEven)
                    w.append(doc.int(c))
                    w.append(doc.array([doc.int(Int(adv))]))
                    cidWidths[c] = adv
                }
                cidFont.set("W", w)
            } else if !twoByte {
                for c in needW { widths[c] = programAdvance(c)!.rounded(.toNearestOrEven) }
                let first = widths.firstIndex { $0 != nil }!
                let last = widths.lastIndex { $0 != nil }!
                // Codes in between that the old range didn't cover keep the width viewers gave them: /MissingWidth.
                let arr = doc.array((first...last).map { doc.int(Int((widths[$0] ?? missingWidth).rounded(.toNearestOrEven))) })
                font.set("FirstChar", doc.int(first))
                font.set("LastChar", doc.int(last))
                font.set("Widths", arr)
            }
        }
        let needU = fresh.filter { hasToUnicode && toUnicode[$0] == nil }
        if !needU.isEmpty, let tu = font.dict("ToUnicode"), tu.isStream {
            // The text each new code stands for: what encode matched it with.
            let map = codeTexts(codes, text)
            var add = "\n\(needU.count) beginbfchar\n"
            for c in needU {
                guard let t = map[c] else { continue }
                let hex = t.utf16.map { String(format: "%04X", $0) }.joined()
                add += "<" + String(format: twoByte ? "%04X" : "%02X", c) + "> <" + hex + ">\n"
                toUnicode[c] = t
            }
            add += "endbfchar\n"
            let s = latin1String(tu.streamData ?? [])
            if let at = s.range(of: "endcmap", options: .backwards) {
                let updated = String(s[..<at.lowerBound]) + add + String(s[at.lowerBound...])
                tu.remove("DecodeParms")
                tu.setStream(latin1Bytes(updated), deflate: false)
                inverseMap = nil
            }
        }
    }

    /// Which text each code of an encoding stands for (codes from the program's cmap stand for one character).
    private func codeTexts(_ codes: [Int], _ s: String) -> [Int: String] {
        var map: [Int: String] = [:]
        let inv = inverse()
        let t = utf16(s.precomposedStringWithCanonicalMapping)
        var i = 0
        for c in codes {
            if i >= t.count { break }
            var matched = false
            var len = min(4, t.count - i)
            while len >= 1 && !matched {
                if inv[text(t[i..<i + len])]?.contains(c) == true {
                    i += len
                    matched = true
                }
                len -= 1
            }
            if matched { continue }
            let step = isHighSurrogate(t[i]) && i + 1 < t.count ? 2 : 1
            if c >= 0 && map[c] == nil { map[c] = text(t[i..<i + step]) }
            i += step
        }
        return map
    }
}
