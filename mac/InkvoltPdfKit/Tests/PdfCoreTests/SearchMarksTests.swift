import Foundation
import Testing
@testable import PdfCore

/// Ported from SearchMarksTests.cs: Mark All Matches (roadmap 4.18, `SearchMarks`).
struct SearchMarksTests {
    private static func pdf() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (The invoice total and the invoice date.) Tj 0 -20 Td (No match here.) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> /Rotate 90 >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Page two has an invoice too.) Tj ET"),
        ])
    }

    private static func hits(_ pdf: [UInt8], _ query: String) throws -> [HitToMark] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        var hits: [HitToMark] = []
        for m in try engine.findAll(query, matchCase: false, wholeWord: true) {
            for h in m.hits { hits.append(HitToMark(m.page, m.text!.rects(h.start, h.end))) }
        }
        return hits
    }

    @Test func EveryHitBecomesAMarkInOneChange() throws {
        let pdf = Self.pdf()
        let hits = try Self.hits(pdf, "invoice")
        #expect(hits.count == 3)
        let result = try SearchMarks.apply(pdf, nil, hits, .highlight, author: "Ana")
        #expect(result.count == SearchMarksCount(3, 0, 0, 0))
        #expect(try SearchMarks.count(pdf, nil, hits, .highlight) == result.count) // what the undo step is named from
        let marks = try Annotations.read(result.data, nil)
        #expect(marks.count == 3)
        #expect(marks.allSatisfy { $0.kind == .highlight && $0.author == "Ana" })
        #expect(marks.map(\.pageIndex) == [0, 0, 1])
        // Each mark sits on its word, the turned page's too.
        for i in 0..<3 {
            let quad = try #require(marks[i].quadRects.count == 1 ? marks[i].quadRects[0] : nil)
            #expect(abs(hits[i].rects[0].centerX - quad.centerX) < 1.5)
            #expect(abs(hits[i].rects[0].centerY - quad.centerY) < 1.5)
        }
    }

    @Test func HitsMarkedAlreadyAreLeftAloneAndOtherKindsStillMark() throws {
        let pdf = Self.pdf()
        let hits = try Self.hits(pdf, "invoice")
        let once = try SearchMarks.apply(pdf, nil, hits, .highlight, author: "Ana").data
        let twice = try SearchMarks.apply(once, nil, hits, .highlight, author: "Ana")
        #expect(twice.count == SearchMarksCount(0, 3, 0, 0))
        #expect(try SearchMarks.count(once, nil, hits, .highlight) == twice.count)
        #expect(twice.data == once) // nothing changed: the same bytes, no edit to undo
        let underlined = try SearchMarks.apply(once, nil, hits, .underline, author: "Ana")
        #expect(underlined.count.marked == 3)
        #expect(try Annotations.read(underlined.data, nil).count == 6)

        // The same hit twice in the list is marked once; hits off the document or without a box are passed over.
        let odd = try SearchMarks.apply(pdf, nil, [hits[0], hits[0], HitToMark(7, hits[0].rects), HitToMark(0, []),
                                                   HitToMark(0, [RectD(.nan, 0, 5, 5)])], .strikeOut, author: "Ana")
        #expect(odd.count == SearchMarksCount(1, 1, 0, 3))
        let read = try Annotations.read(odd.data, nil)
        #expect(read.count == 1 && read.first?.kind == .strikeOut)
    }

    /// A page whose /Annots lists `marks` highlights of 20,000 lines each, each `times` times.
    private static func overmarked(_ marks: Int, _ times: Int) -> [UInt8] {
        let quads = Array(repeating: "10 20 30 20 10 10 30 10", count: 20_000).joined(separator: " ")
        let refs = (0..<times).flatMap { _ in (0..<marks).map { "\(4 + $0) 0 R" } }.joined(separator: " ")
        return Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [\(refs)] >>",
        ] + (0..<marks).map { _ in "<< /Type /Annot /Subtype /Highlight /Rect [10 10 30 20] /QuadPoints [\(quads)] >>" })
    }

    @Test func AMarkListedThousandsOfTimes_IsReadOnce_AndAPageOfTooManyMarkedLinesIsSaid() throws {
        // One highlight of 20,000 lines listed 10,000 times: 200 million boxes before; read once now.
        let hit = [HitToMark(0, [RectD(300, 300, 40, 10)]), HitToMark(0, [RectD(10, 772, 20, 10)])]
        let clock = ContinuousClock.now
        let once = try SearchMarks.count(Self.overmarked(1, 10_000), nil, hit, .highlight)
        #expect(ContinuousClock.now - clock < .seconds(20))
        #expect(once == SearchMarksCount(1, 1, 0, 0)) // the hit under the mark is still known as marked

        // Three of them, each its own: more lines than are read; the hits are planned, and the page is counted as not all read.
        let many = try SearchMarks.count(Self.overmarked(3, 1), nil, hit, .highlight)
        #expect(many == SearchMarksCount(1, 1, 0, 0, pagesNotAllRead: 1))
    }

    @Test func AtMostTheLimitIsMarked() throws {
        let pdf = Self.pdf()
        let many = (0..<(SearchMarks.maxMarks + 10)).map { i in
            HitToMark(0, [RectD(10 + Double(i % 50) * 11, 10 + Double(i / 50) * 7, 10, 6)])
        }
        let result = try SearchMarks.apply(pdf, nil, many, .highlight, author: "Ana")
        // The hits past the limit are counted as left for another run, apart from those marked already or without a page.
        #expect(result.count == SearchMarksCount(SearchMarks.maxMarks, 0, 10, 0))
        let again = try SearchMarks.apply(result.data, nil, many + [HitToMark(9, many[0].rects)], .highlight, author: "Ana")
        #expect(again.count == SearchMarksCount(10, SearchMarks.maxMarks, 0, 1))
    }
}
