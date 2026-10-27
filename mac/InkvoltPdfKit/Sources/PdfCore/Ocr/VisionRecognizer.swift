import CoreGraphics
import Foundation
import Vision

/// Text recognition with Apple's Vision, on this Mac (nothing leaves it), as Inkvolt Print's searchable scans
/// (`ScanPdf.recognize`): `VNRecognizeTextRequest` at the accurate level with language correction. With no languages
/// given, Vision detects the language itself (Windows uses the first of the user's display languages with an OCR pack).
/// Words are the recognized lines split at whitespace, each with Vision's box for its characters, so punctuation stays
/// with its word as in Windows' OCR.
public struct VisionRecognizer: TextRecognizer {
    /// Vision's language codes ("en-US", "es-ES") in order of preference; nil detects the language.
    public var languages: [String]?

    public init(languages: [String]? = nil) { self.languages = languages }

    /// The languages Vision recognizes at the accurate level.
    public static var supportedLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    public func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
        try cancel.check()
        guard let cg = Self.cgImage(image) else { throw PdfEngineError(message: "The page image can't be read for text recognition.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages, !languages.isEmpty {
            request.recognitionLanguages = languages
        } else {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let id = cancel?.register { request.cancel() }
        defer { cancel?.unregister(id) }
        do {
            try handler.perform([request])
        } catch {
            try cancel.check()
            throw PdfEngineError(message: "Text recognition failed: \(error.localizedDescription)")
        }
        try cancel.check()

        let w = Double(image.width), h = Double(image.height)
        func pixels(_ box: CGRect) -> RectD {
            // Vision's boxes are fractions of the image with the origin at the bottom left.
            RectD(Double(box.minX) * w, (1 - Double(box.maxY)) * h, Double(box.width) * w, Double(box.height) * h)
        }
        var words: [OcrWord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            var start: String.Index?
            var i = line.startIndex
            while i <= line.endIndex {
                let atSpace = i == line.endIndex || line[i].isWhitespace
                if atSpace, let s = start {
                    let range = s..<i
                    let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                    words.append(OcrWord(String(line[range]), pixels(box)))
                    start = nil
                } else if !atSpace && start == nil {
                    start = i
                }
                if i == line.endIndex { break }
                i = line.index(after: i)
            }
        }
        return words
    }

    /// The RGB pixels as a Core Graphics image (no copy of the bytes beyond the data provider's).
    static func cgImage(_ image: RenderedImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.pixels.count >= image.stride * image.height,
              let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: image.stride,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
