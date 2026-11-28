import Foundation
import Testing
import PrintCore
@testable import PdfCore

/// Ported from TesseractTests.cs, its "Two languages on a page" and "Through Recognize Text's pipeline" parts (roadmap
/// 2.2), under Windows' names: two recognizers read the page and each line is kept from the language that reads it better
/// (`MixedRecognizer`), the spell checkers answer together (`EitherSpelling`), the text layer keeps both tags, and a word
/// the engine was unsure of is a suspect word. The Mac has no Tesseract (the owner, 2026-11-27): both readings are
/// Vision's, one language each; the rest of that file (the download, the TSV, the engine's process) stays Windows'.
struct MixedLanguagesTests {
    private struct WordList: Spelling {
        let language: String
        let words: Set<String>
        init(_ language: String, _ words: String...) {
            self.language = language
            self.words = Set(words)
        }
        func isKnown(_ word: String) -> Bool { words.contains(word.lowercased()) }
        func suggest(_ word: String) -> [String] { [] }
    }

    private final class Fixed: TextRecognizer, @unchecked Sendable {
        private(set) var calls = 0
        let tag: String
        let words: [RecognizedWord]
        init(_ tag: String, _ words: RecognizedWord...) {
            self.tag = tag
            self.words = words
        }
        var language: String? { tag }
        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] { try read(image, cancel: cancel).map(\.word) }
        func read(_ image: RenderedImage, cancel: CancelToken?) throws -> [RecognizedWord] {
            calls += 1
            return words
        }
    }

    private static func w(_ text: String, _ x: Double, _ y: Double, _ line: Int, _ confidence: Double? = nil) -> RecognizedWord {
        RecognizedWord(text, RectD(x, y, 40, 20), line: line, confidence: confidence)
    }

    private static let english = WordList("en-US", "the", "black", "cat", "sleeps", "here")
    private static let spanish = WordList("es-MX", "el", "gato", "negro", "duerme", "aquí")

    @Test func eachLineIsKeptFromTheLanguageThatReadsItBetter() {
        // Line 1 English, line 2 Spanish; each recognizer garbles the other language's line.
        let english = [Self.w("The", 10, 10, 0), Self.w("black", 60, 10, 0), Self.w("cat", 110, 10, 0), Self.w("Ei", 10, 50, 1), Self.w("gato", 60, 50, 1), Self.w("negr0", 110, 50, 1)]
        let spanish = [Self.w("Tbe", 10, 11, 0), Self.w("blaek", 60, 11, 0), Self.w("cat", 110, 11, 0), Self.w("El", 10, 51, 1), Self.w("gato", 60, 51, 1),
                       Self.w("negro", 110, 51, 1), Self.w("aquí", 10, 90, 2)]
        var chosen = MixedRecognizer.choose(english, Self.english, spanish, Self.spanish)
        #expect(chosen.map(\.text) == ["The", "black", "cat", "El", "gato", "negro", "aquí"])
        #expect(chosen.map(\.line) == [0, 0, 0, 1, 1, 1, 2])

        // A tie stays with the first language; a line only the second read is kept in its place.
        chosen = MixedRecognizer.choose([Self.w("1234", 10, 10, 0), Self.w("here", 10, 90, 1)], Self.english,
                                        [Self.w("1284", 10, 10, 0), Self.w("aquí", 10, 50, 1)], Self.spanish)
        #expect(chosen.map(\.text) == ["1234", "aquí", "here"])
    }

    @Test func withoutADictionaryTheEnginesConfidenceDecides() {
        let chosen = MixedRecognizer.choose([Self.w("नमस्ते", 10, 10, 0, 35)], nil, [Self.w("नमस्ते", 10, 10, 0, 92), Self.w("दुनिया", 60, 10, 0, 90)], nil)
        #expect(chosen.count == 2)
        #expect(chosen.first?.confidence == 92)
        #expect(MixedRecognizer.plausibility(Self.w("cat", 0, 0, 0), Self.english) > MixedRecognizer.plausibility(Self.w("cat", 0, 0, 0), nil))
        #expect(MixedRecognizer.plausibility(Self.w("1234", 0, 0, 0, 99), nil) == 0)
    }

    @Test func garbageNeverOutweighsANameTheDictionaryLacks() {
        // "rn,1l" and "negr0" are a recognizer misreading; "Zbigniew" is a name no dictionary knows.
        let name = MixedRecognizer.plausibility(Self.w("Zbigniew", 0, 0, 0), Self.english)
        #expect(MixedRecognizer.plausibility(Self.w("rn,1l", 0, 0, 0), Self.english) < name / 4)
        #expect(MixedRecognizer.plausibility(Self.w("negr0rnk", 0, 0, 0), nil) < name)
        #expect(name < MixedRecognizer.plausibility(Self.w("sleeps", 0, 0, 0), Self.english) * 8 / 6)
        // A line of garbage loses to the same line read as a name and words.
        let chosen = MixedRecognizer.choose([Self.w("Zbigniew", 10, 10, 0), Self.w("sleeps", 60, 10, 0)], Self.english,
                                            [Self.w("Zb1g,n1ew", 10, 10, 0), Self.w("s1eeps", 60, 10, 0)], Self.spanish)
        #expect(chosen.map(\.text) == ["Zbigniew", "sleeps"])
    }

    /// Adapted: Windows' mixed recognizer names its first language and its page recognizer both ("en-US+es-MX"); the Mac's
    /// recognizer is what the text layer is written with, so it names both. No re-reader (the Mac has no `MissedLines`).
    @Test func twoRecognizersReadThePageAndTheSpellingsAnswerTogether() throws {
        let first = Fixed("en-US", Self.w("cat", 10, 10, 0))
        let second = Fixed("es-MX", Self.w("cta", 10, 10, 0))
        let mixed = MixedRecognizer(first, Self.english, second, Self.spanish)
        #expect(mixed.language == "en-US+es-MX")
        #expect(MixedRecognizer.languagesOf(mixed) == ["en-US", "es-MX"])
        #expect(try mixed.recognize(RenderedImage(1, 1, [0, 0, 0]), cancel: nil).map(\.text) == ["cat"])
        #expect((first.calls, second.calls) == (1, 1))

        let either = try #require(EitherSpelling.of(Self.english, Self.spanish))
        #expect(either.isKnown("gato") && either.isKnown("cat"))
        #expect(!either.isKnown("chat"))
        #expect(EitherSpelling.of(Self.english, nil)?.language == "en-US")
        #expect(EitherSpelling.of(Self.english, nil) is WordList)
    }

    @Test func aTextLayerKeepsBothLanguagesOfAPageInTwo() throws {
        let pdf = ExportTestPdf.blank(1)
        let data = try TextLayer.addInvisibleText(pdf, nil, [0: [OcrWord("gato", RectD(72, 72, 40, 12))]], language: "en-US+es-MX")
        #expect(try TextLayer.words(data, nil)[0]?.language == "en-US+es-MX")
    }

    /// An engine's way of saying how sure it is: one word under its threshold, one over.
    private final class SureOfNothing: TextRecognizer, @unchecked Sendable {
        private(set) var calls = 0
        var language: String? { "hi" }
        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] { try read(image, cancel: cancel).map(\.word) }
        func read(_ image: RenderedImage, cancel: CancelToken?) throws -> [RecognizedWord] {
            calls += 1
            let (w, h) = (Double(image.width), Double(image.height))
            return [RecognizedWord("नमस्ते", RectD(w * 0.1, h * 0.1, w * 0.2, h * 0.02), line: 0, confidence: 31),
                    RecognizedWord("दुनिया", RectD(w * 0.4, h * 0.1, w * 0.2, h * 0.02), line: 0, confidence: 95)]
        }
    }

    /// Adapted: on Windows an engine whose words carry a confidence (Tesseract) isn't asked again for the page as scanned;
    /// Vision's confidence is a line's and was 1.0 on every corpus line (`VisionProbeTests.visionConfidenceOnTheCorpus`),
    /// so the Mac still compares the two readings and marks unsure words besides. Vision's threshold is Windows' 60.
    @Test(.enabled(if: ScanCorpus.runs)) func aWordTheEngineWasUnsureOfIsASuspectAndNothingIsReadAgain() throws {
        var file = ScanCorpus.file("en-skew3-light")
        file.pages = 1
        let pdf = try PdfEngine.open(ScanCorpus.make(file).pdf)
        defer { pdf.close() }
        let reader = SureOfNothing()
        let words = try ScanText.recognize(pdf, 0, reader, RecognizeOptions()).words
        #expect(words[0].suspect.contains(.unsure))
        #expect(!words[1].suspect.contains(.unsure))
        // The cleaned page (once more if it can't tell which way up), and the page as scanned to compare.
        #expect(reader.calls >= 2 && reader.calls <= 3)
        var plainOptions = RecognizeOptions.asScanned
        plainOptions.checkWords = true
        let plain = try ScanText.recognize(pdf, 0, SureOfNothing(), plainOptions).words
        #expect(plain[0].suspect.contains(.unsure))
        #expect(VisionRecognizer().unsureBelow == SuspectWords.unsureBelow && SuspectWords.unsureBelow == 60)
        let mixed = MixedRecognizer(VisionRecognizer(languages: ["en-US"]), nil, VisionRecognizer(languages: ["es-ES"]), nil)
        #expect(mixed.unsureBelow == 60)
    }

    /// Mac only: a recognizer that gives no lines of its own (a stand-in's words) has them put in lines by place.
    @Test func wordsWithoutLinesArePutInLinesByPlace() {
        let lines = RecognizedWord.inLines([OcrWord("a", RectD(10, 10, 20, 10)), OcrWord("b", RectD(40, 11, 20, 10)),
                                            OcrWord("c", RectD(10, 30, 20, 10)), OcrWord("d", RectD(5, 31, 20, 10))])
        #expect(lines.map(\.line) == [0, 0, 1, 2])
    }
}
