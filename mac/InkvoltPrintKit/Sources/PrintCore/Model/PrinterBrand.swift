import Foundation

public enum PrinterBrand: Sendable {
    case other, hp, canon, epson, brother

    /// The maker, from text the printer reports (IPP make-and-model, eSCL MakeAndModel / Manufacturer, DNS-SD `ty`).
    public static func detect(_ texts: String?...) -> PrinterBrand {
        for t in texts {
            guard let t, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if word(t, "Hewlett-Packard") || word(t, "HP") { return .hp }
            if word(t, "Canon") { return .canon }
            if word(t, "Epson") { return .epson }
            if word(t, "Brother") { return .brother }
        }
        return .other
    }

    public var name: String {
        switch self {
        case .hp: "HP"
        case .canon: "Canon"
        case .epson: "Epson"
        case .brother: "Brother"
        case .other: ""
        }
    }

    /// `word` in `text`, case-insensitive, with no letter or digit right before or after it ("HP" isn't in "SHPX").
    private static func word(_ text: String, _ word: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: word, options: .caseInsensitive, range: from..<text.endIndex) {
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : nil
            if !isWordChar(before) && !isWordChar(after) { return true }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
}
