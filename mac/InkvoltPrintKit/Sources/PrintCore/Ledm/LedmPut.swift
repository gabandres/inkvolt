import Foundation

/// The printer answered 401 or 403 to a write: it wants its EWS admin password (`DeviceHttp.setCredentials`), or the one
/// sent was wrong. The password itself is never part of the error.
public struct LedmAuthRequiredError: Error, Equatable, CustomStringConvertible {
    public let credentialsWereSent: Bool

    public init(credentialsWereSent: Bool) { self.credentialsWereSent = credentialsWereSent }

    public var description: String {
        credentialsWereSent ? "The printer rejected the admin password." : "The printer requires its admin password."
    }
}

/// An element to write to a printer, with the namespace and prefix it goes by (a device's own, read from its document).
struct LedmNode: Equatable, Sendable {
    var name: String
    var namespace: String
    var prefix: String
    var children: [LedmNode] = []
    var text: String?

    init(_ name: String, namespace: String, prefix: String, text: String? = nil, children: [LedmNode] = []) {
        self.name = name
        self.namespace = namespace
        self.prefix = prefix
        self.text = text
        self.children = children
    }

    /// The element as the device wrote it, without its children.
    init(like e: XmlElement, text: String? = nil) { self.init(e.name, namespace: e.namespace, prefix: e.prefix, text: text) }

    /// A copy of the device's element with its text and its descendants.
    init(copy e: XmlElement) {
        self.init(like: e)
        children = e.children.map(LedmNode.init(copy:))
        if children.isEmpty { text = e.value }
    }

    /// The document: a UTF-8 declaration, then this element with every namespace it and its descendants use declared on it.
    func document() -> String {
        let prefixes = assignPrefixes()
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        write(&out, prefixes, declare: true)
        return out
    }

    private func all() -> [LedmNode] { [self] + children.flatMap { $0.all() } }

    /// Namespace URI → prefix: each namespace keeps the device's prefix unless another namespace took it first.
    private func assignPrefixes() -> [String: String] {
        let nodes = all()
        let unqualified = nodes.contains { $0.namespace.isEmpty }
        var byNamespace: [String: String] = [:]
        var taken: Set<String> = []
        for n in nodes where !n.namespace.isEmpty && byNamespace[n.namespace] == nil {
            // No default namespace when an element has none (it would fall into it).
            var p = n.prefix.isEmpty && unqualified ? "ns" : n.prefix
            if taken.contains(p) || p.lowercased().hasPrefix("xml") {
                var i = 0
                while taken.contains("ns\(i)") { i += 1 }
                p = "ns\(i)"
            }
            byNamespace[n.namespace] = p
            taken.insert(p)
        }
        return byNamespace
    }

    private func write(_ out: inout String, _ prefixes: [String: String], declare: Bool) {
        let p = prefixes[namespace] ?? ""
        let qname = p.isEmpty ? name : "\(p):\(name)"
        out += "<\(qname)"
        if declare {
            for (ns, prefix) in prefixes.sorted(by: { $0.value < $1.value }) {
                out += prefix.isEmpty ? " xmlns=\"\(Self.escape(ns))\"" : " xmlns:\(prefix)=\"\(Self.escape(ns))\""
            }
        }
        out += ">"
        if let text { out += Self.escape(text) }
        for c in children { c.write(&out, prefixes, declare: false) }
        out += "</\(qname)>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension LedmClient {
    static let writeTimeout: Duration = .seconds(15)

    /// PUT a partial LEDM document (`LedmSettingCatalog.buildPut`) to the resource the DiscoveryTree lists for
    /// `resourceType`, over HTTPS. Throws `LedmAuthRequiredError` on 401/403, `DeviceHttpError` on another refusal.
    public func put(_ resourceType: String, _ body: String) async throws {
        guard let path = try await tree()?.uri(for: resourceType) else { throw LedmNotOffered(what: resourceType) }
        try await put(path: path, body)
    }

    /// PUT an LEDM document to a path (a manifest's, such as the firmware update Config), over HTTPS. The admin password
    /// goes along when `http` has one (`DeviceHttp.setCredentials`). Throws `LedmAuthRequiredError` on 401/403.
    public func put(path: String, _ body: String) async throws {
        let url = http.https(path)
        let response = try await http.send(HttpRequest("PUT", url, headers: ["Content-Type": "text/xml; charset=utf-8"], body: Array(body.utf8),
                                                       timeout: Self.writeTimeout))
        if response.status == 401 || response.status == 403 { throw LedmAuthRequiredError(credentialsWereSent: http.hasCredentials) }
        try DeviceHttp.ensureSuccess(response, "PUT", url)
    }
}

/// The printer doesn't list the resource a write needs.
public struct LedmNotOffered: Error, CustomStringConvertible {
    public let what: String

    public var description: String { "The printer does not expose \(what)." }
}
