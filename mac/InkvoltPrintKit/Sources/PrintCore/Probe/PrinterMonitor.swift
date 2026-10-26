import Foundation

/// What the printer pane and the printer list show for one network printer.
public struct PrinterView: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case connecting, online, offline
        /// Another device answers at the printer's address: nothing of it is shown.
        case elsewhere
    }

    public var phase: Phase
    public var statusMessage: String
    public var statusDetail: String?
    public var severity: Severity
    public var alerts: [PrinterAlert]
    /// The last levels read: a read that couldn't get them keeps these.
    public var supplies: [Consumable]
    public var usage: UsageCounters?
    /// What the printer said about itself when it connected (nil before the first connection).
    public var model: String?
    public var interfaces: [String]
    public var firmware: FirmwareInfo?
    public var location: String?

    public static let connecting = PrinterView(phase: .connecting, statusMessage: "Connecting…", statusDetail: nil, severity: .info, alerts: [],
                                               supplies: [], usage: nil, model: nil, interfaces: [], firmware: nil, location: nil)

    public var isOnline: Bool { phase == .online }

    /// The printer list's line: the state, and for a warning or error the worst alert's words (`PrinterStatus.listLine`).
    public var listLine: String { isOnline ? PrinterStatus.listLine(statusMessage, severity, alerts) : statusMessage }
}

/// What a printer monitor tells the app.
public enum MonitorEvent: Sendable {
    /// The pane's state changed.
    case changed(PrinterView)
    /// Each read, or failure to reach the printer: the menu bar's alerts follow these.
    case observed(PrinterSnapshot)
    /// Connected (or upgraded from SNMP): remember where, and what it is.
    case connected(PrinterWhere, model: String?)
}

/// The printer monitor: keeps one network printer's state current. It connects through the printer's session, reads on the
/// printer's events (LEDM) or every 30 s, asks a printer read over SNMP now and then whether it answers more, retries every
/// 20 s while the printer doesn't answer, and follows an address mDNS announces the printer at once the session says it's
/// this printer. Identity before data holds throughout: the session asks who answers before reading. The Windows app's
/// `PrinterViewModel` connection loop.
public actor PrinterMonitor {
    public static let retryDelay: Duration = .seconds(20)
    public static let fallbackRefresh: Duration = .seconds(30)

    public nonisolated let id: String
    public nonisolated let name: String
    private let session: PrinterSession
    private let onEvent: @Sendable (MonitorEvent) -> Void
    private let retryDelay: Duration
    private let fallbackRefresh: Duration

    /// Where the printer is reached now.
    public private(set) var target: PrinterWhere
    public private(set) var view = PrinterView.connecting

    /// What another device at the address reported (for "This is my printer").
    public private(set) var foreignUuids: [String] = []
    public private(set) var foreignSnmp: SnmpIdentity?

    /// - Parameters:
    ///   - accepted: UUIDs the user confirmed are this printer's; `acceptUuids` adds to them.
    ///   - onEvent: called on the monitor's executor; hand the event off.
    public init(id: String, name: String, target: PrinterWhere, recipe: PrinterRecipe, accepted: @escaping @Sendable () -> [String],
                acceptUuids: @escaping @Sendable ([String]) -> Void, retryDelay: Duration = PrinterMonitor.retryDelay,
                fallbackRefresh: Duration = PrinterMonitor.fallbackRefresh, onEvent: @escaping @Sendable (MonitorEvent) -> Void) {
        self.id = id
        self.name = name
        self.target = target
        self.retryDelay = retryDelay
        self.fallbackRefresh = fallbackRefresh
        self.onEvent = onEvent
        session = PrinterSession(id: id, recipe: recipe, accepted: accepted, acceptUuids: acceptUuids)
    }

    /// Runs until the task is cancelled. `reuse`: a connection still good (watched again without probing).
    public func run(reuse: Bool = false) async {
        var reused = reuse && view.isOnline ? await session.connection : nil
        if reused != nil { await session.askIdentityFirst() } // time passed: the reused connection is asked who it is first
        while !Task.isCancelled {
            do {
                var conn = reused
                reused = nil
                if conn == nil {
                    guard try await connect() else {
                        try await Task.sleep(for: retryDelay)
                        continue
                    }
                    conn = await session.connection
                }
                guard let conn else { continue }
                for await _ in conn.watch(fallbackInterval: fallbackRefresh) {
                    switch try await session.tryUpgrade(target) { // asks who answers first
                    case .elsewhere(let uuids, let snmp)?:
                        setElsewhere(uuids, snmp)
                    case .connected(let richer, _)?:
                        target.snmp = nil // not an SNMP-only printer any more
                        target.esclHint = richer.probe.esclRoot ?? target.esclHint
                        attach(richer)
                        reused = richer // watched from here on (its event feed, if it has one)
                    default:
                        break
                    }
                    if view.phase == .elsewhere || reused != nil { break }
                    // Still this printer? The session asks before reading (a reused connection at once, then every 30 s).
                    if !(try await refresh()) { break }
                    // Gone: connect again after a pause, which checks it's still this printer.
                    if !view.isOnline { break }
                }
                try Task.checkCancellation()
                if !view.isOnline && reused == nil { try await Task.sleep(for: retryDelay) }
            } catch is CancellationError {
                return
            } catch {
                setOffline()
                if (try? await Task.sleep(for: retryDelay)) == nil { return }
            }
        }
    }

    /// mDNS announces the printer: hints at the same address are taken; another address is followed only when the session
    /// finds it's this printer, or can't tell and the address in use no longer answers as this kind of printer
    /// (`PrinterSession.checkAddress`). True when the caller should restart `run` (moved, or seen again while offline).
    public func announced(_ found: DiscoveredPrinter) async -> Bool {
        guard let host = found.host else { return false }
        if host.caseInsensitiveCompare(target.host) == .orderedSame {
            if let escl = found.esclRoot { target.esclHint = escl }
            if let ipp = found.ippUri { target.ippHint = ipp }
            return view.phase == .offline // mDNS just saw it again; don't wait for the retry
        }
        let candidate = PrinterWhere(host, esclHint: found.esclRoot, ippHint: found.ippUri)
        guard let check = try? await session.checkAddress(current: target, candidate: candidate, currentAnswers: view.isOnline,
                                                          announcedModel: found.model),
              check == .move, host.caseInsensitiveCompare(target.host) != .orderedSame else { return false }
        target.host = host
        if let escl = found.esclRoot { target.esclHint = escl }
        if let ipp = found.ippUri { target.ippHint = ipp }
        return true
    }

    /// "This is my printer": the device at the address counts as this printer from now on. True when there was one to accept
    /// (the caller restarts `run`).
    public func acceptDevice(_ accept: @Sendable ([String]) -> Void) -> Bool {
        guard view.phase == .elsewhere, !foreignUuids.isEmpty || foreignSnmp != nil else { return false }
        if !foreignUuids.isEmpty { accept(foreignUuids) }
        if let snmp = foreignSnmp { target.snmp = SnmpDevice.from(snmp) }
        foreignUuids = []
        foreignSnmp = nil
        var v = view
        v.phase = .connecting
        v.statusMessage = PrinterView.connecting.statusMessage
        v.statusDetail = nil
        v.severity = .info
        publish(v)
        return true
    }

    // MARK: Steps

    /// Connects through the session. False, with the state set, when nothing answers there or another device does.
    private func connect() async throws -> Bool {
        switch try await session.connect(target) {
        case .connected(let conn, _):
            attach(conn)
            return true
        case .elsewhere(let uuids, let snmp):
            setElsewhere(uuids, snmp)
            return false
        default:
            setOffline()
            return false
        }
    }

    private func attach(_ conn: PrinterConnection) {
        let probe = conn.probe
        var v = view
        v.model = probe.model ?? v.model
        v.interfaces = probe.interfaces
        v.firmware = probe.firmware
        v.location = probe.location
        publish(v)
        if let escl = probe.esclRoot { target.esclHint = escl }
        if let ipp = probe.ippEndpoint { target.ippHint = ipp }
        onEvent(.connected(target, model: probe.model))
    }

    /// One read through the session, shown. False when another device answers at the address now (nothing of it is read).
    private func refresh() async throws -> Bool {
        let step = try await session.read(target)
        if case .elsewhere(let uuids, let snmp) = step {
            setElsewhere(uuids, snmp)
            return false
        }
        guard case .read(let reading) = step else { return true }
        let status = reading.status
        if reading.isOffline {
            setOffline()
            return true
        }
        var v = view
        v.phase = .online
        if !status.isUnavailable {
            // An unusable reply (printer waking up) keeps the last good status instead of flashing an error.
            v.statusMessage = status.message
            v.statusDetail = status.detail
            v.severity = status.severity
            v.alerts = status.alerts
        }
        if let supplies = reading.supplies { v.supplies = supplies } // not read this time: stay as they were
        if let usage = reading.usage { v.usage = usage }
        publish(v)
        onEvent(.observed(PrinterSnapshot(uuid: id, name: name, reachable: true, status: status.isUnavailable ? nil : status,
                                          supplies: reading.supplies)))
        return true
    }

    private func setOffline() {
        setOffline("Can't reach the printer",
                   "Make sure it's turned on and connected to the same network as this Mac (\(target.host)). Inkvolt Print keeps trying in the background.")
    }

    private func setOffline(_ message: String, _ detail: String, phase: PrinterView.Phase = .offline) {
        var v = view
        v.phase = phase
        v.statusMessage = message
        v.statusDetail = detail
        v.severity = .error
        v.alerts = []
        publish(v)
        onEvent(.observed(PrinterSnapshot(uuid: id, name: name, reachable: false, status: nil, supplies: nil)))
    }

    /// Another device answers at the printer's address: the session let go of every connection. Never the UUIDs or serial
    /// numbers in a log.
    private func setElsewhere(_ uuids: [String], _ snmp: SnmpIdentity?) {
        foreignUuids = uuids
        foreignSnmp = snmp
        setOffline("A different device answers at this address",
                   "Another device now has \(target.host), so its status isn't shown here. The printer probably got a new address: "
                       + "Inkvolt Print watches for it on the network. If the printer was repaired or reset and this really is it, "
                       + "choose This is my printer.",
                   phase: .elsewhere)
    }

    private func publish(_ v: PrinterView) {
        guard v != view else { return }
        view = v
        onEvent(.changed(v))
    }
}
