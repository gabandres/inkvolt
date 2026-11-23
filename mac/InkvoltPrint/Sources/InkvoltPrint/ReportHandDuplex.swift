import AppKit
import Foundation
import PDFKit
import PrintCore
import PrintMac

/// `--hand-duplex` (roadmap 4.2), in demo mode: two-sided by hand on the made-up USB laser (one-sided): offered there and not on
/// a two-sided queue; a 5-page PDF and 2 copies of a 3-page one through Batch Print's runner with the prompt answered face
/// down (the fronts, then the backs last sheet first, page 5's sheet set aside, a blank side between the copies); then Print
/// a PDF on Both Sides by Hand on the laser, answered face up.
extension Report {
    static func handDuplexCheck(_ model: AppModel) async -> [String] {
        var lines = ["hand duplex:"]
        let laserName = "Demo_USB_laser"
        // The queues are listed a moment after the app starts.
        for _ in 0..<50 where !model.printers.contains(where: { $0.queueName == laserName }) { try? await Task.sleep(for: .milliseconds(200)) }
        for printer in model.printers where printer.queueName != nil {
            let twoSided = await HandDuplexPrinting.queueTwoSided(printer, app: model)
            lines.append("  \(printer.queueName ?? "?"): two-sided \(twoSided.map(String.init) ?? "unknown"), by hand offered \(HandDuplex.offered(twoSided))")
        }
        guard let queue = DemoBatchQueue.named(laserName), let info = try? await queue.read() else { return lines + ["  no demo USB laser queue"] }
        let folder = AppModel.dataFolder.appendingPathComponent("hand-duplex-check", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let five = pdf(5, folder.appendingPathComponent("five pages.pdf")), let three = pdf(3, folder.appendingPathComponent("three pages.pdf")) else {
            return lines + ["  the PDFs couldn't be made"]
        }
        defer { HandDuplexPrinting.answer = nil }
        HandDuplexPrinting.answer = .down
        let documents = MacBatchDocuments()
        var batch: [BatchPrintLine] = []
        for (url, copies) in [(five, 1), (three, 2)] {
            guard let measure = try? await BatchMeasurer.measure(url.path, offered: nil, documents, ask: nil) else { continue }
            batch.append(BatchPrintLine(url.path, BatchPrintSettings(copies: copies, twoSided: true), measure, info, byHand: true))
        }
        lines.append("  lines: " + batch.map { "\($0.name) by hand \($0.byHand), \($0.description)" }.joined(separator: "; "))
        var options = BatchPrintOptions()
        options.turnStack = HandDuplexPrinting.turnStack(queue: laserName, printerFace: .down)
        let chosen = options, lines2 = batch
        let summary = await Task.detached { await BatchPrintRunner.run(lines2, queue, documents, options: chosen) }.value
        lines.append("  jobs: " + queue.sent.map { "\($0.name) \($0.pages) two-sided \($0.twoSided) copies \($0.copies)" }.joined(separator: "; "))
        for r in summary.items { lines.append("  \(r.name): \(r.state.rawValue): \(r.message) (\(r.sheetsSent) sheets)") }
        lines.append("  last prompt: \(HandDuplexPrinting.lastPrompt ?? "none")")

        HandDuplexPrinting.answer = .up
        if let laser = model.printers.first(where: { $0.queueName == laserName }),
           let single = await HandDuplexPrinting.run(three, copies: 1, on: laser, app: model) {
            lines.append("  Print a PDF by hand: \(single.items.first?.message ?? "?"); prompt: \(HandDuplexPrinting.lastPrompt ?? "none")")
        } else {
            lines.append("  Print a PDF by hand: no laser printer in the list")
        }

        // A booklet on the one-sided laser (roadmap 4.18 with 4.2): its sides drawn into a PDF, then by hand, answered face down.
        HandDuplexPrinting.answer = .down
        let booklet = SheetChoice(.booklet)
        if let laser = model.printers.first(where: { $0.queueName == laserName }), let setup = SheetPrint.setup(booklet),
           let ten = pdf(10, folder.appendingPathComponent("ten pages.pdf")), let document = PDFDocument(url: ten) {
            let twoSided = await HandDuplexPrinting.queueTwoSided(laser, app: model)
            let route = SheetPrint.route(setup, asked: false, printerTwoSided: twoSided ?? true, byHand: HandDuplex.offered(twoSided))
            let sent = await HandDuplexPrinting.printSheets(document, choice: booklet, name: "ten pages", on: laser, app: model, copies: 1)
            lines.append("  booklet on the laser: route \(route), \(HandDuplexPrinting.lastSides ?? "no sides"); \(sent?.items.first?.message ?? "not sent")")
            lines.append("  booklet prompt: \(HandDuplexPrinting.lastPrompt ?? "none")")
        } else {
            lines.append("  booklet on the laser: no laser printer in the list")
        }
        return lines
    }

    /// A Letter PDF of `pages` pages, each saying its number.
    private static func pdf(_ pages: Int, _ url: URL) -> URL? {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for n in 1...pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Page \(n)", attributes: [.font: NSFont.systemFont(ofSize: 48)]).draw(at: NSPoint(x: 72, y: 600))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
