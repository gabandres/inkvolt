import CoreGraphics
import Foundation
import PDFKit
import PrintCore

/// The pages of a scanner's PDF that aren't one JPEG picture, drawn by PDFKit (the engine Print a PDF uses) at the scan's
/// resolution on white, each a JPEG (`ScannerPdf.renderer`, set at start-up; the Windows app's `ScannedPdfPages`).
public struct ScannedPdfPages: PdfPageRenderer {
    /// Bigger than any scanner's page at its highest resolution (a legal page at 1200 dpi is 10,200 × 16,800 px): a PDF
    /// asking for more is refused rather than filling memory.
    static let maxPixels = 200_000_000

    public init() {}

    public func render(_ pdf: [UInt8], dpi: Int) async throws -> [[UInt8]] {
        try await offPool { Result { try Self.pages(pdf, dpi: dpi) } }.get()
    }

    static func pages(_ pdf: [UInt8], dpi: Int) throws -> [[UInt8]] {
        guard let document = PDFDocument(data: Data(pdf)), !document.isLocked else { throw ScanError("The scanner's PDF couldn't be opened.") }
        var pages: [[UInt8]] = []
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: i)?.pageRef else { throw ScanError("The scanner's PDF has a page that couldn't be read.") }
            pages.append(try ScanImaging.jpeg(draw(page, dpi: dpi)))
        }
        return pages
    }

    /// The page as it shows (its turn applied) at `dpi`.
    static func draw(_ page: CGPDFPage, dpi: Int) throws -> CGImage {
        let box = page.getBoxRect(.mediaBox)
        let turned = (page.rotationAngle / 90 % 2 + 2) % 2 == 1
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(max(dpi, 1)) / 72
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard width * height <= maxPixels, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScanError("The scanner's PDF has a page too large to show.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // The transform takes the page's box (and its /Rotate) onto the turned size, never scaling it.
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ScanError("The scanner's PDF has a page that couldn't be drawn.") }
        return image
    }
}
