import AppKit
import PDFKit
import PrintCore
import PrintMac

/// `open "Inkvolt Print.app" --args --report <name> [--wait <seconds>] [--stay] [--demo] [--search]`: after `--wait` seconds
/// (20 by default) writes what the app shows to `Application Support/InkvoltPrint/report-<name>.txt` in its container, then quits
/// (unless `--stay`); `--search` runs Add a printer's search at launch and lists what it found; `--cancel-mine <queue>`
/// cancels the user's own jobs in that CUPS queue first (as the print queue card's Cancel My Jobs); with `--demo`, `--scan`
/// scans the demo inkjet's feeder and saves a searchable PDF in the container, and says what it holds; `--batch` scans its
/// feeder's batch split at patch codes and saves the files; `--photos` finds the photos on its glass and saves each as a
/// JPEG; `--hardware` runs the new flows on the selected real printer (glass scan with photos, ID card sides, a feeder
/// batch, Set Up in macOS with the queue deleted again; nothing printed or written to the printer); `--papers` lists the paper sizes Print Photos offers for each printer; `--idcard` copies an ID card (both sides from its glass) without printing; `--fix [all]` runs the
/// offline fixer on the office laser (and its repairs); `--setup-probe` asks cupsd to create a queue (a test one, deleted at
/// at once: `CupsSetupProbe`); with `--demo`, `--setup` sets up a demo printer that has no queue. For checking a build over
/// SSH, where no one may be at the screen. Addresses are masked to their last
/// part, so a report can be pasted into a chat.
@MainActor
enum Report {
    static func runIfAsked(_ model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--report") else { return }
        let name = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "app"
        let wait = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 20
        let search = args.contains("--search") ? AddPrinterModel(app: model) : nil
        search?.start()
        let cancelIn = args.firstIndex(of: "--cancel-mine").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Task {
            var cancelled: [String] = []
            if let queue = cancelIn {
                try? await Task.sleep(for: .seconds(3))
                let jobs = PrintJobsModel(queue: queue, app: model)
                await jobs.refresh()
                let mine = jobs.mine.count
                await jobs.cancelMine()
                cancelled = ["Cancel my jobs in \(queue): \(mine) of mine, \(jobs.jobs.count) left\(jobs.message.map { ", " + $0 } ?? "")"]
            }
            if model.isDemo && args.contains("--scan") { cancelled += await scanCheck(model) }
            if model.isDemo && args.contains("--batch") { cancelled += await batchCheck(model) }
            if model.isDemo && args.contains("--photos") { cancelled += await photosCheck(model) }
            if model.isDemo && args.contains("--idcard") { cancelled += await idCardCheck(model) }
            if args.contains("--papers") { cancelled += await papersCheck(model) }
            if !model.isDemo && args.contains("--hardware") { cancelled += await hardwareCheck(model) }
            if args.contains("--icc") { cancelled += await iccCheck() }
            if args.contains("--device") { cancelled += await deviceCheck(model) }
            if args.contains("--setup-probe") { cancelled += await CupsSetupProbe.run() }
            if model.isDemo && args.contains("--setup") { cancelled += await setupCheck(model) }
            if model.isDemo, let i = args.firstIndex(of: "--fix") {
                cancelled += await fixCheck(model, repairAll: i + 1 < args.count && args[i + 1] == "all")
            }
            try? await Task.sleep(for: .seconds(wait))
            let folder = AppModel.dataFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data((text(model, after: wait, search: search) + cancelled.map { $0 + "\n" }.joined()).utf8).write(to: folder.appendingPathComponent("report-\(name).txt"), options: .atomic)
            if !args.contains("--stay") { NSApp.terminate(nil) }
        }
    }

    /// "Set up in macOS" on the first connected demo printer macOS has no queue for, as the status pane's button does.
    private static func setupCheck(_ model: AppModel) async -> [String] {
        for _ in 0..<80 where !model.printers.contains(where: { $0.isNetwork && $0.view.isOnline && $0.queueName == nil }) || model.destinations == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let p = model.printers.first(where: { $0.isNetwork && $0.view.isOnline && $0.queueName == nil }) else {
            return ["setup: every connected printer has a queue"]
        }
        let message = await model.setUpQueue(for: p)
        return ["setup: \(p.name): \(message) Queue now: \(p.queueName ?? "none")"]
    }

    /// The selected printer's settings, firmware update mode and maintenance actions, as the Settings tab and the maintenance
    /// card read them (nothing is written or sent).
    private static func deviceCheck(_ model: AppModel) async -> [String] {
        guard let p = model.selected else { return ["device: no printer selected"] }
        for _ in 0..<60 where !p.view.isOnline { try? await Task.sleep(for: .milliseconds(250)) }
        let settings = DeviceSettingsModel(printer: p)
        await settings.load()
        var lines = ["device: \(p.name): \(settings.settings?.items.count ?? 0) settings\(settings.problem.map { " (" + $0 + ")" } ?? "")"]
        for item in settings.settings?.items ?? [] {
            lines.append("  setting \(item.def.group) / \(item.def.label): \(item.display(item.value)) (\(item.choices.count) choices)")
        }
        if let fw = settings.firmware {
            lines.append("  firmware updates: \(fw.mode), choices \(fw.choices), can change \(fw.canChange), \(fw.statusMessage ?? "-")")
        }
        let maintenance = MaintenanceModel(printer: p)
        await maintenance.load()
        for a in maintenance.options.actions { lines.append("  maintenance: \(a.label)\(maintenance.whyNot(a).map { " (" + $0 + ")" } ?? "")") }
        if let note = maintenance.options.note { lines.append("  maintenance note: \(note)") }
        return lines
    }

    /// What ImageCaptureCore lists, and each scanner's glass and feeder as the Scan tab would see them (a session is opened;
    /// nothing is scanned).
    private static func iccCheck() async -> [String] {
        let scanners = SystemScanners(network: true) { _ in }
        scanners.start()
        try? await Task.sleep(for: .seconds(6))
        var lines = ["ICC: \(scanners.allDevices.count) scanner(s)"]
        for (s, device) in scanners.allDevices {
            var caps: ScannerCapabilities?
            var failure = ""
            do { caps = try await device.capabilities() } catch { failure = " (" + String(describing: error) + ")" }
            let describe: (InputCaps?) -> String = { c in c.map { "\($0.maxWidth)x\($0.maxHeight)/300 in, \($0.resolutions.count) resolutions" } ?? "-" }
            lines.append("  \(s.usb ? "USB" : "network") \(s.name): glass \(describe(caps?.platen)), feeder \(describe(caps?.adf))\(failure)")
        }
        scanners.stop()
        return lines
    }

    /// Demo mode: the offline fixer on the office laser (moved to a new address; its queue paused with a stuck job), and with
    /// `--fix all` its repairs.
    private static func fixCheck(_ model: AppModel, repairAll: Bool) async -> [String] {
        guard let office = model.printers.first(where: { $0.id == Demo.officeUuid }) else { return ["fix: no office laser"] }
        let fixer = OfflineFixerModel(printer: office, app: model)
        fixer.run()
        for _ in 0..<100 where fixer.running { try? await Task.sleep(for: .milliseconds(200)) }
        guard let r = fixer.report else { return ["fix: no report"] }
        var lines = ["fix: \(r.headline) (moved: \(r.moved), adoption: \(r.adoption), adopted: \(fixer.adopted ?? "-"))"]
        for c in fixer.checks { lines.append("  check \(c.state) \(c.title): \(c.detail)") }
        for (i, repair) in r.repairs.enumerated() {
            lines.append("  repair \(repair.kind)\(repair.manualOnly ? " (steps only)" : ""): \(repair.title)")
            if repairAll && !repair.manualOnly {
                fixer.repair(i)
                for _ in 0..<50 where fixer.working != nil || fixer.outcomes[i] == nil { try? await Task.sleep(for: .milliseconds(100)) }
                lines.append("    -> \(fixer.outcomes[i].map { "\($0.kind): \($0.message)" } ?? "no outcome")")
            }
        }
        return lines
    }

    /// Demo mode: the inkjet's feeder (a straight page, a crooked one, a blank sheet) through the review and a searchable PDF.
    private static func scanCheck(_ model: AppModel) async -> [String] {
        guard let laser = model.printers.first(where: { $0.id == Demo.inkjetUuid }) else { return ["scan: no demo inkjet"] }
        for _ in 0..<50 where !laser.view.isOnline { try? await Task.sleep(for: .milliseconds(200)) }
        let scan = laser.scan
        await scan.load()
        guard scan.sources.contains(.adf) else { return ["scan: no feeder (\(scan.loadError ?? "-"), sources \(scan.sources), online \(laser.view.isOnline), \(laser.view.interfaces))"] }
        scan.source = .adf
        scan.format = .searchablePdf
        scan.skipBlank = true
        scan.straighten = true
        scan.splitAt = .none
        scan.scan()
        for _ in 0..<100 where scan.isScanning || scan.pages.pages.contains(where: { !$0.analysed }) { try? await Task.sleep(for: .milliseconds(200)) }
        let notes = scan.pages.pages.map { $0.note.isEmpty ? "-" : $0.note }.joined(separator: ", ")
        var lines = ["scan: \(scan.pages.summary); notes: \(notes)"]
        for p in scan.pages.pages where p.edits.deskew != 0 {
            let left = await scan.residualSkew(p.id)
            lines.append("straightened by " + String(format: "%.2f", p.edits.deskew) + ", left after: " + (left.map { String(format: "%.2f", $0) } ?? "-"))
        }
        let url = AppModel.dataFolder.appendingPathComponent("scan-check.pdf")
        await scan.save(to: url, reveal: false)
        let pdf = PDFDocument(url: url)
        let text = pdf?.string ?? ""
        lines.append("scan saved: \(scan.status) \(scan.problem ?? "")")
        lines.append("PDF pages \(pdf?.pageCount ?? 0), text \(text.count) characters, finds 'demo scanner': \(text.contains("demo scanner"))")
        // A one-click preset into a remembered folder (made here: no one picks it over SSH).
        if let p = model.presets.first {
            let folder = AppModel.dataFolder.appendingPathComponent("preset-check", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.setPresetFolder(p.id, folder)
            await scan.scan(with: p)
            for _ in 0..<150 where scan.isScanning || scan.isSaving || !scan.pages.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
            lines.append("preset \(p.name): \(scan.status) \(scan.problem ?? ""); files: \(files.sorted().joined(separator: ", "))")
        }
        return lines
    }

    /// The demo inkjet ready to scan, its review empty.
    private static func demoScanner(_ model: AppModel) async -> ScanModel? {
        guard let inkjet = model.printers.first(where: { $0.id == Demo.inkjetUuid }) else { return nil }
        for _ in 0..<50 where !inkjet.view.isOnline { try? await Task.sleep(for: .milliseconds(200)) }
        let scan = inkjet.scan
        await scan.load()
        scan.clear()
        return scan.caps == nil ? nil : scan
    }

    private static func scanAndWait(_ scan: ScanModel) async {
        scan.scan()
        for _ in 0..<150 where scan.isScanning || scan.pages.pages.contains(where: { !$0.analysed }) { try? await Task.sleep(for: .milliseconds(200)) }
    }

    private static func files(in folder: URL) -> String {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().joined(separator: ", ")
    }

    /// Demo mode: the feeder's batch (two pages, a Patch T sheet, three more) split at patch codes, saved as PDFs in a folder.
    private static func batchCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["batch: no demo inkjet"] }
        scan.source = .adf
        scan.format = .pdf
        scan.skipBlank = true
        scan.straighten = true
        scan.splitAt = .patchCode
        scan.keepSeparators = false
        await scanAndWait(scan)
        let notes = scan.pages.pages.map { p in
            let file = scan.pages.fileStart(p.id)
            return (file > 0 ? "[file \(file)] " : "") + (p.note.isEmpty ? "-" : p.note)
        }
        var lines = ["batch: \(scan.status)", "  pages: \(notes.joined(separator: ", "))"]
        let folder = AppModel.dataFolder.appendingPathComponent("batch-check", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await scan.save(to: folder, reveal: false)
        lines.append("  saved: \(scan.status) \(scan.problem ?? "")")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
            lines.append("  \(name): \(PDFDocument(url: folder.appendingPathComponent(name))?.pageCount ?? 0) pages")
        }
        scan.splitAt = .none
        return lines
    }

    /// The selected real printer through the new flows, as far as no one at the printer is needed: whatever is on the glass
    /// scanned with photos looked for, the ID card's two sides, a feeder batch split at patch codes (the feeder may be
    /// empty: its error is reported), and Set Up in macOS for real, the queue it makes deleted again.
    private static func hardwareCheck(_ model: AppModel) async -> [String] {
        for _ in 0..<80 where model.selected?.view.isOnline != true { try? await Task.sleep(for: .milliseconds(250)) }
        guard let p = model.selected, p.isNetwork, p.view.isOnline else { return ["hardware: no connected network printer selected"] }
        var lines = ["hardware: \(p.name), queue \(p.queueName == nil ? "none" : "set up"), host name \(p.hostName == nil ? "unknown" : "known")"]
        let scan = p.scan
        await scan.load()
        scan.clear()
        lines.append("  sources: \(scan.sources), resolutions \(scan.resolutions)")
        // The glass, photos looked for.
        scan.source = .platen
        scan.format = .jpeg
        scan.straighten = true
        scan.findPhotos = true
        let started = Date()
        await scanAndWait(scan)
        lines.append("  glass: " + String(format: "%.1f s, ", Date().timeIntervalSince(started)) + "\(scan.status) \(scan.problem ?? "")")
        for page in scan.pages.pages {
            lines.append("    page \(page.dpi) dpi, note '\(page.note)', looks blank \(page.looksBlank), photos \(page.photos?.count ?? -1)")
        }
        if !scan.pages.toSave.isEmpty {
            let folder = AppModel.dataFolder.appendingPathComponent("hardware-glass", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await scan.save(to: folder, reveal: false)
            lines.append("    saved: \(scan.status) \(scan.problem ?? "")")
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
                let size = ScanImaging.size((try? Data(contentsOf: folder.appendingPathComponent(name))).map(Array.init) ?? [])
                lines.append("    \(name): \(size.map { "\($0.width) × \($0.height) px" } ?? "unreadable")")
            }
        }
        scan.clear()
        scan.findPhotos = false
        // The ID card copy's two sides, not printed.
        let card = IdCardCopyModel(printer: p, app: model)
        await card.scanSide(printWhenDone: false)
        await card.scanSide(printWhenDone: false)
        let sheet = card.document?.page(at: 0)?.bounds(for: .mediaBox).size
        lines.append("  id card: \(card.step), sheet \(sheet.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "none"), front \(card.front.map { "\(Int($0.size.width)) × \(Int($0.size.height))" } ?? "-") \(card.problem ?? "")")
        // A feeder batch (the feeder may be empty).
        if scan.sources.contains(.adf) {
            scan.source = .adf
            scan.format = .pdf
            scan.splitAt = .patchCode
            await scanAndWait(scan)
            lines.append("  feeder batch: \(scan.status) \(scan.problem ?? "")")
            scan.clear()
            scan.splitAt = .none
        }
        // Set Up in macOS as the button does it, then the queue it made deleted.
        let before = Set((await LibCups().destinations() ?? []).map(\.name))
        let message = await model.setUpQueue(for: p)
        let after = await LibCups().destinations() ?? []
        let made = after.filter { !before.contains($0.name) }
        lines.append("  set up: \(message)")
        for d in made {
            let uri = d.deviceUri?.split(separator: ":").first.map(String.init) ?? "-"
            let local = d.deviceUri?.contains(".local") == true
            lines.append("    made \(d.name): real queue \(CupsQueues.isRealQueue(d)), scheme \(uri), on the .local name \(local), model \(d.options["printer-make-and-model"] ?? "-")")
            lines.append("    deleted: \(await CupsSetupProbe.delete(d.name))")
        }
        return lines
    }

    /// The papers Print Photos offers for each printer with a queue (its media list through libcups), borderless ones marked.
    private static func papersCheck(_ model: AppModel) async -> [String] {
        try? await Task.sleep(for: .seconds(4)) // the queues are read
        var lines: [String] = []
        for p in model.printers where p.queueName != nil || (model.isDemo && p.id == Demo.inkjetUuid) {
            let choices = QueuePapers.photoChoices(await model.photoMedia(for: p))
            lines.append("papers \(p.name): " + (choices.isEmpty ? "none listed" : choices.map { $0.label + ($0.borderless != nil ? " (+borderless)" : "") }.joined(separator: ", ")))
        }
        return lines.isEmpty ? ["papers: no printer has a queue"] : lines
    }

    /// Demo mode: an ID card copy, front and back from the inkjet's glass, laid out on one sheet (not printed).
    private static func idCardCheck(_ model: AppModel) async -> [String] {
        guard let inkjet = model.printers.first(where: { $0.id == Demo.inkjetUuid }) else { return ["idcard: no demo inkjet"] }
        for _ in 0..<50 where !inkjet.view.isOnline { try? await Task.sleep(for: .milliseconds(200)) }
        let copy = IdCardCopyModel(printer: inkjet, app: model)
        await copy.scanSide(printWhenDone: false)
        let afterFront = "\(copy.step)"
        await copy.scanSide(printWhenDone: false)
        guard let page = copy.document?.page(at: 0) else { return ["idcard: \(afterFront), \(copy.step), \(copy.problem ?? "no sheet")"] }
        let size = page.bounds(for: .mediaBox).size
        return ["idcard: after the front \(afterFront), then \(copy.step); sheet \(Int(size.width)) × \(Int(size.height)) pt, \(copy.document?.pageCount ?? 0) page \(copy.problem ?? "")"]
    }

    /// Demo mode: three photos on the glass, found and saved as JPEGs, each cut out straight.
    private static func photosCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["photos: no demo inkjet"] }
        scan.source = .platen
        scan.format = .jpeg
        scan.findPhotos = true
        await scanAndWait(scan)
        var lines = ["photos: \(scan.status)"]
        for p in scan.pages.pages {
            for (i, b) in (p.photos ?? []).enumerated() {
                lines.append("  photo \(i + 1): centre " + String(format: "%.2f, %.2f", b.centerX, b.centerY) + ", " + String(format: "%.2f × %.2f", b.width, b.height)
                             + ", " + String(format: "%.1f°", b.angle))
            }
        }
        let folder = AppModel.dataFolder.appendingPathComponent("photos-check", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await scan.save(to: folder, reveal: false)
        lines.append("  saved: \(scan.status) \(scan.problem ?? "")")
        for name in files(in: folder).split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            let bytes = (try? Data(contentsOf: folder.appendingPathComponent(name))).map(Array.init) ?? []
            let size = ScanImaging.size(bytes)
            let skew = (try? ScanImaging.analysis(bytes)).map(Deskew.angle)
            lines.append("  \(name): \(size.map { "\($0.width) × \($0.height)" } ?? "-") px, skew left " + (skew.map { String(format: "%.2f", $0) } ?? "-"))
        }
        scan.findPhotos = false
        return lines
    }

    static func text(_ model: AppModel, after wait: Double, search: AddPrinterModel? = nil) -> String {
        var lines = [
            "Inkvolt Print report, \(Int(wait)) s after launch\(model.isDemo ? " (demo)" : "")",
            "Local Network: \(model.localNetwork)",
            "Searching: \(model.isSearching)",
            "Menu bar: \(model.overall)",
            "Printers: \(model.printers.count)",
            "macOS queues: \(model.destinations.map { "\($0.count), \($0.filter(CupsQueues.isRealQueue).count) set up" } ?? "not read")",
        ]
        for p in model.printers {
            let v = p.view
            lines.append("")
            let reached = p.destination.map { "queue, " + CupsQueues.connectionText($0) } ?? mask(p.host)
            lines.append("\(p.name) [\(reached)]\(p.id == model.selectedID ? " (selected)" : "")")
            lines.append("  \(v.phase): \(v.listLine)")
            if let detail = v.statusDetail { lines.append("  " + mask(detail, host: p.host)) }
            if let m = v.model ?? p.model { lines.append("  model: \(m)") }
            if let s = p.systemScanner { lines.append("  USB scanner: \(s.name)\(p.isScannerOnly ? " (a scanner of its own)" : "")") }
            if let q = p.queueName {
                lines.append("  macOS queue: \(q), prints on: \(Printing.macPrinter(for: p, app: model)?.name ?? "not found by AppKit")")
            }
            if !v.interfaces.isEmpty { lines.append("  over: \(v.interfaces.joined(separator: ", "))") }
            if let f = v.firmware { lines.append("  firmware: \(f.display)") }
            for s in v.supplies.map({ SupplyText($0) }) {
                lines.append("  supply: \(s.name): \(s.percentText)\(s.headline.map { ", \($0)" } ?? "")")
            }
            for a in v.alerts { lines.append("  alert (\(a.severity)): \(a.message)") }
            if let u = v.usage, let pages = u.totalImpressions { lines.append("  pages printed: \(pages)") }
        }
        for (_, line) in model.menuLines { lines.append("menu: \(line.level) \(line.name): \(line.text)") }
        if let search {
            lines.append("")
            lines.append("Add a printer: \(search.isSearching ? "searching" : "done"), \(mask(search.status, hosts: search.found.map(\.host)))")
            for f in search.found { lines.append("  \(f.state) \(f.name) [\(mask(f.host))]: \(mask(f.detail, host: f.host))") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mask(_ host: String) -> String {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy({ Int($0) != nil }) ? "*.*.*.\(parts[3])" : "host"
    }

    private static func mask(_ text: String, host: String) -> String { text.replacingOccurrences(of: host, with: mask(host)) }

    private static func mask(_ text: String, hosts: [String]) -> String { hosts.reduce(text) { mask($0, host: $1) } }
}

#if DEBUG
import ScreenCaptureKit

/// Debug builds only (`build.sh debug`): `open "Inkvolt Print.app" --args --demo --snapshot laser:0,inkjet:1
/// [--size 1180x720] [--dark] [--wait <seconds>]`. After `--wait` seconds (8 by default) shows the main window at
/// `--size` points and, for each `name:index`, selects the index-th printer and captures the window with ScreenCaptureKit
/// (as the screen shows it, at its scale, without the shadow) to `Application Support/InkvoltPrint/snapshot-<name>.png` in
/// the container, then quits. For the App Store screenshots. Needs Screen Recording permission for this build (macOS asks
/// the first time) and the Mac's screen unlocked. Release builds have none of this.
@MainActor
enum Snapshot {
    static func runIfAsked(_ model: AppModel) {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--open-demo") { // what "Try the Demo" does, from the sandbox
            Task {
                try? await Task.sleep(for: .seconds(3))
                model.openDemo()
            }
        }
        guard let list = value("--snapshot") else { return }
        let shots = list.split(separator: ",").map { item -> (String, Int) in
            let parts = item.split(separator: ":")
            return (String(parts[0]), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
        let size = value("--size").map { $0.split(separator: "x").compactMap { Double($0) } } ?? [1180, 720]
        let wait = value("--wait").flatMap(Double.init) ?? 8
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task {
            try? await Task.sleep(for: .seconds(wait))
            MainWindow.bringForward()
            try? await Task.sleep(for: .seconds(1))
            let folder = AppModel.dataFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var log: [String] = []
            for (name, index) in shots {
                if index < model.printers.count { model.selectedID = model.printers[index].id }
                guard let window = mainWindow() else {
                    log.append("\(name): no window")
                    break
                }
                if size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
                window.center()
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1.5))
                do {
                    let png = try await capture(window)
                    try png.write(to: folder.appendingPathComponent("snapshot-\(name).png"))
                    log.append("\(name): ok")
                } catch {
                    log.append("\(name): \(error)")
                }
            }
            try? Data(log.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("snapshot-log.txt"))
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(target.frame.width * scale)
        config.height = Int(target.frame.height * scale)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                               configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(MainWindow.id) == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && !($0 is NSPanel) }
    }
}
#endif
