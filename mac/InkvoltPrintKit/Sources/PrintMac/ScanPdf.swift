import CoreGraphics
import Foundation
import ImageIO
import PrintCore
import Vision

/// A recognised word on a page, in the page's own fractions (0 to 1, origin bottom left, as Vision gives them).
public struct OcrWord: Equatable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Scanned pages into a PDF through PrintCore's `PdfWriter` (the Windows app's writer, ported as is): each page the size the
/// scan was at its resolution, its JPEG embedded as it is, and for a searchable PDF the recognised words as an invisible
/// text layer in a CID font with a /ToUnicode map, so the file can be searched and its text selected in any script. Text
/// recognition is Vision's, on this Mac (nothing leaves it). Call through `offPool`.
public enum ScanPdf {
    public struct Page: Sendable {
        public var jpeg: [UInt8]
        public var dpi: Int
        public var words: [OcrWord]?

        public init(jpeg: [UInt8], dpi: Int, words: [OcrWord]? = nil) {
            self.jpeg = jpeg
            self.dpi = dpi
            self.words = words
        }
    }

    public static func write(_ pages: [Page], title: String? = nil) throws -> Data {
        let written = try pages.map { page -> PdfWriter.Page in
            guard let words = page.words else { return PdfWriter.Page(page.jpeg, dpi: page.dpi) }
            let size = try PdfWriter.jpegInfo(page.jpeg)
            return PdfWriter.Page(page.jpeg, dpi: page.dpi, words: pixelWords(words, width: size.width, height: size.height))
        }
        return Data(try PdfWriter.write(written, title: title))
    }

    /// Vision's words (fractions of the image from its bottom left) in the image's pixels from its top left, as `PdfWriter`
    /// takes them. A box that isn't a number is left out.
    public static func pixelWords(_ words: [OcrWord], width: Int, height: Int) -> [PdfWriter.Word] {
        let (w, h) = (Double(width), Double(height))
        return words.compactMap { word in
            let b = word.box
            let x = Double(b.minX) * w, y = (1 - Double(b.maxY)) * h
            let bw = Double(b.width) * w, bh = Double(b.height) * h
            guard x.isFinite, y.isFinite, bw.isFinite, bh.isFinite else { return nil }
            return PdfWriter.Word(word.text, x: x, y: y, width: bw, height: bh)
        }
    }

    /// The languages Vision reads text in on this Mac (`VNRecognizeTextRequest`, accurate), each with its name in the
    /// user's language: the Text language choice, after Automatic.
    public static func textLanguages() -> [(tag: String, name: String)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let tags = (try? request.supportedRecognitionLanguages()) ?? []
        return tags.map { tag in (tag, Locale.current.localizedString(forIdentifier: tag) ?? tag) }
    }

    /// Vision's tag for a Text language a preset or the settings name (`wanted`), among `supported`: the same tag, else the
    /// first with its language ("ru", as Windows' presets name it, is Vision's "ru-RU"); nil when Vision doesn't read it.
    public static func visionTag(_ wanted: String, among supported: [String]) -> String? {
        let tag = wanted.replacingOccurrences(of: "_", with: "-")
        if let same = supported.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return same }
        func language(_ t: String) -> Substring { t.split(separator: "-", maxSplits: 1).first ?? "" }
        let wantedLanguage = language(tag).lowercased()
        if wantedLanguage.isEmpty { return nil }
        return supported.first { language($0).lowercased() == wantedLanguage }
    }

    /// The words on a page, recognised by Vision on this Mac in `language` (a BCP-47 tag, matched to Vision's by
    /// `visionTag`; nil or not read here: Vision tells the language itself); nil when recognition fails (the page still
    /// saves, without text), as for a page too large to clean up (`ScanImaging.decode`: never decoded at full size).
    public static func recognize(_ jpeg: [UInt8], language: String? = nil) -> [OcrWord]? {
        guard let image = try? ScanImaging.decode(jpeg, maxPixels: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language, let supported = try? request.supportedRecognitionLanguages(), let tag = visionTag(language, among: supported) {
            request.recognitionLanguages = [tag]
        } else {
            request.automaticallyDetectsLanguage = true
        }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        var words: [OcrWord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var placed = false
            for range in wordRanges(text) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                words.append(OcrWord(text: String(text[range]), box: box))
                placed = true
            }
            if !placed && !text.isEmpty { words.append(OcrWord(text: text, box: observation.boundingBox)) }
        }
        return words
    }

    /// A recognised line's words: what lies between its spaces, punctuation and hyphens kept (Windows' recognizer gives
    /// "lid:" and "демо-сканера" as words; cutting by word boundaries dropped them, so "демо-сканера" couldn't be found).
    public static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for i in text.indices {
            if text[i].isWhitespace {
                if let s = start { ranges.append(s..<i) }
                start = nil
            } else if start == nil {
                start = i
            }
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }
}
