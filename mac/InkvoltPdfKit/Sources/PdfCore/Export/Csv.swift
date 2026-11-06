import Foundation
import PrintCore

/// Comma-separated values (RFC 4180; the Windows app's `Csv`): fields with a comma, quote, line break or edge spaces are
/// quoted, quotes doubled. Written as UTF-8 with a byte order mark and CRLF line ends, so Excel opens accents and other
/// scripts right. Read leniently: a byte order mark, LF or CRLF, quoted line breaks, and a semicolon or tab separator
/// (Excel's in many locales) found from the header line.
public enum Csv {
    /// Largest CSV read (rows of a form merge, comments).
    public static let maxBytes = 64 * 1024 * 1024
    public static let maxRows = 1_000_000

    public static func write(_ rows: [[String]]) -> [UInt8] {
        var sb = ""
        for row in rows {
            sb += row.map(quote).joined(separator: ",")
            sb += "\r\n"
        }
        return [0xEF, 0xBB, 0xBF] + Array(sb.utf8)
    }

    /// A cell starting with =, +, - or @ would run as a formula in a spreadsheet, quoted or not (CSV injection): a tab
    /// goes in front, which `read` takes off again. Numbers (-3, +1.5) stay as they are.
    public static func quote(_ cell: String) -> String {
        var value = cell
        if let first = value.unicodeScalars.first, "=+-@".unicodeScalars.contains(first), !isPlainNumber(value) {
            value = "\t" + value
        }
        let scalars = value.unicodeScalars
        let needs = !value.isEmpty && (scalars.first == " " || scalars.last == " " || scalars.first == "\t")
            || scalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == ";" }
        return needs ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    /// A decimal number a spreadsheet reads as a number ("-3", "+1.5e2"): digits, a point, an exponent and signs only.
    private static func isPlainNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.unicodeScalars.allSatisfy({ "0123456789.eE+-".unicodeScalars.contains($0) }), let d = Double(t) else { return false }
        return d.isFinite
    }

    /// The text of CSV bytes: UTF-8 (with or without a byte order mark), UTF-16 with one, else Windows-1252.
    public static func decode(_ data: [UInt8]) -> String {
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xFE {
            return String(data: Data(data[2...]), encoding: .utf16LittleEndian) ?? ""
        }
        if data.count >= 2 && data[0] == 0xFE && data[1] == 0xFF {
            return String(data: Data(data[2...]), encoding: .utf16BigEndian) ?? ""
        }
        let start = data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0
        if let text = String(validating: data[start...], as: UTF8.self) { return text }
        return String(data: Data(data), encoding: .windowsCP1252) ?? String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    /// The rows of `text`; empty lines are left out. Throws `PdfEditError` past `maxRows`.
    public static func read(_ text: String) throws -> [[String]] {
        let chars = Array(text.unicodeScalars)
        let sep = separator(chars)
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false, wasQuoted = false

        func endField() {
            var value = String(field)
            // The guard `write` puts in front of formula-like values comes off again.
            let s = value.unicodeScalars
            if s.count > 1, s.first == "\t", let second = s.dropFirst().first, "=+-@".unicodeScalars.contains(second) {
                value = String(String.UnicodeScalarView(s.dropFirst()))
            }
            row.append(value)
            field = String.UnicodeScalarView()
            wasQuoted = false
        }
        func endRow() throws {
            endField()
            if row.count > 1 || !row[0].isEmpty {
                if rows.count >= maxRows { throw PdfEditError(loc("The file has more than {0} rows.", CoreLanguage.number(maxRows))) }
                rows.append(row)
            }
            row = []
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty && !wasQuoted {
                quoted = true
                wasQuoted = true
            } else if c == sep {
                endField()
            } else if c == "\r" || c == "\n" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                try endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || wasQuoted { try endRow() }
        return rows
    }

    /// Comma, else a semicolon or a tab when the first line has more of those (outside quotes).
    private static func separator(_ chars: [Unicode.Scalar]) -> Unicode.Scalar {
        var commas = 0, semis = 0, tabs = 0
        var quoted = false
        for c in chars {
            if c == "\"" {
                quoted.toggle()
            } else if !quoted {
                if c == "\r" || c == "\n" { break }
                if c == "," { commas += 1 } else if c == ";" { semis += 1 } else if c == "\t" { tabs += 1 }
            }
        }
        return semis > commas && semis >= tabs ? ";" : tabs > commas ? "\t" : ","
    }
}
