import Foundation
import PDFKit
import PrintCore
import PrintMac

/// Wave 4's paper commands in the scan review, in demo mode (the Windows demo's `--turn-stack`, `--swap-backs`): `--turn-stack`
/// scans the USB demo laser's one-sided feeder as a turned stack (roadmap 4.1: three two-sided sheets of a report, pages 1
/// to 6, the second sheet fed upside down), the question answered yes, saves a searchable PDF and says in what order the
/// pages' own numbers read; then Backs in the Other Order and Undo.
extension Report {
    /// The demo's USB laser scanner (one-sided feeder), its review empty.
    static func demoLaserScanner(_ model: AppModel) async -> ScanModel? {
        // macOS's scanners are listed a moment after the printers.
        for _ in 0..<50 where !model.printers.contains(where: { $0.systemScanner?.id == Demo.laserScanner.id }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let printer = model.printers.first(where: { $0.systemScanner?.id == Demo.laserScanner.id }) else { return nil }
        let scan = printer.scan
        await scan.load()
        scan.clear()
        return scan.sources.contains(.adf) ? scan : nil
    }

    /// The report pages' numbers in the order a saved searchable PDF's text gives them ("page 3" in each page's heading);
    /// "?" for a page whose heading wasn't read.
    static func reportOrder(_ scan: ScanModel, _ name: String) async -> String {
        let url = AppModel.dataFolder.appendingPathComponent(name)
        let format = scan.format
        defer { scan.format = format }
        scan.format = .searchablePdf
        await scan.save(to: url, reveal: false)
        guard let pdf = PDFDocument(url: url) else { return "no PDF (\(scan.problem ?? scan.status))" }
        return (0..<pdf.pageCount).map { i -> String in
            let text = pdf.page(at: i)?.string ?? ""
            guard let r = text.range(of: #"page \d"#, options: .regularExpression) else { return "?" }
            return String(text[r].dropFirst(5))
        }.joined(separator: " ")
    }

    static func turnStackCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoLaserScanner(model) else {
            let listed = model.printers.map { "\($0.name) [\($0.systemScanner?.id ?? "-")]" }.joined(separator: ", ")
            return ["turn stack: no demo USB laser scanner with a feeder (\(listed))"]
        }
        let kept = (scan.turnStack, scan.skipBlank, scan.straighten, scan.splitAt)
        defer {
            (scan.turnStack, scan.skipBlank, scan.straighten, scan.splitAt) = kept
            scan.answerTurnStack = nil
        }
        scan.source = .adf
        scan.skipBlank = true
        scan.straighten = true
        scan.splitAt = .none
        scan.turnStack = true
        final class Asked { var fronts = 0 }
        let asked = Asked()
        scan.answerTurnStack = { fronts in
            asked.fronts = fronts
            return true
        }
        await scanAndWait(scan)
        var lines = ["turn stack: offered \(scan.offersTurnStack), asked after \(asked.fronts) fronts; \(scan.status)"]
        // Which page is which: Undo puts them back as the feeder sent them, fronts 1, 3, 5 then backs 6, 4, 2.
        let paired = scan.pages.pages.map(\.id)
        let undoName = scan.undoName ?? "none"
        scan.swapBacks()
        let swapped = scan.pages.pages.map(\.id)
        lines.append("  backs in the other order: \(scan.status) undo: \(scan.undoName ?? "none")")
        scan.undo()
        lines.append("  undone: as paired again \(scan.pages.pages.map(\.id) == paired), can swap \(scan.canSwapBacks)")
        scan.undo()
        let scanned = scan.pages.pages.map(\.id)
        let fed = [1, 3, 5, 6, 4, 2]
        var number: [String: Int] = [:]
        for (i, id) in scanned.enumerated() where i < fed.count { number[id] = fed[i] }
        func numbers(_ ids: [String]) -> String { ids.map { number[$0].map(String.init) ?? "?" }.joined(separator: " ") }
        lines.append("  in order (\(undoName)): \(numbers(paired)); backs the other way: \(numbers(swapped)); undone twice: \(numbers(scanned)), can swap \(scan.canSwapBacks)")
        // Again, saved as a searchable PDF: the pages' own headings read in order.
        scan.clear()
        await scanAndWait(scan)
        lines.append("  saved and read back: \(await reportOrder(scan, "turn-stack.pdf"))")
        return lines
    }
}
