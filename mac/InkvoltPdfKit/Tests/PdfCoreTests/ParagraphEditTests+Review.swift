import Foundation
import Testing
@testable import PdfCore

/// Roadmap 2.1 on the Mac, review round 1 (2026-11-10): cases the port got wrong that Windows' tests don't cover.
extension ParagraphEditTests {
    // ---- 1. A form drawn twice, close together ----

    @Test func aFormDrawnTwiceCloseTogetherIsTwoParagraphsAndEachEditsAlone() throws {
        // A one-line form drawn twice 14 pt apart: the two drawings line up as a paragraph would, but they are two pieces
        // of content (one operator draws both), so each is a paragraph of its own.
        let line = "A single line of text drawn by a form"
        let form = "BT /FA \(Self.n(Self.size)) Tf 72 700 Td (\(line)) Tj ET"
        let pdf = ContentEditPdf.make("q /Fm1 Do Q q 1 0 0 1 0 -14 cm /Fm1 Do Q", form: form, fontText: Self.chars)
        let paras = try ContentEditor.read(pdf, nil, 0).paragraphs.filter { $0.text.contains("single line") }.sorted { $0.box.y < $1.box.y }
        #expect(paras.count == 2)
        #expect(paras.allSatisfy { $0.lines.count == 1 && $0.blocked == nil })
        guard paras.count == 2 else { return }
        let edited = try ContentEditor.replaceParagraph(pdf, nil, paras[1], "Changed text in the lower one")
        let after = try ContentEditor.read(edited, nil, 0).paragraphs.sorted { $0.box.y < $1.box.y }.map(\.text)
        #expect(after == [line, "Changed text in the lower one"])
    }

    @Test func overlappingEditsOfOneStreamAreRefusedNotSpliced() {
        let content = Array("BT /F1 12 Tf (Hello) Tj ET".utf8)
        #expect(throws: ContentEditError.self) { try ContentEditor.splice(content, [(13, 20, [65]), (15, 23, [66])]) }
        #expect((try? ContentEditor.splice(content, [(13, 20, [65])])) != nil)
    }

    // ---- 2. Characters only a font without outlines has ----

    @Test func anEmojiOnlyAColorFontHasIsRefusedNotDrawnBlank() throws {
        // Apple Color Emoji has bitmaps only: a stand-in drawn from it would be an empty Type 3 glyph.
        let (pdf, _) = Self.page(.left)
        let p = try Self.body0(pdf)
        let check = p.check(Self.body + " 😀")
        #expect(check.missing == ["😀"])
        #expect(check.borrowed.isEmpty)
        let r = try Self.run(try ContentEditor.read(pdf, nil, 0), "Next block starts here")
        #expect(r.check("Next block 😀").missing == ["😀"])
        // In a look's family too: the family has no emoji, and the system's emoji font has no outlines.
        let looked = p.check(Self.body + " 😀", spans: [TextSpan(Self.body.utf16.count + 1, 2, TextLook(font: "Georgia"))])
        #expect(looked.missing == ["😀"])
    }

    // ---- 3. Huge paragraphs ----

    @Test func twentyThousandCharactersLayOutInAMoment() throws {
        let big = String(repeating: Self.body + " ", count: 115) // about 20,000 characters
        #expect(big.utf16.count > 20_000)
        let (pdf, _) = Self.page(.left)
        let p = try Self.body0(pdf)
        var started = Date()
        let check = p.check(big)
        let wrapped = Date().timeIntervalSince(started)
        #expect(check.lineCount > 300)
        // A line that doesn't wrap (a paragraph of one line) takes it all on one line.
        let one = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first { $0.text == "Next block starts here" })
        started = Date()
        let single = one.check(big)
        let unwrapped = Date().timeIntervalSince(started)
        #expect(single.lineCount == 1)
        #expect(wrapped < 3 && unwrapped < 3, "wrapped \(wrapped) s, one line \(unwrapped) s")
    }

    // ---- 4. Word spacing over stand-in glyphs ----

    @Test func aJustifiedRunWithManyBorrowedCharactersKeepsTheirWidths() throws {
        // 40 characters the subset lacks: the Type 3 stand-in's codes reach 32, which Tw would widen as a space.
        let pdf = ContentEditPdf.make("BT /FA 12 Tf 6 Tw 72 700 Td (Hello World) Tj ET BT /FA 9 Tf 0 Tw 72 600 Td (draft) Tj ET")
        let r = try Self.run(try ContentEditor.read(pdf, nil, 0), "Hello World")
        let text = "Hello αβγδεζηθικλμνξοπρστυφχψωАБВГДЕЖЗИЙКЛМНОП"
        let check = r.check(text)
        #expect(check.missing.isEmpty && check.borrowed.count == 40)
        let edited = try ContentEditor.replaceText(pdf, nil, r, text)
        let line = try #require(try Core2Pdf.lines(edited).first { $0.text.contains("αβγ") })
        #expect(abs(line.box.width - check.width) < 1, "drawn \(line.box.width) pt, laid out \(check.width) pt")
        #expect(Self.words(ContentEditPdf.text(edited)).contains(text))
    }

    // ---- 5. The anchor in a form is its first line ----

    @Test func aParagraphInAFormIsWrittenWhereItsFirstLineWas() throws {
        // A background drawn between the first line and the rest: the new text is written where the first line's
        // operator was, before it, as on the page.
        let lines = Self.wrap(Self.body, Self.width)
        var form = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 72 \(Self.n(Self.top)) Td (\(lines[0])) Tj ET 0.9 g 60 500 320 180 re f 0 g"
        form += " BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 72 \(Self.n(Self.top - Self.step)) Td (\(lines[1])) Tj"
        for l in lines.dropFirst(2) { form += " T* (\(l)) Tj" }
        form += " ET"
        let pdf = ContentEditPdf.make("q /Fm1 Do Q", form: form, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.twenty + " " + Self.body)
        let stream = try Self.formStream(edited)
        let text = try #require(stream.range(of: "Then seven"))
        let background = try #require(stream.range(of: " re f"))
        #expect(text.lowerBound < background.lowerBound)
        #expect(try Self.body0(edited, "Then seven").text == Self.twenty + " " + Self.body)
    }

    // ---- Found again by its place ----

    @Test func aParagraphFoundAgainByItsPlaceIsLaidOutInTheEditedFilesFonts() throws {
        // An edit above it adds operators (a stand-in for "@"), so the paragraph's runs have other ids now: found again by
        // their text and place, they must carry the new reading's fonts.
        let (pdf, _) = Self.page(.left)
        let stale = try Self.body0(pdf)
        let heading = try Self.run(try ContentEditor.read(pdf, nil, 0), "A Heading Here")
        let edited = try ContentEditor.replaceText(pdf, nil, heading, "A Heading @ Here")
        let doc = try Core2Pdf.open(edited)
        let page = doc.page(0)
        let walked = try ContentEditor.walk(doc, page, 0, ContentLexer.parse(ContentEditor.contentBytes(page)), nil)
        let (now, fresh) = try ContentEditor.rematch(stale, walked)
        #expect(now.map(\.id) != stale.runs.map(\.id), "the ids moved")
        #expect(fresh.runs.allSatisfy { r in r.font.map { walked.fontDicts[ObjectIdentifier($0)] != nil } == true })
        let again = try ContentEditor.replaceParagraph(edited, nil, stale, Self.body + " " + Self.twenty)
        #expect(try Self.body0(again).text == Self.body + " " + Self.twenty)
    }
}
