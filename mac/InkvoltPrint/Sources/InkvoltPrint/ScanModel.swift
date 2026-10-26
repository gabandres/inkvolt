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

    private(set) var pages = ScanPages()
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var isScanning = false
    private(set) var isSaving = false
    /// What scanning or saving is doing, or what it did.
    private(set) var status = ""
    private(set) var problem: String?

    @ObservationIgnored private var images: [String: [UInt8]] = [:]
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
        skipBlank = p.skipBlank
        straighten = p.straighten
        preset = p
        let notes = plan.notes
        scan {
            if !notes.isEmpty { self.status = (notes + [self.status]).joined(separator: " ") }
            if !p.review && !self.pages.toSave.isEmpty && self.problem == nil { await self.saveWithPreset() }
        }
    }

    func scan(then finished: (@MainActor () async -> Void)? = nil) {
        guard !isScanning else { return }
        problem = nil
        isScanning = true
        status = source == .platen ? "Scanning…" : "Scanning from the feeder…"
        let request = ScanChoices.request(source, color, dpi, sizes.first { $0.key == sizeKey })
        let skip = skipBlank, straight = straighten
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
            do {
                for try await jpeg in scanner.scan(request) {
                    count += 1
                    status = "Scanned \(count) \(count == 1 ? "page" : "pages")…"
                    await add(jpeg, dpi: Self.dpi(of: jpeg, asked: request.resolution, widthIn300ths: widthIn300ths), skipBlank: skip, straighten: straight)
                }
                status = count == 0 ? "No pages came from the scanner." : pages.summary
                // The page checks finish (blank pages skipped) before a preset saves.
                for _ in 0..<100 where pages.pages.contains(where: { !$0.analysed }) { try await Task.sleep(for: .milliseconds(100)) }
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

    private func add(_ jpeg: [UInt8], dpi: Int, skipBlank: Bool, straighten: Bool) async {
        let id = ScanRecoveryStore.newPageName()
        images[id] = jpeg
        pages.add(ScannedPage(id: id, dpi: dpi))
        keep()
        refreshThumbnail(id)
        // The page check runs beside the next page's scan.
        Task {
            let result: (Bool, Double)? = await offPool {
                guard let gray = try? ScanImaging.analysis(jpeg) else { return nil }
                let blank = BlankPage.isBlank(gray)
                return (blank, straighten && !(skipBlank && blank) ? Deskew.angle(gray) : 0)
            }
            guard let (blank, skew) = result, pages.page(id) != nil else { return }
            pages.analysed(id, looksBlank: blank, skew: skew, skipBlank: skipBlank, straighten: straighten)
            keep()
            refreshThumbnail(id)
            if !isScanning { status = pages.summary }
        }
    }

    // MARK: Review

    func turn(_ id: String, _ quarters: Int) { change(id) { $0.turn(id, quarters) } }
    func crop(_ id: String, shown: CropBox?) { change(id) { $0.crop(id, shown: shown) } }
    func reset(_ id: String) { change(id) { $0.reset(id) } }
    func keepPage(_ id: String) { change(id) { $0.keep(id) } }
    func skipPage(_ id: String) { change(id) { $0.skip(id) } }

    func delete(_ id: String) {
        pages.delete(id)
        images[id] = nil
        thumbnails[id] = nil
        keep()
        status = pages.summary
    }

    func move(_ id: String, by offset: Int) {
        guard let n = pages.number(id) else { return }
        pages.move(id, to: n - 1 + offset)
        keep()
    }

    func move(_ id: String, to index: Int) {
        pages.move(id, to: index)
        keep()
    }

    /// Drops every page (after saving them, or when the user starts over).
    func clear() {
        preset = nil
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
        let list = pages.toSave
        guard !list.isEmpty, !isSaving else { return }
        isSaving = true
        status = "Preparing the copy…"
        let jpegs = list.map { (images[$0.id] ?? [], $0.edits, $0.dpi) }
        let data: Data? = await offPool {
            try? ScanPdf.write(jpegs.map { ScanPdf.Page(jpeg: (try? ScanImaging.jpeg($0.0, $0.1)) ?? $0.0, dpi: $0.2) })
        }
        isSaving = false
        status = pages.summary
        guard let data, let document = PDFDocument(data: data) else {
            problem = "The pages couldn't be prepared for printing."
            return
        }
        Printing.print(document, name: suggestedName, on: printer, app: app)
    }

    // MARK: Saving

    /// Saves the way the preset says: in its folder (asked for once, then remembered), its subfolder, its file name.
    func saveWithPreset() async {
        guard let p = preset else { return }
        var folder = app.presetFolder(p.id)
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use This Folder"
            panel.message = "Choose where \"\(p.name)\" saves its scans. Inkvolt Print remembers it."
            panel.directoryURL = FileManager.default.urls(for: p.folder == .pictures ? .picturesDirectory : .documentDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            app.setPresetFolder(p.id, url)
            folder = app.presetFolder(p.id) ?? url
        }
        guard let folder else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let ctx = NameContext(now: Date(), preset: p.name, printer: printer.name, number: app.reserveNumber(p.id), pages: pages.toSave.count)
        let stem = FileNameTemplate.fileName(p.fileName, ctx)
        let sub = FileNameTemplate.subfolder(p.subfolder, ctx)
        let dir = sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = format == .jpeg ? ".jpg" : ".pdf"
            let count = format == .jpeg ? pages.toSave.count : 1
            let paths = try FileNameTemplate.uniquePaths(dir.path, stem, ext, count: count) { FileManager.default.fileExists(atPath: $0) }
            await save(to: count == 1 ? URL(fileURLWithPath: paths[0]) : dir, names: paths.map { URL(fileURLWithPath: $0) })
        } catch {
            problem = "The scan couldn't be saved in \(folder.lastPathComponent). Check the folder is still there, or choose another in Manage Presets."
        }
    }

    /// The name the save panel suggests: "Scan 2026-10-26 14.30".
    var suggestedName: String {
        FileNameTemplate.fileName("Scan {date} {time}", NameContext(now: Date(), preset: "", printer: printer.name, number: 1, pages: pages.toSave.count))
    }

    /// Saves the pages that are kept to `url` (a PDF file, a JPEG file for one page, or a folder for several), then clears the
    /// review. Searchable PDFs get each page's text recognised first.
    func save(to url: URL, names: [URL]? = nil, reveal: Bool = true) async {
        let list = pages.toSave
        guard !list.isEmpty, !isSaving else { return }
        isSaving = true
        problem = nil
        defer { isSaving = false }
        let jpegs = list.map { (images[$0.id] ?? [], $0.edits, $0.dpi) }
        let format = format
        status = format == .searchablePdf ? "Recognising text…" : "Saving…"
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let result: Result<[URL], any Error> = await offPool {
            do {
                let pages = try jpegs.map { (jpeg, edits, dpi) in (try ScanImaging.jpeg(jpeg, edits), dpi) }
                switch format {
                case .pdf, .searchablePdf:
                    let pdfPages = pages.map { ScanPdf.Page(jpeg: $0.0, dpi: $0.1, words: format == .searchablePdf ? ScanPdf.recognize($0.0) : nil) }
                    try ScanPdf.write(pdfPages, title: url.deletingPathExtension().lastPathComponent).write(to: url, options: .atomic)
                    return .success([url])
                case .jpeg:
                    if pages.count == 1 && !url.hasDirectoryPath {
                        try Data(pages[0].0).write(to: url, options: .atomic)
                        return .success([url])
                    }
                    let stem = FileNameTemplate.sanitize("Scan \(Date().formatted(.iso8601.year().month().day()))")
                    let paths = try names.map { $0.map(\.path) } ?? FileNameTemplate.uniquePaths(url.path, stem, ".jpg", count: pages.count) {
                        FileManager.default.fileExists(atPath: $0)
                    }
                    for (page, path) in zip(pages, paths) { try Data(page.0).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
                    return .success(paths.map { URL(fileURLWithPath: $0) })
                }
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success(let urls):
            let saved = list.count == 1 ? "1 page" : "\(list.count) pages"
            clear()
            status = "Saved \(saved) to \(urls.count == 1 ? urls[0].lastPathComponent : url.lastPathComponent)."
            if reveal { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case .failure:
            problem = "The scan couldn't be saved there. Choose another place, or check there's room on the disk."
            status = pages.summary
        }
    }
}
