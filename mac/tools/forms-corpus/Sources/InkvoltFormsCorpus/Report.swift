import Foundation

/// One thing that went wrong with a form: `kind` is the signature it is grouped by.
struct Failure: Codable {
    var kind: String
    var field: String
    var detail: String
}

/// What the harness plans to put in a field and what it then finds there.
struct Planned: Codable {
    var name: String
    var kind: String
    var sent: String
    var state: String?
    var password: Bool
    var format: String
    var stored = ""
    var display = ""
}

/// One form's run: its fields, what was filled, the failures and notes (Windows' `FormReport`).
struct FormReport: Codable {
    var name = ""
    var status = "pass"
    var skip: String?
    var fields = 0
    var widgets = 0
    var pdfJsFields = -1
    var filled = 0
    var typed = 0
    var bookmarksBefore = 0
    var bookmarksAfter = 0
    var ms = 0
    var features: [String] = []
    var plan: [Planned] = []
    var names: [String] = []
    /// Widgets per field on the page view (`FormEditor.read`).
    var widgetCounts: [String: Int] = [:]
    var failures: [Failure] = []
    var notes: [String] = []

    mutating func fail(_ kind: String, _ field: String, _ detail: String) {
        if failures.filter({ $0.kind == kind }).count >= 25 { return } // enough to see the pattern
        failures.append(Failure(kind: kind, field: field, detail: detail.count > 300 ? String(detail.prefix(300)) + "…" : detail))
    }
}

// Small text helpers the harness shares.

/// The first capture groups of `pattern`'s first match in `s` (group 0 first), nil without a match.
func match(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
}

func isMatch(_ pattern: String, _ s: String) -> Bool { match(pattern, s) != nil }

/// Without any white space.
func normalize(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isWhitespace })) }

func digits(_ s: String) -> String { String(s.filter { $0.isASCII && $0.isNumber }) }

/// Line ends as one "\n".
func unifiedLines(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }

/// A value shortened and with its line ends shown, for a report.
func esc(_ s: String, _ max: Int = 40) -> String {
    (s.count > max ? String(s.prefix(max)) + "…" : s).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
}

/// An error's signature for grouping: its type and its text with the numbers blanked.
func signature(_ error: Error) -> String {
    let text = String(describing: error).split(separator: "\n").first.map(String.init) ?? ""
    let blanked = text.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
    return "\(type(of: error)): \(blanked)"
}
