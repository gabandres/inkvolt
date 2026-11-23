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

    /// `--join` (roadmap 4.8): the demo inkjet's glass holds a 14-inch plan's left half, then its right half (three inches on
    /// both); Join with the Next Page…'s search, the join, the page's size and Undo; then a page with itself refused.
    static func joinCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["join: no demo inkjet"] }
        let kept = (scan.cleanup, scan.source, scan.straighten, scan.upright)
        defer {
            (scan.cleanup, scan.source, scan.straighten, scan.upright) = kept
            Demo.scanSetup.hold(nil)
        }
        (scan.cleanup, scan.source, scan.straighten, scan.upright) = ([], .platen, false, false)
        for half in [DemoScan.leftHalf, DemoScan.rightHalf] {
            Demo.scanSetup.hold(half)
            await scanAndWait(scan)
        }
        guard scan.pages.pages.count == 2, let first = scan.pages.pages.first else { return ["join: \(scan.status) \(scan.problem ?? "")"] }
        guard let work = await scan.findJoin(first.id) else { return ["join: not found (\(scan.problem ?? "-"))"] }
        var lines = ["join: sure \(work.found.sure), score " + String(format: "%.3f", work.found.score) + ", next " + String(format: "%.3f", work.found.next)
                     + ", second half at \(work.placement.x), \(work.placement.y) (\(work.placement.side), turned \(work.placement.turned)); halves \(work.a.width) × \(work.a.height)"]
        let joined = await scan.join(work, at: work.placement)
        let page = scan.pages.pages.first
        let size = page.flatMap { scan.scannedJpeg($0.id) }.flatMap(ScanImaging.size)
        lines.append("  joined \(joined): \(scan.status) pages \(scan.pages.pages.count), the page \(size.map { "\($0.width) × \($0.height)" } ?? "-"); undo: \(scan.undoName ?? "none")")
        scan.undo()
        lines.append("  undone: \(scan.status) pages \(scan.pages.pages.count)")
        lines.append("  the last page with the next: \(scan.joinProblem(scan.pages.pages.last?.id ?? "") ?? "allowed")")
        scan.clear()
        return lines
    }

    /// `--name-from-text` (roadmap 4.11): the demo inkjet's glass holds a made-up invoice; scanned with a preset named
    /// "{text-date} {text-title} {text-number}" that stops on the review, the name the review shows (read by Vision from the
    /// page), then the name typed over it.
    static func nameFromTextCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["name from text: no demo inkjet"] }
        defer { Demo.scanSetup.hold(nil) }
        Demo.scanSetup.hold(DemoScan.invoice)
        var p = ScanPresets.builtIns()[0]
        p.id = "name-from-text-check"
        p.name = "Bills"
        (p.source, p.fileType, p.review, p.skipBlank) = (.glass, .pdf, true, false)
        p.fileName = "{text-date} {text-title} {text-number}"
        await scan.scan(with: p)
        for _ in 0..<150 where scan.isScanning || scan.pages.pages.contains(where: { !$0.analysed }) { try? await Task.sleep(for: .milliseconds(200)) }
        for _ in 0..<100 where scan.saveName.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        var lines = ["name from text: \(scan.status) \(scan.problem ?? "")",
                     "  shown in the review \(scan.showsSaveName), format \(scan.format), name \"\(scan.saveName)\""]
        scan.editSaveName("Maple invoice")
        await scan.fillSaveName() // a name typed stays
        lines.append("  typed over: \"\(scan.saveName)\" (edited \(scan.saveNameEdited))")
        scan.clear()
        lines.append("  after Clear: \"\(scan.saveName)\" shown \(scan.showsSaveName)")
        return lines
    }

    /// `--word-text` (roadmap 4.14): the demo glass's made-up invoice scanned with a Word preset and a text preset, each saved
    /// by itself into a folder in the container: the files, the document's paragraphs (Heading 1 first) and the text file's
    /// first lines.
    /// A camera scan (roadmap 4.12) with demo mode's document camera: Use a Camera's window, two Capture Page, Done, the
    /// pages in the review (found on the desk and warped flat, sized as their paper), then a preset's camera scan saved.
    static func cameraCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["camera: no demo inkjet"] }
        scan.clear()
        scan.scanWithCamera()
        var lines = ["camera:"]
        for _ in 0..<50 where CameraWindow.model?.canCapture != true { try? await Task.sleep(for: .milliseconds(100)) }
        guard let camera = CameraWindow.model else { return lines + ["  no camera window"] }
        lines.append("  window \(CameraWindow.size.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "not shown"), cameras \(camera.cameras.map(\.name)), " + camera.status)
        for _ in 0..<2 {
            await camera.capture()
            for _ in 0..<100 where !camera.canCapture { try? await Task.sleep(for: .milliseconds(100)) }
        }
        lines.append("  after two captures: " + camera.status)
        camera.done()
        for _ in 0..<150 where scan.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        let sizes = scan.pages.pages.compactMap { scan.scannedJpeg($0.id).flatMap(ScanImaging.size) }.map { "\($0.width) × \($0.height)" }
        lines.append("  review: \(scan.pages.pages.count) pages \(sizes), window closed \(CameraWindow.model == nil): " + scan.status)
        // A preset's camera scan: its settings, saved by itself (no review).
        let folder = AppModel.dataFolder.appendingPathComponent("camera-check", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var p = ScanPresets.builtIns()[0]
        p.id = "camera-check"
        p.name = "Camera check"
        (p.review, p.skipBlank, p.after) = (false, false, .none)
        model.setPresetFolder(p.id, folder)
        scan.clear()
        scan.scanWithCamera(p)
        for _ in 0..<50 where CameraWindow.model?.canCapture != true { try? await Task.sleep(for: .milliseconds(100)) }
        await CameraWindow.model?.capture()
        try? await Task.sleep(for: .milliseconds(500))
        CameraWindow.model?.done()
        for _ in 0..<150 where scan.isScanning || scan.isSaving || !scan.pages.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        let saved = ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".pdf") }.sorted()
        lines.append("  preset (\(ScanPresetText.summary(p))): saved \(saved.count) PDF(s): " + scan.status)
        try? FileManager.default.removeItem(at: folder)
        return lines
    }

    /// A phone scan (roadmap 4.6) with a phone on this Mac (`LoopbackPhone`, demo mode: 127.0.0.1 only, a certificate made
    /// for the run): Use Your Phone's window and code, the page, pairing, two photos of the demo document camera's desk, one
    /// that isn't a photo, a second device refused, Done, the pages in the review, and the port closed after.
    static func phoneCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["phone: no demo inkjet"] }
        scan.clear()
        scan.scanWithPhone()
        var lines = ["phone:"]
        for _ in 0..<100 where PhoneWindow.model == nil && scan.problem == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = PhoneWindow.model else { return lines + ["  no phone window: \(scan.problem ?? "")"] }
        let link = window.link
        let address = link.url.replacingOccurrences(of: link.session.token, with: "<code>")
        lines.append("  window \(PhoneWindow.size.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "not shown"), QR \(window.qr.map { "\(Int($0.size.width)) px" } ?? "none"), \(address), \(window.fingerprint): " + window.status)
        let phone = LoopbackPhone(fingerprint: link.fingerprint)
        defer { phone.finish() }
        do {
            let page = try await phone.get(link.url)
            lines.append("  page \(page.status) \(page.body.count) bytes, CSP \(page.header("Content-Security-Policy")?.hasPrefix("default-src 'none'") == true)")
            let pair = try await phone.post(link.url + "/pair")
            lines.append("  pair \(pair.status), cookie \(pair.header("Set-Cookie")?.contains("HttpOnly") == true ? "HttpOnly" : "none"): " + window.status)
            let photo = try ImageIOPhotoCodec().encodeJpeg(DemoCameras.frame(), dpi: 72)
            var sent: [Int] = []
            for _ in 0..<2 { sent.append(try await phone.post(link.url + "/photo", body: photo).status) }
            sent.append(try await phone.post(link.url + "/photo", body: Array("<html>not a photo</html>".utf8) + [UInt8](repeating: 32, count: 64)).status)
            let other = LoopbackPhone(fingerprint: link.fingerprint)
            sent.append(try await other.post(link.url + "/pair").status)
            other.finish()
            lines.append("  photos \(sent) (two photos, one not a photo, a second device): " + window.status)
            lines.append("  done \(try await phone.post(link.url + "/done").status)")
        } catch {
            lines.append("  the phone couldn't reach the page: \(error.localizedDescription)")
            window.done()
        }
        for _ in 0..<200 where scan.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<50 where PhoneWindow.model != nil { try? await Task.sleep(for: .milliseconds(100)) }
        let sizes = scan.pages.pages.compactMap { scan.scannedJpeg($0.id).flatMap(ScanImaging.size) }.map { "\($0.width) × \($0.height)" }
        lines.append("  review: \(scan.pages.pages.count) pages \(sizes), window closed \(PhoneWindow.model == nil): " + scan.status)
        try? await Task.sleep(for: .milliseconds(500))
        let after = LoopbackPhone(fingerprint: link.fingerprint)
        let closed = (try? await after.get(link.url)) == nil
        after.finish()
        lines.append("  port closed after: \(closed)")
        scan.clear() // no pages left for the quit's question
        return lines
    }

    static func wordTextCheck(_ model: AppModel) async -> [String] {
        guard let scan = await demoScanner(model) else { return ["word and text: no demo inkjet"] }
        defer { Demo.scanSetup.hold(nil) }
        Demo.scanSetup.hold(DemoScan.invoice)
        let folder = AppModel.dataFolder.appendingPathComponent("word-text-check", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = ["word and text:"]
        for type in [PresetFileType.word, .text] {
            var p = ScanPresets.builtIns()[0]
            p.id = type == .word ? "word-check" : "text-check"
            p.name = ScanPresetText.fileType(type)
            (p.source, p.fileType, p.review, p.skipBlank, p.after) = (.glass, type, false, false, .none)
            p.fileName = "{text-title}"
            model.setPresetFolder(p.id, folder)
            await scan.scan(with: p)
            for _ in 0..<150 where scan.isScanning || scan.isSaving || !scan.pages.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            lines.append("  \(p.name) (\(ScanPresetText.summary(p))): \(scan.status) \(scan.problem ?? "")")
        }
        let saved = ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".docx") || $0.hasSuffix(".txt") }
        for name in saved.sorted() {
            let bytes = [UInt8]((try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data())
            if name.hasSuffix(".docx") {
                let parts = (try? ZipArchive.entries(bytes)) ?? []
                let xml = parts.first { $0.name == "word/document.xml" }.map { String(decoding: $0.bytes, as: UTF8.self) } ?? ""
                let texts = xml.components(separatedBy: "<w:t xml:space=\"preserve\">").dropFirst().map { String($0.prefix { $0 != "<" }) }
                lines.append("  \(name): \(bytes.count) bytes, \(parts.count) parts, Heading 1 \(xml.contains("w:val=\"Heading1\"")), paragraphs \(texts.count): \(texts.prefix(4).joined(separator: " | "))")
            } else {
                let text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
                lines.append("  \(name): \(bytes.count) bytes, BOM \(bytes.starts(with: [0xEF, 0xBB, 0xBF])), CRLF \(text.contains("\r\n")): \(text.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " | "))")
            }
        }
        return lines
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
