import AppKit
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
        let kept = (scan.turnStack, scan.skipBlank, scan.straighten, scan.splitAt, scan.upright)
        defer {
            (scan.turnStack, scan.skipBlank, scan.straighten, scan.splitAt, scan.upright) = kept
            scan.answerTurnStack = nil
        }
        scan.source = .adf
        scan.skipBlank = true
        scan.straighten = true
        scan.splitAt = .none
        scan.turnStack = true
        scan.upright = false // the order's own steps of Undo only (`uprightCheck` turns the upside-down sheet)
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

    /// `--smaller-file` (roadmap 4.4): the USB demo laser's feeder scanned with a scan preset as it is and with Smaller file
    /// (black and white), each saved as a PDF in the container: its size, whether its pages are CCITT G4 or JPEG, and how much
    /// ink PDFKit (Preview's engine) draws on its first page, so macOS is seen to read the 1-bit pages.
    static func smallerFileCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoLaserScanner(model) else { return ["smaller file: no demo USB laser scanner with a feeder"] }
        let kept = (scan.turnStack, scan.format)
        defer { (scan.turnStack, scan.format) = kept }
        scan.turnStack = false
        var lines = ["smaller file:"]
        for smaller in [false, true] {
            var p = ScanPresets.builtIns()[0]
            p.id = "smaller-file-check"
            p.name = smaller ? "Smaller file" : "As scanned"
            (p.source, p.fileType, p.review, p.skipBlank, p.color, p.smallerFile) = (.feeder, .pdf, true, false, true, smaller)
            await scan.scan(with: p)
            for _ in 0..<150 where scan.isScanning || scan.pages.pages.contains(where: { !$0.analysed }) { try? await Task.sleep(for: .milliseconds(200)) }
            let url = AppModel.dataFolder.appendingPathComponent(smaller ? "smaller-file.pdf" : "smaller-file-off.pdf")
            await scan.save(to: url, reveal: false)
            let data = (try? Data(contentsOf: url)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let pdf = PDFDocument(url: url)
            let ink = pdf?.page(at: 0).map { darkPixels($0.thumbnail(of: CGSize(width: 255, height: 330), for: .mediaBox)) } ?? -1
            lines.append("  \(p.name) (\(ScanPresetText.summary(p))): \(scan.status) \(scan.problem ?? "")")
            lines.append("    \(data.count) bytes, pages \(pdf?.pageCount ?? 0), CCITT G4 \(text.contains("/CCITTFaxDecode")), JPEG \(text.contains("/DCTDecode")), "
                + "dark pixels PDFKit draws on page 1: \(ink)")
        }
        scan.clear()
        return lines
    }

    /// `--cleanup-marks` (roadmap 4.7): the demo inkjet's glass holds the punched order form; scanned with Drop a color (red)
    /// and Remove punch holes, the page's red and the holes' dark pixels before and after, the note and Undo; then blue picked
    /// in the Clean up view's way (`applyClean` with a color) on the same page.
    static func cleanupMarksCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["cleanup marks: no demo inkjet"] }
        let kept = (scan.cleanup, scan.dropColor, scan.source, scan.format)
        defer { (scan.cleanup, scan.dropColor, scan.source, scan.format) = kept }
        scan.source = .platen
        scan.format = .pdf
        scan.cleanup = [.dropColor, .punchHoles]
        scan.dropColor = .red
        await scanAndWait(scan)
        guard let page = scan.pages.pages.first, let before = scan.scannedJpeg(page.id), let after = await scan.savedJpeg(page.id) else {
            return ["cleanup marks: no page (\(scan.status) \(scan.problem ?? ""))"]
        }
        var lines = ["cleanup marks: \(scan.status)", "  note: \(page.note); undo: \(scan.undoName ?? "none")"]
        lines.append("  red pixels \(marks(before).red) → \(marks(after).red); dark pixels in the left inch \(marks(before).holes) → \(marks(after).holes)")
        await scan.applyClean(page.id, [.dropColor], drop: .blue)
        let blue = scan.pages.page(page.id)
        lines.append("  blue instead: note \(blue?.note ?? "-"), color \(blue?.edits.drop?.hex ?? "-"); undo: \(scan.undoName ?? "none")")
        scan.clear()
        return lines
    }

    /// A page's strongly red pixels, and its dark pixels in the left inch (where the form's holes are), on a copy 1/4 the size.
    private static func marks(_ jpeg: [UInt8]) -> (red: Int, holes: Int) {
        guard let image = NSImage(data: Data(jpeg))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (-1, -1) }
        let (w, h) = (image.width / 4, image.height / 4)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return (-1, -1) }
        var (red, holes) = (0, 0)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = (Int(px[(y * w + x) * 4]), Int(px[(y * w + x) * 4 + 1]), Int(px[(y * w + x) * 4 + 2]))
                if r > g + 60 && r > b + 60 { red += 1 }
                if x < w * 2 / 17 && r < 100 && g < 100 && b < 100 { holes += 1 } // the left inch of 8.5
            }
        }
        return (red, holes)
    }

    /// Pixels darker than mid-grey in `image` drawn grey (-1 when it can't be drawn).
    private static func darkPixels(_ image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let (w, h) = (cg.width, cg.height)
        var px = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = px.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? px.filter { $0 < 128 }.count : -1
    }

    /// `--upright` (roadmap 4.3): the same stack with Turn pages upright on: the sheet fed upside down (pages 3 and 4) is
    /// turned, nothing else; one step of Undo turns them back as scanned; then a scan with it off turns none.
    static func uprightCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoLaserScanner(model) else { return ["upright: no demo USB laser scanner with a feeder"] }
        let kept = (scan.turnStack, scan.upright, scan.skipBlank, scan.straighten, scan.splitAt)
        defer {
            (scan.turnStack, scan.upright, scan.skipBlank, scan.straighten, scan.splitAt) = kept
            scan.answerTurnStack = nil
        }
        scan.source = .adf
        scan.skipBlank = true
        scan.straighten = true
        scan.splitAt = .none
        scan.turnStack = true
        scan.answerTurnStack = { _ in true }
        func turns() -> String { scan.pages.pages.map { "\($0.edits.quarterTurns)" }.joined(separator: " ") }
        func notes() -> String { scan.pages.pages.map { $0.note.isEmpty ? "-" : $0.note }.joined(separator: ", ") }
        scan.upright = true
        await scanAndWait(scan)
        var lines = ["upright: \(scan.status)", "  turns by page: \(turns()); notes: \(notes()); undo: \(scan.undoName ?? "none")"]
        scan.undo()
        lines.append("  undone: \(scan.status) turns \(turns()); undo next: \(scan.undoName ?? "none")")
        scan.clear()
        scan.upright = false
        await scanAndWait(scan)
        lines.append("  off: turns \(turns())")
        scan.clear()
        return lines
    }
}
