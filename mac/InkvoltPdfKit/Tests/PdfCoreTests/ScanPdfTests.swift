import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PdfCore

/// ScanPdfTests, ported: a scan becomes a PDF, then gets the OCR text layer and is inserted into a document, as File ›
/// Scan and Organize › Insert from Scanner do. Adapted: Windows writes the scan with Inkvolt Print's .NET `PdfWriter`;
/// Inkvolt Print's Mac writer is `ScanPdf.write` in PrintMac (another package, with libcups), so `scanPdf` here draws the
/// JPEGs the same way, through Core Graphics, which embeds a JPEG as it came (DCTDecode, its own bytes).
struct ScanPdfTests {
    /// A 40 × 56 px grayscale JPEG.
    static let jpeg = Array(Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAZABkAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/wAALCAA4ACgBAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/AKtn4b6fJ+lay6NbWcayXcsUCE7Q0rhQT6ZP0qu+t6LbRg2wlvHIOAkZUA9slsYz7A1Xm8Q6jcLtsbSKzBA+Y/vHBz2JAHTjkGq81nqOqNm+uZZgSG2E4QEDGQo4HHoKkm1LXL9dglW1QgArbLt6HOdxyw/A02PQprmYzXDSTStjc8jFmPbkmtSPQobaEzXDRwxLjc8jBVHbkmmzalodg2wStdOCAVtl3dRnO44U/gapv4kvZowtjp8VsSCC7sZCPQjgAY9wasTeIdOt222NpLeEEfMf3aEY7EgnrxyBVN9X1y8jEaGK1BBDGCPBbPuSSMeoxUa6Nc3kiyXcss7gbQ0rliB6ZP1rUt/DyRRtJIFREBZmbgKB1JNE17oenrzcrcPgEJbDzM846j5fwJqR9MstNjEl9PFACCQHYAtjrgdT9BVebXtJtlxZQy3r4BBC+WnXkEnnpz0NV5te1a5bFlDFZJkEEL5j9OQSeOvPQVVGk3l7s+2Tz3GzO3zZC+3PXGenQVqWfhvp8n6Vn2fhvp8n6VrLo1tZxrJdyxQITtDSuFBPpk/Sq763ottGDbCW8cg4CRlQD2yWxjPsDVebxDqNwu2xtIrMED5j+8cHPYkAdOOQarzWeo6o2b65lmBIbYThAQMZCjgcegqSbUtcv12CVbVCACtsu3oc53HLD8DTY9CmuZjNcNJNK2NzyMWY9uSa1I9ChtoTNcNHDEuNzyMFUduSabNqWh2DbBK104IBW2Xd1Gc7jhT+Bqm/iS9mjC2OnxWxIILuxkI9COABj3BqxN4h063bbY2kt4QR8x/doRjsSCevHIFU31fXLyMRoYrUEEMYI8Fs+5JIx6jFRro1zeSLJdyyzuBtDSuWIHpk/WtS38PJFG0kgVEQFmZuAoHUk0TXuh6evNytw+AQlsPMzzjqPl/Amv/Z")!)

    /// `pages` scanned pages, each the JPEG at `dpi`, written as Inkvolt Print's Mac `ScanPdf.write` writes them.
    static func scanPdf(_ pages: Int, dpi: Int = 100) throws -> [UInt8] {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let info: [CFString: Any] = [kCGPDFContextCreator: "Inkvolt Print", kCGPDFContextTitle: "Scan 2026-10-23 0900"]
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary))
        for _ in 0..<pages {
            let source = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / CGFloat(dpi), height: CGFloat(image.height) * 72 / CGFloat(dpi))
            pdf.beginPage(mediaBox: &box)
            pdf.draw(image, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
        return Array(data as Data)
    }

    @Test func scannedPagesOpenAtTheirScannedSize() throws {
        let engine = try PdfEngine.open(try Self.scanPdf(2))
        defer { engine.close() }
        #expect(engine.pageCount == 2)
        let g = engine.page(1)
        #expect(abs(g.width - 40 * 72.0 / 100) < 0.05)
        #expect(abs(g.height - 56 * 72.0 / 100) < 0.05)
        #expect(try !TextLayer.hasText(engine, 0)) // nothing to search until OCR adds a layer
    }

    @Test func textLayerAndInsertKeepTheScannedJpegAsIs() throws {
        let scan = try Self.scanPdf(2)
        #expect(scan.firstRange(of: Self.jpeg) != nil, "Core Graphics should embed the JPEG as it came")
        let withText = try TextLayer.addInvisibleText(scan, nil, [0: [OcrWord("Invoice", RectD(2, 2, 20, 8))]])
        let e = try PdfEngine.open(withText)
        #expect(try e.text(0).text.contains("Invoice"))
        e.close()

        let result = try PageEditor.insert(TestPdf.make(3), nil, PdfSource(withText, nil, "Scan.pdf"), nil, 1)
        let r = try PdfEngine.open(result)
        defer { r.close() }
        #expect(r.pageCount == 5)
        #expect(try r.text(0).text.contains("Page 1"))
        #expect(try r.text(1).text.contains("Invoice"))
        #expect(try r.text(3).text.contains("Page 2"))
        #expect(result.firstRange(of: Self.jpeg) != nil, "the JPEG should be copied byte for byte, not re-encoded")
    }
}
