import AppKit
import PDFKit
import PrintCore
import PrintMac
import UniformTypeIdentifiers

/// Two-sided printing by hand (roadmap 4.2; the Windows app's `HandDuplexPrinting` and `HandDuplexDialog`): on a printer whose
/// queue can't print both sides, the fronts go first, a prompt says how to put the stack back (face down or face up, the
/// printer's answer first, the person's kept per queue; an odd last sheet set aside), then the backs in the order that stack
/// feeds them. Batch Print and Print a PDF on Both Sides by Hand… both go through `BatchPrintRunner` with
/// `BatchPrintOptions.turnStack` set to `prompt`.
@MainActor
enum HandDuplexPrinting {
    /// `--report`'s answer to the prompt, in place of a person (nil: ask).
    static var answer: OutputFace?
    /// What the last prompt said, for `--report`.
    private(set) static var lastPrompt: String?
    /// The last booklet by hand's sides file (its sides, paper and the pages they're named by), for `--report`.
    private(set) static var lastSides: String?

    /// The face to start the prompt on: the one chosen last for `queue`, else the printer's, else face down (the usual).
    static func startingFace(_ queue: String, printer: OutputFace?) -> OutputFace {
        UserDefaults.standard.string(forKey: key(queue)).flatMap(OutputFace.init) ?? printer ?? .down
    }

    private static func key(_ queue: String) -> String { "handDuplexFace." + queue }

    /// The words for putting the stack back, for `reload`.
    static func instructions(_ file: String, _ reload: HandDuplexReload) -> String {
        var lines: [String] = []
        // The stack that goes back: the set-aside sheet isn't in it (Windows' HandDuplexDialog counts the same).
        let back = reload.sheets - (reload.setAside ? 1 : 0)
        let sheets = back == 1 ? String(localized: "the printed sheet") : String(localized: "the \(back) printed sheets")
        if reload.setAside, let page = reload.lastPage {
            // Where it ends up depends on how the finished stack comes out (face down or face up), so it's said as Windows says it.
            lines.append(String(localized: "1. Take the top sheet (page \(page)) off the output tray and set it aside: nothing prints on its back. Once the backs are done, put it last."))
        }
        let step = reload.setAside ? 2 : 1
        lines.append(reload.turnOver
            ? String(localized: "\(step). Take \(sheets) and turn the stack over like the page of a book, so the printed side faces down and the first page is on top.")
            : String(localized: "\(step). Take \(sheets) as they came out, printed side down, without turning the stack over."))
        lines.append(String(localized: "\(step + 1). Put the stack in the paper tray that way, the top edge going in first as before, then click Print the Backs."))
        if reload.blankBacks > 0 {
            lines.append(reload.blankBacks == 1 ? String(localized: "One sheet goes through again with nothing printed on its back (the end of a copy).")
                : String(localized: "\(reload.blankBacks) sheets go through again with nothing printed on their backs (the ends of copies)."))
        }
        return lines.joined(separator: "\n")
    }

    /// The prompt between the fronts and the backs of `file`: which way up the fronts came out (the stack's handling follows),
    /// Print the Backs or Stop. Answers the face, or nil to stop.
    static func prompt(_ file: String, _ plan: HandDuplexPlan, queue: String, printer: OutputFace?) -> OutputFace? {
        let start = startingFace(queue, printer: printer)
        lastPrompt = "\(file): \(instructions(file, plan.reload(answer ?? start)).replacingOccurrences(of: "\n", with: " | "))"
        if let answer { return answer }
        let alert = NSAlert()
        alert.messageText = String(localized: "The fronts of \(file) are printing. Put the stack back for the backs.")
        let faces = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        faces.addItems(withTitles: [String(localized: "The sheets came out printed side down"), String(localized: "The sheets came out printed side up")])
        faces.selectItem(at: start == .down ? 0 : 1)
        faces.setAccessibilityLabel(String(localized: "Which way up the sheets came out"))
        let changed = FaceChange { face in alert.informativeText = instructions(file, plan.reload(face)) }
        faces.target = changed
        faces.action = #selector(FaceChange.changed(_:))
        alert.accessoryView = faces
        alert.informativeText = instructions(file, plan.reload(start))
        alert.addButton(withTitle: String(localized: "Print the Backs"))
        alert.addButton(withTitle: String(localized: "Stop"))
        let printBacks = alert.runModal() == .alertFirstButtonReturn
        withExtendedLifetime(changed) {}
        guard printBacks else { return nil }
        let face: OutputFace = faces.indexOfSelectedItem == 1 ? .up : .down
        UserDefaults.standard.set(face.rawValue, forKey: key(queue))
        return face
    }

    /// The pop-up's target: the instructions follow the face chosen.
    @MainActor private final class FaceChange: NSObject {
        let body: (OutputFace) -> Void
        init(_ body: @escaping (OutputFace) -> Void) { self.body = body }
        @objc func changed(_ sender: NSPopUpButton) { body(sender.indexOfSelectedItem == 1 ? .up : .down) }
    }

    /// The runner's `turnStack` for a queue: the prompt on the main thread, the printer's face read once.
    static func turnStack(queue: String, printerFace: OutputFace?) -> @Sendable (String, HandDuplexPlan, BatchStop) async -> OutputFace? {
        { file, plan, _ in await MainActor.run { prompt(file, plan, queue: queue, printer: printerFace) } }
    }

    /// Which way up the printer delivers its sheets: cupsd's answer for a real queue; demo mode's laser delivers face down.
    static func printerFace(_ queue: String, app: AppModel) async -> OutputFace? {
        app.isDemo ? .down : await CupsBatchQueue.outputFace(queue)
    }

    /// Whether `printer`'s queue can't print both sides (two-sided by hand is offered then); nil when not known.
    static func queueTwoSided(_ printer: PrinterModel, app: AppModel) async -> Bool? {
        guard let name = printer.queueName else { return nil }
        let queue: (any BatchQueue)? = app.isDemo ? DemoBatchQueue.named(name) : CupsBatchQueue(queue: name)
        return try? await queue?.read()?.canTwoSided
    }

    /// Print a PDF on Both Sides by Hand…: the user picks the file and the copies; it goes straight to the queue as Batch
    /// Print sends a file (the queue's default paper, each page fitted), the fronts, the prompt, the backs.
    static func printPdf(on printer: PrinterModel, app: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a PDF to print on both sides by hand on \(printer.name).")
        panel.prompt = String(localized: "Print…")
        guard panel.runModal() == .OK, let url = panel.url, let copies = askCopies(url.lastPathComponent) else { return }
        Task { @MainActor in
            let summary = await run(url, copies: copies, on: printer, app: app)
            if let message = summary?.items.first?.message { Printing.alert(message) }
        }
    }

    private static func askCopies(_ file: String) -> Int? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Print \(file) on both sides by hand")
        alert.informativeText = String(localized: "The fronts print first. Then Inkvolt Print says how to put the stack back in the paper tray for the backs.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.integerValue = 1
        field.placeholderString = String(localized: "Copies")
        field.setAccessibilityLabel(String(localized: "Copies"))
        let label = NSTextField(labelWithString: String(localized: "Copies:"))
        let row = NSStackView(views: [label, field])
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = row
        alert.addButton(withTitle: String(localized: "Print"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return max(1, min(field.integerValue, BatchPrintLimits.maxCopies))
    }

    /// Print a PDF's booklet on a printer whose queue can't print both sides (roadmap 4.18 with 4.2; Windows'
    /// `SheetPrinting.PrintAsync` with a `HandDuplexPrinter`): the copies asked (`copies` given: not asked), the booklet's sides
    /// drawn by `SheetPrintView` into a PDF of their own at the queue's default paper as a duplexer would get them (two-sided
    /// on the long edge, so each turned back is drawn half-turned: `SheetPrint.halfTurned`), then sent by hand as `run` sends a
    /// file, the prompt naming a set-aside sheet by the document's page on it (`SheetPrint.sideNumbers`), never its side's
    /// number. The sides' file is deleted once the backs are sent or stopped. The summary, or nil when nothing was sent (said).
    static func printSheets(_ document: PDFDocument, choice: SheetChoice, name: String, on printer: PrinterModel, app: AppModel,
                            copies given: Int? = nil) async -> BatchPrintSummary? {
        guard let copies = given ?? askCopies(name) else { return nil }
        guard let queue = batchQueue(printer, app: app), let info = try? await queue.read() else {
            Printing.alert(String(localized: "This printer has no macOS print queue to print through."))
            return nil
        }
        let guess = SheetPrint.guessPaper(metric: Locale.current.measurementSystem == .metric)
        var points = (width: guess.width * SheetPrint.pointsPerUnit, height: guess.height * SheetPrint.pointsPerUnit)
        if let size = info.defaultPaper.flatMap(BatchQueueReading.size) { points = size }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Inkvolt Print by hand", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name + ".pdf")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let view = Printing.printSheets(document, choice: choice, name: name, on: nil, app: nil, save: url,
                                              paper: NSSize(width: points.width, height: points.height)),
              let sides = PDFDocument(url: url), sides.pageCount == view.plan.sheetCount else {
            Printing.alert(String(localized: "macOS couldn't prepare the pages for printing."))
            return nil
        }
        let names = SheetPrint.sideNumbers(view.plan, Array(1...max(1, document.pageCount)))
        lastSides = "\(sides.pageCount) sides at \(Int(points.width)) × \(Int(points.height)) pt, named by pages \(names)"
        return await run(url, copies: copies, on: printer, app: app, pageNumbers: names)
    }

    /// `printer`'s queue as Batch Print sends to it (demo mode's made-up ones), or nil when it has none.
    private static func batchQueue(_ printer: PrinterModel, app: AppModel) -> (any BatchQueue)? {
        printer.queueName.flatMap { (n: String) -> (any BatchQueue)? in app.isDemo ? DemoBatchQueue.named(n) : CupsBatchQueue(queue: n) }
    }

    /// `url` printed by hand on `printer`'s queue; the summary, or nil when there's no queue (said). `pageNumbers`: the
    /// document's page each of the file's pages shows, for the prompt (`BatchPrintLine.pageNumbers`).
    static func run(_ url: URL, copies: Int, on printer: PrinterModel, app: AppModel, pageNumbers: [Int]? = nil) async -> BatchPrintSummary? {
        guard let name = printer.queueName, let queue = batchQueue(printer, app: app) else {
            Printing.alert(String(localized: "This printer has no macOS print queue to print through."))
            return nil
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let documents = MacBatchDocuments()
        let path = url.path
        guard let info = try? await queue.read(), let measure = try? await BatchMeasurer.measure(path, offered: nil, documents, ask: nil) else {
            Printing.alert(String(localized: "This printer has no macOS print queue to print through."))
            return nil
        }
        let line = BatchPrintLine(path, BatchPrintSettings(copies: copies, twoSided: true), measure, info, byHand: true, pageNumbers: pageNumbers)
        if let problem = line.problem {
            Printing.alert(problem)
            return nil
        }
        var options = BatchPrintOptions()
        options.turnStack = turnStack(queue: name, printerFace: await printerFace(name, app: app))
        let chosen = options
        return await Task.detached { await BatchPrintRunner.run([line], queue, documents, options: chosen) }.value
    }
}
