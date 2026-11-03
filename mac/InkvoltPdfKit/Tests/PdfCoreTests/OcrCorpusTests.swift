import Foundation
import Testing
@testable import PdfCore

/// Ported from OcrCorpusTests.cs: the OCR corpus's generator and its measure (`ScanCorpus`, `WordErrorRate`): the numbers
/// beside the corpus rest on them.
struct OcrCorpusTests {
    @Test func wordErrorRateCountsSubstitutionsDeletionsAndInsertions() {
        let truth = ["the", "river", "año", "1234.50"]
        #expect(WordErrorRate.of(truth, truth) == 0)
        #expect(WordErrorRate.of(truth, ["the", "rlver", "año", "1234.50"]) == 0.25) // one substituted
        #expect(WordErrorRate.of(truth, ["the", "año", "1234.50"]) == 0.25) // one missed
        #expect(WordErrorRate.of(truth, ["the", "river", "a", "año", "1234.50"]) == 0.25) // one extra
        #expect(WordErrorRate.of(truth, ["the", "river", "ano", "1234.50"]) == 0.25) // accents count
        #expect(WordErrorRate.of(truth, []) == 1)
        #expect(WordErrorRate.of(["a", "b"], ["x", "y", "z"]) == 1.5)
        #expect(WordErrorRate.words(" Total:  €1,234\nrío ") == ["Total:", "€1,234", "río"])
    }

    @Test(.enabled(if: ScanCorpus.runs)) func theCorpusIsTheSameEveryTime() throws {
        var file = ScanCorpus.files[0]
        file.pages = 1
        let (first, truth) = try ScanCorpus.make(file)
        let (second, _) = try ScanCorpus.make(file)
        #expect(ScanCorpus.sha256(first) == ScanCorpus.sha256(second))

        try #require(truth.count == 1)
        #expect(truth[0].words.count > 250, "\(truth[0].words.count) words")
        let engine = try PdfEngine.open(first)
        defer { engine.close() }
        #expect(engine.pageCount == 1)
        #expect(!(try engine.text(0).text.contains { $0.isLetter })) // a scan: no text to find until it's recognized
    }

    @Test(.enabled(if: ScanCorpus.runs)) func theCorpusHasTwoLanguagesAndTheRoadmapsSkews() throws {
        #expect(Set(ScanCorpus.files.map(\.language)).sorted() == ["en", "es"])
        #expect(ScanCorpus.files.allSatisfy { $0.minSkew >= 3 && $0.minSkew <= 10 && $0.maxSkew >= 3 && $0.maxSkew <= 10 })
        let spanish = try ScanCorpus.makePage(ScanCorpus.files.first { $0.language == "es" }!, 0).truth
        #expect(spanish.words.contains { $0.contains { "áéíóúñü".contains($0) } })
    }
}
