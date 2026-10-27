import Foundation

/// Turns PDF font names ("ABCDEF+Arial-BoldMT", "TimesNewRomanPSMT") into family names Word knows ("Arial", "Times New
/// Roman") (the Windows app's `FontNames`, for the exports to come).
public enum FontNames {
    private static let known: [String: String] = [
        "helvetica": "Arial", "helv": "Arial", "arial mt": "Arial", "times": "Times New Roman", "times roman": "Times New Roman",
        "tim": "Times New Roman", "courier": "Courier New", "cour": "Courier New", "zapf dingbats": "Wingdings",
    ]

    private static let styleWords: Set<String> = [
        "bold", "italic", "oblique", "regular", "book", "medium", "light", "semibold", "demi", "black", "heavy", "condensed", "narrow",
    ]

    private static func has(_ name: String, _ part: String) -> Bool { name.range(of: part, options: .caseInsensitive) != nil }

    public static func looksBold(_ name: String) -> Bool { has(name, "Bold") || has(name, "Black") || has(name, "Heavy") || has(name, "Demi") }

    public static func looksItalic(_ name: String) -> Bool { has(name, "Italic") || has(name, "Oblique") }

    /// The family name for Word: the subset tag, style suffix and PostScript "MT"/"PS" endings dropped, words spaced.
    public static func family(_ pdfName: String) -> String {
        var name = pdfName.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(name)
        if chars.count > 7 && chars[6] == "+" && chars.prefix(6).allSatisfy({ $0.isASCII && $0.isUppercase }) { name = String(chars.dropFirst(7)) }
        if let cut = name.firstIndex(where: { $0 == "," || $0 == "-" }), cut > name.startIndex { name = String(name[..<cut]) }
        for suffix in ["PSMT", "PS", "MT"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        if !name.contains(" ") { name = spaceWords(name) }
        // "Arial Bold" → "Arial" (a style glued to the family); never the whole name.
        var words = name.split(separator: " ").map(String.init)
        while words.count > 1 && styleWords.contains(words[words.count - 1].lowercased()) { words.removeLast() }
        name = words.joined(separator: " ")
        return known[name.lowercased()] ?? name
    }

    /// "TimesNewRoman" → "Times New Roman"; runs of capitals stay together ("SegoeUI" → "Segoe UI").
    private static func spaceWords(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        for i in c.indices {
            if i > 0 && c[i].isUppercase && (c[i - 1].isLowercase || (i + 1 < c.count && c[i + 1].isLowercase && c[i - 1].isUppercase)) {
                out.append(" ")
            }
            out.append(c[i])
        }
        return out
    }
}
