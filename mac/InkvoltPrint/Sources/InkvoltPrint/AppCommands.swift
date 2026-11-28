import AppKit
import PrintCore

/// What reaches the app from outside its window, as the Windows app's shell integration, jump list and tray take it: files
/// opened from Finder or dropped on the window (a PDF to Print a PDF, pictures to Print Photos; `HandedFiles`), the command
/// line's `file.pdf --queue <name>`, and a scan preset run from the menu bar's Scan With, the Dock menu, the command palette
/// or `--preset <id>` (handed to a copy already running).
@MainActor
enum AppCommands {
    // MARK: Files

    /// Files handed in: the first PDF to Print a PDF, else the pictures to Print Photos, on the printer `HandedFiles.target`
    /// picks (`queue`: the macOS queue it was meant for, whose printer is chosen when it's listed). Waits up to 10 s for a
    /// printer to be listed (just launched by the file).
    static func open(_ urls: [URL], queue: String? = nil, app: AppModel = .shared) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        let what = HandedFiles.choose(paths) { FileManager.default.fileExists(atPath: $0) }
        guard what != .nothing else {
            if !paths.isEmpty { Printing.alert(String(localized: "Inkvolt Print prints PDFs and pictures. Open other files in their own app to print them.")) }
            return
        }
        if app === AppModel.shared { MainWindow.bringForward() }
        Task {
            for _ in 0..<40 where !app.printers.contains(where: { !$0.isScannerOnly }) { try? await Task.sleep(for: .milliseconds(250)) }
            let meant = queue.flatMap { q in app.printers.first { $0.queueName?.caseInsensitiveCompare(q) == .orderedSame } }
            guard let printer = HandedFiles.target(app.printers, selected: app.selected, meant: meant, prints: { !$0.isScannerOnly }) else {
                switch what {
                case .pdf(let pdf):
                    Printing.alert(String(localized: "Inkvolt Print hasn't found a printer yet, so \"\((pdf as NSString).lastPathComponent)\" can't be printed. Wait for your printer to appear (or add it by address), then open the file again."))
                default:
                    Printing.alert(String(localized: "Inkvolt Print hasn't found a printer yet, so the photos can't be printed. Wait for your printer to appear (or add it by address), then open them again."))
                }
                return
            }
            app.selectedID = printer.id
            app.showFleet = false
            switch what {
            case .pdf(let pdf): await Printing.printPdf(URL(fileURLWithPath: pdf), on: printer, app: app)
            case .pictures(let pictures): ClipboardPrinting.printPhotos(pictures.map { URL(fileURLWithPath: $0) }, app: app)
            case .nothing: break
            }
        }
    }

    /// The command line's files and `--queue` (`Inkvolt Print file.pdf --queue Office_Laser`); the report and snapshot
    /// runs name files of their own and are left alone.
    static func openFromCommandLine(_ args: [String], app: AppModel = .shared) {
        guard !Report.isRunning, !args.contains("--snapshot") else { return }
        let files = HandedFiles.files(in: args)
        if !files.isEmpty { open(files.map { URL(fileURLWithPath: $0) }, queue: HandedFiles.value("--queue", in: args), app: app) }
    }

    // MARK: Scan presets

    /// The presets offered outside the Scan tab (the menu bar's Scan With: Windows' tray offers nine), while some printer
    /// can scan.
    static func presetsToOffer(_ app: AppModel, max: Int = 9) -> [ScanPreset] {
        app.printers.contains(where: \.canScan) ? Array(app.presets.prefix(max)) : []
    }

    /// A preset asked for by name or id (Windows' `RunPresetWhenReadyAsync`): the window comes forward, waits up to 30 s for
    /// the selected printer's scanner, then the Scan tab runs it. A scanner on its own selected, or none: the first printer
    /// that scans. From outside the app (`--preset`, a later launch's hand-over) it asks first, so nothing scans unseen.
    static func runPreset(_ idOrName: String, from origin: PresetOrigin = .insideApp, app: AppModel = .shared) {
        guard let preset = HandedFiles.preset(idOrName, in: app.presets) else { return } // deleted since: nothing to run
        guard origin.asksFirst else {
            run(preset, app: app)
            return
        }
        guard !asking else { return } // one question at a time: more hand-overs while it's open are dropped
        asking = true
        defer { asking = false }
        if app === AppModel.shared { MainWindow.bringForward() }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Scan with \"\(preset.name)\"?")
        alert.informativeText = String(localized: "Inkvolt Print was started with this scan preset from outside the app. Put the pages on the glass or in the feeder, then click Scan.")
        alert.addButton(withTitle: String(localized: "Scan"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(preset, app: app)
    }

    /// A question about a preset from outside is open.
    private static var asking = false

    /// `preset` run as `runPreset` runs it (the report runs one that stops on the pages, so nothing asks where to save).
    static func run(_ preset: ScanPreset, app: AppModel) {
        if app === AppModel.shared { MainWindow.bringForward() }
        Task {
            for _ in 0..<120 where !(app.selected?.canScan ?? false) && !app.printers.contains(where: \.canScan) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let printer = app.selected?.canScan == true ? app.selected : app.printers.first(where: \.canScan) else {
                Printing.alert(String(localized: "No scanner is connected yet, so \"\(preset.name)\" didn't scan. Try again when the printer shows up."))
                return
            }
            app.selectedID = printer.id
            app.showFleet = false
            app.request(.scan) // the scan shows on the printer's Scan tab
            await printer.scan.scan(with: preset)
        }
    }

    // MARK: A copy already running

    /// The notification a second launch hands its `--preset` to the running copy with (Windows' single-instance pipe).
    /// Any process may post it (sandboxed ones too), so its `object` is only a token: the preset waits in this app's own
    /// container (`PresetHandOver`), which no other app can write.
    static let presetNotification = Notification.Name("com.bermudezsystems.InkvoltPrint.preset")

    /// Where a second launch leaves its preset for the running copy: inside the app's sandbox container.
    static var handOverFolder: URL { AppModel.dataFolder.appendingPathComponent("Preset hand-over", isDirectory: true) }

    /// At launch, before the app starts: with `--preset` and another copy of this app running, the preset goes to that copy,
    /// which comes forward and asks before it scans, and this one ends (true).
    static func handOver(_ args: [String]) -> Bool {
        guard let preset = HandedFiles.value("--preset", in: args), !args.contains("--report"),
              let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me })
        else { return false }
        if let token = PresetHandOver(folder: handOverFolder).leave(preset, now: Date()) {
            DistributedNotificationCenter.default().postNotificationName(presetNotification, object: token, userInfo: nil, deliverImmediately: true)
        }
        running.activate()
        return true
    }

    /// The running copy: presets handed over by later launches (only those this app left: `PresetHandOver`), and this
    /// launch's own `--preset`; both come from outside, so each asks before it scans.
    static func listen(_ args: [String], app: AppModel = .shared) {
        DistributedNotificationCenter.default().addObserver(forName: presetNotification, object: nil, queue: .main) { note in
            guard let token = note.object as? String, token.count <= 64 else { return }
            MainActor.assumeIsolated {
                guard let preset = PresetHandOver(folder: handOverFolder).take(token, now: Date()) else { return }
                runPreset(preset, from: .outside)
            }
        }
        if !Report.isRunning, let preset = HandedFiles.value("--preset", in: args) { runPreset(preset, from: .outside, app: app) }
    }

    // MARK: The Dock menu

    /// The Dock menu's Scan: <preset> for the first five (Windows' jump list).
    static func dockMenu(_ app: AppModel) -> NSMenu? {
        let presets = presetsToOffer(app, max: 5)
        guard !presets.isEmpty else { return nil }
        let menu = NSMenu()
        for p in presets {
            let item = NSMenuItem(title: String(localized: "Scan: \(p.name)"), action: #selector(DockTarget.scan(_:)), keyEquivalent: "")
            item.target = DockTarget.shared
            item.representedObject = p.id
            item.toolTip = ScanPresetText.summary(p)
            menu.addItem(item)
        }
        return menu
    }

    /// The Dock menu items' target.
    @MainActor
    final class DockTarget: NSObject {
        static let shared = DockTarget()

        @objc func scan(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            AppCommands.runPreset(id)
        }
    }
}
