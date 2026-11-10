import Foundation
import Testing
@testable import PdfCore

/// Ported from ParagraphEditTests.cs (with its .Looks, .Lines, .Mixed, .Forms, .Turned and .PdfJs parts): Edit Text &
/// Images, paragraphs (roadmap 2.1): a page's lines grouped into paragraphs with their alignment and line step, and a
/// paragraph's text replaced, rewrapped in its box in its own embedded font, characters it lacks from installed fonts,
/// looks for stretches, text in form XObjects, turned text. Same names, the theories' rows as arguments. Adapted: the
/// fonts are `ContentEditPdf`'s hand-made subsets of the Mac's Arial, Arial Bold and Times New Roman; stand-in fonts are
/// Type 3 fonts named by family and style ("Arial,Bold", read "Arial Bold", where Windows' file name says "arialbd"); the
/// stand-in families are the Mac's (`StandInFonts`); "this PC" is "this Mac"; ZapfDingbats is measured with macOS's own
/// font. The corpus and pdf.js checks are opt-in as on Windows (INKVOLTPDF_CORPUS, INKVOLTPDF_PDFJS).
struct ParagraphEditTests {
    /// What the test fonts hold: no "@", "#" or "€".
    static let chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?'-"

    static let size = 11.0, step = 14.0, width = 300.0, left = 72.0, top = 700.0 // PDF user space (y up)

    static let body = "The quick brown fox jumps over the lazy dog while five boxing wizards jump quickly and a sphinx of black "
        + "quartz judges my vow of silence on a calm and quiet evening by the river"

    static let twenty = "Then seven tired hikers walked along the narrow path toward the old stone bridge before the rain came at last"

    static func n(_ v: Double) -> String { PdfNum.f(v) }

    /// xUnit's `Assert.Equal(expected, actual, precision)`: equal when rounded to `decimals`.
    static func equal(_ a: Double, _ b: Double, _ decimals: Int) -> Bool {
        let f = pow(10.0, Double(decimals))
        return (a * f).rounded(.toNearestOrEven) == (b * f).rounded(.toNearestOrEven)
    }

    static func near(_ a: RectD, _ b: RectD, _ d: Double = 0.01) -> Bool {
        abs(a.x - b.x) < d && abs(a.y - b.y) < d && abs(a.width - b.width) < d && abs(a.height - b.height) < d
    }

    private static let probe: TextRun = try! ContentEditor.read(
        ContentEditPdf.make("BT /FA \(n(size)) Tf 72 700 Td (a) Tj ET", fontText: chars), nil, 0).runs[0]

    /// The width of text in /FA at `size` (points), as the editor measures it.
    static func measure(_ text: String) -> Double { probe.check(text).width }

    /// Greedy word wrap at `width`, as a typesetter does.
    static func wrap(_ text: String, _ width: Double, _ firstIndent: Double = 0) -> [String] {
        var lines: [String] = []
        var cur = ""
        for word in text.split(separator: " ").map(String.init) {
            let room = width - (lines.isEmpty ? firstIndent : 0)
            if !cur.isEmpty && measure(cur + " " + word) > room {
                lines.append(cur)
                cur = word
            } else {
                cur = cur.isEmpty ? word : cur + " " + word
            }
        }
        lines.append(cur)
        return lines
    }

    /// A page: a heading, `body` as a paragraph aligned as asked, and a line of text `gap` points under the paragraph's
    /// last baseline. Left text is written the way many generators do: one text object, T* from line to line, the next
    /// block placed relative to it (Td), so the edit has to leave the text position right.
    static func page(_ align: ParagraphAlign, gap: Double = 60, body: String = body, indent: Double = 0) -> (pdf: [UInt8], lines: [String]) {
        let lines = wrap(body, width, indent)
        var sb = "BT /FA 16 Tf 72 740 Td (A Heading Here) Tj ET\n"
        let lastY: Double = top - Double(lines.count - 1) * step
        if align == .left {
            sb += "BT /FA \(n(size)) Tf \(n(step)) TL \(n(left + indent)) \(n(top)) Td (\(lines[0])) Tj \(n(-indent)) 0 Td"
            for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
            sb += " 0 \(n(-gap)) Td (Next block starts here) Tj ET\n"
        } else {
            for (i, line) in lines.enumerated() {
                let w = measure(line)
                let y: Double = top - Double(i) * step
                let x: Double = align == .right ? left + width - w : align == .center ? left + (width - w) / 2 : left
                let spaces = line.filter { $0 == " " }.count
                let tw: Double = align == .justified && i < lines.count - 1 && spaces > 0 ? (width - w) / Double(spaces) : 0
                sb += "BT /FA \(n(size)) Tf \(n(tw)) Tw \(n(x)) \(n(y)) Td (\(line)) Tj ET\n"
            }
            sb += "BT /FA \(n(size)) Tf 0 Tw \(n(left)) \(n(lastY - gap)) Td (Next block starts here) Tj ET\n"
        }
        return (ContentEditPdf.make(sb, fontText: chars), lines)
    }

    static func body0(_ pdf: [UInt8], _ start: String = "The quick") throws -> TextParagraph {
        let found = try ContentEditor.read(pdf, nil, 0).paragraphs.filter { $0.text.hasPrefix(start) }
        #expect(found.count == 1, "\(found.count) paragraphs start with “\(start)”")
        return try #require(found.first)
    }

    /// Text with its white space made single spaces and ligatures spelled out (MuPDF reads "ﬁ" as "fi").
    static func words(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func run(_ content: PageContent, _ text: String) throws -> TextRun {
        let runs = content.runs.filter { $0.text == text }
        #expect(runs.count == 1, "\(runs.count) runs read “\(text)”")
        return try #require(runs.first)
    }

    static func editError(_ body: () throws -> Any) -> ContentEditError? {
        do {
            _ = try body()
        } catch let e as ContentEditError {
            return e
        } catch {
            Issue.record("unexpected \(error)")
        }
        return nil
    }

    static func count(_ pattern: String, in s: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
    }

    // ---- Grouping ----

    @Test(arguments: [ParagraphAlign.left, .right, .center, .justified])
    func linesGroupIntoAParagraphWithItsAlignmentAndLineStep(_ align: ParagraphAlign) throws {
        let (pdf, lines) = Self.page(align)
        #expect(lines.count >= 3)
        let content = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        #expect(lines.count == p.lines.count)
        #expect(align == p.align)
        #expect(abs(p.lineStep - Self.step) <= 0.1)
        #expect(p.box.x >= Self.left - 1 && p.box.x <= Self.left + Self.width)
        #expect(p.box.right >= Self.left && p.box.right <= Self.left + Self.width + 1)
        // The heading and the block below are paragraphs of their own; the block below is what the paragraph would grow into.
        #expect(content.paragraphs.count == 3)
        let next = try Self.run(content, "Next block starts here")
        #expect(p.below.map { Self.near($0, next.box) } == true)
        // A click anywhere on the paragraph's text, or between its lines, finds it.
        #expect(content.paragraphAt(p.lines[1].x + 5, p.lines[1].y + 3)?.text == p.text)
        #expect(content.paragraphAt(p.lines[0].x + 2, (p.lines[0].bottom + p.lines[1].y) / 2)?.text == p.text)
    }

    @Test func aFirstLineIndentIsKeptAndLinesThatEndShortSplitParagraphs() throws {
        // Two left-aligned paragraphs at one line step: the first's last line ends short, the second starts flush.
        let first = Self.wrap(Self.body, Self.width, 24)
        let second = Self.wrap(Self.twenty, Self.width)
        var sb = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 96 \(Self.n(Self.top)) Td (\(first[0])) Tj -24 0 Td"
        for l in first.dropFirst() + second { sb += " T* (\(l)) Tj" }
        sb += " ET"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let paras = try ContentEditor.read(pdf, nil, 0).paragraphs
        #expect(paras.map(\.text) == [Self.body, Self.twenty])
        #expect(paras[0].firstIndent >= 23.5 && paras[0].firstIndent <= 24.5)
        #expect(paras[0].align == .left)
        #expect(paras[1].firstIndent == 0)

        // Rewritten, the indent stays.
        let edited = try ContentEditor.replaceParagraph(pdf, nil, paras[0], "Short new text for the first paragraph that still wraps onto a second line at this width")
        let again = try #require(try ContentEditor.read(edited, nil, 0).paragraphs.first)
        #expect(again.firstIndent >= 23.5 && again.firstIndent <= 24.5)
        #expect(again.lines[0].x >= 95.5 && again.lines[0].x <= 96.5)
    }

    @Test func textOfOtherSizesOrFontsIsNotJoined() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 11 Tf 72 700 Td (One line of body text here) Tj ET\nBT /FA 9 Tf 72 686 Td (smaller text under it) Tj ET\n"
                + "BT /FT 11 Tf 72 672 Td (other font text) Tj ET", fontText: Self.chars, faces: true)
        #expect(try ContentEditor.read(pdf, nil, 0).paragraphs.count == 3)
    }

    // ---- Rewriting ----

    @Test(arguments: [ParagraphAlign.left, .right, .center, .justified])
    func twentyWordsAddedReflowInOrderAndNothingOverlapsTheNextBlock(_ align: ParagraphAlign) throws {
        let (pdf, lines) = Self.page(align, gap: 120)
        let before = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        let next = try Self.run(before, "Next block starts here")
        let heading = try Self.run(before, "A Heading Here")
        let text = Self.body + " " + Self.twenty
        #expect(Self.twenty.split(separator: " ").count == 20)

        let check = p.check(text)
        #expect(check.missing.isEmpty)
        #expect(check.overlaps == nil)
        #expect(check.lineCount > lines.count)
        #expect(check.box.bottom < next.box.y)

        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        // Read back by MuPDF in order, the words all there; the old text gone.
        let extracted = Self.words(ContentEditPdf.text(edited))
        #expect(extracted.contains(Self.words(text)))
        #expect(Self.count("quick brown", in: extracted) == 1)

        let after = try ContentEditor.read(edited, nil, 0)
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(q.align == align)
        #expect(q.lines.count == check.lineCount)
        #expect(abs(q.lineStep - Self.step) <= 0.1)
        #expect(q.box.x >= p.box.x - 1 && q.box.x <= p.box.right)
        #expect(q.box.right <= p.box.right + 0.5, "\(q.box.right) > \(p.box.right)")
        // What follows stays where it was (in the left case it is placed relative to the paragraph's text).
        let next2 = try Self.run(after, "Next block starts here")
        #expect(Self.equal(next.box.x, next2.box.x, 2))
        #expect(Self.equal(next.box.y, next2.box.y, 2))
        #expect(Self.near(heading.box, try Self.run(after, "A Heading Here").box))
        #expect(q.lines.allSatisfy { $0.bottom < next2.box.y })
        for l in try Core2Pdf.lines(edited) where l.text.contains("Next block") {
            #expect(trimmed(l.text) == "Next block starts here")
        }
        if align == .center { #expect(q.lines.allSatisfy { Self.equal(p.box.centerX, $0.centerX, 1) }) }
        if align == .right { #expect(q.lines.allSatisfy { Self.equal(p.box.right, $0.right, 1) }) }
    }

    @Test func shorterTextShrinksTheParagraph() throws {
        let (pdf, _) = Self.page(.justified)
        let p = try Self.body0(pdf)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "The quick end.")
        let q = try Self.body0(edited)
        #expect(q.lines.count == 1)
        #expect(q.text == "The quick end.")
        #expect(Self.equal(p.lines[0].x, q.lines[0].x, 1)) // the last (only) line of justified text starts left
    }

    @Test func aLineBreakStartsANewLine() throws {
        let (pdf, _) = Self.page(.left)
        let p = try Self.body0(pdf)
        let check = p.check("First line\r\nsecond line")
        #expect(check.lineCount == 2)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "First line\nsecond line")
        #expect(ContentEditPdf.text(edited).replacingOccurrences(of: "\r", with: "").contains("First line\nsecond line"))
    }

    @Test func runningIntoTheBlockBelowIsReportedBeforeAnythingIsWritten() throws {
        let (pdf, _) = Self.page(.left, gap: 28)
        let p = try Self.body0(pdf)
        let text = Self.body + " " + Self.twenty + " " + Self.twenty // three lines more, where there is room for one
        let check = p.check(text)
        #expect(check.overlaps != nil)
        #expect(check.overlaps == p.below)
        let e = Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, text) }
        #expect(e?.overlaps != nil)
        #expect(e?.message.contains("run into what follows") == true)

        // Confirmed, it is written anyway (the caller warned).
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, allowOverlap: true)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(Self.twenty)))
        // A shorter text that fits doesn't warn.
        #expect(p.check(String(Self.body.prefix(40))).overlaps == nil)
    }

    @Test func charactersNoFontHereHasAreRefusedByName() throws {
        let (pdf, _) = Self.page(.justified)
        let p = try Self.body0(pdf)
        let none = "\u{10FFFD}" // private use: no installed font draws it
        let text = Self.body + " mail me @ home " + none
        let check = p.check(text)
        #expect(check.missing == [none])
        let e = Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, text) }
        #expect(e?.missing == [none])
        #expect(e?.message.contains("U+10FFFD") == true)
        #expect(e?.message.contains("any font on this Mac") == true)
    }

    // ---- Characters the embedded subset lacks (part b) ----

    @Test(arguments: ["FA", "FU"])
    func charactersTheSubsetLacksComeFromTheClosestInstalledFont(_ key: String) throws {
        // The subset is Arial's: the stand-in is Arial itself, named; the rest stays in the paragraph's own font.
        func show(_ s: String) -> String { key == "FA" ? "(\(s))" : ContentEditPdf.cid(s, fontText: Self.chars) }
        let lines = Self.wrap(Self.body, Self.width)
        var sb = "BT /\(key) \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 72 \(Self.n(Self.top)) Td \(show(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* \(show(l)) Tj" }
        sb += " 0 -80 Td " + show("Next block starts here") + " Tj ET"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        let text = Self.body + " mail me @ home #1 for €5"
        let check = p.check(text)
        #expect(check.missing.isEmpty)
        #expect(check.borrowed == ["@", "#", "€"])
        #expect(check.standIns == ["Arial"])
        #expect(check.overlaps == nil)

        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
        let after = try ContentEditor.read(edited, nil, 0)
        let q = try Self.body0(edited)
        #expect(q.blocked == nil)
        #expect(q.text == text)
        #expect(p.lead.fontName == q.lead.fontName)
        // Only the borrowed characters are in the stand-in font, at the paragraph's size and color.
        let borrowed = q.runs.filter { $0.fontName != p.lead.fontName }
        #expect(borrowed.map(\.text) == ["@", "#", "€"], "\(borrowed.map { "\($0.text) \($0.fontName)" })")
        #expect(borrowed.allSatisfy { $0.fontName.lowercased().contains("arial") })
        #expect(borrowed.allSatisfy { Self.equal(p.fontSize, $0.fontSize, 1) })
        // Glyph boxes in order on the line: nothing drawn over its neighbors.
        let line = try #require(try Core2Pdf.lines(edited).first { $0.text.contains("@") })
        for i in 1..<line.chars.count { #expect(line.chars[i].box.x >= line.chars[i - 1].box.x - 0.01, "\(line.text) at \(i)") }
        // What follows is still in the paragraph's font (the font is set back after each stand-in).
        let next = try Self.run(after, "Next block starts here")
        #expect(next.fontName == p.lead.fontName)

        // Edited again, the borrowed characters are part of the paragraph.
        let again = try ContentEditor.replaceParagraph(edited, nil, q, q.text.replacingOccurrences(of: "@ home", with: "@ work") + " @ last")
        let r2 = try Self.body0(again)
        #expect(r2.blocked == nil)
        #expect(r2.text.hasSuffix("for €5 @ last"))
        #expect(Self.words(ContentEditPdf.text(again)).contains("mail me @ work"))
        #expect(Self.equal(next.box.y, try Self.run(try ContentEditor.read(again, nil, 0), "Next block starts here").box.y, 2))
    }

    @Test func borrowedCharactersKeepCharacterSpacingAndJustification() throws {
        let lines = Self.wrap(Self.body, Self.width)
        var sb = ""
        for (i, line) in lines.enumerated() {
            let w = Self.measure(line)
            let spaces = Double(line.filter { $0 == " " }.count)
            let tw: Double = i < lines.count - 1 ? (Self.width - w) / spaces : 0
            sb += "BT /FA \(Self.n(Self.size)) Tf \(Self.n(tw)) Tw \(Self.n(Self.left)) \(Self.n(Self.top - Double(i) * Self.step)) Td (\(line)) Tj ET\n"
        }
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.align == .justified)
        let text = "Write to me @ the office #4 or the lab #5 " + Self.body
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let q = try Self.body0(edited, "Write")
        #expect(q.text == text)
        #expect(q.align == .justified)
        // Every line but the last reaches the right edge, stand-ins and all.
        #expect(q.lines.dropLast().allSatisfy { Self.equal(p.box.right, $0.right, 0) })
    }

    @Test func theStandInMatchesTheFontsClassWeightAndSlant() {
        // Fonts not installed, described by their names and descriptor flags (2 serif, 1 fixed pitch, 64 italic). The
        // Mac's families stand in for Windows' (Palatino, Baskerville and Hoefler Text; Menlo and Andale Mono).
        func pick(_ name: String, _ flags: Int = 32) -> String { StandInFonts.rankFor(Self.looseFont(name, flags))[0].name }
        #expect(pick("Helvetica-Oblique") == "Arial Italic")
        #expect(pick("ABCDEF+TimesNewRomanPS-BoldMT") == "Times New Roman Bold")
        let serif = ["Times New Roman Bold Italic", "Georgia Bold Italic", "Palatino Bold Italic", "Baskerville Bold Italic", "Hoefler Text Bold Italic"]
        #expect(serif.contains(pick("ABCDEF+Garamondish-BoldItalic", 2 | 32 | 64)))
        #expect(["Courier New", "Menlo", "Andale Mono"].contains(pick("ABCDEF+Unknownmono", 1 | 32)))
        #expect(["Arial", "Helvetica Neue", "Verdana", "Tahoma", "Trebuchet MS", "Gill Sans"].contains(pick("ABCDEF+Unknownsans", 32)))
    }

    @Test func amongItsClassTheStandInIsTheOneWithTheClosestWidths() {
        // A sans font with Verdana's widths (wide) and one with Arial's: each gets the installed font they came from.
        for (file, expected) in [("verdana.ttf", "Verdana"), ("arial.ttf", "Arial"), ("tahoma.ttf", "Tahoma")] {
            guard let tt = SystemFonts.get(file) else { continue }
            let widths = (32..<127).map { Int((tt.advance(UInt32($0)) * 1000).rounded()) }
            #expect(StandInFonts.rankFor(Self.looseFont("ABCDEF+Someface", 32, widths))[0].name == expected)
        }
    }

    /// A non-embedded simple font with a descriptor: its name, flags and (from 32 on) widths, else 500 each.
    static func looseFont(_ name: String, _ flags: Int, _ widths: [Int]? = nil) -> TextFont {
        let doc = try! MuDoc.create()
        let descriptor = doc.dict([("Type", doc.name("FontDescriptor")), ("FontName", doc.name(name)), ("Flags", doc.int(flags))])
        let w = doc.array((0..<95).map { doc.int(widths?[$0] ?? 500) })
        let font = doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("TrueType")), ("BaseFont", doc.name(name)),
            ("Encoding", doc.name("WinAnsiEncoding")), ("FirstChar", doc.int(32)), ("LastChar", doc.int(126)), ("Widths", w),
            ("FontDescriptor", descriptor),
        ])
        return TextFont(font)
    }

    @Test func newCharactersTheFontHasButThePdfDidntUseCopyAsTyped() throws {
        // The subset holds "Z" and "q", but the page's text never used them before.
        let (pdf, _) = Self.page(.left, body: "Some plain words in a line that wraps around to the next one at this width of the box here")
        let p = try Self.body0(pdf, "Some plain")
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Zebra quietly zigzags past the quay, then quits.")
        #expect(Self.words(ContentEditPdf.text(edited)).contains("Zebra quietly zigzags past the quay, then quits."))
    }

    @Test func aTwoByteFontParagraphReflowsToo() throws {
        let lines = Self.wrap(Self.body, Self.width)
        func cid(_ s: String) -> String { ContentEditPdf.cid(s, fontText: Self.chars) }
        var sb = "BT /FU \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 72 \(Self.n(Self.top)) Td \(cid(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* \(cid(l)) Tj" }
        sb += " ET"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        let text = Self.body + " " + Self.twenty
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
        #expect(try Self.body0(edited).text == text)
    }

    @Test func signedFilesGetTheParagraphEditAppended() throws {
        let placeholder = "[0 0000000000 0000000000 0000000000]"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 750 272 780] /V 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange \(placeholder) /Contents <"
                + String(repeating: "0", count: Core2SignatureTests.contentsHexLength) + "> >>",
            RedactionTestPdf.stream("BT /F1 12 Tf 14 TL 72 700 Td (This agreement is made between the two parties named) Tj T* "
                + "(below, who agree to the terms set out in the pages that) Tj T* (follow this one.) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        let pdf = try Core2SignatureTests.sign(RedactionTestPdf.build(objects), placeholder, cn: "CN=Signer")
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        #expect(try ContentEditor.read(pdf, nil, 0).paragraphs.count == 1)
        #expect(p.lines.count == 3)
        #expect(p.blocked == nil)
        let text = p.text.replacingOccurrences(of: "two parties", with: "three parties")
        let (edited, report) = try SignedEdits.run { try ContentEditor.replaceParagraph(pdf, nil, p, text) }
        #expect(report.appended)
        #expect(report.removedItemKept)
        #expect(Array(edited.prefix(pdf.count)) == pdf)
        #expect(Self.words(ContentEditPdf.text(edited)).contains("three parties"))
    }

    // ---- Review of part a: the edges ----

    /// Body's lines as a left-aligned paragraph drawn through `prefix` (a cm and/or text matrix set-up) with "Next block
    /// starts here" placed relative to it; `tm` starts the first line.
    static func drawn(_ tm: String, prefix: String = "", suffix: String = "", rotate: Int = 0, extra: String = "") -> [UInt8] {
        let lines = wrap(body, width)
        var sb = "\(prefix) BT /FA \(n(size)) Tf \(extra) \(n(step)) TL \(tm) (\(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
        sb += " 0 -60 Td (Next block starts here) Tj ET \(suffix)"
        return ContentEditPdf.make(sb, rotate: rotate, fontText: chars)
    }

    /// Twenty words added re-extract in order, the paragraph keeps its lines' left edge and step, what follows stays.
    func assertReflows(_ pdf: [UInt8]) throws {
        let before = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        let next = try Self.run(before, "Next block starts here")
        let text = Self.body + " " + Self.twenty
        let check = p.check(text)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
        let after = try ContentEditor.read(edited, nil, 0)
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(q.lines.count == check.lineCount)
        #expect(Self.equal(p.lineStep, q.lineStep, 1))
        #expect(q.lines.allSatisfy { Self.equal(p.lines[0].x, $0.x, 1) })
        #expect(q.box.right <= p.box.right + 0.5, "\(q.box.right) > \(p.box.right)")
        let next2 = try Self.run(after, "Next block starts here")
        #expect(Self.equal(next.box.x, next2.box.x, 2))
        #expect(Self.equal(next.box.y, next2.box.y, 2))
    }

    @Test func aParagraphOnATurnedPageReflows() throws {
        // /Rotate 90 with the text turned back upright: as shown, it is an ordinary paragraph.
        try assertReflows(Self.drawn("0 1 -1 0 300 \(Self.n(Self.left)) Tm", rotate: 90))
    }

    @Test func aParagraphInAFlippedCoordinateSystemReflows() throws {
        // As browsers write PDFs: the CTM flips y, and the text matrix flips it back.
        try assertReflows(Self.drawn("1 0 0 -1 \(Self.n(Self.left)) \(Self.n(792 - Self.top)) Tm", prefix: "q 1 0 0 -1 0 792 cm", suffix: "Q"))
    }

    @Test func aParagraphScaledByTheCtmWithSpacingAndHorizontalScalingReflows() throws {
        // Drawn at twice the scale: the paragraph's step and widths are the page's, not text space's.
        try assertReflows(Self.drawn("\(Self.n(Self.left * 2)) \(Self.n(Self.top * 2)) Td", prefix: "q 0.5 0 0 0.5 0 0 cm", suffix: "Q", extra: "0.3 Tc 90 Tz"))
    }

    @Test func aParagraphWrittenBottomUpIsRewrittenInReadingOrder() throws {
        let lines = Self.wrap(Self.body, Self.width)
        var sb = ""
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            sb += "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.left)) \(Self.n(Self.top - Double(i) * Self.step)) Td (\(lines[i])) Tj ET\n"
        }
        let lastY: Double = Self.top - Double(lines.count - 1) * Self.step - 60
        sb += "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.left)) \(Self.n(lastY)) Td (Next block starts here) Tj ET"
        try assertReflows(ContentEditPdf.make(sb, fontText: Self.chars))
    }

    @Test func aRightToLeftParagraphIsEditedLineByLine() throws {
        // Rewrapping lays words out left to right: a Hebrew or Arabic paragraph would come out in the wrong order.
        let hebrew = "שלום עולם זה טקסט בעברית"
        let line = ContentEditPdf.cid(hebrew, fontText: Self.chars + hebrew)
        let pdf = ContentEditPdf.make("BT /FU \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 200 \(Self.n(Self.top)) Td \(line) Tj T* \(line) Tj T* \(line) Tj ET",
                                      fontText: Self.chars + hebrew)
        let paras = try ContentEditor.read(pdf, nil, 0).paragraphs
        #expect(paras.count == 1)
        let p = try #require(paras.first)
        #expect(p.lines.count == 3)
        #expect(p.blocked?.contains("right to left") == true)
    }

    @Test func clickingBetweenTheLinesOfABlockedParagraphFindsNothing() throws {
        // A bigger word on its third line: it is edited line by line.
        let word = String(Self.wrap(Self.body, Self.width)[2].split(separator: " ")[1])
        let pdf = Self.withFace(word, "FA", size: 14)
        let content = try ContentEditor.read(pdf, nil, 0)
        let p = try #require(content.paragraphs.first { $0.text.contains(word) })
        #expect(p.lines.count > 1)
        #expect(p.blocked != nil)
        // Between its first two lines, at their left edge: no run there, and the paragraph can't be edited as one.
        #expect(content.paragraphAt(p.lines[0].x + 2, (p.lines[0].bottom + p.lines[1].y) / 2, slop: 0) == nil)
    }

    @Test func spacesDrawnOnTheirOwnGoWithTheParagraph() throws {
        // Some generators draw each word and each space with its own operator: the spaces are part of the old text too.
        let lines = Self.wrap(Self.body, Self.width)
        var sb = ""
        for (i, line) in lines.enumerated() {
            sb += "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.left)) \(Self.n(Self.top - Double(i) * Self.step)) Td"
            for (k, w) in line.split(separator: " ").enumerated() { sb += k == 0 ? " (\(w)) Tj" : " ( ) Tj (\(w)) Tj" }
            sb += " ET\n"
        }
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.text == Self.body)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.twenty)
        #expect(Self.words(ContentEditPdf.text(edited)) == Self.words(Self.twenty))
        #expect(!(try ContentEditor.read(edited, nil, 0).runs.contains { $0.text == " " }))
    }

    @Test func aParagraphWithASuperscriptInItIsEditedLineByLine() throws {
        // A footnote mark is text of its own (smaller, raised): rewrapping the words around it would leave it behind.
        let lines = Self.wrap(Self.body, Self.width)
        let mark: Double = 72 + Self.measure(lines[1]) + 1
        var sb = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 72 \(Self.n(Self.top)) Td (\(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
        sb += " ET BT /FA 7 Tf 4 Ts \(Self.n(mark)) \(Self.n(Self.top - Self.step)) Td (1) Tj ET"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.blocked?.contains("inside it") == true)
    }

    @Test func emptyTextTakesTheParagraphAwayAndWhatFollowsStays() throws {
        let (pdf, _) = Self.page(.left)
        let p = try Self.body0(pdf)
        let next = try Self.run(try ContentEditor.read(pdf, nil, 0), "Next block starts here")
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "  \r\n ")
        let after = try ContentEditor.read(edited, nil, 0)
        #expect(!after.runs.contains { $0.text.contains("quick") })
        let next2 = try Self.run(after, "Next block starts here")
        #expect(Self.equal(next.box.x, next2.box.x, 2))
        #expect(Self.equal(next.box.y, next2.box.y, 2))
    }

    /// One page with a paragraph of each alignment, the last with a line right under it (to see the overlap warning).
    /// With INKVOLTPDF_SAMPLES set it is written there (paragraph-sample.pdf) for the app.
    @Test func aSamplePageHoldsOneParagraphOfEachAlignment() throws {
        let pdf = Self.samplePage()
        let paras = try ContentEditor.read(pdf, nil, 0).paragraphs.filter { $0.lines.count > 1 }
        #expect(paras.map(\.align) == [.left, .justified, .center, .right])
        #expect(paras.last?.check(Self.body + " " + Self.twenty).overlaps != nil)
        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_SAMPLES"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(pdf).write(to: URL(fileURLWithPath: dir).appendingPathComponent("paragraph-sample.pdf"))
        }
    }

    static func samplePage() -> [UInt8] {
        var sb = "BT /FA 16 Tf 72 750 Td (Paragraph Sample) Tj ET\n"
        var top = 720.0
        for align in [ParagraphAlign.left, .justified, .center, .right] {
            let lines = wrap(body, width)
            for (i, line) in lines.enumerated() {
                let w = measure(line)
                let spaces = Double(line.filter { $0 == " " }.count)
                let tw: Double = align == .justified && i < lines.count - 1 ? (width - w) / spaces : 0
                let x: Double = align == .right ? left + width - w : align == .center ? left + (width - w) / 2 : left
                sb += "BT /FA \(n(size)) Tf \(n(tw)) Tw \(n(x)) \(n(top - Double(i) * step)) Td (\(line)) Tj ET\n"
            }
            top -= Double(lines.count) * step + 30
        }
        sb += "BT /FA \(n(size)) Tf 0 Tw 72 \(n(top + 20)) Td (A line right under the last paragraph) Tj ET\n"
        return ContentEditPdf.make(sb, fontText: chars)
    }

    @Test func theEditIsOneSaveAndTheOldTextIsGoneFromTheContent() throws {
        let (pdf, lines) = Self.page(.center)
        let p = try Self.body0(pdf)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Centered and short now, on two lines when it wraps at the width of the old box here")
        let content = ContentEditPdf.content(edited)
        #expect(lines.allSatisfy { !content.contains("(\($0))") })
        let q = try Self.body0(edited, "Centered")
        #expect(try ContentEditor.replaceParagraph(edited, nil, q, q.text) == edited)
    }

    /// The roadmap's test on real files, run only with INKVOLTPDF_CORPUS set to a folder of PDFs (the export corpus's
    /// .cache): on each of the first pages, the longest editable paragraph gets 20 of its own words added; they must
    /// re-extract in order, and the new lines must not overlap anything else on the page unless the check said so.
    /// Results are written to the test output, nothing to disk.
    @Test func corpusParagraphsTakeTwentyMoreWords() throws {
        guard let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_CORPUS"], !dir.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        var failures: [String] = []
        for name in names.filter({ $0.lowercased().hasSuffix(".pdf") }).sorted() {
            let pdf = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)))
            let pages: Int
            do {
                let engine = try PdfEngine.open(pdf)
                pages = engine.pageCount
                engine.close()
            } catch {
                continue
            }
            for page in 0..<min(3, pages) {
                guard let content = try? ContentEditor.read(pdf, nil, page) else {
                    print("\(name) p\(page + 1): unreadable")
                    continue
                }
                let editable = content.paragraphs.filter { $0.blocked == nil && $0.lines.count > 1 }
                guard let p = editable.max(by: { $0.lines.count < $1.lines.count }) else {
                    print("\(name) p\(page + 1): \(content.paragraphs.count) paragraphs, none editable")
                    continue
                }
                let words = p.text.split(separator: " ").map(String.init)
                let added = (0..<20).map { words[$0 % words.count] }.joined(separator: " ")
                let text = p.text + " " + added
                let check = p.check(text)
                let line = "\(name) p\(page + 1): \(content.paragraphs.count) paragraphs, \(editable.count) editable; longest \(p.lines.count) lines → \(check.lineCount)"
                if !check.missing.isEmpty {
                    print("\(line); refused, font lacks \(check.missing.prefix(5).joined(separator: " "))")
                    continue
                }
                let edited: [UInt8]
                do {
                    edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, allowOverlap: true)
                } catch {
                    failures.append("\(line): \(error)")
                    continue
                }
                let engine = try PdfEngine.open(edited)
                let got = Self.words(try engine.text(page, cache: false).text)
                engine.close()
                if !got.contains(Self.words(added)) { failures.append("\(line): the added words don't re-extract in order") }
                let after = try ContentEditor.read(edited, nil, page)
                let before = Set(content.runs.map { "\($0.text)|\($0.box.x.rounded())|\($0.box.y.rounded())" })
                let fresh = after.paragraphs.first { $0.text == text }?.runs
                    ?? after.runs.filter { !before.contains("\($0.text)|\($0.box.x.rounded())|\($0.box.y.rounded())") && check.box.inflate(1).contains($0.box.x, $0.box.y) }
                let freshIds = Set(fresh.map(\.id))
                let hits = fresh.filter { f in
                    after.runs.contains { o in
                        let x = o.box.intersect(f.box)
                        return !freshIds.contains(o.id) && !trimmed(o.text).isEmpty && !x.isEmpty && x.width * x.height > 4
                    }
                }.count
                print("\(line); overlap \(check.overlaps == nil ? "none reported" : "reported"), \(hits) new line(s) touching other text")
                if check.overlaps == nil && hits > 0 { failures.append("\(line): new lines overlap other text, unreported") }
            }
        }
        for f in failures { print("FAIL " + f) }
        #expect(failures.isEmpty)
    }
}
