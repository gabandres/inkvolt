import Foundation
import Testing
@testable import PdfCore

/// The page half of Windows' `TranslationLooksTests` (roadmap 3.1): a paragraph's bold, italic, subscript and superscript
/// stretches go to the model as markup and come back as looks on the page; markup that can't be trusted leaves the
/// paragraph plain.
@Suite(.serialized) struct TranslationLooksTests {
    static let letters = "The quick brown fox jumps over a lazy dog, until the 0123456789 and THE QUICK BROWN FOX JUMPS OVER A LAZY DOG.!"

    /// "The quick brown fox jumps over d_model and the lazy dog.": "brown" in Arial Bold (/FB), "model" smaller and lowered.
    static func boldAndSubscript() -> [UInt8] {
        ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox jumps over d) Tj /FA 8 Tf -2 Ts (model) Tj 0 Ts /FA 12 Tf ( and the lazy dog.) Tj ET",
            fontText: letters, faces: true)
    }

    static let source = "The quick <b>brown</b> fox jumps over d<sub>model</sub> and the lazy dog."

    static func translate(_ pdf: [UInt8], _ translate: (String) -> String) throws -> (plan: TranslationPlan, result: TranslationResult) {
        let plan = try Translation.makePlan(pdf, nil, [0])
        var answers = TranslationAnswers()
        for (text, _) in plan.texts { answers.done[text] = translate(text) }
        return (plan, try Translation.apply(plan, answers, "es"))
    }

    static func runs(_ pdf: [UInt8]) -> [TextRun] { (try! ContentEditor.read(pdf, nil, 0)).runs.filter { !trimmed($0.text).isEmpty } }

    static func text(_ pdf: [UInt8]) throws -> String { try Translation.makePlan(pdf, nil, [0]).texts.map(\.text).first ?? "" }

    // ---- Markup out ----

    @Test func aBoldWordAndASubscriptGoToTheModelAsMarkup() throws {
        let (plan, _) = try Self.translate(Self.boldAndSubscript()) { $0 }
        #expect(plan.texts.map(\.text) == [Self.source])
        #expect(plan.marked == [Self.source])
        let jobs = Translation.jobs(plan, Translation.pieceTokens(4096))
        #expect(jobs.count == 1 && jobs[0].marked)
    }

    @Test func aHyphenJoinedAtALineEndLeavesTheBoldStretchBeforeItItsOwnLetters() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over a lazy dog and the quick fox is ) Tj /FB 12 Tf (respon-) Tj ET "
                + "BT /FA 12 Tf 1 0 0 1 72 686 Tm (sible for the lazy dog and the brown fox.) Tj ET", fontText: Self.letters + "-", faces: true)
        #expect(try Self.text(pdf) == "The quick brown fox jumps over a lazy dog and the quick fox is <b>respon</b>sible for the lazy dog and the brown fox.")
    }

    @Test func twoSuperscriptsWithALetterBetweenStayTwoStretches() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over a) Tj /FA 8 Tf 4 Ts (2) Tj 0 Ts /FA 12 Tf (b) Tj /FA 8 Tf 4 Ts (3) Tj 0 Ts /FA 12 Tf ( and the lazy dog.) Tj ET",
            fontText: Self.letters)
        #expect(try Self.text(pdf).contains("over a<sup>2</sup>b<sup>3</sup> and"))
    }

    @Test func twoBoldWordsWithAPlainLetterBetweenLeaveItPlain() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (Bold) Tj /FA 12 Tf (x) Tj /FB 12 Tf (Face) Tj /FA 12 Tf ( fox jumps over the lazy dog.) Tj ET",
            fontText: Self.letters, faces: true)
        #expect(try Self.text(pdf).contains("<b>Bold</b>x<b>Face</b>"))
    }

    @Test func smallWordsBesideABigRaisedNameAreNotTakenForSubscripts() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The man named ) Tj /FA 16 Tf 3 Ts (Bartholomew-Fitzwilliam) Tj 0 Ts /FA 12 Tf ( was born in a) Tj ( small town by) Tj ( the sea.) Tj ET",
            fontText: Self.letters + "-")
        #expect(!(try Self.text(pdf)).contains("<"))
    }

    // ---- On the page ----

    /// xUnit's `Assert.Equal(expected, actual, 1)`: equal to one decimal.
    static func near(_ a: Double, _ b: Double, _ within: Double = 0.06) -> Bool { abs(a - b) < within }

    @Test func aBoldWordAndASubscriptKeepTheirLooksInThePagesOwnFaces() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in "a <b>brown</b> fox over d<sub>model</sub> and a dog." }
        #expect(r.report.translated == 1)
        #expect(r.report.fonts.isEmpty) // the page's own fonts have every letter
        let runs = Self.runs(r.data!)
        let bold = runs.filter { $0.text.contains("brown") }
        #expect(bold.count == 1 && bold[0].bold && trimmed(bold[0].text) == "brown", "\(bold.map(\.fontName))")
        let plain = try #require(runs.first { $0.text.contains("over") })
        #expect(!plain.bold)
        // The page's own subscript: 8 points of 12, 2 points down.
        let sub = runs.filter { trimmed($0.text) == "model" }
        #expect(sub.count == 1)
        if let s = sub.first {
            #expect(Self.near(s.fontSize, 8.0 / 12 * plain.fontSize), "\(s.fontSize)")
            #expect(Self.near(s.origin.y, plain.origin.y + 2.0 / 12 * plain.fontSize), "\(s.origin.y)") // lower on the page
        }
        let shown = ContentEditPdf.text(r.data!)
        #expect(shown.contains("brown") && !shown.contains("<"))
    }

    @Test func aBoldWordAndASubscriptKeepTheirLooksWhenTheTranslationIsDrawnInAnInstalledFont() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in "El <b>ñandú</b> salta sobre d<sub>model</sub> y el perro." }
        #expect(r.report.translated == 1)
        #expect(r.report.fonts.contains { $0.contains("Bold") }, "\(r.report.fonts)")
        let runs = Self.runs(r.data!)
        let standIns = runs.filter(\.standIn).count
        #expect(standIns == runs.count, "\(runs.map(\.fontName))") // one installed family, the bold word in its bold face
        let bold = runs.filter { $0.text.contains("ñandú") }
        let plain = try #require(runs.first { $0.text.contains("salta") })
        #expect(bold.count == 1 && bold[0].fontName != plain.fontName) // the bold face of the installed font the rest is in
        #expect(r.report.fonts.sorted() == ["Arial", "Arial Bold"])
        let sub = runs.filter { trimmed($0.text) == "model" }
        #expect(sub.count == 1)
        if let s = sub.first {
            #expect(Self.near(s.fontSize, 8.0 / 12 * plain.fontSize))
            #expect(Self.near(s.origin.y, plain.origin.y + 2.0 / 12 * plain.fontSize))
        }
        #expect(ContentEditPdf.text(r.data!).contains("ñandú"))
    }

    @Test(arguments: [(8.0, 4.0), (6.0, 5.0), (9.0, 2.0)])
    func aSuperscriptRisesAndShrinksOnThePageAsMuchAsItDid(_ size: Double, _ rise: Double) throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog 2) Tj /FA \(Int(size)) Tf \(Int(rise)) Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE QUICK FOX 2<sup>10</sup> AND THE DOG." }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over the lazy dog 2<sup>10</sup> until the dog."])
        let runs = Self.runs(r.data!)
        let plain = try #require(runs.first { $0.text.contains("FOX") })
        let sup = runs.filter { trimmed($0.text) == "10" }
        #expect(sup.count == 1)
        if let s = sup.first {
            #expect(Self.near(s.fontSize, size / 12 * plain.fontSize), "\(s.fontSize)")
            #expect(Self.near(s.origin.y, plain.origin.y - rise / 12 * plain.fontSize), "\(s.origin.y)") // higher on the page
        }
    }

    @Test func aScriptsRiseIsKeptInTheEmsTheCopyDrawsItIn() throws {
        // The paragraph's size (its first run's, 12) isn't its line's (most of it, 10): a rise of 3 points is kept as 0.25
        // of the paragraph's em, which the copy draws it in, so it is 3 points again (not 0.3 em, 3.6 points).
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (A) Tj /FA 10 Tf ( quick brown fox jumps over the lazy dog 2) Tj /FA 7 Tf 3 Ts (10) Tj 0 Ts /FA 10 Tf ( until the dog.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE QUICK FOX 2<sup>10</sup> AND THE DOG." }
        #expect(plan.texts.count == 1 && plan.texts[0].text.contains("<sup>10</sup>"))
        let runs = Self.runs(r.data!)
        let plain = try #require(runs.first { $0.text.contains("FOX") })
        let sup = try #require(runs.first { trimmed($0.text) == "10" })
        #expect(Self.near(plain.fontSize, 10)) // not shrunk
        #expect(Self.near(plain.origin.y - sup.origin.y, 3), "\(plain.origin.y - sup.origin.y)")
    }

    @Test func aFootnoteMarkAndAnExponentInOneParagraphKeepTheirOwnSizesAndRises() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (The quick brown fox jumps over the dog) Tj /FA 6 Tf 5 Ts (1) Tj 0 Ts /FA 12 Tf ( and 2) Tj "
                + "/FA 9 Tf 3 Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE FOX OVER THE DOG<sup>1</sup> AND 2<sup>10</sup> UNTIL THE DOG." }
        #expect(plan.texts.count == 1 && plan.texts[0].text.contains("dog<sup>1</sup> and 2<sup>10</sup>"), "\(plan.texts.map(\.text))")
        let runs = Self.runs(r.data!)
        let plain = try #require(runs.first { $0.text.contains("FOX") })
        let mark = try #require(runs.first { trimmed($0.text) == "1" })
        let exponent = try #require(runs.first { trimmed($0.text) == "10" })
        #expect(Self.near(mark.fontSize, 6.0 / 12 * plain.fontSize))
        #expect(Self.near(exponent.fontSize, 9.0 / 12 * plain.fontSize))
        #expect(Self.near(plain.origin.y - mark.origin.y, 5.0 / 12 * plain.fontSize))
        #expect(Self.near(plain.origin.y - exponent.origin.y, 3.0 / 12 * plain.fontSize))
    }

    @Test func aLineStartingWithASymbolGoesOnTheSentenceAbove() throws {
        // CMSY's "=" or "−" opening a line inside a sentence, set on the line with no gap: not an item of its own.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the quick fox x) Tj ET "
                + "BT /FA 12 Tf 1 0 0 1 64.99 686 Tm (=) Tj (y for the lazy dog and the brown fox jumps over it.) Tj ET",
            fontText: Self.letters + "=")
        #expect(try Translation.makePlan(pdf, nil, [0]).texts.count == 1)
    }

    @Test func aCraftedRiseFarOffTheLineIsNotTakenForItsSuperscript() throws {
        // 1,000 points up: text of its own somewhere else, left as it is; the line is translated without it.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (The quick brown fox jumps over the lazy dog 2) Tj /FA 8 Tf 300 Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE QUICK FOX AND THE DOG." }
        #expect(!plan.texts.contains { $0.text.contains("<") })
        #expect(r.report.translated == 1)
        #expect(Self.runs(r.data!).filter { trimmed($0.text) == "10" }.count == 1)
    }

    @Test func aReplyWhoseMarkupCantBeTrustedIsWrittenPlainWithNoTagOnThePage() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in "a <b>brown fox over d<sub>model and a dog." }
        #expect(r.report.translated == 1)
        let runs = Self.runs(r.data!)
        #expect(runs.allSatisfy { !$0.bold }, "\(runs.filter(\.bold).map(\.text))")
        #expect(runs.allSatisfy { abs($0.fontSize - 12) < 0.1 })
        let shown = ContentEditPdf.text(r.data!)
        #expect(shown.replacingOccurrences(of: "\n", with: " ").contains("a brown fox over dmodel and a dog."), "\(shown)")
        #expect(!shown.contains("<"))
    }

    @Test func anAnswerTheSameAsTheMarkedTextLeavesTheParagraphAsItWas() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { $0 }
        #expect(r.report.translated == 0)
        #expect(r.report.unchanged == 1)
    }

    @Test(arguments: [
        "The quick brown fox jumps over dmodel and the lazy dog.", // sent in plain pieces, or every tag dropped
        "The quick brown fox jumps over d<sub>model</sub> and the lazy dog.", // one tag dropped
    ])
    func anAnswerTheSameAsTheParagraphsTextWithoutItsMarkupLeavesItAsItWas(_ answer: String) throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in answer }
        #expect(r.report.translated == 0)
        #expect(r.report.unchanged == 1)
        #expect(r.report.notTranslated == 0)
        #expect(r.report.flags.isEmpty)
    }

    @Test func aSubscriptAnEditDrewReadsBackAsOneAndStaysOneWhenEditedAgain() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in "a fox over d<sub>model</sub> and a dog." }
        #expect(r.report.translated == 1)
        let found = try ContentEditor.read(r.data!, nil, 0).paragraphs.filter { $0.text.contains("dog") }
        #expect(found.count == 1)
        let q = try #require(found.first)
        #expect(q.text == "a fox over dmodel and a dog.")
        // Its tag keeps the page's own rise (2 points of 12 down), so an edit draws it there again.
        #expect(q.spans == [span(q.text, "model", TextLook(script: .sub, rise: -0.17))], "\(q.spans)")

        let edited = try ContentEditor.replaceParagraph(r.data!, nil, q, "the fox over dmodel and a dog.")
        let runs = Self.runs(edited)
        let plain = try #require(runs.first { $0.text.contains("dog") })
        let sub = runs.filter { trimmed($0.text) == "model" }
        #expect(sub.count == 1)
        if let s = sub.first {
            #expect(Self.near(s.fontSize, 0.7 * plain.fontSize))
            #expect(Self.near(s.origin.y, plain.origin.y + 2.0 / 12 * plain.fontSize))
        }
    }

    @Test func aScriptsRiseInACraftedTagIsHeldToWhatAScriptsCanBe() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (The quick fox over d) Tj /InkvoltLook << /Script /Sub /Rise -100000 >> BDC /FA 8 Tf -2 Ts (model) Tj EMC 0 Ts /FA 12 Tf ( and the dog.) Tj ET",
            fontText: Self.letters)
        let q = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        #expect(q.spans.count == 1 && q.spans.first?.look.rise == -0.6, "\(q.spans)")
    }

    @Test func aSuperscriptWidensTheStepToItsLineByAsMuchAsItReachesPastTheLine() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog.) Tj 0 -14 Td (The quick brown fox jumps over the lazy dog.) Tj ET",
            fontText: Self.letters)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        let text = "The quick brown fox jumps over the lazy dog. A y2 fox."
        let two = (text as NSString).range(of: "2", options: .backwards).location
        func step(_ rise: Double?) -> (count: Int, step: Double) {
            let spans = rise.map { [TextSpan(two, 1, TextLook(script: .superscript, rise: $0))] } ?? []
            let l = ContentEditor.layOut(p, p.runs, text, spans, fit: 1)
            return (l.lines.count, l.lines.count == 2 ? l.lines[1].origin.y - l.lines[0].origin.y : 0)
        }
        let plain = step(nil), raised = step(0.6)
        #expect(plain.count == 2 && raised.count == 2)
        let room = plain.step - p.ascent - p.descent // the leading between the two lines' own ink
        let top = 0.6 * p.fontSize + ContentEditor.scriptScale * p.ascent // the superscript's top above its baseline
        #expect(top - p.ascent > room, "\(top - p.ascent) \(room)")
        #expect(abs(raised.step - (plain.step + (top - p.ascent - room))) < 0.006, "\(raised.step)")
        // A superscript within the line's height changes nothing; one reaching into the leading, only past it.
        #expect(abs(step(0.12).step - plain.step) < 0.006)
        for rise in [0.3, ContentEditor.superRise, 0.45] {
            let reach = rise * p.fontSize + ContentEditor.scriptScale * p.ascent - p.ascent
            #expect(abs(step(rise).step - (plain.step + max(0, reach - room))) < 0.006, "\(rise)")
        }
    }

    @Test func aSuperscriptOnTheFirstLineAndASubscriptOnTheLastAreInsideTheCheckedBox() throws {
        let pdf = ContentEditPdf.make("BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog.) Tj ET", fontText: Self.letters)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        let layout = ContentEditor.layOut(p, p.runs, "x2 and H2", [TextSpan(1, 1, lookSup), TextSpan(8, 1, lookSub)], fit: 1)
        #expect(layout.lines.count == 1)
        let origin = try #require(layout.lines.first?.origin)
        let box = layout.check.box
        let top: Double = origin.y - ContentEditor.superRise * p.fontSize - ContentEditor.scriptScale * p.ascent + 0.01
        let foot: Double = origin.y - ContentEditor.subRise * p.fontSize + ContentEditor.scriptScale * p.descent - 0.01
        #expect(box.y <= top, "\(box.y) \(origin.y)")
        #expect(box.bottom >= foot, "\(box.bottom) \(origin.y)")
    }

    @Test func charactersNoFontHasAreLeftOutAndTheLooksAfterThemStayOnTheirWords() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in "a \u{10FFFD}<b>brown</b> fox \u{10FFFD} over d<sub>model</sub>." }
        #expect(r.report.translated == 1)
        let runs = Self.runs(r.data!)
        #expect(runs.filter(\.bold).map { trimmed($0.text) } == ["brown"])
        let sub = runs.filter { trimmed($0.text) == "model" }
        #expect(sub.count == 1 && Self.near(sub.first?.fontSize ?? 0, 8))
    }

    @Test func arabicForAParagraphInCalibriIsDrawnInAFontMuPDFReadsInOrder() throws {
        // Calibri's Arabic lowers letters it joins; MuPDF read such lines on NIST p. 1 backwards. The closest font whose
        // letters stay on the line is taken. (macOS ships no Calibri; Microsoft Office installs it.)
        if SystemFonts.get("calibri.ttf") == nil { return }
        let pdf = ContentEditPdf.make("BT /FT 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the dog) Tj ET", fontText: Self.letters, faces: true,
                                      timesName: "Calibri")
        let ar = "القسم المُطبّق للهندسة الأمنية (مختبر التكنولوجيا المعلوماتية)"
        let (_, r) = try Self.translate(pdf) { _ in ar }
        #expect(r.report.translated == 1)
        #expect(TranslationCopyTests.plain(ContentEditPdf.text(r.data!)).contains(TranslationCopyTests.plain(ar)), "\(ContentEditPdf.text(r.data!))")
    }

    // ---- Looks a bold, italic or script tag doesn't say ----

    static let boldParagraph =
        "BT /FB 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over ) Tj /FA 12 Tf (the) Tj /FB 12 Tf ( lazy dog and the quick fox.) Tj ET"

    @Test func aRegularWordInABoldParagraphGoesWithTheBoldAroundItAndComesBackRegular() throws {
        let pdf = ContentEditPdf.make(Self.boldParagraph, fontText: Self.letters, faces: true)
        let (plan, r) = try Self.translate(pdf) { _ in "<b>El zorro salta sobre </b>el<b> perro y el zorro.</b>" }
        #expect(plan.texts.map(\.text) == ["<b>The quick brown fox jumps over </b>the<b> lazy dog and the quick fox.</b>"])
        #expect(r.report.translated == 1)
        let runs = Self.runs(r.data!)
        #expect(runs.filter { !$0.bold }.map { trimmed($0.text) } == ["el"], "\(runs.map { ($0.text, $0.bold) })")
        #expect(runs.filter { $0.text.contains("zorro") }.allSatisfy { $0.bold })
    }

    @Test(arguments: [
        "El zorro salta sobre el perro y el zorro.", // every tag dropped: as the paragraph is, bold
        "El zorro salta sobre el perro y <b>el zorro</b>.", // most of its bold dropped: can't be trusted
    ])
    func aBoldParagraphWhoseReplyLostItsBoldStaysBold(_ answer: String) throws {
        let pdf = ContentEditPdf.make(Self.boldParagraph, fontText: Self.letters, faces: true)
        let (_, r) = try Self.translate(pdf) { _ in answer }
        #expect(r.report.translated == 1)
        let runs = Self.runs(r.data!)
        #expect(runs.allSatisfy { $0.bold }, "\(runs.map { ($0.text, $0.bold) })")
    }

    @Test func aWordInAFontOfAnotherClassKeepsIt() throws {
        // A name in Times among Arial: no bold or italic says so.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox named ) Tj /FT 12 Tf (Newton) Tj /FA 12 Tf ( jumps over the lazy dog.) Tj ET",
            fontText: Self.letters + "N", faces: true)
        let (plan, r) = try Self.translate(pdf) { _ in "El zorro llamado <span>Newton</span> salta sobre el perro." }
        #expect(plan.texts.map(\.text) == ["The quick brown fox named <span>Newton</span> jumps over the lazy dog."])
        let runs = Self.runs(r.data!)
        let names = runs.filter { $0.text.contains("Newton") }
        #expect(names.count == 1)
        let name = try #require(names.first)
        #expect(name.fontName.range(of: "Times", options: .caseInsensitive) != nil, "\(name.fontName)")
        #expect(trimmed(name.text) == "Newton")
        #expect(runs.filter { !$0.text.contains("Newton") }.allSatisfy { $0.fontName.range(of: "Times", options: .caseInsensitive) == nil })
    }

    @Test func aWordInAnotherColorKeepsIt() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and jumps over the lazy dog.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "El zorro es <span>rojo</span> y salta sobre el perro." }
        #expect(plan.texts.map(\.text) == ["The quick brown fox is <span>red</span> and jumps over the lazy dog."])
        let runs = Self.runs(r.data!)
        let red = runs.filter { $0.color == 0xFF0000 }
        #expect(red.map { trimmed($0.text) } == ["rojo"])
        #expect(runs.filter { $0.color != 0xFF0000 }.allSatisfy { $0.color == 0 })
    }

    // ---- Plain underlines ----

    static let underlinedLine = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj (brown fox) Tj ( jumps over the lazy dog.) Tj ET"

    static func f3(_ v: Double) -> String { ContentLexer.number((v * 1000).rounded() / 1000) }

    /// The line above with a rule drawn as `rule` places it: (left, right) of "brown fox", page points; its operators.
    static func withRule(_ rule: (Double, Double) -> String) throws -> [UInt8] {
        let words = try #require(runs(ContentEditPdf.make(underlinedLine, fontText: letters)).first { $0.text == "brown fox" }).box
        return ContentEditPdf.make(underlinedLine + " " + rule(words.x, words.right), fontText: letters)
    }

    /// "brown fox" underlined 2 points below the baseline, 0.8 thick, in red.
    static func underlined() throws -> [UInt8] { try withRule { l, r in "1 0 0 rg \(f3(l)) 697.2 \(f3(r - l)) 0.8 re f 0 g" } }

    /// Each rectangle the page's content fills: x, y (PDF space), width, height.
    static func filledRects(_ pdf: [UInt8]) -> [(x: Double, y: Double, w: Double, h: Double)] {
        let content = ContentEditPdf.content(pdf) as NSString
        let re = try! NSRegularExpression(pattern: #"(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) re\s+f"#)
        return re.matches(in: content as String, range: NSRange(location: 0, length: content.length)).map { m in
            let v = (1...4).map { Double(content.substring(with: m.range(at: $0)))! }
            return (v[0], v[1], v[2], v[3])
        }
    }

    @Test func anUnderlineDrawnUnderSomeWordsGoesToTheModelAsMarkup() throws {
        let (plan, _) = try Self.translate(try Self.underlined()) { $0 }
        #expect(plan.texts.map(\.text) == ["The quick <u>brown fox</u> jumps over the lazy dog."])
    }

    @Test func anUnderlineIsDrawnAgainUnderTheWordsTheAnswerUnderlinesAndTheOldOneGoes() throws {
        let (_, r) = try Self.translate(try Self.underlined()) { _ in "El zorro <u>marron rapido</u> salta sobre el perro." }
        #expect(r.report.translated == 1)
        let words = try #require(Self.runs(r.data!).first { $0.text.contains("marron") })
        #expect(trimmed(words.text) == "marron rapido")
        let rules = Self.filledRects(r.data!) // the old rule's operator paints nothing now
        #expect(rules.count == 1, "\(rules)")
        let rule = try #require(rules.first)
        #expect(abs(rule.x - words.box.x) < 0.5, "\(rule) \(words.box)")
        #expect(abs(rule.x + rule.w - words.box.right) < 1.0, "\(rule) \(words.box)")
        #expect(abs(rule.h - 0.8) < 0.01)
        #expect(abs(rule.y + rule.h - (792 - words.origin.y - 2)) < 0.05, "\(rule) \(words.origin)") // 2 points below the baseline, as it was
        #expect(ContentEditPdf.content(r.data!).suffix(80).contains("1 0 0 rg")) // in its red
        #expect(!ContentEditPdf.text(r.data!).contains("<u>"))
    }

    @Test func anUnderlineTheAnswerDroppedIsTakenOffAndNotDrawnAgain() throws {
        let (_, r) = try Self.translate(try Self.underlined()) { _ in "El zorro marron rapido salta sobre el perro." }
        #expect(r.report.translated == 1)
        #expect(Self.filledRects(r.data!).isEmpty)
    }

    // "strike": through the words; "field": a line running on past the words, to be written on; "rule": a table's rule,
    // much wider than the words over it; "thick": a band, not a line.
    @Test(arguments: ["strike", "field", "rule", "thick"])
    func aRuleThatIsntAnUnderlineIsNoLookAndStays(_ kind: String) throws {
        let pdf = try Self.withRule { l, r in
            switch kind {
            case "strike": "\(Self.f3(l)) 703 \(Self.f3(r - l)) 0.8 re f"
            case "field": "\(Self.f3(l)) 697.2 \(Self.f3(r - l + 400)) 0.8 re f"
            case "rule": "40 697.2 520 0.8 re f"
            default: "\(Self.f3(l)) 690 \(Self.f3(r - l)) 8 re f"
            }
        }
        let (plan, r) = try Self.translate(pdf) { _ in "El zorro <u>marron rapido</u> salta sobre el perro." }
        #expect(plan.texts.count == 1 && !plan.texts[0].text.contains("<u>"))
        #expect(Self.filledRects(r.data!).count == 1) // as it was
    }

    @Test func aLinksUnderlineIsTheLinksNotAPlainOne() throws {
        var pdf = try Self.underlined()
        let words = try #require(Self.runs(pdf).first { $0.text == "brown fox" }).box
        let doc = try PdfEdit.open(pdf, nil)
        let link = doc.dict([("Type", doc.name("Annot")), ("Subtype", doc.name("Link")),
                             ("Rect", doc.reals(words.x, 792 - words.bottom - 3, words.right, 792 - words.y))])
        doc.page(0).set("Annots", doc.array([doc.add(link)]))
        try doc.checkFailure()
        pdf = try doc.write("")
        let (plan, _) = try Self.translate(pdf) { $0 }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over the lazy dog."])
    }

    @Test func thousandsOfRulesUnderACrowdedBaselineAreLookedAtQuickly() throws {
        // 4,000 thin rectangles, each under 20,000 runs on one baseline: the look for underlines gives up, it doesn't compare them all.
        var content = "BT /FA 1 Tf 1 0 0 1 10 700 Tm "
        for _ in 0..<20_000 { content += "(ab) Tj " }
        content += "ET 0 g "
        for i in 0..<4_000 { content += "\(ContentLexer.number(10 + Double(i) * 0.1)) 699.8 5 0.1 re f " }
        let pdf = ContentEditPdf.make(content, fontText: Self.letters)
        let doc = try PdfEdit.open(pdf, nil)
        let start = Date()
        _ = try ContentEditor.readRaw(doc, doc.page(0), 0, nil)
        #expect(Date().timeIntervalSince(start) < 10, "\(Date().timeIntervalSince(start)) s")
    }

    @Test func aRuleUnderTwoParagraphsStaysUnderTheOneNotWritten() throws {
        // "The quick brown fox" and, a column's gap on, "jumps over the dog", one rule under both; only the first is translated.
        let line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox) Tj 1 0 0 1 200 700 Tm (jumps over the dog) Tj ET"
        let second = try #require(Self.runs(ContentEditPdf.make(line, fontText: Self.letters)).first { $0.text.hasPrefix("jumps") }).box
        let pdf = ContentEditPdf.make(line + " 0 0 1 rg 72 697.2 \(Self.f3(second.right - 72)) 0.8 re f 0 g", fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { $0.contains("quick") ? "<u>El zorro marron rapido</u>" : $0 }
        #expect(plan.texts.count == 2)
        #expect(plan.texts.allSatisfy { $0.text.hasPrefix("<u>") }, "\(plan.texts.map(\.text))")
        #expect(r.report.translated == 1)
        let rules = Self.filledRects(r.data!)
        #expect(rules.count == 2, "\(rules)") // the one under the translation and what is left of the old one
        #expect(rules.contains { abs($0.x - second.x) < 1 && abs($0.x + $0.w - second.right) < 1 && abs($0.y - 697.2) < 0.01 }, "\(rules) \(second)")
        let words = try #require(Self.runs(r.data!).first { $0.text.contains("marron") })
        #expect(rules.contains { abs($0.x - words.box.x) < 1 }, "\(rules) \(words.box)")
    }

    @Test func twoOtherLooksAreMarkedApartAndEachComesBackAsItsOwn() {
        let text = "A red word and a blue one."
        let spans = [span(text, "red", TextLook(color: 0xFF0000)), span(text, "blue", TextLook(color: 0x0000FF)), span(text, "one", TextLook(color: 0x0000FF, bold: true))]
        #expect(TranslationMarkup.mark(text, spans) == "A <span>red</span> word and a <font>blue</font> <b><font>one</font></b>.") // "one" is blue too
        let (now, looks) = TranslationMarkup.read("Una palabra <span>roja</span> y una <font>azul</font>.", text, spans)
        #expect(looks == [span(now, "roja", TextLook(color: 0xFF0000)), span(now, "azul", TextLook(color: 0x0000FF))])
    }

    @Test func threeOtherLooksAreMarkedAndAFourthKeepsOnlyItsBold() {
        let text = "A red, a green, a blue and a gray word."
        let spans = [
            span(text, "red", TextLook(color: 0xFF0000)), span(text, "green", TextLook(font: "Courier New")),
            span(text, "blue", TextLook(color: 0x0000FF)), span(text, "gray", TextLook(color: 0x808080, bold: true)),
        ]
        #expect(TranslationMarkup.mark(text, spans) == "A <span>red</span>, a <font>green</font>, a <mark>blue</mark> and a <b>gray</b> word.")
        let (now, looks) = TranslationMarkup.read("Un <mark>azul</mark>, un <span>rojo</span> y un <font>verde</font>.", text, spans)
        #expect(looks == [span(now, "azul", TextLook(color: 0x0000FF)), span(now, "rojo", TextLook(color: 0xFF0000)), span(now, "verde", TextLook(font: "Courier New"))])
    }

    @Test(arguments: [
        "Una <span>roja <font>y</font></span> azul.", // one other look inside another
        "Una <font>roja</font> y <font>azul</font> y <font>gris</font> y <font>verde</font>.", // far more than it had
        "Una <mark>roja</mark>.", // one it didn't have
    ])
    func otherLooksAReplyGarblesLeaveItPlain(_ reply: String) {
        let text = "A red word and a blue one."
        let spans = [span(text, "red", TextLook(color: 0xFF0000)), span(text, "blue", TextLook(color: 0x0000FF))]
        let (now, looks) = TranslationMarkup.read(reply, text, spans)
        #expect(looks.isEmpty)
        #expect(!now.contains("<"))
    }

    @Test func aBoldWordARedWordAndAWordInAnotherFontKeepAllThreeLooksOnThePage() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and named ) Tj /FT 12 Tf (Newton) Tj /FA 12 Tf ( over the lazy dog.) Tj ET",
            fontText: Self.letters + "N", faces: true)
        let (plan, r) = try Self.translate(pdf) { _ in "El <b>zorro</b> es <span>rojo</span> y se llama <font>Newton</font> sobre el perro." }
        #expect(plan.texts.map(\.text) == ["The quick <b>brown</b> fox is <span>red</span> and named <font>Newton</font> over the lazy dog."])
        let runs = Self.runs(r.data!)
        #expect(runs.filter { $0.text.contains("zorro") }.map(\.bold) == [true])
        #expect(runs.filter { $0.color == 0xFF0000 }.map { trimmed($0.text) } == ["rojo"])
        let names = runs.filter { $0.text.contains("Newton") }
        #expect(names.count == 1)
        let name = try #require(names.first)
        #expect(name.fontName.range(of: "Times", options: .caseInsensitive) != nil, "\(name.fontName)")
        #expect(name.color == 0)
        #expect(runs.filter { !$0.text.contains("Newton") }.allSatisfy { $0.fontName.range(of: "Times", options: .caseInsensitive) == nil })
    }

    @Test func aParagraphWithMoreThan64LooksKeepsItsScripts() {
        let text = Array(repeating: "word", count: 80).joined(separator: " ") + " x2 and H2O"
        let ns = text as NSString
        var spans = (0..<80).map { TextSpan($0 * 5, 4, lookB) }
        spans.append(TextSpan(ns.range(of: "x2").location + 1, 1, lookSup))
        spans.append(TextSpan(ns.range(of: "H2O").location + 1, 1, lookSub))
        let marked = TranslationMarkup.mark(text, spans)
        #expect(marked.hasSuffix("x<sup>2</sup> and H<sub>2</sub>O"))
        #expect(!marked.contains("<b>"))
        let (_, looks) = TranslationMarkup.read(marked.replacingOccurrences(of: "and", with: "y"), text, spans)
        #expect(looks.map(\.look.script) == [.superscript, .sub])
    }

    /// The right end of a page's one paragraph made of `line`.
    static func rightOf(_ line: String, _ fontText: String) throws -> Double {
        try #require(try ContentEditor.read(ContentEditPdf.make(line, fontText: fontText), nil, 0).paragraphs.first).box.right
    }

    static func f2(_ v: Double) -> String { String(format: "%.2f", v) }

    @Test func aLongerScriptOnABandOfItsOwnJoinsTheLineItSitsOn() throws {
        let line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET"
        let right = try Self.rightOf(line, Self.letters + "[]-")
        let pdf = ContentEditPdf.make(line + " BT /FA 8 Tf 1 0 0 1 \(Self.f2(right + 0.5)) 704 Tm ([12-15]) Tj ET", fontText: Self.letters + "[]-")
        let (plan, r) = try Self.translate(pdf) { _ in "El zorro salta sobre el perro<sup>[12-15]</sup>" }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over the lazy dog<sup>[12-15]</sup>"])
        let runs = Self.runs(r.data!)
        let mark = try #require(runs.first { trimmed($0.text) == "[12-15]" })
        let plain = try #require(runs.first { $0.text.contains("perro") })
        #expect(Self.near(mark.fontSize, 8))
        #expect(mark.origin.y < plain.origin.y - 2, "\(mark.origin.y) \(plain.origin.y)")
    }

    @Test(arguments: ["The quick brown fox jumps over the lazy dog", "The lazy dog"]) // the second: a line shorter than its script
    func aScriptLongerThanTwelveCharactersJoinsTheLineItSitsOnWhole(_ words: String) throws {
        let script = "[3, 7, 12, 18-24, 31, 40]"
        let line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (\(words)) Tj ET"
        let right = try Self.rightOf(line, Self.letters + "[]-")
        let pdf = ContentEditPdf.make(line + " BT /FA 7 Tf 1 0 0 1 \(Self.f2(right + 0.5)) 704.5 Tm (\(script)) Tj ET", fontText: Self.letters + "[]-")
        let (plan, r) = try Self.translate(pdf) { _ in "El perro <sup>\(script)</sup>" }
        #expect(plan.texts.map(\.text) == ["\(words)<sup>\(script)</sup>"])
        let runs = Self.runs(r.data!)
        let mark = try #require(runs.first { $0.text.contains("[3") })
        #expect(trimmed(mark.text) == script) // whole
        #expect(Self.near(mark.fontSize, 7))
        let plain = try #require(runs.first { $0.text.contains("perro") })
        #expect(mark.origin.y < plain.origin.y - 3, "\(mark.origin.y) \(plain.origin.y)")
    }

    static func count(_ s: String, _ part: String) -> Int { s.components(separatedBy: part).count - 1 }

    @Test func aLineHostingALongScriptIsNotAlsoJoinedToAnotherLineAsOne() throws {
        // A big line, a smaller one raised after its end, and a long script raised after that one: the middle line hosts the
        // script and could itself be the big line's script; joined both ways, its words would be sent and written twice.
        let big = "BT /FA 20 Tf 1 0 0 1 72 700 Tm (THE QUICK BROWN FOX) Tj ET"
        let right = try Self.rightOf(big, Self.letters + "[]-")
        let middle = "BT /FA 12 Tf 1 0 0 1 \(Self.f2(right + 2)) 706 Tm (The lazy dog) Tj ET"
        let middleRight = try #require(try ContentEditor.read(ContentEditPdf.make(big + " " + middle, fontText: Self.letters + "[]-"), nil, 0).runs
            .first { $0.text == "The lazy dog" }).box.right
        let pdf = ContentEditPdf.make(big + " " + middle + " BT /FA 7 Tf 1 0 0 1 \(Self.f2(middleRight + 0.5)) 710 Tm ([3, 7, 12, 18-24, 31, 40]) Tj ET",
                                      fontText: Self.letters + "[]-")
        let all = try Translation.makePlan(pdf, nil, [0]).texts.map(\.text).joined()
        #expect(Self.count(all, "lazy dog") == 1, "\(all)")
        #expect(Self.count(all, "[3, 7") == 1, "\(all)")
    }

    @Test func longSmallTextOverALinesWordsIsNotTakenForItsScript() throws {
        // Smaller and raised, but across the line's words: a note set beside it, not a script.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET BT /FA 7 Tf 1 0 0 1 120 704.5 Tm (until the 0123456789 and the dog) Tj ET",
            fontText: Self.letters)
        let texts = try Translation.makePlan(pdf, nil, [0]).texts
        #expect(!texts.contains { $0.text.contains("<sup>") })
    }

    @Test func aMarkOnALongerScriptOnABandOfItsOwnIsReadOnce() throws {
        let line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET"
        let right = try Self.rightOf(line, Self.letters + "[]-*")
        let pdf = ContentEditPdf.make(
            line + " BT /FA 8 Tf 1 0 0 1 \(Self.f2(right + 0.5)) 704 Tm ([12-15]) Tj ET BT /FA 6 Tf 1 0 0 1 \(Self.f2(right + 26)) 707 Tm (*) Tj ET",
            fontText: Self.letters + "[]-*")
        let all = try Translation.makePlan(pdf, nil, [0]).texts.map(\.text).joined()
        #expect(Self.count(all, "[12-15]") == 1, "\(all)")
        #expect(Self.count(all, "brown fox") == 1, "\(all)")
    }

    @Test func twoFootnotesEachStartingWithItsNumberAreTwoParagraphs() throws {
        // attn's "†Work performed while at Google Brain." over "‡Work performed while at Google Research.": a real
        // model's copy wrote both as one, the second mark left in the middle of the new lines.
        let pdf = ContentEditPdf.make(
            "BT /FA 6 Tf 1 0 0 1 72 103 Tm (1) Tj /FA 9 Tf (The quick brown fox jumps over the lazy dog.) Tj ET "
                + "BT /FA 6 Tf 1 0 0 1 72 92 Tm (2) Tj /FA 9 Tf (The lazy dog jumps over the quick brown fox.) Tj ET",
            fontText: Self.letters)
        #expect(try Translation.makePlan(pdf, nil, [0]).texts.map(\.text) == ["The quick brown fox jumps over the lazy dog.", "The lazy dog jumps over the quick brown fox."])
    }

    @Test func twoFootnotesEachAfterItsRaisedMarkAreTwoParagraphs() throws {
        // As attn's: each mark smaller, raised on a band of its own, just before its line.
        let pdf = ContentEditPdf.make(
            "BT /FA 6 Tf 1 0 0 1 72 106.8 Tm (1) Tj ET BT /FA 9 Tf 1 0 0 1 76 103 Tm (The quick brown fox jumps over the lazy dog.) Tj ET "
                + "BT /FA 6 Tf 1 0 0 1 72 95.8 Tm (2) Tj ET BT /FA 9 Tf 1 0 0 1 76 92 Tm (The lazy dog jumps over the quick brown fox.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { $0.replacingOccurrences(of: "The", with: "EL") }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over the lazy dog.", "The lazy dog jumps over the quick brown fox."])
        #expect(r.report.translated == 2)
        #expect(Self.runs(r.data!).filter { ["1", "2"].contains(trimmed($0.text)) }.allSatisfy { Self.near($0.fontSize, 6) }) // the marks stay
    }

    static let longAnswer = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG AND THE QUICK FOX IS THE ONE FOR THE LAZY DOG AND THE BROWN FOX."

    @Test func aNewLineIsNotWrittenInALineEndHyphensOwnTaggedPiece() throws {
        // census-p60 p. 7: each line-end hyphen is a tagged piece of its own whose /ActualText is a soft hyphen, and a new
        // line written in it read as "­" in MuPDF.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm /P <</MCID 1>> BDC (The quick brown fox jumps over the lazy dog and the quick fox is respon) Tj EMC "
                + "/Span <</MCID 2>> BDC (-) Tj EMC ET BT /FA 12 Tf 1 0 0 1 72 686 Tm /P <</MCID 3>> BDC (sible for the lazy dog and the brown fox.) Tj EMC ET",
            fontText: Self.letters + "-")
        let (_, r) = try Self.translate(pdf) { _ in Self.longAnswer }
        #expect(r.report.translated == 1)
        let content = ContentEditPdf.content(r.data!)
        let at = try #require(content.range(of: "/MCID 2"))
        let end = try #require(content.range(of: "EMC", range: at.upperBound..<content.endIndex))
        #expect(!content[at.lowerBound..<end.lowerBound].contains(" Tm"))
    }

    @Test func aNewLineGoesAfterABandPaintedBetweenALinesWordAndItsHyphen() throws {
        // Something painted over the line after its words and before its hyphen: what the line draws last still takes it.
        let first = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the quick fox is respon) Tj ET"
        let right = try Self.rightOf(first, Self.letters + "-")
        let pdf = ContentEditPdf.make(
            first + " 1 1 0.9 rg 60 696 500 14 re f 0 g BT /FA 12 Tf 1 0 0 1 \(Self.f2(right)) 700 Tm (-) Tj ET "
                + "BT /FA 12 Tf 1 0 0 1 72 686 Tm (sible for the lazy dog and the brown fox.) Tj ET",
            fontText: Self.letters + "-")
        let (_, r) = try Self.translate(pdf) { _ in Self.longAnswer }
        #expect(r.report.translated == 1)
        // No new text (a TJ with a string in it) before the band; a removed run's own TJ only moves the text position.
        let content = ContentEditPdf.content(r.data!)
        let band = try #require(content.range(of: "re f"))
        let newText = Rx(#"\[[^\]]*[(<]"#)
        #expect(!newText.isMatch(String(content[..<band.lowerBound])))
        #expect(newText.isMatch(String(content[band.lowerBound...])))
    }

    @Test func aLineOfSmallTextBesideALineIsNotTakenForItsScript() throws {
        // Longer than a mark and hardly smaller than the line it sits on: not a script.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET BT /FA 11 Tf 1 0 0 1 150 703 Tm (jumps over) Tj ET",
            fontText: Self.letters)
        let texts = try Translation.makePlan(pdf, nil, [0]).texts
        #expect(!texts.contains { $0.text.contains("<sup>") })
    }

    @Test(arguments: [
        ("NimbusRomNo9L-Medi", true, false), ("ABCDEF+NimbusRomNo9L-MediItal", true, true), ("NimbusRomNo9L-ReguItal", false, true),
        ("NimbusRomNo9L-Regu", false, false), ("MinionPro-It", false, true), ("MinionPro-BoldIt", true, true), ("ABCDEF+CMMI10", false, true),
        ("CMTI12", false, true), ("CMBX10", true, false), ("CMR10", false, false), ("CMSY10", false, false), ("Gotham-Medium", false, false),
        ("Digital-Regular", false, false), ("Seven-Digital", false, false), ("Trajan-Capital", false, false), ("Space-Orbital", false, false),
        ("Wild-Bandit", false, false), ("Garamond-SemiBoldItal", true, true),
    ])
    func fontNamesThatSayBoldOrItalic(_ name: String, _ bold: Bool, _ italic: Bool) {
        #expect(FontNames.looksBold(name) == bold)
        #expect(FontNames.looksItalic(name) == italic)
    }

    @Test func aMathItalicLetterGoesAsItalic() throws {
        // LaTeX's "d" of "d_model" in CMMI beside the text's roman.
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick fox jumps over ) Tj /FT 12 Tf (d) Tj /FA 12 Tf ( and the lazy dog.) Tj ET",
            fontText: Self.letters, faces: true, timesName: "ABCDEF+CMMI10")
        let text = try Self.text(pdf)
        #expect(text.contains("over <i>d</i> and"), "\(text)")
    }

    @Test func aTitleInNimbusRomNo9LMediIsWrittenInABoldInstalledFont() throws {
        // The section titles of LaTeX papers set in Times: the subset lacks the translation's letters.
        let pdf = ContentEditPdf.make("BT /FT 12 Tf 1 0 0 1 72 700 Tm (The Quick Brown Fox) Tj ET", fontText: Self.letters, faces: true,
                                      timesName: "NimbusRomNo9L-Medi")
        let (_, r) = try Self.translate(pdf) { _ in "El ñandú marrón" }
        #expect(r.report.translated == 1)
        #expect(r.report.fonts == ["Times New Roman Bold"], "\(r.report.fonts)")
        // Windows names the face's file ("timesbd"); here it is the installed bold Times, drawn as a stand-in.
        #expect(Self.runs(r.data!).allSatisfy { $0.standIn && $0.bold }, "\(Self.runs(r.data!).map(\.fontName))")
    }
}
