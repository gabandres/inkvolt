import Foundation
import Testing
@testable import PdfCore

/// Ported from ReadAloudTextTests.cs with the same names. Offsets are UTF-16 units, as on Windows.
struct ReadAloudTextTests {
    private static let page =
        "Chapter One\n" +
        "The quick brown fox jumps over the lazy dog and keeps on run-\n" +
        "ning across the field until the evening comes and the light fades.\n" +
        "It stopped.\n" +
        "A second paragraph begins here and goes on for quite a while too,\n" +
        "ending on this line.\n" +
        "\n" +
        "• First point of a list\n" +
        "• Second point"

    private static let units = Array(page.utf16)

    private static func slice(_ s: Int, _ e: Int) -> String { String(decoding: units[s..<e], as: UTF16.self) }

    private static func offset(of needle: String) -> Int {
        let n = Array(needle.utf16)
        return (0...(units.count - n.count)).first { Array(units[$0..<($0 + n.count)]) == n } ?? -1
    }

    @Test func splitsParagraphsAndJoinsLines() {
        let chunks = ReadAloudText.chunks(3, Self.page)
        #expect(chunks.map(\.text) == [
            "Chapter One",
            "The quick brown fox jumps over the lazy dog and keeps on running across the field until the evening comes and the light fades. It stopped.",
            "A second paragraph begins here and goes on for quite a while too, ending on this line.",
            "• First point of a list",
            "• Second point",
        ])
        #expect(chunks.allSatisfy { $0.page == 3 })
    }

    @Test func mapsSpokenTextBackToThePage() throws {
        let chunks = ReadAloudText.chunks(0, Self.page)
        for c in chunks {
            let spoken = Array(c.text.utf16)
            #expect(spoken.count == c.source.count)
            for (i, u) in spoken.enumerated() where u != 32 { #expect(u == Self.units[c.source[i]]) }
        }
        // "running" spans the hyphenated line break: its page range covers "run-\nning".
        let p = chunks[1]
        let at = try #require(p.text.utf16.firstRange(of: "running".utf16)).lowerBound
        let i = p.text.utf16.distance(from: p.text.utf16.startIndex, to: at)
        let (s, e) = p.sourceRange(i, i + 7)
        #expect(Self.slice(s, e) == "run-\nning")
    }

    @Test func readsFromAGivenPosition() throws {
        let from = Self.offset(of: "A second")
        let to = Self.offset(of: "too,") + 3
        let chunks = ReadAloudText.chunks(0, Self.page, from: from, to: to)
        try #require(chunks.count == 1)
        #expect(chunks[0].text == "A second paragraph begins here and goes on for quite a while too")
        #expect(chunks[0].sourceStart == from)
    }

    @Test func cutsLongParagraphsAtSentenceEnds() {
        let text = (1...60).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let chunks = ReadAloudText.chunks(0, text, maxLength: 200)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.text.utf16.count <= 200 })
        #expect(chunks.allSatisfy { $0.text.hasSuffix(".") })
        #expect(chunks.map(\.text).joined(separator: " ") == text)
    }

    @Test func skipsEmptyAndPunctuationOnlyText() {
        #expect(ReadAloudText.chunks(0, "").isEmpty)
        #expect(ReadAloudText.chunks(0, "\n\n . \n").isEmpty)
    }

    /// A Mac addition: reading again from a sentence keeps the mapping.
    @Test func aChunkReadFromASentenceKeepsItsMapping() {
        let c = ReadAloudText.chunks(0, Self.page)[1]
        let at = c.text.utf16.count - "It stopped.".utf16.count
        let rest = c.suffix(from: at)
        #expect(rest.text == "It stopped.")
        #expect(Self.slice(rest.sourceStart, rest.sourceStart + 11) == "It stopped.")
    }
}
