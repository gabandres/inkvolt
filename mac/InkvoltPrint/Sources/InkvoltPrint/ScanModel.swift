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
        case .searchablePdf: "Searchable PDF (text recognised on this Mac)"
        case .jpeg: "JPEG images"
        }
    }
}

/// One printer's Scan tab (the Windows app's `ScanViewModel`, eSCL part): the settings its scanner offers, scanning page by
/// page, the review (turn, crop, straighten, skip blank pages, reorder, delete), and saving where the user picks. The pages
/// are kept in the recovery folder as they change, so a crash doesn't lose them.
@MainActor @Observable
final class ScanModel {
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

    private(set) var pages = ScanPages()
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var isScanning = false
    private(set) var isSaving = false
    /// What scanning or saving is doing, or what it did.
    private(set) var status = ""
    private(set) var problem: String?

    @ObservationIgnored private var images: [String: [UInt8]] = [:]
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
            loadError = "The scanner isn't available while the printer isn't connected."
            return
        }
        do {
            caps = try await scanner.capabilities()
            loadError = caps == nil ? "This printer's scanner didn't say what it can do." : nil
        } catch {
            loadError = "The scanner didn't answer. Check that the printer is on, then try again."
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
                              findPhotos: p.findPhotos && plan.request.source == .platen)
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
        status = source == .platen ? "Scanning…" : "Scanning from the feeder…"
        let request = ScanChoices.request(source, color, dpi, sizes.first { $0.key == sizeKey })
        var c = given ?? PageCheck(skipBlank: skipBlank, straighten: straighten, splitAt: splitAt, findPhotos: findPhotos)
        if source == .platen { c.splitAt = .none } else { c.findPhotos = false }
        let check = c, split = c.splitAt, photos = c.findPhotos
        let duplex = source == .adfDuplex
        if pages.isEmpty || split != .none { pages.keepSeparators = keepGiven ?? keepSeparators } // the batch's setting when it was scanned
        if app.isDemo { Demo.scanSetup.prepare(feederBatch: split != .none && source != .platen, photosOnGlass: photos) }
        let widthIn300ths = request.width ?? caps?.input(for: source)?.maxWidth
        scanning = Task {
            defer {
                isScanning = false
                scanning = nil
            }
            guard let scanner = await printer.scanner() else {
                problem = "The scanner isn't available while the printer isn't connected."
                status = ""
                return
            }
            var count = 0
            var added: [String] = []
            do {
                for try await jpeg in scanner.scan(request) {
                    count += 1
                    status = "Scanned \(count) \(count == 1 ? "page" : "pages")…"
                    added.append(await add(jpeg, dpi: Self.dpi(of: jpeg, asked: request.resolution, widthIn300ths: widthIn300ths), check: check))
                }
                // The page checks finish (blank pages skipped, separators found) before a preset saves.
                for _ in 0..<150 where pages.pages.contains(where: { !$0.analysed }) { try await Task.sleep(for: .milliseconds(100)) }
                if duplex { pages.separatorBacks(added) }
                keep()
                let found = notes(added, split: split, photos: photos, duplex: duplex)
                status = count == 0 ? "No pages came from the scanner." : ([pages.summary + (found.isEmpty ? "" : ".")] + found).joined(separator: " ")
                await finished?()
            } catch is CancellationError {
                status = "Scan stopped."
            } catch let e as ScanError {
                problem = e.description
                status = count > 0 ? pages.summary : ""
            } catch {
                problem = "The scan didn't finish: the scanner stopped answering."
                status = count > 0 ? pages.summary : ""
            }
        }
    }

    func stop() { scanning?.cancel() }

    /// The page's resolution: what was asked, unless its size says otherwise (a scanner that sent another one).
    static func dpi(of jpeg: [UInt8], asked: Int, widthIn300ths: Int?) -> Int {
        guard let width = widthIn300ths, width > 0, let pixels = ScanImaging.size(jpeg)?.width else { return asked }
        let measured = Int((Double(pixels) * 300 / Double(width)).rounded())
        return abs(measured - asked) <= max(asked / 30, 2) ? asked : measured
    }

    /// What the page check looks for.
    struct PageCheck: Sendable {
        var skipBlank: Bool
        var straighten: Bool
        var splitAt: SplitAt
        var findPhotos: Bool
    }

    /// What the page check found.
    private struct Checked: Sendable {
        var looksBlank: Bool
        var skew: Double
        var separator: SeparatorFound
        var photos: [PhotoBox]?
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
        return Checked(looksBlank: looksBlank, skew: skew, separator: separator, photos: photos)
    }

    @discardableResult
    private func add(_ jpeg: [UInt8], dpi: Int, check c: PageCheck) async -> String {
        let id = ScanRecoveryStore.newPageName()
        images[id] = jpeg
        pages.add(ScannedPage(id: id, dpi: dpi))
        keep()
        refreshThumbnail(id)
        // The page check runs beside the next page's scan.
        Task {
            let result: Checked? = await offPool { Self.check(jpeg, dpi: dpi, c) }
            guard let result, pages.page(id) != nil else {
                pages.analysed(id, looksBlank: false, skew: 0, skipBlank: false, straighten: false) // the page stays as scanned
                return
            }
            pages.analysed(id, looksBlank: result.looksBlank, skew: result.skew, skipBlank: c.skipBlank, straighten: c.straighten,
                           separator: result.separator, photos: result.photos)
            keep()
            refreshThumbnail(id)
            if !isScanning { status = pages.summary }
        }
        return id
    }

    /// What a scan found, after the page summary (the Windows app's notes).
    private func notes(_ added: [String], split: SplitAt, photos: Bool, duplex: Bool) -> [String] {
        let run = added.compactMap { pages.page($0) }
        guard !run.isEmpty else { return [] }
        var notes: [String] = []
        let found = run.reduce(0) { $0 + ($1.photos?.count ?? 0) }
        if photos {
            notes.append(found == 0 ? "No photos were found on the glass: the whole scan is saved."
                : "\(found == 1 ? "1 photo" : "\(found) photos") found, each saved as its own picture.")
        }
        let separators = run.filter { $0.isSeparator && $0.separator.kind != .sheetBack }.count
        if split != .none {
            let files = pages.files.count
            notes.append(separators == 0 ? "No separator sheets were found: it's one file."
                : "\(separators == 1 ? "1 separator sheet" : "\(separators) separator sheets") found: \(files == 1 ? "1 file" : "\(files) files").")
            if duplex && (split == .blankPage || split == .patchCodeOrBlankPage) {
                notes.append("Scanning both sides: a blank back starts a new file too, so patch code sheets suit two-sided batches better.")
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
        guard let jpeg = images[id], let page = pages.page(id) else { return }
        let dpi = page.dpi
        let found: [PhotoBox]? = await offPool {
            guard let gray = try? ScanImaging.analysis(jpeg) else { return nil }
            let ppi = Double(gray.width) * Double(dpi) / Double(max(ScanImaging.size(jpeg)?.width ?? gray.width, 1))
            return PhotoFinder.find(gray, pixelsPerInch: ppi)
        }
        if let found { setPhotos(id, found) }
    }
    func crop(_ id: String, shown: CropBox?) { change(id) { $0.crop(id, shown: shown) } }
    func reset(_ id: String) { change(id) { $0.reset(id) } }
    func keepPage(_ id: String) { change(id) { $0.keep(id) } }
    func skipPage(_ id: String) { change(id) { $0.skip(id) } }

    func delete(_ id: String) {
        savedParts.clear()
        pages.delete(id)
        images[id] = nil
        thumbnails[id] = nil
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
        thumbnails = [:]
        problem = nil
        status = ""
        app.scanStore?.forget(printer.id)
    }

    /// The page with its edits, for the crop view.
    func image(_ id: String, maxPixels: Int = 1600) async -> NSImage? {
        guard let jpeg = images[id], let page = pages.page(id) else { return nil }
        let edits = PageEdits(quarterTurns: page.edits.quarterTurns, deskew: page.edits.deskew) // the crop is what's drawn on it
        let image: CGImage? = await offPool { try? ScanImaging.render(jpeg, edits, maxPixels: maxPixels) }
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
        guard let jpeg = images[id], let edits = pages.page(id)?.edits else { return }
        Task {
            let image: CGImage? = await offPool { try? ScanImaging.render(jpeg, edits, maxPixels: 520) }
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
        guard let jpeg = images[id], let edits = pages.page(id)?.edits else { return nil }
        return await offPool { (try? ScanImaging.analysis(ScanImaging.jpeg(jpeg, edits))).map(Deskew.angle) }
    }

    // MARK: Printing (copy)

    /// The kept pages through the print panel, on this printer's queue: a copy.
    func printPages() async {
        guard !pages.toSave.isEmpty, !isSaving else { return }
        isSaving = true
        status = "Preparing the copy…"
        let jobs = jobs(pages.files)
        let data: Data? = await offPool {
            try? ScanPdf.write(Self.render(jobs).joined().map { ScanPdf.Page(jpeg: $0.jpeg, dpi: $0.dpi) })
        }
        isSaving = false
        status = pages.summary
        guard let data, let document = PDFDocument(data: data) else {
            problem = "The pages couldn't be prepared for printing."
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
    }

    /// An image a file holds: a page as edited, or one photo cut out (no text recognition for photos).
    private struct OutputImage: Sendable {
        var jpeg: [UInt8]
        var dpi: Int
        var isPhoto: Bool
    }

    private func jobs(_ files: [[ScannedPage]]) -> [[PageJob]] {
        files.map { file in file.map { PageJob(jpeg: images[$0.id] ?? [], edits: $0.edits, dpi: $0.dpi, photos: $0.hasPhotos ? $0.photos : nil) } }
    }

    nonisolated private static func render(_ jobs: [[PageJob]]) throws -> [[OutputImage]] {
        try jobs.map { file in
            try file.flatMap { job -> [OutputImage] in
                if let photos = job.photos { return try photos.map { OutputImage(jpeg: try ScanImaging.photo(job.jpeg, $0), dpi: job.dpi, isPhoto: true) } }
                return [OutputImage(jpeg: try ScanImaging.jpeg(job.jpeg, job.edits), dpi: job.dpi, isPhoto: false)]
            }
        }
    }

    /// The images each file holds: one per page, or one per photo.
    var imagesPerFile: [Int] { pages.files.map { file in file.reduce(0) { $0 + ($1.hasPhotos ? $1.photos!.count : 1) } } }

    /// Saving makes more than one file (a batch, or several images): the save panel asks for a folder.
    var savesSeveralFiles: Bool { format == .jpeg ? imagesPerFile.reduce(0, +) > 1 : imagesPerFile.count > 1 }

    /// Writes `files` (each a PDF at `targets[f][0]`, or its images at `targets[f]`), every file's images rendered first.
    nonisolated private static func write(_ jobs: [[PageJob]], to targets: [[URL]], format: ScanFormat) throws -> [URL] {
        let files = try render(jobs)
        var written: [URL] = []
        for (file, urls) in zip(files, targets) {
            switch format {
            case .pdf, .searchablePdf:
                let pdfPages = file.map { ScanPdf.Page(jpeg: $0.jpeg, dpi: $0.dpi, words: format == .searchablePdf && !$0.isPhoto ? ScanPdf.recognize($0.jpeg) : nil) }
                try ScanPdf.write(pdfPages, title: urls[0].deletingPathExtension().lastPathComponent).write(to: urls[0], options: .atomic)
                written.append(urls[0])
            case .jpeg:
                for (image, url) in zip(file, urls) {
                    try Data(image.jpeg).write(to: url, options: urls.count == 1 && files.count == 1 ? .atomic : .withoutOverwriting)
                    written.append(url)
                }
            }
        }
        return written
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
            panel.prompt = "Use This Folder"
            panel.message = "Choose where \"\(p.name)\" saves its scans (a folder in iCloud Drive or another synced folder works too). Inkvolt Print remembers it."
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
        status = format == .searchablePdf ? "Recognising text…" : "Saving…"
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
            let result: Result<[URL], any Error> = await offPool {
                Result {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let count = format == .jpeg ? counts[f] : 1
                    let paths = try FileNameTemplate.uniquePaths(dir.path, stem, ext, count: count) { FileManager.default.fileExists(atPath: $0) }
                    return try Self.write(job, to: [paths.map { URL(fileURLWithPath: $0) }], format: format)
                }
            }
            guard case .success(let urls) = result else {
                isSaving = false
                let part = files.count > 1 ? " (file \(f + 1) of \(files.count); Save again writes the rest)" : ""
                problem = "The scan couldn't be saved in \(folder.lastPathComponent)\(part). Check the folder is still there, or choose another in Manage Presets."
                status = pages.summary
                return
            }
            savedParts.add(ids, paths: urls.map(\.path))
            all += urls
        }
        isSaving = false
        await finishSaving(all, in: folder.lastPathComponent, reveal: p.after == .none)
        await after(p.after, all)
    }

    /// The preset's step after saving: print a copy of what was saved on this printer, or attach it to a new email in the
    /// user's mail app (Inkvolt Print has no mail account of its own). "Open in Inkvolt PDF" waits for a Mac Inkvolt PDF.
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
                problem = "No mail app is set up on this Mac to attach the scan to. The scan is saved."
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return
            }
            service.subject = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Scans"
            service.perform(withItems: urls)
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
        status = format == .searchablePdf ? "Recognising text…" : "Saving…"
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let targets: [[URL]]
        do {
            targets = url.hasDirectoryPath ? try self.targets(in: url, stem: FileNameTemplate.sanitize(suggestedName)) : [[url]]
        } catch {
            isSaving = false
            problem = "There are too many scans with that name in \(url.lastPathComponent). Choose another folder."
            return
        }
        let job = jobs(pages.files)
        let result: Result<[URL], any Error> = await offPool { Result { try Self.write(job, to: targets, format: format) } }
        isSaving = false
        switch result {
        case .success(let urls):
            await finishSaving(urls, in: url.lastPathComponent, reveal: reveal)
        case .failure:
            problem = "The scan couldn't be saved there. Choose another place, or check there's room on the disk."
            status = pages.summary
        }
    }

    private func finishSaving(_ urls: [URL], in place: String, reveal: Bool) async {
        let saved = pages.toSave.count == 1 ? "1 page" : "\(pages.toSave.count) pages"
        let files = urls.count > 1 ? " as \(urls.count) files" : ""
        clear()
        status = "Saved \(saved)\(files) to \(urls.count == 1 ? urls[0].lastPathComponent : place)."
        if reveal { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}
