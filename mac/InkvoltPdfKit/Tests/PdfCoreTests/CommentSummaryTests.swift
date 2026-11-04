import Foundation
import Testing
@testable import PdfCore

/// CommentSummaryTests.cs: Summarize Comments (roadmap 1.4): each page beside its comments, numbered on both sides, long
/// lists continued.
struct CommentSummaryTests {
    @Test func putsEachPageBesideItsNumberedComments() throws {
        let source = try CommentFilesTests.commented()
        let plan = CommentSummary.plan(try Annotations.read(source, nil))
        #expect(plan.map(\.page) == [0, 1])
        // Replies come right under their comment, with its number; numbers run on across pages.
        let first = plan[0].entries
        let i = try #require(first.firstIndex { $0.comment.id == "note-1" })
        let note = first[i]
        #expect(first[i + 1].comment.id == "reply-1" && first[i + 1].depth == 1 && first[i + 1].number == note.number)
        #expect(first[i + 2].comment.id == "reply-2" && first[i + 2].depth == 2 && first[i + 2].number == note.number)
        let numbers = plan.flatMap(\.entries).filter { $0.depth == 0 }.map(\.number)
        #expect(numbers == Array(1...11))

        let pdf = try CommentSummary.make(source, nil, title: "Report.pdf")
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        #expect(engine.pageCount == 2)
        #expect(engine.page(0).width > engine.page(0).height, "landscape sheets")

        let sheet1 = try Core2Pdf.allText(pdf, page: 0)
        #expect(sheet1.contains("Page 1"))
        #expect(sheet1.contains("Comments on Report.pdf"))
        #expect(sheet1.contains("Check this,"))
        #expect(sheet1.contains("Agreed ✓ — señal"))
        #expect(sheet1.contains("Ana Lucía"))
        let sheet2 = try Core2Pdf.allText(pdf, page: 1)
        #expect(sheet2.contains("Page 2"))
        #expect(sheet2.contains("Callout, text")) // in the list and on the page

        // Each number is in a disc on the page side and at its entry: twice per sheet.
        for (page, entries) in plan {
            let words = try Core2Pdf.lines(pdf, page: page).flatMap { $0.text.split(separator: " ").map(String.init) }
            for n in entries.filter({ $0.depth == 0 }).map({ String($0.number) }) {
                #expect(words.filter { $0 == n }.count >= 2, "number \(n) on sheet \(page + 1)")
            }
        }

        // The page is drawn at the left (ink there), the list at the right.
        #expect(try Core2Pdf.ink(pdf, 0, RectD(40, 100, 300, 400)) > 0.002)
    }

    @Test func longListsFlowOntoContinuationSheets() throws {
        var pdf = TestPdf.make(1)
        for i in 0..<40 {
            pdf = try Annotations.addNote(pdf, nil, 0, Double(40 + i * 12), Double(200 + i * 10),
                                          "Comment \(i + 1): " + String(repeating: "words that wrap ", count: 6), author: "Rev")
        }
        let summary = try CommentSummary.make(pdf, nil, title: "long.pdf")
        let engine = try PdfEngine.open(summary)
        defer { engine.close() }
        #expect(engine.pageCount >= 3)
        #expect(try Core2Pdf.allText(summary, page: 1).contains("Page 1 (continued)"))
        let all = try (0..<engine.pageCount).map { try Core2Pdf.allText(summary, page: $0) }.joined(separator: "\n")
        for i in 1...40 { #expect(all.contains("Comment \(i):"), "Comment \(i)") }
    }

    @Test func noCommentsNoSummary() {
        #expect(throws: PdfEditError.self) { try CommentSummary.make(TestPdf.make(1), nil, title: "x.pdf") }
    }
}
