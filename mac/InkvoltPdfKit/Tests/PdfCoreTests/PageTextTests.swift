import Foundation
import Testing
@testable import PdfCore

/// Ported from PageTextTests.cs: hit-testing and caret placement on synthetic text layers, the view rotation maths, and
/// how many pages the engine keeps loaded. Images are RGB here (BGR on Windows): the turned-image test checks the first
/// byte of each pixel either way.
struct PageTextTests {
    private static let w = 6.0, h = 10.0 // character box

    /// A left-to-right line of fixed-width characters with its top-left at (x, y).
    private func line(_ text: String, _ x: Double, _ y: Double) -> [(String, RectD)] {
        Array(text).enumerated().map { i, c in (String(c), RectD(x + Double(i) * Self.w, y, Self.w, Self.h)) }
    }

    /// A right-to-left line in reading order: the first character is the rightmost.
    private func rtlLine(_ text: String, _ right: Double, _ y: Double) -> [(String, RectD)] {
        Array(text).enumerated().map { i, c in (String(c), RectD(right - Double(i + 1) * Self.w, y, Self.w, Self.h)) }
    }

    /// Text turned clockwise: reads top to bottom, characters stacked at x.
    private func downLine(_ text: String, _ x: Double, _ y: Double) -> [(String, RectD)] {
        Array(text).enumerated().map { i, c in (String(c), RectD(x, y + Double(i) * Self.w, Self.h, Self.w)) }
    }

    private func offset(_ text: PageText, of needle: String) -> Int {
        let r = (text.text as NSString).range(of: needle, options: .literal)
        return r.location
    }

    @Test func betweenTwoLinesOfTheLeftColumnTheCaretStaysInThatColumn() {
        // Two columns whose lines are offset: right-column lines sit level with the gaps of the left column.
        var lines: [[(String, RectD)]] = []
        for i in 0..<5 { lines.append(line("left column text here", 50, 100 + Double(i) * 14)) }
        for i in 0..<5 { lines.append(line("right column text", 250, 107 + Double(i) * 14)) }
        let text = PageText(lines)
        let rightStart = offset(text, of: "right")

        var caret = text.hitTest(80, 112) // in the gap between left lines 1 and 2, level with right line 1
        #expect(caret < rightStart, "caret \(caret) jumped to the right column")
        caret = text.hitTest(280, 119) // the gap between right lines 1 and 2, level with a left line
        #expect(caret >= rightStart, "caret \(caret) jumped to the left column")
    }

    @Test func besideAShortLastLineOrAHeadingTheCaretGoesToItsEnd() {
        let text = PageText([
            line("Title", 50, 60),
            line("a paragraph line that is long", 50, 100),
            line("another long paragraph line..", 50, 114),
            line("end.", 50, 128),
            line("next paragraph starts here...", 50, 150),
        ])
        #expect(text.hitTest(200, 65) == 5) // right of the heading
        let end = offset(text, of: "end.") + 4
        #expect(text.hitTest(200, 133) == end) // right of the paragraph's short last line
        #expect(text.hitTest(50 + 2 * Self.w + 1, 118) == offset(text, of: "another") + 2)
    }

    @Test(arguments: [true, false])
    func sidewaysLinesPlaceTheCaretAlongTheirDirection(withDirection: Bool) {
        // Text on a page shown turned: the line runs down the page, x says nothing about the position in it.
        let text = PageText([downLine("abcd", 100, 100)], directions: withDirection ? [(0, 1)] : nil)
        #expect(text.hitTest(140, 100 + Self.w * 1.2) == 1) // upper half of 'b'
        #expect(text.hitTest(60, 100 + Self.w * 1.8) == 2) // lower half of 'b'
        #expect(text.hitTest(105, 300) == 4) // below the end
        #expect(text.hitTest(105, 20) == 0) // above the start
    }

    @Test func rightToLeftCharactersCountFromTheirRightSide() {
        let text = PageText([rtlLine("אבג", 130, 100)]) // א 124-130, ב 118-124, ג 112-118
        #expect(text.hitTest(129, 105) == 0) // right half of א: before it
        #expect(text.hitTest(125, 105) == 1) // left half of א: after it
        #expect(text.hitTest(100, 105) == 3) // left of everything: the end of the line
        #expect(text.hitTest(150, 105) == 0) // right of everything: the start
    }

    @Test func mixedLinesPlaceTheCaretPerRun() {
        // "ab אב" in reading order; the Hebrew run is laid out right to left after the space.
        let line: [(String, RectD)] = [
            ("a", RectD(50, 100, Self.w, Self.h)), ("b", RectD(56, 100, Self.w, Self.h)), (" ", RectD(62, 100, Self.w, Self.h)),
            ("א", RectD(74, 100, Self.w, Self.h)), ("ב", RectD(68, 100, Self.w, Self.h)),
        ]
        let text = PageText([line])
        #expect(text.hitTest(51, 105) == 0) // left half of 'a'
        #expect(text.hitTest(61, 105) == 2) // right half of 'b'
        #expect(text.hitTest(79, 105) == 3) // right half of א: before it
        #expect(text.hitTest(76, 105) == 4) // left half of א: after it
        #expect(text.hitTest(69, 105) == 5) // left half of ב: after it, the end
    }

    @Test func aSurrogatePairIsNeverSplit() {
        let line: [(String, RectD)] = [("a", RectD(50, 100, Self.w, Self.h)), ("😀", RectD(56, 100, Self.w, Self.h)), ("b", RectD(62, 100, Self.w, Self.h))]
        let text = PageText([line])
        #expect(text.hitTest(57, 105) == 1)
        #expect(text.hitTest(61, 105) == 3)
    }

    @Test func movingBetweenLinesKeepsThePositionAlongThem() {
        let text = PageText([line("first line", 50, 100), rtlLine("שורה שנייה", 110, 114)])
        let second = offset(text, of: "\n") + 1
        // From x = 52 (inside 'f') down to the right-to-left line: its leftmost character is its last one.
        #expect(text.nearestCaretInLine(second, 50.5, 119) == text.length)
        #expect(text.nearestCaretInLine(second, 109.5, 119) == second)
        #expect(text.nearestCaretInLine(0, 56 + 1, 105) == 1)
    }

    @Test(arguments: [0, 90, 180, 270])
    func rotatedViewMapsPointsBothWays(rotation: Int) {
        let pw = 200.0, ph = 300.0
        let (vw, vh) = RotatedView.size(pw, ph, rotation)
        for (x, y) in [(0.0, 0.0), (pw, 0.0), (pw, ph), (0.0, ph), (17.5, 42.25)] {
            let v = RotatedView.toView(x, y, pw, ph, rotation)
            #expect((0...vw).contains(v.x))
            #expect((0...vh).contains(v.y))
            let b = RotatedView.fromView(v.x, v.y, pw, ph, rotation)
            #expect(abs(b.x - x) < 1e-9)
            #expect(abs(b.y - y) < 1e-9)
        }
        let r = RectD(10, 20, 30, 40)
        #expect(RotatedView.fromView(RotatedView.toView(r, pw, ph, rotation), pw, ph, rotation) == r)
    }

    @Test func clockwiseMeansTheTopLeftCornerGoesTopRight() {
        #expect(RotatedView.toView(0, 0, 200, 300, 90) == (300.0, 0.0))
        #expect(RotatedView.toView(0, 0, 200, 300, 270) == (0.0, 200.0))
        #expect(RotatedView.normalize(-90) == 270)
        #expect(RotatedView.normalize(360) == 0)
    }

    @Test(arguments: [90, 180, 270])
    func renderedImagesTurnLikeTheView(rotation: Int) throws {
        // 3 × 2 image; each pixel's first byte is its index.
        var px = [UInt8](repeating: 0, count: 3 * 2 * 3)
        for i in 0..<6 { px[i * 3] = UInt8(i) }
        let turned = try RenderedImage(3, 2, px).rotated(rotation)
        let (w, h) = RotatedView.size(3, 2, rotation)
        #expect(turned.width == Int(w))
        #expect(turned.height == Int(h))
        for y in 0..<2 {
            for x in 0..<3 {
                // The pixel's center goes where the view puts that point.
                let v = RotatedView.toView(Double(x) + 0.5, Double(y) + 0.5, 3, 2, rotation)
                #expect(turned.pixels[(Int(v.y) * turned.width + Int(v.x)) * 3] == UInt8(y * 3 + x))
            }
        }
    }

    @Test func scrollingALongDocumentKeepsFewPagesLoaded() throws {
        let engine = try PdfEngine.open(TestPdf.make(90))
        defer { engine.close() }
        #expect((0...PdfEngine.loadedPagesKept).contains(engine.loadedCounts().render.pages))
        let first = try engine.render(0, scale: 0.25)
        for p in 0..<engine.pageCount {
            _ = try engine.render(p, scale: 0.25)
            _ = try engine.text(p, cache: false)
            _ = try engine.links(p)
        }
        let (render, text) = engine.loadedCounts()
        #expect((1...PdfEngine.loadedPagesKept).contains(render.pages))
        #expect((0...PdfEngine.loadedPagesKept).contains(render.lists))
        #expect((1...PdfEngine.loadedPagesKept).contains(text.pages))
        #expect((0...PdfEngine.loadedPagesKept).contains(text.lists))
        // A freed page loads again.
        #expect(try engine.render(0, scale: 0.25).pixels == first.pixels)
        #expect(try engine.text(0, cache: false).text.contains("Page 1"))
    }

    @Test func cancelledTextAndLinkRequestsDoNotRun() throws {
        let engine = try PdfEngine.open(TestPdf.make(2))
        defer { engine.close() }
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try engine.text(0, cancel: cancel) }
        #expect(throws: CancellationError.self) { try engine.links(0, cancel: cancel) }
        #expect(try engine.text(0).text.contains("Page 1"))
    }
}
