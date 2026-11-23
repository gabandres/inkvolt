import AppKit
import PrintCore
import SwiftUI

/// Window › Print Log (roadmap 4.9; Windows' `PrintLogDialog`): the month's totals per printer and per person and its jobs,
/// newest first, from CUPS's own history of finished jobs (`PrintLogKeeper`, kept on this Mac only); the switch that turns it
/// off, Clear, and Export as CSV (Inkvolt Pro, `ProFeature.printLogExport`). New jobs show as they're logged.
@MainActor
enum PrintLogWindow {
    private static var window: NSWindow?
    private(set) static var model: PrintLogModel?

    @discardableResult
    static func show(_ app: AppModel) -> PrintLogModel {
        if let model, model.app === app, let window {
            model.load()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return model
        }
        let model = PrintLogModel(app: app)
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PrintLogView(model: model))
        w.title = app.isDemo ? String(localized: "Print Log — Demo") : String(localized: "Print Log")
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.contentMinSize = NSSize(width: 560, height: 420)
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        model.load()
        return model
    }

    /// The open window's content size, for `--report`.
    static var size: NSSize? { window.flatMap { $0.isVisible ? $0.contentLayoutRect.size : nil } }

    static func close() { window?.close() }
}

/// One line of a month's totals: a printer or a person, its jobs and pages (and of those in color, when any are known).
struct PrintLogTotalRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let jobs: String
    let pages: String
}

/// One job of the month: its document, then when, printer, person and what's known of it.
struct PrintLogRow: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
}

/// The window's model (Windows' `PrintLogViewModel`).
@MainActor
@Observable
final class PrintLogModel {
    /// Jobs listed for a month (all of them are in the totals and the CSV).
    static let maxShown = 200

    let app: AppModel
    private(set) var months: [PrintLogMonth] = []
    var selectedMonth: PrintLogMonth? {
        didSet { if oldValue != selectedMonth { showMonth() } }
    }
    private(set) var byPrinter: [PrintLogTotalRow] = []
    private(set) var byUser: [PrintLogTotalRow] = []
    private(set) var jobs: [PrintLogRow] = []
    private(set) var isLoaded = false
    /// "The latest 200 of this month's 1,234 jobs are listed…", when there are more than are listed.
    private(set) var moreText: String?
    private(set) var message: String?
    @ObservationIgnored private var log: [PrintLogEntry] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var reload = false

    init(app: AppModel) {
        self.app = app
    }

    var isEmpty: Bool { isLoaded && log.isEmpty }
    var hasJobs: Bool { isLoaded && !log.isEmpty }

    /// The log's switch (on by default).
    var isOn: Bool {
        get { app.printLogOn }
        set {
            guard newValue != app.printLogOn else { return }
            app.setPrintLog(on: newValue)
            message = newValue ? String(localized: "The print log is on: jobs are logged from now on.")
                : String(localized: "The print log is off: no more jobs are logged. What's already in it stays until you clear it.")
        }
    }

    /// Reads the log (off the main thread: the file may hold thousands of jobs) and shows the month picked, or the newest.
    func load() {
        if loading {
            reload = true // a job logged while reading: read again once this read is shown
            return
        }
        loading = true
        let file = app.printLog.file
        Task {
            repeat {
                reload = false
                let read = await Task.detached { file.read(Date()) }.value
                show(read)
            } while reload
            loading = false
        }
    }

    private func show(_ read: [PrintLogEntry]) {
        log = read
        let wanted = selectedMonth
        months = PrintLog.months(read)
        isLoaded = true
        let pick = months.first { $0 == wanted } ?? months.first
        if pick == selectedMonth { showMonth() } else { selectedMonth = pick }
    }

    func name(_ month: PrintLogMonth) -> String { PrintLog.monthName(month, Locale.current) }

    private func showMonth() {
        byPrinter = []
        byUser = []
        jobs = []
        moreText = nil
        guard let month = selectedMonth else { return }
        byPrinter = PrintLog.byPrinter(log, month).map(Self.row)
        byUser = PrintLog.byUser(log, month).map(Self.row)
        let all = PrintLog.jobs(log, in: month)
        jobs = all.prefix(Self.maxShown).enumerated().map { i, e in
            PrintLogRow(id: i, title: e.document.isEmpty ? String(localized: "(no name)") : e.document, detail: Self.detail(e))
        }
        if all.count > Self.maxShown {
            moreText = String(localized: "The latest \(Self.maxShown) of this month's \(all.count) jobs are listed; the totals and Export count them all.")
        }
    }

    private static func row(_ t: PrintLogTotal) -> PrintLogTotalRow {
        let jobs = t.jobs == 1 ? String(localized: "\(t.jobs) job") : String(localized: "\(t.jobs) jobs")
        let count = Int(min(t.pages, Int64(Int.max)))
        var pages = count == 1 ? String(localized: "\(count) page") : String(localized: "\(count) pages")
        if t.colorPages > 0 { pages += " " + String(localized: "(\(Int(min(t.colorPages, Int64(Int.max)))) in color)") }
        return PrintLogTotalRow(name: t.name, jobs: jobs, pages: pages)
    }

    /// "Nov 3, 3:42 PM · Office laser · alex · 3 pages × 2 · color".
    static func detail(_ e: PrintLogEntry) -> String {
        var parts = [e.at.formatted(.dateTime.month(.abbreviated).day()) + ", " + e.at.formatted(date: .omitted, time: .shortened)]
        if !e.printer.isEmpty { parts.append(e.printer) }
        if !e.user.isEmpty { parts.append(e.machine.map { String(localized: "\(e.user) on \($0)") } ?? e.user) }
        let detail = PrintLog.detail(e)
        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    /// Export…: the whole log as CSV (Inkvolt Pro; the log and its totals stay free).
    func export() {
        guard Pro.allows(.printLogExport) else {
            ProWindow.show(feature: .printLogExport)
            return
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export the print log")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = PrintLog.csvFileName(Date())
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    /// Writes the CSV to `url` (`--report` calls this directly): UTF-8 with a byte order mark, so Excel reads the names.
    func write(to url: URL) {
        do {
            try Self.bytes(PrintLog.csv(log)).write(to: url, options: .atomic)
            message = String(localized: "Saved \(url.lastPathComponent).")
        } catch {
            message = String(localized: "The print log couldn't be saved: \(error.localizedDescription)")
        }
    }

    static func bytes(_ csv: String) -> Data { Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8) }

    /// Clear the Log…: every job forgotten, after asking.
    func clear(ask: Bool = true) {
        if ask {
            let alert = NSAlert()
            alert.messageText = String(localized: "Clear the print log?")
            alert.informativeText = String(localized: "Every job in it is forgotten, on this Mac. This can't be undone.")
            alert.addButton(withTitle: String(localized: "Clear the Log"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let cleared = app.clearPrintLog()
        message = cleared ? String(localized: "The print log is empty.")
            : String(localized: "The print log couldn't be cleared. Nothing was removed; try again in a moment.")
        load()
    }
}

struct PrintLogView: View {
    @Bindable var model: PrintLogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every job this Mac printed, from macOS's own list of finished jobs, with month totals. Kept on this Mac only, for 13 months; nothing is sent.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Keep a log of print jobs on this Mac", isOn: $model.isOn)
            if model.isEmpty {
                Text("No print jobs logged yet. Jobs show here once they've printed, also those printed while Inkvolt Print was closed (macOS keeps a list of finished jobs for a while).")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                Spacer()
            } else if model.hasJobs {
                Picker("Month", selection: $model.selectedMonth) {
                    ForEach(model.months, id: \.self) { m in Text(model.name(m)).tag(Optional(m)) }
                }
                .frame(maxWidth: 260)
                HStack(alignment: .top, spacing: 16) {
                    totals(String(localized: "By printer"), model.byPrinter)
                    totals(String(localized: "By person"), model.byUser)
                }
                Text("Jobs").font(.headline)
                List(model.jobs) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1).truncationMode(.middle).help(row.title)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.inset)
                if let more = model.moreText {
                    Text(more).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Spacer()
            }
            if let message = model.message {
                Text(message).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                if model.hasJobs {
                    Button("Export…") { model.export() }
                        .help(String(localized: "Save the whole log as a CSV file for a spreadsheet (Inkvolt Pro)"))
                    Button("Clear the Log…") { model.clear() }
                        .help(String(localized: "Forget every job in the print log"))
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func totals(_ title: String, _ rows: [PrintLogTotalRow]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).lineLimit(1).truncationMode(.tail).help(row.name)
                        Text("\(row.pages) · \(row.jobs)").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
        .accessibilityLabel(title)
    }
}
