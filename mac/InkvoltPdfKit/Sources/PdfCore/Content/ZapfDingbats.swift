import CoreGraphics
import CoreText
import Foundation

/// The standard ZapfDingbats font (the Windows app's `ZapfDingbats`, which reads Adobe's Core 14 AFM and ITC Zapf
/// Dingbats glyph list because Windows has no twin of the font). macOS ships the font itself
/// (/System/Library/Fonts/ZapfDingbats.ttf, ITC Zapf Dingbats), so the Mac reads the built-in encoding from Unicode's
/// mapping of it (the Dingbats block follows the font's layout: Unicode's ZDINGBAT.TXT), and each code's glyph name and
/// width from the font: no font data of Adobe's is copied into the app.
enum ZapfDingbats {
    /// The character each code of the built-in encoding stands for (nil: no glyph there).
    static let characters: [UInt32?] = {
        var map = [UInt32?](repeating: nil, count: 256)
        map[0x20] = 0x20
        for c in 0x21...0x7E { map[c] = 0x2700 + UInt32(c - 0x20) }
        // Where Unicode had the shape already, outside the Dingbats block.
        let moved: [Int: UInt32] = [0x25: 0x260E, 0x2A: 0x261B, 0x2B: 0x261E, 0x48: 0x2605, 0x6C: 0x25CF, 0x6E: 0x25A0,
                                    0x73: 0x25B2, 0x74: 0x25BC, 0x75: 0x25C6, 0x77: 0x25D7]
        for (c, u) in moved { map[c] = u }
        for c in 0x80...0x8D { map[c] = 0x2768 + UInt32(c - 0x80) }
        for c in 0xA1...0xA7 { map[c] = 0x2761 + UInt32(c - 0xA1) }
        map[0xA8] = 0x2663
        map[0xA9] = 0x2666
        map[0xAA] = 0x2665
        map[0xAB] = 0x2660
        for c in 0xAC...0xB5 { map[c] = 0x2460 + UInt32(c - 0xAC) }
        for c in 0xB6...0xD4 { map[c] = 0x2776 + UInt32(c - 0xB6) }
        map[0xD5] = 0x2192
        map[0xD6] = 0x2194
        map[0xD7] = 0x2195
        for c in 0xD8...0xEF { map[c] = 0x2798 + UInt32(c - 0xD8) }
        for c in 0xF1...0xFE { map[c] = 0x27B1 + UInt32(c - 0xF1) }
        return map
    }()

    private struct Tables: Sendable {
        var names = [String?](repeating: nil, count: 256)
        var widths: [String: Double] = [:]
        var texts: [String: String] = [:]
    }

    private static let tables: Tables = {
        var t = Tables()
        guard let font = SystemFonts.get("ZapfDingbats.ttf") else { return t }
        let graphics = CTFontCopyGraphicsFont(font.font, nil)
        for code in 0..<256 {
            guard let cp = characters[code], let scalar = Unicode.Scalar(cp) else { continue }
            let glyph = font.glyphOf(cp)
            if glyph == 0 && cp != 0x20 { continue }
            let name = glyph == 0 ? "space" : (graphics.name(for: CGGlyph(clamping: glyph)) as String?) ?? "space"
            t.names[code] = name
            t.widths[name] = glyph == 0 ? 278 : font.glyphAdvance(glyph).rounded()
            if t.texts[name] == nil { t.texts[name] = String(Character(scalar)) }
        }
        return t
    }()

    /// Whether macOS has the font (it always has; a damaged system would read the font as blocked, as before).
    static var available: Bool { tables.names[0x21] != nil }

    /// The built-in encoding: each code's glyph name.
    static var encoding: [String?] { tables.names }

    static func name(_ code: Int) -> String? { (0..<256).contains(code) ? tables.names[code] : nil }

    /// A glyph's width in thousandths of an em, or nil when the font has no glyph of that name.
    static func width(_ name: String) -> Double? { tables.widths[name] }

    /// The character a glyph name stands for.
    static func text(_ name: String) -> String? { tables.texts[name] }
}
