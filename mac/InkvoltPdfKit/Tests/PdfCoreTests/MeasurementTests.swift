import Foundation
import Testing
@testable import PdfCore

/// Ported from MeasurementTests.cs (same names). Refusals are `PdfEditError`s where .NET throws ArgumentException. MuPDF
/// keeps reals as 32-bit floats, so /C reads back to about seven digits (the tests compare it to four decimals, as on
/// Windows).
struct MeasurementTests {
    private static let o = PointD(0, 0)

    private static func near(_ a: Double, _ b: Double, _ decimals: Int) -> Bool {
        abs(a - b) <= 0.5 * pow(10, Double(-decimals))
    }

    /// The page's annotations in order, read through MuPDF.
    private static func annots(_ pdf: [UInt8], page: Int = 0) throws -> [PObj] {
        let doc = try Core2Pdf.open(pdf)
        return (doc.page(page).array("Annots")?.elements ?? []).filter(\.isDict)
    }

    @Test func geometryOfLinesAndShapes() {
        let o = Self.o
        #expect(Self.near(MeasureGeometry.length([o, PointD(3, 4)]), 5, 9))
        #expect(Self.near(MeasureGeometry.length([o, PointD(3, 4), PointD(3, 11)]), 12, 9))
        // A closed outline counts the edge back to the start.
        #expect(Self.near(MeasureGeometry.length([o, PointD(10, 0), PointD(10, 10), PointD(0, 10)], closed: true), 40, 9))
        // Shoelace: any winding, and a concave L-shape.
        #expect(Self.near(MeasureGeometry.area([o, PointD(10, 0), PointD(10, 10), PointD(0, 10)]), 100, 9))
        #expect(Self.near(MeasureGeometry.area([o, PointD(0, 10), PointD(10, 10), PointD(10, 0)]), 100, 9))
        #expect(Self.near(MeasureGeometry.area([o, PointD(10, 0), PointD(10, 5), PointD(5, 5), PointD(5, 10), PointD(0, 10)]), 75, 9))
        #expect(Self.near(MeasureGeometry.area([o, PointD(1, 1)]), 0, 9))
        #expect(MeasureGeometry.centroid([o, PointD(10, 0), PointD(10, 10), PointD(0, 10)]) == PointD(5, 5))
        #expect(MeasureGeometry.centroid([o, PointD(2, 0), PointD(1, 0)]) == PointD(1, 0)) // degenerate: the points' middle
    }

    @Test func scalesTurnPointsIntoRealLengths() throws {
        let o = Self.o
        let s = try MeasureScale.from(1, "in", 10, "ft")
        #expect(s.ratio == "1 in = 10 ft")
        #expect(Self.near(s.perPoint, 10.0 / 72, 12))
        #expect(Self.near(s.value(.distance, [o, PointD(72, 0)]), 10, 9))
        #expect(s.format(.distance, [o, PointD(72, 0)]) == "10.00 ft")
        #expect(s.format(.area, [o, PointD(720, 0), PointD(720, 72), PointD(0, 72)]) == "1,000.00 sq ft")
        #expect(Self.near(s.value(.area, [o, PointD(720, 0), PointD(720, 72), PointD(0, 72)]), 100 * 10, 6))
        #expect(Self.near(s.value(.perimeter, [o, PointD(72, 0), PointD(72, 72), PointD(0, 72), o]), 40, 9))

        var metric = try MeasureScale.from(1, "cm", 2, "m")
        metric.decimals = 1
        #expect(Self.near(metric.value(.distance, [o, PointD(72 / 2.54, 0)]), 2, 9))
        #expect(metric.format(.distance, [o, PointD(72 / 2.54, 0)]) == "2.0 m")
        #expect(MeasureScale.default.ratio == "1 in = 1 in")
        #expect(Self.near(MeasureScale.default.value(.distance, [o, PointD(72, 0)]), 1, 9))
    }

    /// The ratio, its real units per point and its unit.
    static let ratios: [(String, Double, String)] = {
        let perInch: Double = 1 / 72
        var r: [(String, Double, String)] = []
        r.append(("1 in = 10 ft", 10 * perInch, "ft"))
        r.append(("1in=10ft", 10 * perInch, "ft"))
        r.append(("1/4 in = 1 ft", 4 * perInch, "ft"))
        r.append(("1 cm = 0.5 m", 0.5 * 2.54 * perInch, "m"))
        r.append(("2 mm = 1 km", 0.5 * 25.4 * perInch, "km"))
        r.append(("1:100 m", 100 * 0.0254 * perInch, "m"))
        return r
    }()

    @Test(arguments: ratios)
    func ratiosAreRead(_ text: String, _ perPoint: Double, _ unit: String) throws {
        let s = try #require(MeasureScale.parse(text), "\(text)")
        #expect(Self.near(s.perPoint, perPoint, 9))
        #expect(s.unit == unit)
    }

    @Test(arguments: ["", "10 ft", "1 in = ft", "0 in = 10 ft", "1 in = -2 ft", "1 parsec = 2 ft"])
    func badRatiosAreRefused(_ text: String) { #expect(MeasureScale.parse(text) == nil) }

    @Test func calibrationFromAKnownLength() throws {
        // A wall drawn 144 pt long is 25 ft: 1 in on paper is 12.5 ft.
        let s = try MeasureScale.calibrate(144, 25, "ft")
        #expect(Self.near(s.perPoint, 25.0 / 144, 12))
        #expect(s.ratio == "1 in = 12.5 ft")
        #expect(throws: PdfEditError.self) { try MeasureScale.calibrate(0, 25, "ft") }
        #expect(throws: PdfEditError.self) { try MeasureScale.calibrate(10, 0, "ft") }
        #expect(throws: PdfEditError.self) { try MeasureScale.calibrate(10, 1, "furlong") }
    }

    @Test func pageScalesAreWrittenAsViewportsAndReadBack() throws {
        let pdf = TestPdf.make(2)
        let scale = try MeasureScale.from(1, "in", 10, "ft")
        let scaled = try Measurements.setPageScale(pdf, nil, [1], scale)
        #expect(try Measurements.pageScale(scaled, nil, 0, PointD(100, 100)) == nil)
        let back = try #require(try Measurements.pageScale(scaled, nil, 1, PointD(100, 100)))
        #expect(Self.near(back.perPoint, scale.perPoint, 9))
        #expect(back.unit == "ft")
        #expect(back.ratio == "1 in = 10 ft")

        // Setting again replaces it; null removes it.
        let twice = try Measurements.setPageScale(scaled, nil, [1], try MeasureScale.from(1, "in", 20, "ft"))
        #expect(try Core2Pdf.open(twice).page(1).array("VP")?.count == 1)
        #expect(try Measurements.pageScale(try Measurements.setPageScale(twice, nil, [1], nil), nil, 1, PointD(100, 100)) == nil)
    }

    @Test func aViewportOfTheDocumentWinsWhereItApplies() throws {
        // A drawing whose lower half is a detail at another scale (a second viewport, after the whole-page one).
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /VP ["
                + "<< /Type /Viewport /BBox [0 0 612 792] /Measure << /Type /Measure /Subtype /RL /R (1 in = 10 ft) /X [<< /Type /NumberFormat /U (ft) /C 0.138889 /D 100 >>] >> >> "
                + "<< /Type /Viewport /BBox [0 0 612 396] /Measure << /Type /Measure /Subtype /RL /R (1 in = 2 ft) /X [<< /Type /NumberFormat /U (ft) /C 0.0277778 /D 10 >>] >> >>"
                + "] >>",
        ])
        #expect(try Measurements.pageScale(pdf, nil, 0, PointD(100, 100))?.ratio == "1 in = 10 ft") // top half (page space, y down)
        let detail = try #require(try Measurements.pageScale(pdf, nil, 0, PointD(100, 700)))
        #expect(detail.ratio == "1 in = 2 ft")
        #expect(detail.decimals == 1) // /D 10
        // The same, read once for the whole document and looked up per point (what the viewer does as the pointer moves).
        let areas = try #require(try Measurements.viewports(pdf, nil)[0])
        #expect(Measurements.scaleAt(areas, PointD(100, 100))?.ratio == "1 in = 10 ft")
        #expect(Measurements.scaleAt(areas, PointD(100, 700))?.ratio == "1 in = 2 ft")
        #expect(Measurements.scaleAt(nil, PointD(1, 1)) == nil)
        // A new Inkvolt scale goes first, so the document's own detail viewport still wins inside its area.
        let ours = try Measurements.setPageScale(pdf, nil, [0], try MeasureScale.from(1, "in", 5, "ft"))
        #expect(try Measurements.pageScale(ours, nil, 0, PointD(100, 100))?.ratio == "1 in = 5 ft")
        #expect(try Measurements.pageScale(ours, nil, 0, PointD(100, 700))?.ratio == "1 in = 2 ft")
    }

    @Test func measurementsBecomeAnnotationsAcrobatUnderstands() throws {
        let scale = try MeasureScale.from(1, "in", 10, "ft")
        var pdf = TestPdf.make(1)
        pdf = try Measurements.add(pdf, nil, 0, .distance, [PointD(72, 200), PointD(216, 200)], scale, author: "Ada", id: "m1")
        pdf = try Measurements.add(pdf, nil, 0, .perimeter, [PointD(72, 300), PointD(144, 300), PointD(144, 372)], scale, author: "Ada", id: "m2")
        pdf = try Measurements.add(pdf, nil, 0, .area, [PointD(300, 300), PointD(372, 300), PointD(372, 372), PointD(300, 372)], scale,
                                   author: "Ada", id: "m3")
        let annots = try Self.annots(pdf)
        #expect(annots.map { $0.name("Subtype") ?? "" } == ["Line", "PolyLine", "Polygon"])
        #expect(annots.map { $0.name("IT") ?? "" } == ["LineDimension", "PolyLineDimension", "PolygonDimension"])
        #expect(annots.map { $0.text("Contents") ?? "" } == ["20.00 ft", "20.00 ft", "100.00 sq ft"])
        for a in annots {
            let m = try #require(a.dict("Measure"))
            #expect(m.name("Subtype") == "RL")
            #expect(m.text("R") == "1 in = 10 ft")
            let x = try #require(m.array("X")?[0])
            #expect(Self.near(x.number("C") ?? 0, 10.0 / 72, 4))
            #expect(x.text("U") == "ft")
            #expect(a.dict("AP")?["N"] != nil)
        }
        #expect(annots[0]["Cap"]?.bool == true)
        // The label is drawn into the appearance: the page shows the value.
        #expect(try Core2Pdf.allText(pdf).contains("20.00 ft"))
        #expect(try Core2Pdf.allText(pdf).contains("100.00 sq ft"))

        // Reshaped, the value follows.
        let moved = try Annotations.updateGeometry(pdf, nil, "m1", AnnotGeometry(paths: [[PointD(72, 200), PointD(288, 200)]]))
        let line = try #require(try Self.annots(moved).first)
        #expect(line.text("Contents") == "30.00 ft")
        #expect(line.name("IT") == "LineDimension")
    }

    @Test func measurementsReadBackWithTheirValues() throws {
        let scale = try MeasureScale.from(1, "cm", 1, "m")
        let pdf = try Measurements.add(TestPdf.make(1), nil, 0, .distance, [PointD(100, 100), PointD(100 + 72 / 2.54 * 3, 100)], scale,
                                       author: "Ada", id: "d1")
        let all = try Measurements.read(pdf, nil, 0)
        try #require(all.count == 1)
        let found = all[0]
        #expect(found.kind == .distance)
        #expect(found.id == "d1")
        #expect(Self.near(found.value, 3, 4)) // coordinates are stored to 4 decimals
        #expect(found.text == "3.00 m")
        #expect(found.scale.unit == "m")
    }

    @Test func aPageWithAUserUnitMeasuresTrue() throws {
        // /UserUnit 2: each unit of the page's coordinates is 2 points, so a 72-unit line is 2 in long.
        var pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /UserUnit 2 >>",
        ])
        let scale = try MeasureScale.from(1, "in", 10, "ft")
        pdf = try Measurements.setPageScale(pdf, nil, [0], scale)
        let read = try #require(try Measurements.pageScale(pdf, nil, 0, PointD(10, 10)))
        #expect(read.userUnit == 2)
        #expect(Self.near(read.perPoint, 10.0 / 72, 9))
        #expect(Self.near(read.value(.distance, [PointD(0, 0), PointD(72, 0)]), 20, 9))
        #expect(try Measurements.userUnits(pdf, nil)[0] == 2)
        do {
            // /X /C converts from user space units: 20 ft per 72 units.
            let vp = try #require(try Core2Pdf.open(pdf).page(0).array("VP")?[0])
            let x = try #require(vp.dict("Measure")?.array("X")?[0])
            #expect(Self.near(x.number("C") ?? 0, 20.0 / 72, 4))
        }
        pdf = try Measurements.add(pdf, nil, 0, .distance, [PointD(100, 100), PointD(172, 100)], read, author: "Ada", id: "u1")
        let m = try Measurements.read(pdf, nil, 0)
        try #require(m.count == 1)
        #expect(m[0].text == "20.00 ft")
        // A real-size measurement there too: 72 units are 2 in.
        let plain = try Measurements.add(pdf, nil, 0, .distance, [PointD(100, 200), PointD(172, 200)], .default, author: "Ada", id: "u2")
        #expect(try Measurements.read(plain, nil, 0).contains { $0.text == "2.00 in" })
    }

    @Test func measuringOnATurnedPageReadsUpright() throws {
        var pdf = try PageEditor.rotate(TestPdf.make(1), nil, [0], 90)
        let scale = try MeasureScale.from(1, "in", 1, "ft")
        pdf = try Measurements.add(pdf, nil, 0, .distance, [PointD(100, 100), PointD(244, 100)], scale, author: "Ada", id: "r1")
        let all = try Measurements.read(pdf, nil, 0)
        try #require(all.count == 1)
        #expect(all[0].text == "2.00 ft")
        // The label is upright as shown: MuPDF reads it as one horizontal run.
        #expect(try Core2Pdf.lines(pdf).contains { $0.text.contains("2.00 ft") })
    }
}
