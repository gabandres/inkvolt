import Foundation

/// Writes one self-contained HTML5 file from laid-out pages (the Windows app's `HtmlWriter`): real headings (never
/// skipping a level), paragraphs, lists, tables and pictures embedded as data, in reading order, with nothing that fixes
/// the page's width, so it reflows. A running header and footer appear once. Everything from the PDF (text, alt text, the
/// title) is escaped, and the file has no script, link or request of any kind; its Content-Security-Policy says so as
/// well, in case a browser ever disagrees.
enum HtmlWriter {
    private static let style =
        "body{margin:0 auto;max-width:48em;padding:1em;font-family:system-ui,sans-serif;line-height:1.5;overflow-wrap:break-word}"
        + "img{max-width:100%;height:auto}figure{margin:1em 0}table{border-collapse:collapse;margin:1em 0;max-width:100%}"
        + "td,th{padding:.25em .5em;vertical-align:top;text-align:left}table.ruled td,table.ruled th{border:1px solid #888}"
        + "ul.typed{list-style:none;padding-left:0}ul.typed ul.typed{padding-left:1.5em}"
        + "header,footer{color:#555;font-size:.875em}"

    static func write(_ output: ByteSink, _ layout: DocLayoutResult, _ title: String?, _ language: String?) throws {
        try output.write(Array(html(layout, title, language).utf8))
    }

    static func html(_ layout: DocLayoutResult, _ title: String?, _ language: String?) -> String {
        var w = ""
        func line(_ s: String) { w += s + "\n" }
        let firstHeading = layout.pages.lazy.flatMap(\.paragraphs).first { $0.headingLevel > 0 }?.text
        let name = [title, firstHeading].lazy.map { clean($0 ?? "").trimmedWS }.first { !$0.isEmpty } ?? "Document"

        line("<!DOCTYPE html>")
        line(AccessibilityCheck.isLanguage(language) ? "<html lang=\"\(attr(language!))\">" : "<html>")
        line("<head>")
        line("<meta charset=\"utf-8\">")
        line("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        line("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">")
        line("<title>\(text(name))</title>")
        line("<style>\(style)</style>")
        line("</head>")
        line("<body>")
        running(&w, layout.header, "header")
        line("<main>")
        var level = 0
        for (i, page) in layout.pages.enumerated() {
            line("<div id=\"page-\(i + 1)\">")
            blocks(&w, page.blocks, &level)
            line("</div>")
        }
        line("</main>")
        running(&w, layout.footer, "footer")
        line("</body>")
        line("</html>")
        return w
    }

    private static func blocks(_ w: inout String, _ blocks: [DocBlock], _ level: inout Int) {
        var b = 0
        while b < blocks.count {
            switch blocks[b] {
            case .paragraph(let p) where p.list != .none:
                var items: [DocParagraph] = []
                while b < blocks.count, let item = blocks[b].paragraph, item.list != .none {
                    items.append(item)
                    b += 1
                }
                b -= 1
                list(&w, items)
            case .paragraph(let h) where h.headingLevel > 0:
                // A level is never skipped: a screen reader lists headings as an outline.
                level = min(h.headingLevel, level + 1)
                w += "<h\(level)>\(inline(h.runs, bold: false))</h\(level)>\n"
            case .paragraph(let p):
                if !p.text.isBlank { w += "<p>\(inline(p.runs))</p>\n" }
            case .table(let t):
                table(&w, t)
            case .picture(let pic):
                if let img = image(pic.image, pic.box) { w += "<figure>\(img)</figure>\n" }
            }
            b += 1
        }
    }

    // ---- lists ----

    /// A list as it looks: its tag and attributes. Items whose marker no list can show keep it as typed.
    private struct ListLook: Equatable {
        var tag: String
        var attributes: String
    }

    private static func item(_ p: DocParagraph) -> (look: ListLook, value: Int?, runs: [ExportSpan]) {
        if p.list == .bullet { return (ListLook(tag: "ul", attributes: ""), nil, p.runs) }
        let marker = DocLayout.listMarker(p.text).flatMap { $0.bullet ? nil : $0.marker } ?? ""
        guard let number = numbered(marker) else { return (ListLook(tag: "ul", attributes: " class=\"typed\""), nil, p.runs) }
        let runs = afterMarker(p.runs, marker)
        let first = number.unicodeScalars.first!
        if first.value >= 48 && first.value <= 57 { return (ListLook(tag: "ol", attributes: ""), Int(number), runs) }
        return first.value >= 97 ? (ListLook(tag: "ol", attributes: " type=\"a\""), Int(first.value) - 97 + 1, runs)
            : (ListLook(tag: "ol", attributes: " type=\"A\""), Int(first.value) - 65 + 1, runs)
    }

    /// "3." "3)" "a." "b)": what `<ol>` shows by itself (the number or letter); "(iv)" and "7.2.1." aren't, nor digits of
    /// other scripts (`^([0-9]{1,3}|[a-zA-Z])[.)]$`).
    static func numbered(_ marker: String) -> String? {
        let s = Array(marker.unicodeScalars)
        guard s.count >= 2, s.last == "." || s.last == ")" else { return nil }
        let body = s.dropLast()
        func digit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        func letter(_ c: Unicode.Scalar) -> Bool { (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) }
        if body.count <= 3 && body.allSatisfy(digit) { return String(String.UnicodeScalarView(body)) }
        if body.count == 1 && letter(body.first!) { return String(String.UnicodeScalarView(body)) }
        return nil
    }

    /// The runs without the marker they start with and the space after it.
    private static func afterMarker(_ runs: [ExportSpan], _ marker: String) -> [ExportSpan] {
        let m = Array(marker.unicodeScalars)
        var left = m.count
        var kept: [ExportSpan] = []
        var spaces = true
        for run in runs {
            let s = Array(run.text.unicodeScalars)
            var i = 0
            while spaces && i < s.count && (left > 0 || s[i].isWS) {
                if !s[i].isWS || (left > 0 && m[m.count - left] == s[i]) { left = max(0, left - 1) }
                i += 1
            }
            if i < s.count {
                spaces = false
                var r = run
                r.text = String(String.UnicodeScalarView(s[i...]))
                kept.append(r)
            }
        }
        return kept
    }

    /// Items in a row as one list, nested where the indent goes deeper: a deeper list opens inside the item before it, and
    /// a change of kind at the same depth starts a new list.
    private static func list(_ w: inout String, _ items: [DocParagraph]) {
        var open: [(indent: Double, look: ListLook)] = []
        func close(_ w: inout String) {
            w += "</li>\n"
            w += "</\(open.removeLast().look.tag)>\n"
        }
        for p in items {
            let (look, value, runs) = item(p)
            let indent = p.box.x
            while let top = open.last, top.indent > indent + 4 || (abs(top.indent - indent) <= 4 && top.look != look) { close(&w) }
            if open.isEmpty || open.last!.indent < indent - 4 {
                w += "<\(look.tag)\(look.attributes)>\n"
                open.append((indent, look))
            } else {
                w += "</li>\n"
            }
            w += value.map { "<li value=\"\($0)\">" } ?? "<li>"
            w += inline(runs)
        }
        while !open.isEmpty { close(&w) }
    }

    // ---- tables ----

    private static func table(_ w: inout String, _ t: DocTable) {
        let columns = max(t.columnWidths.count, t.rows.map { $0.reduce(0) { $0 + max(1, $1.colSpan) } }.max() ?? 0)
        if columns == 0 || t.rows.isEmpty { return }
        let rows = self.rows(t, columns)
        let first = t.rows[0].filter { !$0.text.isBlank }
        let head = rows.count > 1 && !t.rows[0].isEmpty && !first.isEmpty && first.allSatisfy { $0.paragraphs.allSatisfy(\.allBold) }
        w += t.ruled ? "<table class=\"ruled\">\n" : "<table>\n"
        for (r, row) in rows.enumerated() {
            if head && r == 0 { w += "<thead>\n" }
            if r == (head ? 1 : 0) { w += "<tbody>\n" }
            w += "<tr>"
            for (cell, span) in row {
                let tag = head && r == 0 ? "th" : "td"
                w += tag == "th" ? "<th scope=\"col\"" : "<td"
                if span > 1 { w += " colspan=\"\(span)\"" }
                w += ">"
                if let cell { self.cell(&w, cell) }
                w += "</\(tag)>"
            }
            w += "</tr>\n"
            if head && r == 0 { w += "</thead>\n" }
        }
        w += "</tbody>\n"
        w += "</table>\n"
    }

    /// Every row covering every column, as a table must: a short row is padded, cells over the edge are cut, and a column
    /// no cell starts in (only ever spanned) is taken out.
    private static func rows(_ t: DocTable, _ columns: Int) -> [[(cell: DocCell?, span: Int)]] {
        var placed: [[(cell: DocCell?, start: Int, end: Int)]] = []
        var starts = [Bool](repeating: false, count: columns)
        for row in t.rows {
            var at = 0
            var cells: [(cell: DocCell?, start: Int, end: Int)] = []
            for c in row {
                if at >= columns { break }
                let end = min(columns, at + max(1, c.colSpan))
                cells.append((c, at, end))
                starts[at] = true
                at = end
            }
            if at < columns {
                cells.append((nil, at, columns))
                starts[at] = true
            }
            placed.append(cells)
        }
        return placed.map { row in row.map { ($0.cell, starts[$0.start..<$0.end].filter { $0 }.count) } }
    }

    private static func cell(_ w: inout String, _ cell: DocCell) {
        let paragraphs = cell.paragraphs.filter { !$0.text.isBlank }
        for pic in cell.pictures {
            if let img = image(pic.image, pic.box) { w += img }
        }
        if paragraphs.count == 1 {
            w += inline(paragraphs[0].runs)
        } else {
            for p in paragraphs { w += "<p>\(inline(p.runs))</p>" }
        }
    }

    // ---- pieces ----

    private static func running(_ w: inout String, _ running: DocRunning?, _ tag: String) {
        guard let running else { return }
        // A page number means nothing without pages: the part showing it is left out.
        let rows = running.rows.map { r in
            r.parts.filter { !$0.span.text.unicodeScalars.contains(DocLayout.pageField) }.map { text($0.span.text).trimmedWS }.filter { !$0.isEmpty }
                .joined(separator: "  ")
        }.filter { !$0.isEmpty }
        let pictures = running.pictures.compactMap { image($0.image, $0.image.box) }
        if rows.isEmpty && pictures.isEmpty { return }
        w += "<\(tag)>\n"
        for img in pictures { w += "<p>\(img)</p>\n" }
        for row in rows { w += "<p>\(row)</p>\n" }
        w += "</\(tag)>\n"
    }

    /// A picture as an img with its data, at most as wide as the page had it; nil when it has no bytes.
    private static func image(_ image: ExportImage, _ box: RectD) -> String? {
        if image.data.isEmpty { return nil }
        let type = image.ext == "jpeg" ? "image/jpeg" : "image/png"
        func px(_ pt: Double) -> String { String(max(1, Int(bankers(pt * 96 / 72)))) }
        return "<img src=\"data:\(type);base64,\(Data(image.data).base64EncodedString())\" alt=\"\(attr(image.alt ?? ""))\" width=\"\(px(box.width))\" height=\"\(px(box.height))\">"
    }

    /// Runs as text with what they stress: strong, em and code. Runs that look alike (or are only space) share the tags.
    private static func inline(_ runs: [ExportSpan], bold: Bool = true) -> String {
        var sb = ""
        var open: [String] = [] // outermost first, always in the order strong, em, code
        func set(_ nb: Bool, _ ni: Bool, _ nm: Bool) {
            // What stays open is the start both have in common; the rest closes inside out, so tags always nest.
            let want = [(nb, "strong"), (ni, "em"), (nm, "code")].filter(\.0).map(\.1)
            var keep = 0
            while keep < open.count && keep < want.count && open[keep] == want[keep] { keep += 1 }
            for k in stride(from: open.count - 1, through: keep, by: -1) { sb += "</\(open[k])>" }
            for k in keep..<want.count { sb += "<\(want[k])>" }
            open = want
        }
        for run in runs {
            let t = text(run.text)
            if t.isEmpty { continue }
            if run.text.isBlank {
                sb += t
                continue
            }
            set(bold && run.bold, run.italic, run.mono)
            sb += t
        }
        set(false, false, false)
        return sb
    }

    /// Text for element content: cleaned and escaped; a line break stays one and a tab becomes a space.
    private static func text(_ s: String) -> String {
        escape(clean(s)).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Text for an attribute's value: all on a line.
    private static func attr(_ s: String) -> String {
        escape(clean(s)).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.unicodeScalars.append(c)
            }
        }
        return r
    }

    /// Without the characters HTML forbids, on top of what XML does: C1 controls, noncharacters (U+FDD0-FDEF and the last
    /// two of every plane), and the mark for a running part's page number.
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for c in OpenXmlParts.clean(text).unicodeScalars {
            let v = c.value
            if (v >= 0x7F && v <= 0x9F) || (v >= 0xFDD0 && v <= 0xFDEF) || v & 0xFFFE == 0xFFFE || c == DocLayout.pageField { continue }
            out.append(c)
        }
        return String(out)
    }
}
