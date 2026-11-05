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
    /// The supply history (roadmap 1.1): one file per printer in `history` beside the state file; in memory in demo mode,
    /// where each printer's first reading makes up its year.
    @ObservationIgnored let history: SupplyHistoryStore
    @ObservationIgnored let signal: LocalNetworkSignal
    @ObservationIgnored private let transport: HttpTransportFactory
    @ObservationIgnored private let snmp: any SnmpTransport
    /// The network a recording goes through (roadmap 1.2): this Mac's, each reply bounded as every read is (32 MB, a scanned
    /// page 1 GB) and no certificate pin (it only reads); demo mode's made-up printers.
    @ObservationIgnored let recordingTransport: @Sendable () -> any HttpTransport
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
    /// "Set up in macOS": creates a CUPS queue (this Mac's cupsd, or demo mode's made-up one).
    @ObservationIgnored let queueSetup: any QueueSetupControl
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
    /// A screen the selected printer's pane is asked to show (the Debug build's App Store snapshots).
    var paneRequest: PaneRequest?
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
    /// The Fleet page shows instead of the selected printer (the sidebar's Fleet, View › Fleet).
    var showFleet = false
    /// The Fleet page's rows, Export… and Fix All (roadmap 2.6).
    @ObservationIgnored private(set) lazy var fleet = FleetPageModel(app: self)
    /// What Bonjour sees now, listed or not (Add a printer offers the removed ones).
    @ObservationIgnored private var nearby: [DiscoveredPrinter] = []
    /// Bumped whenever the alert tracker changes (it isn't observable itself).
    private var alertRevision = 0
    /// What the printers' hand-off to Inkvolt PDF last wrote.
    @ObservationIgnored private var handedOff: SuitePrinters?
    @ObservationIgnored private var handOffLater: Task<Void, Never>?

    init(demo: Bool) {
        isDemo = demo
        let signal = LocalNetworkSignal()
        self.signal = signal
        if isDemo, let fixtures = Bundle.main.resourceURL?.appendingPathComponent("Demo") {
            let network = Demo.network(fixtures: fixtures) { DemoScanPage.jpeg($0, width: $1, height: $2) }
            transport = { _, _ in network.http }
            recordingTransport = { network.http }
            snmp = network.snmp
            store = StateStore(memory: Demo.state())
            history = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)
            let offline = DemoOffline()
            queues = offline
            offlineProbes = offline
            queueControl = offline
            queueSetup = offline
        } else {
            transport = URLSessionTransport.factory(localNetwork: signal)
            recordingTransport = {
                URLSessionTransport(check: CertificateCheck(pin: nil), localNetwork: signal)
            }
            snmp = UdpSnmpTransport(localNetwork: signal)
            store = StateStore(file: Self.stateFile)
            history = SupplyHistoryStore(Self.historyFolder.path)
            queues = LibCups()
            offlineProbes = NetworkOfflineProbes(localNetwork: signal)
            queueControl = LibCups()
            queueSetup = LibCups()
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

    /// The supply history's files, beside the state file (Windows' `history` under its data folder).
    static var historyFolder: URL { dataFolder.appendingPathComponent("history", isDirectory: true) }

    static var scansFolder: URL { dataFolder.appendingPathComponent("Scans") }

    /// SNMP as the printers are read (UDP, or demo mode's made-up agents), for a recording.
    var snmpTransport: any SnmpTransport { snmp }

    /// Where recordings go (Windows' `RecordingsFolder`): `Recordings` beside the state file in the container (the sandbox
    /// writes nowhere else without a save panel); demo mode's, of the made-up printers, in a temporary folder (Windows' too).
    var recordingsFolder: URL {
        isDemo ? FileManager.default.temporaryDirectory.appendingPathComponent("Inkvolt Print demo recordings", isDirectory: true)
            : Self.dataFolder.appendingPathComponent("Recordings", isDirectory: true)
    }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkvoltPrint")
    }

    /// The connection recipe for one printer: this Mac's network (or the made-up one) and the printer's certificate pins.
    func recipe(_ id: String) -> PrinterRecipe { PrinterRecipe(transport: transport, snmp: snmp, pin: store.pins(id)) }

    /// Every printer read once, for `status --all` (`FleetReader`): the state file's printers through this Mac's network (or the
    /// made-up one), macOS's queues and USB scanners. Read only: no pin, history or state is written.
    var fleetMac: any FleetMac {
        let transport = transport, snmp = snmp, store = store
        let scanners: @Sendable () async -> [SystemScanner]?
        if isDemo {
            scanners = { Demo.scanners }
        } else {
            scanners = { @Sendable () async -> [SystemScanner]? in await SystemScanners.listOnce() }
        }
        return AppFleetMac(store: store, makeRecipe: { PrinterRecipe(transport: transport, snmp: snmp, pin: ReadOnlyPin(store.pins($0))) },
                           queues: queues, listScanners: scanners, history: history)
    }

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

    /// The paper sizes Print Photos offers for a printer: its macOS queue's (libcups), demo mode's made-up inkjet's, or
    /// none (the fixed list then).
    func photoMedia(for p: PrinterModel) async -> [QueueMedia] {
        if isDemo { return p.id == Demo.inkjetUuid ? Demo.photoMedia : [] }
        guard let queue = p.queueName else { return [] }
        return await LibCups().media(queue)
    }

    /// The paper types, qualities and colors the printer's macOS queue offers for photos.
    func photoJobOptions(for p: PrinterModel) async -> QueueJobOptions {
        if isDemo { return p.id == Demo.inkjetUuid ? Demo.photoJobOptions : .none }
        guard let queue = p.queueName else { return .none }
        return await LibCups().jobOptions(queue)
    }

    /// "Set up in macOS" for a network printer macOS has no queue for: a driverless queue on its IPP URL, then the queues
    /// read again (the printer takes its new queue). Returns what to tell the user.
    func setUpQueue(for p: PrinterModel) async -> String {
        // The session's IPP URL, else Bonjour's, else IPP Everywhere's own (a printer read over LEDM or CDM may print over IPP too).
        let host = p.host.contains(":") ? "[\(p.host)]" : p.host
        let ipp = await p.connection()?.ipp?.endpoint ?? p.ippHint ?? URL(string: "ipp://\(host):631/ipp/print")
        guard let plan = QueueSetup.plan(name: p.name, ippUri: ipp, hostName: p.hostName, destinations: destinations ?? []) else {
            return "This printer doesn't offer driverless printing (IPP), so macOS needs its maker's driver for it. Add it in Printers & Scanners."
        }
        var failure: QueueControlError?
        do {
            try await queueSetup.addQueue(plan)
        } catch let e as QueueControlError {
            failure = e
        } catch {
            failure = .failed("It stopped before it was done.")
        }
        await readQueues()
        return QueueSetup.outcome(failure, info: plan.info)
    }

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
            // A queue macOS no longer has, or one a network printer here now stands for: its supply history goes with it.
            for p in printers where change.removed.contains(p.id) {
                p.stop()
                p.forgetHistory()
            }
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
        handOffPrinters()
    }

    /// The hand-off once things settle (half a second after the last call): a printer added, a UUID accepted for one, the
    /// host name Bonjour gives it. A run of Bonjour updates writes the file once.
    func handOffSoon() {
        guard !isDemo else { return }
        handOffLater?.cancel()
        handOffLater = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            self?.handOffPrinters()
        }
    }

    /// Inkvolt PDF's view of the printers (`SuitePrinters`, in the app group both apps claim): written when what it
    /// says changes, never in demo mode or without the container.
    private func handOffPrinters() {
        guard !isDemo, let root = ProKeyRoot.url?.path else { return }
        var hostNames: [String: String] = [:], queues: [String: String] = [:]
        for p in printers where p.isNetwork {
            if let h = p.hostName { hostNames[p.id] = h }
            if let q = p.queueName { queues[p.id] = q }
        }
        let now = SuitePrinters.from(store.current, hostNames: hostNames, queues: queues)
        guard now != handedOff else { return }
        if now.save(root: root) { handedOff = now }
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
        handOffSoon()
        p.start()
        selectedID = p.id
        return p
    }

    /// A printer connected: remembered with where it answered, so it's listed and connected at once next time.
    func remember(_ p: PrinterModel, at target: PrinterWhere, model: String?) {
        guard printers.contains(where: { $0 === p }) else { return }
        store.remember(KnownPrinter(uuid: p.id, name: p.name, model: model ?? p.model, host: target.host, esclRoot: target.esclHint?.absoluteString,
                                    ippUri: target.ippHint?.absoluteString, snmp: target.snmp))
        handOffPrinters()
    }

    /// Removed from Inkvolt Print (not from macOS): discovery won't list it again.
    func remove(_ p: PrinterModel) {
        p.stop()
        let listed = !p.isNetwork ? nil : ListedPrinter(id: p.id, kind: .network, name: p.name, model: p.model,
                                                      hosts: [p.host] + (p.hostName.map { [$0] } ?? []), acceptedUuids: store.accepted(p.id))
        // A network printer's own queues go with it, so none shows up as a printer of its own.
        let gone = listed.map { PrinterList.hiddenWith($0, destinations ?? []) } ?? [p.id]
        for id in gone { store.remove(id) }
        tracker.forget(p.id)
        // Its supply history goes with it (a reading in flight keeps nothing), and so does any its own queues kept while
        // they were listed on their own: no file is left behind to count toward the store's printers.
        p.forgetHistory()
        for id in gone where id.caseInsensitiveCompare(p.id) != .orderedSame { history.forget(id) }
        printers.removeAll { $0 === p }
        if selectedID == p.id { selectedID = printers.first?.id }
        alertRevision += 1
        handOffPrinters()
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

/// What `AppModel.paneRequest` asks the printer pane for: a tab, the Photos sheet over its first page of glass photos, or
/// Print Photos with these pictures in it.
enum PaneRequest: Equatable {
    case status
    case scan
    case photosSheet
    case printPhotos([URL])
}

/// The app's Mac as `FleetReader` reads it: the state file, cupsd (libcups, or demo mode's made-up queues), ImageCaptureCore's
/// USB scanners and the supply history, all only read.
struct AppFleetMac: FleetMac {
    let store: StateStore
    let makeRecipe: @Sendable (String) -> PrinterRecipe
    let queues: any PrintQueues
    let listScanners: @Sendable () async -> [SystemScanner]?
    let history: SupplyHistoryStore?

    var remembered: [KnownPrinter] { store.current.printers }
    var forgotten: [String] { store.current.forgottenUuids }
    func accepted(_ id: String) -> [String] { store.accepted(id) }
    func firmware(_ id: String) -> String? { store.firmware(id)?.version }
    func recipe(_ printer: KnownPrinter) -> PrinterRecipe { makeRecipe(printer.uuid) }
    func destinations() async throws -> [CupsDestination]? { await queues.destinations() }
    func scanners() async throws -> [SystemScanner]? { await listScanners() }
}
