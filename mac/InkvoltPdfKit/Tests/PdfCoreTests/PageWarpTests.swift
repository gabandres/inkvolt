import Foundation
import Testing
import PrintCore
@testable import PdfCore

/// Ported from PageWarpTests.cs (roadmap 2.2's trapezoid correction and straightened lines): pages photographed at an angle
/// or open in a book (`PhotoCorpus`, with known maps) are straightened only when the page shows it clearly, and recognized
/// words map back onto the photo. The warps are PrintCore's (`Trapezoid`, `CurvedLines`), as Windows' are the shared
/// core's.
struct PageWarpTests {
    private static func distance(_ a: WarpPoint, _ b: WarpPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    @Test(.enabled(if: ScanCorpus.runs), arguments: ["en-trapezoid", "es-trapezoid"])
    func aPagePhotographedAtAnAngleIsFoundAndStraightened(_ name: String) throws {
        let (px, w, h, _) = try PhotoCorpus.photo(PhotoCorpus.file(name))
        let truth = PhotoCorpus.corners(w, h)
        let found = try #require(try Trapezoid.find(GrayImage(w, h, px)))
        for i in 0..<4 {
            #expect(Self.distance(found.corners[i], truth[i]) < 12, "corner \(i): \(found.corners[i]) for \(truth[i])")
            // The straightened page's corners come from the photo's.
            let rect = [WarpPoint(found.left, found.top), WarpPoint(found.right, found.top), WarpPoint(found.right, found.bottom), WarpPoint(found.left, found.bottom)][i]
            #expect(Self.distance(found.source(rect.x, rect.y), found.corners[i]) < 0.5)
        }

        // Cleaned with it, the page's lines run level and the desk is gone.
        let cleaned = try ScanCleanup.clean(px, w, h, 1, PhotoCorpus.dpi, steps: .trapezoid)
        #expect(cleaned.perspective != nil)
        #expect(cleaned.quarterTurns == 0)
        #expect(abs(cleaned.skew) <= 0.5)
        #expect(abs(ScanCleanup.skewOf(cleaned.gray, PhotoCorpus.dpi)) <= 0.3)
        let dark = Double(cleaned.gray.pixels.filter { $0 < 128 }.count) / Double(cleaned.gray.pixels.count)
        #expect(dark >= 0.005 && dark <= 0.12) // the print, not a desk's worth of grey
        // Without the step the same photo isn't warped.
        #expect(try ScanCleanup.clean(px, w, h, 1, PhotoCorpus.dpi).perspective == nil)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aPageLyingSquareOrCutOffOrWithoutADeskIsLeftAsItIs() throws {
        let (clean, w, h, _) = try ScanCorpus.cleanPage(ScanCorpus.files[0], 0)
        #expect(try Trapezoid.find(GrayImage(w, h, clean)) == nil) // no desk around it
        var rng = Rng(7)
        let (fw, fh) = (Double(w), Double(h))
        // Square on the desk (a flatbed with a dark lid): Deskew's to straighten, not warped.
        let square = [WarpPoint(0.1 * fw, 0.08 * fh), WarpPoint(0.9 * fw, 0.08 * fh), WarpPoint(0.9 * fw, 0.92 * fh), WarpPoint(0.1 * fw, 0.92 * fh)]
        #expect(try Trapezoid.find(GrayImage(w, h, PhotoCorpus.onDesk(clean, w, h, square, &rng))) == nil)
        // A corner out of the photo: not sure where the page ends.
        let cut = [WarpPoint(-0.05 * fw, 0.1 * fh), WarpPoint(0.86 * fw, 0.075 * fh), WarpPoint(0.95 * fw, 0.93 * fh), WarpPoint(0.06 * fw, 0.95 * fh)]
        #expect(try Trapezoid.find(GrayImage(w, h, PhotoCorpus.onDesk(clean, w, h, cut, &rng))) == nil)
        // A dark photo of no page at all.
        let dim = (0..<(w * h)).map { _ in UInt8(60 + rng.next(40)) }
        #expect(try Trapezoid.find(GrayImage(w, h, dim)) == nil)
    }

    @Test(arguments: [(0, 0), (5000, 3), (3, 5000)])
    func tinyAndHugeImagesAreLeftAlone(_ w: Int, _ h: Int) throws {
        // Sizes the warps never take on (a hostile page's image is held to ScanText's render limit before it gets here).
        let px = [UInt8](repeating: 0, count: w * h)
        #expect(try Trapezoid.find(GrayImage(w, h, px)) == nil)
        #expect(try CurvedLines.find(GrayImage(w, h, px), 300) == nil)
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: ["en-book", "es-book"])
    func aBooksBentLinesAreFlattened(_ name: String) throws {
        let (px, w, h, _) = try PhotoCorpus.photo(PhotoCorpus.file(name))
        let curve = try #require(try CurvedLines.find(GrayImage(w, h, px), PhotoCorpus.dpi))
        #expect(!curve.vertical)

        // The map follows the known sag: between two places along a line, the line moved as the book moved it.
        let (x0, x1) = (0.2 * Double(w), 0.7 * Double(w)) // within the text: past its lines the map holds still
        var worst = 0.0
        var y = 0.2 * Double(h)
        while y <= 0.8 * Double(h) {
            let (a, b) = (curve.source(x0, y).y, curve.source(x1, y).y)
            // The content at b (column x1) and at a (column x0) is one line of the page: solve each back to the typeset page.
            func typeset(_ x: Double, _ shown: Double) -> Double {
                var from = shown
                for _ in 0..<6 { from = shown - PhotoCorpus.sag(x, from, w, h) }
                return from
            }
            worst = max(worst, abs(typeset(x0, a) - typeset(x1, b)))
            y += 0.05 * Double(h)
        }
        #expect(worst < 4, "lines off by up to \(worst) px")

        // Flattened, nothing is left to straighten.
        let flat = try curve.apply(px, w, h, 1)
        #expect(try CurvedLines.find(GrayImage(w, h, flat), PhotoCorpus.dpi) == nil)

        // Through the whole cleanup.
        let cleaned = try ScanCleanup.clean(px, w, h, 1, PhotoCorpus.dpi, steps: .curvedLines)
        #expect(cleaned.curve != nil)
        #expect(cleaned.skew == 0) // tilted only by its bend: flattened as it is, not turned, so its margins stay upright
        #expect(try ScanCleanup.clean(px, w, h, 1, PhotoCorpus.dpi).curve == nil)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func sidewaysBentLinesAreFlattenedAlongTheirOwnWay() throws {
        let (px, w, h, _) = try PhotoCorpus.photo(PhotoCorpus.file("en-book"))
        let turned = ScanCleanup.turn(px, w, h, 1, 1) // h × w, lines running down
        let curve = try #require(try CurvedLines.find(GrayImage(h, w, turned), PhotoCorpus.dpi, vertical: true))
        #expect(curve.vertical)
        #expect(try CurvedLines.find(GrayImage(h, w, try curve.apply(turned, h, w, 1)), PhotoCorpus.dpi, vertical: true) == nil)
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: [("en-skew3-light", 0), ("es-skew8-shaded", 1)])
    func flatScansAreNotWarped(_ name: String, _ page: Int) throws {
        let (pixels, w, h, truth) = try ScanCorpus.makePage(ScanCorpus.file(name), page)
        let cleaned = try ScanCleanup.clean(pixels, w, h, 1, ScanCorpus.dpi, steps: .all)
        #expect(cleaned.perspective == nil)
        #expect(cleaned.curve == nil)
        #expect(abs(cleaned.skew - truth.skew) <= 0.3)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func thePageTypesetIsNotBent() throws {
        let (clean, w, h, _) = try ScanCorpus.cleanPage(ScanCorpus.files[1], 0)
        #expect(try CurvedLines.find(GrayImage(w, h, clean), ScanCorpus.dpi) == nil)
    }

    @Test func aHomographyTakesEachCornerToItsPartner() throws {
        let from = [WarpPoint(0, 0), WarpPoint(100, 0), WarpPoint(100, 50), WarpPoint(0, 50)]
        let to = [WarpPoint(10, 5), WarpPoint(95, 12), WarpPoint(110, 70), WarpPoint(-3, 60)]
        let map = try #require(Homography.between(from, to))
        for i in 0..<4 { #expect(Self.distance(map.apply(from[i].x, from[i].y), to[i]) < 1e-6) }
        #expect(Homography.between([WarpPoint(0, 0), WarpPoint(1, 1), WarpPoint(2, 2), WarpPoint(3, 3)], to) == nil) // in a line: no map
    }

    /// "Reads" the topmost line of ink as one word, as `ScanTextTests`' stand-in does.
    struct TopLineReader: TextRecognizer {
        var language: String? { "en-US" }

        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            let (w, h) = (image.width, image.height)
            func dark(_ x: Int, _ y: Int) -> Bool { image.pixels[y * image.stride + x * 3] < 128 }
            func ink(_ y: Int) -> Int { (0..<w).filter { dark($0, y) }.count }
            guard let top = (0..<h).first(where: { ink($0) > 3 }) else { return [] }
            var bottom = top
            while bottom + 1 < h && ink(bottom + 1) > 0 { bottom += 1 }
            let xs = (top...bottom).flatMap { y in (0..<w).filter { dark($0, y) } }
            let (left, right) = (xs.min() ?? 0, xs.max() ?? 0)
            return [OcrWord("Heading", RectD(Double(left), Double(top), Double(right - left + 1), Double(bottom - top + 1)))]
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func wordsReadOnAStraightenedPhotoLandOnThePhoto() throws {
        let file = PhotoCorpus.file("en-trapezoid")
        let pdf = try PhotoCorpus.pdf(file)
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let options = RecognizeOptions(checkWords: false, trapezoid: true)
        let words = try ScanText.recognize(engine, 0, TopLineReader(), options).words
        #expect(words.count == 1)
        let word = try #require(words.first)

        // The heading sits at the page's top left: on the photo, inside the page's tipped-back top, slanted as its top edge.
        let corners = PhotoCorpus.corners(2550, 3300).map { WarpPoint($0.x * 72 / 300, $0.y * 72 / 300) }
        let topEdge = atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x) * 180 / .pi
        #expect(abs(word.angle - topEdge) <= 1.0, "\(word.angle) for \(topEdge)")
        let (cx, cy) = (word.rect.x + word.rect.width / 2, word.rect.y + word.rect.height / 2)
        #expect(cx >= corners[0].x && cx <= corners[1].x)
        #expect(cy >= corners[0].y && cy <= corners[0].y + 120)
        #expect(word.rect.height >= 8 && word.rect.height <= 20) // 16 pt at about four fifths of its size
        #expect(try Core2Pdf.ink(pdf, 0, word.rect) > 0.08, "the word lies on the heading's ink")

        // Kept as the cleaned page instead, the words fit the straightened page (level).
        var keep = options
        keep.keepCleanedImage = true
        let kept = try ScanText.recognize(engine, 0, TopLineReader(), keep)
        #expect(kept.words.count == 1)
        #expect(kept.words.first?.angle == 0)
        #expect(kept.cleaned != nil)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aPointOfAFlattenedPageMapsBackThroughTheCurve() throws {
        let (px, w, h, _) = try PhotoCorpus.photo(PhotoCorpus.file("en-book"))
        let curve = try #require(try CurvedLines.find(GrayImage(w, h, px), PhotoCorpus.dpi))
        let frame = ScanFrame(width: w, height: h, skew: 0, quarterTurns: 0, perspective: nil, curve: curve)
        let mapped = frame.toRendered(400, 900)
        #expect(curve.source(400, 900) == WarpPoint(mapped.x, mapped.y))
        let word = frame.toRendered(OcrWord("bent", RectD(300, 880, 200, 40)), 72 / 300.0, 72 / 300.0)
        #expect(word.angle >= -20 && word.angle <= -0.5) // towards the spine (left) the line sags: it rises to the right
    }

    /// A flat page of two columns whose lines aren't level with each other: the right column a third of a line lower.
    private static func twoColumns() throws -> (pixels: [UInt8], width: Int, height: Int) {
        let (clean, w, h, _) = try ScanCorpus.cleanPage(ScanCorpus.files[0], 0)
        var page = [UInt8](repeating: 255, count: w * h)
        // The typeset text runs from x 300 to about 2250: its left 45% makes each column (half a page each, a gutter between).
        let (from, width, drop) = (300, Int(0.42 * Double(w)) - 300, 18) // 11 pt at 1.4 leading is 64 px a line: 18 px is under a third
        for y in 0..<h {
            for x in 0..<width {
                page[y * w + 150 + x] = clean[y * w + from + x]
                let sy = y - drop
                if sy >= 0 { page[y * w + w / 2 + 100 + x] = clean[sy * w + from + x] }
            }
        }
        return (page, w, h)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aFlatPageInTwoColumnsIsNotBent() throws {
        // The columns' lines aren't level: matched across the gutter, they'd look like a step in one bent line.
        let (px, w, h) = try Self.twoColumns()
        #expect(try CurvedLines.find(GrayImage(w, h, px), 300) == nil)
        let cleaned = try ScanCleanup.clean(px, w, h, 1, 300, steps: .all)
        #expect(cleaned.curve == nil)
        #expect(cleaned.perspective == nil)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aTiltedBooksPageIsFlattenedToItsLinesEnds() throws {
        // A book's page tilted 2° as well: flattened in place of being straightened, the ends of its lines (past the strips
        // measured) carry no tilt either.
        let (px, w, h, _) = try PhotoCorpus.photo(PhotoCorpus.file("en-book"))
        let tilted = PageRotate.rotate(px, w, h, w, 1, 2)
        let cleaned = try ScanCleanup.clean(tilted, w, h, 1, PhotoCorpus.dpi, steps: .curvedLines)
        let c = try #require(cleaned.curve)
        #expect(cleaned.skew == 0)
        #expect(abs(ScanCleanup.skewOf(cleaned.gray, PhotoCorpus.dpi)) <= 0.3)
        // Past the measured stretch the map follows the page's tilt there, not a constant.
        let beyond = c.alongTo + 300
        #expect(c.shiftAt(c.alongTo) != c.shiftAt(beyond))
        #expect(abs(c.shiftAt(c.alongTo) + c.shiftSlope * 300 / c.alongHalf - c.shiftAt(beyond)) <= 1e-6)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aTiltedFlatPageOnGreyPaperIsStraightenedNotBent() throws {
        // Grey paper shaded down to below the ink threshold on one side: read as it is, the shade would be ink. The tilted
        // page's bend is looked for on its whitened copy, finds none, and the page is straightened as before.
        let (clean, w, h, _) = try ScanCorpus.cleanPage(ScanCorpus.files[0], 0)
        var grey = [UInt8](repeating: 0, count: clean.count)
        for y in 0..<h {
            for x in 0..<w {
                let paper = 220 - 110.0 * Double(x) / Double(w)
                grey[y * w + x] = UInt8(25 + (paper - 25) * Double(clean[y * w + x]) / 255) // .NET's (byte) cast truncates
            }
        }
        let tilted = PageRotate.rotate(grey, w, h, w, 1, 2)
        let cleaned = try ScanCleanup.clean(tilted, w, h, 1, 300, steps: .curvedLines)
        #expect(cleaned.curve == nil)
        #expect(abs(cleaned.skew - 2) <= 0.3)
    }

    @Test func columnsAreSplitAtGapsAQuarterOfAnInchWide() {
        let ink = [0, 5, 5, 5, 0, 0, 9, 9, 9, 9, 0, 0, 0, 0, 0, 7, 7, 0]
        #expect(CurvedLines.widestColumn(ink, 1, 16, 4) == (1, 9)) // the gap of 5 splits, the gap of 2 doesn't
        #expect(CurvedLines.widestColumn(ink, 1, 16, 2) == (6, 9)) // both split: the inkiest column
        #expect(CurvedLines.widestColumn(ink, 1, 9, 4) == (1, 9))
        #expect(CurvedLines.widestColumn(ink, 1, 16, 6) == (1, 16))
    }
}
