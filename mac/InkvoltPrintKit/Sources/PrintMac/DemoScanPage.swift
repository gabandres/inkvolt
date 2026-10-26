import CoreGraphics
import CoreText
import Foundation
import PrintCore

/// Demo mode's scanned pages (the Windows app draws its own), by `DemoScan` number: a made-up letter with a heading and lines
/// of text, so the review, straightening and searchable PDFs can be tried; the same letter a little crooked either way; a
/// blank sheet with a little paper noise; a Patch T separator sheet, for batches; three photos on the lid, for photos on the
/// glass. Drawn at 150 pixels per inch for the area asked (in 1/300 inch).
public enum DemoScanPage {
    public static func jpeg(_ page: Int, width: Int, height: Int) -> [UInt8] {
        let w = max(width / 2, 200), h = max(height / 2, 200)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.setFillColor(CGColor(red: 0.985, green: 0.98, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if page == DemoScan.separatorSheet {
            separatorSheet(context, w, h)
        } else if page == DemoScan.photos {
            photos(context, w, h)
        } else if page != DemoScan.blank {
            if page == DemoScan.crooked || page == DemoScan.crookedLeft { // crooked by 2.5° (or 1.5° the other way) about the centre
                let degrees: CGFloat = page == DemoScan.crooked ? -2.5 : 1.5
                context.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
                context.rotate(by: degrees * .pi / 180)
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

    /// The Patch T sheet as `SeparatorSheet` lays it out for letter paper, at 150 pixels per inch.
    private static func separatorSheet(_ context: CGContext, _ w: Int, _ h: Int) {
        guard let sheet = SeparatorSheet.page(.patchT, widthIn: 8.5, heightIn: 11) else { return }
        let scale = CGFloat(w) / CGFloat(sheet.width)
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        for bar in sheet.bars {
            context.fill(CGRect(x: CGFloat(bar.x) * scale, y: CGFloat(bar.y) * scale, width: CGFloat(bar.width) * scale, height: CGFloat(bar.height) * scale))
        }
        for line in sheet.lines {
            let x: CGFloat = 0.5 * 150
            draw(line.text, size: CGFloat(line.size) * scale, bold: false, at: CGPoint(x: x, y: CGFloat(line.baseline) * scale), context)
        }
    }

    /// Three prints on the lid, each a little crooked: a landscape, a portrait and a wide one.
    private static func photos(_ context: CGContext, _ w: Int, _ h: Int) {
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)) // the lid
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let inch: CGFloat = 150
        let prints: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, degrees: CGFloat, colors: [CGFloat])] = [
            (0.5, 6.6, 3.6, 2.7, 4, [0.20, 0.45, 0.70]),
            (5.1, 6.3, 2.6, 3.4, -6, [0.65, 0.35, 0.20]),
            (1.4, 1.2, 5, 3.5, 2, [0.25, 0.55, 0.30]),
        ]
        for p in prints {
            let rect = CGRect(x: p.x * inch, y: p.y * inch, width: p.w * inch, height: p.h * inch)
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -p.degrees * .pi / 180)
            let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
            context.setFillColor(CGColor(red: p.colors[0], green: p.colors[1], blue: p.colors[2], alpha: 1))
            context.fill(local)
            // A horizon and a sun, so each looks like a picture.
            context.setFillColor(CGColor(red: p.colors[0] * 0.5, green: p.colors[1] * 0.5, blue: p.colors[2] * 0.5, alpha: 1))
            context.fill(CGRect(x: local.minX, y: local.minY, width: local.width, height: local.height * 0.4))
            context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.3, alpha: 1))
            context.fillEllipse(in: CGRect(x: local.maxX - local.width * 0.3, y: local.maxY - local.height * 0.35, width: local.height * 0.22, height: local.height * 0.22))
            context.restoreGState()
        }
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
