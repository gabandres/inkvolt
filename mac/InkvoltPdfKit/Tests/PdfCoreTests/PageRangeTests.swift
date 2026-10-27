import Foundation
import Testing
@testable import PdfCore

/// Ported from PageRangeTests.cs, with Core1TextTests' PageRangesAcceptTypographicDashes.
struct PageRangeTests {
    @Test(arguments: [
        ("1-3, 5", 10, [0, 1, 2, 4]),
        ("8-", 10, [7, 8, 9]),
        ("-2", 10, [0, 1]),
        ("3;1;3", 10, [0, 2]),
        ("2-end", 4, [1, 2, 3]),
    ])
    func parses(text: String, count: Int, expected: [Int]) {
        let r = PageRange.tryParse(text, count)
        #expect(r.ok)
        #expect(r.pages == expected)
    }

    @Test(arguments: ["0", "11", "5-3", "abc", ""])
    func rejects(text: String) {
        let r = PageRange.tryParse(text, 10)
        #expect(!r.ok)
        #expect(r.error != nil)
    }

    @Test func formatsCompactly() { #expect(PageRange.format([0, 1, 2, 4, 8, 9]) == "1-3, 5, 9-10") }

    @Test func evenOddUseOneBasedNumbers() {
        #expect(PageRange.apply([0, 1, 2, 3], .even) == [1, 3])
        #expect(PageRange.apply([0, 1, 2, 3], .odd) == [0, 2])
    }

    @Test(arguments: ["2–4", "2 — 4", "2-4"])
    func pageRangesAcceptTypographicDashes(text: String) {
        let r = PageRange.tryParse(text, 5)
        #expect(r.ok)
        #expect(r.pages == [1, 2, 3])
        #expect(!PageRange.tryParse("+2", 5).ok)
    }
}
