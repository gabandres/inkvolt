import Foundation
import Testing
@testable import PdfCore

/// Ported from PrintLayoutTests.cs: all 13 tests (with their cases), none left out or adapted.
struct PrintLayoutTests {
    // Letter paper in device-independent pixels, quarter-inch margins.
    private static let letter = RectD(24, 24, 768, 1008)
    private static let portrait: @Sendable (Int) -> (Double, Double) = { _ in (816, 1056) }

    private func near(_ a: Double, _ b: Double, _ places: Int = 3) -> Bool { abs(a - b) < 0.5 * pow(10, -Double(places)) }

    @Test(arguments: [(1, 1), (4, 1), (5, 2), (8, 2), (9, 3), (17, 5)])
    func bookletsUseSheetsOfFourPages(pages: Int, sheets: Int) { #expect(PrintLayout.bookletSheets(pages) == sheets) }

    @Test func bookletOfEightPages() {
        func pairs(_ s: [(left: Int, right: Int)]) -> [[Int]] { s.map { [$0.left, $0.right] } }
        // Sheet 1: 8|1 on the front, 2|7 on the back; sheet 2: 6|3, then 4|5 (0-based below).
        #expect(pairs(PrintLayout.bookletSides(8)) == [[7, 0], [1, 6], [5, 2], [3, 4]])
        // Bound on the right: each side mirrored.
        #expect(pairs(PrintLayout.bookletSides(8, rightBinding: true)) == [[0, 7], [6, 1], [2, 5], [4, 3]])
        // Padded with blank pages at the end: 5 pages make 8, the back cover side is blank.
        #expect(pairs(PrintLayout.bookletSides(5)) == [[-1, 0], [1, -1], [-1, 2], [3, 4]])
        #expect(pairs(PrintLayout.bookletSides(1)) == [[-1, 0], [-1, -1]])
    }

    @Test(arguments: 1...17)
    func foldedBookletsReadInOrder(pages: Int) {
        let sides = PrintLayout.bookletSides(pages)
        let sheets = sides.count / 2
        #expect(PrintLayout.bookletSheets(pages) * 2 == sides.count)
        // Nest the folded sheets (sheet 1 outside) and read: front-right, back-left, …, then back on the way out.
        var read: [Int] = []
        for s in 0..<sheets { read += [sides[2 * s].right, sides[2 * s + 1].left] }
        for s in stride(from: sheets - 1, through: 0, by: -1) { read += [sides[2 * s + 1].right, sides[2 * s].left] }
        let expected: [Int] = (0..<(sheets * 4)).map { (i: Int) -> Int in i < pages ? i : -1 }
        #expect(read == expected)
        // Every page exactly once.
        let printed: [Int] = sides.flatMap { (s: (left: Int, right: Int)) -> [Int] in [s.left, s.right] }.filter { $0 >= 0 }.sorted()
        #expect(printed == Array(0..<pages))
    }

    @Test func bookletPagesSitAgainstTheFold() throws {
        let side = PrintLayout.bookletSide(7, 0, Self.portrait, Self.letter)
        // Portrait paper: the sheet is used turned, so the "left" page is on the top half, turned a quarter.
        let left = try #require(side.pages.first { $0.page == 7 })
        let right = try #require(side.pages.first { $0.page == 0 })
        #expect(side.pages.allSatisfy { $0.turns == 1 })
        #expect(near(left.box.bottom, Self.letter.y + Self.letter.height / 2))
        #expect(near(right.box.y, Self.letter.y + Self.letter.height / 2))
        // Half the sheet each, proportions kept (turned: box width is the page's height).
        #expect(near(left.box.height / left.box.width, 816.0 / 1056))
        #expect(left.box.height <= Self.letter.height / 2 + 0.001 && left.box.width <= Self.letter.width + 0.001)
        // A blank half has nothing on it.
        #expect(PrintLayout.bookletSide(-1, 0, Self.portrait, Self.letter).pages.count == 1)
    }

    @Test(arguments: [(2, 2, 1, true), (4, 2, 2, false), (6, 3, 2, true), (9, 3, 3, false), (16, 4, 4, false)])
    func pagesPerSheetGrids(n: Int, cols: Int, rows: Int, turned: Bool) {
        let g = PrintLayout.grid(n, 816, 1056, Self.letter.width, Self.letter.height)
        #expect(g.cols == cols && g.rows == rows && g.turned == turned)
    }

    @Test func landscapePagesTwoUpStackOnPortraitPaper() {
        let g = PrintLayout.grid(2, 1056, 816, Self.letter.width, Self.letter.height)
        #expect(g.cols == 1 && g.rows == 2 && !g.turned)
    }

    @Test func pagesFillTheirCellsInOrder() {
        let nine = Array(0..<9)
        let across = PrintLayout.pagesPerSheet(nine, Self.portrait, 9, .across, true, Self.letter)
        #expect(across.borders)
        #expect(across.pages.count == 9)
        #expect(across.pages.allSatisfy { $0.turns == 0 })
        // Across: 0 1 2 / 3 4 5 / 6 7 8; down: 0 3 6 / 1 4 7 / 2 5 8.
        #expect(across.pages[1].box.x > across.pages[0].box.x && abs(across.pages[1].box.y - across.pages[0].box.y) < 0.01)
        #expect(across.pages[3].box.y > across.pages[0].box.y && abs(across.pages[3].box.x - across.pages[0].box.x) < 0.01)
        let down = PrintLayout.pagesPerSheet(nine, Self.portrait, 9, .down, false, Self.letter)
        #expect(across.pages[3].box == down.pages[1].box)
        #expect(across.pages[1].box == down.pages[3].box)
        // A sheet with fewer pages than cells fills the first ones.
        #expect(across.pages[1].box == PrintLayout.pagesPerSheet([0, 1], Self.portrait, 9, .across, false, Self.letter).pages[1].box)
        // Inside the printable area, proportions kept, none overlapping.
        for p in across.pages {
            #expect(p.box.x >= Self.letter.x && p.box.right <= Self.letter.right && p.box.y >= Self.letter.y && p.box.bottom <= Self.letter.bottom)
            #expect(near(p.box.width / p.box.height, 816.0 / 1056))
        }
        for i in 0..<across.pages.count {
            for j in (i + 1)..<across.pages.count { #expect(across.pages[i].box.intersect(across.pages[j].box).isEmpty) }
        }
    }

    @Test func twoUpTurnsThePages() {
        let sheet = PrintLayout.pagesPerSheet([0, 1], Self.portrait, 2, .across, false, Self.letter)
        #expect(sheet.pages.allSatisfy { $0.turns == 1 })
        // The turned sheet's left page lands on the top half of the paper.
        #expect(sheet.pages[0].box.bottom <= sheet.pages[1].box.y + 0.01)
        #expect(near(sheet.pages[0].box.width / sheet.pages[0].box.height, 1056.0 / 816))
    }

    @Test func planCountsSheets() {
        let pages = Array(0..<11)
        #expect(PrintPlan(pages, Self.portrait, Self.letter, PrintSetup()).sheetCount == 11)
        let fourUp = PrintSetup(handling: .pagesPerSheet, pagesPerSheet: 4)
        #expect(PrintPlan(pages, Self.portrait, Self.letter, fourUp).sheetCount == 3)
        let booklet = PrintPlan(pages, Self.portrait, Self.letter, PrintSetup(handling: .booklet))
        #expect(booklet.sheetCount == 6 && booklet.paperCount == 3)
        // The last pages-per-sheet sheet holds what's left.
        #expect(PrintPlan(pages, Self.portrait, Self.letter, fourUp).sheet(2).pages.map(\.page) == [8, 9, 10])
        // Page numbers come from the list printed, not its positions.
        let picked = PrintPlan([4, 9], Self.portrait, Self.letter, PrintSetup(handling: .booklet))
        #expect(picked.sheet(0).pages.map(\.page) == [4])
        #expect(picked.sheet(1).pages.map(\.page) == [9])
    }

    @Test func fitShrinksOrEnlargesOnRequest() {
        // A 4 × 6 in page (384 × 576 DIP): actual size stays, fit to paper fills the height.
        let actual = PrintLayout.single(0, 384, 576, Self.letter, .actualSize)
        #expect(actual.box.width == 384 && actual.box.height == 576)
        #expect(near(actual.box.centerX, Self.letter.centerX))
        let fit = PrintLayout.single(0, 384, 576, Self.letter, .fitToPaper)
        #expect(near(fit.box.height, Self.letter.height))
        // Oversized pages shrink either way; landscape pages turn onto portrait paper.
        #expect(near(PrintLayout.single(0, 1632, 2112, Self.letter, .actualSize).box.width, Self.letter.width))
        #expect(PrintLayout.single(0, 1056, 816, Self.letter, .actualSize).turns == 1)
    }

    @Test(arguments: [
        (2.0, 0.0, 2, 3, true), // 200 % of Letter: 6 turned sheets rather than 9 upright (the margins)
        (1.0, 0.0, 1, 2, true), // the margins make even 100 % a little too big for one sheet
        (0.9, 0.0, 1, 1, false),
        (3.0, 48.0, 3, 5, true),
        (2.5, 36.0, 3, 3, false),
    ])
    func posterTiling(scale: Double, overlap: Double, cols: Int, rows: Int, turned: Bool) {
        let t = PrintLayout.posterTiles(816, 1056, scale, Self.letter.width, Self.letter.height, overlap)
        #expect(t.cols == cols && t.rows == rows && t.turned == turned)
    }

    @Test func posterTilesCoverThePageOnce() throws {
        let setup = PrintSetup(handling: .poster, posterScale: 2.5, overlap: 36, cutMarks: true)
        let plan = PrintPlan([0], Self.portrait, Self.letter, setup)
        let t = PrintLayout.posterTiles(816, 1056, 2.5, Self.letter.width, Self.letter.height, 36)
        #expect(t.cols * t.rows == plan.sheetCount)
        // The sources tile the page, overlapping only by the overlap (in page units: 36 / 2.5).
        let sources = try (0..<plan.sheetCount).map { try #require(plan.sheet($0).pages.first?.source) }
        #expect(near(sources.map(\.x).min()!, 0))
        #expect(near(sources.map(\.y).min()!, 0))
        #expect(near(sources.map(\.right).max()!, 816))
        #expect(near(sources.map(\.bottom).max()!, 1056))
        #expect(near(sources[0].right - sources[1].x, 36 / 2.5))
        // Placed at 250 %; inner edges get cut marks, outer ones don't.
        let sheet = plan.sheet(0)
        #expect(near(sheet.pages[0].box.width, sources[0].width * 2.5))
        #expect(sheet.marks.count == 4) // right and bottom edges of the top-left sheet, two ticks each
        #expect(sheet.marks.allSatisfy { $0.x1 >= Self.letter.x - 0.01 && $0.x2 <= Self.letter.right + 0.01 && $0.y2 <= Self.letter.bottom + 0.01 })
        var noMarks = setup
        noMarks.cutMarks = false
        #expect(PrintPlan([0], Self.portrait, Self.letter, noMarks).sheet(0).marks.isEmpty)
    }

    @Test func posterTurnsSheetsWhenThatSavesPaper() {
        // A tall banner page (1:3) at 100 %: 4 turned sheets rather than 6 upright.
        let t = PrintLayout.posterTiles(800, 2400, 1, Self.letter.width, Self.letter.height, 0)
        #expect(t.cols == 1 && t.rows == 4 && t.turned)
        let tile = PrintLayout.posterTile(0, 800, 2400, 0, PrintSetup(handling: .poster, posterScale: 1), Self.letter)
        #expect(tile.pages.first?.turns == 1)
    }
}
