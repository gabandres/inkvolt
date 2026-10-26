import Foundation

public enum FoundState: Equatable, Sendable { case canAdd, adding, added, listed }

/// A printer the Add a printer window found: one the search turned up, or one removed from the list earlier.
public struct FoundPrinter: Identifiable, Sendable {
    public var id: String { host }
    public var name: String
    public var host: String
    /// The address, and where the printer says it is ("192.0.2.40 · Office, 2nd floor"), or why it's offered.
    public var detail: String
    public var probe: ProbeResult?
    public var removed: DiscoveredPrinter?
    public var state: FoundState
    /// The list's entry for it (listed already, or just added).
    public var printerId: String?
    public var error: String?

    public init(name: String, host: String, detail: String, probe: ProbeResult? = nil, removed: DiscoveredPrinter? = nil, state: FoundState = .canAdd,
                printerId: String? = nil) {
        self.name = name
        self.host = host
        self.detail = detail
        self.probe = probe
        self.removed = removed
        self.state = state
        self.printerId = printerId
    }
}

/// Add a printer (the Windows app's `AddPrinterViewModel`, its rules without the window): searches this Mac's network, asks
/// each address that answers what it is as a typed address is asked, lists only printers (those already in the list marked
/// so), and offers printers removed earlier that discovery still sees.
public enum AddPrinter {
    /// A handful at a time: each one asked is a few HTTP requests (and SNMP for a printer without them).
    public static let identifyingAtOnce = 6

    /// The listed printer a probe is (its id and name), if any; the app answers it from its list.
    public typealias Listed = @Sendable (ProbeResult, String) async -> (id: String, name: String)?

    /// A printer removed from the list earlier that discovery sees now.
    public static func removed(_ d: DiscoveredPrinter) -> FoundPrinter? {
        guard let host = d.host else { return nil }
        return FoundPrinter(name: d.name, host: host, detail: "\(host) · Removed from your list earlier", removed: d)
    }

    /// What answered at `host`, as the window lists it; nil when it isn't a printer (something else takes connections on a
    /// printer port).
    public static func found(_ probe: ProbeResult, host: String, listed: (id: String, name: String)?) -> FoundPrinter? {
        guard probe.reachable else { return nil }
        return FoundPrinter(name: listed?.name ?? probe.model ?? host, host: host, detail: probe.location.map { "\(host) · \($0)" } ?? host,
                            probe: probe, state: listed == nil ? .canAdd : .listed, printerId: listed?.id)
    }

    /// Ones to add first, then those listed; by name within each.
    public static func insert(_ f: FoundPrinter, into list: inout [FoundPrinter]) {
        func before(_ a: FoundPrinter, _ b: FoundPrinter) -> Bool {
            let la = a.state == .listed, lb = b.state == .listed
            if la != lb { return !la }
            return a.name.compare(b.name, options: .caseInsensitive, locale: .current) == .orderedAscending
        }
        let at = list.firstIndex { before(f, $0) } ?? list.endIndex
        list.insert(f, at: at)
    }

    /// Runs `search`, identifying each address it reports (never one in `skip` or one twice; `identifyingAtOnce` at a
    /// time) and passing each printer to `found`; `checking` once the search is done and only identification is left.
    /// Returns how many addresses the search asked. Throws `CancellationError` when stopped.
    public static func run(skip: Set<String>, search: @escaping @Sendable (_ found: @escaping @Sendable (String) -> Void,
                                                                  _ progress: @escaping @Sendable (SearchProgress) -> Void) async throws -> Void,
                           identify: @escaping @Sendable (String) async -> FoundPrinter?, progress: @escaping @Sendable (SearchProgress) -> Void,
                           checking: @escaping @Sendable () -> Void, found: @escaping @Sendable (FoundPrinter) -> Void) async throws -> Int {
        let (hosts, reported) = AsyncStream.makeStream(of: String.self)
        let seen = Shared(Set(skip.map { $0.lowercased() }))
        let total = Shared(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { reported.finish() }
                try await search({ host in if seen.withLock({ $0.insert(host.lowercased()).inserted }) { reported.yield(host) } },
                                 { p in
                                     total.withLock { $0 = p.total }
                                     progress(p)
                                 })
                checking()
            }
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { asking in
                    var running = 0
                    for await host in hosts {
                        if running == identifyingAtOnce {
                            try await asking.next()
                            running -= 1
                        }
                        asking.addTask {
                            try Task.checkCancellation()
                            if let f = await identify(host) { found(f) }
                        }
                        running += 1
                    }
                    try await asking.waitForAll()
                }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        return total.withLock { $0 }
    }

    /// Asks the device at `host` what it is (LEDM, CDM, IPP at `ipp` or the default, eSCL, SNMP) and makes its entry.
    public static func identify(_ host: String, ipp: URL? = nil, transport: @escaping HttpTransportFactory, snmp: any SnmpTransport,
                                listed: Listed) async -> FoundPrinter? {
        guard let probe = try? await PrinterConnection.probe(DeviceHttp(host: host, transport: transport), ippHint: ipp, snmp: snmp) else { return nil }
        return found(probe, host: host, listed: await listed(probe, host))
    }

    /// What the printer list remembers for a printer added from what answered at `host`: its id (its UUID, else one from the
    /// address), and for one that answered only SNMP, what it said about itself (only these are read over SNMP).
    public static func knownPrinter(_ probe: ProbeResult, host: String) -> KnownPrinter {
        KnownPrinter(uuid: PrinterId.normalize(probe.uuid, host: host), name: probe.model ?? host, model: probe.model, host: host,
                     esclRoot: probe.esclRoot?.absoluteString, ippUri: probe.ippEndpoint?.absoluteString,
                     snmp: probe.snmp.map(SnmpDevice.from))
    }
}

/// What the Add a printer window says.
public enum AddPrinterText {
    public static let looking = "Looking for printers on your network…"
    public static let checking = "Checking what answered…"
    public static let stopped = "Search stopped."
    public static let failed = "The search didn't work. You can still add a printer by its address."

    public static func looking(_ p: SearchProgress) -> String { "\(looking) \(p.checked) of \(p.total) addresses" }

    /// The search is over: what it found. `total` is how many addresses it asked.
    public static func done(total: Int, found: [FoundPrinter]) -> String {
        let listed = found.count(where: { $0.state == .listed })
        let others = found.count - listed
        if total == 0 { return "This Mac isn't on a home or office network that can be searched." }
        switch (others, listed) {
        case (0, 0): return "No printers answered on your network."
        case (0, 1): return "The printer that answered is in your list already."
        case (0, _): return "The \(listed) printers that answered are in your list already."
        case (1, _): return "Found a printer you can add."
        default: return "Found \(others) printers you can add."
        }
    }

    /// Nothing to add: the window says what may hide a printer.
    public static func nothingFound(_ found: [FoundPrinter]) -> Bool { !found.contains { $0.state != .listed } }

    public static func noAnswer(_ host: String) -> String {
        "No printer answered at \(host). Check the address, and that the printer is on and on this network."
    }
}
