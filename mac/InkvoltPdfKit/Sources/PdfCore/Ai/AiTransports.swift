import Darwin
import Foundation
import Network
import Security

/// Bytes that arrive on one queue and are read in order by one reader: what the transports hand the client as a body.
final class AiByteQueue: AiBody, @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [[UInt8]] = []
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<[UInt8]?, Error>?
    private let onClose: @Sendable () -> Void

    init(onClose: @escaping @Sendable () -> Void = {}) { self.onClose = onClose }

    func yield(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: bytes)
            return
        }
        pieces.append(bytes)
        lock.unlock()
    }

    /// The end of the body: at once, or with an error once the pieces before it were read.
    func finish(_ error: Error? = nil) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        failure = error
        let w = waiter
        waiter = nil
        lock.unlock()
        if let w {
            if let error { w.resume(throwing: error) } else { w.resume(returning: nil) }
        }
    }

    func read(_ cancel: CancelToken) async throws -> [UInt8]? {
        let id = cancel.register { [weak self] in self?.finish(CancellationError()) }
        defer { cancel.unregister(id) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8]?, Error>) in
            lock.lock()
            if !pieces.isEmpty {
                let first = pieces.removeFirst()
                lock.unlock()
                c.resume(returning: first)
            } else if finished {
                let f = failure
                lock.unlock()
                if let f { c.resume(throwing: f) } else { c.resume(returning: nil) }
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func close() {
        finish(CancellationError())
        onClose()
    }
}

/// HTTP/1.1 responses for `AiSocketTransport`, read from what the socket delivers: the head, then a body with a length,
/// chunked, or until the connection closes. A connection that ends before the body does is `AiNetError.closedEarly`.
struct AiHttpReader {
    struct Head: Equatable {
        let status: Int
        let headers: [String: String]
    }

    enum Framing: Equatable {
        case length(Int), chunked, untilClose
    }

    private static let maxHeadBytes = 64 * 1024
    private var pending: [UInt8] = []
    private var framing: Framing?
    private var left = 0
    /// Chunked: true while the next thing is a chunk's size line; false inside its data and its line break.
    private var atSizeLine = true
    private var inTrailers = false
    private(set) var bodyDone = false

    /// Feeds bytes while waiting for the head; returns it when complete (1xx responses skipped). What came after it stays
    /// for `body`.
    mutating func head(_ bytes: [UInt8]) throws -> Head? {
        pending += bytes
        while let end = Self.find(pending, [13, 10, 13, 10]) {
            let text = String(decoding: pending[..<end], as: UTF8.self)
            let parsed = try Self.parseHead(text)
            pending.removeFirst(end + 4)
            if (100..<200).contains(parsed.status) { continue }
            framing = Self.framing(parsed)
            if case .length(let n)? = framing {
                left = n
                if n == 0 { bodyDone = true }
            }
            if parsed.status == 204 || parsed.status == 304 { bodyDone = true }
            return parsed
        }
        if pending.count > Self.maxHeadBytes { throw AiNetError.other("the server's headers are too long") }
        return nil
    }

    /// Feeds body bytes (empty for what `head` left over); returns the body's bytes they hold.
    mutating func body(_ bytes: [UInt8]) throws -> [UInt8] {
        pending += bytes
        switch framing {
        case .length?:
            let n = min(left, pending.count)
            let out = Array(pending[..<n])
            pending.removeFirst(n)
            left -= n
            if left == 0 { bodyDone = true }
            return out
        case .chunked?:
            return try chunked()
        default:
            defer { pending.removeAll() }
            return pending
        }
    }

    /// The connection ended: fine when the body is whole or runs until the close.
    mutating func connectionEnded() throws {
        if bodyDone { return }
        if case .untilClose? = framing {
            bodyDone = true
            return
        }
        throw AiNetError.closedEarly
    }

    private mutating func chunked() throws -> [UInt8] {
        var out: [UInt8] = []
        while !bodyDone {
            if inTrailers {
                guard let end = Self.find(pending, [13, 10]) else { break }
                let isEnd = end == 0
                pending.removeFirst(end + 2)
                if isEnd { bodyDone = true }
            } else if atSizeLine {
                guard let end = Self.find(pending, [13, 10]) else {
                    if pending.count > 1024 { throw AiNetError.other("the server's chunk size is unreadable") }
                    break
                }
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeFirst(end + 2)
                let size = line.split(separator: ";", omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let n = Int(size, radix: 16), n >= 0 else { throw AiNetError.other("the server's chunk size is unreadable") }
                if n == 0 {
                    inTrailers = true
                } else {
                    left = n
                    atSizeLine = false
                }
            } else if left > 0 {
                if pending.isEmpty { break }
                let n = min(left, pending.count)
                out += pending[..<n]
                pending.removeFirst(n)
                left -= n
            } else {
                guard pending.count >= 2 else { break }
                pending.removeFirst(2)
                atSizeLine = true
            }
        }
        return out
    }

    private static func framing(_ head: Head) -> Framing {
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .chunked }
        if let text = head.headers["content-length"], let n = Int(text), n >= 0 { return .length(n) }
        return .untilClose
    }

    private static func parseHead(_ text: String) throws -> Head {
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw AiNetError.other("the server didn't answer in HTTP")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Repeated headers: the first Content-Length stands, others are joined as HTTP says.
            if let old = headers[name], name != "content-length" {
                headers[name] = old + ", " + value
            } else if headers[name] == nil {
                headers[name] = value
            }
        }
        if let encoding = headers["content-encoding"]?.lowercased(), encoding != "identity" {
            throw AiNetError.other("the server sent a compressed answer it wasn't asked for")
        }
        return Head(status: status, headers: headers)
    }

    private static func find(_ data: [UInt8], _ needle: [UInt8]) -> Int? {
        guard data.count >= needle.count else { return nil }
        for i in 0...(data.count - needle.count) where data[i] == needle[0] {
            if (1..<needle.count).allSatisfy({ data[i + $0] == needle[$0] }) { return i }
        }
        return nil
    }
}

/// Requests to this Mac or the network, over Network.framework, because URLSession can't be told which address to use:
/// the host is resolved here, every address is checked against `AiEndpoint.allows`, and only a checked address is
/// connected to (several at once, the first that answers: "localhost" may be ::1 and 127.0.0.1). No proxy, redirects or
/// cookies; plain HTTP/1.1, one request per connection. App Transport Security doesn't apply here, so the app needs no
/// exception for http:// to these servers.
final class AiSocketTransport: AiTransport {
    let usesProxy = false
    let followsRedirects = false
    let usesCookies = false
    private let endpoint: AiEndpoint
    private let timeouts: AiTimeouts
    private let resolve: @Sendable (String) async throws -> [AiAddress]

    init(_ endpoint: AiEndpoint, _ timeouts: AiTimeouts, resolve: @escaping @Sendable (String) async throws -> [AiAddress]) {
        self.endpoint = endpoint
        self.timeouts = timeouts
        self.resolve = resolve
    }

    /// The name resolved, or `CancellationError` as soon as `cancel` fires (`getaddrinfo` itself can't be stopped).
    private func resolveStopping(_ host: String, _ cancel: CancelToken) async throws -> [AiAddress] {
        let once = AiOnce<[AiAddress]>()
        let id = cancel.register { once.resume(with: .failure(CancellationError())) }
        defer { cancel.unregister(id) }
        let resolve = self.resolve
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[AiAddress], Error>) in
            once.begin(c)
            Task {
                do {
                    once.resume(with: .success(try await resolve(host)))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
        }
    }

    /// The system's name resolution, off the main thread (`getaddrinfo` blocks).
    @Sendable static func systemResolve(_ host: String) async throws -> [AiAddress] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[AiAddress], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &list)
                defer { if let list { freeaddrinfo(list) } }
                guard status == 0 else { return c.resume(throwing: AiNetError.hostNotFound) }
                var found: [AiAddress] = []
                var at = list
                while let info = at {
                    if let address = Self.address(info.pointee), !found.contains(address) { found.append(address) }
                    at = info.pointee.ai_next
                }
                c.resume(returning: found)
            }
        }
    }

    private static func address(_ info: addrinfo) -> AiAddress? {
        guard let sa = info.ai_addr else { return nil }
        switch info.ai_family {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var a = p.pointee.sin_addr
                return AiAddress(bytes: withUnsafeBytes(of: &a) { Array($0) })
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var a = p.pointee.sin6_addr
                return AiAddress(bytes: withUnsafeBytes(of: &a) { Array($0) })
            }
        default:
            return nil
        }
    }

    func send(_ request: AiHttpRequest, _ cancel: CancelToken) async throws -> AiHttpResponse {
        try cancel.check()
        let host = endpoint.hostName.hasPrefix("[") ? String(endpoint.hostName.dropFirst().dropLast()) : endpoint.hostName
        var resolved: [AiAddress]
        if let literal = AiAddress(host) {
            resolved = [literal]
        } else {
            resolved = try await resolveStopping(host, cancel)
        }
        try cancel.check()
        let allowed = resolved.filter(endpoint.allows)
        if allowed.isEmpty {
            let place = endpoint.reach == .thisMac ? "this Mac" : "your network"
            throw AiAddressError(resolved.isEmpty
                ? "Couldn't find \(host). Check the address, and that this Mac is online."
                : "\(host) leads to \(resolved[0]), outside \(place), so nothing was sent. If the endpoint is on the internet, enter its public https:// address.")
        }
        let secure = endpoint.scheme == "https"
        let connection = try await connectFirst(allowed, port: endpoint.port ?? (secure ? 443 : 80), tlsName: secure ? host : nil, cancel)
        do {
            return try await exchange(request, connection, cancel)
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: Connecting

    /// Connects to all the addresses at once and keeps the first that answers ("happy eyeballs").
    private func connectFirst(_ addresses: [AiAddress], port: Int, tlsName: String?, _ cancel: CancelToken) async throws -> NWConnection {
        let race = ConnectRace()
        let connections = addresses.map { connection($0, port: port, tlsName: tlsName) }
        let id = cancel.register { race.finish(.failure(CancellationError())) }
        defer { cancel.unregister(id) }
        let queue = DispatchQueue(label: "inkvolt.ai.connect")
        let timer = DispatchWorkItem { race.finish(.failure(AiNetError.timedOut)) }
        queue.asyncAfter(deadline: .now() + timeouts.connect, execute: timer)
        defer { timer.cancel() }
        let count = connections.count
        let winner: NWConnection
        do {
            winner = try await withCheckedThrowingContinuation { (c: CheckedContinuation<NWConnection, Error>) in
                race.begin(c, attempts: count)
                for connection in connections {
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            race.ready(connection)
                        case .waiting(let error), .failed(let error):
                            // Waiting means retrying later (macOS waits on a refused port): one answer is enough here.
                            race.failed(Self.meaning(error))
                            connection.cancel()
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
        } catch {
            for connection in connections { connection.cancel() }
            throw error
        }
        for connection in connections where connection !== winner { connection.cancel() }
        winner.stateUpdateHandler = nil // from here on, a failure comes out of the read or write it stops
        return winner
    }

    /// One attempt's parameters: TCP without delay, no proxy, and with https the name checked against the certificate.
    private func connection(_ address: AiAddress, port: Int, tlsName: String?) -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeouts.connect.rounded(.up)))
        let parameters: NWParameters
        if let tlsName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsName)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
                let ref = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(ref, SecPolicyCreateSSL(true, tlsName as CFString))
                done(SecTrustEvaluateWithError(ref, nil))
            }, DispatchQueue.global(qos: .userInitiated))
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.preferNoProxies = true
        let host: NWEndpoint.Host = address.isIPv4
            ? .ipv4(IPv4Address(Data(address.bytes))!)
            : .ipv6(IPv6Address(Data(address.bytes))!)
        return NWConnection(host: host, port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .http, using: parameters)
    }

    /// What a Network.framework error means for the user.
    static func meaning(_ error: NWError) -> AiNetError {
        switch error {
        case .tls:
            return .secureConnection
        case .dns:
            return .hostNotFound
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .ETIMEDOUT: return .timedOut
            case .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN, .ESHUTDOWN: return .closedEarly
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EPERM, .EACCES: return .unreachable
            default: return .other(String(cString: strerror(code.rawValue)))
            }
        default:
            return .other("\(error)")
        }
    }

    // MARK: The exchange

    private func exchange(_ request: AiHttpRequest, _ connection: NWConnection, _ cancel: CancelToken) async throws -> AiHttpResponse {
        let id = cancel.register { connection.cancel() }
        defer { cancel.unregister(id) }
        try await write(head(request) + (request.body ?? []), connection, cancel)
        var reader = AiHttpReader()
        var parsed: AiHttpReader.Head?
        while parsed == nil {
            let (bytes, ended) = try await receive(connection, cancel)
            parsed = try reader.head(bytes)
            if parsed == nil && ended { throw AiNetError.closedEarly }
        }
        let body = AiByteQueue(onClose: { connection.cancel() })
        let first = try reader.body([])
        body.yield(first)
        if reader.bodyDone {
            body.finish()
        } else {
            Self.pump(connection, reader, body)
        }
        let answer = parsed!
        return AiHttpResponse(status: answer.status, contentType: answer.headers["content-type"], location: answer.headers["location"], body: body)
    }

    /// The request's first lines. No User-Agent, cookies or anything else about the Mac or the user.
    private func head(_ request: AiHttpRequest) -> [UInt8] {
        // Only this endpoint's own URLs come here, so the path is everything after its origin.
        let path = String(request.url.dropFirst(endpoint.origin.count))
        var text = "\(request.method) \(path.isEmpty ? "/" : path) HTTP/1.1\r\nHost: \(endpoint.host)\r\n"
        for h in request.headers { text += "\(h.name): \(h.value)\r\n" }
        if let body = request.body { text += "Content-Length: \(body.count)\r\n" }
        text += "Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
        return Array(text.utf8)
    }

    private func write(_ bytes: [UInt8], _ connection: NWConnection, _ cancel: CancelToken) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if cancel.isCancelled {
                    c.resume(throwing: CancellationError())
                } else if let error {
                    c.resume(throwing: Self.meaning(error))
                } else {
                    c.resume()
                }
            })
        }
    }

    private func receive(_ connection: NWConnection, _ cancel: CancelToken) async throws -> (bytes: [UInt8], ended: Bool) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<(bytes: [UInt8], ended: Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if cancel.isCancelled {
                    c.resume(throwing: CancellationError())
                } else if let error {
                    c.resume(throwing: Self.meaning(error))
                } else {
                    c.resume(returning: (data.map { [UInt8]($0) } ?? [], complete))
                }
            }
        }
    }

    /// Moves the body from the connection into the queue, until it ends.
    private static func pump(_ connection: NWConnection, _ reader: AiHttpReader, _ body: AiByteQueue) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var reader = reader
            do {
                if let error { throw Self.meaning(error) }
                if let data, !data.isEmpty { body.yield(try reader.body([UInt8](data))) }
                if complete { try reader.connectionEnded() }
                if reader.bodyDone || complete {
                    body.finish()
                    connection.cancel()
                    return
                }
                Self.pump(connection, reader, body)
            } catch {
                body.finish(error)
                connection.cancel()
            }
        }
    }
}

/// A continuation resumed once, whichever of several things happens first.
final class AiOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?

    func begin(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            c.resume(with: outcome)
            return
        }
        waiter = c
        lock.unlock()
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return
        }
        outcome = result
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: result)
    }
}

/// The first of several connection attempts to answer, or the first failure once all have failed.
private final class ConnectRace: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<NWConnection, Error>?
    private var outcome: Result<NWConnection, Error>?
    private var left = 0
    private var firstFailure: AiNetError?

    func begin(_ c: CheckedContinuation<NWConnection, Error>, attempts: Int) {
        lock.lock()
        left = attempts
        if let outcome {
            lock.unlock()
            c.resume(with: outcome)
            return
        }
        waiter = c
        lock.unlock()
    }

    func ready(_ connection: NWConnection) { finish(.success(connection)) }

    func failed(_ error: AiNetError) {
        lock.lock()
        if firstFailure == nil { firstFailure = error }
        left -= 1
        let last = left <= 0
        let failure = firstFailure ?? error
        lock.unlock()
        if last { finish(.failure(failure)) }
    }

    func finish(_ result: Result<NWConnection, Error>) {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return
        }
        outcome = result
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: result)
    }
}

/// Requests to the internet: URLSession, with the Mac's proxy setting, no cookies, cache or kept credentials, and no
/// redirects (a 3xx comes back as it is and the client refuses it). https only: `AiEndpoint.tryParse` refuses http:// to
/// the internet, so App Transport Security's defaults hold.
final class AiUrlSessionTransport: AiTransport {
    let usesProxy = true
    let followsRedirects = false
    let usesCookies = false

    func send(_ request: AiHttpRequest, _ cancel: CancelToken) async throws -> AiHttpResponse {
        try cancel.check()
        guard let url = URL(string: request.url) else { throw AiNetError.other("the address can't be read") }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.map { Data($0) }
        urlRequest.httpShouldHandleCookies = false
        for h in request.headers { urlRequest.setValue(h.value, forHTTPHeaderField: h.name) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        // The client keeps the time (first byte, idle): only the system's own limits are out of the way here.
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let delegate = AiSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        let id = cancel.register { task.cancel() }
        defer { cancel.unregister(id) }
        let body = AiByteQueue(onClose: {
            task.cancel()
            session.invalidateAndCancel()
        })
        do {
            let response = try await delegate.start(task, body: body)
            return AiHttpResponse(status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"),
                                  location: response.value(forHTTPHeaderField: "Location"), body: body)
        } catch {
            body.close()
            if cancel.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

private final class AiSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var body: AiByteQueue?

    func start(_ task: URLSessionDataTask, body: AiByteQueue) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
            lock.withLock {
                waiter = c
                self.body = body
            }
            task.resume()
        }
    }

    private func takeWaiter() -> CheckedContinuation<HTTPURLResponse, Error>? {
        lock.withLock {
            let w = waiter
            waiter = nil
            return w
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        if let http = response as? HTTPURLResponse {
            takeWaiter()?.resume(returning: http)
        } else {
            takeWaiter()?.resume(throwing: AiNetError.other("the server didn't answer in HTTP"))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { body }?.yield([UInt8](data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let meaning = error.map { Self.meaning($0) }
        let queue = lock.withLock { body }
        if let meaning {
            takeWaiter()?.resume(throwing: meaning)
            queue?.finish(meaning)
        } else {
            // A redirect declined completes here with its response delivered first.
            if let http = task.response as? HTTPURLResponse { takeWaiter()?.resume(returning: http) }
            queue?.finish()
        }
        session.finishTasksAndInvalidate()
    }

    private static func meaning(_ error: Error) -> Error {
        guard let url = error as? URLError else { return AiNetError.other(error.localizedDescription) }
        switch url.code {
        case .cancelled: return CancellationError()
        case .cannotConnectToHost: return AiNetError.refused
        case .timedOut: return AiNetError.timedOut
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet: return AiNetError.hostNotFound
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return AiNetError.secureConnection
        case .networkConnectionLost: return AiNetError.closedEarly
        default: return AiNetError.other(url.localizedDescription)
        }
    }
}

/// A tiny OpenAI-compatible HTTP server on loopback, for the tests and the app's self-test, so they exercise the real
/// connection without any AI service: it binds 127.0.0.1 only, and each connection gets one scripted answer.
public final class AiLoopbackServer: @unchecked Sendable {
    /// What was asked: the request line, headers and body as received.
    public struct Received: Sendable {
        public let head: String
        public let body: String
        public var requestLine: String { head.components(separatedBy: "\r\n").first ?? "" }
    }

    /// One answer: raw bytes written in pieces, with an optional pause between them, then the connection closed
    /// (`holdOpen`: kept open until `stop`).
    public struct Answer: Sendable {
        public var pieces: [[UInt8]]
        public var pause: Double
        public var holdOpen: Bool

        public init(pieces: [[UInt8]], pause: Double = 0, holdOpen: Bool = false) {
            self.pieces = pieces
            self.pause = pause
            self.holdOpen = holdOpen
        }

        public static func raw(_ text: String) -> Answer { Answer(pieces: [Array(text.utf8)]) }

        /// A JSON answer with its length.
        public static func json(_ status: Int, _ body: String) -> Answer {
            raw("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        }

        /// A streamed answer, each piece a server-sent event in a chunk of its own, then [DONE].
        public static func sse(_ texts: [String], pause: Double = 0, finish: String = "stop") -> Answer {
            func chunk(_ s: String) -> [UInt8] { Array("\(String(s.utf8.count, radix: 16))\r\n\(s)\r\n".utf8) }
            var pieces: [[UInt8]] = [Array("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)]
            for t in texts { pieces.append(chunk("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\(AiProtocol.quote(t))}}]}\n\n")) }
            pieces.append(chunk("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\ndata: [DONE]\n\n"))
            pieces.append(Array("0\r\n\r\n".utf8))
            return Answer(pieces: pieces, pause: pause)
        }
    }

    public let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var requests: [Received] = []
    private var open: [Int32] = []
    private var stopped = false
    private let answersAtOnce: Bool
    private let answer: @Sendable (Received) -> Answer

    /// - Parameter answersAtOnce: answer on connecting, without waiting for a request (what a plain server does to a TLS
    ///   greeting it can't read).
    public init?(answersAtOnce: Bool = false, answer: @escaping @Sendable (Received) -> Answer) {
        self.answersAtOnce = answersAtOnce
        self.answer = answer
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return nil
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else {
            Darwin.close(fd)
            return nil
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        listener = fd
        DispatchQueue.global(qos: .userInitiated).async { [self] in acceptLoop() }
    }

    public var received: [Received] { lock.withLock { requests } }

    /// Stops listening and ends the connections. Each socket is closed by the thread using it, so its number can't be
    /// reused under that thread (these run beside real connections in the same process).
    public func stop() {
        let sockets: [Int32] = lock.withLock {
            stopped = true
            return open
        }
        for s in sockets { shutdown(s, SHUT_RDWR) }
    }

    private func acceptLoop() {
        var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !lock.withLock({ stopped }) {
            if poll(&waiting, 1, 50) <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            let keep: Bool = lock.withLock {
                if stopped { return false }
                open.append(client)
                return true
            }
            guard keep else {
                Darwin.close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
        Darwin.close(listener)
    }

    private func finish(_ client: Int32) {
        lock.withLock { open.removeAll { $0 == client } }
        Darwin.close(client)
    }

    private func serve(_ client: Int32) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data: [UInt8] = []
        let size = 65536
        var buffer = [UInt8](repeating: 0, count: size)
        var headEnd: Int?
        var wanted = 0
        while !answersAtOnce && (headEnd == nil || data.count < headEnd! + 4 + wanted) {
            let n = recv(client, &buffer, size, 0)
            if n <= 0 { break }
            data += buffer[0..<n]
            if headEnd == nil, let end = Self.headEnd(data) {
                headEnd = end
                let head = String(decoding: data[..<end], as: UTF8.self).lowercased()
                if let line = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
                    wanted = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }
        let end = headEnd ?? data.count
        let received = Received(head: String(decoding: data[..<end], as: UTF8.self), body: String(decoding: data[min(end + 4, data.count)...], as: UTF8.self))
        lock.withLock { requests.append(received) }
        let reply = answer(received)
        for (i, piece) in reply.pieces.enumerated() {
            if i > 0 && reply.pause > 0 { Thread.sleep(forTimeInterval: reply.pause) }
            var at = 0
            while at < piece.count {
                let n = piece[at...].withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                at += n
            }
        }
        if reply.holdOpen { // until the other side closes, or stop()
            while recv(client, &buffer, size, 0) > 0 {}
        }
        finish(client)
    }

    private static func headEnd(_ data: [UInt8]) -> Int? {
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) where data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10 { return i }
        return nil
    }
}
