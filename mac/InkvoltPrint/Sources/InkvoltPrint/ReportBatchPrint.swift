import AppKit
import PrintCore
import PrintMac

/// `--report … --batch-print` (roadmap 2.4). With `--demo`: made-up files written from their formats' specs
/// (`BatchPrintSamples`: three invoices, a photo, a floor plan, a two-page TIFF, a PDF whose password is "demo") go through
/// the Batch Print window and the real engines (PDFKit, Image I/O) to the made-up queues, where nothing prints: the
/// estimate, the password asked (a wrong one, then the right one), Print with its question over 100 sheets, a printer that is
/// off stopping the batch, two-sided on the USB laser that has none, Save List… and Open List…, Export Results…' CSV, a
/// watched folder handled once, and `print` run as Terminal runs it, with the Pro gate on and off. Without `--demo`,
/// `--batch-print queue <name>` sends the same files to that macOS queue **held**, reads back what cupsd took, and cancels
/// every job (`CupsBatchQueue.holdOnly`): use a test queue that leads to no printer.
extension Report {
    static func batchPrintCheck(_ model: AppModel, queue name: String?) async -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Inkvolt Print batch check", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples: [(String, [UInt8])] = [
            ("Invoice 1 of 3.pdf", BatchPrintSamples.pdf(2, "Invoice 1")), ("Invoice 2 of 3.pdf", BatchPrintSamples.pdf(4, "Invoice 2")),
            ("Invoice 3 of 3.pdf", BatchPrintSamples.pdf(1, "Invoice 3")), ("Team photo.jpg", BatchPrintSamples.jpeg(1600, 1200)),
            ("Floor plan.png", BatchPrintSamples.png(800, 600)), ("Signed contract.tif", BatchPrintSamples.tiff(2, 400, 500)),
            ("Payroll, password demo.pdf", BatchPrintSamples.pdf(3, "Payroll", password: "demo")),
        ]
        let files = folder.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for (file, bytes) in samples { try? Data(bytes).write(to: files.appendingPathComponent(file)) }
        if let name, !model.isDemo { return await heldCheck(name, files) }
        guard model.isDemo else { return ["batch-print: demo mode only, or `queue <name>` for a test queue"] }
        return await demoCheck(model, folder, files)
    }

    private static func rowLines(_ m: BatchPrintModel) -> [String] {
        m.rows.enumerated().map { i, r in
            "  \(i + 1). \(r.name): \(r.pagesText.isEmpty ? "-" : r.pagesText), \(r.sheetsText.isEmpty ? "-" : r.sheetsText); \(r.stateText)"
        }
    }

    private static func demoCheck(_ model: AppModel, _ folder: URL, _ files: URL) async -> [String] {
        var lines: [String] = []
        let m = BatchPrintWindow.show(model)
        m.sayYes = true
        var asked: [String] = []
        m.answer = { file, wrong in
            asked.append("\(file)\(wrong ? " (wrong)" : "")")
            return asked.count == 1 ? "not it" : "demo"
        }
        m.queueId = "Office_color_MFP"
        await m.readInfo()
        await m.add([files])
        lines.append("batch-print: window \(BatchPrintWindow.size.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "not shown"); printers: "
            + m.choices.map(\.name).joined(separator: ", "))
        lines.append("batch-print: \(m.info?.name ?? "?") takes \(m.papers.map(\.label).joined(separator: ", ")), two-sided \(m.canTwoSided)")
        lines.append("batch-print: password asked for \(asked.joined(separator: ", ")); estimate: \(m.summary)")
        lines += rowLines(m)

        // Clear while it's looking, then a list at once (as Open List does): the new rows are looked at, none left waiting.
        let looking = Task { await m.checkAgain() }
        for _ in 0..<2000 where !(m.isEstimating && m.progress != nil) { try? await Task.sleep(for: .milliseconds(1)) }
        let paths = m.rows.map(\.path)
        m.clear()
        m.rows = paths.map { BatchRow($0, BatchPrintSettings(copies: 1, range: nil, twoSided: false, paper: nil)) }
        await m.estimate()
        await looking.value
        lines.append("batch-print: cleared while looking, the files put back at once: \(m.rows.filter { $0.measure != nil }.count) of \(m.rows.count) looked at, "
            + "still looking: \(m.isEstimating)")

        // Print, 99 copies of the first file making it more than 100 sheets: asked first. Clicked twice (a double click):
        // the second finds the batch under way, so nothing is sent twice.
        await m.estimate() // whatever the check above left
        m.rows.first?.copies = 99
        if let first = m.rows.first { m.changed(first) }
        let waiting = m.stillToSend.filter { $0.line?.problem == nil }.count, askedBefore = m.questions.count
        let click = Task { await m.printAll() }, again = Task { await m.printAll() }
        await click.value
        await again.value
        let demoQueue = m.lastQueue as? DemoBatchQueue
        lines.append("batch-print: asked \"\(m.questions.last ?? "nothing")\"; \(m.message ?? "?") The made-up queue drew \(demoQueue?.sent.count ?? 0) jobs "
            + "for \(waiting) files; Print clicked twice, batches started: \(m.questions.count - askedBefore).")
        lines += rowLines(m)
        lines.append("batch-print: print again sends nothing twice: \(m.canPrint ? "Print still offered" : "Print not offered")")
        let csv = m.resultsCsv() ?? ""
        lines.append("batch-print: Export Results… CSV \(csv.split(separator: "\r\n").count) lines; first row: \(csv.split(separator: "\r\n").dropFirst().first ?? "")")

        // A printer that is off: the batch stops before the first file and says where.
        await m.startOver()
        m.queueId = "Front_desk_demo_mac"
        await m.readInfo()
        await m.printAll()
        lines.append("batch-print: to the front desk (off): \(m.message ?? "?")")

        // Two-sided on the USB laser that has none: each file says so, nothing quietly changes.
        await m.startOver()
        m.queueId = "Demo_USB_laser"
        await m.readInfo()
        m.selection = m.rows.last?.id
        m.rows.last?.twoSided = true
        if let last = m.rows.last { m.changed(last) }
        lines.append("batch-print: two-sided on the USB laser: \(m.rows.last?.stateText ?? "?")")

        // Stop: the batch stops between files.
        m.queueId = "Office_color_MFP"
        await m.readInfo()
        m.rows.last?.twoSided = false
        for row in m.rows { m.changed(row) }
        let printing = Task { await m.printAll() }
        for _ in 0..<200 where m.progress == nil || !m.isSending { try? await Task.sleep(for: .milliseconds(5)) }
        m.stop()
        await printing.value
        lines.append("batch-print: Stop: \(m.message ?? "?")")

        // Save List… and Open List…: the list read back, no password in it.
        let list = folder.appendingPathComponent("Monthly" + BatchPrintList.fileExtension)
        let saved = m.saveList(to: list)
        let text = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        let back = (try? BatchPrintList.load(list.path, allowNetwork: false))?.count ?? -1
        lines.append("batch-print: Save List… \(saved ? "saved" : "not saved"), \(back) lines read back, password in it: \(text.lowercased().contains("password\"") || text.contains("demo\"") ? "yes" : "no")")
        await m.openList(list)
        lines.append("batch-print: Open List… \(m.rows.count) files; \(m.summary)")

        // A watched folder, handled once: done, failed (the locked file: nobody is asked), the log.
        let watched = folder.appendingPathComponent("watched", isDirectory: true)
        try? FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        for file in ["Invoice 3 of 3.pdf", "Floor plan.png", "Payroll, password demo.pdf"] {
            try? FileManager.default.copyItem(at: folder.appendingPathComponent("files/" + file), to: watched.appendingPathComponent(file))
        }
        await m.watch(watched, once: true)
        let done = (try? FileManager.default.contentsOfDirectory(atPath: watched.appendingPathComponent("done").path))?.sorted() ?? []
        let failed = (try? FileManager.default.contentsOfDirectory(atPath: watched.appendingPathComponent("failed").path))?.sorted() ?? []
        let log = (try? String(contentsOf: watched.appendingPathComponent(BatchPrintFolder.logName), encoding: .utf8)) ?? ""
        lines.append("batch-print: watched folder: \(m.message ?? "?") done: \(done.joined(separator: ", ")); failed: \(failed.joined(separator: ", ")); "
            + "log \(log.split(separator: "\n").count) lines")
        lines += m.watchLines.reversed().map { "  " + $0 }

        // `print` as Terminal runs it.
        lines += await commandCheck(list.path, folder)
        return lines
    }

    private static func commandCheck(_ list: String, _ folder: URL) async -> [String] {
        var lines: [String] = []
        let host = MacPrintHost(demo: true)
        func run(_ args: [String], password: String? = nil) async -> String {
            let said = Said()
            let code = await BatchPrintCommandLine.run(args, host, environment: { $0 == BatchPrintCommandLine.passwordVariable ? password : nil },
                                                       output: { said.add("  > " + $0) }, error: { said.add("  ! " + $0) })
            return "exit \(code)\n" + said.text
        }
        lines.append("batch-print: print --list … --printer \"Office color MFP\" (no password given): " + (await run(["print", "--list", list, "--printer", "Office color MFP"])))
        lines.append("batch-print: the same with \(BatchPrintCommandLine.passwordVariable): "
            + (await run(["print", "--list", list, "--printer", "Office color MFP", "--quiet"], password: "demo")))
        lines.append("batch-print: --dry-run --max-sheets 5: " + (await run(["print", "--list", list, "--printer", "Office color MFP", "--dry-run", "--max-sheets", "5"])))
        lines.append("batch-print: a wrong option: " + (await run(["print", "--list", list, "--printer", "Office color MFP", "--copies", "2"])))
        let report = folder.appendingPathComponent("results.csv").path
        let files = folder.appendingPathComponent("files").path
        lines.append("batch-print: files given, with --report: "
            + (await run(["print", files, "--printer", "Demo USB laser", "--two-sided", "--report", report, "--quiet"])))
        let csvLines = ((try? String(contentsOfFile: report, encoding: .utf8)) ?? "").split(separator: "\r\n").count
        lines.append("batch-print: the report has \(csvLines) lines")
        Pro.enforced = true
        lines.append("batch-print: with the Pro gate on: " + (await run(["print", "--list", list, "--printer", "Office color MFP"])))
        lines.append("batch-print: Export Results… with the gate on: \(BatchPrintCsv.export([]) == nil ? "refused" : "allowed")")
        Pro.enforced = false
        return lines
    }

    /// This Mac's queue `name`, every job held, read back and cancelled.
    private static func heldCheck(_ name: String, _ files: URL) async -> [String] {
        var lines: [String] = []
        let queue = CupsBatchQueue(queue: name, holdOnly: true)
        guard let info = try? await queue.read() else { return ["batch-print queue: macOS has no queue \(name)"] }
        lines.append("batch-print queue: \(info.name): \(info.papers.count) papers (\(info.papers.prefix(6).map { "\($0.label) \($0.key)" }.joined(separator: ", "))…), "
            + "default \(info.defaultPaper ?? "none"), two-sided \(info.canTwoSided)")
        let problem = (try? await queue.problem()) ?? nil
        lines.append("batch-print queue: problem now: \(problem ?? "none")")
        let documents = MacBatchDocuments()
        let paths = BatchPrintFiles.listFolder(files.path, recursive: false)
        let letter = info.papers.first { $0.key.hasPrefix("na_letter") || $0.key == "Letter" }?.key
        var batch: [BatchPrintLine] = []
        for (i, path) in paths.enumerated() {
            let measure = (try? await BatchMeasurer.measure(path, offered: "demo", documents, ask: nil)) ?? BatchMeasure(.problem, problem: "stopped")
            let settings = BatchPrintSettings(copies: i == 0 ? 2 : 1, range: nil, twoSided: info.canTwoSided && i % 2 == 0, paper: i == 1 ? letter : nil)
            batch.append(BatchPrintLine(path, settings, measure, info))
        }
        let summary = await BatchPrintRunner.run(batch, queue, documents)
        for r in summary.items {
            lines.append("  \(r.index + 1). \(r.name): \(r.state.rawValue): \(r.message) (copies \(r.copies), two-sided \(r.twoSided), paper \(r.paper ?? "default"))")
        }
        lines.append("batch-print queue: \(summary.text)")
        let ids = queue.heldJobs
        try? await Task.sleep(for: .seconds(1))
        let left = (await LibCups().jobs(name) ?? []).filter { ids.contains($0.id) }
        lines.append("batch-print queue: \(ids.count) jobs held and read back; \(left.isEmpty ? "all cancelled, none left in the queue" : "\(left.count) still there")")
        return lines
    }

    /// What a command said, line by line.
    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }
}
