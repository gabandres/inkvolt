import CoreGraphics
import CoreText
import Foundation
import PrintCore

/// The separator sheet (`SeparatorSheet.page`) as a one-page vector PDF, to print at actual size: the Windows app's
/// `Core/Pdf/SeparatorSheet`. The bars are filled rectangles, black; the text is centred.
public enum SeparatorSheetPdf {
    public static func write(_ sheet: SeparatorSheetPage) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: sheet.title,
                                                                           kCGPDFContextCreator as String: "Inkvolt Print"] as CFDictionary) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for bar in sheet.bars { context.fill(CGRect(x: bar.x, y: bar.y, width: bar.width, height: bar.height)) }
        for line in sheet.lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(line.size), nil)
            let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            let width = CTLineGetTypographicBounds(text, nil, nil, nil)
            let x: Double = max(SeparatorSheet.minTextMargin, (sheet.width - width) / 2)
            context.textPosition = CGPoint(x: x, y: line.baseline)
            CTLineDraw(text, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
