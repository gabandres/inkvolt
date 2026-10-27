import Foundation

/// Tables (ruled grids, text aligned in columns) and figures drawn with vectors.
extension DocLayout {
    /// More columns than this is a scatter of words (chart labels), not a table.
    static let maxTableColumns = 20

    // ---- tables from aligned text ----

    /// Pieces side by side whose lines line up row by row (at least three rows, or two with three or more columns) form a
    /// table, unless they read as text columns (wide, filled lines).
    static func unruledTable(_ pieces: [[Item]], _ body: Double) -> DocTable? {
        if pieces.contains(where: { $0.contains { $0.line == nil } }) { return nil }
        let bounds = pieces.map { p in p.dropFirst().reduce(p[0].box) { $0.union($1.box) } }
        let prose = pieces.indices.map { isProse(pieces[$0], bounds[$0].width, body) }
        if pieces.count == 2 ? prose.contains(true) : prose.filter({ $0 }).count >= 2 { return nil }

        let grouped = rows(pieces.enumerated().flatMap { k, p in p.map { (line: $0.line!, col: k) } })
        let aligned = grouped.filter { Set($0.map(\.col)).count >= 2 }.count
        if grouped.count < 2 || aligned < (pieces.count == 2 ? 3 : 2) || Double(aligned) < 0.6 * Double(grouped.count) { return nil }

        // Column edges: halfway across each gutter.
        var edges = [bounds[0].x]
        for k in 1..<bounds.count { edges.append((bounds[k - 1].right + bounds[k].x) / 2) }
        edges.append(bounds[bounds.count - 1].right)
        let cols = pieces.count

        var cells: [[[ExportLine]]] = []
        var prevBox: RectD?
        for row in grouped {
            let box = row.dropFirst().reduce(row[0].line.box) { $0.union($1.line.box) }
            var filled: [Int] = []
            for x in row where !filled.contains(x.col) { filled.append(x.col) }
            // A row with only a wrapped cell's next line (first column empty, right under the row before) continues that row.
            if !cells.isEmpty && !filled.contains(0) && filled.count <= max(1, cols / 2) && !cells[cells.count - 1][0].isEmpty,
               let pb = prevBox, box.y - pb.bottom < 0.6 * body {
                for (line, col) in row { cells[cells.count - 1][col].append(line) }
                prevBox = pb.union(box)
                continue
            }
            var r = [[ExportLine]](repeating: [], count: cols)
            for (line, col) in row { r[col].append(line) }
            cells.append(r)
            prevBox = box
        }
        // Most cells hold something, and not too many columns: chart labels and scattered words don't make a table.
        let filledCells = cells.reduce(0) { $0 + $1.filter { !$0.isEmpty }.count }
        if cols > maxTableColumns || Double(filledCells) < 0.5 * Double(cells.count * cols) { return nil }
        let tableBox = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
        let docRows = cells.map { r in
            r.indices.map { k in
                DocCell(cellParagraphs(r[k], RectD(edges[k], tableBox.y, edges[k + 1] - edges[k], tableBox.height), body))
            }
        }
        let widths = (0..<cols).map { edges[$0 + 1] - edges[$0] }
        return DocTable(docRows, widths, false, tableBox)
    }

    static func isProse(_ piece: [Item], _ width: Double, _ body: Double) -> Bool {
        if piece.count < 3 || width < 10 * body { return false }
        let widths = piece.map(\.box.width).sorted()
        return widths[widths.count / 2] >= 0.6 * width
    }

    /// Lines grouped into rows: a line whose middle falls within a row's height joins it.
    static func rows(_ lines: [(line: ExportLine, col: Int)]) -> [[(line: ExportLine, col: Int)]] {
        var rows: [(top: Double, bottom: Double, members: [(line: ExportLine, col: Int)])] = []
        for x in lines.sorted(by: { $0.line.box.centerY < $1.line.box.centerY }) {
            let cy = x.line.box.centerY
            if let last = rows.last, cy >= last.top && cy <= last.bottom {
                rows[rows.count - 1] = (min(last.top, x.line.box.y), max(last.bottom, x.line.box.bottom), last.members + [x])
            } else {
                rows.append((x.line.box.y, x.line.box.bottom, [x]))
            }
        }
        return rows.map(\.members)
    }

    /// Tables without lines that follow one another with the same columns (a long table cut where its row groups leave a
    /// gap) are one table.
    static func mergeTables(_ blocks: [DocBlock], _ body: Double) -> [DocBlock] {
        var blocks = blocks
        var i = blocks.count - 2
        while i >= 0 {
            defer { i -= 1 }
            guard case .table(let a) = blocks[i], !a.ruled, case .table(let b) = blocks[i + 1], !b.ruled else { continue }
            if a.columnWidths.count != b.columnWidths.count || b.box.y < a.box.bottom - 1 || b.box.y - a.box.bottom > 4 * body { continue }
            func edge(_ t: DocTable, _ k: Int) -> Double { t.box.x + t.columnWidths.prefix(k).reduce(0, +) }
            if (0...a.columnWidths.count).contains(where: { abs(edge(a, $0) - edge(b, $0)) > max(18, 1.5 * body) }) { continue }
            blocks[i] = .table(DocTable(a.rows + b.rows, a.columnWidths, false, a.box.union(b.box)))
            blocks.remove(at: i + 1)
        }
        return blocks
    }

    // ---- figures drawn with vectors ----

    /// Areas of a page drawn with many vector paths and holding little text: charts and diagrams, exported as a picture
    /// rather than read as text and tables. A figure is a cluster of at least 10 paths (touching or within 4 pt), over
    /// 40 x 40 pt, whose text lines cover less than a fifth of it and hold at most 80 words (400 when they are short
    /// labels, four words a line or fewer: a diagram), and that isn't a ruled table (a grid with text in at least half its
    /// cells). Paths covering half the page or more (backgrounds, frames) don't count. Labels just outside the paths
    /// (within 6 pt) belong to the figure.
    public static func figureRegions(_ paths: [(box: RectD, stroked: Bool)], _ lines: [ExportLine], _ width: Double, _ height: Double) -> [RectD] {
        let near = 4.0
        let items = paths.filter {
            $0.box.width >= 0 && $0.box.height >= 0 && $0.box.width.isFinite && $0.box.height.isFinite
                && $0.box.width * $0.box.height < 0.5 * width * height
        }.sorted { $0.box.x < $1.box.x }
        if items.count < 10 { return [] }
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var k = i
            while parent[k] != r {
                let next = parent[k]
                parent[k] = r
                k = next
            }
            return r
        }
        for i in items.indices {
            let a = items[i].box
            var j = i + 1
            while j < items.count && items[j].box.x <= a.right + near {
                let b = items[j].box
                if b.y <= a.bottom + near && a.y <= b.bottom + near {
                    let rj = find(j), ri = find(i)
                    parent[rj] = ri
                }
                j += 1
            }
        }
        var clusters = groupedInOrder(Array(items.indices), by: find).filter { $0.items.count >= 10 }.map { g in
            (paths: g.items.map { items[$0] }, box: g.items.dropFirst().reduce(items[g.items[0]].box) { $0.union(items[$1].box) })
        }
        // Clusters whose areas overlap are one figure (a legend inside a plot, bars beside axes).
        var merged = true
        while merged {
            merged = false
            outer: for i in clusters.indices {
                for j in i + 1..<clusters.count where !clusters[i].box.intersect(clusters[j].box).isEmpty {
                    clusters[i] = (clusters[i].paths + clusters[j].paths, clusters[i].box.union(clusters[j].box))
                    clusters.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        var figures: [RectD] = []
        for (clusterPaths, box) in clusters {
            if box.width < 40 || box.height < 40 { continue }
            let around = box.inflate(6)
            let inside = lines.filter { around.contains($0.box.centerX, $0.box.centerY) }
            let textArea = inside.reduce(0.0) { $0 + $1.box.width * $1.box.height }
            let wordCount = inside.reduce(0) { $0 + $1.text.letterRuns.count + $1.text.countScalars(\.isDecimalDigit) / 4 }
            // Labels are short; a form or a text box has sentences.
            let labels = !inside.isEmpty && Double(wordCount) <= 4.0 * Double(inside.count)
            if textArea >= 0.2 * box.width * box.height || wordCount > (labels ? 400 : 80) { continue }
            if isRuledTable(clusterPaths, inside) || rowsOfText(inside) || isFormGrid(clusterPaths, box) { continue }
            // The labels around the drawing go with it.
            let region = inside.reduce(box) { $0.union($1.box) }.intersect(RectD(0, 0, width, height))
            if !region.isEmpty { figures.append(region) }
        }
        return figures
    }

    /// The text is set in rows of pieces side by side, three or more, or two with words (four rows at least, and most of
    /// them): a table, even one whose lines don't form a grid. A chart's labels are alone on their row (a legend) or
    /// numbers (the ticks of axes side by side).
    static func rowsOfText(_ lines: [ExportLine]) -> Bool {
        let grouped = rows(lines.filter { !$0.sideways }.map { ($0, 0) })
        let multi = grouped.filter { r in r.count >= 3 || (r.count == 2 && r.contains { $0.line.text.countScalars(\.isLetter) >= 2 }) }.count
        return multi >= 4 && Double(multi) >= 0.5 * Double(grouped.count)
    }

    /// The paths are only rules and outlined boxes that no rule crosses, in a grid covering most of the cluster: a form's
    /// boxes (a table to fill in, mostly empty), not a chart (bars are filled, gridlines cross a data line).
    static func isFormGrid(_ paths: [(box: RectD, stroked: Bool)], _ cluster: RectD) -> Bool {
        if !paths.allSatisfy({ $0.stroked || $0.box.width <= thin || $0.box.height <= thin }) { return false }
        let thinBoxes = paths.filter { $0.box.width <= thin || $0.box.height <= thin }.map(\.box)
        func crossed(_ b: RectD) -> Bool {
            thinBoxes.contains { r in
                r.height <= thin
                    ? r.centerY > b.y + 3 && r.centerY < b.bottom - 3 && ((r.x < b.x - 3 && r.right > b.x + 3) || (r.x < b.right - 3 && r.right > b.right + 3))
                    : r.centerX > b.x + 3 && r.centerX < b.right - 3 && ((r.y < b.y - 3 && r.bottom > b.y + 3) || (r.y < b.bottom - 3 && r.bottom > b.bottom + 3))
            }
        }
        for g in grids(rulesFromPaths(paths)) {
            if (g.xs[g.xs.count - 1] - g.xs[0]) * (g.ys[g.ys.count - 1] - g.ys[0]) < 0.5 * cluster.width * cluster.height { continue }
            // Each outlined shape holds the rules that reach it (a frame, a cell); a chart's gridlines run through its data
            // line's bounds and out the other side.
            let boxes = paths.filter { $0.box.width > thin && $0.box.height > thin }.map { p in
                framePadding(p.box, thinBoxes).map { p.box.inflate(-$0) } ?? p.box
            }
            if !boxes.contains(where: crossed) { return true }
        }
        return false
    }

    /// The paths draw a grid with text in at least half its cells.
    static func isRuledTable(_ paths: [(box: RectD, stroked: Bool)], _ lines: [ExportLine]) -> Bool {
        for grid in grids(rulesFromPaths(paths)) {
            let rowCount = grid.ys.count - 1, cols = grid.xs.count - 1
            var filled = Set<CellKey>()
            for l in lines {
                let r = grid.ys.lastIndex { $0 <= l.box.centerY } ?? -1
                let c = grid.xs.lastIndex { $0 <= l.box.centerX } ?? -1
                if r >= 0 && r < rowCount && c >= 0 && c < cols { filled.insert(CellKey(r: r, c: c)) }
            }
            if Double(filled.count) >= 0.5 * Double(rowCount * cols) { return true }
        }
        return false
    }

    // ---- tables from ruled grids ----

    struct Grid {
        var xs: [Double]
        var ys: [Double]
        var verticals: [RectD]
    }

    struct CellKey: Hashable {
        var r: Int
        var c: Int
    }

    /// Grids of crossing horizontal and vertical rules with at least two columns.
    static func grids(_ rules: [RectD]) -> [Grid] {
        let tol = 2.5
        let h = rules.filter { $0.height <= thin && $0.width > 6 }
        let v = rules.filter { $0.width <= thin && $0.height > 6 }
        if h.count < 2 || v.count < 3 || h.count + v.count > 3000 { return [] }

        // Union-find over rules that cross or touch.
        var parent = Array(0..<(h.count + v.count))
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var k = i
            while parent[k] != r {
                let next = parent[k]
                parent[k] = r
                k = next
            }
            return r
        }
        for a in h.indices {
            for b in v.indices {
                let hy = h[a].centerY, vx = v[b].centerX
                if vx >= h[a].x - tol && vx <= h[a].right + tol && hy >= v[b].y - tol && hy <= v[b].bottom + tol {
                    let ra = find(a), rb = find(h.count + b)
                    parent[ra] = rb
                }
            }
        }
        var result: [Grid] = []
        for group in groupedInOrder(Array(0..<(h.count + v.count)), by: find) {
            let hs = group.items.filter { $0 < h.count }.map { h[$0] }
            let vs = group.items.filter { $0 >= h.count }.map { v[$0 - h.count] }
            if hs.count < 2 || vs.count < 3 { continue }
            let xs = cluster(vs.map(\.centerX), tol)
            let ys = cluster(hs.map(\.centerY), tol)
            if xs.count >= 3 && ys.count >= 2 { result.append(Grid(xs: xs, ys: ys, verticals: vs)) }
        }
        return result
    }

    static func cluster(_ values: [Double], _ tol: Double) -> [Double] {
        var result: [Double] = []
        var group: [Double] = []
        for x in values.sorted() {
            if let last = group.last, x - last > tol {
                result.append(group.reduce(0, +) / Double(group.count))
                group.removeAll()
            }
            group.append(x)
        }
        if !group.isEmpty { result.append(group.reduce(0, +) / Double(group.count)) }
        return result
    }

    /// The table a grid draws, with the lines and pictures inside it (removed from `lines` and `images`). Cells without a
    /// rule between them in a row are merged. Nil when fewer than two cells hold something, or none holds text (a box
    /// around a paragraph, an empty form grid).
    static func tableFromGrid(_ grid: Grid, _ lines: inout [ExportLine], _ images: inout [ExportImage], _ body: Double) -> DocTable? {
        let xs = grid.xs, ys = grid.ys
        let rowCount = ys.count - 1, cols = xs.count - 1
        let bounds = RectD.fromEdges(xs[0], ys[0], xs[xs.count - 1], ys[ys.count - 1])
        // start[r][c]: the column where the merged cell holding (r, c) starts.
        var start = [[Int]](repeating: [Int](repeating: 0, count: cols), count: rowCount)
        for r in 0..<rowCount {
            for c in stride(from: 1, to: cols, by: 1) {
                let top = ys[r], bottom = ys[r + 1]
                let ruled = grid.verticals.contains { abs($0.centerX - xs[c]) <= 2.5 && min($0.bottom, bottom) - max($0.y, top) >= 0.6 * (bottom - top) }
                start[r][c] = ruled ? c : start[r][c - 1]
            }
        }
        func cellAt(_ box: RectD) -> CellKey? {
            let cx = box.centerX, cy = box.centerY
            if !bounds.contains(cx, cy) { return nil }
            let r = min(max(ys.lastIndex { $0 <= cy } ?? -1, 0), rowCount - 1)
            let c = min(max(xs.lastIndex { $0 <= cx } ?? -1, 0), cols - 1)
            return CellKey(r: r, c: start[r][c])
        }
        var content: [CellKey: [ExportLine]] = [:]
        var used = IndexSet()
        for (i, line) in lines.enumerated() {
            guard let key = cellAt(line.box) else { continue }
            content[key, default: []].append(line)
            used.insert(i)
        }
        var pictures: [CellKey: [DocPicture]] = [:]
        var usedImages = IndexSet()
        for (i, img) in images.enumerated() {
            // A picture inside one cell (an icon), not one the grid is drawn over.
            guard let key = cellAt(img.box), img.box.width <= bounds.width / 2, img.box.height <= bounds.height / 2 else { continue }
            pictures[key, default: []].append(DocPicture(image: img, box: img.box))
            usedImages.insert(i)
        }
        // A third of the cells at least hold something (a form's grid of empty boxes isn't a table to rebuild).
        let cellCount = start.reduce(0) { n, row in n + row.indices.filter { row[$0] == $0 }.count }
        let filled = Set(content.keys).union(pictures.keys).count
        if content.isEmpty || filled < 2 || Double(filled) < Double(cellCount) / 3.0 { return nil }
        lines = lines.indices.filter { !used.contains($0) }.map { lines[$0] }
        images = images.indices.filter { !usedImages.contains($0) }.map { images[$0] }

        var docRows: [[DocCell]] = []
        for r in 0..<rowCount {
            var row: [DocCell] = []
            var c = 0
            while c < cols {
                var span = 1
                while c + span < cols && start[r][c + span] == c { span += 1 }
                let cell = RectD.fromEdges(xs[c], ys[r], xs[c + span], ys[r + 1])
                var docCell = DocCell(content[CellKey(r: r, c: c)].map { cellParagraphs($0, cell, body) } ?? [], colSpan: span)
                docCell.pictures = pictures[CellKey(r: r, c: c)] ?? []
                row.append(docCell)
                c += span
            }
            docRows.append(row)
        }
        var table = DocTable(docRows, (0..<cols).map { xs[$0 + 1] - xs[$0] }, true, bounds)
        table.rowHeights = (0..<rowCount).map { ys[$0 + 1] - ys[$0] }
        return table
    }

    static func cellParagraphs(_ lines: [ExportLine], _ cell: RectD, _ body: Double) -> [DocParagraph] {
        let items = lines.sorted { a, b in
            let ya = bankers(a.box.y), yb = bankers(b.box.y)
            return ya != yb ? ya < yb : a.box.x < b.box.x
        }.map { Item($0.box, $0, nil, column: cell) }
        return spaced(flow(items, body)).compactMap(\.paragraph)
    }
}
