import Foundation
import Testing
@testable import PdfCore

/// The rest of Windows' `TranslationCopyTests` (roadmap 3.1): links, protection, clips and bands, columns, crafted files,
/// and the roadmap's 100-page test through a real socket.
@Suite(.serialized) struct TranslationCopyMoreTests {
    typealias T = TranslationCopyTests
    static let letters = T.letters
    static let marked = T.marked

    static func n(_ v: Double) -> String { ContentLexer.number(v) }

    /// A paragraph of three lines whose second has the links `links` drawn in blue (" and " between them), its first line
    /// `first`, underlined as `underline` draws them (given each link's box, page as shown; nil: a thin blue rectangle
    /// filled for each), with a /Link annotation over each unless `annotate` is false. Returns each underline's box.
    static func linkedParagraph(_ links: [String], underline: (([RectD]) -> String)? = nil, annotate: Bool = true,
                                first: String = "The quick brown fox jumps over the lazy dog and the") -> (pdf: [UInt8], underlines: [RectD]) {
        func content(_ drawn: String) -> String {
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (\(first)) Tj 1 0 0 1 72 686 Tm (fox goes on over ) Tj "
                + links.map { "0 0 1 rg (\($0)) Tj 0 g " }.joined(separator: "( and ) Tj ") + "( and a lazy dog until the) Tj "
                + "1 0 0 1 72 672 Tm (end of the day.) Tj ET " + drawn
        }
        let plain = T.page(content(""), fontText: letters)
        let runs = T.read(plain).runs
        let boxes = links.map { l in runs.first { $0.text == l && $0.box.y > 792 - 700 }!.box }
        // Under the baseline (y 686 in PDF space), half a point thick.
        let underlines = boxes.map { RectD.fromEdges($0.x, 792 - 686 + 1.5, $0.right, 792 - 686 + 2) }
        let draw = underline ?? { bs in bs.map { "0 0 1 rg \(n($0.x)) \(n(686 - 2)) \(n($0.width)) 0.5 re f " }.joined() }
        let pdf = T.page(content(draw(boxes)), fontText: letters)
        guard annotate else { return (pdf, underlines) }
        let doc = try! PdfEdit.open(pdf, nil)
        let annots = doc.array()
        for box in boxes {
            let action = doc.dict([("S", doc.name("URI")), ("URI", doc.string(Array("https://example.com/".utf8)))])
            annots.append(doc.add(doc.dict([
                ("Type", doc.name("Annot")), ("Subtype", doc.name("Link")), ("Rect", doc.reals(box.x, 792 - box.bottom, box.right, 792 - box.y)),
                ("Border", doc.array([doc.int(0), doc.int(0), doc.int(0)])), ("A", action),
            ])))
        }
        doc.page(0).set("Annots", annots)
        try! doc.checkFailure()
        return (try! doc.write(""), underlines)
    }

    static func taller(_ r: RectD) -> RectD { .fromEdges(r.x, r.y - 1, r.right, r.bottom + 1) }

    /// Blue pixels (a link's underline) in a box of the page as shown, at 4 px a point.
    static func bluePixels(_ pdf: [UInt8], _ box: RectD) -> Int {
        let engine = try! PdfEngine.open(pdf)
        defer { engine.close() }
        let image = try! engine.render(0, scale: 4, annotations: false)
        var count = 0
        let y0 = Int(box.y * 4), y1 = min(Int((box.bottom * 4).rounded(.up)), image.height)
        let x0 = Int(box.x * 4), x1 = min(Int((box.right * 4).rounded(.up)), image.width)
        if y0 >= y1 || x0 >= x1 { return 0 }
        for y in max(0, y0)..<y1 {
            for x in max(0, x0)..<x1 {
                let i = y * image.stride + 3 * x
                if image.pixels[i + 2] > 180 && image.pixels[i] < 90 && image.pixels[i + 1] < 90 { count += 1 } // RGB
            }
        }
        return count
    }

    static func found(_ pdf: [UInt8], _ query: String) -> (links: [PageLink], hits: [RectD]) {
        let engine = try! PdfEngine.open(pdf)
        defer { engine.close() }
        let text = try! engine.text(0, cache: false)
        let hits = text.find(query, matchCase: true, wholeWord: false).map { h in text.rects(h.start, h.end).dropFirst().reduce(text.rects(h.start, h.end)[0]) { $0.union($1) } }
        return ((try? engine.links(0)) ?? [], hits)
    }

    static let keepsQuickFox = "Now a lazy dog jumps over the brown fox, and the QUICK FOX 42 sits there until the end of the day."

    @Test func aLinksAreaAndUnderlineFollowItsWordsWhenTheTranslationKeepsThem() throws {
        let (pdf, underlines) = Self.linkedParagraph(["QUICK FOX 42"])
        let underline = underlines[0]
        #expect(Self.bluePixels(pdf, Self.taller(underline)) > 0)
        let (_, r) = try T.translate(pdf) { _ in Self.keepsQuickFox }
        let (links, hits) = Self.found(r.data!, "QUICK FOX 42")
        #expect(hits.count == 1)
        let words = try #require(hits.first)
        #expect(abs(words.x - underline.x) > 5, "the words moved") // else the test shows nothing
        // The link covers the words where they are now, not where they were.
        #expect(links.count == 1)
        let area = try #require(links.first?.area)
        #expect(abs(area.x - words.x) <= 1.5 && abs(area.right - words.right) <= 1.5, "\(area) \(words)")
        #expect(area.y < words.centerY && area.bottom > words.centerY, "\(area) \(words)")
        // The underline is under them now, and gone from where they were.
        #expect(Self.bluePixels(r.data!, .fromEdges(words.x + 1, words.centerY, words.right - 1, words.bottom + 6)) > 0)
        if Self.taller(underline).intersect(.fromEdges(words.x, words.y, words.right, words.bottom + 6)).isEmpty {
            #expect(Self.bluePixels(r.data!, Self.taller(underline)) == 0)
        }
    }

    @Test func aLinkWhoseWordsTheTranslationDoesntKeepIsDroppedWithItsUnderline() throws {
        let (pdf, _) = Self.linkedParagraph(["QUICK FOX 42"])
        let (_, r) = try T.translate(pdf) { _ in "Now a lazy dog jumps over the brown fox, and the quick one sits there until the end of the day." }
        #expect(Self.found(r.data!, "x").links.isEmpty)
        let doc = try Core2Pdf.open(r.data!)
        #expect((doc.page(0).array("Annots")?.count ?? 0) == 0)
        #expect(Self.bluePixels(r.data!, RectD(0, 0, 612, 792)) == 0)
    }

    @Test func anUnderlineThatBelongsToNoLinkStaysAsDrawn() throws {
        let (pdf, underlines) = Self.linkedParagraph(["QUICK FOX 42"], annotate: false)
        let (_, r) = try T.translate(pdf) { _ in Self.keepsQuickFox }
        #expect(Self.bluePixels(r.data!, Self.taller(underlines[0])) > 0)
    }

    @Test func aLinksUnderlineInAColorThatCantBeDrawnAgainStaysAsDrawn() throws {
        // Stroked: its color isn't followed (only a plain fill's is), so it couldn't be drawn again under the words.
        let (pdf, underlines) = Self.linkedParagraph(["QUICK FOX 42"], underline: { bs in
            bs.map { "0 0 1 RG 0.5 w \(Self.n($0.x)) \(Self.n(686 - 1.75)) m \(Self.n($0.right)) \(Self.n(686 - 1.75)) l S " }.joined()
        })
        #expect(Self.bluePixels(pdf, Self.taller(underlines[0])) > 0)
        let (_, r) = try T.translate(pdf) { _ in Self.keepsQuickFox }
        #expect(Self.bluePixels(r.data!, Self.taller(underlines[0])) > 0)
    }

    @Test func twoLinksUnderlinesFilledByOneOperatorStayAsDrawn() throws {
        let (pdf, underlines) = Self.linkedParagraph(["QUICK FOX 42", "LAZY DOG 7"], underline: { bs in
            "0 0 1 rg " + bs.map { "\(Self.n($0.x)) \(Self.n(686 - 2)) \(Self.n($0.width)) 0.5 re " }.joined() + "f "
        })
        let (_, r) = try T.translate(pdf) { _ in "Now a lazy dog jumps over the brown fox, and the QUICK FOX 42 and the LAZY DOG 7 sit there until the end of the day." }
        for u in underlines { #expect(Self.bluePixels(r.data!, Self.taller(u)) > 0, "\(u)") }
    }

    @Test func aLinksWordsAreFoundAtEachPlaceTheNewTextHasThem() {
        // Spaces don't count: "800-" "63A," is "800-63A,"; each place is found, an untelling stretch ("the") isn't.
        #expect(ContentEditor.follow(["SP", "800-63A"], ["see", "800-", "63A,", "and", "the", "(800-63A)"], []).map { [$0.start, $0.count] } == [[1, 2], [5, 1]])
        #expect(ContentEditor.follow(["the", "and"], ["the", "and", "dog"], []).isEmpty)
        #expect(ContentEditor.follow(["800-63A"], ["800-63A", "x", "800-63A"], [0]).map { [$0.start, $0.count] } == [[2, 1]])
    }

    @Test func aPagesUnderlinesStayUntilItsLinksAreMoved() throws {
        // Links are moved once the copy's fonts are in it (TranslationWriter.finish); until then, and if moving them
        // fails, the underlines stay with them as they were.
        let (pdf, underlines) = Self.linkedParagraph(["QUICK FOX 42"])
        let doc = try PdfEdit.open(pdf, nil)
        let writer = ContentEditor.TranslationWriter(doc, "T")
        let (_, written, _) = try ContentEditor.translatePage(writer, 0, [], [], { _, _ in Self.keepsQuickFox }, nil)
        #expect(written.count == 1)
        #expect(Self.bluePixels(try doc.write(""), Self.taller(underlines[0])) > 0)
    }

    @Test func aLinkFollowsItsOwnWordsWhereTheTranslationHasThemTwice() throws {
        // "QUICK FOX 42" on the first line too, not linked: the link stays on the second, where its words were.
        let (pdf, _) = Self.linkedParagraph(["QUICK FOX 42"], first: "QUICK FOX 42 and the quick brown fox jumps over the")
        let (_, r) = try T.translate(pdf) { _ in
            "QUICK FOX 42 and the quick brown fox jumps over the fox goes on over QUICK FOX 42 and a LAZY DOG until the end of the day."
        }
        let (links, hits) = Self.found(r.data!, "QUICK FOX 42")
        #expect(hits.count == 2)
        #expect(links.count == 1)
        if hits.count == 2, let area = links.first?.area {
            let second = hits[1]
            #expect(abs(area.x - second.x) <= 1.5, "\(area) \(second)")
            #expect(area.y < second.centerY && area.bottom > second.centerY, "\(area) \(second)")
        }
    }

    @Test func aProtectedFileKeepsItsProtectionAndACopysLanguageIsTheNewOne() throws {
        let plain = T.page(T.lines(72, 700, 12, 14, "Hello World"), fontText: Self.letters)
        let (_, r) = try T.translate(plain, { _ in "THE DOG" }, tag: "es")
        #expect(try Core2Pdf.open(r.data!).catalog.text("Lang") == "es")
        let (_, again) = try T.translate(r.data!, { _ in "THE FOX" }, tag: nil)
        #expect(try Core2Pdf.open(again.data!).catalog["Lang"] == nil)

        let locked = try PdfSecurity.protect(plain, nil, userPassword: nil, ownerPassword: "owner")
        // Opened only to read: said before anything is sent.
        #expect(throws: OwnerPasswordRequired.self) { _ = try Translation.makePlan(locked, nil, [0]) }
        let (_, safe) = try T.translate(locked, { _ in "THE DOG" }, password: "owner")
        #expect(throws: OwnerPasswordRequired.self) { _ = try PdfEdit.open(safe.data!, nil) }
        let engine = try PdfEngine.open(safe.data!, password: "owner")
        defer { engine.close() }
        #expect(try engine.text(0, cache: false).text.contains("THE DOG"))
    }

    @Test func translatingATranslatedCopyWorksAndFontsDontCollide() throws {
        let pdf = T.page(T.lines(72, 700, 12, 14, "Hello World draft, 2024!") + T.lines(72, 650, 12, 14, "2024 draft!"))
        let (_, first) = try T.translate(pdf) { $0.hasPrefix("Hello") ? "Un ñandú corre" : "Otro ñandú" }
        let (_, second) = try T.translate(first.data!) { $0.hasPrefix("Un") ? "Ein ß Läufer" : $0 }
        let text = ContentEditPdf.text(second.data!)
        #expect(text.contains("Ein ß Läufer") && text.contains("Otro ñandú"), "\(text)")
    }

    @Test func aStandInFaceIsEmbeddedOnceHoweverManyPagesUseIt() throws {
        let pdf = TranslationPdf.report(20)
        let (_, r) = try T.translate(pdf) { "\(Self.marked) \($0)" }
        let doc = try Core2Pdf.open(r.data!)
        var objects = Set<Int>(), faces = Set<String>()
        for i in 0..<(try doc.pageCount()) {
            let fonts = try #require(doc.page(i).dict("Resources")?.dict("Font"))
            for key in fonts.keys where key.hasPrefix("InkFb") {
                if let f = fonts[key], f.isRef { objects.insert(f.num) }
                faces.insert(fonts.dict(key)?.name("BaseFont") ?? "")
            }
        }
        #expect((1...4).contains(faces.count), "\(faces)") // a face per style of the page's fonts
        #expect(objects.count <= 12, "\(objects.count) font objects") // each Type 3 font of 255 codes once, not once a page
        #expect(r.data!.count < pdf.count * 3 + 1_500_000, "\(pdf.count) → \(r.data!.count)")
    }

    static func whiteHello(_ under: String) -> [UInt8] {
        T.page(under + "1 1 1 rg " + T.lines(75, 695, 12, 14, "Hello") + "0 0 0 rg " + T.lines(72, 400, 10, 12, "2024 draft!"), fontText: letters)
    }

    @Test(arguments: [
        "0 G 20 w 72 700 m 132 700 l S ", // a wide dark stroke: not a band the page filled, so how far it reaches isn't known
        "1 1 1 rg 60 600 400 150 re f 0 G 20 w 72 700 m 132 700 l S ", // a white card with a dark stroke on it, the text on the stroke
        "0 0 0.5 rg 72 688 300 22 re f q 60 0 0 22 72 688 cm /Im1 Do Q ", // a dark band with a picture on it, the text on the picture
    ])
    func whiteTextOnSomethingOtherThanADarkBandStaysInItsBox(_ under: String) throws {
        let pdf = Self.whiteHello(under)
        let before = try #require(T.read(pdf).paragraphs.first { $0.text == "Hello" })
        let (_, r) = try T.translate(pdf) { $0 == "Hello" ? "THE QUICK BROWN FOX" : "THE DOG" }
        let text = try #require(T.read(r.data!).paragraphs.first { $0.text == "THE QUICK BROWN FOX" })
        #expect(text.box.right <= before.box.right + 1, "\(text.box.right) past \(before.box.right)")
        #expect(text.fontSize < 12)
    }

    @Test func whiteTextOnABandThePageFilledUsesTheBandsRoom() throws {
        // NIST's "Purpose" heading: white on a dark band drawn just before it, the band much wider than the word.
        let (_, r) = try T.translate(Self.whiteHello("0 0 0.5 rg 72 688 300 22 re f ")) { $0 == "Hello" ? "THE QUICK BROWN FOX" : "THE DOG" }
        let text = try #require(T.read(r.data!).paragraphs.first { $0.text == "THE QUICK BROWN FOX" })
        #expect(abs(text.fontSize - 12) < 0.1)
        #expect(text.box.right <= 372, "\(text.box.right) past the band")
        #expect(abs(text.box.x - 75) < 0.1)
    }

    @Test func textDoesntGrowOutOfWhatClipsIt() throws {
        // Inside a clip only as tall as its line: below that it wouldn't show, whatever the text extraction says.
        let pdf = T.page("q 72 690 300 20 re W n " + T.lines(72, 695, 12, 14, "Hello World") + "Q", fontText: Self.letters)
        let (_, r) = try T.translate(pdf) { _ in T.repeated("The quick brown fox jumps over a lazy dog.", 6) }
        let p = try #require(T.read(r.data!).paragraphs.first { $0.text.hasPrefix("The") })
        #expect(p.fontSize < 12)
        // At the smallest size it can't fit: said so, not hidden silently.
        #expect(r.report.doNotFit == 1)
        #expect(p.box.y >= 792 - 710 - 1)
        #expect(p.box.right <= 372 + 1, "\(p.box.right)")
    }

    @Test func textStaysInsideTheClipOfItsLastLineWhenItsFirstLineHasNone() throws {
        let pdf = T.page(T.lines(72, 700, 12, 14, "Hello World draft, 2024!") + "q 72 660 300 40 re W n " + T.lines(72, 686, 12, 14, "draft Hello World draft") + "Q",
                         fontText: "Hello World draft, 2024!THEDOGQUICKBROWNFX")
        let (_, r) = try T.translate(pdf) { _ in T.repeated("THE QUICK BROWN FOX", 4) }
        #expect(r.report.shrunk == 1 && r.report.doNotFit == 0, "\(r.report.shrunk) shrunk, \(r.report.doNotFit) don't fit")
        #expect(TranslationInk.problems(r.data!, 0).isEmpty, "\(TranslationInk.problems(r.data!, 0))")
    }

    @Test func textInAFormStaysInsideTheFormsBox() throws {
        // The form's /BBox clips like any clip: here the form is the page's size, so a clip inside it does the same job.
        let form = "q 72 590 200 20 re W n " + T.lines(72, 595, 12, 14, "Hello World") + "Q"
        let (_, r) = try T.translate(T.page("/Fm1 Do", form, fontText: Self.letters)) { _ in T.repeated("The quick brown fox jumps.", 4) }
        #expect(r.report.doNotFit == 1 || r.report.shrunk == 1)
        for run in T.read(r.data!).runs where run.text.contains("quick") { #expect(run.box.right <= 272 + 1, "\(run.box.right)") }
    }

    @Test func aBigTitleAndTheSmallPrintBesideItGoApart() throws {
        let pdf = T.page("BT /FA 24 Tf 1 0 0 1 72 700 Tm (2024) Tj /FA 8 Tf 1 0 0 1 135 700 Tm (Hello World draft) Tj /FA 14 Tf 1 0 0 1 240 700 Tm (The quick brown fox) Tj ET",
                         fontText: Self.letters)
        let plan = try Translation.makePlan(pdf, nil, [0])
        #expect(plan.texts.contains { $0.text == "Hello World draft" })
        #expect(plan.texts.contains { $0.text == "The quick brown fox" })
    }

    @Test func aLabelAndWhatItLabelsGoApartAtAWideGap() throws {
        let pdf = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm (Hello World) Tj 1 0 0 1 150 700 Tm (The quick brown fox) Tj ET", fontText: Self.letters)
        #expect(try Translation.makePlan(pdf, nil, [0]).texts.map(\.text).sorted() == ["Hello World", "The quick brown fox"])
        // Word spacing a justified line stretches to is still one line.
        let one = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm (Hello) Tj 1 0 0 1 104 700 Tm (World) Tj ET", fontText: Self.letters)
        #expect(try Translation.makePlan(one, nil, [0]).texts.map(\.text) == ["Hello World"])
    }

    @Test func textStaysClearOfAFormFieldBelowIt() throws {
        let base = T.page(T.lines(72, 700, 12, 14, "Hello World") + T.lines(72, 400, 10, 12, "2024 draft!"), fontText: Self.letters)
        let doc = try PdfEdit.open(base, nil)
        let field = doc.add(doc.dict([("Type", doc.name("Annot")), ("Subtype", doc.name("Widget")), ("FT", doc.name("Tx")),
                                      ("T", doc.string(Array("x".utf8))), ("Rect", doc.reals(72, 660, 300, 680))]))
        doc.page(0).set("Annots", doc.array([field]))
        try doc.checkFailure()
        let pdf = try doc.write("")
        let (_, r) = try T.translate(pdf) { $0.hasPrefix("Hello") ? T.repeated("The quick brown fox jumps over a lazy dog.", 4) : "THE DOG" }
        let p = try #require(T.read(r.data!).paragraphs.first { $0.text.hasPrefix("The") })
        #expect(p.box.bottom <= 792 - 680 + 1, "\(p.box.bottom)")
    }

    /// A paragraph of four lines, each on a white band painted just before it.
    static func bandedLines(_ lines: [String]) -> String {
        lines.enumerated().map { i, l in "1 g 70 \(700 - i * 14 - 3) 480 14 re f 0 g BT /FA 12 Tf 1 0 0 1 72 \(700 - i * 14) Tm (\(l)) Tj ET " }.joined()
    }

    static let fourLines = [
        "Hello World draft, 2024! Hello World draft, 2024! Hello World draft, 2024! Hello",
        "World draft, 2024! Hello World draft, 2024! Hello World draft, 2024! Hello World",
        "draft, 2024! Hello World draft, 2024! Hello World draft, 2024! Hello World draft,",
        "2024! Hello World draft.",
    ]

    static let spanish = "Había una vez un ñandú que corría por el campo con mucha prisa, y detrás de él otro ñandú que no corría tanto, porque hacía calor en el campo y el señor del lugar los miraba desde lejos"

    @Test func everyLineOfAParagraphShowsWhenEachOldLineHadABandPaintedUnderItInTheStandInFont() throws {
        let text = Self.spanish + " con mucha atención y sin decir una sola palabra."
        let (_, r) = try T.translate(T.page(Self.bandedLines(Self.fourLines))) { _ in text }
        #expect(!r.report.fonts.isEmpty)
        #expect(TranslationInk.solid(ContentEditPdf.text(r.data!)).contains(TranslationInk.solid(text)))
        #expect(TranslationInk.problems(r.data!, 0).isEmpty, "\(TranslationInk.problems(r.data!, 0))")
    }

    @Test func everyLineOfAParagraphShowsWhenEachOldLineHadABandPaintedUnderItInThePagesOwnFont() throws {
        let lines = Self.fourLines.map {
            $0.replacingOccurrences(of: "Hello World draft, 2024!", with: "The quick brown fox.").replacingOccurrences(of: "World draft, 2024!", with: "the lazy dog.")
                .replacingOccurrences(of: "draft, 2024!", with: "a dog.").replacingOccurrences(of: "2024!", with: "The").replacingOccurrences(of: "Hello", with: "The")
                .replacingOccurrences(of: "World", with: "dog").replacingOccurrences(of: "draft", with: "fox")
        }
        let text = T.repeated("The lazy dog jumps over a quick brown fox until the fox is done.", 4)
        let (_, r) = try T.translate(T.page(Self.bandedLines(lines), fontText: Self.letters)) { _ in text }
        #expect(r.report.fonts.isEmpty)
        #expect(TranslationInk.solid(ContentEditPdf.text(r.data!)).contains(TranslationInk.solid(text)))
        #expect(TranslationInk.problems(r.data!, 0).isEmpty, "\(TranslationInk.problems(r.data!, 0))")
    }

    @Test func everyLineShowsWhenEachOldLineWasClippedToItself() throws {
        let content = Self.fourLines.enumerated().map { i, l in "q 70 \(700 - i * 14 - 3) 480 14 re W n BT /FA 12 Tf 1 0 0 1 72 \(700 - i * 14) Tm (\(l)) Tj ET Q " }.joined()
        let (_, r) = try T.translate(T.page(content)) { _ in Self.spanish + "." }
        #expect(TranslationInk.problems(r.data!, 0).isEmpty, "\(TranslationInk.problems(r.data!, 0))")
    }

    @Test func smallCapitalsDrawnALetterSizeAtATimeStayOneText() throws {
        // No gap between the sizes: a word, as Word draws small capitals. Set apart they'd go to the model as "D" and "IGITAL".
        let seed = T.read(T.page("BT /FA 10 Tf 1 0 0 1 300 700 Tm (D) Tj ET", fontText: "DIGTAL"))
        let after = 300 + seed.runs[0].box.width
        let pdf = T.page("BT /FA 10 Tf 1 0 0 1 300 700 Tm (D) Tj /FA 8 Tf 1 0 0 1 \(Self.n(after)) 700 Tm (IGITAL) Tj ET", fontText: "DIGTAL")
        #expect(try Translation.makePlan(pdf, nil, [0]).texts.map(\.text) == ["DIGITAL"])
    }

    @Test func aShortLineGoingOnInLowercaseStaysWithTheSentence() throws {
        // Ragged text in a narrow column: the first line ends short (the next word would fit), mid-sentence.
        let pdf = T.page(T.lines(72, 700, 12, 14, "The quick brown", "fox jumps over a lazy dog", "until the dog is done.", "THE DOG"), fontText: Self.letters)
        #expect(try Translation.makePlan(pdf, nil, [0]).texts.contains { $0.text.hasPrefix("The quick brown fox jumps over a lazy dog until") })
        // In the editor they stay apart, as they were.
        #expect(T.read(pdf).paragraphs.contains { $0.text == "The quick brown" })
    }

    @Test func textInASpotColorIsntTakenForWhite() throws {
        // "1 scn" in a Separation space is full ink. Read as white, a heading would be held to its old box as if it sat on a dark band.
        let base = T.page("/Spot cs 1 scn " + T.lines(72, 700, 12, 14, "Hello") + "0 g " + T.lines(72, 400, 12, 14, "The quick brown fox jumps over a lazy dog and goes on and on until the dog"),
                          fontText: Self.letters)
        let doc = try PdfEdit.open(base, nil)
        let tint = doc.add(doc.dict([("FunctionType", doc.int(2)), ("N", doc.int(1)), ("Domain", doc.reals(0, 1)), ("C0", doc.reals(1, 1, 1)), ("C1", doc.reals(0, 0, 1))]))
        let res = try #require(doc.page(0).dict("Resources"))
        res.set("ColorSpace", doc.dict([("Spot", doc.array([doc.name("Separation"), doc.name("Blue"), doc.name("DeviceRGB"), tint]))]))
        try doc.checkFailure()
        let (_, r) = try T.translate(try doc.write("")) { $0 == "Hello" ? "THE QUICK BROWN FOX" : $0 }
        #expect(r.report.shrunk == 0)
        #expect(abs((T.read(r.data!).paragraphs.first { $0.text == "THE QUICK BROWN FOX" }?.fontSize ?? 0) - 12) < 0.1)
    }

    @Test func figuresBesideALabelStayInTheirColumn() throws {
        let pdf = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm (Hello World) Tj 1 0 0 1 137 700 Tm (2024) Tj 1 0 0 1 170 700 Tm (2024) Tj ET", fontText: Self.letters)
        let (plan, r) = try T.translate(pdf) { _ in "THE DOG" }
        #expect(plan.texts.map(\.text) == ["Hello World"])
        #expect(T.read(r.data!).runs.filter { $0.text == "2024" }.map { $0.box.x.rounded() }.sorted() == [137, 170])
    }

    static func width(_ pdf: [UInt8], _ s: String) -> Double {
        let font = T.read(pdf).runs[0].font!
        return font.encode(s).codes.reduce(0.0) { $0 + font.widthOf($1) } / 1000 * 10
    }

    @Test func figuresDrawnByTheLabelsOwnOperatorStayInTheirColumns() throws {
        // A table row as attn-v7 and the census draw it: the label and its figures in one TJ, columns made by adjustments.
        let pdf = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm [(Hello World) -2000 (2024) -1500 (1999)] TJ ET", fontText: Self.letters)
        let first = 72 + Self.width(pdf, "Hello World") + 20
        let second = first + Self.width(pdf, "2024") + 15
        let (plan, r) = try T.translate(pdf) { _ in "THE DOG" }
        #expect(plan.texts.map(\.text) == ["Hello World"])
        let runs = T.read(r.data!).runs
        #expect(runs.contains { $0.text.contains("THE DOG") })
        #expect(!runs.contains { $0.text.contains("Hello") })
        #expect(abs((runs.first { trimmed($0.text) == "2024" }?.box.x ?? 0) - first) < 0.01)
        #expect(abs((runs.first { trimmed($0.text) == "1999" }?.box.x ?? 0) - second) < 0.01)
    }

    @Test func aJustifiedLinesYearStaysInItsSentence() throws {
        // pdfTeX's justified line: every space a stretched adjustment, a year among the words.
        let pdf = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm [(results)-650(from)-680(1999)-650(onward)] TJ ET", fontText: Self.letters)
        #expect(try T.translate(pdf) { _ in "THE DOG" }.plan.texts.map(\.text) == ["results from 1999 onward"])
    }

    @Test func everyGlyphOfAnOperatorsColumnsIsDrawnAgain() throws {
        // The space after "2024" is between two columns: it goes with one of them, not with neither.
        let pdf = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm [(Hello World) -2000 (2024 ) -1500 (1999)] TJ ET", fontText: Self.letters)
        let (_, r) = try T.translate(pdf) { _ in "THE DOG" }
        #expect(T.read(r.data!).runs.first { trimmed($0.text) == "2024" }?.text == "2024 ")
    }

    @Test func columnsOfANextLineOperatorStayWhereTheyWere() throws {
        // ' moves to the next line before it draws: the kept column is drawn on that line, and what follows after it.
        let pdf = T.page("BT /FA 10 Tf 12 TL 1 0 0 1 72 712 Tm (Hello World       2024) ' (!) Tj ET", fontText: Self.letters)
        let before = T.read(pdf).runs
        let (plan, r) = try T.translate(pdf) { _ in "THE DOG" }
        #expect(plan.texts.map { trimmed($0.text) } == ["Hello World"])
        let runs = T.read(r.data!).runs
        #expect(runs.contains { $0.text.contains("THE DOG") })
        let was = try #require(before.first { $0.text == "!" }?.box)
        let now = try #require(runs.first { $0.text == "!" }?.box)
        #expect(abs(was.x - now.x) < 0.01 && abs(was.y - now.y) < 0.01, "\(was) → \(now)")
        let year = try #require(runs.first { trimmed($0.text) == "2024" }?.box)
        #expect(abs(year.y - was.y) < 0.01 && abs(year.right - was.x) < 0.1, "\(year) beside \(was)")
    }

    @Test func columnsAreToldApartAlikeInOneOperatorAndBetweenOperators() throws {
        // What follows a label 0.9 ems on, drawn by the label's own TJ or by an operator of its own: a leader's dots or any
        // other value with no letters is a column.
        let probe = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm (Hello World) Tj ET", fontText: Self.letters)
        func texts(_ left: String, _ right: String) throws -> [String] {
            let one = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm [(\(left)) -900 (\(right))] TJ ET", fontText: Self.letters)
            let two = T.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm (\(left)) Tj 1 0 0 1 \(Self.n(72 + Self.width(probe, left) + 9)) 700 Tm (\(right)) Tj ET", fontText: Self.letters)
            let found = try T.translate(two) { _ in "THE DOG" }.plan.texts.map(\.text)
            #expect(try T.translate(one) { _ in "THE DOG" }.plan.texts.map(\.text) == found)
            return found
        }
        #expect(try texts("Hello World", "...") == ["Hello World"])
        #expect(try texts("Hello World", ".!") == ["Hello World"])
    }

    @Test func aPageWhoseColumnsMakeTooManyRunsIsCrowded() throws {
        // 400 operators of 51 columns each: under the limit as operators, over it as the runs they come apart into.
        var sb = "BT /FA 2 Tf "
        let row = "[(Hello)" + String(repeating: " -2000 (1)", count: 50) + "] TJ "
        for i in 0..<400 { sb += "1 0 0 1 20 \(String(format: "%.1f", 780 - Double(i) * 1.9)) Tm " + row }
        #expect(try Translation.makePlan(T.page(sb + "ET", fontText: Self.letters), nil, [0]).crowdedPages == [0])
    }

    @Test func shortLabelsOneUnderTheOtherGoOneByOne() throws {
        // All about as wide, so no next word would fit on the line above: but they aren't one sentence.
        let pdf = T.page(T.lines(72, 700, 10, 12, "Lazy dog", "Brown fox", "Quick dog", "Lazy fox"), fontText: Self.letters)
        #expect(try Translation.makePlan(pdf, nil, [0]).texts.count == 4)
    }

    @Test func textShrinksNoSmallerThanTheFloorWhenItsFirstRunIsABiggerInitial() throws {
        // The paragraph is written at 8 points, the size most of it has: half of that would be under the 5-point floor.
        let pdf = T.page("BT /FA 12 Tf 1 0 0 1 72 700 Tm (T) Tj /FA 8 Tf 1 0 0 1 81 700 Tm (he quick brown fox jumps over a lazy dog) Tj ET " + T.lines(72, 680, 12, 14, "THE DOG"),
                         fontText: Self.letters)
        let words = T.repeated("The quick brown fox jumps over a lazy dog.", 40)
        let (_, r) = try T.translate(pdf) { $0.hasPrefix("T") && $0 != "THE DOG" ? words : "THE FOX" }
        #expect(!TranslationInk.problems(r.data!, 0).contains { $0.contains("drawn at") })
        #expect(r.report.doNotFit == 1)
    }

    @Test func textDoesntGrowUnderABandPaintedLaterForSomethingElse() throws {
        // A short text on the left, and lower down, across the page, a white band painted for a line in the right column only.
        let pdf = T.page(T.lines(72, 700, 12, 14, "Hello World") + "1 g 70 658 480 14 re f 0 g " + T.lines(350, 661, 12, 14, "2024 draft!"), fontText: Self.letters)
        let words = T.repeated("The quick brown fox jumps over a lazy dog.", 5)
        let (_, r) = try T.translate(pdf) { $0.hasPrefix("Hello") ? words : "THE DOG" }
        #expect(TranslationInk.problems(r.data!, 0).isEmpty, "\(TranslationInk.problems(r.data!, 0))")
        #expect(TranslationInk.solid(ContentEditPdf.text(r.data!)).contains(TranslationInk.solid(words)))
    }

    @Test func aNotesSmallNumberStaysAndItsFirstLineStaysWithTheRest() throws {
        let pdf = T.page("BT /FA 5 Tf 1 0 0 1 72 703 Tm (1) Tj /FA 8 Tf 1 0 0 1 76 700 Tm (The quick brown fox jumps over a lazy dog and on) Tj ET "
            + T.lines(72, 690, 8, 10, "until the lazy dog is done and the quick brown fox has gone"), fontText: Self.letters)
        let (plan, r) = try T.translate(pdf) { _ in "THE DOG" }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over a lazy dog and on until the lazy dog is done and the quick brown fox has gone"])
        #expect(T.read(r.data!).runs.contains { $0.text == "1" })
    }

    @Test func aLinkAtTheStartOfALineDoesntSplitTheParagraphOrColorIt() throws {
        // Three lines, a blue link in the second starting it: one paragraph, in the black most of it is in.
        let pdf = T.page("0 g " + T.lines(72, 700, 12, 14, "The quick brown fox jumps over a lazy dog and the")
            + "0 0 1 rg BT /FA 12 Tf 1 0 0 1 72 686 Tm (fox) Tj ET 0 g BT /FA 12 Tf 1 0 0 1 95 686 Tm (jumps over a lazy dog until the quick brown) Tj ET "
            + T.lines(72, 672, 12, 14, "fox is done."), fontText: Self.letters)
        let (plan, r) = try T.translate(pdf) { _ in "THE QUICK BROWN FOX JUMPS OVER A LAZY DOG" }
        #expect(plan.texts.count == 1)
        let runs = T.read(r.data!).runs.filter { $0.text.contains("QUICK") }
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { $0.color == 0 })
    }

    @Test func aTurnedStampInTheMarginDoesntMakeAFullLineLookCentered() throws {
        let pdf = T.page("q 0 1 -1 0 30 300 cm BT /FA 8 Tf 0 0 Td (Hello World draft stamp) Tj ET Q "
            + T.lines(72, 700, 12, 14, "The quick brown fox jumps over a lazy dog and the lazy dog is done until the") + T.lines(72, 400, 10, 12, "THE DOG"),
                         fontText: Self.letters + "stamp")
        let (_, r) = try T.translate(pdf) { $0.hasPrefix("The") ? "THE QUICK BROWN FOX" : $0 }
        #expect(abs((T.read(r.data!).paragraphs.first { $0.text == "THE QUICK BROWN FOX" }?.box.x ?? 0) - 72) < 1)
    }

    @Test func aHeadingInATightClipKeepsItsSize() throws {
        let (_, r) = try T.translate(T.page("q 72 694 400 16 re W n " + T.lines(72, 700, 14, 16, "Hello World") + "Q", fontText: Self.letters)) { _ in "THE DOG" }
        #expect(r.report.shrunk == 0)
    }

    @Test(arguments: [("ABCDEF+NimbusRomNo9L-Regu", 4, StandInFonts.Kind.serif), ("CMR10", 4, .serif), ("Gotham-Book", 34, .sans),
                      ("ABCDEF+NimbusSanL-Regu", 4, .sans), ("CMTT10", 4, .mono)])
    func aStandInIsChosenFromTheRightClass(_ name: String, _ flags: Int, _ kind: StandInFonts.Kind) {
        #expect(StandInFonts.kindOf(name, flags) == kind)
    }

    @Test func aWordHyphenatedAtALineEndGoesOutWhole() throws {
        let pdf = T.page(T.lines(72, 700, 12, 14, "The quick brown fox jumps over a lazy dog and the quick brown fox ju-", "mps over the lazy dog"), fontText: Self.letters + "-")
        let texts = try Translation.makePlan(pdf, nil, [0]).texts
        #expect(texts.count == 1 && texts[0].text.contains("fox jumps over the lazy"))
    }

    @Test func aSignedFilesCopyIsAppendedSoTheSignedVersionStaysInside() throws {
        let pdf = SignedEditTests.signed()
        let (_, r) = try T.translate(pdf) { _ in "Un contrato ñandú" }
        #expect(Array(r.data!.prefix(pdf.count)) == pdf)
        #expect(ContentEditPdf.text(r.data!).contains("ñandú"))
    }

    @Test func aStoppedRunKeepsWhatItHasAndOnlySaysWhereTheRestIs() throws {
        let pdf = T.page(T.lines(72, 700, 12, 14, "Hello World") + T.lines(72, 650, 12, 14, "2024 draft!"), fontText: Self.letters)
        let plan = try Translation.makePlan(pdf, nil, [0])
        var answers = TranslationAnswers()
        answers.cancelled = true
        answers.done["Hello World"] = "THE DOG"
        let result = try Translation.apply(plan, answers, "es")
        #expect(result.report.translated == 1)
        #expect(result.report.notTranslated == 1)
        #expect(result.report.cancelled)
        #expect(result.report.flags.count == 1 && result.report.flags[0].noted == false)
        #expect(result.report.notes == 0)
        #expect(try Annotations.read(result.data!, nil).isEmpty)
        let text = ContentEditPdf.text(result.data!)
        #expect(text.contains("THE DOG") && text.contains("2024 draft!"))
    }

    @Test func nothingTranslatedMakesNoCopy() throws {
        let plan = try Translation.makePlan(T.page(T.lines(72, 700, 12, 14, "Hello World"), fontText: Self.letters), nil, [0])
        var answers = TranslationAnswers()
        answers.stoppedBecause = "No."
        let result = try Translation.apply(plan, answers, "es")
        #expect(result.data == nil)
        #expect(result.report.notTranslated == 1)
    }

    /// Mac addition: the copy's /Resources of a page whose resources other pages share by reference no longer share a
    /// direct /Font dictionary with them (MuPDF's compacting save renumbered it once through each, and every page's
    /// fonts pointed at other objects). An edit of one page leaves the other's text readable.
    @Test func aPageEditedInAFileWhosePagesShareResourcesKeepsEveryPagesFonts() throws {
        let pdf = ContentEditPdf.make(pages: [T.lines(72, 700, 12, 14, "Hello World"), T.lines(72, 700, 12, 14, "2024 draft!")], fontText: Self.letters)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Hello ñandú")
        #expect(ContentEditPdf.text(edited, page: 0).contains("ñandú"))
        #expect(ContentEditPdf.text(edited, page: 1).contains("2024 draft!"))
    }
}
