import Foundation
import Testing
@testable import PdfCore

/// Inkvolt PDF for Mac 1.11.0's hostile-input review (2026-11-10): link following, the copies a translation makes, and a
/// page that fails partway.
extension TranslationHostileTests {
    @Test func aLinkOverLongWordsAReplyRepeatsIsGivenUpWithinItsBudget() throws {
        // A crafted link over 64 words of 256 letters, and a reply of 4,000 short words of the same letter: every word is a
        // place the link's words could start, and each matches a little further. It is given up within the page's budget.
        let link = Array(repeating: String(repeating: "a", count: 256), count: 64)
        let text = Array(repeating: "aaaa", count: 4_000)
        let found = try Self.within(60) { ContentEditor.follow(link, text, []) }
        #expect(found.isEmpty)
        // The budget is per page: once spent, the next link isn't looked for either; a fresh one finds a link at once.
        var budget = 10
        #expect(ContentEditor.follow(["SP", "800-63A"], ["la", "SP", "800-63A,", "dice"], [], budget: &budget).isEmpty)
        #expect(ContentEditor.follow(["SP", "800-63A"], ["la", "SP", "800-63A,", "dice"], []).map { [$0.start, $0.count] } == [[1, 2]])
    }

    @Test func aLinksWordsFollowedAWordAtATimeAreFoundAsBefore() {
        // Punctuation before and after, a word split by the line's gaps, a stretch longer than the words, none at all.
        #expect(ContentEditor.follow(["(SP", "800-63A)"], ["see", "«SP", "800-", "63A»,", "x"], []).map { [$0.start, $0.count] } == [[1, 3]])
        #expect(ContentEditor.follow(["800-63A"], ["800-63AB"], []).isEmpty)
        #expect(ContentEditor.follow(["800-63A"], ["800-", "63"], []).isEmpty)
        #expect(ContentEditor.follow(["Section", "12"], ["Section", "12.", "Section", "12"], []).map { [$0.start, $0.count] } == [[0, 2], [2, 2]])
    }

    @Test func theDocumentsCopiesShareOneBudget() throws {
        // A form's inline /Resources holding a flat array of many entries, copied for every page translated: past the
        // budget it stays shared (the save then keeps it whole) instead of being copied again and again.
        let doc = try MuDoc.create()
        let big = doc.dict([("A", doc.array((0..<100).map { doc.real(Double($0)) }))])
        doc.copyBudget = 250
        let first = ContentEditor.ownCopy(doc, big), second = ContentEditor.ownCopy(doc, big), third = ContentEditor.ownCopy(doc, big)
        #expect(first.id != big.id && second.id != big.id)
        #expect(third.id == big.id, "a third copy past the budget")
        // A flat container larger than what is left isn't copied at all.
        doc.copyBudget = 50
        #expect(ContentEditor.ownCopy(doc, big).id == big.id)
    }

    @Test func aPageThatCantBeWrittenLeavesItsFormsAsTheyWere() throws {
        // Page 1 draws a form (edited in place: nothing else draws it) and has paragraphs in two parts of its content, the
        // third part damaged: the page can't be rewritten, so its form must stay as it was too, not point at stand-in
        // fonts that were never added. Page 2 translates, so there is a copy to look at.
        let formLine = "The quick brown fox"
        let one = ContentEditPdf.make("q /Fm1 Do Q " + T.lines(72, 600, 12, 14, "jumps over a lazy dog"),
                                      form: T.lines(72, 700, 12, 14, formLine),
                                      extraStreams: [T.lines(72, 400, 12, 14, "until the 0123456789")], damagedPart: true,
                                      fontText: Self.letters)
        let doc = try PdfEdit.open(one, nil)
        let fonts = try #require(doc.page(0).dict("Resources")?.dict("Font"))
        let contents = doc.addStream(latin1Bytes(T.lines(72, 700, 12, 14, "THE QUICK BROWN FOX")), deflate: false)
        let page = doc.add(doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, 612, 792)), ("Contents", contents),
                                     ("Resources", doc.dict([("Font", fonts)]))]))
        doc.insertPage(page, at: 1)
        try doc.checkFailure()
        let pdf = try doc.write("")
        let (_, result) = try T.translate(pdf) { $0.replacingOccurrences(of: "quick", with: "lazy").replacingOccurrences(of: "QUICK", with: "LAZY")
            .replacingOccurrences(of: "jumps", with: "walks").replacingOccurrences(of: "until", with: "after") }
        let copy = try #require(result.data)
        let after = try PdfEdit.open(copy, nil)
        let form = try #require(after.page(0).dict("Resources")?.dict("XObject")?.dict("Fm1"))
        let bytes = String(decoding: form.streamData ?? [], as: UTF8.self)
        #expect(bytes.contains(formLine), "the form of a page that stays as it was changed: \(bytes)")
        #expect(!bytes.contains(ContentEditor.standInKey))
        #expect(ContentEditPdf.text(copy, page: 1).contains("LAZY"))
    }
}
