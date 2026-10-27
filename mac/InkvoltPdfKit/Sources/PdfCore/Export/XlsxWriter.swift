import Foundation

/// Writes tables to an Excel workbook (.xlsx), one sheet per table: numbers ("1,234.50", "-7", "12.5%", "$5.00") become
/// numbers shown as they were (decimal places, thousands separator, percent, currency sign); everything else stays text as
/// shown; cells spanning columns are merged; a cell in bold type is bold; column widths follow the table's.
enum XlsxWriter {
    private static let s = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    static func write(_ sink: ByteSink, _ sheets: [(name: String, table: DocTable)], _ title: String?) throws {
        precondition(!sheets.isEmpty, "A workbook needs at least one sheet.")
        let names = sheetNames(sheets.map(\.name))
        let zip = ZipWriter(sink)
        let styles = CellStyles()
        for (i, sheet) in sheets.enumerated() {
            try OpenXmlParts.entry(zip, "xl/worksheets/sheet\(i + 1).xml") { Self.sheet($0, sheet.table, styles) }
        }
        try OpenXmlParts.entry(zip, "xl/workbook.xml") { w in
            w.start("workbook", [("xmlns", s), ("xmlns:r", r)])
            w.start("sheets")
            for (i, name) in names.enumerated() { w.empty("sheet", [("name", name), ("sheetId", String(i + 1)), ("r:id", "rId\(i + 1)")]) }
            w.end()
            w.end()
        }
        try OpenXmlParts.entry(zip, "xl/styles.xml", styles.write)
        try OpenXmlParts.entry(zip, "xl/_rels/workbook.xml.rels") { w in
            OpenXmlParts.relationships(w, names.indices.map { ("rId\($0 + 1)", relBase + "worksheet", "worksheets/sheet\($0 + 1).xml") }
                + [("rIdStyles", relBase + "styles", "styles.xml")])
        }
        try OpenXmlParts.entry(zip, "_rels/.rels") { w in
            OpenXmlParts.relationships(w, [
                ("rId1", relBase + "officeDocument", "xl/workbook.xml"),
                ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
                ("rId3", relBase + "extended-properties", "docProps/app.xml"),
            ])
        }
        try OpenXmlParts.entry(zip, "docProps/core.xml") { OpenXmlParts.coreProperties($0, title) }
        try OpenXmlParts.entry(zip, "docProps/app.xml", OpenXmlParts.appProperties)
        try OpenXmlParts.entry(zip, "[Content_Types].xml") { w in
            OpenXmlParts.contentTypes(w, [
                ("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
                ("/xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"),
            ] + names.indices.map { ("/xl/worksheets/sheet\($0 + 1).xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml") })
        }
        try zip.finish()
    }

    /// Sheet names Excel accepts: at most 31 characters, none of : \ / ? * [ ], unique (case-insensitive).
    static func sheetNames(_ wanted: [String]) -> [String] {
        var used = Set<String>()
        var result: [String] = []
        for raw in wanted {
            let replaced = String(String.UnicodeScalarView(raw.unicodeScalars.map { c in
                ":\\/?*[]".unicodeScalars.contains(c) || c.properties.generalCategory == .control ? " " : c
            }))
            var name = replaced.trimmedWS.trimmingStart { $0 == "'" }.trimmingEnd { $0 == "'" }
            if name.isEmpty { name = "Sheet" }
            if name.utf16.count > 31 { name = OpenXmlParts.cut(name, 31).trimmedWS }
            var candidate = name
            var n = 2
            while !used.insert(candidate.lowercased()).inserted {
                let suffix = " (\(n))"
                candidate = (name.utf16.count + suffix.utf16.count > 31 ? OpenXmlParts.cut(name, 31 - suffix.utf16.count) : name) + suffix
                n += 1
            }
            result.append(candidate)
        }
        return result
    }

    /// The number a cell's text shows, if any (see `parse`).
    static func number(_ text: String) -> Double? { parse(text)?.value }

    /// The number a cell's text shows and the Excel format that shows it the same way ("1,234.50" → 1234.5 with
    /// "#,##0.00"; "12.5%" → 0.125 with "0.0%"; "-$5" → -5 with "$"#,##0); a nil format is General. Nil when the text
    /// isn't a number: other separators ("1.234,50"), a leading zero ("007", an ID), more digits than Excel keeps.
    static func parse(_ text: String) -> (value: Double, format: String?)? {
        let t = text.trimmedWS
        let ns = t as NSString
        guard let m = numberText.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let sign = group("sign"), sign2 = group("sign2")
        if sign != nil && sign2 != nil { return nil }
        let whole = group("int") ?? ""
        let frac = group("frac") ?? ""
        let digits = whole.replacingOccurrences(of: ",", with: "")
        if digits.count > 1 && digits.hasPrefix("0") { return nil }  // "007": an ID, not a number
        if digits.count + frac.count > 15 { return nil }             // longer than Excel keeps exactly
        guard digits.unicodeScalars.allSatisfy({ $0.isASCII }) && frac.unicodeScalars.allSatisfy({ $0.isASCII }),
              var v = Double(frac.isEmpty ? digits : "\(digits).\(frac)") else { return nil }
        if sign == "-" || sign2 == "-" { v = -v }
        let thousands = whole.contains(",")
        let currency = group("cur") ?? ""
        let percent = group("pct") != nil
        if percent { v /= 100 }
        if !thousands && frac.isEmpty && currency.isEmpty && !percent { return (v, nil) }
        var format = (thousands || !currency.isEmpty ? "#,##0" : "0") + (frac.isEmpty ? "" : "." + String(repeating: "0", count: frac.count))
        if percent { format += "%" }
        if !currency.isEmpty { format = "\"" + currency + "\"" + format }
        return (v, format)
    }

    private static let leaders = try! NSRegularExpression(pattern: #"(?:[ \t]*\.){3,}[ \t]*(?=\n|$)"#)

    // [sign][currency][sign]digits[.digits][%], thousands in groups of three after ",".
    private static let numberText = try! NSRegularExpression(
        pattern: #"^(?<sign>[-+])?(?<cur>[$€£¥])?(?<sign2>[-+])?(?<int>\d{1,3}(?:,\d{3})+|\d+)(?:\.(?<frac>\d+))?(?<pct>%)?$"#)

    /// A cell value as .NET's "R" format writes it: the shortest text that reads back the same, integers without ".0".
    static func valueText(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    private static func sheet(_ w: XmlOut, _ t: DocTable, _ styles: CellStyles) {
        w.start("worksheet", [("xmlns", s), ("xmlns:r", r)])
        let cols = max(1, t.columnWidths.count)
        w.start("cols")
        for c in 0..<cols {
            // Excel widths are in characters of about 5.25 pt (Calibri 11).
            let width = c < t.columnWidths.count ? clamp(t.columnWidths[c] / 5.25 + 1, 4, 100) : 10
            w.empty("col", [("min", String(c + 1)), ("max", String(c + 1)), ("width", twoPlaces(width)), ("customWidth", "1")])
        }
        w.end()
        var merges: [String] = []
        w.start("sheetData")
        for (ri, row) in t.rows.enumerated() {
            let rowNo = String(ri + 1)
            w.start("row", [("r", rowNo)])
            var c = 0
            for cell in row {
                let span = max(1, cell.colSpan)
                // Dot leaders ("2008 . . . . .") are layout, not part of the value.
                let cleaned = OpenXmlParts.clean(cell.text)
                let text = leaders.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length), withTemplate: "")
                    .trimmedWS
                if span > 1 { merges.append("\(column(c))\(rowNo):\(column(c + span - 1))\(rowNo)") }
                if !text.isEmpty {
                    let bold = !cell.paragraphs.isEmpty && cell.paragraphs.allSatisfy(\.allBold)
                    let wrap = text.contains("\n")
                    let number = parse(text)
                    let style = styles.index(bold, wrap && number == nil, number?.format)
                    var a = [("r", column(c) + rowNo)]
                    if style != 0 { a.append(("s", String(style))) }
                    if let number {
                        w.start("c", a)
                        w.element("v", valueText(number.value))
                    } else {
                        a.append(("t", "inlineStr"))
                        w.start("c", a)
                        w.start("is")
                        w.start("t", text.contains("\n") ? [("xml:space", "preserve")] : [])
                        w.text(OpenXmlParts.cut(text, 32767)) // Excel's cell limit
                        w.end()
                        w.end()
                    }
                    w.end()
                }
                c += span
            }
            w.end()
        }
        w.end()
        if !merges.isEmpty {
            w.start("mergeCells", [("count", String(merges.count))])
            for m in merges { w.empty("mergeCell", [("ref", m)]) }
            w.end()
        }
        w.end()
    }

    /// .NET's "0.##".
    private static func twoPlaces(_ v: Double) -> String {
        var t = String(format: "%.2f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Column letters: 0 → A, 25 → Z, 26 → AA.
    static func column(_ index: Int) -> String {
        var s = ""
        var n = index + 1
        while n > 0 {
            s = String(Character(Unicode.Scalar(UInt8(65 + (n - 1) % 26)))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// The workbook's cell styles: bold or not, wrapped or not, and a number format; each combination once (index 0 is
    /// the plain style), each number format once (ids from 164 up, where custom formats start).
    private final class CellStyles {
        private struct Xf: Equatable {
            var bold: Bool
            var wrap: Bool
            var numFmt: Int
        }

        private var xfs = [Xf(bold: false, wrap: false, numFmt: 0)]
        private var formats: [(code: String, id: Int)] = []

        func index(_ bold: Bool, _ wrap: Bool, _ format: String?) -> Int {
            var id = 0
            if let format {
                if let known = formats.first(where: { $0.code == format }) {
                    id = known.id
                } else {
                    id = 164 + formats.count
                    formats.append((format, id))
                }
            }
            let xf = Xf(bold: bold, wrap: wrap, numFmt: id)
            if let i = xfs.firstIndex(of: xf) { return i }
            xfs.append(xf)
            return xfs.count - 1
        }

        func write(_ w: XmlOut) {
            w.start("styleSheet", [("xmlns", XlsxWriter.s)])
            if !formats.isEmpty {
                w.start("numFmts", [("count", String(formats.count))])
                for (code, id) in formats { w.empty("numFmt", [("numFmtId", String(id)), ("formatCode", code)]) }
                w.end()
            }
            w.start("fonts", [("count", "2")])
            for bold in [false, true] {
                w.start("font")
                if bold { w.empty("b") }
                w.empty("sz", [("val", "11")])
                w.empty("name", [("val", "Calibri")])
                w.end()
            }
            w.end()
            w.start("fills", [("count", "2")])
            for pattern in ["none", "gray125"] {
                w.start("fill")
                w.empty("patternFill", [("patternType", pattern)])
                w.end()
            }
            w.end()
            w.start("borders", [("count", "1")])
            w.start("border")
            for side in ["left", "right", "top", "bottom", "diagonal"] { w.empty(side) }
            w.end()
            w.end()
            w.start("cellStyleXfs", [("count", "1")])
            xf(w, Xf(bold: false, wrap: false, numFmt: 0), nil)
            w.end()
            w.start("cellXfs", [("count", String(xfs.count))])
            for x in xfs { xf(w, x, 0) }
            w.end()
            w.start("cellStyles", [("count", "1")])
            w.empty("cellStyle", [("name", "Normal"), ("xfId", "0"), ("builtinId", "0")])
            w.end()
            w.end()
        }

        private func xf(_ w: XmlOut, _ x: Xf, _ xfId: Int?) {
            var a = [("numFmtId", String(x.numFmt)), ("fontId", x.bold ? "1" : "0"), ("fillId", "0"), ("borderId", "0")]
            if let xfId { a.append(("xfId", String(xfId))) }
            if x.numFmt != 0 { a.append(("applyNumberFormat", "1")) }
            if x.bold { a.append(("applyFont", "1")) }
            if x.wrap { a.append(("applyAlignment", "1")) }
            w.start("xf", a)
            if x.wrap { w.empty("alignment", [("vertical", "top"), ("wrapText", "1")]) }
            w.end()
        }
    }
}
