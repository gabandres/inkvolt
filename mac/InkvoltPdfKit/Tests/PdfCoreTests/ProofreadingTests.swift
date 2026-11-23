import Foundation
import Testing
@testable import PdfCore

/// ProofreadingTests.cs (roadmap 4.17): Insert Text and Replace Text, made as Acrobat makes them and carried through the
/// comment paths.
struct ProofreadingTests {
    /// The insertion point before "quick" on page 1 of `TestPdf.make`, and the struck-out boxes of "brown".
    private static func places(_ pdf: [UInt8]) throws -> (caret: RectD, brown: [RectD]) {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let text = try engine.text(0)
        let quick = try #require(offset(text, "quick")), brown = try #require(offset(text, "brown"))
        return (try #require(Annotations.caretAt(text, quick)), text.rects(brown, brown + 5))
    }

    /// The UTF-16 offset of `word` in the page's text (.NET's IndexOf).
    static func offset(_ text: PageText, _ word: String) -> Int? {
        guard let r = text.text.range(of: word) else { return nil }
        return text.text.utf16.distance(from: text.text.utf16.startIndex, to: r.lowerBound)
    }

    @Test func caretAt_IsTheInsertionPointAsTallAsItsLine() throws {
        let pdf = TestPdf.make(1)
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let text = try engine.text(0)
        let quick = try #require(Self.offset(text, "quick"))
        let at = try #require(Annotations.caretAt(text, quick))
        let q = text.boxAt(quick)
        #expect(at.width == 0)
        #expect(abs(at.x - q.x) < 0.001)
        #expect(abs(at.height - q.height) < 0.001)
        // At the end of the text: after its last character.
        let end = try #require(Annotations.caretAt(text, text.length))
        #expect(abs(end.x - text.boxAt(text.length - 1).right) < 0.001)
        #expect(Annotations.caretAt(PageText.empty, 0) == nil)
    }

    @Test func insertText_IsABlueCaretWithTheTextAsItsComment() throws {
        let pdf = TestPdf.make(1)
        let (caret, _) = try Self.places(pdf)
        let marked = try Annotations.addInsertText(pdf, nil, 0, caret, "  very  ", author: "Ana", id: "ins-1")

        let all = try Annotations.read(marked, nil)
        #expect(all.count == 1)
        let a = try #require(all.first)
        #expect(a.kind == .caret)
        #expect(a.id == "ins-1")
        #expect(a.contents == "very")
        #expect(a.author == "Ana")
        #expect(a.subject == "Inserted Text")
        #expect(a.color == Annotations.proofBlue)
        #expect(a.replyTo == nil)
        #expect(Annotations.proofKindOf(a, Annotations.replacedCarets([a])) == .insertText)
        // Its tip sits at the insertion point, under the line's middle; it reaches below the line.
        #expect(a.rect.centerX >= caret.x - 1 && a.rect.centerX <= caret.x + 1)
        #expect(a.rect.y > caret.centerY && a.rect.bottom > caret.bottom, "\(a.rect) vs \(caret)")
        // Drawn by every viewer: an appearance of its own, shown blue under the text.
        let annot = try Core2Pdf.lastAnnot(marked)
        #expect(annot.dict("AP")?.dict("N") != nil)
        #expect(annot.name("Sy") == "None")
        #expect(try Core2Pdf.ink(marked, 0, a.rect) > 0.05)
    }

    @Test func replaceText_StrikesTheWordsOutAndGroupsThemWithACaretHoldingTheNewText() throws {
        let pdf = TestPdf.make(1)
        let (_, brown) = try Self.places(pdf)
        let marked = try Annotations.addReplaceText(pdf, nil, 0, brown, "red", author: "Ana", id: "rep-1")

        let all = try Annotations.read(marked, nil)
        #expect(all.count == 2)
        let caret = try #require(all.first { $0.kind == .caret })
        let strike = try #require(all.first { $0.kind == .strikeOut })
        #expect(caret.id == "rep-1")
        #expect(caret.contents == "red")
        #expect(strike.replyTo == "rep-1")
        #expect(strike.grouped)
        #expect(!caret.grouped)
        #expect(strike.subject == "Cross-Out")
        #expect(strike.color == Annotations.proofBlue)
        #expect(abs(strike.quadRects[0].x - brown[0].x) < 0.1)
        // The caret comes after the struck-out word.
        let after = try #require(brown.last).right
        #expect(caret.rect.centerX >= after - 1 && caret.rect.centerX <= after + 1)
        let ids = Set(all.map(\.id))
        #expect(Annotations.isGroupMember(strike, ids))
        #expect(!Annotations.isGroupMember(caret, ids))
        #expect(Annotations.proofKindOf(caret, Annotations.replacedCarets(all)) == .replaceText)
        #expect(Annotations.proofKindOf(strike, Annotations.replacedCarets(all)) == nil)

        // One comment: deleting it takes the strike-out along.
        #expect(try Annotations.read(Annotations.delete(marked, nil, "rep-1"), nil).isEmpty)
        // Deleting the strike-out (picked on the page) takes the group too: never a caret left as Insert Text.
        #expect(Annotations.groupHead(strike, all).id == caret.id)
        #expect(Annotations.groupHead(caret, all).id == caret.id)
        #expect(try Annotations.read(Annotations.delete(marked, nil, strike.id), nil).isEmpty)
    }

    private static func comment(_ id: String, _ to: String?, grouped: Bool, y: Double = 0) -> AnnotationInfo {
        AnnotationInfo(id: id, kind: .strikeOut, subtype: "StrikeOut", pageIndex: 0, rect: RectD(10, y, 50, 10), contents: id,
                       author: nil, modified: nil, subject: nil, color: nil, quadRects: [], isInkvoltPdfStamp: false, replyTo: to,
                       hidden: false, grouped: grouped)
    }

    @Test func aGroupThatLoops_StopsClimbing() {
        let loop = [Self.comment("a", "b", grouped: true), Self.comment("b", "a", grouped: true)]
        #expect(["a", "b"].contains(Annotations.groupHead(loop[0], loop).id))
        #expect(Annotations.groupHead(loop[0], [loop[0]]).id == "a") // its head isn't there: itself
    }

    @Test func aGroupThatLoops_IsListedAsPlainComments_NotHidden() {
        // A in B's group and B in A's: each was the other's member, so the Comments list and the summary showed neither.
        let all = [
            Self.comment("a", "b", grouped: true, y: 10), Self.comment("b", "a", grouped: true, y: 40), // a loop of groups
            Self.comment("c", "c", grouped: true, y: 70), // in its own group
            Self.comment("d", "e", grouped: false, y: 100), Self.comment("e", "d", grouped: false, y: 130), // a loop of replies
            Self.comment("f", "a", grouped: true, y: 160), // a member of a looped head: the head stands for it
            Self.comment("g", "d", grouped: false, y: 190), // a reply into a loop: still a reply
        ]
        let listed = Annotations.asListed(all)
        #expect(listed.map(\.id) == ["a", "b", "c", "d", "e", "g"])
        #expect(listed.filter { $0.id != "g" }.allSatisfy { $0.replyTo == nil && !$0.grouped })
        #expect(listed.first { $0.id == "g" }?.replyTo == "d")

        // The summary lists each loop's comments as comments of their own, the reply under its comment.
        let plan = CommentSummary.plan(all)
        #expect(plan.count == 1)
        let entries = plan.first?.entries ?? []
        #expect(entries.map(\.comment.id) == ["a", "b", "c", "d", "g", "e"])
        #expect(entries.map(\.depth) == [0, 0, 0, 0, 1, 0])
    }

    @Test func aRealReplyIsNotAGroup() throws {
        var pdf = try Annotations.addInsertText(TestPdf.make(1), nil, 0, RectD(100, 100, 0, 20), "x", author: "Ana", id: "ins-1")
        pdf = try Annotations.addReply(pdf, nil, "ins-1", "Agreed", author: "Bo", id: "reply-1")
        let all = try Annotations.read(pdf, nil)
        let reply = try #require(all.first { $0.id == "reply-1" })
        #expect(!reply.grouped)
        #expect(!Annotations.isGroupMember(reply, Set(all.map(\.id))))
        let caret = try #require(all.first { $0.id == "ins-1" })
        #expect(Annotations.proofKindOf(caret, Annotations.replacedCarets(all)) == .insertText)
    }

    @Test func refusesEmptyOrHugeTextAndNoWords() {
        let pdf = TestPdf.make(1)
        let at = RectD(100, 100, 0, 20)
        #expect(throws: PdfEditError.self) { try Annotations.addInsertText(pdf, nil, 0, at, "  \n ", author: "Ana") }
        #expect(throws: PdfEditError.self) {
            try Annotations.addInsertText(pdf, nil, 0, at, String(repeating: "x", count: Annotations.maxProofText + 1), author: "Ana")
        }
        #expect(throws: PdfEditError.self) { try Annotations.addInsertText(pdf, nil, 0, RectD(.nan, 100, 0, 20), "x", author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addReplaceText(pdf, nil, 0, [], "x", author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addInsertText(pdf, nil, 3, at, "x", author: "Ana") }
        // Hostile: infinite height, and a negative page.
        #expect(throws: PdfEditError.self) { try Annotations.addInsertText(pdf, nil, 0, RectD(100, 100, 0, .infinity), "x", author: "Ana") }
        #expect(throws: PdfEditError.self) { try Annotations.addInsertText(pdf, nil, -1, at, "x", author: "Ana") }
    }

    @Test func onATurnedPage_TheCaretStaysUnderTheLineAsShown() throws {
        let turned = try PageEditor.rotate(TestPdf.make(1), nil, [0], 90)
        let at = RectD(200, 300, 0, 20) // page space: as the page is shown
        let a = try #require(try Annotations.read(Annotations.addInsertText(turned, nil, 0, at, "x", author: "Ana"), nil).first)
        #expect(a.rect.centerX >= at.x - 1 && a.rect.centerX <= at.x + 1)
        #expect(a.rect.y > at.centerY && a.rect.bottom > at.bottom, "\(a.rect)")
        // The same chevron as on an unturned page (not on its side).
        let upright = try #require(try Annotations.read(Annotations.addInsertText(TestPdf.make(1), nil, 0, at, "x", author: "Ana"), nil).first)
        #expect(abs(upright.rect.width - a.rect.width) < 0.01)
        #expect(abs(upright.rect.height - a.rect.height) < 0.01)
        #expect(abs(a.rect.width - a.rect.height) > 0.1)
    }

    private static func proofread() throws -> [UInt8] {
        var pdf = TestPdf.make(1)
        let (caret, brown) = try places(pdf)
        pdf = try Annotations.addInsertText(pdf, nil, 0, caret, "very", author: "Ana", id: "ins-1")
        pdf = try Annotations.addReplaceText(pdf, nil, 0, brown, "red", author: "Ana", id: "rep-1")
        return try Annotations.addTextMarkup(pdf, nil, 0, .highlight, [RectD(72, 150, 100, 20)], .yellow, note: "look", author: "Bo", id: "hl-1")
    }

    @Test(arguments: [CommentFileFormat.xfdf, .fdf])
    func theMarksTravelThroughXfdfAndFdf_StillGrouped(_ format: CommentFileFormat) throws {
        let export = try CommentFiles.export(Self.proofread(), nil, format, pdfFileName: "source.pdf")
        #expect(export.count == 4)
        if format == .xfdf {
            let xml = String(decoding: export.data, as: UTF8.self)
            #expect(xml.contains("<caret"))
            #expect(xml.contains("replyType=\"group\""))
            #expect(xml.contains("inreplyto=\"rep-1\""))
        }
        let result = try CommentFiles.importComments(TestPdf.make(1), nil, export.data)
        #expect(result.added == 4)
        let all = try Annotations.read(result.data, nil)
        let caret = try #require(all.first { $0.id == "rep-1" })
        let strike = try #require(all.first { $0.kind == .strikeOut })
        #expect(strike.grouped)
        #expect(strike.replyTo == "rep-1")
        #expect(caret.contents == "red")
        #expect(all.first { $0.id == "ins-1" }?.contents == "very")
        // XFDF carries no appearance for a caret: the import draws one.
        let doc = try Core2Pdf.open(result.data)
        for a in doc.page(0).array("Annots")?.elements ?? [] { #expect(a.dict("AP")?.dict("N") != nil, "\(a.name("Subtype") ?? "")") }
    }

    @Test func theSummaryListsEachMarkOnce_ByWhatItAsks() throws {
        let pdf = try Self.proofread()
        let plan = CommentSummary.plan(try Annotations.read(pdf, nil))
        #expect(plan.count == 1)
        let entries = try #require(plan.first).entries
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.depth == 0 })
        #expect(!entries.contains { $0.comment.kind == .strikeOut })
        #expect(entries.first { $0.comment.id == "ins-1" }?.proof == .insertText)
        #expect(entries.first { $0.comment.id == "rep-1" }?.proof == .replaceText)
        #expect(entries.first { $0.comment.id == "hl-1" }?.proof == nil)

        let text = try Core2Pdf.allText(CommentSummary.make(pdf, nil, title: "proof"), page: 0)
        #expect(text.contains("Replace text"))
        #expect(text.contains("Insert text"))
    }
}
