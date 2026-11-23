import AppKit
import Observation
import PDFKit
import PrintCore
import PrintMac
import SwiftUI

/// Recent scans (roadmap 4.15; the Windows app's `RecentScansViewModel`): the last saves, kept in the state file on this Mac
/// only (`RecentScans`), each with a bookmark of where it was saved, so the sandbox lets Open, Show in Finder, Email Again
/// and Print reach the files in a later run.
extension AppModel {
    /// A save goes on the list: its files, the pages, the scanner's and preset's names, and a bookmark of `access` (the folder
    /// saved in, or the one file the save panel named), made while the save still holds it.
    func noteRecentScan(_ urls: [URL], pages: Int, printer: String, preset: String?, access: URL?) {
        guard !urls.isEmpty else { return }
        let scan = RecentScan(files: urls.map(\.path), savedAt: Date(), pages: pages, printer: printer, preset: preset,
                              access: access.flatMap(FolderBookmarks.make))
        store.change { $0.recentScans = RecentScans.add($0.recentScans, scan) }
    }

    /// The list with the files gone from the disk dropped: looked for off the main thread (a network volume may be slow),
    /// then dropped from the list as it is by then, so a scan saved meanwhile stays.
    func loadRecentScans() async -> [RecentScan] {
        let list = store.current.recentScans
        let gone = await Task.detached { RecentScanAccess.gone(list) }.value
        return store.change { s in
            if !gone.isEmpty { s.recentScans = RecentScans.present(s.recentScans) { !gone.contains($0) } }
            return s.recentScans
        }
    }

    func removeRecentScan(_ scan: RecentScan) -> [RecentScan] {
        store.change { s in
            s.recentScans = RecentScans.remove(s.recentScans, scan)
            return s.recentScans
        }
    }

    func clearRecentScans() { store.change { $0.recentScans = [] } }
}

/// The sandbox's way back to a recent scan's files: its bookmark resolved and held while the work runs.
enum RecentScanAccess {
    static func with<T>(_ scan: RecentScan, _ body: () throws -> T) rethrows -> T {
        guard let data = scan.access, let (url, _) = FolderBookmarks.resolve(data) else { return try body() }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// The files of `list` no longer there (or out of reach: a bookmark that no longer resolves).
    static func gone(_ list: [RecentScan]) -> Set<String> {
        var gone = Set<String>()
        for scan in list {
            with(scan) { for file in scan.files where !FileManager.default.fileExists(atPath: file) { gone.insert(file) } }
        }
        return gone
    }

    /// The folder held open for the pictures handed to Print Photos (it reads them again to turn one), until the next.
    @MainActor private static var held: URL?

    @MainActor static func hold(_ scan: RecentScan) {
        if let held { held.stopAccessingSecurityScopedResource() }
        held = nil
        guard let data = scan.access, let (url, _) = FolderBookmarks.resolve(data), url.startAccessingSecurityScopedResource() else { return }
        held = url
    }
}

/// One line of the list: the scan, its name and when, how many pages, from which scanner and preset.
struct RecentScanRow: Identifiable {
    let scan: RecentScan
    let title: String
    let detail: String
    var id: String { scan.files.first ?? "" }

    /// Pictures go to Print Photos, PDFs to the print panel; a Word or text scan is printed from its own app.
    var canPrint: Bool { scan.isPdf || scan.files.allSatisfy { [".jpg", ".jpeg"].contains(RecentScans.fileExtension($0)) } }
}

@MainActor @Observable
final class RecentScansModel {
    private(set) var rows: [RecentScanRow] = []
    private(set) var loaded = false
    /// What the last action did ("Receipt.pdf was removed from the list; the file is still there.").
    var message: String?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored let printer: PrinterModel

    init(app: AppModel, printer: PrinterModel) {
        self.app = app
        self.printer = printer
    }

    func load() async { show(await app.loadRecentScans()) }

    private func show(_ list: [RecentScan]) {
        let now = Date()
        rows = list.map { RecentScanRow(scan: $0, title: Self.title($0), detail: Self.detail($0, now: now)) }
        loaded = true
    }

    /// "Receipt 0042.pdf", or "Receipt 0042.pdf and 2 more" for a batch or a set of pictures.
    static func title(_ scan: RecentScan) -> String {
        let more = scan.files.count - 1
        if more <= 0 { return scan.name }
        return more == 1 ? String(localized: "\(scan.name) and 1 more") : String(localized: "\(scan.name) and \(more) more")
    }

    /// "Today, 3:42 PM · 3 pages · Demo laser · Receipts".
    static func detail(_ scan: RecentScan, now: Date) -> String {
        let time = scan.savedAt.formatted(date: .omitted, time: .shortened)
        var parts: [String] = switch RecentScans.day(scan.savedAt, now: now) {
        case .today: [String(localized: "Today, \(time)")]
        case .yesterday: [String(localized: "Yesterday, \(time)")]
        case .earlier: [scan.savedAt.formatted(date: .numeric, time: .shortened)]
        }
        if scan.pages > 0 { parts.append(scan.pages == 1 ? String(localized: "1 page") : String(localized: "\(scan.pages) pages")) }
        if let printer = scan.printer { parts.append(printer) }
        if let preset = scan.preset { parts.append(preset) }
        return parts.joined(separator: " · ")
    }

    private func urls(_ scan: RecentScan) -> [URL] { scan.files.map { URL(fileURLWithPath: $0) } }

    func open(_ row: RecentScanRow) {
        let opened = RecentScanAccess.with(row.scan) { NSWorkspace.shared.open(urls(row.scan)[0]) }
        message = opened ? nil : String(localized: "\(row.scan.name) couldn't be opened: no app on this Mac opens it.")
    }

    func showInFinder(_ row: RecentScanRow) {
        RecentScanAccess.with(row.scan) { NSWorkspace.shared.activateFileViewerSelecting(urls(row.scan)) }
    }

    /// Hands the files to the mail app again: nothing is sent by Inkvolt Print.
    func email(_ row: RecentScanRow) {
        let files = urls(row.scan)
        RecentScanAccess.with(row.scan) {
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else {
                message = String(localized: "No mail app is set up on this Mac to attach the scan to. Finder shows it to attach by hand.")
                NSWorkspace.shared.activateFileViewerSelecting(files)
                return
            }
            service.subject = files[0].deletingPathExtension().lastPathComponent
            service.perform(withItems: files)
            message = nil
        }
    }

    /// PDFs print through the print panel as one job; pictures go to Print Photos. `close` closes the list first.
    func print(_ row: RecentScanRow, close: @escaping @MainActor () -> Void) {
        let scan = row.scan
        if !scan.isPdf {
            RecentScanAccess.hold(scan)
            let files = urls(scan)
            close()
            app.paneRequest = nil
            Task { @MainActor [app] in
                try? await Task.sleep(for: .milliseconds(400)) // after the list's sheet has gone
                app.paneRequest = .printPhotos(files)
            }
            return
        }
        let document = PDFDocument()
        var unread = 0
        RecentScanAccess.with(scan) {
            for url in urls(scan) {
                // Read whole while the folder is held: PDFKit reads a file lazily, after the access has ended.
                guard let data = try? Data(contentsOf: url), let pdf = PDFDocument(data: data), !pdf.isLocked else {
                    unread += 1
                    continue
                }
                for i in 0..<pdf.pageCount { if let page = pdf.page(at: i) { document.insert(page, at: document.pageCount) } }
            }
        }
        guard document.pageCount > 0 else {
            message = String(localized: "\(scan.name) couldn't be read to print (moved, changed or protected with a password).")
            return
        }
        if unread > 0 { message = String(localized: "\(unread) of the files couldn't be read and won't print.") }
        close()
        let printer = printer, app = app
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            Printing.print(document, name: scan.files.count == 1 ? urls(scan)[0].deletingPathExtension().lastPathComponent : scan.name,
                           on: printer, app: app)
        }
    }

    func remove(_ row: RecentScanRow) {
        show(app.removeRecentScan(row.scan))
        message = String(localized: "\(row.scan.name) was removed from the list; the file is still there.")
    }

    func clear() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear the list of recent scans?")
        alert.informativeText = String(localized: "The files stay where they are.")
        alert.addButton(withTitle: String(localized: "Clear the List"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.clearRecentScans()
        show([])
        message = nil
    }
}

struct RecentScansSheet: View {
    @State private var model: RecentScansModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, printer: PrinterModel) {
        _model = State(initialValue: RecentScansModel(app: app, printer: printer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Scans").font(.title2.weight(.semibold))
            Text("Your last saved scans, from every scanner. The list is kept on this Mac only; removing a scan from it doesn't delete the file.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            list
            if let message = model.message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Clear the List…") { model.clear() }.disabled(model.rows.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .task { await model.load() }
    }

    @ViewBuilder private var list: some View {
        if model.loaded && model.rows.isEmpty {
            ContentUnavailableView("No Saved Scans Yet", systemImage: "clock",
                                   description: Text("Scans you save, or save with a preset, show here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.rows) { row in RecentScanLine(row: row, model: model) { dismiss() } }
                .listStyle(.inset)
        }
    }
}

private struct RecentScanLine: View {
    let row: RecentScanRow
    let model: RecentScansModel
    let close: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.scan.isPdf ? "doc.richtext" : "photo").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1).truncationMode(.middle)
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Open") { model.open(row) }.help("Open \(row.scan.name)")
            Menu {
                Button("Show in Finder") { model.showInFinder(row) }
                Button("Email Again") { model.email(row) }
                Button("Print…") { model.print(row, close: close) }.disabled(!row.canPrint)
                Divider()
                Button("Remove from List") { model.remove(row) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More for \(row.scan.name): Show in Finder, Email Again, Print, Remove from List")
            .accessibilityLabel("More for \(row.scan.name)")
        }
        .padding(.vertical, 2)
    }
}
