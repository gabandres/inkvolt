import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// File › Set Up a New Printer's Wi-Fi… (roadmap 4.17, Windows' Set up a new printer…): the guide (`PrinterSetupGuide`) in a
/// window of its own, one per app model. The person joins the printer's network and goes back in macOS's Wi-Fi menu; the app
/// never joins a network (PLAN, "Mac differences"). Demo mode's made-up Wi-Fi (`DemoWifi`) has a made-up person do it.
@MainActor
enum PrinterSetupWindow {
    private static var window: NSWindow?
    private(set) static var model: PrinterSetupModel?
    private static let closer = Closer()

    @discardableResult
    static func show(_ app: AppModel) -> PrinterSetupModel {
        if let model, model.app === app, let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return model
        }
        let model = PrinterSetupModel(app: app)
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PrinterSetupView(model: model))
        w.title = app.isDemo ? String(localized: "Set Up a New Printer's Wi-Fi — Demo") : String(localized: "Set Up a New Printer's Wi-Fi")
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.contentMinSize = NSSize(width: 480, height: 380)
        w.delegate = closer
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        model.start()
        return model
    }

    /// `--report … --setup-wifi` closes it when done.
    static func closeForReport() { window?.close() }

    /// Closing the window stops a wait (the guide then says where the Mac is) and forgets the guide.
    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                PrinterSetupWindow.model?.stop()
                PrinterSetupWindow.model = nil
                PrinterSetupWindow.window = nil
            }
        }
    }
}

/// The guide's state for the window, its calls run one at a time as tasks the window can stop.
@MainActor @Observable
final class PrinterSetupModel {
    let app: AppModel
    private(set) var state = SetupState()
    private(set) var working = false
    /// The printers listed before the Mac left for the printer's network, to find the new one once back.
    @ObservationIgnored private var listedBefore: Set<String> = []
    @ObservationIgnored private let guide: PrinterSetupGuide
    @ObservationIgnored private let demo: DemoWifi?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        let demo = app.isDemo ? DemoWifi() : nil
        self.demo = demo
        let (states, sink) = AsyncStream.makeStream(of: SetupState.self, bufferingPolicy: .bufferingNewest(8))
        let wifi: any WifiReading = demo ?? CoreWifi()
        guide = PrinterSetupGuide(wifi, log: { NSLog("%@", $0) }, onChange: { sink.yield($0) })
        follow = Task { @MainActor [weak self] in
            for await state in states { self?.state = state }
        }
    }

    /// Follows the guide's states; it ends when the guide (and its stream's continuation) goes with this model.
    @ObservationIgnored private var follow: Task<Void, Never>?

    var locationUndetermined: Bool { demo == nil && WifiLocation.undetermined }

    /// The printer that joined the home network since (a printer listed now that wasn't before the Mac left).
    var newPrinter: String? {
        guard state.step == .back, state.joined != nil else { return nil }
        let now = app.printers.map { (id: $0.id, name: $0.name) }
        return PrinterSetupGuide.foundPrinter(now, before: listedBefore, maker: state.joined?.maker)?.name
    }

    func start() { look() }

    /// Look (again): asks for location access first when macOS never asked (its alert carries the usage text).
    func look() {
        run { [self] in
            if locationUndetermined { _ = await WifiLocation.shared.request() }
            await guide.look()
        }
    }

    func use(_ candidate: SetupCandidate) {
        listedBefore = Set(app.printers.map(\.id))
        demo?.personJoins = candidate.network // the made-up person, in the made-up Wi-Fi menu
        run { [guide] in await guide.connect(candidate) }
    }

    func done() {
        demo?.personJoins = DemoWifi.home
        run { [guide] in await guide.returnHome() }
    }

    func checkAgain() { run { [guide] in await guide.checkBack() } }

    func openPage() {
        if let page = state.page, !Report.isRunning { NSWorkspace.shared.open(page) }
    }

    /// Stops a wait (Cancel, or the window closing): the guide says where the Mac is.
    func stop() { task?.cancel() }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        guard !working else { return }
        working = true
        task = Task { @MainActor in
            await body()
            self.state = await self.guide.state
            self.working = false
        }
    }

    /// Waits for the call running now, for `--report`.
    func settle() async { await task?.value }
}

struct PrinterSetupView: View {
    @Bindable var model: PrinterSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("For a printer still out of the box: until it's told your Wi-Fi, it offers a network of its own. Join that network in the Wi-Fi menu, enter your Wi-Fi's name and password on the printer's own page, then go back to your network. Inkvolt Print never sees a Wi-Fi password and never changes networks.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            step
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var step: some View {
        let s = model.state
        if let problem = s.problem { Text(problem).fixedSize(horizontal: false, vertical: true) }
        switch s.step {
        case .looking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Looking for printers' networks…")
            }
        case .noWifi:
            EmptyView()
        case .locationOff:
            HStack {
                Button("Open Location Services") { NSWorkspace.shared.open(Self.locationServices) }
                Button("Look Again") { model.look() }
            }
        case .choose:
            if !s.candidates.isEmpty {
                Text("Printers' networks nearby:").font(.headline)
                List(s.candidates, id: \.network.ssid) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.network.name)
                            Text(Self.describe(c)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use This Network") { model.use(c) }.disabled(model.working)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 120)
            }
            Button("Look Again") { model.look() }.disabled(model.working)
        case .inMenu, .returning:
            HStack {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.stop() }
            }
        case .onPrinter:
            if s.page != nil {
                Text("Enter your Wi-Fi's name and password on the printer's page. When it says it's connecting, click Done.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if s.page != nil { Button("Open the Printer's Setup Page") { model.openPage() }.keyboardShortcut(.defaultAction) }
                Button("Done") { model.done() }
            }
        case .back:
            if s.joined != nil {
                if let found = model.newPrinter {
                    Text("Found on your network: \(found)").fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The printer joins your Wi-Fi within a minute or two. Add a Printer… finds it if it doesn't show in the list.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Add a Printer…") {
                    MainWindow.bringForward()
                    model.app.isAddingPrinter = true
                }
                Button("Look Again") { model.look() }
            }
        case .couldNotReturn:
            Button("Check Again") { model.checkAgain() }.disabled(model.working)
        }
    }

    /// "HP, setup network, signal 70 %" (open or asking for a password).
    static func describe(_ c: SetupCandidate) -> String {
        let kind = c.kind == .setup ? String(localized: "setup network") : String(localized: "Wi-Fi Direct")
        let lock = c.network.secured ? String(localized: "asks for a password") : String(localized: "open")
        return "\(c.maker), \(kind), \(lock), " + String(localized: "signal \(c.network.signal)") + " %"
    }

    /// Privacy & Security › Location Services.
    static let locationServices = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
}
