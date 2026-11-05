import Foundation

/// What `FleetReader` reads a Mac's printers through (the Windows app's `IFleetPc`): the app's own (PrintMac's libcups,
/// ImageCaptureCore and this Mac's network), demo mode's made-up Mac (`DemoFleetMac`), or a test's.
public protocol FleetMac: Sendable {
    /// The printers Inkvolt Print remembers, as its state file has them.
    var remembered: [KnownPrinter] { get }

    /// Queues and scanners the user removed from the list: they stay out of the fleet too.
    var forgotten: [String] { get }

    /// The UUIDs the user accepted for a printer ("This is my printer").
    func accepted(_ id: String) -> [String]

    /// The firmware version the firmware watch last saw on a printer, for one that doesn't answer.
    func firmware(_ id: String) -> String?

    /// How to reach a remembered printer. Its certificate pins are read only (`ReadOnlyPin`): this read writes nothing.
    func recipe(_ printer: KnownPrinter) -> PrinterRecipe

    /// macOS's CUPS destinations; nil when cupsd can't be asked.
    func destinations() async throws -> [CupsDestination]?

    /// macOS's USB scanners (ImageCaptureCore); nil when they couldn't be listed.
    func scanners() async throws -> [SystemScanner]?

    /// The supply history, for what a silent printer last said. Only read.
    var history: SupplyHistoryStore? { get }
}

/// A printer's certificate pins as stored, never changed: a certificate seen for the first time is taken for this read only
/// (a read of every printer for `status --all` writes no state).
public struct ReadOnlyPin: CertificatePin {
    private let stored: any CertificatePin

    public init(_ stored: any CertificatePin) { self.stored = stored }

    public func get(_ port: Int) -> String? { stored.get(port) }

    public func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String { stored.get(port) ?? sha256Hex }
}

/// One read of every printer the printer list would show (`PrinterList` decides, as for the sidebar), for `status --all`
/// (the Windows app's `FleetReader`). Read only: it writes no state, history or pin, so it runs beside the app. A printer gets
/// `printerLimit` and then reads as not answering, whatever its read is doing (a printer gone mid-read, a reply that never
/// ends); `atOnce` are read at a time, so forty silent printers take a couple of minutes at most and each holds up only its
/// own row. Identity before data holds: another device at a printer's address is never read under its name
/// (`PrinterSession`). Mac differences: a queue's state and levels come with cupsd's list of destinations (one call, bounded
/// as a whole), not a read per queue; a USB scanner macOS lists is ready to scan (no ImageCaptureCore session is opened).
public enum FleetReader {
    public static let printerLimit: Duration = .seconds(30)
    public static let atOnce = 8

    static let noAnswerInTime = "It didn't answer in time"
    static let couldntRead = "Inkvolt Print couldn't read it"
    static let differentDevice = "A different device answers at this address"
    static let cantReach = "Can't reach the printer"
    static let readyToScan = "Ready to scan"
    static let queuesNote = "macOS's printers couldn't be read, so printers known only to macOS aren't listed."
    static let scannersNote = "macOS's scanners couldn't be read, so scanners on their own aren't listed."

    public static func readAll(_ mac: any FleetMac, now: Date, limit: Duration = printerLimit) async throws -> FleetRead {
        let remembered = mac.remembered
        let listed = remembered.map { p in
            ListedPrinter(id: p.uuid, kind: .network, name: p.name, model: p.model, hosts: [p.host], acceptedUuids: mac.accepted(p.uuid))
        }
        var notes: [String] = []
        // Asked at the same time: two lists that don't answer cost one limit.
        async let queuesRead = whole(limit) { try await mac.destinations() }
        async let scannersRead = whole(limit) { try await mac.scanners() }
        let (destinations, scanners) = await (queuesRead, scannersRead)
        try Task.checkCancellation()
        if destinations == nil { notes.append(queuesNote) }
        if scanners == nil { notes.append(scannersNote) }
        var input = PrinterListInput(listed: listed, selected: nil, destinations: destinations, sweepDone: true, forgotten: mac.forgotten)
        input.scanners = scanners
        let change = PrinterList.reconcile(input)

        var reads: [@Sendable () async -> FleetPrinter] = []
        for p in remembered {
            reads.append { await bounded(limit, silent: { silent(p, mac, noAnswerInTime) }, read: { try await readNetwork(p, mac, now) }) }
        }
        for d in change.addedQueues {
            let facts = queue(d, now)
            reads.append { FleetPrinter.of(facts) }
        }
        for s in change.addedScanners {
            let facts = scanner(s, now)
            reads.append { FleetPrinter.of(facts) }
        }
        let printers = await inTurn(reads)
        try Task.checkCancellation()
        return FleetRead(FleetOrder.sort(printers), notes)
    }

    /// Runs `reads` `atOnce` at a time; each one is bounded already, so this ends in time.
    private static func inTurn(_ reads: [@Sendable () async -> FleetPrinter]) async -> [FleetPrinter] {
        await withTaskGroup(of: (Int, FleetPrinter).self) { group in
            var results = [FleetPrinter?](repeating: nil, count: reads.count)
            var next = 0
            while next < min(atOnce, reads.count) {
                let i = next, read = reads[i]
                group.addTask { (i, await read()) }
                next += 1
            }
            while let (i, printer) = await group.next() {
                results[i] = printer
                if next < reads.count {
                    let j = next, read = reads[j]
                    group.addTask { (j, await read()) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// A list read as a whole (cupsd's, ImageCaptureCore's): nil when it fails or doesn't answer in `limit`.
    private static func whole<T: Sendable>(_ limit: Duration, _ read: @escaping @Sendable () async throws -> [T]?) async -> [T]? {
        let result: [T]?? = await race(limit, timedOut: { nil }) { (try? await read()) ?? nil }
        return result ?? nil
    }

    /// One printer's read, given up after `limit`: then it reads as not answering (`silent`); a read that throws reads as one
    /// Inkvolt Print couldn't read, never with the error's words.
    static func bounded(_ limit: Duration, silent: @escaping @Sendable () -> FleetFacts,
                        read: @escaping @Sendable () async throws -> FleetFacts) async -> FleetPrinter {
        let facts = await race(limit, timedOut: silent) {
            do {
                return try await read()
            } catch is CancellationError {
                return silent()
            } catch {
                var f = silent()
                f.status = .offline(couldntRead)
                return f
            }
        }
        return FleetPrinter.of(facts)
    }

    /// `work`'s result, or `timedOut()`'s once `limit` passes or the caller is cancelled, whichever comes first. The work runs
    /// in a task of its own, cancelled when it isn't waited for any longer: a read that ignores cancellation can't hold the
    /// caller. `timedOut` runs only when its answer is the one given (a silent row reads the supply history from disk).
    static func race<T: Sendable>(_ limit: Duration, timedOut: @escaping @Sendable () -> T, _ work: @escaping @Sendable () async -> T) async -> T {
        let finish = Finish<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                finish.wait(continuation)
                let running = Task.detached { finish.give(await work()) }
                let timer = Task.detached {
                    guard (try? await Task.sleep(for: limit)) != nil else { return } // cancelled: the work answered
                    finish.give(timedOut)
                }
                finish.onEnd {
                    running.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            finish.give(timedOut)
        }
    }

    // MARK: Network printers

    private static func readNetwork(_ p: KnownPrinter, _ mac: any FleetMac, _ now: Date) async throws -> FleetFacts {
        let accepted = mac.accepted(p.uuid)
        let session = PrinterSession(id: p.uuid, recipe: mac.recipe(p), accepted: { accepted }, acceptUuids: { _ in })
        let target = p.target
        let step = try await session.connect(target)
        if case .elsewhere = step { return elsewhere(p) }
        guard case .connected(let conn, _) = step else { return silent(p, mac, cantReach) }
        let reading: PrinterReading
        switch try await session.read(target) {
        case .read(let r): reading = r
        case .elsewhere: return elsewhere(p)
        case .offline, .connected: return silent(p, mac, cantReach) // read gives neither today; never "a different device"
        }
        if reading.isOffline { return silent(p, mac, cantReach) }
        let known = reading.supplies == nil || reading.usage == nil ? lastKnown(p.uuid, mac) : nil
        var f = FleetFacts(p.uuid, conn.probe.product?.makeAndModel ?? p.name, .network)
        f.model = conn.probe.model ?? p.model
        f.connection = FleetConnection.interfaces(conn.probe.interfaces)
        f.reachable = true
        f.status = reading.status
        f.supplies = reading.supplies ?? known?.supplies ?? []
        f.pages = reading.usage?.totalImpressions ?? known?.pages
        f.firmware = conn.probe.firmware.flatMap { $0.display.isEmpty ? nil : $0.display } ?? mac.firmware(p.uuid)
        f.lastReading = now
        f.oldSupplies = reading.supplies == nil
        let oldSupplies = reading.supplies == nil && known?.supplies.isEmpty == false
        f.lastKnown = oldSupplies || (reading.usage?.totalImpressions == nil && known?.pages != nil)
        return f
    }

    /// Another device answers at the address: nothing of it, and nothing kept that could be taken for it.
    private static func elsewhere(_ p: KnownPrinter) -> FleetFacts {
        var f = FleetFacts(p.uuid, p.name, .network)
        f.model = p.model
        f.status = .offline(differentDevice)
        return f
    }

    private static func silent(_ p: KnownPrinter, _ mac: any FleetMac, _ why: String) -> FleetFacts {
        let known = lastKnown(p.uuid, mac)
        var f = FleetFacts(p.uuid, p.name, .network)
        f.model = p.model
        f.status = .offline(why)
        f.supplies = known?.supplies ?? []
        f.pages = known?.pages
        f.firmware = mac.firmware(p.uuid)
        f.lastReadingDay = known?.day
        f.lastKnown = known != nil || f.firmware != nil
        return f
    }

    private static func lastKnown(_ id: String, _ mac: any FleetMac) -> FleetLastKnown? {
        mac.history.flatMap { FleetLastKnown.from($0.rows(id)) }
    }

    // MARK: Queues and scanners

    /// A queue printer, as cupsd listed it: its state, its levels (`marker-*`) and how it's connected, without the server's
    /// or port's name.
    static func queue(_ d: CupsDestination, _ now: Date) -> FleetFacts {
        let reading = CupsStatus.describe(d)
        var f = FleetFacts(CupsQueues.id(for: d.name), d.displayName, .queue)
        f.model = d.makeAndModel
        f.connection = connectionWord(CupsQueues.connection(d))
        f.reachable = !reading.offline
        f.status = reading.status
        f.supplies = CupsStatus.supplies(d)
        f.lastReading = reading.offline ? nil : now
        return f
    }

    static func scanner(_ s: SystemScanner, _ now: Date) -> FleetFacts {
        var f = FleetFacts(ScannerMatch.id(for: s), s.name, .scanner)
        f.connection = "USB scanner"
        f.reachable = true
        f.status = PrinterStatus(code: "ready", message: readyToScan, severity: .info, alerts: [])
        f.lastReading = now
        return f
    }

    /// How a queue is connected, in words (`FleetConnection`).
    public static func connectionWord(_ c: QueueConnection) -> String {
        switch c {
        case .usb: FleetConnection.usb
        case .network: FleetConnection.network
        case .shared: FleetConnection.shared
        case .other: FleetConnection.other
        }
    }
}

/// The first of several answers wins; the rest are dropped. The continuation is resumed once, whichever comes first: an
/// answer before the continuation is set is kept for it.
private final class Finish<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Never>?
        var result: T?
        var done = false
        var end: (@Sendable () -> Void)?
    }

    private let state = Shared(State())

    func wait(_ continuation: CheckedContinuation<T, Never>) {
        let early: T? = state.withLock { s in
            if let r = s.result, !s.done {
                s.done = true
                return r
            }
            s.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func give(_ value: T) { give { value } }

    /// `make` runs only when its answer is wanted: none came first.
    func give(_ make: () -> T) {
        guard state.withLock({ !$0.done && $0.result == nil }) else { return }
        let value = make()
        let (c, end): (CheckedContinuation<T, Never>?, (@Sendable () -> Void)?) = state.withLock { s in
            guard !s.done, s.result == nil else { return (nil, nil) }
            guard let c = s.continuation else {
                s.result = value
                return (nil, nil)
            }
            s.done = true
            s.continuation = nil
            return (c, s.end)
        }
        c?.resume(returning: value)
        end?()
    }

    /// Runs `body` when an answer is in (at once if one is).
    func onEnd(_ body: @escaping @Sendable () -> Void) {
        let now: Bool = state.withLock { s in
            if s.done { return true }
            s.end = body
            return false
        }
        if now { body() }
    }
}
