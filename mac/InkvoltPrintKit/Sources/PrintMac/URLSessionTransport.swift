import CryptoKit
import Foundation
import PrintCore
import Security

/// The network for one printer (`HttpTransportFactory`): URLSession with nothing kept between runs (no cookies, cache or
/// saved credentials), redirects returned rather than followed, and every TLS handshake checked against the printer's
/// certificate pins (`CertificateCheck`). A request sent `once` goes out on a session of its own, so it's never resent on a
/// pooled connection. Timeouts are `DeviceHttp`'s.
public final class URLSessionTransport: HttpTransport {
    private let check: CertificateCheck
    private let localNetwork: LocalNetworkSignal?
    private let session: URLSession

    public init(check: CertificateCheck, localNetwork: LocalNetworkSignal? = nil) {
        self.check = check
        self.localNetwork = localNetwork
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
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw DeviceNetworkError.failed("Not an HTTP reply") }
            localNetwork?.answered()
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HttpResponse(status: http.statusCode, headers: headers, body: Array(data))
        } catch let error as DeviceNetworkError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw map(error)
        }
    }

    private func map(_ error: Error) -> DeviceNetworkError {
        if LocalNetworkSignal.isDenied(error) {
            localNetwork?.denied()
            return .failed("Local Network access is off")
        }
        guard let url = error as? URLError else { return .failed(error.localizedDescription) }
        switch url.code {
        case .timedOut: return .timedOut
        case .cannotConnectToHost:
            // Refused outright (nothing listens on the port), unless the stream says the host was unreachable or silent.
            let stream = (url as NSError).userInfo["_kCFStreamErrorCodeKey"] as? Int
            return stream == nil || stream == Int(ECONNREFUSED) ? .refused : .failed(url.localizedDescription)
        case .cancelled where check.certificateChanged: return .failed("The printer's certificate changed")
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
