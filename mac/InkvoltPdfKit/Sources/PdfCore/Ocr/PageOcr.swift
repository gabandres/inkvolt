import Foundation

/// Text recognition of a page image (Vision's `VisionRecognizer` in the app; a fake in tests).
public protocol TextRecognizer: Sendable {
    /// The language it reads, as a BCP-47 tag ("en-US"); nil when it finds out for itself. Kept with the words for their
    /// review (the text layer's first line).
    var language: String? { get }

    /// The words on the image, in reading order, their boxes in the image's pixels (top-left origin).
    /// - Throws: `CancellationError` when `cancel` fires.
    func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord]

    /// The same words with their lines and the engine's confidence (a default reads `recognize`'s).
    func read(_ image: RenderedImage, cancel: CancelToken?) throws -> [RecognizedWord]
}

extension TextRecognizer {
    public var language: String? { nil }

    /// The words with their lines and the engine's confidence (Windows' `ITextRecognizer.Recognize`): `recognize`'s, each
    /// line the words that follow one another on one band of height, no confidence. Vision's own lines and confidence
    /// replace this (`VisionRecognizer`).
    public func read(_ image: RenderedImage, cancel: CancelToken?) throws -> [RecognizedWord] {
        RecognizedWord.inLines(try recognize(image, cancel: cancel))
    }
}

/// A word as an engine reads it (Windows' shared `RecognizedWord`): its text and box in the image's pixels, the index of
/// its line (words of a line are next to each other), and how sure the engine was of it (0 to 100) when it says.
public struct RecognizedWord: Equatable, Sendable {
    public var text: String
    public var rect: RectD
    public var line: Int
    public var confidence: Double?

    public init(_ text: String, _ rect: RectD, line: Int, confidence: Double? = nil) {
        self.text = text
        self.rect = rect
        self.line = line
        self.confidence = confidence
    }

    public var word: OcrWord { OcrWord(text, rect) }

    /// Words in reading order put in lines: a word starts a new line when it doesn't share most of the last one's height
    /// or lies left of it.
    public static func inLines(_ words: [OcrWord]) -> [RecognizedWord] {
        var line = 0
        var last: RectD?
        return words.map { w in
            if let l = last {
                let down = min(l.bottom, w.rect.bottom) - max(l.y, w.rect.y)
                if down < 0.5 * min(l.height, w.rect.height) || w.rect.x < l.x { line += 1 }
            }
            last = w.rect
            return RecognizedWord(w.text, w.rect, line: line)
        }
    }
}

/// The recognizer Core is given (pdf/GLOSSARY.md "Recognizer"; .NET's `Func<PdfEngine, int, CancellationToken,
/// IReadOnlyList<OcrWord>>`): the words of a page of an open document, in page space. Recognize Text uses it, and export
/// (D5c) will for pages without text.
public typealias Recognizer = @Sendable (PdfEngine, Int, CancelToken?) throws -> [OcrWord]

/// What Recognize Text did.
public struct RecognizeTextReport: Equatable, Sendable {
    /// Words recognized, on how many pages.
    public var words: Int
    public var pagesWithWords: Int
    /// Pages skipped because they already had text.
    public var hadText: Int
    /// Suspect words among them, and pages replaced with their cleaned image (Recognize Text with cleaning, roadmap 2.2).
    public var suspect: Int = 0
    public var replaced: Int = 0
    /// Pages the engine refused (too long to read, or too large to draw): skipped (from 0).
    public var skipped: [Int] = []
}

/// Recognize Text (OCR): pages rendered at 300 dpi and recognized, the words written as an invisible text layer (the
/// Windows app's `PageOcr` and `DocumentTab.RecognizeText`/`RecognizePages`).
public enum PageOcr {
    public static let dpi = 300.0
    /// Very large pages render at less than 300 dpi, within this many pixels (Windows' limit, below the engine's).
    public static let maxRenderPixels = min(60_000_000.0, PdfEngine.maxPixels)

    /// Pixels per point for recognizing a page.
    public static func scale(_ g: PageGeometry) -> Double {
        var scale = dpi / 72
        let area = g.width * g.height
        if area > 0 && area * scale * scale > maxRenderPixels { scale = (maxRenderPixels / area).squareRoot() }
        return scale
    }

    /// A page recognizer: renders the displayed page (its /Rotate applied, so the text is upright as the reader sees it)
    /// and maps the image's boxes back to page space.
    public static func recognizer(_ recognizer: some TextRecognizer) -> Recognizer {
        { engine, page, cancel in
            let g = engine.page(page)
            let image = try engine.render(page, scale: scale(g), cancel: cancel)
            guard image.width > 0, image.height > 0 else { return [] }
            let sx = g.width / Double(image.width), sy = g.height / Double(image.height)
            return try recognizer.recognize(image, cancel: cancel).map { w in
                OcrWord(w.text, RectD(w.rect.x * sx, w.rect.y * sy, w.rect.width * sx, w.rect.height * sy))
            }
        }
    }

    /// A page recognizer that reads as Recognize Text does (roadmap 2.2; the Windows app's `PageOcr.Recognize` with
    /// suspect words): each page through `ScanText` with `options` and `spelling`, so the words it marks as suspect stay
    /// marked (Batch keeps them in the text layer for review, export counts them). Nothing is written back: a cleaned
    /// image is never kept, so the words fit the page as it is.
    public static func recognizer(_ reader: some TextRecognizer, options: RecognizeOptions, spelling: (any Spelling)? = nil) -> Recognizer {
        var options = options
        options.keepCleanedImage = false
        let read = options
        return { engine, page, cancel in try ScanText.recognize(engine, page, reader, read, spelling: spelling, cancel: cancel).words }
    }

    /// Compare's recognizer for scanned pages (the Windows app's `PageOcr.Recognize`): each page cleaned first (straight
    /// and upright) through `ScanText`, no suspect words marked, nothing written back. `spelling`, the language's
    /// dictionary, says which way up a page the cleanup isn't sure of reads: without it, words read upside down pass for
    /// words.
    public static func compareRecognizer(_ reader: some TextRecognizer, spelling: (any Spelling)?) -> Recognizer {
        recognizer(reader, options: RecognizeOptions(clean: true, checkWords: false), spelling: spelling)
    }

    /// OCR of `pages`: pages that already have text are skipped, and pages the engine refuses (`skipped` says which);
    /// words mostly inside an `exclude` area (blacked-out redactions) are dropped. `progress` gets (pages done, pages to do).
    /// - Throws: `CancellationError` when `cancel` fires; the recognizer's errors.
    public static func recognizePages(_ data: [UInt8], _ password: String?, _ pages: [Int], _ recognize: Recognizer,
                                      exclude: [Int: [RectD]]? = nil, cancel: CancelToken? = nil, skipped: SkippedPages? = nil,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> (words: [Int: [OcrWord]], hadText: Int) {
        var result: [Int: [OcrWord]] = [:]
        var hadText = 0
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        let skipped = skipped ?? SkippedPages()
        for (i, page) in pages.enumerated() {
            try cancel.check()
            progress?(i, pages.count)
            guard page >= 0 && page < engine.pageCount, let has = try skipped.unlessRefused({ try TextLayer.hasText(engine, page, cancel: cancel) }) else { continue }
            if has {
                hadText += 1
                continue
            }
            guard var words = try skipped.unlessRefused({ try recognize(engine, page, cancel) }) else { continue }
            if let blacked = exclude?[page] {
                words.removeAll { w in blacked.contains { overlap(w.rect, $0) > 0.3 * w.rect.width * w.rect.height } }
            }
            if !words.isEmpty { result[page] = words }
        }
        progress?(pages.count, pages.count)
        return (result, hadText)
    }

    /// Recognize Text: the pages (nil: all) recognized and given an invisible text layer. The data comes back unchanged
    /// when nothing was recognized.
    public static func recognizeText(_ data: [UInt8], _ password: String?, pages: [Int]? = nil, _ recognize: Recognizer,
                                     cancel: CancelToken? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> ([UInt8], RecognizeTextReport) {
        let all: [Int]
        if let pages {
            all = pages
        } else {
            let engine = try PdfEngine.open(data, password: password)
            all = Array(0..<engine.pageCount)
            engine.close()
        }
        let skipped = SkippedPages()
        let (words, hadText) = try recognizePages(data, password, all, recognize, cancel: cancel, skipped: skipped, progress: progress)
        let report = RecognizeTextReport(words: words.values.reduce(0) { $0 + $1.count }, pagesWithWords: words.count, hadText: hadText,
                                         skipped: skipped.list)
        if report.words == 0 { return (data, report) }
        try cancel.check()
        return (try TextLayer.addInvisibleText(data, password, words), report)
    }

    /// Recognize Text with roadmap 2.2's pipeline (the Windows app's `DocumentTab.RecognizeText` and `RecognizePages`):
    /// each page through `ScanText` (cleaned, suspect words marked, its cleaned image kept when asked), the cleaned pages
    /// written back (`ScanPage`), then the words as an invisible text layer with the recognizer's language. Pages that
    /// already have text are skipped. The data comes back unchanged when nothing was recognized or replaced.
    /// - Throws: `CancellationError` when `cancel` fires; the recognizer's errors.
    public static func recognizeText(_ data: [UInt8], _ password: String?, pages: [Int]? = nil, recognizer: some TextRecognizer,
                                     options: RecognizeOptions, spelling: (any Spelling)? = nil, cancel: CancelToken? = nil,
                                     progress: ((Int, Int) -> Void)? = nil) throws -> ([UInt8], RecognizeTextReport) {
        var words: [Int: [OcrWord]] = [:]
        var cleaned: [Int: CleanedPageImage] = [:]
        var hadText = 0
        let engine = try PdfEngine.open(data, password: password)
        let chosen = pages ?? Array(0..<engine.pageCount)
        let skipped = SkippedPages()
        do {
            defer { engine.close() }
            for (i, page) in chosen.enumerated() {
                try cancel.check()
                progress?(i, chosen.count)
                guard page >= 0 && page < engine.pageCount, let has = try skipped.unlessRefused({ try TextLayer.hasText(engine, page, cancel: cancel) }) else { continue }
                if has {
                    hadText += 1
                    continue
                }
                guard let read = try skipped.unlessRefused({ try ScanText.recognize(engine, page, recognizer, options, spelling: spelling, cancel: cancel) }) else { continue }
                if !read.words.isEmpty { words[page] = read.words }
                if let image = read.cleaned { cleaned[page] = image }
            }
        }
        progress?(chosen.count, chosen.count)
        let all = words.values.flatMap { $0 }
        let report = RecognizeTextReport(words: all.count, pagesWithWords: words.count, hadText: hadText,
                                         suspect: all.filter { !$0.suspect.isEmpty }.count, replaced: cleaned.count, skipped: skipped.list)
        try cancel.check()
        var out = try ScanPage.writeBack(data, password, cleaned)
        if report.words > 0 { out = try TextLayer.addInvisibleText(out, password, words, language: recognizer.language) }
        return (out, report)
    }

    private static func overlap(_ a: RectD, _ b: RectD) -> Double {
        max(0, min(a.right, b.right) - max(a.x, b.x)) * max(0, min(a.bottom, b.bottom) - max(a.y, b.y))
    }
}
