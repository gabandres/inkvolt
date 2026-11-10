import Foundation
import Testing
@testable import PdfCore

/// Inkvolt PDF for Mac 1.11.0's hostile-input review (2026-11-10): crafted pages that grouping, the stand-in fonts and
/// in-place form edits trusted too far.
extension ParagraphEditTests {
    /// A page of `count` one-letter runs side by side on one baseline: one line.
    static func oneLineOf(_ count: Int) -> [UInt8] {
        ContentEditPdf.make("BT /FA 1 Tf 20 400 Td " + String(repeating: "(a) Tj ", count: count) + "ET")
    }

    @Test func aLineOfThousandsOfRunsIsGroupedInTimeLinearInThem() throws {
        // Each run added to a line used to tally the line's fonts again: 4,800 runs took 16 times what 1,200 did.
        let small = Self.oneLineOf(1_200), large = Self.oneLineOf(4_800)
        _ = try ContentEditor.read(small, nil, 0)
        func seconds(_ pdf: [UInt8]) throws -> Double {
            var best = Double.infinity
            for _ in 0..<3 {
                let start = threadSeconds()
                let c = try ContentEditor.read(pdf, nil, 0)
                best = min(best, threadSeconds() - start)
                #expect(c.paragraphs.count == 1)
            }
            return best
        }
        let a = try seconds(small), b = try seconds(large)
        #expect(b < 8 * a + 0.05, "1,200 runs \(a) s, 4,800 runs \(b) s")
    }

    @Test func aPageOfMoreRunsThanAreGroupedIsEditedRunByRun() throws {
        // Grouping looks at every run for each paragraph: past `maxRunsToGroup` the page has no paragraphs (its runs edit
        // one by one, as before paragraph editing) rather than pinning a core.
        var content = "BT /FA 4 Tf "
        for i in 0..<(ContentEditor.maxRunsToGroup + 1) { content += "1 0 0 1 \(20 + (i % 50) * 11) \(780 - (i / 50) * 7) Tm (a) Tj " }
        let c = try ContentEditor.read(ContentEditPdf.make(content + "ET"), nil, 0)
        #expect(c.runs.count == ContentEditor.maxRunsToGroup + 1)
        #expect(c.paragraphs.isEmpty)
        let fewer = try ContentEditor.read(ContentEditPdf.make("BT /FA 4 Tf 20 780 Td (a) Tj ET"), nil, 0)
        #expect(fewer.paragraphs.count == 1)
    }

    @Test func aType3FontOnlyNamedLikeAStandInIsBlocked() throws {
        // A stand-in's /Widths are thousandths of an em because its /FontMatrix says so; a crafted Type 3 font named /InkFb…
        // with another matrix would be read in the wrong units.
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello World) Tj ET")
        let r = try #require(try ContentEditor.read(pdf, nil, 0).runs.first { $0.text.hasPrefix("Hello") })
        let edited = try ContentEditor.replaceText(pdf, nil, r, "Hello Zebra")
        func zBlocked(_ pdf: [UInt8]) throws -> Bool {
            try #require(try ContentEditor.read(pdf, nil, 0).runs.first { $0.text == "Z" }).blocked != nil
        }
        #expect(try !zBlocked(edited))
        let doc = try PdfEdit.open(edited, nil)
        let fonts = try #require(doc.page(0).dict("Resources")?.dict("Font"))
        let key = try #require(fonts.keys.first { $0.hasPrefix(ContentEditor.standInKey) })
        let font = try #require(fonts.dict(key))
        #expect(TextFont.isStandInMatrix(font.array("FontMatrix")))
        font.set("FontMatrix", doc.reals(1, 0, 0, 1, 0, 0))
        try doc.checkFailure()
        #expect(try zBlocked(try doc.write("")))
    }

    @Test func aFormThatIsAlsoAStampsFaceIsCopiedBeforeAnEdit() throws {
        // The page draws /Fm1 once, and a stamp shows the same form as its face: an edit in place would change the stamp too.
        let line = "A single line of text drawn by a form"
        let base = ContentEditPdf.make("q /Fm1 Do Q", form: "BT /FA \(Self.n(Self.size)) Tf 72 700 Td (\(line)) Tj ET", fontText: Self.chars)
        let doc = try PdfEdit.open(base, nil)
        let page = doc.page(0)
        let form = try #require(page.dict("Resources")?.dict("XObject")?["Fm1"])
        let stamp = doc.dict([("Type", doc.name("Annot")), ("Subtype", doc.name("Stamp")), ("Rect", doc.reals(300, 100, 400, 150)),
                              ("AP", doc.dict([("N", form)]))])
        page.set("Annots", doc.array([doc.add(stamp)]))
        try doc.checkFailure()
        let pdf = try doc.write("")
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first { $0.text == line })
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Changed text in the form")
        #expect(try ContentEditor.read(edited, nil, 0).paragraphs.contains { $0.text == "Changed text in the form" })
        let after = try PdfEdit.open(edited, nil)
        let face = try #require(after.page(0).array("Annots")?[0]?.dict("AP")?.dict("N"))
        #expect(String(decoding: face.streamData ?? [], as: UTF8.self).contains(line), "the stamp's face changed with the page")
    }

    @Test func formsAPatternDrawsAreFoundInsideTheFormsThePageDraws() throws {
        // The page draws form Y; Y's resources hold a tiling pattern whose tile draws X, and Y draws X too: X is drawn
        // outside the page's content (by the pattern), Y isn't. Four forms under X (eight levels from the page) are found too.
        let doc = try MuDoc.create()
        func form(_ resources: PObj? = nil) -> PObj {
            var entries: [(String, PObj)] = [("Type", doc.name("XObject")), ("Subtype", doc.name("Form")), ("BBox", doc.reals(0, 0, 10, 10))]
            if let resources { entries.append(("Resources", resources)) }
            return doc.addStream(latin1Bytes("0 0 m 1 1 l S"), dict: doc.dict(entries), deflate: false)
        }
        let deepest = form()
        var deep = deepest
        for _ in 0..<4 { deep = form(doc.dict([("XObject", doc.dict([("D", deep)]))])) }
        let x = form(doc.dict([("XObject", doc.dict([("D", deep)]))]))
        let pattern = doc.addStream(latin1Bytes("/X Do"), dict: doc.dict([("PatternType", doc.int(1)), ("PaintType", doc.int(1)), ("TilingType", doc.int(1)),
                                                                          ("BBox", doc.reals(0, 0, 10, 10)), ("XStep", doc.int(10)), ("YStep", doc.int(10)),
                                                                          ("Resources", doc.dict([("XObject", doc.dict([("X", x)]))]))]), deflate: false)
        let y = form(doc.dict([("XObject", doc.dict([("X", x)])), ("Pattern", doc.dict([("P", pattern)]))]))
        let page = doc.add(doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, 612, 792)),
                                     ("Resources", doc.dict([("XObject", doc.dict([("Y", y)]))])),
                                     ("Contents", doc.addStream(latin1Bytes("/Y Do"), deflate: false))]))
        doc.insertPage(page, at: 0)
        try doc.checkFailure()
        let outside = ContentEditor.formsDrawnOutsideContent(doc)
        #expect(outside.contains(x.id))
        #expect(!outside.contains(y.id))
        #expect(outside.contains(deepest.id), "four forms under the pattern's, eight levels in all")
    }

    @Test func freeResourceNamesAreFoundInOnePass() {
        #expect(ContentEditor.lowestFree(["InkFb1_a", "InkFb3_x", "InkFb01_", "InkFb2"], "InkFb", suffix: "_") == 2)
        #expect(ContentEditor.lowestFree(["InkFm1", "InkFm2", "InkFm10", "InkFm3x"], "InkFm") == 3)
        #expect(ContentEditor.lowestFree([], "InkImg") == 1)
        // A crafted dictionary of 100,000 such names: the next one at once, not after searching them all for each number.
        let keys = (1...100_000).map { "InkFb\($0)_" }
        let start = threadSeconds()
        #expect(ContentEditor.lowestFree(keys, "InkFb", suffix: "_") == 100_001)
        #expect(threadSeconds() - start < 5)
    }
}
