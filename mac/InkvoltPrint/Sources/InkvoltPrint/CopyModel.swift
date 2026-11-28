import AppKit
import Observation
import PrintCore
import PrintMac

/// Copy (the Windows app's Copy tab, page copy; `CopyViewModel`): scan, then print what was scanned in one step, where the
/// printer's jobs go (its macOS queue, or straight to it: `PrinterModel.batchQueue`, decided afresh for each copy), with no
/// print panel. Copies, color or grey, glass or feeder, two-sided when the printer can (by hand when it can't: roadmap 4.2),
/// actual size or fit to the paper, 1, 2 or 4 pages per sheet (`CopyLayout.nUp`), collated or not (`CopyLayout.order`: the
/// app repeats the sheets, so it doesn't rely on the queue collating). Preview before printing scans, shows each sheet as
/// it will print and waits for Print; a copy that didn't print keeps its scans for Print Again. Says why it can't copy
/// (connecting, no scanner, nowhere to print: `CopyRoute.blocker`). The ID card copy is its own sheet (`IdCardCopyModel`).
@MainActor @Observable
final class CopyModel {
    /// A sheet in the preview, in 96ths of an inch: the paper and the pages on it (`image` nil: a page that couldn't be shown).
    struct PreviewSheet: Identifiable {
        struct Page: Identifiable {
            let id: Int
            let image: NSImage?
            let at: Placement
            /// Turned a quarter clockwise to the paper's orientation, as it prints (`PageFit.place`).
            let rotated: Bool
        }

        let id: Int
        let paperWidth: Double, paperHeight: Double
        let pages: [Page]
    }

    /// Scan resolution: enough for text, the size Windows' Copy scans at.
    static let copyDpi = 300

    /// Paper for the preview: Letter or A4 by region, in 96ths of an inch (the printer decides the real paper when printing).
    static var previewPaper: (width: Double, height: Double) { Locale.current.measurementSystem == .metric ? (793.7, 1122.5) : (816, 1056) }

    // The options, as Windows' Copy tab has them.
    var copies = 1 {
        didSet { if CopyRoute.clampCopies(copies) != copies { copies = CopyRoute.clampCopies(copies) } }
    }
    /// Scan in color. Off by default: the printers Inkvolt Print knows print in black only.
    var isColor = false
    private(set) var sources: [ScanSource] = []
    var source = ScanSource.platen
    var twoSided = false
    /// Enlarge or shrink each page to fill the paper, instead of actual size.
    var fitToPaper = false { didSet { showPreviewed() } }
    var pagesPerSheet = 1 { didSet { showPreviewed() } }
    var collate = true
    var previewFirst = false

    /// Where the jobs go prints both sides; else two-sided by hand is offered when it said it can't (`offersByHand`).
    private(set) var canTwoSided = false
    private(set) var offersByHand = false

    private(set) var isBusy = false
    /// Pages are coming off the scanner, or the copy is on its way to the printer: Cancel is possible.
    private(set) var canCancel = false
    /// A scanned copy waits in the preview for Print.
    private(set) var awaitingPrint = false
    private(set) var message: String?
    private(set) var messageIsError = false
    /// The last copy didn't reach the printer; its scans are kept for Print Again.
    private(set) var canPrintAgain = false
    private(set) var sheets: [PreviewSheet] = []
    /// What the last copy sent (its sides' file, the job's copies, the runner's answer), for `--report`.
    private(set) var lastJob: String?

    /// `--report`: the queue to print to in place of the printer's (demo mode's one-sided USB laser for two-sided by hand).
    @ObservationIgnored var queueOverride: (any BatchQueue)?
    /// The job's name where the printer and the queue list it (`--report`'s real copy names what was on the glass).
    @ObservationIgnored var jobName = "Copy"

    @ObservationIgnored private let printer: PrinterModel
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var previewed: [BatchPrintPage]?
    @ObservationIgnored private var thumbnails: [NSImage?] = []
    @ObservationIgnored private var printAgain: (() async -> Void)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var stop: BatchStop?
    /// Each send's number: a progress report from an older one never covers a newer one's words.
    @ObservationIgnored private var sends = 0

    init(printer: PrinterModel, app: AppModel) {
        self.printer = printer
        self.app = app
    }

    // MARK: What can be done

    /// Connected and said whether it has a scanner: a network printer once it answers, a queue printer at once (macOS lists
    /// its USB scanner, or doesn't).
    private var scannerChecked: Bool { !printer.isNetwork || printer.view.isOnline || printer.systemScanner != nil }
    private var hasScanner: Bool { printer.view.interfaces.contains("eSCL") || printer.systemScanner != nil }
    /// Somewhere to print: its macOS queue, or the printer itself straight (roadmap 2.1).
    private var canPrint: Bool { queueOverride != nil || printer.queueName != nil || printer.route != .none }

    var unavailableReason: String? {
        switch CopyRoute.blocker(onPrinter: false, scannerChecked: scannerChecked, hasScanner: hasScanner, canPrint: canPrint) {
        case .connecting: String(localized: "Connecting to the printer…")
        case .noScanner: String(localized: "This printer has no scanner, so it can't copy. You can still print PDFs.")
        case .noQueue: String(localized: "Copies print through this printer's macOS queue, and it isn't set up in macOS yet. Use Set Up in macOS on the Status tab.")
        case .none: nil
        }
    }

    private var controls: CopyControls {
        CopyRoute.controls(onPrinter: false, idCard: false, copies: copies, queueTwoSided: canTwoSided, byHand: offersByHand)
    }

    var showCollate: Bool { controls.collate }
    var showTwoSided: Bool { controls.twoSided }
    var showSource: Bool { sources.count > 1 }
    var canCopy: Bool { unavailableReason == nil && !isBusy }

    var twoSidedText: String { canTwoSided ? String(localized: "Print on both sides") : String(localized: "Print on both sides by hand") }

    var hint: String {
        source == .platen ? String(localized: "Put the page face down on the scanner glass, then click Copy.")
            : String(localized: "Put the pages face up in the document feeder, then click Copy.")
    }

    var summary: String {
        var parts = [copies == 1 ? String(localized: "\(copies) copy") : String(localized: "\(copies) copies")]
        if pagesPerSheet > 1 { parts.append(String(localized: "\(pagesPerSheet) pages per sheet")) }
        parts.append(fitToPaper ? String(localized: "fit to the paper") : String(localized: "actual size"))
        if twoSided && showTwoSided { parts.append(canTwoSided ? String(localized: "both sides of the paper") : String(localized: "both sides by hand")) }
        if !collate && showCollate { parts.append(String(localized: "not collated")) }
        return parts.joined(separator: ", ") + "."
    }

    private var sizing: PageSizing { fitToPaper ? .fitToPaper : .actualSize }
    private var color: ScanColor { isColor ? .color : .grayscale }

    /// The sheet is on screen: the scanner's sources, and whether the printer prints both sides (asked each time: the route
    /// may have changed).
    func shown() async {
        if let scanner = await printer.scanner(), let caps = try? await scanner.capabilities() {
            sources = caps.sources.isEmpty ? [.platen] : caps.sources
            if !sources.contains(source) { source = sources[0] }
        }
        await readTwoSided()
    }

    /// Two-sided where the jobs go (`HandDuplexPrinting.queueTwoSided`); by hand offered where it said it can't.
    func readTwoSided() async {
        let said: Bool? = if let queueOverride { try? await queueOverride.read()?.canTwoSided } else { await HandDuplexPrinting.queueTwoSided(printer, app: app) }
        canTwoSided = said == true
        offersByHand = HandDuplex.offered(said)
        if !canTwoSided && !offersByHand { twoSided = false }
    }

    // MARK: Copy

    /// Copy: scan, then print (or wait in the preview). The work runs in a task of its own so Cancel can stop it.
    func copy() {
        guard canCopy else { return }
        work = Task { await copyPages() }
    }

    /// `copy()`, waited for (`--report`).
    func copyAndWait() async {
        copy()
        await work?.value
    }

    func cancel() {
        work?.cancel()
        stop?.stop()
    }

    private func copyPages() async {
        guard let scanner = await printer.scanner() else {
            say(String(localized: "The scanner isn't available while the printer isn't connected."), error: true)
            return
        }
        let caps = try? await scanner.capabilities()
        let offered = caps?.sources ?? []
        let source = offered.isEmpty || offered.contains(self.source) ? self.source : offered[0]
        let dpi = caps.flatMap { ScanChoices.resolutions($0, source, wanted: [Self.copyDpi]).first } ?? Self.copyDpi
        let size = caps.map { ScanChoices.defaultPageSize(ScanChoices.pageSizes($0, source), remembered: nil,
                                                          metric: Locale.current.measurementSystem == .metric) }
        previewed = nil
        awaitingPrint = false
        thumbnails = []
        sheets = []
        var scanned: [BatchPrintPage] = []
        let pages = await scan(scanner, ScanChoices.request(source, color, dpi, size), dpi: dpi, widthIn300ths: size?.width) { page in
            scanned.append(page)
            self.thumbnails.append(Self.thumbnail(page.jpeg))
            self.showSide(scanned, (scanned.count - 1) / self.pagesPerSheet) // only the side the page lands on: earlier ones are done
        }
        guard let pages, !pages.isEmpty else { return }
        if previewFirst {
            previewed = pages
            awaitingPrint = true
            say(String(localized: "Check the preview, then click Print. Pages per sheet and the size still change it."))
            return
        }
        await printPages(pages)
    }

    /// Prints the copy waiting in the preview, with the options as they are now.
    func printPreviewed() {
        guard awaitingPrint, !isBusy, let pages = previewed else { return }
        awaitingPrint = false
        previewed = nil
        work = Task { await printPages(pages) }
    }

    /// `printPreviewed()`, waited for (`--report`).
    func printPreviewedAndWait() async {
        printPreviewed()
        await work?.value
    }

    func startOver() {
        guard !isBusy else { return }
        forgetPrintAgain()
        previewed = nil
        awaitingPrint = false
        thumbnails = []
        sheets = []
        say(nil)
    }

    /// Sends the copy that didn't print again, from the scans already made.
    func printAgainNow() {
        guard canPrintAgain, !isBusy, let again = printAgain else { return }
        work = Task { await again() }
    }

    /// One scan job; nil when it failed or was cancelled (the message says why). `added`: each page as it comes.
    private func scan(_ scanner: any ScanDevice, _ request: ScanRequest, dpi: Int, widthIn300ths: Int?,
                      added: (BatchPrintPage) -> Void) async -> [BatchPrintPage]? {
        forgetPrintAgain() // a new scan replaces whatever didn't print
        isBusy = true
        canCancel = true
        defer {
            canCancel = false
            isBusy = false
        }
        say(String(localized: "Scanning… (the first page takes longer if the printer was asleep)"))
        var pages: [BatchPrintPage] = []
        do {
            for try await jpeg in scanner.scan(request) {
                try Task.checkCancellation()
                // The resolution the page came at (a scanner may send another than asked), for its size in inches.
                let used = ScanModel.dpi(of: jpeg, asked: dpi, widthIn300ths: widthIn300ths)
                guard let px = ScanImaging.size(jpeg) else { throw ScanError(String(localized: "a page from the scanner isn't a picture")) }
                let inches = CopyLayout.inches(px.width, px.height, used)
                let page = BatchPrintPage(jpeg, inches.width, inches.height)
                pages.append(page)
                added(page)
                say(String(localized: "Scanned page \(pages.count)…"))
            }
            try Task.checkCancellation()
            if pages.isEmpty { say(String(localized: "The scanner returned no pages."), error: true) }
            return pages.isEmpty ? nil : pages
        } catch is CancellationError {
            say(String(localized: "Copy cancelled."))
        } catch let e as ScanError {
            say(String(localized: "Scan failed: \(e.description)"), error: true)
        } catch {
            NSLog("Copy scan failed: %@", "\(error)")
            say(String(localized: "Scan failed: \(error.localizedDescription)"), error: true)
        }
        return nil
    }

    // MARK: Print

    /// The pages printed as the options say now: two-sided by the printer, by hand where it can't, or one side.
    private func printPages(_ pages: [BatchPrintPage]) async {
        let byHand = twoSided && !canTwoSided && offersByHand
        let job = CopyJob(pages: pages, copies: copies, twoSided: twoSided && canTwoSided, byHand: byHand, collate: collate,
                          perSheet: pagesPerSheet, sizing: sizing)
        await send(job)
    }

    /// A copy's print as it was asked, kept as it is for Print Again.
    private struct CopyJob {
        let pages: [BatchPrintPage]
        let copies: Int, twoSided: Bool, byHand: Bool, collate: Bool, perSheet: Int
        let sizing: PageSizing

        var what: String {
            copies > 1 ? (pages.count == 1 ? String(localized: "\(pages.count) page × \(copies) copies") : String(localized: "\(pages.count) pages × \(copies) copies"))
                : (pages.count == 1 ? String(localized: "\(pages.count) page") : String(localized: "\(pages.count) pages"))
        }
    }

    /// Lays the copy out on the paper where its jobs go and sends it there as Batch Print sends a file (`BatchPrintRunner`):
    /// the sides in `CopyLayout.order`, the copies the order leaves to the printer on the job; by hand, the sides once with
    /// the order handed to the runner (`BatchPrintLine.order`), the fronts, the prompt, the backs. A copy that didn't reach
    /// the printer (or was stopped at the prompt) is kept for Print Again; one that may have printed is not.
    private func send(_ job: CopyJob) async {
        forgetPrintAgain()
        isBusy = true
        sends += 1
        let ticket = sends
        let stop = BatchStop()
        self.stop = stop
        canCancel = true
        defer {
            canCancel = false
            isBusy = false
            self.stop = nil
        }
        func keep() {
            printAgain = { [weak self] in await self?.send(job) }
            canPrintAgain = true
        }
        guard let queue = queueOverride ?? printer.batchQueue() else {
            say(String(localized: "This printer isn't set up in macOS yet. Click Set Up in macOS on the Status tab, then Print Again."), error: true)
            keep()
            return
        }
        say(String(localized: "Sending the copy to the printer…"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Inkvolt Print copy", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(jobName + ".pdf")
        let info = try? await queue.read()
        let guess = SheetPrint.guessPaper(metric: Locale.current.measurementSystem == .metric)
        var paper = (width: guess.width * SheetPrint.pointsPerUnit, height: guess.height * SheetPrint.pointsPerUnit)
        if let size = info?.defaultPaper.flatMap(BatchQueueReading.size) { paper = size }
        let line: BatchPrintLine
        let fileSides: Int
        do {
            let sides = try CopyLayout.sides(job.pages.count, job.perSheet)
            let (order, times) = CopyLayout.order(sides.count, job.copies, collate: job.collate, twoSided: job.twoSided || job.byHand)
            let drawn = job.byHand ? Array(sides.indices) : order // by hand: each side once, the runner following the order
            fileSides = drawn.count
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (pages, perSheet, sizing) = (job.pages, job.perSheet, job.sizing)
            let size = CGSize(width: paper.width, height: paper.height)
            try await Task.detached {
                try CopySheets.write(pages, perSheet: perSheet, order: drawn, paper: size, sizing: sizing, to: url, stop: stop)
            }.value
            let measure = try await BatchMeasurer.measure(url.path, offered: nil, MacBatchDocuments(), ask: nil)
            line = job.byHand
                ? BatchPrintLine(url.path, BatchPrintSettings(copies: times, twoSided: true), measure, info, byHand: true,
                                 pageNumbers: sides.map { $0[0] + 1 }, order: order)
                : BatchPrintLine(url.path, BatchPrintSettings(copies: times, twoSided: job.twoSided), measure, info)
        } catch is CancellationError {
            say(String(localized: "Copy cancelled."))
            keep()
            return
        } catch {
            NSLog("Copy layout failed: %@", "\(error)")
            say(String(localized: "Could not print the copy: \(String(localized: "its pages couldn't be laid out on this Mac."))"), error: true)
            keep()
            return
        }
        if let problem = line.problem {
            say(String(localized: "Could not print the copy: \(problem)"), error: true)
            keep()
            return
        }
        var options = BatchPrintOptions()
        if line.byHand {
            let face: OutputFace? = if let name = printer.queueName { await HandDuplexPrinting.printerFace(name, app: app) } else { nil }
            options.turnStack = HandDuplexPrinting.turnStack(queue: printer.queueName ?? printer.id, printerFace: face)
        }
        let chosen = options
        // A late report never covers the result.
        let report: @Sendable (BatchPrintProgress) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.isBusy, self.sends == ticket, p.result == nil, !p.message.isEmpty else { return }
                self.say(p.message)
            }
        }
        let summary = await Task.detached {
            await BatchPrintRunner.run([line], queue, MacBatchDocuments(), options: chosen, progress: report, stop)
        }.value
        guard let result = summary.items.first else {
            say(String(localized: "Copy cancelled."))
            keep()
            return
        }
        lastJob = "\(fileSides) sides at " + String(format: "%.0f × %.0f", paper.width, paper.height)
            + " pt, \(line.settings.copies) on the job, two-sided \(line.settings.twoSided)"
            + ", by hand \(line.byHand), \(line.sheets) sheets estimated; \(result.state.rawValue): \(result.message)"
        if result.state == .sent {
            say(app.isDemo ? String(localized: "Sent to the demo printer: \(job.what). Nothing really prints.") : String(localized: "Sent to the printer: \(job.what)."))
            return
        }
        say(result.state == .stopped && !result.mayHaveSent && result.sheetsSent == 0 ? String(localized: "Copy cancelled.")
            : String(localized: "Could not print the copy: \(result.message)"), error: true)
        if !(result.state == .failed && result.mayHaveSent) { keep() } // never sent again by itself when it may have printed
    }

    private func forgetPrintAgain() {
        printAgain = nil
        canPrintAgain = false
    }

    // MARK: Preview

    /// The previewed copy laid out again after its pages per sheet or size changed.
    private func showPreviewed() {
        guard let pages = previewed else { return }
        let count = (try? CopyLayout.sides(pages.count, pagesPerSheet).count) ?? 0
        for side in 0..<count { showSide(pages, side) }
        if sheets.count > count { sheets.removeLast(sheets.count - count) }
    }

    /// One side of the preview, made anew (its pages so far) or added after the last.
    private func showSide(_ pages: [BatchPrintPage], _ side: Int) {
        let paper = Self.previewPaper
        guard let on = try? CopyLayout.pagesOnSide(pages.count, pagesPerSheet, side),
              let placed = try? CopyLayout.nUp(on.map { (w: pages[$0].widthInches * 96, h: pages[$0].heightInches * 96) }, pagesPerSheet,
                                                paper.width, paper.height, sizing) else { return }
        let shown = placed.enumerated().map { i, p in
            PreviewSheet.Page(id: on[i], image: on[i] < thumbnails.count ? thumbnails[on[i]] : nil, at: p.at, rotated: p.rotated)
        }
        let sheet = PreviewSheet(id: side, paperWidth: paper.width, paperHeight: paper.height, pages: shown)
        if side < sheets.count { sheets[side] = sheet } else { sheets.append(sheet) }
    }

    /// `--report`'s real copy: the share of dark pixels on the previewed copy's first page, made small; nil without one.
    func previewedDarkShare() -> Double? {
        guard let jpeg = previewed?.first?.jpeg, let image = Self.thumbnail(jpeg)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              image.width > 0, image.height > 0 else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let count = image.width * image.height
        let dark = (0..<count).reduce(0) { $0 + (data[$1] < 128 ? 1 : 0) }
        return Double(dark) / Double(count)
    }

    /// A scanned page made small for the preview (600 px at most); nil when it can't be read (printing decodes it again).
    private static func thumbnail(_ jpeg: [UInt8]) -> NSImage? {
        CopySheets.thumbnail(jpeg, maxPixels: 600).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    private func say(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }
}
