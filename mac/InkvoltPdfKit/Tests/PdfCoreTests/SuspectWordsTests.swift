import Foundation
import Testing
@testable import PdfCore

/// Ported from SuspectWordsTests.cs: suspect words (roadmap 2.2). Vision gives a confidence per line, not per word, so
/// doubtful words are found by a documented heuristic. A small dictionary stands in for the spell checker.
struct SuspectWordsTests {
    struct Dictionary: Spelling {
        let words: Set<String>
        init(_ words: String...) { self.words = Set(words.map { $0.lowercased() }) }
        var language: String { "en-US" }
        func isKnown(_ word: String) -> Bool { words.contains(word.lowercased()) }
        func suggest(_ word: String) -> [String] { [] }
    }

    static let words = Dictionary("the", "river", "invoice", "well", "known", "don't", "año")

    @Test(arguments: ["river", "River,", "(invoice)", "\"the\"", "well-known", "don't", "año.", "1,234.50", "A4", "MP3", "2nd", "10mm",
                      "COVID-19", "NASA", "—", "€", "a"])
    func ordinaryWordsAreNotSuspect(_ word: String) {
        #expect(SuspectWords.check(word, Self.words) == [])
    }

    @Test(arguments: [("rlver", SuspectReasons.notInDictionary), ("Invoise.", .notInDictionary), ("c0de", .lettersAndDigits),
                      ("1O5", .lettersAndDigits), ("100O", .lettersAndDigits), ("ri|ver", .oddCharacters), ("riv;er", .oddCharacters),
                      ("|", .oddCharacters), ("the\u{FFFD}", .oddCharacters)])
    func doubtfulWordsAreSuspect(_ word: String, _ expected: SuspectReasons) {
        #expect(SuspectWords.check(word, Self.words) == expected)
    }

    @Test func withoutADictionaryOnlyTheShapeOfAWordCounts() {
        #expect(SuspectWords.check("rlver", nil) == [])
        #expect(SuspectWords.check("he1lo", nil) == .lettersAndDigits)
    }

    @Test func aWordReadDifferentlyOnTheScanAsItWasIsSuspectWhenThatReadingIsARealWord() {
        let cleaned = [
            OcrWord("rlver", RectD(100, 100, 40, 12)),
            OcrWord("the", RectD(150, 100, 20, 12)),
            OcrWord("invoice", RectD(180, 100, 50, 12)),
            OcrWord("found", RectD(240, 100, 40, 12)),
            OcrWord("harbor", RectD(290, 100, 45, 12)),
            OcrWord("meadow", RectD(100, 114, 50, 12)),
        ]
        let original = [
            OcrWord("river", RectD(99, 99, 42, 14)), // a real word where the cleaned page read "rlver"
            OcrWord("the", RectD(149, 99, 22, 14)), // the same
            OcrWord("lnvoice", RectD(179, 99, 52, 14)), // garbled on the scan: the cleaned reading is better
            // nothing at "found": the cleaning found it
            OcrWord("window", RectD(289, 99, 47, 14)), // another word altogether: lines matched wrongly, not a misreading
            OcrWord("meadows", RectD(99, 106, 55, 22)), // a tall box reaching up from the line below...
        ]
        #expect(SuspectWords.readDifferently(cleaned, original, Self.words) == [true, false, false, false, false, false])
        #expect(SuspectWords.alternative(cleaned[0], original) == "river")
        #expect(SuspectWords.alternative(cleaned[1], original) == nil)
        // ...counts only for the word on its own line.
        #expect(SuspectWords.alternative(cleaned[5], original) == "meadows")
    }
}
