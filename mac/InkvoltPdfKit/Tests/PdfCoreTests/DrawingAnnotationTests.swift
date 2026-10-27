import Foundation
import Testing
@testable import PdfCore

/// Ported from DrawingAnnotationTests.cs: ink, shapes, lines, polygons and FreeText, created, read back, drawn by MuPDF,
/// edited and deleted. Refusals are `PdfEditError`s where .NET throws ArgumentException, ArgumentOutOfRangeException or
/// InvalidOperationException. Adapted: SignedFileKeepsItsSignatureThroughDrawingEdits edits the signed-looking fixture of
/// SignedEditTests and checks that every edit is appended after the signed bytes (verifying the signature comes with
/// digital signatures); the raw-byte checks read the file as Latin-1, as Windows does.
struct DrawingAnnotationTests {
    static let blue = AnnotColor(0.1, 0.2, 0.9)

    /// One empty page whose MediaBox doesn't start at 0,0 and whose CropBox trims it, optionally rotated (page space:
    /// 560 x 720, or 720 x 560 when turned a quarter).
    static func oddPage(_ rotate: Int) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [100 200 712 992] /CropBox [120 230 680 950] /Rotate \(rotate) /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.stream(""),
        ])
    }

    /// The fraction of pixels in a page-space region (rendered at 2x) that aren't near-white.
    static func painted(_ data: [UInt8], _ region: RectD, page: Int = 0) throws -> Double {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let img = try engine.render(page, scale: 2, region: region)
        var n = 0
        var i = 0
        while i + 2 < img.pixels.count {
            if img.pixels[i] < 200 || img.pixels[i + 1] < 200 || img.pixels[i + 2] < 200 { n += 1 }
            i += 3
        }
        return Double(n) / Double(img.width * img.height)
    }

    static func only(_ data: [UInt8]) throws -> AnnotationInfo {
        let all = try Annotations.read(data, nil)
        try #require(all.count == 1)
        return all[0]
    }

    static func near(_ expected: PointD, _ actual: PointD, _ comment: Comment? = nil) {
        #expect(abs(expected.x - actual.x) <= 0.05 && abs(expected.y - actual.y) <= 0.05, "\(expected) vs \(actual)")
    }

    static func near(_ expected: RectD, _ actual: RectD) {
        let ok = abs(expected.x - actual.x) <= 0.05 && abs(expected.y - actual.y) <= 0.05
            && abs(expected.width - actual.width) <= 0.05 && abs(expected.height - actual.height) <= 0.05
        #expect(ok, "\(expected) vs \(actual)")
    }

    static func style(_ color: AnnotColor?, fill: AnnotColor? = nil, width: Double = 2, _ change: (inout AnnotStyle) -> Void = { _ in }) -> AnnotStyle {
        var s = AnnotStyle(color: color, fill: fill, width: width)
        change(&s)
        return s
    }

    @Test func inkRoundTripsAndIsDrawn() throws {
        let strokes: [[PointD]] = [[PointD(100, 300), PointD(150, 320), PointD(200, 300), PointD(250, 340)], [PointD(120, 360), PointD(220, 360)]]
        let id = Annotations.newId()
        var pen = AnnotStyle.pen(Self.blue, width: 3)
        pen.opacity = 0.8
        let data = try Annotations.addInk(TestPdf.make(1), nil, 0, strokes, pen, author: "Ana", id: id)

        let a = try Self.only(data)
        #expect(a.id == id)
        #expect(a.kind == .ink)
        #expect(a.author == "Ana")
        let g = try #require(a.geometry)
        try #require(g.paths.count == 2)
        for s in strokes.indices {
            for i in strokes[s].indices { Self.near(strokes[s][i], g.paths[s][i]) }
        }
        Self.near(RectD(100, 300, 150, 60), g.box)
        let st = try #require(a.style)
        #expect(st.color == Self.blue)
        #expect(abs(st.width - 3) <= 0.01)
        #expect(abs(st.opacity - 0.8) <= 0.01)
        #expect(abs(a.opacity - 0.8) <= 0.01)
        #expect(!st.highlighter)
        #expect(a.rect.contains(100, 300) && a.rect.contains(250, 340))

        #expect(try Self.painted(data, RectD(115, 355, 90, 10)) > 0.2, "the second stroke is drawn")
        #expect(try Self.painted(data, RectD(300, 400, 50, 50)) == 0, "nothing elsewhere")
        #expect(latin1(data).contains("/InkList"))
    }

    @Test func highlighterMultipliesOverText() throws {
        // "The quick brown fox": its baseline is at y = 140 (page space), 20 pt Helvetica.
        let data = try Annotations.addInk(TestPdf.make(1), nil, 0, [[PointD(72, 133), PointD(260, 133)]], .marker(), author: "Ana")
        let a = try Self.only(data)
        #expect(a.style?.highlighter == true)
        #expect(abs((a.style?.width ?? 0) - 14) <= 0.01)
        #expect(latin1(data).contains("/Multiply"))

        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let img = try engine.render(0, scale: 1, region: RectD(72, 127, 180, 12))
        // Yellow: much red and green, little blue (Windows reads the same off BGR pixels; MuPDF's are RGB here).
        var tinted = 0, dark = 0
        var i = 0
        while i + 2 < img.pixels.count {
            let r = Int(img.pixels[i]), g = Int(img.pixels[i + 1]), b = Int(img.pixels[i + 2])
            if b < 120 && g > 150 && r > 200 { tinted += 1 }
            if r + g + b < 150 { dark += 1 }
            i += 3
        }
        #expect(tinted > img.width * img.height / 4, "tinted yellow")
        #expect(dark > 20, "the text under it stays dark")
    }

    @Test(arguments: zip([ShapeKind.rectangle, .ellipse], [AnnotationKind.square, .circle]))
    func shapesRoundTripAndAreDrawn(_ shape: ShapeKind, _ kind: AnnotationKind) throws {
        let box = RectD(200, 400, 150, 100)
        let style = Self.style(.red, fill: Self.blue, width: 4) {
            $0.dash = [6, 3]
            $0.opacity = 0.5
        }
        let data = try Annotations.addShape(TestPdf.make(1), nil, 0, shape, box, style, author: "Ana")

        let a = try Self.only(data)
        #expect(a.kind == kind)
        Self.near(box, try #require(a.geometry).box)
        Self.near(box, a.rect)
        let st = try #require(a.style)
        #expect(st.color == .red)
        #expect(st.fill == Self.blue)
        #expect(abs(st.width - 4) <= 0.01)
        #expect(st.dash == [6.0, 3.0])
        #expect(abs(st.opacity - 0.5) <= 0.01)

        // Filled (bluish) in the middle.
        do {
            let engine = try PdfEngine.open(data)
            defer { engine.close() }
            let img = try engine.render(0, scale: 1, region: RectD(box.centerX - 5, box.centerY - 5, 10, 10))
            // RGB here (Windows reads BGR): blue well above red.
            #expect(Int(img.pixels[2]) > Int(img.pixels[0]) + 40, "blue fill at half opacity")
        }
        #expect(try Self.painted(data, RectD(box.right + 3, box.y, 20, 20)) == 0)

        // No fill: the middle stays white, the border is drawn.
        let outline = try Annotations.addShape(TestPdf.make(1), nil, 0, shape, box, .pen(.red, width: 2), author: "Ana")
        #expect(try Self.only(outline).style?.fill == nil)
        #expect(try Self.painted(outline, RectD(box.centerX - 5, box.centerY - 5, 10, 10)) == 0)
        #expect(try Self.painted(outline, RectD(box.x, box.centerY - 3, 3, 6)) > 0.3, "left edge stroked")
    }

    @Test func linesAndArrowsRoundTrip() throws {
        var style = AnnotStyle.arrow(.red, width: 2)
        style.startEnding = .circle
        let data = try Annotations.addLine(TestPdf.make(1), nil, 0, PointD(100, 500), PointD(300, 600), style, author: "Ana")

        let a = try Self.only(data)
        #expect(a.kind == .line)
        let paths = try #require(a.geometry).paths
        try #require(paths.count == 1)
        Self.near(PointD(100, 500), paths[0][0])
        Self.near(PointD(300, 600), paths[0][1])
        #expect(a.style?.startEnding == .circle)
        #expect(a.style?.endEnding == .openArrow)
        #expect(latin1(data).contains("/OpenArrow"))
        #expect(a.rect.contains(300, 600) && a.rect.contains(95, 495), "the rect holds the endings")

        #expect(try Self.painted(data, RectD(195, 545, 10, 10)) > 0.1, "the line's middle")
        #expect(try Self.painted(data, RectD(288, 585, 8, 8)) > 0.05, "the arrow head")

        for ending in LineEnding.allCases {
            var s = AnnotStyle.pen(Self.blue)
            s.endEnding = ending
            s.fill = .yellow
            let d = try Annotations.addLine(TestPdf.make(1), nil, 0, PointD(100, 500), PointD(300, 500), s, author: "Ana")
            #expect(try Self.only(d).style?.endEnding == ending)
        }
    }

    @Test(arguments: [true, false])
    func polygonsAndPolylinesRoundTrip(_ closed: Bool) throws {
        let v = [PointD(100, 100), PointD(300, 120), PointD(250, 300), PointD(120, 250)]
        let style = Self.style(Self.blue, fill: closed ? .yellow : nil, width: 3)
        let data = try Annotations.addPolygon(Self.oddPage(0), nil, 0, v, closed: closed, style, author: "Ana")
        let a = try Self.only(data)
        #expect(a.kind == (closed ? .polygon : .polyLine))
        let paths = try #require(a.geometry).paths
        try #require(paths.count == 1 && paths[0].count == 4)
        for i in 0..<4 { Self.near(v[i], paths[0][i]) }
        #expect(try Self.painted(data, RectD(195, 105, 10, 10)) > 0.1, "first edge drawn")
        // The closing edge only on a polygon.
        #expect((try Self.painted(data, RectD(106, 170, 6, 10)) > 0.05) == closed)
    }

    @Test func freeTextRoundTripsWrapsAndIsExtracted() throws {
        let box = RectD(100, 450, 160, 80)
        let text = "Please review this paragraph again before Friday"
        let data = try Annotations.addFreeText(TestPdf.make(1), nil, 0, box, text,
                                               .textBox(fontSize: 12, border: Self.blue, fill: AnnotColor(1, 1, 0.8)), author: "Ana")

        let a = try Self.only(data)
        #expect(a.kind == .freeText)
        #expect(!a.isInkvoltPdfStamp)
        #expect(a.contents == text)
        let g = try #require(a.geometry)
        Self.near(box, g.box)
        #expect(g.callout.isEmpty)
        let st = try #require(a.style)
        #expect(st.color == Self.blue)
        #expect(abs(st.fontSize - 12) <= 0.01)
        #expect(st.textColor == AnnotStyle.black)
        #expect(st.fill == AnnotColor(1, 1, 0.8))
        let raw = latin1(data)
        #expect(raw.contains("/DA"))
        #expect(raw.contains("/DS"))
        #expect(raw.contains("/RC"))

        // Wrapped onto several lines, all inside the box.
        let lines = try Core2Pdf.lines(data).filter { $0.box.y > 400 }
        #expect(lines.count >= 3, "\(lines.map(\.text).joined(separator: " | "))")
        #expect(lines.map(\.text).joined(separator: " ").contains("Friday"))
        for l in lines {
            #expect(l.box.x >= box.x && l.box.right <= box.right + 1 && l.box.bottom <= box.bottom + 1, "\(l.text) \(l.box)")
        }

        // Editing the text redraws it.
        let edited = try Annotations.setContents(data, nil, a.id, "Done")
        #expect(try Core2Pdf.allText(edited).contains("Done"))
        #expect(try !Core2Pdf.allText(edited).contains("Friday"))
        #expect(try Self.only(edited).id == a.id)

        // Typewriter: no border, no fill.
        let tw = try Annotations.addFreeText(TestPdf.make(1), nil, 0, box, "Typed", .typewriter(fontSize: 14, textColor: .red), author: "Ana")
        let t = try Self.only(tw)
        #expect(t.style?.color == nil)
        #expect(t.style?.textColor == .red)
        #expect(latin1(tw).contains("/FreeTextTypewriter"))
        #expect(try Core2Pdf.allText(tw).contains("Typed"))
        let height = Annotations.freeTextHeight("Typed", width: 160, .typewriter(fontSize: 14))
        #expect(height > 14 && height < 30)
    }

    @Test func freeTextInOtherScriptsEmbedsAFont() throws {
        let data = try Annotations.addFreeText(TestPdf.make(1), nil, 0, RectD(100, 450, 250, 40), "Привет, мир", .typewriter(), author: "Ana")
        #expect(try Core2Pdf.allText(data).contains("Привет, мир"))
        #expect(try Self.only(data).contents == "Привет, мир")
    }

    @Test func calloutRoundTripsAndDrawsItsLeader() throws {
        let box = RectD(300, 300, 150, 50)
        let tip = PointD(150, 450), knee = PointD(250, 325)
        let data = try Annotations.addFreeText(TestPdf.make(1), nil, 0, box, "Look here", .textBox(), author: "Ana", callout: [tip, knee])

        let a = try Self.only(data)
        let g = try #require(a.geometry)
        Self.near(box, g.box)
        try #require(g.callout.count == 2)
        Self.near(tip, g.callout[0])
        Self.near(knee, g.callout[1])
        #expect(a.style?.endEnding == .openArrow)
        #expect(a.rect.contains(tip.x, tip.y))
        let raw = latin1(data)
        #expect(raw.contains("/FreeTextCallout"))
        #expect(raw.contains("/CL"))
        #expect(raw.contains("/RD"))
        #expect(try Core2Pdf.allText(data).contains("Look here"))
        #expect(try Self.painted(data, RectD(198, 385, 6, 6)) > 0.05, "the leader line, tip to knee")
        #expect(try Self.painted(data, RectD(270, 322, 20, 6)) > 0.05, "the leader line, knee to box")
    }

    @Test(arguments: [0, 90, 180, 270])
    func placedCorrectlyOnRotatedAndCroppedPages(_ rotation: Int) throws {
        var data = Self.oddPage(rotation)
        do {
            let e = try PdfEngine.open(data)
            defer { e.close() }
            #expect(abs(e.page(0).width - (rotation == 90 || rotation == 270 ? 720 : 560)) <= 0.5)
        }
        let shapeBox = RectD(60, 80, 120, 70)
        let textBox = RectD(250, 300, 220, 30)
        data = try Annotations.addShape(data, nil, 0, .rectangle, shapeBox, Self.style(.red, fill: .red, width: 1), author: "Ana")
        data = try Annotations.addInk(data, nil, 0, [[PointD(60, 200), PointD(160, 230), PointD(260, 200)]], .pen(Self.blue, width: 3), author: "Ana")
        data = try Annotations.addLine(data, nil, 0, PointD(60, 260), PointD(200, 260), .arrow(Self.blue, width: 2), author: "Ana")
        data = try Annotations.addFreeText(data, nil, 0, textBox, "UPRIGHT CALLOUT", .textBox(fontSize: 14), author: "Ana", callout: [PointD(220, 400)])

        let list = try Annotations.read(data, nil)
        let square = try #require(list.first { $0.kind == .square })
        Self.near(shapeBox, try #require(square.geometry).box)
        Self.near(shapeBox, square.rect)
        Self.near(PointD(160, 230), try #require(list.first { $0.kind == .ink }?.geometry).paths[0][1])
        Self.near(PointD(200, 260), try #require(list.first { $0.kind == .line }?.geometry).paths[0][1])
        let ft = try #require(list.first { $0.kind == .freeText }?.geometry)
        Self.near(textBox, ft.box)
        try #require(ft.callout.count == 1)
        Self.near(PointD(220, 400), ft.callout[0])

        #expect(try Self.painted(data, RectD(shapeBox.x + 5, shapeBox.y + 5, 20, 20)) > 0.9, "the filled rectangle where it was put")
        #expect(try Self.painted(data, RectD(shapeBox.right + 5, shapeBox.y, 20, 20)) == 0)
        #expect(try Self.painted(data, RectD(150, 222, 20, 14)) > 0.05, "the ink stroke")
        #expect(try Self.painted(data, RectD(120, 255, 20, 10)) > 0.1, "the line")
        #expect(try Self.painted(data, RectD(217, 397, 6, 6)) > 0.05, "the callout tip")

        // The text reads left to right in the viewer, inside its box.
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let origin = engine.page(0)
        let line = try #require(try Core2Pdf.lines(data).first { $0.text.contains("UPRIGHT") })
        let box = RectD(line.box.x - origin.originX, line.box.y - origin.originY, line.box.width, line.box.height)
        #expect(box.width > box.height * 3, "rotation \(rotation): text runs sideways (\(box))")
        #expect(box.x >= textBox.x && box.x <= textBox.x + 10, "\(box)")
        #expect(box.y >= textBox.y && box.y <= textBox.bottom, "\(box)")
    }

    @Test func geometryAndStyleEditsKeepTheIdAndRedraw() throws {
        let page = TestPdf.make(2)
        let id = Annotations.newId()
        let data = try Annotations.addShape(page, nil, 1, .ellipse, RectD(100, 300, 100, 100), Self.style(.red, fill: .red), author: "Ana", id: id)
        #expect(try Self.painted(data, RectD(140, 340, 20, 20), page: 1) > 0.9)

        let moved = try Annotations.updateGeometry(data, nil, id, AnnotGeometry(box: RectD(300, 500, 80, 60)))
        let a = try Self.only(moved)
        #expect(a.id == id)
        #expect(a.pageIndex == 1)
        Self.near(RectD(300, 500, 80, 60), try #require(a.geometry).box)
        #expect(try Self.painted(moved, RectD(140, 340, 20, 20), page: 1) == 0)
        #expect(try Self.painted(moved, RectD(330, 520, 20, 20), page: 1) > 0.9)

        var restyle = try #require(a.style)
        restyle.fill = nil
        restyle.color = Self.blue
        restyle.width = 5
        let restyled = try Annotations.updateStyle(moved, nil, id, restyle)
        let r = try Self.only(restyled)
        #expect(r.id == id)
        #expect(r.style?.color == Self.blue)
        #expect(r.style?.fill == nil)
        #expect(try Self.painted(restyled, RectD(330, 520, 20, 20), page: 1) == 0)

        // Ink scales with its bounds.
        let inkId = Annotations.newId()
        let ink = try Annotations.addInk(page, nil, 0, [[PointD(100, 100), PointD(200, 200)]], .pen(Self.blue), author: "Ana", id: inkId)
        let scaled = try Annotations.setBounds(ink, nil, inkId, RectD(300, 400, 50, 200))
        let path = try #require(try Self.only(scaled).geometry).paths[0]
        Self.near(PointD(300, 400), path[0])
        Self.near(PointD(350, 600), path[1])
        #expect(try Self.only(scaled).id == inkId)

        // A callout's tip moves on its own.
        let ftId = Annotations.newId()
        let ft = try Annotations.addFreeText(page, nil, 0, RectD(300, 300, 100, 40), "Hi", .textBox(), author: "Ana", callout: [PointD(200, 200)], id: ftId)
        var g = try #require(try Self.only(ft).geometry)
        g.callout = [PointD(450, 450)]
        let retargeted = try Annotations.updateGeometry(ft, nil, ftId, g)
        let callout = try #require(try Self.only(retargeted).geometry).callout
        try #require(callout.count == 1)
        Self.near(PointD(450, 450), callout[0])
        #expect(try Self.only(retargeted).contents == "Hi")

        #expect(throws: PdfEditError.self) { try Annotations.updateGeometry(ft, nil, ftId, AnnotGeometry()) }
        #expect(throws: PdfEditError.self) { try Annotations.updateStyle(ft, nil, "nope", .typewriter()) }
    }

    @Test func stampsAndTextMarkupAreNotReshaped() throws {
        let stamp = try TextStamps.put(TestPdf.make(1), nil, 0, RectD(100, 100, 100, 20), .text, "Hi", 12)
        let s = try Self.only(stamp)
        #expect(s.geometry == nil)
        #expect(throws: PdfEditError.self) { try Annotations.setBounds(stamp, nil, s.id, RectD(0, 0, 50, 50)) }
    }

    @Test func deleteRemovesEachKind() throws {
        var data = TestPdf.make(1)
        data = try Annotations.addInk(data, nil, 0, [[PointD(100, 100), PointD(150, 150)]], .pen(Self.blue), author: "Ana")
        data = try Annotations.addShape(data, nil, 0, .rectangle, RectD(100, 200, 50, 50), .pen(Self.blue), author: "Ana")
        data = try Annotations.addShape(data, nil, 0, .ellipse, RectD(200, 200, 50, 50), .pen(Self.blue), author: "Ana")
        data = try Annotations.addLine(data, nil, 0, PointD(100, 300), PointD(200, 300), .arrow(Self.blue), author: "Ana")
        data = try Annotations.addPolygon(data, nil, 0, [PointD(300, 300), PointD(350, 300), PointD(320, 350)], closed: true, .pen(Self.blue), author: "Ana")
        data = try Annotations.addFreeText(data, nil, 0, RectD(100, 400, 100, 30), "Bye", .typewriter(), author: "Ana")
        let all = try Annotations.read(data, nil)
        #expect(all.count == 6)
        #expect(all.allSatisfy { $0.geometry != nil })
        for a in all { data = try Annotations.delete(data, nil, a.id) }
        #expect(try Annotations.read(data, nil).isEmpty)
        #expect(try Self.painted(data, RectD(90, 180, 300, 260)) == 0)
    }

    @Test func rejectsUnusableInput() throws {
        let page = TestPdf.make(1)
        #expect(throws: PdfEditError.self) { try Annotations.addInk(page, nil, 0, [], .pen(Self.blue), author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addInk(page, nil, 0, [[PointD(.nan, 1)]], .pen(Self.blue), author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addShape(page, nil, 0, .rectangle, .zero, .pen(Self.blue), author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addLine(page, nil, 0, PointD(1, 1), PointD(2, 2), AnnotStyle(color: nil), author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addShape(page, nil, 3, .rectangle, RectD(1, 1, 5, 5), .pen(Self.blue), author: "Ana") }
        // A single tap draws a dot.
        let dot = try Annotations.addInk(page, nil, 0, [[PointD(400, 400)]], .pen(Self.blue, width: 6), author: "Ana")
        #expect(try Self.painted(dot, RectD(398, 398, 4, 4)) > 0.5)
    }

    @Test func signedFileKeepsItsSignatureThroughDrawingEdits() throws {
        let pdf = SignedEditTests.signed()
        func appended(_ edited: [UInt8]) -> Bool { edited.count > pdf.count && Array(edited[0..<pdf.count]) == pdf }
        let inkId = Annotations.newId()
        var data = try Annotations.addInk(pdf, nil, 0, [[PointD(100, 400), PointD(200, 450)]], .marker(), author: "Ana", id: inkId)
        #expect(appended(data), "appended as an update")
        let ftId = Annotations.newId()
        data = try Annotations.addFreeText(data, nil, 0, RectD(300, 400, 150, 40), "Approved ✓ Ωmega", .textBox(), author: "Ana",
                                           callout: [PointD(250, 350)], id: ftId)
        #expect(appended(data))
        data = try Annotations.addShape(data, nil, 0, .rectangle, RectD(100, 600, 50, 50), .pen(Self.blue), author: "Ana")
        data = try Annotations.addLine(data, nil, 0, PointD(100, 700), PointD(200, 700), .arrow(Self.blue), author: "Ana")
        data = try Annotations.updateGeometry(data, nil, inkId, AnnotGeometry(paths: [[PointD(120, 420), PointD(220, 470)]]))
        data = try Annotations.updateStyle(data, nil, ftId, .textBox(fontSize: 16, border: Self.blue))
        data = try Annotations.setBounds(data, nil, ftId, RectD(150, 150, 200, 200))
        data = try Annotations.setContents(data, nil, ftId, "Changed")
        #expect(appended(data))
        #expect(try Core2Pdf.allText(data).contains("Changed"))
        data = try Annotations.delete(data, nil, inkId)
        #expect(appended(data))
        #expect(try Annotations.read(data, nil).count == 3)
    }
}
