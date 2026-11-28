import AppKit
import PrintCore
import SwiftUI

/// View › Command Palette… (⌘K; the Windows app's Ctrl+K): every command of the sidebar, the printer's toolbar, tabs and
/// menus, each printer to show and each scan preset to run (`PrintPalette`), searched as you type (`PaletteSearch`), run
/// with Return or a click; ↑ and ↓ move, Esc closes. Another printer's commands ("Front desk: Fix printing problems…") wait
/// for a word typed. An entry runs on the printer it named, never one that took its place in the list meanwhile.
@MainActor
enum PrintCommandPalette {
    private static var panel: NSPanel?

    /// The palette's list as it is now, and the printers it was built from (by `PrintPalette.target`).
    static func entries(_ app: AppModel) -> (entries: [PrintPalette.Entry], printers: [PrinterModel]) {
        let printers = app.printers
        let index = app.showFleet ? -1 : printers.firstIndex { $0.id == app.selectedID } ?? -1
        let every = printers.map { offer($0, app) }
        let list = PrintPalette.build(index < 0 ? nil : every[index], index, printers.map(\.name), app.presets.map(\.name), every: every)
        return (list, printers)
    }

    /// What a printer offers, as the Mac's toolbar, tabs and menus have it.
    static func offer(_ p: PrinterModel, _ app: AppModel) -> PrintPalette.Printer {
        PrintPalette.Printer(p.name, canPrint: !p.isScannerOnly, canScan: p.canScan, canCopy: p.canScan && !p.isScannerOnly,
                             hasSettings: p.hasDeviceSettings, needsSetup: needsSetUp(p, app), canFix: p.needsFixing,
                             isNetwork: p.isNetwork && p.view.isOnline, snmpAccess: p.canSetSnmpLogin)
    }

    /// The status tab's Set Up in macOS shows (a network printer macOS has no queue for).
    private static func needsSetUp(_ p: PrinterModel, _ app: AppModel) -> Bool {
        p.isNetwork && p.queueName == nil && app.destinations != nil && p.view.isOnline
    }

    static func show(_ app: AppModel) {
        if let panel, panel.isVisible { return panel.makeKeyAndOrderFront(nil) }
        let built = entries(app)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isRestorable = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.title = String(localized: "Command Palette")
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        panel.contentViewController = NSHostingController(rootView: PaletteView(all: built.entries) { entry, openSettings in
            // Settings is SwiftUI's own window: only a view's openSettings opens it (asked while the palette's view is there).
            if entry.id == "app:settings" { openSettings() }
            close()
            if entry.id != "app:settings" { run(entry.id, app: app, asBuilt: built.printers) }
        } close: { close() })
        if let front = NSApp.keyWindow ?? NSApp.mainWindow {
            let f = front.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 80))
        } else {
            panel.center()
        }
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Runs an entry by its id, on the printers as the list was built (`asBuilt`); one gone meanwhile runs nothing.
    static func run(_ id: String, app: AppModel, asBuilt: [PrinterModel]) {
        if id.hasPrefix("app:") { return runApp(String(id.dropFirst(4)), app: app) }
        if let n = PrintPalette.number(id, after: "show:") {
            guard let p = PrintPalette.target(n, asBuilt, app.printers) else { return }
            return show(p, app: app)
        }
        if let n = PrintPalette.number(id, after: "preset:") {
            guard n < app.presets.count else { return }
            return AppCommands.runPreset(app.presets[n].id, app: app)
        }
        if let (n, command) = PrintPalette.onOther(id) {
            guard let p = PrintPalette.target(n, asBuilt, app.printers) else { return }
            return runPrinter(command, on: p, app: app)
        }
        guard let selected = asBuilt.first(where: { $0.id == app.selectedID }), app.printers.contains(where: { $0 === selected }) else { return }
        if let n = PrintPalette.number(id, after: "section:") {
            show(selected, app: app)
            return app.request(n == 0 ? .status : n == 1 ? .scan : .settings)
        }
        if id.hasPrefix("printer:") { runPrinter(String(id.dropFirst(8)), on: selected, app: app) }
    }

    private static func show(_ p: PrinterModel, app: AppModel) {
        MainWindow.bringForward()
        app.selectedID = p.id
        app.showFleet = false
    }

    /// One of a printer's commands (its toolbar's and menus').
    private static func runPrinter(_ command: String, on p: PrinterModel, app: AppModel) {
        show(p, app: app)
        switch command {
        case "print": Task { await Printing.printPdf(on: p, app: app) }
        case "scan": app.request(.scan)
        case "clipboard": ClipboardPrinting.print(on: p, app: app)
        case "recent": app.request(.recentScans)
        case "setup": Task { Printing.alert(await app.setUpQueue(for: p)) }
        case "reconnect": p.start()
        case "photos": ClipboardPrinting.printPhotos([], app: app)
        case "batch": BatchPrintWindow.show(app)
        case "fix": app.request(.fix)
        case "maintenance": app.request(.status) // the maintenance card is on the status tab
        case "snmp": app.request(.snmpAccess)
        case "remove": confirmRemove(p, app: app)
        default: break
        }
    }

    private static func runApp(_ command: String, app: AppModel) {
        switch command {
        case "add":
            MainWindow.bringForward()
            app.isAddingPrinter = true
        case "setupwifi": PrinterSetupWindow.show(app)
        case "fleet":
            MainWindow.bringForward()
            app.showFleet = true
        case "search": app.searchAgain()
        case "printlog": PrintLogWindow.show(app)
        case "help": HelpWindow.show(app)
        case "report": ReportProblemWindowController.show(app)
        case "about": About.show()
        default: break
        }
    }

    /// Remove from Inkvolt Print…, asked first as the sidebar asks.
    private static func confirmRemove(_ p: PrinterModel, app: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove \(p.name) from Inkvolt Print?")
        alert.informativeText = p.isScannerOnly ? String(localized: "It's listed again when it's connected again.")
            : p.isQueue ? String(localized: "This doesn't remove it from macOS. It's listed again if it's set up in macOS again.")
            : String(localized: "This doesn't remove it from macOS. It won't be listed again when it's found on the network.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, app.printers.contains(where: { $0 === p }) else { return }
        app.remove(p)
    }
}

/// The palette's search field and list.
private struct PaletteView: View {
    let all: [PrintPalette.Entry]
    let runEntry: (PrintPalette.Entry, OpenSettingsAction) -> Void
    let close: () -> Void

    init(all: [PrintPalette.Entry], run: @escaping (PrintPalette.Entry, OpenSettingsAction) -> Void, close: @escaping () -> Void) {
        self.all = all
        self.runEntry = run
        self.close = close
    }
    @State private var query = ""
    @State private var chosen = 0
    @FocusState private var focused: Bool
    @Environment(\.openSettings) private var openSettings

    private var shown: [PrintPalette.Entry] {
        PaletteSearch.filter(all, query, name: \.name, category: \.category, showWhenEmpty: PrintPalette.shownWhenEmpty)
    }

    var body: some View {
        let list = shown
        VStack(spacing: 10) {
            TextField("Search all commands", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
                .onSubmit { if list.indices.contains(chosen) { run(list[chosen]) } }
                .onKeyPress(.downArrow) { move(1, list.count) }
                .onKeyPress(.upArrow) { move(-1, list.count) }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onChange(of: query) { chosen = 0 }
                .accessibilityLabel("Search all commands")
            Divider()
            if list.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(PrintPalette.noMatch(query)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(list.enumerated()), id: \.element.id) { (i: Int, e: PrintPalette.Entry) in row(i, e) }
                        .listStyle(.plain)
                        .onChange(of: chosen) { if list.indices.contains(chosen) { proxy.scrollTo(list[chosen].id) } }
                        .accessibilityLabel("Commands")
                }
            }
        }
        .padding(EdgeInsets(top: 28, leading: 14, bottom: 14, trailing: 14))
        .frame(width: 560, height: 400)
        .onAppear { focused = true }
    }

    private func run(_ e: PrintPalette.Entry) { runEntry(e, openSettings) }

    private func row(_ i: Int, _ e: PrintPalette.Entry) -> some View {
        let label = HStack(spacing: 10) {
            Image(systemName: e.glyph).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).lineLimit(1)
                if !e.category.isEmpty { Text(e.category).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if !e.gesture.isEmpty { Text(e.gesture).font(.callout).foregroundStyle(.secondary) }
        }
        let tappable = label.contentShape(.rect).onTapGesture { run(e) }
        let marked = tappable.listRowBackground(i == chosen ? Color.accentColor.opacity(0.2) : Color.clear)
        return marked.id(e.id).accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }

    private func move(_ by: Int, _ count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        chosen = min(max(chosen + by, 0), count - 1)
        return .handled
    }
}
