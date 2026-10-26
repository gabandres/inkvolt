/// One read of a printer's state (`PrinterConnection.read`): its status, supply levels and usage counters, each from the
/// first of its interfaces that can give it.
public struct PrinterReading: Equatable, Sendable {
    /// `.offline` when the printer didn't answer; `.unavailable` when it answered with errors or garbage (it is waking up or
    /// busy: keep the last good status on screen).
    public var status: PrinterStatus

    /// Nil when they couldn't be read this time (keep the last known levels); empty when the printer reports none.
    public var supplies: [Consumable]?

    /// Lifetime counters (HP's LEDM only); nil when the printer has none or they couldn't be read.
    public var usage: UsageCounters?

    public var isOffline: Bool { status.code == "offline" }
}

/// The parts of a `PrinterReading` a caller wants (only those are asked of the printer).
struct ReadParts: OptionSet, Sendable {
    let rawValue: Int
    static let status = ReadParts(rawValue: 1)
    static let supplies = ReadParts(rawValue: 2)
    static let usage = ReadParts(rawValue: 4)
    static let all: ReadParts = [.status, .supplies, .usage]
}

/// How one part's read settled.
enum Outcome<T: Sendable>: Sendable {
    /// The interface gave it.
    case value(T)
    /// The interface hasn't it ("not supported").
    case none
    /// The interface answered with an error or garbage (`DeviceFailure.isTransient`).
    case missed
    /// No answer (`DeviceFailure.isOffline`).
    case offline

    /// The part's read, settled. Cancellation and other errors propagate.
    static func of(_ read: () async throws -> T?) async throws -> Outcome<T> {
        do {
            return try await read().map(Outcome.value) ?? .none
        } catch let error where DeviceFailure.isOffline(error) {
            return .offline
        } catch let error where DeviceFailure.isTransient(error) {
            return .missed
        }
    }

    func map<U>(_ f: (T) -> U?) -> Outcome<U> {
        switch self {
        case .value(let v): f(v).map(Outcome<U>.value) ?? .none
        case .none: .none
        case .missed: .missed
        case .offline: .offline
        }
    }

    var got: T? { if case .value(let v) = self { v } else { nil } }
}

/// What one interface gave for the parts it was asked (nil: it hasn't that part, or it wasn't asked).
struct SourceRead: Sendable {
    var status: Outcome<PrinterStatus>?
    var supplies: Outcome<[Consumable]>?
    var usage: Outcome<UsageCounters>?
}

/// One of a connection's interfaces as the printer status module sees it: an adapter over its protocol client.
protocol ReadingSource: Sendable {
    /// Reads the parts asked for that this interface has.
    func read(_ parts: ReadParts) async throws -> SourceRead

    /// One small read of the UUID this interface reports; nil when it has no UUID.
    var uuidRead: (@Sendable () async throws -> String?)? { get }
}

extension ReadingSource {
    var uuidRead: (@Sendable () async throws -> String?)? { nil }
}

/// The printer status module: the one fallback order (LEDM, then CDM, then IPP, then SNMP; eSCL too for the UUID) and the
/// one error rule over a connection's interfaces.
/// - An interface that hasn't a part passes it to the next.
/// - An interface that answers with an error or garbage passes it to the next too; when none gives it, status is
///   unavailable and supplies unknown.
/// - A network failure reading status ends the read: the next interface is the same host, so nothing more is asked (no
///   stack of timeouts), and status is offline. One reading supplies leaves them unknown (not asked of the next interface)
///   and ends nothing: status alone decides online or offline.
/// - Usage counters are extra: when they fail they are just missing.
struct PrinterReader: Sendable {
    let sources: [any ReadingSource]

    func read(_ parts: ReadParts) async throws -> PrinterReading {
        var status: PrinterStatus?
        var supplies: [Consumable]?
        var usage: UsageCounters?
        var statusMissed = false, suppliesMissed = false, offline = false
        var need = parts
        for source in sources {
            if need.isEmpty { break }
            let r = try await source.read(need)
            if let v = r.status?.got {
                status = v
                need.remove(.status)
            }
            if let v = r.supplies?.got {
                supplies = v
                need.remove(.supplies)
            }
            if let v = r.usage?.got {
                usage = v
                need.remove(.usage)
            }
            if case .missed? = r.status { statusMissed = true }
            switch r.supplies {
            case .missed?, .offline?: suppliesMissed = true
            default: break
            }
            if case .offline? = r.status { // status decides: the printer isn't there
                offline = true
                break
            }
            // Supplies that timed out aren't asked of the next interface (the same host), but they end nothing.
            if case .offline? = r.supplies { need.remove(.supplies) }
        }
        let gone = PrinterStatus.offline("Printer is not responding")
        if status == nil && offline { return PrinterReading(status: gone, supplies: nil, usage: nil) } // nothing else counts
        return PrinterReading(
            status: status ?? (offline ? gone
                : statusMissed ? .unavailable("The printer is busy; status will update shortly")
                : PrinterStatus(code: "unknown", message: "Status not available", severity: .info, alerts: [])),
            supplies: supplies ?? (offline || suppliesMissed ? nil : []),
            usage: usage)
    }

    /// The UUID the device reports now, from the first interface that tells (same rule: errors pass to the next interface,
    /// a network failure stops). Empty when none told.
    func readUuids() async throws -> [String] {
        for source in sources {
            guard let read = source.uuidRead else { continue }
            let outcome = try await Outcome.of(read)
            if let uuid = outcome.got, !uuid.isEmpty { return [uuid] }
            if case .offline = outcome { break }
        }
        return []
    }
}

// MARK: - The interfaces

/// HP's LEDM: status, consumables and usage, three small documents read at the same time. The usage document serves both
/// the counters and the consumables' page estimates (read once); when it fails the estimates are just missing.
struct LedmSource: ReadingSource {
    let client: LedmClient

    func read(_ parts: ReadParts) async throws -> SourceRead {
        let client = self.client
        let wantsSupplies = parts.contains(.supplies)
        let usageDocument = wantsSupplies || parts.contains(.usage)
            ? Task { try await client.get(LedmResource.productUsageDyn) } : nil
        async let status: Outcome<PrinterStatus>? = parts.contains(.status) ? Outcome.of { try await client.status() } : nil
        async let supplies: Outcome<[Consumable]>? = wantsSupplies ? Outcome.of { () async throws -> [Consumable]? in
            let consumables = try await client.get(LedmResource.consumableConfigDyn)
            let counters: XmlElement? = (try? await usageDocument?.value) ?? nil
            return consumables.map { LedmParsers.parseConsumables($0, usage: counters) }
        } : nil
        async let usage: Outcome<UsageCounters>? = parts.contains(.usage) ? Outcome.of { () async throws -> UsageCounters? in
            guard let document = try await usageDocument?.value else { return nil }
            return LedmParsers.parseUsage(document)
        } : nil
        return try await SourceRead(status: status, supplies: supplies, usage: usage)
    }

    var uuidRead: (@Sendable () async throws -> String?)? {
        let client = self.client
        return { try await client.productInfo()?.uuid }
    }
}

/// HP's CDM: status, then supplies, one after the other (CDM printers time out under bursts). An empty supplies list counts
/// as none, so the next interface is asked.
struct CdmSource: ReadingSource {
    let client: CdmClient

    func read(_ parts: ReadParts) async throws -> SourceRead {
        var result = SourceRead()
        if parts.contains(.status) { result.status = try await Outcome.of { try await client.status() } }
        if parts.contains(.supplies) {
            if case .offline? = result.status {
                result.supplies = .offline
            } else {
                result.supplies = try await Outcome.of {
                    guard let supplies = try await client.supplies(), !supplies.isEmpty else { return nil }
                    return supplies
                }
            }
        }
        return result
    }

    var uuidRead: (@Sendable () async throws -> String?)? {
        let client = self.client
        return { try await client.identity()?.uuid }
    }
}

/// IPP: status and supplies both from one Get-Printer-Attributes request.
struct IppSource: ReadingSource {
    let client: IppClient

    func read(_ parts: ReadParts) async throws -> SourceRead {
        guard !parts.isDisjoint(with: [.status, .supplies]) else { return SourceRead() }
        let attributes = try await Outcome.of { try await client.printerAttributes() }
        return SourceRead(status: parts.contains(.status) ? attributes.map(IppClient.toStatus) : nil,
                          supplies: parts.contains(.supplies) ? attributes.map(IppClient.toConsumables) : nil)
    }

    var uuidRead: (@Sendable () async throws -> String?)? {
        let client = self.client
        return { try await client.printerAttributes().str("printer-uuid") }
    }
}

/// SNMP (Printer MIB): status and supplies from one walk (the client shares a read made moments ago). No UUID.
struct SnmpSource: ReadingSource {
    let client: SnmpPrinterClient

    func read(_ parts: ReadParts) async throws -> SourceRead {
        guard !parts.isDisjoint(with: [.status, .supplies]) else { return SourceRead() }
        let reading = try await Outcome.of { try await client.read() }
        return SourceRead(status: parts.contains(.status) ? reading.map(SnmpPrinterStatus.toStatus) : nil,
                          supplies: parts.contains(.supplies) ? reading.map(SnmpPrinterStatus.toConsumables) : nil)
    }
}

/// eSCL: only the UUID its capabilities carry (a scanner reports no printer status).
struct EsclSource: ReadingSource {
    let client: EsclClient

    func read(_ parts: ReadParts) async throws -> SourceRead { SourceRead() }

    var uuidRead: (@Sendable () async throws -> String?)? {
        let client = self.client
        return { try await client.capabilities()?.uuid }
    }
}
