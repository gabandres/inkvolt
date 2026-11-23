import Foundation
import Testing
@testable import PrintCore

/// Roadmap 4.18: Print a PDF's booklet, poster and pages per sheet, laid out by the shared core's `Sheets.PrintLayout` (the
/// Windows core's, moved there from Inkvolt PDF; Inkvolt PDF for Mac keeps its own in PdfCore, whose PrintLayoutTests run on
/// it) through `SheetPrint`. Ported from SheetPrintTests.cs with the same names.
struct SheetPrintTests {
    private static let letter = (816.0, 1056.0)

    private static func pages(_ n: Int) -> [(Double, Double)] { Array(repeating: letter, count: n) }

    private static func setup(_ choice: SheetChoice) -> Sheets.PrintSetup { SheetPrint.setup(choice)! }

    @Test func eachChoiceGivesItsSetup() {
        #expect(SheetPrint.setup(SheetChoice(.normal)) == nil)
        #expect(Self.setup(SheetChoice(.booklet)).handling == .booklet)
        let four = Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4))
        #expect(four.handling == .pagesPerSheet && four.pagesPerSheet == 4)
        #expect(Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 5)).pagesPerSheet == 2) // not a choice: 2
        let poster = Self.setup(SheetChoice(.poster, posterPercent: 300, cutMarks: false))
        #expect(poster.posterScale == 3.0 && poster.overlap == SheetPrint.posterOverlap && !poster.cutMarks)
        #expect(Self.setup(SheetChoice(.poster, posterPercent: 1000)).posterScale == 2.0)
    }

    @Test func aBookletIsTwoSidedAndAPosterNever() {
        let booklet = Self.setup(SheetChoice(.booklet))
        let poster = Self.setup(SheetChoice(.poster))
        let four = Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4))
        #expect(SheetPrint.twoSided(booklet, asked: false))
        #expect(!SheetPrint.twoSided(poster, asked: true))
        #expect(SheetPrint.twoSided(four, asked: true))
        #expect(!SheetPrint.twoSided(four, asked: false))
    }

    @Test func aBookletOfSixPagesTakesTwoSheetsBothSidesPerCopy() {
        let setup = Self.setup(SheetChoice(.booklet))
        let count = SheetPrint.count(setup, Self.pages(6), Self.letter, copies: 3, twoSided: false)
        #expect(count.sides == 4 * 3 && count.sheets == 2 * 3)
        // In the order a folded stack reads: sheet 1 carries 8|1 and 2|7 (pages 7 and 8 blank), sheet 2 6|3 and 4|5.
        let plan = SheetPrint.plan(Self.pages(6), Self.letter.0, Self.letter.1, setup)
        #expect(plan.sheet(0).pages.map(\.page) == [0])
        #expect(plan.sheet(1).pages.map(\.page) == [1])
        #expect(plan.sheet(2).pages.map(\.page) == [5, 2])
        #expect(plan.sheet(3).pages.map(\.page) == [3, 4])
    }

    @Test func pagesPerSheetCountSidesAndSheets() {
        let four = Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4))
        #expect(SheetPrint.count(four, Self.pages(9), Self.letter, copies: 1, twoSided: false) == (3, 3))
        #expect(SheetPrint.count(four, Self.pages(9), Self.letter, copies: 1, twoSided: true) == (3, 2))
        let sixteen = Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 16))
        #expect(SheetPrint.count(sixteen, Self.pages(16), Self.letter, copies: 1, twoSided: false) == (1, 1))
        #expect(SheetPrint.count(sixteen, [], Self.letter, copies: 1, twoSided: false) == (0, 0))
    }

    /// Mac only (the review): a count that isn't a choice is 2 everywhere, so the sheets still hold every page.
    @Test func aCountThatIsntAChoiceStillPrintsEveryPage() {
        var three = Sheets.PrintSetup(handling: .pagesPerSheet)
        three.pagesPerSheet = 3
        let plan = Sheets.PrintPlan(Array(0..<6), { _ in (612, 792) }, Placement(0, 0, 612, 792), three)
        #expect(plan.sheetCount == 3)
        #expect((0..<plan.sheetCount).flatMap { plan.sheet($0).pages.map(\.page) } == Array(0..<6))
    }

    @Test func aPosterTilesOnePageOverSeveralSheetsWithMarksInsideTheArea() {
        let poster = Self.setup(SheetChoice(.poster, posterPercent: 200))
        let (sides, sheets) = SheetPrint.count(poster, Self.pages(1), Self.letter, copies: 1, twoSided: true)
        #expect(sides == sheets)
        #expect((4...9).contains(sheets)) // a Letter page twice its size, on Letter sheets less the margins, overlapping
        let plan = SheetPrint.plan(Self.pages(1), Self.letter.0, Self.letter.1, poster)
        let area = SheetPrint.area(Self.letter.0, Self.letter.1)
        for i in 0..<plan.sheetCount {
            let sheet = plan.sheet(i)
            #expect(!sheet.marks.isEmpty)
            #expect(sheet.marks.allSatisfy { $0.x1 >= area.x - 0.01 && $0.x2 <= area.right + 0.01 && $0.y1 >= area.y - 0.01 && $0.y2 <= area.bottom + 0.01 })
            #expect(sheet.pages.count == 1 && sheet.pages[0].source != nil)
        }
        let nomarks = Self.setup(SheetChoice(.poster, cutMarks: false))
        #expect(SheetPrint.plan(Self.pages(1), Self.letter.0, Self.letter.1, nomarks).sheet(0).marks.isEmpty)
    }

    @Test func aTurnedSheetsBacksAreDrawnUpsideDown() {
        let booklet = SheetPrint.plan(Self.pages(4), Self.letter.0, Self.letter.1, Self.setup(SheetChoice(.booklet)))
        #expect(!SheetPrint.halfTurned(booklet.sheet(0), 0, twoSided: true))
        #expect(SheetPrint.halfTurned(booklet.sheet(1), 1, twoSided: true))
        #expect(!SheetPrint.halfTurned(booklet.sheet(1), 1, twoSided: false))
        // Four pages on a sheet stay upright: its backs are not turned.
        let four = SheetPrint.plan(Self.pages(8), Self.letter.0, Self.letter.1, Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4)))
        #expect(!SheetPrint.halfTurned(four.sheet(1), 1, twoSided: true))
        // Two portrait pages side by side are on a turned sheet: turned backs.
        let two = SheetPrint.plan(Self.pages(4), Self.letter.0, Self.letter.1, Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 2)))
        #expect(SheetPrint.halfTurned(two.sheet(1), 1, twoSided: true))
    }

    @Test func copiesEachStartOnASheetOfTheirOwn() {
        #expect(SheetPrint.order(3, 2, twoSided: true) == [0, 1, 2, -1, 0, 1, 2])
        #expect(SheetPrint.order(3, 2, twoSided: false) == [0, 1, 2, 0, 1, 2])
        #expect(SheetPrint.order(2, 2, twoSided: true) == [0, 1, 0, 1])
        #expect(SheetPrint.order(0, 5, twoSided: true).isEmpty)
        #expect(SheetPrint.order(2, 100_000, twoSided: false).count == 999 * 2) // copies capped
    }

    @Test func aPosterIsDrawnSharperUpToALimit() {
        #expect(SheetPrint.renderDpi(nil) == 300)
        #expect(SheetPrint.renderDpi(SheetPrint.setup(SheetChoice(.booklet))) == 300)
        #expect(SheetPrint.renderDpi(SheetPrint.setup(SheetChoice(.poster, posterPercent: 150))) == 450)
        #expect(SheetPrint.renderDpi(SheetPrint.setup(SheetChoice(.poster, posterPercent: 400))) == 600)
    }

    @Test func anAbsurdPageSizeCantMakeMillionsOfTiles() {
        let poster = Self.setup(SheetChoice(.poster, posterPercent: 400))
        let huge = [(1e9, 1e9)], broken = [(Double.nan, Double.infinity)]
        let sides = SheetPrint.count(poster, huge, Self.letter, copies: 1, twoSided: false).sides
        #expect((1...20_000).contains(sides)) // counted at 200 in a side
        #expect(SheetPrint.count(poster, broken, Self.letter, copies: 1, twoSided: false).sides == sides)
        #expect(SheetPrint.tooMany(poster, huge, Self.letter, copies: 1))
        #expect(!SheetPrint.tooMany(poster, Self.pages(1), Self.letter, copies: 1))
        let four = Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4))
        #expect(SheetPrint.tooMany(four, Self.pages(40), Self.letter, copies: 101)) // 10 sides × 101
        #expect(!SheetPrint.tooMany(four, Self.pages(40), Self.letter, copies: 100))
    }

    @Test func aPosterOnTinyPaperIsCountedPastTheLimitNeverWrapped() {
        // A 200 in page at 400 % on a sheet about 2 DIPs wide inside its margins: 50,000 tiles a side, 2.5 billion sheets, which
        // an int wraps to a negative count (no sheets, and under every limit).
        let poster = Self.setup(SheetChoice(.poster, posterPercent: 400))
        let page = [(SheetPrint.maxPageSide, SheetPrint.maxPageSide)]
        let tiny = (2 * SheetPrint.margin + 2.048, 2 * SheetPrint.margin + 2.048)
        let plan = SheetPrint.plan(page, tiny.0, tiny.1, poster)
        #expect(plan.sheetCount == Sheets.PrintPlan.maxCounted + 1)
        #expect(SheetPrint.tooMany(poster, page, tiny, copies: 1))
        #expect(plan.sheet(plan.sheetCount - 1).pages.map(\.page) == [0])
        // Many such pages: counting stops at the first; a page after it holds no sheet.
        let many = SheetPrint.plan(Array(repeating: page[0], count: 5000), tiny.0, tiny.1, poster)
        #expect(many.sheetCount == Sheets.PrintPlan.maxCounted + 1)
        #expect(many.sheet(many.sheetCount - 1).pages.map(\.page) == [0])
    }

    @Test func aBookletWithNoWayToPrintBothSidesIsRefused() {
        let booklet = Self.setup(SheetChoice(.booklet))
        let four = Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4))
        let poster = Self.setup(SheetChoice(.poster))
        #expect(SheetPrint.route(booklet, asked: false, printerTwoSided: false, byHand: false) == .noBothSides)
        #expect(SheetPrint.route(booklet, asked: false, printerTwoSided: false, byHand: true) == .byHand)
        #expect(SheetPrint.route(booklet, asked: false, printerTwoSided: true, byHand: true) == .printer)
        #expect(SheetPrint.route(four, asked: false, printerTwoSided: false, byHand: false) == .oneSided)
        #expect(SheetPrint.route(four, asked: true, printerTwoSided: false, byHand: false) == .noBothSides)
        #expect(SheetPrint.route(poster, asked: true, printerTwoSided: true, byHand: true) == .oneSided)
    }

    @Test func anOversizedPageKeepsItsShapeAndThePlanDrawsAtThatSize() {
        let (w, h) = SheetPrint.bounded((400 * 96, 10 * 96)) // a 400 x 10 in banner
        #expect(abs(w - SheetPrint.maxPageSide) < 1e-6)
        #expect(abs(w / h - 40) < 1e-6) // its shape kept, not squashed to 200 x 10
        #expect(SheetPrint.bounded(Self.letter) == (816.0, 1056.0)) // a normal page is left as it is
        // The poster's tiles cover the bounded page exactly: what the print path draws at that same size.
        let poster = Self.setup(SheetChoice(.poster, posterPercent: 150))
        let plan = SheetPrint.plan([(400 * 96, 10 * 96)], Self.letter.0, Self.letter.1, poster)
        let shown = (0..<plan.sheetCount).map { plan.sheet($0).pages[0].source! }
        #expect(abs(shown.map(\.right).max()! - w) < 1e-3)
        #expect(abs(shown.map(\.bottom).max()! - h) < 1e-3)
    }

    @Test func aSideIsNamedByTheFirstDocumentPageOnIt() {
        // Pages 3, 5, 7, 9 and 11 printed four to a sheet: side 1 holds the fifth, page 11.
        let four = SheetPrint.plan(Self.pages(5), Self.letter.0, Self.letter.1, Self.setup(SheetChoice(.pagesPerSheet, pagesPerSheet: 4)))
        let printed = [3, 5, 7, 9, 11]
        #expect(SheetPrint.pageOnSide(four, 0, printed) == 3)
        #expect(SheetPrint.pageOnSide(four, 1, printed) == 11)
        #expect(SheetPrint.pageOnSide(four, 5, printed) == 0)
        // A booklet's first back carries the second page printed.
        let booklet = SheetPrint.plan(Self.pages(4), Self.letter.0, Self.letter.1, Self.setup(SheetChoice(.booklet)))
        #expect(SheetPrint.pageOnSide(booklet, 1, printed) == 5)
    }

    @Test func theAreaKeepsAQuarterInchClear() {
        let a = SheetPrint.area(816, 1056)
        #expect(a == Placement(24, 24, 768, 1008))
        #expect(SheetPrint.area(10, 10).width == 1) // a paper smaller than the margins still has an area
    }
}
