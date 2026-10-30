import Foundation
import Testing
@testable import PdfCore

/// Ported from FieldDetectionTests.cs, whole: form field suggestions from generated pages. The Windows tests draw with
/// PDFsharp's XGraphics in Arial; here the same drawing is a content stream in Helvetica (the same widths), with y from the
/// page's top as XGraphics counts it.
struct FieldDetectionTests {
    private static func text(_ s: String, _ x: Double, _ y: Double) -> String { "BT /F 11 Tf 1 0 0 1 \(x) \(792 - y) Tm (\(s)) Tj ET\n" }
    private static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String { "\(x1) \(792 - y1) m \(x2) \(792 - y2) l S\n" }
    private static func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String { "\(x) \(792 - y - h) \(w) \(h) re S\n" }

    private static func page(_ content: String, rotate: Int = 0) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotate) /Contents 4 0 R /Resources << /Font << /F 5 0 R >> >> >>",
            Core2Pdf.stream(content),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
    }

    private func detect(_ pdf: [UInt8], _ existing: [DesignField] = []) throws -> [FieldSuggestion] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try FieldDetection.suggest(engine, pdf, nil, [0], existing)
    }

    private func rounded(_ r: RectD) -> RectD { RectD(r.x.rounded(), r.y.rounded(), r.width.rounded(), r.height.rounded()) }

    @Test func underscoresBecomeTextFieldsNamedAfterTheirLabel() throws {
        let pdf = Self.page(Self.text("Name: ____________________", 72, 100) + Self.text("Date of birth: __________   City: __________", 72, 130))
        let s = try detect(pdf)
        #expect(s.map(\.name) == ["Name", "Date of birth", "City"])
        #expect(s.allSatisfy { $0.kind == .text })
        let name = s[0]
        #expect(name.rect.x > 100 && name.rect.right > 200, "over the underscores: \(name.rect)")
        #expect((98...106).contains(name.rect.bottom), "stands on the baseline area: \(name.rect)")
        #expect(name.rect.height >= 12)
    }

    @Test func ruledLinesBecomeFieldsAndSignatureLinesSignatureFields() throws {
        let pdf = Self.page(Self.text("Email", 72, 200) + Self.line(110, 202, 320, 202) + Self.line(72, 300, 250, 300) + Self.text("Signature", 72, 313))
        let s = try detect(pdf)
        #expect(s.count == 2)
        let email = try #require(s.first { $0.name == "Email" })
        #expect(email.kind == .text)
        #expect((109...111).contains(email.rect.x))
        #expect((200...203).contains(email.rect.bottom))
        let sig = try #require(s.first { $0.name == "Signature" })
        #expect(sig.kind == .signature)
    }

    @Test func emptyBoxesAndSquares() throws {
        let pdf = Self.page(Self.text("Address", 72, 95) + Self.box(72, 100, 300, 60) + Self.text("Phone", 72, 196) + Self.box(120, 182, 150, 20)
            + Self.box(72, 230, 10, 10) + Self.text("I agree to the terms", 88, 239))
        let s = try detect(pdf)
        let address = try #require(s.first { $0.name == "Address" })
        #expect(address.multiline)
        #expect(rounded(address.rect) == RectD(72, 100, 300, 60))
        let phone = try #require(s.first { $0.name == "Phone" })
        #expect(!phone.multiline)
        let agree = try #require(s.first { $0.kind == .checkBox })
        #expect(agree.name == "I agree to the terms")
        #expect(s.count == 3)
    }

    @Test func boxCharactersBecomeCheckBoxes() throws {
        // "☐ Married" as a page's text layer (fonts map their box symbols to ☐, ❑ and the like).
        var line: [(String, RectD)] = [("☐", RectD(72, 90, 11, 12)), (" ", RectD(83, 90, 3, 12))]
        line += "Married".enumerated().map { (String($0.element), RectD(90 + Double($0.offset) * 6, 90, 6, 12)) }
        let found = try FieldDetection.suggest(0, 612, 792, PageText([line]), [], [], [])
        try #require(found.count == 1)
        #expect(found[0].kind == .checkBox)
        #expect(found[0].name == "Married")
        #expect((9...11).contains(found[0].rect.width))
    }

    @Test func textUnderlinesBoxedTextAndFramesAreNotFields() throws {
        let pdf = Self.page(Self.text("Important notice", 72, 100) + Self.line(72, 102, 160, 102) // underlined text
            + Self.box(72, 150, 200, 30) + Self.text("Already filled in", 80, 170) // a box with text
            + Self.box(20, 20, 572, 752) // page frame
            + Self.line(36, 400, 576, 400)) // a separator across the page
        #expect(try detect(pdf).isEmpty)
    }

    @Test func placesWithFieldsAreSkipped() throws {
        let pdf = Self.page(Self.text("Name: ____________________", 72, 100))
        let first = try detect(pdf)
        try #require(first.count == 1)
        let withField = try FormDesign.add(pdf, nil, [FormDesign.newField(.text, 0, first[0].rect, [], first[0].name)])
        #expect(try detect(withField, FormDesign.read(withField, nil)).isEmpty)

        // A second page's suggestion doesn't reuse a taken name.
        let again = try FieldDetection.suggest(0, 612, 792, .empty, [PageShape(RectD(72, 300, 200, 20), false)], [], ["Text1"])
        try #require(again.count == 1)
        #expect(again[0].name == "Text2")
    }

    @Test func shapesFollowTheTransformAndFormXObjects() throws {
        // A box drawn at (10,10) scaled 2x and moved, and the same drawn inside a form XObject placed with cm.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Fm 5 0 R >> >> >>",
            Core2Pdf.stream("q 2 0 0 2 100 100 cm 0 0 50 10 re S Q 1 1 1 RG 0 0 0 rg q 1 0 0 1 300 500 cm /Fm Do Q 0 G 72 700 m 272 700 l S"),
            Core2Pdf.stream("0 0 40 40 re S 1 g 0 0 5 5 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 10 0]"),
        ])
        let shapes = try VectorShapes.read(pdf, nil, 0)
        let boxes = shapes.filter { !$0.isLine }.map { rounded($0.box) }
        #expect(boxes.contains(RectD(100, 792 - 120, 100, 20)))
        #expect(!boxes.contains { $0.width == 40 }) // stroked white: invisible
        let lines = shapes.filter(\.isLine)
        try #require(lines.count == 1)
        #expect(near(lines[0].box.x, 72, 1))
        #expect(near(lines[0].box.width, 200, 1))
        #expect(near(lines[0].box.centerY, 92, 1))
        #expect(!boxes.contains { $0.width == 5 }) // white fill
    }

    @Test func turnedPagesMapToTheShownPage() throws {
        let pdf = Self.page(Self.box(100, 100, 200, 30), rotate: 90)
        let shapes = try VectorShapes.read(pdf, nil, 0)
        try #require(shapes.count == 1)
        // Page space is the page as shown: turned 90° clockwise, 792 wide.
        #expect(rounded(shapes[0].box) == RectD(792 - 130, 100, 30, 200))
    }

    @Test(arguments: [
        ("Name:", "Name"), ("1. Date of birth (mm/dd/yyyy):", "Date of birth"), ("E-mail address *", "E-mail address"), ("a.b", "a b"),
    ] as [(String, String)])
    func labelsBecomeNames(_ label: String, _ name: String) {
        #expect(FieldDetection.cleanLabel(label) == name)
    }

    @Test func captionsRightOfABoxKeepTheirFirstWords() {
        #expect(FieldDetection.cleanLabel("I agree to the terms and conditions", leading: true) == "I agree to the terms")
    }

    @Test func aCancelledPageStopsAndBusyPagesStayQuick() throws {
        // A dense page: 60 x 60 small squares (a grid of check boxes), each with a caption character to its right.
        var shapes: [PageShape] = []
        var line: [(String, RectD)] = []
        for row in 0..<60 {
            for col in 0..<60 {
                shapes.append(PageShape(RectD(Double(10 + col * 13), Double(10 + row * 13), 8, 8), false))
                line.append(("x", RectD(Double(19 + col * 13), Double(10 + row * 13), 3, 8)))
            }
        }
        let text = PageText([line])
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try FieldDetection.suggest(0, 800, 800, text, shapes, [], [], cancel: cancel) }

        // This thread's processor time: other work on the Mac doesn't count.
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        let start = cpu()
        let found = try FieldDetection.suggest(0, 800, 800, text, shapes, [], [])
        #expect(found.count == 3600)
        #expect(found.allSatisfy { $0.kind == .checkBox })
        #expect(cpu() - start < 10, "took \(cpu() - start) s")
    }

    @Test func theGridFindsWhatTouchesARegion() {
        var rng = SeededGenerator(seed: 3)
        func next() -> Double { Double.random(in: 0..<1, using: &rng) }
        let grid = RectGrid()
        var rects: [RectD] = []
        for i in 0..<500 {
            let r = RectD(next() * 600, next() * 800, next() * (i % 50 == 0 ? 2000 : 60), next() * 40)
            rects.append(r)
            grid.add(r)
        }
        for _ in 0..<200 {
            let region = RectD(next() * 600, next() * 800, next() * 200, next() * 200)
            let expected = rects.indices.filter { rects[$0].x <= region.right && rects[$0].right >= region.x && rects[$0].y <= region.bottom && rects[$0].bottom >= region.y }
            #expect(grid.nearIndices(region) == expected)
        }
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
