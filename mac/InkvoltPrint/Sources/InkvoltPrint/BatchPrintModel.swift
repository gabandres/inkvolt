import AppKit
import Observation
import PrintCore
import PrintMac
import UniformTypeIdentifiers

/// One file of the Batch Print window: how it prints, what it came to, and where it got to.
@MainActor @Observable
final class BatchRow: Identifiable {
    let id = UUID()
    let path: String
    var copies: Int
    var range: String
    var twoSided: Bool
    /// The paper's IPP name; nil: the printer's default.
    var paper: String?
    private(set) var measure: BatchMeasure?
    private(set) var line: BatchPrintLine?
    private(set) var result: BatchPrintResult?
    /// "Sending", "Getting page 2 of 4 ready…" while it goes.
    private(set) var activity: String?

    init(_ path: String, _ settings: BatchPrintSettings) {
        self.path = path
        copies = settings.copies
        range = settings.range ?? ""
        twoSided = settings.twoSided
        paper = settings.paper
    }

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var settings: BatchPrintSettings {
        BatchPrintSettings(copies: copies, range: range.trimmingCharacters(in: .whitespaces).isEmpty ? nil : range, twoSided: twoSided, paper: paper)
    }

    /// Print sends it (again): nothing of it may be in the queue yet.
    var stillToSend: Bool { result?.stillToSend ?? true }
    var needsPassword: Bool { measure?.state == .needsPassword || measure?.state == .wrongPassword }
    /// The password that opened it, in memory only.
    var password: String? { measure?.password }

    var pagesText: String { measure?.state == .ready ? BatchPrintText.count(measure?.pageCount ?? 0, "page") : "" }
    var sheetsText: String { line?.problem == nil && line != nil ? BatchPrintText.sheets(line?.sheets ?? 0) : "" }

    var stateText: String {
        if let activity { return activity }
        if let result { return "\(result.state.rawValue): \(result.message)" }
        guard let measure else { return "Looking at it…" }
        return line?.problem ?? (measure.state == .ready ? "Ready" : measure.problem ?? "")
    }

    var isProblem: Bool {
        if let result { return result.state == .failed || result.state == .skipped }
        return line?.problem != nil
    }

    func measured(_ m: BatchMeasure, _ info: BatchQueueInfo?) {
        measure = m
        refresh(info)
    }

    /// The line again with the row's settings now and the printer as last read.
    func refresh(_ info: BatchQueueInfo?) {
        line = measure.map { BatchPrintLine(path, settings, $0, info) }
    }

    func forget() {
        measure = nil
        line = nil
        result = nil
        activity = nil
    }

    func sending(_ text: String) { activity = text }

    func finished(_ r: BatchPrintResult) {
        result = r
        activity = nil
    }

    func waiting() {
        result = nil
        activity = "Waiting"
    }
}

/// A printer a batch can go to: a macOS queue (demo mode's made-up ones).
struct BatchQueueChoice: Identifiable, Hashable {
    var id: String
    var name: String
}

/// The Batch Print window (roadmap 2.4; Windows' `BatchPrintViewModel`): PDFs and pictures or a folder, added or dropped, in
/// an order the user sets, each estimated in sheets before anything is sent; Print sends them one job at a time to the
/// printer's macOS queue (asking first over `BatchPrintLimits.confirmSheets`), shows each file's progress, and Stop stops
/// between files and pages. Pro (`batchPrintAutomation`): Save List…, Open List…, Watch Folder… and Export Results….
@MainActor @Observable
final class BatchPrintModel {
    let app: AppModel
    let documents: any BatchDocuments = MacBatchDocuments()

    var choices: [BatchQueueChoice] = []
    var queueId: String? {
        didSet { if oldValue != queueId { readQueue() } }
    }
    private(set) var info: BatchQueueInfo?
    var rows: [BatchRow] = []
    var selection: BatchRow.ID?

    var allCopies = 1
    var allTwoSided = false
    var allPaper: String?

    private(set) var isEstimating = false
    private(set) var isSending = false
    var progress: String?
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var watchedFolder: String?
    private(set) var watchLines: [String] = []

    /// The queue Print sent to last (the report reads the demo queue's jobs).
    @ObservationIgnored private(set) var lastQueue: (any BatchQueue)?
    @ObservationIgnored private var run: BatchStop?
    @ObservationIgnored private var watching: BatchStop?
    @ObservationIgnored private var estimating: BatchStop?
    @ObservationIgnored private var declinedPassword = false
    /// `--report`: answers the password questions instead of a person (nil: nobody answers).
    @ObservationIgnored var answer: ((String, Bool) -> String?)?
    /// `--report`: says yes to every question (over 100 sheets, replacing the list, watching a folder with files in it).
    @ObservationIgnored var sayYes = false
    /// The questions asked (`--report` lists them).
    @ObservationIgnored private(set) var questions: [String] = []
    /// The window's last finished batch, for Export Results… and the report.
    private(set) var lastSummary: BatchPrintSummary?

    init(app: AppModel) {
        self.app = app
        loadChoices()
    }

    var selected: BatchRow? { rows.first { $0.id == selection } }
    var canTwoSided: Bool { info?.canTwoSided ?? true }
    var papers: [BatchPaper] { info?.papers ?? [] }
    var isFree: Bool { !isSending && !isEstimating }
    var stillToSend: [BatchRow] { rows.filter(\.stillToSend) }
    var totalSheets: Int { stillToSend.reduce(0) { $0 + ($1.line?.sheets ?? 0) } }
    var canPrint: Bool { isFree && info != nil && stillToSend.contains { $0.line?.problem == nil && $0.line != nil } }
    var hasResults: Bool { rows.contains { $0.result != nil } }

    /// "3 files, 7 sheets to send" under the list.
    var summary: String {
        let waiting = stillToSend
        let skipped = waiting.filter { $0.line?.problem != nil }.count
        var text = "\(BatchPrintText.count(waiting.count, "file")), \(BatchPrintText.sheets(totalSheets)) to send"
        if skipped > 0 { text += " (\(BatchPrintText.number(skipped)) left out)" }
        return rows.isEmpty ? "Add PDFs and pictures, or a folder of them." : text + "."
    }

    // MARK: The printer

    private func loadChoices() {
        if app.isDemo {
            choices = DemoBatchQueue.all.map { BatchQueueChoice(id: $0.destination.name, name: $0.name) }
        } else {
            choices = (app.destinations ?? []).filter(CupsQueues.isRealQueue).map { BatchQueueChoice(id: $0.name, name: $0.displayName) }
        }
        // The printer shown in the main window, when it has a queue.
        let shown = app.isDemo ? "Office_color_MFP" : app.selected?.queueName
        queueId = choices.first { $0.id == shown }?.id ?? choices.first?.id
    }

    func reloadChoices() {
        let keep = queueId
        loadChoices()
        if let keep, choices.contains(where: { $0.id == keep }) { queueId = keep }
    }

    func queue() -> (any BatchQueue)? {
        guard let id = queueId else { return nil }
        return app.isDemo ? DemoBatchQueue.named(id) : CupsBatchQueue(queue: id)
    }

    private func readQueue() {
        Task { _ = await readInfo() }
    }

    @discardableResult
    func readInfo() async -> BatchQueueInfo? {
        let read = try? await queue()?.read()
        info = read ?? nil
        if let paper = allPaper, !(info?.papers.contains { $0.key == paper } ?? false) { allPaper = nil }
        for row in rows { row.refresh(info) }
        return info
    }

    // MARK: The list

    /// Adds files and folders (dropped too), each once, then looks at what's new. A folder's files come at its top, in name order.
    func add(_ urls: [URL]) async {
        if isSending {
            say("Wait until the batch has been sent to change the list.", error: true)
            return
        }
        BatchPlaces.remember(urls, app.store, demo: app.isDemo)
        let paths = urls.map(\.path)
        let (files, leftOut) = await Task.detached { BatchPrintFiles.expand(paths, recursive: false) }.value
        var known = Set(rows.map { $0.path.lowercased() })
        var added = 0, repeated = 0, overLimit = 0
        for file in files {
            if !known.insert(file.lowercased()).inserted {
                repeated += 1
            } else if rows.count >= BatchPrintLimits.maxFiles {
                overLimit += 1
            } else {
                rows.append(BatchRow(file, BatchPrintSettings(copies: allCopies, range: nil, twoSided: allTwoSided, paper: allPaper)))
                added += 1
            }
        }
        var notes: [String] = []
        if repeated > 0 { notes.append("\(BatchPrintText.count(repeated, "file")) already on the list") }
        if leftOut > 0 { notes.append("\(BatchPrintText.count(leftOut, "file")) neither a PDF nor a picture") }
        if overLimit > 0 { notes.append("\(BatchPrintText.number(overLimit)) over the \(BatchPrintText.number(BatchPrintLimits.maxFiles)) a batch takes") }
        say(notes.isEmpty ? nil : "Added \(BatchPrintText.number(added)): \(notes.joined(separator: ", ")).", error: overLimit > 0)
        await estimate()
    }

    /// Opens every row not looked at yet, one at a time and off the main thread.
    func estimate() async {
        if isEstimating { return } // the run under way reaches the new rows too
        isEstimating = true
        declinedPassword = false
        let stop = BatchStop()
        estimating = stop
        defer {
            progress = nil
            isEstimating = false
            estimating = nil
        }
        if info == nil { await readInfo() }
        while let row = rows.first(where: { $0.measure == nil }), !stop.isStopped {
            progress = "Looking at \(BatchPrintText.clean(row.name))…"
            let measure: BatchMeasure
            do {
                measure = try await BatchMeasurer.measure(row.path, offered: row.password, documents, ask: askClosure(), stop)
            } catch {
                break // the list was cleared while looking
            }
            row.measured(measure, info)
        }
    }

    private func askClosure() -> @Sendable (String, Bool) async -> String? {
        { [weak self] name, wrong in await self?.askPassword(name, wrong) }
    }

    /// The first locked file asks; after "no" the others wait for Enter Password…, instead of a window for each.
    private func askPassword(_ file: String, _ wrong: Bool) -> String? {
        if declinedPassword { return nil }
        let given: String?
        if let answer {
            given = answer(file, wrong)
        } else {
            let alert = NSAlert()
            alert.messageText = wrong ? "That password doesn't open \(BatchPrintText.clean(file))." : "\(BatchPrintText.clean(file)) is protected with a password."
            alert.informativeText = "Type its password to print it, or leave it out of the batch."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Leave It Out")
            alert.window.initialFirstResponder = field
            given = alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        if given == nil { declinedPassword = true }
        return given
    }

    func enterPassword() async {
        guard let row = selected, row.needsPassword, isFree else { return }
        declinedPassword = false
        isEstimating = true
        defer { isEstimating = false }
        if let m = try? await BatchMeasurer.measure(row.path, offered: nil, documents, ask: askClosure()) { row.measured(m, info) }
    }

    /// Looks at every row again, so what changed on disk shows now; a file that may be in the queue already stays as it is.
    func checkAgain() async {
        for row in rows where row.stillToSend { row.forget() }
        await estimate()
    }

    /// Forgets every result, so Print sends the whole list again.
    func startOver() async {
        let done = rows.filter { !$0.stillToSend }.count
        if done > 0, !confirm("\(BatchPrintText.count(done, "file")) of this list went to the printer already. Send the whole list again?", "Start Over") { return }
        for row in rows { row.forget() }
        say(nil)
        await estimate()
    }

    func move(_ by: Int) {
        guard !isSending, let row = selected, let at = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let to = at + by
        guard to >= 0, to < rows.count else { return }
        rows.swapAt(at, to)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(row.name), \(to + 1) of \(rows.count)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func remove() {
        guard !isSending, let row = selected, let at = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows.remove(at: at)
        selection = rows.isEmpty ? nil : rows[min(at, rows.count - 1)].id
    }

    func clear() {
        guard !isSending else { return }
        estimating?.stop()
        rows.removeAll()
        selection = nil
        say(nil)
    }

    /// A row's settings changed in the editor: its line again.
    func changed(_ row: BatchRow) { row.refresh(info) }

    // MARK: Printing

    func printAll() async {
        guard canPrint, let queue = queue() else { return }
        guard let info = await readInfo() else {
            say("This printer has no macOS print queue to print through.", error: true)
            return
        }
        let send = rows.filter { $0.stillToSend && $0.measure != nil }
        for row in send { row.refresh(info) }
        let sheets = send.reduce(0) { $0 + ($1.line?.sheets ?? 0) }
        if sheets > BatchPrintLimits.confirmSheets,
           !confirm("This batch comes to \(BatchPrintText.sheets(sheets)) on \(BatchPrintText.clean(info.name)). Print it?", "Print") { return }

        isSending = true
        let stop = BatchStop()
        run = stop
        lastQueue = queue
        say(nil)
        defer {
            run = nil
            progress = nil
            isSending = false
        }
        for row in send { row.waiting() }
        let lines = send.compactMap(\.line)
        let progressing: @Sendable (BatchPrintProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.apply(p, send) }
        }
        let documents = documents
        let summary = await Task.detached { await BatchPrintRunner.run(lines, queue, documents, progress: progressing, stop) }.value
        // Progress arrives in tasks of its own: every result is applied here in case a late one hasn't landed.
        for result in summary.items { send[result.index].finished(result) }
        lastSummary = summary
        say(summary.text, error: summary.stoppedAt != nil || summary.failed > 0)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: summary.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func apply(_ p: BatchPrintProgress, _ rows: [BatchRow]) {
        guard p.index < rows.count else { return }
        let row = rows[p.index]
        if let result = p.result { row.finished(result) } else { row.sending(p.message) }
        progress = p.result == nil ? "File \(p.index + 1) of \(rows.count), \(BatchPrintText.clean(row.name)): \(p.message)" : nil
    }

    func stop() {
        run?.stop()
        progress = "Stopping after the page being drawn…"
    }

    // MARK: Pro

    private func proAllows() -> Bool {
        if Pro.allows(.batchPrintAutomation) { return true }
        ProWindow.show(feature: .batchPrintAutomation)
        return false
    }

    func saveList() {
        guard !rows.isEmpty, proAllows() else { return }
        let panel = NSSavePanel()
        panel.title = "Save the batch list"
        panel.allowedContentTypes = [BatchPlaces.listType]
        panel.nameFieldStringValue = "Batch list" + BatchPrintList.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveList(to: url)
    }

    @discardableResult
    func saveList(to url: URL) -> Bool {
        do {
            try BatchPrintList.save(url.path, rows.map { BatchListEntry($0.path, $0.settings) })
            BatchPlaces.remember([url], app.store, demo: app.isDemo)
            say("Saved \(url.lastPathComponent). Print it from Terminal with: \(BatchPrintCommandLine.program) print --list <the list> --printer <name>")
            return true
        } catch {
            say("The list wasn't saved: \(BatchPrintText.describe(error))", error: true)
            return false
        }
    }

    func openList() {
        guard isFree, proAllows() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a batch list"
        panel.allowedContentTypes = [BatchPlaces.listType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openList(url) }
    }

    /// Puts a saved list's files on the list. Prints nothing: every path is shown and estimated first. Its files are the
    /// ones the sandbox lets this app reach (`BatchPlaces`): one it doesn't reads as "macOS doesn't let Inkvolt Print read".
    func openList(_ url: URL) async {
        BatchPlaces.remember([url], app.store, demo: app.isDemo)
        let path = url.path
        do {
            var entries: [BatchListEntry]
            do {
                entries = try await Task.detached { try BatchPrintList.load(path, allowNetwork: false) }.value
            } catch let e as BatchListError where e.needsNetwork {
                guard confirm("\(e.message) Opening them shares this Mac's sign-in with those computers.", "Open Them") else { return }
                entries = try await Task.detached { try BatchPrintList.load(path, allowNetwork: true) }.value
            }
            let chosen = entries
            let files = try await Task.detached { try BatchPrintList.expand(chosen) }.value
            if !rows.isEmpty, !confirm("Replace the files on the list with the saved list's?", "Replace") { return }
            clear()
            BatchPlaces.open(app.store)
            rows = files.map { BatchRow($0.path, $0.settings) }
            await estimate()
        } catch let e as BatchListError {
            say(e.message, error: true)
        } catch {
            say(BatchPrintText.describe(error), error: true)
        }
    }

    /// The results as a CSV: Pro's.
    func resultsCsv() -> String? {
        let results = rows.enumerated().compactMap { i, row -> BatchPrintResult? in
            guard var r = row.result else { return nil }
            r.index = i
            return r
        }
        return BatchPrintCsv.export(results)
    }

    func exportResults() {
        guard hasResults else { return }
        guard let csv = resultsCsv() else {
            ProWindow.show(feature: .batchPrintAutomation)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save the batch's results"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Batch results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(("\u{FEFF}" + csv).utf8).write(to: url, options: .atomic) // a byte order mark: a spreadsheet reads the names right
            say("Saved \(url.lastPathComponent).")
        } catch {
            say("The results weren't saved: \(BatchPrintText.describe(error))", error: true)
        }
    }

    func chooseWatchFolder() {
        guard watchedFolder == nil, !isSending, proAllows() else { return }
        let panel = NSOpenPanel()
        panel.title = "Watch a folder"
        panel.message = "Each PDF or picture that lands in this folder prints once on \(info?.name ?? "the printer"), with the settings for all files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await self.watch(url) }
    }

    /// Prints each file that lands in the folder, with the "for all files" settings, while it runs. Asks first when files are
    /// there already: choosing the wrong folder shouldn't print it. Not started again by itself after a restart.
    func watch(_ url: URL, once: Bool = false) async {
        guard watchedFolder == nil, let queue = queue() else { return }
        BatchPlaces.remember([url], app.store, demo: app.isDemo)
        let folder = url.path
        let already = BatchPrintFolder.readyToPrint(folder)
        if already > 0,
           !confirm("\(BatchPrintText.count(already, "file")) in \(BatchPrintText.clean(url.lastPathComponent)) would print as soon as it's watched. Print them?",
                    "Print Them") { return }
        let stop = BatchStop()
        watching = stop
        watchedFolder = folder
        watchLines = []
        say(nil)
        var options = BatchFolderOptions()
        options.settings = BatchPrintSettings(copies: allCopies, range: nil, twoSided: allTwoSided, paper: allPaper)
        options.once = once
        if once {
            options.quietPeriod = .milliseconds(300)
            options.pollInterval = .milliseconds(100)
        }
        let progressing: @Sendable (BatchFolderProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.watched(p) }
        }
        let documents = documents, chosen = options
        do {
            let summary = try await Task.detached { try await BatchPrintFolder.run(folder, queue, documents, chosen, progress: progressing, stop) }.value
            say("Stopped watching: \(BatchPrintText.count(summary.sent, "file")) sent (\(BatchPrintText.sheets(summary.sheetsSent))), "
                + "\(BatchPrintText.number(summary.failed)) failed.\(summary.stopReason.map { " " + $0 } ?? "")", error: summary.stopReason != nil)
        } catch let e as BatchFolderBusyError {
            say(e.message, error: true)
        } catch {
            say(BatchPrintText.describe(error), error: true)
        }
        watching = nil
        watchedFolder = nil
    }

    private func watched(_ p: BatchFolderProgress) {
        if let waiting = p.waiting { addWatchLine("Waiting: \(waiting)") }
        if let e = p.finished { addWatchLine("\(BatchFolderEntry.stamp(e.time, date: false)) \(BatchPrintText.clean(e.fileName)): \(e.message)") }
    }

    private func addWatchLine(_ line: String) {
        watchLines.insert(line, at: 0)
        if watchLines.count > 200 { watchLines.removeLast() }
    }

    func stopWatching() { watching?.stop() }

    // MARK: Words

    private func say(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }

    private func confirm(_ question: String, _ yes: String) -> Bool {
        questions.append(question)
        if sayYes || Report.isRunning { return true }
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The files and folders the Batch Print window was given, remembered (`PrintState.batchPlaces`) so the sandbox lets the
/// command line and a list opened later reach them again. Nothing is remembered in demo mode.
@MainActor
enum BatchPlaces {
    static let listType = UTType(filenameExtension: String(BatchPrintList.fileExtension.dropFirst()), conformingTo: .json) ?? .json

    static func remember(_ urls: [URL], _ store: StateStore, demo: Bool) {
        guard !demo else { return }
        let made = urls.compactMap { url in FolderBookmarks.make(url).map { (url.standardizedFileURL.path, $0) } }
        guard !made.isEmpty else { return }
        store.change { state in
            let given = Set(made.map(\.0))
            state.batchPlaces.removeAll { data in FolderBookmarks.resolve(data).map { given.contains($0.url.standardizedFileURL.path) } ?? true }
            state.batchPlaces += made.map(\.1)
            if state.batchPlaces.count > PrintState.maxBatchPlaces { state.batchPlaces.removeFirst(state.batchPlaces.count - PrintState.maxBatchPlaces) }
        }
    }

    /// Every remembered place opened to the sandbox for this run (the command line, a list opened again). Returns how many.
    @discardableResult
    static func open(_ store: StateStore) -> Int {
        var opened = 0
        for data in store.current.batchPlaces {
            guard let (url, _) = FolderBookmarks.resolve(data) else { continue }
            if url.startAccessingSecurityScopedResource() { opened += 1 }
        }
        return opened
    }
}
