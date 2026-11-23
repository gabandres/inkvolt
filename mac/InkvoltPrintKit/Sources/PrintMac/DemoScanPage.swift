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
        if page == DemoScan.punchedForm {
            punchedForm(context, w, h)
        } else if DemoScan.reportPages.contains(page) {
            reportPage(page - DemoScan.reportPage(0), upsideDown: DemoScan.isUpsideDown(page), context, w, h)
        } else if page == DemoScan.separatorSheet {
            separatorSheet(context, w, h)
        } else if page == DemoScan.photos {
            photos(context, w, h)
        } else if page == DemoScan.onLid {
            onLid(context, w, h)
        } else if page != DemoScan.blank {
            if page == DemoScan.crooked || page == DemoScan.crookedLeft { // crooked by 2.5° (or 1.5° the other way) about the centre
                let degrees: CGFloat = page == DemoScan.crooked ? -2.5 : 1.5
                context.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
                context.rotate(by: degrees * .pi / 180)
                context.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
            }
            let inch = CGFloat(150)
            var y = CGFloat(h) - inch
            draw(loc("Inkvolt Print demo"), size: 28, bold: true, at: CGPoint(x: inch, y: y), context)
            y -= 50
            let lines = [
                loc("This page came from the demo scanner. Nothing was scanned and nothing left this Mac."),
                loc("Pages are checked as they arrive: blank sheets are left out and crooked ones straightened."),
                loc("Turn, crop, reorder or delete pages before saving them as a PDF or JPEG images."),
                loc("A searchable PDF carries the words Vision recognises on this Mac, invisible over the page."),
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

    /// A sheet of yellowed paper on the lid, half an inch in from the glass's edges: a heading, lines of text and one in
    /// Russian, so Crop to the paper, Whiten the background and a searchable PDF in another script can be tried.
    private static func onLid(_ context: CGContext, _ w: Int, _ h: Int) {
        let inch: CGFloat = 150
        context.setFillColor(CGColor(gray: lidLevel, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let sheet = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: inch / 2, dy: inch / 2)
        context.setFillColor(CGColor(red: 0.93, green: 0.91, blue: 0.84, alpha: 1))
        context.fill(sheet)
        var y = sheet.maxY - inch
        draw(loc("Inkvolt Print demo"), size: 28, bold: true, at: CGPoint(x: sheet.minX + inch, y: y), context)
        y -= 50
        let lines = [
            loc("This sheet lay on the scanner's lid: Crop to the paper takes the lid off around it."),
            loc("Whiten the background evens the yellowed paper out to white; the writing stays."),
            "Привет из демо-сканера: этот текст тоже находится поиском.",
        ]
        for (i, text) in (0..<12).map({ lines[$0 % lines.count] }).enumerated() {
            draw(text, size: 13, bold: false, at: CGPoint(x: sheet.minX + inch, y: y - CGFloat(i) * 24), context)
        }
    }

    /// Page `number` of a short report of made-up prose (the Windows demo's `TextPage`), turned over when `upsideDown` (a
    /// sheet fed the wrong way up): a heading, paragraphs of serif text and the page's number large enough to read on a
    /// thumbnail. Never a real scan.
    private static func reportPage(_ number: Int, upsideDown: Bool, _ context: CGContext, _ w: Int, _ h: Int) {
        let words = ["the", "quarterly", "report", "shows", "steady", "growth", "in", "every", "region", "with", "higher", "sales", "of",
                     "paper", "toner", "and", "ink", "while", "shipping", "costs", "fell", "slightly", "during", "the", "spring", "months",
                     "before", "rising", "again", "in", "July", "our", "teams", "kept", "delivery", "times", "short", "and", "customers",
                     "told", "us", "they", "liked"]
        if upsideDown {
            context.translateBy(x: CGFloat(w), y: CGFloat(h))
            context.rotate(by: .pi)
        }
        let scale = CGFloat(w) / 1275 // laid out for letter at 150 pixels per inch
        let top = CGFloat(h)
        draw("Quarterly report, page \(number)", size: 30 * scale, bold: true, at: CGPoint(x: 120 * scale, y: top - 140 * scale), context)
        var seed = UInt64(number) &* 7919
        func next(_ n: Int) -> Int { // a small fixed generator: the same page every time
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        var y = 190 * scale
        for line in 0..<38 {
            defer { y += 32 * scale }
            if line % 9 == 8 { y += 18 * scale; continue } // a gap between paragraphs
            var text = ""
            while text.count < (line % 9 == 7 ? 40 : 78) { text += words[next(words.count)] + " " }
            let sentence = text.trimmingCharacters(in: .whitespaces)
            draw(sentence.prefix(1).uppercased() + sentence.dropFirst() + ".", size: 17 * scale, bold: false, font: "Georgia",
                 at: CGPoint(x: 120 * scale, y: top - y - 17 * scale), context)
        }
        draw("\(number)", size: 150 * scale, bold: true, at: CGPoint(x: CGFloat(w) - 260 * scale, y: top - 1440 * scale), context)
    }

    /// An order form (roadmap 4.7): red rules every third of an inch with black print over them, a blue pen's line and three
    /// punch holes' dark shadows half an inch in from the left edge, so Drop a color and Remove punch holes can be tried.
    private static func punchedForm(_ context: CGContext, _ w: Int, _ h: Int) {
        let inch = CGFloat(w) / 8.5
        let top = CGFloat(h)
        draw("ORDER FORM", size: 0.25 * inch, bold: true, at: CGPoint(x: inch, y: top - 0.9 * inch), context)
        context.setFillColor(CGColor(red: 0.84, green: 0.18, blue: 0.2, alpha: 1)) // the form's red rules
        var y = 1.4 * inch
        while y < top - inch {
            context.fill(CGRect(x: 0.9 * inch, y: top - y, width: CGFloat(w) - 1.8 * inch, height: 0.02 * inch))
            y += inch / 3
        }
        let items = ["Toner cartridge, black", "Paper, letter, 500 sheets", "Staples, box of 5000", "Envelopes, #10"]
        for (i, item) in (0..<18).map({ items[$0 % items.count] }).enumerated() {
            draw("\(i + 1).  \(item)   qty \(i % 4 + 1)", size: 0.13 * inch, bold: false, at: CGPoint(x: inch, y: top - 1.4 * inch - CGFloat(i) * inch / 3 + 0.02 * inch), context)
        }
        context.setStrokeColor(CGColor(red: 0.16, green: 0.27, blue: 0.75, alpha: 1)) // a blue pen's line under the total
        context.setLineWidth(0.03 * inch)
        context.strokeLineSegments(between: [CGPoint(x: 4.5 * inch, y: 1.6 * inch), CGPoint(x: 7.2 * inch, y: 1.75 * inch)])
        context.setFillColor(CGColor(gray: 0.25, alpha: 1)) // the feeder's backing seen through each hole
        for y in [1.0, 5.5, 10.0] {
            context.fillEllipse(in: CGRect(x: 0.5 * inch - 0.14 * inch, y: top - CGFloat(y) * inch - 0.14 * inch, width: 0.28 * inch, height: 0.28 * inch))
        }
    }

    /// The demo lid's grey.
    static let lidLevel: CGFloat = 0.72

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

    private static func draw(_ text: String, size: CGFloat, bold: Bool, font name: String = "Helvetica", at point: CGPoint, _ context: CGContext) {
        let font = CTFontCreateWithName((bold ? name + "-Bold" : name) as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
        ]))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
