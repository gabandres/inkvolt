import Foundation
import Testing
@testable import PdfCore

/// Ported from ExportFormTests.cs, every test: export fixes found on a typeset form (TeX-style accents, dot leaders in a
/// font that names its dot "ogonek", labels under fill-in lines, boxed tables drawn with a 1 pt frame, item numbers at
/// the top of each page). Adapted: the Open XML SDK's validator and reader are stood in for by `OpenXmlPackage` (see
/// ExportTests).
struct ExportFormTests {
    private static let look = ExportSpan("", "Serif", 7.5, false, false, 0, .zero)
    private typealias X = OpenXmlPackage

    /// Glyphs of `text` from x, each `advance` wide, top at y (size 7.5, box 7.5 tall).
    private func glyphs(_ text: String, _ x: Double, _ y: Double, _ advance: Double = 3.5) -> [ExportGlyph] {
        var x = x
        return text.map { c in
            defer { x += advance }
            return ExportGlyph(String(c), RectD(x, y, advance, 7.5), Self.look)
        }
    }

    private func accent(_ accent: String, _ x: Double, _ y: Double) -> ExportGlyph { ExportGlyph(accent, RectD(x, y, 0.1, 7.5), Self.look) }

    private func text(_ line: [ExportGlyph]) -> String { line.map(\.text).joined() }

    private func line(_ text: String, _ x: Double, _ y: Double, _ size: Double = 7.5) -> ExportLine {
        let box = RectD(x, y, Double(text.utf16.count) * size * 0.5, size)
        return .of([ExportSpan(text, "Serif", size, false, false, 0, box)])
    }

    private static let dot = String(Character(ExportGlyphs.dotLeader))
    private static let rule = String(Character(ExportGlyphs.lineLeader))

    @Test func anAccentSetOverItsLetterJoinsItAndTheSpaceMuPdfSawBeforeItGoes() throws {
        // "Direcci" " " "´" "on": the accent has no width and sits over the "o", which starts where the "i" ended (the
        // space is the kern back, read as a gap).
        var line = glyphs("Direcci", 100, 100)
        let iEnd = line[line.count - 1].rect.right
        line.append(ExportGlyph(" ", RectD(iEnd, 100, 1.6, 7.5), Self.look))
        line.append(accent("\u{B4}", iEnd + 1.6, 96.5))
        line += glyphs("on", iEnd - 0.1, 100)
        let one = ExportGlyphs.compose([line])
        try #require(one.count == 1)
        #expect(text(one[0]) == "Dirección")

        // "en" " " "´" "areas": a real space between the words stays.
        var words = glyphs("en", 100, 100)
        let nEnd = words[words.count - 1].rect.right
        words.append(ExportGlyph(" ", RectD(nEnd, 100, 2.5, 7.5), Self.look))
        words.append(accent("\u{B4}", nEnd + 4, 96.5))
        words += glyphs("areas", nEnd + 2.3, 100)
        #expect(text(ExportGlyphs.compose([words])[0]) == "en áreas")

        // A dotless i takes the accent as i; a tilde makes ñ.
        var dia = glyphs("D", 100, 100)
        dia.append(accent("\u{B4}", 104.5, 96.5))
        dia += glyphs("\u{131}a", 103.5, 100)
        var ano = glyphs("A", 120, 100)
        ano.append(accent("\u{2DC}", 125.5, 96.5))
        ano += glyphs("no", 123.5, 100)
        // A circumflex or caron (letters to .NET) goes onto its letter, not onto itself.
        var fete = glyphs("f", 140, 100)
        fete.append(accent("\u{2C6}", 145.3, 96.5))
        fete += glyphs("ete", 143.5, 100)
        #expect(ExportGlyphs.compose([dia, ano, fete]).map(text) == ["Día", "Año", "fête"])

        // An accent with a width of its own (TeX's \accent) over its letter joins it; one standing between two letters
        // ("don´t") doesn't.
        var wide = glyphs("caf", 100, 140)
        wide.append(ExportGlyph("\u{B4}", RectD(110.5, 137, 3.75, 7.5), Self.look))
        wide += glyphs("e", 110.5, 140)
        #expect(text(ExportGlyphs.compose([wide])[0]) == "café")
        var apostrophe = glyphs("don", 100, 160)
        apostrophe.append(ExportGlyph("\u{B4}", RectD(110.5, 160, 2.5, 7.5), Self.look))
        apostrophe += glyphs("t", 113, 160)
        #expect(text(ExportGlyphs.compose([apostrophe])[0]) == "don\u{B4}t")
    }

    @Test func aCapitalsAccentReadAsALineOfItsOwnGoesOntoItsLetter() {
        // MuPDF splits "PREDICACIÓN" into "PREDICACI", the accent raised by most of the size alone, and "ON".
        let before = glyphs("PREDICACI", 100, 100, 6)
        let accentLine = [accent("\u{B4}", before[before.count - 1].rect.right + 3, 100 - 0.85 * 7.5)]
        let after = glyphs("ON", before[before.count - 1].rect.right, 100, 6)
        #expect(ExportGlyphs.compose([before, accentLine, after]).map(text) == ["PREDICACI", "", "ÓN"])
    }

    @Test func runsOfDotsOrARepeatedAccentBecomeOneLeaderAndShortRunsStayText() throws {
        var label = glyphs("Name: ", 100, 100)
        let x = label[label.count - 1].rect.right
        // The form's font names its leader dot "ogonek": 40 of them.
        label += (0..<40).map { ExportGlyph("\u{2DB}", RectD(x + Double($0) * 2, 104, 2, 1), Self.look) }
        let composed = ExportGlyphs.compose([label])
        try #require(composed.count == 1)
        #expect(text(composed[0]) == "Name: " + Self.dot)
        #expect(abs(composed[0][composed[0].count - 1].rect.right - (x + 80)) < 0.001) // the leader spans the run

        // An ellipsis in a sentence ("say . . . . then", dots and spaces 0.25 em each) or dots between letters stay text;
        // a long run of dots is a leader.
        #expect(text(ExportGlyphs.compose([glyphs("say . . . . then", 100, 120, 1.9)])[0]) == "say . . . . then")
        #expect(text(ExportGlyphs.compose([glyphs("wait....then", 100, 120)])[0]) == "wait....then")
        let toc = glyphs("Introduction . . . . . . . . . . . . 5", 100, 120)
        #expect(text(ExportGlyphs.compose([toc])[0]) == "Introduction " + Self.dot + " 5")
        // A rule typed in a monospaced font is text.
        let mono = glyphs("+----------+", 100, 140).map { g in
            var g = g
            g.look.mono = true
            return g
        }
        #expect(text(ExportGlyphs.compose([mono])[0]) == "+----------+")
        #expect(text(ExportGlyphs.compose([glyphs("Sign ___", 100, 140)])[0]) == "Sign ___")
        #expect(text(ExportGlyphs.compose([glyphs("Sign ______", 100, 140)])[0]) == "Sign " + Self.rule)
    }

    @Test func aLoneAccentThatDrawsTwoBarsIsAnEqualsSign() {
        // 8 px per point, size 7.5: two 30 px bars 3 px thick, 8 px apart, as "=" draws.
        let w = 40, h = 60
        var alpha = [UInt8](repeating: 0, count: w * h)
        for top in [24, 35] { for y in top..<top + 3 { for x in 5..<35 { alpha[y * w + x] = 255 } } }
        #expect(ExportGlyphs.drawnAs(alpha, w, h, 8, 7.5) == "=")

        // A diaeresis in a wide font: two dots side by side on the same rows, not a bar.
        var dots = [UInt8](repeating: 0, count: w * h)
        for y in 10..<14 { for x0 in [6, 28] { for x in x0..<x0 + 6 { dots[y * w + x] = 255 } } }
        #expect(ExportGlyphs.drawnAs(dots, w, h, 8, 7.5) == nil)

        // A dot accent: a small blob.
        var dot = [UInt8](repeating: 0, count: w * h)
        for y in 10..<16 { for x in 17..<23 { dot[y * w + x] = 255 } }
        #expect(ExportGlyphs.drawnAs(dot, w, h, 8, 7.5) == nil)

        var line = glyphs("M ", 100, 100)
        line.append(ExportGlyph("\u{2D9}", RectD(107, 100, 5, 7.5), Self.look))
        line += glyphs(" Morning", 112, 100)
        #expect(ExportGlyphs.isLoneAccent(line, 2))
        #expect(!ExportGlyphs.isLoneAccent(glyphs("a\u{2D9}b", 100, 100), 1))
    }

    @Test func aFrameBoundedWithRoomForMiteredCornersIsTakenInToMeetItsRules() {
        // The frame drawn at 54..558 x 377..512, bounded 11 pt wider all round; rules inside run from frame to frame.
        let paths: [(box: RectD, stroked: Bool)] = [
            (RectD.fromEdges(43, 366, 569, 523), true),
            (RectD.fromEdges(54, 397, 558, 397.6), true),
            (RectD.fromEdges(54, 465, 558, 465.6), true),
            (RectD.fromEdges(155, 465, 155.6, 512), true),
            (RectD.fromEdges(256, 465, 256.6, 512), true),
        ]
        let rules = DocLayout.rulesFromPaths(paths)
        #expect(rules.filter { $0.width < 1 && $0.height > 100 }.map { bankers($0.x) }.sorted() == [54, 558])
        #expect(rules.contains { abs($0.y - 377) < 0.5 && $0.height == 0 })

        // One line inset in a box (a signature line) leaves the box as drawn.
        let boxed = DocLayout.rulesFromPaths([(RectD.fromEdges(100, 100, 300, 160), true), (RectD.fromEdges(110, 140, 290, 140.5), true)])
        #expect(boxed.contains { $0.width == 0 && abs($0.x - 100) < 0.01 })

        // A frame and rules only, crossing in a grid with a few labels in it: a form's boxes, not a chart.
        let labels = [line("Monday", 70, 470), line("Tuesday", 170, 470), line("Days you can serve:", 200, 380)]
        let more = paths + (0..<8).map { (box: RectD(357 + Double($0) * 25, 465, 0.6, 47), stroked: true) }
        #expect(DocLayout.figureRegions(more, labels, 612, 792).isEmpty)

        // A line chart: gridlines and a data line (a stroked polyline running through the grid) is still a figure.
        var chart: [(box: RectD, stroked: Bool)] = []
        for k in 0...5 {
            chart.append((RectD(100, 400 + Double(k) * 30, 300, 0.5), true))
            chart.append((RectD(100 + Double(k) * 60, 400, 0.5, 150), true))
        }
        chart.append((RectD.fromEdges(112, 418, 377, 532), true))
        #expect(DocLayout.figureRegions(chart, [line("2020", 100, 556), line("2025", 380, 556)], 612, 792).count == 1)
    }

    @Test func labelsSideBySideAreOneParagraphWithTabStopsAndALeaderIsADottedTab() throws {
        let lines = [
            ExportLine.of([
                ExportSpan("1. Name: ", "Serif", 7.5, false, false, 0, RectD(58, 100, 50, 7.5)),
                ExportSpan(Self.dot, "Serif", 8.5, false, false, 0, RectD.fromEdges(110, 104, 558, 105)),
            ]),
            line("(Last name)", 178, 110, 6), line("(First name)", 317, 110, 6), line("(Middle name)", 461, 110, 6),
            line("Signature follows here.", 58, 200, 7.5),
        ]
        let paras = DocLayout.analyze([ExportPage(612, 792, lines, [], [])])[0].paragraphs
        try #require(paras.count == 3)

        let name = paras[0]
        #expect(name.text == "1. Name: \t")
        try #require(name.tabs.count == 1)
        #expect(name.tabs[0].right)
        #expect(name.tabs[0].leader == ".")
        #expect(abs(name.tabs[0].position - (558 - 58)) < 0.05)

        let labels = paras[1]
        #expect(labels.text == "(Last name)\t(First name)\t(Middle name)")
        let labelStops: [Double] = labels.tabs.map { bankers($0.position * 10) / 10 }
        #expect(labelStops == [259.0, 403.0]) // 317 - 58, 461 - 58
        #expect(abs(labels.indent - (178 - 58)) < 0.05)
        #expect((paras[2].spaceBefore ?? 0) > 60) // the gap down to the next line is kept

        let sink = MemorySink()
        try DocumentExport.writeDocx(sink, [ExportPage(612, 792, lines, [], [])], "Form")
        let package = try OpenXmlPackage(sink.bytes)
        #expect(try package.validate().isEmpty)
        let doc = try WordDoc(sink.bytes)
        let body = X.children(doc.body, "w:p")
        let stops = X.elements(body[0], "w:tab").filter { X.attr($0, "w:pos") != nil }
        try #require(stops.count == 1)
        #expect(X.attr(stops[0], "w:leader") == "dot")
        #expect(X.attr(stops[0], "w:val") == "right")
        #expect(X.elements(body[1], "w:r").flatMap { X.children($0, "w:tab") }.count == 2)
        #expect(package.parts["word/fontTable.xml"] != nil)
    }

    @Test func aRuleWithTextAfterItEndsWhereTheTextStartsAndLineSpacingIsNotParagraphSpacing() throws {
        let row = ExportLine.of([
            ExportSpan("Signature ", "Serif", 9, false, false, 0, RectD(58, 100, 45, 9)),
            ExportSpan(Self.rule, "Serif", 9, false, false, 0, RectD.fromEdges(103, 100, 300, 109)),
            ExportSpan(" Date ", "Serif", 9, false, false, 0, RectD(300, 100, 30, 9)),
            ExportSpan(Self.rule, "Serif", 9, false, false, 0, RectD.fromEdges(330, 100, 500, 109)),
        ])
        // Then a paragraph set at 1.5 lines (12 pt type, 18 pt apart), and one more after it, 18 pt down again.
        var lines = [row]
        let text = "Spaced text that runs over three lines of the page in a paragraph"
        for k in 0..<3 { lines.append(line(text, 58, 200 + Double(k) * 18, 12)) }
        lines.append(line("1. The next one", 58, 254, 12))
        let paras = DocLayout.analyze([ExportPage(612, 792, lines, [], [])])[0].paragraphs
        try #require(paras.count == 3)
        #expect(paras[0].tabs.map(\.right) == [false, true])
        let positions: [Double] = paras[0].tabs.map(\.position)
        #expect(positions == [242.0, 442.0]) // 300 - 58, 500 - 58
        #expect(paras[0].tabs.map(\.leader) == ["_", "_"])
        #expect(abs(paras[1].linePitch - 18) < 0.001)
        #expect((0...5).contains(paras[2].spaceBefore ?? -1)) // 18 pt from the last line's top: one line, no gap
    }

    @Test func twoProseColumnsOnOneRowAreNotJoinedWithTabs() {
        let left = "Left column text runs on here as a paragraph"
        let right = "Right column text runs on here as another one"
        var lines: [ExportLine] = []
        for k in 0..<4 {
            lines.append(line(left, 72, 100 + Double(k) * 10, 8))
            lines.append(line(right, 330, 100 + Double(k) * 10, 8))
        }
        let page = DocLayout.analyze([ExportPage(612, 792, lines, [], [])])[0]
        #expect(page.paragraphs.allSatisfy { !$0.text.contains("\t") })
    }

    @Test func anItemNumberAtTheTopOfEachPageBesideItsTextIsNotARunningHeader() throws {
        let pages = (0..<2).map { n in
            ExportPage(612, 792, [
                line("1.", 58, 62), line(n == 0 ? "Name: the first item of the form" : "Is the applicant a willing helper?", 72, 62),
                line("More text further down the page", 58, 300),
                line("S-73 9/19", 54, 762),
            ], [], [])
        }
        let result = DocLayout.analyzeDocument(pages)
        #expect(result.header == nil)
        let footer = try #require(result.footer)
        try #require(footer.rows.count == 1 && footer.rows[0].parts.count == 1)
        #expect(footer.rows[0].parts[0].span.text == "S-73 9/19")
        #expect(result.pages.allSatisfy { $0.paragraphs.first?.text.hasPrefix("1. ") == true })
    }

    @Test func textInTwoCellsSetCloseTogetherStaysInItsCellsAndBoxedTablesStayApart() throws {
        // A ruled header row: "Overseer" in two neighboring cells, 8 pt apart (closer than a column gap).
        var rules: [RectD] = []
        for y in [100.0, 130, 160] { rules.append(RectD(54, y, 300, 0)) }
        for x in [54.0, 154, 254, 354] { rules.append(RectD(x, 100, 0, 60)) }
        var lines = [line("Overseer", 100, 110), line("Overseer", 162, 110), line("Notes", 270, 110)]
        // A second boxed table right under it.
        for y in [180.0, 200, 220] { rules.append(RectD(54, y, 300, 0)) }
        for x in [54.0, 204, 354] { rules.append(RectD(x, 180, 0, 40)) }
        lines.append(line("Saturday", 70, 185))
        lines.append(line("Sunday", 220, 185))
        let pageIn = ExportPage(612, 792, lines, [], rules)
        let tables = DocLayout.analyze([pageIn])[0].tables
        try #require(tables.count == 2)
        #expect(tables[0].rows[0].map(\.text) == ["Overseer", "Overseer", "Notes"])
        #expect(tables[0].rowHeights == [30, 30])

        let sink = MemorySink()
        try DocumentExport.writeDocx(sink, [pageIn], "Tables")
        #expect(try OpenXmlPackage(sink.bytes).validate().isEmpty)
        let doc = try WordDoc(sink.bytes)
        let kids = (doc.body.children ?? []).compactMap { $0 as? XMLElement }
        let first = try #require(kids.firstIndex { $0.name == "w:tbl" })
        #expect(kids[first + 1].name == "w:p") // Word would join two tables that touch
        #expect(doc.tables.count == 2)
        let height = X.elements(X.children(doc.tables[0], "w:tr")[0], "w:trHeight").first
        #expect(X.attr(height, "w:val") == "600")
    }
}
