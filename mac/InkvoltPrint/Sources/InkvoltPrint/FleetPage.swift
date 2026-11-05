import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI
import UniformTypeIdentifiers

/// The Fleet page (roadmap 2.6, the Windows app's `FleetViewModel`): every printer on the list, most trouble first. It reads no
/// printer: each one's monitor (or its queue, read every few seconds) keeps its model current, and while the page shows it
/// looks at them every two seconds. The supply history's last word for a printer that isn't answering is read off the main
/// thread, once. Pro: Export… (CSV or JSON) and Fix All, through `Pro.allows`; without the licence the Pro window says what
/// they do.
@MainActor @Observable
final class FleetPageModel {
    private(set) var rows: [FleetRow] = []
    private(set) var summary = ""
    private(set) var isFixing = false
    /// What the last Fix All did, a line each, and what it left for each printer's own fixer.
    private(set) var fixSteps: [FixAllStep] = []
    private(set) var fixLeft: [String] = []
    private(set) var fixSummary: String?
    /// What the last export said, beside the button.
    private(set) var exportMessage: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var known: [String: FleetLastKnown] = [:]
    @ObservationIgnored private var asked = Set<String>()
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var fixing: Task<FixAllReport, Never>?
    @ObservationIgnored private(set) var printers: [FleetPrinter] = []

    init(app: AppModel) { self.app = app }

    /// The page came on screen: looks at the printers now and every two seconds.
    func show() {
        refresh()
        ticking?.cancel()
        ticking = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(2))) != nil {
                self?.refresh()
            }
        }
    }

    /// The page went: nothing runs for it.
    func hide() {
        ticking?.cancel()
        ticking = nil
    }

    /// The rows as the printers stand now; unchanged words leave the view alone.
    func refresh() {
        for p in app.printers where !p.view.isOnline && p.view.phase != .connecting && !asked.contains(p.id) { askHistory(p.id) }
        printers = app.printers.map { FleetPrinter.of($0.fleetFacts(known[$0.id])) }
        let now = FleetPage.rows(printers, Date())
        if now != rows { rows = now }
        let said = FleetPage.summary(printers)
        if said != summary { summary = said }
    }

    private func askHistory(_ id: String) {
        asked.insert(id)
        let history = app.history
        Task { [weak self] in
            let last = await Task.detached { FleetLastKnown.from(history.rows(id)) }.value
            guard let self, let last else { return }
            self.known[id] = last
            self.refresh()
        }
    }

    func printer(_ id: String) -> PrinterModel? { app.printers.first { $0.id == id } }

    /// A row's Open: that printer's page.
    func open(_ id: String) {
        app.selectedID = id
        app.showFleet = false
    }

    /// Fix It… shows where the fixer can help: a printer that can't be reached or is in error, and a queue printer with any
    /// trouble (a paused queue reads as a warning). Low ink on a network printer isn't something it fixes.
    func canFix(_ row: FleetRow) -> Bool {
        let t = row.printer.trouble
        let fits = t == .error || t == .offline || (t == .warning && row.printer.kind == .queue)
        return fits && printer(row.printer.id)?.needsFixing == true
    }

    // MARK: Pro

    /// Export…: the list as it stands, as CSV or JSON (the save panel's file type).
    func export() {
        guard FleetExport.allowed else {
            ProWindow.show(feature: .fleetExport)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export the printer list"
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "Printers \(Day(Date())).csv"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await write(to: url) }
    }

    /// The bytes an export of the list as it stands writes: JSON by the extension (plain ASCII), else CSV with a byte order
    /// mark, so Excel reads the names as UTF-8 (as Windows writes it).
    func exportBytes(json: Bool) -> Data {
        refresh()
        let now = Date(), who = Diagnostics.Identity.current
        if json { return Data(FleetExport.json(printers, [], now, who).utf8) }
        return SupplyHistoryExport.bytes(FleetExport.csv(printers, now, who))
    }

    /// Writes the list to `url`, off the main thread (the folder may be a slow network share).
    @discardableResult
    func write(to url: URL) async -> Bool {
        let bytes = exportBytes(json: url.pathExtension.lowercased() == "json")
        do {
            try await Task.detached { try bytes.write(to: url, options: .atomic) }.value
            exportMessage = "Saved \(url.lastPathComponent)"
            return true
        } catch {
            exportMessage = "Could not save the list: \(error.localizedDescription)"
            return false
        }
    }

    /// What Fix All looks at: each printer's queue (a queue printer's own, a network printer's that are known to be its).
    var fixTargets: [FixAllTarget] { app.printers.compactMap(\.fixAllTarget) }

    /// Fix All: the fixer's safe repairs over every queue, each confirmed by name (`FleetFixAll`). The window stays free.
    /// `confirm`: asks the person (an alert by default).
    func fixAll(confirm: (@Sendable (Repair) async -> Bool)? = nil) async {
        guard !isFixing else { return }
        guard Pro.allows(.fleetExport) else {
            ProWindow.show(feature: .fleetExport)
            return
        }
        isFixing = true
        fixSteps = []
        fixLeft = []
        fixSummary = "Looking at this Mac's printers…"
        let targets = fixTargets, queues = app.queues, control = app.queueControl
        let ask = confirm ?? { repair in await MainActor.run { Self.ask(repair) } }
        let progress: @Sendable (FixAllStep) -> Void = { [weak self] step in Task { @MainActor in self?.fixSteps.append(step) } }
        let task = Task.detached { await FleetFixAll.run(targets, queues: queues, control: control, confirm: ask, progress: progress) }
        fixing = task
        let report = await task.value
        await Task.yield() // the last line's progress lands first
        fixSteps = report.steps
        fixLeft = report.left
        fixSummary = report.summary
        fixing = nil
        isFixing = false
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: report.summary, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        refresh()
    }

    func stopFixing() { fixing?.cancel() }

    /// One repair's question, by the printer's name.
    private static func ask(_ repair: Repair) -> Bool {
        let alert = NSAlert()
        alert.messageText = repair.question ?? repair.title
        alert.informativeText = repair.detail
        alert.addButton(withTitle: repair.confirm)
        alert.addButton(withTitle: "Don't Change")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The Fleet page: the summary, Export… and Fix All, then a row per printer.
struct FleetView: View {
    @Environment(AppModel.self) private var app
    @State private var fixingPrinter: PrinterModel?

    var body: some View {
        let page = app.fleet
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(page)
                if page.isFixing || page.fixSummary != nil { FixAllResult(page: page) }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(page.rows, id: \.printer.id) { row in
                        FleetRowView(row: row, canFix: page.canFix(row), open: { page.open(row.printer.id) },
                                     fix: { fixingPrinter = page.printer(row.printer.id) })
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Fleet")
        .onAppear { page.show() }
        .onDisappear { page.hide() }
        .sheet(item: $fixingPrinter) { p in OfflineFixerSheet(printer: p, app: app) }
    }

    private func header(_ page: FleetPageModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.summary).font(.title3).accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Button("Export…") { page.export() }
                    .help("Save the list as a spreadsheet (CSV) or JSON (Inkvolt Pro)")
                if page.isFixing {
                    Button("Stop") { page.stopFixing() }
                } else {
                    Button("Fix All…") { Task { await page.fixAll() } }
                        .help("Resume paused printers and let them accept jobs again, asking before each one (Inkvolt Pro)")
                }
                if let message = page.exportMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

/// What the last Fix All did.
private struct FixAllResult: View {
    let page: FleetPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if page.isFixing { ProgressView().controlSize(.small) }
                Text(page.fixSummary ?? "").font(.headline)
            }
            ForEach(Array(page.fixSteps.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(step.title): \(step.message)").fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(step.steps.enumerated()), id: \.offset) { i, line in
                        Text("\(i + 1). \(line)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !page.fixLeft.isEmpty {
                Text("Left for each printer's own Fix It…:").font(.callout.weight(.medium)).padding(.top, 4)
                ForEach(Array(page.fixLeft.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}

/// One printer: its state, problems, supplies, page count, firmware and last reading. VoiceOver reads the row as one sentence
/// (`FleetRow.accessibleText`) with Open and Fix It… as its actions.
private struct FleetRowView: View {
    let row: FleetRow
    let canFix: Bool
    let open: () -> Void
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(tone: tone).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.printer.name).font(.headline).lineLimit(1)
                    Text(FleetPage.troubleText(row.printer.trouble)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if canFix { Button("Fix It…", action: fix) }
                    Button("Open", action: open)
                }
                Text(row.statusLine).foregroundStyle(.secondary).lineLimit(3)
                if let none = row.noSuppliesText {
                    Text(none).font(.callout).foregroundStyle(.secondary)
                } else {
                    supplies
                }
                Text([row.pagesText, row.firmwareText, row.lastReadText].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibleText)
        .accessibilityAction(named: "Open") { open() }
        .accessibilityAction(named: "Fix It…") { if canFix { fix() } }
    }

    private var supplies: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(row.supplies.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.text).font(.callout).lineLimit(1)
                    if let level = s.level {
                        ProgressView(value: Double(level), total: 100).tint(level == 0 ? .red : s.isLow ? .orange : .accentColor)
                    }
                }
            }
        }
    }

    private var tone: PrinterModel.Tone {
        switch row.printer.trouble {
        case .error: .error
        case .warning: .warning
        case .offline: .off
        case .unknown: .unknown
        case .ok: .ok
        }
    }
}
