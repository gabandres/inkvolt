import Foundation

extension ContentEditor {
    /// A line's own baseline and size, as most of its characters sit on it (not a big name set higher, nor a script).
    static func lineBaseline(_ line: PLine) -> (y: Double, size: Double) {
        if let own = line.own { return own }
        var chars: [Double: (count: Int, sizes: [Double: Int])] = [:]
        for r in line.runs {
            let n = trimmed(r.text).utf16.count
            if n == 0 { continue }
            let y = (r.origin.y * 4).rounded() / 4
            var at = chars[y] ?? (0, [:])
            let size = (r.fontSize * 10).rounded() / 10
            at.sizes[size, default: 0] += n
            at.count += n
            chars[y] = at
        }
        // The most characters wins; a tie goes to the first baseline, then the first size, in the order they were met.
        guard let best = chars.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }) else { return (line.lead.origin.y, line.lead.fontSize) }
        let size = best.value.sizes.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key
        return (best.key, size)
    }

    /// For a translated copy, the look a run of a paragraph's line has that its translation keeps (`TranslationMarkup`):
    /// bold or italic where the paragraph's own text (`own`) isn't, and regular where it is bold or italic (a plain word in
    /// a bold paragraph), with its family when that is another, so the page's face for it is found again (LaTeX's bold
    /// and italic are families of their own); a subscript or a superscript where it is smaller than its line's text and
    /// below or above its baseline (`lineBaseline`), at its size and rise on the page; another color, or a family of
    /// another class (a name in Times among Arial, code in a monospace font) where neither bold nor italic says so
    /// (`otherLook`); underlined where the page draws a rule under it (`underlined`, `plainUnderlines`). Nil: the
    /// paragraph's own. `size`: the paragraph's type size (`TextParagraph.fontSize`): a script's size is kept against it.
    static func translationLook(_ own: TextRun, _ size: Double, _ line: (y: Double, size: Double), _ r: TextRun, underlined: Bool = false) -> TextLook? {
        if trimmed(r.text).isEmpty { return nil }
        var script: TextScript?
        var scriptSize: Double?, rise: Double?
        if line.size > 0 && r.fontSize <= 0.85 * line.size {
            let drop = r.origin.y - line.y // page space: down is positive
            if drop >= 0.08 * line.size {
                script = .sub
            } else if drop <= -0.12 * line.size {
                script = .superscript
            }
            if let script, size > 0 {
                // The page's own size and rise, within what a script can be (a crafted rise of a thousand ems is held to
                // one); both in the paragraph's ems, as the copy draws them (its size against the paragraph's, its rise in its ems).
                let ratio = min(max(r.fontSize / size, 0.4), 0.85)
                scriptSize = (ratio * size / scriptScale * 100).rounded(.toNearestOrEven) / 100
                rise = scriptRise(script, -drop / size)
            }
        }
        // A stand-in an earlier edit drew says its look only by its tag.
        let bold = r.tag?.bold ?? (r.standIn ? own.bold : r.bold)
        let italic = r.tag?.italic ?? (r.standIn ? own.italic : r.italic)
        let b: Bool? = bold != own.bold ? bold : nil, i: Bool? = italic != own.italic ? italic : nil
        let pageFace = !r.standIn && r.tag == nil && r.font != nil
        var family = (b != nil || i != nil) && pageFace && !sameFamily(r, own) ? FontNames.family(r.fontName) : nil
        let (otherFamily, color) = b == nil && i == nil ? otherLook(own, r) : (nil, otherColor(own, r))
        family = family ?? otherFamily
        let under: Bool? = underlined && r.text.utf16.contains(where: isLetterOrDigitUnit) ? true : nil
        if b == nil && i == nil && script == nil && family == nil && color == nil && under == nil { return nil }
        return TextLook(font: family, size: scriptSize, color: color, bold: b, italic: i, script: script, rise: rise, underline: under)
    }

    /// What else sets a run of letters apart from its paragraph's own text when bold and italic don't: a family of another
    /// class (serif, sans, monospace; not a symbol font, and TeX's roman beside a Times is the same class), its color.
    private static func otherLook(_ own: TextRun, _ r: TextRun) -> (family: String?, color: Int?) {
        let color = otherColor(own, r)
        guard !r.standIn, r.tag == nil, let font = r.font, let ownFont = own.font, !sameFamily(r, own) else { return (nil, color) }
        if r.text.utf16.filter(isLetterUnit).count < 2 || (font.flags & 4 != 0 && font.flags & 32 == 0) { return (nil, color) }
        return StandInFonts.kindOf(font.name, font.flags) != StandInFonts.kindOf(ownFont.name, ownFont.flags) ? (FontNames.family(r.fontName), color) : (nil, color)
    }

    /// A run's color where it is clearly another than its paragraph's (letters in it; a channel apart by more than 24 of 255).
    private static func otherColor(_ own: TextRun, _ r: TextRun) -> Int? {
        if !r.text.utf16.contains(where: isLetterUnit) { return nil }
        let a = own.color, c = r.color
        for shift in stride(from: 0, through: 16, by: 8) where abs((a >> shift & 0xFF) - (c >> shift & 0xFF)) > 24 { return c & 0xFFFFFF }
        return nil
    }

    /// .NET's `char.IsLetter` on one UTF-16 unit.
    static func isLetterUnit(_ u: UInt16) -> Bool {
        guard let s = Unicode.Scalar(u) else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// .NET's `char.IsLetterOrDigit` on one UTF-16 unit.
    static func isLetterOrDigitUnit(_ u: UInt16) -> Bool {
        isLetterUnit(u) || Unicode.Scalar(u)?.properties.generalCategory == .decimalNumber
    }
}
