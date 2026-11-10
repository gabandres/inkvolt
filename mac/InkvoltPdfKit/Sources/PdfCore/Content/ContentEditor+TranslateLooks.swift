import Foundation

extension ContentEditor {
    /// A line's own baseline and size, as most of its characters sit on it (not a big name set higher, nor a script).
    static func lineBaseline(_ line: PLine) -> (y: Double, size: Double) {
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
    /// bold or italic where the paragraph's own text (`own`) isn't (with its family when that is another, so the page's
    /// face for it is found again: LaTeX's bold and italic are families of their own); a subscript or a superscript where
    /// it is smaller than its line's text and below or above its baseline (`lineBaseline`). Nil: the paragraph's own.
    static func translationLook(_ own: TextRun, _ line: (y: Double, size: Double), _ r: TextRun) -> TextLook? {
        if trimmed(r.text).isEmpty { return nil }
        var script: TextScript?
        if line.size > 0 && r.fontSize <= 0.85 * line.size {
            let drop = r.origin.y - line.y // page space: down is positive
            if drop >= 0.08 * line.size {
                script = .sub
            } else if drop <= -0.12 * line.size {
                script = .superscript
            }
        }
        // A stand-in an earlier edit drew says its look only by its tag.
        let bold = r.tag?.bold ?? (r.standIn ? own.bold : r.bold)
        let italic = r.tag?.italic ?? (r.standIn ? own.italic : r.italic)
        let b = bold && !own.bold
        let i = italic && !own.italic
        if !b && !i && script == nil { return nil }
        let family = (b || i) && !r.standIn && r.tag == nil && r.font != nil && !sameFamily(r, own) ? FontNames.family(r.fontName) : nil
        return TextLook(font: family, bold: b ? true : nil, italic: i ? true : nil, script: script)
    }
}
