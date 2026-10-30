import Foundation
import Testing
@testable import PdfCore

/// Ported from WatermarkTests.cs (same names). The watermark's text goes through `TextPainter` as on Windows; the
/// content stream count is read through MuPDF.
struct WatermarkTests {
    /// A page whose content paints it opaque white, as a scanned page does.
    private static func opaquePage() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.stream("1 1 1 rg 0 0 612 792 re f"),
        ])
    }

    private static func red(_ w: Int = 4, _ h: Int = 4) -> StampImage {
        StampImage(w, h, (0..<(w * h)).flatMap { _ in [UInt8(220), 0, 0] }, nil)
    }

    private static func contentCount(_ pdf: [UInt8]) throws -> Int {
        let doc = try Core2Pdf.open(pdf)
        return doc.page(0).array("Contents")?.count ?? 1
    }

    @Test func tilesCoverThePageWithinTheLimit() {
        let centers = Watermarks.tileCenters(612, 792, 200, 40, 45)
        #expect(centers.count >= 6 && centers.count <= Watermarks.maxTiles)
        // Every corner region of the page has a tile near it.
        for (x, y) in [(0.0, 0.0), (612.0, 0.0), (0.0, 792.0), (612.0, 792.0), (306.0, 396.0)] {
            #expect(centers.contains { abs($0.x - x) < 260 && abs($0.y - y) < 260 })
        }
        // A tiny tile can't explode the content.
        let tiny = Watermarks.tileCenters(612, 792, 2, 2, 0).count
        #expect(tiny >= 1 && tiny <= Watermarks.maxTiles)
        let (w, h) = Watermarks.turnedExtent(200, 40, 90)
        #expect(abs(w - 40) < 1e-6 && abs(h - 200) < 1e-6)
    }

    @Test func textIsTurnedAndCentered() throws {
        let pdf = TestPdf.make(2)
        let result = try Watermarks.apply(pdf, nil, [1], WatermarkOptions(text: "CONFIDENTIAL", color: AnnotColor(0, 0, 0), opacity: 1, rotation: 90))
        #expect(!(try Core2Pdf.allText(result, page: 0)).contains("CONFIDENTIAL"))
        let line = try #require(try Core2Pdf.lines(result, page: 1, annotations: false).first { $0.text == "CONFIDENTIAL" })
        #expect(line.box.height > line.box.width * 3) // upright: turned a quarter
        #expect(line.box.centerX >= 286 && line.box.centerX <= 326)
        #expect(line.box.centerY >= 376 && line.box.centerY <= 416)
        #expect(TestPdf.pageNumbers(result) == [1, 2])
        #expect(try Watermarks.has(result, nil))
    }

    @Test func opacityLetsThePageShowThrough() throws {
        let pdf = Self.opaquePage()
        let faint = try Watermarks.apply(pdf, nil, [0], WatermarkOptions(image: Self.red(), opacity: 0.3, rotation: 0, imageScale: 0.5))
        let (r, g, _) = TestImages.pixelAt(faint, 0, 306, 396)
        #expect(r >= 230 && r <= 255)
        #expect(g >= 150 && g <= 200) // 30% red over white
        let solid = try Watermarks.apply(pdf, nil, [0], WatermarkOptions(image: Self.red(), opacity: 1, rotation: 0, imageScale: 0.5))
        #expect(TestImages.pixelAt(solid, 0, 306, 396).g < 30)
        // Half the page's width, centered: the edges stay white.
        #expect(TestImages.pixelAt(solid, 0, 100, 396).g > 240)
    }

    @Test func behindIsHiddenByOpaqueContent() throws {
        let pdf = Self.opaquePage()
        let behind = try Watermarks.apply(pdf, nil, [0], WatermarkOptions(image: Self.red(), opacity: 1, rotation: 0, imageScale: 1, behind: true))
        #expect(TestImages.pixelAt(behind, 0, 306, 396).g > 240)
        #expect(try Watermarks.has(behind, nil))
        let over = try Watermarks.apply(pdf, nil, [0], WatermarkOptions(image: Self.red(), opacity: 1, rotation: 0, imageScale: 1))
        #expect(TestImages.pixelAt(over, 0, 306, 396).g < 30)
    }

    @Test func tiledRepeatsTheText() throws {
        let result = try Watermarks.apply(TestPdf.make(1), nil, [0], WatermarkOptions(text: "DRAFT", fontSize: 36, rotation: 0, layout: .tiled))
        #expect(try Core2Pdf.lines(result, page: 0, annotations: false).filter { $0.text.contains("DRAFT") }.count >= 6)
    }

    @Test func removesIndependentlyOfTheHeaderAndFooter() throws {
        let pdf = TestPdf.make(1)
        let before = try Self.contentCount(pdf)
        var footer = HeaderFooterOptions()
        footer.footerCenter = "footer text"
        let both = try Watermarks.apply(try HeaderFooter.apply(pdf, nil, [0], footer), nil, [0], WatermarkOptions(text: "SECRET", behind: false))
        let noHeader = try HeaderFooter.remove(both, nil)
        let text = try Core2Pdf.allText(noHeader, page: 0, annotations: false)
        #expect(!text.contains("footer text"))
        #expect(text.contains("SECRET"))
        let plain = try Watermarks.remove(noHeader, nil)
        #expect(!(try Core2Pdf.allText(plain)).contains("SECRET"))
        #expect(try Self.contentCount(plain) == before)
        #expect(!(try Watermarks.has(plain, nil)))
        #expect(try Watermarks.remove(plain, nil) == plain)
        #expect(TestPdf.pageNumbers(plain) == [1])
    }

    @Test func applyingAgainReplaces() throws {
        let once = try Watermarks.apply(TestPdf.make(1), nil, [0], WatermarkOptions(text: "FIRST"))
        let twice = try Watermarks.apply(once, nil, [0], WatermarkOptions(text: "SECOND"))
        let text = try Core2Pdf.allText(twice)
        #expect(!text.contains("FIRST"))
        #expect(text.contains("SECOND"))
    }

    @Test func needsATextOrAnImage() {
        let pdf = TestPdf.make(1)
        #expect(throws: PdfEditError.self) { try Watermarks.apply(pdf, nil, [0], WatermarkOptions(text: " ")) }
        #expect(throws: PdfEditError.self) { try Watermarks.apply(pdf, nil, [0], WatermarkOptions(text: "A", image: Self.red())) }
    }
}
