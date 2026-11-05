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
/// JPEG (the feeder sends PDF only: `--scan` also saves its pages as the scanner's own PDF, and with a page turned);
/// `--firmware` shows the demo laser's firmware notice, runs Keep My Cartridges Working and dismisses the notice;
/// `--history` checks the supply history (where it's kept, Export history…'s CSV saved in the container, and with `--demo`,
/// which reads and saves nothing real, the CSV in memory and the Pro gate switched on without a key); every printer's supplies list their history line and chart; `--hardware` runs the new flows on the selected real printer (glass scan with photos, ID card sides, a feeder
/// batch, Set Up in macOS with the queue deleted again; nothing printed or written to the printer); `--papers` lists the paper sizes Print Photos offers for each printer, with its paper types, qualities and colors;
/// `--photo-job` sends Print Photos' job (one sheet, the queue's photo choices) to each printer's macOS queue held, reads
/// back what cupsd took and cancels it (nothing prints); `--idcard` copies an ID card (both sides from its glass) without printing; `--fix [all]` runs the
/// offline fixer on the office laser (and its repairs); `--setup-probe` asks cupsd to create a queue (a test one, deleted at
/// at once: `CupsSetupProbe`); with `--demo`, `--setup` sets up a demo printer that has no queue; every report ends with the
/// Inkvolt Pro line, and `--pro-window`, `--pro-key <key>`, `--pro-remove <key>` check Help › Inkvolt Pro… (`proCheck`);
/// `--record <address> <folder> [--record-scan] [--community name] [--escl url] [--ipp url] [--force]` records a printer
/// (`RecordCommand`, roadmap 1.2) into `Recordings/<folder>` in the container (demo mode: the made-up printers, into a
/// temporary folder); `--problem` opens Help › Report a Problem… and lists its details, `--problem-record` also runs its
/// Record This Printer and reads the .zip back (`problemCheck`); `--fleet [fix] [status]` shows the Fleet page and lists its
/// rows as VoiceOver reads them, checks Export…'s CSV and JSON (in memory in demo mode; else saved in the container) and the Pro
/// gate, `fix` runs Fix All on demo mode's made-up queues saying yes to each question, `status` runs `status --all --json`
/// through the reader (`fleetCheck`). For checking a build over
/// SSH, where no one may be at the screen. Addresses are masked to their last
/// part, so a report can be pasted into a chat.
@MainActor
enum Report {
    /// The app was started by `--report`: windows open, nothing opens another app or the browser.
    static var isRunning: Bool { CommandLine.arguments.contains("--report") }

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
            if model.isDemo && args.contains("--firmware") { cancelled += await firmwareCheck(model) }
            if args.contains("--history") { cancelled += await historyCheck(model) }
            if args.contains("--papers") { cancelled += await papersCheck(model) }
            if !model.isDemo && args.contains("--photo-job") { cancelled += await photoJobCheck(model) }
            if !model.isDemo && args.contains("--hardware") { cancelled += await hardwareCheck(model) }
            if args.contains("--icc") { cancelled += await iccCheck() }
            if args.contains("--device") { cancelled += await deviceCheck(model) }
            if args.contains("--setup-probe") { cancelled += await CupsSetupProbe.run() }
            if model.isDemo && args.contains("--setup") { cancelled += await setupCheck(model) }
            if let command = RecordCommand.parse(args, keyword: "--record") {
                cancelled += await command.run(in: model.recordingsFolder, transport: model.recordingTransport(), snmp: model.snmpTransport,
                                               who: .current)
            }
            if args.contains("--problem") || args.contains("--problem-record") {
                cancelled += await problemCheck(model, record: args.contains("--problem-record"))
            }
            if let i = args.firstIndex(of: "--fleet") {
                let words = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
                cancelled += await fleetCheck(model, fix: words.contains("fix"), status: words.contains("status"))
            }
            if model.isDemo, let i = args.firstIndex(of: "--fix") {
                cancelled += await fixCheck(model, repairAll: i + 1 < args.count && args[i + 1] == "all")
            }
            cancelled += proCheck(args)
            try? await Task.sleep(for: .seconds(wait))
            let folder = AppModel.dataFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data((text(model, after: wait, search: search) + cancelled.map { $0 + "\n" }.joined()).utf8).write(to: folder.appendingPathComponent("report-\(name).txt"), options: .atomic)
            if !args.contains("--stay") { NSApp.terminate(nil) }
        }
    }

    /// The Inkvolt Pro check, always one line (`ProSetup.reportLine`). `--pro-window` opens Help › Inkvolt Pro… and says
    /// what it shows; `--pro-key <key>` enters a key as the window does, only when none is installed (a key already there is
    /// never replaced); `--pro-remove <key>` removes the installed key only when it is that one.
    private static func proCheck(_ args: [String]) -> [String] {
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        var lines: [String] = []
        if let key = value("--pro-key") {
            if Pro.store.read() != nil {
                lines.append("pro-key: a key is installed already; left as it is")
            } else {
                ProPanel.shared.key = key
                let entered = ProPanel.shared.enter()
                lines.append("pro-key: \(entered ? "entered, licensed to \(Pro.licence?.name ?? "?")" : "refused: \(ProPanel.shared.error ?? "?")")")
            }
        }
        if let key = value("--pro-remove") {
            if Pro.store.read() == ProKeys.format(key) {
                ProPanel.shared.remove()
                lines.append("pro-remove: removed")
            } else {
                lines.append("pro-remove: the installed key isn't that one; left as it is")
            }
        }
        if args.contains("--pro-window") {
            ProWindow.show()
            let size = ProWindow.size.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "not shown"
            let shown = Pro.licence.map { ProView.keyFor($0) } ?? (Pro.enforced ? "Free" : "Everything is free while Inkvolt Print launches")
            lines.append("pro-window: \(size); \(Pro.licence.map { "Pro licensed to \($0.name). " } ?? "")\(shown)")
        }
        return lines + [ProSetup.reportLine]
    }

    /// The Fleet page (roadmap 2.6): its summary and rows (VoiceOver's words, and which offer Fix It…), Export…'s two files with
    /// the identifiers that must not be in them looked for, the Pro gate in front of Export… and Fix All; `fix`: Fix All on
    /// demo mode's made-up queues, every question answered yes (never on this Mac's real queues: a person answers those);
    /// `status`: `status --all --json` through `FleetReader`, as Terminal runs it, and refused with the gate on. Outside demo
    /// mode every line is scrubbed (`Diagnostics.scrub`) and the exports are saved in the container as `report-fleet.*`.
    private static func fleetCheck(_ model: AppModel, fix: Bool, status: Bool) async -> [String] {
        for _ in 0..<80 where model.printers.contains(where: { $0.isNetwork && $0.view.phase == .connecting }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        model.showFleet = true
        let page = model.fleet
        page.refresh()
        let who = Diagnostics.Identity.current
        func clean(_ text: String) -> String { model.isDemo ? text : Diagnostics.scrub(text, who) }
        var lines = ["fleet: \(clean(page.summary))"]
        for row in page.rows { lines.append("  \(clean(row.accessibleText))" + (page.canFix(row) ? " [Fix It…]" : "")) }

        let secrets = [Demo.uuid, Demo.inkjetUuid, Demo.officeUuid, Demo.cdmUuid, "192.0.2.", "DEMO0005200", "CNB0A00000", "demo-mac", who.userName ?? "", who.machineName ?? ""]
        func leaks(_ data: Data) -> [String] {
            let text = String(decoding: data, as: UTF8.self)
            return secrets.filter { !$0.isEmpty && text.range(of: $0, options: .caseInsensitive) != nil }
        }
        if FleetExport.allowed {
            let csv = page.exportBytes(json: false), json = page.exportBytes(json: true)
            let csvText = String(decoding: csv, as: UTF8.self)
            let csvRows = csvText.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count - 1
            let leaked = leaks(csv) + leaks(json)
            let bom = csv.starts(with: [0xEF, 0xBB, 0xBF]), ascii = json.allSatisfy { $0 < 0x80 }
            let left = leaked.isEmpty ? "none" : "\(leaked.count)"
            lines.append("export: CSV \(csvRows) rows, \(csv.count) bytes, byte order mark \(bom); JSON \(json.count) bytes, ASCII \(ascii); identifiers left: \(left)")
            if model.isDemo {
                lines.append("  in memory: nothing is saved in demo mode")
            } else {
                for name in ["report-fleet.csv", "report-fleet.json"] {
                    let saved = await page.write(to: AppModel.dataFolder.appendingPathComponent(name))
                    lines.append("  \(name): \(saved ? "saved" : page.exportMessage ?? "not saved")")
                }
            }
        } else {
            lines.append("export: refused by the Pro check (the button opens the Pro window)")
        }
        let enforced = Pro.enforced
        Pro.enforced = true
        let gated = Pro.allows(.fleetExport)
        lines.append("gate: with the Pro check on and \(Pro.licence == nil ? "no key" : "a key"), Export… and Fix All \(gated ? "allowed" : "refused")")
        Pro.enforced = enforced

        if fix && model.isDemo {
            let asked = Asked()
            await page.fixAll(confirm: { repair in
                asked.add(repair.question ?? repair.title)
                return true
            })
            lines.append("fix all: \(page.fixSummary ?? "-")")
            lines += asked.all.map { "  asked: \($0)" }
            lines += page.fixSteps.map { "  \($0.title): \($0.message)" }
            lines += page.fixLeft.map { "  left: \($0)" }
        } else if fix {
            lines.append("fix all: not run outside demo mode (each question needs a person)")
        }

        if status {
            let fleet = model.fleetMac
            let start = Date()
            let read: @Sendable () async throws -> FleetRead = { try await FleetReader.readAll(fleet, now: Date()) }
            let r = await FleetCommand.run(["status", "--all", "--json"], read: read, now: { Date() }, who)
            let printers = r.output.components(separatedBy: "\"trouble\":").count - 1
            let took = String(format: "%.1f", Date().timeIntervalSince(start))
            let leftIn = leaks(Data(r.output.utf8)).count
            lines.append("status --all --json: exit \(r.code), \(r.output.utf8.count) bytes, \(printers) printers, \(took) s; identifiers left: \(leftIn)")
            Pro.enforced = true
            let refused = await FleetCommand.run(["status", "--all", "--json"], read: read, now: { Date() }, who)
            Pro.enforced = enforced
            let why = refused.error.split(separator: "\n").first.map(String.init) ?? "-"
            lines.append("  with the Pro check on: exit \(refused.code), \(refused.output.count) bytes on standard output, \(clean(why))")
        }
        return lines
    }

    /// The questions a check answered, from the task that asked them.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.withLock { list } }
        func add(_ s: String) { lock.withLock { list.append(s) } }
    }

    /// Help › Report a Problem… (roadmap 1.2): the window, its details as copied and the issue it would open; with `record`,
    /// Record This Printer on the printer shown (the selected one, once it answered), the .zip read back (each file, and
    /// whether the printer's address or this Mac's names are left in any), then a second recording stopped by closing the
    /// window, which must leave nothing.
    private static func problemCheck(_ model: AppModel, record: Bool) async -> [String] {
        for _ in 0..<80 where model.printers.contains(where: { $0.isNetwork && $0.view.phase == .connecting }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let w = ReportProblemWindowController.show(model)
        let size = w.window.map { "\(Int($0.frame.width)) × \(Int($0.frame.height)) pt" } ?? "not shown"
        var lines = ["problem: window \(size), Record This Printer \(w.recordButton.isEnabled ? "enabled" : "disabled")",
                     "  note: \(w.recordNote.stringValue)"]
        lines += w.details.string.split(separator: "\n", omittingEmptySubsequences: false).map { "  | " + $0 }
        w.issueClicked()
        lines.append("  issue: \(w.openedIssue.map { "\($0.host ?? "?")\($0.path), \($0.absoluteString.count) characters" } ?? "none"); \(w.status.stringValue)")
        guard record else { return lines }
        let printer = model.printers.first { $0.id == model.selectedID }
        let host = printer?.recordHost
        await w.record()
        lines.append("  recorded: \(w.status.stringValue)")
        if let zip = w.recording {
            lines.append("  in: \(zip.deletingLastPathComponent() == model.recordingsFolder ? model.recordingsFolder.lastPathComponent : "elsewhere")")
            do {
                let entries = try ZipArchive.entries(Array(try Data(contentsOf: zip)))
                lines.append("  zip: \(zip.lastPathComponent), \(entries.count) files, \(entries.reduce(0) { $0 + $1.bytes.count }) bytes")
                let who = Diagnostics.Identity.current
                // The demo laser's address is the stand-in's own (192.0.2.10), so it isn't looked for.
                let address = host == FixtureScrubber.defaultPlaceholderHost ? nil : host
                let identifiers = [address, who.userName, who.machineName].compactMap { $0 }.filter { $0.count >= 3 }
                var left: [String] = []
                for e in entries {
                    let text = String(decoding: e.bytes, as: UTF8.self)
                    for id in identifiers where text.range(of: id, options: .caseInsensitive) != nil { left.append(e.name) }
                }
                lines.append("  the address or this Mac's names in the files: \(left.isEmpty ? "none" : Set(left).sorted().joined(separator: ", "))")
                lines += entries.map { "    \($0.name) (\($0.bytes.count) bytes)" }
            } catch {
                lines.append("  zip: not read: \(error)")
            }
            lines.append("  details now end with: \(w.details.string.split(separator: "\n").last.map(String.init) ?? "-")")
        }
        // Closing while a recording runs stops it and leaves nothing.
        let folder = model.recordingsFolder
        func count() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count }
        let before = count()
        w.recordClicked()
        try? await Task.sleep(for: .milliseconds(30))
        // Help › Report a Problem… again while it records: the recording goes on, and the window still says so.
        ReportProblemWindowController.show(model)
        lines.append("  opened again while recording: \(w.status.stringValue)")
        w.window?.performClose(nil)
        try? await Task.sleep(for: .seconds(3))
        lines.append("  closed while recording: \(before) entries in the recordings folder before, \(count()) after")
        return lines
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
        var lines = ["scan: \(scan.pages.summary); notes: \(notes)", "scan status: \(scan.status)"]
        for p in scan.pages.pages where p.edits.deskew != 0 {
            let left = await scan.residualSkew(p.id)
            lines.append("straightened by " + String(format: "%.2f", p.edits.deskew) + ", left after: " + (left.map { String(format: "%.2f", $0) } ?? "-"))
        }
        let url = AppModel.dataFolder.appendingPathComponent("scan-check.pdf")
        await scan.save(to: url, reveal: false)
        let pdf = PDFDocument(url: url)
        let text = pdf?.string ?? ""
        lines.append("scan saved: \(scan.status) \(scan.problem ?? ""); for Open in Inkvolt PDF: \(scan.savedPdfs.map(\.lastPathComponent)), installed: \(InkvoltPdfApp.url != nil)")
        lines.append("PDF pages \(pdf?.pageCount ?? 0), text \(text.count) characters, finds 'demo scanner': \(text.contains("demo scanner"))")
        lines += await asSentCheck(scan)
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

    /// Demo mode's inkjet feeder sends PDF only (roadmap 1.3): its three pages, nothing changed, saved as PDF are the scanner's
    /// own file; one page turned, they're made from its pages. The settings the tab had are put back.
    private static func asSentCheck(_ scan: ScanModel) async -> [String] {
        let skip = scan.skipBlank, straight = scan.straighten, format = scan.format
        defer {
            scan.skipBlank = skip
            scan.straighten = straight
            scan.format = format
        }
        scan.clear()
        scan.source = .adf
        scan.format = .pdf
        scan.skipBlank = false
        scan.straighten = false
        scan.splitAt = .none
        var lines: [String] = []
        for turn in [false, true] {
            await scanAndWait(scan)
            if turn, let first = scan.pages.pages.first { scan.turn(first.id, 1) }
            let url = AppModel.dataFolder.appendingPathComponent(turn ? "scan-as-sent-turned.pdf" : "scan-as-sent.pdf")
            await scan.save(to: url, reveal: false)
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            let own = bytes.range(of: Data("/Producer (Inkvolt Print) /Title (Scan)".utf8)) != nil // ScannerPdf.write's, not ScanPdf's
            lines.append("as sent\(turn ? " (a page turned)" : ""): \(scan.status) \(scan.problem ?? ""); pages \(PDFDocument(url: url)?.pageCount ?? 0), the scanner's own bytes: \(own)")
        }
        return lines
    }

    /// Demo mode's laser had an older firmware until this connection (roadmap 1.5): the status card's notice, the Settings
    /// tab's Keep My Cartridges Working (the demo printer forgets what's written, so it reads back what it had), then Dismiss.
    private static func firmwareCheck(_ model: AppModel) async -> [String] {
        guard let p = model.printers.first(where: { $0.id == Demo.uuid }) else { return ["firmware: no demo laser"] }
        for _ in 0..<60 where !p.view.isOnline { try? await Task.sleep(for: .milliseconds(250)) }
        var lines = ["firmware: \(p.name): notice \(p.view.firmwareNotice?.text ?? "none")"]
        lines.append("  hint: \(p.hasDeviceSettings ? FirmwareNoticeView.hintHp : FirmwareNoticeView.hintOther)")
        lines.append("  button: \(p.hasDeviceSettings ? "Firmware Settings" : p.webPage == nil ? "none" : "Printer Web Page"), Dismiss")
        let settings = DeviceSettingsModel(printer: p)
        await settings.load()
        lines.append("  firmware section: \(settings.firmware.map { "\($0.mode)" } ?? "none"), keep my cartridges working offered: \(settings.canKeepCartridges); \(settings.keepCartridgesHint)")
        if settings.canKeepCartridges {
            await settings.keepCartridgesWorking()
            lines.append("  keep my cartridges working: \(settings.message ?? "-")\(settings.messageIsError ? " (error)" : "")\(settings.problem.map { " " + $0 } ?? "")")
        }
        p.dismissFirmwareNotice()
        try? await Task.sleep(for: .milliseconds(300))
        lines.append("  dismissed: notice \(p.view.firmwareNotice?.text ?? "none"), record dismissed: \(model.store.firmware(p.id)?.dismissed == true)")
        return lines
    }

    /// The supply history (roadmap 1.1), once every printer that reads its supplies has: where it's kept (demo mode: in memory,
    /// nothing written), Export history…'s CSV (the button's own call, saved without the panel in the container; in demo mode only in memory) and, in demo
    /// mode without a key, the same export with the Pro gate on (refused: the button opens the Pro window instead).
    private static func historyCheck(_ model: AppModel) async -> [String] {
        for _ in 0..<80 where model.printers.contains(where: { $0.isNetwork && $0.view.phase == .connecting }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Demo mode saves nothing and reads nothing real: its history and the export stay in memory.
        var lines = ["history: demo mode keeps it in memory; nothing is read from or saved to the history folder"]
        if !model.isDemo {
            let folder = AppModel.historyFolder
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tsv") }
            lines = ["history: folder \(folder.lastPathComponent) beside the state file: \(files.count) files"]
            if let first = files.sorted().first, let text = try? String(contentsOf: folder.appendingPathComponent(first), encoding: .utf8) {
                let rows = text.split(separator: "\n")
                let cells = rows.dropFirst().first.map { $0.split(separator: "\t", omittingEmptySubsequences: false).count } ?? 0
                lines.append("  a file: \(rows.first.map(String.init) ?? "-"), \(rows.count - 1) rows of \(cells) cells")
            }
        }
        for p in model.printers {
            let rows = model.history.rows(p.id)
            if rows.isEmpty { continue }
            lines.append("  \(p.name): \(rows.count) rows, \(Set(rows.map(\.key)).count) supplies, \(rows[0].day) to \(rows[rows.count - 1].day)")
        }
        if let csv = SupplyHistoryExport.csv(model) {
            let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            if model.isDemo {
                let bytes = SupplyHistoryExport.bytes(csv)
                lines.append("export: \(rows.count - 1) rows, \(bytes.count) bytes in memory (not saved in demo mode), starts with a byte order mark: \(bytes.starts(with: [0xEF, 0xBB, 0xBF]))")
                lines.append("  columns: \(rows.first ?? "-")")
            } else {
                let url = AppModel.dataFolder.appendingPathComponent("report-supply-history.csv")
                do {
                    try SupplyHistoryExport.write(csv, to: url)
                    let saved = (try? Data(contentsOf: url)) ?? Data()
                    lines.append("export: \(rows.count - 1) rows, saved \(saved.count) bytes, starts with a byte order mark: \(saved.starts(with: [0xEF, 0xBB, 0xBF]))")
                    lines.append("  columns: \(rows.first ?? "-")")
                } catch {
                    lines.append("export: not saved: \(error.localizedDescription)")
                }
            }
        } else {
            lines.append("export: refused by the Pro check (the button opens the Pro window)")
        }
        if model.isDemo && Pro.licence == nil {
            let enforced = Pro.enforced
            Pro.enforced = true
            lines.append("export with the Pro gate on and no key: \(SupplyHistoryExport.csv(model) == nil ? "refused" : "allowed")")
            Pro.enforced = enforced
        }
        return lines
    }

    /// The demo inkjet ready to scan, its review empty.
    static func demoScanner(_ model: AppModel) async -> ScanModel? {
        guard let inkjet = model.printers.first(where: { $0.id == Demo.inkjetUuid }) else { return nil }
        for _ in 0..<50 where !inkjet.view.isOnline { try? await Task.sleep(for: .milliseconds(200)) }
        let scan = inkjet.scan
        await scan.load()
        scan.clear()
        return scan.caps == nil ? nil : scan
    }

    static func scanAndWait(_ scan: ScanModel) async {
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
            let options = await model.photoJobOptions(for: p)
            let types = QueueJobChoices.mediaTypes(options).map(\.label).joined(separator: ", ")
            let qualities = QueueJobChoices.qualities(options).map(\.label).joined(separator: ", ")
            let colors = QueueJobChoices.colors(options).map(\.label).joined(separator: ", ")
            lines.append("paper types \(p.name): \(types.isEmpty ? "none" : types); quality: \(qualities.isEmpty ? "none" : qualities); color: \(colors.isEmpty ? "none" : colors)")
        }
        return lines.isEmpty ? ["papers: no printer has a queue"] : lines
    }

    /// Print Photos' job on each queue printer, held: a blank sheet on the region's paper, with the queue's first photo paper
    /// type (else its default, else its first), its best quality and its first color; read back from cupsd, then cancelled. Nothing prints.
    private static func photoJobCheck(_ model: AppModel) async -> [String] {
        try? await Task.sleep(for: .seconds(4)) // the queues are read
        var lines: [String] = []
        let cups = LibCups()
        for p in model.printers {
            guard let queue = p.queueName else { continue }
            let choices = QueuePapers.photoChoices(await model.photoMedia(for: p))
            guard let paper = QueuePapers.preferred(choices, metric: Locale.current.measurementSystem == .metric) else {
                lines.append("photo job \(p.name): no papers listed")
                continue
            }
            let options = await model.photoJobOptions(for: p)
            let types = QueueJobChoices.mediaTypes(options)
            let type = types.first { PhotoPaperText.isPhotoMedia(QueueJobChoices.schemaMediaType($0.value)) }?.value ?? options.defaultMediaType ?? types.first?.value
            let wanted = QueueJobChoices.jobOptions(mediaType: type, quality: QueueJobChoices.qualities(options).last?.value,
                                                    color: QueueJobChoices.colors(options).first?.value)
            let sheet = paper.sheet
            guard let pdf = blankPdf(width: sheet.width * 72, height: sheet.height * 72) else { return ["photo job: no PDF"] }
            do {
                let job = try await cups.printPdf(queue, pdf, title: "Inkvolt photo job check", media: QueueJobChoices.media(paper, borderless: false),
                                                  options: wanted, hold: true)
                let held = await cups.sentJob(job)
                let took = held.map { j in j.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") } ?? "not found"
                let asked = wanted.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
                lines.append("photo job \(p.name): asked media=\(paper.media) \(asked); held state \(held?.state ?? 0) "
                             + "(\(held?.reasons.joined(separator: ",") ?? "")); took \(took)")
                do {
                    try await cups.cancel(queue, job: job)
                    lines.append("photo job \(p.name): cancelled")
                } catch {
                    lines.append("photo job \(p.name): NOT cancelled: \(error)")
                }
            } catch {
                lines.append("photo job \(p.name): refused: \((error as? PrintJobSendError)?.message ?? "\(error)")")
            }
        }
        return lines.isEmpty ? ["photo job: no printer has a queue"] : lines
    }

    /// One blank page `width` × `height` points.
    private static func blankPdf(width: Double, height: Double) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
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
            if let n = v.firmwareNotice { lines.append("  firmware notice: \(n.text)") }
            for supply in v.supplies {
                let s = SupplyText(supply)
                lines.append("  supply: \(s.name): \(s.percentText)\(s.headline.map { ", \($0)" } ?? "")")
                if let line = v.supplyHistory?.line(for: supply) { lines.append("    history: \(line)") }
            }
            lines += historyLines(v)
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

    /// The supplies card's chart (or why it isn't there yet) and the days left the low-supply alert names.
    private static func historyLines(_ v: PrinterView) -> [String] {
        guard let h = v.supplyHistory else { return [] }
        guard h.chart.hasEnoughToDraw else { return ["  supply chart: none; \(h.chartNote(v.supplies) ?? "no note")"] }
        var lines = ["  supply chart: \(h.chart.from) to \(h.chart.to), \(SupplyChart.marks(h.chart).count) marks"]
        for l in h.chart.lines {
            let points = l.segments.reduce(0) { $0 + $1.count }
            lines.append("    \(l.supply): \(points) points in \(l.segments.count) pieces, new cartridge on \(l.changes.map(\.description))")
        }
        lines.append("    spoken: \(SupplyChart.spoken(h.chart))")
        let days = h.daysLeft.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        lines.append("  days left for the alert: \(days.isEmpty ? "none" : days.joined(separator: ", "))")
        return lines
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

/// Debug builds only (`build.sh debug`): `open "Inkvolt Print.app" --args --demo --snapshot laser:0,inkjet:1:scan
/// [--size 1180x720] [--dark] [--wait <seconds>]`. After `--wait` seconds (8 by default) shows the main window at
/// `--size` points and, for each `name:index[:screen]`, selects the index-th printer, shows the screen (`status`, the
/// default; `scan`, `photos` or `print-photos`, after a scan of the demo inkjet's glass with its photos looked for) and
/// captures the window, with any sheet over it, through ScreenCaptureKit (as the screen shows it, at its scale, without
/// the shadow) to `Application Support/InkvoltPrint/snapshot-<name>.png` in the container, then quits. For the App Store
/// screenshots. Needs Screen Recording permission for this build (macOS asks the first time; an ad-hoc build is a new app
/// to it each time) and the Mac's screen unlocked. Release builds have none of this.
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
        let shots = list.split(separator: ",").map { item -> (name: String, index: Int, screen: String) in
            let parts = item.split(separator: ":").map(String.init)
            return (parts[0], parts.count > 1 ? Int(parts[1]) ?? 0 : 0, parts.count > 2 ? parts[2] : "status")
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
            var photoFiles: [URL]?
            for shot in shots {
                if shot.screen != "status" && photoFiles == nil { photoFiles = await scanGlassPhotos(model) }
                if shot.index < model.printers.count { model.selectedID = model.printers[shot.index].id }
                guard let window = mainWindow() else {
                    log.append("\(shot.name): no window")
                    break
                }
                if size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
                window.center()
                window.makeKeyAndOrderFront(nil)
                switch shot.screen {
                case "scan": model.paneRequest = .scan
                case "photos":
                    model.paneRequest = .scan
                    try? await Task.sleep(for: .seconds(1))
                    model.paneRequest = .photosSheet
                case "print-photos": model.paneRequest = .printPhotos(photoFiles ?? [])
                default: model.paneRequest = .status
                }
                try? await Task.sleep(for: .seconds(shot.screen == "status" ? 1.5 : shot.screen == "print-photos" ? 8 : 4))
                do {
                    let png = try await capture(window)
                    try png.write(to: folder.appendingPathComponent("snapshot-\(shot.name).png"))
                    log.append("\(shot.name): ok")
                } catch {
                    log.append("\(shot.name): \(error)")
                }
                model.paneRequest = .status // closes a sheet
                try? await Task.sleep(for: .seconds(1))
            }
            try? Data(log.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("snapshot-log.txt"))
            NSApp.terminate(nil)
        }
    }

    /// The demo inkjet's glass scanned with its photos looked for (the Scan tab and the Photos sheet show it), and the
    /// photos saved as JPEGs for Print Photos.
    private static func scanGlassPhotos(_ model: AppModel) async -> [URL] {
        guard let scan = await Report.demoScanner(model) else { return [] }
        scan.source = .platen
        scan.format = .jpeg
        scan.findPhotos = true
        await Report.scanAndWait(scan)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-photos", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await scan.save(to: folder, reveal: false)
        await Report.scanAndWait(scan) // saving cleared the pages: scan again for the Scan tab and the Photos sheet
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return names.map { folder.appendingPathComponent($0) }
    }

    /// The main window and any sheet over it, as the screen shows them (the app's own windows only).
    private static func capture(_ window: NSWindow) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
              let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.displays.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.intersects(target.frame) }
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.sourceRect = CGRect(x: target.frame.minX - display.frame.minX, y: target.frame.minY - display.frame.minY,
                                   width: target.frame.width, height: target.frame.height)
        config.width = Int(target.frame.width * scale)
        config.height = Int(target.frame.height * scale)
        config.ignoreShadowsDisplay = true
        config.backgroundColor = .clear
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: ours),
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
