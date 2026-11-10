import Foundation
import Testing
@testable import PdfCore

/// Roadmap 2.1: paragraphs from other software that mix faces of one family (a bold word in Word's PDFs) or a word in
/// another family edit as one; the standard Symbol and ZapfDingbats fonts (ported from ParagraphEditTests.Mixed.cs).
/// ZapfDingbats is measured with macOS's own font, where Windows reads Adobe's AFM (`ZapfDingbats`).
extension ParagraphEditTests {
    /// Body as a left-aligned paragraph in /FA with `word` drawn in `face` ("FB": Arial Bold, "FT": Times, "FA" itself) at
    /// `size` (default the paragraph's), a line under it.
    static func withFace(_ word: String, _ face: String, size: Double = size, standard: String? = nil) -> [UInt8] {
        let lines = wrap(body, width)
        var sb = "BT /FA \(n(Self.size)) Tf \(n(step)) TL \(n(left)) \(n(top)) Td"
        for (i, line) in lines.enumerated() {
            if i > 0 { sb += " T*" }
            if let r = line.range(of: word) {
                sb += " (\(line[..<r.lowerBound])) Tj /\(face) \(n(size)) Tf (\(word)) Tj /FA \(n(Self.size)) Tf (\(line[r.upperBound...])) Tj"
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

    @Test func anotherSizeOnALineStillEditsLineByLine() throws {
        // Two sizes on one baseline: the paragraph's lines group, but rewrapped the bigger word couldn't keep its place.
        let pdf = Self.withFace("sphinx", "FT", size: 14)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first { $0.text.contains("sphinx") })
        #expect(p.lines.count > 1)
        #expect(p.blocked?.contains("mixes fonts") == true)
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
