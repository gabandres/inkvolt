import AppKit
import Observation
import PDFKit
import PrintCore
import PrintMac
import UniformTypeIdentifiers

/// What a scan is saved as.
enum ScanFormat: String, CaseIterable, Identifiable {
    case pdf, searchablePdf, jpeg
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .searchablePdf: String(localized: "Searchable PDF (text recognised on this Mac)")
        case .jpeg: String(localized: "JPEG images")
        }
    }
}

/// One printer's Scan tab (the Windows app's `ScanViewModel`, eSCL part): the settings its scanner offers, scanning page by
/// page, the review (turn, crop, straighten, skip blank pages, reorder, delete), and saving where the user picks. The pages
/// are kept in the recovery folder as they change, so a crash doesn't lose them.
@MainActor @Observable
final class ScanModel {
    /// "Save cancelled after 2 files (a.pdf, b.pdf): Save again writes the rest."
    nonisolated static func saveCancelled(_ count: Int, names: String) -> String {
        count == 1 ? String(localized: "Save cancelled after 1 file (\(names)): Save again writes the rest.")
            : String(localized: "Save cancelled after \(count) files (\(names)): Save again writes the rest.")
    }

    private(set) var caps: ScannerCapabilities?
    private(set) var loadError: String?
    var source: ScanSource = .platen { didSet { fitChoices() } }
    var color: ScanColor = .color
    var dpi = 300
    var sizeKey = "letter"
    var format: ScanFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "scanFormat") }
    }
    var skipBlank: Bool {
        didSet { UserDefaults.standard.set(skipBlank, forKey: "scanSkipBlank") }
    }
    var straighten: Bool {
        didSet { UserDefaults.standard.set(straighten, forKey: "scanStraighten") }
    }
    /// Batch scanning: a feeder run is saved as several files, split at patch code sheets, blank pages, or either.
    var splitAt: SplitAt {
        didSet { UserDefaults.standard.set(splitAt.rawValue, forKey: "scanSplitAt") }
    }
    /// Separator sheets are kept, as the first page of the file each starts.
    var keepSeparators: Bool {
        didSet {
            UserDefaults.standard.set(keepSeparators, forKey: "scanKeepSeparators")
            if !isScanning && pages.keepSeparators != keepSeparators { // the batch on screen follows it
                pages.keepSeparators = keepSeparators
                savedParts.clear()
                keep()
            }
        }
    }
    /// Several photos on the glass: each is found and saved as its own picture (glass scans only).
    var findPhotos: Bool {
        didSet { UserDefaults.standard.set(findPhotos, forKey: "scanFindPhotos") }
    }
    /// The tab's clean up (Scan settings › Clean up): what each scanned page gets (a preset has its own), each to be changed
    /// on a page in the review. Stored as Windows' number.
    var cleanup: PageFilters {
        didSet { UserDefaults.standard.set(cleanup.rawValue, forKey: "scanCleanup") }
    }
    /// The language text is recognised in (a tag Vision lists); nil: Vision tells it itself.
    var ocrLanguage: String? {
        didSet { UserDefaults.standard.set(ocrLanguage, forKey: "scanOcrLanguage") }
    }

    private(set) var pages = ScanPages()
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var isScanning = false
    private(set) var isSaving = false
    /// What scanning or saving is doing, or what it did.
    private(set) var status = ""
    private(set) var problem: String?
    /// The PDFs the last save wrote (a batch: one per file), for the save bar's Open in Inkvolt PDF.
    private(set) var savedPdfs: [URL] = []
    /// The review's Undo of a clean up: a scan's by its settings, the Clean up view's Done or All Pages, each one step.
    private(set) var undoSteps: [UndoStep] = []

    @ObservationIgnored private var images: [String: [UInt8]] = [:]
    /// The scanner's PDF each page came from, for a scanner that sends only PDF (roadmap 1.3, `ScannerPdf.origin`).
    @ObservationIgnored private var origins: [String: PdfOrigin] = [:]
    /// The files of a batch a preset save wrote before it failed part-way: saving again writes only the rest.
    @ObservationIgnored private var savedParts = SavedParts<String>()
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private unowned let printer: PrinterModel
    @ObservationIgnored private let app: AppModel

    init(printer: PrinterModel, app: AppModel) {
        self.printer = printer
        self.app = app
        let d = UserDefaults.standard
        format = ScanFormat(rawValue: d.string(forKey: "scanFormat") ?? "") ?? .searchablePdf
        skipBlank = d.object(forKey: "scanSkipBlank") as? Bool ?? true
        straighten = d.object(forKey: "scanStraighten") as? Bool ?? true
        let split = SplitAt(rawValue: d.integer(forKey: "scanSplitAt"))
        splitAt = split.isKnown ? split : .none
        keepSeparators = d.bool(forKey: "scanKeepSeparators")
        findPhotos = d.bool(forKey: "scanFindPhotos")
        cleanup = PageFilters(rawValue: d.integer(forKey: "scanCleanup")).intersection(.all)
        ocrLanguage = d.string(forKey: "scanOcrLanguage")
        sizeKey = Locale.current.measurementSystem == .metric ? "a4" : "letter"
    }

    // MARK: Settings

    var sources: [ScanSource] { caps?.sources ?? [] }
    var colors: [ScanColor] { caps.map { ScanChoices.colors($0, source) } ?? [.color] }
    var resolutions: [Int] { caps.map { ScanChoices.resolutions($0, source) } ?? ScanChoices.documentResolutions }
    var sizes: [ScanPageSize] { caps.map { ScanChoices.pageSizes($0, source) } ?? ScanChoices.pageSizes }

    /// Reads what the scanner offers (once connected).
    func load() async {
        guard caps == nil else { return }
        guard let scanner = await printer.scanner() else {
            loadError = String(localized: "The scanner isn't available while the printer isn't connected.")
            return
        }
        do {
            caps = try await scanner.capabilities()
            loadError = caps == nil ? String(localized: "This printer's scanner didn't say what it can do.") : nil
        } catch {
            loadError = String(localized: "The scanner didn't answer. Check that the printer is on, then try again.")
        }
        if let first = caps?.sources.first, !(caps?.sources.contains(source) ?? false) { source = first }
        fitChoices()
    }

    private func fitChoices() {
        if !colors.contains(color), let c = colors.first { color = c }
        if !resolutions.contains(dpi) { dpi = resolutions.min { abs($0 - 300) < abs($1 - 300) } ?? 300 }
        let offered = sizes
        sizeKey = ScanChoices.defaultPageSize(offered, remembered: sizeKey, metric: Locale.current.measurementSystem == .metric).key
    }

    // MARK: Scanning

    /// The preset the last scan was made with: Save saves the way it says (its folder, its file name).
    private(set) var preset: ScanPreset?

    /// One click: the preset matched to this scanner (said in the status line where it had to give), scanned, and saved
    /// by itself unless the preset stops on the pages for a review.
    func scan(with p: ScanPreset) async {
        if caps == nil { await load() }
        guard let caps, !isScanning else { return }
        let plan = PresetPlan.plan(p, caps, feederLoaded: nil, ocrAvailable: true, metric: Locale.current.measurementSystem == .metric)
        source = plan.request.source
        color = plan.request.color
        dpi = plan.request.resolution
        sizeKey = ScanChoices.pageSizes.first { $0.width == plan.request.width && $0.height == plan.request.height }?.key ?? sizeKey
        format = p.fileType == .jpeg ? .jpeg : plan.ocr ? .searchablePdf : .pdf
        preset = p
        let notes = plan.notes
        // The preset's checks are its own: the tab's settings stay as the user set them.
        let check = PageCheck(skipBlank: p.skipBlank, straighten: p.straighten, splitAt: p.splitAt,
                              findPhotos: p.findPhotos && plan.request.source == .platen, cleanup: p.cleanup, ocrLanguage: p.ocrLanguage)
        scan(check: check, keepSeparators: p.keepSeparators) {
            if !notes.isEmpty { self.status = (notes + [self.status]).joined(separator: " ") }
            if !p.review && !self.pages.toSave.isEmpty && self.problem == nil { await self.saveWithPreset() }
        }
    }

    /// Scans with the tab's settings, or a preset's `check` and `keepSeparators`. Batches come from the feeder only, photos
    /// from the glass only.
    func scan(check given: PageCheck? = nil, keepSeparators keepGiven: Bool? = nil, then finished: (@MainActor () async -> Void)? = nil) {
        guard !isScanning else { return }
        problem = nil
        isScanning = true
        status = source == .platen ? String(localized: "Scanning…") : String(localized: "Scanning from the feeder…")
        let request = ScanChoices.request(source, color, dpi, sizes.first { $0.key == sizeKey })
        var c = given ?? PageCheck(skipBlank: skipBlank, straighten: straighten, splitAt: splitAt, findPhotos: findPhotos, cleanup: cleanup,
                                   ocrLanguage: ocrLanguage)
        if source == .platen { c.splitAt = .none } else { c.findPhotos = false }
        let check = c, split = c.splitAt, photos = c.findPhotos
        let duplex = source == .adfDuplex
        if pages.isEmpty || split != .none { pages.keepSeparators = keepGiven ?? keepSeparators } // the batch's setting when it was scanned
        if app.isDemo {
            Demo.scanSetup.prepare(feederBatch: split != .none && source != .platen, photosOnGlass: photos, paperOnLid: c.cleanup.contains(.cropToPaper))
        }
        let widthIn300ths = request.width ?? caps?.input(for: source)?.maxWidth
        scanning = Task {
            defer {
                isScanning = false
                scanning = nil
            }
            guard let scanner = await printer.scanner() else {
                problem = String(localized: "The scanner isn't available while the printer isn't connected.")
                status = ""
                return
            }
            var count = 0
            var added: [String] = []
            var failure: (any Error)?
            do {
                for try await jpeg in scanner.scan(request) {
                    count += 1
                    status = count == 1 ? String(localized: "Scanned \(count) page…") : String(localized: "Scanned \(count) pages…")
                    added.append(await add(jpeg, dpi: Self.dpi(of: jpeg, asked: request.resolution, widthIn300ths: widthIn300ths), check: check))
                }
            } catch {
                failure = error
            }
            // Every page check lands (blank pages skipped, separators found, pages cleaned up) before the scan's clean up
            // becomes its step of Undo and a preset saves, as Windows waits for them all; a stopped scan's pages too.
            await checksLanded()
            if failure == nil && duplex { pages.separatorBacks(added) }
            keep()
            let cleaned = recordCleanup(added, check.cleanup)
            switch failure {
            case nil:
                let found = notes(added, split: split, photos: photos, duplex: duplex) + (cleaned.isEmpty ? [] : [cleaned]) + pdfNote(added, request)
                status = count == 0 ? String(localized: "No pages came from the scanner.") : ([pages.summary + (found.isEmpty ? "" : ".")] + found).joined(separator: " ")
                await finished?()
            case is CancellationError:
                status = String(localized: "Scan stopped.")
            case let e as ScanError:
                problem = e.description
                status = count > 0 ? pages.summary : ""
            default:
                problem = String(localized: "The scan didn't finish: the scanner stopped answering.")
                status = count > 0 ? pages.summary : ""
            }
        }
    }

    /// The page checks still running (each page's, beside the next page's scan), by page.
    @ObservationIgnored private var checks: [String: Task<Void, Never>] = [:]

    /// Waits for every page check that is running; each ends by itself (the analysis copy is at most 1100 pixels).
    private func checksLanded() async {
        while let next = checks.first {
            await next.value.value
            if checks[next.key] == next.value { checks[next.key] = nil }
        }
    }

    func stop() { scanning?.cancel() }

    /// The page's resolution: what was asked, unless its size says otherwise (a scanner that sent another one).
    static func dpi(of jpeg: [UInt8], asked: Int, widthIn300ths: Int?) -> Int {
        guard let width = widthIn300ths, width > 0, let pixels = ScanImaging.size(jpeg)?.width else { return asked }
        let measured = Int((Double(pixels) * 300 / Double(width)).rounded()) // bounded: a JPEG's width (at most 65535) x 300 over a width of at least 1
        return abs(measured - asked) <= max(asked / 30, 2) ? asked : measured
    }

    /// What the page check looks for.
    struct PageCheck: Sendable {
        var skipBlank: Bool
        var straighten: Bool
        var splitAt: SplitAt
        var findPhotos: Bool
        /// What each page is cleaned up with (`ScanPages.analysed`), and the language its text is read in.
        var cleanup: PageFilters = []
        var ocrLanguage: String?
    }

    /// What the page check found.
    private struct Checked: Sendable {
        var looksBlank: Bool
        var skew: Double
        var separator: SeparatorFound
        var photos: [PhotoBox]?
        /// The sheet's edge, looked for when the clean up crops to the paper (`ScanPages.wantsPaperEdge`).
        var paperEdge: CropBox?
    }

    /// Separator, blank and skew checks (the Windows app's `AnalyseAsync`), and the photos on the glass. A separator sheet is
    /// neither skipped nor straightened, nor is a page of photos (each is cut out straight).
    nonisolated private static func check(_ jpeg: [UInt8], dpi: Int, _ c: PageCheck) -> Checked? {
        guard let gray = try? ScanImaging.analysis(jpeg) else { return nil }
        let fullWidth = ScanImaging.size(jpeg)?.width ?? gray.width
        let ppi = Double(gray.width) * Double(dpi) / Double(max(fullWidth, 1))
        let separator = c.splitAt == .none ? SeparatorFound.none : Separators.detect(gray, pixelsPerInch: ppi, splitAt: c.splitAt)
        let looksBlank = separator.kind == .blankPage || BlankPage.isBlank(gray)
        let blank = c.skipBlank && looksBlank && !separator.isSeparator
        let photos = c.findPhotos && !blank && !separator.isSeparator ? PhotoFinder.find(gray, pixelsPerInch: ppi) : nil
        let skew = c.straighten && !blank && !separator.isSeparator && (photos?.isEmpty ?? true) ? Deskew.angle(gray) : 0
        let wantsEdge = ScanPages.wantsPaperEdge(c.cleanup, looksBlank: looksBlank, separator: separator, photos: photos)
        let edge = wantsEdge ? PaperEdge.find(gray, ppi: ppi, deskew: skew) : nil
        return Checked(looksBlank: looksBlank, skew: skew, separator: separator, photos: photos, paperEdge: edge)
    }

    @discardableResult
    private func add(_ jpeg: [UInt8], dpi: Int, check c: PageCheck) async -> String {
        let id = ScanRecoveryStore.newPageName()
        images[id] = jpeg
        if let origin = ScannerPdf.origin(of: jpeg) { origins[id] = origin }
        pages.add(ScannedPage(id: id, dpi: dpi, ocrLanguage: c.ocrLanguage))
        keep()
        refreshThumbnail(id)
        // The page check runs beside the next page's scan.
        checks[id] = Task {
            defer { checks[id] = nil }
            let result: Checked? = await offPool { Self.check(jpeg, dpi: dpi, c) }
            guard let result, pages.page(id) != nil else {
                pages.analysed(id, looksBlank: false, skew: 0, skipBlank: false, straighten: false) // the page stays as scanned
                return
            }
            pages.analysed(id, looksBlank: result.looksBlank, skew: result.skew, skipBlank: c.skipBlank, straighten: c.straighten,
                           separator: result.separator, photos: result.photos, cleanup: c.cleanup, paperEdge: result.paperEdge)
            keep()
            refreshThumbnail(id)
            if !isScanning { status = pages.summary }
        }
        return id
    }

    /// After a scan from a source that sends only PDF: what that means, in words (the Windows app's `PdfNote`).
    private func pdfNote(_ added: [String], _ request: ScanRequest) -> [String] {
        guard let origin = added.lazy.compactMap({ self.origins[$0] }).first else { return [] }
        let from = request.source == .platen ? String(localized: "the glass") : String(localized: "the feeder")
        return [origin.rendered
            ? String(localized: "This scanner sends PDF from \(from): its pages were drawn as pictures at \(request.resolution) dpi for the review.")
            : String(localized: "This scanner sends PDF from \(from): its pictures were taken out as they came, so the review, text recognition and presets work as usual.")]
    }

    /// What `ScannerPdf.keepAsSent` needs to know of a file's pages: where each came from, and whether it changed (edited,
    /// cut into photos, or given a text layer).
    private func toSave(_ file: [ScannedPage]) -> [PageToSave] {
        let ocr = format == .searchablePdf
        return file.map { PageToSave(origins[$0.id], changed: !$0.edits.isEmpty || $0.hasPhotos || ocr) }
    }

    /// Each file's PDF when it is exactly the scanner's own (saved as it sent it), else nil; all nil for JPEG.
    private func asSent(_ files: [[ScannedPage]]) -> [[UInt8]?] {
        format == .jpeg ? files.map { _ in nil } : files.map { ScannerPdf.keepAsSent(toSave($0)) }
    }

    /// After a PDF save from a scanner that sends PDF: whether the files are its own PDF, and if not, why (the Windows app's
    /// `AsSentNote`); "" otherwise.
    private func asSentNote(_ files: [[ScannedPage]]) -> String {
        guard format != .jpeg else { return "" }
        let plans = files.map(toSave).filter { $0.contains { $0.origin != nil } }
        if plans.isEmpty { return "" }
        if plans.allSatisfy({ ScannerPdf.keepAsSent($0) != nil }) {
            return plans.count == 1 ? String(localized: " It is the scanner's own PDF, as it sent it.") : String(localized: " They are the scanner's own PDFs, as it sent them.")
        }
        return plans.compactMap(ScannerPdf.whyNotAsSent).first.map { " " + $0 } ?? ""
    }

    /// What a scan found, after the page summary (the Windows app's notes).
    /// "2 separator sheets found: 3 files."
    private static func separatorsFound(_ separators: Int, files: Int) -> String {
        let filesText = files == 1 ? String(localized: "1 file") : String(localized: "\(files) files")
        return separators == 1 ? String(localized: "1 separator sheet found: \(filesText).")
            : String(localized: "\(separators) separator sheets found: \(filesText).")
    }

    private func notes(_ added: [String], split: SplitAt, photos: Bool, duplex: Bool) -> [String] {
        let run = added.compactMap { pages.page($0) }
        guard !run.isEmpty else { return [] }
        var notes: [String] = []
        let found = run.reduce(0) { $0 + ($1.photos?.count ?? 0) }
        if photos {
            notes.append(found == 0 ? String(localized: "No photos were found on the glass: the whole scan is saved.")
                : found == 1 ? String(localized: "1 photo found, saved as its own picture.")
                : String(localized: "\(found) photos found, each saved as its own picture."))
        }
        let separators = run.filter { $0.isSeparator && $0.separator.kind != .sheetBack }.count
        if split != .none {
            let files = pages.files.count
            notes.append(separators == 0 ? String(localized: "No separator sheets were found: it's one file.")
                : Self.separatorsFound(separators, files: files))
            if duplex && (split == .blankPage || split == .patchCodeOrBlankPage) {
                notes.append(String(localized: "Scanning both sides: a blank back starts a new file too, so patch code sheets suit two-sided batches better."))
            }
        }
        return notes
    }

    // MARK: Review

    func turn(_ id: String, _ quarters: Int) { change(id) { $0.turn(id, quarters) } }
    func toggleStartsFile(_ id: String) { change(id) { $0.toggleStartsFile(id) } }
    func notSeparator(_ id: String) { change(id) { $0.notSeparator(id) } }
    func useAsSeparator(_ id: String) { change(id) { $0.useAsSeparator(id) } }
    func setPhotos(_ id: String, _ photos: [PhotoBox]) { change(id) { $0.setPhotos(id, photos) } }

    /// Looks for the photos on the page again (Find Again), forgetting boxes changed by hand.
    func findPhotosAgain(_ id: String) async {
        if let found = await photosFound(id) { setPhotos(id, found) }
    }

    /// The photos on the page as the finder sees them, without changing the page (the Photos sheet's Find Again).
    func photosFound(_ id: String) async -> [PhotoBox]? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let dpi = page.dpi
        return await offPool {
            guard let gray = try? ScanImaging.analysis(jpeg) else { return nil }
            let ppi = Double(gray.width) * Double(dpi) / Double(max(ScanImaging.size(jpeg)?.width ?? gray.width, 1))
            return PhotoFinder.find(gray, pixelsPerInch: ppi)
        }
    }

    /// The scan's width in inches and its height in units of its width, as scanned (photo boxes are measured on it).
    func scanShape(_ id: String) -> (widthInches: Double, aspect: Double)? {
        guard let jpeg = images[id], let page = pages.page(id), let size = ScanImaging.size(jpeg), size.width > 0, page.dpi > 0
        else { return nil }
        return (Double(size.width) / Double(page.dpi), Double(size.height) / Double(size.width))
    }
    func crop(_ id: String, shown: CropBox?) { change(id) { $0.crop(id, shown: shown) } }
    func reset(_ id: String) { change(id) { $0.reset(id) } }
    func keepPage(_ id: String) { change(id) { $0.keep(id) } }
    func skipPage(_ id: String) { change(id) { $0.skip(id) } }

    // MARK: Clean up (roadmap 2.3)

    /// One step of the review's Undo: each page's edits before a clean up and right after it (what of its crop and filters
    /// is still as the clean up left it goes back, `ScanPages.restoreCleanup`).
    struct UndoStep {
        var name: String
        var before: [String: PageEdits]
        var after: [String: PageEdits]
    }

    /// Counts every change to the steps of Undo: Edit › Undo is registered again on each, even when two steps share a name.
    private(set) var undoChanges = 0

    /// "Clean up page 2": what Undo would undo; nil when there's nothing.
    var undoName: String? { undoSteps.last?.name }

    /// Undo can run: there's a step, and no scan or save is under way (Windows' `CanUndo`, not while busy).
    var canUndo: Bool { !undoSteps.isEmpty && !isSaving && !isScanning }

    /// Undoes the last clean up.
    func undo() {
        guard canUndo, let step = undoSteps.popLast() else { return }
        undoChanges += 1
        savedParts.clear()
        pages.restoreCleanup(step.before, after: step.after)
        keep()
        for id in step.before.keys { refreshThumbnail(id) }
        status = "Undone: \(step.name.prefix(1).lowercased() + step.name.dropFirst())."
    }

    private func recordUndo(_ name: String, _ before: [String: PageEdits], after: [String: PageEdits]) {
        guard !before.isEmpty else { return }
        undoSteps.append(UndoStep(name: name, before: before, after: after))
        undoChanges += 1
    }

    /// A scan cleaned up by its settings is one step of Undo, however many pages it has; what to say about it
    /// (`ScanPages.cleanupSummary`: how many pages, and any whose paper's edge couldn't be found).
    private func recordCleanup(_ added: [String], _ cleanup: PageFilters) -> String {
        guard !cleanup.isEmpty else { return "" }
        var before: [String: PageEdits] = [:], after: [String: PageEdits] = [:]
        for id in added {
            guard let page = pages.page(id), let edits = page.beforeCleanup else { continue }
            before[id] = edits
            after[id] = page.edits
        }
        let name = before.count == 1 ? String(localized: "Clean up page \(pages.number(before.keys.first!) ?? 1)") : String(localized: "Clean up \(before.count) pages")
        recordUndo(name, before, after: after)
        return pages.cleanupSummary(added, cleanup)
    }

    /// Each page's paper edge as `PaperEdge.find` saw it on the page straightened by `deskew` (nil edge: none to be sure
    /// of), so the Clean up view's choices don't decode and look again on every switch.
    @ObservationIgnored private var paperEdges: [String: (deskew: Double, edge: CropBox?)] = [:]

    /// The page's edits with `filters` in place of its own (`PageEdits.withFilters`): the paper's edge is looked for on the
    /// analysis copy only when a crop to it is new, once per page and straightening. Nil when the page isn't there.
    func edits(_ id: String, with filters: PageFilters) async -> PageEdits? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let (edits, photos, dpi) = (page.edits, page.hasPhotos, page.dpi)
        if let known = paperEdges[id], known.deskew == edits.deskew {
            return edits.withFilters(filters, photos: photos) { known.edge }
        }
        let (result, looked): (PageEdits, CropBox??) = await offPool {
            var looked: CropBox?? = nil
            let result = edits.withFilters(filters, photos: photos) { () -> CropBox? in
                let edge = ScanImaging.paperEdge(jpeg, dpi: dpi, deskew: edits.deskew)
                looked = .some(edge)
                return edge
            }
            return (result, looked)
        }
        if case .some(let edge) = looked, images[id] != nil { paperEdges[id] = (edits.deskew, edge) }
        return result
    }

    /// What the Clean up view shows: the page (or a scan's first photo) with `filters`, at most 1600 pixels on its longest
    /// side, and what it says about them; nil when `stop` fired (a newer choice) or the page is gone.
    func cleanPreview(_ id: String, _ filters: PageFilters, stop: BatchStop) async -> (image: NSImage?, note: String)? {
        guard let jpeg = images[id], let page = pages.page(id), let edits = await edits(id, with: filters), !stop.isStopped else { return nil }
        let (dpi, photo) = (page.dpi, page.photos?.first)
        let result: Result<CGImage, any Error> = await offPool {
            Result {
                if let photo { return try ScanImaging.photoPreview(jpeg, photo, filters: filters, maxPixels: 1600, dpi: dpi, stop: stop) }
                return try ScanImaging.render(jpeg, edits, maxPixels: 1600, dpi: dpi, stop: stop)
            }
        }
        if stop.isStopped { return nil }
        guard case .success(let image) = result else { return (nil, String(localized: "Couldn't show the page: it couldn't be read.")) }
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), cleanNote(id, filters, edits))
    }

    /// What the Clean up view says after drawing `edits` for `wanted` (the Windows app's `CleanNote`).
    func cleanNote(_ id: String, _ wanted: PageFilters, _ edits: PageEdits) -> String {
        if let size = images[id].flatMap(ScanImaging.size), PageCleanup.tooLarge(size.width, size.height), !wanted.isDisjoint(with: .pixelFilters) {
            return String(localized: "This page is too large to clean up (\(size.width * size.height / 1_000_000) million pixels): it is saved as scanned.")
        }
        let photos = pages.page(id)?.hasPhotos ?? false
        if wanted.contains(.cropToPaper) && !edits.filters.contains(.cropToPaper) && !photos {
            return String(localized: "The paper's edge can't be told from the lid here (a white sheet on a white lid, a page printed to its edges): the page is kept whole.")
        }
        return wanted.isEmpty ? String(localized: "As scanned.") : String(localized: "Shown \(PageCleanup.describe(wanted)).")
    }

    /// The Clean up view's Done: the page gets `filters`, one step of Undo.
    func applyClean(_ id: String, _ filters: PageFilters) async {
        guard let edits = await edits(id, with: filters), let page = pages.page(id), edits != page.edits else { return }
        recordUndo(String(localized: "Clean up page \(pages.number(id) ?? 1)"), [id: page.edits], after: [id: edits])
        change(id) { $0.setEdits(id, edits) }
    }

    /// All Pages' progress while it looks at the pages: how many are done of how many.
    private(set) var cleanProgress: (done: Int, total: Int)?

    /// The Clean up view's All Pages: the switches it shows (`shown`; a page of photos has no crop or whiten) set as
    /// `chosen` has them on every page that is saved (not a separator, not left out), the others' own left alone; one step
    /// of Undo. The pages are looked at a few at a time (`cleanProgress`); `stop` (the view's Cancel) changes none.
    func applyCleanToAll(_ chosen: PageFilters, shown: PageFilters = .all, stop: BatchStop = BatchStop()) async {
        let targets = pages.pages.filter { !$0.isSeparator && !$0.skipped }.map { ($0.id, $0.edits.filters.setting(shown, as: chosen)) }
        var found: [String: PageEdits] = [:]
        cleanProgress = (0, targets.count)
        defer { cleanProgress = nil }
        let width = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
        await withTaskGroup(of: (String, PageEdits?).self) { group in
            var next = 0
            func start() {
                guard next < targets.count, !stop.isStopped else { return }
                let (id, filters) = targets[next]
                next += 1
                group.addTask { (id, await self.edits(id, with: filters)) }
            }
            for _ in 0..<width { start() }
            for await (id, edits) in group {
                if let edits { found[id] = edits }
                cleanProgress?.done += 1
                start()
            }
        }
        if stop.isStopped {
            status = String(localized: "Clean up stopped: no page was changed.")
            return
        }
        var before: [String: PageEdits] = [:], after: [String: PageEdits] = [:]
        for (id, _) in targets {
            guard let edits = found[id], let now = pages.page(id), edits != now.edits else { continue }
            before[id] = now.edits
            after[id] = edits
            pages.setEdits(id, edits)
            refreshThumbnail(id)
        }
        savedParts.clear()
        keep()
        recordUndo(before.count == 1 ? String(localized: "Clean up 1 page") : String(localized: "Clean up \(before.count) pages"), before, after: after)
        status = before.count == 1 ? String(localized: "1 page was cleaned up (Undo puts it back).") : String(localized: "\(before.count) pages were cleaned up (Undo puts them back).")
    }

    func delete(_ id: String) {
        savedParts.clear()
        pages.delete(id)
        images[id] = nil
        thumbnails[id] = nil
        paperEdges[id] = nil
        keep()
        status = pages.summary
    }

    func move(_ id: String, by offset: Int) {
        guard let n = pages.number(id) else { return }
        savedParts.clear()
        pages.move(id, to: n - 1 + offset)
        keep()
    }

    func move(_ id: String, to index: Int) {
        savedParts.clear()
        pages.move(id, to: index)
        keep()
    }

    /// Drops every page (after saving them, or when the user starts over).
    func clear() {
        preset = nil
        savedParts.clear()
        pages = ScanPages()
        images = [:]
        origins = [:]
        thumbnails = [:]
        paperEdges = [:]
        if !undoSteps.isEmpty {
            undoSteps = []
            undoChanges += 1
        }
        problem = nil
        status = ""
        app.scanStore?.forget(printer.id)
    }

    /// The page with its edits, for the crop view: its filters too, so the crop goes on the page as it is.
    func image(_ id: String, maxPixels: Int = 1600, asScanned: Bool = false) async -> NSImage? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        // The crop is what's drawn on it; photos are found and cut on the scan as it came.
        let edits = asScanned ? PageEdits.none : PageEdits(quarterTurns: page.edits.quarterTurns, deskew: page.edits.deskew, filters: page.edits.filters)
        let dpi = page.dpi
        let image: CGImage? = await offPool { try? ScanImaging.render(jpeg, edits, maxPixels: maxPixels, dpi: dpi) }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    private func change(_ id: String, _ body: (inout ScanPages) -> Void) {
        savedParts.clear() // the pages changed: a retry writes everything again
        body(&pages)
        keep()
        refreshThumbnail(id)
        status = pages.summary
    }

    private func refreshThumbnail(_ id: String) {
        guard let jpeg = images[id], let page = pages.page(id) else { return }
        let (edits, dpi) = (page.edits, page.dpi)
        Task {
            let image: CGImage? = await offPool { try? ScanImaging.render(jpeg, edits, maxPixels: 520, dpi: dpi) }
            guard let image, pages.page(id)?.edits == edits else { return } // a later edit's thumbnail wins
            thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    /// The recovery folder gets the page list (and any page not written yet) each time it changes.
    private func keep() {
        guard let store = app.scanStore else { return }
        if pages.isEmpty {
            store.forget(printer.id)
            return
        }
        let kept = pages.kept(printerId: printer.id, printerName: printer.name, ocr: format == .searchablePdf, now: Date())
        let images = images
        try? store.keep(kept) { images[$0] ?? [] }
    }

    /// Pages a run that didn't end cleanly left for this printer: back into the review.
    func restore(_ left: LeftOverScan) {
        var restored = ScanPages(restoring: left.scan)
        for p in restored.pages {
            if let data = FileManager.default.contents(atPath: left.pagePath(KeptPage(p.id, dpi: p.dpi, ocr: false))) {
                images[p.id] = [UInt8](data)
            } else {
                restored.delete(p.id)
            }
        }
        if pages.isEmpty { pages.keepSeparators = keepSeparators }
        for p in restored.pages { pages.add(p) }
        ScanRecoveryStore.remove(left)
        keep()
        for p in pages.pages { refreshThumbnail(p.id) }
        status = pages.summary
    }

    /// The skew the page check measures on the page as it would be saved (0 when straightening worked); for `--report`.
    func residualSkew(_ id: String) async -> Double? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let (edits, dpi) = (page.edits, page.dpi)
        return await offPool { (try? ScanImaging.analysis(ScanImaging.jpeg(jpeg, edits, dpi: dpi))).map(Deskew.angle) }
    }

    /// The page as the scanner sent it; for `--report`.
    func scannedJpeg(_ id: String) -> [UInt8]? { images[id] }

    /// The page as it would be saved, as JPEG (its edits and clean up); for `--report`.
    func savedJpeg(_ id: String) async -> [UInt8]? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let (edits, dpi) = (page.edits, page.dpi)
        return await offPool { try? ScanImaging.jpeg(jpeg, edits, dpi: dpi) }
    }

    // MARK: Printing (copy)

    /// The kept pages through the print panel, on this printer's queue: a copy.
    func printPages() async {
        guard !pages.toSave.isEmpty, !isSaving else { return }
        isSaving = true
        status = String(localized: "Preparing the copy…")
        let jobs = jobs(pages.files)
        let data: Data? = await offPool {
            try? ScanPdf.write(Self.render(jobs).joined().map { ScanPdf.Page(jpeg: $0.jpeg, dpi: $0.dpi) })
        }
        isSaving = false
        status = pages.summary
        guard let data, let document = PDFDocument(data: data) else {
            problem = String(localized: "The pages couldn't be prepared for printing.")
            return
        }
        Printing.print(document, name: suggestedName, on: printer, app: app)
    }

    /// Prints a separator sheet (Patch T, for this Mac's paper size) at actual size, on this printer's queue.
    func printSeparatorSheet() {
        let metric = Locale.current.measurementSystem == .metric
        guard let sheet = SeparatorSheet.page(.patchT, widthIn: metric ? 8.27 : 8.5, heightIn: metric ? 11.69 : 11),
              let data = SeparatorSheetPdf.write(sheet), let document = PDFDocument(data: data) else { return }
        Printing.print(document, name: sheet.title, on: printer, app: app, actualSize: true)
    }

    // MARK: Saving

    /// One page as a file sees it: the scanner's JPEG, its edits, its resolution, and its photos (each saved by itself).
    private struct PageJob: Sendable {
        var jpeg: [UInt8]
        var edits: PageEdits
        var dpi: Int
        var photos: [PhotoBox]?
        /// The language the page's text is read in (nil: Vision's choice).
        var ocrLanguage: String?
    }

    /// An image a file holds: a page as edited, or one photo cut out (no text recognition for photos).
    private struct OutputImage: Sendable {
        var jpeg: [UInt8]
        var dpi: Int
        var isPhoto: Bool
        var ocrLanguage: String?
    }

    private func jobs(_ files: [[ScannedPage]]) -> [[PageJob]] {
        files.map { file in
            file.map { PageJob(jpeg: images[$0.id] ?? [], edits: $0.edits, dpi: $0.dpi, photos: $0.hasPhotos ? $0.photos : nil, ocrLanguage: $0.ocrLanguage) }
        }
    }

    /// Each page as saved: cleaned up by its filters (a page of photos: each photo by what suits a print), checked against
    /// `stop` (a save's Cancel) between pages and inside the filters.
    nonisolated private static func render(_ jobs: [[PageJob]], stop: BatchStop? = nil) throws -> [[OutputImage]] {
        try jobs.map { file in
            try file.flatMap { job -> [OutputImage] in
                try stop?.check()
                if let photos = job.photos {
                    return try photos.map { box in
                        let jpeg = try ScanImaging.photo(job.jpeg, box, filters: job.edits.filters, dpi: job.dpi, stop: stop)
                        return OutputImage(jpeg: jpeg, dpi: job.dpi, isPhoto: true)
                    }
                }
                let jpeg = try ScanImaging.jpeg(job.jpeg, job.edits, dpi: job.dpi, stop: stop)
                return [OutputImage(jpeg: jpeg, dpi: job.dpi, isPhoto: false, ocrLanguage: job.ocrLanguage)]
            }
        }
    }

    /// The running save's stop (its Cancel); nil when none runs.
    @ObservationIgnored private var saveStop: BatchStop?

    /// The save bar's Cancel while saving: the files not written yet aren't, the pages stay.
    func cancelSave() { saveStop?.stop() }

    /// The images each file holds: one per page, or one per photo.
    var imagesPerFile: [Int] { pages.files.map { file in file.reduce(0) { $0 + ($1.hasPhotos ? $1.photos!.count : 1) } } }

    /// Saving makes more than one file (a batch, or several images): the save panel asks for a folder.
    var savesSeveralFiles: Bool { format == .jpeg ? imagesPerFile.reduce(0, +) > 1 : imagesPerFile.count > 1 }

    /// A save's Cancel: the files written before it (`written[f]`, empty for those that weren't), which stay.
    private struct SaveStopped: Error {
        var written: [[URL]]
    }

    /// Writes `files` (each a PDF at `targets[f][0]`, or its images at `targets[f]`), every file's images rendered first. A
    /// file whose `asSent[f]` is there is the scanner's own PDF, written as it sent it (nothing rendered).
    /// - Throws: `SaveStopped` with the files written so far when `stop` fires.
    nonisolated private static func write(_ jobs: [[PageJob]], to targets: [[URL]], format: ScanFormat, asSent: [[UInt8]?],
                                          stop: BatchStop? = nil) throws -> [URL] {
        var written: [[URL]] = jobs.map { _ in [] }
        do {
            try write(jobs, to: targets, format: format, asSent: asSent, stop: stop, written: &written)
        } catch is CancellationError {
            throw SaveStopped(written: written)
        }
        return written.flatMap { $0 }
    }

    nonisolated private static func write(_ jobs: [[PageJob]], to targets: [[URL]], format: ScanFormat, asSent: [[UInt8]?],
                                          stop: BatchStop?, written: inout [[URL]]) throws {
        var files: [[OutputImage]] = []
        for (f, job) in jobs.enumerated() { files.append(f < asSent.count && asSent[f] != nil ? [] : try render([job], stop: stop)[0]) }
        for (f, (file, urls)) in zip(files, targets).enumerated() {
            try stop?.check()
            if format != .jpeg, f < asSent.count, let pdf = asSent[f] {
                try Data(pdf).write(to: urls[0], options: .atomic) // the scanner's own PDF, as it sent it
                written[f] = [urls[0]]
                continue
            }
            switch format {
            case .pdf, .searchablePdf:
                let pdfPages = try file.map { image in
                    try stop?.check()
                    let words = format == .searchablePdf && !image.isPhoto ? ScanPdf.recognize(image.jpeg, language: image.ocrLanguage) : nil
                    return ScanPdf.Page(jpeg: image.jpeg, dpi: image.dpi, words: words)
                }
                try ScanPdf.write(pdfPages, title: urls[0].deletingPathExtension().lastPathComponent).write(to: urls[0], options: .atomic)
                written[f] = [urls[0]]
            case .jpeg:
                var images: [URL] = []
                for (image, url) in zip(file, urls) {
                    try Data(image.jpeg).write(to: url, options: urls.count == 1 && files.count == 1 ? .atomic : .withoutOverwriting)
                    images.append(url)
                }
                written[f] = images
            }
        }
    }

    /// Where each file goes in `folder`, named after `stem`: "Scan.pdf"; a batch "Scan (1).pdf", "Scan (2).pdf"; images
    /// "Scan (1).jpg"…, a batch's "Scan (2-1).jpg" (the Windows app's names). Never over a file that's there.
    private func targets(in folder: URL, stem: String) throws -> [[URL]] {
        let counts = imagesPerFile
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let several = counts.count > 1
        return try counts.enumerated().map { f, images in
            let name = several ? "\(stem) (\(f + 1))" : stem
            if format != .jpeg { return try FileNameTemplate.uniquePaths(folder.path, name, ".pdf", count: 1, exists: exists).map { URL(fileURLWithPath: $0) } }
            if several {
                let set = try FileNameTemplate.uniquePaths(folder.path, "\(stem) (\(f + 1)-1)", ".jpg", count: 1, exists: exists)
                return try (1...images).map { i in
                    i == 1 ? URL(fileURLWithPath: set[0])
                        : URL(fileURLWithPath: try FileNameTemplate.uniquePaths(folder.path, "\(stem) (\(f + 1)-\(i))", ".jpg", count: 1, exists: exists)[0])
                }
            }
            return try FileNameTemplate.uniquePaths(folder.path, name, ".jpg", count: images, exists: exists).map { URL(fileURLWithPath: $0) }
        }
    }

    /// Saves the way the preset says: in its folder (asked for once, then remembered), its subfolder, its file name, each file
    /// of a batch with its own `{n}` and `{pages}`; then what the preset does after (print a copy, attach to an email). A save
    /// that failed part-way writes only the files it hadn't when Save is pressed again.
    func saveWithPreset() async {
        guard let p = preset else { return }
        var folder = app.presetFolder(p.id)
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Use This Folder")
            panel.message = String(localized: "Choose where \"\(p.name)\" saves its scans (a folder in iCloud Drive or another synced folder works too). Inkvolt Print remembers it.")
            panel.directoryURL = FileManager.default.urls(for: p.folder == .pictures ? .picturesDirectory : .documentDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            app.setPresetFolder(p.id, url)
            folder = app.presetFolder(p.id) ?? url
        }
        guard let folder, !pages.toSave.isEmpty, !isSaving else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let files = pages.files
        let counts = imagesPerFile
        let ext = format == .jpeg ? ".jpg" : ".pdf"
        var numbers = PartNumbers(1)
        var all: [URL] = []
        isSaving = true
        problem = nil
        status = format == .searchablePdf ? String(localized: "Recognising text…") : String(localized: "Saving…")
        let stop = BatchStop()
        saveStop = stop
        defer { saveStop = nil }
        for (f, file) in files.enumerated() {
            let ids = file.map(\.id)
            if let done = savedParts.find(ids) {
                all += done.map { URL(fileURLWithPath: $0) }
                continue
            }
            let ctx = NameContext(now: Date(), preset: p.name, printer: printer.name, number: numbers.take(app.reserveNumber(p.id)), pages: counts[f])
            let stem = FileNameTemplate.fileName(p.fileName, ctx)
            let sub = FileNameTemplate.subfolder(p.subfolder, ctx)
            let dir = sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
            let format = format
            let job = jobs([file])
            let sent = asSent([file])
            let result: Result<[URL], any Error> = await offPool {
                Result {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let count = format == .jpeg ? counts[f] : 1
                    let paths = try FileNameTemplate.uniquePaths(dir.path, stem, ext, count: count) { FileManager.default.fileExists(atPath: $0) }
                    return try Self.write(job, to: [paths.map { URL(fileURLWithPath: $0) }], format: format, asSent: sent, stop: stop)
                }
            }
            if case .failure(let error) = result, error is SaveStopped || error is CancellationError {
                isSaving = false
                savedPdfs = all.filter { $0.pathExtension.lowercased() == "pdf" }
                status = all.isEmpty ? String(localized: "Save cancelled. The pages are still here.")
                    : all.count == 1 ? String(localized: "Save cancelled after 1 file: Save again writes the rest.")
                    : String(localized: "Save cancelled after \(all.count) files: Save again writes the rest.")
                return
            }
            guard case .success(let urls) = result else {
                isSaving = false
                let part = files.count > 1 ? String(localized: " (file \(f + 1) of \(files.count); Save again writes the rest)") : ""
                problem = String(localized: "The scan couldn't be saved in \(folder.lastPathComponent)\(part). Check the folder is still there, or choose another in Manage Presets.")
                status = pages.summary
                return
            }
            savedParts.add(ids, paths: urls.map(\.path))
            all += urls
        }
        isSaving = false
        await finishSaving(all, in: folder.lastPathComponent, note: asSentNote(files), reveal: p.after == .none, presetOpens: p.after == .openInInkvoltPdf)
        await after(p.after, all)
    }

    /// The preset's step after saving: print a copy of what was saved on this printer, attach it to a new email in the
    /// user's mail app (Inkvolt Print has no mail account of its own), or open the saved PDFs in Inkvolt PDF (as on Windows,
    /// JPEG scans are only saved).
    private func after(_ step: PresetAfter, _ urls: [URL]) async {
        switch step {
        case .print:
            let document = PDFDocument()
            for url in urls {
                if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                    for i in 0..<pdf.pageCount { if let page = pdf.page(at: i) { document.insert(page, at: document.pageCount) } }
                } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                    document.insert(page, at: document.pageCount)
                }
            }
            if document.pageCount > 0 { Printing.print(document, name: urls.first?.deletingPathExtension().lastPathComponent ?? "Scan", on: printer, app: app) }
        case .email:
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: urls) else {
                problem = String(localized: "No mail app is set up on this Mac to attach the scan to. The scan is saved.")
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return
            }
            service.subject = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : String(localized: "Scans")
            service.perform(withItems: urls)
        case .openInInkvoltPdf:
            if !InkvoltPdfApp.open(urls) { problem = String(localized: "Inkvolt PDF isn't installed on this Mac. The scan is saved.") }
        default:
            break
        }
    }

    /// The name the save panel suggests: "Scan 2026-10-26 14.30".
    var suggestedName: String {
        FileNameTemplate.fileName("Scan {date} {time}", NameContext(now: Date(), preset: "", printer: printer.name, number: 1, pages: pages.toSave.count))
    }

    /// Saves the pages that are kept to `url`: a PDF or JPEG file when they make one file, else a folder, where each file of a
    /// batch (and each image) gets a numbered name. Searchable PDFs get each page's text recognised first (not photos'). Then
    /// clears the review.
    func save(to url: URL, reveal: Bool = true) async {
        guard !pages.toSave.isEmpty, !isSaving else { return }
        isSaving = true
        problem = nil
        let format = format
        status = format == .searchablePdf ? String(localized: "Recognising text…") : String(localized: "Saving…")
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let targets: [[URL]]
        do {
            targets = url.hasDirectoryPath ? try self.targets(in: url, stem: FileNameTemplate.sanitize(suggestedName)) : [[url]]
        } catch {
            isSaving = false
            problem = String(localized: "There are too many scans with that name in \(url.lastPathComponent). Choose another folder.")
            return
        }
        let files = pages.files
        // The files a cancelled save wrote stay written: saving again writes only the rest (`savedParts`).
        let earlier = files.map { savedParts.find($0.map(\.id)) }
        let rest = files.indices.filter { earlier[$0] == nil }
        let job = jobs(rest.map { files[$0] }), sent = asSent(rest.map { files[$0] }), restTargets = rest.map { targets[$0] }
        let stop = BatchStop()
        saveStop = stop
        let result: Result<[URL], any Error> = await offPool {
            Result { try Self.write(job, to: restTargets, format: format, asSent: sent, stop: stop) }
        }
        saveStop = nil
        isSaving = false
        let before = earlier.compactMap { $0 }.flatMap { $0 }.map { URL(fileURLWithPath: $0) }
        // Cancel stops before the next page or file; one that came after everything was written changes nothing.
        if case .failure(let error) = result, let stopped = error as? SaveStopped {
            for (i, urls) in stopped.written.enumerated() where !urls.isEmpty { savedParts.add(files[rest[i]].map(\.id), paths: urls.map(\.path)) }
            let saved = before + stopped.written.flatMap { $0 }
            savedPdfs = saved.filter { $0.pathExtension.lowercased() == "pdf" }
            status = saved.isEmpty ? String(localized: "Save cancelled. The pages are still here.")
                : Self.saveCancelled(saved.count, names: saved.map(\.lastPathComponent).joined(separator: ", "))
            return
        }
        switch result {
        case .success(let urls):
            await finishSaving(before + urls, in: url.lastPathComponent, note: asSentNote(files), reveal: reveal)
        case .failure:
            problem = String(localized: "The scan couldn't be saved there. Choose another place, or check there's room on the disk.")
            status = pages.summary
        }
    }

    /// The save's status line; then, with Settings' "Open scans in Inkvolt PDF" on and Inkvolt PDF installed, the saved
    /// PDFs open there (once: not again when the preset's own step opens them), else Finder shows them when asked.
    private func finishSaving(_ urls: [URL], in place: String, note: String, reveal: Bool, presetOpens: Bool = false) async {
        let saved = pages.toSave.count == 1 ? String(localized: "1 page") : String(localized: "\(pages.toSave.count) pages")
        let files = urls.count > 1 ? String(localized: " as \(urls.count) files") : ""
        clear()
        status = String(localized: "Saved \(saved)\(files) to \(urls.count == 1 ? urls[0].lastPathComponent : place).") + note
        savedPdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        if InkvoltPdfApp.openScans && !presetOpens && !savedPdfs.isEmpty && InkvoltPdfApp.url != nil {
            _ = InkvoltPdfApp.open(savedPdfs)
        } else if reveal {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// The save bar's Open in Inkvolt PDF: every PDF the last save wrote.
    func openSavedInInkvoltPdf() {
        if !InkvoltPdfApp.open(savedPdfs) { problem = String(localized: "Inkvolt PDF isn't installed on this Mac. The scan is saved.") }
    }
}
