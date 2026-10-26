import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PrintCore
import Vision

/// A recognised word on a page, in the page's own fractions (0 to 1, origin bottom left, as Vision gives them).
public struct OcrWord: Equatable, Sendable {
    public var text: String
    public var box: CGRect
}

/// Scanned pages into a PDF (the Windows app's `PdfWriter`): each page the size the scan was at its resolution, its JPEG
/// drawn whole, and for a searchable PDF the recognised words as invisible text over where they are, so the file can be
/// searched and its text selected. Text recognition is Vision's, on this Mac (nothing leaves it). Call through `offPool`.
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

    public struct WriteError: Error {}

    public static func write(_ pages: [Page], title: String? = nil) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw WriteError() }
        var info: [CFString: Any] = [kCGPDFContextCreator: "Inkvolt Print"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let pdf = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else { throw WriteError() }
        for page in pages {
            guard let source = CGImageSourceCreateWithData(Data(page.jpeg) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WriteError() }
            let dpi = CGFloat(max(page.dpi, 1))
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(image, in: box)
            if let words = page.words { drawInvisible(words, in: box, pdf) }
            pdf.endPage()
        }
        pdf.closePDF()
        return data as Data
    }

    /// Each word as invisible text filling its box: the font sized to the box's height, stretched to its width.
    static func drawInvisible(_ words: [OcrWord], in page: CGRect, _ pdf: CGContext) {
        pdf.saveGState()
        pdf.setTextDrawingMode(.invisible)
        for word in words where !word.text.isEmpty {
            let rect = CGRect(x: word.box.minX * page.width, y: word.box.minY * page.height, width: word.box.width * page.width,
                              height: word.box.height * page.height)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
            let stretch = natural > 0 ? rect.width / natural : 1
            pdf.saveGState()
            pdf.scaleBy(x: stretch, y: 1)
            pdf.textMatrix = .identity
            pdf.textPosition = CGPoint(x: rect.minX / stretch, y: rect.minY + rect.height * 0.15)
            CTLineDraw(line, pdf)
            pdf.restoreGState()
        }
        pdf.restoreGState()
    }

    /// The words on a page, recognised by Vision on this Mac; nil when recognition fails (the page still saves, without text).
    public static func recognize(_ jpeg: [UInt8]) -> [OcrWord]? {
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
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
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
                guard let word, let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                words.append(OcrWord(text: word, box: box))
                placed = true
            }
            if !placed { words.append(OcrWord(text: text, box: observation.boundingBox)) }
        }
        return words
    }
}
