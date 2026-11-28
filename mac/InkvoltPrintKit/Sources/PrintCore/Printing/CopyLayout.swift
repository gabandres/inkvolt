import Foundation

/// Where an image goes on the paper, in the paper's units (left, top, width, height).
public struct Placement: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var right: Double { x + width }
    public var bottom: Double { y + height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The part both cover; empty (all zero) when they don't overlap.
    public func intersect(_ other: Placement) -> Placement {
        let l = max(x, other.x), t = max(y, other.y)
        let r = min(right, other.right), b = min(bottom, other.bottom)
        return r > l && b > t ? Placement(l, t, r - l, b - t) : Placement(0, 0, 0, 0)
    }

    /// Grown by `d` on every side (shrunk when negative).
    public func inflate(_ d: Double) -> Placement { Placement(x - d, y - d, width + 2 * d, height + 2 * d) }
}

/// Copying (scan, then print what was scanned): page placement at actual size, 2-up and 4-up sides and the order copies
/// print in, and the ID card copy layout, front on the top half and back on the bottom half of one sheet. Units are whatever
/// the caller uses for both page and paper.
public enum CopyLayout {
    /// One side of an ID card is scanned from the glass's top-left corner (the scanner's reference corner): 4.5 × 3 in, in
    /// eSCL's 1/300 in. An ID-1 card is 3.37 × 2.13 in, so there's room for a card placed a little off the corner.
    public static let idCardScanWidth = 1350, idCardScanHeight = 900

    /// Space kept clear around each half, so a side never runs into the printer's unprintable edge (¼ in at 96 per inch).
    public static let idCardMargin = 24.0

    /// A scanned page's size in inches, from its pixel size and the resolution it was scanned at.
    public static func inches(_ widthPx: Int, _ heightPx: Int, _ dpi: Int) -> (width: Double, height: Double) {
        dpi <= 0 ? (0, 0) : (Double(widthPx) / Double(dpi), Double(heightPx) / Double(dpi))
    }

    /// The ID card scan region on this scanner's glass: the corner area, clamped to what the glass allows.
    public static func idCardRequest(_ color: ScanColor, _ dpi: Int) -> ScanRequest {
        ScanRequest(source: .platen, color: color, resolution: dpi, width: idCardScanWidth, height: idCardScanHeight)
    }

    /// A copied page centred on the paper, turned to the paper's orientation as it prints: at its own size (only pages
    /// larger than the paper shrink to fit), or enlarged or shrunk to fill the paper.
    public static func page(_ pageW: Double, _ pageH: Double, _ paperW: Double, _ paperH: Double, _ sizing: PageSizing = .actualSize) -> PagePlacement {
        PageFit.place(pageW, pageH, paperW, paperH, sizing)
    }

    /// ID card copy: `front` centred in the top half, `back` in the bottom half, both at actual size. A side larger than its
    /// half (minus `margin` all round) shrinks to fit; both sides then use the same scale, so the copy's two halves always
    /// match.
    public static func idCard(_ paperW: Double, _ paperH: Double, _ front: (w: Double, h: Double), _ back: (w: Double, h: Double),
                              margin: Double = idCardMargin) -> (front: Placement, back: Placement) {
        let halfH = paperH / 2
        let boxW = max(1, paperW - 2 * margin)
        let boxH = max(1, halfH - 2 * margin)
        let scale = min(PageFit.scale(front.w, front.h, boxW, boxH, .actualSize), PageFit.scale(back.w, back.h, boxW, boxH, .actualSize))
        func place(_ top: Double, _ side: (w: Double, h: Double)) -> Placement {
            let (w, h) = (side.w * scale, side.h * scale)
            return Placement((paperW - w) / 2, top + (halfH - h) / 2, w, h)
        }
        return (place(0, front), place(halfH, back))
    }

    /// Pages per side of paper a page copy offers: one, 2-up and 4-up.
    public static let pagesPerSheetChoices = [1, 2, 4]

    /// Space kept clear around the pages of a 2-up or 4-up side (¼ in at 96 per inch), and between them (⅛ in).
    public static let nUpMargin = 24.0, nUpGap = 12.0

    /// A pages-per-sheet count other than 1, 2 or 4 (Windows' `ArgumentOutOfRangeException`).
    public struct PagesPerSheetError: Error, Equatable {
        public let pagesPerSheet: Int

        public init(pagesPerSheet: Int) { self.pagesPerSheet = pagesPerSheet }
    }

    /// The page indices printed on each side of paper, in reading order: pages 0–1 on the first side of a 2-up copy, and so on.
    public static func sides(_ pageCount: Int, _ pagesPerSheet: Int) throws -> [[Int]] {
        try check(pagesPerSheet)
        var sides: [[Int]] = []
        var side = 0
        while Int64(side) * Int64(pagesPerSheet) < Int64(pageCount) {
            sides.append(try pagesOnSide(pageCount, pagesPerSheet, side))
            side += 1
        }
        return sides
    }

    /// The page indices on one side (`sides`); none for a side past the last page.
    public static func pagesOnSide(_ pageCount: Int, _ pagesPerSheet: Int, _ side: Int) throws -> [Int] {
        try check(pagesPerSheet)
        let first = Int64(side) * Int64(pagesPerSheet)
        guard side >= 0, first < Int64(pageCount) else { return [] }
        let count = min(Int64(pagesPerSheet), Int64(pageCount) - first)
        return (0..<Int(count)).map { Int(first) + $0 } // bounded: first < pageCount, an Int
    }

    /// The sides one print job holds, in order (−1: a blank back), and the copy count for the print ticket. Collated (or one
    /// copy): each side once, the queue making the copies (1 2 3, 1 2 3); but two-sided with an odd number of sides, the
    /// copies are made here, each ending on a blank back, so no two copies share a sheet. Uncollated: each sheet repeated
    /// here, one copy on the ticket (1 1, 2 2, 3 3), so it doesn't depend on a driver honouring the ticket's collation; on
    /// two-sided paper a sheet is a side and its back, an odd last side getting a blank back.
    public static func order(_ sideCount: Int, _ copies: Int, collate: Bool, twoSided: Bool) -> (sides: [Int], ticketCopies: Int) {
        let copies = max(1, copies)
        if sideCount <= 0 { return ([], copies) }
        let once = Array(0..<sideCount)
        if copies == 1 { return (once, 1) }
        if collate && twoSided && sideCount % 2 == 1 { return (Array(repeating: once + [-1], count: copies).flatMap { $0 }, 1) }
        if collate { return (once, copies) }
        var order: [Int] = []
        let perSheet = twoSided ? 2 : 1
        for first in stride(from: 0, to: sideCount, by: perSheet) {
            for _ in 0..<copies {
                order.append(first)
                if twoSided { order.append(first + 1 < sideCount ? first + 1 : -1) }
            }
        }
        return (order, 1)
    }

    /// Sheets of paper a page copy uses: its sides (pages per sheet), on one or both sides of the paper, times the copies.
    public static func sheets(_ pageCount: Int, _ pagesPerSheet: Int, _ copies: Int, twoSided: Bool) throws -> Int {
        let sides = try sides(pageCount, pagesPerSheet).count
        return (twoSided ? (sides + 1) / 2 : sides) * max(1, copies)
    }

    /// Where each page of one side goes. One page per sheet: centred and sized per `sizing`, as a plain copy. 2-up: two
    /// cells, one above the other on portrait paper (beside each other on landscape paper); 4-up: two by two, in reading
    /// order. Each page sits in its cell as on its own sheet (`PageFit.place`: turned a quarter when the cell's orientation
    /// differs, so 2-up portrait pages read as a landscape sheet), inside a margin all round.
    public static func nUp(_ pages: [(w: Double, h: Double)], _ pagesPerSheet: Int, _ paperW: Double, _ paperH: Double,
                           _ sizing: PageSizing = .actualSize) throws -> [PagePlacement] {
        try check(pagesPerSheet)
        if pagesPerSheet == 1 { return pages.prefix(1).map { PageFit.place($0.w, $0.h, paperW, paperH, sizing) } }
        let (cols, rows) = pagesPerSheet == 4 ? (2, 2) : paperW > paperH ? (2, 1) : (1, 2)
        let cellW = max(1, (paperW - 2 * nUpMargin - Double(cols - 1) * nUpGap) / Double(cols))
        let cellH = max(1, (paperH - 2 * nUpMargin - Double(rows - 1) * nUpGap) / Double(rows))
        var placed: [PagePlacement] = []
        for i in 0..<min(pages.count, pagesPerSheet) {
            let x = nUpMargin + Double(i % cols) * (cellW + nUpGap), y = nUpMargin + Double(i / cols) * (cellH + nUpGap)
            var p = PageFit.place(pages[i].w, pages[i].h, cellW, cellH, sizing)
            p.at.x += x
            p.at.y += y
            placed.append(p)
        }
        return placed
    }

    private static func check(_ pagesPerSheet: Int) throws {
        if !pagesPerSheetChoices.contains(pagesPerSheet) { throw PagesPerSheetError(pagesPerSheet: pagesPerSheet) }
    }
}
