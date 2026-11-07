import Foundation
import PrintCore

/// A form field as form data sees it (export, import, merge; the Windows app's `FormDataField`): one per field name.
/// `value`: as exported (a check box or radio's export value, "Off" when off; a multi-select list's choices joined by
/// "\n"). `options`: choice fields' export values; check boxes' and radios' on states and export values. `labels`:
/// choice fields' display texts.
public struct FormDataField: Equatable, Sendable {
    public var name: String
    public var kind: FormFieldKind
    public var value: String
    public var options: [String]
    public var labels: [String]
    public var maxLength: Int
    public var required: Bool
    public var readOnly: Bool
    public var multiSelect: Bool
    public var editable: Bool
}

/// What a form data import did.
public struct FormDataImport: Sendable {
    /// The filled document (the original bytes when nothing changed).
    public var data: [UInt8]
    /// Values that went in.
    public var filled: Int
    /// Names in the file that no field of the form has.
    public var unknown: [String]
    /// Values refused: not one of a field's choices, too long, read-only, or refused by the form's own scripts.
    public var rejected: [FieldRejection]
    /// Anything else (a CSV with more rows than the one used).
    public var notes: [String]
}

extension FormEditor {
    /// The fields that hold data (not push buttons or signatures), in the form's order, each name once.
    public static func dataFields(_ data: [UInt8], _ password: String?) throws -> [FormDataField] {
        let doc = try PdfEdit.openToRead(data, password)
        let acro = doc.catalog.dict("AcroForm")
        var result: [FormDataField] = []
        var seen = Set<String>()
        for f in try collect(doc, acro) {
            if !["Tx", "Ch", "Btn"].contains(f.type) || (f.type == "Btn" && f.flags & ffPushButton != 0) || !seen.insert(f.name).inserted { continue }
            let kind: FormFieldKind = f.type == "Tx" ? .text : f.type == "Ch" ? .choice : f.flags & ffRadio != 0 ? .radio : .checkBox
            var options: [String] = [], labels: [String] = []
            if kind == .choice {
                (options, labels) = readOptions(inherited(f.dict, "Opt"))
            } else if kind != .text {
                for o in f.widgets.compactMap({ onStateOf($0, in: f) }) + (buttonOptions(f) ?? []) where !options.contains(o) { options.append(o) }
            }
            result.append(FormDataField(
                name: f.name, kind: kind, value: exportValueOf(f), options: options, labels: labels,
                maxLength: inherited(f.dict, "MaxLen")?.int ?? 0, required: f.flags & ffRequired != 0, readOnly: f.flags & ffReadOnly != 0,
                multiSelect: kind == .choice && f.flags & ffMultiSelect != 0, editable: kind == .choice && f.flags & ffEdit != 0))
        }
        return result
    }

    /// A value from a data file checked against its field, before it is filled in: the value to set (a check box's TRUE,
    /// Yes, 1 or X become its on state; FALSE, No, 0 "Off"), or why it can't go in (not one of the choices, too long,
    /// empty for a required field, read-only).
    public static func checkValue(_ f: FormDataField, _ raw: String) -> (value: String?, problem: String?) {
        let value = raw.replacingOccurrences(of: "\r\n", with: "\n")
        func short(_ s: String) -> String { s.count <= 40 ? s : String(s.prefix(40)) + "…" }
        if f.readOnly { return value == f.value ? (nil, nil) : (nil, loc("it is read-only")) }
        if f.required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && f.kind != .checkBox && f.kind != .radio {
            return (nil, loc("it is required, and the value is empty"))
        }
        switch f.kind {
        case .text:
            let length = value.utf16.count
            return f.maxLength > 0 && length > f.maxLength ? (nil, loc("it takes at most {0} characters ({1} given)", CoreLanguage.number(f.maxLength), CoreLanguage.number(length))) : (value, nil)
        case .choice:
            let parts = f.multiSelect ? value.split(separator: "\n").map(String.init) : value.isEmpty ? [] : [value]
            if !f.multiSelect && parts.isEmpty { return ("", nil) }
            if f.editable { return (value, nil) }
            for p in parts where !f.options.contains(p) && !f.labels.contains(p) {
                let list = f.options.prefix(8).map(short).joined(separator: ", ")
                return (nil, f.options.count > 8
                    ? loc("\"{0}\" isn't one of its choices ({1}, …)", short(p), list) : loc("\"{0}\" isn't one of its choices ({1})", short(p), list))
            }
            return (value, nil)
        default:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || ["Off", "off", "OFF"].contains(trimmed) { return ("Off", nil) }
            if let exact = f.options.first(where: { $0 == trimmed }) { return (exact, nil) }
            if let loose = f.options.first(where: { $0.lowercased() == trimmed.lowercased() }) { return (loose, nil) }
            if f.kind == .checkBox, let on = f.options.first {
                if ["true", "yes", "1", "x", "on", "checked"].contains(trimmed.lowercased()) { return (on, nil) }
                if ["false", "no", "0", "unchecked"].contains(trimmed.lowercased()) { return ("Off", nil) }
            }
            return (nil, loc("\"{0}\" isn't one of its states ({1})", short(trimmed), (f.options + ["Off"]).joined(separator: ", ")))
        }
    }
}

/// Form data in and out (roadmap 1.4; the Windows app's `FormDataFiles`): a form's values exported as XFDF, FDF (what
/// Acrobat reads and writes), CSV (a header row of field names and a row of values) or JSON
/// (`{"fields": {"name": "value", "list": ["a", "b"]}}`), and imported from any of them. Every field type travels: text
/// (several lines kept), check boxes and radio buttons (their export value, "Off" when off), combo boxes and list boxes
/// (several choices: an array in JSON, values in XFDF, lines in a CSV cell). Imported values are checked against their
/// fields first (`FormEditor.checkValue`), then filled through the form's own scripts (`FormEditor.fill`), which may
/// refuse some too. Many rows of a CSV make many forms: `FormMerge`. Refusals are `PdfEditError`s.
public enum FormDataFiles {
    /// Largest data file read.
    public static let maxFileBytes = 16 * 1024 * 1024

    public static func fileExtension(_ format: FormDataFormat) -> String {
        switch format {
        case .xfdf: "xfdf"
        case .fdf: "fdf"
        case .json: "json"
        case .csv: "csv"
        }
    }

    public static func format(ofPath path: String) -> FormDataFormat? {
        switch (path as NSString).pathExtension.lowercased() {
        case "xfdf", "xml": .xfdf
        case "fdf": .fdf
        case "json": .json
        case "csv", "txt": .csv
        default: nil
        }
    }

    static func noFields() -> PdfEditError { PdfEditError(loc("This PDF has no form fields with data.")) }

    public static func export(_ data: [UInt8], _ password: String?, _ format: FormDataFormat, pdfFileName: String? = nil) throws -> [UInt8] {
        let fields = try FormEditor.dataFields(data, password)
        if fields.isEmpty { throw noFields() }
        switch format {
        case .csv:
            return Csv.write([fields.map(\.name), fields.map(\.value)])
        case .json:
            var out = "{\n  \"fields\": {"
            for (i, f) in fields.enumerated() {
                out += (i == 0 ? "\n" : ",\n") + "    " + json(f.name) + ": "
                if f.multiSelect {
                    let parts = f.value.split(separator: "\n").map { json(String($0)) }
                    out += parts.isEmpty ? "[]" : "[\n" + parts.map { "      " + $0 }.joined(separator: ",\n") + "\n    ]"
                } else {
                    out += json(f.value)
                }
            }
            out += fields.isEmpty ? "}\n}" : "\n  }\n}"
            return Array(out.utf8)
        case .xfdf, .fdf:
            let entries = fields.map { f in
                FormData.Entry(name: f.name, values: f.multiSelect ? f.value.split(separator: "\n").map(String.init) : [f.value],
                               isName: f.kind == .checkBox || f.kind == .radio)
            }
            return format == .xfdf ? FormData.xfdf(entries, pdfFileName) : FormData.fdf(entries, pdfFileName)
        }
    }

    /// A JSON string: quotes, backslashes and control characters escaped; everything else as it is (UTF-8).
    private static func json(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 || c.value == 0x2028 || c.value == 0x2029 { out += String(format: "\\u%04X", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }

    /// Fills the form from a data file (XFDF, FDF, JSON or CSV, told apart by their content; a CSV's first row).
    public static func importData(_ data: [UInt8], _ password: String?, _ file: [UInt8], host: FormActionHost? = nil) throws -> FormDataImport {
        var notes: [String] = []
        let values: [String: String]
        if sniff(file) == .csv {
            let (header, rows) = try readTable(file)
            if rows.isEmpty { throw PdfEditError(loc("The CSV has field names but no row of values.")) }
            if rows.count > 1 {
                notes.append(loc("The file has {0} rows of values: the first was filled in. Fill Forms from CSV makes a form for each row.", number(rows.count)))
            }
            values = row(header, rows[0])
        } else {
            values = try readValues(file)
        }
        return try fill(data, password, values, notes, host: host)
    }

    static func fill(_ data: [UInt8], _ password: String?, _ values: [String: String], _ notes: [String], host: FormActionHost? = nil) throws -> FormDataImport {
        let fields = try FormEditor.dataFields(data, password)
        if fields.isEmpty { throw noFields() }
        var (good, unknown, rejected) = check(fields, values)
        if good.isEmpty { return FormDataImport(data: data, filled: 0, unknown: unknown, rejected: rejected, notes: notes) }
        let result = try FormEditor.fill(data, password, good, host: host)
        rejected += result.rejected
        let refused = Set(result.rejected.map(\.fieldName))
        let filled = good.keys.filter { !refused.contains($0) }.count
        unknown.sort()
        return FormDataImport(data: result.data, filled: filled, unknown: unknown, rejected: rejected, notes: notes)
    }

    /// The values that fit their fields, the names no field has, and the values refused (with why).
    static func check(_ fields: [FormDataField], _ values: [String: String]) -> (good: [String: String], unknown: [String], rejected: [FieldRejection]) {
        var byName: [String: FormDataField] = [:]
        for f in fields where byName[f.name] == nil { byName[f.name] = f }
        var good: [String: String] = [:]
        var unknown: [String] = [], rejected: [FieldRejection] = []
        for name in values.keys.sorted() {
            guard let raw = values[name] else { continue }
            guard let f = byName[name] else {
                unknown.append(name)
                continue
            }
            let (value, problem) = FormEditor.checkValue(f, raw)
            if let problem {
                rejected.append(FieldRejection(fieldName: name, message: "\(name): \(problem)"))
            } else if let value {
                good[name] = value
            }
        }
        return (good, unknown, rejected)
    }

    /// Full field name → value (several values joined by "\n") from XFDF, FDF, JSON or a CSV's first row. Throws when the
    /// file isn't one of them, is damaged, too big, or carries a DTD.
    public static func readValues(_ file: [UInt8]) throws -> [String: String] {
        if file.isEmpty { throw PdfEditError(loc("The file is empty.")) }
        if file.count > maxFileBytes { throw PdfEditError(loc("The file is larger than {0} MB, the most Inkvolt PDF reads as form data.", CoreLanguage.number(maxFileBytes >> 20))) }
        switch sniff(file) {
        case .json:
            return try readJson(file)
        case .csv:
            let (header, rows) = try readTable(file)
            return rows.isEmpty ? [:] : row(header, rows[0])
        case .xfdf, .fdf:
            if CommentFiles.hasDtd(Array(file.prefix(4096))) {
                throw PdfEditError(loc("The file has a DTD (<!DOCTYPE>), which Inkvolt PDF doesn't read: it could make the file read other files or grow without end."))
            }
            guard let parsed = FormData.parse(file) else { throw PdfEditError(loc("The file isn't XFDF, FDF, JSON or CSV form data, or it is damaged.")) }
            return parsed.mapValues { $0.joined(separator: "\n") }
        }
    }

    /// What a data file is, from its first bytes: XML is XFDF, %FDF is FDF, { or [ is JSON, anything else CSV.
    public static func sniff(_ file: [UInt8]) -> FormDataFormat {
        var start = file.count >= 3 && file[0] == 0xEF && file[1] == 0xBB && file[2] == 0xBF ? 3 : 0
        while start < file.count && [32, 9, 13, 10].contains(file[start]) { start += 1 }
        if start >= file.count { return .csv }
        switch file[start] {
        case UInt8(ascii: "<"): return .xfdf
        case UInt8(ascii: "{"), UInt8(ascii: "["): return .json
        default: return file[start...].starts(with: Array("%FDF".utf8)) ? .fdf : .csv
        }
    }

    private static func readJson(_ file: [UInt8]) throws -> [String: String] {
        // JSONSerialization has no depth limit of its own: nesting past 64 is refused first, as Windows' MaxDepth does (JSON5's
        // strings and comments read as such: `JsonNesting`).
        if !JsonNesting.isSafe(Data(file)) {
            throw PdfEditError(loc("The JSON file can't be read: it is nested more than 64 levels deep.")) // JsonNesting.limit
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(file), options: [.json5Allowed])
        } catch {
            throw PdfEditError(loc("The JSON file can't be read: {0}", error.localizedDescription))
        }
        var root = object as? [String: Any]
        if let fields = root?["fields"] as? [String: Any] { root = fields }
        guard let root else {
            throw PdfEditError(loc("The JSON file should hold an object of field names and values: {\"fields\": {\"name\": \"value\"}}."))
        }
        var result: [String: String] = [:]
        func scalar(_ v: Any) -> String? {
            if let s = v as? String { return s }
            if let n = v as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
                return n.stringValue
            }
            return nil
        }
        func walk(_ obj: [String: Any], _ parent: String?) {
            for (key, value) in obj {
                let name = parent.map { "\($0).\(key)" } ?? key
                if let nested = value as? [String: Any] {
                    walk(nested, name)
                } else if let list = value as? [Any] {
                    result[name] = list.compactMap(scalar).joined(separator: "\n")
                } else if let v = scalar(value) {
                    result[name] = v
                }
            }
        }
        walk(root, nil)
        return result
    }

    /// A CSV's header (field names) and its rows of values. Throws when it is too big, has too many rows, is empty, or
    /// names a column twice.
    static func readTable(_ file: [UInt8]) throws -> (header: [String], rows: [[String]]) {
        if file.count > Csv.maxBytes { throw PdfEditError(loc("The file is larger than {0} MB.", CoreLanguage.number(Csv.maxBytes >> 20))) }
        let rows = try Csv.read(Csv.decode(file))
        if rows.isEmpty { throw PdfEditError(loc("The CSV file is empty.")) }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces) }
        var seen = Set<String>()
        for h in header where !h.isEmpty && !seen.insert(h).inserted { throw PdfEditError(loc("The column \"{0}\" is in the CSV twice.", h)) }
        return (header, Array(rows.dropFirst()))
    }

    /// A row's values by column name (empty column names left out; missing cells are empty).
    static func row(_ header: [String], _ row: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for (i, h) in header.enumerated() where !h.isEmpty { values[h] = i < row.count ? row[i] : "" }
        return values
    }

    static func number(_ n: Int) -> String { CoreLanguage.number(n) }
}
