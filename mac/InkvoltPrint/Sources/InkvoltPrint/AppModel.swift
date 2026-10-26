import AppKit
import Observation
import PrintCore
import PrintMac

/// The app: the printer list, discovery, Local Network access, and the menu bar's alerts. One per process, made at launch
/// (`shared`) whether or not a window ever shows. Its environment (this Mac's, or demo mode's made-up one) is chosen once.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel(arguments: CommandLine.arguments)

    /// How long the first Bonjour sweep counts as "searching" (the empty list says so rather than "no printers").
    static let firstSweep: Duration = .seconds(30)

    /// `--demo`: made-up printers from the bundled fixtures; nothing reaches the network, nothing is saved.
    let isDemo: Bool
    @ObservationIgnored let store: StateStore
    @ObservationIgnored let signal: LocalNetworkSignal
    @ObservationIgnored private let transport: HttpTransportFactory
    @ObservationIgnored private let snmp: any SnmpTransport
    @ObservationIgnored private let tracker: AlertTracker
    @ObservationIgnored private var discovery: BonjourDiscovery?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Opens the main window or brings it forward; set by the menu bar item, which SwiftUI shows at launch.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    private(set) var printers: [PrinterModel] = []
    var selectedID: String? {
        didSet { if oldValue != selectedID { store.change { $0.selectedUuid = selectedID } } }
    }
    private(set) var localNetwork: LocalNetworkAccess = .unknown
    private(set) var isSearching = true
    /// Bumped whenever the alert tracker changes (it isn't observable itself).
    private var alertRevision = 0

    init(arguments: [String]) {
        isDemo = arguments.contains("--demo")
        let signal = LocalNetworkSignal()
        self.signal = signal
        if isDemo, let fixtures = Bundle.main.resourceURL?.appendingPathComponent("Demo") {
            let network = Demo.network(fixtures: fixtures)
            transport = { _, _ in network.http }
            snmp = network.snmp
            store = StateStore(memory: Demo.state())
        } else {
            transport = URLSessionTransport.factory(localNetwork: signal)
            snmp = UdpSnmpTransport(localNetwork: signal)
            store = StateStore(file: Self.stateFile)
        }
        tracker = AlertTracker(rules: AlertRules(), shown: store.current.shownAlerts)
        printers = store.current.printers.map { PrinterModel(known: $0, app: self) }
        let selected = store.current.selectedUuid
        selectedID = printers.first { $0.id.caseInsensitiveCompare(selected ?? "") == .orderedSame }?.id ?? printers.first?.id
    }

    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/InkvoltPrint/state.json` in the sandbox.
    static var stateFile: URL { dataFolder.appendingPathComponent("state.json") }

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
        ticking = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(60))) != nil {
                guard let self else { return }
                self.show(self.tracker.release(now: Date())) // held alerts due, quiet hours over
            }
        }
        if isDemo {
            isSearching = false
            return
        }
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
            guard (try? await Task.sleep(for: time)) != nil else { return }
            self?.isSearching = false
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
            if selectedID == nil { selectedID = p.id }
        }
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
        store.remove(p.id)
        tracker.forget(p.id)
        printers.removeAll { $0 === p }
        if selectedID == p.id { selectedID = printers.first?.id }
        alertRevision += 1
    }

    /// A second copy of the app with the made-up printers.
    func openDemo() {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--demo"]
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    // MARK: Alerts and the menu bar

    func observe(_ snapshot: PrinterSnapshot) { show(tracker.observe(snapshot, now: Date())) }

    private func show(_ notices: [AlertNotice]) {
        if !notices.isEmpty {
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
