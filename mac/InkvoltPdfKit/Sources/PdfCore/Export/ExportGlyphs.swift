import Foundation

/// A character as a page draws it: its text, its box (page space), its look and the line it belongs to.
public struct ExportGlyph: Equatable, Sendable {
    public var text: String
    public var rect: RectD
    public var look: ExportSpan

    public init(_ text: String, _ rect: RectD, _ look: ExportSpan) {
        self.text = text
        self.rect = rect
        self.look = look
    }
}

/// Fixes to a page's characters before they become lines: accents drawn as separate characters joined to their letters,
/// and runs of dots or rules (a form's fill-in lines) turned into one leader.
public enum ExportGlyphs {
    /// A dot leader (a run of dots); its box spans the run. Laid out as a tab with dots up to where it ended.
    public static let dotLeader: Unicode.Scalar = "\u{E001}"
    /// A rule to write on ("______"), laid out as a tab with an underline.
    public static let lineLeader: Unicode.Scalar = "\u{E002}"
    /// A dashed rule ("-------"), laid out as a tab with hyphens.
    public static let dashLeader: Unicode.Scalar = "\u{E003}"

    public static func isLeader(_ c: Unicode.Scalar) -> Bool { c == dotLeader || c == lineLeader || c == dashLeader }

    /// A string holding a leader.
    static func hasLeader(_ s: String) -> Bool { s.unicodeScalars.contains(where: isLeader) }

    /// Whether a glyph is an accent standing alone (a space or the line's end on both sides): one no letter took. Some
    /// fonts name other shapes after accents ("dotaccent" drawing "="), so such a glyph is worth a look at its shape.
    public static func isLoneAccent(_ line: [ExportGlyph], _ k: Int) -> Bool {
        guard let c = line[k].text.single, combining[c] != nil else { return false }
        return (k == 0 || line[k - 1].text.isBlank) && (k == line.count - 1 || line[k + 1].text.isBlank)
    }

    /// What a glyph draws, from its rendering (alpha per pixel, `width` × `height`, `pixelsPerPoint`) and its type size:
    /// "=" for two level bars as wide as each other (half the size across at least), "−" for one such bar; nil for
    /// anything else (an accent's dot or stroke is small).
    public static func drawnAs(_ alpha: [UInt8], _ width: Int, _ height: Int, _ pixelsPerPoint: Double, _ size: Double) -> String? {
        var left = width, right = -1
        var rows: [(y: Int, from: Int, to: Int)] = []
        for y in 0..<height {
            var from = -1, to = -1, ink = 0
            for x in 0..<width where alpha[y * width + x] > 96 {
                if from < 0 { from = x }
                to = x
                ink += 1
            }
            if from < 0 { continue }
            if Double(ink) < 0.8 * Double(to - from + 1) { return nil } // gaps in a row: dots side by side ("¨"), not a bar
            rows.append((y, from, to))
            (left, right) = (min(left, from), max(right, to))
        }
        if rows.isEmpty || Double(right - left + 1) < 0.35 * size * pixelsPerPoint { return nil }
        // Runs of rows with ink, each a bar when it is thin and spans most of the ink's width.
        var bars: [(top: Int, bottom: Int)] = []
        for r in rows {
            if let last = bars.last, r.y == last.bottom + 1 { bars[bars.count - 1] = (last.top, r.y) } else { bars.append((r.y, r.y)) }
        }
        let inkWidth = Double(right - left + 1)
        for (top, bottom) in bars {
            if Double(bottom - top + 1) > 0.2 * size * pixelsPerPoint { return nil } // not thin: a letter's shape
            let span = rows.filter { $0.y >= top && $0.y <= bottom }.map { $0.to - $0.from + 1 }.max()!
            if Double(span) < 0.8 * inkWidth { return nil }
        }
        switch bars.count {
        case 2: return "="
        case 1: return "\u{2212}"
        default: return nil
        }
    }

    /// Spacing accents a typesetter (TeX, older PostScript drivers) draws over or under a letter, and their combining forms.
    static let combining: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{B4}": "\u{301}", "`": "\u{300}", "\u{2C6}": "\u{302}", "\u{2DC}": "\u{303}", "\u{A8}": "\u{308}", "\u{2C7}": "\u{30C}",
        "\u{2DA}": "\u{30A}", "\u{2D8}": "\u{306}", "\u{2DD}": "\u{30B}", "\u{AF}": "\u{304}", "\u{2D9}": "\u{307}", "\u{B8}": "\u{327}",
        "\u{2DB}": "\u{328}",
    ]

    /// Accents that go under the letter (cedilla, ogonek); the rest go over it.
    private static func below(_ accent: Unicode.Scalar) -> Bool { accent == "\u{B8}" || accent == "\u{2DB}" }

    private struct At: Hashable {
        var line: Int
        var index: Int
    }

    /// Joins accents drawn as their own characters (often with no width, placed over the letter by a kern back) to the
    /// letter they sit on: "Direcci" "´" "on" becomes "Dirección", and a capital's raised accent, which MuPDF reads as a
    /// line of its own above, goes onto its letter too ("PREDICACI" "´" "ON" → "PREDICACIÓN"). A space MuPDF put before
    /// the accent (the kern back looked like a gap) goes as well. A dotless i or j takes the accent as i or j. Before
    /// that, runs of four or more dots, underscores or dashes (spaces between them allowed), or of one accent repeated (a
    /// form's fonts sometimes name their leader dot "ogonek"), become one leader character spanning the run. Only
    /// left-to-right lines are changed; the result has one list per line given (a line of only an accent ends empty).
    public static func compose(_ lines: [[ExportGlyph]], leftToRight: ((Int) -> Bool)? = nil) -> [[ExportGlyph]] {
        let ltr = leftToRight ?? { _ in true }
        // Leaders first: a run of one accent repeated is a leader, not accents for the letters around it.
        var result = lines.indices.map { ltr($0) ? leaders(lines[$0]) : lines[$0] }
        // Letters that can take an accent, by line.
        var letters: [At] = []
        for i in result.indices where ltr(i) {
            for k in result[i].indices {
                // "ˆ" and "ˇ" are letters to .NET (modifier letters): accents, not letters to put one on.
                if let c = result[i][k].text.single, c.isLetter, combining[c] == nil { letters.append(At(line: i, index: k)) }
            }
        }
        var removed = Set<At>()
        for i in result.indices where ltr(i) {
            for k in result[i].indices {
                let g = result[i][k]
                guard let accent = g.text.single, let mark = combining[accent] else { continue }
                let size = max(1, g.look.size)
                // One set over a letter by a kern back has little or no width; one with its own width (TeX's \accent keeps
                // it and kerns around it) must sit over its letter in the same line, centered on it.
                let wide = g.rect.width > 0.3 * size
                let cx = g.rect.centerX
                var best: At?
                var bestDistance = Double.greatestFiniteMagnitude
                for at in letters {
                    if removed.contains(at) { continue }
                    let b = result[at.line][at.index]
                    if abs(b.look.size - g.look.size) > 0.35 * size { continue }
                    let inset = 0.1 * b.rect.width
                    if cx < b.rect.x + inset || cx > b.rect.right - inset { continue }
                    // Over the letter (raised, or level with it), or under it for a cedilla.
                    let dy = g.rect.centerY - b.rect.centerY
                    if abs(dy) > 1.2 * size { continue }
                    if below(accent) ? dy < -0.2 * size : dy > 0.2 * size { continue }
                    if wide && abs(dy) > 0.95 * size { continue }
                    let distance = abs(dy) + abs(cx - b.rect.centerX)
                    if distance < bestDistance { (best, bestDistance) = (at, distance) }
                }
                guard let at = best else { continue }
                let baseGlyph = result[at.line][at.index]
                let letter = baseGlyph.text == "\u{131}" ? "i" : baseGlyph.text == "\u{237}" ? "j" : baseGlyph.text
                var joined = baseGlyph
                joined.text = (letter + String(Character(mark))).precomposedStringWithCanonicalMapping
                result[at.line][at.index] = joined
                removed.insert(At(line: i, index: k))
                // MuPDF reads the kern back before an accent as a space: drop it when the letter starts where the one
                // before it ended (no room for a space), not a real space between words ("en ´areas").
                var s = k - 1
                while s >= 1 && s >= k - 2 {
                    defer { s -= 1 }
                    let sp = result[i][s]
                    if removed.contains(At(line: i, index: s)) { continue }
                    if !sp.text.isBlank { break }
                    let before = result[i][s - 1]
                    if at.line == i && !before.text.isBlank && baseGlyph.rect.x < before.rect.right + 0.15 * size {
                        removed.insert(At(line: i, index: s))
                    }
                    break
                }
            }
        }
        if removed.isEmpty { return result }
        for i in result.indices where removed.contains(where: { $0.line == i }) {
            result[i] = result[i].indices.filter { !removed.contains(At(line: i, index: $0)) }.map { result[i][$0] }
        }
        return result
    }

    private static func leaderKind(_ text: String) -> Unicode.Scalar? {
        switch text {
        case ".", "\u{B7}", "\u{2024}", "\u{2025}", "\u{2026}", "\u{2022}": return dotLeader
        case "_", "\u{2017}": return lineLeader
        case "-", "\u{2013}", "\u{2014}", "\u{2012}", "\u{2212}": return dashLeader
        default:
            if let c = text.single, combining[c] != nil { return dotLeader }
            return nil
        }
    }

    /// Runs of four or more of one leader character (spaces between allowed) as one leader glyph.
    private static func leaders(_ line: [ExportGlyph]) -> [ExportGlyph] {
        var output: [ExportGlyph] = []
        output.reserveCapacity(line.count)
        var k = 0
        while k < line.count {
            let g = line[k]
            guard let kind = leaderKind(g.text) else {
                output.append(g)
                k += 1
                continue
            }
            // Extend over the same character, with spaces between allowed; "..." and "--" stay text.
            var end = k
            var count = 1
            var j = k + 1
            while j < line.count {
                if line[j].text == g.text {
                    end = j
                    count += 1
                } else if !line[j].text.isBlank {
                    break
                }
                j += 1
            }
            var box = g.rect
            if end > k { for j in k + 1...end { box = box.union(line[j].rect) } }
            // Not an ellipsis or a rule typed in text: short runs, runs in a monospaced font ("+-----+"), runs between
            // letters ("wait....then").
            func letterAt(_ j: Int) -> Bool { j >= 0 && j < line.count && (line[j].text.unicodeScalars.first?.isLetterOrDigit ?? false) }
            if count < 4 || box.width < 2.5 * max(1, g.look.size) || g.look.mono || (letterAt(k - 1) && letterAt(end + 1)) {
                output.append(g)
                k += 1
                continue
            }
            output.append(ExportGlyph(String(Character(kind)), box, g.look))
            k = end + 1
        }
        return output
    }
}
