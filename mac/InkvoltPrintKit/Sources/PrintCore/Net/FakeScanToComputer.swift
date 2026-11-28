import Foundation
import Synchronization

/// A made-up HP printer panel's Scan to Computer list (demo mode and tests; Windows' `FakeScanToComputer`), in front of a
/// printer's documents (a `FixtureTransport`): its DiscoveryTree gains the walk-up interface (`LedmWalkupScan`'s assumed
/// names), the list holds the computers POSTed to it until they're DELETEd or the printer "restarts" (`powerUp`), and `press`
/// is someone choosing a computer on the panel and pressing Scan: a scan event in the EventTable (whose long poll answers at
/// once on a change) and the event document's type. The list, manifest and event documents themselves are the fixtures'
/// (`Fixtures/hp-demo`, written by hand). Never opens a socket.
public final class FakeScanToComputer: HttpTransport {
    public static let manifestPath = "/WalkupScanToComp/WalkupScanToCompManifest.xml"
    public static let listPath = "/WalkupScanToComp/WalkupScanToCompDestinations"
    public static let eventPath = "/WalkupScanToComp/WalkupScanToCompEvent"

    private static let treePath = "/DevMgmt/DiscoveryTree.xml", tablePath = "/EventMgmt/EventTable.xml"

    private struct State {
        var listed: [(id: Int, name: String, host: String)] = []
        var events: [(category: String, stamp: Int, uris: [String])] = []
        var next = 1, version = 1, stamp = 100
        var eventType: String?
        var writes: [String] = []
        var postAnswer: Int?, tableAnswer: Int?, listAnswer: Int?, addedThenAnswer: Int?
        var noLocation = false
        var polls = 0, mostPolls = 0
    }

    private let documents: any HttpTransport
    private let inTree: Bool
    private let state = Mutex(State())

    public init(_ documents: any HttpTransport, inTree: Bool = true) {
        self.documents = documents
        self.inTree = inTree
    }

    /// What a POST to the list gets instead of 201 (401 for an admin password, 400…); nil: the Mac is added.
    public var postAnswer: Int? {
        get { state.withLock { $0.postAnswer } }
        set { state.withLock { $0.postAnswer = newValue } }
    }

    /// What a GET of the EventTable gets instead of the table (503: as if it weren't answering); nil: the table.
    public var tableAnswer: Int? {
        get { state.withLock { $0.tableAnswer } }
        set { state.withLock { $0.tableAnswer = newValue } }
    }

    /// What a GET of the list gets instead of the list (503: busy for now); nil: the list.
    public var listAnswer: Int? {
        get { state.withLock { $0.listAnswer } }
        set { state.withLock { $0.listAnswer = newValue } }
    }

    /// A POST adds the computer and then gets this instead of 201 (its answer lost: 503, say); nil: 201.
    public var addedThenAnswer: Int? {
        get { state.withLock { $0.addedThenAnswer } }
        set { state.withLock { $0.addedThenAnswer = newValue } }
    }

    /// A 201 without a `Location` (the list then says where it went).
    public var noLocation: Bool {
        get { state.withLock { $0.noLocation } }
        set { state.withLock { $0.noLocation = newValue } }
    }

    /// Every POST and DELETE, in order: method and path.
    public var writes: [String] { state.withLock { $0.writes } }

    /// The names on the list now.
    public var names: [String] { state.withLock { $0.listed.map(\.name) } }

    /// The destinations' paths on the list now.
    public var paths: [String] { state.withLock { $0.listed.map { "\(Self.listPath)/\($0.id)" } } }

    /// The host names on the list now (this app's carry its marker).
    public var hosts: [String] { state.withLock { $0.listed.map(\.host) } }

    /// The most EventTable long polls held open at once (one connection should hold one).
    public var mostPolls: Int { state.withLock { $0.mostPolls } }

    /// A computer already on the list (another Mac, HP's software for this one, or with `host` an earlier run of this app's).
    /// Its path.
    @discardableResult
    public func add(_ name: String, host: String? = nil) -> String {
        state.withLock { s in
            s.listed.append((s.next, name, host ?? name))
            defer { s.next += 1 }
            return "\(Self.listPath)/\(s.next)"
        }
    }

    /// Someone picks `destination` (default: the last computer added) on the panel and presses Scan: the event document says
    /// `type` and the EventTable gets a new scan event naming the destination. False when the list is empty.
    @discardableResult
    public func press(_ destination: String? = nil, type: String = "ScanRequested") -> Bool {
        state.withLock { s in
            guard destination != nil || !s.listed.isEmpty else { return false }
            let target = destination ?? "\(Self.listPath)/\(s.listed[s.listed.count - 1].id)"
            s.eventType = type
            Self.changed(&s, LedmWalkupScan.names.scanEventCategory, [target, Self.eventPath])
            return true
        }
    }

    /// The printer restarts: its list is empty and its EventTable says it powered up.
    public func powerUp() {
        state.withLock { s in
            s.listed.removeAll()
            Self.changed(&s, LedmWalkupScan.powerUpCategory, ["/DevMgmt/ProductStatusDyn.xml"])
        }
    }

    private static func changed(_ s: inout State, _ category: String, _ uris: [String]) {
        s.stamp += 1
        s.events.removeAll { $0.category == category }
        s.events.append((category, s.stamp, uris))
        s.version += 1
    }

    private var etag: String { state.withLock { "fake-\($0.version)" } }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        let path = request.url.path
        let method = request.method
        if method == "GET" && path == Self.treePath && inTree { return try await tree(request) }
        if method == "GET" && path == Self.tablePath {
            if let down = tableAnswer { return HttpResponse(status: down) }
            return try await table(request)
        }
        if !inTree { return try await documents.send(request) }
        if method == "GET" && path == Self.listPath {
            if let failing = listAnswer { return HttpResponse(status: failing) }
            return try await list(request)
        }
        if method == "GET" && path == Self.eventPath { return try await event(request) }
        if method == "POST" && path == Self.listPath { return try post(request) }
        if method == "DELETE" && path.hasPrefix(Self.listPath + "/") {
            let removed: Bool = state.withLock { s in
                s.writes.append("DELETE \(path)")
                guard let id = Int(path.dropFirst(Self.listPath.count + 1)), path.dropFirst(Self.listPath.count + 1).allSatisfy(\.isNumber) else { return false }
                let before = s.listed.count
                s.listed.removeAll { $0.id == id }
                return s.listed.count < before
            }
            return HttpResponse(status: removed ? 200 : 404)
        }
        return try await documents.send(request)
    }

    private func post(_ request: HttpRequest) throws -> HttpResponse {
        let refused: Int? = state.withLock { s in
            s.writes.append("POST \(request.url.path)")
            return s.postAnswer
        }
        if let refused { return HttpResponse(status: refused) }
        let posted = try DeviceXml.load(request.bodyBytes())
        let name = posted.kid(LedmWalkupScan.names.name)?.value ?? "?"
        let host = posted.kid(LedmWalkupScan.names.hostname)?.value ?? name
        let (id, lost, noLocation): (Int, Int?, Bool) = state.withLock { s in
            let id = s.next
            s.next += 1
            s.listed.append((id, name, host))
            return (id, s.addedThenAnswer, s.noLocation)
        }
        if let lost { return HttpResponse(status: lost) }
        guard !noLocation, let location = URL(string: "\(Self.listPath)/\(id)", relativeTo: request.url)?.absoluteString else {
            return HttpResponse(status: 201)
        }
        return HttpResponse(status: 201, headers: ["Location": location])
    }

    /// The fixture's document as text, or the inner answer when it isn't a document.
    private func inner(_ request: HttpRequest) async throws -> (text: String?, failed: HttpResponse?) {
        var plain = HttpRequest("GET", request.url, timeout: request.timeout)
        plain.headers = [:]
        let response = try await documents.send(plain)
        guard response.isSuccess else { return (nil, HttpResponse(status: response.status)) }
        return (response.text, nil)
    }

    /// Text inserted before the document's last closing tag (its root's).
    private static func beforeRootEnd(_ text: String, _ insert: String) -> String {
        guard let end = text.range(of: "</", options: .backwards) else { return text }
        return text.replacingCharacters(in: end.lowerBound..<end.lowerBound, with: insert)
    }

    private static func xml(_ text: String, etag: String? = nil) -> HttpResponse {
        var headers = ["Content-Type": "text/xml"]
        if let etag { headers["ETag"] = etag }
        return HttpResponse(status: 200, headers: headers, body: Array(text.utf8))
    }

    private static func prefixed(_ e: XmlElement, _ local: String) -> String { e.prefix.isEmpty ? local : "\(e.prefix):\(local)" }

    /// The printer's tree with the walk-up interface listed (a `SupportedIfc`, as the tree lists its other manifests).
    private func tree(_ request: HttpRequest) async throws -> HttpResponse {
        let (text, failed) = try await inner(request)
        guard let text else { return failed! }
        let root = try DeviceXml.load(text)
        let dd = LedmWalkupScan.dictionaryNamespace
        let ifc = "<\(Self.prefixed(root, "SupportedIfc"))><\(Self.prefixed(root, "ManifestURI"))>\(Self.manifestPath)</\(Self.prefixed(root, "ManifestURI"))>"
            + "<dd:ResourceType xmlns:dd=\"\(dd)\">\(LedmWalkupScan.names.interface)</dd:ResourceType><dd:Revision xmlns:dd=\"\(dd)\">demo</dd:Revision>"
            + "</\(Self.prefixed(root, "SupportedIfc"))>"
        return Self.xml(Self.beforeRootEnd(text, ifc))
    }

    /// The fixture's list with the computers on it now.
    private func list(_ request: HttpRequest) async throws -> HttpResponse {
        let (text, failed) = try await inner(request)
        guard let text else { return failed! }
        let root = try DeviceXml.load(text)
        let n = LedmWalkupScan.names
        let listed = state.withLock { $0.listed }
        let destinations = listed.map { l in
            "<\(Self.prefixed(root, n.destination)) xmlns:dd=\"\(LedmWalkupScan.dictionaryNamespace)\" xmlns:dd3=\"\(n.hostnameNamespace)\">"
                + "<dd:\(n.resourceUri)>\(Self.listPath)/\(l.id)</dd:\(n.resourceUri)><dd:\(n.name)>\(LedmNode.escape(l.name))</dd:\(n.name)>"
                + "<dd3:\(n.hostname)>\(LedmNode.escape(l.host))</dd3:\(n.hostname)>"
                + "<\(Self.prefixed(root, n.linkType))>\(n.linkTypeValue)</\(Self.prefixed(root, n.linkType))></\(Self.prefixed(root, n.destination))>"
        }.joined()
        return Self.xml(Self.beforeRootEnd(text, destinations))
    }

    /// The fixture's event document, saying what was last pressed.
    private func event(_ request: HttpRequest) async throws -> HttpResponse {
        let (text, failed) = try await inner(request)
        guard var text else { return failed! }
        if let type = state.withLock({ $0.eventType }),
           let range = text.range(of: "(<[^<>]*\(LedmWalkupScan.names.eventType)>)[^<]*(</)", options: .regularExpression) {
            let match = String(text[range])
            let open = match[..<(match.range(of: ">")!.upperBound)]
            text.replaceSubrange(range, with: open + LedmNode.escape(type) + "</")
        }
        return Self.xml(text)
    }

    /// The fixture's EventTable with this panel's events (one per category, the latest), under an ETag that changes with
    /// them. A long poll (`If-None-Match`) on the current one is held until something changes or its `timeout` runs out (304).
    private func table(_ request: HttpRequest) async throws -> HttpResponse {
        guard let asked = request.header("If-None-Match") else { return try await tableNow(request) }
        state.withLock { s in
            s.polls += 1
            s.mostPolls = max(s.mostPolls, s.polls)
        }
        defer { state.withLock { $0.polls -= 1 } }
        if asked == etag {
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
            let deciseconds = query?.first { $0.name == "timeout" }?.value.flatMap { Int($0) }
            let wait = Duration.milliseconds(min(max((deciseconds.map { $0 * 100 }) ?? 60_000, 1_000), 600_000))
            let clock = ContinuousClock()
            let until = clock.now + wait
            while asked == etag {
                if clock.now >= until { return HttpResponse(status: 304) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        return try await tableNow(request)
    }

    private func tableNow(_ request: HttpRequest) async throws -> HttpResponse {
        var plainUrl = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        plainUrl?.query = nil
        let (text, failed) = try await inner(HttpRequest("GET", plainUrl?.url ?? request.url, timeout: request.timeout))
        guard let text else { return failed! }
        let root = try DeviceXml.load(text)
        let (ours, tag): ([(category: String, stamp: Int, uris: [String])], String) = state.withLock { ($0.events, "fake-\($0.version)") }
        var events = LedmParsers.parseEventTable(root).filter { e in !ours.contains { $0.category == e.category } }
            .map { (category: $0.category, stamp: $0.agingStamp ?? "", uris: $0.uris, type: $0.resourceType) }
        events += ours.map { (category: $0.category, stamp: "\($0.stamp)-1", uris: $0.uris, type: nil) }
        let ev = Self.prefixed(root, "Event"), payload = Self.prefixed(root, "Payload"), table = Self.prefixed(root, root.name)
        let xmlns = root.prefix.isEmpty ? "xmlns=\"\(root.namespace)\"" : "xmlns:\(root.prefix)=\"\(root.namespace)\""
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><\(table) \(xmlns) xmlns:dd=\"\(LedmWalkupScan.dictionaryNamespace)\">"
        for e in events {
            out += "<\(ev)><dd:UnqualifiedEventCategory>\(LedmNode.escape(e.category))</dd:UnqualifiedEventCategory>"
                + "<dd:AgingStamp>\(LedmNode.escape(e.stamp))</dd:AgingStamp>"
            for uri in e.uris {
                out += "<\(payload)><dd:ResourceURI>\(LedmNode.escape(uri))</dd:ResourceURI>"
                    + (e.type.map { "<dd:ResourceType>\(LedmNode.escape($0))</dd:ResourceType>" } ?? "") + "</\(payload)>"
            }
            out += "</\(ev)>"
        }
        return Self.xml(out + "</\(table)>", etag: tag)
    }
}
