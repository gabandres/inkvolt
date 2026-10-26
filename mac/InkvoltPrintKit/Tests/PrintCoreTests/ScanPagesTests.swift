import Foundation
import Testing
@testable import PrintCore

/// The scan review's page list: the page check skipping and straightening, the user's edits, the order, what's saved, and
/// crash recovery. New for the Mac (the Windows app keeps the list in `ScanViewModel`, without tests of its own).
struct ScanPagesTests {
    private static func pages(_ n: Int) -> ScanPages {
        var p = ScanPages()
        for i in 1...n { p.add(ScannedPage(id: "p\(i).jpg", dpi: 300)) }
        return p
    }

    @Test func aBlankPageIsSkippedAndACrookedOneStraightenedWhenTheyreOn() throws {
        var p = Self.pages(3)
        p.analysed("p1.jpg", looksBlank: false, skew: 1.5, skipBlank: true, straighten: true)
        p.analysed("p2.jpg", looksBlank: true, skew: 2, skipBlank: true, straighten: true)
        p.analysed("p3.jpg", looksBlank: true, skew: 0, skipBlank: false, straighten: true)
        #expect(try #require(p.page("p1.jpg")).edits == PageEdits(deskew: 1.5))
        #expect(try #require(p.page("p1.jpg")).note == "Straightened")
        #expect(try #require(p.page("p2.jpg")).skipped)
        #expect(try #require(p.page("p2.jpg")).edits.isEmpty) // a blank page isn't straightened
        #expect(try #require(p.page("p2.jpg")).note == "Blank, not saved")
        #expect(!(try #require(p.page("p3.jpg")).skipped)) // Skip blank pages off: kept
        #expect(p.toSave.map(\.id) == ["p1.jpg", "p3.jpg"])
        #expect(p.summary == "3 pages, 1 not saved")
    }

    @Test func aPageEditedBeforeItsCheckIsntStraightenedOverTheEdit() throws {
        var p = Self.pages(1)
        p.turn("p1.jpg", 1)
        p.analysed("p1.jpg", looksBlank: false, skew: 3, skipBlank: true, straighten: true)
        #expect(try #require(p.page("p1.jpg")).edits == PageEdits(quarterTurns: 1))
        #expect(try #require(p.page("p1.jpg")).note == "Edited")
    }

    @Test func turnsCropsAndResetsAreThePagesEdits() throws {
        var p = Self.pages(1)
        p.turn("p1.jpg", -1)
        #expect(try #require(p.page("p1.jpg")).edits.quarterTurns == 3)
        p.crop("p1.jpg", shown: CropBox(0.1, 0.1, 0.5, 0.5))
        let shown = try #require(p.page("p1.jpg")).edits.shownCrop // through a turn and back: equal but for rounding
        #expect([shown.x, shown.y, shown.width, shown.height].map { ($0 * 1e9).rounded() / 1e9 } == [0.1, 0.1, 0.5, 0.5])
        p.crop("p1.jpg", shown: .full)
        #expect(try #require(p.page("p1.jpg")).edits.crop == nil)
        p.reset("p1.jpg")
        #expect(try #require(p.page("p1.jpg")).edits.isEmpty)
    }

    @Test func pagesAreReorderedDeletedKeptAndSkipped() {
        var p = Self.pages(4)
        p.move("p4.jpg", to: 0)
        #expect(p.pages.map(\.id) == ["p4.jpg", "p1.jpg", "p2.jpg", "p3.jpg"])
        p.move("p4.jpg", to: 99)
        #expect(p.pages.map(\.id) == ["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"])
        p.delete("p2.jpg")
        p.skip("p3.jpg")
        #expect(p.toSave.map(\.id) == ["p1.jpg", "p4.jpg"])
        p.keep("p3.jpg")
        #expect(p.toSave.map(\.id) == ["p1.jpg", "p3.jpg", "p4.jpg"])
        #expect(p.number("p4.jpg") == 3)
        #expect(ScanPages().summary == "No pages yet")
        #expect(Self.pages(1).summary == "1 page")
    }

    @Test func theRecoveryFolderKeepsThePagesAsTheyWere() {
        var p = Self.pages(2)
        p.analysed("p1.jpg", looksBlank: false, skew: -2, skipBlank: true, straighten: true)
        p.analysed("p2.jpg", looksBlank: true, skew: 0, skipBlank: true, straighten: true)
        p.crop("p1.jpg", shown: CropBox(0, 0, 0.5, 1))
        let kept = p.kept(printerId: Demo.uuid, printerName: "Demo printer", ocr: true, now: Date(timeIntervalSince1970: 0))
        #expect(kept.pages.map(\.file) == ["p1.jpg", "p2.jpg"])
        #expect(kept.pages[1].skipped)
        let back = ScanPages(restoring: kept)
        #expect(back.pages.map(\.edits) == p.pages.map(\.edits))
        #expect(back.toSave.map(\.id) == ["p1.jpg"])
    }
}
