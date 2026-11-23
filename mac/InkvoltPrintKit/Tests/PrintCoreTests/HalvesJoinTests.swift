import Foundation
import Testing
import TestTiming
@testable import PrintCore

/// Ported from HalvesJoinTests.cs: joining two halves of an original too big for the glass (roadmap 4.8), on made-up scans at
/// 100 pixels an inch. Adapted: the drawings come from a fixed generator here (.NET's `Random` there: other boxes, the same
/// kind of drawing); a stop is a `BatchStop`, which throws `CancellationError`.
struct HalvesJoinTests {
    private static let ppi = 100.0

    private struct Rng {
        var state: UInt64
        init(_ seed: Int) { state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func next(_ n: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(n))
        }
        mutating func next(_ low: Int, _ high: Int) -> Int { low + next(high - low) }
    }

    /// A made-up drawing `w` × `h`: paper, ruled boxes and blocky labels all over.
    private static func drawing(_ w: Int, _ h: Int, seed: Int = 3) -> [UInt8] {
        var px = [UInt8](repeating: 240, count: w * h)
        var rng = Rng(seed)
        for _ in 0..<(w * h / 4000) {
            let (x, y, bw, bh) = (rng.next(w - 60), rng.next(h - 60), 10 + rng.next(50), 6 + rng.next(50))
            let level = UInt8(rng.next(20, 160))
            let outline = rng.next(2) == 0
            for yy in y..<(y + bh) {
                for xx in x..<(x + bw) where !outline || yy < y + 2 || yy >= y + bh - 2 || xx < x + 2 || xx >= x + bw - 2 { px[yy * w + xx] = level }
            }
        }
        return px
    }

    /// The part of `src` (width `sw`) from (x, y), `w` × `h`; outside it white (the lid).
    private static func part(_ src: [UInt8], _ sw: Int, _ sh: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 250, count: w * h)
        for yy in 0..<h {
            for xx in 0..<w where x + xx >= 0 && y + yy >= 0 && x + xx < sw && y + yy < sh { px[yy * w + xx] = src[(y + yy) * sw + x + xx] }
        }
        return px
    }

    private static func turn(_ px: [UInt8]) -> [UInt8] { px.reversed() }

    private static func noise(_ px: inout [UInt8], _ seed: Int) {
        var rng = Rng(seed)
        for i in px.indices { px[i] = UInt8(min(255, max(0, Int(px[i]) + rng.next(-4, 5)))) }
    }

    private static func gray(_ w: Int, _ h: Int, _ px: [UInt8]) -> GrayImage { GrayImage(w, h, px) }

    @Test func twoHalvesSideBySideAreFoundAndJoined() throws {
        let (w, h) = (1500, 1000) // a 15 × 10 inch original on an 8.5 inch wide glass
        let original = Self.drawing(w, h)
        var first = Self.part(original, w, h, 0, 0, 850, h)
        var second = Self.part(original, w, h, 650, -15, 850, h) // two inches of overlap, laid 0.15 inch higher on the glass
        Self.noise(&first, 1)
        Self.noise(&second, 2)
        let found = try HalvesJoin.find(Self.gray(850, h, first), Self.gray(850, h, second), ppi: Self.ppi)
        #expect(found.sure, "score \(found.score), next \(found.next), \(found.placement)")
        #expect(found.placement == JoinPlacement(.right, false, 650, -15))

        let joined = try #require(HalvesJoin.join(first, 850, h, second, 850, h, channels: 1, found.placement))
        #expect(joined.width == 1500 && joined.height == 1015)
        // Each side of the seam is its half: the original, give or take the scan's noise.
        for (x, y) in [(100, 300), (740, 500), (760, 500), (1400, 900)] {
            #expect(abs(Int(joined.pixels[(y + 15) * 1500 + x]) - Int(original[y * w + x])) <= 4) // the page starts 0.15 inch above the first half
        }
    }

    @Test func aSecondHalfScannedTheOtherWayRoundIsTurned() throws {
        let (w, h) = (1500, 1000)
        let original = Self.drawing(w, h, seed: 9)
        let first = Self.part(original, w, h, 0, 0, 850, h)
        let second = Self.turn(Self.part(original, w, h, 700, 0, 850, h)) // the original turned round on the glass for its other half
        let found = try HalvesJoin.find(Self.gray(850, h, first), Self.gray(850, h, second), ppi: Self.ppi)
        #expect(found.sure)
        #expect(found.placement == JoinPlacement(.right, true, 700, 0))
        let joined = try #require(HalvesJoin.join(first, 850, h, second, 850, h, channels: 1, found.placement))
        #expect(joined.pixels[600 * 1550 + 1300] == original[600 * w + 1300])
    }

    /// Minutes of every core on CI's three (it held the whole suite's timing tests up by 150 s): it runs on the Mac and the
    /// PC, not on CI (`Timing.onCI`), as PageCleanupTests' huge page does.
    @Test(.enabled(if: !Timing.onCI)) func aHugePageIsSearchedOnASmallCopyAndStillFound() throws {
        // Halves said to be at 12 pixels an inch, 1600 pixels long (133 inches): searched on copies that size, every placement
        // takes minutes; on copies of at most 400 pixels a side, a moment.
        let (w, h) = (2700, 200)
        let original = Self.drawing(w, h, seed: 7)
        let first = Self.part(original, w, h, 0, 0, 1600, h)
        let second = Self.part(original, w, h, 1100, 0, 1600, h)
        let started = Date()
        let found = try HalvesJoin.find(Self.gray(1600, h, first), Self.gray(1600, h, second), ppi: 12)
        #expect(Date().timeIntervalSince(started) < Timing.limit(10))
        #expect(found.placement == JoinPlacement(.right, false, 1100, 0))
    }

    @Test func findingTheOverlapStopsWhenCancelled() {
        let original = Self.drawing(1500, 1000)
        let (first, second) = (Self.part(original, 1500, 1000, 0, 0, 850, 1000), Self.part(original, 1500, 1000, 650, 0, 850, 1000))
        let stop = BatchStop()
        stop.stop()
        #expect(throws: CancellationError.self) { try HalvesJoin.find(Self.gray(850, 1000, first), Self.gray(850, 1000, second), ppi: Self.ppi, stop: stop) }
    }

    @Test func halvesOneAboveTheOtherAndGivenInEitherOrder() throws {
        let (w, h) = (1000, 1500)
        let original = Self.drawing(w, h, seed: 4)
        let top = Self.part(original, w, h, 0, 0, w, 850)
        let bottom = Self.part(original, w, h, 8, 650, w, 850)
        let below = try HalvesJoin.find(Self.gray(w, 850, top), Self.gray(w, 850, bottom), ppi: Self.ppi)
        #expect(below.sure)
        #expect(below.placement == JoinPlacement(.below, false, 8, 650))
        let above = try HalvesJoin.find(Self.gray(w, 850, bottom), Self.gray(w, 850, top), ppi: Self.ppi) // the bottom half scanned first
        #expect(above.sure)
        #expect(above.placement == JoinPlacement(.above, false, -8, -650))
    }

    /// A plan on squared paper: the grid repeats every half inch, so only its few labels tell the overlap from a step of it.
    @Test func aRuledGridIsntTakenForTheOverlap() throws {
        let (w, h) = (1400, 1100)
        var plan = [UInt8](repeating: 245, count: w * h)
        for y in 0..<h { for x in 0..<w where x % 50 == 0 || y % 50 == 0 { plan[y * w + x] = 150 } }
        var rng = Rng(5)
        for _ in 0..<25 {
            let (x0, y0) = (rng.next(w - 80), rng.next(h - 30))
            for y in y0..<(y0 + 20) { for x in x0..<(x0 + 70) where (x + y) % 3 != 0 { plan[y * w + x] = 30 } }
        }
        var first = Self.part(plan, w, h, 0, 0, 850, h)
        var second = Self.turn(Self.part(plan, w, h, 550, 10, 850, h))
        Self.noise(&first, 3)
        Self.noise(&second, 4)
        let found = try HalvesJoin.find(Self.gray(850, h, first), Self.gray(850, h, second), ppi: Self.ppi)
        #expect(found.sure, "score \(found.score), next \(found.next), \(found.placement)")
        #expect(found.placement == JoinPlacement(.right, true, 550, 10))
    }

    @Test func halvesThatDontOverlapAreAGuessToNudge() throws {
        let (w, h) = (850, 1000)
        let found = try HalvesJoin.find(Self.gray(w, h, Self.drawing(w, h, seed: 1)), Self.gray(w, h, Self.drawing(w, h, seed: 2)), ppi: Self.ppi) // nothing in common
        #expect(!found.sure)

        // Squared paper with nothing on it: every step of the grid matches as well as any other.
        let grid = (0..<(w * h)).map { i -> UInt8 in i % w % 50 == 0 || i / w % 50 == 0 ? 140 : 245 }
        var (gridA, gridB) = (grid, grid)
        Self.noise(&gridA, 5)
        Self.noise(&gridB, 6) // two scans are never the same to the pixel
        #expect(!(try HalvesJoin.find(Self.gray(w, h, gridA), Self.gray(w, h, gridB), ppi: Self.ppi).sure))

        let blank = [UInt8](repeating: 245, count: w * h)
        let plain = try HalvesJoin.find(Self.gray(w, h, blank), Self.gray(w, h, blank), ppi: Self.ppi)
        #expect(!plain.sure)
        #expect(plain.placement == HalvesJoin.edgeToEdge(.right, false, w, h, w, h)) // edge to edge, to start the nudge from
    }

    /// The app finds the overlap on copies a third the size: a copy leaves out the half's last columns, which, the half turned
    /// round, are its first, so the placement moves back by them at full size.
    @Test func aTurnedHalfFoundOnSmallerCopiesLandsToThePixel() throws {
        let (w, h, factor) = (1500, 999, 3)
        let original = Self.drawing(w, h, seed: 12)
        let first = Self.part(original, w, h, 0, 0, 850, h)
        let second = Self.turn(Self.part(original, w, h, 652, 0, 848, h)) // 848 = 3 × 282 + 2: two columns more than the copy holds
        let found = try HalvesJoin.find(HalvesJoin.gray(first, 850, h, channels: 1, factor: factor), HalvesJoin.gray(second, 848, h, channels: 1, factor: factor),
                                        ppi: Self.ppi / Double(factor))
        #expect(found.sure)
        #expect(HalvesJoin.fromCopy(found.placement, factor: factor, secondWidth: 848, secondHeight: h) == JoinPlacement(.right, true, 652, 0))
        #expect(found.placement.scaled(Double(factor)) == JoinPlacement(.right, true, 654, 0)) // scaled alone: two pixels off
        #expect(HalvesJoin.toCopy(JoinPlacement(.right, true, 652, 0), factor: factor, secondWidth: 848, secondHeight: h) == found.placement)
        // Unturned, a copy's columns start where the half's do.
        #expect(HalvesJoin.fromCopy(JoinPlacement(.right, false, 217, 1), factor: factor, secondWidth: 848, secondHeight: h) == JoinPlacement(.right, false, 651, 3))
        let joined = try #require(HalvesJoin.join(first, 850, h, second, 848, h, channels: 1,
                                                  HalvesJoin.fromCopy(found.placement, factor: factor, secondWidth: 848, secondHeight: h)))
        #expect(Array(joined.pixels[(500 * 1500 + 1000)..<(500 * 1500 + 1400)]) == Array(original[(500 * w + 1000)..<(500 * w + 1400)]))
    }

    @Test func aNudgeAndAScaleMoveThePlacement() {
        let at = JoinPlacement(.right, false, 650, 15)
        #expect(at.nudged(5, -5) == JoinPlacement(.right, false, 655, 10))
        #expect(at.scaled(3) == JoinPlacement(.right, false, 1950, 45))
        #expect(HalvesJoin.edgeToEdge(.below, true, 200, 300, 200, 300) == JoinPlacement(.below, true, 0, 300))
        #expect(HalvesJoin.edgeToEdge(.left, false, 200, 300, 200, 400) == JoinPlacement(.left, false, -200, -50))
    }

    @Test func colorHalvesJoinAndAJoinTooLargeIsRefused() throws {
        let first = [UInt8](repeating: 10, count: 4 * 2 * 3)
        let second = [UInt8](repeating: 200, count: 4 * 2 * 3)
        let joined = try #require(HalvesJoin.join(first, 4, 2, second, 4, 2, channels: 3, JoinPlacement(.right, false, 2, 1)))
        #expect(joined.width == 6 && joined.height == 3)
        #expect(joined.pixels[(1 * 6 + 2) * 3] == 10) // left of the seam (x 3): the first half
        #expect(joined.pixels[(1 * 6 + 3) * 3] == 200) // from the seam on: the second
        #expect(joined.pixels[(0 * 6 + 5) * 3] == 255) // neither: white
        #expect(HalvesJoin.join(first, 4, 2, second, 4, 2, channels: 3, JoinPlacement(.right, false, 20_000, 20_000)) == nil) // a page past the limit
        #expect(HalvesJoin.join(first, 40, 2, second, 4, 2, channels: 3, JoinPlacement(.right, false, 2, 0)) == nil) // fewer pixels than it says
        #expect(HalvesJoin.join(first, 4, 2, second, 4, 2, channels: 3, JoinPlacement(.right, false, Int.max, Int.min)) == nil) // Mac only: no overflow
    }

    /// Mac only (Windows' view model does it): the joined page takes the halves' place and the first's new-file mark; Undo puts
    /// the halves back where they were.
    @Test func theJoinedPageTakesTheHalvesPlaceAndUndoPutsThemBack() {
        var pages = ScanPages(["a", "b", "c", "d"].map { ScannedPage(id: $0, dpi: 300) })
        pages.toggleStartsFile("b")
        let done = pages.join("b", "c", into: ScannedPage(id: "bc", dpi: 300))
        #expect(pages.pages.map(\.id) == ["a", "bc", "d"])
        #expect(pages.page("bc")?.startsFile == true)
        #expect(done?.at == 1 && done?.halves.map(\.id) == ["b", "c"])
        pages.unjoin("bc", halves: done!.halves, at: done!.at)
        #expect(pages.pages.map(\.id) == ["a", "b", "c", "d"] && pages.page("b")?.startsFile == true)
        #expect(pages.join("a", "gone", into: ScannedPage(id: "x", dpi: 300)) == nil && pages.pages.count == 4)
    }

    /// `px` (width `w`) twice as large each way: a drawing at 100 pixels an inch as scanned at 200.
    private static func doubled(_ px: [UInt8], _ w: Int) -> [UInt8] {
        let h = px.count / w
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<(h * 2) {
            for x in 0..<(w * 2) { out[y * w * 2 + x] = px[y / 2 * w + x / 2] }
        }
        return out
    }

    /// Mac only (Windows' join view does it): full-size halves are looked for on copies of about 100 pixels an inch, and the
    /// placement found is where the second half starts, in full-size pixels, sure or not. Review finding: one scoring 0 or
    /// less was put edge to edge instead.
    @Test func fullSizeHalvesAreFoundOnCopiesAndTheGuessIsKeptSureOrNot() throws {
        let (w, h) = (1500, 999)
        let original = Self.doubled(Self.drawing(w, h, seed: 12), w) // 3000 × 1998, "scanned at 200 dpi"
        let first = Self.part(original, 3000, 1998, 0, 0, 1700, 1998)
        // 1695 wide: odd, so its copy leaves out a column, which, turned, is its first (the cut ends on the drawing's last
        // column, so the copy's pixels are the drawing's, as the first half's are).
        let second = Self.turn(Self.part(original, 3000, 1998, 1305, 0, 1695, 1998))
        #expect(HalvesJoin.analysisFactor(dpi: 200) == 2 && HalvesJoin.analysisFactor(dpi: 600) == 6 && HalvesJoin.analysisFactor(dpi: 75) == 1)
        let found = try HalvesJoin.find(first, 1700, 1998, second, 1695, 1998, channels: 1, dpi: 200)
        #expect(found.sure, "score \(found.score), next \(found.next), \(found.placement)")
        #expect(found.placement == JoinPlacement(.right, true, 1305, 0))

        // Nothing in common: not sure, and the guess is the search's, at full size (not edge to edge).
        let other = Self.doubled(Self.drawing(850, h, seed: 2), 850)
        let guess = try HalvesJoin.find(first, 1700, 1998, other, 1700, 1998, channels: 1, dpi: 200)
        let onCopies = try HalvesJoin.find(HalvesJoin.gray(first, 1700, 1998, channels: 1, factor: 2), HalvesJoin.gray(other, 1700, 1998, channels: 1, factor: 2),
                                           ppi: 100)
        #expect(!guess.sure && guess.score == onCopies.score)
        #expect(guess.placement == HalvesJoin.fromCopy(onCopies.placement, factor: 2, secondWidth: 1700, secondHeight: 1998))

        // Fewer pixels than said, or no channels it reads: edge to edge, not sure, nothing read past the end.
        let short = try HalvesJoin.find([1, 2, 3], 1700, 1998, other, 1700, 1998, channels: 1, dpi: 200)
        #expect(!short.sure && short.placement == HalvesJoin.edgeToEdge(.right, false, 1700, 1998, 1700, 1998))
        #expect(!(try HalvesJoin.find(first, 1700, 1998, other, 1700, 1998, channels: 2, dpi: 200).sure))
        #expect(!(try HalvesJoin.find(first, Int.max, 1998, other, 1700, -1, channels: 1, dpi: 200).sure))
    }

    /// Mac only: the preview's copies are made once, small enough that the halves side by side are at most about the side
    /// asked for (Windows' join view: the same sum with its 1600).
    @Test func thePreviewsCopiesAreSmallEnoughForTheHalvesSideBySide() {
        #expect(HalvesJoin.previewFactor(3000, 1998, 1695, 1998, side: 900) == 7) // ⌈6000 / 900⌉
        #expect(HalvesJoin.previewFactor(400, 300, 300, 300, side: 900) == 1)
        #expect(HalvesJoin.previewFactor(4500, 100, 100, 100, side: 900) == 10)
        #expect(HalvesJoin.previewFactor(Int.max, 1, 1, 1, side: 0) >= 1) // no trap
        #expect(HalvesJoin.previewFactor(-5, -5, -5, -5, side: 900) == 1 && HalvesJoin.previewFactor(10, 10, 10, 10, side: .max) == 1)
    }
}
