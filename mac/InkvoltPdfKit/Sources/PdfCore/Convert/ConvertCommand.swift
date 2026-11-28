import Foundation
import PrintCore

/// Finder's "Convert to Word with Inkvolt PDF" and the command line behind it, as Windows' `ConvertCommand`:
/// `InkvoltPdf --convert-to word <files…>` (also `excel`, `powerpoint`, `text`, `html`, or the extension), the command
/// bar's one-click Convert for each file, with its defaults. A command-line launch hands the request to a running copy
/// with `toArguments`; the copy reads it back with `tryParse`. Finder's service (the app's `NSServices`) hands its files
/// straight to the running copy, which macOS starts when none runs.
///
/// Every argument after the format is a file, whatever it looks like (a name may start with "--"). Relative ones are
/// made full against this launch's folder; full ones are kept as given (only "." and ".." taken out). An argument
/// holding a control character is dropped, as on Windows (no file name typed or chosen in Finder holds one), and so is a
/// path into /dev (`onDisk`): a read of a terminal or a pipe never ends.
public enum ConvertCommand {
    public static let switchName = "--convert-to"

    /// The most files one request converts (Finder passes a whole selection); the rest are counted as dropped.
    public static let maxFiles = 500

    public enum ParseError: Sendable, Equatable { case none, notACommand, noFormat, unknownFormat, noFiles }

    /// What to convert: the format, the files (full paths, in order, each once), and what was left out: files past
    /// `maxFiles` (`overLimit`) and arguments that can't be a file name (`refused`), said apart.
    public struct Request: Sendable, Equatable {
        public var format: ExportFormat
        public var files: [String]
        public var overLimit: Int
        public var refused: Int

        public init(_ format: ExportFormat, _ files: [String], overLimit: Int = 0, refused: Int = 0) {
            self.format = format
            self.files = files
            self.overLimit = overLimit
            self.refused = refused
        }
    }

    /// The app's own options (`--lang`, `--report`) come before `--convert-to`; from it on, everything is the command,
    /// every argument after the format a file. Without the command, all of it is options and files.
    public static func splitOptions(_ args: [String]) -> (options: [String], command: [String]) {
        for (i, arg) in args.enumerated() where isCommand([arg]) {
            return (Array(args[..<i]), Array(args[i...]))
        }
        return (args, [])
    }

    /// Several requests as one batch per format (several service calls or command-line launches together): files in the
    /// order they came, each once, at most `maxFiles`; what each left out added up.
    public static func merge(_ requests: [Request]) -> [Request] {
        var formats: [ExportFormat] = []
        for r in requests where !formats.contains(r.format) { formats.append(r.format) }
        return formats.map { format in
            var files: [String] = []
            var seen = Set<String>()
            var over = 0, refused = 0
            for r in requests where r.format == format {
                over = addLeftOut(over, r.overLimit)
                refused = addLeftOut(refused, r.refused)
                for f in r.files where seen.insert(f.lowercased()).inserted {
                    if files.count >= maxFiles { over = addLeftOut(over, 1) } else { files.append(f) }
                }
            }
            return Request(format, files, overLimit: over, refused: refused)
        }
    }

    /// Whether the app may quit: no document window, no conversions window, no conversion gathering, waiting or running,
    /// and no launch's files read but not handled yet.
    public static func mayExit(mainOpen: Bool, listOpen: Bool, converting: Bool, forwards: Int) -> Bool {
        !mainOpen && !listOpen && !converting && forwards == 0
    }

    private static let names: [(name: String, format: ExportFormat)] = [
        ("word", .word), ("docx", .word),
        ("excel", .excel), ("xlsx", .excel),
        ("powerpoint", .powerPoint), ("pptx", .powerPoint),
        ("text", .text), ("txt", .text),
        ("html", .html),
    ]

    /// True when the first argument is `--convert-to` or `--convert-to=…` (any case).
    public static func isCommand(_ args: [String]) -> Bool {
        guard let first = args.first?.lowercased() else { return false }
        return first == switchName || first.hasPrefix(switchName + "=")
    }

    /// Reads `--convert-to format file…` or `--convert-to=format file…`; `folder` is what relative names are made full
    /// against (the launch's own folder).
    public static func tryParse(_ args: [String], folder: String = FileManager.default.currentDirectoryPath) -> (request: Request?, error: ParseError) {
        guard isCommand(args) else { return (nil, .notACommand) }
        let first = args[0]
        let name: String?
        let filesFrom: Int
        if first.count > switchName.count {
            name = String(first.dropFirst(switchName.count + 1))
            filesFrom = 1
        } else {
            name = args.count > 1 ? args[1] : nil
            filesFrom = 2
        }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, .noFormat) }
        // A forwarded launch's own leftovers: "word:3:1" (toArguments); each count bounded.
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var over = 0, refused = 0
        guard let format = formatNamed(parts[0]), parts.count == 1 || parts.count == 3 else { return (nil, .unknownFormat) }
        if parts.count == 3 {
            guard let o = Int(parts[1]), let r = Int(parts[2]), (0...maxLeftOut).contains(o), (0...maxLeftOut).contains(r) else {
                return (nil, .unknownFormat)
            }
            over = o
            refused = r
        }
        var files: [String] = []
        var seen = Set<String>()
        for arg in args.dropFirst(filesFrom) {
            if arg.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard !arg.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }), let full = full(arg, folder) else {
                refused = addLeftOut(refused, 1)
                continue
            }
            guard seen.insert(full.lowercased()).inserted else { continue }
            guard files.count < maxFiles else {
                over = addLeftOut(over, 1)
                continue
            }
            files.append(full)
        }
        guard !files.isEmpty else { return (nil, .noFiles) }
        return (Request(format, files, overLimit: over, refused: refused), .none)
    }

    private static func formatNamed(_ name: String) -> ExportFormat? {
        names.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.format
    }

    private static func full(_ arg: String, _ folder: String) -> String? {
        let full = arg.hasPrefix("/") ? arg : (folder as NSString).appendingPathComponent(arg)
        let path = URL(fileURLWithPath: full).standardizedFileURL.path
        return onDisk(path) ? path : nil
    }

    /// A path to a file, not into /dev (a terminal, a pipe, `/dev/fd/0`: a read that can hold a conversion for good).
    /// A link to one is refused when converting: only a regular file is read (`ConvertFile.isRegularFile`).
    static func onDisk(_ full: String) -> Bool {
        var p = full
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        let lower = p.lowercased()
        return lower != "/dev" && !lower.hasPrefix("/dev/")
    }

    /// The most a left-out count says (a forwarded launch's own counts are bounded so; sums stop there).
    public static let maxLeftOut = 1_000_000

    /// `a` + `b`, at most `maxLeftOut` (never overflowing).
    public static func addLeftOut(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? maxLeftOut : 0) : min(maxLeftOut, max(0, sum))
    }

    /// The request as one launch hands it to another: the format joined to the switch, then the full paths. What the
    /// launch left out travels in the switch (`--convert-to=word:3:1`: over the limit, refused), so the running copy says
    /// so; every argument after it stays a file.
    public static func toArguments(_ request: Request) -> [String] {
        let name = names.first { $0.format == request.format }!.name
        let counts = request.overLimit + request.refused > 0 ? ":\(request.overLimit):\(request.refused)" : ""
        return ["\(switchName)=\(name)\(counts)"] + request.files
    }

    /// The output's name: the PDF's, with the format's extension (`report.pdf` → `report.docx`). A name Windows maps to a
    /// device gets "_" (`_CON.docx`), as Windows' does, so the file moves to a PC; an empty one is "Untitled".
    public static func outputName(_ pdfPath: String, _ format: ExportFormat) -> String {
        let file = (pdfPath as NSString).lastPathComponent
        var stem = file.lastIndex(of: ".").map { String(file[..<$0]) } ?? file
        stem = stem.trimmingCharacters(in: .whitespaces)
        while let last = stem.last, last == "." || last == " " { stem.removeLast() }
        if stem.isEmpty { stem = "Untitled" }
        if ReservedFileNames.isDevice(stem) { stem = "_" + stem }
        return stem + DocumentExport.fileExtension(format)
    }

    /// Where a request's result shows: the in-app one-click's notice ("Saved report.docx · Show in Finder · Change
    /// options…") when a document window is up, nothing else is converting or listed, and the request is one file; the
    /// small conversions window otherwise (several files, or the app not open).
    public static func showsNotice(windowReady: Bool, listOpen: Bool, busy: Bool, files: Int) -> Bool {
        windowReady && !listOpen && !busy && files == 1
    }
}

/// How one conversion ended.
public enum ConvertResult: Sendable, Equatable { case saved, notFound, notOpened, nothingToSave, cancelled, failed }

/// A conversion's result: the file written (and whether it went to Documents) with its notes ("2 pages recognized"), or
/// the message that says why nothing was written, ready to show.
public struct ConvertOutcome: Sendable, Equatable {
    public let result: ConvertResult
    public let output: String?
    public let inDocuments: Bool
    public let message: String?

    public static func saved(_ output: String, inDocuments: Bool, notes: String?) -> ConvertOutcome {
        ConvertOutcome(result: .saved, output: output, inDocuments: inDocuments, message: notes)
    }

    public static func failed(_ result: ConvertResult, _ message: String?) -> ConvertOutcome {
        ConvertOutcome(result: result, output: nil, inDocuments: false, message: message)
    }
}

/// What the user answered once for one selection's conversions (`ConvertJob.answers`, one per `ConvertQueue.add`), so
/// 500 protected files don't ask 500 times: a cancelled password prompt asks for no more passwords (those files end
/// Cancelled), and the answer to "export a protected file anyway?" holds for the rest of that selection.
@MainActor
public final class ConvertAnswers {
    public var askPasswords = true
    public var exportProtected: Bool?

    public init() {}
}

/// One file of a request in the `ConvertQueue`.
@MainActor
public final class ConvertJob {
    public enum States: Sendable, Equatable { case waiting, converting, done }

    public let pdf: String
    public let format: ExportFormat

    /// Opened when written: asked for (the notice of a batch of this one file, as the one-click opens it); a listed one
    /// never is.
    public private(set) var open = false

    /// The result won't be opened: the notice joined a list (a later request of the same selection came).
    public func stopOpening() { open = false }

    func setOpen(_ value: Bool) { open = value }

    public internal(set) var state: States = .waiting
    public internal(set) var outcome: ConvertOutcome?

    /// What the user answered once for the selection this file came with (shared by its request's jobs).
    public internal(set) var answers: ConvertAnswers

    init(pdf: String, format: ExportFormat, answers: ConvertAnswers) {
        self.pdf = pdf
        self.format = format
        self.answers = answers
    }
}

/// The conversions one copy of the app runs for Finder: one at a time, in the order asked, on the main actor (the
/// conversion may ask, as for a password), each file once while it waits or runs. A conversion that throws ends as
/// `failed` with its message and the next one starts. The list keeps the last `maxListed`; finished ones go first.
@MainActor
public final class ConvertQueue {
    public typealias Convert = @MainActor (ConvertJob, CancelToken) async throws -> ConvertOutcome

    public static let maxListed = 1000
    /// The most files that wait at once: a request past it is cut (`fit`), so a flood of requests can't grow the list.
    public static let maxWaiting = 5_000

    private let convert: Convert
    private var cancel = CancelToken()
    private var running = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var jobs: [ConvertJob] = []

    /// A job was added, started or finished.
    public var changed: ((ConvertJob) -> Void)?

    public init(_ convert: @escaping Convert) { self.convert = convert }

    /// Returns when nothing waits or runs.
    public func idle() async {
        guard running else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// A job waits or runs (false already when the last one's done is reported).
    public var isBusy: Bool { jobs.contains { $0.state != .done } }

    /// Queues each file of `request` not already waiting or converting; returns those added. With `open`, a request of
    /// one file opens its result when written.
    @discardableResult
    public func add(_ request: ConvertCommand.Request, open: Bool = false) -> [ConvertJob] {
        var added: [ConvertJob] = []
        let answers = ConvertAnswers() // one selection's: a later one asks again
        for pdf in request.files where !pending(request.format, pdf) {
            let job = ConvertJob(pdf: pdf, format: request.format, answers: answers)
            job.setOpen(open && request.files.count == 1)
            jobs.append(job)
            added.append(job)
            changed?(job)
        }
        trim()
        if !added.isEmpty && !running {
            running = true
            Task { await self.run() }
        }
        return added
    }

    private func pending(_ format: ExportFormat, _ pdf: String) -> Bool {
        jobs.contains { $0.state != .done && $0.format == format && $0.pdf.caseInsensitiveCompare(pdf) == .orderedSame }
    }

    /// How many more files may wait now.
    public var room: Int { max(0, Self.maxWaiting - jobs.filter { $0.state != .done }.count) }

    /// `request` as it fits: whole when its new files (those not already waiting or converting) fit in `room`; else its
    /// new files up to the room, and how many more were cut.
    public func fit(_ request: ConvertCommand.Request) -> (taken: ConvertCommand.Request, cut: Int) {
        let room = room
        if request.files.count <= room { return (request, 0) }
        let fresh = request.files.filter { !pending(request.format, $0) }
        if fresh.count <= room { return (request, 0) }
        var taken = request
        taken.files = Array(fresh.prefix(room))
        return (taken, fresh.count - room)
    }

    /// Stops the conversion running and those waiting (each ends cancelled).
    public func cancelAll() {
        cancel.cancel()
        for job in jobs where job.state == .waiting { finish(job, .failed(.cancelled, nil)) }
    }

    private func run() async {
        while let job = jobs.first(where: { $0.state == .waiting }) {
            if cancel.isCancelled { cancel = CancelToken() }
            job.state = .converting
            changed?(job)
            let outcome: ConvertOutcome
            do {
                outcome = try await convert(job, cancel)
            } catch is CancellationError {
                outcome = .failed(.cancelled, nil)
            } catch {
                outcome = .failed(.failed, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
            finish(job, outcome)
        }
        running = false
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }

    private func finish(_ job: ConvertJob, _ outcome: ConvertOutcome) {
        job.outcome = outcome
        job.state = .done
        changed?(job)
    }

    private func trim() {
        var i = 0
        while i < jobs.count && jobs.count > Self.maxListed {
            if jobs[i].state == .done { jobs.remove(at: i) } else { i += 1 }
        }
    }
}

/// Requests that come together (Finder's service called again for more files, a script starting one command-line launch
/// per file) are gathered while they come within `quiet` of each other (at most `longest` after the first) and handled as
/// one batch (`ConvertCommand.merge`), so nine files make one list, not a notice and a list of eight.
public struct ConvertGather: Sendable {
    public static let quiet: TimeInterval = 0.4
    public static let longest: TimeInterval = 2

    /// How long after the last request the selection is taken as complete: a notice's result opens only then, so a
    /// request that comes after its batch was cut still folds the notice into the list instead of opening Word.
    public static let settle: TimeInterval = 4

    private var lastEver: Date?
    private var requests: [ConvertCommand.Request] = []
    private var first = Date.distantPast, last = Date.distantPast

    public init() {}

    /// When no request will have come for `settle`; nil when none ever came.
    public var settledAt: Date? { lastEver.map { $0.addingTimeInterval(Self.settle) } }

    public func settled(_ now: Date) -> Bool { settledAt.map { now >= $0 } ?? true }

    public var isEmpty: Bool { requests.isEmpty }

    /// When the batch is complete: `quiet` after the last request, or `longest` after the first.
    public var dueAt: Date? {
        isEmpty ? nil : min(last.addingTimeInterval(Self.quiet), first.addingTimeInterval(Self.longest))
    }

    public mutating func add(_ request: ConvertCommand.Request, _ now: Date) {
        if isEmpty { first = now }
        last = now
        lastEver = now
        requests.append(request)
    }

    public func isDue(_ now: Date) -> Bool { dueAt.map { now >= $0 } ?? false }

    /// The batch, one request per format, and nothing gathered after.
    public mutating func take() -> [ConvertCommand.Request] {
        let merged = ConvertCommand.merge(requests)
        requests = []
        return merged
    }
}

/// How a command-line launch reaches the copy of the app already running (Finder's service needs none: macOS hands its
/// files to the one copy): it becomes the owner when none runs, else hands its arguments over. When the owner can't be
/// reached, an ordinary launch opens on its own; a conversion launch keeps trying for `convertPatience`, then converts
/// on its own only if no other such copy does (`standaloneSlot`), and otherwise gives up. Only a few launches wait so
/// (`waiterSlot`, nil when they are taken): the rest give up after their first try. As Windows' `LaunchHandoff`.
public enum LaunchHandoff {
    public enum Way: Sendable, Equatable { case owner, forwarded, standalone, dropped }

    public static let convertPatience: TimeInterval = 60

    public static func find(convert: Bool, own: () -> Bool, forward: () -> Bool, waiterSlot: () -> LaunchSlot?,
                            standaloneSlot: () -> Bool, elapsed: () -> TimeInterval, wait: (TimeInterval) -> Void) -> Way {
        var waiting: LaunchSlot?
        defer { waiting?.release() }
        var attempt = 0
        while true {
            if own() { return .owner }
            if forward() { return .forwarded }
            if !convert { return .standalone }
            if attempt == 0 {
                waiting = waiterSlot()
                if waiting == nil { return .dropped }
            }
            if elapsed() >= convertPatience { return standaloneSlot() ? .standalone : .dropped }
            wait(0.5 * Double(1 << min(attempt, 3)))
            attempt += 1
        }
    }
}

/// A slot `LaunchHandoff` holds while it waits, let go of when it is done.
public protocol LaunchSlot: AnyObject {
    func release()
}
