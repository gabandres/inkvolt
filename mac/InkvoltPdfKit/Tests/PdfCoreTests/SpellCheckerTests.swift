import Foundation
import Testing
@testable import PdfCore

/// Ported from SpellCheckerTests.cs: spell check where people type (roadmap 4.1): what is looked up, what is underlined,
/// and what Ignore, Add to dictionary and a suggestion do. A word list stands in for the Mac's NSSpellChecker.
struct SpellCheckerTests {
    private final class WordList: SpellingDictionary, @unchecked Sendable {
        private var words: Set<String>
        private(set) var added: [String] = []
        private(set) var lookups = 0
        var refuses = false
        let language = "en-US"

        init(_ words: String...) { self.words = Set(words.map { $0.lowercased() }) }

        func isKnown(_ word: String) -> Bool {
            lookups += 1
            return words.contains(word.lowercased())
        }

        func suggest(_ word: String) -> [String] {
            (words.filter { $0.count == word.count && $0.first == word.lowercased().first } + [word]).sorted()
        }

        func add(_ word: String) -> Bool {
            if refuses { return false }
            added.append(word)
            words.insert(word.lowercased())
            return true
        }
    }

    private static func looked(_ text: String, skipAllCaps: Bool = true) -> [String] {
        SpellChecker.words(text, skipAllCaps: skipAllCaps).map { (text as NSString).substring(with: NSRange(location: $0.start, length: $0.length)) }
    }

    @Test func WordsAreLettersWithApostrophesInside() {
        #expect(Self.looked("Don't worry, it's well-known (año).") == ["Don't", "worry", "it's", "well", "known", "año"])
        #expect(Self.looked("rock ’n’ roll") == ["rock", "roll"])
        #expect(Self.looked("«l'été»") == ["l'été"])
    }

    @Test(arguments: [
        "A4 2nd 10mm MP3 COVID-19 1,234.50", // digits
        "a I x", // single letters
        "NASA UNESCO", // capitals: an acronym
        "https://example.com/path www.inkvolt.app mail@example.com example.com C:\\Users\\me\\file.pdf ./notes and/or",
        "— € … ¿¡ \u{FFFC}",
    ])
    func NumbersAddressesAcronymsAndSymbolsAreLeftAlone(_ text: String) {
        #expect(Self.looked(text).isEmpty)
    }

    @Test func CapitalsAreLookedUpWhenAsked() { #expect(Self.looked("NASA", skipAllCaps: false) == ["NASA"]) }

    @Test func AnOverlongRunIsNoWord() { #expect(Self.looked(String(repeating: "x", count: SpellChecker.maxWordLength + 1)).isEmpty) }

    @Test func AHugeTextIsLookedUpOnlyThatFar() {
        let text = Array(repeating: "word", count: SpellChecker.maxWords * 3).joined(separator: " ")
        #expect(SpellChecker.words(text).count == SpellChecker.maxWords)
    }

    @Test func MisspellingsAreTheUnknownWordsWithTheirPlace() {
        let check = SpellChecker(WordList("the", "quick", "fox", "jumps"))
        let found = check.check("The quikc fox jumsp, NASA said.")
        #expect(found == [Misspelling(4, "quikc"), Misspelling(14, "jumsp"), Misspelling(26, "said")])
        #expect(SpellChecker.at(found, 9) == Misspelling(4, "quikc")) // the caret just after the word
        #expect(SpellChecker.at(found, 11) == nil)
    }

    @Test func AWordIsLookedUpOnce() {
        let words = WordList("fine")
        let check = SpellChecker(words)
        _ = check.check("fine fine wrng wrng")
        _ = check.check("fine wrng")
        #expect(words.lookups == 2)
    }

    @Test func IgnoreLastsForTheSession() {
        let check = SpellChecker(WordList("hello"))
        #expect(check.check("hello Inkvolt").count == 1)
        #expect(!check.isIgnored("Inkvolt"))
        check.ignore("Inkvolt")
        #expect(check.isIgnored("Inkvolt"))
        #expect(check.check("Inkvolt hello Inkvolt").isEmpty)
        #expect(check.check("inkvolt").count == 1) // as written: another spelling is another word
    }

    @Test func AddToDictionaryTeachesTheUsersDictionary() {
        let words = WordList("hello")
        let check = SpellChecker(words)
        #expect(check.check("Inkvolt").count == 1)
        #expect(check.add("Inkvolt"))
        #expect(words.added == ["Inkvolt"])
        #expect(check.check("Inkvolt").isEmpty)
        #expect(SpellChecker(words).check("Inkvolt").isEmpty) // the dictionary has it, not only this checker
    }

    @Test func AWordTheDictionaryRefusesStaysUnderlined() {
        let words = WordList("hello")
        words.refuses = true
        let check = SpellChecker(words)
        #expect(!check.add("Inkvolt"))
        #expect(check.check("Inkvolt").count == 1)
    }

    @Test func SuggestionsLeaveTheWordOutAndStopAtFive() {
        let check = SpellChecker(WordList("cart", "card", "care", "cars", "cast", "cash", "cats"))
        let s = check.suggestions("cazt")
        #expect(s.count == SpellChecker.maxSuggestions)
        #expect(!s.contains("cazt"))
    }

    @Test func ASuggestionReplacesTheWordOnlyWhereItStillIs() {
        let m = Misspelling(4, "quikc")
        #expect(SpellChecker.correct("The quikc fox", m, "quick") == "The quick fox")
        #expect(SpellChecker.correct("The quick fox", m, "quick") == nil) // typed over since
        #expect(SpellChecker.correct("The", m, "quick") == nil)
    }

    /// Windows' name; on the Mac the third language is the Mac's own.
    @Test func TheDocumentsLanguageComesFirstThenTheInterfacesInWindowsRegion() {
        #expect(SpellChecker.languages("fr-CA", "es", "es-MX") == ["fr-CA", "es-MX", "en-US"])
        #expect(SpellChecker.languages(nil, "es", "en-GB") == ["es-ES", "en-GB", "en-US"])
        #expect(SpellChecker.languages("", "en", "en-GB") == ["en-GB", "en-US"])
        #expect(SpellChecker.languages("en-us", "en", "de-DE") == ["en-US", "de-DE"])
    }

    @Test(arguments: ["x-klingon-and-more-than-thirty-five-chars", "en US", "<script>", "123"])
    func AHostileLanguageTagIsLeftOut(_ tag: String) {
        #expect(SpellChecker.languages(tag, "en", "en-US") == ["en-US"])
    }

    @Test func TheDocumentSaysItsLanguage() {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /Lang (es-MX) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ])
        #expect(SpellChecker.documentLanguage(pdf, nil) == "es-MX")
        #expect(SpellChecker.documentLanguage(TestPdf.make(1), nil) == nil)
        #expect(SpellChecker.documentLanguage([1, 2, 3], nil) == nil)
    }
}
