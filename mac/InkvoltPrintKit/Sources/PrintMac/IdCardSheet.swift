import CoreGraphics
import Foundation
import ImageIO
import PrintCore

/// The ID card copy as one PDF page (the Windows app's `IdCardPaginator`): the front centred in the top half of the paper and
/// the back in the bottom half, at actual size (`CopyLayout.idCard`), to print without scaling.
public enum IdCardSheet {
    /// One side as scanned: its JPEG and the resolution it was scanned at.
    public struct Side: Sendable {
        public var jpeg: [UInt8]
        public var dpi: Int

        public init(jpeg: [UInt8], dpi: Int) {
            self.jpeg = jpeg
            self.dpi = dpi
        }
    }

    /// `paper`: in points (Letter 612 × 792, A4 595 × 842).
    public static func pdf(front: Side, back: Side, paper: CGSize) -> Data? {
        guard let f = image(front.jpeg), let b = image(back.jpeg) else { return nil }
        let fi = CopyLayout.inches(f.width, f.height, front.dpi), bi = CopyLayout.inches(b.width, b.height, back.dpi)
        let margin: Double = 18 // ¼ in, in points
        let (top, bottom) = CopyLayout.idCard(Double(paper.width), Double(paper.height), (fi.width * 72, fi.height * 72),
                                              (bi.width * 72, bi.height * 72), margin: margin)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "ID card copy"] as CFDictionary) else { return nil }
        context.beginPDFPage(nil)
        // Placements are top-left based, y down; PDF pages are y up.
        for (image, p) in [(f, top), (b, bottom)] {
            context.draw(image, in: CGRect(x: p.x, y: Double(paper.height) - p.y - p.height, width: p.width, height: p.height))
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func image(_ jpeg: [UInt8]) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
