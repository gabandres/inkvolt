import Foundation

/// Text recognition of a page image (Vision's `VisionRecognizer` in the app; a fake in tests).
public protocol TextRecognizer: Sendable {
    /// The words on the image, in reading order, their boxes in the image's pixels (top-left origin).
    /// - Throws: `CancellationError` when `cancel` fires.
    func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord]
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

    /// OCR of `pages`: pages that already have text are skipped; words mostly inside an `exclude` area (blacked-out
    /// redactions) are dropped. `progress` gets (pages done, pages to do).
    /// - Throws: `CancellationError` when `cancel` fires; the recognizer's errors.
    public static func recognizePages(_ data: [UInt8], _ password: String?, _ pages: [Int], _ recognize: Recognizer,
                                      exclude: [Int: [RectD]]? = nil, cancel: CancelToken? = nil,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> (words: [Int: [OcrWord]], hadText: Int) {
        var result: [Int: [OcrWord]] = [:]
        var hadText = 0
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        for (i, page) in pages.enumerated() {
            try cancel.check()
            progress?(i, pages.count)
            guard page >= 0 && page < engine.pageCount else { continue }
            if try TextLayer.hasText(engine, page, cancel: cancel) {
                hadText += 1
                continue
            }
            var words = try recognize(engine, page, cancel)
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
        let (words, hadText) = try recognizePages(data, password, all, recognize, cancel: cancel, progress: progress)
        let report = RecognizeTextReport(words: words.values.reduce(0) { $0 + $1.count }, pagesWithWords: words.count, hadText: hadText)
        if report.words == 0 { return (data, report) }
        try cancel.check()
        return (try TextLayer.addInvisibleText(data, password, words), report)
    }

    private static func overlap(_ a: RectD, _ b: RectD) -> Double {
        max(0, min(a.right, b.right) - max(a.x, b.x)) * max(0, min(a.bottom, b.bottom) - max(a.y, b.y))
    }
}
