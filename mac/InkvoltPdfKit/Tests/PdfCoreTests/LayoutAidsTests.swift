import Foundation
import Testing
@testable import PdfCore

/// LayoutAidsTests.cs (roadmap 4.19): rulers, guides, a grid and snapping (`LayoutAids`, `PageGuides`, `Snapper`), and
/// snapping in Prepare Form's `FormDesigner` (the Mac's designer takes what to snap to with each press and drag, as it
/// takes the page's size, where Windows' holds a `SnapFor`).
struct LayoutAidsTests {
    private static let inv = Locale(identifier: "en_US_POSIX")

    @Test func rulersLabelNiceStepsInTheUnitAndTickBetween() throws {
        // 1 pixel a point, inches: 72 px an inch, so every inch is labelled, tenths between (7.2 px apart).
        let ticks = LayoutAids.ticks(0, 612, 1, .inches, locale: Self.inv)
        let labelled = ticks.filter { $0.level == 0 }
        #expect(labelled.map(\.label) == ["0", "1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(abs(labelled[1].at - 72) < 1e-6)
        #expect(ticks.contains { $0.level == 1 && abs($0.at - 36) < 1e-6 }) // the half inch
        let small = ticks.filter { $0.level > 0 }.map(\.at)
        #expect(zip(small, small.dropFirst()).allSatisfy { $1 - $0 >= 5 - 1e-9 })

        // Zoomed out: labels every 2 or 5 units so they stay 60 px apart.
        let far = LayoutAids.ticks(0, 2000, 0.25, .inches, locale: Self.inv).filter { $0.level == 0 }.map(\.label)
        #expect(far[0] == "0")
        #expect(far[1] == "5")

        // Millimeters at 2 px a point (5.7 px a millimeter): 10 mm is 57 px, under 60, so every 20 mm.
        let mm = LayoutAids.ticks(0, 200, 2, .millimeters, locale: Self.inv).filter { $0.level == 0 }.map(\.label)
        #expect(mm == ["0", "20", "40", "60"])
        // A part of a page shown: ticks only there; fractions when zoomed in.
        let near = LayoutAids.ticks(100, 120, 20, .inches, locale: Self.inv)
        #expect(near.allSatisfy { $0.at >= 100 && $0.at <= 120 })
        #expect(near.contains { $0.label == "1.5" })
        #expect(LayoutAids.ticks(100, 120, 20, .inches, locale: Locale(identifier: "es_ES")).first { $0.level == 0 && $0.at > 107 }?.label == "1,5")

        #expect(LayoutAids.ticks(0, 100, 0, .inches).isEmpty)
        #expect(LayoutAids.ticks(0, .infinity, 1, .inches).isEmpty)
        #expect(LayoutAids.niceStep(1.3) == 2)
        #expect(abs(LayoutAids.niceStep(0.041) - 0.05) < 1e-9)
        #expect(LayoutAids.niceStep(10) == 10)
    }

    @Test func theRulerUnitIsThePagesScaleOrTheRegionsUnlessChosen() throws {
        #expect(RulerUnit.for("auto", nil, metric: false) == .inches)
        #expect(RulerUnit.for("auto", .default, metric: true) == .millimeters)
        #expect(RulerUnit.for("pt", try MeasureScale.from(1, "in", 10, "ft"), metric: true) == .points)
        let feet = RulerUnit.for("auto", try MeasureScale.from(1, "in", 10, "ft"), metric: false)
        #expect(feet.name == "ft")
        #expect(abs(feet.pointsPer - 7.2) < 1e-6) // an inch on paper (72 pt) is 10 ft
    }

    @Test func aGuideFromARulerRunsAsTheScreenShowsIt() {
        // Upright: the top ruler gives a line across (a page y), the left one a line down (a page x).
        #expect(LayoutAids.fromRuler(0, topRuler: true, 100, 612, 792, 0) == Guide(0, .y, 100))
        #expect(LayoutAids.fromRuler(0, topRuler: false, 50, 612, 792, 0) == Guide(0, .x, 50))
        // Turned a quarter: a line across the screen is a page x; down the screen a page y, counted from the bottom.
        #expect(LayoutAids.fromRuler(1, topRuler: true, 100, 612, 792, 90) == Guide(1, .x, 100))
        #expect(LayoutAids.fromRuler(1, topRuler: false, 50, 612, 792, 90) == Guide(1, .y, 792 - 50))
        #expect(LayoutAids.fromRuler(0, topRuler: true, 100, 612, 792, 180) == Guide(0, .y, 792 - 100))
        #expect(LayoutAids.fromRuler(0, topRuler: true, 800, 612, 792, 0) == nil)
        #expect(LayoutAids.fromRuler(0, topRuler: false, -1, 612, 792, 0) == nil)
        #expect(LayoutAids.acrossScreen(.y, 0))
        #expect(!LayoutAids.acrossScreen(.y, 90))
    }

    @Test func guidesAreKeptPerPageMovedAndDraggedOffToGo() throws {
        let guides = PageGuides()
        #expect(guides.add(Guide(0, .x, 100), 612, 792))
        #expect(guides.add(Guide(0, .y, 900), 612, 792)) // kept on the page
        #expect(guides.add(Guide(2, .y, 300), 612, 792))
        #expect(guides.on(0)[1].at == 792)
        #expect(guides.on(2).count == 1)
        #expect(guides.at(0, PointD(103, 500), 4) == Guide(0, .x, 100))
        #expect(guides.at(0, PointD(110, 500), 4) == nil)

        let v = guides.version
        let moved = try #require(guides.move(guides.on(0)[0], 150, 612, 792))
        #expect(moved.at == 150)
        #expect(guides.version > v)
        #expect(guides.move(moved, -5, 612, 792) == nil) // back onto the ruler: gone
        #expect(guides.on(0).count == 1)
        #expect(guides.clear(2) == 1)
        #expect(guides.clear() == 1)
        #expect(guides.all.isEmpty)

        for i in 0..<PageGuides.maxPerPage { guides.add(Guide(0, .x, Double(i)), 612, 792) }
        #expect(!guides.add(Guide(0, .x, 1), 612, 792))
        #expect(!guides.add(Guide(1, .x, .nan), 612, 792))
    }

    @Test func pointsAndBoxesSnapToTheNearestGuideGridOrEdge() throws {
        let snap = try #require(Snapper.for([Guide(0, .x, 100), Guide(0, .y, 200)], [RectD(300, 300, 100, 50)], gridStep: 0, reach: 5))
        #expect(snap.point(PointD(97, 210)) == PointD(100, 210))
        #expect(snap.lines == [SnapLine(.x, 100)])
        #expect(snap.point(PointD(347, 198)) == PointD(350, 200)) // another box's center, a guide
        #expect(snap.point(PointD(50, 50)) == PointD(50, 50))
        #expect(snap.lines.isEmpty)

        // A box moves so its nearest edge or center lands on a line: here its right edge on the guide.
        #expect(snap.move(RectD(42, 260, 60, 20)) == RectD(40, 260, 60, 20))
        // Its middle on the other box's middle.
        #expect(snap.move(RectD(332, 318, 40, 20)) == RectD(330, 315, 40, 20))
        // Resizing: only the edges that moved snap, never below the smallest size.
        #expect(snap.resize(RectD(10, 10, 80, 20), RectD(10, 10, 93, 20)) == RectD(10, 10, 90, 20))
        #expect(snap.resize(RectD(90, 10, 12, 20), RectD(98, 10, 4, 20), min: 4) == RectD(98, 10, 4, 20))

        let grid = try #require(Snapper.for(nil, nil, gridStep: 18, reach: 4))
        #expect(grid.point(PointD(38, 63)) == PointD(36, 63))
        #expect(grid.point(PointD(38, 70)) == PointD(36, 72))
        #expect(Snapper.for(nil, nil, gridStep: 0, reach: 5) == nil)
        #expect(Snapper.for([Guide(0, .x, 1)], nil, gridStep: 0, reach: 0) == nil)
        let (xs, ys) = LayoutAids.grid(612, 792, 72)
        #expect(xs.count == 8)
        #expect(ys.count == 10)
        #expect(LayoutAids.grid(612, 792, 0.1).xs.isEmpty)
    }

    @Test func prepareFormSnapsFieldsToGuidesAndTheOtherFields() throws {
        let a = FormDesign.newField(.text, 0, RectD(100, 100, 100, 20), [], "A").with { $0.id = "a" }
        let b = FormDesign.newField(.text, 0, RectD(300, 200, 100, 20), [], "B").with { $0.id = "b" }
        var d = FormDesigner()
        d.setFields([a, b])
        let guides = [Guide(0, .x, 250)]
        let fields = d.fields
        let snapFor: (Int, Set<String>) -> Snapper? = { _, without in
            Snapper.for(guides, fields.filter { !without.contains($0.id) }.map(\.rect), gridStep: 0, reach: 5)
        }
        func press(_ x: Double, _ y: Double, snap: ((Int, Set<String>) -> Snapper?)?) {
            _ = d.press(0, PointD(x, y), clicks: 1, reach: 5, pageWidth: 612, pageHeight: 792, snap: snap)
        }

        // Dragged near B's top: A's top snaps to it; its left stays where the pointer took it.
        press(110, 110, snap: snapFor)
        d.dragged(to: PointD(130, 207), shift: false, threshold: 2, snap: snapFor)
        #expect(d.shownRect(a) == RectD(120, 200, 100, 20))
        #expect(d.snapLines.contains(SnapLine(.y, 200)))
        #expect(d.release() == .moved(a.with { $0.rect = RectD(120, 200, 100, 20) }))
        #expect(d.snapLines.isEmpty)

        // A new box's corner snaps to the guide.
        d.kind = .text
        press(248, 400, snap: snapFor)
        d.dragged(to: PointD(352, 430), shift: false, threshold: 2, snap: snapFor)
        #expect(d.release() == .placed(DesignPlacement(kind: .text, pageIndex: 0, rect: RectD(250, 400, 100, 30))))

        // Snapping off: where the pointer is.
        d.kind = nil
        press(310, 210, snap: nil)
        d.dragged(to: PointD(312, 213), shift: false, threshold: 2, snap: nil)
        #expect(d.shownRect(b) == RectD(302, 203, 100, 20))
    }
}
