import Foundation

/// The run's pass rate and its failures grouped by signature, each group with its smallest example (Windows' `FormsSummary`).
enum Summary {
    /// A failure's group: its kind, plus for exceptions the error's signature and for value problems the field kind and format.
    static func group(_ f: Failure) -> String {
        switch f.kind {
        case "read-exception", "fill-exception", "reopen-exception", "crash", "mupdf-cannot-read-saved":
            return "\(f.kind): \(f.detail)"
        case "field-not-found":
            return "field-not-found (\(match(#"a (\w+) field"#, f.detail)?[1] ?? ""))"
        case "hang", "pdfjs-cannot-read-filled", "value-rejected-by-script", "tab-order-changed", "encryption-lost", "encryption-changed",
             "pages-lost", "comments-lost", "bookmarks-lost", "widgets-changed-after-save":
            return f.kind
        default:
            let head = match(#"^[\w]+(?: [\w:/\-,. ]*?)?(?=[:(]|$)"#, f.detail)?[0] ?? ""
            return "\(f.kind): \(head.trimmingCharacters(in: .whitespaces))"
        }
    }

    private static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

    static func markdown(_ reports: [FormReport], size: (String) -> Int) -> String {
        let run = reports.filter { $0.status != "skip" }
        let passed = run.filter { $0.status == "pass" }.count
        let rate = run.isEmpty ? 0 : 100 * Double(passed) / Double(run.count)
        var out = "Forms run: \(run.count); passed: \(passed) (\(String(format: "%.1f", rate))%); failed: \(run.count - passed).\n"
        out += "Fields (Inkvolt): \(run.map(\.fields).reduce(0, +)); filled: \(run.map(\.filled).reduce(0, +)); "
        out += "typed: \(run.map(\.typed).reduce(0, +)); pdf.js lists: \(run.filter { $0.pdfJsFields >= 0 }.map(\.pdfJsFields).reduce(0, +)).\n"
        for (skip, group) in Dictionary(grouping: reports.filter { $0.status == "skip" }, by: { $0.skip ?? "" }).sorted(by: { $0.key < $1.key }) {
            out += "Skipped, \(skip): \(group.count) (\(group.prefix(8).map(\.name).joined(separator: ", ")))\n"
        }
        let calcForms = run.filter { $0.notes.contains { $0.hasPrefix("calculated fields") } }.count
        let calcStill = run.filter { $0.notes.contains { $0.hasPrefix("calc-not-updated") } }.map(\.name)
        out += "Calculated fields: \(calcForms) forms have them; in \(calcStill.count) none changed after filling (note only)"
        out += calcStill.isEmpty ? ".\n\n" : ": \(calcStill.joined(separator: ", ")).\n\n"

        out += "| Source | Pass |\n|---|---|\n"
        for (source, group) in Dictionary(grouping: run, by: { sourceOf($0.name) }).sorted(by: { $0.value.count > $1.value.count }) {
            out += "| \(source) | \(group.filter { $0.status == "pass" }.count) / \(group.count) |\n"
        }
        out += "\n| Group | Forms | Failures | Smallest example (form · field · detail) |\n|---|---:|---:|---|\n"
        var groups: [String: [(report: FormReport, failure: Failure)]] = [:]
        for r in run { for f in r.failures { groups[group(f), default: []].append((r, f)) } }
        func formsOf(_ list: [(report: FormReport, failure: Failure)]) -> [String] { Array(Set(list.map(\.report.name))).sorted() }
        let sorted = groups.sorted { a, b in
            let ca = formsOf(a.value).count, cb = formsOf(b.value).count
            return ca != cb ? ca > cb : a.key < b.key
        }
        for (key, list) in sorted {
            let smallest = list.min { size($0.report.name) < size($1.report.name) }
            out += "| \(cell(key)) | \(formsOf(list).count) | \(list.count) | \(cell(smallest?.report.name ?? "")) · `\(cell(smallest?.failure.field ?? ""))` · \(cell(smallest?.failure.detail ?? "")) |\n"
        }
        out += "\nForms per group:\n"
        for (key, list) in sorted { out += "- \(key): \(formsOf(list).joined(separator: ", "))\n" }
        return out
    }

    /// The form's source, from its name's prefix.
    static func sourceOf(_ name: String) -> String { name.split(separator: "-").first.map(String.init) ?? name }
}
