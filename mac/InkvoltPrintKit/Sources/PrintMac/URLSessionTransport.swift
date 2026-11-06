import CryptoKit
import Foundation
import PrintCore
import Security
import Synchronization

/// The network for one printer (`HttpTransportFactory`): URLSession with nothing kept between runs (no cookies, cache or
/// saved credentials), redirects returned rather than followed, and every TLS handshake checked against the printer's
/// certificate pins (`CertificateCheck`). A request sent `once` goes out on a session of its own, so it's never resent on a
/// pooled connection. Timeouts are `DeviceHttp`'s. Every reply is read as it arrives and given up on past the request's
/// `replyLimit` (as Windows' `DeviceHttp` bounds every reply: 32 MB, a scanned page 1 GB), so a printer that never stops
/// answering can't fill this Mac's memory; `replyLimit` here lowers that bound (the tests' quick one).
public final class URLSessionTransport: HttpTransport {
    private let check: CertificateCheck
    private let localNetwork: LocalNetworkSignal?
    private let replyLimit: Int?
    private let session: URLSession

    public init(check: CertificateCheck, localNetwork: LocalNetworkSignal? = nil, replyLimit: Int? = nil) {
        self.check = check
        self.localNetwork = localNetwork
        self.replyLimit = replyLimit
        session = Self.session(check)
    }

    deinit { session.invalidateAndCancel() }

    /// A transport factory for `PrinterRecipe` and `DeviceHttp`.
    public static func factory(localNetwork: LocalNetworkSignal?) -> HttpTransportFactory {
        { _, check in URLSessionTransport(check: check, localNetwork: localNetwork) }
    }

    private static func session(_ check: CertificateCheck) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 600 // DeviceHttp times each request; LEDM's event long poll waits minutes
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: Delegate(check), delegateQueue: nil)
    }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body.map { Data($0) }
        r.timeoutInterval = max(1, Double(request.timeout.components.seconds) + 1)
        let session = request.once ? Self.session(check) : self.session
        defer { if request.once { session.finishTasksAndInvalidate() } }
        do {
            let limit = replyLimit.map { min($0, request.replyLimit) } ?? request.replyLimit
            let reply = try await bounded(r, session, limit)
            localNetwork?.answered()
            return reply
        } catch let error as DeviceNetworkError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw map(error)
        }
    }

    /// An HTTP reply's status and headers; nil: not an HTTP reply.
    private static func head(_ response: URLResponse) -> (status: Int, headers: [String: String])? {
        guard let http = response as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return (http.statusCode, headers)
    }

    /// The most a reply's buffer is made ready for before its bytes arrive; past it the buffer grows as they come, so a length
    /// a printer claims (up to eSCL's 1 GB) costs only what it sends.
    static let maxReservation = 4 << 20

    /// What a reply whose Content-Length says `expected` reserves: that, at most `maxReservation`; nothing without one or past
    /// `limit` (refused at once).
    static func reservation(_ expected: Int64, limit: Int) -> Int {
        guard expected > 0, expected <= Int64(limit) else { return 0 }
        return Int(min(expected, Int64(maxReservation)))
    }

    /// The reply read in the pieces it arrives in (a task delegate counting `didReceive`), given up on (its task cancelled)
    /// past `limit` bytes, or at once when its length says so.
    private func bounded(_ r: URLRequest, _ session: URLSession, _ limit: Int) async throws -> HttpResponse {
        let reader = BoundedReader(limit: limit)
        let task = session.dataTask(with: r)
        task.delegate = reader // the session's delegate still answers redirects and certificates
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// One bounded reply's bytes as they arrive, and its end.
    private final class BoundedReader: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var status: Int?
            var headers: [String: String] = [:]
            var body: [UInt8] = []
            var tooLong = false
            var continuation: CheckedContinuation<HttpResponse, any Error>?
        }

        private let limit: Int
        private let state = Mutex(State())

        init(limit: Int) { self.limit = limit }

        func start(_ continuation: CheckedContinuation<HttpResponse, any Error>) { state.withLock { $0.continuation = continuation } }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let head = URLSessionTransport.head(response)
            let tooLong = response.expectedContentLength > Int64(limit)
            state.withLock {
                $0.status = head?.status
                $0.headers = head?.headers ?? [:]
                $0.tooLong = tooLong
                $0.body.reserveCapacity(URLSessionTransport.reservation(response.expectedContentLength, limit: limit))
            }
            completionHandler(tooLong ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = state.withLock { s -> Bool in
                guard s.body.count + data.count <= limit else {
                    s.tooLong = true
                    return true
                }
                s.body.append(contentsOf: data)
                return false
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let done = state.withLock { s -> State in
                let done = s
                s = State() // resumed once; the bytes go with it
                return done
            }
            guard let continuation = done.continuation else { return }
            if done.tooLong {
                continuation.resume(throwing: DeviceNetworkError.failed("The reply was longer than \(limit / (1 << 20)) MB"))
            } else if let error {
                continuation.resume(throwing: error)
            } else if let status = done.status {
                continuation.resume(returning: HttpResponse(status: status, headers: done.headers, body: done.body))
            } else {
                continuation.resume(throwing: DeviceNetworkError.failed("Not an HTTP reply"))
            }
        }
    }

    private func map(_ error: Error) -> DeviceNetworkError {
        if LocalNetworkSignal.isDenied(error) {
            localNetwork?.denied()
            return .failed(loc("Local Network access is off"))
        }
        guard let url = error as? URLError else { return .failed(error.localizedDescription) }
        switch url.code {
        case .timedOut: return .timedOut
        case .cannotConnectToHost:
            // Refused outright (nothing listens on the port), unless the stream says the host was unreachable or silent.
            let stream = (url as NSError).userInfo["_kCFStreamErrorCodeKey"] as? Int
            return stream == nil || stream == Int(ECONNREFUSED) ? .refused : .failed(url.localizedDescription)
        case .cancelled where check.certificateChanged: return .failed(loc("The printer's certificate changed"))
        default: return .failed(url.localizedDescription)
        }
    }

    /// Redirects are returned, not followed; server trust is the printer's pin; HTTP authentication challenges get the
    /// response (the admin password goes out as a header, only where `DeviceHttp` puts it).
    private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        private let check: CertificateCheck

        init(_ check: CertificateCheck) { self.check = check }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                return (.cancelAuthenticationChallenge, nil)
            }
            let der = SecCertificateCopyData(leaf) as Data
            let thumb = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
            return check.accept(sha256Hex: thumb, port: space.port) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
    }
}
