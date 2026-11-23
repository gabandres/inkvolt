import Foundation
import Testing
@testable import PrintCore

/// Ported from CleanUpMarksTests.cs: Clean up's "Drop a color" and "Remove punch holes" (roadmap 4.7), on made-up scans.
/// Adapted: color pixels are RGB on the Mac (Windows' BGR), so pages are built and read as RGB; .NET's `Random` is a fixed
/// generator here (other noise, the same kind); the kept page's colour is checked through `KeptPage`'s Codable as Windows
/// checks it through System.Text.Json.
struct CleanUpMarksTests {
    private static let dpi = 300
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    /// A color page (RGB) of paper at `paper`.
    private static func page(_ w: Int, _ h: Int, _ paper: RGB) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { (px[i * 3], px[i * 3 + 1], px[i * 3 + 2]) = (paper.r, paper.g, paper.b) }
        return px
    }

    private static func box(_ px: inout [UInt8], _ w: Int, _ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ c: RGB) {
        for yy in y..<(y + bh) { for xx in x..<(x + bw) { (px[(yy * w + xx) * 3], px[(yy * w + xx) * 3 + 1], px[(yy * w + xx) * 3 + 2]) = (c.r, c.g, c.b) } }
    }

    private static func at(_ px: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> RGB { (px[(y * w + x) * 3], px[(y * w + x) * 3 + 1], px[(y * w + x) * 3 + 2]) }

    private static func noise(_ px: inout [UInt8], _ sigma: Double, seed: UInt64 = 5) {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func unit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
        for i in px.indices {
            let g = (-2 * log(1 - unit())).squareRoot() * cos(2 * .pi * unit())
            px[i] = UInt8(min(255, max(0, Double(px[i]) + g * sigma)))
        }
    }

    /// A red-ruled form with black print on it, a blue pen's note and a green stamp: what each drop leaves.
    private static func form(_ w: Int, _ h: Int) -> [UInt8] {
        var px = page(w, h, (250, 249, 245))
        var y = 100
        while y < h - 100 {
            box(&px, w, 60, y, w - 120, 3, (215, 45, 50)) // the form's red rules
            y += 60
        }
        var x = 80
        while x < w - 120 {
            box(&px, w, x, 140, 24, 30, (25, 25, 28)) // black print crossing a rule
            x += 40
        }
        box(&px, w, 80, 300, 300, 6, (40, 70, 190)) // a blue pen's line
        box(&px, w, 500, 300, 80, 80, (40, 150, 70)) // a green stamp
        box(&px, w, 100, 155, 30, 4, (25, 25, 28)) // black over the red rule at y = 160
        return px
    }

    private static func apply(_ px: [UInt8], _ w: Int, _ h: Int, _ channels: Int, _ filters: PageFilters, dpi: Int = dpi, drop: DropColor? = nil) throws -> CleanedPage {
        try PageCleanup.apply(px, width: w, height: h, channels: channels, dpi: dpi, filters, drop: drop)
    }

    @Test func redDropsToWhiteAndBlackPrintStays() throws {
        let (w, h) = (800, 600)
        var page = Self.form(w, h)
        Self.noise(&page, 3)
        let result = try Self.apply(page, w, h, 3, .dropColor, drop: .red)
        #expect(result.done == .dropColor)
        let rule = Self.at(result.pixels, w, 700, 101)
        #expect(rule.r > 235 && rule.g > 235 && rule.b > 235, "the red rule is \(rule)")
        let print = Self.at(result.pixels, w, 90, 150)
        #expect(print.r < 60 && print.g < 60 && print.b < 60, "the black print is \(print)")
        let blue = Self.at(result.pixels, w, 100, 302)
        #expect(blue.b > 150 && blue.r < 80, "the blue pen is \(blue)")
        let green = Self.at(result.pixels, w, 540, 340)
        #expect(green.g > 120 && green.r < 80, "the green stamp is \(green)")
        #expect(page != result.pixels) // the scan itself is never written to: a new page came back
    }

    @Test func blueAndGreenDropByTheirOwnHue() throws {
        let (w, h) = (800, 600)
        let blue = try Self.apply(Self.form(w, h), w, h, 3, .dropColor, drop: .blue).pixels
        #expect(Self.at(blue, w, 100, 302).r > 235, "the blue pen went white")
        #expect(Self.at(blue, w, 700, 101).g < 80, "the red rule stayed")
        let green = try Self.apply(Self.form(w, h), w, h, 3, .dropColor, drop: .green).pixels
        #expect(Self.at(green, w, 540, 340).r > 235, "the stamp went white")
        #expect(Self.at(green, w, 100, 302).r < 80, "the blue pen stayed")
    }

    @Test func aPickedColorDropsThatHueOnly() throws {
        let (w, h) = (400, 300)
        var page = Self.page(w, h, (250, 250, 250))
        Self.box(&page, w, 20, 20, 100, 40, (150, 60, 180)) // a purple highlighter
        Self.box(&page, w, 200, 20, 100, 40, (215, 45, 50)) // red
        let picked = DropColor(150, 60, 180)
        #expect(picked.isColorful)
        #expect(!picked.isNamed)
        let px = try Self.apply(page, w, h, 3, .dropColor, drop: picked).pixels
        #expect(Self.at(px, w, 50, 40).g > 235)
        #expect(Self.at(px, w, 250, 40).g < 80)
    }

    @Test func greyHasNoHueToPickAndGreyScansHaveNoColorToDrop() throws {
        #expect(!DropColor(120, 120, 128).isColorful)
        #expect(!DropColor(30, 30, 30).isColorful)
        let grey = [UInt8](repeating: 90, count: 100 * 100)
        let result = try Self.apply(grey, 100, 100, 1, .dropColor, drop: .red)
        #expect(result.done == [])
        #expect(result.pixels == grey)
    }

    @Test func aPageWithoutTheColorIsLeftAsItIs() throws {
        let (w, h) = (200, 200)
        var page = Self.page(w, h, (240, 235, 220)) // cream paper: a hue, but hardly any color
        Self.box(&page, w, 20, 20, 100, 20, (20, 20, 20))
        #expect(try Self.apply(page, w, h, 3, .dropColor, drop: .red).done == [])
    }

    @Test(arguments: [("#D22B2B", true), ("d22b2b", true), ("#12345", false), ("#GGGGGG", false), ("", false), (nil, false), ("+D22B2B", false)] as [(String?, Bool)])
    func colorsAreReadBackOnlyAsWritten(_ hex: String?, _ valid: Bool) {
        let color = DropColor.parse(hex)
        #expect((color != nil) == valid)
        if let color { #expect(color == .red) }
        #expect(DropColor.blue.hex == "#2B55C8")
        #expect(DropColor.parse(DropColor.blue.hex) == .blue)
    }

    @Test func theEditsCarryTheColorOnlyWithTheFilter() {
        let dropping = PageEdits.none.withFilters([.dropColor, .whiten], drop: .blue)
        #expect(dropping.drop == .blue)
        #expect(!dropping.isEmpty)
        #expect(dropping.withFilters(.whiten, drop: .blue).drop == nil)
        #expect(PageEdits.none.withFilters(.dropColor, drop: nil).drop == .red) // red unless told
        #expect(PageEdits.none.withFilters(.dropColor, drop: .red) != dropping.withFilters(.dropColor, drop: .blue))

        let cleaned = PageEdits.none.cleanedUp([.dropColor, .punchHoles], photos: false, paperEdge: nil, measuredAt: 0, drop: .green)
        #expect(cleaned?.drop == .green)
        #expect(cleaned?.filters == [.dropColor, .punchHoles])
        // A scan of photos gets what suits a print only: no color dropped, no holes looked for.
        #expect(PageEdits.none.cleanedUp([.dropColor, .punchHoles], photos: true, paperEdge: nil, measuredAt: 0, drop: .green) == nil)
    }

    @Test func aGreyPageIsntSaidToHaveAColorDropped() {
        let cleaned = PageEdits.none.cleanedUp([.dropColor, .whiten], photos: false, paperEdge: nil, measuredAt: 0, drop: .blue, grey: true)
        #expect(cleaned?.filters == .whiten)
        #expect(cleaned?.drop == nil)
        #expect(PageEdits.none.cleanedUp(.dropColor, photos: false, paperEdge: nil, measuredAt: 0, drop: .blue, grey: true) == nil) // nothing else: the scan stays as sent
        #expect(PageCleanup.for([.dropColor, .whiten, .punchHoles], grey: true) == [.whiten, .punchHoles])
        #expect(PageCleanup.for(.dropColor, grey: false) == .dropColor)
    }

    @Test func aKeptPageKeepsItsColor() throws {
        var kept = KeptPage("p.jpg", dpi: 300, ocr: false)
        kept.filters = .dropColor
        kept.drop = "#2E9E4F"
        let back = try JSONDecoder().decode(KeptPage.self, from: JSONEncoder().encode(kept))
        #expect(back.edits.drop == .green)
        kept.filters = .whiten
        #expect(kept.edits.drop == nil)
        kept.filters = .dropColor
        kept.drop = "nonsense"
        #expect(kept.edits.drop == .red)
    }

    @Test func presetsKeepAColorTheyCanRead() {
        var a = ScanPreset()
        a.id = "a"
        a.name = "Forms"
        a.cleanup = [.dropColor, .punchHoles]
        a.dropColor = "#2b55c8"
        var b = ScanPreset()
        b.id = "b"
        b.name = "Odd"
        b.cleanup = .dropColor
        b.dropColor = "blue-ish"
        let list = ScanPresets.normalize(ScanPresetSettings(items: [a, b]))
        #expect(list[0].dropColor == "#2B55C8")
        #expect(list[0].cleanup == [.dropColor, .punchHoles])
        #expect(list[1].dropColor == nil)
        #expect(ScanPresetText.summary(list[0]).contains("blue dropped"))
        #expect(ScanPresetText.summary(list[0]).contains("punch holes removed"))
        #expect(ScanPresetText.summary(list[1]).contains("red dropped"))
    }

    // ---- Punch holes ----

    /// A grey page (letter at 300 dpi scaled to `dpi`) with lines of blocky words from 1.2 inch in.
    private static func textPage(_ w: Int, _ h: Int, _ dpi: Int, paper: UInt8 = 238) -> [UInt8] {
        var px = [UInt8](repeating: paper, count: w * h)
        var state: UInt64 = 11 &* 0x9E37_79B9_7F4A_7C15 | 1
        func next(_ n: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(n))
        }
        let (letter, line) = (dpi / 20, dpi / 6)
        let margin = 1.2 * Double(dpi)
        var y = Int(margin)
        while Double(y + letter) < Double(h) - margin {
            var x = Int(margin)
            while Double(x) < Double(w) - margin {
                let n = 2 + next(7)
                var l = 0
                while l < n && Double(x) < Double(w) - margin {
                    for yy in y..<(y + letter) { for xx in x..<(x + letter) { px[yy * w + xx] = 30 } }
                    l += 1
                    x += letter + 3
                }
                x += letter
            }
            y += line
        }
        return px
    }

    private static func disc(_ px: inout [UInt8], _ w: Int, _ cx: Double, _ cy: Double, _ r: Double, _ level: UInt8, inner: Double = 0, innerLevel: UInt8 = 0) {
        for y in Int(cy - r - 1)...Int(cy + r + 1) {
            for x in Int(cx - r - 1)...Int(cx + r + 1) {
                let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
                if d <= r { px[y * w + x] = d < inner ? innerLevel : level }
            }
        }
    }

    @Test func threePunchedHolesAreFilledWithThePaper() throws {
        let (w, h, dpi) = (2550, 3300, Double(Self.dpi)) // letter at 300 dpi
        var page = Self.textPage(w, h, Self.dpi)
        let holes = [0.95, 5.5, 10.05].map { (x: 0.5 * dpi, y: $0 * dpi) } // a three-hole punch on the left
        for (x, y) in holes { Self.disc(&page, w, x, y, 0.14 * dpi, 70) } // the feeder's dark backing through each hole
        Self.noise(&page, 3)
        let text = page[Int(3 * dpi) * w + Int(1.2 * dpi)]

        let result = try Self.apply(page, w, h, 1, .punchHoles)
        #expect(result.done == .punchHoles)
        #expect(result.holes == 3)
        for (x, y) in holes {
            #expect((225...250).contains(result.pixels[Int(y) * w + Int(x)]))
            #expect((225...250).contains(result.pixels[Int(y + 0.13 * dpi) * w + Int(x)])) // the rim too
        }
        #expect(result.pixels[Int(3 * dpi) * w + Int(1.2 * dpi)] == text) // the text is as it was
    }

    @Test func aRingShadowAndHolesAtTheTopAreFoundToo() throws {
        let (w, h, dpi) = (2550, 3300, Double(Self.dpi))
        var page = Self.textPage(w, h, Self.dpi)
        Self.disc(&page, w, 0.5 * dpi, 5.5 * dpi, 0.15 * dpi, 110, inner: 0.11 * dpi, innerLevel: 245) // a hole's shadow, the lid's white in it
        Self.disc(&page, w, 3 * dpi, 0.45 * dpi, 0.13 * dpi, 60)
        Self.disc(&page, w, 5.5 * dpi, 0.45 * dpi, 0.13 * dpi, 60)
        let found = try PunchHoles.find(page, w, h, 1, Self.dpi)
        #expect(found.count == 3)
        #expect(found.contains { abs($0.x - 0.5 * dpi) < 10 && abs($0.y - 5.5 * dpi) < 10 })
    }

    @Test func roundMarksThatArentHolesStay() throws {
        let (w, h, dpi) = (2550, 3300, Double(Self.dpi))
        var page = Self.textPage(w, h, Self.dpi)
        Self.disc(&page, w, 4 * dpi, 5 * dpi, 0.15 * dpi, 40) // a dot in the page's middle
        Self.disc(&page, w, 0.5 * dpi, 3 * dpi, 0.04 * dpi, 40) // a bullet in the margin: too small
        Self.disc(&page, w, 0.6 * dpi, 7 * dpi, 0.6 * dpi, 40) // a big logo: too big
        Self.disc(&page, w, 0.06 * dpi, 9 * dpi, 0.14 * dpi, 40) // a hole cut by the page's edge: not sure what it is
        // A heading's "O" near the edge, between its letters.
        Self.disc(&page, w, 1.0 * dpi, 1.0 * dpi, 0.12 * dpi, 30, inner: 0.07 * dpi, innerLevel: 238)
        for side in [0.68, 1.15] {
            for yy in Int(0.88 * dpi)..<Int((1.12 * dpi).rounded(.up)) { for xx in 0..<Int((0.15 * dpi).rounded(.up)) { page[yy * w + Int(side * dpi) + xx] = 30 } }
        }
        #expect(try PunchHoles.find(page, w, h, 1, Self.dpi).isEmpty)
        #expect(try Self.apply(page, w, h, 1, .punchHoles).done == [])
    }

    @Test func holesOnAColorPageGetItsOwnPaperColor() throws {
        let (w, h, dpi) = (1275, 1650, 150) // letter at 150 dpi
        let d = Double(dpi)
        var page = Self.page(w, h, (245, 238, 205)) // yellowish paper
        for y in [4.0, 7.0] {
            for yy in Int((y - 0.14) * d)...Int((y + 0.14) * d) {
                for xx in Int(0.36 * d)...Int(0.64 * d) where pow(Double(xx) - 0.5 * d, 2) + pow(Double(yy) - y * d, 2) <= pow(0.14 * d, 2) {
                    (page[(yy * w + xx) * 3], page[(yy * w + xx) * 3 + 1], page[(yy * w + xx) * 3 + 2]) = (40, 40, 40)
                }
            }
        }
        let result = try Self.apply(page, w, h, 3, .punchHoles, dpi: dpi)
        #expect(result.holes == 2)
        #expect(Self.at(result.pixels, w, Int(0.5 * d), 4 * dpi) == (245, 238, 205))
    }

    @Test func aDarkPageOrOneTooSmallHasNoHoles() throws {
        #expect(try PunchHoles.find([UInt8](repeating: 60, count: 600 * 600), 600, 600, 1, 300).isEmpty)
        #expect(try PunchHoles.find([UInt8](repeating: 0, count: 100), 10, 10, 1, 300).isEmpty)
        #expect(try PunchHoles.find([UInt8](repeating: 0, count: 10), 100, 100, 1, 300).isEmpty) // fewer pixels than it says: nothing read past the end
        #expect(try PunchHoles.find([UInt8](repeating: 238, count: 100), 10, 10, 1, Int.max).isEmpty) // a resolution no scan has
    }
}
