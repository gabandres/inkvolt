import Foundation
import Testing
@testable import PdfCore

/// Ported from ReplacePagesTests.cs (roadmap 4.13), all 5 tests, same names: one for one, keeping what led to the replaced
/// pages. Refusals are `PdfEditError`s (.NET's ArgumentException); APageNamedTwiceSaysSo compares the English messages.
struct ReplacePagesTests {
    private static func markers(_ pdf: [UInt8]) throws -> [String] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try (0..<engine.pageCount).map { try engine.text($0).text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
    }

    @Test func theNewPagesTakeTheirPlaces_BookmarksAndLinksFollow() throws {
        var pdf = try Bookmarks.setOutline(TestPdf.make(4), nil, [Bookmark("Third", 2, top: 300), Bookmark("Fourth", 3)])
        pdf = try Links.put(pdf, nil, 0, RectD(72, 300, 100, 20), uri: nil, targetPage: 2)
        let source = PdfSource(TestPdf.make(3, marker: "new"), nil, "fixed.pdf")

        let replaced = try PageEditor.replace(pdf, nil, [1, 2], source, [1, 2])

        #expect(try Self.markers(replaced) == ["Page 1 alpha", "Page 2 new", "Page 3 new", "Page 4 alpha"])
        let bookmarks = try Bookmarks.read(replaced, nil)
        #expect(bookmarks.map { "\($0.title)|\($0.pageIndex)" } == ["Third|2", "Fourth|3"])
        #expect(abs((bookmarks.first?.top ?? 0) - 300) < 0.5) // the same spot
        #expect(try Links.read(replaced, nil).map(\.targetPage) == [2])
    }

    @Test func theOrderOfTheNewPagesIsTheOrderGiven() throws {
        let replaced = try PageEditor.replace(TestPdf.make(3), nil, [0, 2], PdfSource(TestPdf.make(2, marker: "new"), nil, "x.pdf"), [1, 0])
        #expect(try Self.markers(replaced) == ["Page 2 new", "Page 2 alpha", "Page 1 new"])
    }

    @Test func countsThatDiffer_OrAPageNamedTwice_AreRefused() {
        let pdf = TestPdf.make(3)
        let source = PdfSource(TestPdf.make(3, marker: "new"), nil, "x.pdf")
        #expect(throws: PdfEditError.self) { try PageEditor.replace(pdf, nil, [0, 1], source, [0]) }
        #expect(throws: PdfEditError.self) { try PageEditor.replace(pdf, nil, [0, 0], source, [0, 1]) }
        #expect(throws: PdfEditError.self) { try PageEditor.replace(pdf, nil, [5], source, [0]) }
        #expect(throws: PdfEditError.self) { try PageEditor.replace(pdf, nil, [0], source, [7]) }
    }

    @Test func aSignedFileTakesItAsAnAppendedChange() throws {
        let signed = SignedEditTests.signed()
        let (edited, report) = try SignedEdits.run { try PageEditor.replace(signed, nil, [1], PdfSource(TestPdf.make(1, marker: "new"), nil, "x.pdf"), [0]) }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        #expect(try Self.markers(edited) == ["Hello contract", "Page 1 new"])
    }

    @Test func aPageNamedTwiceSaysSo() {
        let pdf = TestPdf.make(3)
        let source = PdfSource(TestPdf.make(3, marker: "new"), nil, "x.pdf")
        func message(_ body: () throws -> [UInt8]) -> String? {
            do {
                _ = try body()
                return nil
            } catch {
                return (error as? PdfEditError)?.message
            }
        }
        #expect(message { try PageEditor.replace(pdf, nil, [0, 0], source, [0, 1]) } == "A page to replace is named twice: each can be replaced once.")
        #expect(message { try PageEditor.replace(pdf, nil, [0, 1], source, [2, 2]) } == "A page of the other PDF is named twice: each can take only one page's place.")
        #expect(message { try PageEditor.replace(pdf, nil, [0, 1], source, [0]) } == "Choose as many pages to put in as pages to replace.")
    }
}
