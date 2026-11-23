import Foundation
import Testing
@testable import PdfCore

/// Ported from InterleaveTests.cs (roadmap 4.3), all 8 tests, same names: Interleave Pages and Scan the Backs, fronts then
/// backs put together sheet by sheet. Refusals are `PdfEditError`s (.NET's ArgumentException). Adapted: the signed file
/// is `IncrSignatureTests.signedForm(twoPages:)` (signed for real, so its status is verified as on Windows); the plain
/// labels of PlainLabelsAreDropped… are written as catalog text (Windows writes them with PDFsharp).
struct InterleaveTests {
    @Test func backsScannedAfterTurningTheStackOverComeLastPageFirst() throws {
        #expect(try PageEditor.interleaveOrder(6, [0, 1, 2], [3, 4, 5], reverseBacks: true) == [0, 5, 1, 4, 2, 3])
        #expect(try PageEditor.interleaveOrder(6, [0, 1, 2], [3, 4, 5], reverseBacks: false) == [0, 3, 1, 4, 2, 5])
    }

    @Test func otherPagesStayWhereTheyAre_AndWhatOneSideHasLeftOverFollows() throws {
        // A cover page before the scan, three fronts and two backs, a page after.
        #expect(try PageEditor.interleaveOrder(7, [1, 2, 3], [4, 5], reverseBacks: false) == [0, 1, 4, 2, 5, 3, 6])
        #expect(try PageEditor.interleaveOrder(6, [1], [2, 3, 4, 5], reverseBacks: true) == [0, 1, 5, 4, 3, 2])
    }

    @Test func aPageOnBothSides_OrASideWithNone_IsRefused() {
        #expect(throws: PdfEditError.self) { try PageEditor.interleaveOrder(4, [0, 1], [1, 2], reverseBacks: false) }
        #expect(throws: PdfEditError.self) { try PageEditor.interleaveOrder(4, [], [1, 2], reverseBacks: false) }
        #expect(throws: PdfEditError.self) { try PageEditor.interleaveOrder(4, [0], [4], reverseBacks: false) }
    }

    @Test func twoRangesOfOneDocument() throws {
        let pdf = try PageEditor.interleave(TestPdf.make(6), nil, [0, 1, 2], [3, 4, 5], reverseBacks: true)
        #expect(TestPdf.pageNumbers(pdf) == [1, 6, 2, 5, 3, 4])
    }

    @Test func backsFromAnotherFile_KeepTheFrontsBookmarks() throws {
        let fronts = try Bookmarks.setOutline(TestPdf.make(3, marker: "front"), nil, [Bookmark("Second sheet", 1)])
        let pdf = try PageEditor.interleaveWith(fronts, nil, PdfSource(TestPdf.make(3, marker: "back"), nil, "backs.pdf"), reverseBacks: true)

        #expect(TestPdf.pageNumbers(pdf) == [1, 3, 2, 2, 3, 1])
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        #expect(try (0..<6).map { try engine.text($0).text.contains("front") ? "front" : "back" } == ["front", "back", "front", "back", "front", "back"])
        #expect(try Bookmarks.read(pdf, nil).map(\.pageIndex) == [2]) // the second front, now the third page
    }

    @Test func aSignedFileTakesTheBacksAsAnAppendedChange() throws {
        let signed = try IncrSignatureTests.signedForm(twoPages: true)
        let (edited, report) = try SignedEdits.run {
            try PageEditor.interleaveWith(signed, nil, PdfSource(TestPdf.make(2, marker: "back"), nil, "backs.pdf"), reverseBacks: true)
        }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        // The signed revision stays as it was signed; added pages show as a change no signature allows, as a rotation does.
        #expect(Signatures.verify(edited).first { $0.fieldName == "Approval" }?.status == .disallowedChanges)
        let engine = try PdfEngine.open(edited)
        defer { engine.close() }
        #expect(engine.pageCount == 4)
        #expect(try engine.text(1).text.contains("Page 2 back"))
        #expect(try engine.text(2).text.contains("Second page"))
    }

    @Test func pageLabelsAreNumberedOnThroughTheInterleavedPages_NoneShownTwice() throws {
        // A preface in i, ii, then six scanned pages labeled 1-6: the interleaved ones read 1-6 again, in their new order.
        let labeled = try PageLabels.write(TestPdf.make(8), nil, [0, 1], PageLabelStyle(.lowerRoman, "", 1), restartAfter: true)
        let pdf = try PageEditor.interleave(labeled, nil, [2, 3, 4], [5, 6, 7], reverseBacks: true)
        #expect(try DocumentFeatures.pageLabels(pdf, nil) == ["i", "ii", "1", "2", "3", "4", "5", "6"])
        #expect(TestPdf.pageNumbers(pdf) == [1, 2, 3, 8, 4, 7, 5, 6])

        // Backs from another file take labels too.
        let with = try PageEditor.interleaveWith(PageLabels.write(TestPdf.make(2), nil, [0, 1], PageLabelStyle(.decimal, "A-", 1)), nil,
                                                 PdfSource(TestPdf.make(2, marker: "back"), nil, "backs.pdf"), reverseBacks: false)
        #expect(try DocumentFeatures.pageLabels(with, nil) == ["A-1", "A-2", "A-3", "A-4"])
    }

    @Test func plainLabelsAreDropped_TheNumbersShowAnyway() throws {
        let pdf = TestPdf.make(4, catalogExtra: "/PageLabels << /Nums [0 << /S /D >>] >> ")
        #expect(try DocumentFeatures.pageLabels(pdf, nil) == ["1", "2", "3", "4"])
        #expect(try DocumentFeatures.pageLabels(PageEditor.interleave(pdf, nil, [0, 1], [2, 3], reverseBacks: true), nil) == nil)
        #expect(try DocumentFeatures.pageLabels(TestPdf.make(2), nil) == nil)
        #expect(try DocumentFeatures.pageLabels(PageEditor.interleave(TestPdf.make(4), nil, [0, 1], [2, 3], reverseBacks: true), nil) == nil)
    }
}
