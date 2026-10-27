import Foundation

/// How pages go onto the paper when printing (Acrobat's "Page Sizing & Handling").
public enum PrintHandling: Sendable {
    /// One page per sheet, turned to the paper's orientation, sized by `PrintSetup.sizing`.
    case fit
    /// Several pages per sheet (2, 4, 6, 9 or 16), each scaled to its cell.
    case pagesPerSheet
    /// Saddle-stitched booklet: two pages on each side of a sheet, ordered so the folded stack reads in order.
    case booklet
    /// One page enlarged across several sheets, to be trimmed and put together.
    case poster
}

/// Size in fit handling.
public enum PrintSizing: Sendable {
    /// The page's own size; only pages larger than the paper shrink to fit.
    case actualSize
    /// Every page shrinks or grows to fill the paper.
    case fitToPaper
}

/// The order pages fill a sheet's cells: rows left to right (across), or columns top to bottom (down).
public enum PagesOrder: Sendable { case across, down }

/// Print handling choices. Lengths (`overlap`) are in the paper's units.
public struct PrintSetup: Equatable, Sendable {
    public var handling = PrintHandling.fit
    public var sizing = PrintSizing.actualSize
    /// Pages per sheet: 2, 4, 6, 9 or 16.
    public var pagesPerSheet = 2
    public var order = PagesOrder.across
    /// A thin line around each page (pages per sheet).
    public var borders = false
    /// Booklet bound on the right (right-to-left languages): page 1 is on the right of the cover's back.
    public var rightBinding = false
    /// Poster: the page's size on paper as a multiple of its own (2 = 200 %).
    public var posterScale = 2.0
    /// Poster: how much neighboring sheets repeat of each other, for gluing.
    public var overlap = 0.0
    /// Poster: marks where to trim each sheet (the middle of each overlap).
    public var cutMarks = true

    public static let pagesPerSheetChoices = [2, 4, 6, 9, 16]

    public init(handling: PrintHandling = .fit, sizing: PrintSizing = .actualSize, pagesPerSheet: Int = 2, order: PagesOrder = .across,
                borders: Bool = false, rightBinding: Bool = false, posterScale: Double = 2, overlap: Double = 0, cutMarks: Bool = true) {
        self.handling = handling
        self.sizing = sizing
        self.pagesPerSheet = pagesPerSheet
        self.order = order
        self.borders = borders
        self.rightBinding = rightBinding
        self.posterScale = posterScale
        self.overlap = overlap
        self.cutMarks = cutMarks
    }
}

/// A page (or, for a poster, part of one) on a sheet. `box`: where, on the paper (origin at its top-left, y down);
/// `turns`: quarter turns clockwise it is drawn with (0 or 1); `source`: the part of the page shown (page units, as
/// shown; nil for all of it). With a turn, the box's width is the source's height.
public struct PlacedPage: Equatable, Sendable {
    public var page: Int
    public var box: RectD
    public var turns: Int
    public var source: RectD?

    public init(_ page: Int, _ box: RectD, _ turns: Int, source: RectD? = nil) {
        self.page = page
        self.box = box
        self.turns = turns
        self.source = source
    }
}

/// A cut mark: a short line on the sheet (paper coordinates).
public struct CutMark: Equatable, Sendable {
    public var x1: Double, y1: Double, x2: Double, y2: Double
}

/// What one side of one sheet of paper carries.
public struct PrintSheet: Equatable, Sendable {
    public var pages: [PlacedPage]
    public var marks: [CutMark]
    public var borders: Bool

    public static let blank = PrintSheet(pages: [], marks: [], borders: false)
}

/// Where printed pages go on the paper: one per sheet (fit), several per sheet, booklets and posters. Pure geometry, in
/// any units as long as pages and paper use the same ones. `PrintPlan` lays out sheets one at a time, so printing draws
/// each sheet only when it is sent.
public enum PrintLayout {
    /// The factor that sizes a page (already turned to the paper's orientation) on paper `w` × `h`, keeping its
    /// proportions. Actual size shrinks only what doesn't fit; fit to paper also enlarges (pages within 3 % of the paper
    /// print at their own size).
    public static func scale(_ pageW: Double, _ pageH: Double, _ w: Double, _ h: Double, _ sizing: PrintSizing) -> Double {
        if pageW <= 0 || pageH <= 0 { return 1 }
        let fit = min(w / pageW, h / pageH)
        if sizing == .actualSize || (fit > 1 && fit < 1.03) { return min(1, fit) }
        return fit
    }

    /// One page per sheet: centered in `area`, turned when that fits better (landscape on portrait paper).
    public static func single(_ page: Int, _ w: Double, _ h: Double, _ area: RectD, _ sizing: PrintSizing) -> PlacedPage {
        let turn = (w > h) != (area.width > area.height) && abs(w - h) > 1
        let (fw, fh) = turn ? (h, w) : (w, h)
        let s = scale(fw, fh, area.width, area.height, sizing)
        let dw = fw * s, dh = fh * s
        return PlacedPage(page, RectD(area.x + (area.width - dw) / 2, area.y + (area.height - dh) / 2, dw, dh), turn ? 1 : 0)
    }

    // ---- Pages per sheet ----

    /// The grid for `n` pages per sheet: columns and rows, and whether the sheet is used turned (its long side across,
    /// the pages turned a quarter clockwise onto the paper): whichever shows a `pageW` × `pageH` page largest.
    public static func grid(_ n: Int, _ pageW: Double, _ pageH: Double, _ areaW: Double, _ areaH: Double) -> (cols: Int, rows: Int, turned: Bool) {
        precondition(PrintSetup.pagesPerSheetChoices.contains(n), "Pages per sheet: 2, 4, 6, 9 or 16.")
        var best = (cols: 1, rows: n, turned: false)
        var bestScale = -1.0
        for turned in [false, true] {
            let (w, h) = turned ? (areaH, areaW) : (areaW, areaH)
            for cols in 1...n where n % cols == 0 {
                let rows = n / cols
                // Grids as people expect them: 2 = 2×1 or 1×2, 6 = 3×2 or 2×3, squares otherwise.
                if max(cols, rows) > 2 * min(cols, rows) && n != 2 { continue }
                let s = min(w / Double(cols) / pageW, h / Double(rows) / pageH)
                if s > bestScale * 1.0001 {
                    bestScale = s
                    best = (cols, rows, turned)
                }
            }
        }
        return best
    }

    /// The cell of the `k`th page on a cols × rows grid of a w × h sheet (sheet coordinates).
    public static func cell(_ k: Int, _ cols: Int, _ rows: Int, _ order: PagesOrder, _ w: Double, _ h: Double) -> RectD {
        let (col, row) = order == .across ? (k % cols, k / cols) : (k / rows, k % rows)
        let cw = w / Double(cols), ch = h / Double(rows)
        return RectD(Double(col) * cw, Double(row) * ch, cw, ch)
    }

    /// A sheet of `pages` (at most `n`; their sizes from `size`), laid out on the grid `grid` picks for the first page,
    /// each page scaled to fit its cell, centered.
    public static func pagesPerSheet(_ pages: [Int], _ size: (Int) -> (Double, Double), _ n: Int, _ order: PagesOrder, _ borders: Bool,
                                     _ area: RectD) -> PrintSheet {
        if pages.isEmpty { return .blank }
        let (pw, ph) = size(pages[0])
        let (cols, rows, turned) = grid(n, pw, ph, area.width, area.height)
        let (w, h) = turned ? (area.height, area.width) : (area.width, area.height)
        // A small gap between neighbors, so pages (and their borders) don't touch.
        let gap = min(w / Double(cols), h / Double(rows)) * 0.02
        var list: [PlacedPage] = []
        for k in 0..<min(n, pages.count) {
            let c = cell(k, cols, rows, order, w, h).inflate(-gap / 2)
            let (sw, sh) = size(pages[k])
            let s = min(c.width / sw, c.height / sh)
            let box = RectD(c.x + (c.width - sw * s) / 2, c.y + (c.height - sh * s) / 2, sw * s, sh * s)
            list.append(PlacedPage(pages[k], toPaper(box, turned, area), turned ? 1 : 0))
        }
        return PrintSheet(pages: list, marks: [], borders: borders)
    }

    /// A box on a sheet used turned (its width along the paper's height) to the paper: the sheet is turned a quarter
    /// clockwise onto `area`, so its top-left corner lands at the area's top-right.
    static func toPaper(_ box: RectD, _ turned: Bool, _ area: RectD) -> RectD {
        turned ? RectD(area.right - box.bottom, area.y + box.x, box.height, box.width) : RectD(area.x + box.x, area.y + box.y, box.width, box.height)
    }

    private static func toPaper(_ x: Double, _ y: Double, _ turned: Bool, _ area: RectD) -> (Double, Double) {
        turned ? (area.right - y, area.y + x) : (area.x + x, area.y + y)
    }

    // ---- Booklet ----

    /// Sheets of paper a booklet of `pageCount` pages needs (4 pages each, both sides).
    public static func bookletSheets(_ pageCount: Int) -> Int { max(1, (pageCount + 3) / 4) }

    /// The pages on each side of a saddle-stitched booklet's sheets, in printing order (sheet 1 front, sheet 1 back,
    /// sheet 2 front, …): indexes into the `pageCount` pages printed, -1 for a blank (padded to a multiple of 4 with
    /// blank pages at the end). Folded and stacked, the sheets read 1, 2, 3, … With `rightBinding` each side is mirrored.
    public static func bookletSides(_ pageCount: Int, rightBinding: Bool = false) -> [(left: Int, right: Int)] {
        let sheets = bookletSheets(pageCount)
        let n = sheets * 4
        func p(_ i: Int) -> Int { i < pageCount ? i : -1 }
        var sides: [(left: Int, right: Int)] = []
        for s in 0..<sheets {
            let front = (p(n - 1 - 2 * s), p(2 * s))
            let back = (p(2 * s + 1), p(n - 2 - 2 * s))
            sides.append(rightBinding ? (front.1, front.0) : front)
            sides.append(rightBinding ? (back.1, back.0) : back)
        }
        return sides
    }

    /// One side of a booklet sheet: the sheet used with its long side across (turned onto portrait paper), the two
    /// pages side by side, each scaled to its half and set against the fold.
    public static func bookletSide(_ left: Int, _ right: Int, _ size: (Int) -> (Double, Double), _ area: RectD) -> PrintSheet {
        let turned = area.width < area.height
        let (w, h) = turned ? (area.height, area.width) : (area.width, area.height)
        let half = w / 2
        var list: [PlacedPage] = []
        for (page, isLeft) in [(left, true), (right, false)] where page >= 0 {
            let (pw, ph) = size(page)
            let s = min(half / pw, h / ph)
            let bw = pw * s, bh = ph * s
            let box = RectD(isLeft ? half - bw : half, (h - bh) / 2, bw, bh)
            list.append(PlacedPage(page, toPaper(box, turned, area), turned ? 1 : 0))
        }
        return PrintSheet(pages: list, marks: [], borders: false)
    }

    // ---- Poster ----

    /// How a page `pageW` × `pageH` enlarged `scale` times is tiled: columns and rows of sheets of `areaW` × `areaH`,
    /// overlapping by `overlap`, and whether the sheets are used turned (fewer sheets wins; upright on a tie).
    public static func posterTiles(_ pageW: Double, _ pageH: Double, _ scale: Double, _ areaW: Double, _ areaH: Double,
                                   _ overlap: Double) -> (cols: Int, rows: Int, turned: Bool) {
        func count(_ w: Double, _ h: Double) -> (Int, Int) {
            let ov = clampOverlap(overlap, w, h)
            return (tiles(pageW * scale, w, ov), tiles(pageH * scale, h, ov))
        }
        let (c1, r1) = count(areaW, areaH)
        let (c2, r2) = count(areaH, areaW)
        return c2 * r2 < c1 * r1 ? (c2, r2, true) : (c1, r1, false)
    }

    private static func clampOverlap(_ overlap: Double, _ w: Double, _ h: Double) -> Double { min(max(overlap, 0), min(w, h) / 4) }

    /// Tiles of `tile` overlapping by `ov` needed to cover `length`.
    private static func tiles(_ length: Double, _ tile: Double, _ ov: Double) -> Int {
        max(1, Int(((length - ov) / (tile - ov) - 1e-9).rounded(.up)))
    }

    /// Sheet `tile` (row by row from the top-left) of the poster of page `page` (`pageW` × `pageH`): the part of the page
    /// it shows, centered on the tiles as a whole, and cut marks at the middle of each overlap with a neighbor.
    public static func posterTile(_ page: Int, _ pageW: Double, _ pageH: Double, _ tile: Int, _ setup: PrintSetup, _ area: RectD) -> PrintSheet {
        let scale = setup.posterScale
        let (cols, rows, turned) = posterTiles(pageW, pageH, scale, area.width, area.height, setup.overlap)
        let (w, h) = turned ? (area.height, area.width) : (area.width, area.height)
        let ov = clampOverlap(setup.overlap, w, h)
        let stepX = w - ov, stepY = h - ov
        let pw = pageW * scale, ph = pageH * scale
        // The poster centered on what the tiles cover together.
        let ox = (Double(cols) * stepX + ov - pw) / 2
        let oy = (Double(rows) * stepY + ov - ph) / 2
        let col = tile % cols, row = tile / cols
        // This sheet's window onto the enlarged page, and the part of the page in it.
        let window = RectD(Double(col) * stepX - ox, Double(row) * stepY - oy, w, h)
        let shown = window.intersect(RectD(0, 0, pw, ph))
        var pages: [PlacedPage] = []
        if !shown.isEmpty {
            let box = RectD(shown.x - window.x, shown.y - window.y, shown.width, shown.height)
            let source = RectD(shown.x / scale, shown.y / scale, shown.width / scale, shown.height / scale)
            pages.append(PlacedPage(page, toPaper(box, turned, area), turned ? 1 : 0, source: source))
        }

        var marks: [CutMark] = []
        if setup.cutMarks {
            let len = min(min(w, h) * 0.04, 18)
            func mark(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CutMark {
                let (a, b) = toPaper(x1, y1, turned, area)
                let (c, d) = toPaper(x2, y2, turned, area)
                return CutMark(x1: a, y1: b, x2: c, y2: d)
            }
            func vertical(_ x: Double) {
                marks.append(mark(x, 0, x, len))
                marks.append(mark(x, h - len, x, h))
            }
            func horizontal(_ y: Double) {
                marks.append(mark(0, y, len, y))
                marks.append(mark(w - len, y, w, y))
            }
            if col > 0 { vertical(ov / 2) }
            if col < cols - 1 { vertical(w - ov / 2) }
            if row > 0 { horizontal(ov / 2) }
            if row < rows - 1 { horizontal(h - ov / 2) }
        }
        return PrintSheet(pages: pages, marks: marks, borders: false)
    }
}

/// A print job's sheets: how many, and each one laid out when asked for (so a long job is never laid out, or drawn, all
/// at once). Pages are the 0-based page numbers printed, in order; sizes and paper in the same units.
public struct PrintPlan: Sendable {
    private let pages: [Int]
    private let size: @Sendable (Int) -> (Double, Double)
    private let area: RectD
    private let setup: PrintSetup
    private let sides: [(left: Int, right: Int)]?
    private let posterStart: [Int]? // poster: the first sheet of each page, and the total at the end

    /// Sides of paper printed (a booklet: two per sheet of paper).
    public let sheetCount: Int

    /// - Parameters:
    ///   - size: a page's size as shown (rotation applied).
    ///   - area: the paper's printable area (paper coordinates: origin at its top-left, y down).
    public init(_ pages: [Int], _ size: @escaping @Sendable (Int) -> (Double, Double), _ area: RectD, _ setup: PrintSetup) {
        self.pages = pages
        self.size = size
        self.area = area
        self.setup = setup
        switch setup.handling {
        case .booklet:
            let s = PrintLayout.bookletSides(pages.count, rightBinding: setup.rightBinding)
            sides = s
            posterStart = nil
            sheetCount = s.count
        case .pagesPerSheet:
            sides = nil
            posterStart = nil
            sheetCount = (pages.count + setup.pagesPerSheet - 1) / setup.pagesPerSheet
        case .poster:
            var start = [Int](repeating: 0, count: pages.count + 1)
            for (i, p) in pages.enumerated() {
                let (w, h) = size(p)
                let (c, r, _) = PrintLayout.posterTiles(w, h, setup.posterScale, area.width, area.height, setup.overlap)
                start[i + 1] = start[i] + c * r
            }
            sides = nil
            posterStart = start
            sheetCount = start[start.count - 1]
        case .fit:
            sides = nil
            posterStart = nil
            sheetCount = pages.count
        }
    }

    /// Sheets of paper used (a booklet prints on both sides).
    public var paperCount: Int { setup.handling == .booklet ? sheetCount / 2 : sheetCount }

    public func sheet(_ index: Int) -> PrintSheet {
        precondition(index >= 0 && index < sheetCount, "No sheet \(index).")
        switch setup.handling {
        case .booklet:
            let (l, r) = sides![index]
            return PrintLayout.bookletSide(l < 0 ? -1 : pages[l], r < 0 ? -1 : pages[r], size, area)
        case .pagesPerSheet:
            let n = setup.pagesPerSheet
            let slice = Array(pages.dropFirst(index * n).prefix(n))
            return PrintLayout.pagesPerSheet(slice, size, n, setup.order, setup.borders, area)
        case .poster:
            let i = posterStart!.lastIndex { $0 <= index }!
            let (w, h) = size(pages[i])
            return PrintLayout.posterTile(pages[i], w, h, index - posterStart![i], setup, area)
        case .fit:
            let (w, h) = size(pages[index])
            return PrintSheet(pages: [PrintLayout.single(pages[index], w, h, area, setup.sizing)], marks: [], borders: false)
        }
    }
}
