import Foundation

/// One chat message: role "system", "user" or "assistant".
public struct AiMessage: Sendable, Equatable {
    public let role: String
    public let content: String
    /// Pictures sent with the text (PNG), for a vision model: alternate text for a figure.
    public var images: [[UInt8]] = []

    public init(role: String, content: String, images: [[UInt8]] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    public static func system(_ content: String) -> AiMessage { AiMessage(role: "system", content: content) }
    public static func user(_ content: String) -> AiMessage { AiMessage(role: "user", content: content) }
    public static func assistant(_ content: String) -> AiMessage { AiMessage(role: "assistant", content: content) }
}

/// JSONSerialization recurses without a limit: a few kilobytes of {"a":{"a":... from a server or a preset file would run the
/// thread out of stack and stop the app. So it reads only what nests within the depth Windows' System.Text.Json allows by
/// default; no answer or preset nests anywhere near it.
enum JsonNesting {
    static let limit = 64

    static func isSafe(_ json: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for b in json {
            if inString {
                if escaped {
                    escaped = false
                } else if b == 0x5C {
                    escaped = true
                } else if b == 0x22 {
                    inString = false
                }
            } else if b == 0x22 {
                inString = true
            } else if b == 0x5B || b == 0x7B {
                depth += 1
                if depth > limit { return false }
            } else if b == 0x5D || b == 0x7D {
                depth -= 1
            }
        }
        return true
    }
}

/// A failure talking to the AI endpoint, with a message meant for the user.
public struct AiError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The OpenAI-compatible chat API (`POST {base}/chat/completions`, `GET {base}/models`) that Ollama, LM Studio, llama.cpp,
/// vLLM and the cloud providers share: request bodies, model lists, and error messages worded for the user.
public enum AiProtocol {
    /// The request body: model, messages and stream, nothing else (no user id, no metadata), plus the answer's limit
    /// (`max_tokens`) when given: only for servers known to honour it (Ollama maps it to num_predict), since some cloud
    /// models refuse it.
    public static func chatRequestJson(_ model: String, _ messages: [AiMessage], stream: Bool = true, maxTokens: Int? = nil) -> String {
        var json = "{\"model\":\(quote(model)),\"messages\":["
        for (i, m) in messages.enumerated() {
            if i > 0 { json += "," }
            json += "{\"role\":\(quote(m.role)),\"content\":"
            if m.images.isEmpty {
                json += quote(m.content)
            } else {
                // Text and pictures as content parts (the OpenAI vision format Ollama and LM Studio accept too).
                json += "[{\"type\":\"text\",\"text\":\(quote(m.content))}"
                for png in m.images {
                    json += ",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,\(Data(png).base64EncodedString())\"}}"
                }
                json += "]"
            }
            json += "}"
        }
        json += "],\"stream\":\(stream ? "true" : "false")"
        if let maxTokens { json += ",\"max_tokens\":\(maxTokens)" }
        return json + "}"
    }

    /// A string in JSON: quotes, backslashes and control characters escaped.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Any JSON value, or nil when it isn't JSON, or nests too deep (`JsonNesting`).
    static func parse(_ text: String) -> Any? {
        let data = Data(text.utf8)
        guard JsonNesting.isSafe(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The whole number a JSON value holds, as .NET's `TryGetInt32` reads it: a true integer within Int32, not a
    /// boolean, string or fraction.
    static func int32(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n), let v = Int32(exactly: n.int64Value) else { return nil }
        return Int(v)
    }

    /// The model ids of a `/models` answer (`{"data":[{"id":…}]}`), sorted; empty when it has none.
    /// - Throws: `AiError` when the answer isn't a model list.
    public static func parseModels(_ json: String) throws -> [String] {
        guard let value = parse(json) else {
            throw AiError("The endpoint's model list isn't JSON. Is the address right (it usually ends in /v1)?")
        }
        guard let root = value as? [String: Any], let data = root["data"] as? [Any] else {
            throw AiError("The endpoint's model list isn't in the OpenAI format. Type the model's name instead.")
        }
        var seen = Set<String>()
        var ids: [String] = []
        for case let m as [String: Any] in data {
            guard let id = m["id"] as? String, !id.isEmpty, seen.insert(id.lowercased()).inserted else { continue }
            ids.append(id)
        }
        return ids.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The server's own error text from an error body (`{"error":{"message":…}}`, `{"error":"…"}`, `{"detail":…}`), or nil.
    public static func errorMessageOf(_ body: String?) -> String? {
        guard let body, !AiText.trim(body).isEmpty else { return nil }
        if let value = parse(body) { return errorMessageOf(json: value) }
        let text = AiText.trim(body)
        return text.hasPrefix("<") ? nil : shorten(text, 300) // an HTML error page says nothing useful
    }

    static func errorMessageOf(json root: Any) -> String? {
        guard let object = root as? [String: Any] else { return nil }
        for name in ["error", "detail", "message"] {
            guard let e = object[name] else { continue }
            if let s = e as? String { return shorten(s, 300) }
            if let o = e as? [String: Any], let m = o["message"] as? String { return shorten(m, 300) }
        }
        return nil
    }

    /// Ollama's `/api/ps`: the context length the running model was loaded with, or nil when that model isn't loaded (or
    /// the answer doesn't say). "llama3.2" and "llama3.2:latest" are the same model.
    public static func ollamaLoadedContext(_ json: String, _ model: String) -> Int? {
        guard let root = parse(json) as? [String: Any], let models = root["models"] as? [Any] else { return nil }
        for case let m as [String: Any] in models {
            let names = ["name", "model"].compactMap { m[$0] as? String }
            guard names.contains(where: { sameModel($0, model) }) else { continue }
            if let n = int32(m["context_length"]), n > 0 { return n }
        }
        return nil
    }

    /// Ollama's `/api/show`: the model's own `num_ctx` parameter (set in its Modelfile; it overrides the server's default)
    /// and the context it was trained for (`model_info`'s "…context_length"), each nil when absent.
    public static func ollamaShowContext(_ json: String) -> (numCtx: Int?, trained: Int?) {
        guard let root = parse(json) as? [String: Any] else { return (nil, nil) }
        var numCtx: Int?
        var trained: Int?
        if let p = root["parameters"] as? String {
            let pattern = try! NSRegularExpression(pattern: #"(?m)^\s*num_ctx\s+(\d+)"#)
            let whole = NSRange(p.startIndex..., in: p)
            if let m = pattern.firstMatch(in: p, range: whole), let r = Range(m.range(at: 1), in: p), let n = Int32(p[r]), n > 0 {
                numCtx = Int(n)
            }
        }
        if let info = root["model_info"] as? [String: Any] {
            for (name, value) in info where name.hasSuffix(".context_length") {
                if let t = int32(value), t > 0 { trained = t }
            }
        }
        return (numCtx, trained)
    }

    private static func sameModel(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            let t = AiText.trim(s)
            return (t.contains(":") ? t : t + ":latest").lowercased()
        }
        return norm(a) == norm(b)
    }

    /// What an HTTP error status means for the user, with the server's own message when it gives one.
    public static func describeError(_ status: Int, _ serverMessage: String?, _ model: String, _ endpoint: AiEndpoint) -> String {
        let trimmed = AiText.trim(serverMessage ?? "")
        let said = trimmed.isEmpty ? "" : " The server said: \"\(trimmed)\""
        let lower = serverMessage?.lowercased() ?? ""
        let mentionsModel = lower.contains("model")
        let mentionsContext = lower.contains("context") || lower.contains("too long") || lower.contains("tokens")
        switch status {
        case 401, 403:
            return "\(endpoint.host) refused the request (\(status)): check the API key in Settings › AI assistant.\(said)"
        case 404 where mentionsModel:
            let how = endpoint.serverName == "Ollama" ? ", or download it with: ollama pull \(model)." : "."
            return "The model \"\(model)\" isn't available at \(endpoint.host) (404). Pick another one in Settings › AI assistant\(how)\(said)"
        case 404:
            return "Nothing answers at \(endpoint.chatUrl) (404). Check the endpoint address in Settings › AI assistant (it usually ends in /v1).\(said)"
        case 400 where mentionsContext, 413 where mentionsContext:
            return "The text is too long for the model.\(said) Choose fewer pages, or a smaller context size in Settings › AI assistant."
        case 400 where mentionsModel:
            return "\(endpoint.host) doesn't accept the model \"\(model)\".\(said)"
        case 429:
            return "\(endpoint.host) is limiting requests (429): wait a moment, or check your plan's quota.\(said)"
        case 500...:
            return "\(endpoint.host) had a problem answering (\(status)).\(said)"
        default:
            return "\(endpoint.host) refused the request (\(status)).\(said)"
        }
    }

    /// At most `max` UTF-16 units, the last an ellipsis, as Windows counts them (never inside a surrogate pair).
    public static func shorten(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        var cut = text.utf16.index(text.utf16.startIndex, offsetBy: max - 1)
        if UTF16.isTrailSurrogate(text.utf16[cut]) { cut = text.utf16.index(before: cut) }
        return String(text[..<cut]) + "…"
    }
}

/// Reads a streamed chat answer: server-sent events, one `data: {json}` chunk per line (a JSON value split over several
/// data lines is joined, as the SSE format allows), `data: [DONE]` at the end, comments and other fields ignored. Also
/// takes a plain JSON line, for servers that skip the `data:` prefix.
public final class AiStreamParser {
    private var data = ""
    private var dataLength = 0
    private var dataLines = 0

    /// Data lines of one event each tried as JSON as it arrives (servers without blank lines send a value per line). Past
    /// them the event is read at the blank line that ends it: reading it all again at each of a million lines takes hours.
    static let maxTriedDataLines = 64

    /// Most characters held for one event while its data lines are joined.
    public static let maxEventChars = 4 << 20

    /// True after `[DONE]`.
    public private(set) var done = false
    /// Why the model stopped ("stop", "length"…), once it says so.
    public private(set) var finishReason: String?
    /// True when any chunk was read (the stream wasn't empty).
    public private(set) var sawData = false

    public init() {}

    /// Feeds one line (without its line break); returns the answer text it adds, or "".
    /// - Throws: `AiError` when the stream carries an error, or a chunk that isn't JSON.
    public func line(_ line: String) throws -> String {
        if done { return "" }
        if line.isEmpty { return try flush(strict: true) }
        if line.utf8.first == UInt8(ascii: ":") { return "" } // comment / keep-alive
        let payload: String
        if line.hasPrefix("data:") {
            let after = line.dropFirst(5)
            payload = String(after.hasPrefix(" ") ? after.dropFirst() : after)
        } else if AiText.trimStart(line).hasPrefix("{") {
            payload = line
        } else {
            return "" // event:, id:, retry:
        }
        if AiText.trim(payload) == "[DONE]" {
            data = ""
            dataLength = 0
            dataLines = 0
            done = true
            return ""
        }
        let length = payload.utf16.count
        if dataLength + length > Self.maxEventChars {
            data = ""
            dataLength = 0
            dataLines = 0
            throw AiError("The endpoint sent a streamed chunk too large to be part of an answer.")
        }
        if !data.isEmpty {
            data += "\n"
            dataLength += 1
        }
        data += payload
        dataLength += length
        dataLines += 1
        return dataLines <= Self.maxTriedDataLines ? try flush(strict: false) : ""
    }

    /// Call at the end of the stream: reads what is left.
    public func end() throws -> String { try flush(strict: true) }

    private func flush(strict: Bool) throws -> String {
        if data.isEmpty { return "" }
        guard let value = AiProtocol.parse(data) else {
            if !strict { return "" } // more data lines may follow
            data = ""
            dataLength = 0
            dataLines = 0
            throw AiError("The endpoint sent an answer Inkvolt PDF can't read (not OpenAI-compatible streaming).")
        }
        data = ""
        dataLength = 0
        dataLines = 0
        sawData = true
        return try chunk(value)
    }

    private func chunk(_ value: Any) throws -> String {
        guard let root = value as? [String: Any] else { return "" }
        if root["error"] != nil, let error = AiProtocol.errorMessageOf(json: root) {
            throw AiError("The model stopped with an error: \"\(error)\"")
        }
        guard let choices = root["choices"] as? [Any] else { return "" }
        var text = ""
        for case let c as [String: Any] in choices {
            if let index = c["index"], AiProtocol.int32(index) != 0 { continue } // only the first choice
            if let d = c["delta"] as? [String: Any], let s = d["content"] as? String {
                text += s
            } else if let m = c["message"] as? [String: Any], let s = m["content"] as? String {
                text += s
            } else if let s = c["text"] as? String {
                text += s
            }
            if let f = c["finish_reason"] as? String { finishReason = f }
        }
        return text
    }

    /// The text and finish reason of a whole (not streamed) answer, for servers that ignore `"stream": true`.
    /// - Throws: `AiError` when it isn't a chat completion.
    public static func parseWhole(_ json: String) throws -> (text: String, finishReason: String?) {
        guard let value = AiProtocol.parse(json) else {
            throw AiError("The endpoint sent an answer Inkvolt PDF can't read (not JSON).")
        }
        let p = AiStreamParser()
        let text = try p.chunk(value)
        guard let root = value as? [String: Any], root["choices"] != nil else {
            throw AiError("The endpoint's answer isn't an OpenAI-compatible chat completion.")
        }
        return (text, p.finishReason)
    }
}
