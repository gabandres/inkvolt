import AppKit
import Observation
import PrintCore
import PrintMac

/// The app: the printer list (network printers, and queue printers from macOS's CUPS queues), discovery, Local Network
/// access, and the menu bar's alerts. One per process, made at launch
/// (`shared`) whether or not a window ever shows. Its environment (this Mac's, or demo mode's made-up one) is chosen once.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel(demo: CommandLine.arguments.contains("--demo"))

    /// "Try the Demo": the made-up printers in a window of their own, in this process (a sandboxed app can't pass
    /// arguments to a second copy of itself). The app itself when it was started with `--demo`.
    static let demo: AppModel = shared.isDemo ? shared : AppModel(demo: true)

    /// How long the first Bonjour sweep counts as "searching" (the empty list says so rather than "no printers").
    static let firstSweep: Duration = .seconds(30)

    /// How often macOS's queues are read (cupsd answers over its socket in a moment).
    static let queueRefresh: Duration = .seconds(10)

    /// `--demo`: made-up printers from the bundled fixtures; nothing reaches the network, nothing is saved.
    let isDemo: Bool
    @ObservationIgnored let store: StateStore
    @ObservationIgnored let signal: LocalNetworkSignal
    @ObservationIgnored private let transport: HttpTransportFactory
    @ObservationIgnored private let snmp: any SnmpTransport
    @ObservationIgnored private var tracker: AlertTracker
    /// The menu bar item and its alerts, as the user set them.
    private(set) var settings: AlertSettings
    /// The main window is on screen: printers are watched live; closed, they're checked now and then.
    @ObservationIgnored private(set) var windowOpen = true
    @ObservationIgnored private let conditions = PollingConditions()
    @ObservationIgnored let queues: any PrintQueues
    /// The offline fixer's network checks and its queue repairs (this Mac's, or demo mode's made-up ones).
    @ObservationIgnored let offlineProbes: any OfflineProbes
    @ObservationIgnored let queueControl: any QueueControl
    @ObservationIgnored private var readingQueues: Task<Void, Never>?
    /// Discovery's first sweep is over: network queues may be listed (a printer it finds would take their place).
    @ObservationIgnored private var sweepDone = false
    /// A queue printer selected last time, selected again once it's listed.
    @ObservationIgnored private var wantedQueue: String?
    /// Scanned pages not saved yet, kept for after a crash (none in demo mode).
    @ObservationIgnored private(set) lazy var scanStore: ScanRecoveryStore? = isDemo ? nil : try? ScanRecoveryStore.start(Self.scansFolder.path)
    /// The scan presets (one-click scans), the built-in ones until the user changes them.
    private(set) var presets: [ScanPreset] = []
    /// Scans a run that didn't end cleanly left behind, offered on their printer's Scan tab.
    var leftOverScans: [LeftOverScan] = []
    /// macOS's USB scanners (ImageCaptureCore); made up in demo mode.
    @ObservationIgnored private var systemScanners: SystemScanners?
    /// The scanners as last listed; nil before the first list.
    @ObservationIgnored private var scannerList: [SystemScanner]?
    /// The queues as last read; nil before the first read, or when cupsd couldn't be asked.
    private(set) var destinations: [CupsDestination]?
    @ObservationIgnored private var discovery: BonjourDiscovery?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Open the main window or the demo window, or bring it forward; set by the menu bar item, which SwiftUI shows at
    /// launch.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openDemoWindow: (() -> Void)?

    private(set) var printers: [PrinterModel] = []
    var selectedID: String? {
        didSet { if oldValue != selectedID { store.change { $0.selectedUuid = selectedID } } }
    }
    private(set) var localNetwork: LocalNetworkAccess = .unknown
    private(set) var isSearching = true
    /// Add a printer is open (the menu command and the empty list open it).
    var isAddingPrinter = false
    /// What Bonjour sees now, listed or not (Add a printer offers the removed ones).
    @ObservationIgnored private var nearby: [DiscoveredPrinter] = []
    /// Bumped whenever the alert tracker changes (it isn't observable itself).
    private var alertRevision = 0

    init(demo: Bool) {
        isDemo = demo
        let signal = LocalNetworkSignal()
        self.signal = signal
        if isDemo, let fixtures = Bundle.main.resourceURL?.appendingPathComponent("Demo") {
            let network = Demo.network(fixtures: fixtures) { DemoScanPage.jpeg($0, width: $1, height: $2) }
            transport = { _, _ in network.http }
            snmp = network.snmp
            store = StateStore(memory: Demo.state())
            let offline = DemoOffline()
            queues = offline
            offlineProbes = offline
            queueControl = offline
        } else {
            transport = URLSessionTransport.factory(localNetwork: signal)
            snmp = UdpSnmpTransport(localNetwork: signal)
            store = StateStore(file: Self.stateFile)
            queues = LibCups()
            offlineProbes = NetworkOfflineProbes(localNetwork: signal)
            queueControl = LibCups()
        }
        settings = store.current.alertSettings
        presets = ScanPresets.normalize(store.current.scanPresets)
        tracker = AlertTracker(rules: store.current.alertSettings.rules, shown: store.current.shownAlerts)
        tracker.pausedUntil = settings.pausedUntil
        printers = store.current.printers.map { PrinterModel(known: $0, app: self) }
        let selected = store.current.selectedUuid
        if CupsQueues.isQueueId(selected) { wantedQueue = selected }
        selectedID = printers.first { $0.id.caseInsensitiveCompare(selected ?? "") == .orderedSame }?.id ?? printers.first?.id
    }

    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/InkvoltPrint/state.json` in the sandbox.
    static var stateFile: URL { dataFolder.appendingPathComponent("state.json") }

    static var scansFolder: URL { dataFolder.appendingPathComponent("Scans") }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkvoltPrint")
    }

    /// The connection recipe for one printer: this Mac's network (or the made-up one) and the printer's certificate pins.
    func recipe(_ id: String) -> PrinterRecipe { PrinterRecipe(transport: transport, snmp: snmp, pin: store.pins(id)) }

    /// Starts every printer's monitor, discovery and the alerts' clock. Once, at launch.
    func start() {
        guard !started else { return }
        started = true
        for p in printers { p.start() }
        if !isDemo {
            ScanRecoveryStore.discardEmpty(Self.scansFolder.path)
            leftOverScans = ScanRecoveryStore.findLeftOver(Self.scansFolder.path)
            _ = scanStore
        }
        ticking = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(60))) != nil {
                guard let self else { return }
                if let until = self.settings.pausedUntil, until <= Date() { self.resumeAlerts() } // the pause is over
                self.show(self.tracker.release(now: Date())) // held alerts due, quiet hours over
            }
        }
        readingQueues = Task { [weak self] in
            repeat {
                guard let self else { return }
                await self.readQueues()
            } while (try? await Task.sleep(for: self?.windowOpen == false ? .seconds(60) : Self.queueRefresh)) != nil
        }
        if isDemo {
            isSearching = false
            sweepDone = true
            scannerList = DemoScanDevice.all
            reconcile()
            return
        }
        let scanners = SystemScanners { [weak self] list in
            self?.scannerList = list
            self?.reconcile()
        }
        systemScanners = scanners
        scanners.start()
        signal.onChange { [weak self] access in Task { @MainActor in self?.localNetworkChanged(access) } }
        let discovery = BonjourDiscovery(localNetwork: signal) { [weak self] services in
            let found = DiscoveredPrinters.join(services)
            Task { @MainActor in self?.merge(found) }
        }
        self.discovery = discovery
        discovery.start()
        searchFor(Self.firstSweep)
    }

    /// Search again: what Bonjour has seen is dropped and browsed afresh.
    func searchAgain() {
        guard let discovery else { return }
        discovery.restart()
        searchFor(Self.firstSweep)
    }

    private func searchFor(_ time: Duration) {
        isSearching = true
        searching?.cancel()
        searching = Task { [weak self] in
            guard (try? await Task.sleep(for: time)) != nil, let self else { return }
            self.isSearching = false
            if !self.sweepDone {
                self.sweepDone = true
                self.reconcile()
            }
        }
    }

    private func localNetworkChanged(_ access: LocalNetworkAccess) {
        let was = localNetwork
        localNetwork = access
        // Allowed after all (the user answered the alert, or turned it on in Settings): look and connect again now.
        if access == .allowed && was == .denied {
            discovery?.restart()
            for p in printers where !p.view.isOnline { p.start() }
        }
    }

    // MARK: The list

    var selected: PrinterModel? { printers.first { $0.id == selectedID } }

    var isEmpty: Bool { printers.isEmpty }

    /// Printers found on the network join the list (only real UUIDs: mDNS TXT is untrusted text); a printer already listed
    /// takes what the announcement says, and follows it to a new address once its session says it's the same printer.
    private func merge(_ found: [DiscoveredPrinter]) {
        nearby = found
        for d in found where PrinterId.isValid(d.uuid) {
            if let p = printers.first(where: { $0.isKnown(as: d.uuid) }) {
                p.apply(d)
                continue
            }
            guard let host = d.host, !store.isForgotten(d.uuid) else { continue }
            let p = PrinterModel(known: KnownPrinter(uuid: d.uuid, name: d.name, model: d.model, host: host, esclRoot: d.esclRoot?.absoluteString,
                                                     ippUri: d.ippUri?.absoluteString), app: self)
            printers.append(p)
            p.start()
            if !windowOpen { p.suspend(conditions) }
            if selectedID == nil { selectedID = p.id }
        }
        reconcile() // a queue a printer just found stands for gives way to it
    }

    // MARK: Queue printers

    /// Reads macOS's queues: each queue printer takes its queue's state, and the list follows the queues.
    private func readQueues() async {
        let read = await queues.destinations()
        guard let read else { return } // cupsd can't be asked now: the queue printers stay as they are
        destinations = read
        for p in printers where p.isQueue {
            if let d = read.first(where: { CupsQueues.id(for: $0.name) == p.id }) { p.update(d) }
        }
        reconcile()
    }

    /// The printer list module's change, made: queue printers added and removed, the selection moved.
    private func reconcile() {
        guard let destinations else { return }
        let listed = printers.map { p -> ListedPrinter in
            if p.isScannerOnly, let s = p.systemScanner {
                var l = ListedPrinter.forScanner(s)
                l.hasUnsavedScans = p.unsavedPages > 0
                return l
            }
            if p.isQueue, let d = p.destination { return .forQueue(d) }
            return ListedPrinter(id: p.id, kind: .network, name: p.name, model: p.model, hosts: [p.host] + (p.hostName.map { [$0] } ?? []),
                                 acceptedUuids: store.accepted(p.id))
        }
        var input = PrinterListInput(listed: listed, selected: selectedID, destinations: destinations, sweepDone: sweepDone,
                                     forgotten: store.current.forgottenUuids, wantedQueue: wantedQueue)
        input.scanners = scannerList
        let change = PrinterList.reconcile(input)
        wantedQueue = change.wantedQueue
        for id in change.unforget { store.unforget(id) }
        if change.changes {
            for p in printers where change.removed.contains(p.id) { p.stop() }
            printers.removeAll { change.removed.contains($0.id) }
            for id in change.removed { tracker.forget(id) }
            printers += change.addedQueues.map { PrinterModel(queue: $0, app: self) }
            printers += change.addedScanners.map { PrinterModel(scanner: $0, app: self) }
            alertRevision += 1
        }
        if change.selected != selectedID { selectedID = change.selected }
        if let given = change.systemScanners {
            for p in printers where p.isQueue { p.systemScanner = given[p.id] ?? nil }
        }
        // Each network printer's own queue, for its print queue card.
        let claims = PrinterList.claims(listed)
        let real = destinations.filter(CupsQueues.isRealQueue)
        for p in printers where p.isNetwork {
            let own = real.first { CupsQueues.claim($0, claims)?.id == p.id }?.name
            if own != p.queueName { p.queueName = own }
        }
    }

    // MARK: Scan presets

    /// Saves the presets (a list from a newer version of the app is used as it is, never written over).
    func savePresets(_ list: [ScanPreset]) {
        presets = list
        guard store.current.scanPresets?.isNewer != true else { return }
        store.change { s in
            var stored = s.scanPresets ?? ScanPresetSettings()
            stored.items = list
            s.scanPresets = stored
            let ids = Set(list.map(\.id))
            s.presetFolders = s.presetFolders.filter { ids.contains($0.key) }
        }
    }

    /// The preset's next `{n}`, taken (and saved) at once, so two scans never share it.
    func reserveNumber(_ presetId: String) -> Int {
        var list = presets
        let n = ScanPresets.reserve(&list, presetId) ?? 1
        savePresets(list)
        return n
    }

    /// The folder the preset saves to, when the user chose one and it's still there.
    func presetFolder(_ id: String) -> URL? {
        guard let bookmark = store.current.presetFolders[id], let (url, renewed) = FolderBookmarks.resolve(bookmark) else { return nil }
        if let renewed { store.change { $0.presetFolders[id] = renewed } }
        return url
    }

    func setPresetFolder(_ id: String, _ url: URL) {
        guard let bookmark = FolderBookmarks.make(url) else { return }
        store.change { $0.presetFolders[id] = bookmark }
    }

    /// The scanner to scan with: ImageCaptureCore's device, or demo mode's made-up one.
    func scanDevice(for s: SystemScanner) -> (any ScanDevice)? {
        isDemo ? DemoScanDevice(s) : systemScanners?.device(s.id)
    }

    /// The queue's printer can't be reached, as macOS says.
    func queueOffline(_ name: String) -> Bool {
        destinations?.first { $0.name == name }.map { CupsStatus.describe($0).offline } ?? false
    }

    // MARK: Add a printer

    /// Printers Bonjour sees now that were removed from the list: they can be put back.
    func removedNearby() -> [DiscoveredPrinter] {
        nearby.filter { $0.host != nil && PrinterId.isValid($0.uuid) && store.isForgotten($0.uuid) }
    }

    /// Puts a printer removed earlier back on the list (discovery lists it again at once) and selects it.
    func addBack(_ d: DiscoveredPrinter) -> PrinterModel? {
        store.unforget(d.uuid)
        merge(nearby)
        let p = printers.first { $0.isKnown(as: d.uuid) }
        if let p { selectedID = p.id }
        return p
    }

    /// Searches the networks this Mac is on (the made-up one in demo mode); `found` for each address that may be a printer
    /// (any thread). Bonjour looks again too: a printer that just woke up shows by itself.
    func searchNetwork(found: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (SearchProgress) -> Void) async throws {
        if isDemo {
            try await Demo.searchNetwork(found: found, progress: progress)
            return
        }
        searchAgain()
        try await NetworkSearch.search(SocketNetworkScanner(localNetwork: signal), found: found, progress: progress)
    }

    /// Asks the device at `host` what it is, and makes Add a printer's entry for it (nil: not a printer).
    func identify(_ host: String, ipp: URL? = nil) async -> FoundPrinter? {
        await AddPrinter.identify(host, ipp: ipp, transport: transport, snmp: snmp) { [weak self] probe, host in
            await self?.listedEntry(probe, host)
        }
    }

    private func listedEntry(_ probe: ProbeResult, _ host: String) -> (id: String, name: String)? {
        listed(probe, host).map { (id: $0.id, name: $0.name) }
    }

    /// The listed printer this is (same UUID, or the same address for one without), or nil.
    func listed(_ probe: ProbeResult, _ host: String) -> PrinterModel? {
        let id = PrinterId.normalize(probe.uuid, host: host)
        return printers.first { $0.isKnown(as: id) || $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// Lists, remembers and selects the printer that answered at `host`.
    @discardableResult
    func add(_ probe: ProbeResult, host: String) -> PrinterModel {
        let known = AddPrinter.knownPrinter(probe, host: host)
        store.unforget(known.uuid)
        if let p = printers.first(where: { $0.id.caseInsensitiveCompare(known.uuid) == .orderedSame }) {
            selectedID = p.id
            return p
        }
        let p = PrinterModel(known: known, app: self)
        printers.append(p)
        store.remember(known)
        p.start()
        selectedID = p.id
        return p
    }

    /// A printer connected: remembered with where it answered, so it's listed and connected at once next time.
    func remember(_ p: PrinterModel, at target: PrinterWhere, model: String?) {
        guard printers.contains(where: { $0 === p }) else { return }
        store.remember(KnownPrinter(uuid: p.id, name: p.name, model: model ?? p.model, host: target.host, esclRoot: target.esclHint?.absoluteString,
                                    ippUri: target.ippHint?.absoluteString, snmp: target.snmp))
    }

    /// Removed from Inkvolt Print (not from macOS): discovery won't list it again.
    func remove(_ p: PrinterModel) {
        p.stop()
        let listed = !p.isNetwork ? nil : ListedPrinter(id: p.id, kind: .network, name: p.name, model: p.model,
                                                      hosts: [p.host] + (p.hostName.map { [$0] } ?? []), acceptedUuids: store.accepted(p.id))
        // A network printer's own queues go with it, so none shows up as a printer of its own.
        for id in listed.map({ PrinterList.hiddenWith($0, destinations ?? []) }) ?? [p.id] { store.remove(id) }
        tracker.forget(p.id)
        printers.removeAll { $0 === p }
        if selectedID == p.id { selectedID = printers.first?.id }
        alertRevision += 1
    }

    /// The made-up printers in a window beside this one.
    func openDemo() {
        AppModel.demo.start()
        NSApp.activate()
        AppModel.shared.openDemoWindow?()
    }

    // MARK: Alerts and the menu bar

    /// Changes the settings, saves them and applies them to the alerts.
    func changeSettings(_ body: (inout AlertSettings) -> Void) {
        let wasOn = settings.rules.enabled
        var s = settings
        body(&s)
        s.repair()
        guard s != settings else { return }
        settings = s
        store.change { $0.alertSettings = s }
        if s.rules.enabled && !wasOn {
            // Alerts just turned on: start afresh, so a problem already there (noticed silently while they were off) is told.
            tracker = AlertTracker(rules: s.rules)
            store.change { $0.shownAlerts = [:] }
        } else {
            tracker.rules = s.rules
        }
        tracker.pausedUntil = s.pausedUntil
        alertRevision += 1
    }

    /// Pauses alerts for a while, or (nil) until tomorrow morning.
    func pauseAlerts(for span: TimeInterval?) {
        let until = span.map { Date().addingTimeInterval($0) } ?? AlertSettings.tomorrowMorning(after: Date())
        changeSettings { $0.pausedUntil = until }
    }

    func resumeAlerts() { changeSettings { $0.pausedUntil = nil } }

    var isPaused: Bool { settings.isPaused(now: Date()) }

    /// The main window opened or closed (the demo window's printers stay live: it's only a demo).
    func windowChanged(open: Bool) {
        guard open != windowOpen, !isDemo || self !== AppModel.demo else { return }
        windowOpen = open
        for p in printers where p.isNetwork {
            if open { p.resume() } else { p.suspend(conditions) }
        }
    }

    func observe(_ snapshot: PrinterSnapshot) { show(tracker.observe(snapshot, now: Date())) }

    private func show(_ notices: [AlertNotice]) {
        if !notices.isEmpty && !(isDemo && self !== AppModel.shared) { // the demo window's made-up printers don't notify
            let (title, text) = TrayText.notice(notices)
            Notifier.post(title: title, body: text, printer: notices[0].uuid)
        }
        alertRevision += 1
        let shown = tracker.shown()
        if shown != store.current.shownAlerts { store.change { $0.shownAlerts = shown } }
    }

    /// The menu bar icon: the worst printer.
    var overall: AlertLevel {
        _ = alertRevision
        return tracker.overall
    }

    /// A line per printer for the menu.
    var menuLines: [(id: String, line: PrinterLine)] {
        _ = alertRevision
        return printers.map { p in
            (p.id, TrayText.line(name: p.name, tracked: tracker.level(p.id), problem: tracker.problem(p.id), view: p.view))
        }
    }
}
