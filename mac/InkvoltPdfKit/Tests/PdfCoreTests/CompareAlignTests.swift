import Foundation
import Testing
@testable import PdfCore

/// Ported from CompareAlignTests.cs (roadmap 3.3): scans lined up before the overlay, what looks different besides the
/// words, and both in the annotated copy.
struct CompareAlignTests {
    private static let scale = 100.0 / 72
    private static let w = 850, h = 1100

    /// Lines of "words" on white, as a scanned page has them: rows of dark blocks of uneven lengths.
    private static func inked(_ x: Double, _ y: Double) -> Bool {
        if x < 90 || x > 760 || y < 90 || y > 1010 { return false }
        let line = Int((y - 90) / 30)
        if (y - 90) - Double(line * 30) > 12 { return false }
        let along = x - 90 + Double(line * 13)
        let word = Int(along / 57)
        return along - Double(word * 57) < Double(40 + (word * 7 + line * 11) % 13)
    }

    /// The page, seen turned by `angle` degrees clockwise and then shifted, as a crooked feed would.
    private static func scan(_ angle: Double = 0, _ dx: Double = 0, _ dy: Double = 0, extra: ((Double, Double) -> Bool)? = nil) -> RenderedImage {
        let r = angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        var pixels = [UInt8](repeating: 0, count: w * h * 3)
        let cx = Double(w) / 2, cy = Double(h) / 2
        for y in 0..<h {
            for x in 0..<w {
                let rx = Double(x) + 0.5 - dx - cx, ry = Double(y) + 0.5 - dy - cy
                let sx = cx + rx * cos + ry * sin, sy = cy - rx * sin + ry * cos
                let v: UInt8 = inked(sx, sy) || extra?(sx, sy) == true ? 30 : 245
                let i = (y * w + x) * 3
                pixels[i] = v
                pixels[i + 1] = v
                pixels[i + 2] = v
            }
        }
        return RenderedImage(w, h, pixels)
    }

    private static func aligned(_ changed: RenderedImage, _ a: PageAlignment) throws -> RenderedImage {
        try CompareAlign.resample(changed, 0, 0, scale, a, w, h)
    }

    private static func overlay(_ a: RenderedImage, _ b: RenderedImage) throws -> VisualDiff { try VisualCompare.overlay(a, b, minPixels: 6, slack: 2) }

    @Test(arguments: [(0.0, 14.0, -9.0), (1.5, 0, 0), (-2.2, 12, 8), (4, -20, 15)])
    func aShiftedOrSkewedScanOfTheSamePageLooksTheSameOnceAligned(_ angle: Double, _ dx: Double, _ dy: Double) throws {
        let old = Self.scan(), changed = Self.scan(angle, dx, dy)
        #expect(try VisualCompare.overlay(old, changed).changedShare > 0.02, "not aligned, it differs all over")

        let a = try CompareAlign.find(old, changed, Self.scale)
        #expect(!a.isNone)
        #expect(abs(a.angle - angle) <= 0.3)
        let diff = try Self.overlay(old, try Self.aligned(changed, a))
        #expect(diff.changedShare < 0.003, "left over \(diff.changedShare), \(a)")
        // A sliver a pixel wide in the drawing can fall between the turned page's samples.
        #expect(diff.regions.allSatisfy { min($0.width, $0.height) <= 2 }, "left over \(diff.regions), \(a)")
    }

    @Test func whatReallyChangedStillShowsAfterAligning() throws {
        func stamp(_ x: Double, _ y: Double) -> Bool { x > 500 && x < 580 && y > 1030 && y < 1070 }
        let old = Self.scan(), changed = Self.scan(1.2, 10, -6, extra: stamp)
        let a = try CompareAlign.find(old, changed, Self.scale)
        let diff = try Self.overlay(old, try Self.aligned(changed, a))
        #expect(diff.regions.count == 1)
        let region = try #require(diff.regions.first)
        #expect((500...580).contains(region.centerX))
        #expect((1030...1070).contains(region.centerY))
    }

    @Test func aChangedWordOnAScanShowsAtTheScaleScansAreCheckedAt() throws {
        let old = try PdfEngine.open(TestPdf.make(1, marker: "The Buyer pays 1,250 on delivery"))
        let changed = try PdfEngine.open(TestPdf.make(1, marker: "The Seller pays 7,950 on delivery"))
        defer {
            old.close()
            changed.close()
        }
        let s = VisualCompare.scanCheckScale
        let diff = try VisualCompare.overlayScans(try old.render(0, scale: s), try changed.render(0, scale: s), s)
        #expect(!diff.regions.isEmpty)
    }

    private static func line(_ text: String, _ y: Double, x: Double = 50) -> PageText {
        PageText([text.enumerated().map { i, c in (String(c), RectD(x + Double(i) * 6, y, 6, 10)) }])
    }

    @Test func whatIsRemovedFromAPageWithNoCounterpartStillGetsItsNote() throws {
        let moved = (0..<80).map { "m\($0)" }.joined(separator: " ")
        let first = (0..<60).map { "a\($0)" }.joined(separator: " ")
        let last = (0..<60).map { "z\($0)" }.joined(separator: " ")
        let oldPages = [Self.line(first, 100), Self.line(moved + " gone0 gone1 gone2 gone3 gone4", 100), Self.line(last, 100)]
        let newPages = [Self.line(first, 100), Self.line(last + " " + moved, 100)]
        let r = try DocumentCompare.run(oldPages, newPages)
        #expect(r.changes.contains { $0.kind == .deleted })
        let notes = try Annotations.read(try CompareReport.annotate(TestPdf.make(2, marker: "x"), nil, r, newPages, oldName: "old.pdf", summary: r.summary()), nil)
        #expect(notes.contains { $0.contents.contains("gone0") })
    }

    @Test func anAreaBeyondTheChangedPagesEdgeIsMentioned() throws {
        let o = Self.line("same words here", 100), n = Self.line("same words here", 100)
        let r = try DocumentCompare.run([o], [n])
        let data = try CompareReport.annotate(TestPdf.make(1, marker: "x"), nil, r, [n], oldName: "old.pdf", summary: "summary",
                                              visual: [CompareVisualArea(0, [], offPage: 2)])
        let notes = try Annotations.read(data, nil)
        #expect(notes.contains { $0.contents.contains("2 areas beyond this page's edge look different") })
    }

    @Test func theSamePageNeedsNoAlignment() throws {
        let page = Self.scan()
        #expect(try CompareAlign.find(page, page, Self.scale).isNone)
    }

    @Test func anAlignmentGoesThereAndBack() {
        let a = PageAlignment(12, -7, 2.5, 300, 400)
        let there = a.toNew(120, 640)
        let back = a.toOld(there.x, there.y)
        #expect(abs(back.x - 120) < 1e-6)
        #expect(abs(back.y - 640) < 1e-6)
    }

    @Test func areasUnderTextAreLeftToTheTextCompare() {
        let old = Self.line("the same words", 100), changed = Self.line("the same words", 100)
        let overText = RectD(55, 100, 40, 10)
        let onItsOwn = RectD(300, 400, 80, 60)
        #expect(VisualAreas.offText([overText, onItsOwn], old, changed, .none) == [onItsOwn])
    }

    @Test func textThatReflowedTellsNothingVisually() {
        #expect(VisualAreas.sameLayout(Self.line("the same words", 100), Self.line("the same words", 100)))
        #expect(!VisualAreas.sameLayout(Self.line("the same words", 100), Self.line("the same words", 180)))
        #expect(VisualAreas.sameLayout(.empty, Self.line("words", 100)))
    }

    /// A line's place is rounded half to even, as Windows' Math.Round: 10.5 is 10, so it isn't 11.4's place but is 9.6's.
    @Test func linesArePlacedRoundingHalfToEvenAsWindows() {
        #expect(!VisualAreas.sameLayout(Self.line("the same words", 100, x: 10.5), Self.line("the same words", 100, x: 11.4)))
        #expect(VisualAreas.sameLayout(Self.line("the same words", 100, x: 10.5), Self.line("the same words", 100, x: 9.6)))
    }

    /// Two scans' slack is a point and a half in pixels, half to even as Windows' Math.Round, within 2 to 6.
    @Test func scanSlackRoundsHalfToEvenAsWindows() {
        #expect(VisualCompare.scanSlack(3) == 4) // 4.5
        #expect(VisualCompare.scanSlack(VisualCompare.scanCheckScale) == 2)
        #expect(VisualCompare.scanSlack(100) == 6)
        #expect(VisualCompare.scanSlack(.nan) == 2)
    }

    @Test func theAnnotatedCopyHasMovesFormattingAndWhatLooksDifferent() throws {
        let before = "the first long part of this line stays where it was and so does"
        let after = "the last long part of this very line that also keeps its place here"
        let goes = "one two three four five six seven eight"
        let oldPage = Self.line("\(before) \(goes) \(after)", 100), newPage = Self.line("\(before) \(after) \(goes)", 100)
        let moved = try DocumentCompare.run([oldPage], [newPage])
        #expect(moved.moved == 1)

        let plain = WordLook("Arial", 11, false, false, 0)
        var bold = plain
        bold.bold = true
        let o = Self.line("same words here", 100), n = Self.line("same words here", 100)
        let styled = try DocumentCompare.run(CompareSource([o], looks: [PageLooks([(0, plain)])]),
                                             CompareSource([n], looks: [PageLooks([(0, plain), (5, bold), (10, plain)])]))
        #expect(styled.formatted == 1)

        let one = TestPdf.make(1, marker: "x")
        let fromMoved = try Annotations.read(try CompareReport.annotate(one, nil, moved, [newPage], oldName: "old.pdf", summary: moved.summary()), nil)
        #expect(fromMoved.contains { $0.kind == .highlight && $0.contents.contains("Moved here from page 1 of old.pdf") })

        let box = RectD(200, 300, 60, 40)
        let styledCopy = try CompareReport.annotate(one, nil, styled, [n], oldName: "old.pdf", summary: styled.summary(), visual: [CompareVisualArea(0, [box])])
        let fromStyled = try Annotations.read(styledCopy, nil)
        #expect(fromStyled.contains { $0.kind == .highlight && $0.contents == "Formatting: bold added" })
        let areas = fromStyled.filter { $0.contents == "Looks different in old.pdf." }
        #expect(areas.count == 1)
        #expect(areas.first?.rect.contains(box.centerX, box.centerY) == true)
    }
}
