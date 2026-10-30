import Foundation
import Testing
@testable import PdfCore

/// A Mac addition (no .NET counterpart file): the measuring tools' state, which the Windows app keeps in
/// `PageViewer.Measure` (a view, untested there) and the Mac keeps in PdfCore as `MeasureDraft`, with the per-version
/// scale lookup of `DocumentTab.ScaleAt` as `MeasureScales`. The rules are the Windows viewer's.
struct MeasureDraftTests {
    @Test func aDistanceEndsAtItsSecondClick() throws {
        var d = MeasureDraft(.distance)
        #expect(d.click(page: 0, PointD(72, 100)) == nil)
        #expect(d.isActive && d.points.count == 1)
        d.move(page: 0, PointD(144, 100))
        #expect(d.value(.default) == "1.00 in")
        #expect(d.described(.default) == "1 point(s), 0.00 in") // without the pointer
        let done = try #require(d.click(page: 0, PointD(216, 100)))
        #expect(done.page == 0 && done.points == [PointD(72, 100), PointD(216, 100)])
        #expect(!d.isActive && d.hover == nil && d.described(.default) == nil)
    }

    @Test func anAreaEndsWithADoubleClickOrReturnOnceItHasThreeCorners() throws {
        var d = MeasureDraft(.area)
        _ = d.click(page: 1, PointD(0, 0))
        _ = d.click(page: 1, PointD(72, 0))
        #expect(d.finish() == nil) // two corners: it goes on
        #expect(d.isActive)
        _ = d.click(page: 1, PointD(72, 72))
        // The double-click's first press adds the corner, its second ends the area without adding another.
        _ = d.click(page: 1, PointD(0, 72))
        let done = try #require(d.click(page: 1, PointD(0, 72), clicks: 2))
        #expect(done.points.count == 4)
        let scale = try MeasureScale.from(1, "in", 10, "ft")
        #expect(scale.format(.area, done.points) == "100.00 sq ft")

        var r = MeasureDraft(.perimeter)
        _ = r.click(page: 0, PointD(0, 0))
        _ = r.click(page: 0, PointD(72, 0))
        #expect(try #require(r.finish()).points.count == 2)
    }

    @Test func theValueSoFarFollowsThePointer() throws {
        let scale = try MeasureScale.from(1, "in", 10, "ft")
        var d = MeasureDraft(.area)
        #expect(d.value(scale) == "")
        _ = d.click(page: 0, PointD(0, 0))
        _ = d.click(page: 0, PointD(72, 0))
        d.move(page: 0, PointD(72, 72))
        #expect(d.value(scale) == "50.00 sq ft · perimeter 34.14 ft")
        #expect(d.value(scale, includeHover: false) == "10.00 ft")
        d.move(page: 3, PointD(0, 0)) // another page: ignored
        #expect(d.hover == PointD(72, 72))
    }

    @Test func backspaceEscapeAndAnotherPage() {
        var d = MeasureDraft(.perimeter)
        _ = d.click(page: 0, PointD(0, 0))
        _ = d.click(page: 0, PointD(10, 0))
        _ = d.click(page: 0, PointD(10, 0)) // the same spot again isn't a point
        #expect(d.points.count == 2)
        #expect(d.removeLast())
        #expect(d.points == [PointD(0, 0)])
        #expect(d.removeLast())
        #expect(!d.isActive)
        #expect(!d.removeLast())
        _ = d.click(page: 0, PointD(0, 0))
        _ = d.click(page: 2, PointD(5, 5)) // a click on another page starts over there
        #expect(d.page == 2 && d.points == [PointD(5, 5)])
        d.cancel()
        #expect(!d.isActive && d.points.isEmpty)
    }

    @Test func shiftKeepsASegmentStraight() throws {
        var d = MeasureDraft(.calibrate)
        #expect(d.tool.kind == .distance)
        _ = d.click(page: 0, PointD(100, 100))
        d.move(page: 0, PointD(200, 103), shift: true)
        #expect(abs(d.hover!.y - 100) < 1e-9)
        let done = try #require(d.click(page: 0, PointD(200, 103), shift: true))
        #expect(abs(done.points[1].y - 100) < 1e-9)
    }

    @Test func scalesAreLookedUpPerVersion() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /UserUnit 2 >>",
        ])
        let scaled = try Measurements.setPageScale(pdf, nil, [0], try MeasureScale.from(1, "in", 10, "ft"))
        let scales = MeasureScales(scaled, nil)
        #expect(scales.pageScale(0).ratio == "1 in = 10 ft")
        let second = scales.scaleAt(1, PointD(5, 5))
        #expect(second.ratio == "1 in = 1 in" && second.userUnit == 2) // real size, in the page's units
        #expect(MeasureScales([1, 2, 3], nil).pageScale(0) == .default) // unreadable: real size
        #expect(try MeasureScale.from(1, "in", 10, "ft").announcement(.area, [PointD(0, 0), PointD(72, 0), PointD(72, 72), PointD(0, 72)])
            == "Area: 100.00 sq ft, perimeter 40.00 ft (scale 1 in = 10 ft).")
    }

    @Test func numbersAreReadAsTyped() {
        let us = Locale(identifier: "en_US"), es = Locale(identifier: "es_ES")
        #expect(MeasureScale.number(" 12.5 ", 1e-9, 1e12, locale: us) == 12.5)
        #expect(MeasureScale.number("12,5", 1e-9, 1e12, locale: es) == 12.5)
        #expect(MeasureScale.number("0", 1e-9, 1e12, locale: us) == nil)
        #expect(MeasureScale.number("ten", 1e-9, 1e12, locale: us) == nil)
    }
}
