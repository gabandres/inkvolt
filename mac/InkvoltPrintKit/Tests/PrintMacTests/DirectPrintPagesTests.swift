import CoreGraphics
import Foundation
import PDFKit
import PrintCore
import Testing
@testable import PrintMac

/// A PDF's pages drawn for a direct print (`DirectPrintPages`, Mac only: Windows draws with WPF in the app, untested there):
/// fitted inside the paper's margins, a landscape page turned a quarter clockwise on portrait paper, made grey, enlarged to the
/// printer's resolution, and the copies the printer doesn't make sent again with a blank back between two-sided copies. Small
/// made-up paper (2 × 3 in at 100 dpi) keeps each page a few thousand pixels.
struct DirectPrintPagesTests {
    /// A one-page PDF `w` × `h` points, white, with a black square of `side` points in its top left corner.
    static func pdf(_ w: CGFloat, _ h: CGFloat, side: CGFloat, pages: Int = 1) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: h - side, width: side, height: side))
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    static func plan(_ margins: Int = 0, dpi: Int = 100, copies: Int = 1, twoSided: Bool = false) -> DirectPrintPlan {
        let paper = DirectPaper("custom", 5080, 7620, margins, margins, margins, margins) // 2 × 3 in
        var plan = DirectPrintPlan(.pwgRaster, dpi: dpi, color: .gray8, paper: paper)
        (plan.repeatCount, plan.twoSided) = (copies, twoSided)
        return plan
    }

    private static func dark(_ p: RasterPage, _ x: Int, _ y: Int) -> Bool { p.pixels[y * p.width + x] < 128 }

    @Test func aPortraitPageFillsThePaperInsideItsMargins() throws {
        let document = try Self.pdf(144, 216, side: 36) // the paper's own size: the square is the top left half inch
        let plan = Self.plan(635) // quarter-inch margins
        let page = try DirectPrintPages.page(try #require(document.page(at: 0)), plan: plan, job: plan.job(1))
        #expect([page.width, page.height] == [200, 300] as [Int])
        #expect(!Self.dark(page, 10, 10)) // the margin stays white
        // Shrunk to 0.75 into the 150 × 250 px area and centred (12.5 px down): the square is at 25-62 across, 37-75 down.
        #expect(Self.dark(page, 30, 45))
        #expect(!Self.dark(page, 30, 30))
        #expect(!Self.dark(page, 70, 45))
        #expect(!Self.dark(page, 190, 290))
    }

    @Test func aLandscapePageIsTurnedAQuarterClockwise() throws {
        let document = try Self.pdf(216, 144, side: 36) // landscape: its top left square ends at the paper's top right
        let plan = Self.plan()
        let page = try DirectPrintPages.page(try #require(document.page(at: 0)), plan: plan, job: plan.job(1))
        #expect(Self.dark(page, 195, 5))
        #expect(!Self.dark(page, 5, 5))
        #expect(!Self.dark(page, 5, 295))
    }

    @Test func pagesAreEnlargedToThePrintersResolution() throws {
        let document = try Self.pdf(144, 216, side: 36)
        let plan = Self.plan(dpi: 600)
        #expect([plan.renderDpi, plan.enlarge] == [300, 2] as [Int])
        let page = try DirectPrintPages.page(try #require(document.page(at: 0)), plan: plan, job: plan.job(1))
        #expect([page.width, page.height] == [1200, 1800] as [Int])
        #expect(Self.dark(page, 10, 10))
        #expect(!Self.dark(page, 1190, 1790))
    }

    @Test func copiesThePrinterDoesntMakeGoAgainWithABlankBackBetween() throws {
        let document = try Self.pdf(144, 216, side: 36, pages: 3)
        let raster = try DirectPrintPages.document(document, plan: Self.plan(copies: 2, twoSided: true))
        // PWG raster's TotalPageCount (header offset 452, after the 4-byte sync word): 3 pages and a blank back, twice.
        let count = raster[4 + 452..<4 + 456].reduce(0) { $0 << 8 | Int($1) }
        #expect(count == 8)
    }
}
