import Foundation

/// Where a queue printer's supply levels and problems came from, beside macOS's own status of the queue (the Windows app's
/// `QueueReadingFrom`; its third route, a maker's driver over Windows' bidi, has no Mac counterpart).
public enum QueueReadingFrom: Equatable, Sendable {
    /// The printer itself over IPP, connected by USB (CUPS's IPP over USB, or a local relay to it).
    case printerOverUsb
    /// The printer itself over IPP on the network (a queue nobody added as a network printer).
    case printerOverNetwork
}

/// What a queue printer said: supply levels, and a status when it has one. Nil `status`: alerts only, in `alerts`.
public struct QueueDeviceReading: Equatable, Sendable {
    public var from: QueueReadingFrom
    public var status: PrinterStatus?
    public var alerts: [PrinterAlert]
    public var supplies: [Consumable]

    public init(from: QueueReadingFrom, status: PrinterStatus?, alerts: [PrinterAlert], supplies: [Consumable]) {
        self.from = from
        self.status = status
        self.alerts = alerts
        self.supplies = supplies
    }

    /// It said anything worth showing.
    public var saysAnything: Bool { status != nil || !alerts.isEmpty || !supplies.isEmpty }
}

/// One way of asking a queue's printer more than its queue says: PrintMac's IPP request to the queue's printer
/// (`IppQueueReading.route` says which queues and how; `IppQueueReading.from` reads the reply). Read-only. Nil, or a throw,
/// when the queue has no such route or the printer doesn't answer: asked again much later, never an error.
public protocol QueueDeviceReader: Sendable {
    func read() async throws -> QueueDeviceReading?
}

/// One read of a queue printer as macOS has it (the Windows app's `QueueStatusRead`): its status, whether macOS can reach
/// it, the levels cupsd last heard (`marker-*`; often none, or old, for a queue that hasn't printed lately), and the
/// jobs-waiting note an ordinary state carries.
public struct QueueStatusRead: Equatable, Sendable {
    public var status: PrinterStatus
    public var offline: Bool
    public var supplies: [Consumable]
    public var jobsNote: String?

    public init(status: PrinterStatus, offline: Bool, supplies: [Consumable], jobsNote: String? = nil) {
        self.status = status
        self.offline = offline
        self.supplies = supplies
        self.jobsNote = jobsNote
    }

    public static func of(_ d: CupsDestination) -> QueueStatusRead {
        let r = CupsStatus.describe(d)
        return QueueStatusRead(status: r.status, offline: r.offline, supplies: CupsStatus.supplies(d), jobsNote: CupsStatus.jobsNote(d))
    }
}

/// A queue printer whose printer may report more than its queue (the Windows app's `DeviceQueueStatusSource`): readers are
/// asked in order, the first that answers wins, and what it said is merged into macOS's read of the queue
/// (`QueueDevice.merge`). Each call is time-limited (`limit`); a reader that answers is asked again after `readInterval`, one
/// that has nothing (unsupported, timed out, failed) after `nothingInterval`, so a queue whose printer never answers costs
/// one try every few minutes. The last reading stands for a read in between. Two Mac differences (Windows' source is read
/// by one caller at a time and drops its reading on the first miss): reads that overlap share one round of questions (an
/// actor lets the second in while the first waits on the printer), and a round with nothing keeps the last reading while
/// it's younger than `keptFor`, asking again after `readInterval`, so one timeout doesn't blank the card for five minutes.
public actor DeviceQueueStatus {
    public static let readInterval: TimeInterval = 30
    public static let nothingInterval: TimeInterval = 5 * 60
    public static let keptFor: TimeInterval = 2 * 60
    public static let callLimit: Duration = .seconds(8)

    private let readers: [any QueueDeviceReader]
    private let now: @Sendable () -> Date
    private let limit: Duration
    private var last: QueueDeviceReading?
    /// When `last` was read.
    private var lastAt = Date.distantPast
    private var next = Date.distantPast
    private var inFlight: Task<Void, Never>?
    private var macOSHadSupplies = false

    /// `now` and `limit`: a clock and a shorter time per call, for tests.
    public init(readers: [any QueueDeviceReader], now: @escaping @Sendable () -> Date = { Date() }, limit: Duration = callLimit) {
        self.readers = readers
        self.now = now
        self.limit = limit
    }

    /// Where the last reading came from; nil: no reader answered (yet).
    public var from: QueueReadingFrom? { last?.from }

    /// For the status card's "Status and supply levels from …".
    public var origin: String { last.map { QueueDeviceText.origin($0.from) } ?? QueueDeviceText.macOSOrigin }

    public var hasSupplyLevels: Bool { last.map { !$0.supplies.isEmpty } == true || macOSHadSupplies }

    /// The supplies card's source line for `read` (this source's last result): where the printer's own levels came from;
    /// "Not reported by this printer." for a queue that's online with none; nil for cupsd's own copy or an offline queue.
    public func suppliesSource(_ read: QueueStatusRead) -> String? {
        QueueDeviceText.suppliesSource(read, from: last.flatMap { $0.supplies.isEmpty ? nil : $0.from })
    }

    /// The queue now without asking the printer: `macOS`'s read with the last reading, its origin and supplies line, so the
    /// card shows macOS's state at once while a round (up to `callLimit`) is out; `read` then gives the printer's answer.
    public func current(_ macOS: QueueStatusRead) -> (read: QueueStatusRead, origin: String, source: String?) {
        let read = last.map { QueueDevice.merge(macOS, $0) } ?? macOS
        return (read, origin, suppliesSource(read))
    }

    /// The queue now: `macOS`'s read with what the printer said. Nil when macOS no longer has the queue (removed meanwhile),
    /// and then nothing is asked.
    public func read(_ macOS: QueueStatusRead?) async -> QueueStatusRead? {
        guard let macOS else { return nil }
        macOSHadSupplies = !macOS.supplies.isEmpty
        let at = now()
        if let inFlight {
            await inFlight.value
        } else if at >= next {
            let round = Task { await self.askReaders(at) }
            inFlight = round
            await round.value
        }
        return last.map { QueueDevice.merge(macOS, $0) } ?? macOS
    }

    /// One round: the readers in order until one answers.
    private func askReaders(_ at: Date) async {
        defer { inFlight = nil }
        for reader in readers {
            if let r = await ask(reader), r.saysAnything {
                (last, lastAt, next) = (r, at, at.addingTimeInterval(Self.readInterval))
                return
            }
        }
        if last != nil && at.timeIntervalSince(lastAt) < Self.keptFor {
            next = at.addingTimeInterval(Self.readInterval) // kept: ask again soon
        } else {
            (last, next) = (nil, at.addingTimeInterval(Self.nothingInterval))
        }
    }

    private func ask(_ reader: any QueueDeviceReader) async -> QueueDeviceReading? {
        await FleetReader.race(limit, timedOut: { nil }) {
            do {
                return try await reader.read()
            } catch {
                return nil // failed: nothing this time
            }
        }
    }
}

/// How macOS's status of a queue and what its printer said make one (the Windows app's `QueueDevice` and
/// `QueueSnmp.MergeStatus`).
public enum QueueDevice {
    /// Supplies are the reading's when it has any, else cupsd's. macOS holding the jobs (paused, not accepting jobs, the
    /// queue stopped on an error) or not reaching the printer stays the headline, with the reading's problems added under it;
    /// otherwise the printer's own IPP status leads, with macOS's jobs-waiting note. A reading taken while macOS says the
    /// printer is offline keeps the offline headline, and its supplies show as the last known.
    public static func merge(_ macOS: QueueStatusRead, _ reading: QueueDeviceReading) -> QueueStatusRead {
        let supplies = reading.supplies.isEmpty ? macOS.supplies : reading.supplies
        let w = macOS.status
        if let printer = reading.status, !macOS.offline {
            if heldByMacOS(w) { return QueueStatusRead(status: adding(printer.alerts, to: w), offline: false, supplies: supplies, jobsNote: macOS.jobsNote) }
            var status = printer
            status.detail = join(printer.detail, macOS.jobsNote)
            return QueueStatusRead(status: status, offline: false, supplies: supplies, jobsNote: macOS.jobsNote)
        }
        let extra = (reading.status?.alerts ?? []) + reading.alerts
        return QueueStatusRead(status: adding(extra, to: w, explain: true), offline: macOS.offline, supplies: supplies, jobsNote: macOS.jobsNote)
    }

    /// `w` with the problems it doesn't say yet, at the worst severity; `explain`: a worse problem's words lead the detail.
    private static func adding(_ extra: [PrinterAlert], to w: PrinterStatus, explain: Bool = false) -> PrinterStatus {
        var alerts: [PrinterAlert] = []
        for a in w.alerts + extra where !alerts.contains(where: { $0.id == a.id }) && !(a.id == "paused" && w.code == "paused") {
            alerts.append(a)
        }
        let severity = max(alerts.map(\.severity).max() ?? .info, w.severity)
        var status = w
        if explain, severity > w.severity, let top = alerts.first(where: { $0.severity == severity }) {
            status.detail = join(top.message, w.detail)
        }
        status.alerts = alerts
        status.severity = severity
        return status
    }

    /// macOS's own conditions on the queue (`CupsStatus.describe`): it holds the jobs, or turns new ones away.
    private static func heldByMacOS(_ w: PrinterStatus) -> Bool { ["paused", "rejecting", "error"].contains(w.code) }

    private static func join(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

/// The words for where a reading came from (in the status card's "Status and supply levels from …").
public enum QueueDeviceText {
    public static func origin(_ from: QueueReadingFrom) -> String {
        switch from {
        case .printerOverUsb: loc("the printer over USB (IPP)")
        case .printerOverNetwork: loc("the printer over IPP")
        }
    }

    /// Short, for the supplies card and the fleet: "From the printer over USB".
    public static func source(_ from: QueueReadingFrom) -> String {
        switch from {
        case .printerOverUsb: loc("From the printer over USB")
        case .printerOverNetwork: loc("From the printer")
        }
    }

    /// The origin when no printer answered: the queue as macOS has it.
    public static var macOSOrigin: String { loc("macOS's print queue") }

    /// The supplies card of a queue printer that's online with no levels from anywhere.
    public static var notReported: String { loc("Not reported by this printer.") }

    /// The supplies card's source line for `read`: `from`, where the printer's own levels came from (nil: none, so the levels
    /// shown are cupsd's copy, with no line); "Not reported by this printer." for a queue that's online with none at all; nil
    /// for an offline one. For a queue printer with no reader as for one with.
    public static func suppliesSource(_ read: QueueStatusRead, from: QueueReadingFrom?) -> String? {
        if read.supplies.isEmpty { return read.offline ? nil : notReported }
        return from.map(source)
    }
}
