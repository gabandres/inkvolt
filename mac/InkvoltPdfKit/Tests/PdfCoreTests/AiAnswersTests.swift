import Foundation
import PrintCore
import Testing
@testable import PdfCore

/// Ported from AiAnswersTests.cs (same names): roadmap 4.20, the conversation kept with the document's session, and an
/// answer saved to Word, a PDF or a comment. Adapted: the Word part is read from the package as text; an empty element is
/// `<w:b/>` here (`<w:b />` from .NET's writer); the PDF's bold is checked on an answer in Latin script (PLAN, 4.20).
struct AiAnswersTests {
    private static let when = Date(timeIntervalSince1970: 1_795_444_200) // 2026-11-20 14:30 UTC

    private static func summary() -> AiExchange {
        AiExchange(.summary, shown: "Summarize pages 1–3", asked: "Summarize pages 1–3",
                   answer: "## Overview\nThe lease runs **two years** [p. 2].\n\n- Rent is due monthly [p. 3]\n* Deposit: one month\n1. Sign by Friday",
                   model: "llama3.2", when: when)
    }

    private static func question() -> AiExchange {
        AiExchange(.answer, shown: "Who pays repairs?", asked: "Who pays repairs?",
                   answer: "The landlord pays structural repairs [p. 5], the tenant minor ones.", model: "qwen3:8b", when: when)
    }

    @Test func theConversation_KeepsEachAnswer_AndSendsThemAsTurns() {
        let c = AiConversation()
        c.add(Self.summary())
        var asked = Self.question()
        asked.asked = "Who pays for repairs? (asked in English)"
        c.add(asked)
        #expect(c.exchanges.count == 2)
        #expect(c.turns.map(\.question) == ["Summarize pages 1–3", "Who pays for repairs? (asked in English)"])
        #expect(c.turns[1].answer == Self.question().answer)
        for _ in 0..<(AiConversation.maxExchanges + 5) { c.add(Self.question()) }
        #expect(c.exchanges.count == AiConversation.maxExchanges)
        c.clear()
        #expect(c.turns.isEmpty)
    }

    @Test func aDocumentSessionKeepsItsConversation() throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(1), "a.pdf")
        #expect(session.aiConversation.exchanges.isEmpty)
        session.aiConversation.add(Self.question())
        #expect(session.aiConversation === session.aiConversation)
        #expect(session.aiConversation.exchanges.count == 1)
    }

    @Test func aComment_GoesOnTheFirstPageCited_AndSaysAnAiWroteIt() throws {
        #expect(Self.summary().citedPages(10) == [1, 2])
        #expect(AiAnswerExport.commentPage(Self.summary(), 10, current: 7) == 1)
        var uncited = Self.summary()
        uncited.answer = "No citations."
        #expect(AiAnswerExport.commentPage(uncited, 10, current: 7) == 7)
        #expect(AiAnswerExport.commentPage(Self.question(), 3, current: 0) == 0) // [p. 5] isn't a page of a 3-page document

        let text = AiAnswerExport.commentText(Self.summary())
        #expect(text.hasPrefix("Summarize pages 1–3\n\n"))
        #expect(text.contains("The lease runs two years [p. 2]."))
        #expect(!text.contains("**"))
        #expect(text.contains("• Rent is due monthly"))
        #expect(text.contains("llama3.2"))
        #expect(text.contains("may be wrong"))
        var long = Self.question()
        long.answer = String(repeating: "x", count: 50_000)
        #expect(AiAnswerExport.commentText(long).count < AiAnswerExport.maxCommentChars + 500)

        // As a sticky note in the document: the text as it is, one undo step for the app.
        let pdf = try Annotations.addNote(TestPdf.make(2), nil, 1, 560, 16, text, author: "Ana")
        let notes = try Annotations.read(pdf, nil)
        #expect(notes.count == 1 && notes.first?.contents == text)
    }

    @Test func word_HasTheTitle_EachQuestionAsAHeading_TheNote_AndTheAnswersLook() throws {
        let docx = try AiAnswerExport.toDocx([Self.summary(), Self.question()], "lease.pdf")
        let package = try OpenXmlPackage(docx)
        #expect(package.parts["[Content_Types].xml"] != nil)
        let xml = String(decoding: try #require(package.parts["word/document.xml"]), as: UTF8.self)
        #expect(xml.contains("AI answers about lease.pdf"))
        #expect(xml.contains("Summarize pages 1–3"))
        #expect(xml.contains("Who pays repairs?"))
        #expect(xml.contains("Heading2"))
        #expect(xml.contains("llama3.2"))
        #expect(xml.contains("qwen3:8b"))
        #expect(xml.contains("may be wrong"))
        #expect(xml.contains("[p. 2]"))
        #expect(xml.contains("<w:numPr>")) // the bullets are Word's own
        #expect(xml.contains("1. Sign by Friday"))
        #expect(!xml.contains("**"))
        // "two years" is a bold run of its own.
        let bold = try #require(xml.range(of: "two years"))
        let run = try #require(xml.range(of: "<w:r>", options: .backwards, range: xml.startIndex..<bold.lowerBound))
        let props = xml[run.lowerBound..<bold.lowerBound]
        #expect(props.contains("<w:b/>") || props.contains("<w:b />"))
        #expect(throws: PdfEditError.self) { try AiAnswerExport.toDocx([], "x.pdf") }
    }

    @Test func pdf_HasTheSameText_AndFlowsOntoMorePages() throws {
        var other = Self.question()
        other.answer = "Привет, Zoë: the answer in two scripts."
        let pdf = try AiAnswerExport.toPdf([Self.summary(), other], "lease.pdf")
        let text = try Core2Pdf.allText(pdf, page: 0)
        #expect(text.contains("AI answers about lease.pdf"))
        #expect(text.contains("Summarize pages 1–3"))
        #expect(text.contains("Overview"))
        #expect(text.contains("two years [p. 2]"))
        #expect(text.contains("Rent is due monthly"))
        #expect(text.contains("llama3.2"))
        #expect(text.contains("Привет, Zoë"))
        #expect(!text.contains("**"))

        var many = Self.question()
        many.answer = (1...200).map { "Point \($0): the landlord pays repairs." }.joined(separator: "\n")
        let longer = try AiAnswerExport.toPdf([many], "lease.pdf")
        let engine = try PdfEngine.open(longer)
        defer { engine.close() }
        #expect(engine.pageCount >= 4, "\(engine.pageCount) pages")
        #expect(try engine.text(engine.pageCount - 1).text.contains("Point 200"))
        #expect(throws: PdfEditError.self) { try AiAnswerExport.toPdf([], "x.pdf") }

        // **bold** is drawn bold, the rest of its line regular. Mac: on an answer in Latin script only (Helvetica and
        // Helvetica-Bold); text past WinAnsi goes in Type 3 fonts, drawn bold but read back by MuPDF as regular.
        let latin = try AiAnswerExport.toPdf([Self.summary()], "lease.pdf")
        let first = try PdfEngine.open(latin)
        defer { first.close() }
        let spans = try first.exportPage(0, images: false).lines.flatMap(\.spans)
        #expect(spans.contains { $0.text.contains("two") && $0.bold })
        #expect(spans.contains { $0.text.contains("lease runs") && !$0.bold })
        #expect(spans.contains { $0.text.contains("[p. 2]") && !$0.bold })
    }
}
