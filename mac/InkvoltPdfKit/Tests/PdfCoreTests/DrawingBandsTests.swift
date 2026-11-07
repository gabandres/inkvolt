import Foundation
import Testing
@testable import PdfCore

/// Mac addition (roadmap 3.6): a large drawing is split into bands of rows, each drawn on a thread of its own from the
/// page's one display list (`inkv_draw_bands`). The bands must give the picture one thread gives, pixel for pixel, and
/// share one budget, so a page that takes too long to draw is refused after the time one thread would have had.
@Suite(.serialized)
struct DrawingBandsTests {
    typealias P = PageCheckTests

    /// A page of `size` points with `content` and `resources`, and `more` objects from number 5 on.
    static func page(_ content: String, _ resources: String = "", size: (Int, Int) = (612, 792), extra: String = "", more: [[UInt8]] = []) -> [UInt8] {
        P.build([
            P.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            P.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            P.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size.0) \(size.1)] /Contents 4 0 R /Resources << \(resources) >> \(extra) >>"),
            P.stream(P.zlib(Array(content.utf8)), "/Filter /FlateDecode"),
        ] + more)
    }

    /// A circle of radius `r` around (x, y), as four Béziers.
    static func circle(_ x: Double, _ y: Double, _ r: Double) -> String {
        let k = 0.5523 * r
        return "\(x + r) \(y) m \(x + r) \(y + k) \(x + k) \(y + r) \(x) \(y + r) c \(x - k) \(y + r) \(x - r) \(y + k) \(x - r) \(y) c "
            + "\(x - r) \(y - k) \(x - k) \(y - r) \(x) \(y - r) c \(x + k) \(y - r) \(x + r) \(y - k) \(x + r) \(y) c "
    }

    /// Pages that draw what MuPDF draws differently: paths across the bands' edges, text, a picture, a soft mask and a
    /// blend, a tiling pattern, a shading, a comment's appearance.
    static let kinds: [String] = ["drawing sheet", "drawing sheet with a picture", "text and comment", "picture", "soft mask and blend",
                                  "pattern and shading"]

    static func file(_ kind: String) -> [UInt8] {
        switch kind {
        case "drawing sheet", "drawing sheet with a picture":
            var content = "0.5 w 0 0 0 RG\n"
            var rng = SplitMix(seed: 7)
            for _ in 0..<20_000 {
                let x = rng.next(2560), y = rng.next(1700)
                content += "\(x) \(y) m \(x + rng.next(300)) \(y + rng.next(300)) l S\n"
            }
            content += "0.2 0.4 0.8 rg " + circle(1300, 860, 700) + "f\n"
            content += "BT /F2 24 Tf 2200 60 Td (A-103 FLOOR PLAN) Tj ET"
            guard kind.hasSuffix("picture") else {
                return page(content, "/Font << /F2 5 0 R >>", size: (2592, 1728), more: [P.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")])
            }
            content += " q 300 0 0 200 2200 1400 cm /Im Do Q" // a logo in the title block
            var logo: [UInt8] = []
            for y in 0..<30 {
                for x in 0..<40 { logo += [UInt8(x * 6), UInt8(y * 8), 128] }
            }
            return page(content, "/Font << /F2 5 0 R >> /XObject << /Im 6 0 R >>", size: (2592, 1728), more: [
                P.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
                P.stream(logo, "/Type /XObject /Subtype /Image /Width 40 /Height 30 /BitsPerComponent 8 /ColorSpace /DeviceRGB"),
            ])
        case "text and comment":
            var content = "BT /F1 11 Tf 14 TL 50 760 Td\n"
            for i in 0..<50 { content += "(Line \(i): the quick brown fox jumps over the lazy dog, again and again.) '\n" }
            content += "ET"
            return page(content, "/Font << /F1 5 0 R >>", extra: "/Annots [6 0 R]", more: [
                P.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>"),
                P.obj("<< /Type /Annot /Subtype /Square /Rect [100 200 500 600] /C [1 0 0] /AP << /N 7 0 R >> >>"),
                P.stream("1 0 0 RG 4 w 2 2 396 396 re S", "/Type /XObject /Subtype /Form /BBox [0 0 400 400]"),
            ])
        case "picture":
            var pixels: [UInt8] = []
            for y in 0..<97 { for x in 0..<131 { pixels += [UInt8(x * 255 / 130), UInt8(y * 255 / 96), UInt8((x ^ y) & 255)] } }
            return page("q 1 0.3 -0.3 1 0 0 cm 400 0 0 500 150 100 cm /Im Do Q", "/XObject << /Im 5 0 R >>", more: [
                P.stream(P.zlib(pixels), "/Type /XObject /Subtype /Image /Width 131 /Height 97 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode"),
            ])
        case "soft mask and blend":
            return page("0 0 1 rg 50 50 512 692 re f /GS1 gs 1 0 0 rg " + circle(306, 396, 280) + "f /GS2 gs 0 1 0 rg " + circle(306, 300, 200) + "f",
                        "/ExtGState << /GS1 5 0 R /GS2 << /BM /Multiply /ca 0.6 >> >>", more: [
                P.obj("<< /Type /ExtGState /SMask << /S /Luminosity /G 6 0 R >> >>"),
                P.stream("/Sh sh", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Group << /S /Transparency /CS /DeviceGray >> /Resources << /Shading << /Sh 7 0 R >> >>"),
                P.obj("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 0 792] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> /Extend [true true] >>"),
            ])
        default:
            return page("/Pattern cs /P1 scn 0 0 612 396 re f q 0 396 612 396 re W n /Sh sh Q",
                        "/Pattern << /P1 5 0 R >> /Shading << /Sh 6 0 R >>", more: [
                P.stream("0 0 1 RG 0 0 m 9 9 l S 1 0 0 rg 4 0 2 2 re f", "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 9 9] /XStep 9 /YStep 9 /Resources << >>"),
                P.obj("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [306 600 0 306 600 300] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 1 0] /C1 [0 0.5 1] /N 1 >> /Extend [false true] >>"),
            ])
        }
    }

    /// Whether two pictures are the same bytes (a debug build's `==` on 12 MB of pixels takes a minute).
    static func same(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        return a.withUnsafeBytes { x in b.withUnsafeBytes { y in a.isEmpty || memcmp(x.baseAddress!, y.baseAddress!, a.count) == 0 } }
    }

    /// The bytes darker than half.
    static func dark(_ a: [UInt8]) -> Int {
        a.withUnsafeBufferPointer { p in
            var n = 0
            for v in p where v < 128 { n += 1 }
            return n
        }
    }

    /// The largest difference between two pictures' bytes, and the average one.
    static func differ(_ a: [UInt8], _ b: [UInt8]) -> (most: Int, mean: Double) {
        var most = 0, sum = 0
        a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in
                for i in 0..<min(x.count, y.count) where x[i] != y[i] {
                    let d = abs(Int(x[i]) - Int(y[i]))
                    most = max(most, d)
                    sum += d
                }
            }
        }
        return (most, Double(sum) / Double(max(a.count, 1)))
    }

    /// Only a list of many paths and no pictures is split (`inkv_bandable`): every other page draws as before, byte for
    /// byte; a drawing sheet's bands differ from one thread's within anti-aliasing (an edge cut at a band's top steps
    /// from there: a sixteenth of a pixel), never by a seam.
    @Test(arguments: kinds)
    func ADrawingInBandsIsTheSameAsOnOneThread(_ kind: String) throws {
        let engine = try PdfEngine.open(Self.file(kind))
        defer { engine.close() }
        let g = engine.page(0)
        let scale = min(2.0, 1200 / g.width) * 1.5 // past the size that is split
        let whole = RectD(0, 0, g.width, g.height)
        let region = RectD(g.width * 0.13, g.height * 0.21, g.width * 0.6, g.height * 0.55) // offset rows and columns
        for area in [whole, region] {
            let one = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: scale, region: area) }
            #expect(one.pixels.contains { $0 < 200 }, "\(kind): nothing drawn")
            for bands in [3, 7, 16] {
                let split = try PdfEngine.$bandsForTests.withValue(bands) { try engine.render(0, scale: scale, region: area) }
                #expect(split.width == one.width && split.height == one.height, "\(kind), \(bands) bands")
                if kind == "drawing sheet" {
                    let d = Self.differ(split.pixels, one.pixels)
                    #expect(d.most <= 32 && d.mean < 2, "\(bands) bands: at most \(d.most) apart, \(d.mean) on average")
                    #expect(d.most > 0, "\(bands) bands: drawn on one thread")
                } else {
                    #expect(Self.same(split.pixels, one.pixels), "\(kind), \(bands) bands")
                }
            }
        }
        #expect(PdfEngine.bands(1200 * 800) > 1, "a sheet at 1,200 px is split by default")
        #expect(PdfEngine.bands(512 * 512) == 1, "a tile isn't")
    }

    /// A page whose drawing alone takes seconds (2,000 translucent circles at 600 dpi: 10 s of one M1 core, 2.1 s in 16
    /// bands; reading it, milliseconds).
    static let slowToDraw: [UInt8] = {
        var content = "/GS1 gs\n"
        for i in 0..<2000 {
            let x = 120 + Double(i * 37 % 372), y = 140 + Double(i * 53 % 512)
            content += "\(Double(i % 3) / 2) 0.5 \(Double(i % 5) / 4) rg " + circle(x, y, 120) + "f\n"
        }
        return page(content, "/ExtGState << /GS1 << /ca 0.5 >> >>")
    }()


    @Test(arguments: [1, 16])
    func APageSlowToDrawIsRefusedAfterOneBudgetInBandsToo(_ bands: Int) throws {
        // Each band adding its own thread's time to one count: with a budget each, 16 bands would have had 16 budgets,
        // and this page (several seconds of one core in all, a fraction of that a band) would have been drawn.
        let engine = try P.open(Self.slowToDraw)
        defer { engine.close() }
        var refusal: PageRefused?
        let took = P.time {
            refusal = P.refused { _ = try PdfEngine.$bandsForTests.withValue(bands) { try engine.render(0, scale: 600 / 72.0) } }
        }
        #expect(took < P.limit + P.slack, "\(bands) bands: \(took) s")
        #expect(refusal?.tooSlow == true, "\(bands) bands")
        #expect(engine.verdictOf(0) == .tooSlow)
    }

    @Test func CancelStopsEveryBand() throws {
        let engine = try P.open(Self.slowToDraw, budget: 0)
        defer { engine.close() }
        let cancel = CancelToken()
        // A thread of its own, as the app's Cancel comes from the main thread: the bands keep GCD's threads busy.
        Thread {
            usleep(200_000)
            cancel.cancel()
        }.start()
        let took = P.time {
            do {
                _ = try PdfEngine.$bandsForTests.withValue(16) { try engine.render(0, scale: 600 / 72.0, cancel: cancel) }
                Issue.record("not cancelled")
            } catch is CancellationError {
            } catch {
                Issue.record("threw \(error)")
            }
        }
        #expect(took < 1.5, "\(took) s")
        #expect(engine.verdictOf(0) != .tooSlow)
    }

    // ---- Review of the bands (a0f82aaf) ----

    static let topScale = 1200 / 612.0 * 1.5

    /// Seconds a render takes when `cancel` fires 20 ms after it starts (the list made before). The cancelling thread is
    /// running before the render starts, and a render that ends before the cancel came (the thread held back on CI's busy
    /// runner: "1 bands: not cancelled" on master df75423b) is run again, at most 5 times.
    static func cancelled(_ engine: PdfEngine, bands: Int) -> Double {
        for attempt in 1...5 {
            let cancel = CancelToken()
            let go = DispatchSemaphore(value: 0)
            Thread {
                go.wait()
                usleep(20_000)
                cancel.cancel()
            }.start()
            var finished = false
            let took = P.time {
                go.signal()
                do {
                    _ = try PdfEngine.$bandsForTests.withValue(bands) { try engine.render(0, scale: topScale, cancel: cancel) }
                    finished = true
                } catch is CancellationError {
                } catch {
                    Issue.record("\(bands) bands: threw \(error)")
                }
            }
            if !finished { return took }
            if attempt == 5 { Issue.record("\(bands) bands: not cancelled, 5 times") }
        }
        return .infinity
    }

    /// A list of `times` x 10,000 strokes below the page (a form drawn again and again), which every band skips, and
    /// lines on it: skipping them costs one thread little, 16 bands far more in all (each walks the whole list).
    static let skippedBelow = offPage(150)

    static func offPage(_ times: Int) -> [UInt8] {
        var form = "0.3 w\n"
        var rng = SplitMix(seed: 3)
        for _ in 0..<10_000 {
            let x = rng.next(600), y = -400 + rng.next(300)
            form += "\(x) \(y) m \(x + 2) \(y + 1) l S\n"
        }
        let content = String(repeating: "/F Do\n", count: times) + grid(2400)
        return page(content, "/XObject << /F 5 0 R >>", more: [
            P.stream(P.zlib(Array(form.utf8)), "/Type /XObject /Subtype /Form /BBox [0 -400 612 0] /Filter /FlateDecode"),
        ])
    }

    /// A band that only skips nodes makes no drawing call the guard sees: it must see a stop in MuPDF's own flag, which
    /// it reads between nodes, or it walks the whole list after the others stopped.
    @Test func ACancelStopsBandsThatOnlySkipAsSoonAsOneThread() throws {
        let engine = try P.open(Self.skippedBelow, budget: 0)
        defer { engine.close() }
        _ = try engine.render(0, scale: 0.1) // the list, made once
        let alone = Self.cancelled(engine, bands: 1)
        let banded = Self.cancelled(engine, bands: 16)
        // 0.05 s more on a Mac; 0.5 s on GitHub's runner, whose 3 cores take 16 threads in turns (0.17 against 0.02 s
        // seen, 6c6e72c7): the walk this guards against took 1.5 s.
        let more = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 0.05 : 0.5
        #expect(banded < alone + more, "16 bands: \(banded) s after Cancel at 20 ms; one thread: \(alone) s")
    }

    /// The bands share one budget but cost more CPU in all than one thread (every band walks the list): a page one thread
    /// draws within its budget must never be refused in bands.
    @Test func APageOneThreadDrawsInItsBudgetIsDrawnInBands() throws {
        let engine = try P.open(Self.skippedBelow, budget: 0)
        defer { engine.close() }
        _ = try engine.render(0, scale: 0.1)
        let alone = try P.time { _ = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: Self.topScale) } }
        engine.pageBudget = alone * 1.5
        let one = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: Self.topScale) }
        var banded: RenderedImage?
        let took = P.time {
            do {
                banded = try PdfEngine.$bandsForTests.withValue(16) { try engine.render(0, scale: Self.topScale) }
            } catch {
                Issue.record("16 bands within a budget of \(alone * 1.5) s: \(error)")
            }
        }
        #expect(Self.same(banded?.pixels, one.pixels), "\(took) s in bands")
        #expect(engine.verdictOf(0) != .tooSlow)
    }

    /// A sheet of `count` lines along the rows and columns.
    static func grid(_ count: Int, extra: String = "") -> String {
        var content = "0.5 w 0 0 0 RG\n"
        var rng = SplitMix(seed: 5)
        for i in 0..<count {
            let x = 20 + rng.next(560), y = 20 + rng.next(740), l = 10 + rng.next(200)
            content += i % 2 == 0 ? "\(x) \(y) m \(x + l) \(y) l S\n" : "\(x) \(y) m \(x) \(y + l) l S\n"
        }
        return content + extra
    }

    /// MuPDF's rasterizer moves a slanted edge's end to where it crosses the picture's top or bottom, rounded to its
    /// sub-pixel grid, and steps the edge from there (draw-edge.c, clip_lerp_y): a picture's rows depend on where it is
    /// cut, on one thread as in bands (the viewer's tiles differ from a whole page the same way). Overlapping the bands
    /// would only move the cut. So each band must be, byte for byte, what one thread draws of the same rows; and a sheet
    /// of lines along the rows and columns, whose edges a cut doesn't move, is the whole page's picture byte for byte.
    @Test(arguments: [2, 3, 8, 16])
    func EachBandIsWhatOneThreadDrawsOfItsRows(_ bands: Int) throws {
        let engine = try PdfEngine.open(Self.file("drawing sheet"))
        defer { engine.close() }
        let g = engine.page(0)
        let scale = 1200 / g.height // 1,200 rows: every count of bands here cuts at whole rows
        let split = try PdfEngine.$bandsForTests.withValue(bands) { try engine.render(0, scale: scale) }
        var stitched: [UInt8] = []
        for i in 0..<bands {
            let y0 = Double(1200 * i / bands) / scale, y1 = Double(1200 * (i + 1) / bands) / scale
            let rows = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: scale, region: RectD(0, y0, g.width, y1 - y0)) }
            stitched += rows.pixels
        }
        #expect(split.height == 1200)
        #expect(Self.same(split.pixels, stitched), "\(bands) bands")
        let whole = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: scale) }
        #expect(!Self.same(stitched, whole.pixels), "one thread cut at the bands' rows: the same as whole")
    }

    @Test(arguments: [3, 7, 16])
    func ASheetOfStraightLinesIsTheSameInBandsByteForByte(_ bands: Int) throws {
        let engine = try PdfEngine.open(Self.page(Self.grid(2400)))
        defer { engine.close() }
        let scale = 1200 / 612.0 * 1.5
        let one = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: scale) }
        let split = try PdfEngine.$bandsForTests.withValue(bands) { try engine.render(0, scale: scale) }
        #expect(Self.same(split.pixels, one.pixels), "\(bands) bands")
    }

    /// A Type3 font whose one glyph ("A") draws a picture mask: a glyph larger than MuPDF's glyph cache takes is drawn
    /// by the draw device clipped to its band, and its picture scaled for that band's part only.
    static let typeThree: [UInt8] = {
        var mask: [UInt8] = []
        for y in 0..<150 {
            for x in stride(from: 0, to: 200, by: 8) {
                var byte: UInt8 = 0
                for b in 0..<8 where ((x + b) / 7 + y / 5) % 3 == 0 || (x + b + y) % 11 == 0 { byte |= 0x80 >> UInt8(b) }
                mask.append(byte)
            }
        }
        let content = grid(2400, extra: "0 0 0 rg BT /T3 150 Tf 100 300 Td (A) Tj ET")
        return page(content, "/Font << /T3 5 0 R >>", more: [
            P.obj("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a 6 0 R >> "
                  + "/Encoding << /Type /Encoding /Differences [65 /a] >> /FirstChar 65 /LastChar 65 /Widths [1000] "
                  + "/Resources << /XObject << /Im 7 0 R >> >> >>"),
            P.stream("1000 0 0 0 1000 1000 d1 q 1000 0 0 1000 0 0 cm /Im Do Q"),
            P.stream(P.zlib(mask), "/Type /XObject /Subtype /Image /Width 200 /Height 150 /BitsPerComponent 1 /ImageMask true /Filter /FlateDecode"),
        ])
    }()

    @Test(arguments: [3, 7, 16])
    func AType3GlyphWithAPictureIsNotSplit(_ bands: Int) throws {
        let engine = try PdfEngine.open(Self.typeThree)
        defer { engine.close() }
        let scale = 1200 / 612.0 * 1.5
        let one = try PdfEngine.$bandsForTests.withValue(1) { try engine.render(0, scale: scale) }
        #expect(Self.dark(one.pixels) > 50_000, "the glyph drawn")
        let split = try PdfEngine.$bandsForTests.withValue(bands) { try engine.render(0, scale: scale) }
        #expect(Self.same(split.pixels, one.pixels), "\(bands) bands")
    }
}
