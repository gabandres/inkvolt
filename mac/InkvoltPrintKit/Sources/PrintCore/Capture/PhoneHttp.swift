import Foundation

/// One TLS connection's bytes, as `PhoneHttp` reads and writes them (PrintMac: a Network framework connection; tests: a
/// fake). `receive`: up to `max` bytes, nil once it's closed, broken, or nothing came within `timeout`.
public protocol PhoneConnectionIO: Sendable {
    func receive(max: Int, timeout: Duration) async -> [UInt8]?
    func send(_ bytes: [UInt8]) async -> Bool
}

/// A request's head as read off the wire, before anything is answered.
public struct PhoneHttpHead: Equatable, Sendable {
    public var method: String
    public var path: String
    public var version: String
    /// Names lowercased; a name given twice keeps both values, in order.
    public var headers: [(name: String, value: String)]

    public static func == (a: PhoneHttpHead, b: PhoneHttpHead) -> Bool {
        a.method == b.method && a.path == b.path && a.version == b.version && a.headers.map(\.name) == b.headers.map(\.name)
            && a.headers.map(\.value) == b.headers.map(\.value)
    }

    public func values(_ name: String) -> [String] { headers.filter { $0.name == name }.map(\.value) }

    /// The value of the cookie `name` among the Cookie headers' pairs.
    public func cookie(_ name: String) -> String? {
        for header in values("cookie") {
            for pair in header.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == name { return kv[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}

/// The phone page's HTTP/1.1 (roadmap 4.6; what Kestrel does for Windows' `KestrelPhoneHost`), over one connection whose
/// TLS PrintMac's server has done: every request read as hostile input (a request line of at most `maxRequestLine` bytes,
/// at most `maxHeaders` headers in `maxHead` bytes, read within `headTimeout`; an absolute or odd target, a folded or
/// nameless header, two lengths, any transfer coding refused before the session sees it), handed to the `PhoneSession`
/// with its body read only when the session asks, at most what it allows (a declared length past that refused before a
/// byte is read), each part within `bodyTimeout`. Answers carry Windows' headers (no-store, nosniff, DENY, no-referrer, the
/// page's CSP). A body not read, a 413, a request that says close, or HTTP/1.0 closes the connection after the answer;
/// otherwise it's kept for the next request up to `idleTimeout`.
public enum PhoneHttp {
    public static let maxRequestLine = 2 * 1024, maxHead = 16 * 1024, maxHeaders = 40
    public static let headTimeout: Duration = .seconds(15), idleTimeout: Duration = .seconds(60), bodyTimeout: Duration = .seconds(10)
    static let chunk = 64 * 1024

    /// What a head said is wrong, as the status it's answered with.
    public struct Refusal: Error, Equatable {
        public let status: Int
    }

    /// Serves requests on `io` from `peer` until the connection closes, an answer closes it, or the task is cancelled (the
    /// server closed).
    public static func serve(_ io: any PhoneConnectionIO, peer: String, session: PhoneSession) async {
        var buffer: [UInt8] = []
        while !Task.isCancelled {
            let head: PhoneHttpHead
            switch await readHead(io, &buffer, timeout: buffer.isEmpty ? idleTimeout : headTimeout) {
            case .closed: return
            case .refused(let status):
                _ = await io.send(response(PhoneReply.empty(status), head: nil, close: true))
                return
            case .head(let h): head = h
            }
            let declared: Int
            do {
                declared = try length(head)
            } catch let r as Refusal {
                _ = await io.send(response(PhoneReply.empty(r.status), head: head, close: true))
                return
            } catch {
                return
            }
            var bodyRead = false
            var broken = false
            let request = PhoneRequest(head.method, head.path, peer: peer, cookie: head.cookie(PhoneSession.cookieName),
                                       fromPage: head.values(PhoneSession.pageHeader.lowercased()).first?.trimmingCharacters(in: .whitespaces) == "1")
            let reply = await session.handle(request) { max in
                bodyRead = true
                guard declared <= max else { return nil }
                let body = await readBody(io, &buffer, declared)
                if body == nil { broken = true }
                return body
            }
            if broken { return }
            let wantsClose = head.version == "HTTP/1.0" || head.values("connection").contains { $0.lowercased().contains("close") }
            let close = (!bodyRead && declared > 0) || reply.status == 413 || wantsClose
            guard await io.send(response(reply, head: head, close: close)), !close else { return }
        }
    }

    enum HeadRead { case head(PhoneHttpHead), refused(Int), closed }

    /// The next request's head (what follows it stays in `buffer`).
    static func readHead(_ io: any PhoneConnectionIO, _ buffer: inout [UInt8], timeout: Duration) async -> HeadRead {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let end = headEnd(buffer) {
                let bytes = Array(buffer[..<end])
                buffer.removeFirst(end + 4)
                do {
                    return .head(try parse(bytes))
                } catch let r as Refusal {
                    return .refused(r.status)
                } catch {
                    return .refused(400)
                }
            }
            if buffer.count > maxHead { return .refused(431) }
            if !buffer.isEmpty, firstLineTooLong(buffer) { return .refused(414) }
            let left = deadline - ContinuousClock.now
            guard left > .zero, let more = await io.receive(max: maxHead + 4 - buffer.count, timeout: left), !more.isEmpty else {
                return buffer.isEmpty ? .closed : .refused(408)
            }
            buffer += more
        }
    }

    private static func headEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return i }
        return nil
    }

    private static func firstLineTooLong(_ b: [UInt8]) -> Bool {
        let line = b.firstIndex(of: 10) ?? b.count
        return line > maxRequestLine
    }

    /// A head's bytes (without the blank line) as a request; `Refusal` with the status for anything that isn't one.
    public static func parse(_ bytes: [UInt8]) throws -> PhoneHttpHead {
        // Only printable ASCII, tabs and CR LF: no NUL, no bare CR, no bytes past ASCII.
        for (i, b) in bytes.enumerated() {
            let ok = (b >= 0x20 && b < 0x7F) || b == 9 || (b == 13 && i + 1 < bytes.count && bytes[i + 1] == 10) || (b == 10 && i > 0 && bytes[i - 1] == 13)
            if !ok { throw Refusal(status: 400) }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.utf8.count <= maxRequestLine else { throw Refusal(status: 414) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Refusal(status: 400) }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard !method.isEmpty, method.count <= 16, method.allSatisfy({ $0.isASCII && $0.isUppercase }) else { throw Refusal(status: 400) }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw Refusal(status: 505) }
        // Origin form only ("/p/…"): no absolute URL, no "*", no fragment, no backslash.
        guard target.hasPrefix("/"), !target.contains("#"), !target.contains("\\"), !target.contains("\t") else { throw Refusal(status: 400) }
        let path = String(target.prefix { $0 != "?" })
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty else { throw Refusal(status: 400) }
            if line.first == " " || line.first == "\t" { throw Refusal(status: 400) } // obsolete line folding
            guard let colon = line.firstIndex(of: ":") else { throw Refusal(status: 400) }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.allSatisfy(isTokenCharacter) else { throw Refusal(status: 400) }
            headers.append((name.lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))))
            if headers.count > maxHeaders { throw Refusal(status: 431) }
        }
        return PhoneHttpHead(method: method, path: path, version: version, headers: headers)
    }

    private static func isTokenCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        if (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { return true }
        return "!#$%&'*+-.^_`|~".contains(c)
    }

    /// The body's length: its Content-Length (digits only, one value), 0 without one. A transfer coding is refused (the
    /// page's `fetch` of a photo always says its length).
    static func length(_ head: PhoneHttpHead) throws -> Int {
        if !head.values("transfer-encoding").isEmpty { throw Refusal(status: 411) }
        let lengths = Set(head.values("content-length").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        guard let only = lengths.first else { return 0 }
        guard lengths.count == 1, !only.isEmpty, only.count <= 10, only.allSatisfy(\.isASCIIDigit), let n = Int(only) else {
            throw Refusal(status: 400)
        }
        return n
    }

    /// Exactly `count` bytes of body, from what's buffered and then the connection; nil when it closed or stalled.
    static func readBody(_ io: any PhoneConnectionIO, _ buffer: inout [UInt8], _ count: Int) async -> [UInt8]? {
        var body: [UInt8] = []
        body.reserveCapacity(min(count, 4 * 1024 * 1024))
        let now = min(count, buffer.count)
        body += buffer[..<now]
        buffer.removeFirst(now)
        while body.count < count {
            guard let more = await io.receive(max: min(chunk, count - body.count), timeout: bodyTimeout), !more.isEmpty else { return nil }
            body += more
        }
        return body
    }

    /// The answer's bytes: status line, Windows' headers, the body (none for HEAD).
    public static func response(_ reply: PhoneReply, head: PhoneHttpHead?, close: Bool) -> [UInt8] {
        let isHead = head?.method == "HEAD"
        var lines = ["HTTP/1.1 \(reply.status) \(reason(reply.status))", "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
                     "X-Frame-Options: DENY", "Referrer-Policy: no-referrer"]
        if let csp = reply.contentSecurityPolicy { lines.append("Content-Security-Policy: \(csp)") }
        if let cookie = reply.setCookie { lines.append("Set-Cookie: \(cookie)") }
        if let seconds = reply.retryAfterSeconds { lines.append("Retry-After: \(seconds)") }
        let body = isHead ? [] : reply.body ?? []
        if let type = reply.contentType, !body.isEmpty { lines.append("Content-Type: \(type)") }
        lines.append("Content-Length: \(body.count)")
        if close { lines.append("Connection: close") }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 410: "Gone"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 505: "HTTP Version Not Supported"
        default: "Error"
        }
    }
}
