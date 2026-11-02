import Foundation
import Synchronization

// Batch print (Print roadmap 2.4), the Windows app's `BatchPrint.cs`: the estimate, the bounds, the order and the run. What
// draws the pages and what takes the jobs are behind `BatchDocuments` and `BatchQueue` (PrintMac: PDFKit and the printer's
// CUPS queue; the tests: fakes).

/// The bounds of a batch, so one file or one list can't take the Mac or a ream of paper with it.
public enum BatchPrintLimits {
    /// Files in a list (a folder's files count one by one).
    public static let maxFiles = 2000
    /// Copies of one file, as Print a PDF allows.
    public static let maxCopies = 99
    /// Pages of one file: each page is drawn before anything is sent.
    public static let maxPages = 5000
    /// A file larger than this is read by nobody: it's held whole for the estimate.
    public static let maxFileBytes: Int64 = 2 << 30
    /// A picture larger than this is refused before its pixels are decoded (a small file can claim a huge size).
    public static let maxPicturePixels: Int64 = 250_000_000
    /// Tries at one file's password before it's left out.
    public static let maxPasswordTries = 3
    /// The window asks before sending a batch of more sheets than this.
    public static let confirmSheets = 100
    /// The command line and a watched folder stop short of more sheets than this in one run unless told otherwise.
    public static let defaultMaxSheets = 500

    /// Why a picture of this size won't be decoded, or nil.
    public static func pictureProblem(_ width: Int64, _ height: Int64) -> String? {
        if width <= 0 || height <= 0 { return "The picture is damaged: it has no size." }
        if width.multipliedReportingOverflow(by: height).overflow || width * height > maxPicturePixels {
            return "The picture is too large to print (\(FleetPage.grouped(Int(clamping: width))) × \(FleetPage.grouped(Int(clamping: height))) pixels)."
        }
        return nil
    }

    /// Why a file of this many pages won't be printed, or nil.
    public static func pagesProblem(_ pages: Int) -> String? {
        if pages <= 0 { return "The file has no pages." }
        if pages > maxPages {
            return "The file has \(FleetPage.grouped(pages)) pages: a batch takes at most \(FleetPage.grouped(maxPages)) per file. Print a PDF or split it first."
        }
        return nil
    }
}

/// How one file of a batch prints. `range` nil or empty: all its pages; `paper` nil: the printer's default paper.
public struct BatchPrintSettings: Equatable, Sendable {
    public var copies: Int
    public var range: String?
    public var twoSided: Bool
    public var paper: String?

    public init(copies: Int = 1, range: String? = nil, twoSided: Bool = false, paper: String? = nil) {
        self.copies = copies
        self.range = range
        self.twoSided = twoSided
        self.paper = paper
    }

    /// The sheets a job of this many pages takes: nothing else decides what the estimate says.
    public static func sheets(_ pages: Int, _ copies: Int, _ twoSided: Bool) -> Int {
        let perCopy = twoSided ? (Int64(pages) + 1) / 2 : Int64(pages)
        return Int(min(Int64(Int32.max), perCopy * Int64(copies)))
    }
}

/// A file's exact contents when it was looked at: the same fingerprint at print time means the estimate still holds.
public struct BatchFingerprint: Equatable, Sendable {
    public var length: Int64
    public var sha256: String
}

/// A file can't be printed, for a reason a person can read.
public struct BatchFileError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The PDF needs a password, or the one given doesn't open it.
public struct BatchPasswordError: Error, Sendable {
    public init() {}
}

/// The printer wouldn't take a setting (two-sided, the paper, the copies). Nothing was sent for this file; others may be fine.
public struct BatchSettingRefused: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The queue itself failed: the batch stops here. `mayHaveSent`: part of this file may have reached it, so it says to check
/// before sending it again.
public struct BatchQueueError: Error, Sendable {
    public var message: String
    public var mayHaveSent: Bool
    public init(_ message: String, mayHaveSent: Bool) {
        self.message = message
        self.mayHaveSent = mayHaveSent
    }
}

/// A file of a batch, read whole and fingerprinted when it's opened: what prints is those bytes, whatever happens to the file
/// afterwards. (Windows holds the file open so nobody can write it; macOS has no such lock, so the Mac keeps the bytes.) Only
/// files of a size the batch takes, never a link (it could point anywhere).
public struct BatchHeldFile: Sendable {
    public let path: String
    public let bytes: [UInt8]
    public let fingerprint: BatchFingerprint

    /// - Throws: `BatchFileError`: it's gone, unreadable, a link, empty or too large.
    public static func open(_ path: String) throws -> BatchHeldFile {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil { throw BatchFileError("This is a link to a file elsewhere: add the file itself.") }
        var isFolder: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { throw BatchFileError("This is a folder, not a file.") }
        let size: Int64
        do {
            size = (try manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw BatchFileError(BatchPrintText.describe(error))
        }
        if size > BatchPrintLimits.maxFileBytes { throw BatchFileError("The file is too large to print here (\(FleetPage.grouped(Int(size >> 20))) MB).") }
        let bytes: [UInt8]
        do {
            bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw BatchFileError(BatchPrintText.describe(error))
        }
        if bytes.isEmpty { throw BatchFileError("The file is empty.") }
        if Int64(bytes.count) > BatchPrintLimits.maxFileBytes { throw BatchFileError("The file is too large to print here.") }
        return BatchHeldFile(path: path, bytes: bytes, fingerprint: BatchFingerprint(length: Int64(bytes.count), sha256: Digest.hex(Digest.sha256(bytes), uppercase: true)))
    }
}

/// One page drawn for printing: a JPEG and its size in inches.
public struct BatchPrintPage: Sendable {
    public var jpeg: [UInt8]
    public var widthInches: Double
    public var heightInches: Double

    public init(_ jpeg: [UInt8], _ widthInches: Double, _ heightInches: Double) {
        self.jpeg = jpeg
        self.widthInches = widthInches
        self.heightInches = heightInches
    }
}

/// A file open for printing (its bytes held, `BatchHeldFile`) until closed.
public protocol BatchDocument: AnyObject, Sendable {
    var fingerprint: BatchFingerprint { get }
    var pageCount: Int { get }
    /// A PDF's pages print at their size, a picture fills the paper.
    var sizing: PageSizing { get }
    /// Draws a 1-based page.
    func render(_ page: Int, _ stop: BatchStop) async throws -> BatchPrintPage
    func close()
}

/// Opens the files of a batch: PDFKit and Image I/O in the app (PrintMac), a fake in the tests.
public protocol BatchDocuments: Sendable {
    /// - Throws: `BatchPasswordError` when it needs a password or `password` is wrong; `BatchFileError` when it can't be read
    ///   or printed.
    func open(_ path: String, _ password: String?, _ stop: BatchStop) async throws -> any BatchDocument
}

/// A paper the printer offers.
public struct BatchPaper: Equatable, Sendable, CustomStringConvertible {
    public var key: String
    public var label: String
    public init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    public var description: String { label }
}

/// What a printer takes.
public struct BatchQueueInfo: Equatable, Sendable {
    public var name: String
    public var papers: [BatchPaper]
    public var defaultPaper: String?
    public var canTwoSided: Bool

    public init(_ name: String, _ papers: [BatchPaper], _ defaultPaper: String?, canTwoSided: Bool) {
        self.name = name
        self.papers = papers
        self.defaultPaper = defaultPaper
        self.canTwoSided = canTwoSided
    }
}

/// One file as it's sent. Carries no password: the document was opened with it.
public struct BatchPrintJob: Equatable, Sendable {
    public var name: String
    public var pages: [Int]
    public var copies: Int
    public var twoSided: Bool
    public var paper: String?
    public var sheets: Int
}

/// What the queue took for a job.
public struct BatchReceipt: Equatable, Sendable {
    public var pages: Int
    public var sheets: Int
    public init(pages: Int, sheets: Int) {
        self.pages = pages
        self.sheets = sheets
    }
}

/// Where a batch's jobs go: the printer's CUPS queue, the made-up queue in demo mode, a fake in the tests. Roadmap 2.1 (print
/// straight to the printer over IPP) is another implementation of this: nothing above it knows which it is talking to.
public protocol BatchQueue: Sendable {
    /// What the printer takes; nil: it has no queue to print through.
    func read() async throws -> BatchQueueInfo?
    /// Why nothing should be sent now (offline, a jam, out of paper), or nil.
    func problem() async throws -> String?
    /// Draws the job's pages, then hands them over as one job, or sends nothing. `onSpooling` says the point of no return is
    /// reached: from there it finishes whatever `stop` says.
    /// - Throws: `BatchSettingRefused` (nothing sent), `BatchQueueError`, `BatchFileError` (a page couldn't be drawn: nothing
    ///   sent), `CancellationError` (stopped before the point of no return).
    func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?, onSpooling: @escaping @Sendable () -> Void,
              _ stop: BatchStop) async throws -> BatchReceipt
}

/// Stop for a batch (.NET's CancellationToken): set by the window's Stop, read between files and between pages. A child stops
/// with its parent.
public final class BatchStop: Sendable {
    private let flag = Atomic(false)
    private let parent: BatchStop?

    public init(parent: BatchStop? = nil) { self.parent = parent }

    public var isStopped: Bool { flag.load(ordering: .acquiring) || (parent?.isStopped ?? false) }

    public func stop() { flag.store(true, ordering: .releasing) }

    /// Throws `CancellationError` when stopped.
    public func check() throws { if isStopped { throw CancellationError() } }
}

/// What a printer's answer to the job's options kept of what was asked, compared before anything prints.
public enum BatchTicketCheck {
    /// - Parameters:
    ///   - askedPaper: the paper's size asked for in points; nil: the printer's default, nothing to compare.
    ///   - gotTwoSided: nil: the printer doesn't say (it has no two-sided setting).
    /// - Returns: why this job must not be sent, or nil.
    public static func problem(_ askedCopies: Int, _ askedTwoSided: Bool, _ askedPaper: (width: Double, height: Double)?,
                               _ gotCopies: Int?, _ gotTwoSided: Bool?, _ gotPaper: (width: Double, height: Double)?) -> String? {
        if let copies = gotCopies, copies != askedCopies {
            return "The printer would print \(copies) \(copies == 1 ? "copy" : "copies") instead of \(askedCopies)."
        }
        if askedTwoSided && gotTwoSided != true { return "The printer wouldn't print this two-sided, which would take more paper than the estimate." }
        if !askedTwoSided && gotTwoSided == true { return "The printer would print this two-sided though one-sided was asked for." }
        if let paper = askedPaper {
            guard let got = gotPaper, abs(got.width - paper.width) <= 2, abs(got.height - paper.height) <= 2 else {
                return "The printer wouldn't keep the paper chosen for this file."
            }
        }
        return nil
    }
}

/// Plain words for what can go wrong reading a file.
public enum BatchPrintText {
    public static func describe(_ error: any Error) -> String {
        if let e = error as? BatchFileError { return e.message }
        if let e = error as? CocoaError {
            switch e.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return "The file is gone."
            case .fileReadNoPermission: return "macOS doesn't let Inkvolt Print read this file."
            default: break
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return "The file is gone." }
        if ns.domain == NSCocoaErrorDomain && (ns.code == CocoaError.fileReadNoSuchFile.rawValue || ns.code == CocoaError.fileNoSuchFile.rawValue) {
            return "The file is gone."
        }
        return error.localizedDescription
    }

    /// A file's name for a line of text: anything that would move the cursor or color a terminal is taken out.
    public static func clean(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { isControl($0) ? " " : $0 }))
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool { s.properties.generalCategory == .control }

    public static func count(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(FleetPage.grouped(n)) \(word)s" }

    public static func sheets(_ n: Int) -> String { count(n, "sheet") }
}

/// Order in a folder: as the Finder sorts by name, so "page 2" comes before "page 10" (the Windows app's `NaturalOrder`).
public enum NaturalOrder {
    /// Negative, zero or positive, as `a` sorts before, with or after `b`.
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf16), y = Array(b.utf16)
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func upper(_ c: UInt16) -> UInt16 { c >= 97 && c <= 122 ? c - 32 : c }
        var i = 0, j = 0
        while i < x.count && j < y.count {
            if isDigit(x[i]) && isDigit(y[j]) {
                let (startA, startB) = (i, j)
                while i < x.count && isDigit(x[i]) { i += 1 }
                while j < y.count && isDigit(y[j]) { j += 1 }
                let digitsA = x[startA..<i].drop { $0 == 48 }, digitsB = y[startB..<j].drop { $0 == 48 }
                if digitsA.count != digitsB.count { return digitsA.count < digitsB.count ? -1 : 1 }
                if let k = zip(digitsA, digitsB).first(where: { $0 != $1 }) { return k.0 < k.1 ? -1 : 1 }
                continue
            }
            let (p, q) = (upper(x[i]), upper(y[j]))
            if p != q { return p < q ? -1 : 1 }
            i += 1
            j += 1
        }
        let rest = (x.count - i) - (y.count - j)
        if rest != 0 { return rest < 0 ? -1 : 1 }
        return x == y ? 0 : (x.lexicographicallyPrecedes(y) ? -1 : 1)
    }

    public static func less(_ a: String, _ b: String) -> Bool { compare(a, b) < 0 }
}

/// The files a batch takes, and what a folder comes to.
public enum BatchPrintFiles {
    static let pictures: Set<String> = [".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".bmp", ".dib", ".gif", ".tif", ".tiff", ".heic", ".heif", ".hif", ".webp"]

    private static func ext(_ path: String) -> String {
        let e = (path as NSString).pathExtension
        return e.isEmpty ? "" : "." + e.lowercased()
    }

    public static func isPdf(_ path: String) -> Bool { ext(path) == ".pdf" }

    /// A PDF or a picture, by its name. What it really is, is read when it's opened.
    public static func isSupported(_ path: String) -> Bool { isPdf(path) || pictures.contains(ext(path)) }

    /// The PDFs and pictures among `paths`: files as given, folders as the files at their top (below too with `recursive`) in
    /// the Finder's name order, each once. Links and hidden files aren't taken from a folder. `leftOut` counts what was given
    /// but isn't printable.
    public static func expand(_ paths: [String], recursive: Bool) -> (files: [String], leftOut: Int) {
        var seen = Set<String>()
        var result: [String] = []
        var leftOut = 0
        for raw in paths {
            let path = (raw as NSString).standardizingPath
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            if exists && isFolder.boolValue {
                for file in listFolder(path, recursive: recursive) where seen.insert(file.lowercased()).inserted { result.append(file) }
            } else if exists && isSupported(path) {
                if seen.insert(path.lowercased()).inserted { result.append(path) }
            } else {
                leftOut += 1
            }
        }
        return (result, leftOut)
    }

    /// The printable files of a folder, in order. Folder by folder, never through a link (out of the folder, or round in a loop).
    public static func listFolder(_ folder: String, recursive: Bool) -> [String] {
        let manager = FileManager.default
        var files: [(folder: String, name: String, path: String)] = []
        var folders = [folder]
        while let at = folders.popLast() {
            guard let names = try? manager.contentsOfDirectory(atPath: at) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = (at as NSString).appendingPathComponent(name)
                guard let attributes = try? manager.attributesOfItem(atPath: path) else { continue }
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink { continue }
                if type == .typeDirectory {
                    if recursive { folders.append(path) }
                } else if isSupported(name) && !name.hasPrefix("~$") {
                    let relative = String(at.dropFirst(folder.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    files.append((relative, name, path))
                }
            }
        }
        return files.sorted { a, b in
            let byFolder = NaturalOrder.compare(a.folder, b.folder)
            return byFolder != 0 ? byFolder < 0 : NaturalOrder.less(a.name, b.name)
        }.map(\.path)
    }
}

public enum BatchMeasureState: Sendable {
    /// It opened: its pages are counted.
    case ready
    /// It needs a password nobody gave.
    case needsPassword
    /// The password given, or every try, was wrong.
    case wrongPassword
    /// It can't be printed (`BatchMeasure.problem`).
    case problem
}

/// A file as it was when last looked at. A password that opened it stays here in memory, never in any text or file.
public struct BatchMeasure: Sendable, CustomStringConvertible {
    public var state: BatchMeasureState
    public var problem: String?
    public var pageCount = 0
    public var fingerprint: BatchFingerprint?
    public var password: String?

    public init(_ state: BatchMeasureState, problem: String? = nil, pageCount: Int = 0, fingerprint: BatchFingerprint? = nil, password: String? = nil) {
        self.state = state
        self.problem = problem
        self.pageCount = pageCount
        self.fingerprint = fingerprint
        self.password = password
    }

    public var description: String { state == .ready ? "\(pageCount) pages" : problem ?? "\(state)" }
}

/// The time limits around calls into engines and printers that may hang on a hostile file or a stuck queue: the batch goes
/// on, or says where it stopped.
public struct BatchPrintOptions: Sendable {
    /// How long a file has to open (the engine hung on it, or it's a slow network file).
    public var openTimeout: Duration = .seconds(90)
    /// How long the queue has to say whether it's ready.
    public var queueTimeout: Duration = .seconds(20)
    /// A job's time to be drawn and handed over: this much, plus `sendTimePerPage` for each page.
    public var sendTimeout: Duration = .seconds(300)
    public var sendTimePerPage: Duration = .seconds(30)

    public init() {}
}

/// The outcome of work given a time limit: done, or the time ran out first (the work may still be going).
enum Timed<T: Sendable>: Sendable {
    case done(T)
    case late
}

/// Runs `work` and waits at most `limit` for it. A late result is handed to `whenLate` (a document opened after giving up on
/// it is closed). The work runs on in the background when it ignores being cancelled, as a hung engine would.
/// One race between work and its time limit: the first to finish resumes the waiter; a late result goes to `whenLate`.
final class TimedRace<T: Sendable>: Sendable {
    let state = Mutex<(done: Bool, continuation: CheckedContinuation<Timed<T>, any Error>?)>((false, nil))
    let whenLate: (@Sendable (T) -> Void)?

    init(_ whenLate: (@Sendable (T) -> Void)?) { self.whenLate = whenLate }

    func finish(_ result: Result<Timed<T>, any Error>) -> Bool {
        let continuation = state.withLock { s -> CheckedContinuation<Timed<T>, any Error>? in
            if s.done { return nil }
            s.done = true
            let c = s.continuation
            s.continuation = nil
            return c
        }
        guard let continuation else {
            if case .success(.done(let late)) = result { whenLate?(late) }
            return false
        }
        continuation.resume(with: result)
        return true
    }
}

/// Runs `work` and waits at most `limit` for it. A late result is handed to `whenLate` (a document opened after giving up on
/// it is closed). The work runs on in the background when it ignores being cancelled, as a hung engine would.
func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T, whenLate: (@Sendable (T) -> Void)? = nil) async throws -> Timed<T> {
    let race = TimedRace<T>(whenLate)
    return try await withCheckedThrowingContinuation { continuation in
        race.state.withLock { $0.continuation = continuation }
        let task = Task {
            do {
                _ = race.finish(.success(.done(try await work())))
            } catch {
                _ = race.finish(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            if race.finish(.success(.late)) { task.cancel() }
        }
    }
}

/// Looking at a file: its pages, and its password when it has one, asked a bounded number of times.
public enum BatchMeasurer {
    /// Opens the file to read what the estimate needs. Only a file that asks gets a password: `offered` first (one that opened
    /// it before, or a command line's), once, then `ask` (file name, wrong: the last password didn't open it; nil back: leave
    /// it out), at most `BatchPrintLimits.maxPasswordTries` times. With no `ask` (a command line, a watched folder) nobody is
    /// asked. Never throws for the file; throws `CancellationError` when stopped.
    public static func measure(_ path: String, offered: String?, _ documents: any BatchDocuments, ask: (@Sendable (String, Bool) async -> String?)?,
                               options: BatchPrintOptions = BatchPrintOptions(), _ stop: BatchStop = BatchStop()) async throws -> BatchMeasure {
        var offered = offered
        var password: String?
        var asked = 0
        while true {
            do {
                let document = try await open(path, password, documents, options, stop)
                defer { document.close() }
                if let problem = BatchPrintLimits.pagesProblem(document.pageCount) { return BatchMeasure(.problem, problem: problem) }
                return BatchMeasure(.ready, pageCount: document.pageCount, fingerprint: document.fingerprint, password: password)
            } catch is BatchPasswordError {
                let wrong = password != nil
                if let given = offered {
                    (password, offered) = (given, nil)
                    continue
                }
                if ask == nil || asked >= BatchPrintLimits.maxPasswordTries {
                    return wrong ? BatchMeasure(.wrongPassword, problem: "The password doesn't open this PDF: it's left out.")
                        : BatchMeasure(.needsPassword, problem: "This PDF needs a password: it's left out.")
                }
                asked += 1
                password = await ask?((path as NSString).lastPathComponent, wrong)
                if password == nil { return BatchMeasure(.needsPassword, problem: "This PDF needs a password: it's left out.") }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return BatchMeasure(.problem, problem: BatchPrintText.describe(error))
            }
        }
    }

    /// Opens a document within the time allowed; one that opens after giving up on it is closed then.
    static func open(_ path: String, _ password: String?, _ documents: any BatchDocuments, _ options: BatchPrintOptions, _ stop: BatchStop) async throws -> any BatchDocument {
        let opening = BatchStop(parent: stop)
        switch try await within(options.openTimeout, { try await documents.open(path, password, opening) }, whenLate: { $0.close() }) {
        case .done(let document): return document
        case .late:
            opening.stop()
            try stop.check()
            throw BatchFileError("The file took too long to open: it may be damaged. It's left out.")
        }
    }
}

/// One line of a batch: a file, how it prints, and what that comes to now that its pages are known.
public struct BatchPrintLine: Sendable, CustomStringConvertible {
    public let path: String
    public let settings: BatchPrintSettings
    public let measure: BatchMeasure
    /// Why this line won't print, or nil. Never quietly another range, paper or side: it says so and doesn't print.
    public let problem: String?
    /// The pages it prints; none with a `problem`.
    public let pages: [Int]
    public let sheets: Int

    public init(_ path: String, _ settings: BatchPrintSettings, _ measure: BatchMeasure, _ queue: BatchQueueInfo?) {
        self.path = path
        self.settings = settings
        self.measure = measure
        let (problem, pages) = Self.check(settings, measure, queue)
        self.problem = problem
        self.pages = pages
        sheets = problem == nil ? BatchPrintSettings.sheets(pages.count, settings.copies, settings.twoSided) : 0
    }

    public var name: String { (path as NSString).lastPathComponent }

    public var description: String { "\(BatchPrintText.clean(name)): \(problem ?? BatchPrintText.sheets(sheets))" }

    private static func check(_ s: BatchPrintSettings, _ measure: BatchMeasure, _ queue: BatchQueueInfo?) -> (String?, [Int]) {
        if measure.state != .ready { return (measure.problem ?? "This file can't be read.", []) }
        if s.copies < 1 || s.copies > BatchPrintLimits.maxCopies { return ("Copies must be 1 to \(BatchPrintLimits.maxCopies).", []) }
        if s.twoSided, let queue, !queue.canTwoSided { return ("This printer doesn't print two-sided.", []) }
        if let paper = s.paper, let queue, !queue.papers.contains(where: { $0.key.lowercased() == paper.lowercased() }) {
            return ("This printer doesn't offer the paper \"\(BatchPrintText.clean(paper))\".", [])
        }
        switch PageRange.parse(s.range, measure.pageCount) {
        case .success(let pages): return (nil, pages)
        case .failure(let invalid): return ("The pages \"\(BatchPrintText.clean(s.range ?? ""))\" can't be printed: \(invalid.message).", [])
        }
    }
}

/// Where a file got to in a batch.
public enum BatchPrintState: String, Sendable {
    case waiting = "Waiting", sending = "Sending"
    /// Handed to the printer's queue. Whether paper came out is the printer's to say.
    case sent = "Sent"
    /// Left out before sending (a password, a range, a damaged file).
    case skipped = "Skipped"
    /// It couldn't be sent: it changed or vanished, or sending failed.
    case failed = "Failed"
    /// The batch stopped before it: not sent.
    case stopped = "Stopped"
}

/// One file's result.
public struct BatchPrintResult: Sendable {
    public var index: Int
    public var path: String
    public var state: BatchPrintState
    public var message: String
    public var pages: Int
    public var copies: Int
    public var twoSided: Bool
    public var paper: String?
    public var sheetsEstimated: Int
    public var sheetsSent: Int
    public var time: Date
    /// Sending failed part-way: some of it may be in the queue, so it's never sent again without someone choosing to.
    public var mayHaveSent = false

    public var name: String { (path as NSString).lastPathComponent }

    /// Print sends this file (again): it hasn't reached the queue, for sure. Pressing Print twice or resuming a stopped batch
    /// never prints a file twice.
    public var stillToSend: Bool { state == .waiting || state == .stopped || state == .skipped }
}

/// A file's progress: `result` is set when the file's finished.
public struct BatchPrintProgress: Sendable {
    public var index: Int
    public var state: BatchPrintState
    public var message: String
    public var result: BatchPrintResult?
}

/// What a batch did. `stoppedAt`: the first file not sent because the batch stopped; nil: it went to the end.
public struct BatchPrintSummary: Sendable {
    /// Exit codes, the same as Inkvolt PDF's command line: every file sent; a file failed or was skipped; wrong command line
    /// (nothing done); stopped before the end.
    public static let done: Int32 = 0, someFailed: Int32 = 1, wrong: Int32 = 2, stopped: Int32 = 3

    public var items: [BatchPrintResult]
    public var stoppedAt: Int?
    public var stopReason: String?

    public var sent: Int { items.filter { $0.state == .sent }.count }
    public var skipped: Int { items.filter { $0.state == .skipped }.count }
    public var failed: Int { items.filter { $0.state == .failed }.count }
    public var notSent: Int { items.filter { $0.state == .stopped }.count }
    public var sheetsSent: Int { items.reduce(0) { $0 + $1.sheetsSent } }

    public var exitCode: Int32 { stoppedAt != nil ? Self.stopped : failed + skipped > 0 ? Self.someFailed : Self.done }

    /// "Stopped at file 7 of 50 (report.pdf): Paper jam. 6 sent, 44 not sent." or "48 sent (87 sheets), 1 skipped, 1 failed."
    public var text: String {
        var parts: [String] = []
        if sent > 0 || items.isEmpty { parts.append("\(FleetPage.grouped(sent)) sent (\(BatchPrintText.sheets(sheetsSent)))") }
        if skipped > 0 { parts.append("\(FleetPage.grouped(skipped)) skipped") }
        if failed > 0 { parts.append("\(FleetPage.grouped(failed)) failed") }
        if notSent > 0 { parts.append("\(FleetPage.grouped(notSent)) not sent") }
        let counts = parts.joined(separator: ", ") + "."
        guard let at = stoppedAt else { return counts }
        let place = at < items.count
            ? "Stopped at file \(FleetPage.grouped(at + 1)) of \(FleetPage.grouped(items.count)) (\(BatchPrintText.clean(items[at].name)))" : "Stopped"
        return "\(place): \(stopReason ?? "") \(counts)"
    }
}

/// Sends a batch: one file at a time, in the order given, each as one job. Just before sending, a file is opened and held and
/// must be byte for byte what the estimate saw, or it isn't printed. A file that can't be sent is listed and the batch goes on;
/// a queue that fails or reports a problem stops it, and the rest are listed as not sent. Stopping (`stop`) takes effect
/// between files and between pages being drawn; a job already handed over finishes.
public enum BatchPrintRunner {
    public static func run(_ lines: [BatchPrintLine], _ queue: any BatchQueue, _ documents: any BatchDocuments, options: BatchPrintOptions = BatchPrintOptions(),
                           progress: (@Sendable (BatchPrintProgress) -> Void)? = nil, _ stop: BatchStop = BatchStop()) async -> BatchPrintSummary {
        var results: [BatchPrintResult] = []
        var stoppedAt: Int?
        var stopReason: String?

        func halt(_ at: Int, _ why: String) {
            if stoppedAt == nil { stoppedAt = at }
            if stopReason == nil { stopReason = why }
        }
        func finish(_ index: Int, _ line: BatchPrintLine, _ state: BatchPrintState, _ message: String, sheetsSent: Int = 0, unsure: Bool = false) {
            var result = BatchPrintResult(index: index, path: line.path, state: state, message: message, pages: line.pages.count, copies: line.settings.copies,
                                          twoSided: line.settings.twoSided, paper: line.settings.paper, sheetsEstimated: line.sheets, sheetsSent: sheetsSent, time: Date())
            result.mayHaveSent = unsure
            results.append(result)
            progress?(BatchPrintProgress(index: index, state: state, message: message, result: result))
        }

        for (i, line) in lines.enumerated() {
            if let problem = line.problem {
                finish(i, line, .skipped, problem)
                continue
            }
            if stoppedAt != nil {
                finish(i, line, .stopped, notSentText)
                continue
            }
            if stop.isStopped {
                halt(i, "You stopped the batch.")
                finish(i, line, .stopped, notSentText)
                continue
            }
            progress?(BatchPrintProgress(index: i, state: .sending, message: "Getting it ready…", result: nil))
            let outcome = await sendOne(line, queue, documents, options, progress, i, stop)
            if let why = outcome.stop { halt(i, why) }
            finish(i, line, outcome.state, outcome.message, sheetsSent: outcome.sheets, unsure: outcome.unsure)
        }
        return BatchPrintSummary(items: results, stoppedAt: stoppedAt, stopReason: stopReason)
    }

    private static let notSentText = "Not sent: the batch stopped before it."

    /// A file's progress lines, passed on as they come (before its result).
    private static func relay(_ index: Int) -> (@escaping @Sendable (BatchPrintProgress) -> Void) -> @Sendable (String) -> Void {
        { progress in { progress(BatchPrintProgress(index: index, state: .sending, message: $0, result: nil)) } }
    }

    private struct Outcome {
        var state: BatchPrintState
        var message: String
        var sheets = 0
        var stop: String?
        var unsure = false
    }

    private static func sendOne(_ line: BatchPrintLine, _ queue: any BatchQueue, _ documents: any BatchDocuments, _ options: BatchPrintOptions,
                                _ progress: (@Sendable (BatchPrintProgress) -> Void)?, _ index: Int, _ stop: BatchStop) async -> Outcome {
        do {
            var problem: String?
            do {
                switch try await within(options.queueTimeout, { try await queue.problem() }) {
                case .done(let said): problem = said
                case .late: problem = "macOS doesn't answer about the printer."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                problem = (error as? BatchQueueError)?.message ?? error.localizedDescription
            }
            if let problem { return Outcome(state: .stopped, message: notSentText, stop: problem) }
            try stop.check()

            let document: any BatchDocument
            do {
                document = try await BatchMeasurer.open(line.path, line.measure.password, documents, options, stop)
            } catch is BatchPasswordError {
                return Outcome(state: .failed, message: "The file changed since the estimate: its password no longer opens it. Not printed.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Outcome(state: .failed, message: "\(BatchPrintText.describe(error)) Not printed.")
            }
            defer { document.close() }

            if document.fingerprint != line.measure.fingerprint || document.pageCount != line.measure.pageCount {
                let counts = document.pageCount != line.measure.pageCount
                    ? " (\(BatchPrintText.count(line.measure.pageCount, "page")) then, \(FleetPage.grouped(document.pageCount)) now)" : ""
                return Outcome(state: .failed, message: "The file changed since the estimate\(counts). Not printed: check the list again to print it.")
            }

            let job = BatchPrintJob(name: line.name, pages: line.pages, copies: line.settings.copies, twoSided: line.settings.twoSided,
                                    paper: line.settings.paper, sheets: line.sheets)
            let limit = options.sendTimeout + options.sendTimePerPage * line.pages.count
            let spooling = Atomic(false)
            // Its own stop: the queue takes it up to the point of no return, and a job past it has to finish; a drawing that
            // hung is told to stop, and sends nothing if it ever wakes up.
            let sendStop = BatchStop(parent: stop)
            let report = progress.map(Self.relay(index))
            let receipt: BatchReceipt
            let onSpooling: @Sendable () -> Void = { spooling.store(true, ordering: .releasing) }
            let sending: @Sendable () async throws -> BatchReceipt = { try await queue.send(document, job, progress: report, onSpooling: onSpooling, sendStop) }
            switch try await within(limit, sending) {
            case .done(let r): receipt = r
            case .late:
                sendStop.stop()
                let spooled = spooling.load(ordering: .acquiring)
                return Outcome(state: .failed, message: spooled ? "macOS didn't finish taking it in time: check the queue before sending it again."
                    : "It took too long to draw: it may be damaged. Not printed.", stop: spooled ? "The printer's queue stopped taking jobs." : nil, unsure: spooled)
            }
            if receipt.sheets > line.sheets {
                return Outcome(state: .failed, message: "The queue took \(BatchPrintText.sheets(receipt.sheets)), more than the \(FleetPage.grouped(line.sheets)) estimated.",
                               sheets: receipt.sheets, stop: "A job came to more sheets than its estimate, so nothing more is sent.", unsure: true)
            }
            return Outcome(state: .sent, message: "Sent to the queue: \(BatchPrintText.sheets(receipt.sheets)).", sheets: receipt.sheets)
        } catch is CancellationError {
            return Outcome(state: .stopped, message: notSentText, stop: "You stopped the batch.")
        } catch let e as BatchSettingRefused {
            return Outcome(state: .failed, message: "\(e.message) Not printed.")
        } catch let e as BatchFileError {
            return Outcome(state: .failed, message: "\(e.message) Not printed.")
        } catch let e as BatchQueueError {
            return e.mayHaveSent
                ? Outcome(state: .failed, message: "Sending failed part-way: check the queue before sending it again.", stop: e.message, unsure: true)
                : Outcome(state: .stopped, message: notSentText, stop: e.message)
        } catch {
            // Queue and printer errors come in many types. Whether any of the job got there isn't known.
            return Outcome(state: .failed, message: "Sending failed: check the queue before sending it again.", stop: "\(error)", unsure: true)
        }
    }
}

/// A batch's results as one CSV (RFC 4180, roadmap 2.4, Pro), a row per file in the list's order. File names come from
/// outside, so a cell a spreadsheet would run as a formula starts with an apostrophe (`CsvCell`).
public enum BatchPrintCsv {
    static let columns = "Order,File,Folder,Result,Details,Pages,Copies,Two-sided,Paper,Sheets estimated,Sheets sent,Time"

    /// The file's text when the Pro check allows it; nil when it doesn't (the caller shows what Pro does and where to get it).
    public static func export(_ results: [BatchPrintResult], timeZone: TimeZone = .current) -> String? {
        Pro.allows(.batchPrintAutomation) ? build(results, timeZone: timeZone) : nil
    }

    public static func build(_ results: [BatchPrintResult], timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var csv = columns + "\r\n"
        for r in results {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.time)
            let time = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            let cells = [String(r.index + 1), CsvCell.of(r.name), CsvCell.of((r.path as NSString).deletingLastPathComponent), r.state.rawValue, CsvCell.of(r.message),
                         String(r.pages), String(r.copies), r.twoSided ? "Yes" : "No", CsvCell.of(r.paper ?? ""), String(r.sheetsEstimated), String(r.sheetsSent), time]
            csv += cells.joined(separator: ",") + "\r\n"
        }
        return csv
    }
}
