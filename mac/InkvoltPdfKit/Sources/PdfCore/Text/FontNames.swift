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

    /// Whether a font's name says bold: "Bold", "Black", "Heavy", "Demi" in it; URW's "Medi" style ("NimbusRomNo9L-Medi",
    /// "-MediItal": the bold of its Times); TeX's bold Computer Modern ("CMBX10", "CMBXTI10", "CMMIB10").
    public static func looksBold(_ name: String) -> Bool {
        has(name, "Bold") || has(name, "Black") || has(name, "Heavy") || has(name, "Demi")
            || urwMedium.isMatch(styleOf(name)) || texBold.isMatch(untagged(name))
    }

    /// Whether a font's name says italic: "Italic", "Oblique" in it; a style ending in URW's "Ital" ("-ReguItal") or
    /// Adobe's "It" ("MinionPro-It", "-BoldIt"); TeX's italic, slanted and math italic Computer Modern ("CMTI10",
    /// "CMSL10", "CMMI10": the "d" of "d_model").
    public static func looksItalic(_ name: String) -> Bool {
        has(name, "Italic") || has(name, "Oblique") || styleItalic.isMatch(styleOf(name)) || texItalic.isMatch(untagged(name))
    }

    /// A font name without its subset tag ("ABCDEF+").
    private static func untagged(_ name: String) -> String {
        let u = Array(name.utf16)
        guard u.count > 7, u[6] == 43, u.prefix(6).allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return name }
        return String(decoding: u.dropFirst(7), as: UTF16.self)
    }

    /// The style part of a font name: after its last '-' or ',' ("Medi" of "NimbusRomNo9L-Medi"); empty when it has none.
    private static func styleOf(_ name: String) -> String {
        guard let cut = name.lastIndex(where: { $0 == "-" || $0 == "," }) else { return "" }
        return name[name.index(after: cut)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let urwMedium = Rx("^Medi(Ital)?$", ignoreCase: true)

    // A style of capitalized words ending in "Ital" or "It" ("ReguItal", "MediItal", "BoldIt", "SemiboldIt", "It"); not a
    // word that merely ends so ("Digital", "Capital", "Orbital", "Bandit").
    private static let styleItalic = Rx("^(?:[A-Z][a-z]*)*?(?:Ital|It)$")

    private static let texBold = Rx(#"^CM(?:BX(?:SL|TI)?|B|MIB|BSY|SSBX)\d+$"#)

    private static let texItalic = Rx(#"^CM(?:MI|MIB|TI|SL|BXTI|BXSL|ITT|SSI|U)\d+$"#)

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
