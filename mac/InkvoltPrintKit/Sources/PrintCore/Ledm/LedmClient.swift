import Foundation
import Synchronization

/// HP LEDM (XML over HTTP). Resource URIs come from the DiscoveryTree, not hard-coded paths. Reads go over plain HTTP;
/// writes (later: settings) go over HTTPS so admin credentials never cross the LAN in clear text.
public final class LedmClient: Sendable {
    /// Long-poll window the printer holds an EventTable request open (deciseconds on the wire).
    public static let eventWait: Duration = .seconds(60)

    public let http: DeviceHttp
    private let cache = Mutex<(tree: DiscoveryTree?, caps: [String: XmlElement])>((nil, [:]))
    private let feed = Mutex<LedmEventFeed?>(nil)

    public init(_ http: DeviceHttp) { self.http = http }

    /// Nil when the device does not speak LEDM.
    public func tree() async throws -> DiscoveryTree? {
        if let tree = cache.withLock({ $0.tree }) { return tree }
        guard let bytes = try await http.getBytesOrNil(try http.http(DiscoveryTree.path)) else { return nil }
        let tree = DiscoveryTree.parse(try DeviceXml.load(bytes))
        cache.withLock { $0.tree = tree }
        return tree
    }

    /// Fetch a resource by LEDM type. Nil if the device does not expose it. *Cap resources are cached.
    public func get(_ resourceType: String) async throws -> XmlElement? {
        if let cached = cache.withLock({ $0.caps[resourceType] }) { return cached }
        guard let path = try await tree()?.uri(for: resourceType), let bytes = try await http.getBytesOrNil(try http.http(path)) else { return nil }
        let doc = try DeviceXml.load(bytes)
        if resourceType.hasSuffix("Cap") { cache.withLock { $0.caps[resourceType] = doc } }
        return doc
    }

    public func status() async throws -> PrinterStatus? { try await get(LedmResource.productStatusDyn).map(LedmParsers.parseStatus) }

    public func productInfo() async throws -> ProductInfo? { try await get(LedmResource.productConfigDyn).map(LedmParsers.parseProductConfig) }

    public func usage() async throws -> UsageCounters? { try await get(LedmResource.productUsageDyn).map(LedmParsers.parseUsage) }

    public func consumables() async throws -> [Consumable]? {
        async let supplies = get(LedmResource.consumableConfigDyn)
        async let usage = get(LedmResource.productUsageDyn)
        let (s, u) = try await (supplies, usage)
        return s.map { LedmParsers.parseConsumables($0, usage: u) }
    }

    /// GET an LEDM document by path (manifest resources aren't in the DiscoveryTree). Nil on 404.
    public func get(path: String) async throws -> XmlElement? {
        try await http.getBytesOrNil(try http.http(path)).map { try DeviceXml.load($0) }
    }

    /// Yields each time the printer's event table changes, through the connection's one `events` feed (so the status and
    /// Scan to Computer share one long poll). The first table comes at once; an empty list comes once when the printer stops
    /// answering. Ends when the consumer stops.
    public func watchEvents() -> AsyncStream<[LedmEvent]> {
        let tables = events.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await table in tables { continuation.yield(table.events) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The printer's EventTable, read once for everyone watching this connection (`LedmEventFeed`).
    public var events: LedmEventFeed {
        feed.withLock { kept in
            if let kept { return kept }
            let made = LedmEventFeed { [weak self] in
                guard let self else { return AsyncStream { $0.finish() } }
                return self.pollTables()
            }
            kept = made
            return made
        }
    }

    /// The long poll itself, as a stream that ends when its consumer stops.
    private func pollTables() -> AsyncStream<LedmEventTable> {
        AsyncStream { continuation in
            let task = Task {
                await self.runWatch { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The device's delayed reply (`?timeout=` + `If-None-Match`), so an idle printer costs one request per minute, not a poll
    /// loop. The first table at once; an unanswered one (`answered` false) once per outage. Ends at once when the tree lists
    /// no EventTable.
    private func runWatch(_ yield: @Sendable (LedmEventTable) -> Void) async {
        guard let path = try? await tree()?.uri(for: LedmResource.eventTable) else { return }
        var etag: String?
        var backoff: Duration = .seconds(2)
        let wait = Int(Self.eventWait.components.seconds * 10)
        var wasFailing = false
        let clock = ContinuousClock()
        while !Task.isCancelled {
            var events: [LedmEvent]?
            var failed = false
            var notModified = false
            var recovered = false
            let started = clock.now
            do {
                var request = HttpRequest("GET", etag == nil ? try http.http(path) : try http.http("\(path)?timeout=\(wait)"),
                                          timeout: Self.eventWait + .seconds(15))
                if let etag { request.headers["If-None-Match"] = etag }
                let response = try await http.send(request)
                notModified = response.status == 304
                if !notModified {
                    try DeviceHttp.ensureSuccess(response, "GET", request.url)
                    // HP sends unquoted ETags ("34-2").
                    etag = response.header("ETag")
                    events = LedmParsers.parseEventTable(try DeviceXml.load(response.body))
                }
                backoff = .seconds(2)
                if wasFailing {
                    // Back: a table read now is the fresh start the watchers need, under its own ETag; a 304 on the old one
                    // says nothing, so the whole table is read next, at once (not after the no-ETag pause below).
                    wasFailing = false
                    recovered = true
                    if events == nil { etag = nil }
                }
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }

            if let events { yield(LedmEventTable(events, answered: true)) }
            do {
                if failed {
                    // Tell the caller once per outage so it can re-read status (and show "offline").
                    if !wasFailing { yield(LedmEventTable([], answered: false)) }
                    wasFailing = true
                    try await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(30))
                } else if notModified && clock.now - started < .seconds(1) {
                    // Firmware that ignores ?timeout= answers 304 at once; don't spin.
                    try await Task.sleep(for: .seconds(5))
                } else if etag == nil && !recovered {
                    // Device gave no ETag: long poll impossible, fall back to a slow refresh.
                    try await Task.sleep(for: .seconds(30))
                }
            } catch {
                return
            }
        }
    }
}
