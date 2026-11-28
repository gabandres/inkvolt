import Foundation
import Testing
@testable import PrintCore

/// Copying: the copied page on the paper, 2-up and 4-up sides, the order copies print in, and the ID card layout. Ported from
/// CopyLayoutTests.cs; all 21 tests, none left out. Adapted: the ID card scan settings test reads the scan region with
/// `XmlElement.kid` instead of LINQ to XML's `Descendants`; a pages-per-sheet count other than 1, 2 or 4 throws
/// `CopyLayout.PagesPerSheetError` where .NET throws ArgumentOutOfRangeException; `int.MaxValue` is `Int32.max` (Swift's Int is
/// 64 bits, and the side's first page past it is still worked out without overflowing).
struct CopyLayoutTests {
    // Letter paper and sides in DIPs (96 per inch), like the spooler hands them to the paginator.
    private static let letterW = 816.0, letterH = 1056.0
    private static let cardScan = (w: 4.5 * 96, h: 3 * 96.0)

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 5e-7 }

    @Test func idCardSidesPrintAtActualSizeCentredInEachHalf() {
        let (front, back) = CopyLayout.idCard(Self.letterW, Self.letterH, Self.cardScan, Self.cardScan)

        #expect(front == Placement((816 - 432) / 2.0, (528 - 288) / 2.0, 432, 288))
        #expect(back == Placement((816 - 432) / 2.0, 528 + (528 - 288) / 2.0, 432, 288))
        #expect(front.y + front.height <= Self.letterH / 2)
        #expect(back.y >= Self.letterH / 2)
    }

    @Test func oversizedSidesShrinkTogetherToFitTheirHalfWithMargins() {
        // A whole Letter page scanned by mistake for the back: both sides take its (smaller) scale.
        let (front, back) = CopyLayout.idCard(Self.letterW, Self.letterH, Self.cardScan, (Self.letterW, Self.letterH))

        #expect(back.height <= Self.letterH / 2 - 2 * CopyLayout.idCardMargin + 1e-9)
        #expect(back.y >= Self.letterH / 2 + CopyLayout.idCardMargin - 1e-9)
        let scale = back.height / Self.letterH
        #expect(Self.near(front.width, Self.cardScan.w * scale))
        #expect(Self.near(front.height, Self.cardScan.h * scale))
    }

    @Test func idCardOnA4StaysActualSize() {
        let (front, _) = CopyLayout.idCard(793.7, 1122.5, Self.cardScan, Self.cardScan)

        #expect(front.width == 432 && front.height == 288)
    }

    @Test func copiedPageIsCentredAtActualSizeAndOnlyShrinks() {
        #expect(CopyLayout.page(Self.letterW, Self.letterH, Self.letterW, Self.letterH)
            == PagePlacement(Placement(0, 0, Self.letterW, Self.letterH), false))
        #expect(CopyLayout.page(384, 384, Self.letterW, Self.letterH) == PagePlacement(Placement(216, 336, 384, 384), false)) // small page: not enlarged

        let a4OnLetter = CopyLayout.page(793.7, 1122.5, Self.letterW, Self.letterH).at
        #expect(Self.near(a4OnLetter.height, Self.letterH))
        #expect(Self.near(a4OnLetter.y, 0))
    }

    @Test func landscapeCopyIsTurnedLikeItPrints() {
        // A 6 × 4 in photo on portrait Letter: turned a quarter (as the print path does), not shrunk.
        let p = CopyLayout.page(576, 384, Self.letterW, Self.letterH)

        #expect(p.rotated)
        #expect(p.at == Placement((Self.letterW - 384) / 2, (Self.letterH - 576) / 2, 384, 576))
    }

    @Test func scannedSizeInInchesFromPixelsAndDpi() {
        #expect(CopyLayout.inches(2550, 3300, 300) == (8.5, 11))
        #expect(CopyLayout.inches(675, 450, 150) == (4.5, 3))
        #expect(CopyLayout.inches(100, 100, 0) == (0, 0))
    }

    @Test func idCardScanIsTheGlassCornerAndFitsTheM234dwPlaten() throws {
        let caps = ScannerCapabilities.parse(try DeviceXml.load(Fixtures.data("m234dw/eSCL_ScannerCapabilities.xml")))
        let request = CopyLayout.idCardRequest(.grayscale, 300)

        let settings = try DeviceXml.load(try #require(EsclXml.buildScanSettings(request, caps)))
        let region = try #require(settings.kid("ScanRegions")?.kid("ScanRegion"))

        #expect(request.source == .platen)
        #expect(region.kidValue("Width") == "1350")
        #expect(region.kidValue("Height") == "900")
        #expect(region.kidValue("XOffset") == "0")
        #expect(settings.kidValue("ColorMode") == "Grayscale8")
    }

    // ------------------------------------------------------------------ 2-up, 4-up, collation

    private static let letterPage = (w: letterW, h: letterH)

    @Test func pagesAreGroupedBySideInReadingOrder() throws {
        #expect(try CopyLayout.sides(5, 2) == [[0, 1], [2, 3], [4]])
        #expect(try CopyLayout.sides(5, 4) == [[0, 1, 2, 3], [4]])
        #expect(try CopyLayout.sides(2, 1) == [[0], [1]])
        #expect(try CopyLayout.sides(0, 4).isEmpty)
    }

    @Test(arguments: [0, 3, -2, Int(Int32.max)])
    func onlyOneTwoOrFourPagesPerSheet(_ perSheet: Int) {
        #expect(throws: CopyLayout.PagesPerSheetError(pagesPerSheet: perSheet)) { try CopyLayout.sides(3, perSheet) }
        #expect(throws: CopyLayout.PagesPerSheetError(pagesPerSheet: perSheet)) {
            try CopyLayout.nUp([Self.letterPage], perSheet, Self.letterW, Self.letterH)
        }
    }

    @Test func twoUpOnPortraitPaperTurnsThePagesAndStacksThemFirstOnTop() throws {
        let placed = try CopyLayout.nUp([Self.letterPage, Self.letterPage], 2, Self.letterW, Self.letterH)

        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.rotated }) // portrait pages in landscape cells: the sheet reads turned
        let (top, bottom) = (placed[0].at, placed[1].at)
        #expect(top.y + top.height <= bottom.y + 1e-9)
        #expect(Self.near(top.width, bottom.width))
        #expect(Self.near(Self.letterW / Self.letterH, top.height / top.width)) // turned, proportions kept
        Self.expectInside(placed, Self.letterW, Self.letterH)
    }

    @Test func twoUpOnLandscapePaperPutsThemSideBySideUnturned() throws {
        let placed = try CopyLayout.nUp([Self.letterPage, Self.letterPage], 2, Self.letterH, Self.letterW)

        #expect(placed.allSatisfy { !$0.rotated })
        #expect(placed[0].at.x + placed[0].at.width <= placed[1].at.x + 1e-9)
        #expect(Self.near(placed[0].at.y, placed[1].at.y))
        Self.expectInside(placed, Self.letterH, Self.letterW)
    }

    @Test func fourUpGoesLeftToRightThenTopToBottom() throws {
        let placed = try CopyLayout.nUp([Self.letterPage, Self.letterPage, Self.letterPage, Self.letterPage], 4, Self.letterW, Self.letterH)

        #expect(placed.allSatisfy { !$0.rotated })
        let at = placed.map(\.at)
        #expect(at[0].x < at[1].x && at[0].y == at[1].y)
        #expect(at[2].x == at[0].x && at[2].y > at[0].y)
        #expect(at[3].x == at[1].x && at[3].y == at[2].y)
        #expect(at[0].y + at[0].height <= at[2].y + 1e-9 && at[0].x + at[0].width <= at[1].x + 1e-9) // no overlap
        Self.expectInside(placed, Self.letterW, Self.letterH)
    }

    @Test func fourUpTurnsLandscapePagesAndLeavesShortSidesEmpty() throws {
        let landscape = (w: Self.letterH, h: Self.letterW)
        let placed = try CopyLayout.nUp([landscape, landscape, landscape], 4, Self.letterW, Self.letterH)

        #expect(placed.count == 3)
        #expect(placed.allSatisfy { $0.rotated })
    }

    @Test func onePagePerSheetIsThePlainCopy() throws {
        let placed = try CopyLayout.nUp([(400, 300)], 1, Self.letterW, Self.letterH, .fitToPaper)
        #expect(placed == [CopyLayout.page(400, 300, Self.letterW, Self.letterH, .fitToPaper)])
    }

    @Test func aPageWithNoSizeLandsSomewhereFinite() throws {
        let placed = try CopyLayout.nUp([(0, 0), (-5, Double.leastNonzeroMagnitude), Self.letterPage], 4, Self.letterW, Self.letterH)

        #expect(placed.allSatisfy { $0.at.x.isFinite && $0.at.y.isFinite && $0.at.width.isFinite && $0.at.height.isFinite })
        #expect(try CopyLayout.nUp([], 2, Self.letterW, Self.letterH).isEmpty)
    }

    private static func expectInside(_ placed: [PagePlacement], _ paperW: Double, _ paperH: Double) {
        for p in placed {
            let at = p.at
            #expect(at.x >= CopyLayout.nUpMargin - 1e-9 && at.y >= CopyLayout.nUpMargin - 1e-9, "\(at)")
            #expect(at.x + at.width <= paperW - CopyLayout.nUpMargin + 1e-9 && at.y + at.height <= paperH - CopyLayout.nUpMargin + 1e-9, "\(at)")
        }
    }

    @Test func collatedCopiesPrintEachSideOnceAndLeaveTheCopiesToTheQueue() {
        #expect(Self.order(3, 2, collate: true, twoSided: false) == ("0 1 2", 2))
        #expect(Self.order(4, 2, collate: true, twoSided: true) == ("0 1 2 3", 2)) // even: each copy ends on a full sheet
        #expect(Self.order(2, 1, collate: false, twoSided: true) == ("0 1", 1)) // one copy: nothing to collate
        #expect(Self.order(3, 1, collate: true, twoSided: true) == ("0 1 2", 1)) // one copy: its last back is blank anyway
    }

    @Test func collatedTwoSidedCopiesOfAnOddCountEachEndOnABlankBack() throws {
        // Left to the queue's copy count, copy 2 would start on copy 1's last back: made here instead, one copy on the ticket.
        #expect(Self.order(3, 3, collate: true, twoSided: true) == ("0 1 2 -1 0 1 2 -1 0 1 2 -1", 1))
        #expect(Self.order(1, 2, collate: true, twoSided: true) == ("0 -1 0 -1", 1))
        #expect(try CopyLayout.sheets(5, 2, 3, twoSided: true) == 6) // 3 sides: 2 sheets a copy, as the order prints them
    }

    @Test(arguments: [
        (5, 2, 0, "0 1"),
        (5, 2, 2, "4"),
        (5, 2, 3, ""),
        (5, 4, -1, ""),
        (Int(Int32.max), 4, Int(Int32.max), ""),
    ])
    func aSideHoldsItsPagesAndASidePastTheEndNone(_ pages: Int, _ perSheet: Int, _ side: Int, _ expected: String) throws {
        #expect(try CopyLayout.pagesOnSide(pages, perSheet, side).map(String.init).joined(separator: " ") == expected)
    }

    @Test func uncollatedCopiesRepeatEachSheetWithOneCopyOnTheTicket() {
        #expect(Self.order(3, 2, collate: false, twoSided: false) == ("0 0 1 1 2 2", 1))
        // Two-sided: a sheet is a side and its back; the odd last side gets a blank back so each copy is its own sheet.
        #expect(Self.order(3, 2, collate: false, twoSided: true) == ("0 1 0 1 2 -1 2 -1", 1))
    }

    @Test func oddCountsAreHarmless() {
        #expect(Self.order(0, 5, collate: false, twoSided: true) == ("", 5))
        #expect(Self.order(1, 0, collate: false, twoSided: false) == ("0", 1))
        #expect(Self.order(1, -7, collate: true, twoSided: false) == ("0", 1))
    }

    /// The order as text ("0 1 -1"), so a tuple compares by value.
    private static func order(_ sides: Int, _ copies: Int, collate: Bool, twoSided: Bool) -> (String, Int) {
        let (order, ticket) = CopyLayout.order(sides, copies, collate: collate, twoSided: twoSided)
        return (order.map(String.init).joined(separator: " "), ticket)
    }

    @Test(arguments: [
        (5, 1, 1, false, 5),
        (5, 2, 1, false, 3),
        (5, 2, 3, true, 6), // 3 sides, 2 sheets two-sided, 3 copies
        (9, 4, 2, true, 4), // 3 sides, 2 sheets two-sided, 2 copies
        (0, 4, 3, false, 0),
    ])
    func sheetsCountSidesPaperAndCopies(_ pages: Int, _ perSheet: Int, _ copies: Int, _ twoSided: Bool, _ expected: Int) throws {
        #expect(try CopyLayout.sheets(pages, perSheet, copies, twoSided: twoSided) == expected)
    }
}
