import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PrintCore
import UniformTypeIdentifiers

/// Batch print's engines on the Mac (Windows' `WindowsBatchDocuments`): PDFKit for PDFs, Image I/O for pictures, over the file's
/// bytes as `BatchHeldFile` held them when it was opened, so what prints is what was fingerprinted. Hostile files are bounded
/// before anything is decoded: a picture's pixel size is read from its header (`BatchPrintLimits.pictureProblem`), a
/// TIFF's pages are counted, a PDF's pages are counted by `BatchMeasurer` against `maxPages`, a page is drawn at 300 dpi no
/// larger than 50 megapixels, a picture no longer than 4,200 pixels on its long side; the runner's time limits cover an
/// engine that hangs. A PDF that needs a password says so (`BatchPasswordError`), and `BatchMeasurer` tries one as Windows
/// does: the one given, then at most three asked for.
///
/// Mac difference: a PDF whose author doesn't allow printing (its permissions, which PDFKit reads) is left out with that
/// reason, as Preview won't print it either.
public struct MacBatchDocuments: BatchDocuments {
    public init() {}

    /// Windows' `QueuePrinter.RenderDpi`.
    public static let dpi = 300.0
    /// A drawn PDF page is never more pixels than this (Windows' `PdfSource.RenderAsync` bound).
    public static let maxPagePixels = 50_000_000.0
    /// A picture is drawn no longer than this on its long side: 14 in at 300 dpi, more than Legal paper shows.
    public static let maxEdge = 4200

    public func open(_ path: String, _ password: String?, _ stop: BatchStop) async throws -> any BatchDocument {
        let held = try BatchHeldFile.open(path)
        try stop.check()
        let data = Data(held.bytes)
        if Self.isPdf(held.bytes) {
            guard let pdf = PDFDocument(data: data) else { throw BatchFileError("This PDF can't be read: it may be damaged.") }
            if pdf.isLocked {
                guard let password, pdf.unlock(withPassword: password) else { throw BatchPasswordError() }
            }
            if !pdf.allowsPrinting { throw BatchFileError("This PDF's author doesn't allow printing it.") }
            return PdfBatchDocument(held.fingerprint, pdf)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else {
            throw BatchFileError("This picture can't be read: it may be damaged, or not a kind macOS reads.")
        }
        // A TIFF's pages print one by one; other kinds (an animated GIF, a HEIC's extra pictures) print their first picture.
        let isTiff = UTType(type)?.conforms(to: .tiff) == true
        let count = isTiff ? CGImageSourceGetCount(source) : min(1, CGImageSourceGetCount(source))
        if count < 1 { throw BatchFileError("This picture can't be read: it may be damaged.") }
        if count > BatchPrintLimits.maxPages { return PictureBatchDocument(held.fingerprint, source, count: count) } // the measurer says why
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value ?? 0
            if let problem = BatchPrintLimits.pictureProblem(width, height) { throw BatchFileError(problem) }
        }
        return PictureBatchDocument(held.fingerprint, source, count: count)
    }

    /// "%PDF-" in the first kilobyte, where the format allows it to start.
    static func isPdf(_ bytes: [UInt8]) -> Bool {
        let head = bytes.prefix(1024)
        let mark = Array("%PDF-".utf8)
        guard head.count >= mark.count else { return false }
        return (head.startIndex...(head.endIndex - mark.count)).contains { Array(head[$0..<$0 + mark.count]) == mark }
    }

    /// A drawn page as a JPEG, quality as the scans are saved.
    static func jpeg(_ image: CGImage) throws -> [UInt8] {
        do {
            return try ScanImaging.jpeg(image)
        } catch {
            throw BatchFileError("A page couldn't be prepared for printing.")
        }
    }
}

/// A PDF open for printing. PDFKit's document isn't for two threads at once: pages are drawn one at a time.
final class PdfBatchDocument: BatchDocument, @unchecked Sendable {
    let fingerprint: BatchFingerprint
    private let pdf: PDFDocument
    private let lock = NSLock()

    init(_ fingerprint: BatchFingerprint, _ pdf: PDFDocument) {
        self.fingerprint = fingerprint
        self.pdf = pdf
    }

    var pageCount: Int { lock.withLock { pdf.pageCount } }
    var sizing: PageSizing { .actualSize }

    func render(_ page: Int, _ stop: BatchStop) async throws -> BatchPrintPage {
        try stop.check()
        return try lock.withLock {
            guard page >= 1, page <= pdf.pageCount, let p = pdf.page(at: page - 1) else { throw BatchFileError("Page \(page) can't be drawn.") }
            let box = p.bounds(for: .mediaBox)
            let turned = abs(p.rotation) % 180 == 90
            let width = Double(turned ? box.height : box.width), height = Double(turned ? box.width : box.height)
            guard width > 0, height > 0, width < 14_400, height < 14_400 else { throw BatchFileError("Page \(page) has no size a printer can take.") }
            var scale = MacBatchDocuments.dpi / 72
            let pixels = width * scale * height * scale
            if pixels > MacBatchDocuments.maxPagePixels { scale *= (MacBatchDocuments.maxPagePixels / pixels).squareRoot() }
            let w = max(1, Int(width * scale)), h = max(1, Int(height * scale)) // bounded: under 14,400 pt at most 300 dpi, checked above
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw BatchFileError("Page \(page) can't be drawn.") }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            p.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { throw BatchFileError("Page \(page) can't be drawn.") }
            return BatchPrintPage(try MacBatchDocuments.jpeg(image), width / 72, height / 72)
        }
    }

    func close() {}
}

/// A picture (or a TIFF's pages) open for printing: decoded page by page, upright as its orientation says, at most
/// `maxEdge` pixels long, filling the paper.
final class PictureBatchDocument: BatchDocument, @unchecked Sendable {
    let fingerprint: BatchFingerprint
    let pageCount: Int
    private let source: CGImageSource
    private let lock = NSLock()

    init(_ fingerprint: BatchFingerprint, _ source: CGImageSource, count: Int) {
        self.fingerprint = fingerprint
        self.source = source
        pageCount = count
    }

    var sizing: PageSizing { .fitToPaper }

    func render(_ page: Int, _ stop: BatchStop) async throws -> BatchPrintPage {
        try stop.check()
        return try lock.withLock {
            let index = page - 1
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let what = pageCount > 1 ? "Page \(page) of the picture" : "The picture"
            guard index >= 0, index < pageCount, width > 0, height > 0 else { throw BatchFileError("\(what) can't be drawn.") }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), MacBatchDocuments.maxEdge),
                                            kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw BatchFileError("\(what) can't be drawn.") }
            // Drawn on white: a picture with see-through parts prints as it looks.
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw BatchFileError("\(what) can't be drawn.")
            }
            let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(all)
            context.draw(image, in: all)
            guard let flat = context.makeImage() else { throw BatchFileError("\(what) can't be drawn.") }
            return BatchPrintPage(try MacBatchDocuments.jpeg(flat), Double(image.width) / MacBatchDocuments.dpi, Double(image.height) / MacBatchDocuments.dpi)
        }
    }

    func close() {}
}
