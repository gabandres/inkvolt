import Foundation
import Testing
@testable import PrintCore

/// Several photos on the glass: rectangles found on synthetic flatbed scans (the whole glass, 8.5 × 11.7 in at 100 dpi, as
/// the app analyses it: a noisy white lid with prints laid on it, straight or turned) and each one cut out straight. Ported
/// from GlassPhotoTests.cs (the noise comes from a seeded generator of its own, not .NET's Random).
/// One at a time: each check is seconds of CPU, like ImagingTests.
@Suite(.serialized)
struct GlassPhotoTests {
    private static let w = 850, h = 1170
    private static let ppi = 100.0

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

    /// A print on the glass, in inches: centre, size, turned `degrees` clockwise.
    private struct Print: Sendable {
        var x: Double, y: Double, width: Double, height: Double, degrees: Double
        var brightSky = false

        init(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ degrees: Double, brightSky: Bool = false) {
            (self.x, self.y, self.width, self.height, self.degrees, self.brightSky) = (x, y, width, height, degrees, brightSky)
        }
    }

    /// The lid (level 246 with scanner noise) with each print drawn on it: mid tones in soft blotches, a bright sky band if asked.
    private static func glass(_ prints: Print...) -> GrayImage { GrayImage(width: w, height: h, pixels: glassPixels(prints)) }

    private static func glassPixels(_ prints: [Print], seed: UInt64 = 5) -> [UInt8] {
        var noise = Noise(state: seed)
        var pixels = (0..<(w * h)).map { _ in UInt8(246 + noise.next(-6...6)) }
        for p in prints {
            let radians: Double = p.degrees * .pi / 180
            let (s, c) = (sin(radians), cos(radians))
            for y in 0..<h {
                for x in 0..<w {
                    // Where this pixel is on the print (inches from its centre, along its sides).
                    let dx: Double = Double(x) / ppi - p.x
                    let dy: Double = Double(y) / ppi - p.y
                    let u: Double = c * dx + s * dy
                    let v: Double = -s * dx + c * dy
                    if abs(u) > p.width / 2 || abs(v) > p.height / 2 { continue }
                    let level: Double
                    if p.brightSky && v < -p.height / 6 {
                        level = 220 + 4 * sin(u * 9)
                    } else {
                        let blotch: Double = 70 * sin(u * 3.1) * cos(v * 2.3)
                        level = 120 + blotch + Double(noise.next(-8...8))
                    }
                    pixels[y * w + x] = UInt8(min(max(level, 0), 255))
                }
            }
        }
        return pixels
    }

    private static func expectFound(_ expected: Print, _ box: PhotoBox?, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let box else {
            Issue.record("no box", sourceLocation: sourceLocation)
            return
        }
        // Box units are the scan's width: 8.5 in here.
        let inch = 1 / 8.5
        let (cx, cy) = (box.centerX / inch, box.centerY / inch)
        let (bw, bh) = (box.width / inch, box.height / inch)
        #expect((expected.x - 0.08)...(expected.x + 0.08) ~= cx, "centre x \(cx)", sourceLocation: sourceLocation)
        #expect((expected.y - 0.08)...(expected.y + 0.08) ~= cy, "centre y \(cy)", sourceLocation: sourceLocation)
        #expect((expected.width - 0.16)...(expected.width + 0.04) ~= bw, "width \(bw)", sourceLocation: sourceLocation) // trimmed a little, never larger
        #expect((expected.height - 0.16)...(expected.height + 0.04) ~= bh, "height \(bh)", sourceLocation: sourceLocation)
        #expect((expected.degrees - 0.75)...(expected.degrees + 0.75) ~= box.angle, "angle \(box.angle)", sourceLocation: sourceLocation)
    }

    private static func find(_ img: GrayImage) async -> [PhotoBox] {
        await offPool { PhotoFinder.find(img, pixelsPerInch: ppi) }
    }

    @Test func findsThreePrintsStraightAndTurnedInReadingOrder() async {
        let prints = [
            Print(2.4, 2.2, 4, 3, 0),
            Print(6.4, 2.5, 3, 4.2, 7),
            Print(4.2, 8.3, 5, 3.5, -12),
        ]

        let boxes = await Self.find(GrayImage(width: Self.w, height: Self.h, pixels: Self.glassPixels(prints)))

        #expect(boxes.count == 3)
        for i in 0..<min(3, boxes.count) { Self.expectFound(prints[i], boxes[i]) }
    }

    @Test func steepAnglesComeBackWithin45Degrees() async {
        let boxes = await Self.find(Self.glass(Print(4.25, 5.5, 5, 3, 32)))

        #expect(boxes.count == 1)
        Self.expectFound(Print(4.25, 5.5, 5, 3, 32), boxes.first)

        // Turned 60°, a 5 × 3 print is a 3 × 5 one turned -30°.
        let steep = await Self.find(Self.glass(Print(4.25, 5.5, 5, 3, 60)))
        #expect(steep.count == 1)
        Self.expectFound(Print(4.25, 5.5, 3, 5, -30), steep.first)
    }

    @Test func aBrightSkyInsideAPrintStaysPartOfIt() async {
        let print = Print(4.25, 5, 6, 4, 4, brightSky: true)

        let boxes = await Self.find(Self.glass(print))

        #expect(boxes.count == 1)
        Self.expectFound(print, boxes.first)
    }

    @Test func printsAgainstTheGlassEdgeAndCloseTogether() async {
        let corner = Print(1.5, 1, 3, 2, 0) // pushed into the corner of the glass
        let left = Print(2.0, 6, 3.6, 2.5, 0)
        let right = Print(6.15, 6, 4, 2.5, 0) // 0.35 in from the left one

        let boxes = await Self.find(Self.glass(corner, left, right))

        #expect(boxes.count == 3)
        guard boxes.count == 3 else { return }
        Self.expectFound(corner, boxes[0])
        Self.expectFound(left, boxes[1])
        Self.expectFound(right, boxes[2])
    }

    @Test func aPrintJustShortOfTheEdgeDoesntGrowToIt() async {
        let nearTop = Print(3, 1.8, 4, 3.5, 0) // its top 0.05 in below the glass's edge
        let nearLeft = Print(1.6, 6.5, 3, 3, -3) // a corner 0.03 in from the left edge

        let boxes = await Self.find(Self.glass(nearTop, nearLeft))

        #expect(boxes.count == 2)
        guard boxes.count == 2 else { return }
        Self.expectFound(nearTop, boxes[0])
        Self.expectFound(nearLeft, boxes[1])
        let top: Double = (boxes[0].centerY - boxes[0].height / 2) * 8.5
        #expect((0.045...0.1) ~= top, "top \(top)") // the top stays where the print's is, not the glass's
        let leftmost: Double = boxes[1].corners().map(\.x).min()! * 8.5
        #expect((0.02...0.08) ~= leftmost, "left \(leftmost)")
    }

    @Test func emptyGlassDustHairsAndLidShadowsAreNoPhotos() async {
        var pixels = Self.glassPixels([])
        for x in 0..<Self.w {
            for y in 0..<5 { pixels[y * Self.w + x] = 150 } // the lid's shadow along the top
        }
        for i in 0..<400 { pixels[(300 + i) * Self.w + 200 + i / 3] = 60 } // a hair
        for (x, y) in [(100, 900), (700, 400), (420, 610)] {
            for d in 0..<9 { pixels[(y + d / 3) * Self.w + x + d % 3] = 40 } // dust
        }

        #expect(await Self.find(GrayImage(width: Self.w, height: Self.h, pixels: pixels)).isEmpty)
        #expect(await Self.find(Self.glass(Print(4, 4, 0.4, 0.5, 0))).isEmpty) // a stamp, not a photo
    }

    // ---- Cutting each photo out ----

    /// A grey 3-channel page (stride padded) with one turned rectangle of colour (60, 120, 200) on white.
    private static func colourPage(_ print: Print) -> (pixels: [UInt8], stride: Int) {
        let stride = (w * 3 + 3) & ~3
        var pixels = [UInt8](repeating: 255, count: stride * h)
        let radians: Double = print.degrees * .pi / 180
        let (s, c) = (sin(radians), cos(radians))
        for y in 0..<h {
            for x in 0..<w {
                let dx: Double = Double(x) / ppi - print.x
                let dy: Double = Double(y) / ppi - print.y
                let u: Double = c * dx + s * dy
                let v: Double = -s * dx + c * dy
                if abs(u) > print.width / 2 || abs(v) > print.height / 2 { continue }
                let i = y * stride + x * 3
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (60, 120, 200)
            }
        }
        return (pixels, stride)
    }

    @Test(arguments: [0.0, 9, -21])
    func cutsATurnedPhotoOutStraight(_ degrees: Double) async {
        let print = Print(4, 5, 4, 2.5, degrees)
        let (page, stride) = Self.colourPage(print)
        let box = PhotoBox(centerX: 4 / 8.5, centerY: 5 / 8.5, width: 3.9 / 8.5, height: 2.4 / 8.5, angle: degrees) // a little inside the print, as found

        let (x, y, w, h) = GlassPhotoCrop.bounds(box, width: Self.w, height: Self.h)
        let regionStride = (w * 3 + 3) & ~3
        var region = [UInt8](repeating: 0, count: regionStride * h)
        for row in 0..<h {
            let from = (y + row) * stride + x * 3
            region.replaceSubrange((row * regionStride)..<(row * regionStride + w * 3), with: page[from..<(from + w * 3)])
        }
        let regionCopy = region
        let photo = await offPool {
            GlassPhotoCrop.straighten(regionCopy, regionWidth: w, regionHeight: h, stride: regionStride, channels: 3, box: box,
                                 scanWidth: Self.w, regionX: x, regionY: y)
        }

        #expect((388...392) ~= photo.width)
        #expect((238...242) ~= photo.height)
        // Every pixel is the print's colour: no white corners from the glass.
        var bad: [String] = []
        for row in 0..<photo.height {
            for col in 0..<photo.width {
                let i = row * photo.stride + col * 3
                if abs(Int(photo.pixels[i]) - 60) >= 20 || abs(Int(photo.pixels[i + 2]) - 200) >= 20 { bad.append("\(col),\(row)") }
            }
        }
        #expect(bad.isEmpty, "pixels \(bad.prefix(5))")
    }

    @Test func boundsStayInsideTheScan() {
        let (x, y, w, h) = GlassPhotoCrop.bounds(PhotoBox(centerX: 0.02, centerY: 0.02, width: 0.2, height: 0.1, angle: 30), width: Self.w, height: Self.h)

        #expect(x == 0 && y == 0)
        #expect(w > 0 && h > 0 && x + w <= Self.w && y + h <= Self.h)
    }

    @Test func presetsSayWhenTheyFindPhotos() {
        var preset = ScanPreset()
        preset.id = "photos"
        preset.name = "Photos"
        preset.findPhotos = true

        #expect(ScanPresetText.summary(preset).contains("each photo on the glass by itself"))
        #expect(ScanPresets.normalize(ScanPresetSettings(items: [preset]))[0].findPhotos)
    }

    // ---- Adjusting a box in the review ----

    @Test func draggingACornerKeepsTheOppositeOne() {
        let box = PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.2, angle: 30)
        let corners = box.corners()

        let resized = box.withCorner(2, corners[2].x + 0.05, corners[2].y + 0.02)

        #expect(abs(corners[0].x - resized.corners()[0].x) < 1e-9)
        #expect(abs(corners[0].y - resized.corners()[0].y) < 1e-9)
        #expect(resized.angle == 30)
        #expect(resized.width > box.width)
    }

    @Test func cornerOrderAndContainment() {
        let box = PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.2, angle: 0)

        let rounded = box.corners().map { PhotoPoint(($0.x * 1e9).rounded() / 1e9, ($0.y * 1e9).rounded() / 1e9) }
        #expect(rounded == [PhotoPoint(0.3, 0.4), PhotoPoint(0.7, 0.4), PhotoPoint(0.7, 0.6), PhotoPoint(0.3, 0.6)])
        #expect(box.contains(0.6, 0.55))
        #expect(!box.contains(0.6, 0.65))
        var quarter = box
        quarter.angle = 90
        #expect(quarter.contains(0.55, 0.65)) // turned a quarter: 0.2 wide, 0.4 tall
    }

    // ---- Mac only: the box in a full-size scan's pixels, for the Core Image cut-out ----

    @Test func aBoxInTheFullSizeScansPixels() {
        let box = PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.2, angle: 12, quarterTurns: 1)

        let pixels = box.inPixels(scanWidth: 2550)

        #expect(abs(pixels.centerX - 1275) < 1e-9 && abs(pixels.centerY - 1275) < 1e-9)
        #expect(abs(pixels.width - 1020) < 1e-9 && abs(pixels.height - 510) < 1e-9)
        #expect(pixels.angle == 12 && pixels.quarterTurns == 1)
        for (p, c) in zip(pixels.corners, box.corners()) { #expect(abs(p.x - c.x * 2550) < 1e-9 && abs(p.y - c.y * 2550) < 1e-9) }
    }
}
