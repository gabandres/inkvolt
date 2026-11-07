import Foundation

/// The values the harness puts in fields, by what the field's scripts expect (Windows' `FormsHarness.TextValue`).
enum FieldValues {
    /// What kind of value a text field's format or keystroke script expects: number:<sepStyle>:<decimals>, percent,
    /// date:<format>, time, zip, zip4, phone, ssn, mask:<mask>, custom (other JavaScript) or plain.
    static func formatOf(format: String?, keystroke: String?) -> String {
        let s = (format ?? "") + "\n" + (keystroke ?? "")
        if s.allSatisfy(\.isWhitespace) { return "plain" }
        if let m = match(#"AFNumber_Format\s*\(\s*(\d+)\s*,\s*(\d)"#, s) { return "number:\(m[2]):\(m[1])" }
        if let m = match(#"AFNumber_Keystroke\s*\(\s*(\d+)\s*,\s*(\d)"#, s) { return "number:\(m[2]):\(m[1])" }
        if isMatch("AFNumber_(Format|Keystroke)", s) { return "number:0" }
        if isMatch("AFPercent_(Format|Keystroke)", s) { return "percent" }
        if let m = match(#"AFDate_(?:Format|Keystroke)Ex\s*\(\s*["']([^"']*)["']"#, s) { return "date:" + m[1] }
        if let m = match(#"AFDate_(?:Format|Keystroke)\s*\(\s*(\d+)"#, s) { return "date:" + dateFormat(Int(m[1]) ?? -1) }
        if isMatch("AFTime_(Format|Keystroke)", s) { return "time" }
        if let m = match(#"AFSpecial_(?:Format|Keystroke)\s*\(\s*(\d)"#, s) {
            switch m[1] {
            case "0": return "zip"
            case "1": return "zip4"
            case "2": return "phone"
            default: return "ssn"
            }
        }
        if let m = match(#"AFSpecial_KeystrokeEx\s*\(\s*["']([^"']*)["']"#, s) { return "mask:" + m[1] }
        return "custom"
    }

    private static func dateFormat(_ n: Int) -> String {
        let formats = ["m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy", "mmmm-yy",
                       "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM"]
        return formats.indices.contains(n) ? formats[n] : "mm/dd/yyyy"
    }

    static func textValue(_ ordinal: Int, _ format: String, maxLen: Int, multiline: Bool, comb: Bool) -> String {
        let number = String(1000 + ordinal * 7 % 9000)
        var value: String
        if format.hasPrefix("number:2") || format.hasPrefix("number:3") {
            value = number + ",5" // a Spanish-format amount as its readers type it: decimal comma
        } else if format == "percent" {
            value = "12"
        } else if format.hasPrefix("number") {
            value = number
        } else if format == "time" {
            value = "13:30"
        } else if format == "zip" {
            value = "00901"
        } else if format == "zip4" {
            value = "009011234"
        } else if format == "phone" {
            value = "7875551234"
        } else if format == "ssn" {
            value = "123456789"
        } else if format.hasPrefix("date:") {
            value = formatDate(String(format.dropFirst(5)))
        } else if format.hasPrefix("mask:") {
            value = fillMask(String(format.dropFirst(5)))
        } else if comb {
            value = "123456789"
        } else if multiline {
            value = "Ink\(ordinal)\nline two"
        } else {
            value = "Ink\(ordinal)"
        }
        if maxLen > 0 && value.count > maxLen {
            let short = "I\(ordinal)"
            value = format == "plain" && maxLen >= 2 ? String(short.prefix(maxLen)) : String((0..<maxLen).map { Character(String($0 % 9 + 1)) })
        }
        return value
    }

    /// The date 2024-03-15 13:30 in an AFDate format.
    private static func formatDate(_ format: String) -> String {
        let words: [(String, String)] = [
            ("yyyy", "2024"), ("yy", "24"), ("mmmm", "March"), ("mmm", "Mar"), ("mm", "03"), ("m", "3"), ("dddd", "Friday"), ("ddd", "Fri"),
            ("dd", "15"), ("d", "15"), ("HH", "13"), ("H", "13"), ("hh", "1"), ("h", "1"), ("MM", "30"), ("M", "30"), ("ss", "00"), ("s", "00"),
            ("tt", "pm"), ("t", "p"),
        ]
        var out = "", rest = Substring(format)
        outer: while !rest.isEmpty {
            for (key, value) in words where rest.hasPrefix(key) {
                out += value
                rest = rest.dropFirst(key.count)
                continue outer
            }
            out.append(rest.removeFirst())
        }
        return out
    }

    private static func fillMask(_ mask: String) -> String {
        var out = "", n = 1
        for c in mask {
            switch c {
            case "9":
                out += String(n % 10)
                n += 1
            case "A", "X", "*", "O": out += "K"
            default: out.append(c)
            }
        }
        return out
    }

    /// How Acrobat shows an amount typed with a decimal comma in a sepStyle 2 (1.234,56) or 3 (1234,56) field with nDec
    /// decimals: 1007,5 → 1.007,50 or 1007,50 (or 1008 with no decimals). Nil for other formats or values.
    static func spanishAmount(_ format: String, _ typed: String) -> String? {
        guard let m = match(#"^number:([23]):(\d+)$"#, format), typed.contains(","), let dec = Int(m[2]), dec <= 8,
              let v = Decimal(string: typed.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US")) else { return nil }
        var rounded = Decimal()
        var input = v
        NSDecimalRound(&rounded, &input, dec, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = dec
        formatter.maximumFractionDigits = dec
        formatter.minimumIntegerDigits = 1
        formatter.usesGroupingSeparator = false
        let text = formatter.string(from: rounded as NSDecimalNumber) ?? typed
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var whole = String(parts[0])
        if m[1] == "2" {
            var i = whole.count - 3
            while i > 0 {
                whole.insert(".", at: whole.index(whole.startIndex, offsetBy: i))
                i -= 3
            }
        }
        return parts.count > 1 ? whole + "," + parts[1] : whole
    }
}
