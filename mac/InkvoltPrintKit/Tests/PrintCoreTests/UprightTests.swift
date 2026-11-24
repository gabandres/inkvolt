import Foundation
import Testing
import TestTiming
@testable import PrintCore

/// Ported from UprightTests.cs: which way up a straightened page of text is (`Upright`, shared with Inkvolt PDF's Recognize
/// Text and Compare): more ink rises above a line's middle than hangs below it, and pages turned upright on their own in the
/// scan review (roadmap 4.3, `PageUpright`). A synthetic page at 100 dpi (850 × 1100). Adapted: `UprightFound` and
/// `PageEdits.checked` are Swift values (nil for "nothing changes"); the language is read with Foundation's `Locale.Language`
/// where Windows asks CultureInfo. Mac only: theReviewTurnsAPageUprightAndUndoTurnsItBack (`ScanPages`, the Windows view
/// model's `RecordUpright`).
@Suite(.offThePool)
struct UprightTests {
    private static let w = 850, h = 1100

    private static func paper() -> [UInt8] { [UInt8](repeating: 245, count: w * h) }

    /// A line of "text" from `top`, 15 rows: a dense middle band 8 rows tall, ascenders (4 rows, a third inked) above it and
    /// descenders (3 rows, an eighth inked) below.
    private static func text(_ px: inout [UInt8], _ top: Int, _ x0: Int = 100, _ x1: Int = 750) {
        for x in x0..<x1 {
            for y in top..<(top + 4) where x % 3 == 0 { px[y * w + x] = 20 }
            for y in (top + 4)..<(top + 12) where x % 7 != 6 { px[y * w + x] = 20 }
            for y in (top + 12)..<(top + 15) where x % 8 == 0 { px[y * w + x] = 20 }
        }
    }

    /// A shaded picture from `top`, 300 rows: dark all across at its top, less and less of it to its foot.
    private static func picture(_ px: inout [UInt8], _ top: Int) {
        for y in top..<(top + 300) {
            for x in 100..<(100 + 650 * (top + 300 - y) / 300) { px[y * w + x] = 20 }
        }
    }

    /// `lines` lines of text 26 rows apart from row 80; a picture from `pictureTop`.
    private static func page(_ lines: Int, pictureTop: Int? = nil) -> GrayImage {
        var px = paper()
        for l in 0..<lines { text(&px, 80 + l * 26) }
        if let p = pictureTop { picture(&px, p) }
        return GrayImage(w, h, px)
    }

    private static func upsideDown(_ g: GrayImage) -> GrayImage { GrayImage(g.width, g.height, g.pixels.reversed()) }

    private static func readsUpright(_ page: GrayImage) {
        #expect(Upright.upsideDown(page) == (false, true))
        #expect(Upright.upsideDown(upsideDown(page)) == (true, true))
    }

    @Test func aPageOfTextReadsWhichWayUpItIs() { Self.readsUpright(Self.page(30)) }

    // ---- PageUpright: the scan review's turn (roadmap 4.3) ----

    @Test(arguments: [0, 1, 2, 3])
    func aPageFedAnyWayRoundIsTurnedUpright(_ fedTurns: Int) {
        let page = Self.page(30)
        let fed = GrayImage(fedTurns % 2 == 0 ? Self.w : Self.h, fedTurns % 2 == 0 ? Self.h : Self.w,
                            ScanCleanup.turn(page.pixels, Self.w, Self.h, 1, fedTurns))
        let found = PageUpright.find(fed, 100)
        #expect(found.sure)
        #expect(found.turns == (4 - fedTurns) % 4)
    }

    @Test func aPageItIsntSureOfIsntTurned() {
        // Blank paper, a picture alone, lines with as much ink above as below (bars): no turn.
        #expect(PageUpright.find(GrayImage(Self.w, Self.h, Self.paper()), 100).turns == 0)
        var picture = Self.paper()
        Self.picture(&picture, 300)
        #expect(!PageUpright.find(GrayImage(Self.w, Self.h, picture), 100).sure)
        var bars = Self.paper()
        for l in 0..<30 {
            for y in (80 + l * 26)..<(92 + l * 26) {
                for x in 100..<750 { bars[y * Self.w + x] = 20 }
            }
        }
        #expect(PageUpright.find(GrayImage(Self.w, Self.h, bars), 100).turns == 0)
        #expect(PageUpright.find(GrayImage(10, 10, [UInt8](repeating: 0, count: 100)), 100) == .unsure)
        #expect(PageUpright.find(Self.page(30), .nan) == .unsure)
    }

    @Test func aCopyFinerThan150DpiIsReadAtAbout100() {
        // The same page at 300 dpi (each pixel 3 × 3): read as at 100.
        let page = Self.upsideDown(Self.page(30))
        var big = [UInt8](repeating: 0, count: Self.w * 3 * Self.h * 3)
        for y in 0..<(Self.h * 3) {
            for x in 0..<(Self.w * 3) { big[y * Self.w * 3 + x] = page.pixels[y / 3 * Self.w + x / 3] }
        }
        #expect(PageUpright.find(GrayImage(Self.w * 3, Self.h * 3, big), 300).turns == 2)
    }

    @Test(arguments: [
        (nil, true), ("", true), ("en-US", true), ("es", true), ("ru-RU", true), ("el", true), ("he-IL", false), ("ar", false),
        ("fa-IR", false), ("zh-Hans-CN", false), ("ja", false), ("hi-IN", false), ("not a tag!", true),
    ] as [(String?, Bool)])
    func onlyScriptsWhoseLettersRiseAboveTheLineAreTurned(_ language: String?, _ suits: Bool) {
        #expect(PageUpright.suitsLanguage(language) == suits)
    }

    @Test func theReviewsCheckTurnsAndStraightensOnlyWhatItMay() {
        // Fed a quarter turn: turned back three quarters; a page the check may not straighten (blank, a separator, photos)
        // or one with no text to read is neither turned nor straightened.
        let page = Self.page(30)
        let sideways = GrayImage(Self.h, Self.w, ScanCleanup.turn(page.pixels, Self.w, Self.h, 1, 1))
        #expect(PageUpright.orient(sideways, 100, straighten: true, upright: true, mayStraighten: true, hasText: true) == (0.0, 3))
        #expect(PageUpright.orient(sideways, 100, straighten: true, upright: false, mayStraighten: true, hasText: true).quarterTurns == 0)
        #expect(PageUpright.orient(sideways, 100, straighten: true, upright: true, mayStraighten: false, hasText: false) == (0.0, 0))
        #expect(PageUpright.orient(sideways, 100, straighten: true, upright: true, mayStraighten: true, hasText: false) == (0.0, 0))

        // Straightened by its lines' skew as they run: the sideways page 3° crooked.
        let crooked = GrayImage(Self.h, Self.w, PageRotate.rotate(sideways.pixels, Self.h, Self.w, Self.h, 1, 3))
        let (angle, turns) = PageUpright.orient(crooked, 100, straighten: true, upright: true, mayStraighten: true, hasText: true)
        #expect(turns == 3)
        #expect(abs(angle - 3) <= 0.5)
        #expect(PageUpright.orient(crooked, 100, straighten: false, upright: true, mayStraighten: true, hasText: true).deskew == 0)
    }

    @Test func onlyAPageNobodyEditedTakesTheChecksTurnAndItReadsAsTurnedUntilTurnedBack() {
        #expect(PageEdits.none.checked(1.5, 2) == PageEdits(quarterTurns: 2, deskew: 1.5))
        #expect(PageEdits.none.checked(0, 0) == nil)
        #expect(PageEdits.none.checked(0, 4) == nil)
        #expect(PageEdits.none.turned(1).checked(1.5, 2) == nil) // turned by hand during the check
        let turned = PageEdits.none.checked(0, 3)!
        #expect(turned.turnedUprightBy(3))
        #expect(!turned.turned(1).turnedUprightBy(3))
        #expect(!PageEdits.none.turnedUprightBy(0))
    }

    @Test(arguments: [(0.2, 0.0), (-3.5, -3.5), (12, 0), (.nan, 0)] as [(Double, Double)])
    func aSidewaysPageIsStraightenedWithinTheReviewsLimits(_ skew: Double, _ expected: Double) {
        #expect(PageUpright.straightenBy(skew) == expected)
    }

    @Test func aShadedPictureDoesntTurnAPageOfTextOver() {
        // Ten lines of text above a picture whose shading ends in paper at its foot: as a "line", nearly all of it lies
        // below its darkest rows and outweighed the text.
        Self.readsUpright(Self.page(10, pictureTop: 500))
    }

    @Test func aPictureAndItsOneLineCaption() {
        // Two runs, the picture's 300 rows and the caption's 15: the lines' height is the caption's, not the picture's.
        var px = Self.paper()
        Self.picture(&px, 400)
        Self.text(&px, 720)
        Self.readsUpright(GrayImage(Self.w, Self.h, px))
    }

    @Test func aFormWhoseRulesOutnumberItsLines() {
        // Rules 4 rows thick between and below the lines: too short to be text, they don't set the lines' height.
        var px = Self.paper()
        for l in 0..<8 { Self.text(&px, 80 + l * 26) }
        for r in 0..<14 {
            for y in (99 + r * 26)..<(103 + r * 26) {
                for x in 100..<750 { px[y * Self.w + x] = 20 }
            }
        }
        Self.readsUpright(GrayImage(Self.w, Self.h, px))
    }

    @Test func aWidePictureAndANarrowColumnOfText() {
        // The picture's rows set how faint ink may be to count; a column 40 px wide has ascenders and descenders fainter
        // than that, read once the picture is left out.
        var px = Self.paper()
        for y in 80..<280 {
            for x in 60..<790 { px[y * Self.w + x] = 20 }
        }
        for l in 0..<12 { Self.text(&px, 400 + l * 26, 100, 140) }
        Self.readsUpright(GrayImage(Self.w, Self.h, px))
    }

    @Test func tightParagraphsBesideOneLineItemsAreLines() {
        // Eight lines set with no white between are one run of 120 rows; three items apart. The run is cut into its lines
        // and counts, not left out as a picture.
        var px = Self.paper()
        for l in 0..<8 { Self.text(&px, 80 + l * 15) }
        var items = Self.paper()
        for top in [400, 426, 452] {
            Self.text(&px, top)
            Self.text(&items, top)
        }
        let page = GrayImage(Self.w, Self.h, px)
        Self.readsUpright(page)
        let above = Upright.aboveBelow(page).above
        let itemsAbove = Upright.aboveBelow(GrayImage(Self.w, Self.h, items)).above
        #expect(above > 3 * itemsAbove, "\(above) / \(itemsAbove)")
    }

    @Test func aHeadingTwiceTheBodysHeightIsStillALine() {
        // The heading's own rows count: its ascenders are what say which way is up here, with only two body lines.
        var px = Self.page(2).pixels
        for x in 100..<750 {
            for y in 20..<28 where x % 3 == 0 { px[y * Self.w + x] = 20 }
            for y in 28..<44 where x % 7 != 6 { px[y * Self.w + x] = 20 }
            for y in 44..<50 where x % 8 == 0 { px[y * Self.w + x] = 20 }
        }
        let (above, below) = Upright.aboveBelow(GrayImage(Self.w, Self.h, px))
        let (bodyAbove, bodyBelow) = Upright.aboveBelow(Self.page(2))
        #expect(above > bodyAbove && below > bodyBelow, "\(above) \(below) / \(bodyAbove) \(bodyBelow)")
    }

    // ---- In the review (Mac only) ----

    @Test func theReviewTurnsAPageUprightAndUndoTurnsItBack() {
        var pages = ScanPages([ScannedPage(id: "a", dpi: 300), ScannedPage(id: "b", dpi: 300), ScannedPage(id: "c", dpi: 300)])
        pages.analysed("a", looksBlank: false, skew: 1.5, skipBlank: true, straighten: true, quarterTurns: 2)
        pages.analysed("b", looksBlank: false, skew: 0, skipBlank: true, straighten: true, quarterTurns: 3)
        pages.analysed("c", looksBlank: true, skew: 0, skipBlank: true, straighten: true, quarterTurns: 1) // blank: left alone
        #expect(pages.page("a")?.edits == PageEdits(quarterTurns: 2, deskew: 1.5))
        #expect(pages.page("a")?.note == "Turned upright" && pages.page("b")?.turnedUpright == true)
        #expect(pages.page("c")?.edits == PageEdits.none && pages.page("c")?.uprightTurns == 0)
        pages.turn("b", 1) // turned on by hand: no longer as the check left it
        #expect(pages.undoUpright(["a", "b", "c"]) == ["a"])
        #expect(pages.page("a")?.edits == PageEdits(deskew: 1.5) && pages.page("a")?.note == "Straightened")
        #expect(pages.page("b")?.edits.quarterTurns == 0) // 3 + 1: a whole turn, by hand
    }

    @Test func presetsTurnPagesUprightUnlessTurnedOffAndOldOnesDoToo() throws {
        let json = #"{"Version":1,"Items":[{"Id":"abc","Name":"Old"},{"Id":"def","Name":"Off","TurnUpright":false}]}"#
        let list = ScanPresets.normalize(try JSONDecoder().decode(ScanPresetSettings.self, from: Data(json.utf8)))
        #expect(list.map(\.turnUpright) == [true, false])
        #expect(String(decoding: try JSONEncoder().encode(ScanPresetSettings(items: [list[1]])), as: UTF8.self).contains(#""TurnUpright":false"#))
    }
}
