import Foundation
import Testing
@testable import PdfCore

/// Ported from FindAllTests.cs: Find across a document (roadmap 3.6, the Mac's E16): pages read on several threads, in
/// order, remembered for the next search. Serialized: `PdfEngine.keptTextChars` and `findThreads` are process-wide and
/// some tests change them. Adapted: Windows' FindAll is an enumeration the caller can stop; the Mac's returns the pages
/// and hands them to `onPage` in order, so ACancelledSearchStops cancels from there and StoppingEarlyAndDisposingLeaveNothingRunning
/// closes the engine between searches. ThreadsFindWhatOneThreadFinds is a Mac addition (the Mac reads on threads in
/// process where Windows uses worker processes; FindWorkerTests has no counterpart).
@Suite(.serialized)
struct FindAllTests {
    @Test(arguments: [("fox", false, false), ("FOX", true, false), ("quick brown", false, false), ("Page 3", false, true),
                      ("lazy  dog", false, false), ("o", false, true)])
    func FindsWhatEachPageFindsInPageOrder(_ c: (query: String, matchCase: Bool, wholeWord: Bool)) throws {
        let engine = try PdfEngine.open(TestPdf.make(9))
        defer { engine.close() }
        let all = try engine.findAll(c.query, matchCase: c.matchCase, wholeWord: c.wholeWord)

        #expect(all.map(\.page) == Array(0..<9))
        for p in 0..<9 {
            let expected = try engine.text(p, cache: false).find(c.query, matchCase: c.matchCase, wholeWord: c.wholeWord)
            #expect(expected.map(\.start) == all[p].hits.map(\.start) && expected.map(\.end) == all[p].hits.map(\.end))
            #expect(all[p].error == nil)
            if expected.isEmpty { #expect(all[p].text == nil) } else { #expect(try engine.text(p).text == all[p].text?.text) }
        }
    }

    /// Runs `test` with whole page texts kept up to `chars` characters.
    private func withKeptTexts(_ chars: Int, _ test: () throws -> Void) rethrows {
        let keep = PdfEngine.keptTextChars
        PdfEngine.keptTextChars = chars
        defer { PdfEngine.keptTextChars = keep }
        try test()
    }

    @Test func ASecondSearchReadsOnlyThePagesThatCanMatch() throws {
        try withKeptTexts(0) {
            let engine = try PdfEngine.open(TestPdf.make(8))
            defer { engine.close() }
            #expect(try engine.findAll("fox", matchCase: false, wholeWord: false).reduce(0) { $0 + $1.hits.count } == 8)
            let read = engine.extractions
            #expect(read == 8)

            // Nothing matches: every page's text is remembered as a string, none is read again.
            #expect(try engine.findAll("zebra", matchCase: false, wholeWord: false).allSatisfy { $0.hits.isEmpty })
            #expect(engine.extractions == read)

            // One page matches: only it is read again (for its boxes), and its hit has them.
            let found = try engine.findAll("Page 7", matchCase: false, wholeWord: true).filter { !$0.hits.isEmpty }
            try #require(found.count == 1)
            #expect(found[0].page == 6)
            #expect(engine.extractions == read + 1)
            #expect(!(found[0].text?.rects(found[0].hits[0].start, found[0].hits[0].end).isEmpty ?? true))
        }
    }

    @Test func PagesWithLittleTextAreKeptWholeAndNeverReadAgain() throws {
        let engine = try PdfEngine.open(TestPdf.make(8))
        defer { engine.close() }
        #expect(try engine.findAll("fox", matchCase: false, wholeWord: false).filter { !$0.hits.isEmpty }.count == 8)
        #expect(engine.extractions == 8)

        // A drawing set's title blocks: every later search, and the view's text, come from what was kept.
        let found = try engine.findAll("Page 7", matchCase: false, wholeWord: true).filter { !$0.hits.isEmpty }
        try #require(found.count == 1)
        #expect(!(found[0].text?.rects(found[0].hits[0].start, found[0].hits[0].end).isEmpty ?? true))
        #expect(try engine.findAll("lazy dog", matchCase: false, wholeWord: false).filter { !$0.hits.isEmpty }.count == 8)
        #expect(try found[0].text === engine.text(6))
        #expect(engine.extractions == 8)
    }

    @Test func PagesAlreadyReadForTheViewAreNotReadAgain() throws {
        try withKeptTexts(0) {
            let engine = try PdfEngine.open(TestPdf.make(3))
            defer { engine.close() }
            _ = try engine.text(0)
            _ = try engine.text(1, cache: false)
            let read = engine.extractions
            #expect(try engine.findAll("lazy", matchCase: false, wholeWord: false).filter { !$0.hits.isEmpty }.count == 3)
            // Page 1 is in the view's cache and page 2 had never been read; page 1 (read without caching) is read again.
            #expect(engine.extractions == read + 2)
        }
    }

    @Test func ACancelledSearchStops() throws {
        // 400 pages, not Windows' 40: here several threads read at once, and 40 small pages are all read before the
        // cancel from the second page's callback gets through.
        let engine = try PdfEngine.open(TestPdf.make(400))
        defer { engine.close() }
        let cancel = CancelToken()
        let seen = Seen()
        #expect(throws: CancellationError.self) {
            try engine.findAll("fox", matchCase: false, wholeWord: false, cancel: cancel) { _ in
                if seen.add() == 2 { cancel.cancel() }
            }
        }
        #expect(seen.count >= 2 && seen.count < 400, "\(seen.count)")
        #expect(engine.extractions < 400)
    }

    @Test func StoppingEarlyAndDisposingLeaveNothingRunning() throws {
        let engine = try PdfEngine.open(TestPdf.make(30))
        let first = try engine.findAll("fox", matchCase: false, wholeWord: false).first
        #expect(first?.page == 0)
        #expect(first?.hits.count == 1)
        engine.close()
        #expect(throws: PdfEngineClosed.self) { try engine.findAll("fox", matchCase: false, wholeWord: false) }
    }

    @Test func AnEditSearchesTheNewContent() throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(2, marker: "alpha"), "a.pdf")
        #expect(try session.engine.findAll("alpha", matchCase: false, wholeWord: false).filter { !$0.hits.isEmpty }.count == 2)
        try session.commit(TestPdf.make(2, marker: "omega"), "Edit")
        #expect(try session.engine.findAll("alpha", matchCase: false, wholeWord: false).allSatisfy { $0.hits.isEmpty })
        #expect(try session.engine.findAll("omega", matchCase: false, wholeWord: false).filter { !$0.hits.isEmpty }.count == 2)
    }

    @Test(arguments: [("exam-\nple", "example"), ("Café au lait", "cafe"), ("Café au lait", "CAFE"), ("a cat", "at"), ("a cat", "a cat")])
    func MatchesOnAStringAgreesWithFind(_ c: (text: String, query: String)) {
        let lines = c.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { y, line in
            line.enumerated().map { i, ch in (String(ch), RectD(Double(i * 5), Double(y * 12), 5, 10)) }
        }
        let page = PageText(lines)
        #expect(page.text == c.text)
        for (matchCase, wholeWord, accents) in [(false, false, false), (true, false, false), (false, true, false), (false, false, true)] {
            #expect(!page.find(c.query, matchCase: matchCase, wholeWord: wholeWord, ignoreAccents: accents).isEmpty
                == PageText.matches(page.text, c.query, matchCase: matchCase, wholeWord: wholeWord, ignoreAccents: accents))
        }
    }

    @Test func ThreadsFindWhatOneThreadFinds() throws {
        let threads = PdfEngine.findThreads
        defer { PdfEngine.findThreads = threads }
        let data = TestPdf.make(64)
        PdfEngine.findThreads = 1
        let one = try PdfEngine.open(data)
        defer { one.close() }
        let alone = try one.findAll("o", matchCase: false, wholeWord: false)
        PdfEngine.findThreads = 4
        let many = try PdfEngine.open(data)
        defer { many.close() }
        let order = Seen()
        let together = try many.findAll("o", matchCase: false, wholeWord: false) { m in #expect(order.add() == m.page + 1) }
        #expect(together.map(\.page) == Array(0..<64))
        #expect(alone.map { $0.hits.map(\.start) } == together.map { $0.hits.map(\.start) })
        #expect(many.extractions == 64) // each page read once, on the four threads' own instances
    }
}

/// Counts calls from the search's threads.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() -> Int { lock.withLock { n += 1; return n } }
    var count: Int { lock.withLock { n } }
}
