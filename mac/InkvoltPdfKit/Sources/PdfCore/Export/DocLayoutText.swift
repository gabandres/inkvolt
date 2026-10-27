import Foundation

/// Paragraphs, lists, running headers and footers, hyphens and headings.
extension DocLayout {
    // ---- paragraphs ----

    /// Lines in reading order joined into paragraphs; tables and pictures pass through.
    static func flow(_ items: [Item], _ body: Double) -> [DocBlock] {
        let ordered = joinRows(items)
        var blocks: [DocBlock] = []
        var cur: [ExportLine] = []
        var curLast = -1 // the index in `ordered` of cur's last line
        var column = RectD.zero
        // Where the text of each column ends on the right: its longest line (justified text reaches it on every line).
        var textRight: [RectD: Double] = [:]
        for i in ordered where i.line != nil {
            let key = i.column ?? i.box
            textRight[key] = max(textRight[key] ?? -Double.infinity, i.box.right)
        }
        let blockRight = blockRights(ordered, textRight)
        func flush() {
            if !cur.isEmpty { blocks.append(.paragraph(paragraph(cur, column, body))) }
            cur = []
        }
        for (index, item) in ordered.enumerated() {
            if let b = item.block {
                flush()
                blocks.append(b)
                continue
            }
            let line = item.line!
            if !cur.isEmpty && continues(cur, line, column, blockRight[curLast] ?? textRight[column] ?? column.right) {
                cur.append(line)
            } else {
                flush()
                cur.append(line)
                column = item.column ?? line.box
            }
            curLast = index
        }
        flush()
        return blocks
    }

    /// Pieces of text side by side on one row of a column (a form's labels under their fill-in lines, choices with their
    /// boxes, a label and its value) as one line, a tab before each piece after the first: they export as one paragraph
    /// with tab stops where the pieces started, instead of a staircase of paragraphs. Not two pieces of prose (several
    /// words each, both wide): blocks of text side by side stay apart.
    static func joinRows(_ ordered: [Item]) -> [Item] {
        var result: [Item] = []
        result.reserveCapacity(ordered.count)
        var i = 0
        while i < ordered.count {
            let item = ordered[i]
            if item.line == nil {
                result.append(item)
                i += 1
                continue
            }
            var group = [item]
            var top = item.box.y, bottom = item.box.bottom
            var j = i + 1
            while j < ordered.count {
                let next = ordered[j]
                if next.line == nil || next.column != item.column || next.box.centerY < top || next.box.centerY > bottom { break }
                group.append(next)
                (top, bottom) = (min(top, next.box.y), max(bottom, next.box.bottom))
                j += 1
            }
            group.sort { $0.box.x < $1.box.x }
            let width = (item.column ?? item.box).width
            let overlapping = zip(group, group.dropFirst()).contains { $1.box.x < $0.box.right - 1 }
            let prose = group.filter { g in
                g.box.width >= 0.3 * width && g.line!.text.letterRuns.count >= 4 && !ExportGlyphs.hasLeader(g.line!.text)
                    && inParagraph(ordered, g, group)
            }.count >= 2
            if group.count == 1 || overlapping || prose {
                result += ordered[i..<j]
                i = j
                continue
            }
            var spans = group[0].line!.spans
            for g in group.dropFirst() {
                spans.append(g.line!.spans[0].with(text: "\t", box: RectD(g.box.x, g.box.y, 0, g.box.height)))
                spans += g.line!.spans
            }
            let line = ExportLine.of(spans)
            result.append(Item(line.box, line, nil, column: item.column))
            i = j
        }
        return result
    }

    /// A line of the same size right above or below the piece, under it: the piece is a line of a paragraph.
    static func inParagraph(_ ordered: [Item], _ piece: Item, _ row: [Item]) -> Bool {
        let size = piece.line!.size
        return ordered.contains { o in
            guard let l = o.line, !row.contains(where: { $0 === o }), abs(l.size - size) <= 0.12 * size else { return false }
            if min(o.box.right, piece.box.right) - max(o.box.x, piece.box.x) <= 0.5 * min(o.box.width, piece.box.width) { return false }
            let gap = max(o.box.y - piece.box.bottom, piece.box.y - o.box.bottom)
            return gap > -0.5 * l.size && gap < 0.65 * l.size
        }
    }

    /// A line laid out with tabs (pieces of a row, a leader): it is a paragraph of its own.
    static func tabbed(_ line: ExportLine) -> Bool { line.text.unicodeScalars.contains { $0 == "\t" || ExportGlyphs.isLeader($0) } }

    /// Where each line's block of text ends on the right, by the line's index in `ordered`. A block is a run of lines one
    /// under the other, close together and starting about level; when most of its lines reach the same right edge
    /// (justified or filled text, such as an indented abstract or quote) that edge is the block's own, else the
    /// column's (short lines: an address).
    static func blockRights(_ ordered: [Item], _ textRight: [RectD: Double]) -> [Int: Double] {
        var result: [Int: Double] = [:]
        var block: [(index: Int, line: ExportLine)] = []
        var blockColumn: RectD?
        func close() {
            if block.isEmpty { return }
            let column = blockColumn ?? block[0].line.box
            var right = textRight[column] ?? column.right
            if block.count >= 3 {
                let maxRight = block.map(\.line.box.right).max()!
                let size = block[0].line.size
                let reach = block.dropLast().filter { $0.line.box.right >= maxRight - 2 * size }.count
                if reach >= 2 && Double(reach) >= 0.6 * Double(block.count - 1) { right = maxRight }
            }
            for l in block { result[l.index] = right }
            block.removeAll()
        }
        for (index, item) in ordered.enumerated() {
            guard let line = item.line else {
                close()
                continue
            }
            if let prev = block.last?.line {
                let size = max(1, prev.size)
                if item.column != blockColumn || line.box.y < prev.box.y + 0.5 * prev.box.height
                    || line.box.y - prev.box.bottom > size || abs(line.box.x - prev.box.x) > 3 * size {
                    close()
                }
            }
            if block.isEmpty { blockColumn = item.column }
            block.append((index, line))
        }
        close()
        return result
    }

    /// Whether `line` carries on the paragraph so far (rather than starting a new one). `textRight`: where the column's
    /// lines end at the most.
    static func continues(_ cur: [ExportLine], _ line: ExportLine, _ column: RectD, _ textRight: Double) -> Bool {
        let prev = cur[cur.count - 1]
        let size = prev.size
        if tabbed(prev) || tabbed(line) { return false }
        if abs(size - line.size) > max(1, 0.12 * size) { return false }
        if listMarker(line.text) != nil { return false }
        if line.box.y < prev.box.y + 0.5 * prev.box.height { return false }          // not below
        if line.box.x > prev.box.right || line.box.right < prev.box.x { return false } // not under it
        let gap = line.box.y - prev.box.bottom
        if gap > 0.65 * size { return false }
        if cur.count >= 2 && gap > cur[1].box.y - cur[0].box.bottom + 0.35 * size { return false }
        func isBold(_ l: ExportLine) -> Bool { l.spans.filter { !$0.text.isBlank }.allSatisfy(\.bold) }
        if isBold(prev) && !isBold(line) { return false } // a bold line over plain text: a heading or label
        // The line before ended short: its last word was followed by room for this line's first word (an address, a
        // paragraph's last line). Word widths are estimated from the line's average character width.
        let text = line.text.trimmedStartWS
        let charWidth = line.box.width / Double(max(1, line.text.utf16.count))
        let firstWord: Int
        if let sp = text.utf16.firstIndex(of: 32), text.utf16.distance(from: text.utf16.startIndex, to: sp) > 0 {
            firstWord = text.utf16.distance(from: text.utf16.startIndex, to: sp)
        } else {
            firstWord = text.utf16.count
        }
        if prev.box.right + Double(firstWord + 1) * charWidth < textRight - 0.5 * size { return false }
        if listMarker(cur[0].text) != nil { return line.box.x >= cur[0].box.x - 1 && line.box.x <= cur[0].box.x + 4 * size }
        let left = cur.count == 1 ? min(prev.box.x, line.box.x) : cur.dropFirst().map(\.box.x).min()!
        return line.box.x <= left + 1.2 * size
    }

    static func paragraph(_ lines: [ExportLine], _ column: RectD, _ body: Double) -> DocParagraph {
        var runs: [ExportSpan] = []
        var tabs: [DocTab] = []
        for line in lines {
            // Tabs between a row's pieces start text where the piece did; a leader is a tab filled up to where it ended
            // (a right stop), or, with text after it in the same piece ("Signature ____ Date ____"), up to where that
            // text starts (a left stop), so the text stays where it was and the rule keeps its length. A number after it
            // (a page number after dots) ends at the right edge as it did.
            var spans: [ExportSpan] = []
            for (k, sp) in line.spans.enumerated() {
                if sp.text == "\t" {
                    tabs.append(DocTab(position: sp.box.x - column.x, right: false, leader: "\0"))
                } else if let c = sp.text.single, ExportGlyphs.isLeader(c) {
                    let fill: Unicode.Scalar = c == ExportGlyphs.lineLeader ? "_" : c == ExportGlyphs.dashLeader ? "-" : "."
                    // What follows: text, a row's next piece (a tab) or another leader end the rule where it ended.
                    let next = line.spans[(k + 1)...].first { $0.text == "\t" || !$0.text.isBlank }
                    if let next, next.text != "\t", !ExportGlyphs.isLeader(next.text.unicodeScalars.first!), !ExportLine.numberLike(next.text) {
                        tabs.append(DocTab(position: next.box.x - column.x, right: false, leader: fill))
                    } else {
                        tabs.append(DocTab(position: sp.box.right - column.x, right: true, leader: fill))
                    }
                    spans.append(sp.with(text: "\t"))
                    continue
                }
                spans.append(sp)
            }
            if let lastRun = runs.last {
                let last = Array(lastRun.text.trimmedEndWS.unicodeScalars)
                let next = line.text.trimmedStartWS.unicodeScalars.first
                if last.count >= 2 && last[last.count - 1] == softHyphen && last[last.count - 2].isLetter {
                    runs[runs.count - 1].text = String(String.UnicodeScalarView(last.dropLast()))   // a hyphenation point: "educa­" + "tion"
                } else if last.count >= 2 && last[last.count - 1] == "-" && last[last.count - 2].isLetter && (next?.isLowercase ?? false) {
                    var t = String.UnicodeScalarView(last.dropLast())
                    t.append(lineHyphen)
                    runs[runs.count - 1].text = String(t)                                            // "exam-" + "ple": dehyphenate decides
                } else if !(lastRun.text.unicodeScalars.last?.isWS ?? true) {
                    runs[runs.count - 1].text += " "
                }
            }
            for s in spans { add(&runs, s) }
        }
        // Soft hyphens inside a line are invisible break points: not text.
        for i in runs.indices where runs[i].text.unicodeScalars.contains(softHyphen) {
            runs[i].text = String(String.UnicodeScalarView(runs[i].text.unicodeScalars.filter { $0 != softHyphen }))
        }
        // Trim the ends (spaces only: a leader at the end is a tab that stays).
        func blank(_ r: ExportSpan) -> Bool { r.text.unicodeScalars.allSatisfy { $0 != "\t" && $0.isWS } }
        while let first = runs.first, blank(first) { runs.removeFirst() }
        while let last = runs.last, blank(last) { runs.removeLast() }
        if !runs.isEmpty {
            runs[0].text = runs[0].text.trimmingStart { spaces.contains($0) }
            runs[runs.count - 1].text = runs[runs.count - 1].text.trimmingEnd { spaces.contains($0) }
        }

        let box = lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) }
        let size = weightedSize(runs, lines[0].size)
        var list = ListKind.none
        if let m = listMarker(lines[0].text) {
            list = m.bullet ? .bullet : .marker
            if m.bullet { stripMarker(&runs) }
        }

        let first = lines[0].box.x - column.x
        let rest = lines.count > 1 ? lines.dropFirst().map(\.box.x).min()! - column.x : first
        var align = TextAlign.left
        if list == .none && column.width > 0 && tabs.isEmpty {
            let tol = max(3, 0.03 * column.width)
            if lines.allSatisfy({ abs($0.box.centerX - column.centerX) <= tol }) && first > 2 * size {
                align = .center
            } else if lines.allSatisfy({ abs($0.box.right - column.right) <= 3 }) && first > 0.4 * column.width {
                align = .right
            }
        }
        var indent = 0.0, firstLine = 0.0
        if align == .left {
            if list != .none {
                indent = max(0, first)
            } else {
                indent = max(0, min(first, rest))
                firstLine = lines.count > 1 ? first - rest : 0
                if abs(firstLine) < 0.5 * size { firstLine = 0 }
                if indent < 0.5 * size { indent = 0 }
            }
        }
        var p = DocParagraph(runs, box)
        p.size = size
        p.lineCount = lines.count
        p.list = list
        p.align = align
        p.indent = indent
        p.firstLine = firstLine
        p.tabs = tabs
        p.linePitch = lines.count > 1 ? (lines[lines.count - 1].box.y - lines[0].box.y) / Double(lines.count - 1) : 0
        return p
    }

    /// Whitespace to trim at a paragraph's ends: all but the tab (a leader or a row's piece may end it).
    static let spaces: Set<Unicode.Scalar> = [" ", "\u{A0}", "\u{2002}", "\u{2003}", "\u{2009}", "\u{202F}", "\r", "\n"]

    static func add(_ runs: inout [ExportSpan], _ s: ExportSpan) {
        if s.text.isEmpty { return }
        if let last = runs.last, last.sameLook(s) || s.text.isBlank {
            runs[runs.count - 1] = last.with(text: last.text + s.text, box: last.box.union(s.box))
        } else {
            runs.append(s)
        }
    }

    static func weightedSize(_ runs: [ExportSpan], _ fallback: Double) -> Double {
        let groups = groupedInOrder(runs.filter { !$0.text.isBlank }) { bankers($0.size * 2) / 2 }
            .map { (size: $0.key, n: $0.items.reduce(0) { $0 + $1.text.utf16.count }) }
        return groups.max { $0.n < $1.n }?.size ?? fallback
    }

    /// Removes a leading bullet character and the spaces after it (Word draws its own bullet).
    static func stripMarker(_ runs: inout [ExportSpan]) {
        var removed = false
        while !runs.isEmpty {
            var t = runs[0].text.trimmedStartWS
            if !removed, let c = t.unicodeScalars.first, bullets.contains(c) {
                t = String(t.unicodeScalars.dropFirst())
                removed = true
            }
            t = t.trimmedStartWS
            if !t.isEmpty {
                runs[0].text = t
                return
            }
            runs.removeFirst()
        }
    }

    static let bullets: Set<Unicode.Scalar> = Set(
        "\u{2022}\u{25E6}\u{25AA}\u{25AB}\u{2023}\u{2043}\u{25CF}\u{25CB}\u{25A0}\u{25A1}\u{25BA}\u{25B6}\u{27A2}\u{2756}\u{2713}\u{2714}\u{2013}\u{2014}-*\u{B7}\u{F0B7}\u{F0A7}\u{F076}\u{F0D8}\u{F0FC}\u{F06C}\u{F0A8}"
            .unicodeScalars)

    /// The list marker a line starts with, if any: a bullet, or a number/letter followed by "." or ")".
    public static func listMarker(_ text: String) -> (bullet: Bool, marker: String)? {
        let t = Array(text.trimmedStartWS.unicodeScalars)
        if t.count >= 2 && bullets.contains(t[0]) && (t[1].isWS || ["\u{2022}", "\u{25CF}", "\u{25AA}", "\u{25A0}", "\u{F0B7}"].contains(t[0])) {
            let rest = String(String.UnicodeScalarView(t.dropFirst())).trimmedStartWS
            if let c = rest.unicodeScalars.first, !bullets.contains(c) { return (true, String(Character(t[0]))) }
            return nil
        }
        let s = String(String.UnicodeScalarView(t))
        let ns = s as NSString
        guard let m = numberMarker.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.range(withName: "m").location != NSNotFound ? m.range(withName: "m") : m.range(withName: "n")
        return (false, ns.substring(with: r))
    }

    /// Whether the text is only a list marker ("•", "1.", "a)"), so the item's text is a separate line beside it.
    static func isMarkerOnly(_ text: String) -> Bool {
        let t = text.trimmedWS
        let n = t.utf16.count
        guard n > 0 && n <= 5 else { return false }
        if n == 1, let c = t.unicodeScalars.first, bullets.contains(c) { return true }
        let probe = t + " X"
        return numberMarker.firstMatch(in: probe, range: NSRange(location: 0, length: (probe as NSString).length)) != nil
    }

    // "1." "a)" "(iv)" "7.2.1." before any text, or "8.1" before a capital (not "3.5 percent"). Windows names both
    // groups "m"; ICU wants distinct names.
    static let numberMarker = try! NSRegularExpression(
        pattern: #"^(?<m>\(?(?:\d{1,3}|[a-zA-Z]|[ivxIVX]{1,5})[.)]|\d{1,3}(?:\.\d{1,3})+\.)\s+\S|^(?<n>\d{1,3}(?:\.\d{1,3})+)\s+\p{Lu}"#)

    // ---- running headers and footers ----

    private struct RunningKey: Hashable {
        var top: Bool
        var key: String
    }

    private struct At: Hashable {
        var page: Int
        var index: Int
    }

    static let runningKey = try! NSRegularExpression(pattern: #"\d+|\b[IVXLCDM]+\b|\b[ivxlcdm]+\b"#)

    /// Lines in the top or bottom tenth of the page that repeat (digits and roman numerals aside) on at least half the
    /// pages, two at least, with no other page text on their row: taken off the pages and returned as header and footer
    /// rows. A number that changes from page to page becomes `pageField`.
    static func running(_ pages: [ExportPage]) -> (pages: [ExportPage], header: DocRunning?, footer: DocRunning?) {
        if pages.count < 2 { return (pages, nil, nil) }
        var seen: [(key: RunningKey, list: [At])] = []
        var seenIndex: [RunningKey: Int] = [:]
        var seenPictures: [(key: RunningKey, list: [At])] = []
        var pictureIndex: [RunningKey: Int] = [:]
        func note(_ key: RunningKey, _ at: At, _ entries: inout [(key: RunningKey, list: [At])], _ index: inout [RunningKey: Int]) {
            if let k = index[key] {
                if entries[k].list.last?.page != at.page { entries[k].list.append(at) }
            } else {
                index[key] = entries.count
                entries.append((key, [at]))
            }
        }
        for (i, page) in pages.enumerated() {
            for (li, line) in page.lines.enumerated() {
                if line.sideways || line.text.isBlank { continue }
                let top = line.box.bottom <= page.height * 0.12
                if !top && line.box.y < page.height * 0.88 { continue }
                let trimmed = line.text.trimmedWS
                let key = runningKey.stringByReplacingMatches(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length), withTemplate: "#")
                note(RunningKey(top: top, key: key), At(page: i, index: li), &seen, &seenIndex)
            }
            // The same picture (a logo) in the same place; the writer stores equal pictures once, so they share a ref.
            for (ii, img) in page.images.enumerated() {
                guard let ref = img.ref else { continue }
                let top = img.box.bottom <= page.height * 0.12
                if !top && img.box.y < page.height * 0.88 { continue }
                func q(_ v: Double) -> Int { Int(bankers(v / 4)) }
                note(RunningKey(top: top, key: "\(ref)@\(q(img.box.x)),\(q(img.box.y)),\(q(img.box.width))"), At(page: i, index: ii), &seenPictures, &pictureIndex)
            }
        }
        let need = max(2, Int((Double(pages.count) / 2).rounded(.up)))
        // A line with page text beside it on its row (an item number at the top of a form) is part of the page. Lines
        // repeated on two pages or more (a chapter title on odd pages, the book's on even ones) are header-like too.
        let candidates = Set(seen.filter { $0.list.count >= 2 }.flatMap(\.list))
        func alone(_ at: At) -> Bool {
            let line = pages[at.page].lines[at.index]
            return !pages[at.page].lines.enumerated().contains { oi, o in
                oi != at.index && !o.sideways && !o.text.isBlank && !candidates.contains(At(page: at.page, index: oi))
                    && min(o.box.bottom, line.box.bottom) - max(o.box.y, line.box.y) > 0.5 * min(o.box.height, line.box.height)
            }
        }
        let running = seen.filter { $0.list.count >= need }.map { ($0.key, $0.list.filter(alone)) }.filter { $0.1.count >= need }
        let runningPictures = seenPictures.filter { $0.list.count >= need }
        if running.isEmpty && runningPictures.isEmpty { return (pages, nil, nil) }

        let dropLines = Set(running.flatMap(\.1))
        let dropImages = Set(runningPictures.flatMap(\.list))
        let stripped = pages.enumerated().map { i, p -> ExportPage in
            var p = p
            p.lines = p.lines.indices.filter { !dropLines.contains(At(page: i, index: $0)) }.map { p.lines[$0] }
            p.images = p.images.indices.filter { !dropImages.contains(At(page: i, index: $0)) }.map { p.images[$0] }
            return p
        }
        return (stripped, rows(true), rows(false))

        func zone(_ box: RectD, _ width: Double) -> TextAlign {
            box.centerX < width * 0.36 ? .left : box.centerX > width * 0.64 ? .right : .center
        }

        func rows(_ top: Bool) -> DocRunning? {
            let groups = running.filter { $0.0.top == top }.map(\.1)
            let pictures = runningPictures.filter { $0.key.top == top }
                .map { (page: $0.list[0].page, image: pages[$0.list[0].page].images[$0.list[0].index]) }
                .sorted { $0.image.box.x < $1.image.box.x }
                .map { RunningPicture(zone: zone($0.image.box, pages[$0.page].width), image: $0.image) }
            let linePages: [Int] = groups.flatMap { $0.map(\.page) }
            let picturePages: [Int] = runningPictures.filter { $0.key.top == top }.flatMap { $0.list.map(\.page) }
            let onPages = Set(linePages + picturePages)
            if groups.isEmpty { return pictures.isEmpty ? nil : DocRunning(rows: [], pictures: pictures, onPages: onPages) }
            // Shown as on the first page that has them; numbers that differ between two occurrences are the page number.
            let first = groups.map { $0[0].page }.min()!
            let lines = groups.filter { $0[0].page == first }.map { g -> (line: ExportLine, span: ExportSpan) in
                let line = pages[g[0].page].lines[g[0].index]
                var text = line.text.trimmedWS
                if g.count > 1 {
                    let other = pages[g[1].page].lines[g[1].index].text.trimmedWS
                    let a = runningKey.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                    let b = runningKey.matches(in: other, range: NSRange(location: 0, length: (other as NSString).length))
                    let original = text as NSString
                    for k in stride(from: min(a.count, b.count) - 1, through: 0, by: -1)
                    where original.substring(with: a[k].range) != (other as NSString).substring(with: b[k].range) {
                        text = (text as NSString).replacingCharacters(in: a[k].range, with: String(Character(pageField)))
                    }
                }
                let look = line.spans.first { !$0.text.isBlank } ?? line.spans[0]
                return (line, look.with(text: text, box: line.box))
            }.sorted { $0.line.box.y < $1.line.box.y }
            let width = pages[first].width
            var result: [DocRunningRow] = []
            for (line, span) in lines {
                let z = zone(line.box, width)
                if let prev = result.last?.parts.last?.span.box, line.box.y < prev.bottom && line.box.bottom > prev.y {
                    result[result.count - 1].parts.append(RunningPart(zone: z, span: span))
                } else {
                    result.append(DocRunningRow(parts: [RunningPart(zone: z, span: span)]))
                }
            }
            return DocRunning(rows: result.map { DocRunningRow(parts: $0.parts.sorted { $0.span.box.x < $1.span.box.x }) },
                              pictures: pictures, onPages: onPages)
        }
    }

    // ---- hyphens ----

    static let softHyphen: Unicode.Scalar = "\u{AD}"

    /// Stands for a hyphen at the end of a line, before a lowercase letter, until `dehyphenate` decides (the same code
    /// point as `ExportGlyphs.dotLeader`, as on Windows).
    static let lineHyphen: Unicode.Scalar = "\u{E001}"

    /// Settles each hyphen that ended a line before a lowercase word: kept ("equivalence-adjusted") when the document
    /// hyphenates with soft hyphens (so a hard one is real), or when both halves are words the document uses and the
    /// joined word isn't; otherwise dropped ("exam-" + "ple" → "example"). The document's words leave out each line's
    /// first word and a hyphenated last word, which may be halves.
    static func dehyphenate(_ pages: [DocPage], _ source: [ExportPage]) -> [DocPage] {
        var soft = false
        var words = Set<String>()
        for line in source.flatMap(\.lines) {
            let text = line.text
            if text.unicodeScalars.contains(softHyphen) { soft = true }
            let tokens = text.letterRuns
            let end = text.trimmedEndWS.unicodeScalars.last
            let last = end == "-" || end == softHyphen ? tokens.count - 1 : tokens.count
            if last > 1 { for i in 1..<last { words.insert(tokens[i].lowercased()) } }
        }
        func known(_ w: String) -> Bool { words.contains(w.lowercased()) }
        func fix(_ p: DocParagraph) -> DocParagraph {
            if !p.runs.contains(where: { $0.text.unicodeScalars.contains(lineHyphen) }) { return p }
            let text = Array(p.text.unicodeScalars)
            var keep: [Bool] = []
            for i in text.indices where text[i] == lineHyphen {
                var a = i
                while a > 0 && text[a - 1].isLetter { a -= 1 }
                var b = i + 1
                while b < text.count && text[b].isLetter { b += 1 }
                let left = String(String.UnicodeScalarView(text[a..<i])), right = String(String.UnicodeScalarView(text[(i + 1)..<b]))
                keep.append(soft || (!known(left + right) && known(left) && known(right)))
            }
            var next = 0
            var q = p
            q.runs = p.runs.map { r in
                guard r.text.unicodeScalars.contains(lineHyphen) else { return r }
                var out = String.UnicodeScalarView()
                for c in r.text.unicodeScalars {
                    if c != lineHyphen {
                        out.append(c)
                    } else {
                        if keep[next] { out.append("-") }
                        next += 1
                    }
                }
                return r.with(text: String(out))
            }
            return q
        }
        func fixBlock(_ b: DocBlock) -> DocBlock {
            switch b {
            case .paragraph(let p): return .paragraph(fix(p))
            case .table(var t):
                t.rows = t.rows.map { r in
                    r.map { c in
                        var c = c
                        c.paragraphs = c.paragraphs.map(fix)
                        return c
                    }
                }
                return .table(t)
            case .picture: return b
            }
        }
        return pages.map { pg in
            var pg = pg
            pg.blocks = pg.blocks.map(fixBlock)
            return pg
        }
    }

    // ---- headings ----

    /// Paragraphs in larger type than the body text (short ones: a heading is at most three lines) become headings: the
    /// largest size used for one is level 1, the next level 2, and so on (sizes within 0.75 pt count as one).
    static func assignHeadings(_ pages: [DocPage], _ body: Double) -> [DocPage] {
        func candidate(_ p: DocParagraph) -> Bool {
            let n = p.text.trimmedWS.utf16.count
            return p.size >= body * 1.15 && p.size >= body + 1 && p.lineCount <= 3 && p.list == .none && n > 0 && n <= 200
        }
        var sizes: [Double] = []
        for p in pages.flatMap(\.paragraphs) where candidate(p) && !sizes.contains(p.size) { sizes.append(p.size) }
        sizes.sort(by: >)
        if sizes.isEmpty { return pages }
        var levels: [Double] = []
        for s in sizes where levels.isEmpty || levels[levels.count - 1] - s > 0.75 { levels.append(s) }
        func level(_ size: Double) -> Int {
            let i = levels.firstIndex { size >= $0 - 0.75 } ?? -1
            return min(6, (i < 0 ? levels.count - 1 : i) + 1)
        }
        return pages.map { page in
            var page = page
            page.blocks = page.blocks.map { b in
                guard case .paragraph(var p) = b, candidate(p) else { return b }
                p.headingLevel = level(p.size)
                return .paragraph(p)
            }
            return page
        }
    }
}
