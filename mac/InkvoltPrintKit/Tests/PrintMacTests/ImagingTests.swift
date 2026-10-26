import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PrintCore
import Testing
@testable import PrintMac

/// PrintMac's page and photo drawing: scanned pages turned, cropped and straightened, searchable PDFs, photo sheets. One at
/// a time, the work on `offPool`: it's seconds of CPU, and on a small CI runner it starved the IPP timing tests beside it.
@Suite(.serialized)
struct MacImagingTests {
    private static func cgImage(_ jpeg: [UInt8]) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func aTurnedPageSwapsItsSidesAndACropKeepsItsShare() async throws {
        let (page, turned, cropped, same) = try await offPool { () -> Result<([UInt8], (Int, Int), (Int, Int), Bool), any Error> in
            Result {
                let page = DemoScanPage.jpeg(0, width: 2550, height: 3300) // 1275 × 1650 px
                let turned = try ScanImaging.render(page, PageEdits(quarterTurns: 1))
                let cropped = try ScanImaging.render(page, PageEdits(crop: CropBox(0, 0, 0.5, 0.5)))
                return (page, (turned.width, turned.height), (cropped.width, cropped.height), try ScanImaging.jpeg(page, .none) == page)
            }
        }.get()
        #expect(!page.isEmpty)
        #expect(turned == (1650, 1275))
        #expect(abs(cropped.0 - 638) <= 1 && abs(cropped.1 - 825) <= 1)
        #expect(same) // unedited: the scanner's own bytes
    }

    @Test func aCrookedPageIsStraightenedToWithinHalfADegree() async throws {
        let (skew, after, blank) = try await offPool { () -> Result<(Double, Double, Bool), any Error> in
            Result {
                let crooked = DemoScanPage.jpeg(1, width: 2550, height: 3300)
                let skew = Deskew.angle(try ScanImaging.analysis(crooked))
                let after = Deskew.angle(try ScanImaging.analysis(ScanImaging.jpeg(crooked, PageEdits(deskew: skew))))
                return (skew, after, BlankPage.isBlank(try ScanImaging.analysis(DemoScanPage.jpeg(2, width: 2550, height: 3300))))
            }
        }.get()
        #expect(abs(skew) > 1.5)
        #expect(abs(after) < 0.5)
        #expect(blank)
    }

    @Test func aSearchablePdfHasEachPageAtItsSizeWithItsWords() async throws {
        let data = try await offPool { () -> Result<Data, any Error> in
            Result {
                let page = DemoScanPage.jpeg(0, width: 2550, height: 3300)
                return try ScanPdf.write([ScanPdf.Page(jpeg: page, dpi: 150, words: ScanPdf.recognize(page)), ScanPdf.Page(jpeg: page, dpi: 150)])
            }
        }.get()
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 612) < 1 && abs(box.height - 792) < 1) // 8.5 × 11 in
        let first: String = pdf.page(at: 0)?.string ?? "", second: String = pdf.page(at: 1)?.string ?? ""
        #expect(first.contains("demo scanner"))
        #expect(second.isEmpty)
    }

    @Test func photoSheetsArePagesAtThePapersSize() async throws {
        let photo = try Self.cgImage(DemoScanPage.jpeg(0, width: 1800, height: 1200))
        let inputs = [PhotoInput(Double(photo.width), Double(photo.height), 3, .none)]
        let paper = SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25)
        let sheets = PhotoLayout.sheets(inputs, PhotoLayoutOptions(kind: .printSize, size: PhotoSizes.in4x6), paper)
        #expect(!sheets.isEmpty)
        let data = try await offPool { Result { try PhotoSheets.pdf(sheets, photos: [photo], names: ["photo.jpg"], paper: paper) } }.get()
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == sheets.count)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 612) < 1 && abs(box.height - 792) < 1)
        #expect(PhotoSheets.preview(sheets[0], photos: [photo], names: ["photo.jpg"], paper: paper, width: 200)?.width == 200)
    }
}
