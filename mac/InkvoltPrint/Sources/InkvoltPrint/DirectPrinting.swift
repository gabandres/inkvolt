import AppKit
import PDFKit
import PrintCore
import PrintMac
import Synchronization

/// Printing straight to the printer from Inkvolt Print (roadmap 2.1, Windows' PrintTargets and DirectPrinter): a network
/// printer whose jobs the router sends straight (no macOS queue, the person chose it, or macOS can't use its queue:
/// `PrinterModel.directRoute`) and that takes PWG raster, Apple raster or PCLm over IPP gets the pages from Inkvolt Print
/// itself. Every kind of print comes here with its pages as a PDF: Print a PDF (one page a sheet, or a layout laid out on the
/// printer's paper), Copy, a scan preset's print step, Print Photos, an ID card copy, the clipboard and a recent scan. Its
/// options are asked here (copies, paper unless the kind fixes it, both sides, color, from the printer's own attributes), the
/// printer asked whether it can print, the pages drawn and sent (`DirectPrinter`), and a small window follows the job until it
/// ends, with Cancel. Where the jobs go through the macOS queue, macOS's print panel prints as before.
@MainActor
enum DirectPrinting {
    /// The printer's IPP client when this print goes straight to it: the router decides now.
    static func route(_ printer: PrinterModel) async -> IppClient? { await printer.directRoute() }

    /// The account name the printer shows with the job.
    nonisolated static var user: String { NSUserName() }

    /// A print's pages as `DirectPrinter` draws them: a PDF file (opened with its password), how its pages go on the paper,
    /// and whether the file is a temporary one to delete once sent.
    struct Pages {
        var url: URL
        var password: String?
        var layout: DirectPrintPages.Layout
        var temporary: Bool
    }

    /// One print straight to the printer: the options asked from what the printer offers (`paper` fixed by the kind: its size
    /// in inches, then not asked; `bothSides` asked for by the kind: a booklet, a card), the plan made, the pages made for it
    /// (`make`, given the plan, so a layout lays out on the printer's paper; nil: said, nothing sent), then the window.
    static func print(name: String, on printer: PrinterModel, ipp: IppClient, paper fixed: (width: Double, height: Double)? = nil,
                      borderless: Bool = false, bothSides: Bool = false, make: @escaping (DirectPrintPlan) async -> Pages?) async {
        let caps: IppPrintCaps
        do {
            caps = try await printer.directCaps.cache(for: ipp).get()
        } catch {
            Printing.alert(DirectPrintError.noAnswerBeforeSending().message)
            return
        }
        guard var request = ask(caps, file: name, printer: printer.name, askPaper: fixed == nil, bothSides: bothSides) else { return }
        if let fixed {
            request.paperInches = fixed
            request.borderless = borderless
        }
        let plan: DirectPrintPlan
        switch DirectPrintPlan.choose(caps, request) {
        case .success(let p): plan = p
        case .failure(let problem):
            printer.directCaps.cache(for: ipp).forget()
            Printing.alert(problem.message)
            return
        }
        guard let pages = await make(plan) else { return }
        let window = DirectPrintWindow(title: String(localized: "Printing \(name) on \(printer.name)"))
        let job = Task {
            let said = await run(pages.url, password: pages.password, name: name, plan: plan, ipp: ipp, layout: pages.layout) { window.say($0) }
            if pages.temporary { try? FileManager.default.removeItem(at: pages.url) }
            window.done(said)
        }
        window.onCancel = { job.cancel() }
    }

    /// Print a PDF, one page a sheet, each fitted inside the printer's margins.
    static func printFile(_ url: URL, password: String?, name: String, on printer: PrinterModel, ipp: IppClient) async {
        await print(name: name, on: printer, ipp: ipp) { _ in Pages(url: url, password: password, layout: .fitted(.fitToPaper), temporary: false) }
    }

    /// A document the app made or opened (Copy, a preset's print step, Print Photos' sheets, an ID card, the clipboard, a
    /// recent scan): written to a temporary file, then printed as `layout` says (`paper`: the size it was laid out for).
    static func printDocument(_ document: PDFDocument, name: String, on printer: PrinterModel, ipp: IppClient, layout: DirectPrintPages.Layout,
                              paper: (width: Double, height: Double)? = nil, borderless: Bool = false, bothSides: Bool = false) async {
        guard let data = document.dataRepresentation() else {
            Printing.alert(String(localized: "Its pages couldn't be made ready on this Mac. Nothing was sent."))
            return
        }
        await printData(data, name: name, on: printer, ipp: ipp, layout: layout, paper: paper, borderless: borderless, bothSides: bothSides)
    }

    static func printData(_ pdf: Data, name: String, on printer: PrinterModel, ipp: IppClient, layout: DirectPrintPages.Layout,
                          paper: (width: Double, height: Double)? = nil, borderless: Bool = false, bothSides: Bool = false) async {
        await print(name: name, on: printer, ipp: ipp, paper: paper, borderless: borderless, bothSides: bothSides) { _ in
            let url = temporaryPdf()
            guard (try? pdf.write(to: url)) != nil else {
                Printing.alert(String(localized: "Its pages couldn't be made ready on this Mac. Nothing was sent."))
                return nil
            }
            return Pages(url: url, password: nil, layout: layout, temporary: true)
        }
    }

    /// Print a PDF's layouts (several per sheet, a booklet, a poster; roadmap 4.18) straight to the printer: laid out by
    /// `SheetPrintView` on the paper the plan chose, into a PDF of its sheets, each then printed on the whole paper. A booklet
    /// asks the printer for both sides (one that prints one side goes by hand before this: `Printing.printPdf`).
    static func printSheets(_ document: PDFDocument, choice: SheetChoice, name: String, on printer: PrinterModel, ipp: IppClient,
                            sizes: [(Double, Double)]) async {
        guard let setup = SheetPrint.setup(choice) else { return }
        await print(name: name, on: printer, ipp: ipp, bothSides: SheetPrint.twoSided(setup, asked: false)) { plan in
            let url = temporaryPdf()
            let paper = NSSize(width: plan.paper.widthInches * 72, height: plan.paper.heightInches * 72)
            guard let view = Printing.printSheets(document, choice: choice, name: name, on: nil, app: nil, save: url, paper: paper, sizes: sizes),
                  let sheets = PDFDocument(url: url), sheets.pageCount == view.plan.sheetCount else {
                try? FileManager.default.removeItem(at: url)
                Printing.alert(String(localized: "Its pages couldn't be made ready on this Mac. Nothing was sent."))
                return nil
            }
            return Pages(url: url, password: nil, layout: .sheet, temporary: true)
        }
    }

    private static func temporaryPdf() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-direct-\(UUID().uuidString).pdf")
    }

    /// The PDF at `url` drawn into a job file and sent, then followed (`DirectPrinter.print`); `say` tells each step, and the
    /// end is returned, in words true to what happened. Cancel before the printer has the job sends nothing; the sending
    /// itself is never cut (Windows sends with no cancel: a job cut halfway may print anyway); once the printer has given the
    /// job an id, Cancel is Cancel-Job (and says when the printer didn't take it). `sent`: the printer has the job (its id,
    /// 0 when it gave none).
    static func run(_ url: URL, password: String?, name: String, plan: DirectPrintPlan, ipp: IppClient, layout: DirectPrintPages.Layout = .fitted(.fitToPaper),
                    sent: (@Sendable (Int) -> Void)? = nil, say: @escaping @MainActor @Sendable (String) -> Void) async -> String {
        say(String(localized: "Asking the printer whether it can print…"))
        if let problem = await printerProblem(ipp) { return problem }
        let stop = BatchStop()
        let given = Atomic(-1) // the job's id once the printer has it
        do {
            let outcome = try await withTaskCancellationHandler {
                try await DirectPrinter.print(ipp, user: user, jobName: name, plan: plan, pdf: url, password: password, layout: layout, stop: stop,
                                              progress: { text in Task { @MainActor in say(text) } },
                                              onSent: { id in
                                                  given.store(id, ordering: .releasing)
                                                  sent?(id)
                                              })
            } onCancel: {
                stop.stop()
            }
            if outcome.jobId == 0 && (stop.isStopped || Task.isCancelled) {
                return String(localized: "The printer already has the job and gave it no number to cancel it by. Cancel it on the printer's control panel.")
            }
            return outcome.words
        } catch is CancellationError {
            return given.load(ordering: .acquiring) > 0 ? loc("Cancelled at the printer") : String(localized: "Cancelled. Nothing was sent.")
        } catch let e as DirectPrintError {
            return e.message
        } catch {
            return String(localized: "Its pages couldn't be made ready on this Mac. Nothing was sent.")
        }
    }

    /// Why nothing should go to the printer now (stopped, an error, not taking jobs), or nil.
    static func printerProblem(_ ipp: IppClient) async -> String? {
        do {
            return DirectJob.printerProblem(try await ipp.printerAttributes(DirectJob.stateAttributes))
        } catch {
            return DirectPrintError.noAnswerBeforeSending().message
        }
    }

    /// The options, from what the printer offers: copies, paper (`askPaper`), both sides (asked for by the kind: `bothSides`,
    /// then ticked and fixed), color. Nil when cancelled.
    private static func ask(_ caps: IppPrintCaps, file: String, printer: String, askPaper: Bool, bothSides: Bool) -> DirectPrintRequest? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Print \(file) straight to \(printer)?")
        alert.informativeText = String(localized: "Inkvolt Print draws the pages and sends them to the printer itself, not through a macOS queue.")
        let copies = NSTextField(string: "1")
        copies.formatter = { () -> NumberFormatter in
            let f = NumberFormatter()
            (f.minimum, f.maximum, f.allowsFloats) = (1, 999, false)
            return f
        }()
        copies.frame.size.width = 60
        copies.setAccessibilityLabel(String(localized: "Copies"))
        let papers = NSPopUpButton()
        let choices = caps.paperChoices()
        papers.addItems(withTitles: choices.map(\.label))
        if let d = caps.defaultPaper, let i = choices.firstIndex(where: { $0.paper.name == d.name }) { papers.selectItem(at: i) }
        papers.setAccessibilityLabel(String(localized: "Paper"))
        let sides = NSButton(checkboxWithTitle: String(localized: "Both sides"), target: nil, action: nil)
        sides.isEnabled = caps.twoSided && !bothSides
        if bothSides { sides.state = .on }
        let color = NSPopUpButton()
        color.addItems(withTitles: [String(localized: "Color"), String(localized: "Black and white")])
        color.selectItem(at: caps.color && caps.colorByDefault ? 0 : 1)
        color.isEnabled = caps.color
        color.setAccessibilityLabel(String(localized: "Color"))
        var rows: [[NSView]] = [[NSTextField(labelWithString: String(localized: "Copies:")), copies]]
        if askPaper { rows.append([NSTextField(labelWithString: String(localized: "Paper:")), papers]) }
        rows.append([NSTextField(labelWithString: ""), sides])
        rows.append([NSTextField(labelWithString: String(localized: "Color:")), color])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(rows.count) * 30)
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Print"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var request = DirectPrintRequest(copies: min(999, max(1, copies.integerValue)), twoSided: bothSides || sides.state == .on)
        if askPaper, choices.indices.contains(papers.indexOfSelectedItem) { request.paperName = choices[papers.indexOfSelectedItem].paper.name }
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
