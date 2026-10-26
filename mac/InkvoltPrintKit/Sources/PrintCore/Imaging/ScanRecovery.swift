import Foundation

/// A scanned page kept on disk: the scanner's JPEG (`file`, in the scan's folder), its resolution, whether it gets OCR when
/// saved, and what the review did to it.
public struct KeptPage: Equatable, Sendable, Codable {
    public var file: String
    public var dpi: Int
    public var ocr: Bool
    public var quarterTurns = 0
    public var deskew = 0.0
    public var crop: CropBox?
    public var skipped = false
    public var startsFile = false
    /// Mac only (the Windows app's recovery list has none of them): the photos found on the glass, the page as a batch's
    /// separator, and whether it looked blank. Missing in an older list: none, not one, and as `skipped` says.
    public var photos: [PhotoBox]?
    public var separator: SeparatorFound?
    public var looksBlank: Bool?

    public init(_ file: String, dpi: Int, ocr: Bool, quarterTurns: Int = 0, deskew: Double = 0, crop: CropBox? = nil, skipped: Bool = false,
                startsFile: Bool = false) {
        self.file = file
        self.dpi = dpi
        self.ocr = ocr
        self.quarterTurns = quarterTurns
        self.deskew = deskew
        self.crop = crop
        self.skipped = skipped
        self.startsFile = startsFile
    }

    public var edits: PageEdits { PageEdits(quarterTurns: quarterTurns, deskew: deskew, crop: crop) }
}

/// One printer's unsaved scan: its pages in order.
public struct KeptScan: Equatable, Sendable, Codable {
    public var printerId: String
    public var printerName: String
    public var savedUtc: Date
    public var pages: [KeptPage]

    public init(printerId: String, printerName: String, savedUtc: Date, pages: [KeptPage]) {
        self.printerId = printerId
        self.printerName = printerName
        self.savedUtc = savedUtc
        self.pages = pages
    }
}

/// A scan a run left unsaved, in `folder`.
public struct LeftOverScan: Equatable, Sendable {
    public var folder: String
    public var listPath: String
    public var scan: KeptScan

    public func pagePath(_ page: KeptPage) -> String { (folder as NSString).appendingPathComponent(page.file) }
}

/// Unsaved scans kept on disk while Inkvolt Print runs, so a crash, a killed process or the Mac shutting down doesn't lose
/// them: each printer's page list beside the scanner's JPEGs, in this run's `RunFolder`. Pages are written once (a scanned
/// page never changes; the review's edits are in the list), the list each time it changes; pages no list names any more are
/// deleted. A clean exit removes the folder.
public final class ScanRecoveryStore: @unchecked Sendable {
    private let run: RunFolder
    private let gate = NSLock()
    private var ended = false

    private init(_ run: RunFolder) { self.run = run }

    public static func start(_ root: String) throws -> ScanRecoveryStore { ScanRecoveryStore(try RunFolder.start(root)) }

    /// A file name for a page not kept yet.
    public static func newPageName() -> String { "page-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).jpg" }

    /// Writes a scanned page under `name` (`newPageName`), for `KeptPage.file`.
    public func keepPage(_ name: String, _ jpeg: [UInt8]) throws {
        try gate.withLock {
            if !ended { try RunFolder.writeAtomic(path(name), jpeg) }
        }
    }

    /// Writes a scanned page and returns its file name.
    public func keepPage(_ jpeg: [UInt8]) throws -> String {
        let name = Self.newPageName()
        try keepPage(name, jpeg)
        return name
    }

    /// Writes (or replaces) a printer's page list, first writing each page it names that isn't on disk (new, or deleted with
    /// a scan saved and then changed again) from `jpeg` when given; then deletes the pages no list names.
    public func keep(_ scan: KeptScan, jpeg: ((String) -> [UInt8])? = nil) throws {
        try gate.withLock {
            if ended { return }
            if let jpeg {
                for page in scan.pages where !FileManager.default.fileExists(atPath: path(page.file)) {
                    try RunFolder.writeAtomic(path(page.file), jpeg(page.file))
                }
            }
            try RunFolder.writeAtomic(Self.listPath(run.path, scan.printerId), Array(try Self.encoder.encode(scan)))
            Self.deleteUnlisted(run.path)
        }
    }

    /// A printer's scan was saved or cleared: its list and pages go.
    public func forget(_ printerId: String) {
        gate.withLock {
            if ended { return }
            RunFolder.tryDelete(Self.listPath(run.path, printerId))
            Self.deleteUnlisted(run.path)
        }
    }

    /// Scans left by runs that ended without a clean exit: complete ones only (a list that can't be read, or names a missing
    /// page, is skipped).
    public static func findLeftOver(_ root: String) -> [LeftOverScan] {
        var found: [LeftOverScan] = []
        for folder in RunFolder.leftOver(root) {
            for list in lists(folder) {
                guard let data = FileManager.default.contents(atPath: list), let scan = try? decoder.decode(KeptScan.self, from: data),
                      !scan.pages.isEmpty, !scan.printerId.isEmpty,
                      scan.pages.allSatisfy({ !$0.file.isEmpty && !$0.file.contains("/") && !$0.file.contains("\\") && $0.file != ".."
                          && FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent($0.file)) }) else { continue }
                found.append(LeftOverScan(folder: folder, listPath: list, scan: scan))
            }
        }
        return found
    }

    /// Deletes a left-over scan (restored, or declined): its list and pages, and its folder with the last one.
    public static func remove(_ scan: LeftOverScan) {
        RunFolder.tryDelete(scan.listPath)
        deleteUnlisted(scan.folder)
        if RunFolder.isDirectory(scan.folder) && lists(scan.folder).isEmpty { RunFolder.delete(scan.folder) }
    }

    /// Deletes left-over folders with no scan to offer (a run that ended with everything saved).
    public static func discardEmpty(_ root: String) {
        for folder in RunFolder.leftOver(root) where lists(folder).isEmpty { RunFolder.delete(folder) }
    }

    /// Ends the run leaving the scans for the next start, as a crash would (the Mac shutting down, tests).
    public func keepForNextStart() {
        gate.withLock {
            ended = true
            run.abandon()
        }
    }

    /// A clean exit: every kept scan and the run's folder go.
    public func close() {
        gate.withLock {
            ended = true
            run.close()
        }
    }

    private func path(_ name: String) -> String { (run.path as NSString).appendingPathComponent(name) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The list's file name: the printer's id hashed, as ids hold characters file names can't.
    private static func listPath(_ folder: String, _ printerId: String) -> String {
        (folder as NSString).appendingPathComponent("scan-\(Digest.hex(Digest.sha256(Array(printerId.utf8))).prefix(16)).json")
    }

    private static func lists(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("scan-") && $0.hasSuffix(".json") }.sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    private static func deleteUnlisted(_ folder: String) {
        guard RunFolder.isDirectory(folder) else { return }
        var listed = Set<String>()
        for list in lists(folder) {
            // Can't tell what's still needed: keep every page.
            guard let data = FileManager.default.contents(atPath: list), let scan = try? decoder.decode(KeptScan.self, from: data) else { return }
            for page in scan.pages { listed.insert(page.file.lowercased()) }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        where name.hasPrefix("page-") && name.hasSuffix(".jpg") && !listed.contains(name.lowercased()) {
            RunFolder.tryDelete((folder as NSString).appendingPathComponent(name))
        }
    }
}
