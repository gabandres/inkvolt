import Foundation

extension AutoTag {
    /// A laid-out page's blocks as tag blocks. Consecutive list paragraphs make one list (deeper indents nest); two or more
    /// lines ending in page numbers after dot leaders make a table of contents; a short line that is mostly math (math
    /// fonts, or symbols centered or numbered "(1)") is a formula; small numbered text at the foot of the page, with no body
    /// text under it, is a footnote; "Figure 2:" or "Table 1." next to a figure or table is its caption. A table must look
    /// like one (`plausibleTable`); one that doesn't (a chart's labels) is a figure when it is mostly numbers, else its text
    /// as paragraphs.
    static func blocks(_ page: Int, _ laid: DocPage, _ body: Double, _ height: Double) -> [TagBlock] {
        var result: [TagBlock] = []
        var fromTables: [TagBlock] = []
        let src = laid.blocks
        var list: [DocParagraph]?
        func flushList() {
            guard let items = list else { return }
            // A numbered section title ("3.1 Encoder Stacks") in bold reads as a list item of one: it is a heading.
            if items.count == 1, items[0].allBold, items[0].text.trimmedWS.utf16.count <= 120, let depth = sectionDepth(items[0].text) {
                let only = items[0]
                var h = TagBlock(page: page, kind: .heading, box: bounds(only.sources.isEmpty ? [only.box] : only.sources))
                h.level = min(depth, 6)
                h.sources = only.sources
                h.text = only.text.trimmedWS
                result.append(h)
            } else {
                result.append(listBlock(page, items))
            }
            list = nil
        }
        var i = 0
        while i < src.count {
            let b = src[i]
            if let first = b.paragraph, tocEntry(first), i + 1 < src.count, let second = src[i + 1].paragraph, tocEntry(second) {
                flushList()
                var entries: [DocParagraph] = []
                while i < src.count, let e = src[i].paragraph, tocEntry(e) {
                    entries.append(e)
                    i += 1
                }
                result.append(contentsBlock(page, entries))
                continue
            }
            if let item = b.paragraph, item.list != .none, item.headingLevel == 0 {
                list = (list ?? []) + [item]
                i += 1
                continue
            }
            flushList()
            switch b {
            case .paragraph(let p):
                if !p.sources.isEmpty { result.append(paragraphBlock(page, p, body, height, src[(i + 1)...])) }
            case .table(let t):
                let made = tableBlocks(page, t)
                result += made
                fromTables += made.filter { $0.kind == .figure }
            case .picture(let pic):
                let box = pic.image.pageBox ?? pic.box
                var f = TagBlock(page: page, kind: .figure, box: box)
                f.sources = [box]
                result.append(f)
            }
            i += 1
        }
        flushList()
        mergeChartFigures(&result, fromTables)
        figureLabels(&result)
        captions(&result)
        return result
    }

    private static func paragraphBlock(_ page: Int, _ p: DocParagraph, _ body: Double, _ height: Double, _ after: ArraySlice<DocBlock>) -> TagBlock {
        // Text set sideways in a margin (an arXiv stamp, a running title) isn't a heading, however large.
        let area = bounds(p.sources)
        let text = p.text.trimmedWS
        var block = TagBlock(page: page, kind: .paragraph, box: area)
        block.sources = p.sources
        block.text = text
        if p.headingLevel > 0 && !(area.height > 3 * area.width && text.utf16.count > 3) {
            block.kind = .heading
            block.level = p.headingLevel
            return block
        }
        if isFormula(p) {
            block.kind = .formula
            block.alt = text
            return block
        }
        // A footnote: smaller than the body, low on the page, starting with its number or mark, and no body text under it
        // in its column.
        if p.size > 0 && p.size <= 0.9 * body && area.y >= 0.55 * height && noteStart(text) {
            let bodyUnder = after.contains { b in
                guard let q = b.paragraph, q.size > 0.9 * body, !q.sources.isEmpty else { return false }
                let qa = bounds(q.sources)
                return qa.y > area.y && qa.x < area.right && qa.right > area.x
            }
            if !bodyUnder { block.kind = .note }
        }
        return block
    }

    /// A list's items, nested by how far each one is indented (a deeper item goes in the list of the item before).
    private static func listBlock(_ page: Int, _ items: [DocParagraph]) -> TagBlock {
        let levels = self.levels(items.map { ($0.sources.first ?? $0.box).x })
        var b = TagBlock(page: page, kind: .list, box: bounds(items.map { $0.sources.isEmpty ? $0.box : bounds($0.sources) }))
        b.items = items.indices.map { TagListItem(sources: items[$0].sources, text: items[$0].text.trimmedWS, level: levels[$0]) }
        b.text = items.map(\.text.trimmedWS).joined(separator: "\n")
        return b
    }

    private static func contentsBlock(_ page: Int, _ entries: [DocParagraph]) -> TagBlock {
        let levels = self.levels(entries.map { ($0.sources.first ?? $0.box).x })
        let texts = entries.map { replace(spaces, unleader($0.text), " ").trimmedWS }
        var b = TagBlock(page: page, kind: .contents, box: bounds(entries.map { $0.sources.isEmpty ? $0.box : bounds($0.sources) }))
        b.items = entries.indices.map { TagListItem(sources: entries[$0].sources, text: texts[$0], level: levels[$0]) }
        b.text = texts.joined(separator: "\n")
        return b
    }

    /// Nesting levels from left edges: each distinct indent (6 points apart or more) is a level, the leftmost 0; an item is
    /// never more than one level deeper than the one before it (the first is at 0).
    static func levels(_ lefts: [Double]) -> [Int] {
        var steps: [Double] = []
        for x in lefts.sorted() where steps.isEmpty || x - steps[steps.count - 1] >= 6 { steps.append(x) }
        var levels = [Int](repeating: 0, count: lefts.count)
        for k in lefts.indices {
            let level = steps.lastIndex { $0 <= lefts[k] + 0.5 } ?? -1
            levels[k] = max(0, min(level, k == 0 ? 0 : levels[k - 1] + 1))
        }
        return levels
    }

    /// A contents entry: one or two lines ending in a page number after dot leaders (or dots in the text).
    static func tocEntry(_ p: DocParagraph) -> Bool {
        // Leaders the layout found are tabs (or leader marks) in the text, or a wide stretch it read as spaces before the
        // number (dots drawn one by one).
        let raw = p.text.trimmedWS
        let leader = raw.unicodeScalars.contains(where: ExportGlyphs.isLeader)
            || (p.tabs.contains { $0.leader != "\0" } && raw.unicodeScalars.contains("\t"))
            || (matches(wideGapNumber, raw) && p.sources.count >= 3 && p.sources.dropFirst().dropLast().contains { $0.width >= 40 })
        let text = unleader(raw)
        let n = text.utf16.count
        if n < 3 || n > 200 || p.lineCount > 2 || !matches(pageNumberEnd, text) { return false }
        return leader || matches(dotsBeforeNumber, text)
    }

    /// The text with the layout's leader marks as tabs.
    private static func unleader(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars { out.append(ExportGlyphs.isLeader(c) ? "\t" : c) }
        return String(out).trimmedWS
    }

    /// Display math: a short paragraph mostly in math fonts (TeX's CMMI, CMSY, CMEX, the AMS fonts, Cambria Math…), or one
    /// with math symbols and a relation that is centered or numbered "(1)", with hardly any words.
    static func isFormula(_ p: DocParagraph) -> Bool {
        let text = p.text.trimmedWS
        let length = text.utf16.count
        if length == 0 || length > 300 || p.lineCount > 4 { return false }
        var chars = 0, math = 0, symbols = 0, words = 0
        for r in p.runs {
            let mathFont = matches(mathFontPattern, r.font)
            if !mathFont { words += count(word, r.text) }
            for c in r.text.unicodeScalars where !c.isWS {
                chars += 1
                if mathFont { math += 1 }
                if c.properties.generalCategory == .mathSymbol || (0x370...0x3FF).contains(c.value) || (0x2200...0x22FF).contains(c.value) { symbols += 1 }
            }
        }
        if chars == 0 || words > 2 { return false }
        if Double(math) >= 0.3 * Double(chars) && math + symbols >= 3 { return true }
        let relation: Set<Unicode.Scalar> = ["=", "<", ">", "≤", "≥", "≈", "≠", "∈", "→", "∝"]
        return symbols >= 2 && text.unicodeScalars.contains(where: relation.contains) && (matches(equationNumber, text) || p.align == .center)
    }

    /// A table looks like one: in at least half its rows (two at least) two or more cells hold something, at least two
    /// columns hold something in two rows or more, and a third of its cells or more aren't empty. A chart's gridlines with
    /// labels at a few of their crossings don't.
    static func plausibleTable(_ t: DocTable) -> Bool {
        if t.rows.count < 2 { return true }
        let columns = t.rows.map { $0.reduce(0) { $0 + max(1, $1.colSpan) } }.max() ?? 0
        if columns < 2 { return true }
        var used = [Int](repeating: 0, count: columns)
        var cells = 0, filled = 0, rowsWithTwo = 0
        for row in t.rows {
            var col = 0, n = 0
            for cell in row {
                cells += 1
                if !empty(cell) {
                    filled += 1
                    n += 1
                    if col < columns { used[col] += 1 }
                }
                col += max(1, cell.colSpan)
            }
            if n >= 2 { rowsWithTwo += 1 }
        }
        return rowsWithTwo >= max(2, (t.rows.count + 1) / 2) && used.count(where: { $0 >= 2 }) >= 2 && Double(filled) >= 0.34 * Double(cells)
    }

    private static func empty(_ c: DocCell) -> Bool { c.text.isBlank && c.pictures.isEmpty }
    private static func bold(_ c: DocCell) -> Bool { !c.paragraphs.isEmpty && c.paragraphs.allSatisfy(\.allBold) }
    private static func number(_ c: DocCell) -> Bool { !c.text.isBlank && ExportLine.numberLike(c.text) }

    /// Most rows (four in five) hold only numbers after their first cell.
    private static func numbersAfterFirst(_ rows: ArraySlice<[DocCell]>) -> Bool {
        if rows.isEmpty { return false }
        let n = rows.count { r in
            let rest = r.dropFirst().filter { !empty($0) }
            return !rest.isEmpty && rest.allSatisfy(number)
        }
        return Double(n) >= (0.8 * Double(rows.count)).rounded(.up)
    }

    private static func tableBlocks(_ page: Int, _ t: DocTable) -> [TagBlock] {
        let rows = t.rows.map { r in
            r.map { c in
                TagCell(sources: c.paragraphs.flatMap(\.sources), text: c.text.trimmedWS, colSpan: c.colSpan,
                        pictures: c.pictures.map { $0.image.pageBox ?? $0.box })
            }
        }
        let all = rows.flatMap { $0 }.flatMap { $0.sources + $0.pictures }
        if all.isEmpty { return [] }
        let box = bounds(all)
        if !plausibleTable(t) {
            // A chart's labels (mostly numbers) are part of the chart: a figure. Text that happened to line up: paragraphs.
            let filled = t.rows.flatMap { $0 }.filter { !empty($0) }
            if filled.count(where: number) * 2 >= filled.count {
                var f = TagBlock(page: page, kind: .figure, box: box)
                f.sources = [box]
                return [f]
            }
            return rows.flatMap { $0 }.filter { !$0.sources.isEmpty }.map { cell in
                var p = TagBlock(page: page, kind: .paragraph, box: bounds(cell.sources))
                p.sources = cell.sources
                p.text = cell.text
                return p
            }
        }
        let body = t.rows.dropFirst()
        func topBold(_ c: DocCell) -> Bool { c.paragraphs.isEmpty || bold(c) }
        // Column headers: a first row in bold over rows that aren't, or a row of words over rows of numbers.
        let boldTop = t.rows.count > 1 && t.rows[0].allSatisfy(topBold) && t.rows[0].contains { !$0.paragraphs.isEmpty }
            && !body.allSatisfy { $0.allSatisfy(topBold) }
        let wordsTop = t.rows.count > 1 && t.rows[0].count(where: { !empty($0) }) >= 2 && !t.rows[0].contains(where: number) && numbersAfterFirst(body)
        var headerRows = boldTop || wordsTop ? 1 : 0
        // A header spanning columns over the headers under it ("2025" over "Q1 Q2"): both rows are headers.
        if headerRows == 1 && t.rows.count > 3 && t.rows[0].contains(where: { $0.colSpan > 1 }) && t.rows[1].contains(where: { !empty($0) })
            && !t.rows[1].contains(where: number)
            && (t.rows[1].allSatisfy { empty($0) || bold($0) } || (wordsTop && numbersAfterFirst(t.rows.dropFirst(2)))) {
            headerRows = 2
        }
        // Row headers: each row's first cell in bold when the rest aren't, or words in front of numbers.
        let data = t.rows.dropFirst(headerRows)
        let firstCells = data.count >= 2 && data.allSatisfy { $0.count >= 2 && !empty($0[0]) }
        let boldFirst = data.allSatisfy { bold($0[0]) } && !data.allSatisfy { $0.dropFirst().allSatisfy { empty($0) || bold($0) } }
        let headerColumn = firstCells && (boldFirst || (data.allSatisfy { !number($0[0]) } && numbersAfterFirst(data)))
        var b = TagBlock(page: page, kind: .table, box: box)
        b.rows = rows
        b.headerRows = headerRows
        b.headerColumn = headerColumn
        b.text = (rows.first ?? []).map(\.text).joined(separator: " | ")
        return [b]
    }

    /// A figure made from a chart's labels joins the picture or drawing it overlaps (one figure for the chart).
    private static func mergeChartFigures(_ blocks: inout [TagBlock], _ fromTables: [TagBlock]) {
        for chart in fromTables {
            guard let at = blocks.firstIndex(of: chart),
                  let other = blocks.indices.first(where: { k in
                      k != at && blocks[k].kind == .figure && area(blocks[k].box.intersect(chart.box)) > 0.3 * min(area(blocks[k].box), area(chart.box))
                  }) else { continue }
            let union = blocks[other].box.union(chart.box)
            blocks[other].box = union
            blocks[other].sources = [union]
            blocks.remove(at: at)
        }
    }

    /// Short text inside a figure (a diagram's labels, an axis title; a few words just outside its edge too, never a
    /// caption) is part of the figure: its content goes in the Figure, whose box grows to hold it.
    private static func figureLabels(_ blocks: inout [TagBlock]) {
        for i in blocks.indices.reversed() {
            let b = blocks[i]
            let length = b.text.utf16.count
            if b.kind != .paragraph || length > 200 || matches(captionStart, b.text) { continue }
            let margin = length <= 20 ? 24.0 : length <= 40 ? 12.0 : 2.0
            guard let f = blocks.firstIndex(where: { $0.kind == .figure && $0.page == b.page && area($0.box.inflate(margin).intersect(b.box)) >= 0.75 * area(b.box) }) else { continue }
            let union = blocks[f].box.union(b.box)
            blocks[f].box = union
            blocks[f].sources = [union]
            blocks.remove(at: i)
        }
    }

    /// "Figure 2:", "Table 1." and the like right before or after a figure or table (near it, overlapping it across): its caption.
    private static func captions(_ blocks: inout [TagBlock]) {
        for i in blocks.indices {
            let b = blocks[i]
            if b.kind != .paragraph || b.text.utf16.count > 600 || !matches(captionStart, b.text) { continue }
            func near(_ k: Int) -> Bool {
                guard blocks.indices.contains(k), blocks[k].kind == .figure || blocks[k].kind == .table else { return false }
                let x = blocks[k].box
                return max(x.y - b.box.bottom, b.box.y - x.bottom) <= 48 && x.x < b.box.right && b.box.x < x.right
            }
            if near(i - 1) || near(i + 1) { blocks[i].kind = .caption }
        }
    }

    // ---- Patterns ----

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    private static func count(_ r: NSRegularExpression, _ s: String) -> Int {
        r.numberOfMatches(in: s, range: NSRange(location: 0, length: s.utf16.count))
    }

    private static func replace(_ r: NSRegularExpression, _ s: String, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: with)
    }

    private static let pageNumberEnd = regex(#"(?:\t|[.·…_ ]{3,}|\s)\s*(\d{1,4}|[ivxlcdm]{1,6})$"#)
    private static let wideGapNumber = regex(#"\S\s{2,}(\d{1,4}|[ivxlcdm]{1,6})$"#)
    private static let dotsBeforeNumber = regex(#"\S\s*[.·…]{3,}\s*(\d{1,4}|[ivxlcdm]{1,6})$"#)
    /// A footnote's start: its number (raised against the text, or one or two digits and a space) or mark, then a word, not a size ("3x3").
    private static let noteMarker = regex(#"^(?:\d{1,3}(?![x×]\d)(?=\S)|\d{1,2}\s|[*∗†‡§¶‖]{1,3})\s*\p{L}"#)
    private static let equationNumber = regex(#"\(\s*\d{1,3}[a-z]?\s*\)$"#)
    private static let word = regex(#"\p{L}{4,}"#)
    private static let spaces = regex(#"\s+"#)
    private static let mathFontPattern = regex(#"(^|\+)(CMMI|CMSY|CMEX|CMBSY|MSAM|MSBM|EUFM|EURM|EUSM|RSFS|LMMath|STIXMath|STIXTwoMath|XITSMath|LatinModernMath)|CambriaMath|Cambria Math|-Math\b"#, .caseInsensitive)
    private static let captionStart = regex(#"^(Figure|Fig\.?|Table|Tab\.|Chart|Graph|Exhibit|Listing|Scheme|Diagram|Abbildung|Abb\.|Tabelle|Tabla|Cuadro|Figura|Gráfico|Gráfica|Tableau|Graphique|Tabella|Afbeelding|Tabel)\s*(\d+(\.\d+)*|[IVXLC]+|[A-Z])([.:\-–—)]|\s|$)"#, .caseInsensitive)

    /// Text that starts like a footnote and says something (two words or more).
    static func noteStart(_ text: String) -> Bool { matches(noteMarker, text) && count(word, text) >= 2 }
}
