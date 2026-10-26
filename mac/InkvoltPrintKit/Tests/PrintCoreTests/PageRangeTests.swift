import Foundation
import Testing
@testable import PrintCore

/// Print-dialog page ranges. Ported from PageRangeTests.cs; both tests, none left out. Adapted: .NET's
/// `TryParse(text, count, out pages, out error)` is `parse(text, count)` returning a `Result` here.
struct PageRangeTests {
    @Test(arguments: [
        ("", 5, [1, 2, 3, 4, 5]),
        ("  ", 3, [1, 2, 3]),
        ("2", 5, [2]),
        ("1-3, 5", 5, [1, 2, 3, 5]),
        ("4-", 6, [4, 5, 6]),
        ("-2", 6, [1, 2]),
        ("3-1", 5, [1, 2, 3]),
        ("2,2,1", 5, [1, 2]),
        ("1\u{2013}3", 5, [1, 2, 3]), // en dash, as pasted from Word
    ] as [(String, Int, [Int])])
    func parses(_ text: String, _ pageCount: Int, _ expected: [Int]) {
        #expect(PageRange.parse(text, pageCount) == .success(expected))
    }

    @Test(arguments: [
        ("0", 5, "Pages start at 1"),
        ("7", 5, "This document has 5 pages"),
        ("2-9", 5, "This document has 5 pages"),
        ("a", 5, "Use page numbers like 1-3, 5"),
        ("1--2", 5, "Use page numbers like 1-3, 5"),
    ] as [(String, Int, String)])
    func rejects(_ text: String, _ pageCount: Int, _ error: String) {
        #expect(PageRange.parse(text, pageCount) == .failure(PageRange.Invalid(error)))
    }
}
