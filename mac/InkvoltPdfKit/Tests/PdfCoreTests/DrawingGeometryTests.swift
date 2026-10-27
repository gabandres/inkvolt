import Foundation
import Testing
@testable import PdfCore

/// Ported from DrawingGeometryTests.cs: all 12 tests, none left out or adapted.
struct DrawingGeometryTests {
    private func near(_ expected: Double, _ actual: Double) -> Bool { abs(expected - actual) < 5e-7 }

    private func sign(_ v: Double) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }

    @Test(arguments: [
        (10.0, 1.0, 10.0, 0.0), // almost horizontal → horizontal
        (10.0, 9.0, 9.5, 9.5), // almost diagonal → diagonal
        (-1.0, -10.0, 0.0, -10.0), // almost vertical (up) → vertical
    ])
    func snapAngleTurnsToMultiplesOf45(x: Double, y: Double, ex: Double, ey: Double) {
        let p = DrawingGeometry.snapAngle(PointD(0, 0), PointD(x, y))
        let length = (x * x + y * y).squareRoot()
        #expect(near(length, (p.x * p.x + p.y * p.y).squareRoot()))
        if ex == 0 { #expect(near(0, p.x)) }
        if ey == 0 { #expect(near(0, p.y)) }
        if ex != 0 && ey != 0 { #expect(near(abs(p.x), abs(p.y))) }
        #expect(sign(ex) == sign((p.x * 1e6).rounded() / 1e6))
        #expect(sign(ey) == sign((p.y * 1e6).rounded() / 1e6))
    }

    @Test func dragBoxSquaresTowardsThePointer() {
        #expect(DrawingGeometry.dragBox(PointD(10, 10), PointD(40, 20), square: true) == RectD(10, 10, 30, 30))
        #expect(DrawingGeometry.dragBox(PointD(10, 10), PointD(-20, 0), square: true) == RectD(-20, -20, 30, 30))
        #expect(DrawingGeometry.dragBox(PointD(10, 2), PointD(5, 10), square: false) == RectD(5, 2, 5, 8))
    }

    @Test func resizeMovesOnlyTheDraggedSides() {
        let r = RectD(10, 10, 100, 50)
        #expect(DrawingGeometry.resize(r, DrawingGeometry.bottomRight, PointD(150, 80)) == RectD(10, 10, 140, 70))
        #expect(DrawingGeometry.resize(r, DrawingGeometry.left, PointD(0, 999)) == RectD(0, 10, 110, 50))
        #expect(DrawingGeometry.resize(r, DrawingGeometry.top, PointD(-5, 30)) == RectD(10, 30, 100, 30))
        // Dragged past the opposite side: stops at the minimum size instead of flipping.
        #expect(DrawingGeometry.resize(r, DrawingGeometry.right, PointD(-100, 0), minSize: 4) == RectD(10, 10, 4, 50))
    }

    @Test func resizeKeepsTheAspectFromTheOppositeCorner() {
        let a = DrawingGeometry.resize(RectD(10, 10, 100, 50), DrawingGeometry.topLeft, PointD(-90, 0), keepAspect: true)
        #expect(near(110, a.right))
        #expect(near(60, a.bottom))
        #expect(near(2, a.width / a.height))
        #expect(near(200, a.width))
    }

    @Test func handlesGoClockwiseFromTheTopLeft() {
        let r = RectD(0, 0, 10, 20)
        #expect(DrawingGeometry.handlePoint(r, DrawingGeometry.topLeft) == PointD(0, 0))
        #expect(DrawingGeometry.handlePoint(r, DrawingGeometry.top) == PointD(5, 0))
        #expect(DrawingGeometry.handlePoint(r, DrawingGeometry.right) == PointD(10, 10))
        #expect(DrawingGeometry.handlePoint(r, DrawingGeometry.bottomLeft) == PointD(0, 20))
    }

    @Test func clampMoveKeepsTheBoundsOnThePage() {
        let b = RectD(10, 10, 50, 50)
        #expect(DrawingGeometry.clampMove(b, -30, 40, 200, 100) == (-10.0, 40.0))
        #expect(DrawingGeometry.clampMove(b, 500, -500, 200, 100) == (140.0, -10.0))
        // Already sticking out on the left: may come back in, never go further out.
        let outside = RectD(-20, 10, 50, 50)
        #expect(DrawingGeometry.clampMove(outside, -5, 0, 200, 100) == (0.0, 0.0))
        #expect(DrawingGeometry.clampMove(outside, 15, 0, 200, 100) == (15.0, 0.0))
    }

    @Test func translateMovesEveryPart() {
        let g = AnnotGeometry(box: RectD(0, 0, 10, 10), paths: [[PointD(1, 1), PointD(2, 3)]], callout: [PointD(-5, -5)])
        let m = DrawingGeometry.translate(g, 3, 4)
        #expect(m.box == RectD(3, 4, 10, 10))
        #expect(m.paths[0][1] == PointD(5, 7))
        #expect(m.callout[0] == PointD(-2, -1))
    }

    @Test func freeTextFrameIsItsBoxAndResizingKeepsTheTip() {
        let g = AnnotGeometry(box: RectD(100, 100, 80, 30), callout: [PointD(20, 20)])
        #expect(DrawingGeometry.frame("FreeText", g) == RectD(100, 100, 80, 30))
        #expect(DrawingGeometry.frame("Square", g) == RectD(20, 20, 160, 110))
        let r = DrawingGeometry.withFrame("FreeText", g, RectD(120, 100, 60, 40))
        #expect(r.box == RectD(120, 100, 60, 40))
        #expect(r.callout[0] == PointD(20, 20))
        let ink = AnnotGeometry(paths: [[PointD(0, 0), PointD(10, 10)]])
        #expect(DrawingGeometry.withFrame("Ink", ink, RectD(5, 5, 20, 40)).paths[0][1] == PointD(25, 45))
    }

    @Test func hitTestsStrokesNotEmptyInteriors() {
        let style = AnnotStyle(color: .red, width: 2)
        var filled = style
        filled.fill = .yellow
        let square = AnnotGeometry(box: RectD(0, 0, 100, 100))
        #expect(DrawingGeometry.hit("Square", square, style, PointD(1, 50), 2))
        #expect(!DrawingGeometry.hit("Square", square, style, PointD(50, 50), 2))
        #expect(DrawingGeometry.hit("Square", square, filled, PointD(50, 50), 2))

        let circle = AnnotGeometry(box: RectD(0, 0, 100, 100))
        #expect(DrawingGeometry.hit("Circle", circle, style, PointD(50, 1.5), 2))
        #expect(!DrawingGeometry.hit("Circle", circle, style, PointD(50, 50), 2))
        #expect(!DrawingGeometry.hit("Circle", circle, style, PointD(2, 2), 2)) // the box's corner is outside the ellipse

        let line = AnnotGeometry(paths: [[PointD(0, 0), PointD(100, 0)]])
        #expect(DrawingGeometry.hit("Line", line, style, PointD(50, 2.5), 2))
        #expect(!DrawingGeometry.hit("Line", line, style, PointD(50, 6), 2))
        #expect(!DrawingGeometry.hit("Line", line, style, PointD(110, 0), 2))
    }

    @Test func hitTestsTextBoxesAndCalloutLeaders() {
        let g = AnnotGeometry(box: RectD(100, 100, 80, 30), callout: [PointD(20, 115)])
        let style = AnnotStyle.textBox()
        #expect(DrawingGeometry.hit("FreeText", g, style, PointD(140, 110), 1))
        #expect(DrawingGeometry.hit("FreeText", g, style, PointD(60, 115.5), 1)) // on the leader
        #expect(!DrawingGeometry.hit("FreeText", g, style, PointD(60, 140), 1))
    }

    @Test func hitTestsFilledPolygonsInside() {
        let tri = AnnotGeometry(paths: [[PointD(0, 0), PointD(100, 0), PointD(50, 80)]])
        let stroke = AnnotStyle(color: .red, width: 1)
        var filled = stroke
        filled.fill = .red
        #expect(!DrawingGeometry.hit("Polygon", tri, stroke, PointD(50, 30), 1))
        #expect(DrawingGeometry.hit("Polygon", tri, filled, PointD(50, 30), 1))
        #expect(DrawingGeometry.hit("Polygon", tri, stroke, PointD(25, 40), 1.5)) // on the closing edge
    }

    @Test func simplifyDropsPointsOnAStraightRun() {
        let pts: [PointD] = (0..<50).map { (i: Int) -> PointD in PointD(Double(i), i < 25 ? 0 : Double(i - 25)) }
        #expect(DrawingGeometry.simplify(pts, 0.1) == [PointD(0, 0), PointD(25, 0), PointD(49, 24)])
        #expect(DrawingGeometry.simplify([PointD(0, 0), PointD(1, 1)], 1).count == 2)
    }
}
