import Foundation

/// One scanned page in the review: its JPEG in the run folder (`id` is the file's name), what's been done to it, and whether
/// it's left out of the file.
public struct ScannedPage: Equatable, Sendable, Identifiable {
    public var id: String
    public var dpi: Int
    public var edits: PageEdits
    /// Left out of the file (found blank, or the user chose so); listed, dimmed, with Keep.
    public var skipped: Bool
    /// The page check found it blank (with or without Skip blank pages on).
    public var looksBlank: Bool
    /// The page check ran (blank and skew); until then it shows as scanned.
    public var analysed: Bool
    /// A batch's separator sheet (a patch code, a blank page, marked by hand, or the back of a patch sheet): a new file
    /// starts after it, and it's left out unless the batch keeps separators.
    public var separator: SeparatorFound
    /// The user started a new file at this page.
    public var startsFile: Bool
    /// The photos found on the glass (each saved as a picture of its own); nil when they weren't looked for, empty when none
    /// was found (the whole scan is saved).
    public var photos: [PhotoBox]?
    /// The OCR language the page was scanned with (a BCP-47 tag); nil: the app's own choice.
    public var ocrLanguage: String?
    /// The page's edits from before the scan's clean up changed them (the Windows app's `BeforeCleanup`); nil when it didn't.
    public var beforeCleanup: PageEdits?
    /// The scan's crop to the paper was tried on the page and found no edge, so it stays whole.
    public var noPaperEdge = false

    public init(id: String, dpi: Int, edits: PageEdits = .none, skipped: Bool = false, looksBlank: Bool = false, analysed: Bool = false,
                separator: SeparatorFound = .none, startsFile: Bool = false, photos: [PhotoBox]? = nil, ocrLanguage: String? = nil) {
        self.ocrLanguage = ocrLanguage
        self.id = id
        self.dpi = dpi
        self.edits = edits
        self.skipped = skipped
        self.looksBlank = looksBlank
        self.analysed = analysed
        self.separator = separator
        self.startsFile = startsFile
        self.photos = photos
    }

    public var isSeparator: Bool { separator.isSeparator }

    /// Each photo is saved by itself.
    public var hasPhotos: Bool { !(photos?.isEmpty ?? true) }

    /// What happened to the page, under its number: "Straightened", "Edited", "Blank, not saved", what it was cleaned up
    /// with, or nothing.
    public var note: String {
        if isSeparator { return "Separator: \(separator.description)" }
        if hasPhotos {
            let count = photos!.count == 1 ? "1 photo" : "\(photos!.count) photos"
            return edits.filters.isEmpty ? count : "\(count), \(PageCleanup.describe(edits.filters))"
        }
        if skipped { return looksBlank ? "Blank, not saved" : "Not saved" }
        if !edits.filters.isEmpty {
            let done = PageCleanup.describe(edits.filters)
            return done.prefix(1).uppercased() + done.dropFirst()
        }
        if edits.deskew != 0 && edits.crop == nil && edits.quarterTurns % 4 == 0 { return "Straightened" }
        return edits.isEmpty ? "" : "Edited"
    }
}

/// The scan review's pages (the Windows app's Scan tab list): pages join as they're scanned, the page check skips blank ones
/// and straightens crooked ones (each when it's on), and the user turns, crops, deletes, reorders and keeps pages before
/// saving. A value: the app keeps one per scanner and saves it to the recovery folder as it changes.
public struct ScanPages: Equatable, Sendable {
    public private(set) var pages: [ScannedPage] = []
    /// The batch keeps its separator sheets (as the first page of the file each starts): the setting it was scanned with.
    public var keepSeparators = false

    public init(_ pages: [ScannedPage] = []) { self.pages = pages }

    public var isEmpty: Bool { pages.isEmpty }

    /// The files the pages are saved as (`BatchSplit`): one unless separators or new-file marks split them.
    public var files: [[ScannedPage]] {
        BatchSplit.parts(pages.map { BatchPage(separator: $0.isSeparator, startsFile: $0.startsFile, skipped: $0.skipped) },
                         keepSeparators: keepSeparators).map { part in part.map { pages[$0] } }
    }

    /// The pages that are saved, in order (every file's).
    public var toSave: [ScannedPage] { files.flatMap { $0 } }

    /// The file (1-based) the page starts, when there's more than one file; 0 for every other page.
    public func fileStart(_ id: String) -> Int {
        let parts = files
        guard parts.count > 1 else { return 0 }
        return parts.firstIndex { $0.first?.id == id }.map { $0 + 1 } ?? 0
    }

    public func page(_ id: String) -> ScannedPage? { pages.first { $0.id == id } }

    public func number(_ id: String) -> Int? { pages.firstIndex { $0.id == id }.map { $0 + 1 } }

    public mutating func add(_ page: ScannedPage) { pages.append(page) }

    /// The page check's answer for a page (on a downscaled grey copy): blank pages are skipped when `skipBlank`, a crooked page
    /// is straightened when `straighten` and it hasn't been edited meanwhile. A blank page isn't straightened.
    /// A separator sheet is neither skipped nor straightened, nor is a page of photos straightened (each photo is cut out
    /// straight by itself).
    ///
    /// `cleanup` (the scan's or preset's) then goes on a page that isn't blank or a separator (`PageEdits.cleanedUp`).
    /// `paperEdge` is `PaperEdge.find` on the analysis copy straightened by `skew`, which the caller runs only when
    /// `wantsPaperEdge` says; it crops only a page straightened by `skew`. Returns the page's edits from before the clean
    /// up, for Undo; nil when it got none.
    @discardableResult
    public mutating func analysed(_ id: String, looksBlank: Bool, skew: Double, skipBlank: Bool, straighten: Bool,
                                  separator: SeparatorFound = .none, photos: [PhotoBox]? = nil, cleanup: PageFilters = [],
                                  paperEdge: CropBox? = nil) -> PageEdits? {
        update(id) { p in
            p.analysed = true
            p.beforeCleanup = nil
            p.noPaperEdge = false
            p.looksBlank = looksBlank || separator.kind == .blankPage
            p.separator = separator
            p.photos = photos
            let blank = skipBlank && p.looksBlank && !separator.isSeparator
            if blank { p.skipped = true }
            if straighten && !blank && !separator.isSeparator && !p.hasPhotos && skew != 0 && p.edits.isEmpty { p.edits = PageEdits(deskew: skew) }
            guard !cleanup.isEmpty, !p.looksBlank, !separator.isSeparator else { return }
            // Tried only on a page with no filters or crop yet (`cleanedUp`) whose photos weren't looked for.
            p.noPaperEdge = cleanup.contains(.cropToPaper) && photos == nil && paperEdge == nil && p.edits.filters.isEmpty && p.edits.crop == nil
            guard let cleaned = p.edits.cleanedUp(cleanup, photos: p.hasPhotos, paperEdge: photos == nil ? paperEdge : nil, measuredAt: skew) else { return }
            p.beforeCleanup = p.edits
            p.edits = cleaned
        }
        return page(id)?.beforeCleanup
    }

    /// Whether the page check should look for the paper's edge (`PaperEdge.find`) on a page it found so: only for a crop to
    /// the paper, on a page that isn't blank or a separator and whose photos weren't looked for.
    public static func wantsPaperEdge(_ cleanup: PageFilters, looksBlank: Bool, separator: SeparatorFound, photos: [PhotoBox]?) -> Bool {
        cleanup.contains(.cropToPaper) && !looksBlank && separator.kind != .blankPage && !separator.isSeparator && photos == nil
    }

    /// What a scan cleaned up by its settings says once its pages `ids` are checked: how many pages its clean up changed (one
    /// step of Undo; not those given filters or a crop by hand first), and how many a crop to the paper was tried on and found no edge
    /// (`noPaperEdge`: they stay whole). Empty for nothing.
    public func cleanupSummary(_ ids: [String], _ cleanup: PageFilters) -> String {
        if cleanup.isEmpty { return "" }
        let run = inOrder(ids)
        let changed = run.filter { $0.beforeCleanup != nil }.count
        let noEdge = cleanup.contains(.cropToPaper) ? run.filter(\.noPaperEdge).count : 0
        var parts: [String] = []
        if changed > 0 { parts.append(changed == 1 ? "1 page was cleaned up (Undo puts it back)." : "\(changed) pages were cleaned up (Undo puts them back).") }
        if noEdge > 0 { parts.append("The paper's edge couldn't be told from the lid on \(noEdge) \(noEdge == 1 ? "page" : "pages"): kept whole.") }
        return parts.joined(separator: " ")
    }

    /// A two-sided batch: the other side of each patch code sheet among `ids` (one run's pages, in order) belongs to the
    /// sheet (`BatchSplit.duplexSeparatorBacks`), so it neither starts the next file nor ends up in it.
    public mutating func separatorBacks(_ ids: [String]) {
        let run = inOrder(ids)
        let backs = BatchSplit.duplexSeparatorBacks(patch: run.map { $0.separator.kind == .patchCode }, blank: run.map(\.looksBlank))
        for i in backs where !run[i].isSeparator {
            update(run[i].id) { p in
                p.skipped = false
                p.separator = SeparatorFound(.sheetBack)
                p.edits = .none // not straightened: it isn't saved (unless separators are kept)
            }
        }
    }

    /// Start a new file here, or don't (not on a separator, which starts one anyway).
    public mutating func toggleStartsFile(_ id: String) {
        update(id) { p in if !p.isSeparator { p.startsFile.toggle() } }
    }

    /// Not a separator: the page is saved like the others.
    public mutating func notSeparator(_ id: String) { update(id) { $0.separator = .none } }

    /// Use as a separator sheet: a new file starts after it.
    public mutating func useAsSeparator(_ id: String) {
        update(id) { p in
            p.startsFile = false
            p.skipped = false
            p.separator = SeparatorFound(.byHand)
        }
    }

    /// Each page's file number where a file starts (only when there's more than one file), for the whole list at once.
    public var fileStarts: [String: Int] {
        let parts = files
        guard parts.count > 1 else { return [:] }
        var starts: [String: Int] = [:]
        for (i, part) in parts.enumerated() { if let first = part.first { starts[first.id] = i + 1 } }
        return starts
    }

    /// The photos on a page, as the user changed them (empty: save the whole scan).
    public mutating func setPhotos(_ id: String, _ photos: [PhotoBox]) { update(id) { $0.photos = photos } }

    /// Turns a page `quarters` quarter turns clockwise (negative: anticlockwise).
    public mutating func turn(_ id: String, _ quarters: Int) {
        update(id) { p in
            // A page of photos turns every photo (the page itself is never saved).
            if let photos = p.photos, !photos.isEmpty {
                p.photos = photos.map { b in var t = b; t.quarterTurns = ((b.quarterTurns + quarters) % 4 + 4) % 4; return t }
            } else {
                p.edits = p.edits.turned(quarters)
            }
        }
    }

    /// Sets the crop from a box drawn on the page as shown (turned); nil or the whole page: no crop.
    public mutating func crop(_ id: String, shown: CropBox?) { update(id) { $0.edits = $0.edits.withShownCrop(shown) } }

    /// Undoes every edit, the straightening too.
    public mutating func reset(_ id: String) { update(id) { $0.edits = .none } }

    public mutating func keep(_ id: String) { update(id) { $0.skipped = false } }

    public mutating func skip(_ id: String) { update(id) { $0.skipped = true } }

    public mutating func delete(_ id: String) { pages.removeAll { $0.id == id } }

    /// Moves a page to `index` (in the list as it is after the page is taken out), clamped to the list.
    public mutating func move(_ id: String, to index: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: min(max(index, 0), pages.count))
    }

    /// "3 pages", "3 pages, 1 not saved", "1 page", "5 pages in 2 files, 1 separator left out", "1 page (3 photos)".
    public var summary: String {
        if pages.isEmpty { return "No pages yet" }
        var all = pages.count == 1 ? "1 page" : "\(pages.count) pages"
        let parts = files
        if parts.count > 1 { all += " in \(parts.count) files" }
        let photos = parts.joined().reduce(0) { $0 + ($1.hasPhotos ? $1.photos!.count : 0) }
        if photos > 0 { all += photos == 1 ? " (1 photo)" : " (\(photos) photos)" }
        let separators = keepSeparators ? 0 : pages.filter(\.isSeparator).count
        let left = pages.filter { $0.skipped && !$0.isSeparator }.count
        var notes: [String] = []
        if separators > 0 { notes.append(separators == 1 ? "1 separator left out" : "\(separators) separators left out") }
        if left > 0 { notes.append("\(left) not saved") }
        return ([all] + notes).joined(separator: ", ")
    }

    // MARK: Crash recovery

    /// What the recovery folder keeps of these pages (`ScanRecoveryStore.keep`).
    public func kept(printerId: String, printerName: String, ocr: Bool, now: Date) -> KeptScan {
        KeptScan(printerId: printerId, printerName: printerName, savedUtc: now, pages: pages.map { p in
            var k = KeptPage(p.id, dpi: p.dpi, ocr: ocr, quarterTurns: p.edits.quarterTurns, deskew: p.edits.deskew, crop: p.edits.crop,
                             skipped: p.skipped, startsFile: p.startsFile)
            k.photos = p.photos
            k.separator = p.isSeparator ? p.separator : nil
            k.looksBlank = p.looksBlank
            k.filters = p.edits.filters.isEmpty ? nil : p.edits.filters
            k.ocrLanguage = p.ocrLanguage
            return k
        })
    }

    /// The pages a scan left over (the app quit or crashed before they were saved), as they were.
    public init(restoring scan: KeptScan) {
        pages = scan.pages.map { k in
            ScannedPage(id: k.file, dpi: k.dpi, edits: k.edits, skipped: k.skipped, looksBlank: k.looksBlank ?? k.skipped, analysed: true,
                        separator: k.separator ?? .none, startsFile: k.startsFile, photos: k.photos, ocrLanguage: k.ocrLanguage)
        }
    }

    /// The pages `ids` names, in that order (one look-up each, not a search of the list).
    private func inOrder(_ ids: [String]) -> [ScannedPage] {
        let byId = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    private mutating func update(_ id: String, _ change: (inout ScannedPage) -> Void) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        change(&pages[i])
    }
}
