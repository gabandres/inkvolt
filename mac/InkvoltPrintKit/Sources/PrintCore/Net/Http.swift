import Foundation

/// One HTTP request to a printer. PrintCore never opens a socket: a transport sends it (URLSession in PrintMac; the
/// fixture transport in demo mode and tests).
public struct HttpRequest: Sendable {
    public var method: String
    public var url: URL
    /// Header names as written; transports send them as given (Authorization included).
    public var headers: [String: String]
    public var body: [UInt8]?
    public var timeout: Duration
    /// A request that changes something on the printer and must never arrive twice: no pooled connection, no resend.
    public var once: Bool

    public init(_ method: String, _ url: URL, headers: [String: String] = [:], body: [UInt8]? = nil, timeout: Duration = DeviceHttp.defaultTimeout,
                once: Bool = false) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.once = once
    }

    public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

public struct HttpResponse: Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: [UInt8]

    public init(status: Int, headers: [String: String] = [:], body: [UInt8] = []) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Sends requests to printers. Throws `DeviceNetworkError` when the printer can't be reached; an HTTP error status is a
/// response, not an error.
public protocol HttpTransport: Sendable {
    func send(_ request: HttpRequest) async throws -> HttpResponse
}

/// The printer couldn't be reached (.NET's HttpRequestException and TimeoutException): it is offline.
public enum DeviceNetworkError: Error, Equatable, CustomStringConvertible {
    /// The connection was refused outright (nothing listens on that port): a printer without this interface.
    case refused
    case timedOut
    /// Unreachable, no route, a name that doesn't resolve, a TLS failure (a changed certificate among them).
    case failed(String)

    public var description: String {
        switch self {
        case .refused: "Connection refused"
        case .timedOut: "Timed out"
        case .failed(let why): why
        }
    }
}

/// The printer answered with an error status where success was needed.
public struct DeviceHttpError: Error, CustomStringConvertible {
    public let status: Int
    public let method: String
    public let url: URL
    public let body: String?

    /// A redirect's `Location` (redirects aren't followed), as the printer sent it.
    public let location: String?

    public var description: String { "\(method) \(url.path) returned \(status)" }
}

/// How a failure reading a printer counts (one rule for every interface).
public enum DeviceFailure {
    /// No answer: the printer is off, asleep past waking, or gone.
    public static func isOffline(_ error: Error) -> Bool { error is DeviceNetworkError || error is SnmpTimeoutError }

    /// The printer answered, but with an error status or an unreadable body (common while it wakes up).
    public static func isTransient(_ error: Error) -> Bool {
        error is DeviceHttpError || error is XmlFormatError || error is IppFormatError || error is SnmpFormatError || error is SnmpErrorStatus
    }
}
