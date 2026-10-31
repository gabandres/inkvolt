import Foundation
import Testing
@testable import PdfCore

/// A Mac addition, from the release review of E11: what a crafted or broken server can send, through the parsers and through
/// the real connection (`AiLoopbackServer`), and addresses that try to look like something else. A crash fails the whole run;
/// a hang fails by `within`.
struct AiHostileTests {
    struct TimedOut: Error {}

    private final class Outcome<T>: @unchecked Sendable { var result: Result<T, Error>? }

    private func within<T: Sendable>(_ seconds: Double = 20, _ work: @escaping @Sendable () throws -> T) throws -> T {
        let box = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
            box.result = Result { try work() }
            done.signal()
        }.start()
        if done.wait(timeout: .now() + seconds) == .timedOut { throw TimedOut() }
        return try box.result!.get()
    }

    private static func message(_ work: () async throws -> Void) async -> String? {
        do {
            try await work()
            return nil
        } catch let e as AiError {
            return e.message
        } catch {
            return "not an AiError: \(error)"
        }
    }

    private static func endpoint(_ url: String) -> AiEndpoint { AiEndpoint.tryParse(url).endpoint! }

    // MARK: JSON that isn't what was asked for (Windows' ParseWhole and OllamaLoadedContext throw on these)

    private static let notObjects = ["[]", "[[]]", "1", "-1.5", "null", "true", "\"text\"", "{}", "{\"choices\":1}", "{\"data\":{}}", "{\"models\":\"x\"}"]

    @Test(arguments: notObjects)
    func jsonThatIsNoAnswerIsAnAiErrorOrNothing(_ json: String) throws {
        #expect(throws: AiError.self) { _ = try AiProtocol.parseModels(json) }
        #expect(AiProtocol.ollamaLoadedContext(json, "m") == nil)
        let shown = AiProtocol.ollamaShowContext(json)
        #expect(shown.numCtx == nil && shown.trained == nil)
        _ = AiProtocol.errorMessageOf(json)
        if json != "{\"choices\":1}" { // "choices" is there, with nothing in it: an empty answer, as on Windows
            #expect(throws: AiError.self) { _ = try AiStreamParser.parseWhole(json) }
        } else {
            #expect(try AiStreamParser.parseWhole(json).text == "")
        }
    }

    @Test(arguments: [
        #"{"choices":[1,"x",null,[],{"index":"0"},{"index":1e999},{"delta":[]},{"delta":{"content":1}},{"message":{"content":[]}},{"finish_reason":1}]}"#,
        #"{"choices":[{"index":99999999999999999999,"delta":{"content":"far"}}]}"#,
        #"{"error":[]}"#, #"{"error":{"message":1}}"#, #"{"detail":{}}"#, #"{"error":null,"choices":[]}"#,
        #"{"models":[1,{"name":1},{"name":"m","context_length":99999999999999999999},{"name":"m","context_length":-1},{"model":"m","context_length":1.5},{"name":"m","context_length":"8"}]}"#,
        #"{"parameters":1,"model_info":[]}"#, #"{"parameters":"num_ctx 99999999999999999999","model_info":{"a.context_length":1e999}}"#,
        #"{"data":[1,{"id":1},{"id":""},{"id":null}]}"#,
    ])
    func oddValuesDontStopAnything(_ json: String) {
        _ = try? AiStreamParser.parseWhole(json)
        _ = try? AiProtocol.parseModels(json)
        #expect(AiProtocol.ollamaLoadedContext(json, "m") == nil)
        let shown = AiProtocol.ollamaShowContext(json)
        #expect(shown.numCtx == nil && shown.trained == nil)
        _ = AiProtocol.errorMessageOf(json)
        let parser = AiStreamParser()
        _ = try? parser.line("data: " + json)
        _ = try? parser.end()
    }

    @Test(arguments: ["[", "{\"a\":"])
    func jsonNestedWithoutEndIsRefused(_ opening: String) throws {
        let json = String(repeating: opening, count: 1_000_000)
        try within(60) {
            #expect(throws: AiError.self) { _ = try AiStreamParser.parseWhole(json) }
            #expect(AiProtocol.ollamaLoadedContext(json, "m") == nil)
        }
    }

    @Test func anAnswerNestedAsDeepAsAnAnswerMayBeIsRead() throws {
        let inner = String(repeating: "[", count: JsonNesting.limit - 5) + String(repeating: "]", count: JsonNesting.limit - 5)
        let reply = try AiStreamParser.parseWhole("{\"choices\":[{\"message\":{\"content\":\"[[[{{{ in a string\"},\"pad\":\(inner)}]}")
        #expect(reply.text == "[[[{{{ in a string")
    }

    /// The same answers through the real connection.
    @Test(arguments: notObjects)
    func theClientSaysSoWhenTheServerAnswersWithIt(_ json: String) async throws {
        let server = try #require(AiLoopbackServer { _ in .json(200, json) })
        defer { server.stop() }
        let client = AiClient(Self.endpoint("http://127.0.0.1:\(server.port)/v1"), "m", apiKey: nil)
        let answered = await Self.message { _ = try await client.chat([.user("Q")]) }
        if json != "{\"choices\":1}" { #expect(answered?.contains("not an AiError") == false) }
        let listed = await Self.message { _ = try await client.listModels() }
        #expect(listed?.contains("not an AiError") == false)
        #expect(try await client.ollamaContext().context == nil)
    }

    @Test(arguments: [
        "HTTP/1.1 99999999999999999999 X\r\n\r\n", "HTTP/1.1 -5 X\r\n\r\n", "HTTP/1.1 0 X\r\n\r\n", "HTTP/1.1 999 X\r\n\r\n", "NOT HTTP\r\n\r\n", "\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\nx", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Length: 9223372036854775807\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFFFFF\r\nx", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFFFFFFFFFF\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nx", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;x=y\r\n",
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nx", "HTTP/1.1 302 Moved\r\nLocation: \u{1}://%%%\r\n\r\n", "HTTP/1.1 302 Moved\r\n\r\n",
        "HTTP/1.1 100 Go on\r\n\r\nHTTP/1.1 100 Go on\r\n\r\n", "HTTP/1.1 200 OK\r\n: no name\r\nno colon\r\n\r\n",
    ])
    func aServerSpeakingBrokenHttpIsAnError(_ raw: String) async throws {
        let server = try #require(AiLoopbackServer { _ in .raw(raw) })
        defer { server.stop() }
        let client = AiClient(Self.endpoint("http://127.0.0.1:\(server.port)/v1"), "m", apiKey: nil)
        let said = await Self.message { _ = try await client.chat([.user("Q")]) }
        #expect(said?.contains("not an AiError") != true, "\(said ?? "")")
    }

    @Test func anAnswerNestedWithoutEndThroughTheConnectionIsAnError() async throws {
        let body = String(repeating: "{\"a\":", count: 1_000_000)
        let server = try #require(AiLoopbackServer { _ in .json(200, body) })
        defer { server.stop() }
        let client = AiClient(Self.endpoint("http://127.0.0.1:\(server.port)/v1"), "m", apiKey: nil)
        #expect(await Self.message { _ = try await client.chat([.user("Q")]) }?.contains("not an AiError") == false)
        #expect(await Self.message { _ = try await client.listModels() }?.contains("not an AiError") == false)
        #expect(try await client.ollamaContext().context == nil)
    }

    // MARK: Work and memory a server can ask for

    @Test func aParameterOfNothingButLineBreaksIsReadInTime() throws {
        let json = "{\"parameters\":\"" + String(repeating: "\\n", count: (AiClient.maxBodyBytes - 32) / 2) + "\"}"
        _ = try within { AiProtocol.ollamaShowContext(json) }
    }

    @Test func anEventOfManyDataLinesIsntReadAgainAtEachLine() throws {
        // "[", then a million lines of "1,": every line's attempt reads all of the event so far, to its unfinished end.
        _ = try within {
            let parser = AiStreamParser()
            _ = try parser.line("data: [")
            for _ in 0..<1_000_000 { _ = try parser.line("data: 1,") }
        }
    }

    @Test func aJsonValueOverSeveralDataLinesIsStillRead() throws {
        // Past the lines tried one by one, the blank line that ends the event reads it.
        let parser = AiStreamParser()
        var text = try parser.line("data: {\"choices\":[{\"delta\":{\"content\":\"joined\"}}],\"pad\":[")
        for _ in 0..<500 { text += try parser.line("data: 1,") }
        text += try parser.line("data: 1]}")
        text += try parser.line("")
        #expect(text == "joined")
    }

    @Test func trailersWithoutALineBreakDontFillMemory() throws {
        var reader = AiHttpReader()
        _ = try reader.head(Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        _ = try reader.body(Array("0\r\n".utf8))
        let endless = [UInt8](repeating: 0x78, count: 65536)
        #expect(throws: AiNetError.self) {
            for _ in 0..<64 { _ = try reader.body(endless) }
        }
    }

    @Test func aBodyFasterThanItsReaderIsStopped() async throws {
        final class Closed: @unchecked Sendable { var count = 0 }
        let closed = Closed()
        let queue = AiByteQueue(onClose: { closed.count += 1 })
        let piece = [UInt8](repeating: 0x78, count: 1 << 20)
        for _ in 0..<(AiByteQueue.maxQueuedBytes >> 20) + 2 { queue.yield(piece) }
        #expect(closed.count == 1)
        var bytes = 0
        let token = CancelToken()
        await #expect(throws: AiNetError.self) {
            while let got = try await queue.read(token) { bytes += got.count }
        }
        #expect(bytes <= AiByteQueue.maxQueuedBytes)
    }

    // MARK: Addresses

    @Test(arguments: [
        ("http://2130706433:11434/v1", AiReach.thisMac), ("http://0x7f.1:11434/v1", .thisMac), ("http://127.1/v1", .thisMac), ("http://[::1]:1/v1", .thisMac),
        ("http://[::ffff:127.0.0.1]:1/v1", .thisMac), ("http://LOCALHOST:1/v1", .thisMac), ("http://localhost.:1/v1", .thisMac),
        ("http://169.254.169.254/v1", .localNetwork), ("http://100.64.0.1/v1", .localNetwork), ("http://[fe80::1]/v1", .localNetwork), ("http://[fd00::1]/v1", .localNetwork),
        ("http://nas/v1", .localNetwork), ("http://nas.local/v1", .localNetwork),
    ] as [(String, AiReach)])
    func addressesReachWhereTheySay(_ url: String, _ reach: AiReach) throws {
        #expect(AiEndpoint.tryParse(url).endpoint?.reach == reach, "\(url)")
    }

    @Test(arguments: [
        "http://8.8.8.8/v1", "http://134744072/v1", "http://[::ffff:8.8.8.8]/v1", "http://[2001:db8::1]/v1", "http://0.0.0.0:11434/v1", "http://[::]:11434/v1", "http://1.1/v1",
        "http://127.0.0.1.example.com/v1", "http://localhost.example.com/v1", "http://nas.local.example.com/v1", "http://example.com/v1",
        "http://user:secret@127.0.0.1/v1", "http://127.0.0.1@example.com/v1", "http://example.com\\@127.0.0.1/v1", "http://example.com#@127.0.0.1/v1", "http://127.0.0.1/v1?x=1",
        "ftp://127.0.0.1/v1", "file:///etc/passwd", "http://exa mple.com/v1", "http://127.0.0.1:99999/v1", "http://127.0.0.1:-1/v1", "http://[::1/v1",
        "http://local\u{0068}ost\u{FF0E}example\u{FF0E}com/v1",
    ])
    func addressesThatWouldMisleadAreRefused(_ url: String) {
        #expect(AiEndpoint.tryParse(url).endpoint == nil, "\(url)")
    }

    @Test func aMappedAddressCountsAsWhatItStandsFor() throws {
        let local = Self.endpoint("http://nas.local/v1")
        #expect(!local.allows(try #require(AiAddress("::ffff:8.8.8.8"))))
        #expect(local.allows(try #require(AiAddress("::ffff:192.168.1.5"))))
        #expect(!Self.endpoint("http://localhost/v1").allows(try #require(AiAddress("::ffff:192.168.1.5"))))
        #expect(!local.allows(try #require(AiAddress("0.0.0.0"))))
        #expect(!local.allows(try #require(AiAddress("::"))))
    }

    // MARK: Off, and the key

    @Test func theAssistantIsOffUntilTurnedOn() {
        let fresh = AiSettings()
        #expect(!fresh.enabled)
        #expect(fresh.noPreview.isEmpty && fresh.cloudWarned.isEmpty)
        #expect(AiService.current(fresh).config == nil)
        #expect(AiService.current(fresh).problem == "The AI assistant is off.")
        #expect(AiService.describe(fresh).hasPrefix("Off."))
        // Turned on with a model but no answer to "don't ask again": the window always shows.
        var on = fresh
        on.enabled = true
        on.model = "m"
        let config = AiService.current(on).config
        #expect(config?.endpoint.reach == .thisMac) // the preset as it comes: this Mac, not a server anywhere
        let consent = AiConsent(on, Self.endpoint(AiEndpoint.ollamaUrl), copyRestricted: false)
        #expect(consent.asks)
    }

    @Test func aKeyGoesOnlyInTheChatAndModelRequestsToItsOwnEndpoint() async throws {
        let server = try #require(AiLoopbackServer { received in
            received.requestLine.contains("/api/") ? .json(200, "{}") : received.requestLine.hasPrefix("GET") ? .json(200, #"{"data":[]}"#) : .sse(["Hi"])
        })
        defer { server.stop() }
        let client = AiClient(Self.endpoint("http://127.0.0.1:\(server.port)/v1"), "m", apiKey: "SECRET-KEY")
        _ = try await client.ollamaContext()
        _ = try await client.listModels()
        _ = try await client.chat([.user("Q")])
        for request in server.received {
            let hasKey = request.head.contains("SECRET-KEY")
            #expect(hasKey == !request.requestLine.contains("/api/"), "\(request.requestLine)")
            #expect(!request.body.contains("SECRET-KEY"))
            #expect(!request.head.lowercased().contains("user-agent"))
        }
    }
}
