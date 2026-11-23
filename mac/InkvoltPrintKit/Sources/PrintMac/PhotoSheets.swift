import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PrintCore

/// Photos for printing (the Windows app's Photos tab, drawing part): pictures read the right way up (EXIF orientation), and
/// `PhotoLayout`'s sheets drawn into a PDF at the paper's real size, each photo clipped to its print, turned when its print
/// is, with its file name under it on a contact sheet. Call through `offPool`.
public enum PhotoSheets {
    /// Most pixels a photo is read at: 300 dpi for an 8 × 10 in print.
    public static let maxPixels = 3000

    public struct PhotoError: Error {}

    /// A picture the right way up, at most `maxPixels` on its longest side (`quarterTurns` more turns clockwise).
    public static func load(_ url: URL, quarterTurns: Int = 0, maxPixels: Int = maxPixels) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PhotoError() }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoError() }
        let turns = ((quarterTurns % 4) + 4) % 4
        return turns == 0 ? image : try ScanImaging.turned(image, turns)
    }

    /// The sheets as a PDF, one page per sheet at `paper`'s size. `photos[i]` is `PhotoLayout`'s photo `i`; `names` its file
    /// names (contact sheets).
    public static func pdf(_ sheets: [PhotoSheet], photos: [CGImage], names: [String], paper: SheetPaper) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "Inkvolt Print"] as CFDictionary) else { throw PhotoError() }
        let page = CGSize(width: paper.width * 72, height: paper.height * 72)
        for sheet in sheets {
            var box = CGRect(origin: .zero, size: page)
            pdf.beginPage(mediaBox: &box)
            draw(sheet, photos: photos, names: names, paper: paper, in: pdf)
            pdf.endPage()
        }
        pdf.closePDF()
        return data as Data
    }

    /// One sheet into a context whose units are points with the origin at the bottom left (a PDF page, or a preview).
    public static func draw(_ sheet: PhotoSheet, photos: [CGImage], names: [String], paper: SheetPaper, in context: CGContext, scale: CGFloat = 72) {
        let height = paper.height * Double(scale)
        func rect(_ p: Placement) -> CGRect {
            CGRect(x: p.x * Double(scale), y: height - (p.y + p.height) * Double(scale), width: p.width * Double(scale), height: p.height * Double(scale))
        }
        for cell in sheet.cells where photos.indices.contains(cell.photo) {
            let image = photos[cell.photo]
            context.saveGState()
            context.clip(to: rect(cell.cell))
            let target = rect(cell.image)
            context.interpolationQuality = .high
            if cell.turned {
                // A quarter turn clockwise: drawn into the box's turned shape about its centre.
                context.translateBy(x: target.midX, y: target.midY)
                context.rotate(by: -.pi / 2)
                context.draw(image, in: CGRect(x: -target.height / 2, y: -target.width / 2, width: target.height, height: target.width))
            } else {
                context.draw(image, in: target)
            }
            context.restoreGState()
            if let caption = cell.caption, names.indices.contains(cell.photo) {
                let r = rect(caption)
                let font = CTFontCreateWithName("Helvetica" as CFString, max(min(r.height * 0.7, 9 * scale / 72), 4), nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: names[cell.photo], attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: 1),
                ]))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                context.saveGState()
                context.clip(to: r)
                context.textPosition = CGPoint(x: r.midX - min(width, r.width) / 2, y: r.minY + r.height * 0.25)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
        drawMarks(sheet, height: height, scale: Double(scale), in: context)
    }

    /// A sheet's lines (a card's fold and cut marks, a calendar's grid) and text (a card's message, a calendar's names and
    /// days; roadmap 4.16): lines a hairline grey, dashed where marked; text wrapped from the top of its box, in Helvetica
    /// (bold for titles, grey when muted).
    private static func drawMarks(_ sheet: PhotoSheet, height: Double, scale: Double, in context: CGContext) {
        if !sheet.lines.isEmpty {
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
            context.setLineWidth(max(0.5, 0.75 * scale / 72))
            for line in sheet.lines {
                context.setLineDash(phase: 0, lengths: line.dashed ? [3 * scale / 72, 2 * scale / 72] : [])
                context.beginPath()
                context.move(to: CGPoint(x: line.x1 * scale, y: height - line.y1 * scale))
                context.addLine(to: CGPoint(x: line.x2 * scale, y: height - line.y2 * scale))
                context.strokePath()
            }
            context.restoreGState()
        }
        context.textMatrix = .identity
        for text in sheet.texts where !text.text.isEmpty && text.size > 0 && text.box.width > 0 && text.box.height > 0 {
            let font = CTFontCreateWithName((text.bold ? "Helvetica-Bold" : "Helvetica") as CFString, text.size * scale, nil)
            var alignment: CTTextAlignment = switch text.align {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            let style = withUnsafeBytes(of: &alignment) { bytes in
                [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)]
                    .withUnsafeBufferPointer { CTParagraphStyleCreate($0.baseAddress, $0.count) }
            }
            let words = NSAttributedString(string: text.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: text.muted ? 0.45 : 0.1, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ])
            // Down by the font's height past the box (a line or two of a short box still shows, as Windows lets text run on).
            let box = CGRect(x: text.box.x * scale, y: height - text.box.bottom * scale - text.size * scale,
                             width: text.box.width * scale, height: text.box.height * scale + text.size * scale)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(words), CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
            CTFrameDraw(frame, context)
        }
    }

    /// A small picture of a sheet for the preview, `width` pixels wide.
    public static func preview(_ sheet: PhotoSheet, photos: [CGImage], names: [String], paper: SheetPaper, width: Int) -> CGImage? {
        let scale = CGFloat(width) / CGFloat(paper.width)
        // The paper is the queue's (from the printer's driver): a size no Int holds draws no preview.
        guard let height = Int(exactly: (paper.height * Double(scale)).rounded()),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(sheet, photos: photos, names: names, paper: paper, in: context, scale: scale)
        return context.makeImage()
    }
}
