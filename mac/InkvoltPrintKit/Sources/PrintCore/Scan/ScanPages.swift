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

    public init(id: String, dpi: Int, edits: PageEdits = .none, skipped: Bool = false, looksBlank: Bool = false, analysed: Bool = false) {
        self.id = id
        self.dpi = dpi
        self.edits = edits
        self.skipped = skipped
        self.looksBlank = looksBlank
        self.analysed = analysed
    }

    /// What happened to the page, under its number: "Straightened", "Edited", "Blank, not saved", or nothing.
    public var note: String {
        if skipped { return looksBlank ? "Blank, not saved" : "Not saved" }
        if edits.deskew != 0 && edits.crop == nil && edits.quarterTurns % 4 == 0 { return "Straightened" }
        return edits.isEmpty ? "" : "Edited"
    }
}

/// The scan review's pages (the Windows app's Scan tab list): pages join as they're scanned, the page check skips blank ones
/// and straightens crooked ones (each when it's on), and the user turns, crops, deletes, reorders and keeps pages before
/// saving. A value: the app keeps one per scanner and saves it to the recovery folder as it changes.
public struct ScanPages: Equatable, Sendable {
    public private(set) var pages: [ScannedPage] = []

    public init(_ pages: [ScannedPage] = []) { self.pages = pages }

    public var isEmpty: Bool { pages.isEmpty }

    /// The pages that go into the file, in order.
    public var toSave: [ScannedPage] { pages.filter { !$0.skipped } }

    public func page(_ id: String) -> ScannedPage? { pages.first { $0.id == id } }

    public func number(_ id: String) -> Int? { pages.firstIndex { $0.id == id }.map { $0 + 1 } }

    public mutating func add(_ page: ScannedPage) { pages.append(page) }

    /// The page check's answer for a page (on a downscaled grey copy): blank pages are skipped when `skipBlank`, a crooked page
    /// is straightened when `straighten` and it hasn't been edited meanwhile. A blank page isn't straightened.
    public mutating func analysed(_ id: String, looksBlank: Bool, skew: Double, skipBlank: Bool, straighten: Bool) {
        update(id) { p in
            p.analysed = true
            p.looksBlank = looksBlank
            if skipBlank && looksBlank { p.skipped = true }
            if straighten && !(skipBlank && looksBlank) && skew != 0 && p.edits.isEmpty { p.edits = PageEdits(deskew: skew) }
        }
    }

    /// Turns a page `quarters` quarter turns clockwise (negative: anticlockwise).
    public mutating func turn(_ id: String, _ quarters: Int) { update(id) { $0.edits = $0.edits.turned(quarters) } }

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

    /// "3 pages", "3 pages, 1 not saved", "1 page".
    public var summary: String {
        if pages.isEmpty { return "No pages yet" }
        let all = pages.count == 1 ? "1 page" : "\(pages.count) pages"
        let left = pages.count - toSave.count
        return left == 0 ? all : "\(all), \(left) not saved"
    }

    // MARK: Crash recovery

    /// What the recovery folder keeps of these pages (`ScanRecoveryStore.keep`).
    public func kept(printerId: String, printerName: String, ocr: Bool, now: Date) -> KeptScan {
        KeptScan(printerId: printerId, printerName: printerName, savedUtc: now, pages: pages.map { p in
            KeptPage(p.id, dpi: p.dpi, ocr: ocr, quarterTurns: p.edits.quarterTurns, deskew: p.edits.deskew, crop: p.edits.crop, skipped: p.skipped)
        })
    }

    /// The pages a scan left over (the app quit or crashed before they were saved), as they were.
    public init(restoring scan: KeptScan) {
        pages = scan.pages.map { k in
            ScannedPage(id: k.file, dpi: k.dpi, edits: k.edits, skipped: k.skipped, looksBlank: k.skipped, analysed: true)
        }
    }

    private mutating func update(_ id: String, _ change: (inout ScannedPage) -> Void) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        change(&pages[i])
    }
}
