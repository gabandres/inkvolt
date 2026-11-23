import Foundation
import Testing
@testable import PdfCore

/// Ported from PageLabelEditTests.cs (roadmap 4.14), all 7 tests, same names: written for a range, the other pages keeping
/// theirs. Refusals are `PdfEditError`s (.NET's ArgumentException). TheFewestRangesAreWritten reads /Nums through MuPDF.
struct PageLabelEditTests {
    /// Each page's label, or "none" when the document has no labels.
    private static func labels(_ pdf: [UInt8]) throws -> [String] { try DocumentFeatures.pageLabels(pdf, nil) ?? ["none"] }

    private static let roman = PageLabelStyle(.lowerRoman, "", 1)

    @Test func aPrefaceInRomanThenTheBodyFromOne() throws {
        let pdf = try PageLabels.write(TestPdf.make(6), nil, [0, 1], Self.roman, restartAfter: true)
        #expect(try Self.labels(pdf) == ["i", "ii", "1", "2", "3", "4"])

        // Without restarting, the pages after keep the labels they had.
        #expect(try Self.labels(PageLabels.write(TestPdf.make(6), nil, [0, 1], Self.roman)) == ["i", "ii", "3", "4", "5", "6"])
    }

    @Test func everyStyle_PrefixesAndAStartNumber() throws {
        var pdf = TestPdf.make(8)
        pdf = try PageLabels.write(pdf, nil, [0, 1], PageLabelStyle(.upperRoman, "", 4))
        pdf = try PageLabels.write(pdf, nil, [2, 3], PageLabelStyle(.upperLetters, "App-", 1))
        pdf = try PageLabels.write(pdf, nil, [4, 5], PageLabelStyle(.lowerLetters, "", 26))
        pdf = try PageLabels.write(pdf, nil, [6], PageLabelStyle(.none, "Cover", 1))
        pdf = try PageLabels.write(pdf, nil, [7], PageLabelStyle(.decimal, "A-", 10))
        #expect(try Self.labels(pdf) == ["IV", "V", "App-A", "App-B", "z", "aa", "Cover", "A-10"])
        #expect(PageLabelStyle(.upperLetters, "App-", 1).format(1) == "App-B")
        #expect(try PageLabels.at(pdf, nil, 3) == PageLabelStyle(.upperLetters, "App-", 2))
    }

    @Test func labelsThatComeBackToPlainNumbersAreNotWritten() throws {
        let labeled = try PageLabels.write(TestPdf.make(3), nil, [0], Self.roman, restartAfter: true)
        #expect(try Self.labels(labeled) == ["i", "1", "2"])
        #expect(try Self.labels(PageLabels.remove(labeled, nil)) == ["none"])
        #expect(try Self.labels(PageLabels.write(labeled, nil, [0, 1, 2], PageLabelStyle(.decimal, "", 1))) == ["none"])
        #expect(try PageLabels.at(TestPdf.make(3), nil, 2) == PageLabelStyle(.decimal, "", 3))
    }

    @Test func theFewestRangesAreWritten() throws {
        let pdf = try PageLabels.write(TestPdf.make(10), nil, [0, 1, 2], Self.roman, restartAfter: true)
        let doc = try PdfEdit.openToRead(pdf, nil)
        let nums = try #require(doc.catalog.dict("PageLabels")?.array("Nums"))
        #expect(nums.count == 4) // [0 << /S /r >> 3 << /S /D >>]
    }

    @Test func aHostilePrefixOrNumberIsRefused() {
        let pdf = TestPdf.make(2)
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [0], PageLabelStyle(.decimal, String(repeating: "x", count: 65), 1)) }
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [0], PageLabelStyle(.decimal, "a\nb", 1)) }
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [0], PageLabelStyle(.decimal, "", 0)) }
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [0], PageLabelStyle(.decimal, "", PageLabels.maxStart + 1)) }
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [0], PageLabelStyle(.none, "", 1)) }
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [2], Self.roman) }
        #expect(throws: PdfEditError.self) { try PageLabels.write(pdf, nil, [], Self.roman) }
    }

    @Test func pageEditsKeepTheLabelsWritten_AndAReplacedPageKeepsItsOwn() throws {
        let labeled = try PageLabels.write(TestPdf.make(4), nil, [0, 1], Self.roman, restartAfter: true)
        #expect(try Self.labels(labeled) == ["i", "ii", "1", "2"])
        #expect(try Self.labels(PageEditor.move(labeled, nil, 4, [0], 4)) == ["ii", "1", "2", "i"])
    }

    @Test func aSignedFileTakesThemAsAnAppendedChange() throws {
        let signed = SignedEditTests.signed()
        let (edited, report) = try SignedEdits.run { try PageLabels.write(signed, nil, [0], PageLabelStyle(.none, "Cover", 1), restartAfter: true) }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        #expect(try Self.labels(edited) == ["Cover", "1"])
    }
}
