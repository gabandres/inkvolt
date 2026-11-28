import AppKit
import PdfCore
import PrintCore

/// Finder's "Convert to Word with Inkvolt PDF" (the Services entry in Info.plist, `ServiceProvider`) and the command
/// line's `--convert-to word <files…>` (`ConvertCommand`, `ConvertLaunch`), in the one copy of the app, as Windows'
/// `ExplorerConvert`: every request goes into one `ConvertQueue` and is converted by `convertFile`. One file with a
/// document window up shows the in-app one-click's notice there; otherwise the small `ConvertWindowController` lists
/// each file and what became of it (`ConvertCommand.showsNotice`). Change options… opens the PDF in a window and its
/// export options. Launched only to convert, the app quits once nothing is left (`ConvertCommand.mayExit`).
@MainActor
enum FinderConvert {
    private static var queue: ConvertQueue?
    private static var list: ConvertWindowController?
    private weak static var main: DocumentWindowController?
    private static var noticed: Set<ObjectIdentifier> = []
    private static var nextNoticed = false
    private static var gather = ConvertGather()
    private static var timer: Timer?
    private static var openLater: [(job: ConvertJob, output: String)] = []
    private static var openTimer: Timer?

    /// The app was started for conversions (a command-line launch, or Finder's service with nothing open): it quits once
    /// they are done and nothing else is open.
    static var quitWhenDone = false

    /// The command-line launch's own request, routed once the app has started (`AppDelegate`).
    static var pendingLaunch: ConvertCommand.Request?

    /// A stand-in for the conversion (a self-test's), nil for the real one.
    static var convertForTest: ConvertQueue.Convert?

    private static var shared: ConvertQueue {
        if let queue { return queue }
        let made = ConvertQueue { job, cancel in
            if let convertForTest { return try await convertForTest(job, cancel) }
            return try await convertFile(job, cancel)
        }
        made.changed = { onChanged($0) }
        queue = made
        return made
    }

    /// The jobs listed or noticed so far (the self-test).
    static var jobs: [ConvertJob] { queue?.jobs ?? [] }

    /// Returns once the gathered requests have been handed out and every conversion has ended.
    static func idle() async {
        while !gather.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        await queue?.idle()
    }

    /// The conversions window is open.
    static var listOpen: Bool { list != nil }

    /// Requests are being gathered, or conversions wait or run.
    static var converting: Bool { !gather.isEmpty || queue?.isBusy == true }

    /// Something is going on: the start page doesn't show over it.
    static var isActive: Bool { converting || listOpen || pendingLaunch != nil }

    /// The document window a notice shows in: the key one, else any.
    private static func frontController() -> DocumentWindowController? {
        let controllers = NSDocumentController.shared.documents.compactMap { $0.windowControllers.first as? DocumentWindowController }
            .filter { $0.window.map { !$0.isMiniaturized } == true && $0.pdf.session != nil } // a locked screen shows none as visible
        let current = NSDocumentController.shared.currentDocument?.windowControllers.first as? DocumentWindowController
        return controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first { $0 === current } ?? controllers.first
    }

    /// Converts `request`'s files, together with the requests that come with it: the batch is handed out once they stop
    /// coming (`ConvertGather`).
    static func route(_ request: ConvertCommand.Request) {
        if NSDocumentController.shared.documents.isEmpty && !listOpen && !converting
            && !NSApp.windows.contains(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) {
            quitWhenDone = true
        }
        gather.add(request, Date())
        arm()
    }

    private static func arm() {
        timer?.invalidate()
        timer = nil
        guard let due = gather.dueAt else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.001, due.timeIntervalSinceNow), repeats: false) { _ in
            MainActor.assumeIsolated { flush() }
        }
    }

    private static func flush() {
        guard gather.isDue(Date()) else { return arm() }
        timer = nil
        for batch in gather.take() { routeNow(batch, frontController()) }
        if !listOpen && !converting { maybeQuit() }
    }

    /// One batch: the notice in `main` for one file (opened when written, as the one-click), the list otherwise (nothing
    /// opened: a selection of thirty would open thirty Word windows).
    private static func routeNow(_ request: ConvertCommand.Request, _ window: DocumentWindowController?) {
        main = window
        let queue = shared
        let (taken, cut) = queue.fit(request)
        let leftOut = ConvertCommand.addLeftOut(ConvertCommand.addLeftOut(taken.overLimit, taken.refused), cut)
        // A notice still converting, or whose result waits to open, came from the same selection when another request
        // follows: it joins the list, and nothing opens.
        let folded = fold()
        let notice = !folded && leftOut == 0
            && ConvertCommand.showsNotice(windowReady: window != nil, listOpen: list != nil, busy: queue.isBusy, files: taken.files.count)
        Report.progress("convert from Finder: \(taken.files.count) file(s) to \(taken.format), \(notice ? "notice" : "listed")"
            + (leftOut > 0 ? ", \(taken.overLimit) over the limit, \(taken.refused) refused, \(cut) past the waiting list" : ""))
        if notice {
            window?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            showList()
            list?.sayLeftOut(overLimit: taken.overLimit, refused: taken.refused, cut: cut)
        }
        nextNoticed = notice
        defer { nextNoticed = false }
        queue.add(taken, open: notice)
    }

    private static func openWhenSettled(_ job: ConvertJob, _ output: String) {
        openLater.append((job, output))
        openSettled()
    }

    private static func openSettled() {
        openTimer?.invalidate()
        openTimer = nil
        guard !openLater.isEmpty else { return }
        if !gather.settled(Date()), let at = gather.settledAt {
            openTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, at.timeIntervalSinceNow), repeats: false) { _ in
                MainActor.assumeIsolated { openSettled() }
            }
            return
        }
        for (job, output) in openLater where job.open {
            if Report.isRunning {
                Report.progress("convert from Finder: would open \((output as NSString).lastPathComponent)")
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: output))
            }
        }
        openLater = []
    }

    /// Moves the notice's conversion (running, or saved with its result still to open) into the list: it opens nothing,
    /// and the list shows it with the rest of the selection. False when there was none.
    private static func fold() -> Bool {
        var jobs = (queue?.jobs ?? []).filter { noticed.contains(ObjectIdentifier($0)) && $0.state != .done }
        for later in openLater where !jobs.contains(where: { $0 === later.job }) { jobs.append(later.job) }
        guard !jobs.isEmpty else { return false }
        showList()
        for job in jobs {
            job.stopOpening()
            noticed.remove(ObjectIdentifier(job))
            list?.track(job)
        }
        openLater = []
        Report.progress("convert from Finder: a later request came; the notice's \(jobs.count) file(s) joined the list")
        return true
    }

    private static func showList() {
        if list == nil {
            let made = ConvertWindowController(shared)
            made.closed = {
                list = nil
                if !converting { maybeQuit() }
            }
            list = made
            made.showWindow(nil)
        }
        list?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func onChanged(_ job: ConvertJob) {
        if job.state == .waiting {
            if nextNoticed { noticed.insert(ObjectIdentifier(job)) } else { list?.track(job) }
            return
        }
        guard job.state == .done else { return }
        defer { if !converting && !listOpen { maybeQuit() } }
        guard noticed.remove(ObjectIdentifier(job)) != nil, let outcome = job.outcome else { return }
        // The window closed meanwhile: the list shows what became of it.
        guard let main, main.window != nil, main.pdf.session != nil else {
            showList()
            list?.track(job)
            return
        }
        // As the command bar's one-click: "Saved report.docx · Show in Finder · Change options…".
        switch outcome.result {
        case .saved:
            if job.open, let output = outcome.output { openWhenSettled(job, output) }
            let url = URL(fileURLWithPath: outcome.output ?? job.pdf)
            main.noticeBar.show(savedText(outcome), links: [
                (loc("Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                (loc("Change options…"), { changeOptions(job.pdf, job.format) }),
            ])
        case .cancelled:
            main.notify(loc("Export cancelled. Nothing was saved."))
        case .notFound:
            main.noticeBar.show(outcome.message ?? loc("Export failed"), links: [])
        default:
            main.noticeBar.show(outcome.message ?? loc("Export failed"), links: [(loc("Change options…"), { changeOptions(job.pdf, job.format) })])
        }
    }

    /// "Saved report.docx" (or "… in Documents"), its notes after it.
    static func savedText(_ outcome: ConvertOutcome) -> String {
        let file = ((outcome.output ?? "") as NSString).lastPathComponent
        if let notes = outcome.message, !notes.isEmpty {
            return outcome.inDocuments ? loc("Saved {0} in Documents ({1})", file, notes) : loc("Saved {0} ({1})", file, notes)
        }
        return outcome.inDocuments ? loc("Saved {0} in Documents", file) : loc("Saved {0}", file)
    }

    /// Opens `pdf` in a window and its export options for `format`.
    static func changeOptions(_ pdf: String, _ format: ExportFormat) {
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: pdf), display: true) { document, _, _ in
            MainActor.assumeIsolated {
                guard let controller = document?.windowControllers.first as? DocumentWindowController else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated { if !controller.isBusy { controller.askExport(format) } }
                }
            }
        }
    }

    /// Quits when the app was started for conversions and nothing is left: no document, no conversions window, nothing
    /// converting.
    static func maybeQuit() {
        guard quitWhenDone, !Report.isRunning else { return }
        let mainOpen = !NSDocumentController.shared.documents.isEmpty || StartWindowController.shared?.window?.isVisible == true
        guard ConvertCommand.mayExit(mainOpen: mainOpen, listOpen: listOpen, converting: converting, forwards: pendingLaunch == nil ? 0 : 1) else { return }
        NSApp.terminate(nil)
    }

    /// What a wrong command line says (English, as the rest of the command line).
    nonisolated static func explain(_ error: ConvertCommand.ParseError) -> String {
        switch error {
        case .noFormat: "Say what to convert to, then the files: --convert-to word (or excel, powerpoint, text, html) file.pdf"
        case .unknownFormat: "Inkvolt PDF converts to word, excel, powerpoint, text or html: --convert-to word file.pdf"
        default: "Name the PDF files to convert after the format: --convert-to word file.pdf"
        }
    }

    // MARK: One file

    /// Whether `path` is a regular file (a link followed), nil when nothing is there. A pipe or device is never read.
    nonisolated private static func fileKind(_ path: String) -> Bool? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// `work` off the main thread; Cancel ends the wait (the work is left to finish, its result dropped).
    private static func off<T: Sendable>(_ cancel: CancelToken, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await cancel.off(work)
    }

    /// Finder's "Convert to Word with Inkvolt PDF" for one file: the one-click Convert without a window, as Windows'
    /// `ExportActions.ConvertFile`. The file is read as File › Open reads it (its password asked for; a damaged one ends
    /// with Open's message), a protected one asks "export anyway?", every page goes with scanned pages recognized, the
    /// output is reserved next to the PDF or in Documents, never over a file, and it is opened when the job says so
    /// (once the requests have settled). Nothing is shown here: the outcome says what happened.
    static func convertFile(_ job: ConvertJob, _ cancel: CancelToken) async throws -> ConvertOutcome {
        let pdf = job.pdf, fileName = (pdf as NSString).lastPathComponent, format = job.format
        // A read that stalls (a server that stopped answering) doesn't hold the queue: Cancel ends the wait.
        switch try await off(cancel, { fileKind(pdf) }) {
        case nil: return .failed(.notFound, loc("Couldn't find {0}.", fileName))
        case false?: return .failed(.notOpened, loc("Couldn't open {0}", fileName) + ". " + loc("The file may be damaged or in a format Inkvolt PDF can't read."))
        case true?: break
        }
        var password: String?
        var wrong = false
        let session: DocumentSession
        while true {
            let pw = password
            do {
                // A session opened after Cancel won (its bytes and MuPDF context) is closed, not kept with no owner.
                session = try await cancel.off({ try SessionBox(DocumentSession.open(pdf, password: pw)) }, discard: { $0.session.close() }).session
                break
            } catch let e as PasswordRequired {
                // Cancelling one password prompt asks for no more in this selection's conversions (ConvertAnswers).
                try cancel.check()
                guard job.answers.askPasswords else { return .failed(.cancelled, nil) }
                guard let given = PasswordPrompt.ask(file: fileName, wrong: wrong || e.wrongPassword) else {
                    job.answers.askPasswords = false
                    return .failed(.cancelled, nil)
                }
                password = given
                wrong = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed(.notOpened, loc("Couldn't open {0}", fileName) + ". " + loc("The file may be damaged or in a format Inkvolt PDF can't read.")
                               + " " + ((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            }
        }
        defer { session.close() }
        let pages = Array(0..<session.engine.pageCount)
        guard !pages.isEmpty else { return .failed(.nothingToSave, loc("Nothing could be extracted from these pages, so no file was saved.")) }
        if session.openPassword != nil {
            // Asked once for this selection (ConvertAnswers).
            try cancel.check()
            if job.answers.exportProtected == nil {
                let alert = NSAlert()
                alert.messageText = loc("This PDF is password-protected")
                alert.informativeText = loc("The exported file is saved without its password protection: anyone can open it.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: loc("Export Anyway"))
                alert.addButton(withTitle: loc("Cancel"))
                job.answers.exportProtected = Report.skipsDialogs ? false : alert.runModal() == .alertFirstButtonReturn
            }
            if job.answers.exportProtected != true { return .failed(.cancelled, nil) }
        }
        let name = ConvertCommand.outputName(pdf, format)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        let target = try await off(cancel) { ExportTarget.reserve(pdfPath: pdf, fileName: name, documents: documents) }
        guard let target else {
            return .failed(.failed, loc("The PDF's folder doesn't accept new files and there is no Documents folder to use instead. Use Change options… to choose where to save it."))
        }
        defer { ExportTarget.deleteIfEmpty(target.path) }
        let data = session.data, pw = session.password
        let source = format == .powerPoint || format == .html ? data : nil
        let recognize = UserDefaults.standard.object(forKey: "ExportOcr") as? Bool != false
        let recognizer: Recognizer? = recognize ? (DocumentWindowController.atOnceRecognizer ?? SavedOcr.recognizer()) : nil
        let title = ((pdf as NSString).lastPathComponent as NSString).deletingPathExtension
        let options = ExportOptions(pages: pages, title: title, recognize: recognizer, source: source, sourcePassword: pw)
        let path = target.path
        do {
            let report = try await off(cancel) {
                let engine = try PdfEngine.open(data, password: pw)
                defer { engine.close() }
                return try DocumentExport.exportToFile(engine, format, path, options: options, cancel: cancel, overReservedOnly: true)
            }
            guard report.saved else {
                return .failed(.nothingToSave, DocumentWindowController.nothingSaved(report, format, pages: pages.count, recognize: recognize))
            }
            let notes = DocumentWindowController.exportNotes(report, format)
            return .saved(path, inDocuments: target.inDocuments, notes: notes.isEmpty ? nil : notes.joined(separator: ", "))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(.failed, (error as? LocalizedError)?.errorDescription ?? (error as? PdfEditError)?.message ?? String(describing: error))
        }
    }

    /// A session handed from the queue that opened it to the main actor, which alone uses it from then on.
    private struct SessionBox: @unchecked Sendable {
        let session: DocumentSession
        init(_ session: DocumentSession) { self.session = session }
    }
}

/// A continuation resumed once, by whichever comes first: the work's result or Cancel.
/// Finder's Services entry, "Convert to Word with Inkvolt PDF" (Info.plist's NSServices, message `convertToWord`): the PDFs
/// selected in Finder, as file URLs on the pasteboard, become one request. macOS starts the app when it isn't running and
/// hands every selected file to this one copy.
final class ServiceProvider: NSObject {
    @MainActor static let shared = ServiceProvider()

    @MainActor
    @objc func convertToWord(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let (request, why) = ConvertCommand.tryParse(["--convert-to", "word"] + urls.map(\.path), folder: "/")
        guard let request else {
            error.pointee = FinderConvert.explain(why) as NSString
            return
        }
        FinderConvert.route(request)
    }
}

/// A command-line launch (`--convert-to`) and the copy of the app already running, as Windows' single instance: the
/// launch hands its request over in a distributed notification (`deliverImmediately`, so a copy in the background gets
/// it) and waits for the copy's answer; with no copy running it becomes the app itself (`LaunchHandoff`). Only copies of
/// this same app bundle take each other's requests, so a self-test's copy from another folder never converts them.
enum ConvertLaunch {
    static let requestName = Notification.Name("com.bermudezsystems.InkvoltPdf.convert")
    static let answerName = Notification.Name("com.bermudezsystems.InkvoltPdf.convert.answer")

    private static var bundlePath: String { Bundle.main.bundleURL.standardizedFileURL.path }

    /// The command line's `--convert-to`: nil when this process is to become the app with `request` (set into
    /// `FinderConvert.pendingLaunch`), else the exit code (0: handed to the running copy; 2: a wrong command line; 1: no
    /// copy took it and another launch converts on its own).
    @MainActor
    static func run(_ command: [String]) -> Int32? {
        let (request, error) = ConvertCommand.tryParse(command)
        guard let request else {
            FileHandle.standardError.write(Data("Can't convert: \(FinderConvert.explain(error))\n".utf8))
            return 2
        }
        let start = Date()
        let way = LaunchHandoff.find(convert: true, own: { !otherCopyRuns() }, forward: { forward(request) },
                                     waiterSlot: { FileSlot.take(prefix: "waiter", count: 4) }, standaloneSlot: { FileSlot.take(prefix: "standalone", count: 1) != nil },
                                     elapsed: { Date().timeIntervalSince(start) }, wait: { Thread.sleep(forTimeInterval: $0) })
        switch way {
        case .forwarded: return 0
        case .dropped:
            FileHandle.standardError.write(Data("Inkvolt PDF didn't answer and another launch is converting on its own; nothing was converted.\n".utf8))
            return 1
        case .owner, .standalone:
            FinderConvert.pendingLaunch = request
            FinderConvert.quitWhenDone = true
            return nil
        }
    }

    private static func otherCopyRuns() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me && $0.bundleURL?.standardizedFileURL.path == bundlePath }
    }

    /// Posts the request and waits up to 3 seconds for the running copy to say it took it.
    @MainActor
    private static func forward(_ request: ConvertCommand.Request) -> Bool {
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        final class Flag: @unchecked Sendable { var taken = false }
        let flag = Flag()
        let observer = center.addObserver(forName: answerName, object: id, queue: nil) { _ in flag.taken = true }
        defer { center.removeObserver(observer) }
        center.postNotificationName(requestName, object: bundlePath,
                                    userInfo: ["id": id, "arguments": ConvertCommand.toArguments(request)], deliverImmediately: true)
        let until = Date().addingTimeInterval(3)
        while !flag.taken && Date() < until { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return flag.taken
    }

    /// The running copy's side: takes other launches' requests for this bundle and answers each.
    @MainActor
    static func listen() {
        DistributedNotificationCenter.default().addObserver(ConvertLaunchListener.shared, selector: #selector(ConvertLaunchListener.received(_:)),
                                                           name: requestName, object: bundlePath, suspensionBehavior: .deliverImmediately)
    }

    @MainActor
    fileprivate static func received(_ note: Notification) {
        guard let info = note.userInfo, let id = info["id"] as? String, id.count <= 64,
              let arguments = info["arguments"] as? [String], arguments.count <= ConvertCommand.maxFiles + 1 else { return }
        let (request, error) = ConvertCommand.tryParse(arguments, folder: "/")
        guard let request else { return Report.progress("forwarded convert command refused: \(error)") }
        DistributedNotificationCenter.default().postNotificationName(answerName, object: id, userInfo: nil, deliverImmediately: true)
        FinderConvert.route(request)
    }
}

/// The distributed notification's target (a selector-based observer delivers on the main thread).
final class ConvertLaunchListener: NSObject {
    @MainActor static let shared = ConvertLaunchListener()
    @MainActor @objc func received(_ note: Notification) { ConvertLaunch.received(note) }
}

/// One of a few lock files (`flock`) in the user's temporary folder: a launch holds one while it waits for the running
/// copy, or for as long as it converts on its own; the system lets go of it when the process ends.
final class FileSlot: LaunchSlot {
    private let fd: Int32
    private init(_ fd: Int32) { self.fd = fd }

    static func take(prefix: String, count: Int) -> FileSlot? {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-pdf-convert")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for i in 0..<count {
            let path = (folder as NSString).appendingPathComponent("\(prefix)-\(i).lock")
            let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return FileSlot(fd) }
            close(fd)
        }
        return nil
    }

    func release() { close(fd) }
}

/// The small window that lists Finder's conversions when the app isn't open or several files were chosen: each file,
/// its state, and when done "Saved report.docx · Open · Show in Finder · Change options…" or the message saying why
/// not. Cancel stops the one running and those waiting; closing it while it works does the same, then closes.
@MainActor
final class ConvertWindowController: NSWindowController, NSWindowDelegate {
    private let queue: ConvertQueue
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let dropped = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private let button = NSButton(title: loc("Cancel"), target: nil, action: nil)
    private var tracked: [(job: ConvertJob, row: NSStackView)] = []
    private var closeWhenIdle = false
    private var goneDone = 0, goneSaved = 0
    private var overLimit = 0, refusedCount = 0, cut = 0
    private var previous: ((ConvertJob) -> Void)?

    /// Called once the window has closed.
    var closed: (() -> Void)?

    init(_ queue: ConvertQueue) {
        self.queue = queue
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = loc("Convert with Inkvolt PDF")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        dropped.isHidden = true
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        let documentView = ConvertRowsView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = documentView
        button.target = self
        button.action = #selector(buttonClicked)
        button.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), button])
        let content = NSStackView(views: [heading, dropped, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 14, right: 24)
        window.contentView = content
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: documentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 520),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
            dropped.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
        ])
        window.center()
        // The queue reports to FinderConvert; this window listens after it.
        previous = queue.changed
        queue.changed = { [weak self] job in
            self?.previous?(job)
            self?.changed(job)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The heading the window shows (the self-test).
    var headingText: String { heading.stringValue }
    /// The left-out lines the window shows (the self-test).
    var droppedText: String { dropped.isHidden ? "" : dropped.stringValue }
    /// Each row's name and state as VoiceOver reads them (the self-test).
    var rowLabels: [String] { tracked.map { $0.row.accessibilityLabel() ?? "" } }
    /// The button's title: Cancel while converting, Close after.
    var buttonTitle: String { button.title }

    @objc private func buttonClicked() {
        if queue.isBusy { queue.cancelAll() } else { window?.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard queue.isBusy else { return true }
        // Nothing is left half done: the running one stops (its empty reserved file goes), then the window closes.
        guard !closeWhenIdle else { return false }
        closeWhenIdle = true
        queue.cancelAll()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.queue.idle()
            guard self.closeWhenIdle else { return }
            self.closeWhenIdle = false
            if !self.queue.isBusy { self.window?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        queue.changed = previous
        closed?()
    }

    /// Lists `job` (just queued); a close waiting for the cancelled ones is called off.
    func track(_ job: ConvertJob) {
        closeWhenIdle = false
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        tracked.append((job, row))
        rows.addArrangedSubview(row)
        // The rows follow the queue's list (it keeps the last ConvertQueue.maxListed finished): no row for good per file.
        if tracked.count > queue.jobs.count {
            let listed = Set(queue.jobs.map(ObjectIdentifier.init))
            for gone in tracked where !listed.contains(ObjectIdentifier(gone.job)) {
                gone.row.removeFromSuperview()
                goneDone += 1 // still counted in the heading (the queue trims finished ones only)
                if gone.job.outcome?.result == .saved { goneSaved += 1 }
            }
            tracked.removeAll { !listed.contains(ObjectIdentifier($0.job)) }
        }
        fill(job, row)
        refresh()
    }

    /// What the requests left out, said apart: past the 500-file limit, names that can't be a file, and files past the
    /// waiting list (`ConvertQueue.maxWaiting`).
    func sayLeftOut(overLimit: Int, refused: Int, cut: Int) {
        self.overLimit = ConvertCommand.addLeftOut(self.overLimit, overLimit)
        refusedCount = ConvertCommand.addLeftOut(refusedCount, refused)
        self.cut = ConvertCommand.addLeftOut(self.cut, cut)
        var lines: [String] = []
        let n = CoreLanguage.number
        if self.overLimit > 0 {
            lines.append(self.overLimit == 1 ? loc("{0} more file wasn't added: Inkvolt PDF converts up to {1} at a time.", 1, n(ConvertCommand.maxFiles))
                : loc("{0} more files weren't added: Inkvolt PDF converts up to {1} at a time.", n(self.overLimit), n(ConvertCommand.maxFiles)))
        }
        if refusedCount > 0 {
            lines.append(refusedCount == 1 ? loc("{0} file name couldn't be used (it holds characters no file name can have, or it names a device), so it was left out.", 1)
                : loc("{0} file names couldn't be used (they hold characters no file name can have, or they name a device), so they were left out.", n(refusedCount)))
        }
        if self.cut > 0 {
            lines.append(self.cut == 1 ? loc("{0} more file wasn't added: up to {1} files can wait to be converted. Try it again once these are done.", 1, n(ConvertQueue.maxWaiting))
                : loc("{0} more files weren't added: up to {1} files can wait to be converted. Try them again once these are done.", n(self.cut), n(ConvertQueue.maxWaiting)))
        }
        dropped.stringValue = lines.joined(separator: "\n")
        dropped.isHidden = lines.isEmpty
    }

    private func changed(_ job: ConvertJob) {
        for (j, row) in tracked where j === job {
            fill(job, row)
            if job.state == .converting { row.scrollToVisible(row.bounds) }
        }
        refresh()
    }

    private func refresh() {
        let total = tracked.count + goneDone
        let done = tracked.filter { $0.job.state == .done }.count + goneDone
        let saved = tracked.filter { $0.job.outcome?.result == .saved }.count + goneSaved
        let n = CoreLanguage.number
        heading.stringValue = done < total || total == 0
            ? (total == 1 ? loc("Converting {0} file", 1) : loc("Converting {0} files", n(total)))
            : loc("{0} of {1} converted", n(saved), n(total))
        button.title = queue.isBusy ? loc("Cancel") : loc("Close")
    }

    private func fill(_ job: ConvertJob, _ row: NSStackView) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        // The name comes from outside: one line, cut with "…".
        let name = NSTextField(labelWithString: (job.pdf as NSString).lastPathComponent)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = job.pdf
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        row.addArrangedSubview(name)
        let outcome = job.outcome
        let text: String
        switch job.state {
        case .waiting: text = loc("Waiting")
        case .converting: text = loc("Converting…")
        case .done:
            switch outcome?.result {
            case .saved?: text = outcome.map(FinderConvert.savedText) ?? ""
            case .cancelled?: text = loc("Cancelled")
            default: text = outcome?.message ?? loc("Export failed")
            }
        }
        let state = NSTextField(wrappingLabelWithString: text)
        state.maximumNumberOfLines = 3
        state.textColor = outcome.map { $0.result != .saved && $0.result != .cancelled } == true ? .systemRed : .secondaryLabelColor
        state.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        row.addArrangedSubview(state)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(name.stringValue): \(text)")
        guard job.state == .done, let outcome else { return }
        var links: [NSButton] = []
        if outcome.result == .saved, let output = outcome.output {
            let url = URL(fileURLWithPath: output)
            links.append(link(loc("Open")) { NSWorkspace.shared.open(url) })
            links.append(link(loc("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if outcome.result != .notFound {
            links.append(link(loc("Change options…")) { FinderConvert.changeOptions(job.pdf, job.format) })
        }
        if !links.isEmpty { row.addArrangedSubview(NSStackView(views: links)) }
    }

    private var actions: [ObjectIdentifier: () -> Void] = [:]

    private func link(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(linkClicked(_:)))
        b.isBordered = false
        b.contentTintColor = .linkColor
        actions[ObjectIdentifier(b)] = action
        return b
    }

    @objc private func linkClicked(_ sender: NSButton) { actions[ObjectIdentifier(sender)]?() }
}

/// A document view that lays out from the top.
private final class ConvertRowsView: NSView {
    override var isFlipped: Bool { true }
}
