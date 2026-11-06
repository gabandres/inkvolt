import Foundation

/// A printer Inkvolt Print remembers, as Inkvolt PDF sees it (the Windows suite's `InkvoltPrinter`): where to reach it,
/// what queue matching knows it by, and the macOS queue Inkvolt Print found standing for it.
public struct SuitePrinter: Equatable, Sendable {
    public var id: String
    public var name: String
    public var model: String?
    public var host: String
    public var esclRoot: String?
    public var ippUri: String?
    /// Its address and Bonjour host name.
    public var hosts: [String]
    /// The other UUIDs the user confirmed are this printer's ("This is my printer").
    public var acceptedUuids: [String]
    /// The CUPS queue that prints to it (Windows' `QueueNames`), when Inkvolt Print found one.
    public var queue: String?
    /// Added as SNMP-only: its status is read over SNMP.
    public var snmpOnly: Bool

    public init(id: String, name: String, model: String? = nil, host: String, esclRoot: String? = nil, ippUri: String? = nil,
                hosts: [String] = [], acceptedUuids: [String] = [], queue: String? = nil, snmpOnly: Bool = false) {
        self.id = id
        self.name = name
        self.model = model
        self.host = host
        self.esclRoot = esclRoot
        self.ippUri = ippUri
        self.hosts = hosts
        self.acceptedUuids = acceptedUuids
        self.queue = queue
        self.snmpOnly = snmpOnly
    }

    /// As queue matching sees it.
    public var claim: QueueClaim {
        QueueClaim(id: id, name: name, model: model, hosts: hosts.isEmpty ? [host] : hosts,
                   uuids: (PrinterId.isValid(id) ? [id] : []) + acceptedUuids)
    }
}

/// The hand-off from Inkvolt Print to Inkvolt PDF on the Mac: the printers Inkvolt Print remembers, in
/// `<app group>/Inkvolt/printers.json` (the container both apps claim, as the Pro key's file). Windows' Inkvolt PDF reads
/// Inkvolt Print's own `state.json`; on the Mac that file is in Inkvolt Print's sandbox container, which macOS guards
/// from other apps. Inkvolt Print writes this file after its list changes (no certificate pins, presets, folders or keys:
/// only what finding the printer behind a print queue and reading its status take); Inkvolt PDF only reads it, and what
/// it reads is bounded: a file over `maxBytes` reads as empty, at most `maxPrinters` printers, `maxText` characters a
/// value, `maxNames` hosts or UUIDs a printer, and an entry without an id or a host is skipped. Never throws.
public struct SuitePrinters: Equatable, Sendable {
    public static let maxBytes = 256 * 1024
    public static let maxPrinters = 100
    public static let maxText = 512
    public static let maxNames = 16
    public static let version = 1

    public static let empty = SuitePrinters([])

    public var printers: [SuitePrinter]

    public init(_ printers: [SuitePrinter]) { self.printers = printers }

    /// The file under the shared root (`ProKeyRoot.url`'s path on the Mac).
    public static func file(root: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent("Inkvolt").appendingPathComponent("printers.json").path
    }

    /// What Inkvolt Print hands over: its remembered network printers (not the forgotten ones), with each one's Bonjour
    /// host name and queue as its printer list knows them (by printer id).
    public static func from(_ state: PrintState, hostNames: [String: String] = [:], queues: [String: String] = [:]) -> SuitePrinters {
        func lookup(_ map: [String: String], _ id: String) -> String? {
            map.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }?.value
        }
        let forgotten = Set(state.forgottenUuids.map { $0.lowercased() })
        let list = state.printers.filter { !forgotten.contains($0.uuid.lowercased()) }.map { p in
            let accepted = state.acceptedUuids.first { PrinterId.same($0.key, p.uuid) }?.value ?? []
            let hosts = [p.host] + (lookup(hostNames, p.uuid).map { [$0] } ?? [])
            return SuitePrinter(id: p.uuid, name: p.name, model: p.model, host: p.host, esclRoot: p.esclRoot, ippUri: p.ippUri,
                                hosts: hosts, acceptedUuids: accepted, queue: lookup(queues, p.uuid), snmpOnly: p.snmp != nil)
        }
        return SuitePrinters(Array(list.prefix(maxPrinters)))
    }

    // MARK: Reading

    /// Reads the file under `root`; missing, unreadable or too big reads as empty.
    public static func load(root: String) -> SuitePrinters {
        let url = URL(fileURLWithPath: file(root: root))
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= maxBytes, let data = try? Data(contentsOf: url) else { return .empty }
        return parse(data)
    }

    public static func parse(_ data: Data) -> SuitePrinters {
        guard data.count <= maxBytes, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["printers"] as? [Any] else { return .empty }
        var out: [SuitePrinter] = []
        for item in list {
            guard out.count < maxPrinters else { break }
            if let entry = item as? [String: Any], let p = printer(entry) { out.append(p) }
        }
        return SuitePrinters(out)
    }

    private static func printer(_ e: [String: Any]) -> SuitePrinter? {
        guard let id = text(e["id"]), let host = text(e["host"]) else { return nil }
        let escl = text(e["esclRoot"]).flatMap { web($0, ["http", "https"]) }
        let ipp = text(e["ippUri"]).flatMap { web($0, ["http", "https", "ipp", "ipps"]) }
        return SuitePrinter(id: id, name: text(e["name"]) ?? host, model: text(e["model"]), host: host, esclRoot: escl, ippUri: ipp,
                            hosts: names(e["hosts"]), acceptedUuids: names(e["acceptedUuids"]), queue: text(e["queue"]),
                            snmpOnly: e["snmpOnly"] as? Bool ?? false)
    }

    /// A string value, trimmed; nil when empty, too long or not a string.
    private static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= maxText else { return nil }
        return s
    }

    private static func names(_ value: Any?) -> [String] {
        Array(((value as? [Any]) ?? []).compactMap(text).prefix(maxNames))
    }

    /// A URL with one of `schemes` and a host, else nil (a file: or javascript: root is never followed).
    private static func web(_ s: String, _ schemes: Set<String>) -> String? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), schemes.contains(scheme), u.host?.isEmpty == false else { return nil }
        return s
    }

    // MARK: Writing (Inkvolt Print)

    public func encoded() -> Data {
        let list: [[String: Any]] = printers.map { p in
            var e: [String: Any] = ["id": p.id, "name": p.name, "host": p.host, "hosts": p.hosts, "acceptedUuids": p.acceptedUuids,
                                    "snmpOnly": p.snmpOnly]
            if let v = p.model { e["model"] = v }
            if let v = p.esclRoot { e["esclRoot"] = v }
            if let v = p.ippUri { e["ippUri"] = v }
            if let v = p.queue { e["queue"] = v }
            return e
        }
        let root: [String: Any] = ["version": Self.version, "printers": list]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes the file under `root` when it says something else than this (atomically, its folder made); false when it
    /// couldn't be written.
    @discardableResult
    public func save(root: String) -> Bool {
        let url = URL(fileURLWithPath: Self.file(root: root))
        let data = encoded()
        if (try? Data(contentsOf: url)) == data { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Matching

    /// The printer behind the CUPS queue `name` (the print panel's printer): the one Inkvolt Print found for that queue,
    /// else queue matching over the queue's device URI and name (`CupsQueues.claim`); nil when none, or more than one
    /// could be it.
    public func printer(forQueue name: String, _ destination: CupsDestination?) -> SuitePrinter? {
        if let p = printers.first(where: { $0.queue?.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        guard let destination, let claim = CupsQueues.claim(destination, printers.map(\.claim)) else { return nil }
        return printers.first { $0.id == claim.id }
    }
}

/// A printer's health before printing (the Windows app's `PrinterCheck`): read-only (status and supplies), and given at
/// most `budget`; a printer that doesn't answer in time reads as offline, one that answers with something unreadable gives
/// no status at all.
public enum PrinterCheck {
    public static let budget: Duration = .seconds(2)
    public static let notResponding = "Not responding"

    /// "isn't responding", "has a problem": the warning after the printer's name.
    public static func problem(_ h: PrinterHealth, _ printer: String) -> String {
        h.state == .offline ? loc("{0} isn't responding", printer) : loc("{0} has a problem", printer)
    }

    /// What to do about a printer that `shouldWarn`s (Windows' words, with macOS's queue).
    public static func advice(_ h: PrinterHealth) -> String {
        if h.state == .offline {
            return loc("It didn't answer just now: it may be off, or not on this network. If you print anyway, macOS keeps the job until the printer is back.")
        }
        return loc("{0}. Fix it on the printer first, or print anyway: the job waits in the macOS queue until the printer can print it.", h.summary)
    }

    /// The line for a printer: "Office laser: Ready · toner 45%" (only names and values).
    public static func line(_ h: PrinterHealth, _ printer: String) -> String { "\(printer): \(h.summary)" }

    /// The health of `printer`, read through `transport` (and `snmp` for a printer added as SNMP-only); offline once
    /// `budget` passes or the caller is cancelled (`FleetReader.race`, which cancels the read either way).
    public static func health(_ printer: SuitePrinter, transport: @escaping HttpTransportFactory, snmp: (any SnmpTransport)? = nil,
                              budget: Duration = budget) async -> PrinterHealth? {
        await FleetReader.race(budget, timedOut: { .offline(notResponding) }) { await read(printer, transport, snmp) }
    }

    private static func read(_ p: SuitePrinter, _ transport: @escaping HttpTransportFactory, _ snmp: (any SnmpTransport)?) async
        -> PrinterHealth? {
        do {
            let conn = try await PrinterConnection.open(p.host, transport: transport, esclHint: p.esclRoot.flatMap { URL(string: $0) },
                                                        ippHint: p.ippUri.flatMap { URL(string: $0) }, snmp: p.snmpOnly ? snmp : nil)
            guard conn.probe.reachable else { return .offline(notResponding) }
            async let status = conn.status()
            async let supplies = suppliesOrNone(conn)
            return try await PrinterHealth.from(status, supplies)
        } catch {
            return error is CancellationError || DeviceFailure.isOffline(error) ? .offline(notResponding) : nil
        }
    }

    /// Status alone is still worth showing.
    private static func suppliesOrNone(_ conn: PrinterConnection) async -> [Consumable] {
        (try? await conn.supplies()) ?? []
    }
}
