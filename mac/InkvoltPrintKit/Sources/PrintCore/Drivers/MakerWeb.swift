import Foundation

/// Why a read of a maker's page was refused or failed (the Windows app's `FetchProblem`).
public enum FetchProblem: Sendable, Equatable {
    /// Not https, or a host not on the maker's list (a redirect to one included).
    case notMakersSite
    case tooManyRedirects
    case tooBig
    case timedOut
    /// No answer, or an error status.
    case unreachable
}

public struct FetchError: Error, Equatable {
    public let problem: FetchProblem
    public init(_ problem: FetchProblem) { self.problem = problem }
}

/// Reads a page from a maker's own site, everything it gets treated as hostile (the Windows app's `BoundedHttp`, its page
/// half: the Mac never downloads a file): https only, to hosts on the maker's list only (each redirect checked the same way,
/// at most 5), bounded in size (the transport gives up past it as the bytes come) and in time. Nothing is sent but the request
/// for the address (and for HP's driver list, the JSON naming the model and the macOS asked about): no cookies, no
/// identifiers. The transport never follows a redirect itself (PrintMac's URLSession transport with the system's trust).
public struct MakerWeb: Sendable {
    let transport: any HttpTransport

    public init(_ transport: any HttpTransport) { self.transport = transport }

    static let maxRedirects = 5

    /// The host is the maker's: https, a name on the list exactly (no user info, no other port).
    public static func isAllowed(_ url: URL, _ hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains { $0.lowercased() == host }
    }

    /// A page's text (UTF-8), at most `maxBytes`, within `limit`.
    public func text(_ url: URL, hosts: [String], maxBytes: Int = DriverPages.maxPage, limit: Duration = DriverPages.limit) async throws -> String {
        try await fetch(url, hosts: hosts, maxBytes: maxBytes, limit: limit, post: nil)
    }

    /// The answer (UTF-8) to a JSON request posted to a maker's site (HP's driver list asks this way). Only `json` is sent; a
    /// redirect isn't followed (a post isn't sent again elsewhere): it is `.unreachable`.
    public func postJson(_ url: URL, _ json: String, hosts: [String], maxBytes: Int = DriverPages.maxPage, limit: Duration = DriverPages.limit) async throws -> String {
        try await fetch(url, hosts: hosts, maxBytes: maxBytes, limit: limit, post: json)
    }

    private func fetch(_ url: URL, hosts: [String], maxBytes: Int, limit: Duration, post: String?) async throws -> String {
        var at = url
        let until = ContinuousClock.now + limit
        var hop = 0
        while true {
            guard Self.isAllowed(at, hosts) else { throw FetchError(.notMakersSite) }
            let left = until - ContinuousClock.now
            guard left > .zero else { throw FetchError(.timedOut) }
            var headers = ["User-Agent": "InkvoltPrint/1.0"]
            if post != nil { headers["Content-Type"] = "application/json" }
            let request = HttpRequest(post == nil ? "GET" : "POST", at, headers: headers, body: post.map { Array($0.utf8) }, timeout: left,
                                      once: post != nil, replyLimit: maxBytes)
            let response: HttpResponse
            do {
                response = try await transport.send(request)
            } catch DeviceNetworkError.timedOut {
                throw FetchError(.timedOut)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FetchError(.unreachable)
            }
            if (300..<400).contains(response.status), let location = response.header("Location") {
                if post != nil { throw FetchError(.unreachable) }
                if hop >= Self.maxRedirects { throw FetchError(.tooManyRedirects) }
                guard let next = URL(string: location, relativeTo: at)?.absoluteURL else { throw FetchError(.unreachable) }
                at = next
                hop += 1
                continue
            }
            guard response.isSuccess else { throw FetchError(.unreachable) }
            guard response.body.count <= maxBytes else { throw FetchError(.tooBig) }
            return response.text
        }
    }
}
