import Foundation
import Testing
@testable import PdfCore

/// Not a port (Windows' recognizer is the app's `PageOcr`, without tests of its own): Recognize Text on the Mac, with
/// Apple's Vision on TestPdf's pages drawn as pictures (`TextLayerTests.scanned`), and with a fake recognizer for the
/// parts that don't need Vision (skipping pages with text, excluded areas, cancelling).
@Suite(.timeLimit(.minutes(3))) struct OcrTests {
    /// Vision's recognizer never answers on GitHub's macOS runners (virtual machines): the tests that call it hung the
    /// `pdf` job until its time limit. They run on a real Mac.
    static let visionAnswers = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil

    /// A recognizer that returns fixed words in image pixels (scaled from page points at 300 dpi), and counts its calls.
    final class Fake: TextRecognizer, @unchecked Sendable {
        let words: [OcrWord]
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }

        init(_ words: [OcrWord]) { self.words = words }

        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            try cancel.check()
            lock.withLock { _calls += 1 }
            let s = PageOcr.dpi / 72
            return words.map { OcrWord($0.text, RectD($0.rect.x * s, $0.rect.y * s, $0.rect.width * s, $0.rect.height * s)) }
        }
    }

    /// MuPDF's box of `word` on the page (the union of its characters).
    static func box(_ data: [UInt8], _ page: Int, _ word: String) throws -> RectD? {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let t = try engine.text(page)
        guard let hit = t.find(word, matchCase: false, wholeWord: true).first else { return nil }
        return TextLayerTests.box(t, hit.start, hit.end)
    }

    @Test(.enabled(if: visionAnswers), arguments: [0, 90]) func visionReadsTheScannedPageWhereTheTextIs(rotate: Int) throws {
        let scan = try TextLayerTests.scanned(rotate)
        var original = TestPdf.make(1)
        if rotate != 0 { original = try PageEditor.rotate(original, nil, [0], rotate) }
        let engine = try PdfEngine.open(scan)
        defer { engine.close() }
        let words = try PageOcr.recognizer(VisionRecognizer())(engine, 0, nil)
        let texts = words.map { $0.text.lowercased() }
        for expected in ["quick", "brown", "fox", "jumps", "over", "lazy", "dog"] {
            #expect(texts.contains(expected), "\(expected) in \(texts)")
        }
        // Each word's box lies where MuPDF has the word in the original (within a few points: Vision's boxes are its own).
        for word in ["quick", "brown", "jumps", "lazy"] {
            guard let got = words.first(where: { $0.text.lowercased() == word }), let want = try Self.box(original, 0, word) else { continue }
            #expect(abs(got.rect.centerX - want.centerX) < 4 && abs(got.rect.centerY - want.centerY) < 4, "\(word) \(got.rect) vs \(want)")
            #expect(abs(got.rect.width - want.width) < 8, "\(word) \(got.rect) vs \(want)")
        }
    }

    @Test(.enabled(if: visionAnswers)) func recognizeTextMakesTheScanSearchableAndSkipsPagesWithText() throws {
        let scan = try TextLayerTests.scanned(0)
        let doc = try PageEditor.insert(scan, nil, PdfSource(TestPdf.make(1, marker: "beta"), nil, "text.pdf"), nil, 1)
        var steps: [Int] = []
        let (data, report) = try PageOcr.recognizeText(doc, nil, PageOcr.recognizer(VisionRecognizer())) { done, _ in steps.append(done) }
        #expect(report.hadText == 1)
        #expect(report.pagesWithWords == 1)
        #expect(report.words >= 10)
        #expect(steps.last == 2)
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let text = try engine.text(0)
        #expect(text.text.lowercased().contains("quick brown fox"), "\(text.text)")
        #expect(text.text.lowercased().contains("lazy dog"), "\(text.text)")
        // The recognized words sit where the original text was (Vision's word boxes are a few points loose: within 8).
        let got = try #require(try Self.box(data, 0, "quick")), want = try #require(try Self.box(TestPdf.make(1), 0, "quick"))
        #expect(abs(got.centerX - want.centerX) < 4 && abs(got.centerY - want.centerY) < 4 && abs(got.width - want.width) < 8, "\(got) vs \(want)")
        // And the page looks the same.
        let a = try PdfEngine.open(doc)
        defer { a.close() }
        #expect(try a.render(0, scale: 1).pixels == engine.render(0, scale: 1).pixels)
    }

    @Test func excludedAreasAndPagesOutOfRangeAreLeftOut() throws {
        let scan = try TextLayerTests.scanned(0)
        let fake = Fake([OcrWord("kept", RectD(72, 72, 40, 12)), OcrWord("hidden", RectD(300, 300, 40, 12))])
        let (words, hadText) = try PageOcr.recognizePages(scan, nil, [0, 5], PageOcr.recognizer(fake), exclude: [0: [RectD(290, 290, 100, 40)]])
        #expect(hadText == 0)
        #expect(words[0]?.map(\.text) == ["kept"])
        #expect(abs((words[0]?[0].rect.x ?? 0) - 72) < 0.5)
        #expect(fake.calls == 1)
    }

    @Test func nothingRecognizedLeavesTheFileAsItWas() throws {
        let scan = try TextLayerTests.scanned(0)
        let (data, report) = try PageOcr.recognizeText(scan, nil, PageOcr.recognizer(Fake([])))
        #expect(data == scan)
        #expect(report == RecognizeTextReport(words: 0, pagesWithWords: 0, hadText: 0))
    }

    @Test(.enabled(if: visionAnswers)) func cancelStopsRecognition() throws {
        let scan = try TextLayerTests.scanned(0)
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try PageOcr.recognizeText(scan, nil, PageOcr.recognizer(VisionRecognizer()), cancel: cancel)
        }
        let engine = try PdfEngine.open(scan)
        defer { engine.close() }
        let image = try engine.render(0, scale: 1)
        #expect(throws: CancellationError.self) { _ = try VisionRecognizer().recognize(image, cancel: cancel) }
    }

    @Test func pagesTooLargeFor300DpiRenderWithinTheLimit() {
        #expect(PageOcr.scale(PageGeometry(0, 0, 612, 792)) == 300.0 / 72)
        let huge = PageGeometry(0, 0, 14_400, 14_400)
        let s = PageOcr.scale(huge)
        #expect(huge.width * huge.height * s * s <= PageOcr.maxRenderPixels * 1.0001)
    }
}
