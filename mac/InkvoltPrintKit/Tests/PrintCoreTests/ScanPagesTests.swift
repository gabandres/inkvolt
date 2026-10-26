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

    // MARK: Batches

    private static let patch = SeparatorFound(.patchCode, code: .patchT)

    /// Letter, letter, Patch T sheet, letter, blank, letter: the demo feeder's batch.
    private static func batch(skipBlank: Bool = true) -> ScanPages {
        var p = Self.pages(6)
        for i in 1...6 {
            p.analysed("p\(i).jpg", looksBlank: i == 5, skew: i == 6 ? -1.5 : 0, skipBlank: skipBlank, straighten: true,
                       separator: i == 3 ? Self.patch : .none)
        }
        return p
    }

    @Test func aSeparatorSheetStartsANewFileAndIsLeftOut() throws {
        let p = Self.batch()

        #expect(p.files.map { $0.map(\.id) } == [["p1.jpg", "p2.jpg"], ["p4.jpg", "p6.jpg"]])
        #expect(p.fileStart("p1.jpg") == 1)
        #expect(p.fileStart("p4.jpg") == 2)
        #expect(p.fileStart("p2.jpg") == 0)
        #expect(p.fileStarts == ["p1.jpg": 1, "p4.jpg": 2])
        let sheet = try #require(p.page("p3.jpg"))
        #expect(!sheet.skipped)
        #expect(sheet.edits.isEmpty)
        #expect(sheet.note == "Separator: Patch T sheet")
        #expect(p.summary == "6 pages in 2 files, 1 separator left out, 1 not saved")
        #expect(try #require(p.page("p6.jpg")).edits == PageEdits(deskew: -1.5))
    }

    @Test func keptSeparatorsStartTheFileTheyBegin() {
        var p = Self.batch()
        p.keepSeparators = true

        #expect(p.files.map { $0.map(\.id) } == [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg", "p6.jpg"]])
        #expect(p.summary == "6 pages in 2 files, 1 not saved")
    }

    @Test func oneFileSaysNothingAboutFiles() {
        let p = Self.pages(2)
        #expect(p.files.count == 1)
        #expect(p.fileStart("p1.jpg") == 0)
    }

    @Test func splitPointsMoveByHand() {
        var p = Self.batch()
        p.toggleStartsFile("p2.jpg")
        #expect(p.files.map { $0.map(\.id) } == [["p1.jpg"], ["p2.jpg"], ["p4.jpg", "p6.jpg"]])
        p.toggleStartsFile("p3.jpg") // a separator starts one anyway
        #expect(p.page("p3.jpg")?.startsFile == false)
        p.notSeparator("p3.jpg")
        #expect(p.files.map { $0.map(\.id) } == [["p1.jpg"], ["p2.jpg", "p3.jpg", "p4.jpg", "p6.jpg"]])
        p.useAsSeparator("p5.jpg") // the blank page: kept back, as a separator
        #expect(p.page("p5.jpg")?.skipped == false)
        #expect(p.files.map { $0.map(\.id) } == [["p1.jpg"], ["p2.jpg", "p3.jpg", "p4.jpg"], ["p6.jpg"]])
    }

    @Test func aBlankSeparatorIsNotSkipped() throws {
        var p = Self.pages(3)
        p.analysed("p2.jpg", looksBlank: true, skew: 0, skipBlank: true, straighten: true, separator: SeparatorFound(.blankPage))
        let sheet = try #require(p.page("p2.jpg"))
        #expect(!sheet.skipped)
        #expect(sheet.looksBlank)
        #expect(p.files.count == 2)
    }

    @Test func theBackOfAPatchSheetBelongsToItInATwoSidedBatch() throws {
        var p = Self.pages(6)
        // Front, back pairs: sheet 2 is the patch sheet; its back has some show-through, so it doesn't look blank.
        for i in 1...6 {
            p.analysed("p\(i).jpg", looksBlank: false, skew: i == 4 ? 1 : 0, skipBlank: true, straighten: true,
                       separator: i == 3 ? Self.patch : .none)
        }
        p.separatorBacks((1...6).map { "p\($0).jpg" })

        let back = try #require(p.page("p4.jpg"))
        #expect(back.separator.kind == .sheetBack)
        #expect(back.edits.isEmpty)
        #expect(p.files.map { $0.map(\.id) } == [["p1.jpg", "p2.jpg"], ["p5.jpg", "p6.jpg"]])
    }

    @Test func aBatchComesBackFromTheRecoveryFolderAsTheSameFiles() throws {
        var p = Self.batch()
        p.toggleStartsFile("p2.jpg")
        let kept = p.kept(printerId: Demo.uuid, printerName: "Demo printer", ocr: false, now: Date(timeIntervalSince1970: 0))
        #expect(kept.pages[2].separator == Self.patch)
        let data = try JSONEncoder().encode(kept)
        let back = ScanPages(restoring: try JSONDecoder().decode(KeptScan.self, from: data))
        #expect(back.files.map { $0.map(\.id) } == p.files.map { $0.map(\.id) })
        #expect(back.page("p3.jpg")?.note == "Separator: Patch T sheet")
        #expect(back.page("p5.jpg")?.note == "Blank, not saved")
    }

    // MARK: Photos on the glass

    @Test func photosOnTheGlassAreSavedByThemselvesAndTurnTogether() throws {
        var p = Self.pages(1)
        let boxes = [PhotoBox(centerX: 0.25, centerY: 0.2, width: 0.3, height: 0.2, angle: 3),
                     PhotoBox(centerX: 0.7, centerY: 0.2, width: 0.3, height: 0.2, angle: -2)]
        p.analysed("p1.jpg", looksBlank: false, skew: 2, skipBlank: true, straighten: true, photos: boxes)
        #expect(p.fileStarts.isEmpty)
        let page = try #require(p.page("p1.jpg"))
        #expect(page.edits.isEmpty) // each photo is cut out straight, not the page
        #expect(page.note == "2 photos")
        #expect(p.summary == "1 page (2 photos)")

        p.turn("p1.jpg", 1)
        #expect(p.page("p1.jpg")?.photos?.map(\.quarterTurns) == [1, 1])
        #expect(p.page("p1.jpg")?.edits.isEmpty == true)
        p.turn("p1.jpg", -2)
        #expect(p.page("p1.jpg")?.photos?.map(\.quarterTurns) == [3, 3])

        let kept = p.kept(printerId: Demo.uuid, printerName: "Demo printer", ocr: false, now: Date(timeIntervalSince1970: 0))
        #expect(ScanPages(restoring: try JSONDecoder().decode(KeptScan.self, from: try JSONEncoder().encode(kept))).page("p1.jpg")?.photos?.count == 2)

        p.setPhotos("p1.jpg", [])
        #expect(p.page("p1.jpg")?.hasPhotos == false) // none: the whole scan is saved
        p.turn("p1.jpg", 1)
        #expect(p.page("p1.jpg")?.edits.quarterTurns == 1)
    }
}
