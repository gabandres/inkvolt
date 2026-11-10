import Foundation
import Testing
@testable import PdfCore

/// Roadmap 2.1: text inside form XObjects (reused drawings) edits as paragraphs and as single runs (ported from
/// ParagraphEditTests.Forms.cs); and paragraphs in turned text, in their own direction (ParagraphEditTests.Turned.cs).
extension ParagraphEditTests {
    /// Body's lines as a left-aligned paragraph, with a line under it, as a form's content.
    static func formBody(_ text: String = body) -> String {
        let lines = wrap(text, width)
        var sb = "BT /FA \(n(size)) Tf \(n(step)) TL \(n(left)) \(n(top)) Td (\(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
        return sb + " 0 -60 Td (Inside the form too) Tj ET"
    }

    static func formStream(_ pdf: [UInt8], page: Int = 0, name: String = "Fm1") throws -> String {
        let doc = try Core2Pdf.open(pdf)
        let form = try #require(doc.page(page).dict("Resources")?.dict("XObject")?.dict(name))
        return latin1String(form.streamData ?? [])
    }

    @Test(arguments: [false, true])
    func aParagraphInsideAFormXObjectReflows(_ inherits: Bool) throws {
        let pdf = ContentEditPdf.make("q /Fm1 Do Q BT /FA 12 Tf 72 300 Td (On the page itself) Tj ET", form: Self.formBody(), formInherits: inherits,
                                      fontText: Self.chars)
        let before = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.runs.allSatisfy { $0.id < 0 })
        let inside = try Self.run(before, "Inside the form too")
        let onPage = try Self.run(before, "On the page itself")
        let text = Self.body + " " + Self.twenty
        let check = p.check(text)
        #expect(check.overlaps == nil)

        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
        let after = try ContentEditor.read(edited, nil, 0)
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(q.lines.count == check.lineCount)
        #expect(Self.equal(inside.box.y, try Self.run(after, "Inside the form too").box.y, 2))
        #expect(Self.near(onPage.box, try Self.run(after, "On the page itself").box))
        // The form's stream was rewritten; the page's own content wasn't.
        #expect(try Self.formStream(edited).contains("Then seven tired"))
        #expect(ContentEditPdf.content(pdf) == ContentEditPdf.content(edited))
    }

    @Test(arguments: [false, true])
    func standInFontsForAFormGoWithItsResources(_ inherits: Bool) throws {
        // "@" isn't in the font: drawn in a stand-in, embedded where the form's fonts are (its own resources, or the page's
        // when it borrows them).
        let pdf = ContentEditPdf.make("q /Fm1 Do Q", form: Self.formBody(), formInherits: inherits, fontText: Self.chars)
        let p = try Self.body0(pdf)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Mail me @ home, " + Self.body)
        #expect(Self.words(ContentEditPdf.text(edited)).contains("Mail me @ home"))
        let doc = try Core2Pdf.open(edited)
        let pageFonts = try #require(doc.page(0).dict("Resources")?.dict("Font"))
        let form = try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict("Fm1"))
        let formFonts = form.dict("Resources")?.dict("Font")
        let holder = inherits ? pageFonts : try #require(formFonts)
        #expect(holder.keys.contains { $0.hasPrefix("InkFb") })
        if !inherits { #expect(!pageFonts.keys.contains { $0.hasPrefix("InkFb") }) }
    }

    @Test func aFormDrawnTwiceOnThePageIsCopiedSoOnlyTheClickedOneChanges() throws {
        let pdf = ContentEditPdf.make("q /Fm1 Do Q q 1 0 0 1 0 -380 cm /Fm1 Do Q", form: Self.formBody(), fontText: Self.chars)
        let paras = try ContentEditor.read(pdf, nil, 0).paragraphs.filter { $0.text == Self.body }.sorted { $0.box.y < $1.box.y }
        #expect(paras.count == 2)
        #expect(paras.allSatisfy { $0.blocked == nil })
        let edited = try ContentEditor.replaceParagraph(pdf, nil, paras[1], Self.twenty)
        let after = try ContentEditor.read(edited, nil, 0).paragraphs.filter { $0.lines.count > 1 }.sorted { $0.box.y < $1.box.y }
        #expect(after.map(\.text) == [Self.body, Self.twenty])
        #expect(Self.near(paras[0].box, after[0].box))
        #expect(Self.equal(paras[1].box.y, after[1].box.y, 1))
        // The original form is untouched; the lower Do now draws a copy of its own.
        #expect(!(try Self.formStream(edited).contains("Then seven")))
    }

    @Test func aFormSharedWithAnotherPageIsCopiedForThisPage() throws {
        let one = ContentEditPdf.make("q /Fm1 Do Q", form: Self.formBody(), fontText: Self.chars)
        let doc = try Core2Pdf.open(one)
        let first = doc.page(0)
        let page2 = doc.add(doc.dict([
            ("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, 612, 792)), ("Resources", first["Resources"]!),
            ("Contents", doc.addStream(latin1Bytes("q /Fm1 Do Q"), deflate: false)),
        ]))
        doc.insertPage(page2, at: 1)
        try doc.checkFailure()
        let pdf = try doc.write("")
        #expect(try Self.body0(pdf).text == Self.body)
        #expect(try ContentEditor.read(pdf, nil, 1).paragraphs.first { $0.lines.count > 1 }?.text == Self.body)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, try Self.body0(pdf), Self.twenty)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(Self.twenty)))
        #expect(Self.words(ContentEditPdf.text(edited, page: 1)).contains(Self.words(Self.body)))
        #expect(try ContentEditor.read(edited, nil, 0).paragraphs.first { $0.lines.count > 1 }?.text == Self.twenty)
        #expect(try ContentEditor.read(edited, nil, 1).paragraphs.first { $0.lines.count > 1 }?.text == Self.body)
    }

    @Test func aParagraphHalfInAFormIsEditedLineByLine() throws {
        // The form draws the first two lines, the page the rest, lined up: two streams can't be rewritten as one.
        let lines = Self.wrap(Self.body, Self.width)
        let form = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL \(Self.n(Self.left)) \(Self.n(Self.top)) Td (\(lines[0])) Tj T* (\(lines[1])) Tj ET"
        var sb = "q /Fm1 Do Q BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL \(Self.n(Self.left)) \(Self.n(Self.top - 2 * Self.step)) Td (\(lines[2])) Tj"
        for l in lines.dropFirst(3) { sb += " T* (\(l)) Tj" }
        sb += " ET"
        let pdf = ContentEditPdf.make(sb, form: form, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.blocked?.contains("form XObject") == true)
    }

    @Test func aSingleRunInsideAFormIsEditedInPlace() throws {
        let pdf = ContentEditPdf.make("q /Fm1 Do Q BT /FA 12 Tf 72 600 Td (draft) Tj ET", form: "BT /FA 12 Tf 72 700 Td (Hello) Tj (World) Tj ET")
        let content = try ContentEditor.read(pdf, nil, 0)
        let hello = try Self.run(content, "Hello")
        #expect(hello.blocked == nil)
        #expect(hello.id < 0)
        let world = try Self.run(content, "World")
        let edited = try ContentEditor.replaceText(pdf, nil, hello, "Hell")
        let after = try ContentEditor.read(edited, nil, 0)
        let hell = try #require(after.runs.first { $0.id == hello.id })
        #expect(hell.text == "Hell")
        // "World" follows in the same text object: it moves with the end of "Hell", as on a page (no reflow).
        let world2 = try Self.run(after, "World")
        #expect(Self.equal(world.box.y, world2.box.y, 2))
        #expect(Self.equal(hell.box.right, world2.box.x, 0))
        #expect(try Self.formStream(edited).contains("(Hell) Tj"))
        #expect(ContentEditPdf.text(edited).contains("draft"))
    }

    @Test func picturesInsideAFormStayAsTheyAre() throws {
        let pdf = ContentEditPdf.make("q /Fm1 Do Q", form: "q 100 0 0 50 72 600 cm /Im1 Do Q BT /FA 12 Tf 72 700 Td (Hello) Tj ET")
        let content = try ContentEditor.read(pdf, nil, 0)
        #expect(content.images.count == 1)
        #expect(content.images.first?.blocked?.contains("form XObject") == true)
        #expect(try Self.run(content, "Hello").blocked == nil)
    }

    // ---- Turned text (ParagraphEditTests.Turned.cs) ----

    /// Body as a left-aligned paragraph turned `degrees` counterclockwise on an upright page (PDF space), its first
    /// baseline starting at (`x`, `y`), "Next block starts here" `gap` points under its last line in the same direction.
    static func turnedPdf(_ degrees: Double, _ x: Double, _ y: Double, gap: Double = 60, extra: String = "") -> [UInt8] {
        let r = degrees * .pi / 180
        let s = sin(r), c = cos(r)
        let lines = wrap(body, width)
        var sb = "BT /FA \(n(size)) Tf \(n(step)) TL \(n(c)) \(n(s)) \(n(-s)) \(n(c)) \(n(x)) \(n(y)) Tm (\(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
        sb += " 0 \(n(-gap)) Td (Next block starts here) Tj ET \(extra)"
        return ContentEditPdf.make(sb, fontText: chars)
    }

    /// A paragraph's lines in its own direction (as if turned upright).
    static func frameLines(_ p: TextParagraph) -> [RectD] { (p.upright ?? p).lines }

    /// Two angles are one direction (180° and -180° alike).
    static func sameDirection(_ expected: Double, _ actual: Double) -> Bool { cos((actual - expected) * .pi / 180) > 0.9999 }

    @Test(arguments: [(90.0, 150.0, 250.0), (-90, 450, 600), (180, 450, 500), (30, 150, 300)])
    func aTurnedParagraphReflowsInItsOwnDirection(_ turn: (Double, Double, Double)) throws {
        let (degrees, x, y) = turn
        let pdf = Self.turnedPdf(degrees, x, y)
        let before = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.text == Self.body)
        #expect(Self.sameDirection(-degrees, p.angle), "\(p.angle)° is not \(-degrees)°")
        #expect(p.lines.count == Self.wrap(Self.body, Self.width).count)
        #expect(Self.equal(Self.step, p.lineStep, 1))
        let next = try Self.run(before, "Next block starts here")
        #expect(!p.runs.contains { $0.id == next.id })

        let text = Self.body + " " + Self.twenty
        let check = p.check(text)
        #expect(check.overlaps == nil)
        #expect(check.lineCount > p.lines.count)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        #expect(Self.words(ContentEditPdf.text(edited)).contains(Self.words(text)))
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(Self.sameDirection(-degrees, q.angle))
        #expect(q.lines.count == check.lineCount)
        #expect(Self.equal(p.lineStep, q.lineStep, 1))
        // Its lines start where its first line did, in its own direction, and stay inside its width.
        let was = Self.frameLines(p)
        #expect(Self.frameLines(q).allSatisfy { Self.equal(was[0].x, $0.x, 1) })
        #expect(Self.equal(was[0].y, Self.frameLines(q)[0].y, 1))
        #expect((Self.frameLines(q).map(\.right).max() ?? 0) <= (was.map(\.right).max() ?? 0) + 0.5)
        let next2 = try Self.run(try ContentEditor.read(edited, nil, 0), "Next block starts here")
        #expect(Self.equal(next.box.x, next2.box.x, 2))
        #expect(Self.equal(next.box.y, next2.box.y, 2))
    }

    @Test func turnedTextRunningIntoTheBlockBelowIsReportedBeforeAnythingIsWritten() throws {
        let pdf = Self.turnedPdf(90, 150, 250, gap: 18)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.below != nil)
        let next = try Self.run(try ContentEditor.read(pdf, nil, 0), "Next block starts here")
        let check = p.check(Self.body + " " + Self.twenty)
        let overlaps = try #require(check.overlaps)
        #expect(!overlaps.intersect(next.box).isEmpty)
        let e = Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, Self.body + " " + Self.twenty) }
        #expect(e?.overlaps != nil)
    }

    @Test func turnedAndUprightTextAreNotJoinedAndClicksBetweenTurnedLinesFindTheParagraph() throws {
        // A sideways column beside an upright paragraph: two paragraphs, each in its own direction.
        let lines = Self.wrap(Self.body, Self.width)
        var upright = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL 200 700 Td (\(lines[0])) Tj"
        for l in lines.dropFirst() { upright += " T* (\(l)) Tj" }
        upright += " ET"
        let pdf = Self.turnedPdf(90, 80, 300, extra: upright)
        let content = try ContentEditor.read(pdf, nil, 0)
        let both = content.paragraphs.filter { $0.text == Self.body }
        #expect(both.count == 2)
        #expect(both.filter { abs($0.angle) < 0.5 }.count == 1)
        let turned = try #require(both.first { abs($0.angle + 90) < 0.5 })
        #expect(both.filter { abs($0.angle + 90) < 0.5 }.count == 1)
        #expect(turned.runs.allSatisfy { Self.equal(-90, $0.angle, 1) })

        // Between its first two lines (they run up the page, one beside the other), the turned paragraph.
        let l0 = turned.lines[0], l1 = turned.lines[1]
        let x = (min(l0.right, l1.right) + max(l0.x, l1.x)) / 2
        let found = try #require(content.paragraphAt(x, l0.centerY))
        #expect(found.text == turned.text && Self.near(found.box, turned.box))
    }

    @Test(arguments: [[10.0, 10.4, 10.6, 10.9], [0.3, 0.6, 0.7]])
    func eachRunIsInOneParagraphWhateverDirectionsAreNearIt(_ degrees: [Double]) throws {
        // Short lines, each turned its own few degrees (counterclockwise in PDF space), far enough apart not to join.
        var sb = ""
        for (i, d) in degrees.enumerated() {
            let r = d * .pi / 180
            sb += "BT /FA \(Self.n(Self.size)) Tf \(Self.n(cos(r))) \(Self.n(sin(r))) \(Self.n(-sin(r))) \(Self.n(cos(r))) 72 \(Self.n(700 - Double(i) * 120)) Tm (Line number \(i) of the page) Tj ET\n"
        }
        let content = try ContentEditor.read(ContentEditPdf.make(sb, fontText: Self.chars), nil, 0)
        let runs = content.runs.filter { $0.text.hasPrefix("Line number") }
        #expect(runs.count == degrees.count)
        for r in runs {
            let holding = content.paragraphs.filter { $0.runs.contains { $0.id == r.id } }
            #expect(holding.count == 1, "\(r.text) (\(r.angle)°) is in \(holding.count) paragraphs")
            // In the paragraph of its own direction: within half a degree of the paragraph's angle.
            if let h = holding.first { #expect(abs(ContentEditor.turn(r.angle - h.angle)) < 0.5, "\(r.angle) in a paragraph at \(h.angle)") }
        }
    }
}
