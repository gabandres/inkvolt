import CoreGraphics
import CoreText
import Foundation

/// A system font, as Core Text has it at 1000 units per em (the Windows app's `TrueTypeFont`, which reads a TrueType file
/// itself for HarfBuzz): its glyphs for code points, advance widths, ascent and descent, and glyph outlines for the
/// fonts `Type3FontWriter` embeds. Any outline format Core Text reads works (TrueType, CFF, collections). One object per
/// font for the process (`SystemFonts`), so fonts compare by identity.
final class TrueTypeFont: @unchecked Sendable, Hashable {
    /// Core Text's font at 1000 points: its units are thousandths of an em.
    let font: CTFont
    let family: String
    let postScriptName: String
    let unitsPerEm = 1000.0
    /// Ascent and descent as fractions of the em (descent negative).
    let ascent: Double
    let descent: Double
    /// The font's bounding box in thousandths of an em: xMin, yMin, xMax, yMax.
    let bbox: [Double]

    private let lock = NSLock()
    private var glyphs: [UInt32: Int] = [:]
    private var advances: [Int: Double] = [:]

    init(_ font: CTFont) {
        self.font = font
        family = CTFontCopyFamilyName(font) as String
        postScriptName = CTFontCopyPostScriptName(font) as String
        ascent = Double(CTFontGetAscent(font)) / 1000
        descent = -Double(CTFontGetDescent(font)) / 1000
        let b = CTFontGetBoundingBox(font)
        bbox = [Double(b.minX), Double(b.minY), Double(b.maxX), Double(b.maxY)]
    }

    static func == (a: TrueTypeFont, b: TrueTypeFont) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// The glyph for a code point (0 when the font has none).
    func glyphOf(_ codePoint: UInt32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let g = glyphs[codePoint] { return g }
        var units: [UniChar] = []
        if let scalar = Unicode.Scalar(codePoint) { units = Array(String(Character(scalar)).utf16) }
        var out = [CGGlyph](repeating: 0, count: max(units.count, 1))
        let found = !units.isEmpty && CTFontGetGlyphsForCharacters(font, units, &out, units.count)
        let g = found ? Int(out[0]) : 0
        glyphs[codePoint] = g
        return g
    }

    func has(_ codePoint: UInt32) -> Bool { codePoint == 10 || codePoint == 13 || codePoint == 9 || glyphOf(codePoint) != 0 }

    /// A glyph's advance width in font units (thousandths of an em).
    func glyphAdvance(_ glyph: Int) -> Double {
        lock.lock()
        if let a = advances[glyph] {
            lock.unlock()
            return a
        }
        lock.unlock()
        var g = CGGlyph(clamping: glyph)
        var size = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &size, 1)
        let a = Double(size.width)
        lock.lock()
        advances[glyph] = a
        lock.unlock()
        return a
    }

    /// The advance width of a code point, in ems.
    func advance(_ codePoint: UInt32) -> Double { glyphAdvance(glyphOf(codePoint)) / unitsPerEm }

    func measure(_ s: String) -> Double { s.unicodeScalars.reduce(0) { $0 + advance($1.value) } }

    /// The glyph's outline (font units, y up) and its bounding box.
    func outline(_ glyph: Int) -> (path: CGPath?, box: CGRect) {
        var g = CGGlyph(clamping: glyph)
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &box, 1)
        return (CTFontCreatePathForGlyph(font, g, nil), box)
    }

    /// The code points of `s` (.NET's `TrueTypeFont.CodePoints`).
    static func codePoints(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
}

/// The three standard PDF text font families (not embedded, WinAnsi).
enum StdFamily: Sendable { case helvetica, times, courier }

/// A standard-14 text font: its PDF name, and the system font with the same metrics, used to measure (Arial for
/// Helvetica, Times New Roman for Times, Courier New for Courier, as on Windows; macOS has them in Supplemental).
struct StdFont: Equatable, Sendable {
    var family: StdFamily
    var bold: Bool
    var italic: Bool

    init(_ family: StdFamily, _ bold: Bool, _ italic: Bool) {
        self.family = family
        self.bold = bold
        self.italic = italic
    }

    static let helvetica = StdFont(.helvetica, false, false)

    var baseFont: String {
        switch family {
        case .times:
            switch (bold, italic) {
            case (true, true): return "Times-BoldItalic"
            case (true, false): return "Times-Bold"
            case (false, true): return "Times-Italic"
            default: return "Times-Roman"
            }
        case .courier: return "Courier" + suffix("Oblique")
        case .helvetica: return "Helvetica" + suffix("Oblique")
        }
    }

    private func suffix(_ italic: String) -> String {
        switch (bold, self.italic) {
        case (true, true): "-Bold" + italic
        case (true, false): "-Bold"
        case (false, true): "-" + italic
        default: ""
        }
    }

    /// The system font with the same metrics (the Windows file names; `SystemFonts` finds the Mac's).
    var metrics: TrueTypeFont? {
        let style = bold ? (italic ? "bi" : "bd") : (italic ? "i" : "")
        switch family {
        case .times: return SystemFonts.get("times\(style).ttf")
        case .courier: return SystemFonts.get("cour\(style).ttf")
        case .helvetica: return SystemFonts.get("arial\(style).ttf")
        }
    }

    /// Maps any font name (a /DA resource name or a /BaseFont) to the closest standard family.
    static func fromName(_ name: String?) -> StdFont {
        var n = Substring(name ?? "")
        while n.hasPrefix("/") { n = n.dropFirst() }
        if let plus = n.firstIndex(of: "+"), n.distance(from: n.startIndex, to: plus) == 6 { n = n[n.index(after: plus)...] }
        let s = String(n)
        func has(_ part: String) -> Bool { s.range(of: part, options: .caseInsensitive) != nil }
        var bold = has("Bold") || s.hasSuffix("Bd") || has("Black")
        let italic = has("Italic") || has("Oblique") || s.hasSuffix("It")
        let family: StdFamily
        if has("Cour") || has("Mono") {
            family = .courier
        } else if has("Times") || s.hasPrefix("TiRo") || (has("Serif") && !has("Sans")) || has("Georgia") || has("Garamond") {
            family = .times
        } else {
            family = .helvetica
        }
        if s == "TiBo" || s == "HeBo" || s == "CoBo" { bold = true }
        return StdFont(family, bold, italic)
    }

    /// The advance in ems of a WinAnsi character.
    func advance(_ c: UInt32) -> Double { family == .courier ? 0.6 : metrics?.advance(c) ?? 0.5 }

    func measure(_ s: String) -> Double {
        let m = metrics
        var w = 0.0
        for u in s.utf16 { w += family == .courier ? 0.6 : m?.advance(UInt32(u)) ?? 0.5 }
        return w
    }

    var ascent: Double { metrics?.ascent ?? 0.9 }
    var descent: Double { metrics?.descent ?? -0.21 }
}

/// System fonts, loaded once for the process. Windows reads its font folders and walks a list of fallback files; the Mac
/// asks Core Text for the font that has a character (its cascade list), and maps the Windows names of the standard fonts'
/// metric twins to the files macOS ships.
enum SystemFonts {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var byFile: [String: TrueTypeFont?] = [:]
        var byName: [String: TrueTypeFont] = [:]
    }

    private static let cache = Cache()

    private static let macFiles: [String: String] = [
        "arial.ttf": "Arial.ttf", "arialbd.ttf": "Arial Bold.ttf", "ariali.ttf": "Arial Italic.ttf", "arialbi.ttf": "Arial Bold Italic.ttf",
        "times.ttf": "Times New Roman.ttf", "timesbd.ttf": "Times New Roman Bold.ttf", "timesi.ttf": "Times New Roman Italic.ttf",
        "timesbi.ttf": "Times New Roman Bold Italic.ttf", "cour.ttf": "Courier New.ttf", "courbd.ttf": "Courier New Bold.ttf",
        "couri.ttf": "Courier New Italic.ttf", "courbi.ttf": "Courier New Bold Italic.ttf",
    ]

    private static let folders = ["/System/Library/Fonts/Supplemental", "/System/Library/Fonts", "/Library/Fonts"]

    /// A font by its Windows file name ("arial.ttf") or a Mac one ("Arial Unicode.ttf"); nil when it isn't there.
    static func get(_ file: String) -> TrueTypeFont? {
        let key = file.lowercased()
        cache.lock.lock()
        if let hit = cache.byFile[key] {
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()
        let name = macFiles[key] ?? file
        var loaded: TrueTypeFont?
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let first = descriptors.first else { continue }
            loaded = wrap(CTFontCreateWithFontDescriptor(first, 1000, nil))
            break
        }
        cache.lock.lock()
        cache.byFile[key] = .some(loaded)
        cache.lock.unlock()
        return loaded
    }

    /// The one `TrueTypeFont` for a Core Text font (at 1000 units per em).
    static func wrap(_ font: CTFont) -> TrueTypeFont {
        let name = CTFontCopyPostScriptName(font) as String
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let hit = cache.byName[name] { return hit }
        let sized = CTFontGetSize(font) == 1000 ? font : CTFontCreateCopyWithAttributes(font, 1000, nil, nil)
        let made = TrueTypeFont(sized)
        cache.byName[name] = made
        return made
    }

    /// The font to draw `codePoint` with: the primary when it has the glyph, else the one Core Text falls back to.
    static func forCodePoint(_ codePoint: UInt32, _ primary: TrueTypeFont?) -> TrueTypeFont? {
        if let primary, primary.has(codePoint) { return primary }
        guard let base = primary ?? get("arial.ttf"), let scalar = Unicode.Scalar(codePoint) else { return primary }
        let s = String(Character(scalar)) as CFString
        let fallback = wrap(CTFontCreateForString(base.font, s, CFRange(location: 0, length: CFStringGetLength(s))))
        return fallback.has(codePoint) ? fallback : primary ?? base
    }
}

/// WinAnsiEncoding (the encoding the standard fonts use here).
enum WinAnsi {
    private static let specials: [UInt16: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88,
        0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93,
        0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B,
        0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    static func encode(_ c: UInt16) -> UInt8? {
        if (0x20...0x7E).contains(c) || (0xA0...0xFF).contains(c) { return UInt8(c) }
        return specials[c]
    }

    static func canEncode(_ s: String) -> Bool { s.utf16.allSatisfy { $0 == 10 || $0 == 13 || $0 == 9 || encode($0) != nil } }

    /// A PDF literal string's body (escaped) as WinAnsi bytes; characters it can't encode become '?'.
    static func literal(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf16.count + 8)
        for u in s.utf16 {
            let c = encode(u) ?? (u == 9 ? 32 : 63)
            if c == 40 || c == 41 || c == 92 { out.append(92) }
            out.append(c)
        }
        return out
    }
}
