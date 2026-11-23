import Foundation

/// Print a PDF's layouts (roadmap 4.18): as before, several pages per sheet, a booklet, or a poster.
public enum PdfLayout: Sendable, CaseIterable { case normal, pagesPerSheet, booklet, poster }

/// How a laid-out job's two sides are printed (`SheetPrint.route`).
public enum SheetRoute: Equatable, Sendable { case oneSided, printer, byHand, noBothSides }

/// What the person chose for Print a PDF's layout. `pagesPerSheet`: 2, 4, 6, 9 or 16 (`Sheets.PrintSetup.pagesPerSheetChoices`);
/// `posterPercent`: the poster's size as a percentage of the page's (`SheetPrint.posterPercents`).
public struct SheetChoice: Equatable, Sendable {
    public var layout: PdfLayout
    public var pagesPerSheet: Int
    public var posterPercent: Int
    public var cutMarks: Bool

    public init(_ layout: PdfLayout, pagesPerSheet: Int = 2, posterPercent: Int = 200, cutMarks: Bool = true) {
        self.layout = layout
        self.pagesPerSheet = pagesPerSheet
        self.posterPercent = posterPercent
        self.cutMarks = cutMarks
    }
}

/// Inkvolt Print's use of the shared sheet layouts (`Sheets.PrintLayout`): the setup for a choice, the paper's area, how many
/// sides and sheets a job takes, which backs are drawn upside down, and how sharp a poster's pages are drawn. Lengths in
/// device-independent pixels (96 an inch), the unit Windows' print path uses; the Mac's draws in points, 72 an inch, from the
/// same plan (`SheetPrint.pointsPerUnit`). The Windows core's `SheetPrint`.
public enum SheetPrint {
    /// Space kept clear on every side of the paper (¼ in), outside any printer's unprintable edge.
    public static let margin = 24.0

    /// How much a poster's neighboring sheets repeat of each other (¼ in), for taping or gluing.
    public static let posterOverlap = 24.0

    /// A page drawn for printing, at this resolution; a poster's enlarged pages at more (`renderDpi`).
    public static let baseDpi = 300, maxDpi = 600

    public static let posterPercents = [150, 200, 300, 400]

    /// Points (the Mac's print unit, 72 an inch) per DIP (96 an inch).
    public static let pointsPerUnit = 72.0 / 96.0

    /// Letter (or A4 where the region is metric), for counting sheets before the printer's paper is known.
    public static func guessPaper(metric: Bool) -> (width: Double, height: Double) {
        // Inches, then DIPs: spelled out, as CI's Swift gave up type-checking the literals in one tuple expression.
        let inches: (Double, Double) = metric ? (8.27, 11.69) : (8.5, 11)
        return (inches.0 * 96, inches.1 * 96)
    }

    /// The shared layout's setup for a choice; nil for the normal one page per sheet (the print path as before).
    public static func setup(_ choice: SheetChoice) -> Sheets.PrintSetup? {
        switch choice.layout {
        case .pagesPerSheet:
            Sheets.PrintSetup(handling: .pagesPerSheet,
                              pagesPerSheet: Sheets.PrintSetup.pagesPerSheetChoices.contains(choice.pagesPerSheet) ? choice.pagesPerSheet : 2)
        case .booklet:
            Sheets.PrintSetup(handling: .booklet)
        case .poster:
            Sheets.PrintSetup(handling: .poster, posterScale: Double(posterPercents.contains(choice.posterPercent) ? choice.posterPercent : 200) / 100,
                              overlap: posterOverlap, cutMarks: choice.cutMarks)
        case .normal:
            nil
        }
    }

    /// The part of a `paperW` × `paperH` sheet pages go on: `margin` in from each edge.
    public static func area(_ paperW: Double, _ paperH: Double) -> Placement {
        Placement(margin, margin, max(1, paperW - 2 * margin), max(1, paperH - 2 * margin))
    }

    /// The most sides one job prints, copies included: past it Print a PDF says so instead of drawing them all.
    public static let maxSides = 1000

    /// A page side longer than this (200 in) is counted at it: a file's absurd page size can't make millions of poster tiles.
    public static let maxPageSide = 200.0 * 96

    /// The job's sheets on this paper: pages numbered 0… in the order given, each `sizes`' size (DIPs).
    public static func plan(_ sizes: [(Double, Double)], _ paperW: Double, _ paperH: Double, _ setup: Sheets.PrintSetup) -> Sheets.PrintPlan {
        let bounded = sizes.map(Self.bounded)
        return Sheets.PrintPlan(Array(sizes.indices), { bounded[$0] }, area(paperW, paperH), setup)
    }

    /// A page's size as the layout takes it: a side past `maxPageSide` brings the page down to it, its shape kept, so a
    /// poster's tiles and the drawing of the page agree; a size that isn't a number is a square of that side, a side under 1
    /// is 1. The print path draws each page at this size.
    public static func bounded(_ s: (Double, Double)) -> (Double, Double) {
        let (w, h) = s
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return (maxPageSide, maxPageSide) }
        let k = min(1, maxPageSide / max(w, h))
        return (max(1, w * k), max(1, h * k))
    }

    /// How a job's two sides get printed: one-sided; by the printer; by hand (fronts, the stack put back, backs); or not at
    /// all (`noBothSides`: a booklet, or both sides asked, on a printer that can't and with no by-hand offered), which Print
    /// a PDF refuses rather than sending a two-sided job the printer would print on one side.
    public static func route(_ setup: Sheets.PrintSetup, asked: Bool, printerTwoSided: Bool, byHand: Bool) -> SheetRoute {
        !twoSided(setup, asked: asked) ? .oneSided : printerTwoSided ? .printer : byHand ? .byHand : .noBothSides
    }

    /// The document's page number a side shows first (pages per sheet's first cell, a booklet's left page or its only one),
    /// for two-sided by hand's words ("page 7"): `numbers` are the 1-based pages printed, in the job's order.
    public static func pageOnSide(_ plan: Sheets.PrintPlan, _ side: Int, _ numbers: [Int]) -> Int {
        guard side >= 0, side < plan.sheetCount, !numbers.isEmpty else { return 0 }
        guard let first = plan.sheet(side).pages.map(\.page).min() else { return 0 }
        return numbers[min(max(first, 0), numbers.count - 1)]
    }

    /// The job is too big to print in one go (`maxSides`, counted on the guessed paper as `count` does).
    public static func tooMany(_ setup: Sheets.PrintSetup, _ sizes: [(Double, Double)], _ paper: (Double, Double), copies: Int) -> Bool {
        count(setup, sizes, paper, copies: copies, twoSided: false).sides > maxSides
    }

    /// Whether the job prints on both sides: a booklet always (it can't be folded otherwise), a poster never (its sheets are
    /// trimmed and joined edge to edge), pages per sheet as asked.
    public static func twoSided(_ setup: Sheets.PrintSetup, asked: Bool) -> Bool {
        switch setup.handling {
        case .booklet: true
        case .poster: false
        default: asked
        }
    }

    /// A side drawn upside down: the back of a sheet used turned (a booklet's, or 2 or 6 portrait pages side by side), printed
    /// flipping on the long edge as both a duplexer and two-sided by hand do. Turned a half, it reads the right way up once
    /// the sheet is turned over like a booklet's page (what flipping on the short edge would give, which a printer may not
    /// offer). Backs are the odd sides: every copy starts on a sheet of its own.
    public static func halfTurned(_ sheet: Sheets.PrintSheet, _ side: Int, twoSided: Bool) -> Bool {
        twoSided && side % 2 == 1 && sheet.pages.contains { $0.turns == 1 }
    }

    /// The sides one job prints, in order, every copy made here (the ticket asks for one): each copy's sides 0…`sides`−1,
    /// and on both sides of the paper a copy with an odd count ends on a blank back (−1) so the next starts on a sheet of its own.
    public static func order(_ sides: Int, _ copies: Int, twoSided: Bool) -> [Int] {
        let copies = min(max(copies, 1), 999)
        var order: [Int] = []
        guard sides > 0 else { return order }
        for c in 0..<copies {
            order += 0..<sides
            if twoSided && sides % 2 == 1 && c < copies - 1 { order.append(-1) }
        }
        return order
    }

    /// The resolution a job's pages are drawn at: a poster's enlarged pages sharper, up to `maxDpi`.
    public static func renderDpi(_ setup: Sheets.PrintSetup?) -> Int {
        guard let setup, setup.handling == .poster else { return baseDpi }
        let dpi = (Double(baseDpi) * setup.posterScale).rounded(.toNearestOrEven)
        return dpi.isFinite ? Int(min(max(dpi, Double(baseDpi)), Double(maxDpi))) : baseDpi
    }

    /// How many sides the job prints and on how many sheets of paper, for the summary (the paper guessed: `guessPaper`).
    /// Copies each start on a sheet of their own.
    public static func count(_ setup: Sheets.PrintSetup, _ sizes: [(Double, Double)], _ paper: (Double, Double), copies: Int,
                             twoSided asked: Bool) -> (sides: Int, sheets: Int) {
        if sizes.isEmpty { return (0, 0) }
        let copies = min(max(1, copies), 1_000_000) // a count past every limit either way, never one that overflows
        let sides = plan(sizes, paper.0, paper.1, setup).sheetCount
        let sheets = twoSided(setup, asked: asked) ? (sides + 1) / 2 : sides
        return (sides * copies, sheets * copies)
    }
}
