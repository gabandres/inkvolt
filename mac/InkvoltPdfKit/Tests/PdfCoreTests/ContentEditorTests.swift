import Foundation
import Testing
@testable import PdfCore

/// Ported from ContentEditorTests.cs (Edit Text & Images): the lexer, reading runs and pictures, editing text in the
/// page's own fonts, moving, resizing, replacing and deleting pictures, and the regressions of the first version; all 34
/// cases (the theory's rows as arguments). Adapted: the fonts are the hand-made Arial subsets of `ContentEditPdf` (PDFsharp
/// draws them on Windows), so `cid` needs no seed PDF; where .NET reads PDFsharp objects the check reads the same entries
/// through `PObj`; MovingAPictureRewritesOnlyItsPlacement checks where MuPDF draws the picture by its pixels (the
/// Windows engine's export page, which lists drawn images, comes with D5c); EncryptedFilesKeepTheirProtection encrypts
/// with MuPDF (AES-128) where Windows uses PDFsharp; ARealisticPageIsReadAndEdited draws its page by hand (lines of text
/// in both fonts, a ruled table and a logo) because `ExportTestPdf` comes with D5c's export tests. A page past the end
/// throws `PdfEngineError` (.NET: `ArgumentOutOfRangeException`). Left out: nothing.
struct ContentEditorTests {
    private static let simple = "BT /FA 20 Tf 72 692 Td (Hello World) Tj ET\nBT /FA 12 Tf 72 600 Td (draft) Tj ET"

    private func run(_ pdf: [UInt8], _ text: String, page: Int = 0) throws -> TextRun {
        let runs = try ContentEditor.read(pdf, nil, page).runs.filter { $0.text == text }
        #expect(runs.count == 1)
        return try #require(runs.first)
    }

    /// xUnit's `Assert.Equal(expected, actual, precision)`: equal when rounded to `decimals`.
    private func equal(_ a: Double, _ b: Double, _ decimals: Int) -> Bool {
        let f = pow(10.0, Double(decimals))
        return (a * f).rounded(.toNearestOrEven) == (b * f).rounded(.toNearestOrEven)
    }

    private func near(_ expected: RectD, _ actual: RectD, _ comment: Comment? = nil) {
        #expect(abs(expected.x - actual.x) < 0.6 && abs(expected.y - actual.y) < 0.6 && abs(expected.width - actual.width) < 0.6
            && abs(expected.height - actual.height) < 0.6, "expected \(expected), got \(actual)")
    }

    private func editError(_ body: () throws -> Any) -> ContentEditError? {
        do {
            _ = try body()
        } catch let e as ContentEditError {
            return e
        } catch {
            Issue.record("unexpected \(error)")
        }
        return nil
    }

    // ---- Lexer ----

    @Test func lexerReadsStringsNamesArraysAndDictionaries() throws {
        let ops = ContentLexer.parse(latin1Bytes(
            #"% a comment"# + "\n" + #"/Span <</MCID 3 /Alt (a\)b)>> BDC (nested (parens) \(x\) \101\n) Tj <48 65 6C6> Tj /A#20B Do [(a) -120.5 (b)] TJ EMC"#))
        #expect(ops.map(\.name) == ["BDC", "Tj", "Tj", "Do", "TJ", "EMC"])
        #expect(ops[0].operands[1]["MCID"]?.num == 3)
        #expect(latin1String(try #require(ops[0].operands[1]["Alt"]).bytes) == "a)b")
        #expect(latin1String(ops[1].operands[0].bytes) == "nested (parens) (x) A\n")
        #expect(latin1String(ops[2].operands[0].bytes) == "Hel`") // odd digit padded with 0
        #expect(ops[2].operands[0].hex)
        #expect(ops[3].operands[0].name == "A B")
        #expect(ops[4].operands[0].items[1].num == -120.5)
    }

    @Test func lexerSkipsInlineImageDataEvenWhenItHoldsEI() {
        // 3 x 1 RGB, unfiltered: the data (9 bytes) holds " EI " itself, which only the computed length gets past.
        let data: [UInt8] = [0x20, 69, 73, 0x20, 1, 2, 3, 4, 5]
        let head = latin1Bytes("q 30 0 0 10 50 50 cm BI /W 3 /H 1 /BPC 8 /CS /RGB ID ")
        let tail = latin1Bytes("\nEI Q BT /FA 9 Tf (after) Tj ET")
        let ops = ContentLexer.parse(head + data + tail)
        #expect(ops.map(\.name) == ["q", "cm", "BI", "Q", "BT", "Tf", "Tj", "ET"])
        #expect(ops[2].dataEnd - ops[2].dataStart == data.count)

        // Filtered data (length unknown): the EI followed by ordinary content ends it.
        let filtered = ContentLexer.parse(latin1Bytes("BI /W 2 /H 2 /BPC 8 /CS /G /F /AHx ID 00ff\n00ff> EI Q"))
        #expect(filtered.map(\.name) == ["BI", "Q"])
    }

    @Test func lexerSurvivesMalformedContent() {
        let ops = ContentLexer.parse(latin1Bytes(") ] } >> 5 --3 Td (unterminated"))
        #expect(ops.contains { $0.name == "Td" && $0.n(1) == -3 })
    }

    @Test func toUnicodeCMapRangesAndArraysAreRead() {
        var map: [Int: String] = [:]
        TextFont.readCMap(latin1Bytes(
            "begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0003> <0020> <0010> <00660069> endbfchar "
                + "2 beginbfrange <0020> <0022> <0041> <0030> <0031> [<0078> <D83DDE00>] endbfrange endcmap"), into: &map)
        #expect(map[3] == " ")
        #expect(map[0x10] == "fi")
        #expect(map[0x22] == "C")
        #expect(map[0x31] == "\u{1F600}")
    }

    @Test func glyphNamesMapToText() {
        #expect(GlyphNames.toUnicode("eacute") == "é")
        #expect(GlyphNames.toUnicode("f_f_i") == "ffi")
        #expect(GlyphNames.toUnicode("A.sc") == "A")
        #expect(GlyphNames.toUnicode("uni20AC") == "€")
        #expect(GlyphNames.toUnicode("u1F600") == "\u{1F600}")
        #expect(GlyphNames.inEncoding("WinAnsiEncoding", 0x80) == "Euro")
        #expect(GlyphNames.inEncoding("StandardEncoding", 0x27) == "quoteright")
        #expect(GlyphNames.inEncoding("MacRomanEncoding", 0x8E) == "eacute")
        #expect(CffProgram.standardStringCount == 229)
    }

    // ---- Reading runs ----

    @Test func runsLandWhereMuPdfShowsTheirCharacters() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 20 Tf 72 692 Td (Hello World) Tj ET\n"
                + "q 1.5 0 0 1.5 10 20 cm BT /FU 10 Tf 2 0 0 1 40 300 Tm 3 Tc " + ContentEditPdf.cid("World") + " Tj ET Q\n"
                + "BT /FA 14 Tf 100 200 Td [(He) 400 (llo) -2000 (World)] TJ ET")
        let content = try ContentEditor.read(pdf, nil, 0)
        #expect(content.runs.map(\.text) == ["Hello World", "World", "Hello World"])
        #expect(content.runs.allSatisfy { $0.blocked == nil })

        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let text = try engine.text(0, cache: false)
        let units = Array(text.text.utf16)
        for run in content.runs {
            // MuPDF's boxes of the run's first and last letters lie at the run's ends.
            let probe = run.text.replacingOccurrences(of: " ", with: "")
            let hits = units.indices.filter { units[$0] != 32 && units[$0] != 10 }.map(text.boxAt)
                .filter { run.box.inflate(1.5).contains($0.centerX, $0.centerY) }
            #expect(hits.count == probe.utf16.count)
            let left = hits.map(\.x).min() ?? 0, right = hits.map(\.right).max() ?? 0
            #expect((-1.5...1.5).contains(left - run.box.x))
            #expect((-1.5...1.5).contains(run.box.right - right))
        }
        #expect(equal(15, content.runs[1].fontSize, 1)) // 10 pt under a 1.5 scale
        #expect(equal(20, content.runs[0].fontSize, 1))
    }

    @Test func runsOnARotatedPageAreInPageSpace() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello) Tj ET", rotate: 90)
        let r = try run(pdf, "Hello")
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let text = try engine.text(0, cache: false)
        let all = (0..<text.length).map(text.boxAt).reduce(RectD.zero) { $0.union($1) }
        // Along the baseline (down the page when turned) the ends match; across it MuPDF's boxes are tighter.
        #expect(abs(all.y - r.box.y) <= 1.5)
        #expect(abs(all.bottom - r.box.bottom) <= 1.5)
        #expect(all.x >= r.box.x - 1 && all.right <= r.box.right + 1, "\(all) vs \(r.box)")
        #expect(equal(90, r.angle, 1))
    }

    // ---- Editing text ----

    @Test func textIsReplacedInItsOwnSimpleFont() throws {
        let pdf = ContentEditPdf.make(Self.simple)
        let r = try run(pdf, "Hello World")
        let check = r.check("Hello Word")
        #expect(check.missing.isEmpty)
        #expect(check.width < check.oldWidth)

        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hello Word")
        let text = ContentEditPdf.text(edited)
        #expect(text.contains("Hello Word"))
        #expect(!text.contains("World"))
        #expect(text.contains("draft"))
        let after = try run(edited, "Hello Word")
        #expect(equal(r.box.x, after.box.x, 2))
        #expect(equal(r.box.y, after.box.y, 2))
        #expect(ContentEditPdf.content(edited).contains("72 692 Td")) // the rest of the content is kept as written
    }

    /// A text layer as Windows writes it since its OCR's %f line: comment lines the Mac doesn't read yet (E14).
    private static let windowsLayer = "%InkvoltOCR 1 es-MX\n%f 0 0 0 612 792\n%w 1 72 600 40 12 0 6472616674\nq BT 3 Tr /FA 12 Tf 72 600 Td (draft) Tj ET Q"

    @Test func aWindowsTextLayersCommentLinesStayWhenTextIsEdited() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello World) Tj ET\n" + Self.windowsLayer + "\nBT /FA 12 Tf 72 500 Td (after) Tj ET")
        let edited = try ContentEditor.replaceText(pdf, nil, run(pdf, "Hello World"), "Hello Word")
        let content = ContentEditPdf.content(edited)
        #expect(content.contains(Self.windowsLayer)) // to the byte
        #expect(try run(edited, "Hello Word").text == "Hello Word")
        #expect(try run(edited, "draft").text == "draft")
        // Editing the words after the layer; the layer's own word is refused, as invisible text.
        let later = try ContentEditor.replaceText(edited, nil, run(edited, "after"), "later")
        #expect(ContentEditPdf.content(later).contains("%InkvoltOCR 1 es-MX\n%f 0 0 0 612 792\n%w 1 72 600 40 12 0 6472616674\n"))
        #expect(try run(later, "later").text == "later")
        let layerWord = try run(later, "draft")
        #expect(editError { try ContentEditor.replaceText(later, nil, layerWord, "drat") }?.message.contains("invisible") == true)
    }

    @Test func aWindowsTextLayersCommentLinesStayWhenTheDocumentIsTagged() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello World) Tj ET\n" + Self.windowsLayer)
        let tagged = try AutoTag.write(pdf, nil, TagTest.plan(pdf), AccessibleOptions(title: "Layer", language: "en"))
        let content = ContentEditPdf.content(tagged)
        #expect(content.contains("%InkvoltOCR 1 es-MX\n%f 0 0 0 612 792\n%w 1 72 600 40 12 0 6472616674\n"))
        #expect(try !AccessibilityCheck.run(tagged, nil).failedConditions.contains("01-005")) // nothing swallowed by a comment
    }

    @Test func unchangedTextReturnsTheSameBytes() throws {
        let pdf = ContentEditPdf.make(Self.simple)
        #expect(try ContentEditor.replaceText(pdf, nil, run(pdf, "Hello World"), "Hello World") == pdf)
    }

    @Test func missingGlyphsAreRefusedByName() throws {
        let pdf = ContentEditPdf.make(Self.simple)
        let r = try run(pdf, "Hello World")
        let check = r.check("Hello Zebra")
        #expect(check.missing == ["Z", "b"])
        let e = try #require(editError { try ContentEditor.replaceText(pdf, nil, r, "Hello Zebra") })
        #expect(e.missing == ["Z", "b"])
        #expect(e.message.contains("“Z”"))
        #expect(e.message.contains("Arial"))
    }

    @Test func type0IdentityHTextIsWrittenAsGlyphIds() throws {
        let pdf = ContentEditPdf.make("BT /FU 20 Tf 72 692 Td " + ContentEditPdf.cid("Hello World") + " Tj ET")
        let r = try run(pdf, "Hello World")
        #expect(r.font?.twoByte == true)
        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hold Wer, 2024!")
        #expect(ContentEditPdf.text(edited).contains("Hold Wer, 2024!"))
        #expect(ContentEditPdf.content(edited).contains("<")) // still a hex string

        let e = try #require(editError { try ContentEditor.replaceText(pdf, nil, r, "Hello Kim") })
        #expect(e.missing == ["K", "i", "m"])
    }

    @Test func kerningOutsideTheEditIsKept() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td [-50 (H) 120 (ello) -900 (Wor) 80 (ld) 30] TJ ET")
        let r = try run(pdf, "Hello World")
        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hello Wo")
        let content = ContentEditPdf.content(edited)
        #expect(content.contains("[-50 (H) 120 (ello) -900 (Wo) 30] TJ"), "\(content)")
        // MuPDF breaks the line at the wide gap.
        #expect(ContentEditPdf.text(edited).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).contains("Hello Wo"))

        // An edit in the middle drops the adjustment inside it.
        let mid = try ContentEditor.replaceText(pdf, nil, r, "Hello Wedld")
        #expect(ContentEditPdf.content(mid).contains("[-50 (H) 120 (ello) -900 (Wedld) 30] TJ"), "\(ContentEditPdf.content(mid))")
    }

    @Test func quoteOperatorsKeepTheirLineMoves() throws {
        let pdf = ContentEditPdf.make("BT /FA 12 Tf 14 TL 72 700 Td (draft) Tj (Hello) ' 2 1 (World) \" ET")
        let hello = try run(pdf, "Hello")
        let world = try run(pdf, "World")
        #expect(equal(14, hello.box.y - (try run(pdf, "draft")).box.y, 1))
        let e1 = try ContentEditor.replaceText(pdf, nil, hello, "Hell")
        #expect(ContentEditPdf.content(e1).contains("(Hell) '"))
        let e2 = try ContentEditor.replaceText(e1, nil, try run(e1, "World"), "Word")
        #expect(ContentEditPdf.content(e2).contains("2 1 (Word) \""))
        #expect(equal(world.box.y, try run(e2, "Word").box.y, 1))
    }

    @Test func aSpaceTheCMapDoesNotMapIsStillWritten() throws {
        // Words set apart by TJ gaps in a font whose ToUnicode CMap has no space: the space comes from the font's own
        // cmap (and is added to the CMap), or else becomes a gap.
        let pdf = ContentEditPdf.withoutSpace(ContentEditPdf.make(
            "BT /FU 20 Tf 72 692 Td [" + ContentEditPdf.cid("Hello") + " -300 " + ContentEditPdf.cid("World") + "] TJ ET"))
        let r = try run(pdf, "Hello World")
        #expect(r.check("Hello World draft").missing.isEmpty)
        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hello World draft")
        #expect(ContentEditPdf.text(edited).contains("Hello World draft"))
        #expect(try run(edited, "Hello World draft").text == "Hello World draft")
    }

    @Test func textInAFormXObjectIsListedButNotEditable() throws {
        let pdf = ContentEditPdf.make("q /Fm1 Do Q BT /FA 12 Tf 72 600 Td (draft) Tj ET", form: "BT /FA 12 Tf 72 700 Td (Hello) Tj ET")
        let content = try ContentEditor.read(pdf, nil, 0)
        let inForm = try #require(content.runs.first { $0.text == "Hello" })
        #expect(inForm.blocked?.contains("form XObject") == true)
        #expect(inForm.id < 0)
        #expect(content.runs.first { $0.text == "draft" }?.blocked == nil)
        let e = try #require(editError { try ContentEditor.replaceText(pdf, nil, inForm, "Hell") })
        #expect(e.message.contains("can't be edited"))
    }

    @Test func severalContentStreamsAreReadAsOne() throws {
        // The second stream continues the text object the first began.
        let pdf = ContentEditPdf.make("BT /FA 20 Tf", extraStreams: ["72 692 Td (Hello) Tj", "ET BT /FA 9 Tf 72 600 Td (draft) Tj ET"])
        let edited = try ContentEditor.replaceText(pdf, nil, try run(pdf, "Hello"), "Hell")
        let text = ContentEditPdf.text(edited)
        #expect(text.contains("Hell"))
        #expect(text.contains("draft"))
    }

    @Test func aStaleRunIsRefused() throws {
        let pdf = ContentEditPdf.make(Self.simple)
        let r = try run(pdf, "Hello World")
        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hello Wold")
        let e = try #require(editError { try ContentEditor.replaceText(edited, nil, r, "Hello") })
        #expect(e.message.contains("changed"))
    }

    @Test func invisibleTextAndTextWithActualTextAreNotEditable() throws {
        let pdf = ContentEditPdf.make("q BT 3 Tr /FA 12 Tf 72 700 Td (Hello) Tj ET Q\n/Span <</ActualText (fi)>> BDC BT /FA 12 Tf 72 600 Td (draft) Tj ET EMC BT /FA 12 Tf 72 500 Td (World) Tj ET")
        #expect(try run(pdf, "Hello").blocked?.contains("invisible") == true)
        #expect(try run(pdf, "draft").blocked?.contains("ActualText") == true)
        #expect(try run(pdf, "World").blocked == nil)
    }

    @Test func encryptedFilesKeepTheirProtection() throws {
        let pdf = Encrypt.with(ContentEditPdf.make(Self.simple), "aes-128", user: "u", owner: "o")
        let r = try #require(try ContentEditor.read(pdf, "o", 0).runs.first { $0.text == "Hello World" })
        let edited = try KeptProtection.run(openPassword: nil, dropOpenPassword: false) { try ContentEditor.replaceText(pdf, "o", r, "Hello Wold") }
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(edited) }
        let engine = try PdfEngine.open(edited, password: "u")
        defer { engine.close() }
        #expect(try engine.text(0, cache: false).text.contains("Hello Wold"))
    }

    @Test func signedFilesGetTheEditAppended() throws {
        let pdf = SignedEditTests.signed()
        let r = try #require(try ContentEditor.read(pdf, nil, 0).runs.first { $0.blocked == nil && $0.text.utf16.count > 3 })
        let target = String(r.text.dropLast())
        if !r.check(target).missing.isEmpty { return }
        let (edited, report) = try SignedEdits.run { try ContentEditor.replaceText(pdf, nil, r, target) }
        #expect(report.appended)
        #expect(report.removedItemKept)
        #expect(Array(edited.prefix(pdf.count)) == pdf)
    }

    // ---- Pictures ----

    private static let pictures = "q 100 0 0 50 72 600 cm /Im1 Do Q\nq 40 0 0 20 300 300 cm /Im1 Do Q\nBT /FA 12 Tf 72 500 Td (draft) Tj ET"

    @Test func picturesAreFoundWithTheirBoxes() throws {
        let pdf = ContentEditPdf.make(Self.pictures + "\nq 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \u{80}\nEI Q")
        let images = try ContentEditor.read(pdf, nil, 0).images
        #expect(images.count == 3)
        #expect(images[0].box == RectD(72, 792 - 650, 100, 50))
        #expect(images[2].inline)
        #expect(images[2].box == RectD(50, 792 - 60, 30, 10))
    }

    @Test func movingAPictureRewritesOnlyItsPlacement() throws {
        let pdf = ContentEditPdf.make(Self.pictures)
        let image = try ContentEditor.read(pdf, nil, 0).images[0]
        let moved = try ContentEditor.moveImage(pdf, nil, image, RectD(200, 100, 50, 25))
        let images = try ContentEditor.read(moved, nil, 0).images
        #expect(images.count == 2)
        near(RectD(200, 100, 50, 25), images[0].box)
        near(RectD(300, 792 - 320, 40, 20), images[1].box) // the other use of /Im1 stays
        #expect(ContentEditPdf.content(moved).contains("50 0 0 25 200 667 cm")) // its own cm changed, no wrapper

        // MuPDF draws it there (and no longer where it was).
        let there = TestImages.pixelAt(moved, 0, 225, 112)
        #expect(there.r > 200 && there.g < 60, "\(there)")
        let before = TestImages.pixelAt(moved, 0, 122, 167)
        #expect(before.g > 200, "\(before)")
    }

    @Test func aPictureWithoutItsOwnGroupIsWrapped() throws {
        let pdf = ContentEditPdf.make("q 2 0 0 2 0 0 cm q 50 0 0 25 10 10 cm /Im1 Do 30 0 0 10 0 100 cm /Im1 Do Q Q", rotate: 90)
        let images = try ContentEditor.read(pdf, nil, 0).images
        let target = RectD(images[0].box.x + 30, images[0].box.y + 40, images[0].box.width / 2, images[0].box.height / 2)
        let moved = try ContentEditor.moveImage(pdf, nil, images[0], target)
        let after = try ContentEditor.read(moved, nil, 0).images
        near(target, after[0].box)
        near(images[1].box, after[1].box) // drawn after it, under the same state: unchanged
    }

    @Test func deletingAPictureKeepsItsOtherUses() throws {
        let pdf = ContentEditPdf.make(Self.pictures)
        let image = try ContentEditor.read(pdf, nil, 0).images[0]
        let (deleted, report) = try SignedEdits.run { try ContentEditor.deleteImage(pdf, nil, image) }
        #expect(!report.appended)
        let images = try ContentEditor.read(deleted, nil, 0).images
        #expect(images.count == 1)
        near(RectD(300, 792 - 320, 40, 20), images[0].box)
        #expect(ContentEditPdf.text(deleted).contains("draft"))
    }

    @Test func deletingTheLastUseDropsTheResource() throws {
        let pdf = ContentEditPdf.make("q 100 0 0 50 72 600 cm /Im1 Do Q")
        let deleted = try ContentEditor.deleteImage(pdf, nil, try ContentEditor.read(pdf, nil, 0).images[0])
        #expect(try ContentEditor.read(deleted, nil, 0).images.isEmpty)
        let d = try Core2Pdf.open(deleted)
        let xo = try #require(d.page(0).dict("Resources")?.dict("XObject"))
        #expect(!xo.has("Im1"))
    }

    @Test func inlinePicturesCanBeMovedAndDeleted() throws {
        let pdf = ContentEditPdf.make("q 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \u{80}\nEI Q BT /FA 12 Tf 72 500 Td (draft) Tj ET")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        let moved = try ContentEditor.moveImage(pdf, nil, image, RectD(100, 100, 60, 20))
        let movedImages = try ContentEditor.read(moved, nil, 0).images
        #expect(movedImages.count == 1)
        near(RectD(100, 100, 60, 20), movedImages[0].box)
        let deleted = try ContentEditor.deleteImage(moved, nil, movedImages[0])
        #expect(try ContentEditor.read(deleted, nil, 0).images.isEmpty)
        #expect(ContentEditPdf.text(deleted).contains("draft"))
    }

    @Test func replacingAPictureFitsTheNewOneInItsBox() throws {
        let pdf = ContentEditPdf.make(Self.pictures)
        let image = try ContentEditor.read(pdf, nil, 0).images[0] // 100 x 50
        let png = TestImages.png(10, 10) { _, _ in (0, 0, 255, 255) }
        let replaced = try ContentEditor.replaceImage(pdf, nil, image, png, "blue.png")
        let images = try ContentEditor.read(replaced, nil, 0).images
        #expect(images.count == 2)
        near(RectD(72 + 25, 792 - 650, 50, 50), images[0].box) // square, centered
        let p = TestImages.pixelAt(replaced, 0, 72 + 50, 792 - 625)
        #expect(p.b > 200 && p.r < 60, "\(p)")
        #expect(TestImages.pixelAt(replaced, 0, 320, 792 - 310).r > 200) // the other use is still the red picture
    }

    @Test func picturesInAFormXObjectAreNotEditable() throws {
        let pdf = ContentEditPdf.make("q /Fm1 Do Q", form: "q 100 0 0 50 72 600 cm /Im1 Do Q")
        let images = try ContentEditor.read(pdf, nil, 0).images
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.blocked != nil)
        #expect(throws: ContentEditError.self) { try ContentEditor.deleteImage(pdf, nil, image) }
    }

    /// A realistic page (lines of text in both fonts, a ruled table, a logo): its text and picture are found and editable.
    /// With INKVOLTPDF_SAMPLES set it is written there (edit-sample.pdf) for the app.
    @Test func aRealisticPageIsReadAndEdited() throws {
        var content = "q 60 0 0 30 480 720 cm /Im1 Do Q\nBT /FA 18 Tf 72 720 Td (Hello World 2024) Tj ET\n"
        for (i, line) in ["Hello draft World", "draft, 2024!", "Wonder Hello", "Ünï World draft"].enumerated() {
            content += "BT /FA 11 Tf 72 \(680 - i * 16) Td (\(line)) Tj ET\n"
        }
        content += "BT /FU 11 Tf 72 590 Td " + ContentEditPdf.cid("Hello World") + " Tj ET\n"
        content += "0.5 w 72 560 m 540 560 l S 72 540 m 540 540 l S 72 520 m 540 520 l S 300 520 m 300 560 l S\n"
        content += "BT /FA 10 Tf 76 546 Td (Order) Tj 228 0 Td (2024) Tj ET BT /FA 10 Tf 76 526 Td (Total) Tj 228 0 Td (draft) Tj ET\n"
        let pdf = ContentEditPdf.make(content)
        let page = try ContentEditor.read(pdf, nil, 0)
        #expect(!page.images.isEmpty)
        #expect(page.runs.filter { $0.blocked == nil }.count > 5)
        let r = try #require(page.runs.first { $0.blocked == nil && $0.text.count > 4 })
        let shorter = String(r.text.dropLast())
        #expect(r.check(shorter).missing.isEmpty)
        let edited = try ContentEditor.replaceText(pdf, nil, r, shorter)
        #expect(ContentEditPdf.text(edited).contains(shorter))
        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_SAMPLES"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(pdf).write(to: URL(fileURLWithPath: dir).appendingPathComponent("edit-sample.pdf"))
        }
    }

    // ---- Regressions (review of the first version) ----

    @Test(arguments: [
        "BI /W 2 /H 1 /BPC 8 /CS /G /F /AHx ID 00ff> EI Q BT /FA 12 Tf 72 500 Td (Se\u{F1}or) Tj ET", // Latin-1 in a string after it
        "BI /W 2 /H 1 /BPC 8 /CS /G /F /AHx ID 00ff>EI Q BT /FA 12 Tf 72 500 Td (Se\u{F1}or) Tj ET", // no space before EI
        "BI /W 2 /H 1 /BPC 8 /CS /G /F /A85 ID !!~> EI Q BT /FA 12 Tf 72 500 Td (Se\u{F1}or) Tj ET",
        "BI /W 2 /H 1 /BPC 8 /CS /G /F /Fl /L 6 ID \u{01}\u{02} EI\u{FF} EI Q BT /FA 12 Tf 72 500 Td (Se\u{F1}or) Tj ET", // stated length
    ])
    func inlineImageDataEndsWhereItSays(_ body: String) {
        let ops = ContentLexer.parse(latin1Bytes("q 30 0 0 10 50 50 cm " + body))
        #expect(ops.map(\.name) == ["q", "cm", "BI", "Q", "BT", "Tf", "Td", "Tj", "ET"])
        #expect(ops.count > 2 && !ops[2].broken)
    }

    @Test func anInlineImageWithoutAClearEndIsNotEditableAndNothingIsLost() throws {
        // Filtered data with binary bytes after every EI candidate: its end can't be told, so it isn't touched.
        let content = "q 30 0 0 10 50 50 cm BI /W 2 /H 1 /BPC 8 /CS /G /F /Fl ID \u{01} EI\u{02}\u{03}\u{04} Q BT /FA 12 Tf 72 500 Td (draft) Tj ET"
        let ops = ContentLexer.parse(latin1Bytes(content))
        let last = try #require(ops.last)
        #expect(last.broken)
        #expect(last.dataStart == last.end) // never stretched to the end of the stream
        let pdf = ContentEditPdf.make("BT /FA 12 Tf 72 600 Td (Hello) Tj ET " + content)
        let page = try ContentEditor.read(pdf, nil, 0)
        #expect(page.images.count == 1)
        let image = try #require(page.images.first)
        #expect(image.blocked != nil)
        #expect(throws: ContentEditError.self) { try ContentEditor.deleteImage(pdf, nil, image) }
        let edited = try ContentEditor.replaceText(pdf, nil, try #require(page.runs.first { $0.text == "Hello" }), "Hell")
        let after = ContentEditPdf.content(edited)
        #expect(after.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(content)) // the rest of the page as it was
    }

    @Test(arguments: [
        "q 1 0 0 1 20 10 cm 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \u{80}\nEI Q", // two cms
        "q /GS1 gs 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \u{80}\nEI Q", // gs before the cm
    ])
    func anInlineImageMovedOutsideItsOwnGroupKeepsItsData(_ content: String) throws {
        let pdf = ContentEditPdf.make(content + " BT /FA 12 Tf 72 500 Td (draft) Tj ET")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        let moved = try ContentEditor.moveImage(pdf, nil, image, RectD(200, 100, 60, 20))
        let after = try ContentEditor.read(moved, nil, 0).images
        #expect(after.count == 1)
        near(RectD(200, 100, 60, 20), after[0].box)
        #expect(after[0].inline)
        #expect(ContentEditPdf.content(moved).contains("ID \u{80}\nEI"))
        let p = TestImages.pixelAt(moved, 0, 230, 110)
        #expect(p.r > 100 && p.r < 160 && p.r == p.g && p.g == p.b, "\(p)") // the gray pixel, drawn there
    }

    @Test func aContentStreamThatCantBeReadIsKept() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello) Tj ET", extraStreams: ["BT /FA 9 Tf 72 600 Td (draft) Tj ET"], damagedPart: true)
        let edited = try ContentEditor.replaceText(pdf, nil, try run(pdf, "Hello"), "Hell")
        let d = try Core2Pdf.open(edited)
        let parts = try #require(d.page(0).array("Contents"))
        #expect(parts.count == 3) // only the edited stream was replaced
        #expect(parts[2]?.rawStreamData?.count == 12)
        #expect(ContentEditPdf.text(edited).contains("draft"))

        // An operator split across streams needs them rewritten as one: refused rather than dropping the damaged one.
        let split = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello)", extraStreams: ["Tj ET"], damagedPart: true)
        let e = try #require(editError { try ContentEditor.replaceText(split, nil, try run(split, "Hello"), "Hell") })
        #expect(e.message.contains("damaged"))
    }

    @Test func aPictureAFormBorrowsStaysInThePageResources() throws {
        let pdf = ContentEditPdf.make("q 100 0 0 50 72 600 cm /Im1 Do Q q /Fm1 Do Q", form: "q 40 0 0 20 300 300 cm /Im1 Do Q", formInherits: true)
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first { $0.blocked == nil })
        let deleted = try ContentEditor.deleteImage(pdf, nil, image)
        let d = try Core2Pdf.open(deleted)
        #expect(d.page(0).dict("Resources")?.dict("XObject")?.has("Im1") == true)
        #expect(TestImages.pixelAt(deleted, 0, 320, 792 - 310).r > 200) // the form still draws the red picture
    }
}
