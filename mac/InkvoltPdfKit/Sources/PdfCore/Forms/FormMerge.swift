import Foundation
import PrintCore

/// Where a merge's forms go and what they are called.
public struct FormMergeOptions: Sendable {
    public static let defaultTemplate = "<<name>> <<n:3>>"

    public var outputFolder: String
    /// The file name of each form (without .pdf): Batch's tokens (<<name>> the form's name, <<n>> the row's number,
    /// <<n:3>> padded, <<date>>) and any column of the CSV (<<Last name>>: that row's value; Batch's tokens win over
    /// columns of the same name).
    public var nameTemplate = defaultTemplate
    /// A name that is taken gets a number ("form (2).pdf"); with false, files of the same name are replaced.
    public var neverOverwrite = true
    /// The forms are flattened: values become part of the page and can't be changed.
    public var flatten = false
    /// For <<date>> in names.
    public var date = Date()

    public init(outputFolder: String, nameTemplate: String = defaultTemplate) {
        self.outputFolder = outputFolder
        self.nameTemplate = nameTemplate
    }
}

/// A row of a merge. `row`: its number among the data rows (from 1; the header isn't counted); `file`: the form made (nil
/// when the row failed); `problems`: why it failed, each value refused with its field and why.
public struct FormMergeRow: Equatable, Sendable {
    public var row: Int
    public var file: String?
    public var problems: [String]
}

/// What a merge did. `unknownColumns`: columns no field of the form has (their values are left out).
public struct FormMergeReport: Sendable {
    public var rows: Int
    public var made: [FormMergeRow]
    public var failed: [FormMergeRow]
    public var unknownColumns: [String]
    public var stopped: Bool

    /// "198 forms made, 2 rows failed."
    public var text: String {
        let madeCount = FormDataFiles.number(made.count), failedCount = FormDataFiles.number(failed.count)
        var s = made.count == 1 ? loc("{0} form made", madeCount) : loc("{0} forms made", madeCount)
        if !failed.isEmpty { s += failed.count == 1 ? loc(", {0} row failed", failedCount) : loc(", {0} rows failed", failedCount) }
        if stopped { s += loc(", stopped before the end") }
        return s + "."
    }

    /// The report as CSV: a line per row (row, result, file, problems), then the unknown columns.
    public func csv() -> [UInt8] {
        var rows: [[String]] = [["Row", "Result", "File", "Problems"]]
        for r in (made + failed).sorted(by: { $0.row < $1.row }) {
            rows.append([String(r.row), r.file == nil ? "Failed" : "Made", r.file ?? "", r.problems.joined(separator: "\n")])
        }
        for c in unknownColumns { rows.append(["", "Column left out", "", "\"\(c)\" isn't a field of the form"]) }
        return Csv.write(rows)
    }
}

/// A merge (Tools › Forms › Fill Forms from CSV…, `--fill`; the Windows app's `FormMerge`): a CSV whose header names the
/// form's fields and whose every row fills one copy of the form, saved in a folder under a name made from a pattern (the
/// row's number, any column). Each row's values are checked against their fields and then run through the form's
/// scripts; a row with a value refused (not one of the choices, too long, required but empty, refused by a validate
/// script) is not saved and is reported with every problem it has. Columns that aren't fields are reported once and left
/// out.
public enum FormMerge {
    private static let token = try! NSRegularExpression(pattern: #"<<\s*([^<>:]+?)\s*(?::([^<>]*))?>>"#)
    private static let batchTokens: Set<String> = ["name", "n", "date", "folder"]

    /// A name Batch's tokens use (name, n, date, folder): a column called so can't be put in a file name.
    public static func isBatchToken(_ column: String) -> Bool { batchTokens.contains(column.trimmingCharacters(in: .whitespaces).lowercased()) }

    /// What is wrong with a name pattern for the given columns, or nil.
    public static func validateTemplate(_ template: String, _ columns: [String]) -> String? {
        if let error = BatchNames.validate(template) { return error }
        let known = Set(columns.map { $0.lowercased() })
        let ns = template as NSString
        for m in token.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if !isBatchToken(name) && !known.contains(name.lowercased()) {
                return loc("<<{0}>> is neither a column of the CSV nor <<name>>, <<n>> or <<date>>.", name)
            }
        }
        return nil
    }

    /// The columns of a CSV (its header), to offer them for the name pattern.
    public static func columns(_ csv: [UInt8]) throws -> [String] { try FormDataFiles.readTable(csv).header }

    /// `formPath`: the form's path (its name is <<name>>; it is never overwritten). `progress`: rows done, and how many.
    /// Throws when the CSV can't be read, the name pattern names a column it doesn't have, or the PDF has no form.
    public static func run(_ form: [UInt8], _ password: String?, _ csv: [UInt8], formPath: String, _ options: FormMergeOptions,
                           progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> FormMergeReport {
        let (header, rows) = try FormDataFiles.readTable(csv)
        if let error = validateTemplate(options.nameTemplate, header) { throw PdfEditError(error) }
        let fields = try FormEditor.dataFields(form, password)
        if fields.isEmpty { throw FormDataFiles.noFields() }
        let names = Set(fields.map(\.name))
        let unknown = header.filter { !$0.isEmpty && !names.contains($0) }
        let outputs = OutputNames(overwrite: !options.neverOverwrite, inputs: [formPath])

        var made: [FormMergeRow] = [], failed: [FormMergeRow] = []
        var stopped = false
        for (i, row) in rows.enumerated() {
            if cancel?.isCancelled == true {
                stopped = true
                break
            }
            let number = i + 1
            defer { progress?(number, rows.count) }
            var values = FormDataFiles.row(header, row)
            for u in unknown { values[u] = nil }
            do {
                let (good, _, rejected) = FormDataFiles.check(fields, values)
                var problems = rejected.map(\.message)
                var filled = form
                if problems.isEmpty && !good.isEmpty {
                    let result = try FormEditor.fill(form, password, good)
                    problems += result.rejected.map { $0.message.isEmpty ? loc("{0}: refused by the form", $0.fieldName) : "\($0.fieldName): \($0.message)" }
                    filled = result.data
                }
                if !problems.isEmpty {
                    failed.append(FormMergeRow(row: number, file: nil, problems: problems))
                    continue
                }
                if options.flatten {
                    let pdf = filled
                    filled = try SignedEdits.run({ try Flattener.flatten(pdf, password) }, allowRewrite: true).0
                }
                let name = fileName(options.nameTemplate, header, row, formPath, number, options.date) + ".pdf"
                let bytes = filled
                let path = try outputs.place(options.outputFolder, name) { temp in try Data(bytes).write(to: URL(fileURLWithPath: temp)) }
                made.append(FormMergeRow(row: number, file: path, problems: []))
            } catch {
                let message = (error as? PdfEditError)?.message ?? error.localizedDescription
                failed.append(FormMergeRow(row: number, file: nil, problems: [message]))
            }
        }
        return FormMergeReport(rows: rows.count, made: made, failed: failed, unknownColumns: unknown, stopped: stopped)
    }

    /// A row's file name: its columns put in first, then Batch's tokens; made a valid file name.
    static func fileName(_ template: String, _ header: [String], _ row: [String], _ formPath: String, _ number: Int, _ date: Date) -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in token.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            if isBatchToken(name) {
                out += ns.substring(with: m.range)
            } else {
                let col = header.firstIndex { $0.lowercased() == name.lowercased() }
                let value = col.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
                out += value.replacingOccurrences(of: "<", with: "_").replacingOccurrences(of: ">", with: "_")
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
            }
            last = m.range.location + m.range.length
        }
        return BatchNames.expand(out + ns.substring(from: last), formPath, number, date)
    }
}
