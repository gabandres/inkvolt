import Foundation
import Security
import Testing
@testable import PdfCore

private func parsed(_ url: String) -> AiEndpoint { AiEndpoint.tryParse(url).endpoint! }

/// Mac additions: the rules the Windows tab and dialogs hold (`AiService`, `AiActions.ConfirmSend`, `DocumentTab.Ai`), kept
/// in PdfCore here so they are tested, and the promise: off by default, nothing sent until the user approved it.
struct AiAssistantTests {
    private static func settings(_ preset: String = "Custom", url: String = "http://127.0.0.1:9/v1", model: String = "m") -> AiSettings {
        var s = AiSettings()
        s.enabled = true
        s.preset = preset
        s.customUrl = url
        s.model = model
        return s
    }

    @Test func theAssistantIsOffByDefault() {
        let s = AiSettings()
        #expect(!s.enabled)
        #expect(s.preset == "Ollama")
        #expect(s.contextTokens == 4096)
        #expect(s.noPreview.isEmpty && s.cloudWarned.isEmpty)
        let now = AiService.current(s)
        #expect(now.config == nil)
        #expect(now.problem == "The AI assistant is off.")
        #expect(AiService.describe(s).hasPrefix("Off."))
    }

    @Test func configurationNeedsAnAddressAndAModel() {
        #expect(AiService.current(Self.settings(model: " ")).problem == "Choose a model for the AI assistant.")
        #expect(AiService.current(Self.settings(url: "http://8.8.8.8/v1")).problem?.contains("https://") == true)
        let local = AiService.current(Self.settings("Ollama", model: " llama3.2 ")).config
        #expect(local?.model == "llama3.2")
        #expect(local?.endpoint.key == AiEndpoint.ollamaUrl)
        #expect(local?.contextTokens == 4096)
        #expect(local?.serverLabel == "Ollama")
        var lm = Self.settings("LMStudio")
        lm.contextTokens = 100
        #expect(AiService.current(lm).config?.contextTokens == 1024) // kept within the range the settings allow
        #expect(AiService.current(lm).config?.serverLabel == "LM Studio")
        #expect(AiService.describe(Self.settings("Ollama")) == "On: m at Ollama. Stays on this Mac.")
        #expect(AiService.describe(Self.settings(model: "")).hasPrefix("On, but not set up:"))
    }

    @Test func settingsAreCheckedBeforeSaving() {
        #expect(AiService.validate(enabled: false, url: "nonsense url", model: "", context: "4,096") == nil)
        #expect(AiService.validate(enabled: false, url: "", model: "", context: "12")?.contains("1,024") == true)
        #expect(AiService.validate(enabled: true, url: "", model: "m", context: "4096")?.contains("address") == true)
        #expect(AiService.validate(enabled: true, url: AiEndpoint.ollamaUrl, model: " ", context: "4096")?.contains("model") == true)
        #expect(AiService.validate(enabled: true, url: AiEndpoint.ollamaUrl, model: "m", context: "8.192") == nil)
        #expect(AiService.parseContext("131,072") == 131072)
        #expect(AiService.parseContext("2,000,001") == nil)
    }

    @Test func theWindowAlwaysShowsUnlessTheUserChoseOtherwise() {
        let local = parsed("http://127.0.0.1:9/v1")
        var s = Self.settings()
        #expect(AiConsent(s, local, copyRestricted: false).asks) // every send, until told otherwise
        s.noPreview = ["HTTP://127.0.0.1:9/V1"]
        #expect(!AiConsent(s, local, copyRestricted: false).asks) // the same endpoint, in any case
        #expect(AiConsent(s, local, copyRestricted: true).asks) // text the PDF forbids copying: always
        #expect(AiConsent(s, local, copyRestricted: false, force: true).asks)
        #expect(!AiConsent(s, local, copyRestricted: false, force: true).offersDontAsk)
        #expect(AiConsent(s, parsed("http://127.0.0.1:10/v1"), copyRestricted: false).asks) // another endpoint isn't trusted
    }

    @Test func theFirstSendToTheInternetIsAlwaysAskedAbout() {
        let cloud = parsed("https://api.example.com/v1")
        var s = Self.settings(url: cloud.key)
        s.noPreview = [cloud.key]
        let first = AiConsent(s, cloud, copyRestricted: false)
        #expect(first.asks)
        #expect(first.firstCloud)
        #expect(first.blocked(host: cloud.host, understood: false, sendAnyway: false)?.contains("I understand") == true)
        #expect(first.blocked(host: cloud.host, understood: true, sendAnyway: false) == nil)
        s = first.applied(to: s, cloud, dontAsk: true)
        #expect(s.cloudWarned == [cloud.key])
        #expect(s.noPreview == [cloud.key])
        #expect(!AiConsent(s, cloud, copyRestricted: false).asks)
        #expect(!AiConsent(Self.settings(), parsed("http://nas.local/v1"), copyRestricted: false).firstCloud)
    }

    @Test func restrictedTextNeedsItsOwnTick() {
        let local = parsed("http://127.0.0.1:9/v1")
        let c = AiConsent(Self.settings(), local, copyRestricted: true)
        #expect(c.blocked(host: local.host, understood: false, sendAnyway: false)?.contains("Send it anyway") == true)
        #expect(c.blocked(host: local.host, understood: false, sendAnyway: true) == nil)
    }

    @Test func sayingDontAskIsForgottenWhenUnticked() {
        let local = parsed("http://127.0.0.1:9/v1")
        var s = Self.settings()
        s.noPreview = [local.key]
        let c = AiConsent(s, local, copyRestricted: true)
        #expect(c.dontAskNow)
        #expect(c.applied(to: s, local, dontAsk: false).noPreview.isEmpty)
    }

    @Test func whatGoesIsSaidInCharactersTokensAndRequests() {
        let one = AiOutgoing([[.system("abc"), .user("de")]], what: "The text of page 1")
        #expect(one.characters == 5)
        #expect(one.summary == "The text of page 1: 5 characters (about \(AiText.estimateTokens("abc") + AiText.estimateTokens("de") + 8) tokens) in 1 request.")
        let two = AiOutgoing([[.user("a")], [.user("b")]], what: "X", followUp: "more")
        #expect(two.summary.hasSuffix("in 2 requests, then more."))
        let long = String(repeating: "x", count: AiConsent.maxShown + 7)
        #expect(AiConsent.shownPreview(long).hasSuffix("… and 7 more characters (Copy All has everything)."))
        #expect(AiConsent.shownPreview("short") == "short")
    }

    @Test func jobsSayWhyNothingGoes() {
        let config = AiService.current(Self.settings())
        let c = config.config!
        #expect(AiJobs.summary([2], [AiPageText(2, "  ")], c, settings: Self.settings()).notSent == "Not sent: page 3 has no text. Scanned pages need Recognize Text (OCR) first.")
        #expect(AiJobs.summary([0, 1], [AiPageText(0, ""), AiPageText(1, "")], c, settings: Self.settings()).notSent?.contains("pages 1–2 have no text") == true)
        #expect(AiJobs.question("Q", turns: [], pages: [0], [AiPageText(0, "")], c).notSent == "Not sent: page 1 has no text to ask about.")
        #expect(AiJobs.explanation("   ", page: 0, c).notSent == "The selection has no text to explain.")
    }

    @Test func onlyWhatWasAskedAboutIsInTheRequest() throws {
        let c = try #require(AiService.current(Self.settings()).config)
        let texts = [AiPageText(0, "Rent is due."), AiPageText(1, "Other page.")]
        let q = try #require(AiJobs.question("When?", turns: [AiTurn("Who?", "A [p. 1].")], pages: [0], [texts[0]], c).job)
        let all = q.request.messages.map(\.content).joined(separator: "\n")
        #expect(all.contains("Rent is due."))
        #expect(!all.contains("Other page."))
        #expect(q.outgoing.what == "Your question and the text of page 1, and the conversation so far (1 earlier answer)")
        let e = try #require(AiJobs.explanation("Force  majeure", page: 4, c).job)
        #expect(e.label == "Explain: “Force majeure”")
        #expect(e.historyQuestion == "Explain this passage from page 5: \"Force majeure\"")
        #expect(e.outgoing.what == "The selected text (page 5)")
        let s = try #require(AiJobs.summary([0], [texts[0]], c, settings: Self.settings()).job)
        #expect(s.label == "Summarize page 1")
        #expect(s.outgoing.followUp == nil)
    }

    @Test func thePagesBoxTakesAllOrARange() {
        #expect(AiJobs.scope("All", pageCount: 3).pages == [0, 1, 2])
        #expect(AiJobs.scope(" ", pageCount: 2).pages == [0, 1])
        #expect(AiJobs.scope("2-3", pageCount: 5).pages == [1, 2])
        #expect(AiJobs.scope("9", pageCount: 2).error?.hasPrefix("Pages: ") == true)
    }

    @Test func combiningIsShownUnlessALocalEndpointSaidNotTo() {
        let page = Array(repeating: "Words in a sentence.", count: 900).joined(separator: " ")
        let texts = (0..<6).map { AiPageText($0, page) }
        var local = Self.settings()
        let c = AiService.current(local).config!
        let shown = AiJobs.summary(Array(0..<6), texts, c, settings: local).job!
        #expect(shown.showCombine)
        #expect(shown.outgoing.followUp?.contains("which you'll see") == true)
        local.noPreview = [c.endpoint.key]
        let skipped = AiJobs.summary(Array(0..<6), texts, c, settings: local).job!
        #expect(!skipped.showCombine)
        #expect(skipped.outgoing.followUp?.contains("without asking") == true)
        // An internet endpoint's combining requests are always shown.
        var cloud = Self.settings(url: "https://api.example.com/v1")
        cloud.noPreview = ["https://api.example.com/v1"]
        let cc = AiService.current(cloud).config!
        #expect(AiJobs.summary(Array(0..<6), texts, cc, settings: cloud).job!.showCombine)
    }

    @Test func aSummaryDeclinedAtCombiningEndsWithItsPartsAndSendsNoMore() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.sse("A part.") }
        let page = Array(repeating: "Words in a sentence.", count: 900).joined(separator: " ")
        let s = Self.settings()
        let c = AiService.current(s).config!
        let job = AiJobs.summary(Array(0..<6), (0..<6).map { AiPageText($0, page) }, c, settings: s).job!
        let client = AiClient(c.endpoint, c.model, apiKey: nil, handler: handler)
        let steps = AiRecorder<AiStep>()
        let reply = try await AiJobs.run(job, client: client, config: c, onFinal: nil, onStep: { steps.add($0) }, confirmCombine: { _, _ in false }, cancel: nil)
        #expect(reply.finishReason == AiJobs.notCombined)
        #expect(handler.requests.count == job.chunks.count)
        #expect(AiJobs.finishNote(reply, answer: reply.text)?.contains("not combined") == true)
    }

    @Test func onlyTheFinalAnswerStreamsToThePane() async throws {
        let handler = FakeAiHandler { r, _ in
            let body = String(decoding: r.body ?? [], as: UTF8.self)
            return body.contains("These are summaries") ? FakeAiHandler.sse("<think>hm</think>", "Whole.") : FakeAiHandler.sse("Part.")
        }
        let page = Array(repeating: "Words in a sentence.", count: 900).joined(separator: " ")
        let s = Self.settings()
        let c = AiService.current(s).config!
        let job = AiJobs.summary(Array(0..<6), (0..<6).map { AiPageText($0, page) }, c, settings: s).job!
        let streamed = AiRecorder<String>()
        let client = AiClient(c.endpoint, c.model, apiKey: nil, handler: handler)
        let reply = try await AiJobs.run(job, client: client, config: c, onFinal: { streamed.add($0) }, onStep: { _ in }, confirmCombine: { _, _ in true }, cancel: nil)
        #expect(reply.text == "Whole.")
        #expect(streamed.all.joined() == "<think>hm</think>Whole.")
        #expect(reply.finishReason == "stop")
    }

    @Test func ollamaIsAskedForTheContextAndOnlyItsModelNameGoes() async throws {
        let handler = FakeAiHandler { r, _ in
            r.url.hasSuffix("/api/ps")
                ? FakeAiHandler.json(200, #"{"models":[{"name":"m:latest","context_length":8192}]}"#)
                : FakeAiHandler.json(200, #"{"parameters":"num_ctx 2048\n","model_info":{"gemma.context_length":4096}}"#)
        }
        let s = Self.settings("Ollama")
        let c = AiService.current(s).config!
        let keys = AiMemoryKeyStore()
        let resolved = try await AiService.resolve(c, keys: keys, handler: handler)
        #expect(resolved.contextTokens == 4096) // as loaded, capped at what it was trained for
        #expect(resolved.contextSource == "the model's own limit")
        #expect(handler.requests.all.map(\.url) == ["http://127.0.0.1:11434/api/ps", "http://127.0.0.1:11434/api/show"])
        #expect(handler.requests.all[0].body == nil)
        #expect(String(decoding: handler.requests.all[1].body ?? [], as: UTF8.self) == "{\"model\":\"m\"}")
        #expect(AiService.client(resolved, keys: keys, handler: handler).maxAnswerTokens == AiText.answerTokens(4096))

        let silent = FakeAiHandler { _, _ in FakeAiHandler.json(404, "{}") }
        let fallback = try await AiService.resolve(c, keys: keys, handler: silent)
        #expect(fallback.contextTokens == 4096)
        #expect(fallback.contextSource == "Ollama's usual default (it didn't say)")
        // Other endpoints keep the size set in Settings, and aren't asked.
        let lm = AiService.current(Self.settings("LMStudio")).config!
        #expect(try await AiService.resolve(lm, keys: keys, handler: silent) == lm)
        #expect(silent.requests.count == 2)
        #expect(AiService.client(lm, keys: keys, handler: silent).maxAnswerTokens == nil)
    }

    @Test func aLoadedContextBelowTheTrainedOneStands() {
        #expect(AiProtocol.ollamaLoadedContext(#"{"models":[{"model":"LLAMA3.2","context_length":2048}]}"#, "llama3.2:latest") == 2048)
        #expect(AiProtocol.ollamaLoadedContext(#"[1]"#, "m") == nil)
        #expect(AiProtocol.ollamaShowContext(#"{"parameters":"stop x\n  num_ctx   16384\n"}"#).numCtx == 16384)
        #expect(AiProtocol.ollamaShowContext("[]").numCtx == nil)
    }

    @Test func anAnswerIsDrawnWithHeadingsBulletsBoldAndLinks() {
        let runs = AiAnswerMarkup.runs("## Title [p. 1]\n- one **two** [p. 2]\nloose ** star [p. 99]", pageCount: 5)
        #expect(runs == [
            AiRun("Title ", bold: true), AiRun("[p. 1]", bold: true, page: 0), AiRun("\n"),
            AiRun("•  one "), AiRun("two", bold: true), AiRun(" "), AiRun("[p. 2]", page: 1), AiRun("\n"),
            AiRun("loose "), AiRun("** star [p. 99]"),
        ])
        #expect(AiAnswerMarkup.copied("A") == "A\n\n(AI-generated, may be wrong)")
    }

    @Test func altTextIsOneCleanLine() {
        #expect(AiPrompts.cleanAltText("  \"Alt text: A red  bar\nchart.\" ") == "A red bar chart.")
        let long = String(repeating: "word ", count: 80)
        let cut = AiPrompts.cleanAltText(long)
        #expect(cut.utf16.count <= 251)
        #expect(cut.hasSuffix("word…"))
        let job = AiJobs.altText(png: Array(repeating: 0, count: 24), nearby: "Near  it", language: "en", page: 2, number: 4)
        #expect(job.messages[1].images.count == 1)
        #expect(job.messages[1].content.contains("page 3"))
        #expect(job.messages[1].content.contains("Near it"))
        #expect(job.outgoing.what == "picture 4 of page 3 (as an image) and the text near it")
        #expect(AiPrompts.preview(job.outgoing.requests).contains("[a picture: PNG, 0 × 0 pixels, 0 KB]"))
        let json = AiProtocol.chatRequestJson("m", job.messages)
        #expect(json.contains("\"type\":\"image_url\""))
        #expect(json.contains("data:image/png;base64,"))
    }

    @Test func keysAreKeptPerEndpointAndARemovedOneIsGone() throws {
        let keys = AiMemoryKeyStore()
        try keys.set("https://a.example/v1", " sk-a ")
        #expect(keys.get("HTTPS://A.example/v1") == "sk-a")
        #expect(keys.get("https://b.example/v1") == nil)
        #expect(keys.has("https://a.example/v1"))
        try keys.set("https://a.example/v1", nil)
        #expect(!keys.has("https://a.example/v1"))
    }

    @Test func aKeyWithALineBreakIsRefusedBeforeAnythingIsSent() async throws {
        let handler = FakeAiHandler { _, _ in FakeAiHandler.sse("no") }
        let client = AiClient(parsed(AiEndpoint.ollamaUrl), "m", apiKey: "sk-a\r\nX-Evil: 1", handler: handler)
        let chat = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(chat?.contains("API key") == true)
        #expect(chat?.contains("X-Evil") == false)
        await #expect(throws: AiError.self) { _ = try await client.listModels() }
        #expect(handler.requests.count == 0)
    }

    @Test func pageTextIsReadOnceForAnEngine() async throws {
        let engine = try PdfEngine.open(TestPdf.make(3))
        let cache = AiPageCache()
        let token = CancelToken()
        let first = try await cache.read([0, 2], engine: engine, cancel: token)
        #expect(first.map(\.page) == [0, 2])
        #expect(first.allSatisfy { !$0.text.isEmpty })
        #expect(cache.missing([0, 1, 2], engine: engine) == [1])
        let other = try PdfEngine.open(TestPdf.make(2))
        #expect(cache.missing([0], engine: other) == [0]) // an edit replaced the engine: read again
        let cancelled = CancelToken()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await AiPageCache().read([0], engine: other, cancel: cancelled) }
    }

    /// The real Keychain API, on a keychain made for the test and thrown away: the login keychain is locked over SSH
    /// (errSecInteractionNotAllowed) and is the user's. SecKeychainOpen is deprecated, so it is found by name (nothing else
    /// reads a keychain by path); the app itself never calls it.
    @Test func theKeychainKeepsAKeyPerEndpoint() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-ai-\(UUID().uuidString).keychain-db").path
        func security(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "security \(args[0])")
        }
        try security("create-keychain", "-p", "throwaway", path)
        defer { try? security("delete-keychain", path) }
        try security("unlock-keychain", "-p", "throwaway", path)
        typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<SecKeychain?>) -> OSStatus
        let opener = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainOpen")) // RTLD_DEFAULT
        var keychain: SecKeychain?
        #expect(unsafeBitCast(opener, to: Open.self)(path, &keychain) == errSecSuccess)

        let store = AiKeychainStore(service: "com.bermudezsystems.InkvoltPdf.ai-key.test", keychain: try #require(keychain))
        let a = "https://tests.example.invalid/v1"
        try store.set(a, " not-a-real-key-1 ")
        #expect(store.get(a) == "not-a-real-key-1")
        try store.set(a, "not-a-real-key-2")
        #expect(store.get(a.uppercased()) == "not-a-real-key-2")
        #expect(store.get("https://other.example.invalid/v1") == nil)
        #expect(store.has(a))
        try store.set(a, nil)
        #expect(store.get(a) == nil)
        try store.set(a, nil) // removing what isn't there is fine
    }
}

/// Mac additions: the real connection to a fake server on loopback (`AiLoopbackServer`), no AI service anywhere.
struct AiLoopbackTests {
    private static func client(_ server: AiLoopbackServer, key: String? = nil, timeouts: AiTimeouts = .standard) -> AiClient {
        AiClient(parsed("http://127.0.0.1:\(server.port)/v1"), "m", apiKey: key, timeouts: timeouts)
    }

    @Test func aStreamedAnswerArrivesPieceByPieceOverTheSocket() async throws {
        let server = try #require(AiLoopbackServer { _ in .sse(["Hel", "lo ", "😀 [p. 1]"], pause: 0.02) })
        defer { server.stop() }
        let pieces = AiRecorder<String>()
        let reply = try await Self.client(server).chat([.user("Q")], onText: { pieces.add($0) })
        #expect(reply.text == "Hello 😀 [p. 1]")
        #expect(pieces.all == ["Hel", "lo ", "😀 [p. 1]"])
        #expect(reply.finishReason == "stop")
    }

    @Test func theRequestHasOnlyWhatItMust() async throws {
        let server = try #require(AiLoopbackServer { _ in .sse(["ok"]) })
        defer { server.stop() }
        _ = try await Self.client(server, key: "not-a-real-key").chat([.user("private text")])
        let got = try #require(server.received.first)
        #expect(got.requestLine == "POST /v1/chat/completions HTTP/1.1")
        let names = got.head.components(separatedBy: "\r\n").dropFirst().compactMap { $0.split(separator: ":").first.map { $0.lowercased() } }
        #expect(Set(names) == ["host", "content-type", "accept", "authorization", "content-length", "accept-encoding", "connection"])
        #expect(got.head.contains("Authorization: Bearer not-a-real-key"))
        #expect(got.body == AiProtocol.chatRequestJson("m", [.user("private text")]))
    }

    @Test func withoutAKeyNoAuthorizationGoes() async throws {
        let server = try #require(AiLoopbackServer { _ in .json(200, #"{"data":[{"id":"b"},{"id":"a"}]}"#) })
        defer { server.stop() }
        #expect(try await Self.client(server).listModels() == ["a", "b"])
        let got = try #require(server.received.first)
        #expect(got.requestLine == "GET /v1/models HTTP/1.1")
        #expect(!got.head.lowercased().contains("authorization"))
    }

    @Test func aRedirectIsNotFollowedAndTheKeyGoesNowhereElse() async throws {
        let server = try #require(AiLoopbackServer { _ in .raw("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/v1/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") })
        defer { server.stop() }
        let message = await aiMessage { _ = try await Self.client(server, key: "k").chat([.user("Q")]) }
        #expect(message?.contains("doesn't follow redirects") == true)
        #expect(server.received.count == 1)
    }

    @Test func nothingListeningIsSaidAsSuch() async throws {
        // A port that was free a moment ago.
        let server = try #require(AiLoopbackServer { _ in .sse([]) })
        let port = server.port
        server.stop()
        let client = AiClient(parsed("http://127.0.0.1:\(port)/v1"), "m", apiKey: nil)
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("nothing is listening") == true)
    }

    @Test func stopCutsARunningAnswer() async throws {
        let server = try #require(AiLoopbackServer { _ in
            var a = AiLoopbackServer.Answer.sse(["first"])
            a.pieces.removeLast(2) // no end: the stream stays open
            a.holdOpen = true
            return a
        })
        defer { server.stop() }
        let cancel = CancelToken()
        let started = Date()
        await #expect(throws: CancellationError.self) {
            _ = try await Self.client(server).chat([.user("Q")], onText: { _ in cancel.cancel() }, cancel: cancel)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aQuietStreamIsGivenUp() async throws {
        let server = try #require(AiLoopbackServer { _ in
            var a = AiLoopbackServer.Answer.sse(["first"])
            a.pieces.removeLast(2)
            a.holdOpen = true
            return a
        })
        defer { server.stop() }
        let client = Self.client(server, timeouts: AiTimeouts(connect: 2, firstByte: 2, idle: 0.2))
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("stopped answering") == true)
    }

    @Test func aServerThatDiesMidAnswerIsSaidAsSuch() async throws {
        let server = try #require(AiLoopbackServer { _ in
            var a = AiLoopbackServer.Answer.sse(["first"])
            a.pieces.removeLast(2) // chunked, but closed before its last chunk
            return a
        })
        defer { server.stop() }
        let message = await aiMessage { _ = try await Self.client(server).chat([.user("Q")]) }
        #expect(message?.contains("closed before the answer finished") == true)
    }

    @Test func plainHttpFromAnHttpsEndpointFailsSecurely() async throws {
        let server = try #require(AiLoopbackServer { _ in .raw("HTTP/1.1 200 OK\r\n\r\nnot tls") })
        defer { server.stop() }
        let client = AiClient(parsed("https://127.0.0.1:\(server.port)/v1"), "m", apiKey: "k")
        let message = await aiMessage { _ = try await client.chat([.user("private text")]) }
        #expect(message?.contains("secure connection") == true, "\(message ?? "no message")")
    }

    @Test func happyEyeballsSkipsAnAddressThatRefuses() async throws {
        // localhost as ::1 (nothing listens there on this port) and 127.0.0.1.
        let server = try #require(AiLoopbackServer { _ in .sse(["ok"]) })
        defer { server.stop() }
        let ep = parsed("http://localhost:\(server.port)/v1")
        let addresses = [try #require(AiAddress("::1")), try #require(AiAddress("127.0.0.1"))]
        let client = AiClient(ep, "m", apiKey: nil, handler: AiClient.createHandler(ep, resolve: { _ in addresses }))
        #expect(try await client.chat([.user("Q")]).text == "ok")
    }

    @Test func aNameThatResolvesToNothingIsNotFound() async throws {
        let ep = parsed("http://nowhere.local:9/v1")
        let client = AiClient(ep, "m", apiKey: nil, handler: AiClient.createHandler(ep, resolve: { _ in [] }))
        let message = await aiMessage { _ = try await client.chat([.user("Q")]) }
        #expect(message?.contains("Couldn't find nowhere.local") == true)
    }

    @Test func uRLSessionStreamsAndDoesNotFollowRedirects() async throws {
        // The internet path's transport, against loopback: only the test sends it there; `tryParse` keeps http:// off it.
        let server = try #require(AiLoopbackServer { received in
            received.requestLine.contains("/moved") ? .raw("HTTP/1.1 307 Moved\r\nLocation: /v1/other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") : .sse(["a", "b"], pause: 0.02)
        })
        defer { server.stop() }
        let transport = AiUrlSessionTransport()
        let token = CancelToken()
        let request = AiHttpRequest(method: "POST", url: "http://127.0.0.1:\(server.port)/v1/chat/completions", headers: [], body: Array("{}".utf8))
        let response = try await transport.send(request, token)
        #expect(response.status == 200)
        var all: [UInt8] = []
        while let piece = try await response.body.read(token) { all += piece }
        response.body.close()
        #expect(String(decoding: all, as: UTF8.self).contains("[DONE]"))

        let moved = try await transport.send(AiHttpRequest(method: "GET", url: "http://127.0.0.1:\(server.port)/moved", headers: [], body: nil), token)
        #expect(moved.status == 307)
        #expect(moved.location == "/v1/other")
        moved.body.close()
        #expect(server.received.count == 2)
    }
}

/// Mac additions: the HTTP reader behind `AiSocketTransport`, fed in awkward pieces.
struct AiHttpReaderTests {
    private func head(_ reader: inout AiHttpReader, _ text: String) throws -> AiHttpReader.Head? { try reader.head(Array(text.utf8)) }

    @Test func aHeadMayArriveInPiecesAndContinueSkipped() throws {
        var r = AiHttpReader()
        #expect(try head(&r, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 20") == nil)
        let h = try #require(try head(&r, "0 OK\r\nContent-Type: text/plain\r\nX-A: 1\r\nx-a: 2\r\nContent-Length: 3\r\n\r\nab"))
        #expect(h.status == 200)
        #expect(h.headers["content-type"] == "text/plain")
        #expect(h.headers["x-a"] == "1, 2")
        #expect(String(decoding: try r.body([]), as: UTF8.self) == "ab")
        #expect(!r.bodyDone)
        #expect(String(decoding: try r.body(Array("cXXX".utf8)), as: UTF8.self) == "c")
        #expect(r.bodyDone)
    }

    @Test func chunksMaySplitAnywhere() throws {
        var r = AiHttpReader()
        _ = try head(&r, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
        var out: [UInt8] = []
        for b in Array("5;x=y\r\nhello\r\n1\r\n \r\n6\r\nworld!\r\n0\r\nTrailer: z\r\n\r\n".utf8) { out += try r.body([b]) }
        #expect(String(decoding: out, as: UTF8.self) == "hello world!")
        #expect(r.bodyDone)
    }

    @Test func anEndBeforeTheBodyEndsIsNotAnAnswer() throws {
        var chunked = AiHttpReader()
        _ = try head(&chunked, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe")
        _ = try chunked.body([])
        #expect(throws: AiNetError.closedEarly) { try chunked.connectionEnded() }
        var sized = AiHttpReader()
        _ = try head(&sized, "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nabc")
        _ = try sized.body([])
        #expect(throws: AiNetError.closedEarly) { try sized.connectionEnded() }
        var open = AiHttpReader()
        _ = try head(&open, "HTTP/1.1 200 OK\r\n\r\nabc")
        #expect(String(decoding: try open.body([]), as: UTF8.self) == "abc")
        try open.connectionEnded()
        #expect(open.bodyDone)
    }

    @Test func unreadableAnswersAreRefused() {
        var r = AiHttpReader()
        #expect(throws: AiNetError.self) { _ = try head(&r, "not http\r\n\r\n") }
        var z = AiHttpReader()
        #expect(throws: AiNetError.self) { _ = try head(&z, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n") }
        var big = AiHttpReader()
        #expect(throws: AiNetError.self) { _ = try head(&big, String(repeating: "x", count: 70_000)) }
        var bad = AiHttpReader()
        #expect(throws: AiNetError.self) {
            _ = try head(&bad, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            _ = try bad.body(Array("zz\r\n".utf8))
        }
    }

    @Test func addressesReadAsDotNetReadsThem() throws {
        #expect(AiAddress("127.1")?.description == "127.0.0.1")
        #expect(AiAddress("[::1]")?.description == "::1")
        #expect(AiAddress("gpu-box") == nil)
        #expect(AiAddress("cafe") == nil)
        #expect(AiEndpoint.classify("127.1") == .thisMac)
        // A name made of digits is an address, not a local name, so 8.8.8.8 written as a number stays the internet.
        #expect(AiEndpoint.classify("134744072") == .internet)
        #expect(AiEndpoint.tryParse("http://134744072/v1").endpoint == nil)
        #expect(AiEndpoint.tryParse("http://[fe80::1]:8000").endpoint?.key == "http://[fe80::1]:8000/v1")
        #expect(AiEndpoint.tryParse("http://[fe80::1]:8000").endpoint?.reach == .localNetwork)
        #expect(AiEndpoint.tryParse("http://host:99999/v1").endpoint == nil)
        #expect(AiEndpoint.tryParse("http://exa mple/v1").endpoint == nil)
        #expect(AiEndpoint.tryParse("mailto:me@example.com").endpoint == nil)
    }
}
