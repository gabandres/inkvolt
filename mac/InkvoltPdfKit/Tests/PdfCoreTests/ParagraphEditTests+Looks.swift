import Foundation
import Testing
@testable import PdfCore

/// Ported from ParagraphEditTests.Looks.cs (paragraph editing, part c, roadmap 2.1): font, size, color, bold and italic
/// for stretches of a paragraph; all 6 cases, in the same suite. Adapted: a face's font is read back by its PostScript
/// name in the Type 3 font's descriptor ("Arial-BoldMT", "Arial-ItalicMT", "TimesNewRomanPSMT"), where Windows reads its
/// subset's file name ("arialbd", "ariali", "times").
extension ParagraphEditTests {
    private typealias T = ParagraphEditTests

    private static func span(_ text: String, _ word: String, _ look: TextLook) -> TextSpan {
        let r = text.range(of: word)
        #expect(r != nil, "\(word)")
        let at = r.map { text.utf16.distance(from: text.utf16.startIndex, to: $0.lowerBound.samePosition(in: text.utf16)!) } ?? 0
        return TextSpan(at, word.utf16.count, look)
    }

    /// "quick" bold, "brown" italic and red, "fox" at 16 pt, "lazy dog" in Times New Roman.
    private static func looks(_ text: String) -> [TextSpan] {
        [
            span(text, "quick", TextLook(bold: true)),
            span(text, "brown", TextLook(color: 0xCC0000, italic: true)),
            span(text, "fox", TextLook(size: 16)),
            span(text, "lazy dog", TextLook(font: "Times New Roman")),
        ]
    }

    private static func sameSpans(_ expected: [TextSpan], _ actual: [TextSpan]) -> Bool {
        expected.sorted { $0.start < $1.start } == actual.sorted { $0.start < $1.start }
    }

    private static func bodyOnly(_ pdf: [UInt8]) -> String {
        T.words(T.text(pdf).replacingOccurrences(of: "A Heading Here|Next block starts here", with: "", options: .regularExpression))
    }

    @Test func aStretchGetsItsOwnFontSizeColorBoldAndItalic() throws {
        let (pdf, _) = T.page(.left, gap: 120)
        let p = try T.body0(pdf)
        let next = try T.runNamed(try ContentEditor.read(pdf, nil, 0), "Next block starts here")
        var looks = Self.looks(T.body)
        looks.append(Self.span(T.body, " boxin", TextLook(italic: true)))
        let check = p.check(T.body, looks)
        #expect(check.lookProblem == nil)
        #expect(check.missing.isEmpty)
        #expect(check.faces == ["Arial Bold", "Arial Italic", "Times New Roman"])

        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, T.body, spans: looks)
        #expect(Self.bodyOnly(edited) == T.words(T.body))
        let q = try T.body0(edited)
        #expect(q.blocked == nil)
        #expect(q.text == T.body)
        #expect(q.lead.fontName == p.lead.fontName)
        // A space at a line's end isn't drawn: its look goes with it.
        #expect(Self.sameSpans(looks.dropLast() + [Self.span(T.body, "boxin", TextLook(italic: true))], q.spans), "\(q.spans)")
        // Read back, the same text and looks lay out as they are.
        let same = q.check(q.text, q.spans)
        #expect(same.lineCount == q.lines.count)
        #expect(same.overlaps == nil)
        var runs: [String: TextRun] = [:]
        for r in q.runs where runs[r.text.trimmingCharacters(in: .whitespaces)] == nil { runs[r.text.trimmingCharacters(in: .whitespaces)] = r }
        #expect(runs["quick"]?.fontName.contains("Arial-Bold") == true, "\(runs["quick"]?.fontName ?? "-")")
        #expect(runs["boxin"]?.fontName.contains("Arial-Italic") == true, "\(runs["boxin"]?.fontName ?? "-")")
        #expect(runs["brown"]?.color == 0xCC0000)
        #expect(T.equal(16, runs["fox"]?.fontSize ?? 0, 1))
        #expect(runs["fox"]?.fontName == p.lead.fontName)
        #expect(runs["lazy dog"]?.fontName.range(of: "times", options: .caseInsensitive) != nil) // one stretch, one operator
        // The rest keeps the paragraph's own color and size; the lines don't run into each other; what follows stays.
        for r in q.runs where !["brown", "fox"].contains(r.text.trimmingCharacters(in: .whitespaces)) {
            #expect(r.color == p.lead.color, "\(r.text)")
        }
        for i in 1..<q.lines.count { #expect(q.lines[i].y >= q.lines[i - 1].bottom - 1, "line \(i)") }
        #expect(q.lines[0].y >= p.box.y - 0.5, "the first line stays inside the box's top")
        let next2 = try T.runNamed(try ContentEditor.read(edited, nil, 0), "Next block starts here")
        #expect(T.equal(next.box.y, next2.box.y, 2))
        #expect(next2.color == p.lead.color)
        #expect(T.equal(p.fontSize, next2.fontSize, 2))
        #expect(next2.fontName == p.lead.fontName)
    }

    @Test func typingAgainKeepsTheLooksOfWhatDidntChange() throws {
        let (pdf, _) = T.page(.left, gap: 120)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, try T.body0(pdf), T.body, spans: Self.looks(T.body))
        let q = try T.body0(edited)
        // Text typed without looks: the stretches around the change keep theirs.
        let text = q.text.replacingOccurrences(of: "jumps", with: "leaps high") + " and more words at the end"
        let again = try ContentEditor.replaceParagraph(edited, nil, q, text)
        let r = try T.body0(again)
        #expect(r.text == text)
        #expect(Self.sameSpans(Self.looks(text), r.spans), "\(r.spans)")
        // The same text and looks: nothing to write.
        #expect(try ContentEditor.replaceParagraph(again, nil, r, r.text) == again)
    }

    @Test func theLooksAloneCanChangeAndBeTakenOff() throws {
        let (pdf, _) = T.page(.justified, gap: 120)
        let p = try T.body0(pdf)
        let look = Self.span(T.body, "black quartz", TextLook(size: 13, bold: true))
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, T.body, spans: [look])
        let q = try T.body0(edited)
        #expect(q.align == .justified)
        #expect(q.lines.dropLast().allSatisfy { T.equal(p.box.right, $0.right, 0) })
        #expect(Self.sameSpans([look], q.spans), "\(q.spans)")
        // Taken off: plain again, at the old line step.
        let plain = try ContentEditor.replaceParagraph(edited, nil, q, q.text, spans: [])
        let r = try T.body0(plain)
        #expect(r.spans.isEmpty)
        #expect(r.runs.allSatisfy { $0.fontName == p.lead.fontName && !$0.standIn })
        #expect(T.equal(p.lineStep, r.lineStep, 1))
        #expect(r.lines.count == p.lines.count)
    }

    @Test(arguments: [ParagraphAlign.left, .justified])
    func allOfItInAnotherFontIsStillOneParagraphDrawnALineAtATime(_ align: ParagraphAlign) throws {
        let (pdf, _) = T.page(align, gap: 120)
        let p = try T.body0(pdf)
        let georgia = TextLook(font: "Georgia")
        let all = TextSpan(0, T.body.utf16.count, georgia)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, T.body, spans: [all])
        let q = try T.body0(edited)
        #expect(q.blocked == nil)
        #expect(q.align == align)
        #expect(Self.sameSpans([all], q.spans), "\(q.spans)")
        // One operator a line (words, spaces and justification together), not one a word.
        #expect(q.runs.count >= q.lines.count && q.runs.count <= q.lines.count + 1, "\(q.runs.count) runs, \(q.lines.count) lines")
        #expect(Self.bodyOnly(edited) == T.words(T.body))
        if align == .justified { #expect(q.lines.dropLast().allSatisfy { T.equal(p.box.right, $0.right, 0) }) }
        // Edited again: more words, still all Georgia.
        let text = T.body + " " + T.twenty
        let again = try T.body0(try ContentEditor.replaceParagraph(edited, nil, q, text))
        #expect(again.text == text)
        #expect(Self.sameSpans([TextSpan(0, text.utf16.count, georgia)], again.spans), "\(again.spans)")
    }

    @Test func aColorOverASpotInkIsSetBackAfterwardsAndOverAPatternRefused() throws {
        let lines = T.wrap(T.body, T.width)
        func make(_ color: String) -> String {
            var sb = "\(color) BT /FA \(T.n(T.size)) Tf \(T.n(T.step)) TL 72 \(T.n(T.top)) Td (\(lines[0])) Tj"
            for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
            return sb + " 0 -60 Td (Next block starts here) Tj ET"
        }
        let spot = T.make(make("/CS0 cs 0.5 scn"))
        let looks = [Self.span(T.body, "quick", TextLook(color: 0x0000FF))]
        let edited = try ContentEditor.replaceParagraph(spot, nil, try T.body0(spot), T.body, spans: looks)
        let content = ContentEditPdf.content(edited)
        #expect(content.range(of: #"0 0 1 rg[\s\S]*/CS0 cs 0\.5 scn[\s\S]*Next block"#, options: .regularExpression) != nil)

        let pattern = T.make(make("/Pattern cs /P1 scn"))
        let p = try T.body0(pattern)
        #expect(p.check(T.body, looks).lookProblem != nil)
        #expect(throws: ContentEditError.self) { try ContentEditor.replaceParagraph(pattern, nil, p, T.body, spans: looks) }
        // Other looks are fine there.
        _ = try ContentEditor.replaceParagraph(pattern, nil, p, T.body, spans: [Self.span(T.body, "quick", TextLook(bold: true))])
    }
}
