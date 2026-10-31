import Foundation
import Testing
@testable import PdfCore

/// Ported from AiReviewTests.cs (same names): address checks, keys per endpoint, limits, combine confirmation. .NET's
/// `CreateHandler` with a `resolve` function is `AiClient.createHandler(_:resolve:)`, connecting for real on loopback.
struct AiReviewTests {
    private static func endpoint(_ url: String) -> AiEndpoint { AiEndpoint.tryParse(url).endpoint! }

    // MARK: 1. Hosts: what is classified is what is connected to

    @Test(arguments: [
        "http://api\u{3002}openai\u{3002}com/v1", // ideographic full stops: IDNA turns them into dots
        "http://api\u{FF0E}openai\u{FF0E}com/v1", // fullwidth full stops
        "https://b\u{00FC}cher.example/v1",
        "api\u{3002}openai\u{3002}com",
    ])
    func nonAsciiHostsAreRefused(_ url: String) {
        let result = AiEndpoint.tryParse(url)
        #expect(result.endpoint == nil)
        #expect(result.error?.contains("xn--") == true)
    }

    @Test func punycodeHostsAreTheInternet() {
        #expect(Self.endpoint("https://xn--bcher-kva.example/v1").reach == .internet)
    }

    @Test(arguments: [
        ("http://localhost:11434/v1", "127.0.0.1", true),
        ("http://localhost:11434/v1", "::1", true),
        ("http://localhost:11434/v1", "192.168.1.5", false),
        ("http://evil.localhost:11434/v1", "203.0.113.7", false),
        ("http://nas.local:11434/v1", "192.168.1.5", true),
        ("http://nas.local:11434/v1", "fd00::5", true),
        ("http://nas.local:11434/v1", "127.0.0.1", true),
        ("http://nas.local:11434/v1", "8.8.8.8", false),
        ("http://gpu:8000/v1", "2001:db8::1", false),
        ("https://api.example.com/v1", "8.8.8.8", true),
        ("https://api.example.com/v1", "10.0.0.1", true),
    ] as [(String, String, Bool)])
    func addressesMustMatchTheLabel(_ url: String, _ ip: String, _ allowed: Bool) throws {
        #expect(Self.endpoint(url).allows(try #require(AiAddress(ip))) == allowed)
    }

    @Test(arguments: [("http://nas.local:9/v1", "203.0.113.7"), ("http://evil.localhost:9/v1", "192.168.1.5")])
    func aNameThatLeadsOutsideItsLabelIsNotConnectedTo(_ url: String, _ resolvesTo: String) async throws {
        let ep = Self.endpoint(url)
        let asked = AiRecorder<String>()
        let address = try #require(AiAddress(resolvesTo))
        let handler = AiClient.createHandler(ep, resolve: { host in
            asked.add(host)
            return [address]
        })
        let client = AiClient(ep, "m", apiKey: "sk-secret", handler: handler)
        let message = await aiMessage { _ = try await client.chat([.user("private text")]) }
        #expect(message?.contains("nothing was sent") == true)
        #expect(message?.contains(resolvesTo) == true)
        #expect(asked.count == 1)
    }

    @Test func aLocalNameConnectsToTheCheckedAddress() async throws {
        // A tiny OpenAI-compatible server on loopback; the name "ollama.localhost" is resolved by the test, to a public
        // address first (skipped) and then loopback, which is the one connected to.
        let body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\ndata: [DONE]\n\n"
        let server = try #require(AiLoopbackServer { _ in
            .raw("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        })
        defer { server.stop() }
        let ep = Self.endpoint("http://ollama.localhost:\(server.port)/v1")
        #expect(ep.reach == .thisMac)
        let addresses = [try #require(AiAddress("203.0.113.9")), try #require(AiAddress("127.0.0.1"))]
        let handler = AiClient.createHandler(ep, resolve: { _ in addresses })
        let client = AiClient(ep, "m", apiKey: nil, handler: handler)
        let reply = try await client.chat([.user("Q")])
        #expect(reply.text == "Hi")
        #expect(server.received.first?.requestLine.hasPrefix("POST /v1/chat/completions") == true)
    }

    // MARK: 2. Keys belong to the endpoint they were entered for

    @Test func changingTheEndpointDropsTheTypedKeyAndTheRemoval() {
        let saved = ["https://api.example.com/v1": "sk-saved", "http://localhost:11434/v1": "local-saved"]
        let look: (String) -> String? = { saved[$0.lowercased()] }
        let draft = AiKeyDraft("https://api.example.com/v1")
        draft.type("sk-typed")
        #expect(draft.keyToUse(look) == "sk-typed")

        #expect(draft.endpointChanged("http://localhost:11434/v1")) // switched to the Ollama preset
        #expect(draft.typed == nil)
        #expect(draft.keyToUse(look) == "local-saved") // never the cloud key

        draft.removeSaved()
        #expect(draft.keyToUse(look) == nil)
        #expect(draft.endpointChanged("https://api.example.com/v1"))
        #expect(!draft.remove) // removing the local key doesn't carry over
        #expect(draft.keyToUse(look) == "sk-saved")

        #expect(!draft.endpointChanged("HTTPS://api.example.com/v1"))
        #expect(draft.endpointChanged(nil)) // an invalid address: no key at all
        #expect(draft.keyToUse(look) == nil)
    }

    @Test func keysAreKeyedByTheNormalizedEndpoint() {
        #expect(Self.endpoint("API.example.com:443/v1/").key == Self.endpoint("https://api.example.com/v1/chat/completions").key)
    }

    // MARK: 3. Malformed answers end in an error, within limits

    @Test(arguments: [
        #"{"choices":[{"index":"0","delta":{"content":"x"}}]}"#,
        #"{"choices":[{"index":1.5,"delta":{"content":"x"}}]}"#,
        #"{"choices":[{"index":99999999999,"delta":{"content":"x"}}]}"#,
    ])
    func oddChoiceIndexesAreSkippedNotThrown(_ json: String) throws {
        #expect(try AiStreamParser().line("data: " + json) == "")
    }

    @Test func anEndlessEventIsRefused() {
        let p = AiStreamParser()
        let line = "data: " + String(repeating: "x", count: 1 << 20)
        #expect(throws: AiError.self) {
            for _ in 0..<10 { _ = try p.line(line) }
        }
    }

    @Test func aStreamWithoutLineBreaksIsRefused() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.response(200, "data: " + String(repeating: "x", count: AiClient.maxLineChars + 10)) }
        let client = AiClient(Self.endpoint(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: handler)
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("too long") == true)
    }

    @Test func anOversizedWholeAnswerIsRefusedAndAnErrorBodyCut() async throws {
        let huge = FakeAiHandler { _, _ in
            FakeAiHandler.json(200, #"{"choices":[{"message":{"content":" "# + String(repeating: "x", count: AiClient.maxBodyBytes) + "\"}}]}")
        }
        let a = AiClient(Self.endpoint(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: huge)
        let first = await aiMessage { _ = try await a.chat([.user("Q")]) }
        #expect(first?.contains("MB") == true)

        let bigError = FakeAiHandler { _, _ in FakeAiHandler.response(500, String(repeating: "e", count: AiClient.maxBodyBytes + 100), type: nil) }
        let b = AiClient(Self.endpoint(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: bigError)
        let second = await aiMessage { _ = try await b.chat([.user("Q")]) }
        #expect(second?.contains("500") == true)
    }

    @Test func aBodyThatBreaksOffIsAnAiError() async throws {
        let handler = FakeAiHandler { _, _ in
            AiHttpResponse(status: 401, contentType: nil, location: nil, body: FakeBody(failure: AiNetError.closedEarly))
        }
        let client = AiClient(Self.endpoint(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: handler)
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("closed before the answer finished") == true)
        await #expect(throws: AiError.self) { _ = try await client.listModels() }
    }

    // MARK: 4. Combining requests are shown before they go

    private static func longChunks() -> [AiChunk] {
        let page = Array(repeating: "Words in a sentence.", count: 60).joined(separator: " ")
        return AiText.chunk((0..<4).map { AiPageText($0, page) }, 400)
    }

    @Test func combiningRequestsAreConfirmedWithTheirExactText() async throws {
        let chunks = Self.longChunks()
        let shown = AiRecorder<[[AiMessage]]>()
        let sent = AiRecorder<[AiMessage]>()
        let result = try await AiPrompts.summarize(chunks, inputTokens: 400, ask: { m, s, _ in
            sent.add(m)
            return s.isFinal ? "Final" : "Partial \(s.index)"
        }, confirmCombine: { round, _ in
            shown.add(round)
            return true
        })
        #expect(result == "Final")
        #expect(shown.count == 1)
        let round = shown.all[0]
        #expect(round[0] == sent.all.last) // exactly what was shown is what went
        #expect(round[0][1].content.contains("Partial 1"))
    }

    @Test func decliningKeepsThePartialSummariesAndSendsNothingMore() async throws {
        let chunks = Self.longChunks()
        let calls = AiRecorder<Int>()
        let result = try await AiPrompts.summarize(chunks, inputTokens: 400, ask: { _, s, _ in
            calls.add(1)
            return "Partial \(s.index)"
        }, confirmCombine: { _, _ in false })
        #expect(calls.count == chunks.count)
        #expect(result.replacingOccurrences(of: "### Page ", with: "### Pages ").contains("### Pages"))
        #expect(result.contains("Partial 1"))
        #expect(result.contains("Partial \(chunks.count)"))
    }
}
