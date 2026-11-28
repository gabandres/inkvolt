import Foundation
import Testing
@testable import PdfCore

/// Roadmap 2.1: paragraphs from other software that mix faces of one family (a bold word in Word's PDFs) or a word in
/// another family edit as one; the standard Symbol and ZapfDingbats fonts (ported from ParagraphEditTests.Mixed.cs).
/// ZapfDingbats is measured with macOS's own font, where Windows reads Adobe's AFM (`ZapfDingbats`).
extension ParagraphEditTests {
    /// Body as a left-aligned paragraph in /FA with `word` drawn in `face` ("FB": Arial Bold, "FT": Times, "FA" itself) at
    /// `size` (default the paragraph's), raised by `rise` (Ts), in the fill operator `fill` (nil: the paragraph's black), a
    /// line under it.
    static func withFace(_ word: String, _ face: String, size: Double = size, standard: String? = nil, rise: Double = 0,
                         fill: String? = nil) -> [UInt8] {
        let lines = wrap(body, width)
        var sb = "BT /FA \(n(Self.size)) Tf \(n(step)) TL \(n(left)) \(n(top)) Td"
        let (raise, lower) = rise == 0 ? ("", "") : (" \(n(rise)) Ts", " 0 Ts")
        let (paint, back) = fill.map { (" \($0)", " 0 g") } ?? ("", "")
        for (i, line) in lines.enumerated() {
            if i > 0 { sb += " T*" }
            if let r = line.range(of: word) {
                sb += " (\(line[..<r.lowerBound])) Tj /\(face) \(n(size)) Tf\(raise)\(paint) (\(word)) Tj\(lower)\(back) /FA \(n(Self.size)) Tf"
                sb += " (\(line[r.upperBound...])) Tj"
            } else {
                sb += " (\(line)) Tj"
            }
        }
        sb += " 0 -60 Td (Next block starts here) Tj ET"
        return ContentEditPdf.make(sb, fontText: chars, faces: true, standard: standard)
    }

    @Test func aParagraphWithABoldWordOfItsOwnFamilyIsOneParagraphWithASpan() throws {
        let pdf = Self.withFace("boxing", "FB")
        let before = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        let boldRun = try Self.run(before, "boxing")
        #expect(boldRun.bold)
        #expect(!p.lead.bold)
        _ = Self.sameSpans([Self.span(Self.body, "boxing", TextLook(bold: true))], p.spans)
        let next = try Self.run(before, "Next block starts here")

        // Rewritten with words in front, the word moves along and stays bold, drawn in the PDF's own bold font.
        let text = "Now then " + Self.body
        let check = p.check(text)
        #expect(check.missing.isEmpty)
        #expect(check.faces.isEmpty) // nothing from this Mac: the page has the face
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited).replacingOccurrences(of: "Next block starts here", with: "")).contains(Self.words(text)))
        let q = try Self.body0(edited, "Now then")
        #expect(q.blocked == nil)
        #expect(q.text == text)
        _ = Self.sameSpans([Self.span(text, "boxing", TextLook(bold: true))], q.spans)
        let bold2 = try #require(q.runs.first { trimmed($0.text) == "boxing" })
        #expect(q.runs.filter { trimmed($0.text) == "boxing" }.count == 1)
        #expect(bold2.bold)
        #expect(bold2.fontName == boldRun.fontName)
        #expect(q.lead.fontName == p.lead.fontName)
        let next2 = try Self.run(try ContentEditor.read(edited, nil, 0), "Next block starts here")
        #expect(Self.equal(next.box.y, next2.box.y, 2))
        #expect(next2.fontName == next.fontName)
    }

    @Test func newBoldTextUsesTheParagraphsOwnBoldFont() throws {
        let pdf = Self.withFace("boxing", "FB")
        let p = try Self.body0(pdf)
        let boldName = try Self.run(try ContentEditor.read(pdf, nil, 0), "boxing").fontName
        let looks = [Self.span(Self.body, "boxing", TextLook(bold: true)), Self.span(Self.body, "quick", TextLook(bold: true)),
                     Self.span(Self.body, "lazy", TextLook(italic: true))]
        let check = p.check(Self.body, spans: looks)
        #expect(check.missing.isEmpty)
        #expect(check.faces == ["Arial Italic"]) // the page has no italic face: that one comes from this Mac
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.body, spans: looks)
        let q = try Self.body0(edited)
        _ = Self.sameSpans(looks, q.spans)
        let runs = Self.byText(q)
        #expect(runs["quick"]?.fontName == boldName)
        #expect(runs["boxing"]?.fontName == boldName)
        #expect(runs["lazy"]?.fontName.contains("Arial Italic") == true)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(Self.body)))
    }

    @Test func aWordInAnotherFamilyIsPartOfTheParagraphAndKeepsThePagesFont() throws {
        // A Times word inside a line of Arial: one paragraph, the word a stretch in its own family.
        let pdf = Self.withFace("sphinx", "FT")
        let before = try ContentEditor.read(pdf, nil, 0)
        let times = try Self.run(before, "sphinx")
        let family = FontNames.family(times.fontName)
        #expect(family == "Times New Roman")
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        #expect(FontNames.family(p.lead.fontName) == "Arial")
        _ = Self.sameSpans([Self.span(Self.body, "sphinx", TextLook(font: family))], p.spans)

        // Rewritten with words in front, the word moves along in the page's own Times, nothing from this Mac.
        let text = "Now then " + Self.body + " " + Self.twenty
        let check = p.check(text)
        #expect(check.missing.isEmpty)
        #expect(check.faces.isEmpty)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited).replacingOccurrences(of: "Next block starts here", with: "")).contains(Self.words(text)))
        let q = try Self.body0(edited, "Now then")
        #expect(q.blocked == nil)
        #expect(q.text == text)
        _ = Self.sameSpans([Self.span(text, "sphinx", TextLook(font: family))], q.spans)
        #expect(q.runs.first { trimmed($0.text) == "sphinx" }?.fontName == times.fontName)
        #expect(q.lead.fontName == p.lead.fontName)
    }

    @Test func textTypedIntoTheOtherFamilyIsWrittenInIt() throws {
        let pdf = Self.withFace("sphinx", "FT")
        let p = try Self.body0(pdf)
        let times = try Self.run(try ContentEditor.read(pdf, nil, 0), "sphinx").fontName
        // "sphinx" becomes "sphinxes": the letters typed onto the word take its look, and Times has them.
        let text = p.text.replacingOccurrences(of: "sphinx", with: "sphinxes")
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(q.runs.first { trimmed($0.text) == "sphinxes" }?.fontName == times)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
    }

    @Test func aLineThatBeginsInAnotherFamilyJoinsTheParagraph() throws {
        let lines = Self.wrap(Self.body, Self.width)
        let word = String(lines[1].split(separator: " ")[0])
        let pdf = Self.withFace(word, "FT")
        let p = try Self.body0(pdf)
        #expect(p.lines.count == lines.count)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        #expect(FontNames.family(p.lead.fontName) == "Arial")
        let text = Self.body + " " + Self.twenty
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(q.runs.first { trimmed($0.text) == word }.map { FontNames.family($0.fontName) } == "Times New Roman")
    }

    @Test func aBiggerWordInTheParagraphsOwnFontIsAStretchOfItsSize() throws {
        let pdf = Self.withFace("boxing", "FA", size: 14)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        #expect(Self.equal(Self.size, p.fontSize, 2)) // its own size, not the bigger word's
        #expect(Self.equal(Self.step, p.lineStep, 0), "\(p.lineStep)") // the line with the bigger word read as the paragraph's own step
        _ = Self.sameSpans([Self.span(Self.body, "boxing", TextLook(size: 14))], p.spans)
        let next = try Self.run(try ContentEditor.read(pdf, nil, 0), "Next block starts here")

        // Rewritten with words in front, the word moves along at its size; the rest stays at the paragraph's.
        let text = "Now then " + Self.body
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited, "Now then")
        #expect(q.blocked == nil)
        #expect(q.text == text)
        _ = Self.sameSpans([Self.span(text, "boxing", TextLook(size: 14))], q.spans)
        let word = try #require(q.runs.first { trimmed($0.text) == "boxing" })
        #expect(q.runs.filter { trimmed($0.text) == "boxing" }.count == 1)
        #expect(Self.equal(14, word.fontSize, 1))
        #expect(q.runs.filter { trimmed($0.text) != "boxing" }.allSatisfy { Self.equal(Self.size, $0.fontSize, 1) })
        #expect(word.fontName == p.lead.fontName)
        for i in 1..<q.lines.count { #expect(q.lines[i].y >= q.lines[i - 1].bottom - 1, "line \(i)") }
        #expect(Self.words(ContentEditPdf.text(edited).replacingOccurrences(of: "Next block starts here", with: "")).contains(Self.words(text)))
        let next2 = try Self.run(try ContentEditor.read(edited, nil, 0), "Next block starts here")
        #expect(Self.equal(next.box.y, next2.box.y, 2))
        #expect(Self.equal(Self.size, next2.fontSize, 2))
    }

    @Test func aWordInAnotherFamilyAndSizeKeepsBoth() throws {
        let pdf = Self.withFace("sphinx", "FT", size: 14)
        let times = try Self.run(try ContentEditor.read(pdf, nil, 0), "sphinx")
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        _ = Self.sameSpans([Self.span(Self.body, "sphinx", TextLook(font: "Times New Roman", size: 14))], p.spans)
        let text = Self.body + " " + Self.twenty
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, allowOverlap: true)
        let q = try Self.body0(edited)
        let word = try #require(q.runs.first { trimmed($0.text) == "sphinx" })
        #expect(q.runs.filter { trimmed($0.text) == "sphinx" }.count == 1)
        #expect(word.fontName == times.fontName)
        #expect(Self.equal(14, word.fontSize, 1))
        _ = Self.sameSpans([Self.span(text, "sphinx", TextLook(font: "Times New Roman", size: 14))], q.spans)
    }

    @Test func aColoredWordKeepsItsColorAsThePageSetIt() throws {
        // "quartz" in CMYK red: a stretch of that color, written again with the page's own CMYK operator, not as RGB.
        let pdf = Self.withFace("quartz", "FA", fill: "0 1 1 0 k")
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.lead.color == 0)
        let red = try Self.run(try ContentEditor.read(pdf, nil, 0), "quartz").color
        #expect(red != 0)
        _ = Self.sameSpans([Self.span(Self.body, "quartz", TextLook(color: red))], p.spans)
        // Letters typed onto the word take its color; words in front move it along.
        let text = "Now then " + Self.body.replacingOccurrences(of: "quartz", with: "quartzite")
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let content = ContentEditPdf.content(edited)
        #expect(content.contains("0 1 1 0 k"))
        #expect(!content.contains(" rg "))
        let q = try Self.body0(edited, "Now then")
        _ = Self.sameSpans([Self.span(text, "quartzite", TextLook(color: red))], q.spans)
        #expect(q.runs.filter { trimmed($0.text) != "quartzite" }.allSatisfy { $0.color == 0 })
        #expect(try Self.run(try ContentEditor.read(edited, nil, 0), "Next block starts here").color == 0)
    }

    @Test func aSmallerWordSetBelowTheLineIsASubscript() throws {
        let pdf = Self.withFace("quartz", "FA", size: 7, rise: -2)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        try #require(p.spans.count == 1, "\(p.spans)")
        let span = p.spans[0]
        let u = Array(Self.body.utf16)
        #expect(String(decoding: u[span.start..<span.end], as: UTF16.self) == "quartz")
        #expect(span.look.script == .sub)
        #expect(Self.equal(-2.0 / Self.size, span.look.rise ?? 0, 2), "\(String(describing: span.look.rise))")
        let text = "Now then " + Self.body
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited, "Now then")
        let sub = try #require(q.runs.first { trimmed($0.text) == "quartz" })
        #expect(Self.equal(7, sub.fontSize, 0), "\(sub.fontSize)")
        let line = try #require(q.runs.first { abs($0.box.centerY - sub.box.centerY) < Self.size && $0.id != sub.id })
        #expect(Self.equal(line.origin.y + 2, sub.origin.y, 0), "\(line.origin.y) \(sub.origin.y)") // still 2 points below its line
        #expect(q.spans.count == 1 && q.spans.first?.look.script == .sub)
    }

    @Test func aBiggerWordSetOffItsLineStillEditsLineByLine() throws {
        let pdf = Self.withFace("sphinx", "FT", size: 14, rise: 1.5)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first { $0.text.contains("sphinx") })
        #expect(p.lines.count > 1)
        #expect(p.blocked?.contains("off its line") == true, "\(p.blocked ?? "nil")")
        #expect(Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, "anything") } != nil)
    }

    @Test func aWordInTheStandardSymbolFontNotEmbeddedIsPartOfTheParagraphAndStaysInIt() throws {
        // /FS is Symbol as old software wrote it, without widths: "sphinx" in it reads σπηινξ (Symbol's own encoding).
        let pdf = Self.withFace("sphinx", "FS", standard: "Symbol")
        let greek = try #require(try ContentEditor.read(pdf, nil, 0).runs.first { $0.fontName == "Symbol" })
        #expect(greek.text == "σπηινξ")
        #expect(greek.blocked == nil)
        let expected: Double = Self.size * Double(603 + 549 + 603 + 329 + 521 + 493) / 1000 // Symbol's own widths (Adobe's, as macOS's Symbol has them)
        #expect(Self.equal(expected, greek.box.width, 1), "\(greek.box.width)")
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        let body = Self.body.replacingOccurrences(of: "sphinx", with: "σπηινξ")
        #expect(p.text == body)

        // Rewritten with words in front and a letter typed onto the word: it moves along in Symbol, the letter too.
        let text = "Now then " + body.replacingOccurrences(of: "σπηινξ", with: "σπηινξα")
        let check = p.check(text)
        #expect(check.missing.isEmpty)
        #expect(check.faces.isEmpty) // nothing from this Mac
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited, "Now then")
        #expect(q.blocked == nil)
        #expect(q.text == text)
        #expect(q.runs.first { trimmed($0.text) == "σπηινξα" }?.fontName == "Symbol")
        #expect(q.lead.fontName == p.lead.fontName)
        #expect(ContentEditPdf.text(edited).contains("σπηινξα")) // MuPDF reads it back the same
    }

    @Test func aWordInStandardZapfDingbatsNotEmbeddedIsPartOfTheParagraphAndStaysInIt() throws {
        // /FS is ZapfDingbats as old software wrote it, without widths: "sphinx" in it is six dingbats (its own encoding),
        // measured with the font's widths.
        let marks = "▲❐❈❉■❘"
        let pdf = Self.withFace("sphinx", "FS", standard: "ZapfDingbats")
        let run = try #require(try ContentEditor.read(pdf, nil, 0).runs.first { $0.fontName == "ZapfDingbats" })
        #expect(run.text == marks)
        #expect(run.blocked == nil)
        #expect(Self.equal(Self.size * Double(892 + 762 + 787 + 713 + 761 + 138) / 1000, run.box.width, 1), "\(run.box.width)")
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        let body = Self.body.replacingOccurrences(of: "sphinx", with: marks)
        #expect(p.text == body)

        // Rewritten with words in front and a check mark typed onto the word: it moves along in ZapfDingbats, the mark too.
        let text = "Now then " + body.replacingOccurrences(of: marks, with: marks + "✔")
        let check = p.check(text)
        #expect(check.missing.isEmpty)
        #expect(check.faces.isEmpty) // nothing from this Mac
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited, "Now then")
        #expect(q.blocked == nil)
        #expect(q.text == text)
        let moved = try #require(q.runs.first { trimmed($0.text) == marks + "✔" })
        #expect(moved.fontName == "ZapfDingbats")
        #expect(Self.equal(Self.size * Double(892 + 762 + 787 + 713 + 761 + 138 + 846) / 1000, moved.box.width, 1), "\(moved.box.width)")
        #expect(q.lead.fontName == p.lead.fontName)
        // MuPDF reads a ZapfDingbats it doesn't embed by its own font's glyphs, not as these characters; it reads the moved
        // word as it read it before, the typed mark after it.
        func word(_ read: String) -> String {
            let s = read.replacingOccurrences(of: "\n", with: " ")
            guard let a = s.range(of: "and a "), let b = s.range(of: " of black") else { return "" }
            return String(s[a.upperBound..<b.lowerBound])
        }
        let was = word(ContentEditPdf.text(pdf))
        #expect(was.count == 6)
        #expect(word(ContentEditPdf.text(edited)).hasPrefix(was))
    }

    @Test func zapfDingbatsMetricsAreAdobes() {
        // Every code of the built-in encoding has a name and a width, and its names their characters.
        #expect((0..<256).filter { ZapfDingbats.name($0) != nil }.count == 202)
        #expect(ZapfDingbats.width("a1") == 974)
        #expect(ZapfDingbats.width("space") == 278)
        #expect(ZapfDingbats.width("A") == nil)
        #expect(ZapfDingbats.text("a20") == "✔")
        #expect(ZapfDingbats.name(128).flatMap(ZapfDingbats.text) == "❨") // a89, a bracket past 127
        #expect(ZapfDingbats.name(0xF0) == nil)
    }

    @Test func aWordInAnotherFamilyWhoseFontCantBeUsedStillEditsLineByLine() throws {
        // The Times word's font isn't there to write it in: rewritten in the paragraph's Arial it would change silently.
        let content = try ContentEditor.read(Self.withFace("sphinx", "FT"), nil, 0)
        let runs = content.runs.map { r -> TextRun in
            var x = r
            if r.text == "sphinx" { x.font = nil }
            return x
        }
        let p = try #require(ContentEditor.groupParagraphs(PageContent(runs: runs, images: content.images)).first { $0.text.contains("sphinx") })
        #expect(p.lines.count > 1)
        #expect(p.blocked != nil)
    }
}
