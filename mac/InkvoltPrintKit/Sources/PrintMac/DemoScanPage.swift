import CoreGraphics
import CoreText
import Foundation
import PrintCore

/// Demo mode's scanned pages (the Windows app draws its own): a made-up letter with a heading and lines of text, so the
/// review, straightening and searchable PDFs can be tried; page 1 is the same letter a little crooked, page 2 a blank sheet
/// with a little paper noise. Drawn at 150 pixels per inch for the area asked (in 1/300 inch).
public enum DemoScanPage {
    public static func jpeg(_ page: Int, width: Int, height: Int) -> [UInt8] {
        let w = max(width / 2, 200), h = max(height / 2, 200)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.setFillColor(CGColor(red: 0.985, green: 0.98, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if page != 2 {
            if page == 1 { // crooked by 2.5° about the centre
                context.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
                context.rotate(by: -2.5 * .pi / 180)
                context.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
            }
            let inch = CGFloat(150)
            var y = CGFloat(h) - inch
            draw("Inkvolt Print demo", size: 28, bold: true, at: CGPoint(x: inch, y: y), context)
            y -= 50
            let lines = [
                "This page came from the demo scanner. Nothing was scanned and nothing left this Mac.",
                "Pages are checked as they arrive: blank sheets are left out and crooked ones straightened.",
                "Turn, crop, reorder or delete pages before saving them as a PDF or JPEG images.",
                "A searchable PDF carries the words Vision recognises on this Mac, invisible over the page.",
            ]
            for (i, text) in (0..<18).map({ lines[$0 % lines.count] }).enumerated() {
                draw(text, size: 13, bold: false, at: CGPoint(x: inch, y: y - CGFloat(i) * 24), context)
            }
        } else {
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            for i in 0..<12 { context.fill(CGRect(x: (i * 97) % w, y: (i * 211) % h, width: 1, height: 1)) } // dust
        }
        guard let image = context.makeImage(), let bytes = try? ScanImaging.jpeg(image) else { return [] }
        return bytes
    }

    private static func draw(_ text: String, size: CGFloat, bold: Bool, at point: CGPoint, _ context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
        ]))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
