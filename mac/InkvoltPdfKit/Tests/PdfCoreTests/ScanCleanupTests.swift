import Foundation
import Testing
@testable import PdfCore

/// Ported from ScanCleanupTests.cs: cleaning a scanned page before text recognition (roadmap 2.2): straightening up to
/// ±15°, turning upright, smoothing, evening out the paper, removing specks. Pages come from the OCR corpus's generator
/// (`ScanCorpus`, ported with the same seeds), so the expectations are Windows' own. Adapted: colour is RGB on the Mac
/// (Windows' BGR), so ColourIsKeptWhenAsked warms the red channel at index 0.
struct ScanCleanupTests {
    @Test(.enabled(if: ScanCorpus.runs), arguments: [("en-skew3-light", 0), ("en-skew6-noisy", 1), ("en-skew10-shaded", 0), ("es-skew4-noisy", 1), ("es-skew8-shaded", 0)])
    func corpusPagesAreStraightenedAndLeftUpright(_ name: String, _ page: Int) throws {
        let (pixels, w, h, truth) = try ScanCorpus.makePage(ScanCorpus.file(name), page)
        #expect(abs(truth.skew) >= 3 && abs(truth.skew) <= 10)

        let cleaned = try ScanCleanup.clean(pixels, w, h, 1, ScanCorpus.dpi)
        #expect(abs(cleaned.skew - truth.skew) <= 0.3, "\(cleaned.skew) for \(truth.skew)")
        #expect(cleaned.quarterTurns == 0)
        #expect(cleaned.uprightSure)
        #expect(abs(ScanCleanup.skewOf(cleaned.gray, ScanCorpus.dpi)) <= 0.3)
        // The paper is white now, and the ink still dark.
        #expect(GrayImage.median(cleaned.gray, 0, 0, w, h) == 255)
        #expect(cleaned.gray.pixels.contains { $0 < 60 })
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: [(0, 2), (1, 3)]) // upside down: two turns; turned clockwise on the glass: three more make it upright
    func turnedPagesAreTurnedUpright(_ page: Int, _ expected: Int) throws {
        let (pixels, w, h, truth) = try ScanCorpus.makePage(ScanCorpus.file("en-turned"), page)
        #expect(truth.turns != 0)
        let cleaned = try ScanCleanup.clean(pixels, w, h, 1, ScanCorpus.dpi)
        #expect(cleaned.quarterTurns == expected)
        #expect(cleaned.uprightSure)
        let size = expected % 2 == 0 ? (w, h) : (h, w)
        #expect(cleaned.gray.width == size.0 && cleaned.gray.height == size.1)
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: [-15.0, -12.5, 14.0, 15.0])
    func skewsUpToFifteenDegreesAreFound(_ skew: Double) throws {
        let (pixels, w, h, _) = try ScanCorpus.makePage(ScanCorpus.file("en-skew3-light"), 0)
        let straight = try ScanCleanup.clean(pixels, w, h, 1, ScanCorpus.dpi).gray
        let turned = PageRotate.rotate(straight.pixels, w, h, w, 1, skew)
        let found = ScanCleanup.skewOf(GrayImage(w, h, turned), ScanCorpus.dpi)
        #expect(abs(found - skew) <= 0.35, "\(found) for \(skew)")
    }

    @Test func loneSpecksGoButFullStopsAndDotsStay() throws {
        let (w, h) = (300, 200)
        var px = [UInt8](repeating: 255, count: w * h)
        func box(_ x0: Int, _ y0: Int, _ bw: Int, _ bh: Int) {
            for y in y0..<(y0 + bh) {
                for x in x0..<(x0 + bw) { px[y * w + x] = 10 }
            }
        }
        box(40, 60, 6, 30)   // the stem of an i
        box(40, 50, 6, 6)    // its dot, 4 px above
        box(50, 84, 5, 5)    // a full stop after it
        box(260, 170, 4, 4)  // a speck far from everything
        box(250, 30, 3, 2)   // another
        box(150, 100, 40, 40) // a big dark square: not a speck

        let removed = try Despeckle.remove(&px, w, h, 300)
        #expect(removed == 2)
        #expect(px[171 * w + 261] == 255)
        #expect(px[31 * w + 251] == 255)
        #expect(px[52 * w + 42] == 10) // the dot
        #expect(px[86 * w + 52] == 10) // the full stop
        #expect(px[120 * w + 170] == 10)
    }

    @Test func unevenPaperBecomesWhiteAndInkStays() {
        let (w, h) = (600, 400)
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { px[y * w + x] = UInt8(240 - 90 * x / w) } // paper from 240 down to 150 (a lid's shadow)
        }
        for y in 100..<110 {
            for x in stride(from: 20, to: 580, by: 3) { px[y * w + x] = px[y * w + x] / 8 } // a line of ink across the shading
        }
        let paper = PaperLevel.estimate(px, w, h, 300)
        PaperLevel.whiten(&px, paper)
        #expect(px[300 * w + 30] == 255)
        #expect(px[300 * w + 570] == 255) // the shaded side too
        #expect(px[105 * w + 20] < 60)
        #expect(px[105 * w + 578] < 60)
    }

    @Test func turningMovesPixelsClockwise() {
        // 3 × 2: a b c / d e f
        let px: [UInt8] = [1, 2, 3, 4, 5, 6]
        #expect(ScanCleanup.turn(px, 3, 2, 1, 1) == [4, 1, 5, 2, 6, 3]) // 2 × 3: d a / e b / f c
        #expect(ScanCleanup.turn(px, 3, 2, 1, 2) == [6, 5, 4, 3, 2, 1])
        #expect(ScanCleanup.turn(px, 3, 2, 1, 3) == [3, 6, 2, 5, 1, 4])
        #expect(ScanCleanup.turn(ScanCleanup.turn(px, 3, 2, 1, 1), 2, 3, 1, 3) == px)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func colourIsKeptWhenAsked() throws {
        let (gray, w, h, _) = try ScanCorpus.makePage(ScanCorpus.file("en-skew3-light"), 0)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in gray.indices {
            rgb[i * 3] = UInt8(min(255, Int(gray[i]) + 10)) // a warm paper
            rgb[i * 3 + 1] = gray[i]
            rgb[i * 3 + 2] = gray[i]
        }
        let cleaned = try ScanCleanup.clean(rgb, w, h, 3, ScanCorpus.dpi, keepColor: true)
        let color = try #require(cleaned.rgb)
        #expect(color.count == cleaned.gray.pixels.count * 3)
        for i in stride(from: 0, to: cleaned.gray.pixels.count, by: 997) where cleaned.gray.pixels[i] == 255 {
            #expect(color[i * 3] == 255)
        }
    }
}
