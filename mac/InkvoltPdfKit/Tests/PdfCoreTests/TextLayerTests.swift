import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfCore

/// TextLayerTests, ported. Adapted: the "scanned" page is made by rendering TestPdf's page with PdfEngine and putting the
/// picture back as a page of its own (ImageImport), where Windows rasterizes it with Redaction.Apply (redaction is E1 on
/// the Mac); a rotated scan is that page turned with PageEditor.rotate. "Invisible" is checked on the whole page, byte
/// for byte, besides Windows' ink measure. `NoWordsReturnsTheSameBytes` compares the bytes (Swift arrays are values, not
/// references). Added for the Mac: Apple's PDFKit finds the words where they were recognized, and Core Graphics draws
/// the page unchanged; the font is the glyphless one (GlyphlessFont).
struct TextLayerTests {
    /// A page that is only an image (no text): TestPdf's page drawn at 72 dpi.
    static func scanned(_ rotate: Int) throws -> [UInt8] {
        let engine = try PdfEngine.open(TestPdf.make(1))
        defer { engine.close() }
        let img = try engine.render(0, scale: 1)
        let png = TestImages.png(img.width, img.height, dpi: 72) { x, y in
            let i = (y * img.width + x) * 3
            return (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2], 255)
        }
        var data = try ImageImport.imagesToPdf([(png, "scan.png")])
        if rotate != 0 { data = try PageEditor.rotate(data, nil, [0], rotate) }
        return data
    }

    static let words = [
        OcrWord("Invoice", RectD(72, 300, 90, 24)),
        OcrWord("number", RectD(170, 300, 80, 24)),
        OcrWord("Total:", RectD(72, 340, 50, 12)),
        OcrWord("€1,234", RectD(130, 340, 55, 12)),
        OcrWord("مرحبا", RectD(300, 340, 60, 14)),
    ]

    static func box(_ t: PageText, _ s: Int, _ e: Int) -> RectD {
        let rects = t.rects(s, e)
        return rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    @Test(arguments: [0, 90, 270]) func invisibleWordsAreFoundWhereTheyWereRecognized(rotate: Int) throws {
        let scan = try Self.scanned(rotate)
        let before = try PdfEngine.open(scan)
        #expect(try !TextLayer.hasText(before, 0))
        before.close()

        let data = try TextLayer.addInvisibleText(scan, nil, [0: Self.words])

        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        #expect(try TextLayer.hasText(engine, 0))
        let text = try engine.text(0)
        #expect(text.text.contains("Invoice number"))
        #expect(text.text.contains("Total: €1,234"))
        #expect(text.text.contains("مرحبا"))
        let invoice = try #require(text.text.range(of: "Invoice")), total = try #require(text.text.range(of: "Total"))
        #expect(invoice.lowerBound < total.lowerBound, "reading order")
        for w in Self.words {
            let found = text.find(w.text, matchCase: true, wholeWord: false)
            try #require(found.count == 1, "\(w.text)")
            let box = Self.box(text, found[0].start, found[0].end)
            #expect(abs(box.x - w.rect.x) <= 1.5, "\(w.text) x \(box)")
            #expect(abs(box.right - w.rect.right) <= 1.5, "\(w.text) right \(box)")
            #expect(abs(box.y - w.rect.y) <= 1.5, "\(w.text) y \(box)")
            #expect(abs(box.bottom - w.rect.bottom) <= 1.5, "\(w.text) bottom \(box)")
        }
        // Invisible: the page looks exactly as before.
        let region = RectD(60, 290, 320, 70)
        #expect(abs(try Core2Pdf.ink(scan, 0, region) - Core2Pdf.ink(data, 0, region)) < 0.0005)
        let a = try PdfEngine.open(scan), b = try PdfEngine.open(data)
        defer {
            a.close()
            b.close()
        }
        #expect(try a.render(0, scale: 1.5).pixels == b.render(0, scale: 1.5).pixels)
    }

    @Test func existingContentStateDoesNotLeakIntoTheTextLayer() throws {
        // The page's content ends inside an unbalanced q with a scaling cm: the layer must still land where asked.
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.stream("q 2 0 0 2 0 0 cm 0 0 10 10 re f"),
        ])
        let withText = try TextLayer.addInvisibleText(data, nil, [0: [OcrWord("Hello", RectD(100, 100, 50, 20))]])
        let engine = try PdfEngine.open(withText)
        defer { engine.close() }
        let t = try engine.text(0)
        let found = t.find("Hello", matchCase: true, wholeWord: false)
        try #require(found.count == 1)
        let box = Self.box(t, found[0].start, found[0].end)
        #expect((98.5...101.5).contains(box.x))
        #expect((98.5...101.5).contains(box.y))
    }

    @Test(arguments: [
        "q q 2 0 0 2 0 0 cm 0 0 10 10 re f", // two unbalanced saves
        "Q 2 0 0 2 0 0 cm q 3 0 0 3 0 0 cm 0 0 10 10 re f", // a restore with nothing saved, then a save
    ]) func unbalancedContentDoesNotMoveTheTextLayer(content: String) throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.stream(content),
        ])
        let withText = try TextLayer.addInvisibleText(data, nil, [0: [OcrWord("Hello", RectD(100, 100, 50, 20))]])
        let engine = try PdfEngine.open(withText)
        defer { engine.close() }
        let t = try engine.text(0)
        let found = t.find("Hello", matchCase: true, wholeWord: false)
        try #require(found.count == 1)
        let box = Self.box(t, found[0].start, found[0].end)
        #expect((98.5...101.5).contains(box.x))
        #expect((98.5...101.5).contains(box.y))
        #expect((48...52).contains(box.width))
    }

    @Test func noWordsReturnsTheSameBytes() throws {
        let scan = try Self.scanned(0)
        #expect(try TextLayer.addInvisibleText(scan, nil, [0: [OcrWord(" ", RectD(1, 1, 5, 5))]]) == scan)
    }

    // ---- Mac: Apple's PDFKit and Core Graphics ----

    /// The page drawn by Core Graphics (as Preview and PDFKit draw it), RGBA.
    static func quartz(_ data: [UInt8]) throws -> [UInt8] {
        let doc = try #require(CGPDFDocument(CGDataProvider(data: Data(data) as CFData)!))
        let page = try #require(doc.page(at: 1))
        let box = page.getBoxRect(.cropBox)
        let w = Int(box.width), h = Int(box.height)
        let width = page.rotationAngle % 180 == 0 ? w : h, height = page.rotationAngle % 180 == 0 ? h : w
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buf in
            let ctx = try #require(CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                                                     rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
        }
        return pixels
    }

    @Test(arguments: [0, 90]) func pdfKitFindsTheInvisibleWords(rotate: Int) throws {
        let scan = try Self.scanned(rotate)
        let data = try TextLayer.addInvisibleText(scan, nil, [0: Self.words])
        let doc = try #require(PDFDocument(data: Data(data)))
        let page = try #require(doc.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains("Invoice number"), "\(text)")
        #expect(text.contains("Total: €1,234"), "\(text)")
        #expect(text.contains("مرحبا"), "\(text)")
        if rotate == 0 {
            // PDFKit's boxes are in PDF space (origin bottom left); the page is 792 points high.
            for w in Self.words.prefix(4) {
                let found = doc.findString(w.text, withOptions: [])
                try #require(found.count == 1, "\(w.text)")
                let b = found[0].bounds(for: page)
                #expect(abs(Double(b.minX) - w.rect.x) <= 2, "\(w.text) \(b)")
                #expect(abs(Double(b.maxX) - w.rect.right) <= 2, "\(w.text) \(b)")
                #expect(abs(Double(b.minY) - (792 - w.rect.bottom)) <= 2, "\(w.text) \(b)")
                #expect(abs(Double(b.maxY) - (792 - w.rect.y)) <= 2, "\(w.text) \(b)")
            }
        }
        // Invisible in Core Graphics too.
        #expect(try Self.quartz(scan) == Self.quartz(data))
    }

    @Test func eachPageGetsItsOwnFontAndTheProgramIsSharedOnce() throws {
        let one = try Self.scanned(0)
        let two = try PageEditor.insert(one, nil, PdfSource(one, nil, "scan.pdf"), nil, 1)
        let data = try TextLayer.addInvisibleText(two, nil, [0: [OcrWord("first", RectD(72, 72, 60, 20))], 1: [OcrWord("second", RectD(72, 72, 60, 20))]])
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        #expect(try engine.text(0).text.contains("first") && !engine.text(0).text.contains("second"))
        #expect(try engine.text(1).text.contains("second"))
        let all = try PdfText.everything(data)
        #expect(all.components(separatedBy: "/FontFile2").count - 1 == 1)
        #expect(all.contains("/InkvoltGlyphless"))
    }
}
