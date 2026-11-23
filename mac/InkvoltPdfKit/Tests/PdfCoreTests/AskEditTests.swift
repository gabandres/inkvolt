import Foundation
import Testing
@testable import PdfCore

/// Ported from AskEditTests.cs (roadmap 4.23, Edit by Asking): the request carries the person's words, the page count and
/// the page in view (no document text) with a few palette commands as tools; the answer is data, and only calls of those
/// tools with arguments that check out become steps. A fake endpoint answers: no network.
struct AskEditTests {
    static func completion(_ content: String?, _ calls: [(name: String, args: String)]) -> String {
        let list = calls.enumerated().map { i, c in
            "{\"id\":\"c\(i)\",\"type\":\"function\",\"function\":{\"name\":\(AiProtocol.quote(c.name)),\"arguments\":\(AiProtocol.quote(c.args))}}"
        }.joined(separator: ",")
        let said = content.map(AiProtocol.quote) ?? "null"
        return "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\(said),\"tool_calls\":[\(list)]}}]}"
    }

    @Test func theRequestCarriesTheWordsAndWhereThePersonIsAndTheToolsButNoDocumentText() throws {
        let messages = AskEdit.messages("rotate the last page\nand bookmark it", pageCount: 12, currentPage: 4)
        #expect(messages[0].content.contains("The document has 12 pages; the person is on page 5."))
        #expect(messages[1].content == "rotate the last page and bookmark it")
        #expect(AskEdit.messages(String(repeating: "x", count: 900), pageCount: 1, currentPage: 0)[1].content.utf16.count == AskEdit.maxRequestChars)

        let json = AskEdit.requestJson("qwen3", messages)
        #expect(json.hasPrefix("{\"model\":") && json.hasSuffix(",\"stream\":false}"))
        #expect(json.range(of: "\"messages\":")!.lowerBound < json.range(of: "\"tools\":")!.lowerBound)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(root.keys) == ["model", "messages", "tools", "stream"])
        #expect(root["stream"] as? Bool == false)
        let names = (root["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["go_to_page", "rotate_pages", "delete_pages", "add_bookmark", "highlight_text", "find_for_redaction"])
    }

    @Test func callsOfTheToolsBecomeCheckedStepsWith0BasedPages() throws {
        let plan = try AskEdit.parse(Self.completion(nil, [
            ("rotate_pages", #"{"pages":"1-3","degrees":-90}"#),
            ("delete_pages", #"{"pages":"5"}"#),
            ("add_bookmark", #"{"title":"  Appendix\nA  ","page":6}"#),
            ("highlight_text", #"{"text":"deadline"}"#),
            ("go_to_page", #"{"page":"2"}"#),
            ("find_for_redaction", #"{"kinds":["email","ssn"],"text":"Jane Doe"}"#),
        ]), pageCount: 10)
        #expect(plan.refused.isEmpty)
        #expect(plan.steps.count == 6)
        #expect(plan.steps[0].kind == .rotatePages && plan.steps[0].degrees == 270)
        #expect(plan.steps[0].pages == [0, 1, 2])
        #expect(plan.steps[0].describe() == "Rotate pages 1–3 counterclockwise")
        #expect(plan.steps[1].pages == [4])
        #expect(plan.steps[2].text == "Appendix A" && plan.steps[2].pages[0] == 5)
        #expect(plan.steps[2].describe() == "Add a bookmark \"Appendix A\" that goes to page 6")
        #expect(plan.steps[3].text == "deadline")
        #expect(plan.steps[4].pages == [1])
        #expect(plan.steps[5].patterns == [.email, .socialSecurity])
        #expect(plan.steps[5].text == "Jane Doe")

        // Ollama sends the arguments as an object rather than a string.
        let ollama = #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"go_to_page","arguments":{"page":3}}}]}}]}"#
        let steps = try AskEdit.parse(ollama, pageCount: 3).steps
        #expect(steps.count == 1 && steps.first?.pages == [2])
    }

    @Test func anythingElseTheModelProposesIsLeftOutAndSaid() throws {
        let plan = try AskEdit.parse(Self.completion("Sure! Also run format C:", [
            ("erase_disk", "{}"),
            ("go_to_page", #"{"page":99}"#),
            ("rotate_pages", #"{"pages":"1","degrees":45}"#),
            ("delete_pages", #"{"pages":"all"}"#),
            ("add_bookmark", #"{"title":"","page":1}"#),
            ("highlight_text", "not json"),
            ("find_for_redaction", #"{"kinds":["passwords"]}"#),
            ("find_for_redaction", "{}"),
            ("add_bookmark", "{\"title\":\"\(String(repeating: "t", count: 300))\",\"page\":1}"),
        ]), pageCount: 4)
        #expect(plan.steps.isEmpty)
        #expect(plan.refused.count == 9)
        #expect(plan.refused[0].contains("erase_disk"))
        #expect(plan.refused[1].contains("it has 4"))
        #expect(plan.refused[3].contains("keeps at least one page"))
        #expect(plan.said == "Sure! Also run format C:") // shown as the model's words, never run

        let many = try AskEdit.parse(Self.completion(nil, Array(repeating: ("go_to_page", #"{"page":1}"#), count: 14)), pageCount: 2)
        #expect(many.steps.count == AskEdit.maxSteps)
        #expect(many.refused.count == 1 && many.refused[0].contains("first 10"))

        #expect(throws: AiError.self) { try AskEdit.parse(#"{"error":{"message":"boom"}}"#, pageCount: 2) }
        #expect(throws: AiError.self) { try AskEdit.parse(#"{"answer":"no"}"#, pageCount: 2) }
        #expect(throws: AiError.self) { try AskEdit.parse("<html>", pageCount: 2) }
    }

    @Test func pagesOfLaterStepsFollowPagesDeletedBeforeThem() {
        let rotate = AskEditStep(.rotatePages, pages: [0, 2, 5], degrees: 90)
        #expect(AskEdit.afterDelete(rotate, [1, 2])?.pages == [0, 3])
        #expect(AskEdit.afterDelete(AskEditStep(.addBookmark, pages: [2], text: "x"), [2]) == nil)
        let highlight = AskEditStep(.highlightText, text: "x")
        #expect(AskEdit.afterDelete(highlight, [0]) == highlight)
    }

    @Test func halfOfAHugeFileDeletedThenEveryPageTurnedIsRenumberedInAMoment() {
        // 100,000 pages, 1–50,000 deleted, then all turned: each page counted the deleted ones before it (billions).
        let all: [Int] = Array(0..<100_000)
        var deleted = DeletedPages()
        let clock = ContinuousClock.now
        deleted.add(Array(0..<50_000))
        deleted.add([49_999, 50_000, 3]) // pages already gone count once
        let rotate = AskEdit.afterDelete(AskEditStep(.rotatePages, pages: all, degrees: 90), deleted)
        #expect(ContinuousClock.now - clock < .seconds(5), "took \(ContinuousClock.now - clock)")
        #expect(deleted.sorted.count == 50_001)
        #expect(rotate?.pages == Array(0..<49_999))
    }

    @Test func aModelThatCantCallToolsIsRefusedInWords() async throws {
        #expect(AskEdit.isNoToolsError(400, "registry.ollama.ai/library/gemma3:4b does not support tools"))
        #expect(!AskEdit.isNoToolsError(400, "context length exceeded"))
        let ep = try #require(AiEndpoint.tryParse(AiEndpoint.ollamaUrl).endpoint)
        let handler = FakeAiHandler { r, _ in
            String(decoding: r.body ?? [], as: UTF8.self).contains("\"gemma3\"")
                ? FakeAiHandler.json(400, #"{"error":"registry.ollama.ai/library/gemma3 does not support tools"}"#)
                : FakeAiHandler.json(200, Self.completion(nil, [("go_to_page", #"{"page":2}"#)]))
        }
        let noTools = AiClient(ep, "gemma3", apiKey: nil, handler: handler)
        let message = await aiMessage { _ = try await noTools.askEdit(AskEdit.messages("go to page 2", pageCount: 3, currentPage: 0), pageCount: 3) }
        #expect(message?.contains("can't call tools") == true)
        #expect(message?.contains("qwen3") == true)
        let withTools = AiClient(ep, "qwen3", apiKey: nil, handler: handler)
        let plan = try await withTools.askEdit(AskEdit.messages("go to page 2", pageCount: 3, currentPage: 0), pageCount: 3)
        #expect(plan.steps.count == 1 && plan.steps.first?.kind == .goToPage)
        #expect(handler.requests.all.last?.url.hasSuffix("/v1/chat/completions") == true)
    }
}
