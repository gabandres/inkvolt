import Foundation
import Testing
@testable import PdfCore

/// Ported from ImageImportTests.cs: all 4 tests. The image objects are read through MuPDF (`Core2Pdf.open`) where
/// Windows reads them with PDFsharp: a JPEG's stream as stored (`rawStreamData`), PNG samples decoded (`streamData`).
/// Adapted: the test JPEGs are drawn by MuPDF (`TestImages.jpeg`), and both refusals are `PdfEditError` (.NET throws
/// `InvalidOperationException` for a file that isn't an image and `ArgumentException` for no images).
struct ImageImportTests {
    private func images(_ doc: MuDoc, _ page: Int) -> [PObj] {
        guard let x = doc.page(page).dict("Resources")?.dict("XObject") else { return [] }
        return x.keys.compactMap { x.dict($0) }
    }

    private func pageSize(_ doc: MuDoc, _ page: Int) -> (w: Double, h: Double) { PageBoxes.displaySize(doc.page(page)) }

    @Test func jpegIsEmbeddedAsIs() throws {
        let jpeg = TestImages.jpeg(120, 80)
        let pdf = try ImageImport.imagesToPdf([(jpeg, "photo.jpg")])
        let doc = try Core2Pdf.open(pdf)
        #expect(try doc.pageCount() == 1)
        let all = images(doc, 0)
        try #require(all.count == 1)
        let image = all[0]
        #expect(image.name("Filter") == "DCTDecode")
        #expect(image.rawStreamData == jpeg)
        #expect(image.int("Width") == 120)
        #expect(image.int("Height") == 80)
        #expect(image.name("ColorSpace") == "DeviceRGB")

        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let g = engine.page(0)
        #expect(g.width > g.height)
        // Red quarter top-left, white elsewhere.
        let red = TestImages.pixelAt(pdf, 0, g.width * 0.2, g.height * 0.2)
        #expect(red.r > 200 && red.g < 60, "\(red)")
        let white = TestImages.pixelAt(pdf, 0, g.width * 0.8, g.height * 0.8)
        #expect(white.g > 200, "\(white)")
    }

    @Test func exifOrientationTurnsThePage() throws {
        // Stored landscape, orientation 6 (rotate 90 clockwise to view): shown portrait, the red corner top-right.
        let jpeg = TestImages.withExifOrientation(TestImages.jpeg(200, 100), 6)
        #expect(ImageImport.readJpeg(jpeg)?.orientation == 6)
        let pdf = try ImageImport.imagesToPdf([(jpeg, "turned.jpg")])
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let g = engine.page(0)
        #expect(g.height > g.width)
        let topRight = TestImages.pixelAt(pdf, 0, g.width * 0.8, g.height * 0.2)
        #expect(topRight.r > 200 && topRight.g < 60, "\(topRight)")
        let topLeft = TestImages.pixelAt(pdf, 0, g.width * 0.2, g.height * 0.2)
        #expect(topLeft.g > 200, "\(topLeft)")
    }

    @Test func pngWithAlphaGetsAnSMask() throws {
        // Left half opaque red, right half fully transparent; one half-transparent dark red pixel row at the top.
        let png = TestImages.png(40, 20, dpi: 72) { x, y in y == 0 ? (100, 0, 0, 128) : x < 20 ? (255, 0, 0, 255) : (0, 0, 0, 0) }
        let pdf = try ImageImport.imagesToPdf([(png, "logo.png")])
        let doc = try Core2Pdf.open(pdf)
        let all = images(doc, 0)
        try #require(all.count == 1)
        let image = all[0]
        #expect(image.name("Filter") == "FlateDecode")
        #expect(image.int("Width") == 40)
        let mask = try #require(image.dict("SMask"))
        #expect(mask.name("ColorSpace") == "DeviceGray")
        let alpha = try #require(mask.streamData)
        #expect(alpha[40 + 5] == 255)
        #expect(alpha[40 + 30] == 0)
        #expect((120...136).contains(alpha[3]))
        // Colors are stored straight (not premultiplied): the half-transparent pixel keeps its red of 100.
        let rgb = try #require(image.streamData)
        #expect((94...106).contains(rgb[3 * 3]))

        // At 72 dpi the page is the image's pixel size; transparent parts show the white page.
        #expect(abs(pageSize(doc, 0).w - 40) <= 1)
        #expect(abs(pageSize(doc, 0).h - 20) <= 1)
        let clear = TestImages.pixelAt(pdf, 0, 30, 10)
        #expect(clear.r > 240 && clear.g > 240, "\(clear)")
        let solid = TestImages.pixelAt(pdf, 0, 5, 10)
        #expect(solid.r > 200 && solid.g < 60, "\(solid)")
    }

    @Test func pageSizesAndPageCount() throws {
        let png = TestImages.png(300, 100) { _, _ in (0, 0, 255, 255) }
        let jpeg = TestImages.jpeg(50, 100)
        let pdf = try ImageImport.imagesToPdf([(png, "wide.png"), (jpeg, "tall.jpg"), (png, "again.png")], pageSize: .letter)
        let doc = try Core2Pdf.open(pdf)
        #expect(try doc.pageCount() == 3)
        // Wide image → landscape Letter; tall → portrait.
        #expect(abs(pageSize(doc, 0).w - 792) <= 1)
        #expect(abs(pageSize(doc, 0).h - 612) <= 1)
        #expect(abs(pageSize(doc, 1).w - 612) <= 1)
        #expect(abs(pageSize(doc, 1).h - 792) <= 1)
        // An opaque single-color image needs no mask; 96 dpi without pHYs: 300 px = 225 pt, centered.
        #expect(images(doc, 0).first?.has("SMask") == false)
        let center = TestImages.pixelAt(pdf, 0, 396, 306)
        #expect(center.b > 200 && center.r < 60, "\(center)")
        let outside = TestImages.pixelAt(pdf, 0, 396 - 120, 306)
        #expect(outside.r > 240, "\(outside)")

        let a4 = try Core2Pdf.open(ImageImport.imagesToPdf([(jpeg, "tall.jpg")], pageSize: .a4))
        #expect(abs(pageSize(a4, 0).w - 595.28) <= 1)

        #expect(throws: PdfEditError.self) { try ImageImport.imagesToPdf([(Array("not an image".utf8), "notes.txt")]) }
        #expect(throws: PdfEditError.self) { try ImageImport.imagesToPdf([]) }
    }
}
