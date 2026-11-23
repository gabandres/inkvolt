import Foundation
import Testing
@testable import PdfCore

/// Ported from BlankPagesTests.cs (roadmap 4.4), all 9 tests, same names: Remove Blank Pages and Split at Blank Pages, in
/// the app and in Batch. Adapted: AShortLineIsNotBlank…'s page is written by hand (Windows draws it with PDFsharp);
/// removing every page is refused with `PdfEditError` (.NET's InvalidOperationException); the progress is a closure.
final class BlankPagesTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-blank-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    /// Pages 1-3 of `TestPdf.make` with blank pages after page 1 and after page 3 (five pages).
    static func withBlanks() throws -> [UInt8] {
        let pdf = try PageEditor.insertBlank(TestPdf.make(3), nil, 1, 1, 612, 792)
        return try PageEditor.insertBlank(pdf, nil, 4, 1, 612, 792)
    }

    private static func find(_ pdf: [UInt8]) throws -> [Int] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try BlankPages.find(engine)
    }

    private static func numbers(_ path: String) throws -> [Int] { TestPdf.pageNumbers(Array(try Data(contentsOf: URL(fileURLWithPath: path)))) }

    @Test func findsThePagesThatAreAllPaper() throws {
        #expect(try Self.find(Self.withBlanks()) == [1, 4])
        #expect(try Self.find(TestPdf.make(2)).isEmpty)
    }

    @Test func aShortLineIsNotBlank_ButSpecksAndPaleShowThroughAre() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
            Core2Pdf.stream("BT /F1 11 Tf 250 392 Td (Continued overleaf) Tj ET"),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R >>",
            // Dust, and the back of the sheet showing through.
            Core2Pdf.stream("0 g 200 491.4 0.6 0.6 re f 0.9216 g 100 492 300 200 re f"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        #expect(try Self.find(pdf) == [1])
    }

    @Test func separatorSheetsSplitTheStack() {
        #expect(BlankPages.splitAt(5, [1, 4]) == [[0], [2, 3]])
        #expect(BlankPages.splitAt(6, [0, 1, 3, 4]) == [[2], [5]]) // two blank sides in a row separate once; none before the first
        #expect(BlankPages.splitAt(3, []) == [[0, 1, 2]])
        #expect(BlankPages.splitAt(2, [0, 1]).isEmpty)
    }

    @Test func removingThemKeepsTheRest_AndNeverTheLastPage() throws {
        let removed = try BlankPages.remove(Self.withBlanks(), nil, [1, 4])
        #expect(TestPdf.pageNumbers(removed) == [1, 2, 3])
        let allBlank = try PageEditor.insertBlank(PageEditor.delete(TestPdf.make(2), nil, [0]), nil, 0, 1, 612, 792)
        #expect(throws: PdfEditError.self) { try BlankPages.remove(allBlank, nil, [0, 1]) }
    }

    @Test func aSignedFileTakesTheRemovalAsAnAppendedChange() throws {
        let signed = SignedEditTests.signed()
        let withBlank = try SignedEdits.run { try PageEditor.insertBlank(signed, nil, 2, 1, 612, 792) }.0
        #expect(try Self.find(withBlank) == [2])
        let (edited, report) = try SignedEdits.run { try BlankPages.remove(withBlank, nil, [2]) }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        let engine = try PdfEngine.open(edited)
        defer { engine.close() }
        #expect(engine.pageCount == 2)
    }

    @Test func batchRemovesThem_AndSplitsAtThem() async throws {
        let input = path("stack.pdf")
        try Data(try Self.withBlanks()).write(to: URL(fileURLWithPath: input))
        let plan = BatchPlan(steps: [.splitAtBlankPages, .removeBlankPages], outputFolder: path("out"))
        let summary = try await BatchRunner.run([BatchFile(input)], plan, BatchHost())

        let item = try #require(summary.items.first)
        #expect(summary.items.count == 1)
        #expect(item.state == .done)
        #expect(item.outputs.map { ($0 as NSString).lastPathComponent } == ["stack.pdf", "stack - part 1.pdf", "stack - part 2.pdf"])
        #expect(try Self.numbers(item.outputs[0]) == [1, 2, 3])
        #expect(try Self.numbers(item.outputs[1]) == [1])
        #expect(try Self.numbers(item.outputs[2]) == [2, 3])
        #expect(item.notes.contains("2 blank pages removed."))
        #expect(item.notes.contains("2 parts saved."))

        // A file without a blank page: nothing split, said so.
        let plain = path("plain.pdf")
        try Data(TestPdf.make(2)).write(to: URL(fileURLWithPath: plain))
        var only = plan
        only.steps = [.splitAtBlankPages]
        let none = try #require(try await BatchRunner.run([BatchFile(plain)], only, BatchHost()).items.first)
        #expect(none.outputs.isEmpty)
        #expect(none.notes.contains("No blank page found: nothing was split."))
    }

    @Test func batesNumbersGoOnFromThePagesStamped_WhenBlankPagesWentAfter() async throws {
        // The first file's blank page is stamped, then removed: the next file goes on from 4, not from 3.
        let first = path("1.pdf"), second = path("2.pdf")
        try Data(try PageEditor.insertBlank(TestPdf.make(2), nil, 1, 1, 612, 792)).write(to: URL(fileURLWithPath: first))
        try Data(TestPdf.make(1)).write(to: URL(fileURLWithPath: second))
        var options = HeaderFooterOptions()
        options.footerRight = "<<bates>>"
        options.marginBottom = 12
        options.bates = BatesFormat("CASE-", 1, 4)
        let plan = BatchPlan(steps: [.headerFooter(options, continueBates: true), .removeBlankPages], outputFolder: path("out"))
        let summary = try await BatchRunner.run([BatchFile(first), BatchFile(second)], plan, BatchHost())

        #expect(summary.items.allSatisfy { $0.state == .done })
        #expect(summary.items[0].notes.contains("1 blank page removed."))
        let engine = try PdfEngine.open(Array(try Data(contentsOf: URL(fileURLWithPath: summary.items[1].outputs[0]))))
        defer { engine.close() }
        #expect(try engine.text(0).text.contains("CASE-0004"))
    }

    @Test func aPageThatCantBeReadIsNotBlank() throws {
        let engine = try PdfEngine.open(Self.withBlanks())
        defer { engine.close() }
        #expect(try !BlankPages.isBlank(engine, 99))
        #expect(try !BlankPages.isBlank(engine, -1))
    }

    @Test func theSearchSaysHowFarItIs_AndStopsWhenAsked() throws {
        let engine = try PdfEngine.open(Self.withBlanks())
        defer { engine.close() }
        var seen: [[Int]] = []
        _ = try BlankPages.find(engine, progress: { seen.append([$0, $1]) })
        #expect(seen == [[0, 5], [1, 5], [2, 5], [3, 5], [4, 5]])
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try BlankPages.find(engine, cancel: cancel) }
    }
}
