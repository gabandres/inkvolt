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
    /// Pages lying sideways or upside down turned upright when their text says so clearly (`PageUpright`, roadmap 4.3).
    var upright: Bool {
        didSet { UserDefaults.standard.set(upright, forKey: "scanUpright") }
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
    /// The feeder scans one side: both sides by turning the stack over for the backs (`TurnedStack`, roadmap 4.1).
    var turnStack: Bool {
        didSet { UserDefaults.standard.set(turnStack, forKey: "scanTurnStack") }
    }
    /// The tab's clean up (Scan settings › Clean up): what each scanned page gets (a preset has its own), each to be changed
    /// on a page in the review. Stored as Windows' number.
    /// The color the tab's Drop a color drops (roadmap 4.7), kept as "#RRGGBB"; red until another is chosen.
    var dropColor: DropColor {
        didSet { UserDefaults.standard.set(dropColor.hex, forKey: "scanDropColor") }
    }
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
    /// The review's Undo: a scan's clean up by its settings, the Clean up view's Done or All Pages, a turned stack put in
    /// order or its backs swapped, each one step.
    private(set) var undoSteps: [UndoStep] = []
    /// The last scan's turned stack, while its backs can be put the other way (until the next scan or Clear).
    var stack: StackScan?
    /// What the turned stack's question answers instead of asking (`--report`); nil: the alert asks.
    @ObservationIgnored var answerTurnStack: (@MainActor (Int) -> Bool)?

    @ObservationIgnored private var images: [String: [UInt8]] = [:]
    /// The scanner's PDF each page came from, for a scanner that sends only PDF (roadmap 1.3, `ScannerPdf.origin`).
    @ObservationIgnored private var origins: [String: PdfOrigin] = [:]
    /// The files of a batch a preset save wrote before it failed part-way: saving again writes only the rest.
    @ObservationIgnored private var savedParts = SavedParts<String>()
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private unowned let printer: PrinterModel
    @ObservationIgnored private let app: AppModel

    /// The printer this tab scans on (Recent Scans' Print prints there).
    var owner: PrinterModel { printer }

    init(printer: PrinterModel, app: AppModel) {
        self.printer = printer
        self.app = app
        let d = UserDefaults.standard
        format = ScanFormat(rawValue: d.string(forKey: "scanFormat") ?? "") ?? .searchablePdf
        skipBlank = d.object(forKey: "scanSkipBlank") as? Bool ?? true
        straighten = d.object(forKey: "scanStraighten") as? Bool ?? true
        upright = d.object(forKey: "scanUpright") as? Bool ?? true
        let split = SplitAt(rawValue: d.integer(forKey: "scanSplitAt"))
        splitAt = split.isKnown ? split : .none
        keepSeparators = d.bool(forKey: "scanKeepSeparators")
        findPhotos = d.bool(forKey: "scanFindPhotos")
        turnStack = d.bool(forKey: "scanTurnStack")
        cleanup = PageFilters(rawValue: d.integer(forKey: "scanCleanup")).intersection(.all)
        dropColor = DropColor.parse(d.string(forKey: "scanDropColor")) ?? .red
        ocrLanguage = d.string(forKey: "scanOcrLanguage")
        sizeKey = Locale.current.measurementSystem == .metric ? "a4" : "letter"
    }

    // MARK: Settings

    var sources: [ScanSource] { caps?.sources ?? [] }
    var colors: [ScanColor] { caps.map { ScanChoices.colors($0, source) } ?? [.color] }
    var resolutions: [Int] { caps.map { ScanChoices.resolutions($0, source) } ?? ScanChoices.documentResolutions }
    var sizes: [ScanPageSize] { caps.map { ScanChoices.pageSizes($0, source) } ?? ScanChoices.pageSizes }
    /// The feeder is chosen and scans one side only: the tab offers `turnStack`.
    var offersTurnStack: Bool { caps.map { ScanChoices.offersTurnStack($0, source) } ?? false }

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
        let plan = PresetPlan.plan(p, caps, feederLoaded: nil, ocrAvailable: true, metric: Locale.current.measurementSystem == .metric, turnsStacks: true)
        source = plan.request.source
        color = plan.request.color
        dpi = plan.request.resolution
        sizeKey = ScanChoices.pageSizes.first { $0.width == plan.request.width && $0.height == plan.request.height }?.key ?? sizeKey
        format = p.fileType == .jpeg ? .jpeg : plan.ocr ? .searchablePdf : .pdf
        if preset?.id != p.id { forgetSaveName() }
        preset = p
        let notes = plan.notes
        // The preset's checks are its own: the tab's settings stay as the user set them.
        let check = PageCheck(skipBlank: p.skipBlank, straighten: p.straighten, splitAt: p.splitAt,
                              findPhotos: p.findPhotos && plan.request.source == .platen, cleanup: p.cleanup, ocrLanguage: p.ocrLanguage,
                              upright: p.turnUpright, oneBit: plan.oneBit, drop: DropColor.parse(p.dropColor) ?? .red)
        scan(check: check, keepSeparators: p.keepSeparators, turnStack: plan.turnStack) {
            if !notes.isEmpty { self.status = (notes + [self.status]).joined(separator: " ") }
            if !p.review && !self.pages.toSave.isEmpty && self.problem == nil { await self.saveWithPreset() }
            if p.review { await self.fillSaveName() } // once its pages are checked
        }
    }

    // MARK: The file's name from the page's text (roadmap 4.11)

    /// The review shows the name the preset's save will give (its template reads the page's text), to change before saving.
    var showsSaveName: Bool { preset.map { $0.review && FileNameTemplate.readsText($0.fileName) } ?? false }

    /// The first file's name (no extension): filled from the page's text (`fillSaveName`), or as typed in the review.
    private(set) var saveName = ""
    private(set) var saveNameEdited = false
    @ObservationIgnored private var saveNameFills = 0
    /// What the first page said, for the page as it was read (its id and edits): a fill or the save after it reads it once.
    @ObservationIgnored private var foundFor: (page: String, edits: PageEdits, found: FoundInText)?

    /// The name as typed in the review: the save gives the first file this name.
    func editSaveName(_ name: String) {
        saveName = name
        saveNameEdited = true
    }

    private func forgetSaveName() {
        saveName = ""
        saveNameEdited = false
        foundFor = nil
    }

    /// What the first page of `file` (not a page of photos) says for the preset's name, its text read by Vision as the page
    /// will be saved; nil when the name doesn't ask, `FoundInText.none` when the page says nothing or can't be read.
    private func found(in file: [ScannedPage], _ p: ScanPreset) async -> FoundInText? {
        guard FileNameTemplate.readsText(p.fileName) || FileNameTemplate.readsText(p.subfolder) else { return nil }
        guard let page = file.first(where: { !$0.hasPhotos }), let jpeg = images[page.id] else { return FoundInText.none }
        if let cached = foundFor, cached.page == page.id, cached.edits == page.edits { return cached.found }
        let (edits, dpi, language) = (page.edits, page.dpi, page.ocrLanguage)
        let found: FoundInText = await offPool {
            guard let shown = try? ScanImaging.jpeg(jpeg, edits, dpi: dpi), let size = try? PdfWriter.jpegInfo(shown),
                  let words = ScanPdf.recognize(shown, language: language) else { return FoundInText.none }
            return TextFinds.find(ScanPdf.pixelWords(words, width: size.width, height: size.height), locale: .current)
        }
        if self.pages.page(page.id)?.edits == edits { foundFor = (page.id, edits, found) }
        return found
    }

    /// Fills `saveName` as the preset's save would name the first file (with the preset's next number), unless it was typed.
    func fillSaveName() async {
        guard showsSaveName, !saveNameEdited, let p = preset, let file = pages.files.first, !file.isEmpty else { return }
        saveNameFills += 1
        let fill = saveNameFills
        let found = await found(in: file, p)
        guard fill == saveNameFills, !saveNameEdited, preset?.id == p.id else { return }
        let current = app.presets.first { $0.id == p.id } ?? p
        let pages = imagesPerFile.first ?? file.count
        saveName = FileNameTemplate.fileName(current.fileName, NameContext(now: Date(), preset: current.name, printer: printer.name,
                                                                           number: current.nextNumber, pages: pages, found: found))
    }

    /// Scans with the tab's settings, or a preset's `check`, `keepSeparators` and `turnStack`. Batches come from the feeder
    /// only, photos from the glass only; a turned stack (`TurnedStack`) only from a feeder that scans one side.
    func scan(check given: PageCheck? = nil, keepSeparators keepGiven: Bool? = nil, turnStack turnGiven: Bool? = nil,
              then finished: (@MainActor () async -> Void)? = nil) {
        guard !isScanning else { return }
        problem = nil
        isScanning = true
        stack = nil // "Backs in the Other Order" is for the last turned stack only
        status = source == .platen ? String(localized: "Scanning…") : String(localized: "Scanning from the feeder…")
        let request = ScanChoices.request(source, color, dpi, sizes.first { $0.key == sizeKey })
        var c = given ?? PageCheck(skipBlank: skipBlank, straighten: straighten, splitAt: splitAt, findPhotos: findPhotos, cleanup: cleanup,
                                   ocrLanguage: ocrLanguage, upright: upright, drop: dropColor)
        if source == .platen { c.splitAt = .none } else { c.findPhotos = false }
        // Which way up is told by Latin-like letters only: a page in Hebrew, Arabic or Chinese isn't turned.
        c.upright = c.upright && PageUpright.suitsLanguage(c.ocrLanguage ?? Locale.preferredLanguages.first)
        let check = c, split = c.splitAt, photos = c.findPhotos
        let duplex = source == .adfDuplex
        let turning = (turnGiven ?? turnStack) && offersTurnStack
        if pages.isEmpty || split != .none { pages.keepSeparators = keepGiven ?? keepSeparators } // the batch's setting when it was scanned
        if app.isDemo {
            Demo.scanSetup.prepare(feederBatch: split != .none && source != .platen, photosOnGlass: photos, paperOnLid: c.cleanup.contains(.cropToPaper),
                                   turnedStack: turning ? .fronts : nil, markedForm: !c.cleanup.isDisjoint(with: [.dropColor, .punchHoles]))
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
            var sides: [[String]] = [[], []] // a turned stack's fronts, then its backs
            var side = 0
            @MainActor func pass() async throws {
                for try await jpeg in scanner.scan(request) {
                    count += 1
                    status = count == 1 ? String(localized: "Scanned \(count) page…") : String(localized: "Scanned \(count) pages…")
                    let id = await add(jpeg, dpi: Self.dpi(of: jpeg, asked: request.resolution, widthIn300ths: widthIn300ths), check: check)
                    added.append(id)
                    sides[side].append(id)
                }
                if Task.isCancelled { throw CancellationError() } // the stream ends quietly when the task is stopped
            }
            do {
                try await pass()
            } catch {
                failure = error
            }
            // Both sides on a one-sided feeder: the backs once the stack is turned over, then every page in its place.
            var stackNote = ""
            var backsStopped = false
            if turning && failure == nil && !sides[0].isEmpty {
                let fronts = sides[0].count
                status = fronts == 1 ? String(localized: "Fronts scanned: \(fronts) page.") : String(localized: "Fronts scanned: \(fronts) pages.")
                if await askTurnStack(fronts) {
                    if app.isDemo { Demo.scanSetup.prepare(feederBatch: split != .none, photosOnGlass: false, turnedStack: .backs) }
                    status = String(localized: "Scanning the backs…")
                    side = 1
                    do {
                        try await pass()
                    } catch is CancellationError {
                        // Stopped part-way: the backs scanned so far are put in order like any others, and that is said.
                        stackNote = String(localized: "Scanning the backs was stopped: the pages scanned are in order.")
                        backsStopped = true
                    } catch {
                        // The fronts are kept: what went wrong with the backs is said, and they can be scanned again by hand.
                        let why = (error as? ScanError)?.description ?? String(localized: "the scanner stopped answering.")
                        stackNote = String(localized: "The backs couldn't be scanned: \(why) The fronts are kept.")
                    }
                    await checksLanded()
                    let backs = sides[1]
                    if !backs.isEmpty { putStackInOrder(fronts: sides[0], backs: backs) } // with each separator sheet's other side
                    let counts = fronts == backs.count ? String(localized: "Fronts and backs are in page order.")
                        : backs.isEmpty ? (fronts == 1 ? String(localized: "The feeder sent no backs, so only \(fronts) front is here.")
                                            : String(localized: "The feeder sent no backs, so only the \(fronts) fronts are here."))
                        : String(localized: "\(fronts) fronts but \(backs.count) backs: a sheet may have gone through twice or been left behind. The backs were matched from the last sheet: check the order and drag any page that's out of place, or click Undo to put the backs after the fronts.")
                    stackNote = stackNote.isEmpty ? counts : !backs.isEmpty && fronts != backs.count ? stackNote + " " + counts : stackNote
                } else {
                    stackNote = String(localized: "Only the fronts were scanned.")
                }
            }
            // Every page check lands (blank pages skipped, separators found, pages cleaned up) before the scan's clean up
            // becomes its step of Undo and a preset saves, as Windows waits for them all; a stopped scan's pages too.
            await checksLanded()
            if failure == nil && duplex { pages.separatorBacks(added) }
            keep()
            let turned = recordUpright(added)
            let cleaned = recordCleanup(added, check.cleanup)
            switch failure {
            case nil:
                let found = (stackNote.isEmpty ? [] : [stackNote]) + notes(added, split: split, photos: photos, duplex: duplex || stack != nil)
                    + (turned.isEmpty ? [] : [turned]) + (cleaned.isEmpty ? [] : [cleaned]) + pdfNote(added, request)
                status = count == 0 ? String(localized: "No pages came from the scanner.") : ([pages.summary + (found.isEmpty ? "" : ".")] + found).joined(separator: " ")
                if !backsStopped { await finished?() } // stopped: the pages stay for a look, not saved by a preset
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
        /// Turn a page upright when it lies sideways or upside down and its text says so clearly (`PageUpright`).
        var upright = false
        /// Save the pages in a PDF in black and white (a preset's smaller file, roadmap 4.4).
        var oneBit = false
        /// The color the clean up's Drop a color drops (roadmap 4.7).
        var drop: DropColor = .red
    }

    /// What the page check found.
    private struct Checked: Sendable {
        var looksBlank: Bool
        var skew: Double
        /// The quarter turns that stand it upright (`PageUpright.orient`); 0 when not sure.
        var turns: Int
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
        // Straightened and turned upright (roadmap 4.3) only when it's a page: not skipped, a separator or a scan of photos;
        // looked at for its way up only when something is on it.
        let mayStraighten = !blank && !separator.isSeparator && (photos?.isEmpty ?? true)
        let (skew, turns) = PageUpright.orient(gray, ppi, straighten: c.straighten, upright: c.upright, mayStraighten: mayStraighten,
                                               hasText: mayStraighten && !looksBlank)
        let wantsEdge = ScanPages.wantsPaperEdge(c.cleanup, looksBlank: looksBlank, separator: separator, photos: photos)
        let edge = wantsEdge ? PaperEdge.find(gray, ppi: ppi, deskew: skew) : nil
        return Checked(looksBlank: looksBlank, skew: skew, turns: turns, separator: separator, photos: photos, paperEdge: edge)
    }

    /// Past `PageCleanup.maxPixels` by its header (read without decoding): saved as scanned, never decoded at full size.
    /// Past `PageCleanup.maxPixels`, or with no size in its header (ImageIO gives none for a JPEG claiming 65,500 × 65,500,
    /// and such a picture is never decoded): saved as scanned.
    nonisolated static func tooLargeToEdit(_ jpeg: [UInt8]) -> Bool {
        ScanImaging.size(jpeg).map { PageCleanup.tooLarge($0.width, $0.height) } ?? true
    }

    @discardableResult
    private func add(_ jpeg: [UInt8], dpi: Int, check c: PageCheck) async -> String {
        let id = ScanRecoveryStore.newPageName()
        images[id] = jpeg
        if let origin = ScannerPdf.origin(of: jpeg) { origins[id] = origin }
        var page = ScannedPage(id: id, dpi: dpi, ocrLanguage: c.ocrLanguage, tooLargeToEdit: Self.tooLargeToEdit(jpeg))
        page.oneBit = c.oneBit
        pages.add(page)
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
                           separator: result.separator, photos: result.photos, cleanup: c.cleanup, paperEdge: result.paperEdge,
                           quarterTurns: result.turns, drop: c.drop, grey: Self.isGrey(jpeg))
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
        return file.map { PageToSave(origins[$0.id], changed: !$0.edits.isEmpty || $0.hasPhotos || ocr || $0.oneBit) }
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

    // MARK: A turned stack (roadmap 4.1)

    /// Asks for the stack to be turned over once its `fronts` are scanned (the Windows app's question, a modal alert);
    /// false: only the fronts.
    private func askTurnStack(_ fronts: Int) async -> Bool {
        if let answerTurnStack { return answerTurnStack(fronts) }
        let alert = NSAlert()
        alert.messageText = fronts == 1 ? String(localized: "Fronts scanned: \(fronts) page.") : String(localized: "Fronts scanned: \(fronts) pages.")
        alert.informativeText = fronts == 1
            ? String(localized: "The front of \(fronts) sheet is scanned. Take it out of the output tray, turn it over like a page of a book, put it back in the feeder and click Scan the Backs.")
            : String(localized: "The fronts of \(fronts) sheets are scanned. Take the stack out of the output tray, turn it over like a page of a book without sorting it, put it back in the feeder and click Scan the Backs.")
        alert.addButton(withTitle: String(localized: "Scan the Backs"))
        alert.addButton(withTitle: String(localized: "Only the Fronts"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A turned stack's fronts and backs put in page order (backs last sheet first), each separator sheet's other side with
    /// it; one step of Undo puts them back as scanned.
    private func putStackInOrder(fronts: [String], backs: [String]) {
        var scanned = StackScan(fronts: fronts, backs: backs)
        pages.pair(&scanned, reversed: TurnedStack.backsReversed)
        stack = scanned
        let ids = fronts + backs, first = scanned
        recordUndo(String(localized: "Put the fronts and backs in order")) { model in
            // This step's own stack: by now its pairing is the first one again (Undo takes a swap back before this), whatever
            // a later scan did to the review's.
            var now = first
            model.pages.unpair(&now)
            if model.stack?.fronts == fronts { model.stack = nil }
            return ids
        }
    }

    /// "Backs in the Other Order" can run: there's a turned stack and nothing is scanning or saving.
    var canSwapBacks: Bool { stack != nil && !isScanning && !isSaving }

    /// The backs matched the other way round (a scanner whose output tray reverses the stack): first sheet first, or back to
    /// last sheet first; one step of Undo.
    func swapBacks() {
        guard canSwapBacks, var scanned = stack else { return }
        savedParts.clear()
        let was = scanned.reversed
        // The sheets pair differently now: each separator sheet's other side is found again (the old marks put back). The
        // step keeps its own stack and marks: a scan meanwhile lets the review's go.
        let swap = pages.swapBacks(&scanned)
        stack = scanned
        keep()
        let ids = scanned.fronts + scanned.backs
        for id in ids { refreshThumbnail(id) }
        recordUndo(String(localized: "Put the backs in the other order")) { model in
            model.stack = model.pages.undoSwap(swap)
            return ids
        }
        status = was ? String(localized: "The backs are now matched from the first sheet. Undo puts them back.")
            : String(localized: "The backs are matched from the last sheet again.")
    }

    // MARK: Clean up (roadmap 2.3)

    /// One step of the review's Undo: a clean up (each page's edits before it and right after it: what of its crop and filters
    /// is still as the clean up left it goes back, `ScanPages.restoreCleanup`), a turned stack put in order or its backs
    /// swapped, pages turned upright; `undo` puts it back and returns the pages whose thumbnails change.
    struct UndoStep {
        var name: String
        var undo: @MainActor (ScanModel) -> [String]
    }

    /// Counts every change to the steps of Undo: Edit › Undo is registered again on each, even when two steps share a name.
    private(set) var undoChanges = 0

    /// "Clean up page 2": what Undo would undo; nil when there's nothing.
    var undoName: String? { undoSteps.last?.name }

    /// Undo can run: there's a step, and no scan or save is under way (Windows' `CanUndo`, not while busy).
    var canUndo: Bool { !undoSteps.isEmpty && !isSaving && !isScanning }

    /// Undoes the last step.
    func undo() {
        guard canUndo, let step = undoSteps.popLast() else { return }
        undoChanges += 1
        savedParts.clear()
        let changed = step.undo(self)
        keep()
        for id in changed { refreshThumbnail(id) }
        status = "Undone: \(step.name.prefix(1).lowercased() + step.name.dropFirst())."
    }

    private func recordUndo(_ name: String, _ before: [String: PageEdits], after: [String: PageEdits]) {
        guard !before.isEmpty else { return }
        recordUndo(name) { model in
            model.pages.restoreCleanup(before, after: after)
            return Array(before.keys)
        }
    }

    private func recordUndo(_ name: String, _ undo: @escaping @MainActor (ScanModel) -> [String]) {
        undoSteps.append(UndoStep(name: name, undo: undo))
        undoChanges += 1
    }

    /// Pages the scan turned upright (`PageUpright`) are one step of Undo, however many: each still as the check left it
    /// goes back as the scanner sent it. What to say about it ("2 pages were turned upright."), or "".
    private func recordUpright(_ added: [String]) -> String {
        let turned = added.filter { pages.page($0)?.turnedUpright == true }
        guard let first = turned.first else { return "" }
        let name = turned.count == 1 ? String(localized: "Turn page \(pages.number(first) ?? 1) upright") : String(localized: "Turn \(turned.count) pages upright")
        recordUndo(name) { model in model.pages.undoUpright(turned) }
        return turned.count == 1 ? String(localized: "1 page was turned upright.") : String(localized: "\(turned.count) pages were turned upright.")
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
    func edits(_ id: String, with filters: PageFilters, drop: DropColor? = nil) async -> PageEdits? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let (edits, photos, dpi) = (page.edits, page.hasPhotos, page.dpi)
        if let known = paperEdges[id], known.deskew == edits.deskew {
            return edits.withFilters(filters, photos: photos, drop: drop) { known.edge }
        }
        let (result, looked): (PageEdits, CropBox??) = await offPool {
            var looked: CropBox?? = nil
            let result = edits.withFilters(filters, photos: photos, drop: drop) { () -> CropBox? in
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
    func cleanPreview(_ id: String, _ filters: PageFilters, drop: DropColor? = nil, stop: BatchStop) async -> (image: NSImage?, note: String)? {
        guard let jpeg = images[id], let page = pages.page(id), let edits = await edits(id, with: filters, drop: drop), !stop.isStopped else { return nil }
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
        if let size = images[id].flatMap(ScanImaging.size), PageCleanup.tooLarge(size.width, size.height) {
            let pixels = size.width.multipliedReportingOverflow(by: size.height) // a header's sizes: the product can overflow
            let shown = (pixels.overflow ? Int.max : pixels.partialValue) / 1_000_000
            return String(localized: "This page is too large to clean up, straighten, crop or turn (\(shown) million pixels): it is saved as scanned.")
        }
        let photos = pages.page(id)?.hasPhotos ?? false
        if wanted.contains(.cropToPaper) && !edits.filters.contains(.cropToPaper) && !photos {
            return String(localized: "The paper's edge can't be told from the lid here (a white sheet on a white lid, a page printed to its edges): the page is kept whole.")
        }
        if wanted.contains(.dropColor), let jpeg = images[id], Self.isGrey(jpeg) {
            return String(localized: "This page was scanned in grey: it has no colors to drop.")
        }
        return wanted.isEmpty ? String(localized: "As scanned.") : String(localized: "Shown \(PageCleanup.describe(wanted, drop: edits.drop)).")
    }

    /// The scanner's JPEG is grey (one component): it has no color to drop.
    nonisolated static func isGrey(_ jpeg: [UInt8]) -> Bool { (try? PdfWriter.jpegInfo(jpeg))?.components == 1 }

    /// The Clean up view's Done: the page gets `filters`, one step of Undo.
    func applyClean(_ id: String, _ filters: PageFilters, drop: DropColor? = nil) async {
        guard let edits = await edits(id, with: filters, drop: drop), let page = pages.page(id), edits != page.edits else { return }
        recordUndo(String(localized: "Clean up page \(pages.number(id) ?? 1)"), [id: page.edits], after: [id: edits])
        change(id) { $0.setEdits(id, edits) }
    }

    /// All Pages' progress while it looks at the pages: how many are done of how many.
    private(set) var cleanProgress: (done: Int, total: Int)?

    /// The Clean up view's All Pages: the switches it shows (`shown`; a page of photos has no crop or whiten) set as
    /// `chosen` has them on every page that is saved (not a separator, not left out), the others' own left alone; one step
    /// of Undo. The pages are looked at a few at a time (`cleanProgress`); `stop` (the view's Cancel) changes none.
    func applyCleanToAll(_ chosen: PageFilters, shown: PageFilters = .all, drop: DropColor? = nil, stop: BatchStop = BatchStop()) async {
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
                group.addTask { (id, await self.edits(id, with: filters, drop: drop)) }
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
        forgetSaveName()
        stack = nil
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
        if showsSaveName && !saveNameEdited && !isScanning { Task { await fillSaveName() } } // the first page may have changed
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
        for var p in restored.pages {
            p.tooLargeToEdit = images[p.id].map(Self.tooLargeToEdit) ?? false
            pages.add(p)
        }
        ScanRecoveryStore.remove(left)
        keep()
        for p in pages.pages { refreshThumbnail(p.id) }
        status = pages.summary
    }

    /// The skew the page check measures on the page as it would be saved (0 when straightening worked); for `--report`.
    func residualSkew(_ id: String) async -> Double? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let (edits, dpi) = (page.edits, page.dpi)
        return await offPool { (try? ScanImaging.analysis(ScanImaging.jpeg(jpeg, edits, dpi: dpi))).map { Deskew.angle($0) } }
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
        /// Saved in a PDF in black and white (roadmap 4.4).
        var oneBit = false
    }

    /// An image a file holds: a page as edited, or one photo cut out (no text recognition for photos, never black and white).
    private struct OutputImage: Sendable {
        var jpeg: [UInt8]
        var dpi: Int
        var isPhoto: Bool
        var ocrLanguage: String?
        var oneBit = false
    }

    private func jobs(_ files: [[ScannedPage]]) -> [[PageJob]] {
        files.map { file in
            file.map { PageJob(jpeg: images[$0.id] ?? [], edits: $0.edits, dpi: $0.dpi, photos: $0.hasPhotos ? $0.photos : nil, ocrLanguage: $0.ocrLanguage,
                    oneBit: $0.oneBit) }
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
                return [OutputImage(jpeg: jpeg, dpi: job.dpi, isPhoto: false, ocrLanguage: job.ocrLanguage, oneBit: job.oneBit)]
            }
        }
    }

    /// One file's pages as a Word document or text file (roadmap 4.14) at `url`: each page's text read by Vision as the page
    /// is saved; a page of photos goes in as its photos, a page with no text read as the page itself (Windows' `DocPagesAsync`).
    /// - Throws: `SaveStopped` (nothing written) when `stop` fires.
    nonisolated private static func writeDocument(_ file: [PageJob], to url: URL, type: PresetFileType, title: String, stop: BatchStop?) throws -> [URL] {
        do {
            var pages: [ScanDocPage] = []
            for job in file {
                try stop?.check()
                if let photos = job.photos {
                    let jpegs = try photos.map { try ScanImaging.photo(job.jpeg, $0, filters: job.edits.filters, dpi: job.dpi, stop: stop) }
                    pages.append(ScanDocPage(nil, dpi: job.dpi, pictures: jpegs))
                    continue
                }
                let jpeg = try ScanImaging.jpeg(job.jpeg, job.edits, dpi: job.dpi, stop: stop)
                if let words = ScanPdf.recognize(jpeg, language: job.ocrLanguage), !words.isEmpty, let size = try? PdfWriter.jpegInfo(jpeg) {
                    pages.append(ScanDocPage(ScanPdf.pixelWords(words, width: size.width, height: size.height), dpi: job.dpi))
                } else {
                    pages.append(ScanDocPage(nil, dpi: job.dpi, pictures: [jpeg]))
                }
            }
            try stop?.check()
            let bytes = type == .word ? try ScanDocx.write(pages, title: title) : ScanText.write(pages)
            try Data(bytes).write(to: url, options: .atomic)
            return [url]
        } catch is CancellationError {
            throw SaveStopped(written: [])
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
    /// `options`: a preset's PDF/A-2b or password (roadmap 4.18); `asSent` is all nil then (always the app's own PDF).
    nonisolated private static func write(_ jobs: [[PageJob]], to targets: [[URL]], format: ScanFormat, asSent: [[UInt8]?],
                                          stop: BatchStop? = nil, options: PdfWriteOptions? = nil) throws -> [URL] {
        var written: [[URL]] = jobs.map { _ in [] }
        do {
            try write(jobs, to: targets, format: format, asSent: asSent, stop: stop, options: options, written: &written)
        } catch is CancellationError {
            throw SaveStopped(written: written)
        }
        return written.flatMap { $0 }
    }

    nonisolated private static func write(_ jobs: [[PageJob]], to targets: [[URL]], format: ScanFormat, asSent: [[UInt8]?],
                                          stop: BatchStop?, options: PdfWriteOptions?, written: inout [[URL]]) throws {
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
                    // Black and white (a smaller file): the page at 1 bit; one that can't be (too large) stays its JPEG.
                    let bits = image.oneBit && !image.isPhoto ? try? ScanImaging.bits(image.jpeg, dpi: image.dpi, stop: stop) : nil
                    try stop?.check()
                    return ScanPdf.Page(jpeg: image.jpeg, dpi: image.dpi, words: words, bits: bits)
                }
                try ScanPdf.write(pdfPages, title: urls[0].deletingPathExtension().lastPathComponent, options: options)
                    .write(to: urls[0], options: .atomic)
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
    /// `reveal` false (the report's checks): nothing is shown or opened once saved.
    func saveWithPreset(reveal: Bool = true) async {
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
        // A preset's PDF/A or password (roadmap 4.18): the password kept in the keychain, else asked now (and kept when the
        // person says so). Such a PDF is always the app's own, never the scanner's as it sent it.
        var password: String?
        if format != .jpeg && ScanPresets.savesWithPassword(p) {
            password = app.presetPasswords.password(for: p.id)
            if !PdfEncryption.usable(password) {
                guard let asked = PresetPasswordPrompt.ask(presetName: p.name), PdfEncryption.usable(asked.password) else {
                    problem = String(localized: "Not saved: the preset puts a password on its PDF, and none was entered.")
                    return
                }
                password = asked.password
                if asked.remember { app.presetPasswords.set(asked.password, for: p.id) }
            }
        }
        let options: PdfWriteOptions?
        do {
            options = format == .jpeg ? nil : try ScanPresets.writeOptions(p, password)
        } catch {
            problem = String(localized: "Not saved: the preset puts a password on its PDF, and none was entered.")
            return
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let files = pages.files
        let counts = imagesPerFile
        // A Word document or text file (roadmap 4.14): the text read from the pages, written by PrintCore.
        let document: PresetFileType? = p.fileType == .word || p.fileType == .text ? p.fileType : nil
        let ext = document.map(ScanPresets.fileExtension) ?? (format == .jpeg ? ".jpg" : ".pdf")
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
            let found = await found(in: file, p)
            let ctx = NameContext(now: Date(), preset: p.name, printer: printer.name, number: numbers.take(app.reserveNumber(p.id)), pages: counts[f],
                                  found: found)
            // The first file's name as the review shows it, when it was changed there; else the template's.
            let typed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = f == 0 && saveNameEdited && !typed.isEmpty ? FileNameTemplate.sanitize(typed) : FileNameTemplate.fileName(p.fileName, ctx)
            let sub = FileNameTemplate.subfolder(p.subfolder, ctx)
            let dir = sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
            let format = format
            let job = jobs([file])
            let sent = options == nil ? asSent([file]) : [nil]
            let result: Result<[URL], any Error> = await offPool {
                Result {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let count = format == .jpeg && document == nil ? counts[f] : 1
                    let paths = try FileNameTemplate.uniquePaths(dir.path, stem, ext, count: count) { FileManager.default.fileExists(atPath: $0) }
                    if let document {
                        return try Self.writeDocument(job[0], to: URL(fileURLWithPath: paths[0]), type: document, title: stem, stop: stop)
                    }
                    return try Self.write(job, to: [paths.map { URL(fileURLWithPath: $0) }], format: format, asSent: sent, stop: stop, options: options)
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
        let note = options == nil ? asSentNote(files)
            : options?.pdfA == true ? " " + String(localized: "Saved as PDF/A.") : " " + String(localized: "It asks for its password to open.")
        await finishSaving(all, in: folder.lastPathComponent, note: note, reveal: reveal && p.after == .none, presetOpens: !reveal || p.after == .openInInkvoltPdf,
                           preset: p.name, access: folder)
        await after(p.after, all, document: document != nil, password: options?.password)
    }

    /// The preset's step after saving: print a copy of what was saved on this printer, attach it to a new email in the
    /// user's mail app (Inkvolt Print has no mail account of its own), or open the saved PDFs in Inkvolt PDF (as on Windows,
    /// JPEG scans are only saved).
    /// A Word or text scan (`document`) prints its pages, as Windows' copy does, and isn't opened in Inkvolt PDF (it opens PDFs).
    /// `password`: the one the preset put on its PDFs, which PDFKit opens them with to print the copy (Windows' engine can't).
    private func after(_ step: PresetAfter, _ urls: [URL], document: Bool = false, password: String? = nil) async {
        switch step {
        case .print where document:
            await printPages()
        case .openInInkvoltPdf where document:
            break
        case .print:
            let document = PDFDocument()
            for url in urls {
                if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                    if pdf.isLocked, !(password.map { pdf.unlock(withPassword: $0) } ?? false) {
                        // PDFKit can't open AES-256 with a password beyond ASCII (an ñ): the copy is printed from the
                        // scanned pages instead, as a Word or text scan's is, rather than nothing said and nothing printed.
                        await printPages()
                        return
                    }
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
            await finishSaving(before + urls, in: url.lastPathComponent, note: asSentNote(files), reveal: reveal, access: url)
        case .failure:
            problem = String(localized: "The scan couldn't be saved there. Choose another place, or check there's room on the disk.")
            status = pages.summary
        }
    }

    /// The save's status line; then, with Settings' "Open scans in Inkvolt PDF" on and Inkvolt PDF installed, the saved
    /// PDFs open there (once: not again when the preset's own step opens them), else Finder shows them when asked.
    /// A save also goes on the recent scans (roadmap 4.15), with this scanner's name, the preset's, and a bookmark of `access`
    /// (the folder saved in, or the one file a save panel named), while the save still holds it.
    private func finishSaving(_ urls: [URL], in place: String, note: String, reveal: Bool, presetOpens: Bool = false,
                              preset: String? = nil, access: URL? = nil) async {
        app.noteRecentScan(urls, pages: pages.toSave.count, printer: printer.name, preset: preset, access: access)
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

// MARK: Join two halves (roadmap 4.8)

/// Join with the Next Page…'s work: both halves as saved (RGB, full size), the overlap `HalvesJoin` found on copies a
/// `factor` smaller, whether it is sure, and the page ids it was opened on.
struct JoinWork: Sendable {
    let first: String, second: String
    let a: JoinImages.Half, b: JoinImages.Half
    let dpi: Int
    let found: JoinFound
    /// The overlap in full-size pixels (`HalvesJoin.fromCopy`): where the second half starts.
    let placement: JoinPlacement
    /// The halves `previewFactor` times smaller, made once for the sheet's preview (Windows' join view does the same).
    let previewA: JoinImages.Half, previewB: JoinImages.Half
    let previewFactor: Int
}

extension ScanModel {
    /// Why page `id` can't be joined with the next one; nil when it can (the next page there, neither a separator nor a scan
    /// of photos, both checked and at one resolution).
    func joinProblem(_ id: String) -> String? {
        guard let n = pages.number(id), let page = pages.page(id) else { return String(localized: "The pages changed while the join was open: choose Join with the Next Page… again.") }
        guard n < pages.pages.count else { return String(localized: "Page \(n) is the last: join a page with the one after it.") }
        let next = pages.pages[n]
        if page.isSeparator || next.isSeparator || page.photos != nil || next.photos != nil || page.tooLargeToEdit || next.tooLargeToEdit {
            return String(localized: "Page \(n) or the next one can't be joined: separator sheets and scans of photos stay as they are.")
        }
        if !page.analysed || !next.analysed { return String(localized: "Page \(n) or the next one is still being checked: join them in a moment.") }
        if page.dpi != next.dpi { return String(localized: "The two pages were scanned at different resolutions: scan both halves at the same one to join them.") }
        return nil
    }

    /// The two halves read and their overlap looked for (on grey copies of about 100 pixels an inch); nil (with `problem` set)
    /// when they can't be joined or read.
    func findJoin(_ id: String, stop: BatchStop = BatchStop()) async -> JoinWork? {
        if let why = joinProblem(id) {
            problem = why
            return nil
        }
        guard let n = pages.number(id) else { return nil }
        let (first, second) = (pages.pages[n - 1], pages.pages[n])
        guard let jpegA = images[first.id], let jpegB = images[second.id] else { return nil }
        let dpi = first.dpi
        let work: JoinWork? = await offPool {
            guard let a = try? JoinImages.half(jpegA, first.edits, dpi: dpi, stop: stop),
                  let b = try? JoinImages.half(jpegB, second.edits, dpi: dpi, stop: stop) else { return nil }
            // As Windows: the placement found, sure or not (not sure, it is the best guess to nudge from).
            guard let found = try? HalvesJoin.find(a.rgb, a.width, a.height, b.rgb, b.width, b.height, channels: 3, dpi: dpi, stop: stop) else { return nil }
            let placement = found.placement
            let previewFactor = HalvesJoin.previewFactor(a.width, a.height, b.width, b.height, side: ScanModel.joinPreviewSide)
            let pa = HalvesJoin.shrink(a.rgb, a.width, a.height, channels: 3, factor: previewFactor)
            let pb = HalvesJoin.shrink(b.rgb, b.width, b.height, channels: 3, factor: previewFactor)
            return JoinWork(first: first.id, second: second.id, a: a, b: b, dpi: dpi, found: found, placement: placement,
                            previewA: JoinImages.Half(rgb: pa.pixels, width: pa.width, height: pa.height),
                            previewB: JoinImages.Half(rgb: pb.pixels, width: pb.width, height: pb.height), previewFactor: previewFactor)
        }
        if work == nil && !stop.isStopped { problem = String(localized: "Couldn't join the pages. Try scanning the halves again.") }
        return work
    }

    /// The halves joined at `placement` into one page in their place (one step of Undo); false (with `problem` set) when the
    /// joined page would be too large or the pages changed meanwhile.
    @discardableResult
    func join(_ work: JoinWork, at placement: JoinPlacement) async -> Bool {
        guard pages.page(work.first) != nil, pages.page(work.second) != nil, pages.number(work.second) == pages.number(work.first).map({ $0 + 1 }) else {
            problem = String(localized: "The pages changed while the join was open: choose Join with the Next Page… again.")
            return false
        }
        let made: (bytes: [UInt8]?, tooLarge: Bool) = await offPool {
            guard let joined = HalvesJoin.join(work.a.rgb, work.a.width, work.a.height, work.b.rgb, work.b.width, work.b.height, channels: 3, placement) else {
                return (nil, true)
            }
            return (try? JoinImages.jpeg(joined.pixels, width: joined.width, height: joined.height), false)
        }
        guard let bytes = made.bytes else {
            problem = made.tooLarge ? String(localized: "The joined page would be too large: move the second half closer.")
                : String(localized: "Couldn't join the pages. Try scanning the halves again.")
            return false
        }
        let (n1, n2) = (pages.number(work.first) ?? 1, pages.number(work.second) ?? 2)
        let id = ScanRecoveryStore.newPageName()
        images[id] = bytes
        var page = ScannedPage(id: id, dpi: work.dpi, analysed: true, ocrLanguage: pages.page(work.first)?.ocrLanguage)
        page.oneBit = pages.page(work.first)?.oneBit ?? false
        guard let done = pages.join(work.first, work.second, into: page) else { return false }
        savedParts.clear()
        problem = nil
        keep()
        refreshThumbnail(id)
        recordUndo(String(localized: "Join pages \(n1) and \(n2)")) { model in
            model.pages.unjoin(id, halves: done.halves, at: done.at)
            model.thumbnails[id] = nil
            return done.halves.map(\.id)
        }
        status = String(localized: "Pages \(n1) and \(n2) joined into one.")
        return true
    }

    /// The longest side of the join sheet's preview, about (pixels).
    nonisolated static let joinPreviewSide = 900

    /// A small copy of the halves joined at `placement`, for the join sheet's preview (at most about `joinPreviewSide` pixels
    /// a side). Only the small copies made once (`JoinWork.previewA`, `previewB`) are joined: a nudge costs a moment.
    nonisolated static func joinPreview(_ work: JoinWork, _ placement: JoinPlacement) -> CGImage? {
        let (a, b) = (work.previewA, work.previewB)
        let at = HalvesJoin.toCopy(placement, factor: work.previewFactor, secondWidth: work.b.width, secondHeight: work.b.height)
        guard let joined = HalvesJoin.join(a.rgb, a.width, a.height, b.rgb, b.width, b.height, channels: 3, at) else { return nil }
        return try? JoinImages.picture(joined.pixels, width: joined.width, height: joined.height)
    }
}
