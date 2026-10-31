import Foundation
import Testing
@testable import PdfCore

/// Ported from AiTests.cs (same names; each class a suite). The Mac says "this Mac" where Windows says "this PC", in the
/// reach labels and the messages. `FakeAiHandler` is an `AiTransport` (.NET: `HttpMessageHandler`): no network; a refused
/// connection or a bad certificate is an `AiNetError`. Tests with real sockets (a server on loopback): AiLoopbackTests.

private func parsed(_ url: String) -> AiEndpoint {
    AiEndpoint.tryParse(url).endpoint!
}

/// Records from a `@Sendable` closure.
final class AiRecorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func add(_ value: T) { lock.withLock { values.append(value) } }
    var all: [T] { lock.withLock { values } }
    var count: Int { all.count }
}

/// What a test expects to be an `AiError`: its message.
func aiMessage(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch let e as AiError {
        return e.message
    } catch {
        return "unexpected \(error)"
    }
}

struct AiEndpointTests {
    @Test(arguments: [
        ("localhost", AiReach.thisMac), ("LOCALHOST.", .thisMac), ("ollama.localhost", .thisMac), ("127.0.0.1", .thisMac),
        ("127.8.9.10", .thisMac), ("[::1]", .thisMac), ("::ffff:127.0.0.1", .thisMac), ("10.1.2.3", .localNetwork),
        ("172.16.0.1", .localNetwork), ("172.31.255.255", .localNetwork), ("192.168.1.20", .localNetwork),
        ("169.254.10.10", .localNetwork), ("100.100.1.1", .localNetwork), ("::ffff:192.168.0.9", .localNetwork),
        ("fd12:3456::1", .localNetwork), ("fe80::1", .localNetwork), ("nas.local", .localNetwork), ("gpu-box", .localNetwork),
        ("router.lan", .localNetwork), ("pc.home.arpa", .localNetwork), ("172.32.0.1", .internet), ("192.0.2.10", .internet),
        ("8.8.8.8", .internet), ("2001:db8::1", .internet), ("api.example.com", .internet), ("local.example.com", .internet),
        ("localhost.example.com", .internet),
    ] as [(String, AiReach)])
    func classifiesHosts(_ host: String, _ expected: AiReach) {
        #expect(AiEndpoint.classify(host) == expected)
    }

    @Test(arguments: [
        ("http://localhost:11434/v1", "http://localhost:11434/v1", AiReach.thisMac),
        ("localhost:11434", "http://localhost:11434/v1", .thisMac),
        ("http://localhost:1234/v1/", "http://localhost:1234/v1", .thisMac),
        ("http://192.168.1.10:8080", "http://192.168.1.10:8080/v1", .localNetwork),
        ("api.example.com", "https://api.example.com/v1", .internet),
        ("api.example.com:8443/openai/v1", "https://api.example.com:8443/openai/v1", .internet),
        ("https://api.example.com/v1/chat/completions", "https://api.example.com/v1", .internet),
        ("https://api.example.com/v1/models", "https://api.example.com/v1", .internet),
        ("  https://API.Example.com/v1  ", "https://api.example.com/v1", .internet),
    ] as [(String, String, AiReach)])
    func parsesBaseUrls(_ text: String, _ expected: String, _ reach: AiReach) throws {
        let result = AiEndpoint.tryParse(text)
        let ep = try #require(result.endpoint, "\(result.error ?? "")")
        #expect(ep.key == expected)
        #expect(ep.reach == reach)
        #expect(ep.chatUrl == expected + "/chat/completions")
        #expect(ep.modelsUrl == expected + "/models")
    }

    @Test(arguments: [
        ("", "address"), ("http://api.example.com/v1", "https://"), ("http://8.8.8.8:11434/v1", "https://"),
        ("https://me:secret@api.example.com/v1", "API key"), ("https://api.example.com/v1?key=1", "?"),
        ("ftp://files.example.com", "https://"), ("http://", "web address"),
    ] as [(String, String)])
    func refusesBadOrUnsafeUrls(_ text: String, _ mention: String) {
        let result = AiEndpoint.tryParse(text)
        #expect(result.endpoint == nil)
        #expect(result.error?.contains(mention) == true)
    }

    @Test func describesWhereTextGoes() {
        let local = parsed(AiEndpoint.ollamaUrl)
        #expect(local.reachText == "Stays on this Mac")
        #expect(local.serverName == "Ollama")
        #expect(parsed(AiEndpoint.lmStudioUrl).serverName == "LM Studio")
        let lan = parsed("http://nas.local:11434/v1")
        #expect(lan.reachText == "Stays on your network (nas.local:11434)")
        #expect(lan.serverName == nil)
        #expect(parsed("https://api.example.com/v1").reachText == "Leaves this Mac: sent to api.example.com")
    }
}

struct AiProtocolTests {
    @Test func requestCarriesOnlyModelMessagesAndStream() throws {
        let json = AiProtocol.chatRequestJson("llama3.2", [.system("Be brief."), .user("Say \"hi\"\nplease")])
        // The keys in order, as the Windows writer puts them.
        #expect(json.hasPrefix("{\"model\":\"llama3.2\",\"messages\":["))
        #expect(json.hasSuffix(",\"stream\":true}"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(root.keys) == ["model", "messages", "stream"])
        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["content"] as? String == "Say \"hi\"\nplease")
    }

    @Test func parsesModelLists() async throws {
        #expect(try AiProtocol.parseModels(#"{"object":"list","data":[{"id":"llama3.2:latest","object":"model"},{"id":"gemma3:4b"},{"id":""},{"x":1}]}"#)
            == ["gemma3:4b", "llama3.2:latest"])
        #expect(try AiProtocol.parseModels(#"{"data":[]}"#).isEmpty)
        #expect(throws: AiError.self) { try AiProtocol.parseModels(#"{"models":[]}"#) }
        #expect(throws: AiError.self) { try AiProtocol.parseModels("<html>") }
    }

    @Test(arguments: [
        (#"{"error":{"message":"model \"x\" not found, try pulling it first","type":"api_error"}}"#, "model \"x\" not found, try pulling it first"),
        (#"{"error":"bad key"}"#, "bad key"),
        (#"{"detail":"Not Found"}"#, "Not Found"),
        ("plain text failure", "plain text failure"),
        ("<html><body>502</body></html>", nil),
        ("", nil),
    ] as [(String, String?)])
    func readsServerErrors(_ body: String, _ expected: String?) {
        #expect(AiProtocol.errorMessageOf(body) == expected)
    }

    @Test func wordsHttpErrorsForTheUser() {
        let ollama = parsed(AiEndpoint.ollamaUrl)
        #expect(AiProtocol.describeError(401, nil, "m", ollama).contains("API key"))
        let missing = AiProtocol.describeError(404, "model \"phi4\" not found, try pulling it first", "phi4", ollama)
        #expect(missing.contains("ollama pull phi4"))
        #expect(missing.contains("not found"))
        let cloud = parsed("https://api.example.com/v1")
        #expect(!AiProtocol.describeError(404, "The model `x` does not exist", "x", cloud).lowercased().contains("ollama"))
        #expect(AiProtocol.describeError(404, nil, "x", cloud).contains("/v1"))
        #expect(AiProtocol.describeError(400, "This model's maximum context length is 8192 tokens", "x", cloud).contains("fewer pages"))
        #expect(AiProtocol.describeError(429, nil, "x", cloud).contains("429"))
        #expect(AiProtocol.describeError(500, nil, "x", cloud).contains("500"))
    }

    @Test func parsesAStreamedAnswer() throws {
        let p = AiStreamParser()
        var text = ""
        for line in [
            ": keep-alive",
            #"data: {"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#, "",
            #"data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hello"}}]}"#, "",
            #"data:{"id":"1","choices":[{"index":0,"delta":{"content":", world"}}]}"#, "",
            "event: ping", "id: 7",
            #"data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "",
            "data: [DONE]", "",
            #"data: {"choices":[{"delta":{"content":"after done"}}]}"#,
        ] { text += try p.line(line) }
        text += try p.end()
        #expect(text == "Hello, world")
        #expect(p.done)
        #expect(p.finishReason == "stop")
    }

    @Test func joinsJsonSplitOverDataLines() throws {
        // The first line alone isn't JSON, so it waits; together they are.
        let p = AiStreamParser()
        #expect(try p.line(#"data: {"choices":[{"delta":"#) == "")
        #expect(try p.line(#"data: {"content":"joined"}}]}"#) == "joined")
        #expect(try p.line("") == "")
    }

    @Test func readsPlainJsonLinesAndSkipsOtherChoices() throws {
        let p = AiStreamParser()
        #expect(try p.line(#"{"choices":[{"index":0,"delta":{"content":"a"}},{"index":1,"delta":{"content":"b"}}]}"#) == "a")
        #expect(try p.line(#"{"choices":[{"index":0,"delta":{"reasoning_content":"thinking"}}]}"#) == "")
        #expect(try p.line(#"data: {"choices":[{"index":0,"delta":{"content":"len"},"finish_reason":"length"}]}"#) == "len")
        #expect(p.finishReason == "length")
    }

    @Test func streamErrorsThrow() throws {
        let p = AiStreamParser()
        #expect(throws: AiError("The model stopped with an error: \"out of memory\"")) { try p.line(#"data: {"error":{"message":"out of memory"}}"#) }
        let q = AiStreamParser()
        _ = try q.line("data: not json at all")
        #expect(throws: AiError.self) { try q.line("") }
    }

    @Test func parsesAWholeAnswer() throws {
        let whole = try AiStreamParser.parseWhole(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Done."},"finish_reason":"stop"}]}"#)
        #expect(whole.text == "Done.")
        #expect(whole.finishReason == "stop")
        #expect(throws: AiError.self) { try AiStreamParser.parseWhole(#"{"object":"list"}"#) }
        #expect(throws: AiError.self) { try AiStreamParser.parseWhole("oops") }
    }
}

/// A body from fixed bytes, then the end (or an error); `stall`: nothing more until cancelled (.NET's StallingStream).
final class FakeBody: AiBody, @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [[UInt8]]
    private let failure: Error?
    private let stall: Bool
    private let waiter = AiOnce<[UInt8]?>()

    init(_ text: String = "", failure: Error? = nil, stall: Bool = false) {
        pieces = text.isEmpty ? [] : [Array(text.utf8)]
        self.failure = failure
        self.stall = stall
    }

    func read(_ cancel: CancelToken) async throws -> [UInt8]? {
        let next: [UInt8]? = lock.withLock { pieces.isEmpty ? nil : pieces.removeFirst() }
        if let next { return next }
        if let failure { throw failure }
        if !stall { return nil }
        let id = cancel.register { [waiter] in waiter.resume(with: .failure(CancellationError())) }
        defer { cancel.unregister(id) }
        return try await withCheckedThrowingContinuation { waiter.begin($0) }
    }

    func close() {}
}

/// A transport that answers from a function and records the requests; no network.
final class FakeAiHandler: AiTransport, @unchecked Sendable {
    let usesProxy = false
    let followsRedirects = false
    let usesCookies = false
    private let answer: @Sendable (AiHttpRequest, CancelToken) async throws -> AiHttpResponse
    let requests = AiRecorder<AiHttpRequest>()

    init(_ answer: @escaping @Sendable (AiHttpRequest, CancelToken) async throws -> AiHttpResponse) { self.answer = answer }

    func send(_ request: AiHttpRequest, _ cancel: CancelToken) async throws -> AiHttpResponse {
        requests.add(request)
        return try await answer(request, cancel)
    }

    static func response(_ status: Int, _ text: String, type: String? = "text/event-stream", location: String? = nil) -> AiHttpResponse {
        AiHttpResponse(status: status, contentType: type, location: location, body: FakeBody(text))
    }

    static func sse(_ pieces: String...) -> AiHttpResponse {
        var text = ": ping\n\n"
        for p in pieces { text += "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\(AiProtocol.quote(p))}}]}\n\n" }
        text += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return response(200, text)
    }

    static func json(_ status: Int, _ json: String) -> AiHttpResponse { response(status, json, type: "application/json") }
}

/// Waits until `cancel` fires, then throws `CancellationError`.
func waitForCancel(_ cancel: CancelToken) async throws {
    let once = AiOnce<Int>()
    let id = cancel.register { once.resume(with: .failure(CancellationError())) }
    defer { cancel.unregister(id) }
    _ = try await withCheckedThrowingContinuation { once.begin($0) }
}

struct AiClientTests {
    private static func header(_ r: AiHttpRequest, _ name: String) -> String? {
        r.headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    @Test func streamsAChatAnswer() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.sse("The ", "answer", " [p. 2].") }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "llama3.2", apiKey: nil, handler: handler)
        let pieces = AiRecorder<String>()
        let reply = try await client.chat([.user("Q?")], onText: { pieces.add($0) })

        #expect(reply.text == "The answer [p. 2].")
        #expect(pieces.all == ["The ", "answer", " [p. 2]."])
        #expect(reply.finishReason == "stop")
        #expect(!reply.wasCutOff)
        #expect(handler.requests.count == 1)
        let request = handler.requests.all[0]
        #expect(request.method == "POST")
        #expect(request.url == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(Self.header(request, "Authorization") == nil)
        let body = String(decoding: request.body ?? [], as: UTF8.self)
        #expect(body.contains("\"stream\":true"))
        #expect(body.contains("\"model\":\"llama3.2\""))
    }

    @Test func sendsTheKeyOnlyAsABearerToken() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.sse("ok") }
        let client = AiClient(parsed("https://api.example.com/v1"), "m", apiKey: " sk-test ", handler: handler)
        _ = try await client.chat([.user("Q")])
        let request = handler.requests.all[0]
        #expect(Self.header(request, "Authorization") == "Bearer sk-test")
        #expect(!String(decoding: request.body ?? [], as: UTF8.self).contains("sk-test"))
        #expect(Self.header(request, "Cookie") == nil)
    }

    @Test func takesAWholeJsonAnswer() async throws {
        let handler = FakeAiHandler { _, _ in
            FakeAiHandler.json(200, #"{"choices":[{"index":0,"message":{"role":"assistant","content":"All at once"},"finish_reason":"length"}]}"#)
        }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: handler)
        let reply = try await client.chat([.user("Q")])
        #expect(reply.text == "All at once")
        #expect(reply.wasCutOff)
    }

    @Test func explainsHttpErrors() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.json(404, #"{"error":{"message":"model \"phi4\" not found, try pulling it first"}}"#) }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "phi4", apiKey: nil, handler: handler)
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("ollama pull phi4") == true)

        let denied = FakeAiHandler { _, _ in FakeAiHandler.json(401, #"{"error":{"message":"Incorrect API key"}}"#) }
        let cloud = AiClient(parsed("https://api.example.com/v1"), "m", apiKey: "bad", handler: denied)
        let message2 = await aiMessage { _ = try await cloud.chat([.user("Q")]) }
        #expect(message2?.contains("API key") == true)
        #expect(message2?.replacingOccurrences(of: "Incorrect API key", with: "").contains("bad") == false)
    }

    @Test func refusesRedirects() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.response(307, "", location: "https://elsewhere.example.net/v1/chat/completions") }
        let client = AiClient(parsed("https://api.example.com/v1"), "m", apiKey: nil, handler: handler)
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("elsewhere.example.net") == true)
        #expect(handler.requests.count == 1)
    }

    @Test(arguments: [
        (AiEndpoint.ollamaUrl, "Is Ollama running?"),
        (AiEndpoint.lmStudioUrl, "LM Studio"),
        ("http://192.168.1.50:8000/v1", "Is the server running"),
    ])
    func explainsRefusedConnections(_ url: String, _ hint: String) async throws {
        let handler = FakeAiHandler { _, _ in throw AiNetError.refused }
        let client = AiClient(parsed(url), "m", apiKey: nil, handler: handler)
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains(hint) == true)
    }

    @Test func explainsUnknownHostsAndCertificates() async throws {
        let dns = FakeAiHandler { _, _ in throw AiNetError.hostNotFound }
        let a = AiClient(parsed("https://api.example.com/v1"), "m", apiKey: nil, handler: dns)
        let first = await aiMessage { _ = try await a.chat([.user("Q")]) }
        #expect(first?.contains("Couldn't find api.example.com") == true)
        let tls = FakeAiHandler { _, _ in throw AiNetError.secureConnection }
        let b = AiClient(parsed("https://api.example.com/v1"), "m", apiKey: nil, handler: tls)
        let second = await aiMessage { _ = try await b.chat([.user("Q")]) }
        #expect(second?.contains("secure connection") == true)
    }

    private static let stalling: @Sendable (AiHttpRequest, CancelToken) async throws -> AiHttpResponse = { _, _ in
        AiHttpResponse(status: 200, contentType: "text/event-stream", location: nil,
                       body: FakeBody("data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n", stall: true))
    }

    @Test func cancellingStops() async throws {
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: FakeAiHandler(Self.stalling))
        let cancel = CancelToken()
        let got = AiRecorder<String>()
        await #expect(throws: CancellationError.self) {
            _ = try await client.chat([.user("Q")], onText: {
                got.add($0)
                cancel.cancel()
            }, cancel: cancel)
        }
        #expect(got.all == ["Hal"])
    }

    @Test func givesUpOnAStalledStream() async throws {
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: FakeAiHandler(Self.stalling),
                              timeouts: AiTimeouts(connect: 1, firstByte: 5, idle: 0.2))
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("stopped answering") == true)
    }

    @Test func timesOutWaitingForTheFirstByte() async throws {
        let handler = FakeAiHandler { _, cancel in
            try await waitForCancel(cancel)
            return FakeAiHandler.response(200, "")
        }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: handler, timeouts: AiTimeouts(connect: 1, firstByte: 0.2, idle: 1))
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("didn't answer") == true)
        #expect(message?.contains("loading") == true)
    }

    @Test func emptyStreamIsAnError() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.response(200, "") }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "m", apiKey: nil, handler: handler)
        await #expect(throws: AiError.self) { _ = try await client.chat([.user("Q")]) }
    }

    @Test func listsModels() async throws {
        let handler = FakeAiHandler { r, _ in
            r.url.hasSuffix("/v1/models") ? FakeAiHandler.json(200, #"{"data":[{"id":"qwen3:8b"},{"id":"llama3.2"}]}"#) : FakeAiHandler.json(404, "{}")
        }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "", apiKey: nil, handler: handler)
        #expect(try await client.listModels() == ["llama3.2", "qwen3:8b"])
        #expect(handler.requests.all[0].method == "GET")

        let none = FakeAiHandler { _, _ in FakeAiHandler.json(404, "{}") }
        let c2 = AiClient(parsed(AiEndpoint.ollamaUrl), "", apiKey: nil, handler: none)
        #expect(try await c2.listModels().isEmpty)
    }

    @Test func localEndpointsSkipTheProxyAndNothingRedirects() {
        let local = AiClient.createHandler(parsed(AiEndpoint.ollamaUrl))
        #expect(!local.usesProxy)
        #expect(!local.followsRedirects)
        #expect(!local.usesCookies)
        let cloud = AiClient.createHandler(parsed("https://api.example.com/v1"))
        #expect(cloud.usesProxy)
        #expect(!cloud.followsRedirects)
    }
}

struct AiTextTests {
    private static func pages(_ texts: String...) -> [AiPageText] {
        texts.enumerated().map { AiPageText($0.offset, $0.element) }
    }

    @Test func pagesThatFitShareOneChunk() throws {
        let chunks = AiText.chunk(Self.pages("First page.", "", "Third   page.\n\n\n\nMore."), 1000)
        #expect(chunks.count == 1)
        let c = chunks[0]
        #expect(c.firstPage == 0)
        #expect(c.lastPage == 2)
        #expect(c.text == "[Page 1]\nFirst page.\n\n[Page 3]\nThird page.\n\nMore.")
        #expect(c.pagesText == "pages 1–3")
    }

    @Test func longTextIsCutAtBreaksWithinTheLimit() {
        let para = Array(repeating: "Some words make a sentence.", count: 40).joined(separator: " ") // ~1100 chars
        let chunks = AiText.chunk(Self.pages(para, para, para), 150)
        #expect(chunks.count >= 6)
        for c in chunks {
            #expect(AiText.estimateTokens(c.text) <= 150)
            #expect(c.text.hasPrefix("[Page "))
            #expect(c.text.hasSuffix(".")) // cut after a sentence
        }
        // Nothing lost: every word comes through once.
        let words = chunks.reduce(0) { sum, c in
            sum + c.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { $0 == "sentence." }.count
        }
        #expect(words == 120)
    }

    @Test func cutsDontSplitSurrogatePairs() {
        let emoji = String(repeating: "😀", count: 300)
        for piece in AiText.pieces(emoji, 101) {
            let units = Array(piece.utf16)
            #expect(!UTF16.isLeadSurrogate(units[units.count - 1]))
            #expect(!UTF16.isTrailSurrogate(units[0]))
            #expect(!piece.contains("\u{FFFD}"))
        }
    }

    @Test func findsPageCitations() {
        let answer = "Rent is due monthly [p. 2]. Fees [pp. 3-4] and [page 5] apply (p. 1); see [p. 99] and [p.7]."
        let cites = AiText.citations(answer, 10)
        #expect(cites.map(\.page) == [1, 2, 4, 0, 6])
        let ns = answer as NSString
        #expect(ns.substring(with: NSRange(location: cites[0].start, length: cites[0].length)) == "[p. 2]")
        #expect(ns.substring(with: NSRange(location: cites[1].start, length: cites[1].length)) == "[pp. 3-4]")
        #expect(AiText.citations("Paragraph [3] and [p. 0].", 10).isEmpty)
    }

    @Test func hidesReasoning() {
        var r = AiText.withoutThinking("<think>Let me see")
        #expect(r.text == "")
        #expect(r.thinking)
        r = AiText.withoutThinking("  <think>hmm\n</think>\n\nAnswer.")
        #expect(r.text == "Answer.")
        #expect(!r.thinking)
        r = AiText.withoutThinking("No tags")
        #expect(r.text == "No tags")
        #expect(!r.thinking)
    }

    @Test func budgetGrowsWithTheContext() {
        #expect(AiText.inputTokens(2048) >= 300)
        #expect(AiText.inputTokens(8192) > AiText.inputTokens(4096))
        for ctx in AiText.contextSizes { // the text, the instructions and the answer fit together
            #expect(AiText.inputTokens(ctx) + 400 + AiText.answerTokens(ctx) <= ctx)
        }
        #expect(AiText.defaultContextTokens == 4096)
        #expect(AiText.pagesText([0, 1, 2, 4]) == "pages 1–3, 5")
        #expect(AiText.pagesText([3]) == "page 4")
    }
}

struct AiPromptTests {
    private static func pages(_ texts: String...) -> [AiPageText] {
        texts.enumerated().map { AiPageText($0.offset, $0.element) }
    }

    private static let page = Array(repeating: "Words in a sentence.", count: 60).joined(separator: " ")

    @Test func shortDocumentsAreSummarizedInOneRequest() async throws {
        let chunks = AiText.chunk(Self.pages("Alpha.", "Beta."), 10_000)
        let calls = AiRecorder<(messages: [AiMessage], step: AiStep)>()
        let result = try await AiPrompts.summarize(chunks, inputTokens: 10_000, ask: { m, s, _ in
            calls.add((m, s))
            return "Summary [p. 1]"
        })
        #expect(result == "Summary [p. 1]")
        #expect(calls.count == 1)
        let call = calls.all[0]
        #expect(call.step.isFinal)
        #expect(call.messages[0].role == "system")
        #expect(call.messages[0].content.contains("[p. N]"))
        #expect(call.messages[1].content.contains("[Page 2]\nBeta."))
    }

    @Test func longDocumentsAreMappedThenCombined() async throws {
        let chunks = AiText.chunk(Self.pages(Self.page, Self.page, Self.page, Self.page), 400)
        #expect(chunks.count >= 4)
        let steps = AiRecorder<AiStep>()
        let result = try await AiPrompts.summarize(chunks, inputTokens: 400, ask: { _, s, _ in
            steps.add(s)
            return s.isFinal ? "Final" : "Part summary \(s.index)"
        })
        #expect(result == "Final")
        #expect(steps.count == chunks.count + 1)
        #expect(steps.all.filter(\.isFinal).count == 1)
        #expect(steps.all.last?.isFinal == true)
        #expect(steps.all.map(\.index) == Array(1...steps.count))
    }

    @Test func longPartialSummariesAreCombinedInRounds() async throws {
        let chunks = AiText.chunk(Self.pages(Self.page, Self.page, Self.page, Self.page, Self.page, Self.page), 400)
        let combine = AiRecorder<Int>()
        let result = try await AiPrompts.summarize(chunks, inputTokens: 400, ask: { m, s, _ in
            if m[1].content.hasPrefix("These are summaries") { combine.add(1) }
            return s.isFinal ? "Final" : String(repeating: "x", count: 600) // wordy parts: three don't fit one request
        })
        #expect(result == "Final")
        #expect(combine.count >= 2)
    }

    @Test func emptyTextIsRefusedAndCancelStops() async throws {
        await #expect(throws: AiError.self) { _ = try await AiPrompts.summarize([], inputTokens: 1000, ask: { _, _, _ in "" }) }
        let chunks = AiText.chunk(Self.pages(Self.page, Self.page, Self.page), 400)
        let cancel = CancelToken()
        let calls = AiRecorder<Int>()
        await #expect(throws: CancellationError.self) {
            _ = try await AiPrompts.summarize(chunks, inputTokens: 400, ask: { _, _, _ in
                calls.add(1)
                cancel.cancel()
                return "s"
            }, cancel: cancel)
        }
        #expect(calls.count == 1)
    }

    @Test func askSendsTheWholeTextWhenItFits() {
        let r = AiPrompts.ask("What is due?", history: [AiTurn("Who signs?", "The tenant [p. 1].")], pages: Self.pages("Lease between A and B.", "Rent is due monthly."), inputTokens: 10_000)
        #expect(!r.trimmed)
        #expect(r.pages == [0, 1])
        #expect(r.messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(r.messages[0].content.contains("[Page 2]\nRent is due monthly."))
        #expect(r.messages[r.messages.count - 1].content == "What is due?")
    }

    @Test func askPicksTheRelatedPartsOfALongDocument() {
        let filler = Array(repeating: "General background about the company and its history.", count: 40).joined(separator: " ")
        let pages = Self.pages(filler, filler, "The security deposit is two months of rent, returned within 30 days.", filler, filler)
        let r = AiPrompts.ask("How much is the security deposit?", history: [], pages: pages, inputTokens: 800)
        #expect(r.trimmed)
        #expect(r.pages.contains(2))
        #expect(r.messages[0].content.contains("security deposit is two months"))
        #expect(r.messages.reduce(0) { $0 + AiText.estimateTokens($1.content) } < 800 + AiText.estimateTokens(AiPrompts.askSystem) + 100)
        #expect(r.messages[0].content.contains("most related"))
    }

    @Test func askDropsTheOldestTurnsFirst() {
        let history = (1...30).map { AiTurn("Question \($0)?", String(repeating: "a", count: 200)) }
        let r = AiPrompts.ask("Last?", history: history, pages: Self.pages("Text."), inputTokens: 3000)
        let questions = r.messages.filter { $0.role == "user" }.map(\.content)
        #expect(questions.last == "Last?")
        #expect(questions.contains("Question 30?"))
        #expect(!questions.contains("Question 1?"))
    }

    @Test func explainQuotesTheSelection() throws {
        let m = try AiPrompts.explain("  Force   majeure clause ", page: 4, inputTokens: 5000)
        #expect(m[1].content.contains("page 5"))
        #expect(m[1].content.contains("Force majeure clause"))
        #expect(throws: AiError.self) { try AiPrompts.explain(String(repeating: "x", count: 6000), page: 0, inputTokens: 1000) }
        #expect(throws: AiError.self) { try AiPrompts.explain("   ", page: 0, inputTokens: 5000) }
    }

    @Test func copyRestrictionIsReadFromThePermissions() throws {
        // The app asks before sending text of a PDF whose permissions forbid copying.
        var noCopy = PdfPermissions.all
        noCopy.copy = false
        let pdf = try PdfSecurity.protect(ExportTestPdf.make(), nil, userPassword: nil, ownerPassword: "owner-pw", permissions: noCopy)
        #expect(try !PdfSecurity.readSecurity(pdf, nil).permissions.copy)
        #expect(!PdfSecurity.isOpenPassword(pdf, "owner-pw"))
        // The Windows `IsCopyRestrictedAsync`, which is a Kit rule here.
        #expect(AiCopyRestriction.isRestricted(pdf, password: nil, hasEncryption: true))
        #expect(!AiCopyRestriction.isRestricted(pdf, password: "owner-pw", hasEncryption: true)) // opened as the author
        #expect(!AiCopyRestriction.isRestricted(pdf, password: nil, hasEncryption: false))
    }

    @Test func previewShowsEveryRequestAndRole() {
        let preview = AiPrompts.preview([[.system("S1"), .user("U1")], [.user("U2")]])
        #expect(preview.contains("Request 1 of 2"))
        #expect(preview.contains("── system ──\nS1"))
        #expect(preview.contains("── user ──\nU2"))
        #expect(!AiPrompts.preview([[.user("only")]]).contains("Request"))
    }
}
