import Foundation
import Testing
@testable import PdfCore

/// D0: MuPDF builds, links and answers through the shim (EngineTests proper come with D1).
struct EngineSmokeTests {
    @Test func opensAPdfAndCountsItsPages() throws {
        let engine = try PdfEngine.open(TestPdf.make(3))
        #expect(try engine.pageCount == 3)
        let size = try engine.pageSize(0)
        #expect(size.width == 612 && size.height == 792)
    }

    @Test func readsEachPagesText() throws {
        let engine = try PdfEngine.open(TestPdf.make(2, marker: "beta"))
        #expect(try engine.text(1).contains("Page 2 beta"))
        #expect(try engine.text(0).contains("jumps over the lazy dog"))
    }

    @Test func drawsAPageWithInkWhereTheTextIs() throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        let image = try engine.render(0, scale: 0.5)
        #expect(image.width == 306 && image.height == 396)
        #expect(image.pixels.count == 306 * 396 * 3)
        #expect(image.pixels.contains { $0 < 128 }) // the text is drawn
        #expect(image.pixels.first == 255) // the top-left corner is paper
    }

    @Test func aBrokenFileThrowsInsteadOfStopping() {
        #expect(throws: PdfEngineError.self) { try PdfEngine.open(Array("not a pdf".utf8)) }
    }

    @Test func aPageThatIsntThereThrows() throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        #expect(throws: PdfEngineError.self) { try engine.text(5) }
    }
}
