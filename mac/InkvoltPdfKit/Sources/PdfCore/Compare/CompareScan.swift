import Foundation

/// Scans on one side of a comparison: recognized words as page text, and the slips recognizers make (the Windows app's
/// `CompareScan`).
public enum CompareScan {
    /// Recognized words as a page's text, in the order they were read: a new line where the next word sits on another row
    /// or goes back along the line (measured along the words' own angle, so a skewed page reads as lines). Each character
    /// gets its share of the word's box, along the word's angle.
    public static func pageTextOf(_ words: [OcrWord]) -> PageText {
        var lines: [[(String, RectD)]] = []
        var directions: [(Double, Double)] = []
        var line: [(String, RectD)] = []
        var last: (along: Double, across: Double, height: Double)?
        var direction = (1.0, 0.0)
        for w in words {
            if w.text.isEmpty { continue }
            let radians = (w.angle.isFinite ? w.angle : 0) * Double.pi / 180
            let sin = Foundation.sin(radians), cos = Foundation.cos(radians)
            let cx = w.rect.x + w.rect.width / 2, cy = w.rect.y + w.rect.height / 2
            let along = cx * cos + cy * sin
            let across = -cx * sin + cy * cos
            if let l = last, abs(across - l.across) > max(l.height, w.rect.height) / 2 || along < l.along {
                lines.append(line)
                directions.append(direction)
                line = []
            } else if last != nil {
                // The space between two words of a line: a thin box where the word starts.
                line.append((" ", box(cx - w.rect.width / 2 * cos, cy - w.rect.width / 2 * sin, 0.5, w.rect.height, sin, cos)))
            }
            direction = (cos, sin)

            // Whole characters (a surrogate pair or combining mark stays with its letter).
            let parts = w.text.map(String.init)
            let each = w.rect.width / Double(parts.count)
            for (i, part) in parts.enumerated() {
                let offset = (Double(i) + 0.5) * each - w.rect.width / 2
                line.append((part, box(cx + offset * cos, cy + offset * sin, each, w.rect.height, sin, cos)))
            }
            last = (along, across, w.rect.height)
        }
        if !line.isEmpty {
            lines.append(line)
            directions.append(direction)
        }
        return lines.isEmpty ? .empty : PageText(lines, directions: directions)
    }

    /// The upright box around a box of this size turned about its centre.
    private static func box(_ cx: Double, _ cy: Double, _ width: Double, _ height: Double, _ sin: Double, _ cos: Double) -> RectD {
        let w = abs(width * cos) + abs(height * sin)
        let h = abs(width * sin) + abs(height * cos)
        return RectD(cx - w / 2, cy - h / 2, w, h)
    }

    /// Whether two readings of the same place differ only in what recognizers confuse: l, I, 1 and |; O and 0; S and 5;
    /// B and 8; rn and m; case. A heuristic like suspect words, never a score: such a change stays listed, marked as maybe
    /// misread.
    public static func looksLikeASlip(_ a: String, _ b: String) -> Bool { a != b && blurred(a) == blurred(b) }

    /// Marks only: a stray speck read as punctuation.
    public static func isOnlyMarks(_ s: String) -> Bool {
        !s.isEmpty && !s.unicodeScalars.contains(where: isLetterOrDigit)
    }

    /// .NET's `char.IsLetterOrDigit`: a letter or a decimal digit.
    static func isLetterOrDigit(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }

    /// Words a scan doesn't have, enough of them to fill a line: a recognizer now and then skips a whole line that is
    /// plainly on the page, so this may not have been removed at all.
    public static func couldBeALostLine(_ s: String) -> Bool { s.split(separator: " ").count >= 6 }

    private static func blurred(_ s: String) -> String {
        var out = ""
        for raw in s.replacingOccurrences(of: "rn", with: "m").lowercased() {
            if raw.isWhitespace { continue }
            switch raw {
            case "i", "1", "|", "!": out.append("l")
            case "0": out.append("o")
            case "5": out.append("s")
            case "8": out.append("b")
            default: out.append(raw)
            }
        }
        return out
    }
}
