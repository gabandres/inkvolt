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
    /// Its Bonjour host name, once discovery saw it (queue matching knows it by that too).
    private(set) var hostName: String?
    /// The CUPS queue its print jobs go through: a queue printer's own, or the one macOS has for a network printer.
    var queueName: String?
    private(set) var view = PrinterView.connecting
    /// A queue printer's queue, as last read.
    private(set) var destination: CupsDestination?

    @ObservationIgnored private let monitor: PrinterMonitor?
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// The window is closed: the printer is checked now and then instead of watched live.
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(known: KnownPrinter, app: AppModel) {
        id = known.uuid
        name = known.name
        model = known.model
        host = known.host
        self.app = app
        let (stream, continuation) = AsyncStream.makeStream(of: MonitorEvent.self)
        let store = app.store, id = known.uuid
        monitor = PrinterMonitor(id: id, name: known.name, target: known.target, recipe: app.recipe(id), accepted: { store.accepted(id) },
                                 acceptUuids: { store.accept(id, $0) }, onEvent: { continuation.yield($0) })
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
        update(d)
    }

    var isQueue: Bool { monitor == nil && systemScanner == nil || destination != nil }

    /// Found on the network or added by address: it has a printer monitor.
    var isNetwork: Bool { monitor != nil }

    /// A scanner of its own (no printer, no queue).
    var isScannerOnly: Bool { monitor == nil && destination == nil && systemScanner != nil }

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

    /// The queue was read again.
    func update(_ d: CupsDestination) {
        destination = d
        queueName = d.name
        name = d.displayName
        model = d.makeAndModel
        let v = CupsStatus.view(d)
        if v != view { view = v }
        app.observe(CupsStatus.snapshot(d, id: id))
    }

    /// Starts (or restarts) the monitor's connection loop.
    func start() {
        guard let monitor, polling == nil else { return }
        running?.cancel()
        running = Task { await monitor.run() }
    }

    func stop() {
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
        host = address
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
        hostName = found.hostName
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
            if await monitor.acceptDevice({ store.accept(id, $0) }) { start() }
        }
    }

    private func handle(_ event: MonitorEvent) {
        switch event {
        case .changed(let v):
            view = v
            if let m = v.model { model = m }
        case .observed(let snapshot):
            app.observe(snapshot)
        case .connected(let target, let model):
            host = target.host
            app.remember(self, at: target, model: model)
        }
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

    static func post(title: String, body: String, printer: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [printerKey: printer]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
