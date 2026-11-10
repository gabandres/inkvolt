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

    @Test func aBoldWordAndASubscriptKeepTheirLooksInThePagesOwnFaces() throws {
        let (_, r) = try Self.translate(Self.boldAndSubscript()) { _ in "a <b>brown</b> fox over d<sub>model</sub> and a dog." }
        #expect(r.report.translated == 1)
        #expect(r.report.fonts.isEmpty) // the page's own fonts have every letter
        let runs = Self.runs(r.data!)
        let bold = runs.filter { $0.text.contains("brown") }
        #expect(bold.count == 1 && bold[0].bold && trimmed(bold[0].text) == "brown", "\(bold.map(\.fontName))")
        let plain = try #require(runs.first { $0.text.contains("over") })
        #expect(!plain.bold)
        let sub = runs.filter { trimmed($0.text) == "model" }
        #expect(sub.count == 1)
        if let s = sub.first {
            #expect(abs(s.fontSize - 0.7 * plain.fontSize) < 0.1)
            #expect(abs(s.origin.y - (plain.origin.y + 0.15 * plain.fontSize)) < 0.1) // lower on the page
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
            #expect(abs(s.fontSize - 0.7 * plain.fontSize) < 0.1)
            #expect(abs(s.origin.y - (plain.origin.y + 0.15 * plain.fontSize)) < 0.1)
        }
        #expect(ContentEditPdf.text(r.data!).contains("ñandú"))
    }

    @Test func aSuperscriptRisesAndShrinksOnThePage() throws {
        let pdf = ContentEditPdf.make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog 2) Tj /FA 8 Tf 4 Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE QUICK FOX 2<sup>10</sup> AND THE DOG." }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over the lazy dog 2<sup>10</sup> until the dog."])
        let runs = Self.runs(r.data!)
        let plain = try #require(runs.first { $0.text.contains("FOX") })
        let sup = runs.filter { trimmed($0.text) == "10" }
        #expect(sup.count == 1)
        if let s = sup.first {
            #expect(abs(s.fontSize - 0.7 * plain.fontSize) < 0.1)
            #expect(abs(s.origin.y - (plain.origin.y - 0.35 * plain.fontSize)) < 0.1) // higher on the page
        }
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
        #expect(q.spans == [span(q.text, "model", lookSub)])

        let edited = try ContentEditor.replaceParagraph(r.data!, nil, q, "the fox over dmodel and a dog.")
        let runs = Self.runs(edited)
        let plain = try #require(runs.first { $0.text.contains("dog") })
        let sub = runs.filter { trimmed($0.text) == "model" }
        #expect(sub.count == 1)
        if let s = sub.first {
            #expect(abs(s.fontSize - 0.7 * plain.fontSize) < 0.1)
            #expect(abs(s.origin.y - (plain.origin.y + 0.15 * plain.fontSize)) < 0.1)
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
        #expect(sub.count == 1 && abs((sub.first?.fontSize ?? 0) - 0.7 * 12) < 0.1)
    }
}
