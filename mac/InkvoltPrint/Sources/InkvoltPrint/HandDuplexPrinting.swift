import AppKit
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

    /// `url` printed by hand on `printer`'s queue; the summary, or nil when there's no queue (said).
    static func run(_ url: URL, copies: Int, on printer: PrinterModel, app: AppModel) async -> BatchPrintSummary? {
        let found = printer.queueName.flatMap { (n: String) -> (any BatchQueue)? in app.isDemo ? DemoBatchQueue.named(n) : CupsBatchQueue(queue: n) }
        guard let name = printer.queueName, let queue = found else {
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
        let line = BatchPrintLine(path, BatchPrintSettings(copies: copies, twoSided: true), measure, info, byHand: true)
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
