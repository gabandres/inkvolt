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

    /// Asks the options, then prints `document` on `printer` through `ipp`; problems in plain words, nothing sent before
    /// the printer was asked whether it can print.
    static func print(_ document: PDFDocument, name: String, on printer: PrinterModel, ipp: IppClient) async {
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
        let job = Task { await send(document, name: name, plan: plan, ipp: ipp, window: window) }
        window.onCancel = { job.cancel() }
    }

    /// The pages drawn and sent, then followed; what the window says at each step. Cancel before the printer has the job
    /// sends nothing; after, it asks the printer to cancel (and says when it may still print).
    private static func send(_ document: PDFDocument, name: String, plan: DirectPrintPlan, ipp: IppClient, window: DirectPrintWindow) async {
        let pages = document.pageCount
        window.say(String(localized: "Asking the printer whether it can print…"))
        if let problem = await printerProblem(ipp) {
            window.done(problem)
            return
        }
        window.say(String(localized: "Making the pages ready…"))
        let data = document.dataRepresentation()
        let drawn = Task.detached(priority: .userInitiated) { () throws -> [UInt8] in
            guard let data, let copy = PDFDocument(data: data) else { throw DirectPrintPages.NotDrawn() }
            return try DirectPrintPages.document(copy, plan: plan)
        }
        let raster: [UInt8]
        do {
            raster = try await withTaskCancellationHandler { try await drawn.value } onCancel: { drawn.cancel() }
        } catch is CancellationError {
            window.done(String(localized: "Cancelled. Nothing was sent."))
            return
        } catch {
            window.done(String(localized: "Its pages couldn't be made ready on this Mac. Nothing was sent."))
            return
        }
        if Task.isCancelled {
            window.done(String(localized: "Cancelled. Nothing was sent."))
            return
        }
        window.say(String(localized: "Sending the pages to the printer…"))
        let id: Int
        do {
            id = try await DirectJob.send(ipp, user: user, jobName: name, plan, document: raster).jobId
        } catch let e as DirectPrintError {
            window.done(e.message)
            return
        } catch {
            window.done(String(localized: "Cancelled. Nothing was sent."))
            return
        }
        guard id > 0 else {
            window.done(loc("Waiting its turn at the printer"))
            return
        }
        window.say(loc("Waiting its turn at the printer"))
        let shownPages = pages * plan.repeatCount
        let last = await DirectJob.watch(ipp, user: user, jobId: id, every: .seconds(2), quiet: .seconds(180)) { state in
            Task { @MainActor in window.say(DirectJob.describe(state, pages: shownPages)) }
        }
        if Task.isCancelled {
            do { try await DirectJob.stop(ipp, user: user, jobId: id) } catch let e as DirectPrintError {
                window.done(e.message)
                return
            } catch {}
            window.done(loc("Cancelled at the printer"))
            return
        }
        window.done(last.map { DirectJob.describe($0, pages: shownPages) } ?? loc("Waiting its turn at the printer"))
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
