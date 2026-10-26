import Foundation
import Observation
import PrintCore
import UserNotifications

/// One network printer on the list: its printer monitor's state, for the pane, the list and the menu bar.
@MainActor @Observable
final class PrinterModel: Identifiable {
    let id: String
    private(set) var name: String
    private(set) var model: String?
    /// Where it's reached now (it follows the printer to a new address).
    private(set) var host: String
    private(set) var view = PrinterView.connecting

    @ObservationIgnored private let monitor: PrinterMonitor
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?

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

    /// Starts (or restarts) the monitor's connection loop.
    func start() {
        running?.cancel()
        let monitor = monitor
        running = Task { await monitor.run() }
    }

    func stop() {
        running?.cancel()
        running = nil
        events?.cancel()
    }

    /// The device a printer may answer to: its id, or a UUID the user accepted for it ("This is my printer").
    func isKnown(as uuid: String) -> Bool {
        uuid.caseInsensitiveCompare(id) == .orderedSame || app.store.accepted(id).contains { $0.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// mDNS announced it: hints taken, a new address followed once it's known to be this printer.
    func apply(_ found: DiscoveredPrinter) {
        if model == nil { model = found.model }
        let monitor = monitor
        Task {
            if await monitor.announced(found) { start() }
        }
    }

    /// "This is my printer": the device now at its address counts as this printer.
    func acceptDevice() {
        let monitor = monitor, store = app.store, id = id
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
