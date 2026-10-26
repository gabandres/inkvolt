import Foundation
import Testing
@testable import PrintCore

/// Blank page and skew detection on synthetic scans: a letter page at 100 dpi (850 × 1100), as the app analyses it. Ported
/// from ImagingTests.cs (the noise comes from a seeded generator of its own, not .NET's Random).
struct ImagingTests {
    private static let w = 850, h = 1100

    /// SplitMix64: repeatable noise.
    private struct Noise {
        var state: UInt64
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return range.lowerBound + Int(z % UInt64(range.count))
        }
    }

    /// Off-white paper with scanner noise (±6 levels, repeatable).
    private static func paper(_ level: Int = 242, seed: UInt64 = 1) -> [UInt8] {
        var noise = Noise(state: seed)
        return (0..<(w * h)).map { _ in UInt8(level + noise.next(-6...6)) }
    }

    private static func fill(_ pixels: inout [UInt8], _ x: Int, _ y: Int, _ fw: Int, _ fh: Int, _ level: UInt8) {
        for yy in y..<(y + fh) {
            for xx in x..<(x + fw) { pixels[yy * w + xx] = level }
        }
    }

    /// A page of text lines (word-shaped bars, 8 px tall every 24 px), turned `degrees` clockwise.
    private static func textPage(_ degrees: Double, lines: Int = 30) -> GrayImage {
        var pixels = paper()
        let (s, c) = (sin(degrees * .pi / 180), cos(degrees * .pi / 180))
        for y in 0..<h {
            for x in 0..<w {
                // Where this pixel was on the straight page.
                let (dx, dy) = (Double(x) - Double(w) / 2, Double(y) - Double(h) / 2)
                let qx = c * dx + s * dy + Double(w) / 2
                let qy = -s * dx + c * dy + Double(h) / 2
                let row = (qy - 150) / 24
                if qx < 110 || qx > 740 || row < 0 || row >= Double(lines) || qy - 150 - Double(Int(row) * 24) >= 8 { continue }
                if Int(qx - 110) % 70 < 58 { pixels[y * w + x] = 40 } // words with gaps
            }
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    @Test func plainPaperWithNoiseSpecksAndDarkEdgesIsBlank() async {
        var pixels = Self.paper()
        for (x, y) in [(200, 300), (500, 640), (610, 900), (333, 333)] { pixels[y * Self.w + x] = 20 } // lone dust specks
        Self.fill(&pixels, 0, 0, Self.w, 30, 30) // lid shadow along the top edge
        Self.fill(&pixels, 0, 0, 20, Self.h, 60) // feeder edge
        Self.fill(&pixels, 30, 500, 20, 20, 0) // punched hole in the margin
        let page = GrayImage(width: Self.w, height: Self.h, pixels: pixels)
        #expect(await offPool { BlankPage.isBlank(page) })
    }

    @Test func showThroughFromTheBackIsStillBlank() async {
        var pixels = Self.paper()
        for row in 0..<30 { Self.fill(&pixels, 110, 150 + row * 24, 630, 8, 210) } // faint mirror of the back's text
        let page = GrayImage(width: Self.w, height: Self.h, pixels: pixels)
        #expect(await offPool { BlankPage.isBlank(page) })
    }

    @Test func oneShortWordIsNotBlank() async {
        var pixels = Self.paper()
        Self.fill(&pixels, 400, 520, 40, 10, 50) // about "Page 2" at 100 dpi, as a solid bar
        let page = GrayImage(width: Self.w, height: Self.h, pixels: pixels)
        #expect(await offPool { !BlankPage.isBlank(page) })
    }

    @Test func textAndDarkPagesAreNotBlank() async {
        #expect(await offPool { !BlankPage.isBlank(Self.textPage(0)) })
        #expect(await offPool { !BlankPage.isBlank(GrayImage(width: Self.w, height: Self.h, pixels: Self.paper(70))) }) // a dark photo
    }

    @Test(arguments: [3, -2.5, 1.2, -7, 9.5])
    func findsTheSkewOfATextPage(_ degrees: Double) async {
        #expect(await offPool { abs(Deskew.angle(Self.textPage(degrees)) - degrees) } <= 0.15)
    }

    @Test func straightAndNearlyStraightPagesAreLeftAlone() async {
        #expect(await offPool { Deskew.angle(Self.textPage(0)) } == 0)
        #expect(await offPool { Deskew.angle(Self.textPage(0.2)) } == 0)
    }

    @Test func noTextLinesNoAnswer() async {
        #expect(await offPool { Deskew.angle(GrayImage(width: Self.w, height: Self.h, pixels: Self.paper())) } == 0) // blank
        // A photo-like page: smooth blotches, no lines.
        var pixels = Self.paper()
        for y in 0..<Self.h {
            for x in 0..<Self.w { pixels[y * Self.w + x] = UInt8(128 + 100 * sin(Double(x) / 37) * cos(Double(y) / 53)) }
        }
        let photo = pixels
        #expect(await offPool { Deskew.angle(GrayImage(width: Self.w, height: Self.h, pixels: photo)) } == 0)
    }

    @Test func turningASkewedPageBackStraightensIt() async {
        let skewed = await offPool { Self.textPage(4) }
        let straight = await offPool { PageRotate.rotate(skewed.pixels, width: Self.w, height: Self.h, stride: Self.w, channels: 1, degrees: -4) }
        #expect(await offPool { Deskew.angle(GrayImage(width: Self.w, height: Self.h, pixels: straight)) } == 0)
        #expect(straight[0] == 255) // the corner the page turned away from is white
        #expect(await offPool { PageRotate.rotate(skewed.pixels, width: Self.w, height: Self.h, stride: Self.w, channels: 1, degrees: 0) } == skewed.pixels)
    }

    @Test func rotationKeepsColourChannelsApart() {
        // 3 × 3 BGR, stride padded to 12: a quarter turn moves the blue top-left pixel to the top-right.
        var pixels = [UInt8](repeating: 200, count: 3 * 12)
        (pixels[0], pixels[1], pixels[2]) = (255, 0, 0)
        let turned = PageRotate.rotate(pixels, width: 3, height: 3, stride: 12, channels: 3, degrees: 90)
        #expect(Array(turned[6..<9]) == [255, 0, 0])
        #expect(Array(turned[0..<3]) == [200, 200, 200])
    }

    @Test func cropFollowsThePageWhenItTurns() {
        let box = CropBox(0.1, 0.2, 0.3, 0.4)
        #expect(Self.close(CropBox(0.4, 0.1, 0.4, 0.3), box.turn(1))) // top-left area → top-right after a clockwise quarter
        #expect(box.turn(4) == box)
        #expect(box.turn(3) == box.turn(-1))
        #expect(Self.close(box, box.turn(1).turn(-1)))
    }

    @Test func editsKeepTheCropInTheStraightenedPage() throws {
        let turned = PageEdits.none.turned(1)
        let shown = CropBox(0.5, 0, 0.5, 1) // right half of the turned page = top half of the scan
        let edits = turned.withShownCrop(shown)
        #expect(Self.close(CropBox(0, 0, 1, 0.5), try #require(edits.crop)))
        #expect(Self.close(shown, edits.shownCrop))
        #expect(PageEdits.none.turned(-1).quarterTurns == 3)
        #expect(PageEdits.none.turned(4).isEmpty)
        #expect(PageEdits.none.withShownCrop(.full).isEmpty)
        #expect(!edits.isEmpty)
    }

    private static func close(_ a: CropBox, _ b: CropBox) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }
}
