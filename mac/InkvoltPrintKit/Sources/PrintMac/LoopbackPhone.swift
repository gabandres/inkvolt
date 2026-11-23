import Foundation
import PrintCore
import Security

/// A phone on this Mac (roadmap 4.6's checks: `--report … --phone` and PhoneServerTests): what the phone page's script does,
/// over URLSession to the scan's own address, trusting only the certificate whose fingerprint the Mac shows. Keeps the
/// session cookie itself (nothing goes to the shared cookie store) and sends the page's header unless told not to.
public final class LoopbackPhone: NSObject, URLSessionDelegate, @unchecked Sendable {
    public struct Answer: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data

        public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    private let fingerprint: String
    private let lock = NSLock()
    private var cookie: String?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(fingerprint: String) { self.fingerprint = fingerprint }

    public func get(_ url: String) async throws -> Answer { try await ask(url, method: "GET", body: nil, page: false, withCookie: true) }

    /// POST to the page's address plus `action` ("/pair", "/photo", "/done"); the cookie a reply sets is kept.
    public func post(_ url: String, body: [UInt8]? = nil, page: Bool = true, withCookie: Bool = true) async throws -> Answer {
        try await ask(url, method: "POST", body: body, page: page, withCookie: withCookie)
    }

    private func ask(_ url: String, method: String, body: [UInt8]?, page: Bool, withCookie: Bool) async throws -> Answer {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if let body {
            request.httpBody = Data(body)
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        }
        if page { request.setValue("1", forHTTPHeaderField: PhoneSession.pageHeader) }
        if withCookie, let cookie = lock.withLock({ cookie }) { request.setValue("\(PhoneSession.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        let answer = Answer(status: http.statusCode, headers: headers, body: data)
        if let set = answer.header("Set-Cookie"), set.hasPrefix(PhoneSession.cookieName + "=") {
            let value = set.dropFirst(PhoneSession.cookieName.count + 1).prefix { $0 != ";" }
            lock.withLock { cookie = String(value) }
        }
        return answer
    }

    public func finish() { session.invalidateAndCancel() }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              PhoneCertificateKeychain.fingerprint(Array(SecCertificateCopyData(leaf) as Data)) == fingerprint else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
