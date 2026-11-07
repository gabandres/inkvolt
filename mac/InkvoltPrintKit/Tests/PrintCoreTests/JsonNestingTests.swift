import Foundation
import Testing
@testable import PrintCore

/// The depth check before JSONSerialization (`JsonNesting`), which reads JSON5 where a preset or a form data file allows it:
/// a ' string, a // or /* */ comment, or a closing bracket with nothing open must not hide nesting from the count. No Windows
/// equivalent: System.Text.Json stops at its MaxDepth itself. A Mac addition from Inkvolt PDF for Mac's hostile-input review.
struct JsonNestingTests {
    private static let open = String(repeating: "[", count: 100_000)
    private static let close = String(repeating: "]", count: 100_000)

    /// The cases (named, so a failure doesn't print 100,000 brackets) that `isSafe` gives `safe` for.
    private static func check(_ cases: [(String, String)], safe: Bool) {
        for (name, json) in cases {
            let got = JsonNesting.isSafe(Data(json.utf8))
            #expect(got == safe, "\(name)")
        }
    }

    @Test func Nesting_hidden_by_JSON5_is_still_counted() {
        Self.check([
            // A " inside a ' string: the old count took it for a string's start and the brackets after it as text.
            ("a \" in a ' string", "{a:'\"', b:\(Self.open)"),
            // Closing brackets in a comment: the old count went far below 0, then back up through the real ones.
            ("] in a /* */ comment", "/* \(Self.close) */ \(Self.open)"),
            ("] in a // comment", "// \(Self.close)\n\(Self.open)"),
            // Closing brackets with nothing open (not JSON, but never below 0).
            ("] with nothing open", Self.close + Self.open),
            // A ' string can't hide a " string's end, nor an escaped ' its own.
            ("a ' in a \" string", "{a:\"'\", b:\(Self.open)"),
            ("an escaped ' in a ' string", "{a:'\\'', b:\(Self.open)"),
        ], safe: false)
    }

    @Test func What_JSON5_puts_in_strings_and_comments_isnt_counted() {
        Self.check([
            ("[ in strings", "{'a': '\(Self.open)', \"b\": \"\(Self.open)\"}"),
            ("[ in comments", "// \(Self.open)\n{ /* \(Self.open) */ a: 1 }"),
            ("escaped quotes", "{ a: 'it\\'s [[[', b: \"say \\\"[[[\\\"\" }"),
            // A / that isn't a comment's start, and a comment never closed, hide nothing after them.
            ("a lone /", "{a: 1 / 2}"),
            ("a comment never closed", "[1] /* " + Self.open),
        ], safe: true)
    }

    @Test func Up_to_the_limit_is_read_and_one_more_isnt() {
        let limit = JsonNesting.limit
        let deepest = String(repeating: "[", count: limit) + String(repeating: "]", count: limit)
        let tooDeep = String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1)
        let wide = "[" + Array(repeating: "[[]]", count: 1_000).joined(separator: ",") + "]"
        Self.check([("the limit", deepest), ("wide", wide)], safe: true)
        Self.check([("one more", tooDeep)], safe: false)
    }
}
