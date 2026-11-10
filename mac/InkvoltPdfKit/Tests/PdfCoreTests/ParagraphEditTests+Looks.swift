import Foundation
import Testing
@testable import PdfCore

/// Paragraph editing, part c (roadmap 2.1): font, size, color, bold and italic for stretches of a paragraph (ported from
/// ParagraphEditTests.Looks.cs). The look bar's families are Core Text's (Comic Sans MS and Impact ship with macOS too).
extension ParagraphEditTests {
    static func span(_ text: String, _ word: String, _ look: TextLook) -> TextSpan {
        let at = text.utf16.ranges(of: word.utf16).first.map { text.utf16.distance(from: text.utf16.startIndex, to: $0.lowerBound) }
        #expect(at != nil, "\(word)")
        return TextSpan(at ?? 0, word.utf16.count, look)
    }

    /// "quick" bold, "brown" italic and red, "fox" at 16 pt, "lazy dog" in Times New Roman.
    static func looks(_ text: String) -> [TextSpan] {
        [
            span(text, "quick", TextLook(bold: true)),
            span(text, "brown", TextLook(color: 0xCC0000, italic: true)),
            span(text, "fox", TextLook(size: 16)),
            span(text, "lazy dog", TextLook(font: "Times New Roman")),
        ]
    }

    static func sameSpans(_ expected: [TextSpan], _ actual: [TextSpan], _ comment: String = "") -> Bool {
        let e = expected.sorted { $0.start < $1.start }, a = actual.sorted { $0.start < $1.start }
        let ok = e == a
        if !ok { Issue.record("spans differ \(comment): expected \(e), got \(a)") }
        return ok
    }

    /// The runs of a paragraph by their trimmed text (the first of each).
    static func byText(_ p: TextParagraph) -> [String: TextRun] {
        var map: [String: TextRun] = [:]
        for r in p.runs where map[trimmed(r.text)] == nil { map[trimmed(r.text)] = r }
        return map
    }

    static func withoutFrame(_ s: String) -> String {
        s.replacingOccurrences(of: "A Heading Here", with: "").replacingOccurrences(of: "Next block starts here", with: "")
    }

    @Test func theLookBarListsEveryInstalledFamily() {
        let fonts = ContentEditor.lookFonts()
        #expect(fonts.contains("Arial"))
        #expect(fonts.contains("Times New Roman"))
        // Beyond the common families: whatever Core Text lists (Comic Sans MS and Impact ship with macOS).
        #expect(fonts.contains("Comic Sans MS"))
        #expect(fonts.contains("Impact"))
        #expect(fonts == fonts.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(Set(fonts.map { $0.lowercased() }).count == fonts.count)
        // Faces aren't families of their own (macOS has families named so, such as "Arial Rounded MT Bold": they are).
        #expect(!fonts.contains("Arial Bold") && !fonts.contains("Arial Italic") && !fonts.contains("Times New Roman Bold"))
        #expect(!fonts.contains { $0.hasSuffix(" Regular") })
    }

    @Test func aLookInAFamilyBeyondTheFourteenDrawsInIt() throws {
        let (pdf, _) = Self.page(.left, gap: 120)
        let p = try Self.body0(pdf)
        let looks = [
            Self.span(Self.body, "lazy dog", TextLook(font: "Comic Sans MS")),
            Self.span(Self.body, "wizards", TextLook(font: "Comic Sans MS", bold: true)),
            Self.span(Self.body, "sphinx", TextLook(font: "No Such Family")),
        ]
        let check = p.check(Self.body, spans: looks)
        #expect(check.lookProblem == nil)
        #expect(check.missing.isEmpty)
        // A family not installed falls back to the closest installed font, named as such.
        #expect(check.faces == ["Comic Sans MS", "Comic Sans MS Bold", "Arial"])

        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.body, spans: looks)
        #expect(Self.words(Self.body) == Self.words(Self.withoutFrame(ContentEditPdf.text(edited))))
        let q = try Self.body0(edited)
        _ = Self.sameSpans(looks, q.spans)
        let runs = Self.byText(q)
        #expect(runs["lazy dog"]?.fontName.lowercased().contains("comic") == true)
        #expect(runs["wizards"]?.fontName.contains("ComicSansMS Bold") == true)
    }

    @Test func aStretchGetsItsOwnFontSizeColorBoldAndItalic() throws {
        let (pdf, _) = Self.page(.left, gap: 120)
        let p = try Self.body0(pdf)
        let next = try Self.run(try ContentEditor.read(pdf, nil, 0), "Next block starts here")
        var looks = Self.looks(Self.body)
        looks.append(Self.span(Self.body, " boxin", TextLook(italic: true)))
        let check = p.check(Self.body, spans: looks)
        #expect(check.lookProblem == nil)
        #expect(check.missing.isEmpty)
        #expect(check.faces == ["Arial Bold", "Arial Italic", "Times New Roman"])

        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.body, spans: looks)
        #expect(Self.words(Self.body) == Self.words(Self.withoutFrame(ContentEditPdf.text(edited))))
        let q = try Self.body0(edited)
        #expect(q.blocked == nil)
        #expect(q.text == Self.body)
        #expect(p.lead.fontName == q.lead.fontName)
        // A space at a line's end isn't drawn: its look goes with it.
        _ = Self.sameSpans(Array(looks.dropLast()) + [Self.span(Self.body, "boxin", TextLook(italic: true))], q.spans)
        // Read back, the same text and looks lay out as they are.
        let same = q.check(q.text, spans: q.spans)
        #expect(q.lines.count == same.lineCount)
        #expect(same.overlaps == nil)
        let runs = Self.byText(q)
        #expect(runs["quick"]?.fontName.contains("Arial Bold") == true)
        #expect(runs["boxin"]?.fontName.contains("Arial Italic") == true)
        #expect(runs["brown"]?.color == 0xCC0000)
        #expect(runs["fox"].map { Self.equal(16, $0.fontSize, 1) } == true)
        #expect(runs["fox"]?.fontName == p.lead.fontName)
        #expect(runs["lazy dog"]?.fontName.lowercased().contains("times") == true) // one stretch, one operator
        // The rest keeps the paragraph's own color and size; the lines don't run into each other; what follows stays.
        #expect(q.runs.filter { !["brown", "fox"].contains(trimmed($0.text)) }.allSatisfy { $0.color == p.lead.color })
        for i in 1..<q.lines.count { #expect(q.lines[i].y >= q.lines[i - 1].bottom - 1, "line \(i)") }
        #expect(q.lines[0].y >= p.box.y - 0.5, "the first line stays inside the box's top")
        let next2 = try Self.run(try ContentEditor.read(edited, nil, 0), "Next block starts here")
        #expect(Self.equal(next.box.y, next2.box.y, 2))
        #expect(next2.color == p.lead.color)
        #expect(Self.equal(p.fontSize, next2.fontSize, 2))
        #expect(next2.fontName == p.lead.fontName)
    }

    @Test func typingAgainKeepsTheLooksOfWhatDidntChange() throws {
        let (pdf, _) = Self.page(.left, gap: 120)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, try Self.body0(pdf), Self.body, spans: Self.looks(Self.body))
        let q = try Self.body0(edited)
        // Text typed without looks: the stretches around the change keep theirs.
        let text = q.text.replacingOccurrences(of: "jumps", with: "leaps high") + " and more words at the end"
        let again = try ContentEditor.replaceParagraph(edited, nil, q, text)
        let r = try Self.body0(again)
        #expect(r.text == text)
        _ = Self.sameSpans(Self.looks(text), r.spans)
        // The same text and looks: nothing to write.
        #expect(try ContentEditor.replaceParagraph(again, nil, r, r.text) == again)
    }

    @Test func theLooksAloneCanChangeAndBeTakenOff() throws {
        let (pdf, _) = Self.page(.justified, gap: 120)
        let p = try Self.body0(pdf)
        let bold = [Self.span(Self.body, "black quartz", TextLook(size: 13, bold: true))]
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.body, spans: bold)
        let q = try Self.body0(edited)
        #expect(q.align == .justified)
        #expect(q.lines.dropLast().allSatisfy { Self.equal(p.box.right, $0.right, 0) })
        _ = Self.sameSpans(bold, q.spans)
        // Taken off: plain again, at the old line step.
        let plain = try ContentEditor.replaceParagraph(edited, nil, q, q.text, spans: [])
        let r = try Self.body0(plain)
        #expect(r.spans.isEmpty)
        #expect(r.runs.allSatisfy { $0.fontName == p.lead.fontName })
        #expect(Self.equal(p.lineStep, r.lineStep, 1))
        #expect(r.lines.count == p.lines.count)
    }

    @Test(arguments: [ParagraphAlign.left, .justified])
    func allOfItInAnotherFontIsStillOneParagraphDrawnALineAtATime(_ align: ParagraphAlign) throws {
        let (pdf, _) = Self.page(align, gap: 120)
        let p = try Self.body0(pdf)
        let georgia = TextLook(font: "Georgia")
        let all = [TextSpan(0, Self.body.utf16.count, georgia)]
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.body, spans: all)
        let q = try Self.body0(edited)
        #expect(q.blocked == nil)
        #expect(q.align == align)
        _ = Self.sameSpans(all, q.spans)
        // One operator a line (words, spaces and justification together), not one a word.
        #expect(q.runs.count >= q.lines.count && q.runs.count <= q.lines.count + 1, "\(q.runs.count) runs on \(q.lines.count) lines")
        #expect(Self.words(Self.body) == Self.words(Self.withoutFrame(ContentEditPdf.text(edited))))
        if align == .justified { #expect(q.lines.dropLast().allSatisfy { Self.equal(p.box.right, $0.right, 0) }) }
        // Edited again: more words, still all Georgia.
        let text = Self.body + " " + Self.twenty
        let again = try Self.body0(try ContentEditor.replaceParagraph(edited, nil, q, text))
        #expect(again.text == text)
        _ = Self.sameSpans([TextSpan(0, text.utf16.count, georgia)], again.spans)
    }

    @Test func aColorOverASpotInkIsSetBackAfterwardsAndOverAPatternRefused() throws {
        let lines = Self.wrap(Self.body, Self.width)
        func make(_ color: String) -> String {
            var sb = "\(color) BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 72 \(Self.n(Self.top)) Td (\(lines[0])) Tj"
            for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
            return sb + " 0 -60 Td (Next block starts here) Tj ET"
        }
        let spot = ContentEditPdf.make(make("/CS0 cs 0.5 scn"), fontText: Self.chars)
        let looks = [Self.span(Self.body, "quick", TextLook(color: 0x0000FF))]
        let edited = try ContentEditor.replaceParagraph(spot, nil, try Self.body0(spot), Self.body, spans: looks)
        let content = ContentEditPdf.content(edited)
        #expect(content.range(of: #"0 0 1 rg[\s\S]*/CS0 cs 0\.5 scn[\s\S]*Next block"#, options: .regularExpression) != nil)

        let pattern = ContentEditPdf.make(make("/Pattern cs /P1 scn"), fontText: Self.chars)
        let p = try Self.body0(pattern)
        #expect(p.check(Self.body, spans: looks).lookProblem != nil)
        #expect(Self.editError { try ContentEditor.replaceParagraph(pattern, nil, p, Self.body, spans: looks) } != nil)
        // Other looks are fine there.
        _ = try ContentEditor.replaceParagraph(pattern, nil, p, Self.body, spans: [Self.span(Self.body, "quick", TextLook(bold: true))])
    }

    // ---- Hyphenated line ends and kerning (ParagraphEditTests.Lines.cs) ----

    /// A left-aligned paragraph of the given lines (one text object, T* between them), with a line under it.
    static func linesPdf(_ lines: [String], fontText: String = chars, unicode: Bool = false) -> [UInt8] {
        func show(_ s: String) -> String { unicode ? ContentEditPdf.cid(s, fontText: fontText) : "(\(s))" }
        var sb = "BT /\(unicode ? "FU" : "FA") \(n(size)) Tf \(n(step)) TL \(n(left)) \(n(top)) Td \(show(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* \(show(l)) Tj" }
        sb += " 0 -60 Td \(show("Next block starts here")) Tj ET"
        return ContentEditPdf.make(sb, fontText: fontText)
    }

    @Test func aHyphenatedLineEndStaysOneWordWhenRewrapped() throws {
        let pdf = Self.linesPdf(["The quick brown fox is respon-", "sible for the lazy dog and the", "five boxing wizards too"])
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == "The quick brown fox is respon-sible for the lazy dog and the five boxing wizards too")
        // Words added in front move the word along: it stays "respon-sible", never split at the hyphen or given a space.
        let text = "Now then " + p.text
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains("respon-sible"))
        #expect(try Self.body0(edited, "Now then").text == text)
    }

    @Test func aSoftHyphenALineBreakAddedIsDropped() throws {
        // Some generators write the hyphen a line break added as U+00AD (a Unicode font's ToUnicode says so): it isn't
        // part of the word.
        let pdf = Self.linesPdf(["The quick brown fox is respon\u{AD}", "sible for the lazy dog and the", "five boxing wizards too"],
                                fontText: Self.chars + "\u{AD}", unicode: true)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == "The quick brown fox is responsible for the lazy dog and the five boxing wizards too")
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Now then " + p.text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains("responsible"))
        #expect(try Self.body0(edited, "Now then").text == "Now then " + p.text)
    }

    @Test func kerningOfTheOriginalLinesIsKeptWhereThePairSurvives() throws {
        // The generator kerned "fo" by -40, "ov" and "vo" by -25 (TJ adjustments inside words); the word gaps are plain spaces.
        func kerned(_ line: String) -> String {
            "[(" + line.replacingOccurrences(of: "fo", with: "f) -40 (o").replacingOccurrences(of: "ov", with: "o) -25 (v")
                .replacingOccurrences(of: "vo", with: "v) -25 (o") + ")] TJ"
        }
        let lines = Self.wrap(Self.body, Self.width)
        var sb = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL \(Self.n(Self.left)) \(Self.n(Self.top)) Td \(kerned(lines[0]))"
        for l in lines.dropFirst() { sb += " T* \(kerned(l))" }
        sb += " 0 -60 Td (Next block starts here) Tj ET"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        let text = "Now then " + p.text + " for the fox"
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let content = ContentEditPdf.content(edited)
        // "fox" moved along its line, and "for" and "fox" were typed at the end: each pair keeps its kerning; "vow" and "over" too.
        #expect(Self.count(#"f\) -40 \(o"#, in: content) == 3)
        #expect(Self.count(#"o\) -25 \(v"#, in: content) == 1) // "over"
        #expect(Self.count(#"v\) -25 \(o"#, in: content) == 1) // "vow"
        #expect(try Self.body0(edited, "Now then").text == text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
        // Lines without the pair get no adjustment of theirs.
        let plain = try ContentEditor.replaceParagraph(pdf, nil, p, "No such pairs in here at all")
        #expect(!ContentEditPdf.content(plain).contains("-40"))
    }

    @Test func theOneRunEditorKernsTheChangedMiddleLikeTheRestOfTheRun() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td [(Hel) -30 (lo World)] TJ ET")
        let r = try Self.run(try ContentEditor.read(pdf, nil, 0), "Hello World")
        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hello Hello")
        let content = ContentEditPdf.content(edited)
        // The kept start keeps its adjustment as before; the typed "Hello" gets the same pair kerned.
        #expect(content.contains("[(Hel) -30 (lo Hel) -30 (lo)] TJ"), "\(content)")
        #expect(ContentEditPdf.text(edited).contains("Hello Hello"))
    }
}
