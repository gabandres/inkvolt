import AppKit
import PDFKit
import PrintCore
import PrintMac

/// Print a PDF straight to the printer (roadmap 2.1, Windows' DirectPrinter): a network printer macOS has no queue for, that
/// takes PWG raster, Apple raster or PCLm over IPP, gets the pages from Inkvolt Print itself: its options asked here (copies,
/// paper, both sides, color, from the printer's own attributes), the pages drawn (`DirectPrintPages`), the printer asked
/// whether it can print now, the job sent with Print-Job and followed in a small window until it ends, with Cancel. Where
/// the printer has a queue, macOS's print panel prints as before (PrintRoutes: the queue stays the default; no choice of
/// straight is offered on the Mac, PLAN P12 2.1).
@MainActor
enum DirectPrinting {
    /// The printer's IPP client when its jobs go straight to it: no macOS queue, and its IPP lists a raster format.
    static func route(_ printer: PrinterModel) async -> IppClient? {
        guard printer.isNetwork, let connection = await printer.connection(), let ipp = connection.ipp else { return nil }
        let raster = !IppPrintCaps.formatsIn(connection.probe.ipp?.strs("document-format-supported") ?? []).isEmpty
        let route = PrintRoutes.choose(hasQueue: printer.queueName != nil, printerTakesRaster: raster, personChoseDirect: false)
        return route == .direct ? ipp : nil
    }

    /// The account name the printer shows with the job.
    static var user: String { NSUserName() }

    /// Asks the options, then prints the PDF at `url` (opened with `password` when it has one) on `printer` through `ipp`;
    /// problems in plain words, nothing sent before the printer was asked whether it can print.
    static func print(_ url: URL, password: String?, name: String, on printer: PrinterModel, ipp: IppClient) async {
        let caps: IppPrintCaps
        do {
            caps = IppPrintCaps.from(try await ipp.printerAttributes(IppPrintCaps.requested))
        } catch {
            Printing.alert(DirectPrintError.noAnswerBeforeSending().message)
            return
        }
        guard let request = ask(caps, file: name, printer: printer.name) else { return }
        let plan: DirectPrintPlan
        switch DirectPrintPlan.choose(caps, request) {
        case .success(let p): plan = p
        case .failure(let problem):
            Printing.alert(problem.message)
            return
        }
        let window = DirectPrintWindow(title: String(localized: "Printing \(name) on \(printer.name)"))
        let job = Task {
            let said = await run(url, password: password, name: name, plan: plan, ipp: ipp) { window.say($0) }
            window.done(said)
        }
        window.onCancel = { job.cancel() }
    }

    /// The PDF at `url` drawn into a job file and sent, then followed; `say` tells each step, and the end is returned, in
    /// words true to what happened. Cancel before the printer has the job sends nothing; the sending itself is never cut
    /// (Windows sends with no cancel: a job cut halfway may print anyway); once the printer has given the job an id, Cancel
    /// is Cancel-Job (and says when the printer didn't take it). `sent`: the printer has the job (its id, 0 when it gave none).
    static func run(_ url: URL, password: String?, name: String, plan: DirectPrintPlan, ipp: IppClient,
                    sent: ((Int) -> Void)? = nil, say: @escaping @MainActor @Sendable (String) -> Void) async -> String {
        say(String(localized: "Asking the printer whether it can print…"))
        if let problem = await printerProblem(ipp) { return problem }
        say(String(localized: "Making the pages ready…"))
        let file = DirectJobFile.temporaryUrl()
        defer { try? FileManager.default.removeItem(at: file) }
        let head = DirectJob.printJobRequest(ipp.printerUri, user: user, jobName: name, plan)
        let drawn = Task.detached(priority: .userInitiated) { () throws -> (upload: DirectJobUpload, pages: Int) in
            try draw(url, password: password, plan: plan, into: file, head: head)
        }
        let made: (upload: DirectJobUpload, pages: Int)
        do {
            made = try await withTaskCancellationHandler { try await drawn.value } onCancel: { drawn.cancel() }
        } catch is CancellationError {
            return String(localized: "Cancelled. Nothing was sent.")
        } catch let e as DirectPrintError {
            return e.message
        } catch {
            return String(localized: "Its pages couldn't be made ready on this Mac. Nothing was sent.")
        }
        if Task.isCancelled { return String(localized: "Cancelled. Nothing was sent.") }
        say(String(localized: "Sending the pages to the printer…"))
        let reply: (jobId: Int, state: DirectJobState?)
        do {
            reply = try await DirectJob.send(ipp, made.upload)
        } catch {
            return (error as? DirectPrintError)?.message ?? loc("The printer stopped answering while the job was sent. Check it before printing again: it may have the job.")
        }
        let (id, answered) = reply
        sent?(id)
        // Windows' count: one copy's pages (a blank back included), each copy sent again, each copy the printer makes.
        let impressions = plan.impressions(made.pages)
        guard id > 0 else {
            if Task.isCancelled { return String(localized: "The printer already has the job and gave it no number to cancel it by. Cancel it on the printer's control panel.") }
            return answered.map { DirectJob.describe($0, pages: impressions) } ?? loc("Waiting its turn at the printer")
        }
        if !Task.isCancelled { say(answered.map { DirectJob.describe($0, pages: impressions) } ?? loc("Waiting its turn at the printer")) }
        let clock = ContinuousClock()
        let started = clock.now
        let watched = await DirectJob.watch(ipp, user: user, jobId: id, every: .seconds(2), quiet: .seconds(180)) { state in
            Task { @MainActor in say(DirectJob.describe(state, pages: impressions)) }
        }
        let last = watched ?? answered
        if Task.isCancelled {
            do { try await DirectJob.stop(ipp, user: user, jobId: id) } catch let e as DirectPrintError {
                return e.message
            } catch {}
            return loc("Cancelled at the printer")
        }
        if let tooLong = DirectJob.followedTooLong(last, after: clock.now - started) { return tooLong }
        return last.map { DirectJob.describe($0, pages: impressions) } ?? loc("Waiting its turn at the printer")
    }

    /// Off the main thread: the PDF opened from its file, its pages drawn into the job file after `head` (Print-Job's
    /// attributes). Returns the file to upload and the PDF's page count.
    nonisolated private static func draw(_ url: URL, password: String?, plan: DirectPrintPlan, into file: URL, head: [UInt8]) throws
        -> (upload: DirectJobUpload, pages: Int) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { throw DirectPrintPages.NotDrawn() }
        if document.isLocked, !(password.map { document.unlock(withPassword: $0) } ?? false) { throw DirectPrintPages.NotDrawn() }
        let job = try DirectJobFile(file, request: head)
        try DirectPrintPages.write(document, plan: plan) { bytes in try job.append(bytes) }
        return (try job.finish(), document.pageCount)
    }

    /// Why nothing should go to the printer now (stopped, an error, not taking jobs), or nil.
    static func printerProblem(_ ipp: IppClient) async -> String? {
        do {
            return DirectJob.printerProblem(try await ipp.printerAttributes(DirectJob.stateAttributes))
        } catch {
            return DirectPrintError.noAnswerBeforeSending().message
        }
    }

    /// The options, from what the printer offers: copies, paper, both sides, color. Nil when cancelled.
    private static func ask(_ caps: IppPrintCaps, file: String, printer: String) -> DirectPrintRequest? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Print \(file) straight to \(printer)?")
        alert.informativeText = String(localized: "macOS has no printer set up for it, so Inkvolt Print draws the pages and sends them to the printer itself.")
        let copies = NSTextField(string: "1")
        copies.formatter = { () -> NumberFormatter in
            let f = NumberFormatter()
            (f.minimum, f.maximum, f.allowsFloats) = (1, 999, false)
            return f
        }()
        copies.frame.size.width = 60
        let papers = NSPopUpButton()
        let choices = caps.paperChoices()
        papers.addItems(withTitles: choices.map(\.label))
        if let d = caps.defaultPaper, let i = choices.firstIndex(where: { $0.paper.name == d.name }) { papers.selectItem(at: i) }
        let sides = NSButton(checkboxWithTitle: String(localized: "Both sides"), target: nil, action: nil)
        sides.isEnabled = caps.twoSided
        let color = NSPopUpButton()
        color.addItems(withTitles: [String(localized: "Color"), String(localized: "Black and white")])
        color.selectItem(at: caps.color && caps.colorByDefault ? 0 : 1)
        color.isEnabled = caps.color
        let rows: [[NSView]] = [
            [NSTextField(labelWithString: String(localized: "Copies:")), copies],
            [NSTextField(labelWithString: String(localized: "Paper:")), papers],
            [NSTextField(labelWithString: ""), sides],
            [NSTextField(labelWithString: String(localized: "Color:")), color],
        ]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Print"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var request = DirectPrintRequest(copies: min(999, max(1, copies.integerValue)), twoSided: sides.state == .on)
        if choices.indices.contains(papers.indexOfSelectedItem) { request.paperName = choices[papers.indexOfSelectedItem].paper.name }
        if caps.color { request.color = color.indexOfSelectedItem == 0 }
        return request
    }
}

/// The small window a direct print shows: what it's doing, then how it ended, with Cancel (then Close).
@MainActor
final class DirectPrintWindow: NSObject, NSWindowDelegate {
    private static var open: Set<DirectPrintWindow> = []

    private let window: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let button = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private var finished = false
    var onCancel: (() -> Void)?

    init(title: String) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled, .closable, .utilityWindow],
                         backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        button.target = self
        button.action = #selector(press)
        button.keyEquivalent = "\u{1b}"
        label.preferredMaxLayoutWidth = 320
        let row = NSStackView(views: [spinner, label])
        row.alignment = .top
        let stack = NSStackView(views: [row, button])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.open.insert(self)
    }

    func say(_ text: String) {
        guard !finished else { return }
        label.stringValue = text
        NSAccessibility.post(element: label, notification: .valueChanged)
    }

    /// The end: its words stay, Cancel becomes Close.
    func done(_ text: String) {
        finished = true
        label.stringValue = text
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        button.title = String(localized: "Close")
        NSAccessibility.post(element: label, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func press() {
        if finished {
            window.close()
        } else {
            label.stringValue = String(localized: "Cancelling…")
            onCancel?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { onCancel?() }
        Self.open.remove(self)
    }
}
