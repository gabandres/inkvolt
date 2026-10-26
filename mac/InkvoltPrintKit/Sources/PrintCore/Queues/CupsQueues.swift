import Foundation

/// How this Mac reaches a queue's printer, from its `device-uri`.
public enum QueueConnection: Equatable, Sendable { case usb, network, shared, other }

/// A network printer on the list as queue matching sees it: its id, its name and model, the addresses and Bonjour names it's
/// known by, and the UUIDs it answers to.
public struct QueueClaim: Equatable, Sendable {
    public var id: String
    public var name: String
    public var model: String?
    /// Its address, its Bonjour host name ("NPI1A2B3C.local"), and the like.
    public var hosts: [String]
    /// Its id when that's a UUID, and the UUIDs the user accepted for it.
    public var uuids: [String]

    public init(id: String, name: String, model: String? = nil, hosts: [String] = [], uuids: [String] = []) {
        self.id = id
        self.name = name
        self.model = model
        self.hosts = hosts
        self.uuids = uuids
    }
}

/// Which CUPS destinations are printers Inkvolt Print lists on their own (the Windows app's `QueueKinds` and `QueueMatch`, for
/// macOS): queues someone set up (USB, network, shared from another Mac or a Windows PC) that no network printer here already
/// stands for. Bonjour's temporary destinations (network printers macOS sees but nobody set up), faxes, classes and PDF
/// writers are left out.
public enum CupsQueues {
    private static let idPrefix = "mac-queue:"

    /// The id a queue printer goes by (selection, alerts, hidden list): never a UUID, so never mixed up with a device.
    public static func id(for queueName: String) -> String { idPrefix + queueName.trimmingCharacters(in: .whitespaces).lowercased() }

    public static func isQueueId(_ id: String?) -> Bool { id?.hasPrefix(idPrefix) == true }

    private static let virtualSchemes: Set<String> = ["file", "cups-pdf", "pdf", "pdfwriter", "pdf-writer", "fax", "faxmodem", "cups-brf"]
    private static let virtualWords = ["pdf", "fax", "send to", "virtual print", "document writer", "image writer"]

    public static func isVirtual(_ d: CupsDestination) -> Bool {
        if d.has(CupsDestination.TypeBit.fax) || d.has(CupsDestination.TypeBit.class) { return true }
        if let scheme = scheme(d.deviceUri), virtualSchemes.contains(scheme) { return true }
        return virtualWords.contains { w in
            [d.name.replacingOccurrences(of: "_", with: " "), d.displayName, d.makeAndModel ?? ""].contains { $0.range(of: w, options: .caseInsensitive) != nil }
        }
    }

    /// The destinations to consider at all: real queues, not Bonjour's temporary ones or virtual printers.
    public static func isRealQueue(_ d: CupsDestination) -> Bool { !d.isTemporary && !isVirtual(d) }

    public static func connection(_ d: CupsDestination) -> QueueConnection {
        let s = scheme(d.deviceUri)
        if s == "smb" || d.has(CupsDestination.TypeBit.remote) { return .shared }
        switch s {
        case "usb": return .usb
        case "hp": return d.deviceUri?.contains("/usb/") == true ? .usb : .network // HP's driver: hp:/usb/… or hp:/net/…
        case "dnssd", "mdns", "ipp", "ipps", "http", "https", "socket", "lpd": return .network
        default: return .other
        }
    }

    /// "USB", "Network", "Shared from office-pc"…: how this Mac reaches it, in a word or two.
    public static func connectionText(_ d: CupsDestination) -> String {
        switch connection(d) {
        case .usb: "USB"
        case .network: "Network"
        case .shared: server(d).map { "Shared from \($0)" } ?? "Shared from another computer"
        case .other: "Set up on this Mac"
        }
    }

    /// "Network (192.0.2.40)", "Network (Bonjour)", "USB": the connection with where, for the printer pane's details.
    public static func connectionDetail(_ d: CupsDestination) -> String {
        let text = connectionText(d)
        guard connection(d) == .network, let uri = d.deviceUri else { return text }
        if scheme(uri) == "dnssd" || serviceInstance(uri) != nil { return "\(text) (Bonjour)" }
        return host(uri).map { "\(text) (\($0))" } ?? text
    }

    /// Where a queue's printer can be asked directly (SNMP, IPP): the host in a network queue's device URI, not a Bonjour
    /// service name; nil for USB, shared and the rest.
    public static func address(_ d: CupsDestination) -> String? {
        guard connection(d) == .network, let uri = d.deviceUri, serviceInstance(uri) == nil, scheme(uri) != "dnssd" else { return nil }
        return host(uri)
    }

    /// The network printer here that stands for a queue: in order of certainty, the printer's UUID in the device URI
    /// (`dnssd://…?uuid=`), its address or Bonjour host name there, its Bonjour service name, and last its name or model
    /// starting the queue's (when exactly one printer's does). Nil when nothing matches or the name is ambiguous.
    public static func claim(_ d: CupsDestination, _ known: [QueueClaim]) -> QueueClaim? {
        guard !known.isEmpty else { return nil }
        let uri = d.deviceUri ?? ""
        if let uuid = uuidIn(uri), let p = known.first(where: { $0.uuids.contains { same(normalizedUuid($0), uuid) } || same(normalizedUuid($0.id), uuid) }) {
            return p
        }
        if let h = host(uri).map(bareHost) {
            let byHost = known.filter { $0.hosts.contains { same(bareHost($0), h) } }
            if byHost.count == 1 { return byHost[0] }
        }
        if let instance = serviceInstance(uri) {
            let byService = known.filter { same($0.name, instance) }
            if byService.count == 1 { return byService[0] }
        }
        let names = [d.displayName, d.name.replacingOccurrences(of: "_", with: " ")]
        let byName = known.filter { p in
            names.contains { n in startsWithWord(n, p.name) || (p.model.map { startsWithWord(n, $0) } ?? false) }
        }
        return byName.count == 1 ? byName[0] : nil
    }

    /// The real queues among `destinations` that none of `known` stands for.
    public static func unclaimed(_ destinations: [CupsDestination], _ known: [QueueClaim]) -> [CupsDestination] {
        destinations.filter { isRealQueue($0) && claim($0, known) == nil }
    }

    // MARK: Device URIs

    static func scheme(_ uri: String?) -> String? {
        guard let uri, let colon = uri.firstIndex(of: ":") else { return nil }
        return uri[..<colon].lowercased()
    }

    /// The host part, percent-decoded ("NPI1A2B3C.local", "192.0.2.40", "HP LaserJet (1A2B3C)._ipp._tcp.local.").
    static func host(_ uri: String) -> String? {
        guard let start = uri.range(of: "://")?.upperBound else { return nil }
        var rest = uri[start...]
        if let at = rest.firstIndex(of: "@"), rest[..<at].firstIndex(of: "/") == nil { rest = rest[rest.index(after: at)...] }
        var h = String(rest.prefix { $0 != "/" && $0 != "?" })
        if h.hasPrefix("[") { h = String(h.prefix { $0 != "]" }.dropFirst()) } else if let colon = h.lastIndex(of: ":"), h[h.index(after: colon)...].allSatisfy(\.isNumber) {
            h = String(h[..<colon])
        }
        h = h.removingPercentEncoding ?? h
        return h.isEmpty ? nil : h
    }

    /// A Bonjour service's instance name in a device URI ("HP LaserJet MFP M234dw (1A2B3C)" from
    /// `ipp://HP%20LaserJet%20MFP%20M234dw%20(1A2B3C)._ipp._tcp.local./`), or nil.
    static func serviceInstance(_ uri: String) -> String? {
        guard let h = host(uri) else { return nil }
        for type in ["._ipp._tcp", "._ipps._tcp", "._printer._tcp", "._pdl-datastream._tcp", "._uscan._tcp"] {
            if let r = h.range(of: type, options: .caseInsensitive) { return String(h[..<r.lowerBound]) }
        }
        return nil
    }

    /// The `uuid=` query parameter (macOS's dnssd and IPP Everywhere queues carry the printer's), normalized.
    static func uuidIn(_ uri: String) -> String? {
        guard let q = uri.firstIndex(of: "?") else { return nil }
        for pair in uri[uri.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "uuid", let u = normalizedUuid(String(kv[1])) { return u }
        }
        return nil
    }

    static func normalizedUuid(_ text: String) -> String? {
        var raw = text.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        if raw.lowercased().hasPrefix("urn:uuid:") { raw = String(raw.dropFirst(9)) }
        return PrinterId.isValid(raw) ? raw.lowercased() : nil
    }

    private static func bareHost(_ h: String) -> String {
        var h = h.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// The server a shared queue is on: an `smb://server/printer` URI's host, or for a printer shared from another Mac its
    /// Bonjour service's computer ("Front desk @ office-mac").
    static func server(_ d: CupsDestination) -> String? {
        guard let uri = d.deviceUri else { return nil }
        if scheme(uri) == "smb" { return host(uri) }
        if let instance = serviceInstance(uri), let at = instance.range(of: " @ ") { return String(instance[at.upperBound...]) }
        return nil
    }

    /// `prefix` starts `text` and ends there or at a character that isn't a letter or digit.
    private static func startsWithWord(_ text: String, _ prefix: String) -> Bool {
        guard !prefix.isEmpty, text.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        let rest = text.dropFirst(prefix.count)
        return rest.first.map { !$0.isLetter && !$0.isNumber } ?? true
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

/// A queue's status in plain words. `offline`: macOS says the printer can't be reached.
public struct QueueReading: Equatable, Sendable {
    public var status: PrinterStatus
    public var offline: Bool
}

/// A CUPS destination's state as a printer status (the Windows app's `SpoolerStatus`): `printer-state` and
/// `printer-state-reasons` are IPP's, so they're worded as a network printer's IPP status is; macOS's own conditions
/// (paused, not accepting jobs, the printer not answering its queue) come first, and CUPS's notes about itself (`cups-*`)
/// are left out.
public enum CupsStatus {
    public static func describe(_ d: CupsDestination) -> QueueReading {
        let waiting = switch d.jobs ?? 0 {
        case 0: ""
        case 1: " 1 job is waiting."
        case let n: " \(n) jobs are waiting."
        }
        let reasons = d.reasons.map { IppClient.splitReason($0).id }
        if reasons.contains("offline") || reasons.contains("offline-report") && d.state != 4 {
            let check = switch CupsQueues.connection(d) {
            case .usb: "Check that it's turned on and its USB cable is plugged in."
            case .shared: "Check that the computer sharing it is on and the printer is turned on."
            case .network: "Check that it's turned on and on the same network as this Mac."
            case .other: "Check that it's turned on and connected."
            }
            return QueueReading(status: PrinterStatus(code: "offline", message: "Offline", severity: .error, alerts: [],
                                                      detail: "macOS can't reach the printer. \(check)\(waiting)"), offline: true)
        }

        var attributes = d.asIpp.attributes
        attributes["printer-state-reasons"] = d.reasons.filter { r in
            let id = IppClient.splitReason(r).id
            return !id.hasPrefix("cups-") && !["paused", "offline-report", "hold-new-jobs", "none"].contains(id)
        }.map { .text($0) }
        var status = IppClient.toStatus(IppResponse(statusCode: 0, attributes: attributes))
        let jobs = waiting.isEmpty ? nil : waiting.trimmingCharacters(in: .whitespaces)

        if d.state == 5 {
            // Stopped on a problem the printer reports: that problem. Stopped without one: paused, by someone or by macOS
            // itself when the printer failed a job.
            if let error = status.alerts.first(where: { $0.severity == .error }) {
                return QueueReading(status: PrinterStatus(code: "error", message: error.message, severity: .error, alerts: status.alerts,
                                                          detail: join(IppStatusText.explain(error.id), jobs)), offline: false)
            }
            return QueueReading(status: PrinterStatus(code: "paused", message: "Paused in macOS", severity: .warning, alerts: status.alerts,
                                                      detail: "macOS holds print jobs until the printer is resumed (Printers & Scanners › Printer Queue › Resume).\(waiting)"),
                                offline: false)
        }
        if !d.isAcceptingJobs && status.severity != .error {
            return QueueReading(status: PrinterStatus(code: "rejecting", message: "Not accepting jobs", severity: .warning, alerts: status.alerts,
                                                      detail: "macOS turns new print jobs away for this printer until it accepts them again.\(waiting)"),
                                offline: false)
        }
        status.detail = join(status.detail, jobs)
        return QueueReading(status: status, offline: false)
    }

    private static func join(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Supply levels as cupsd last heard them from the printer (`marker-*`; none for a queue that hasn't printed lately).
    public static func supplies(_ d: CupsDestination) -> [Consumable] { IppClient.toConsumables(d.asIpp) }
}

extension CupsStatus {
    /// What the printer pane and the list show for a queue printer: its queue's state, the supply levels cupsd has, and
    /// how this Mac reaches it.
    public static func view(_ d: CupsDestination) -> PrinterView {
        let r = describe(d)
        return PrinterView(phase: r.offline ? .offline : .online, statusMessage: r.status.message, statusDetail: r.status.detail,
                           severity: r.status.severity, alerts: r.status.alerts, supplies: supplies(d), usage: nil, model: d.makeAndModel,
                           interfaces: [CupsQueues.connectionDetail(d)], firmware: nil, location: d.location)
    }

    /// For the menu bar's alerts.
    public static func snapshot(_ d: CupsDestination, id: String) -> PrinterSnapshot {
        let r = describe(d)
        return PrinterSnapshot(uuid: id, name: d.displayName, reachable: !r.offline, status: r.offline ? nil : r.status, supplies: supplies(d))
    }
}

/// macOS's print queues: libcups in PrintMac, made up in demo mode.
public protocol PrintQueues: Sendable {
    /// The CUPS destinations, with the jobs waiting in each; nil when cupsd can't be asked.
    func destinations() async -> [CupsDestination]?

    /// The jobs in a queue that aren't finished; nil when cupsd can't be asked.
    func jobs(_ queue: String) async -> [QueueJob]?

    /// Cancels a job (CUPS lets anyone cancel their own; others' need an administrator). Throws `PrintJobCancelError`.
    func cancel(_ queue: String, job: Int) async throws

    /// Who this Mac's user is to CUPS (`job-originating-user-name` of their jobs).
    var user: String { get }
}

/// A job couldn't be cancelled; `message` says why in plain words.
public struct PrintJobCancelError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Made-up queues (demo mode, tests): the destinations as given, with jobs that can be cancelled (in memory only).
public final class FixedQueues: PrintQueues {
    public let list: [CupsDestination]
    public let user: String
    private let held: Shared<[String: [QueueJob]]>

    public init(_ list: [CupsDestination], jobs: [String: [QueueJob]] = [:], user: String = "you") {
        self.list = list
        self.user = user
        held = Shared(jobs)
    }

    public func destinations() async -> [CupsDestination]? {
        let jobs = held.withLock { $0 }
        return list.map { d in
            var d = d
            if let j = jobs.first(where: { $0.key.caseInsensitiveCompare(d.name) == .orderedSame })?.value { d.jobs = j.count }
            return d
        }
    }

    public func jobs(_ queue: String) async -> [QueueJob]? {
        held.withLock { h in h.first { $0.key.caseInsensitiveCompare(queue) == .orderedSame }?.value ?? [] }
    }

    public func cancel(_ queue: String, job: Int) async throws {
        let user = user
        let refused: PrintJobCancelError? = held.withLock { h in
            guard let key = h.keys.first(where: { $0.caseInsensitiveCompare(queue) == .orderedSame }),
                  let i = h[key]?.firstIndex(where: { $0.id == job }) else { return PrintJobCancelError("It has already finished.") }
            guard QueueJobText.isOwner(h[key]![i].owner, user) else { return PrintJobCancelError("Only an administrator can cancel someone else's job.") }
            h[key]!.remove(at: i)
            return nil
        }
        if let refused { throw refused }
    }
}
