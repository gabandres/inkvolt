import Foundation
import Observation
import PrintCore
import PrintMac
import UserNotifications

/// One printer on the list, for the pane, the list and the menu bar: a network printer (its printer monitor's state) or a
/// queue printer (its CUPS queue's state, read by the app).
@MainActor @Observable
final class PrinterModel: Identifiable {
    let id: String
    private(set) var name: String
    private(set) var model: String?
    /// Where it's reached now (it follows the printer to a new address); a queue printer's address in its device URI, else
    /// how this Mac reaches it ("USB").
    private(set) var host: String
    /// Addresses it was reached at before (it moved), oldest first: its queues may still point there (Windows' previous hosts).
    @ObservationIgnored private(set) var previousHosts: [String] = []
    /// Its Bonjour host name, once discovery saw it (queue matching knows it by that too).
    private(set) var hostName: String?
    /// The IPP URL Bonjour announced (or the one remembered), for setting it up in macOS when its session reads it another way.
    @ObservationIgnored private(set) var ippHint: URL?
    /// The CUPS queue its print jobs go through: a queue printer's own, or the one macOS has for a network printer.
    var queueName: String?
    private(set) var view = PrinterView.connecting
    /// When it last gave a reading (its monitor's, or its queue's), for the Fleet page; a scanner of its own's is the page's now.
    @ObservationIgnored private(set) var lastReading: Date?
    /// A queue printer's queue, as last read.
    private(set) var destination: CupsDestination?
    /// What a queue printer's printer says beyond its queue (roadmap 3.6); nil: macOS's queue only.
    @ObservationIgnored private var deviceStatus: DeviceQueueStatus?
    /// The device URI `deviceStatus`'s readers were made for.
    @ObservationIgnored private var readersFor: String?
    /// Queue reads started: only the newest one's result is shown.
    @ObservationIgnored private var readsStarted = 0

    @ObservationIgnored private let monitor: PrinterMonitor?
    /// Its supply history: a network printer's monitor feeds it, a queue printer's queue levels do (`update`); nil for a
    /// scanner of its own. Kept here so removing the printer forgets it, and a reading in flight then keeps nothing.
    @ObservationIgnored private let history: SupplyHistoryFeed?
    /// A queue printer's readings going into its history off the main thread, one after another.
    @ObservationIgnored private var historyStep: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// The window is closed: the printer is checked now and then instead of watched live.
    @ObservationIgnored private var polling: Task<Void, Never>?

    /// The state file, for what's remembered per printer.
    var store: StateStore { app.store }

    init(known: KnownPrinter, app: AppModel) {
        id = known.uuid
        name = known.name
        model = known.model
        host = known.host
        ippHint = known.ippUri.flatMap { URL(string: $0) }
        readOverSnmp = known.snmp != nil
        self.app = app
        let (stream, continuation) = AsyncStream.makeStream(of: MonitorEvent.self)
        let store = app.store, id = known.uuid
        let history = SupplyHistoryFeed(app.history, id)
        self.history = history
        monitor = PrinterMonitor(id: id, name: known.name, target: known.target, recipe: app.recipe(id), accepted: { store.accepted(id) },
                                 acceptUuids: { [weak app] uuids in
                                     store.accept(id, uuids)
                                     Task { @MainActor in app?.handOffSoon() } // Inkvolt PDF matches queues by them too
                                 }, firmware: store.firmwareMemory(id),
                                 history: history, onEvent: { continuation.yield($0) })
        events = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
    }

    /// A scanner of its own: a USB scanner macOS has a driver for that belongs to no printer on the list.
    init(scanner s: SystemScanner, app: AppModel) {
        id = ScannerMatch.id(for: s)
        name = s.name
        host = "USB"
        self.app = app
        monitor = nil
        history = nil
        systemScanner = s
        view = .scannerReady
    }

    /// A queue printer: known only by its CUPS queue.
    init(queue d: CupsDestination, app: AppModel) {
        id = CupsQueues.id(for: d.name)
        name = d.displayName
        model = d.makeAndModel
        host = CupsQueues.address(d) ?? CupsQueues.connectionText(d)
        self.app = app
        monitor = nil
        history = SupplyHistoryFeed(app.history, id)
        update(d)
    }

    var isQueue: Bool { monitor == nil && systemScanner == nil || destination != nil }

    /// Found on the network or added by address: it has a printer monitor.
    var isNetwork: Bool { monitor != nil }

    /// Added as SNMP-only (it answered none of LEDM, CDM and IPP), and not upgraded since: read over SNMP with its login.
    private(set) var readOverSnmp = false

    /// The printer's menu offers SNMP Access…: a network printer read over SNMP (its community may change). Windows'
    /// `CanSetSnmpLogin`.
    var canSetSnmpLogin: Bool { isNetwork && readOverSnmp }

    /// The SNMP login kept for it now (public when none is).
    var snmpLogin: SnmpLogin { app.snmpLogins.get(id) ?? .public }

    /// The printer's menu › SNMP Access…: the login it's read with, kept in the Keychain (public: nothing kept), then a new
    /// connection with it. False when the Keychain refused (nothing changed).
    func setSnmpLogin(_ chosen: SnmpLogin) -> Bool {
        guard canSetSnmpLogin, chosen != snmpLogin else { return true }
        guard app.snmpLogins.save(chosen, for: id) else { return false }
        if polling == nil { start() } // connects again, with it
        return true
    }

    /// A scanner of its own (no printer, no queue).
    var isScannerOnly: Bool { monitor == nil && destination == nil && systemScanner != nil }

    /// The address Report a Problem can record this printer at (Windows' `RecordHost`); nil: it has none (a scanner of its
    /// own, a queue printer on USB).
    var recordHost: String? {
        if isScannerOnly { return nil }
        if isNetwork { return host }
        return destination.flatMap(CupsQueues.address)
    }

    /// Report a Problem's recording of this printer (Windows' `RecordForReportAsync`): as `record`, through this Mac's
    /// network with each reply bounded (demo mode's: made-up printers), into the app's recordings folder.
    func recordForReport() async throws -> ReportRecordingDone {
        guard let host = recordHost else { throw DeviceNetworkError.failed("This printer has no address to record.") }
        var options = RecordOptions(transport: app.recordingTransport(), snmp: app.snmpTransport)
        options.login = app.snmpLogins.get(id) // asked as its readings are; never written into the recording
        options.esclHint = await monitor?.target.esclHint // Windows' EsclRoot: the eSCL root DNS-SD or a connection found
        options.ippHint = ippHint
        return try await ReportRecording.run(host, parent: app.recordingsFolder, options, now: Date())
    }

    /// A queue printer's (or a scanner of its own's) USB scanner, through ImageCaptureCore.
    var systemScanner: SystemScanner?

    /// The Scan tab's pages and settings, made when the tab first shows (and kept while the app runs).
    @ObservationIgnored private var scanModel: ScanModel?
    var scan: ScanModel {
        if let scanModel { return scanModel }
        let m = ScanModel(printer: self, app: app)
        scanModel = m
        return m
    }

    /// The printer has a scanner (eSCL, or a USB one through macOS), or pages scanned from it wait to be saved.
    var canScan: Bool { view.interfaces.contains("eSCL") || systemScanner != nil || scanModel?.pages.isEmpty == false }

    /// The printer's connection while it's connected as itself (settings, maintenance).
    func connection() async -> PrinterConnection? { await monitor?.connection() }

    /// HP's settings interface answered (LEDM): the Settings tab.
    var hasDeviceSettings: Bool { view.isOnline && view.interfaces.contains("LEDM") }

    /// Scanned pages waiting to be saved.
    var unsavedPages: Int { scanModel?.pages.toSave.count ?? 0 }

    /// Its scanner: the printer's own (eSCL) while it's connected as itself, else its USB scanner.
    func scanner() async -> (any ScanDevice)? {
        if let monitor, let escl = await monitor.scanner() { return escl }
        return systemScanner.flatMap { app.scanDevice(for: $0) }
    }

    /// The queue was read again: macOS's status of it, with what its printer said when a reader can ask it (roadmap 3.6,
    /// `DeviceQueueStatus`: at most every 30 s, every 5 minutes while it doesn't answer; the last reading in between).
    func update(_ d: CupsDestination) {
        destination = d
        queueName = d.name
        name = d.displayName
        model = d.makeAndModel
        if d.deviceUri != readersFor { // new, or re-pointed: the printer to ask is another
            readersFor = d.deviceUri
            let readers = app.queueReaders(for: d)
            deviceStatus = readers.isEmpty ? nil : DeviceQueueStatus(readers: readers)
        }
        let macOS = QueueStatusRead.of(d)
        readsStarted += 1 // every read, so a device read still out for an older one (an old target) shows nothing
        let ticket = readsStarted
        guard let deviceStatus else {
            show(d, macOS, origin: QueueDeviceText.macOSOrigin, source: QueueDeviceText.suppliesSource(macOS, from: nil))
            observing = historyStep
            return
        }
        observing = Task { [weak self] in
            // macOS's state at once, with the printer's last reading: the card doesn't wait on the printer (up to its limit).
            let now = await deviceStatus.current(macOS)
            if let me = self, ticket == me.readsStarted, !me.stopped { // else a newer read is on its way, or it was removed
                me.showCard(d, now.read, origin: now.origin, source: now.source)
            } else {
                return
            }
            let read = await deviceStatus.read(macOS) ?? macOS
            let origin = await deviceStatus.origin
            let source = await deviceStatus.suppliesSource(read)
            guard let self, ticket == self.readsStarted, !self.stopped else { return }
            self.show(d, read, origin: origin, source: source)
            await self.historyStep?.value
        }
    }

    /// The latest queue read's way into the alerts (`update`): over once its snapshot reached the alert tracker. Job alerts
    /// wait for it, so a job is judged with the printer's state from the same read (`AppModel.readJobs`).
    @ObservationIgnored private var observing: Task<Void, Never>?

    /// Once the latest queue read's snapshot reached the alert tracker (at once for a network printer: its monitor's do).
    func observed() async { await observing?.value }

    /// A queue read shown: the card, then its levels into the supply history, then the alert.
    private func show(_ d: CupsDestination, _ read: QueueStatusRead, origin: String, source: String?) {
        let v = showCard(d, read, origin: origin, source: source)
        let snapshot = CupsStatus.snapshot(d, id: id, read: read)
        guard let history else {
            app.observe(snapshot)
            return
        }
        // Its levels kept in the supply history first (CUPS gives no page count), by the rule a network printer's reading
        // follows, and off the main thread as the monitor's are (a file read and written): then the card and the alert.
        let previous = historyStep, supplies = v.supplies
        historyStep = Task.detached { [weak self] in
            await previous?.value
            let shown = history.show(supplies, pages: nil)
            await self?.showHistory(shown, snapshot)
        }
    }

    /// A queue read on the card alone (its history and alert come with `show`).
    @discardableResult
    private func showCard(_ d: CupsDestination, _ read: QueueStatusRead, origin: String, source: String?) -> PrinterView {
        var v = CupsStatus.view(d, read: read, origin: origin, suppliesSource: source)
        if v.isOnline { lastReading = Date() }
        v.supplyHistory = view.supplyHistory // until the history has this reading
        if v != view { view = v }
        return v
    }

    /// A queue reading's history worked out: the card's lines and chart, and the alert's days left.
    private func showHistory(_ shown: SupplyHistoryView?, _ snapshot: PrinterSnapshot) {
        guard !stopped else { return } // removed meanwhile: nothing is shown or alerted
        if let shown, shown != view.supplyHistory { view.supplyHistory = shown }
        var snapshot = snapshot
        snapshot.daysLeft = view.supplyHistory?.daysLeft
        app.observe(snapshot)
    }

    /// Removed from the app: its supply history goes with it, and a reading still in flight keeps nothing.
    func forgetHistory() {
        if let history { history.forget() } else { app.history.forget(id) }
    }

    /// Starts (or restarts) the monitor's connection loop.
    func start() {
        guard let monitor, polling == nil else { return }
        running?.cancel()
        running = Task { await monitor.run() }
    }

    func stop() {
        stopped = true
        historyStep?.cancel()
        running?.cancel()
        running = nil
        polling?.cancel()
        polling = nil
        events?.cancel()
    }

    /// The window closed: the live connection stops, and the printer is checked every few minutes (less often on battery,
    /// in Low Data Mode, or while it doesn't answer) for the menu bar's alerts. The Windows app's tray checks.
    func suspend(_ conditions: PollingConditions) {
        guard let monitor, polling == nil else { return }
        running?.cancel()
        running = nil
        polling = Task {
            var failures = 0
            while !Task.isCancelled {
                let wait = AlertPolling.interval(onBattery: conditions.onBattery, constrained: conditions.constrained, failures: failures)
                guard (try? await Task.sleep(for: .seconds(wait))) != nil else { return }
                failures = await monitor.check() ? 0 : failures + 1
            }
        }
    }

    /// The window is back: watched live again at once (a connection still good is kept, and asked who it is first).
    func resume() {
        guard let monitor, polling != nil else { return }
        polling?.cancel()
        polling = nil
        running = Task { await monitor.run(reuse: true) }
    }

    /// The offline fixer found the printer at a new address and the user (or the fixer, when it's certain) took it.
    func move(to address: String) {
        guard let monitor else { return }
        follow(address)
        Task {
            await monitor.move(to: address)
            if polling == nil { start() }
        }
    }

    /// The offline fixer has something to check: the printer doesn't answer, another device does, or its queue is stuck.
    var needsFixing: Bool {
        switch view.phase {
        case .offline, .elsewhere: true
        case .online: destination.map { $0.state == 5 || !$0.isAcceptingJobs } ?? false
        case .connecting: false
        }
    }

    /// The device a printer may answer to: its id, or a UUID the user accepted for it ("This is my printer").
    func isKnown(as uuid: String) -> Bool {
        guard isNetwork else { return uuid.caseInsensitiveCompare(id) == .orderedSame }
        return uuid.caseInsensitiveCompare(id) == .orderedSame || app.store.accepted(id).contains { $0.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// mDNS announced it: hints taken, a new address followed once it's known to be this printer.
    func apply(_ found: DiscoveredPrinter) {
        if model == nil { model = found.model }
        if hostName != found.hostName {
            hostName = found.hostName
            if isNetwork { app.handOffSoon() } // the hand-off gives Inkvolt PDF the Bonjour name
        }
        if let ipp = found.ippUri { ippHint = ipp }
        guard let monitor else { return }
        Task {
            if await monitor.announced(found) { start() }
        }
    }

    /// "This is my printer": the device now at its address counts as this printer.
    func acceptDevice() {
        guard let monitor else { return }
        let store = app.store, id = id
        Task {
            guard await monitor.acceptDevice({ store.accept(id, $0) }) else { return }
            app.handOffSoon()
            start()
        }
    }

    /// The status card's firmware notice was closed (roadmap 1.5): gone at once, and kept as dismissed for this change.
    func dismissFirmwareNotice() {
        guard let monitor else { return }
        view.firmwareNotice = nil
        Task { await monitor.dismissFirmwareNotice() }
    }

    /// The printer's web page (its embedded web server), where a printer Inkvolt Print doesn't set up keeps its settings.
    var webPage: URL? {
        guard isNetwork, !host.isEmpty else { return nil }
        return URL(string: "https://\(host.contains(":") ? "[\(host)]" : host)/")
    }

    private func handle(_ event: MonitorEvent) {
        switch event {
        case .changed(let v):
            if v.isOnline { lastReading = Date() }
            view = v
            if let m = v.model { model = m }
        case .observed(let snapshot):
            app.observe(snapshot)
        case .connected(let target, let model):
            follow(target.host)
            readOverSnmp = target.snmp != nil
            app.remember(self, at: target, model: model)
        }
    }

    /// This printer as the Fleet page lists it, from what the app shows (nothing is read from it here). `known`: the supply
    /// history's last word, for one that isn't answering. A scanner of its own that macOS lists is ready `now`, as
    /// `status --all` says (`FleetReader.scanner`).
    func fleetFacts(_ known: FleetLastKnown?, now: Date) -> FleetFacts {
        let kind: FleetKind = isScannerOnly ? .scanner : isQueue ? .queue : .network
        let connection: String? = if isScannerOnly { "USB scanner" }
            else if let d = destination { FleetReader.connectionWord(CupsQueues.connection(d)) }
            else { FleetConnection.interfaces(view.interfaces) }
        let shown = view.firmware.map(\.display).flatMap { $0.isEmpty ? nil : $0 }
        return .shown(id, name, kind, view: view, connection: connection, firmware: shown ?? app.store.firmware(id)?.version,
                      lastReading: isScannerOnly ? now : lastReading, known: known)
    }

    /// The printer as the offline fixer and Fix All see it (Windows' `FixerDevice`): a network printer's address and the
    /// addresses it had, so a queue still pointing at its old one is its own.
    var fixerDevice: OfflineDevice {
        OfflineDevice(uuid: id, name: name, model: model, host: isNetwork ? host : nil, previousHosts: previousHosts)
    }

    /// What Fix All looks at for this printer: a queue printer's own queue, a network printer's known ones; nil for a scanner
    /// of its own.
    var fixAllTarget: FixAllTarget? {
        if isScannerOnly { return nil }
        if let d = destination { return .queue(d.name) }
        return .network(fixerDevice)
    }

    /// Reached at `address` now: the one before is kept among the addresses it had.
    private func follow(_ address: String) {
        let old = host
        host = address
        guard !old.isEmpty, old.caseInsensitiveCompare(address) != .orderedSame,
              !previousHosts.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) else { return }
        previousHosts.append(old)
    }

    /// For the list's dot and the pane's status icon.
    var tone: Tone {
        switch view.phase {
        case .connecting: .unknown
        case .offline, .elsewhere: .off
        case .online: view.severity == .error ? .error : view.severity == .warning ? .warning : .ok
        }
    }

    enum Tone { case unknown, ok, warning, error, off }
}

/// Alerts as macOS notifications. Asks for permission with the first alert.
enum Notifier {
    static let printerKey = "printer"
    /// A print job's notification (roadmap 3.4): Open the Queue and Pause Alerts, as Windows' job toast.
    static let jobCategory = "job"
    static let openQueueAction = "open-queue"
    static let pauseAction = "pause-alerts"
    /// Pause Alerts from a notification: an hour (Windows' `AlertToasts.PauseFor`).
    static let pauseFor: TimeInterval = 60 * 60

    /// The job notification's buttons; once, at launch.
    static func registerCategories() {
        let open = UNNotificationAction(identifier: openQueueAction, title: "Open the Queue", options: [.foreground])
        let pause = UNNotificationAction(identifier: pauseAction, title: "Pause Alerts", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: jobCategory, actions: [open, pause], intentIdentifiers: []),
        ])
    }

    /// `job`: a print job's notification, whose click opens the printer's print queue card. The document's name is in the
    /// text only, never in what the notification carries back to the app.
    static func post(title: String, body: String, printer: String, job: Bool = false) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if job { content.categoryIdentifier = jobCategory }
            content.userInfo = [printerKey: printer]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
