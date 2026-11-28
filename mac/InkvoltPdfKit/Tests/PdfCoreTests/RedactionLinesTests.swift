import Foundation
import Testing
@testable import PdfCore

/// Ported from RedactionLinesTests.cs (same names): roadmap 1.5's last item, glyph-spacing inference around pixel
/// redactions (arXiv 2206.02285). Pages where the width of the gap a removed name leaves would tell the name: after
/// Redaction, a line looks the same whichever name it held.
@Suite struct RedactionLinesTests {
    private static func page(_ content: String) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream(content),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
    }

    private static func show(_ text: String, _ y: Double = 700, wordSpacing: Double = 0) -> String {
        "BT /F1 18 Tf \(String(format: "%.3f", wordSpacing)) Tw 72 \(PdfNum.f2(y)) Td (\(text)) Tj ET "
    }

    /// Each match of `text` on the page, grown by a point (as Apply Redactions marks it).
    private static func boxes(_ pdf: [UInt8], _ text: String) throws -> [RectD] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let t = try engine.text(0)
        return t.find(text, matchCase: true, wholeWord: false).map { m in t.rects(m.start, m.end).reduce(RectD.zero) { $0.union($1) }.inflate(1) }
    }

    private static func redact(_ pdf: [UInt8], _ text: String) throws -> Redaction.RedactedPages {
        try Redaction.redact(pdf, nil, [0: try boxes(pdf, text)], dpi: 144)
    }

    private static func render(_ pdf: [UInt8], _ strip: RectD) throws -> RenderedImage {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.render(0, scale: 2, region: strip)
    }

    private static func dark(_ img: RenderedImage, _ x: Int, _ y: Int) -> Bool {
        let o = (y * img.width + x) * 3
        return Int(img.pixels[o]) + Int(img.pixels[o + 1]) + Int(img.pixels[o + 2]) < 384
    }

    /// Which pixel columns of a strip of the page hold ink, at 2 pixels a point.
    private static func ink(_ pdf: [UInt8], _ strip: RectD) throws -> [Bool] {
        let img = try render(pdf, strip)
        var ink = [Bool](repeating: false, count: img.width)
        for y in 0..<img.height {
            for x in 0..<img.width where dark(img, x, y) { ink[x] = true }
        }
        return ink
    }

    /// Which pixel rows of a strip of the page hold ink, at 2 pixels a point.
    private static func inkRows(_ pdf: [UInt8], _ strip: RectD) throws -> [Bool] {
        let img = try render(pdf, strip)
        var ink = [Bool](repeating: false, count: img.height)
        for y in 0..<img.height {
            for x in 0..<img.width where dark(img, x, y) { ink[y] = true }
        }
        return ink
    }

    /// The first column with ink at or after `from`.
    private static func firstInk(_ ink: [Bool], _ from: Int) -> Int { (from..<ink.count).first { ink[$0] } ?? -1 }

    private static func differing(_ a: [Bool], _ b: [Bool]) -> Int { zip(a, b).count { $0 != $1 } }

    /// The stretches of ink (words and boxes: gaps under 8 pixels, between letters, joined; a space is 12).
    private static func runs(_ ink: [Bool]) -> [(start: Int, end: Int)] {
        var runs: [(start: Int, end: Int)] = []
        for x in ink.indices where ink[x] {
            if let last = runs.last, x - last.end < 8 {
                runs[runs.count - 1].end = x + 1
            } else {
                runs.append((x, x + 1))
            }
        }
        return runs
    }

    /// The line looks the same in both: the same words and box, each starting and ending within a pixel of the other's.
    /// (Not to the pixel: a moved word keeps the shading it was drawn with, a fraction of a pixel that depends on where it was.)
    private static func sameLine(_ a: [Bool], _ b: [Bool], sourceLocation: SourceLocation = #_sourceLocation) {
        let ra = runs(a), rb = runs(b)
        #expect(ra.count == rb.count, "\(ra.count) vs \(rb.count) stretches: \(ra) | \(rb)", sourceLocation: sourceLocation)
        for (x, y) in zip(ra, rb) {
            #expect(abs(x.start - y.start) <= 1 && abs(x.end - y.end) <= 1, "\(ra) | \(rb)", sourceLocation: sourceLocation)
        }
    }

    /// The line at 700 (Helvetica 18) from its start to the page's right margin.
    private static let lineStrip = RectD(60, 72, 500, 24)

    private static func flat(_ p: [(x: Double, width: Double)]) -> [[Double]] { p.map { [$0.x, $0.width] } }

    @Test func theLayoutDependsOnTheRemovedWidthOnlyByItsStep() {
        // "Name: ▮ lives here", the box 70 or 80 points wide: in a line 20 points high both are two 40-point steps.
        func line(_ boxWidth: Double, _ gap: Double) -> RedactionLines.CutLine {
            var l = RedactionLines.CutLine(band: RectD(72, 80, 300, 20), rows: RectD(72, 78, 300, 24), pieces: [
                .init(x: 72, right: 120, kind: .word, spaced: false),
                .init(x: 120 + gap, right: 120 + gap + boxWidth, kind: .box, spaced: true),
                .init(x: 120 + 2 * gap + boxWidth, right: 160 + 2 * gap + boxWidth, kind: .word, spaced: true),
                .init(x: 165 + 2 * gap + boxWidth, right: 190 + 2 * gap + boxWidth, kind: .word, spaced: true),
            ], areas: [])
            l.limit = 612
            return l
        }
        let narrow = RedactionLines.layout(line(70, 5))
        let wide = RedactionLines.layout(line(80, 9)) // a justified line's wider spaces too
        #expect(Self.flat(narrow) == Self.flat(wide))
        #expect(Self.flat(narrow) == [[72, 48], [125, 80], [210, 40], [255, 25]])
        #expect(RedactionLines.boxWidth(1, 20) == 40) // at least one step
        #expect(RedactionLines.boxWidth(110, 20) == 120)
        // A line that would run off the page (or into the next column) narrows its spaces to fit.
        var tightLine = line(80, 5)
        tightLine.limit = 275
        let tight = RedactionLines.layout(tightLine)
        #expect(abs(tight[tight.count - 1].x + tight[tight.count - 1].width - 275) < 1e-3)
        // Right-aligned, it keeps its end (the band's: 372); centred, its middle (222); either way the same for both widths.
        for align in [RedactionLines.Alignment.end, .middle] {
            var l1 = line(70, 5), l2 = line(80, 9)
            l1.align = align
            l2.align = align
            let a = RedactionLines.layout(l1)
            #expect(Self.flat(a) == Self.flat(RedactionLines.layout(l2)))
            let (first, last) = (a[0].x, a[a.count - 1].x + a[a.count - 1].width)
            #expect(abs((align == .end ? last : (first + last) / 2) - (align == .end ? 372 : 222)) < 1e-3)
        }
    }

    @Test func twoNamesOfDifferentWidthsLeaveTheSameLine() throws {
        // The text after the name starts where the name ended: left as it was, its place tells the name's width.
        let a = Self.page(Self.show("Patient: Robert Kahn was seen on Monday"))
        let b = Self.page(Self.show("Patient: Bob Kahn was seen on Monday"))
        let wasA = try Self.boxes(a, "was")[0].x, wasB = try Self.boxes(b, "was")[0].x
        #expect(abs(wasA - wasB) > 10, "\(wasA) \(wasB)") // the names differ by 22 points

        let ra = try Self.redact(a, "Robert Kahn")
        let rb = try Self.redact(b, "Bob Kahn")
        try #require(ra.blacked[0]?.count == 1 && rb.blacked[0]?.count == 1)
        #expect(ra.blacked[0]![0] == rb.blacked[0]![0])
        let inkA = try Self.ink(ra.data, Self.lineStrip)
        Self.sameLine(inkA, try Self.ink(rb.data, Self.lineStrip))
        // Everything after the box is still there, in order: "was seen on Monday" starts a space after it.
        let box = ra.blacked[0]![0]
        let after = Self.firstInk(inkA, Int((box.right - Self.lineStrip.x) * 2) + 3) // past the box's shaded edge
        let gap = Double(after) / 2 + Self.lineStrip.x - box.right
        #expect(gap >= 3 && gap <= 8, "\(gap)")
        #expect(inkA.dropFirst(after).count { $0 } > 100, "the words after the box show")
        // The box is a whole number of steps of twice the line's height.
        let steps = box.width / (RedactionLines.stepOfHeight * (try Self.boxes(a, "Patient:")[0].inflate(-1).height))
        #expect(abs(steps.rounded() - steps) < 0.05, "\(steps)")
    }

    @Test func justifiedLinesKeepNoTraceOfTheRemovedWidthInTheirSpaces() throws {
        // Justified to the same width, the spaces of a line with a shorter name are wider: the words before the box tell it.
        func text(_ name: String) -> String { "The patient \(name) was seen at the clinic today" }
        func natural(_ name: String) throws -> Double { try Self.boxes(Self.page(Self.show(text(name))), text(name))[0].width - 2 }
        func spacing(_ name: String) throws -> Double { (480 - (try natural(name))) / Double(text(name).count { $0 == " " }) }
        let a = Self.page(Self.show(text("Robert Kahn"), wordSpacing: try spacing("Robert Kahn")))
        let b = Self.page(Self.show(text("Bob Kahn"), wordSpacing: try spacing("Bob Kahn")))
        #expect(abs(try Self.boxes(a, "today")[0].right - Self.boxes(b, "today")[0].right) <= 0.5)
        #expect(abs(try Self.boxes(a, "patient")[0].x - Self.boxes(b, "patient")[0].x) > 1) // the first space already differs

        let ra = try Self.redact(a, "Robert Kahn")
        let rb = try Self.redact(b, "Bob Kahn")
        Self.sameLine(try Self.ink(ra.data, Self.lineStrip), try Self.ink(rb.data, Self.lineStrip))
        // The words that moved are said, so what was kept can be found where it went.
        let today = try Self.boxes(a, "today")[0]
        let now = ra.moved.now(0, today)
        #expect(today.x != now.x)
        #expect(try Self.ink(ra.data, now.inflate(-2)).count { $0 } > 10)
    }

    @Test func aLineRedactedWholeIsJustItsRoundedBoxAndABlockKeepsItsArea() throws {
        // A whole line redacted: its box, drawn round the words, would be as wide as they are; it is rounded to whole steps,
        // so two names on lines of their own leave the same box. The line under it keeps its place.
        let a = Self.page(Self.show("Bob Kahn") + Self.show("Visible line below", 670))
        let b = Self.page(Self.show("Robert Kahn") + Self.show("Visible line below", 670))
        let ra = try Self.redact(a, "Bob Kahn")
        let rb = try Self.redact(b, "Robert Kahn")
        try #require(ra.blacked[0]?.count == 1 && rb.blacked[0]?.count == 1)
        let black = ra.blacked[0]![0]
        #expect(black == rb.blacked[0]![0])
        #expect(abs(try Self.boxes(a, "Bob Kahn")[0].x + 1 - black.x) < 0.5) // where its text started
        Self.sameLine(try Self.ink(ra.data, Self.lineStrip), try Self.ink(rb.data, Self.lineStrip))
        #expect(ra.moved.isEmpty)
        let below = RectD(60, 792 - 690, 500, 24)
        #expect(Self.differing(try Self.ink(a, below), try Self.ink(ra.data, below)) <= 4)

        // A block over both lines: its box is the area drawn, as drawn.
        let block = RectD.fromEdges(60, 70, 400, 130)
        let rc = try Redaction.redact(a, nil, [0: [block]], dpi: 144)
        #expect(rc.blacked[0] == [block])
    }

    @Test func aNeighbouringColumnIsNotRunInto() throws {
        // "Ann a b" and, on the same rows, another column's "Right": with "a" redacted and its box rounded up to a whole
        // step, the line would reach past where the other column starts; its spaces narrow so it stops short of it.
        func chars(_ s: String, _ x: Double) -> [(String, RectD)] { s.enumerated().map { (String($1), RectD(x + 10 * Double($0), 80, 10, 20)) } }
        let text = PageText([chars("Ann a b", 72), chars("Right", 170)])
        let lines = RedactionLines.find(text, [RectD(111, 79, 12, 22)], 612, 792)
        try #require(lines.count == 1)
        let line = lines[0]
        #expect(abs(line.limit - 160) < 1e-3)
        #expect(line.pieces.map(\.box) == [false, true, false])
        let placed = RedactionLines.layout(line)
        #expect(abs(placed[1].width - 40) < 1e-3) // one step of twice the line's height
        #expect(abs(placed[placed.count - 1].x + placed[placed.count - 1].width - 160) < 1e-3)
    }

    @Test func aPictureRedactedBesideAParagraphLeavesItsLinesAlone() {
        func chars(_ s: String, _ x: Double, _ y: Double) -> [(String, RectD)] { s.enumerated().map { (String($1), RectD(x + 10 * Double($0), y, 10, 20)) } }
        let text = PageText([chars("abc def", 72, 80), chars("ghi jkl", 72, 104), chars("mno pqr", 72, 128)])
        // Taller than a line, a few points right of the paragraph: no letter of it is taken.
        #expect(RedactionLines.find(text, [RectD(150, 70, 200, 90)], 612, 792).isEmpty)
        // A block over the middle of the lines takes "def", "jkl" and "pqr": each line keeps the rest, laid out again.
        #expect(RedactionLines.find(text, [RectD(110, 70, 100, 90)], 612, 792).count == 3)
    }

    @Test func hostileAreasAndTextLeaveThePageRedacted() throws {
        let pdf = Self.page(Self.show("Patient: Ann Lee was seen"))
        let name = try Self.boxes(pdf, "Ann Lee")[0]
        let hostile: [[RectD]] = [
            [name, RectD(.nan, 0, 10, 10), RectD(0, .infinity, 10, 10)],
            [name, RectD(-1e9, name.y, 2e9, name.height)], // an area across the whole line and far beyond
            (0..<2000).map { RectD(72 + Double($0) * 0.01, name.y, 0.5, name.height) }, // thousands of slivers
        ]
        for areas in hostile {
            let r = try Redaction.redact(pdf, nil, [0: areas], dpi: 72)
            let engine = try PdfEngine.open(r.data)
            defer { engine.close() }
            #expect(try engine.text(0).isEmpty)
        }
        // Lines found from text with no size are left alone.
        let text = PageText([[("A", RectD(10, 10, 0, 0)), ("B", RectD(20, 10, 5, 0))]])
        #expect(RedactionLines.find(text, [RectD(0, 0, 50, 50)], 612, 792).isEmpty)
    }

    @Test func aSidewaysLineIsLaidOutAlongItsOwnAxis() throws {
        // "A B C" turned clockwise (down the page): "B" redacted, the line's pieces run down it.
        let turned = PageText([[("A", RectD(10, 10, 10, 10)), (" ", RectD(10, 20, 10, 10)), ("B", RectD(10, 30, 10, 10)),
                                (" ", RectD(10, 40, 10, 10)), ("C", RectD(10, 50, 10, 10))]], directions: [(0, 1)])
        let lines = RedactionLines.find(turned, [RectD(9, 29, 12, 12)], 612, 792)
        try #require(lines.count == 1)
        let line = lines[0]
        #expect(line.vertical)
        #expect(line.pieces.map(\.kind) == [.word, .box, .word])
        #expect(line.toPage(line.band) == RectD(10, 10, 10, 50))

        // On a page: a name written up the page, two names of different lengths leave the same column.
        func up(_ name: String) -> [UInt8] { Self.page("BT /F1 18 Tf 0 1 -1 0 300 100 Tm (Patient: \(name) was seen on Monday) Tj ET") }
        let a = try Redaction.redact(up("Robert Kahn"), nil, [0: try Self.boxes(up("Robert Kahn"), "Robert Kahn")], dpi: 144)
        let b = try Redaction.redact(up("Bob Kahn"), nil, [0: try Self.boxes(up("Bob Kahn"), "Bob Kahn")], dpi: 144)
        try #require(a.blacked[0]?.count == 1 && b.blacked[0]?.count == 1)
        #expect(a.blacked[0]![0] == b.blacked[0]![0])
        let column = RectD(276, 60, 30, 680)
        Self.sameLine(try Self.inkRows(a.data, column), try Self.inkRows(b.data, column))
    }

    /// The width Helvetica 18 gives `text` on its page (found through the page's text).
    private static func width(_ text: String) throws -> Double { try boxes(page(show(text)), text)[0].width - 2 }

    @Test func rightAlignedAndCentredLinesKeepTheirEdgeNotTheirStart() throws {
        // A right-aligned block (each line ends at 540) and a centred one (each line's middle at 306): with a name of
        // either length redacted, the line comes out the same, still ending at 540, or centred at 306.
        func right(_ text: String, _ y: Double) throws -> String { "BT /F1 18 Tf \(String(format: "%.3f", 540 - (try Self.width(text)))) \(PdfNum.f2(y)) Td (\(text)) Tj ET " }
        func centre(_ text: String, _ y: Double) throws -> String { "BT /F1 18 Tf \(String(format: "%.3f", 306 - (try Self.width(text)) / 2)) \(PdfNum.f2(y)) Td (\(text)) Tj ET " }
        for isRight in [true, false] {
            func place(_ text: String, _ y: Double) throws -> String { isRight ? try right(text, y) : try centre(text, y) }
            func block(_ name: String) throws -> [UInt8] {
                Self.page(try place("Patient: \(name) was seen", 700) + place("Second line of the block", 676) + place("A third one", 652))
            }
            let a = try Self.redact(try block("Robert Kahn"), "Robert Kahn")
            let b = try Self.redact(try block("Bob Kahn"), "Bob Kahn")
            let inkA = try Self.ink(a.data, Self.lineStrip)
            Self.sameLine(inkA, try Self.ink(b.data, Self.lineStrip))
            let runs = Self.runs(inkA)
            let (first, last) = (Double(runs[0].start) / 2 + Self.lineStrip.x, Double(runs[runs.count - 1].end) / 2 + Self.lineStrip.x)
            if isRight {
                #expect(last >= 538 && last <= 542, "\(last)")
            } else {
                #expect((first + last) / 2 >= 304 && (first + last) / 2 <= 308, "\((first + last) / 2)")
            }
        }
    }

    @Test func nothingOfAnAreaMarksWhereTheLineEnded() throws {
        // The area runs from the name to 500 points, far past the line's end, and starts left of the line: what isn't the
        // box is paper, not black, and the shortened line leaves paper behind it (not the black the area left).
        let pdf = Self.page(Self.show("Patient: Robert Kahn"))
        let name = try Self.boxes(pdf, "Robert Kahn")[0]
        let area = RectD.fromEdges(name.x, name.y, 500, name.bottom)
        let r = try Redaction.redact(pdf, nil, [0: [area]], dpi: 144)
        try #require(r.blacked[0]?.count == 1)
        let box = r.blacked[0]![0]
        #expect(box.right < 300, "\(box)")
        let after = RectD(box.right + 1, area.y + 1, 500 - box.right, area.height - 2)
        #expect(try Self.ink(r.data, after).count { $0 } == 0)

        let start = Self.page(Self.show("Patient: Robert Kahn was seen"))
        let whole = RectD.fromEdges(40, name.y, try Self.boxes(start, "Patient:")[0].right, name.bottom) // the area starts left of the line
        let s = try Redaction.redact(start, nil, [0: [whole]], dpi: 144)
        let words = Self.runs(try Self.ink(s.data, Self.lineStrip))
        let end = Double(words[words.count - 1].end) / 2 + Self.lineStrip.x
        #expect(try Self.ink(s.data, RectD(end + 1, name.y + 1, 560 - end, name.height - 2)).count { $0 } == 0)
    }

    @Test func anEarlierRedactionsBoxKeepsItsWidthAndMovesWithItsLine() throws {
        // A box an earlier redaction left between words (40 points), then another word redacted on the line: the earlier
        // box isn't squeezed into the space it sits in, it moves with the line, and Moved says where it went.
        let pdf = Self.page("BT /F1 18 Tf 72 700 Td (Name: ) Tj ET 0 g 130 695 40 18 re f BT /F1 18 Tf 175 700 Td (lives at Main Street now) Tj ET")
        let earlier = RectD(130, 792 - 713, 40, 18)
        let r = try Self.redact(pdf, "Main")
        try #require(r.blacked[0]?.count == 2)
        let kept = try #require(r.blacked[0]!.first { abs($0.width - 40) < 1 })
        #expect(abs(kept.x - r.moved.now(0, earlier).x) < 0.5)
        let runs = Self.runs(try Self.ink(r.data, Self.lineStrip))
        #expect(runs.contains { abs(Double($0.end - $0.start) / 2 - 40) <= 1 }) // still 40 points of black
    }

    @Test func aLineWhoseSpaceHoldsARuleStaysWhereItIs() throws {
        // A table row: a rule between "here" and "and". Laying the line out again would cut and move the rule, so the line
        // stays: the rule and the words after it where they were, the box rounded where it allows, and it isn't recorded
        // as laid out (the check reports it).
        var pdf = Self.page(Self.show("Code    A1 here and B2 there"))
        let code = try Self.boxes(pdf, "Code")[0]
        let a1 = try Self.boxes(pdf, "A1")[0]
        let rule = (code.right + a1.x) / 2
        pdf = Self.page(Self.show("Code    A1 here and B2 there") + "0 g \(PdfNum.f2(rule)) 690 1 30 re f")
        let r = try Self.redact(pdf, "A1")
        for kept in [RectD.fromEdges(code.x - 2, 72, rule + 4, 96), RectD.fromEdges(try Self.boxes(pdf, "here")[0].x, 72, 540, 96)] {
            #expect(Self.differing(try Self.ink(pdf, kept), try Self.ink(r.data, kept)) <= 4, "\(kept) stays")
        }
        let doc = try PdfEdit.openToRead(r.data, nil)
        let image = try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict("PdRedacted"))
        #expect(Redaction.laidOutBoxes(image).isEmpty)
        #expect(!(r.blacked[0] ?? []).isEmpty)
    }

    @Test func aHighlightedLineIsLaidOutAgain() throws {
        // A highlight from the line's first letter to its last: the paper beside the line is white, its spaces yellow. The
        // yellow is the line's background, not a rule or a picture: the line is laid out again (recorded as Inkvolt's, so
        // the check doesn't report its box), and two names leave the same line. Before, it stayed in place and the space
        // after the box still told the name's width.
        func highlighted(_ text: String, rule: Bool = false) throws -> [UInt8] {
            let b = try Self.boxes(Self.page(Self.show(text)), text)[0].inflate(-1)
            let fill = "1 0.85 0.1 rg \(PdfNum.f2(b.x)) \(PdfNum.f2(792 - b.bottom)) \(PdfNum.f2(b.width)) \(PdfNum.f2(b.height)) re f 0 g "
            let was = try Self.boxes(Self.page(Self.show(text)), "was")[0]
            return Self.page(fill + (rule ? "\(PdfNum.f2(was.x - 3)) 690 1 30 re f " : "") + Self.show(text))
        }
        let a = try highlighted("Patient: Robert Kahn was seen on Monday")
        let b = try highlighted("Patient: Bob Kahn was seen on Monday")
        let ra = try Self.redact(a, "Robert Kahn")
        let rb = try Self.redact(b, "Bob Kahn")
        try #require(ra.blacked[0]?.count == 1 && rb.blacked[0]?.count == 1)
        #expect(ra.blacked[0]![0] == rb.blacked[0]![0])
        Self.sameLine(try Self.ink(ra.data, Self.lineStrip), try Self.ink(rb.data, Self.lineStrip))
        let image = try #require(try PdfEdit.openToRead(ra.data, nil).page(0).dict("Resources")?.dict("XObject")?.dict("PdRedacted"))
        #expect(Redaction.laidOutBoxes(image).count == 1)

        // A rule in a highlighted line's space still keeps the line where it is.
        let ruled = try Self.redact(try highlighted("Patient: Robert Kahn was seen on Monday", rule: true), "Robert Kahn")
        let kept = try #require(try PdfEdit.openToRead(ruled.data, nil).page(0).dict("Resources")?.dict("XObject")?.dict("PdRedacted"))
        #expect(Redaction.laidOutBoxes(kept).isEmpty)
    }

    @Test func linesWhoseBandsOverlapAreEachLaidOutFromThePageAsItWas() throws {
        // Tight leading: the bands of the two lines overlap. The second line is laid out from the page as it was, not from
        // the first line's moved pixels in the rows they share: its rows come out exactly as when it is redacted alone.
        let pdf = Self.page("BT /F1 18 Tf 72 700 Td (Alpha Robert Kahn beta) Tj ET BT /F1 18 Tf 72 686 Td (Gamma Bob Kahn delta) Tj ET")
        let first = try Self.boxes(pdf, "Alpha Robert Kahn beta")[0].inflate(-1)
        let second = try Self.boxes(pdf, "Gamma Bob Kahn delta")[0].inflate(-1)
        #expect(second.y < first.bottom - 2, "the bands overlap")
        // Each area over its own line's rows only, so the rows they share hold the same pixels before either is laid out.
        let n1 = try Self.boxes(pdf, "Robert Kahn")[0], n2 = try Self.boxes(pdf, "Bob Kahn")[0]
        let a1 = RectD.fromEdges(n1.x, first.y, n1.right, second.y - 0.5)
        let a2 = RectD.fromEdges(n2.x, first.bottom + 0.5, n2.right, second.bottom)
        let both = try Redaction.redact(pdf, nil, [0: [a1, a2]], dpi: 144)
        let bottom = try Redaction.redact(pdf, nil, [0: [a2]], dpi: 144)
        #expect(both.blacked[0]?.count == 2)
        #expect(try Self.render(both.data, second).pixels == Self.render(bottom.data, second).pixels)
    }

    @Test func aTallAreaIsRowsOfLines() throws {
        // An area over the middle of three lines: each line keeps its words with a rounded box, and between the lines,
        // where the area was, is paper, not black with the area's drawn edges.
        let pdf = Self.page(Self.show("Alpha one two three") + Self.show("Beta four five six", 666) + Self.show("Gamma seven eight", 632))
        let area = RectD.fromEdges(130, 792 - 718, 200, 792 - 626)
        let r = try Redaction.redact(pdf, nil, [0: [area]], dpi: 144)
        #expect(r.blacked[0]?.count == 3)
        #expect((r.blacked[0] ?? []).allSatisfy { $0.height < 30 })
        let bands = try ["Alpha one two three", "Beta four five six", "Gamma seven eight"].map { try Self.boxes(pdf, $0)[0].inflate(-1) }
        for k in 0..<(bands.count - 1) { // the leading between the lines
            let between = RectD.fromEdges(area.x, bands[k].bottom + 1, area.right, bands[k + 1].y - 1)
            #expect(try Self.ink(r.data, between).count { $0 } <= 2, "black between lines \(k + 1) and \(k + 2)")
        }
    }

    @Test func aBlockIsRecordedAsInkvoltsOwn() throws {
        // A block (no text left beside it) is black as drawn, and the picture says so: a check later doesn't call it a leak.
        let pdf = Self.page(Self.show("Alpha one two three") + Self.show("Beta four five six", 676))
        let block = RectD.fromEdges(60, 70, 400, 125)
        let r = try Redaction.redact(pdf, nil, [0: [block]], dpi: 72)
        let doc = try PdfEdit.openToRead(r.data, nil)
        let image = try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict("PdRedacted"))
        let written = Redaction.laidOutBoxes(image)
        try #require(written.count == 1)
        #expect(abs(block.x - written[0].x) <= 0.1)
        #expect(abs(block.width - written[0].width) <= 0.1)
    }
}
