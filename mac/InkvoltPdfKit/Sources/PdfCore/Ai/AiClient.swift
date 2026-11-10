import Foundation
import PrintCore

/// A finished answer: its text and why the model stopped ("length" = cut off by the model's limit).
public struct AiReply: Sendable, Equatable {
    public let text: String
    public let finishReason: String?
    public init(_ text: String, _ finishReason: String?) {
        self.text = text
        self.finishReason = finishReason
    }

    public var wasCutOff: Bool { finishReason == "length" }
}

/// How long to wait, in seconds. Local models can take a while to load before the first word (`firstByte`); after that a
/// stream that goes quiet for `idle` is given up.
public struct AiTimeouts: Sendable {
    public let connect: Double
    public let firstByte: Double
    public let idle: Double
    public init(connect: Double, firstByte: Double, idle: Double) {
        self.connect = connect
        self.firstByte = firstByte
        self.idle = idle
    }

    public static let standard = AiTimeouts(connect: 10, firstByte: 600, idle: 120)
}

/// One HTTP request as the client asks for it.
public struct AiHttpRequest: Sendable {
    public let method: String
    public let url: String
    public var headers: [(name: String, value: String)]
    public let body: [UInt8]?
}

/// A response's body, read piece by piece. `read` throws `CancellationError` once `cancel` fires.
public protocol AiBody: Sendable {
    /// The next bytes; nil at the end.
    func read(_ cancel: CancelToken) async throws -> [UInt8]?
    func close()
}

/// A response as far as its headers.
public struct AiHttpResponse: Sendable {
    public let status: Int
    /// The Content-Type's value.
    public let contentType: String?
    public let location: String?
    public let body: any AiBody
    public init(status: Int, contentType: String?, location: String?, body: any AiBody) {
        self.status = status
        self.contentType = contentType
        self.location = location
        self.body = body
    }
}

/// How requests reach the network (the Windows app's `HttpMessageHandler`): tests answer with a fake, the app uses
/// `AiClient.createHandler`. Failing to connect throws `AiNetError` or `AiAddressError`; `send` throws `CancellationError`
/// once `cancel` fires.
public protocol AiTransport: Sendable {
    /// Whether a system proxy may carry the request.
    var usesProxy: Bool { get }
    var followsRedirects: Bool { get }
    var usesCookies: Bool { get }
    func send(_ request: AiHttpRequest, _ cancel: CancelToken) async throws -> AiHttpResponse
}

/// A connection failure, by what it means for the user.
public enum AiNetError: Error, Sendable, Equatable {
    case refused, timedOut, hostNotFound, secureConnection, closedEarly
    /// A private address that can't be reached: macOS's Local Network permission, or the network.
    case unreachable
    case other(String)
}

/// A name led to an address outside the endpoint's range (or to none); no connection was made.
public struct AiAddressError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// A token that fires when its parent does, or after a time that can be moved (.NET's linked `CancellationTokenSource`
/// with `CancelAfter`). The client tells them apart by whether the parent fired.
///
/// The client moves the time on every line of a stream, so moving it later schedules nothing: the one pending timer, when
/// it wakes early, sleeps again until the time now set. (A timer a line, cancelled or not, stays queued until its time: an
/// endpoint sending keep-alives as fast as they are read queued millions, 42 GB on CI before the system killed the tests.)
final class AiDeadline: @unchecked Sendable {
    let token = CancelToken()
    private let parent: CancelToken?
    private var parentId: Int?
    private let lock = NSLock()
    private var due = DispatchTime.distantFuture
    /// When the earliest pending timer wakes (nil: none pending).
    private var wakeAt: DispatchTime?
    private var finished = false
    private var scheduled = 0
    /// Timers scheduled so far (for tests).
    var timersScheduled: Int { lock.withLock { scheduled } }

    init(_ parent: CancelToken?) {
        self.parent = parent
        parentId = parent?.register { [token] in token.cancel() }
    }

    func cancelAfter(_ seconds: Double) {
        let when = DispatchTime.now() + seconds
        lock.withLock {
            guard !finished else { return }
            due = when
            if let wakeAt, wakeAt <= when { return } // it wakes first and sleeps on until `due`
            schedule(when)
        }
    }

    /// Under the lock.
    private func schedule(_ when: DispatchTime) {
        wakeAt = when
        scheduled += 1
        DispatchQueue.global().asyncAfter(deadline: when) { [self] in wake() }
    }

    private func wake() {
        let fire: Bool = lock.withLock {
            guard !finished else { return false }
            let now = DispatchTime.now()
            if now >= due {
                finished = true
                return true
            }
            // Early (the time was moved on): sleep until it, unless a timer already wakes later than now.
            if wakeAt.map({ $0 <= now }) ?? true { schedule(due) }
            return false
        }
        if fire { token.cancel() }
    }

    func finish() {
        lock.withLock { finished = true }
        parent?.unregister(parentId)
    }
}

/// Talks to one OpenAI-compatible endpoint the user configured. Sends only what it is given (the messages and the model
/// name, plus the API key as a bearer token when there is one); no telemetry, cookies or redirects. Errors come out as
/// `AiError` worded for the user; cancelling throws `CancellationError`.
public final class AiClient: Sendable {
    /// Longest line of a streamed answer, largest whole body read, longest answer kept.
    public static let maxLineChars = 1 << 20, maxBodyBytes = 8 << 20, maxAnswerChars = 4 << 20

    private let endpoint: AiEndpoint
    private let model: String
    private let apiKey: String?
    private let timeouts: AiTimeouts
    private let transport: any AiTransport
    /// The answer's limit sent as `max_tokens`, or nil to send none (see `AiProtocol.chatRequestJson`).
    public let maxAnswerTokens: Int?

    /// - Parameter handler: for tests; by default `createHandler`.
    public init(_ endpoint: AiEndpoint, _ model: String, apiKey: String?, handler: (any AiTransport)? = nil,
                timeouts: AiTimeouts = .standard, maxAnswerTokens: Int? = nil) {
        self.endpoint = endpoint
        self.model = model
        let trimmed = AiText.trim(apiKey ?? "")
        self.apiKey = trimmed.isEmpty ? nil : trimmed
        self.timeouts = timeouts
        self.maxAnswerTokens = maxAnswerTokens
        transport = handler ?? Self.createHandler(endpoint, timeouts)
    }

    /// The connection for an endpoint: no redirects (they could take the text somewhere else), no cookies. Requests to
    /// this Mac or the network never go through a proxy, and connect only to an address in the endpoint's range
    /// (`AiEndpoint.allows`): the name is resolved here and the checked address is the one connected to, so neither a name
    /// that resolves elsewhere nor DNS rebinding can take the text off the Mac or network. Internet endpoints use URLSession
    /// and the Mac's proxy setting, as browsers do.
    /// - Parameter resolve: for tests: name resolution (by default `AiSocketTransport.systemResolve`).
    public static func createHandler(_ endpoint: AiEndpoint, _ timeouts: AiTimeouts = .standard,
                                     resolve: (@Sendable (String) async throws -> [AiAddress])? = nil) -> any AiTransport {
        if endpoint.reach == .internet { return AiUrlSessionTransport() }
        return AiSocketTransport(endpoint, timeouts, resolve: resolve ?? AiSocketTransport.systemResolve)
    }

    /// Ollama only: how much context the model really gets, asked from Ollama's own API on the same server (only the
    /// model name is sent). `/api/ps` gives the context of the model as loaded; else `/api/show` gives its num_ctx
    /// parameter; else nil (Ollama then uses its server default, OLLAMA_CONTEXT_LENGTH or 4,096 on most machines). Both are
    /// capped at the context the model was trained for. Its OpenAI-compatible endpoint takes no context size per request.
    public func ollamaContext(cancel: CancelToken? = nil) async throws -> (context: Int?, source: String) {
        var trained: Int?
        var numCtx: Int?
        var loaded: Int?
        do {
            loaded = AiProtocol.ollamaLoadedContext(try await native("GET", "/api/ps", nil, cancel), model)
            let body = "{\"model\":\(AiProtocol.quote(model))}"
            (numCtx, trained) = AiProtocol.ollamaShowContext(try await native("POST", "/api/show", body, cancel))
        } catch is AiError {
            // Not Ollama, or not answering: the request itself will say why.
        }
        var context: Int?
        var source = ""
        if let loaded {
            (context, source) = (loaded, loc("as Ollama loaded it"))
        } else if let numCtx {
            (context, source) = (numCtx, loc("the model's num_ctx in Ollama"))
        }
        if let c = context, let trained, trained < c { (context, source) = (trained, loc("the model's own limit")) }
        return (context, source)
    }

    private func native(_ method: String, _ path: String, _ json: String?, _ cancel: CancelToken?) async throws -> String {
        var headers: [(name: String, value: String)] = []
        if json != nil { headers.append(("Content-Type", "application/json; charset=utf-8")) }
        let request = AiHttpRequest(method: method, url: endpoint.origin + path, headers: headers, body: json.map { Array($0.utf8) })
        let deadline = AiDeadline(cancel)
        defer { deadline.finish() }
        deadline.cancelAfter(5)
        let response = try await send(request, deadline, cancel, 5)
        defer { response.body.close() }
        let body = try await readBody(response, deadline, cancel, truncate: true)
        return (200..<300).contains(response.status) ? body : ""
    }

    /// The models the endpoint offers (`GET /models`). Empty when it doesn't list them (404).
    public func listModels(cancel: CancelToken? = nil) async throws -> [String] {
        let request = AiHttpRequest(method: "GET", url: endpoint.modelsUrl, headers: try authorization(), body: nil)
        let deadline = AiDeadline(cancel)
        defer { deadline.finish() }
        deadline.cancelAfter(20)
        let response = try await send(request, deadline, cancel, 20)
        defer { response.body.close() }
        let ok = (200..<300).contains(response.status)
        let body = try await readBody(response, deadline, cancel, truncate: !ok)
        if response.status == 404 { return [] }
        if !ok { throw AiError(AiProtocol.describeError(response.status, AiProtocol.errorMessageOf(body), model, endpoint)) }
        return try AiProtocol.parseModels(body)
    }

    /// Sends one chat request and streams the answer, calling `onText` with each piece as it arrives.
    public func chat(_ messages: [AiMessage], onText: (@Sendable (String) -> Void)? = nil, cancel: CancelToken? = nil) async throws -> AiReply {
        let json = AiProtocol.chatRequestJson(model, messages, maxTokens: maxAnswerTokens)
        var headers: [(name: String, value: String)] = [("Content-Type", "application/json; charset=utf-8"), ("Accept", "text/event-stream")]
        headers += try authorization()
        let request = AiHttpRequest(method: "POST", url: endpoint.chatUrl, headers: headers, body: Array(json.utf8))

        let deadline = AiDeadline(cancel)
        defer { deadline.finish() }
        deadline.cancelAfter(timeouts.firstByte)
        let response = try await send(request, deadline, cancel, timeouts.firstByte)
        defer { response.body.close() }
        if !(200..<300).contains(response.status) {
            let body = try await readBody(response, deadline, cancel, truncate: true)
            throw AiError(AiProtocol.describeError(response.status, AiProtocol.errorMessageOf(body), model, endpoint), status: response.status)
        }

        let mediaType = (response.contentType ?? "").lowercased()
        if mediaType.contains("json") && !mediaType.contains("ndjson") {
            // The server ignored "stream": the whole answer comes at once.
            let whole = try AiStreamParser.parseWhole(try await readBody(response, deadline, cancel))
            onText?(whole.text)
            return AiReply(whole.text, whole.finishReason)
        }

        let parser = AiStreamParser()
        var text = ""
        var length = 0
        do {
            let reader = AiLineReader(response.body)
            while !parser.done {
                deadline.cancelAfter(timeouts.idle)
                guard let line = try await reader.readLine(deadline.token) else { break }
                let piece = try parser.line(line)
                if piece.isEmpty { continue }
                let pieceLength = piece.utf16.count
                if length + pieceLength > Self.maxAnswerChars {
                    throw AiError(loc("The answer from {0} grew far longer than an answer should; it was stopped.", endpoint.host))
                }
                text += piece
                length += pieceLength
                onText?(piece)
            }
            let rest = try parser.end()
            if !rest.isEmpty {
                text += rest
                onText?(rest)
            }
        } catch is CancellationError {
            if cancel?.isCancelled == true { throw CancellationError() }
            throw AiError(loc("{0} stopped answering (nothing for {1} seconds).", endpoint.host, CoreLanguage.number(Int(timeouts.idle.rounded())))) // bounded: the app's own timeouts (AiTimeouts.standard)
        } catch is AiNetError {
            if cancel?.isCancelled == true { throw CancellationError() }
            throw AiError(Self.closedEarly(endpoint))
        }
        if !parser.sawData { throw AiError(loc("{0} answered with an empty stream. Is the model name right?", endpoint.host)) }
        return AiReply(text, parser.finishReason)
    }

    /// The key as a bearer token, when there is one. A pasted key with a line break in it could add headers of its own,
    /// so it is refused here, before anything is sent.
    private func authorization() throws -> [(name: String, value: String)] {
        guard let apiKey else { return [] }
        if apiKey.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw AiError(loc("The API key has a line break or another character a key can't have. Enter it again in Settings › AI assistant."))
        }
        return [("Authorization", "Bearer \(apiKey)")]
    }

    private func send(_ request: AiHttpRequest, _ deadline: AiDeadline, _ cancel: CancelToken?, _ wait: Double) async throws -> AiHttpResponse {
        let response: AiHttpResponse
        do {
            response = try await transport.send(request, deadline.token)
        } catch is CancellationError {
            if cancel?.isCancelled == true { throw CancellationError() }
            let loading = endpoint.reach == .thisMac ? " " + loc("A large model may still be loading: try again in a moment.") : ""
            throw AiError(loc("{0} didn't answer within {1}.", endpoint.host, Self.describe(wait)) + loading)
        } catch let error as AiAddressError {
            throw AiError(error.message)
        } catch let error as AiNetError {
            if cancel?.isCancelled == true { throw CancellationError() }
            throw AiError(Self.describeConnectionFailure(endpoint, error))
        }
        if (300..<400).contains(response.status) {
            response.body.close()
            let to = response.location.flatMap { URL(string: $0, relativeTo: URL(string: endpoint.key + "/")) }?.absoluteURL
            var shown: String?
            if let to, var parts = URLComponents(url: to, resolvingAgainstBaseURL: false) {
                parts.query = nil
                parts.fragment = nil
                shown = parts.string
            }
            if let shown {
                throw AiError(loc("{0} redirects to {1}. Inkvolt PDF doesn't follow redirects: enter that address in Settings › AI assistant if you trust it.", endpoint.host, shown),
                              status: response.status)
            }
            throw AiError(loc("{0} redirects to another address. Inkvolt PDF doesn't follow redirects: enter that address in Settings › AI assistant if you trust it.", endpoint.host),
                          status: response.status)
        }
        return response
    }

    /// Reads a whole (not streamed) body, at most `maxBodyBytes`: an error body is cut there (`truncate`), an answer that
    /// long is refused.
    private func readBody(_ response: AiHttpResponse, _ deadline: AiDeadline, _ cancel: CancelToken?, truncate: Bool = false) async throws -> String {
        var bytes: [UInt8] = []
        do {
            while let piece = try await response.body.read(deadline.token) {
                if bytes.count + piece.count > Self.maxBodyBytes {
                    if !truncate { throw AiError(loc("{0} sent more than {1} MB in one answer; it was stopped.", endpoint.host, CoreLanguage.number(Self.maxBodyBytes >> 20))) }
                    bytes += piece.prefix(Self.maxBodyBytes - bytes.count)
                    break
                }
                bytes += piece
            }
        } catch is CancellationError {
            if cancel?.isCancelled == true { throw CancellationError() }
            throw AiError(loc("The endpoint took too long to send its answer."))
        } catch is AiNetError {
            if cancel?.isCancelled == true { throw CancellationError() }
            throw AiError(Self.closedEarly(endpoint))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "Couldn't connect to localhost:11434. Is Ollama running?" and the like.
    public static func describeConnectionFailure(_ endpoint: AiEndpoint, _ error: AiNetError) -> String {
        switch error {
        case .timedOut:
            return loc("{0} didn't respond. Check the address, the network and any firewall.", endpoint.host)
        case .hostNotFound:
            return loc("Couldn't find {0}. Check the address, and that this Mac is online.", endpoint.hostName)
        case .secureConnection:
            return loc("Couldn't make a secure connection to {0}: its certificate isn't trusted by this Mac, or it doesn't speak https.", endpoint.host)
        case .closedEarly:
            return closedEarly(endpoint)
        case .unreachable:
            return loc("Couldn't reach {0}. If it is on your network, allow Inkvolt PDF in System Settings › Privacy & Security › Local Network, and check that the computer is on.", endpoint.host)
        case .refused:
            switch endpoint.serverName {
            case "Ollama":
                return loc("Couldn't connect to {0}: nothing is listening there. Is Ollama running? Start it (or run: ollama serve) and try again.", endpoint.host)
            case "LM Studio":
                return loc("Couldn't connect to {0}: nothing is listening there. Is LM Studio's local server running? Start it in LM Studio (Developer › Start server) and try again.", endpoint.host)
            default:
                return loc("Couldn't connect to {0}: nothing is listening there. Is the server running, and is the port right?", endpoint.host)
            }
        case .other(let what):
            return loc("The request to {0} failed ({1}).", endpoint.host, what)
        }
    }

    /// The server was reached but the connection ended before the answer did (the server stopped or crashed).
    public static func closedEarly(_ endpoint: AiEndpoint) -> String {
        if let name = endpoint.serverName {
            return loc("The connection to {0} closed before the answer finished: did {1} stop or crash?", endpoint.host, name)
        }
        return loc("The connection to {0} closed before the answer finished.", endpoint.host)
    }

    private static func describe(_ t: Double) -> String {
        if t >= 60 {
            let minutes = Int((t / 60).rounded()) // bounded: t is one of the app's own timeouts
            return t >= 120 ? loc("{0} minutes", CoreLanguage.number(minutes)) : loc("{0} minute", CoreLanguage.number(minutes))
        }
        return loc("{0} seconds", CoreLanguage.number(Int(t.rounded()))) // bounded: t is one of the app's own timeouts
    }
}

/// Reads UTF-8 lines (LF or CRLF) of at most `AiClient.maxLineChars`, so a stream without line breaks can't fill memory.
final class AiLineReader {
    private let body: any AiBody
    private var buffer: [UInt8] = []
    private var at = 0
    private var line: [UInt8] = []
    private var lineChars = 0
    private var ended = false

    init(_ body: any AiBody) { self.body = body }

    func readLine(_ cancel: CancelToken) async throws -> String? {
        while true {
            while at < buffer.count {
                let b = buffer[at]
                at += 1
                if b == 10 { return take() }
                // UTF-16 units, as Windows counts: continuation bytes add none, a four-byte letter adds two.
                if b & 0xC0 != 0x80 { lineChars += b >= 0xF0 ? 2 : 1 }
                if lineChars > AiClient.maxLineChars { throw AiError(loc("The endpoint sent a line too long to be part of a streamed answer.")) }
                line.append(b)
            }
            if ended { return line.isEmpty ? nil : take() }
            if let next = try await body.read(cancel) {
                buffer = next
            } else {
                buffer = []
                ended = true
            }
            at = 0
        }
    }

    private func take() -> String {
        if line.last == 13 { line.removeLast() }
        let s = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        lineChars = 0
        return s
    }
}
