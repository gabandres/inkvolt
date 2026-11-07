import Foundation
import Testing
@testable import PdfCore

/// Ported from CompareChangesTests.cs: what Compare lists besides wording (roadmap 3.3): formatting changes, moved
/// paragraphs, running headers and footers, words read from a scan.
struct CompareChangesTests {
    private static let plain = WordLook("Arial", 11, false, false, 0)

    private static func page(_ lines: String...) -> PageText { CompareTests.page(lines) }
    private static func page(_ lines: [String]) -> PageText { CompareTests.page(lines) }

    /// Looks over a page's text: `runs` gives other looks to phrases of it, everything else is plain.
    private static func looks(_ page: PageText, _ runs: [(String, WordLook)] = []) -> PageLooks {
        var list: [(start: Int, look: WordLook)] = [(0, plain)]
        let text = page.text as NSString
        for (phrase, look) in runs.sorted(by: { text.range(of: $0.0).location < text.range(of: $1.0).location }) {
            let at = text.range(of: phrase).location
            #expect(at != NSNotFound, "\(phrase)")
            list.append((at, look))
            list.append((at + (phrase as NSString).length, plain))
        }
        return PageLooks(list)
    }

    private static func styled(_ text: String, _ oldRuns: [(String, WordLook)], _ newRuns: [(String, WordLook)]) throws -> CompareResult {
        let o = page(text), n = page(text)
        return try DocumentCompare.run(CompareSource([o], looks: [looks(o, oldRuns)]), CompareSource([n], looks: [looks(n, newRuns)]))
    }

    private static func with(_ change: (inout WordLook) -> Void) -> WordLook {
        var look = plain
        change(&look)
        return look
    }

    private static let bold = with { $0.bold = true }

    // ---- Formatting ----

    @Test func aWordTurnedBoldIsOneFormattingChangeAndNoWordingChange() throws {
        let r = try Self.styled("the fee is due on the first day", [], [("fee is due", Self.bold)])
        #expect(r.changes.count == 1)
        let c = try #require(r.changes.first)
        #expect(c.kind == .formatted)
        #expect(c.newText == "fee is due")
        #expect(c.oldText == "fee is due")
        #expect(c.look?.parts == .bold)
        #expect(c.look?.describe() == "bold added")
        #expect((r.inserted, r.deleted, r.changed, r.formatted) == (0, 0, 0, 1))
        #expect(c.new == [WordSpan(0, 4, 14)])
        #expect(r.summary().contains("1 formatting change"))
        #expect(r.summary().hasPrefix("No text changes"))
        #expect(!r.identical)
    }

    @Test(arguments: [("size", LookParts.size, "size 11 → 14 pt"), ("font", LookParts.font, "font Arial → Times New Roman"),
                      ("color", LookParts.color, "color black → #C00000"), ("italic", LookParts.italic, "italic added")])
    func eachKindOfFormattingIsNamed(_ kind: String, _ parts: LookParts, _ description: String) throws {
        let look = switch kind {
        case "size": Self.with { $0.size = 14 }
        case "font": Self.with { $0.font = "Times New Roman" }
        case "color": Self.with { $0.color = 0xC00000 }
        default: Self.with { $0.italic = true }
        }
        let r = try Self.styled("one two three", [], [("two", look)])
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.look?.parts == parts)
        #expect(r.changes.first?.look?.describe() == description)
    }

    @Test func severalChangesInOneRunAreDescribedTogether() throws {
        let r = try Self.styled("one two three", [("two", Self.bold)], [("two", Self.with { $0.size = 16; $0.italic = true })])
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.look?.parts == [.bold, .italic, .size])
        #expect(r.changes.first?.look?.describe() == "bold removed, italic added, size 11 → 16 pt")
    }

    @Test func tinyDifferencesAreNotFormattingChanges() throws {
        let r = try Self.styled("one two three", [], [("two", Self.with { $0.size = 11.1; $0.color = 0x050505 })])
        #expect(r.changes.isEmpty)
        #expect(r.identical)
    }

    @Test func partOfAWordCounts() throws {
        let r = try Self.styled("international", [], [("inter", Self.bold)])
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.look?.parts == .bold)
    }

    @Test func adjacentWordsWithDifferentChangesAreSeparate() throws {
        let r = try Self.styled("one two three four", [], [("two", Self.bold), ("three", Self.with { $0.size = 14 })])
        #expect(r.changes.map(\.newText) == ["two", "three"])
    }

    @Test func aRunOverAPageBreakIsOneChangeWithASpanOnEachPage() throws {
        let o1 = Self.page("alpha beta gamma"), o2 = Self.page("delta epsilon zeta")
        let n1 = Self.page("alpha beta gamma"), n2 = Self.page("delta epsilon zeta")
        let r = try DocumentCompare.run(CompareSource([o1, o2], looks: [Self.looks(o1), Self.looks(o2)]),
                                        CompareSource([n1, n2], looks: [Self.looks(n1, [("gamma", Self.bold)]), Self.looks(n2, [("delta", Self.bold)])]))
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.newText == "gamma delta")
        #expect(r.changes.first?.new.map(\.page) == [0, 1])
    }

    @Test func wordingIsListedBeforeMovesAndFormattingOnARow() throws {
        let o = Self.page("one two three four five"), n = Self.page("one 2 three four five")
        let r = try DocumentCompare.run(CompareSource([o], looks: [Self.looks(o)]), CompareSource([n], looks: [Self.looks(n, [("three", Self.bold)])]))
        #expect(r.changes.map(\.kind) == [.changed, .formatted])
    }

    @Test func withoutLooksOnOneSideNoFormattingIsReported() throws {
        let o = Self.page("one two"), n = Self.page("one two")
        let r = try DocumentCompare.run(CompareSource([o], looks: [nil]), CompareSource([n], looks: [Self.looks(n, [("two", Self.bold)])]))
        #expect(r.changes.isEmpty)
        #expect(try DocumentCompare.run(CompareSource([o]), CompareSource([n], looks: [Self.looks(n, [("two", Self.bold)])])).changes.isEmpty)
    }

    // ---- Moves ----

    private static let a = "The supplier shall deliver the goods to the buyer at the agreed place before the end of each month."
    private static let b = "The buyer shall inspect all goods within ten days and report any defects to the supplier in writing."
    private static let c = "Neither party may assign this agreement without the prior written consent of the other party here."
    private static let d = "Notices must be sent by registered mail or courier to the address that each party has given above."

    @Test func aMovedParagraphIsOneMoveNotARemovalAndAnInsertion() throws {
        let r = try DocumentCompare.run([Self.page(Self.a, Self.b, Self.c, Self.d)], [Self.page(Self.b, Self.c, Self.a, Self.d)])
        #expect(r.changes.count == 1)
        let c = try #require(r.changes.first)
        #expect(c.kind == .moved)
        #expect(c.newText == Self.a)
        #expect(c.oldText == Self.a)
        #expect((r.inserted, r.deleted, r.changed, r.moved) == (0, 0, 0, 1))
        #expect(r.summary().contains("1 moved"))
        #expect((c.old[0].page, c.old[0].start) == (0, 0))
        let newText = Self.page(Self.b, Self.c, Self.a, Self.d).text as NSString
        #expect(c.new[0].start == newText.range(of: String(Self.a.prefix(20))).location)
    }

    @Test func aMoveSaysWhereTheTextWasTakenFrom() throws {
        let r = try DocumentCompare.run([Self.page(Self.a, Self.b, Self.c, Self.d)], [Self.page(Self.a, Self.c, Self.b, Self.d)])
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.kind == .moved)
        #expect(r.changes.first?.newAnchor?.page == 0)
    }

    @Test func aMoveAcrossPagesKeepsBothPlaces() throws {
        let r = try DocumentCompare.run([Self.page(Self.a, Self.b), Self.page(Self.c, Self.d)], [Self.page(Self.b), Self.page(Self.c, Self.d, Self.a)])
        let moves = r.changes.filter { $0.kind == .moved }
        #expect(moves.count == 1)
        let c = try #require(moves.first)
        #expect(c.old[0].page == 0)
        #expect(c.new[0].page == 1)
        #expect(c.row == 1)
    }

    @Test func aMovedParagraphWithAnEditedWordIsAMoveAndAChange() throws {
        let edited = Self.a.replacingOccurrences(of: "agreed", with: "chosen")
        let r = try DocumentCompare.run([Self.page(Self.a, Self.b, Self.c, Self.d)], [Self.page(Self.b, Self.c, edited, Self.d)])
        #expect(r.changes.count == 2)
        let words = r.changes.filter { $0.kind == .changed }
        #expect(words.count == 1)
        #expect(words.first?.oldText == "agreed")
        #expect(words.first?.newText == "chosen")
        #expect(r.changes.filter { $0.kind != .changed }.map(\.kind) == [.moved])
    }

    @Test func aReplacedSentenceInPlaceIsNotAMove() throws {
        let r = try DocumentCompare.run([Self.page(Self.a, Self.b, Self.d)], [Self.page(Self.a, Self.c, Self.d)])
        #expect(!r.changes.contains { $0.kind == .moved })
    }

    @Test func shortRepeatedPhrasesAreNotMoves() throws {
        let r = try DocumentCompare.run([Self.page("in the event of alpha we pay beta gamma delta epsilon zeta eta theta")],
                                        [Self.page("alpha we pay beta gamma delta epsilon zeta in the event of eta theta")])
        #expect(!r.changes.contains { $0.kind == .moved && $0.newText.split(separator: " ").count < 3 })
    }

    @Test func aPageMovedElsewhereIsOneMoveNotAPageRemovedAndInserted() throws {
        let pages = [Self.a, Self.b, Self.c, Self.d, Self.a.replacingOccurrences(of: "goods", with: "wares") + " Extra words so the page stays apart from the first."]
        let r = try DocumentCompare.run(pages.map { Self.page($0) }, [0, 2, 3, 1, 4].map { Self.page(pages[$0]) })
        #expect(r.moved == 1)
        #expect((r.pagesRemoved, r.pagesInserted) == (0, 0))
        #expect(r.rows.contains { $0.pageMoved })
    }

    @Test func formattingInsideAMovedParagraphIsListedToo() throws {
        let o = Self.page(Self.a, Self.b, Self.c, Self.d), n = Self.page(Self.b, Self.c, Self.a, Self.d)
        let r = try DocumentCompare.run(CompareSource([o], looks: [Self.looks(o)]), CompareSource([n], looks: [Self.looks(n, [("agreed place", Self.bold)])]))
        #expect(r.changes.map(\.kind) == [.moved, .formatted])
    }

    @Test func moveSearchIsBoundedOnRepetitiveText() throws {
        // No unique words and every run alike: the search must stop on its budget, not take quadratic time.
        let a = (0..<30_000).map { $0 % 2 == 0 ? "aa bb cc dd ee" : "ff" }
        let b = Array(a.reversed())
        func line(_ words: [String]) -> PageText { PageText([words.joined(separator: " ").map { (String($0), RectD(0, 0, 1, 1)) }]) }
        let start = Date()
        _ = try DocumentCompare.run([line(a)], [line(b)])
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(ms < 20_000, "took \(Int(ms)) ms")
    }

    @Test func aLongMoveSearchCanBeCancelled() {
        let token = CancelToken()
        token.cancel()
        #expect(throws: CancellationError.self) {
            try CompareMoves.find([DiffOp(.delete, 0, 0, 1), DiffOp(.insert, 1, 0, 1)], ["a"], ["b"], cancel: token)
        }
    }

    // ---- Running headers and footers ----

    /// Pages with a body of their own and a last line made from the page's number.
    private static func footed(_ count: Int, _ footer: (Int) -> String, bodyWords: Int = 12) -> [PageText] {
        (0..<count).map { p in
            page((0..<bodyWords).map { "body\(p)word\($0)" }.joined(separator: " "), (0..<bodyWords).map { "more\(p)word\($0)" }.joined(separator: " "), footer(p))
        }
    }

    @Test func aNumberThatDiffersWithoutCountingUpIsCompared() throws {
        func sub(_ p: Int) -> String { "Subtotal: \(1000 + p * 137),\(10 + p)" }
        let r = try DocumentCompare.run(Self.footed(5, sub), Self.footed(5) { $0 == 2 ? "Subtotal: 9999,99" : sub($0) })
        #expect(!r.identical)
        #expect(r.changes.contains { $0.new.count == 1 && $0.new[0].page == 2 && $0.newText.contains("9999") })
    }

    @Test func aFixedNumberBesideAPageNumberMustMatch() throws {
        let r = try DocumentCompare.run(Self.footed(5) { "Contract 123 - Page \($0 + 1)" }, Self.footed(5) { "Contract 456 - Page \($0 + 1)" })
        #expect(r.changes.filter { $0.kind == .changed && $0.oldText == "123" && $0.newText == "456" }.count == 5)
    }

    @Test func pageNumbersKeepOutOfItPastNineAndWithAFixedNumberBesideThem() throws {
        func foot(_ p: Int) -> String { "Contract 123 - Page \(p + 1) of 14" }
        let r = try DocumentCompare.run(Self.footed(14, foot), Self.footed(14, foot))
        #expect(r.changes.isEmpty)
        // A page removed: every later page's number is one less, and that's no change.
        let shifted = Self.footed(14, foot)
        let after = Self.footed(14, foot).enumerated().filter { $0.offset != 3 }.map(\.element)
        let cut = try DocumentCompare.run(shifted, after)
        #expect(cut.pagesRemoved == 1)
        #expect(cut.changes.count == 1)
    }

    private static func flowing(_ words: [String], _ perPage: Int) -> [PageText] {
        stride(from: 0, to: words.count, by: perPage).map { start in
            let chunk = Array(words[start..<min(words.count, start + perPage)])
            return page(stride(from: 0, to: chunk.count, by: 12).map { chunk[$0..<min(chunk.count, $0 + 12)].joined(separator: " ") })
        }
    }

    @Test func textThatOnlyFlowedOntoAnotherPageIsNoPageChange() throws {
        let words = (0..<300).map { "w\($0)" }
        let added = (0..<50).map { "new\($0)" }
        let r = try DocumentCompare.run(Self.flowing(words, 100), Self.flowing(added + words, 100))
        #expect(r.pagesInserted == 0)
        #expect(r.inserted == 1)
        #expect(r.changes.count == 1)
    }

    @Test func aWordRemovedOnAPageWhoseTextFlowedIsStillListed() throws {
        let words = (0..<300).map { "w\($0)" }
        let changed = words.filter { !["w270", "w271", "w272"].contains($0) }
        let r = try DocumentCompare.run(Self.flowing(words, 100), Self.flowing(changed, 120))
        #expect(r.pagesRemoved == 0)
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.kind == .deleted)
        #expect(r.changes.first?.oldText == "w270 w271 w272")
    }

    @Test func whatIsLeftOnAPageThatMostlyMovedIsListed() throws {
        let moved = (0..<80).map { "m\($0)" }, gone = (0..<15).map { "gone\($0)" }
        let first = (0..<100).map { "a\($0)" }, last = (0..<100).map { "z\($0)" }
        let r = try DocumentCompare.run([Self.flowing(first, 100)[0], Self.flowing(moved + gone, 100)[0], Self.flowing(last, 100)[0]],
                                        [Self.flowing(first, 100)[0], Self.flowing(last + moved, 200)[0]])
        #expect(r.pagesRemoved == 0)
        #expect(r.moved == 1)
        #expect(r.changes.contains { $0.kind == .deleted && $0.oldText.hasPrefix("gone0") })
    }

    private static func bodied(_ header: String, _ pages: [(body: String, number: Int)]) -> [PageText] {
        pages.map { page(header, $0.body, "more of the text on this page", "and a last line of it", "Page \($0.number)") }
    }

    @Test func pageNumbersThatMoveWithTheFlowAreNotChanges() throws {
        // The same words, with the page break elsewhere: the footers land between other words on the new side.
        let oldPages = [Self.page("Supply Agreement", "alpha beta gamma", "delta epsilon zeta", "eta theta iota", "Page 1"),
                        Self.page("Supply Agreement", "kappa lambda mu", "nu xi omicron", "pi rho sigma", "Page 2")]
        let newPages = [Self.page("Supply Agreement", "alpha beta gamma", "delta epsilon", "zeta eta theta iota", "Page 1"),
                        Self.page("Supply Agreement", "kappa lambda", "mu nu xi omicron", "pi rho sigma", "Page 2")]
        #expect(try DocumentCompare.run(oldPages, newPages).changes.isEmpty)
        let moved = [Self.page("Supply Agreement", "alpha beta gamma", "delta epsilon zeta", "Page 1"),
                     Self.page("Supply Agreement", "eta theta iota", "kappa lambda mu", "nu xi omicron", "pi rho sigma", "Page 2")]
        #expect(try DocumentCompare.run(oldPages, moved).changes.isEmpty)
    }

    @Test func aChangedFooterIsStillAChange() throws {
        let oldPages = Self.bodied("Draft for review", [("alpha", 1), ("beta", 2), ("gamma", 3)])
        let newPages = Self.bodied("Final version", [("alpha", 1), ("beta", 2), ("gamma", 3)])
        let r = try DocumentCompare.run(oldPages, newPages)
        #expect(r.changes.count == 3)
        #expect(r.changes.allSatisfy { $0.oldText == "Draft for review" && $0.newText == "Final version" })
    }

    @Test func aFixedNumberInAHeaderIsNotTakenForAPageNumber() throws {
        let oldPages = Self.bodied("Contract 123", [("alpha", 1), ("beta", 2), ("gamma", 3)])
        let newPages = Self.bodied("Contract 124", [("alpha", 1), ("beta", 2), ("gamma", 3)])
        #expect(try DocumentCompare.run(oldPages, newPages).changed == 3)
    }

    @Test func aChangedShortPageIsNeverTakenForAFooter() throws {
        let r = try DocumentCompare.run([Self.page("Total 100"), Self.page("Total 200")], [Self.page("Total 100"), Self.page("Total 300")])
        #expect(r.changed == 1)
    }

    // ---- Scans ----

    @Test func changesOnARecognizedPageSayTheyWereReadFromAScan() throws {
        let r = try DocumentCompare.run(CompareSource([Self.page("the fee is 100 dollars today")]),
                                        CompareSource([Self.page("the fee is 150 dollars today")], scanned: [true]))
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.readFromScan == true)
        #expect(r.changes.first?.maybeMisread == false) // 100 → 150 is no slip of a recognizer's
    }

    @Test(arguments: [("modern", "rnodern"), ("Total", "TotaI"), ("100", "1O0"), ("SOLD", "S0LD")])
    func aRecognizerSlipIsListedButMarkedAsMaybeMisread(_ truth: String, _ read: String) throws {
        let r = try DocumentCompare.run(CompareSource([Self.page("the \(truth) is here")]), CompareSource([Self.page("the \(read) is here")], scanned: [true]))
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.maybeMisread == true)
        #expect(r.summary().contains("may be misread"))
    }

    @Test func withoutAScanNothingIsCalledMisread() throws {
        let r = try DocumentCompare.run([Self.page("the Total is here")], [Self.page("the TotaI is here")])
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.readFromScan == false)
        #expect(r.changes.first?.maybeMisread == false)
    }

    @Test func strayPunctuationOnAScanIsMaybeMisread() throws {
        let r = try DocumentCompare.run(CompareSource([Self.page("alpha beta gamma")]), CompareSource([Self.page("alpha . beta gamma")], scanned: [true]))
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.maybeMisread == true)
    }

    @Test func wordsOfASkewedScanBecomeLinesInReadingOrder() throws {
        // Two rows of words on a page turned 5° clockwise: each word's box is turned about its centre.
        let r = 5 * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        func at(_ text: String, _ x: Double, _ y: Double) -> OcrWord { OcrWord(text, RectD(100 + x * cos - y * sin, 100 + x * sin + y * cos, 40, 10), angle: 5) }
        let page = CompareScan.pageTextOf([at("alpha", 0, 0), at("beta", 50, 0), at("gamma", 0, 20), at("delta", 50, 20)])
        #expect(page.text == "alpha beta\ngamma delta")
        #expect(!page.rects(0, 5).isEmpty)
        // The first word's characters run along the turned line.
        let first = page.boxAt(0), last = page.boxAt(4)
        #expect(last.centerX > first.centerX + 20)
        #expect(last.centerY > first.centerY + 2)
    }

    @Test func noWordsMakeNoText() { #expect(CompareScan.pageTextOf([]).isEmpty) }
}
