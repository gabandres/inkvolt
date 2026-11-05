import Foundation
import Testing
@testable import PrintCore

/// The scan review's filters (roadmap 2.3), on made-up pages. Ported from PageCleanupTests.cs with the same names; the
/// pages come from a seeded generator of their own (not .NET's Random), and colour pages are RGB as the Mac renders them
/// (Windows' are BGR). What the filters do for a recognizer: pdf/tools/ocr-corpus, cleanup (Windows).
/// One at a time: each check is seconds of CPU, and the huge page's timing would suffer beside the others.
@Suite(.serialized)
struct PageCleanupTests {
    private static let dpi = 300

    /// SplitMix64: repeatable pages.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func next(_ count: Int) -> Int { Int(next() % UInt64(count)) }

        /// In [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    /// A page: paper at `paper`, lines of blocky "words" (ink level `ink`) in the given area.
    private static func textPage(_ w: Int, _ h: Int, paper: UInt8 = 230, ink: UInt8 = 30, left: Int? = nil, top: Int? = nil, right: Int? = nil,
                                 bottom: Int? = nil) -> [UInt8] {
        var px = [UInt8](repeating: paper, count: w * h)
        words(&px, w, left ?? w / 10, top ?? h / 10, right ?? w - w / 10, bottom ?? h - h / 10, ink)
        return px
    }

    private static func words(_ px: inout [UInt8], _ w: Int, _ left: Int, _ top: Int, _ right: Int, _ bottom: Int, _ ink: UInt8) {
        var rng = Rng(state: 7)
        var y = top
        while y + 30 < bottom {
            var x = left
            while x < right - 40 {
                let letters = 3 + rng.next(6)
                var l = 0
                while l < letters && x < right - 20 {
                    fill(&px, w, x, y, 14, 28, ink)
                    l += 1
                    x += 22
                }
                x += 24
            }
            y += 50
        }
    }

    private static func fill(_ px: inout [UInt8], _ w: Int, _ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ level: UInt8) {
        for yy in y..<(y + bh) {
            for xx in x..<(x + bw) { px[yy * w + xx] = level }
        }
    }

    private static func noise(_ px: inout [UInt8], _ sigma: Double, seed: UInt64 = 3) {
        var rng = Rng(state: seed)
        for i in px.indices {
            let g = (-2 * log(1 - rng.unit())).squareRoot() * cos(2 * .pi * rng.unit())
            px[i] = UInt8(min(max(Double(px[i]) + g * sigma, 0), 255))
        }
    }

    /// A sheet (its own pixels) on a lid of the given level; the scan is w × h at 100 pixels an inch (the analysis copy).
    private static func onLid(_ sheet: [UInt8], _ sw: Int, _ sh: Int, _ w: Int, _ h: Int, _ x0: Int, _ y0: Int, _ lid: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: lid, count: w * h)
        for y in 0..<sh { px.replaceSubrange(((y + y0) * w + x0)..<((y + y0) * w + x0 + sw), with: sheet[(y * sw)..<(y * sw + sw)]) }
        return px
    }

    private static func inside(_ found: CropBox?, _ x: Double, _ y: Double, _ right: Double, _ bottom: Double, _ tolerance: Double = 0.012) {
        guard let b = found else {
            Issue.record("no crop found")
            return
        }
        #expect(b.x >= x - tolerance && b.x <= x + 0.002, "x \(b.x)")
        #expect(b.y >= y - tolerance && b.y <= y + 0.002, "y \(b.y)")
        #expect(b.x + b.width >= right - 0.002 && b.x + b.width <= right + tolerance, "right \(b.x + b.width)")
        #expect(b.y + b.height >= bottom - 0.002 && b.y + b.height <= bottom + tolerance, "bottom \(b.y + b.height)")
    }

    // MARK: Crop to the paper

    private static let glassW = 850, glassH = 1170, ppi = 100.0 // a whole glass at the analysis copy's size

    private static func smallSheet(_ paper: UInt8, _ ink: UInt8 = 40) -> [UInt8] { textPageSmall(600, 800, paper, ink) }

    private static func textPageSmall(_ w: Int, _ h: Int, _ paper: UInt8, _ ink: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: paper, count: w * h)
        for y in Swift.stride(from: 60, to: h - 60, by: 22) {
            for x in Swift.stride(from: 60, to: w - 60, by: 7) where (x + y) % 41 != 0 && x % 49 > 7 { fill(&px, w, x, y, 5, 10, ink) }
        }
        return px
    }

    private static func glass(_ px: [UInt8]) -> GrayImage { GrayImage(width: glassW, height: glassH, pixels: px) }

    @Test func aStripNarrowerThanTheEdgeItMeasuresHasNoEdgeRatherThanACrash() {
        let pixels = [UInt8](repeating: 255, count: 1000 * 40)
        #expect(PaperEdge.find(GrayImage(width: 1000, height: 40, pixels: pixels), ppi: 1200) == nil)
        #expect(PaperEdge.find(GrayImage(width: 40, height: 1000, pixels: pixels), ppi: 1200) == nil)
    }

    @Test func aPageTooLargeToCleanSavesAsScanned() {
        let clean = PageEdits(filters: [.whiten, .descreen])
        #expect(!clean.for(width: 4000, height: 3000).isEmpty)
        #expect(clean.for(width: 20000, height: 20000).isEmpty)
        var turned = clean
        turned.quarterTurns = 1
        #expect(turned.for(width: 20000, height: 20000) == PageEdits(quarterTurns: 1))
    }

    @Test func aGreySheetOnAWhiteLidIsCroppedToItsEdge() {
        let scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        Self.inside(PaperEdge.find(Self.glass(scan), ppi: Self.ppi), 120.0 / 850, 150.0 / 1170, 720.0 / 850, 950.0 / 1170)
    }

    @Test func aSheetInTheCornerOfTheGlassShowsLidOnTwoSidesOnly() {
        let scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 0, 0, 245)
        Self.inside(PaperEdge.find(Self.glass(scan), ppi: Self.ppi), 0, 0, 600.0 / 850, 800.0 / 1170)
    }

    @Test func aDarkSheetOnAWhiteLidKeepsAllOfItself() {
        let scan = Self.onLid(Self.smallSheet(40, 220), 600, 800, Self.glassW, Self.glassH, 100, 100, 245)
        Self.inside(PaperEdge.find(Self.glass(scan), ppi: Self.ppi), 100.0 / 850, 100.0 / 1170, 700.0 / 850, 900.0 / 1170)
    }

    @Test func aPagePrintedToItsEdgesIsKeptWhole() {
        var page = [UInt8](repeating: 240, count: Self.glassW * Self.glassH)
        for y in Swift.stride(from: 0, to: Self.glassH - 12, by: 22) {
            for x in Swift.stride(from: 0, to: Self.glassW - 6, by: 7) { Self.fill(&page, Self.glassW, x, y, 5, 10, 30) }
        }
        #expect(PaperEdge.find(Self.glass(page), ppi: Self.ppi) == nil)
    }

    @Test func anAllDarkPageIsKeptWhole() {
        var page = [UInt8](repeating: 25, count: Self.glassW * Self.glassH)
        Self.fill(&page, Self.glassW, 200, 300, 400, 300, 220)
        #expect(PaperEdge.find(Self.glass(page), ppi: Self.ppi) == nil)
    }

    @Test func aWhiteSheetUnderAWhiteLidIsKeptWhole() {
        let page = Self.textPageSmall(Self.glassW, Self.glassH, 240, 40)
        #expect(PaperEdge.find(Self.glass(page), ppi: Self.ppi) == nil)
    }

    @Test func aPictureWithACaptionBelowItIsNotMistakenForASheet() {
        var page = [UInt8](repeating: 240, count: Self.glassW * Self.glassH)
        Self.fill(&page, Self.glassW, 150, 150, 500, 500, 120)
        for x in Swift.stride(from: 150, to: 600, by: 8) { Self.fill(&page, Self.glassW, x, 700, 5, 10, 30) } // the caption
        #expect(PaperEdge.find(Self.glass(page), ppi: Self.ppi) == nil)
    }

    @Test func aFaintNoteOutsideAPictureStopsTheCrop() {
        var page = [UInt8](repeating: 240, count: Self.glassW * Self.glassH)
        Self.fill(&page, Self.glassW, 150, 150, 500, 500, 120)
        Self.fill(&page, Self.glassW, 150, 800, 300, 2, 228) // twelve levels under the paper, a pencil line
        #expect(PaperEdge.find(Self.glass(page), ppi: Self.ppi) == nil)
    }

    @Test func dustOutsideTheSheetDoesNotStopTheCrop() {
        var scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        for (x, y) in [(20, 30), (800, 100), (50, 1100), (780, 1000)] { Self.fill(&scan, Self.glassW, x, y, 3, 3, 60) }
        #expect(PaperEdge.find(Self.glass(scan), ppi: Self.ppi) != nil)
    }

    @Test func aLineOfTinyLettersOutsideStopsTheCrop() {
        var scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        for x in Swift.stride(from: 150, to: 450, by: 6) { Self.fill(&scan, Self.glassW, x, 1050, 3, 4, 80) } // each no bigger than dust, together a caption
        #expect(PaperEdge.find(Self.glass(scan), ppi: Self.ppi) == nil)
    }

    @Test func aLoneLetterOutsideStopsTheCrop() {
        var scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        Self.fill(&scan, Self.glassW, 780, 1050, 12, 14, 40)
        #expect(PaperEdge.find(Self.glass(scan), ppi: Self.ppi) == nil)
    }

    @Test func aNoisyScanStillFindsTheSheet() {
        var scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        Self.noise(&scan, 4)
        Self.inside(PaperEdge.find(Self.glass(scan), ppi: Self.ppi), 120.0 / 850, 150.0 / 1170, 720.0 / 850, 950.0 / 1170, 0.03)
    }

    @Test func aCrookedSheetIsCroppedInTheStraightenedPage() {
        let scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        let turned = PageRotate.rotate(scan, width: Self.glassW, height: Self.glassH, stride: Self.glassW, channels: 1, degrees: 4, fill: 245)
        Self.inside(PaperEdge.find(Self.glass(turned), ppi: Self.ppi, deskew: 4), 120.0 / 850, 150.0 / 1170, 720.0 / 850, 950.0 / 1170, 0.02)
    }

    @Test(arguments: [(1, 1), (2, 500), (31, 31)] as [(Int, Int)])
    func tinyImagesHaveNoEdge(_ w: Int, _ h: Int) {
        #expect(PaperEdge.find(GrayImage(width: w, height: h, pixels: [UInt8](repeating: 0, count: w * h)), ppi: Self.ppi) == nil)
    }

    /// Mac addition: an image whose pixels don't fill it, or a resolution no scan has, is no sheet rather than a crash.
    @Test func anImageShorterThanItsSizeOrANonsenseResolutionHasNoEdge() {
        #expect(PaperEdge.find(GrayImage(width: Self.glassW, height: Self.glassH, pixels: [UInt8](repeating: 240, count: 100)), ppi: Self.ppi) == nil)
        let scan = Self.onLid(Self.smallSheet(205), 600, 800, Self.glassW, Self.glassH, 120, 150, 245)
        for ppi in [Double.nan, .infinity, 1e300] { #expect(PaperEdge.find(Self.glass(scan), ppi: ppi) == nil) }
        #expect(PaperEdge.find(Self.glass(scan), ppi: Self.ppi, deskew: .nan) == nil)
    }

    // MARK: Whiten

    private static func whitened(_ px: [UInt8], _ w: Int, _ h: Int, channels: Int = 1, dpi: Int = PageCleanupTests.dpi) throws -> [UInt8] {
        try PageCleanup.apply(px, width: w, height: h, channels: channels, dpi: dpi, .whiten).pixels
    }

    private static func whiteShare(_ px: [UInt8], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ w: Int) -> Double {
        var (white, all) = (0, 0)
        for y in y0..<y1 {
            for x in x0..<x1 {
                all += 1
                if px[y * w + x] == 255 { white += 1 }
            }
        }
        return Double(white) / Double(all)
    }

    @Test func aGreyPageGoesWhiteAndItsTextStays() throws {
        let (w, h) = (1200, 1500)
        var page = Self.textPage(w, h, paper: 190, ink: 30)
        Self.noise(&page, 5)
        let clean = try Self.whitened(page, w, h)
        let share = Self.whiteShare(clean, 0, 0, w, h / 20, w)
        #expect(share > 0.97, "\(share) of the margin is white")
        #expect(clean[(h / 10 + 14) * w + w / 10 + 7] < 90, "ink stays dark")
    }

    @Test func unevenPaperGoesWhiteAllOver() throws {
        let (w, h) = (1200, 1500)
        var page = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { page[y * w + x] = UInt8(236 - 60.0 * Double(x * x) / Double(w * w)) }
        }
        Self.noise(&page, 3)
        let clean = try Self.whitened(page, w, h)
        let share = Self.whiteShare(clean, 0, 0, w, h, w)
        #expect(share > 0.97, "\(share)")
    }

    @Test(arguments: [(25, 0.0), (25, 4.0), (40, 10.0)] as [(Int, Double)]) // a pencil line 25 levels under the paper, one pixel wide
    func aFaintThinSignatureSurvives(_ contrast: Int, _ noise: Double) throws {
        let (w, h) = (1200, 1500)
        let paper: UInt8 = 225
        var page = Self.textPage(w, h, paper: paper, ink: 30, top: 100, bottom: 700)
        // A curve one pixel wide, like a signature in hard pencil.
        var stroke: [Int] = []
        var last = 1000
        for x in 200..<1000 {
            let y = 1000 + Int(80 * sin(Double(x) / 30))
            for yy in min(y, last)...max(y, last) {
                page[yy * w + x] = paper - UInt8(contrast)
                stroke.append(yy * w + x)
            }
            last = y
        }
        var noisy = page
        if noise > 0 { Self.noise(&noisy, noise) }
        let clean = try Self.whitened(noisy, w, h)
        let kept = stroke.filter { clean[$0] < 250 }.count
        #expect(Double(kept) > Double(stroke.count) * 0.7, "\(kept) of \(stroke.count) pixels of the stroke kept")
    }

    @Test func aDarkPageIsLeftAlone() throws {
        let (w, h) = (800, 1000)
        let page = Self.textPage(w, h, paper: 40, ink: 220)
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .whiten)
        #expect(result.done == [])
        #expect(result.pixels == page)
    }

    @Test func aPhotoOnThePageIsNotWashedOut() throws {
        let (w, h) = (1200, 1500)
        var page = Self.textPage(w, h, paper: 235, ink: 30, top: 900)
        // A picture of mid-tones: a gradient with detail, its bright parts close to the paper.
        for y in 100..<800 {
            for x in 200..<1000 { page[y * w + x] = UInt8(60 + 170.0 * Double(y - 100) / 700 + 12 * sin(Double(x) / 5)) }
        }
        let clean = try Self.whitened(page, w, h)
        var (before, after) = (0.0, 0.0)
        var white = 0
        for y in 150..<750 {
            for x in 250..<950 {
                before += Double(page[y * w + x])
                after += Double(clean[y * w + x])
                if clean[y * w + x] == 255 { white += 1 }
            }
        }
        let count = 600.0 * 700
        #expect(after / count >= before / count - 5 && after / count <= before / count + 25, "mean \(before / count) → \(after / count)")
        #expect(Double(white) < count / 20, "\(white) of \(count) pixels went white") // only its lightest end, where it meets the paper's level
    }

    @Test func aColoredStampStaysItsColor() throws {
        let (w, h) = (800, 1000)
        var page = [UInt8](repeating: 0, count: w * h * 3)
        for i in Swift.stride(from: 0, to: page.count, by: 3) { (page[i], page[i + 1], page[i + 2]) = (210, 205, 195) }
        for y in 400..<500 {
            for x in 300..<500 { (page[(y * w + x) * 3], page[(y * w + x) * 3 + 1], page[(y * w + x) * 3 + 2]) = (170, 40, 40) }
        }
        let clean = try Self.whitened(page, w, h, channels: 3)
        let at = (450 * w + 400) * 3
        #expect(Int(clean[at]) > Int(clean[at + 2]) + 80, "RGB \(clean[at]),\(clean[at + 1]),\(clean[at + 2])")
        #expect([clean[3], clean[4], clean[5]] == [255, 255, 255])
    }

    @Test func loneSpecksGoAndAFullStopStays() throws {
        let (w, h) = (1200, 1500)
        var page = Self.textPage(w, h, paper: 230, ink: 30, top: 200, bottom: 600)
        Self.fill(&page, w, 600, 1200, 6, 6, 40) // a speck, far from anything
        Self.fill(&page, w, 130, 232, 5, 5, 30) // a full stop on a line of text
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .whiten)
        #expect(result.specks >= 1)
        #expect(result.pixels[1203 * w + 603] == 255)
        #expect(result.pixels[234 * w + 132] < 128, "the full stop")
    }

    @Test func theScanItselfIsNeverWrittenTo() throws {
        let (w, h) = (800, 1000)
        var page = Self.textPage(w, h, paper: 190, ink: 30)
        Self.noise(&page, 8)
        let copy = Array(page)
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .pixelFilters)
        #expect(page == copy)
        #expect(result.pixels != page)
    }

    @Test func filtersGiveTheSamePageTwice() throws {
        let (w, h) = (800, 1000)
        var page = Self.textPage(w, h, paper: 190, ink: 30)
        Self.noise(&page, 8)
        let a = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .pixelFilters).pixels
        let b = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .pixelFilters).pixels
        #expect(a == b)
    }

    // MARK: Descreen

    /// A screen of round dots at 45°, period given, so a mid-grey of level tone.
    private static func screen(_ px: inout [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ period: Double, _ tone: Double) {
        let root2 = 2.0.squareRoot()
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (u, v) = (Double(x + y) / root2, Double(x - y) / root2)
                let spot = (cos(2 * .pi * u / period) + cos(2 * .pi * v / period)) / 4 + 0.5 // 0..1
                px[y * w + x] = spot > tone ? 25 : 235
            }
        }
    }

    private static func stats(_ px: [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (mean: Double, spread: Double) {
        var (sum, squares) = (0.0, 0.0)
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = Double(px[y * w + x])
                sum += v
                squares += v * v
                n += 1
            }
        }
        let mean = sum / Double(n)
        return (mean, max(0, squares / Double(n) - mean * mean).squareRoot())
    }

    @Test(arguments: [(4.6, 300), (3.5, 300), (5.6, 600), (9.2, 600)] as [(Double, Int)]) // 65 and 85 lines an inch at 300 dpi, 106 and 65 at 600
    func halftoneDotsGoAndTheToneStays(_ period: Double, _ dpi: Int) throws {
        let (w, h) = (1400, 1800)
        var page = [UInt8](repeating: 235, count: w * h)
        Self.screen(&page, w, 200, 200, 1200, 1000, period, 0.55)
        let before = Self.stats(page, w, 300, 300, 1100, 900)
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: dpi, .descreen)
        #expect(result.done == .descreen)
        let after = Self.stats(result.pixels, w, 300, 300, 1100, 900)
        #expect(after.spread < before.spread * 0.15, "spread \(before.spread) → \(after.spread)")
        #expect(abs(after.mean - before.mean) <= 3, "mean \(before.mean) → \(after.mean)")
    }

    @Test func descreeningLeavesTextBesideThePictureByteForByte() throws {
        let (w, h) = (1400, 1800)
        var page = Self.textPage(w, h, paper: 235, ink: 30, top: 1100, bottom: 1700)
        Self.screen(&page, w, 200, 100, 1200, 900, 4.6, 0.55)
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .descreen)
        #expect(result.done == .descreen)
        #expect(page[(1050 * w)...] == result.pixels[(1050 * w)...])
    }

    @Test func aPageOfTextHasNothingToDescreen() throws {
        let (w, h) = (1200, 1500)
        let page = Self.textPage(w, h, paper: 235, ink: 30)
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .descreen)
        #expect(result.done == [])
        #expect(result.pixels == page)
    }

    @Test func aBarCodeHasNothingToDescreen() throws {
        let (w, h) = (1200, 1500)
        var page = [UInt8](repeating: 240, count: w * h)
        for x in Swift.stride(from: 200, to: 1000, by: 6) { Self.fill(&page, w, x, 300, 3, 600, 20) }
        #expect(try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .descreen).done == [])
    }

    @Test func aPreviewAtLowResolutionIsLeftAlone() throws {
        let (w, h) = (480, 620)
        var page = [UInt8](repeating: 0, count: w * h)
        Self.screen(&page, w, 0, 0, w, h, 4.6, 0.5)
        #expect(try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: 60, .descreen).done == [])
    }

    // MARK: Restore colors

    private static func colorPage(_ w: Int, _ h: Int, _ at: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var page = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w { (page[(y * w + x) * 3], page[(y * w + x) * 3 + 1], page[(y * w + x) * 3 + 2]) = at(x, y) }
        }
        return page
    }

    @Test func aFadedPrintGetsItsRangeAndItsNeutralsBack() throws {
        let (w, h) = (600, 400)
        // A grey ramp with a cast: blacks lifted, reds kept while blues and greens fade.
        let page = Self.colorPage(w, h) { x, _ in
            let v = 255.0 * Double(x) / Double(w - 1)
            return (UInt8(60 + v * 0.75), UInt8(70 + v * 0.55), UInt8(90 + v * 0.45))
        }
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 3, dpi: Self.dpi, .restoreColors)
        #expect(result.done == .restoreColors)
        let px = result.pixels
        func pixel(_ x: Int) -> [UInt8] { [px[(200 * w + x) * 3], px[(200 * w + x) * 3 + 1], px[(200 * w + x) * 3 + 2]] }
        for v in pixel(5) { #expect(v < 25, "black \(v)") }
        for v in pixel(w - 6) { #expect(v > 235, "white \(v)") }
        let middle = pixel(w / 2)
        #expect(middle.max()! - middle.min()! < 30, "RGB \(middle)")
    }

    @Test func fadedGreyTextGetsDarker() throws {
        let (w, h) = (800, 1000)
        let page = Self.textPage(w, h, paper: 225, ink: 150)
        let px = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .restoreColors).pixels
        #expect(px[(h / 10 + 14) * w + w / 10 + 7] < 30)
        #expect(px[5] > 245)
    }

    @Test func aPageAtFullRangeIsNearlyUnchanged() throws {
        let (w, h) = (512, 256)
        var page = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { page[y * w + x] = UInt8(x / 2) }
        }
        let px = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: Self.dpi, .restoreColors).pixels
        for i in Swift.stride(from: 0, to: page.count, by: 97) { #expect(abs(Int(px[i]) - Int(page[i])) <= 5) }
    }

    @Test func aDarkPageAndABlankPageAreLeftAlone() throws {
        let (w, h) = (400, 400)
        let dark = Self.textPage(w, h, paper: 40, ink: 10)
        #expect(try PageCleanup.apply(dark, width: w, height: h, channels: 1, dpi: Self.dpi, .restoreColors).done == [])
        let blank = [UInt8](repeating: 233, count: w * h)
        #expect(try PageCleanup.apply(blank, width: w, height: h, channels: 1, dpi: Self.dpi, .restoreColors).done == [])
    }

    // MARK: Any page

    @Test(arguments: [(1, 1), (3, 2), (8, 8), (7, 2000), (2000, 7)] as [(Int, Int)])
    func tinyAndThinPagesComeThrough(_ w: Int, _ h: Int) throws {
        for channels in [1, 3] {
            var rng = Rng(state: 1)
            let page = (0..<(w * h * channels)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            #expect(try PageCleanup.apply(page, width: w, height: h, channels: channels, dpi: Self.dpi, .pixelFilters).pixels.count == page.count)
        }
    }

    @Test func aPageTooLargeIsLeftAsItIsBeforeAnyMemoryIsTaken() throws {
        let page = [UInt8](repeating: 0, count: 16)
        let result = try PageCleanup.apply(page, width: 20_000, height: 20_000, channels: 3, dpi: 1200, .pixelFilters)
        #expect(result.done == [])
        #expect(page.withUnsafeBufferPointer { $0.baseAddress } == result.pixels.withUnsafeBufferPointer { $0.baseAddress }) // the same buffer, not a copy
    }

    /// Mac addition: what a caller can get wrong (sizes that don't match the pixels, channels, a resolution no scan has)
    /// leaves the page as it is, never a crash.
    @Test func sizesThatDontMatchThePixelsLeaveThePageAsItIs() throws {
        let page = Self.textPage(400, 400)
        for (w, h, channels) in [(400, 401, 1), (400, 400, 3), (400, 400, 4), (400, 400, 0), (-400, -400, 1), (Int.max, 2, 1), (0, 400, 1)] {
            let result = try PageCleanup.apply(page, width: w, height: h, channels: channels, dpi: Self.dpi, .pixelFilters)
            #expect(result.done == [] && result.pixels == page, "\(w) × \(h) × \(channels)")
        }
        for dpi in [Int.min, -300, 0, Int.max] { _ = try PageCleanup.apply(page, width: 400, height: 400, channels: 1, dpi: dpi, .pixelFilters) }
    }

    @Test func aCancelledTokenStopsBeforeAnythingStarts() {
        let stop = BatchStop()
        stop.stop()
        #expect(throws: CancellationError.self) {
            try PageCleanup.apply([UInt8](repeating: 0, count: 100), width: 10, height: 10, channels: 1, dpi: Self.dpi, .whiten, stop: stop)
        }
    }

    @Test func aHugePageIsCleanedInReasonableTimeAndCancelsQuickly() throws {
        // 600 dpi Letter in grey: 33.7 million pixels. The limits are generous: other builds run beside these tests.
        let (w, h) = (5100, 6600)
        var page = Self.textPage(w, h, paper: 200, ink: 30)
        Self.screen(&page, w, 500, 500, 2500, 2500, 9.2, 0.5)
        var clock = ContinuousClock.now
        let result = try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: 600, .pixelFilters)
        #expect(ContinuousClock.now - clock < .seconds(120), "\(ContinuousClock.now - clock)")
        #expect(result.done == .pixelFilters)

        let stop = BatchStop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { stop.stop() }
        clock = ContinuousClock.now
        #expect(throws: CancellationError.self) { try PageCleanup.apply(page, width: w, height: h, channels: 1, dpi: 600, .pixelFilters, stop: stop) }
        #expect(ContinuousClock.now - clock < .seconds(20), "cancelled after \(ContinuousClock.now - clock)")
    }

    // MARK: Edits, recovery, presets

    @Test func aFilterMakesAPageEditedAndTheCropFlagAloneDoesNot() {
        #expect(!PageEdits(filters: .whiten).isEmpty)
        #expect(PageEdits(filters: .cropToPaper).isEmpty)
        #expect(PageEdits(filters: .whiten) != PageEdits(filters: .descreen))
    }

    @Test func croppingByHandMeansTheCropIsNoLongerThePapers() {
        let edits = PageEdits(crop: CropBox(0.1, 0.1, 0.5, 0.5), filters: [.cropToPaper, .whiten])
        let drawn = edits.withShownCrop(CropBox(0.2, 0.2, 0.4, 0.4))
        #expect(drawn.filters == .whiten)
    }

    @Test func aKeptPageKeepsItsFiltersAndLanguage() throws {
        var kept = KeptPage("p.jpg", dpi: 300, ocr: true)
        kept.filters = [.descreen, .cropToPaper]
        kept.ocrLanguage = "ru"
        let back = try JSONDecoder().decode(KeptPage.self, from: JSONEncoder().encode(kept))
        #expect(back.edits.filters == [.descreen, .cropToPaper])
        #expect(back.ocrLanguage == "ru")
        // A list written before filters existed reads as none.
        let old = #"{"file":"p.jpg","dpi":300,"ocr":true,"quarterTurns":0,"deskew":0,"skipped":false,"startsFile":false}"#
        #expect(try JSONDecoder().decode(KeptPage.self, from: Data(old.utf8)).edits.filters == [])
    }

    @Test func presetsKeepTheirFiltersOffUnlessAskedAndUnknownBitsAreDropped() throws {
        for p in ScanPresets.builtIns() { #expect(p.cleanup == []) }
        var item = ScanPreset()
        item.id = "a"
        item.name = "A"
        item.cleanup = PageFilters(rawValue: 0xFF)
        item.ocrLanguage = "ja"
        let stored = ScanPresetSettings(items: [item])
        let preset = ScanPresets.normalize(try JSONDecoder().decode(ScanPresetSettings.self, from: JSONEncoder().encode(stored)))[0]
        #expect(preset.cleanup == .all)
        #expect(preset.ocrLanguage == "ja")
        #expect(ScanPresetText.summary(preset).contains("whitened"))
    }

    @Test func aPresetWrittenBeforeFiltersReadsAsNone() throws {
        let old = try JSONDecoder().decode(ScanPresetSettings.self, from: Data(#"{"Version":1,"Items":[{"Id":"a","Name":"A"}]}"#.utf8))
        #expect(ScanPresets.normalize(old)[0].cleanup == [])
    }

    /// Mac addition: the Windows app writes the filters as their number, and reads the Mac's the same way.
    @Test func aPresetsFiltersAreStoredAsWindowsStoresThem() throws {
        var item = ScanPreset()
        item.cleanup = [.cropToPaper, .descreen]
        item.ocrLanguage = "es-MX"
        let json = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(json.contains(#""Cleanup":5"#))
        #expect(json.contains(#""OcrLanguage":"es-MX""#))
        let windows = try JSONDecoder().decode(ScanPreset.self, from: Data(#"{"Id":"a","Name":"A","Cleanup":10,"OcrLanguage":null}"#.utf8))
        #expect(windows.cleanup == [.whiten, .restoreColors])
        #expect(windows.ocrLanguage == nil)
        #expect(windows.unknown == nil)
    }
}

/// Which steps a page's clean up runs, as the Windows review decides them (ScanViewModel's page check and clean up view,
/// which have no tests of their own there): Mac tests of PrintCore's `ScanPages` and `PageEdits`.
struct PageCleanupStepsTests {
    private static let edge = CropBox(0.1, 0.1, 0.7, 0.7)

    private static func analysed(_ cleanup: PageFilters, looksBlank: Bool = false, skipBlank: Bool = true, separator: SeparatorFound = .none,
                                 photos: [PhotoBox]? = nil, paperEdge: CropBox? = edge, edits: PageEdits = .none, skew: Double = 2,
                                 straighten: Bool = true) -> ScannedPage {
        var pages = ScanPages([ScannedPage(id: "a", dpi: 300, edits: edits)])
        pages.analysed("a", looksBlank: looksBlank, skew: skew, skipBlank: skipBlank, straighten: straighten, separator: separator, photos: photos,
                       cleanup: cleanup, paperEdge: paperEdge)
        return pages.page("a")!
    }

    @Test func aScansCleanUpGoesOnEachPageWithItsEdgeAndItsStraightening() {
        let p = Self.analysed(.all)
        #expect(p.edits == PageEdits(deskew: 2, crop: Self.edge, filters: .all))
        #expect(p.note == "Cropped to the paper, whitened, descreened, colors restored")
        let noEdge = Self.analysed(.all, paperEdge: nil)
        #expect(noEdge.edits == PageEdits(deskew: 2, filters: .pixelFilters))
        #expect(Self.analysed([]).edits == PageEdits(deskew: 2))
    }

    @Test func blankPagesSeparatorsAndEditedPagesAreNotCleanedUp() {
        #expect(Self.analysed(.all, looksBlank: true).edits == .none)
        #expect(Self.analysed(.all, looksBlank: true, skipBlank: false).edits == PageEdits(deskew: 2)) // kept, still not cleaned
        #expect(Self.analysed(.all, separator: SeparatorFound(.patchCode)).edits == .none)
        let byHand = PageEdits(crop: CropBox(0.2, 0.2, 0.5, 0.5))
        #expect(Self.analysed(.all, edits: byHand).edits == byHand)
    }

    /// The edge is found on the page straightened by the skew the check measured: a page straightened by another angle (edited
    /// during the check, or not straightened) would be cut in the wrong place, so it keeps its whole page.
    @Test func thePaperEdgeCropsOnlyAPageStraightenedAsItWasMeasured() {
        let turned = PageEdits(quarterTurns: 1)
        #expect(Self.analysed(.all, edits: turned).edits == PageEdits(quarterTurns: 1, filters: .pixelFilters))
        #expect(Self.analysed(.all, edits: turned, skew: 0).edits == PageEdits(quarterTurns: 1, crop: Self.edge, filters: .all))
        #expect(Self.analysed(.all, straighten: false).edits == PageEdits(filters: .pixelFilters))
        #expect(Self.analysed(.all).edits == PageEdits(deskew: 2, crop: Self.edge, filters: .all))
        #expect(PageEdits(deskew: 1).cleanedUp(.all, photos: false, paperEdge: Self.edge, measuredAt: 2) == PageEdits(deskew: 1, filters: .pixelFilters))
        #expect(PageEdits(deskew: 1).cleanedUp(.cropToPaper, photos: false, paperEdge: Self.edge, measuredAt: 2) == nil)
    }

    @Test func photosOnTheGlassGetOnlyWhatSuitsAPrint() {
        let photo = PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.2, angle: 0)
        let p = Self.analysed(.all, photos: [photo])
        #expect(p.edits.filters == [.descreen, .restoreColors])
        #expect(p.edits.crop == nil)
        #expect(p.note == "1 photo, descreened, colors restored")
        // Photos looked for and none found: the whole scan is the page, but its edge wasn't looked for.
        #expect(Self.analysed(.all, photos: []).edits.filters == .pixelFilters)
    }

    @Test func choosingFiltersForAPageLooksForTheEdgeOnlyWhenItIsNew() {
        var looked = 0
        func edge() -> CropBox? {
            looked += 1
            return Self.edge
        }
        let start = PageEdits(deskew: 1)
        let cropped = start.withFilters(.all, photos: false, paperEdge: edge)
        #expect(cropped == PageEdits(deskew: 1, crop: Self.edge, filters: .all))
        #expect(cropped.withFilters([.cropToPaper, .whiten], photos: false, paperEdge: edge) == PageEdits(deskew: 1, crop: Self.edge, filters: [.cropToPaper, .whiten]))
        #expect(looked == 1)
        #expect(cropped.withFilters(.whiten, photos: false, paperEdge: edge) == PageEdits(deskew: 1, filters: .whiten))
        #expect(start.withFilters(.all, photos: false) { nil } == PageEdits(deskew: 1, filters: .pixelFilters))
        #expect(start.withFilters(.all, photos: true, paperEdge: edge) == PageEdits(deskew: 1, filters: .pixelFilters))
        #expect(looked == 1)
    }

    @Test func theScanSaysHowManyPagesWereCleanedAndWhichHadNoEdge() {
        var pages = ScanPages([ScannedPage(id: "a", dpi: 300), ScannedPage(id: "b", dpi: 300), ScannedPage(id: "c", dpi: 300)])
        pages.analysed("a", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .all, paperEdge: Self.edge)
        pages.analysed("b", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .all, paperEdge: nil)
        pages.analysed("c", looksBlank: true, skew: 0, skipBlank: true, straighten: true, cleanup: .all, paperEdge: nil)
        #expect(pages.cleanupSummary(["a", "b", "c"], .all) == "2 pages were cleaned up (Undo puts them back). The paper's edge couldn't be told from the lid on 1 page: kept whole.")
        #expect(pages.cleanupSummary(["a"], .cropToPaper) == "1 page was cleaned up (Undo puts it back).")
        #expect(pages.cleanupSummary(["a"], []) == "")
    }

    /// No edge is counted only where it was looked for and not found: not on a page cropped by hand, one cleaned up by hand
    /// during the check, one not checked yet, or one whose edge was found at another straightening.
    @Test func onlyPagesTheEdgeWasLookedForOnCountAsHavingNoEdge() {
        var pages = ScanPages([ScannedPage(id: "hand", dpi: 300, edits: PageEdits(crop: CropBox(0.2, 0.2, 0.5, 0.5))),
                               ScannedPage(id: "filters", dpi: 300, edits: PageEdits(filters: .whiten)),
                               ScannedPage(id: "turned", dpi: 300, edits: PageEdits(quarterTurns: 1)), ScannedPage(id: "later", dpi: 300)])
        pages.analysed("hand", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .cropToPaper, paperEdge: nil)
        pages.analysed("filters", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .cropToPaper, paperEdge: nil)
        pages.analysed("turned", looksBlank: false, skew: 2, skipBlank: true, straighten: true, cleanup: .cropToPaper, paperEdge: Self.edge)
        let all = ["hand", "filters", "turned", "later"]
        #expect(pages.cleanupSummary(all, .cropToPaper) == "")
        pages.analysed("later", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .cropToPaper, paperEdge: nil)
        #expect(pages.cleanupSummary(all, .cropToPaper) == "The paper's edge couldn't be told from the lid on 1 page: kept whole.")
    }

    /// Cleaned up is what the check changed (the Windows app's `BeforeCleanup`), not every page with filters: one given
    /// filters by hand during the check is left alone, and isn't one step of the scan's Undo.
    @Test func onlyPagesTheCheckCleanedUpAreCountedAsCleanedUp() {
        var pages = ScanPages([ScannedPage(id: "a", dpi: 300, edits: PageEdits(filters: .whiten)), ScannedPage(id: "b", dpi: 300)])
        #expect(pages.analysed("a", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .whiten) == nil)
        #expect(pages.cleanupSummary(["a", "b"], .whiten) == "")
        #expect(pages.analysed("b", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: .whiten) == PageEdits.none)
        #expect(pages.cleanupSummary(["a", "b"], .whiten) == "1 page was cleaned up (Undo puts it back).")
    }

    @Test func aPagesFiltersAndLanguageSurviveARestart() {
        var pages = ScanPages([ScannedPage(id: "a", dpi: 300, ocrLanguage: "ar")])
        pages.analysed("a", looksBlank: false, skew: 0, skipBlank: true, straighten: true, cleanup: [.whiten, .cropToPaper], paperEdge: Self.edge)
        let kept = pages.kept(printerId: "p", printerName: "P", ocr: true, now: Date(timeIntervalSince1970: 0))
        #expect(kept.pages[0].filters == [.whiten, .cropToPaper])
        #expect(kept.pages[0].ocrLanguage == "ar")
        let back = ScanPages(restoring: kept).page("a")!
        #expect(back.edits.filters == [.whiten, .cropToPaper])
        #expect(back.edits.crop == Self.edge)
        #expect(back.ocrLanguage == "ar")
    }
}
