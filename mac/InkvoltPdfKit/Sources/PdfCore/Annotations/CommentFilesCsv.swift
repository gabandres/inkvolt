import Foundation

/// The comments CSV of `CommentFiles` (a row per comment, for spreadsheets).
extension CommentFiles {
    /// The columns of a comments CSV. Page is from 1; Date is ISO 8601; Color and Fill are #RRGGBB; Rect is "x1 y1 x2 y2"
    /// in PDF points (origin at the bottom left; a text box's own box, without its callout); Points holds the geometry in
    /// the same units: the quads of a text markup, the strokes of a drawing (separated by ";"), a line's two ends, the
    /// vertices of a polygon or a callout's points. Ends are the line endings (start and end, or a callout's one), Dashes
    /// the dash pattern.
    public static let csvColumns = [
        "Id", "Page", "Type", "Author", "Date", "Subject", "Text", "Reply to", "Color", "Fill", "Opacity", "Width", "Dashes", "Ends",
        "Icon", "Rect", "Points",
    ]

    static func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func writeCsv(_ records: [Record]) -> [UInt8] {
        var rows = [csvColumns]
        for r in records {
            let d = r.dict
            var width = ""
            if let w = d["BS"]?.dictValue?["W"]?.numberValue {
                width = Fdf.number(w)
            } else if let border = d["Border"]?.numbers, border.count >= 3 {
                width = Fdf.number(border[2])
            }
            var dashes = ""
            if let bs = d["BS"]?.dictValue, bs["S"]?.nameValue == "D" { dashes = spaced(bs["D"]?.numbers) }
            var ends = ""
            if let one = d["LE"]?.nameValue {
                ends = one
            } else if let list = d["LE"]?.arrayValue {
                ends = list.compactMap(\.nameValue).joined(separator: " ")
            }
            var opacity = ""
            if let ca = d["CA"]?.numberValue, ca < 1 { opacity = Fdf.number(ca) }
            let rect = r.subtype == "FreeText" ? textBox(d) : d["Rect"]?.numbers
            let row: [String] = [
                r.key, String(r.page + 1), r.subtype, d["T"]?.stringValue ?? "",
                PdfDates.parse(d["M"]?.stringValue).map(isoDate) ?? "",
                d["Subj"]?.stringValue ?? "", d["Contents"]?.stringValue ?? "", r.replyTo ?? "",
                hex(d["C"]?.numbers) ?? "", hex(d["IC"]?.numbers) ?? "", opacity, width, dashes, ends,
                d["Name"]?.nameValue ?? "", spaced(rect), pointsOf(r),
            ]
            rows.append(row)
        }
        return Csv.write(rows)
    }

    /// A text box's own rectangle: its /Rect less the /RD fringe a callout adds.
    private static func textBox(_ d: [String: FdfValue]) -> [Double]? {
        guard let r = d["Rect"]?.numbers, r.count == 4 else { return nil }
        guard let rd = d["RD"]?.numbers, rd.count == 4, !rd.contains(where: { $0 < 0 }) else { return r }
        let x1 = min(r[0], r[2]) + rd[0], y1 = min(r[1], r[3]) + rd[1]
        let x2 = max(r[0], r[2]) - rd[2], y2 = max(r[1], r[3]) - rd[3]
        return x2 > x1 && y2 > y1 ? [x1, y1, x2, y2] : r
    }

    private static func spaced(_ values: [Double]?) -> String { values?.map(Fdf.number).joined(separator: " ") ?? "" }

    private static func pointsOf(_ r: Record) -> String {
        let d = r.dict
        switch r.subtype {
        case "Ink": return d["InkList"]?.arrayValue?.map { spaced($0.numbers) }.joined(separator: ";") ?? ""
        case "Line": return spaced(d["L"]?.numbers)
        case "Polygon", "PolyLine": return spaced(d["Vertices"]?.numbers)
        case "FreeText": return spaced(d["CL"]?.numbers)
        default: return spaced(d["QuadPoints"]?.numbers)
        }
    }

    /// A CSV date: ISO 8601 with or without a time and zone ("2026-11-03T10:20:30-04:00", "2026-11-03 10:20", "2026-11-03").
    static func csvDate(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let d = iso.date(from: t) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = pattern
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    // swiftlint:disable:next function_body_length
    static func readCsv(_ file: [UInt8], _ skipped: inout [String]) throws -> [Record] {
        let rows = try Csv.read(Csv.decode(file))
        if rows.isEmpty { throw PdfEditError("The file is empty.") }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ name: String) -> Int? { header.firstIndex(of: name.lowercased()) }
        if col("Page") == nil || col("Type") == nil || col("Rect") == nil {
            throw PdfEditError("The file isn't XFDF, FDF or a comments CSV: a CSV needs the columns Page, Type and Rect (export one to see them all).")
        }
        if rows.count - 1 > maxComments { throw tooMany() }

        var records: [Record] = []
        for i in 1..<rows.count {
            let row = rows[i]
            func cell(_ name: String) -> String {
                guard let c = col(name), c < row.count else { return "" }
                return row[c]
            }
            let line = i + 1
            let pageText = cell("Page")
            let pg = !pageText.isEmpty && pageText.allSatisfy({ $0.isASCII && $0.isNumber }) ? (Int(pageText).map { $0 - 1 } ?? -1) : -1
            let subtype = cell("Type").trimmingCharacters(in: .whitespaces)
            if xfdfElements[subtype] == nil {
                skipped.append("Row \(line): \"\(subtype)\" isn't a kind of comment Inkvolt PDF imports")
                continue
            }
            var d: [String: FdfValue] = ["Subtype": .name(subtype)]
            if let rect = nums(cell("Rect")), rect.count == 4 { d["Rect"] = box(rect) }
            if !cell("Author").isEmpty { d["T"] = .string(cell("Author")) }
            if !cell("Subject").isEmpty { d["Subj"] = .string(cell("Subject")) }
            d["Contents"] = .string(cell("Text"))
            if let date = csvDate(cell("Date")) { d["M"] = .string(PdfDates.format(date)) }
            if let c = color(cell("Color")) { d["C"] = c }
            if let fill = color(cell("Fill")) { d["IC"] = fill }
            if let ca = num(cell("Opacity")) { d["CA"] = .number(min(max(ca, 0), 1)) }
            let dashes = nums(cell("Dashes"))
            let width = num(cell("Width"))
            if width != nil || !(dashes ?? []).isEmpty {
                var bs: [String: FdfValue] = ["Type": .name("Border"), "W": .number(min(max(width ?? 1, 0), 1000)), "S": .name("S")]
                if let dashes, !dashes.isEmpty {
                    bs["S"] = .name("D")
                    bs["D"] = .numbers(Array(dashes.prefix(16)))
                }
                d["BS"] = .dict(bs)
            }
            let ends = cell("Ends").split(separator: " ").map(String.init)
            if subtype == "FreeText" && ends.count == 1 {
                d["LE"] = .name(ends[0])
            } else if ends.count == 2 {
                d["LE"] = .array([.name(ends[0]), .name(ends[1])])
            }
            if !cell("Icon").isEmpty { d["Name"] = .name(cell("Icon")) }
            d["F"] = .number(4) // print
            let points = cell("Points")
            switch subtype {
            case "Ink":
                let strokes = points.split(separator: ";").compactMap { nums(String($0)) }.filter { $0.count >= 2 && $0.count % 2 == 0 }
                if !strokes.isEmpty { d["InkList"] = .array(strokes.map { FdfValue.numbers($0) }) }
            case "Line":
                if let l = nums(points), l.count == 4 { d["L"] = .numbers(l) }
            case "Polygon", "PolyLine":
                if let v = nums(points), v.count >= 4, v.count % 2 == 0 { d["Vertices"] = .numbers(v) }
            case "FreeText":
                if let cl = nums(points), cl.count == 4 || cl.count == 6 { d["CL"] = .numbers(cl) }
            case "Highlight", "Underline", "StrikeOut", "Squiggly", "Redact":
                if let q = nums(points), !q.isEmpty, q.count % 8 == 0 { d["QuadPoints"] = .numbers(q) }
            default:
                break
            }
            let id = cell("Id")
            let key = id.isEmpty ? hashKey("csv", i, nil, d) : id
            let to = cell("Reply to")
            if !to.isEmpty { d["RT"] = .name("R") }
            records.append(Record(key: key, page: pg, dict: d, replyTo: to.isEmpty ? nil : to))
        }
        return records
    }
}
