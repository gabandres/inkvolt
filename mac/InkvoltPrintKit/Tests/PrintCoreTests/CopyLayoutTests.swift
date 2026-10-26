import Foundation
import Testing
@testable import PrintCore

/// Copying: the copied page on the paper and the ID card layout. Ported from CopyLayoutTests.cs; all 7 tests, none left
/// out. Adapted: the ID card scan settings test reads the scan region with `XmlElement.kid` instead of LINQ to XML's
/// `Descendants`.
struct CopyLayoutTests {
    // Letter paper and sides in DIPs (96 per inch), like the spooler hands them to the paginator.
    private static let letterW = 816.0, letterH = 1056.0
    private static let cardScan = (w: 4.5 * 96, h: 3 * 96.0)

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 5e-7 }

    @Test func idCardSidesPrintAtActualSizeCentredInEachHalf() {
        let (front, back) = CopyLayout.idCard(Self.letterW, Self.letterH, Self.cardScan, Self.cardScan)

        #expect(front == Placement((816 - 432) / 2.0, (528 - 288) / 2.0, 432, 288))
        #expect(back == Placement((816 - 432) / 2.0, 528 + (528 - 288) / 2.0, 432, 288))
        #expect(front.y + front.height <= Self.letterH / 2)
        #expect(back.y >= Self.letterH / 2)
    }

    @Test func oversizedSidesShrinkTogetherToFitTheirHalfWithMargins() {
        // A whole Letter page scanned by mistake for the back: both sides take its (smaller) scale.
        let (front, back) = CopyLayout.idCard(Self.letterW, Self.letterH, Self.cardScan, (Self.letterW, Self.letterH))

        #expect(back.height <= Self.letterH / 2 - 2 * CopyLayout.idCardMargin + 1e-9)
        #expect(back.y >= Self.letterH / 2 + CopyLayout.idCardMargin - 1e-9)
        let scale = back.height / Self.letterH
        #expect(Self.near(front.width, Self.cardScan.w * scale))
        #expect(Self.near(front.height, Self.cardScan.h * scale))
    }

    @Test func idCardOnA4StaysActualSize() {
        let (front, _) = CopyLayout.idCard(793.7, 1122.5, Self.cardScan, Self.cardScan)

        #expect(front.width == 432 && front.height == 288)
    }

    @Test func copiedPageIsCentredAtActualSizeAndOnlyShrinks() {
        #expect(CopyLayout.page(Self.letterW, Self.letterH, Self.letterW, Self.letterH)
            == PagePlacement(Placement(0, 0, Self.letterW, Self.letterH), false))
        #expect(CopyLayout.page(384, 384, Self.letterW, Self.letterH) == PagePlacement(Placement(216, 336, 384, 384), false)) // small page: not enlarged

        let a4OnLetter = CopyLayout.page(793.7, 1122.5, Self.letterW, Self.letterH).at
        #expect(Self.near(a4OnLetter.height, Self.letterH))
        #expect(Self.near(a4OnLetter.y, 0))
    }

    @Test func landscapeCopyIsTurnedLikeItPrints() {
        // A 6 × 4 in photo on portrait Letter: turned a quarter (as the print path does), not shrunk.
        let p = CopyLayout.page(576, 384, Self.letterW, Self.letterH)

        #expect(p.rotated)
        #expect(p.at == Placement((Self.letterW - 384) / 2, (Self.letterH - 576) / 2, 384, 576))
    }

    @Test func scannedSizeInInchesFromPixelsAndDpi() {
        #expect(CopyLayout.inches(2550, 3300, 300) == (8.5, 11))
        #expect(CopyLayout.inches(675, 450, 150) == (4.5, 3))
        #expect(CopyLayout.inches(100, 100, 0) == (0, 0))
    }

    @Test func idCardScanIsTheGlassCornerAndFitsTheM234dwPlaten() throws {
        let caps = ScannerCapabilities.parse(try DeviceXml.load(Fixtures.data("m234dw/eSCL_ScannerCapabilities.xml")))
        let request = CopyLayout.idCardRequest(.grayscale, 300)

        let settings = try DeviceXml.load(try #require(EsclXml.buildScanSettings(request, caps)))
        let region = try #require(settings.kid("ScanRegions")?.kid("ScanRegion"))

        #expect(request.source == .platen)
        #expect(region.kidValue("Width") == "1350")
        #expect(region.kidValue("Height") == "900")
        #expect(region.kidValue("XOffset") == "0")
        #expect(settings.kidValue("ColorMode") == "Grayscale8")
    }
}
