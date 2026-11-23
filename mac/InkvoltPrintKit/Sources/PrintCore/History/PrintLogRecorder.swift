import Foundation

/// One job of CUPS's own history of finished jobs (IPP Get-Jobs with `which-jobs=completed` over cupsd's socket, PrintMac's
/// `LibCups.finishedJobs`): the Mac's counterpart of what Windows' spooler says about a job in its notices (`JobChange`), read
/// as a whole once the job is done. What cupsd hides of other users' jobs (their names and documents) is simply missing.
public struct FinishedJob: Equatable, Sendable {
    public var id: Int
    /// The queue's name (the last part of `job-printer-uri`).
    public var queue: String
    public var document: String?
    public var user: String?
    /// `job-originating-host-name`; nil for this Mac (`localhost`).
    public var machine: String?
    public var state: JobState
    public var submitted: Date?
    public var completed: Date?
    /// The document's pages (`job-impressions`), when CUPS knows them.
    public var pages: Int?
    /// The pages CUPS counted as printed, copies included (`job-impressions-completed`, else `job-media-sheets-completed`).
    public var printed: Int?
    public var copies: Int?
    public var color: Bool?
    public var twoSided: Bool?

    public init(id: Int, queue: String, document: String? = nil, user: String? = nil, machine: String? = nil, state: JobState = .completed,
                submitted: Date? = nil, completed: Date? = nil, pages: Int? = nil, printed: Int? = nil, copies: Int? = nil,
                color: Bool? = nil, twoSided: Bool? = nil) {
        self.id = id
        self.queue = queue
        self.document = document
        self.user = user
        self.machine = machine
        self.state = state
        self.submitted = submitted
        self.completed = completed
        self.pages = pages
        self.printed = printed
        self.copies = copies
        self.color = color
        self.twoSided = twoSided
    }

    /// The job's key in the log: its id with its creation time, since cupsd uses an id again once its job cache is reset.
    public var key: String { "\(id)@\(submitted.map { Int($0.timeIntervalSince1970) } ?? 0)" }
}

/// What a finished job's Get-Jobs attributes say (the Mac's counterpart of Windows' `JobSettings.Read` and
/// `JobChange.SystemTime`), read as hostile input: values come as text by attribute name (the first value of each), numbers
/// out of range are nothing, a time that isn't one is none.
public enum FinishedJobAttributes {
    public static let requested = [
        "job-id", "job-printer-uri", "job-name", "job-state", "job-originating-user-name", "job-originating-host-name",
        "time-at-creation", "time-at-completed", "job-impressions", "job-impressions-completed", "job-media-sheets-completed",
        "copies", "print-color-mode", "sides",
    ]

    /// The job, or nil without a job id, a queue or a finished state.
    public static func job(_ a: [String: String]) -> FinishedJob? {
        guard let id = number(a["job-id"]), id > 0, let raw = number(a["job-state"]), let state = JobState(rawValue: raw),
              [.canceled, .aborted, .completed].contains(state), let queue = queue(a["job-printer-uri"]) else { return nil }
        let host = a["job-originating-host-name"].map { AlertText.clean($0, PrintLog.maxText) }
        let local = host.map { ["", "localhost", "127.0.0.1", "::1", "[::1]"].contains($0.lowercased()) } ?? true
        let impressions = count(a["job-impressions-completed"])
        let sheets = count(a["job-media-sheets-completed"])
        let copies = number(a["copies"]).flatMap { $0 > 0 ? min($0, PrintLog.maxCopies) : nil }
        let color: Bool? = switch a["print-color-mode"]?.lowercased() {
        case "color", "process-color"?: true
        case "monochrome", "process-monochrome", "bi-level", "process-bi-level"?: false
        default: nil
        }
        let twoSided: Bool? = switch a["sides"]?.lowercased() {
        case "one-sided"?: false
        case "two-sided-long-edge", "two-sided-short-edge"?: true
        default: nil
        }
        return FinishedJob(id: id, queue: queue, document: a["job-name"], user: a["job-originating-user-name"], machine: local ? nil : host,
                           state: state, submitted: time(a["time-at-creation"]), completed: time(a["time-at-completed"]),
                           pages: count(a["job-impressions"]), printed: impressions ?? sheets, copies: copies, color: color,
                           twoSided: twoSided)
    }

    /// "ipp://localhost/printers/Office_Laser" → "Office_Laser"; nil for anything that names no queue.
    static func queue(_ uri: String?) -> String? {
        guard let uri, uri.count <= 1024, let range = uri.range(of: "/printers/") ?? uri.range(of: "/classes/") else { return nil }
        let name = String(uri[range.upperBound...].prefix { $0 != "/" && $0 != "?" })
        let decoded = name.removingPercentEncoding ?? name
        let clean = AlertText.clean(decoded, PrintLog.maxText)
        return clean.isEmpty ? nil : clean
    }

    private static func number(_ s: String?) -> Int? {
        guard let s, s.count <= 20, let n = Int(s.trimmingCharacters(in: .whitespaces)), n <= Int(Int32.max) else { return nil }
        return n
    }

    private static func count(_ s: String?) -> Int? { number(s).flatMap { $0 >= 0 ? min($0, PrintLog.maxPages) : nil } }

    /// Seconds since 1970 (CUPS's times), as a date from 1990 to 9000 (Windows' `SystemTime` rule); nil otherwise.
    public static func time(_ s: String?) -> Date? {
        guard let n = number(s), n >= 631_152_000 else { return nil } // 1990-01-01
        return Date(timeIntervalSince1970: TimeInterval(n))
    }
}

/// Turns CUPS's history of finished jobs into print log entries (roadmap 4.9; the Mac's `PrintLogRecorder`): each job logged
/// once (by `FinishedJob.key`), and only one that finished since the log was turned on (`since`), so jobs printed before
/// aren't, as Windows doesn't log jobs printed before it watched. CUPS keeps the history while Inkvolt Print is closed, so
/// the jobs printed meanwhile are logged at the next read (Windows logs only while it runs). How it ended: printed when CUPS
/// completed it or stopped it after a page printed; cancelled when it was cancelled before; left when CUPS gave up on it
/// before. Not thread-safe: the keeper calls it under its lock.
public final class PrintLogRecorder {
    /// Most jobs remembered as logged (CUPS keeps 500 finished jobs by default; `LibCups.finishedJobs` reads at most this
    /// many).
    public static let maxOpen = 2_000

    private var logged: Set<String>?

    public init() {}

    /// Jobs remembered as logged now (for tests).
    public var open: Int { logged?.count ?? 0 }

    /// The history read now: the entries for the jobs not logged yet that finished at or after `since`. `whole`: the read
    /// holds all CUPS keeps (not just its newest few), so the jobs it doesn't list are gone for good. `known`: the keys of
    /// the jobs the log already holds, asked only the first time (or after `reset`); nil while the log can't be read, and
    /// then nothing is read now (it's asked again next time). `printerName`: a queue's name as the Mac shows it.
    public func read(_ history: [FinishedJob], since: Date, now: Date, whole: Bool = true, known: () -> Set<String>?,
                     printerName: (String) -> String = { $0 }) -> [PrintLogEntry] {
        guard var logged = logged ?? known() else { return [] }
        var seen = Set<String>()
        var done: [PrintLogEntry] = []
        for job in history.prefix(Self.maxOpen) {
            let key = job.key
            guard seen.insert(key).inserted else { continue }
            if logged.contains(key) { continue }
            guard (job.completed ?? job.submitted ?? now) >= since else { continue }
            if let entry = Self.entry(job, now: now, printerName: printerName) {
                done.append(entry)
                logged.insert(key)
            }
        }
        if whole {
            // Jobs CUPS no longer lists can't come back: only those it lists stay remembered.
            logged = logged.intersection(seen)
        } else if logged.count > Self.maxOpen * 2 {
            // A read of the newest few says nothing of the older jobs; past twice the bound, what was logged is asked of the
            // log again at the next read (it holds every job it logged).
            self.logged = nil
            return done.sorted { $0.at < $1.at }
        }
        self.logged = logged
        return done.sorted { $0.at < $1.at }
    }

    /// Forgets what was logged (it's asked of the log again at the next read).
    public func reset() { logged = nil }

    static func entry(_ job: FinishedJob, now: Date, printerName: (String) -> String) -> PrintLogEntry? {
        let printed = job.printed ?? 0
        let outcome: PrintLogOutcome = job.state == .completed || printed > 0 ? .printed : job.state == .canceled ? .cancelled : .left
        let copies = job.copies ?? 1
        let pages = (job.pages ?? 0) > 0 ? job.pages! : printed / max(1, copies)
        return PrintLog.clean(PrintLogEntry(at: job.submitted ?? job.completed ?? now, printer: printerName(job.queue),
                                            document: AlertText.cut(AlertText.lastPart(AlertText.clean(job.document, Int.max)), PrintLog.maxText), user: job.user ?? "",
                                            pages: pages, copies: copies, color: job.color, twoSided: job.twoSided, outcome: outcome,
                                            machine: job.machine, printed: printed, job: job.key))
    }
}

/// The print log as the app keeps it (roadmap 4.9; the Mac's `PrintLogKeeper`): CUPS's history through a `PrintLogRecorder`
/// into a `PrintLogFile`, only while on. On is `since`, the moment it was turned on (or the first launch): the app keeps it
/// in its state, nil when off. Thread-safe: reads come off the main thread, the switch from the window.
public final class PrintLogKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder = PrintLogRecorder()
    private let clock: @Sendable () -> Date
    private var sinceDate: Date?
    public let file: PrintLogFile

    public init(_ file: PrintLogFile, since: Date?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        sinceDate = since
        self.clock = clock
    }

    /// Raised (on the reading's thread) after jobs were added to the log.
    public var added: (@Sendable () -> Void)?

    /// When logging was turned on; nil while off.
    public var since: Date? { lock.withLock { sinceDate } }

    public var on: Bool { since != nil }

    /// Turns logging on (from now: jobs finished while it was off aren't logged) or off. The new `since`, for the app's state.
    @discardableResult
    public func turn(_ on: Bool) -> Date? {
        lock.withLock {
            if on == (sinceDate != nil) { return sinceDate }
            sinceDate = on ? clock() : nil
            recorder.reset()
            return sinceDate
        }
    }

    /// One read of CUPS's history: the jobs it adds (0 while off, and while the log's file can't be read: its jobs would be
    /// taken for none and logged again). `whole`: the read holds all CUPS keeps (`PrintLogRecorder.read`).
    @discardableResult
    public func read(_ history: [FinishedJob], whole: Bool = true, printerName: (String) -> String = { $0 }) -> Int {
        let now = clock()
        let count: Int = lock.withLock {
            guard let since = sinceDate else { return 0 }
            let done = recorder.read(history, since: since, now: now, whole: whole, known: { file.jobs(now) },
                                     printerName: printerName)
            if !done.isEmpty { file.add(done, now) }
            return done.count
        }
        if count > 0 { added?() }
        return count
    }

    /// Clear: every job forgotten, and only jobs finished from now on logged (CUPS's history still holds the cleared ones).
    /// The new `since` (unchanged when the file couldn't be deleted: then nothing is forgotten), and whether it was cleared.
    public func clear() -> (cleared: Bool, since: Date?) {
        lock.withLock {
            guard file.clear() else { return (false, sinceDate) }
            if sinceDate != nil { sinceDate = clock() }
            recorder.reset()
            return (true, sinceDate)
        }
    }
}

/// Where CUPS's history of finished jobs comes from: PrintMac's `LibCups` (cupsd over its socket), a fake in tests, demo
/// mode's none.
public protocol FinishedJobHistory: Sendable {
    /// The newest finished jobs of every queue, at most `limit` (cupsd lists the newest first); nil when cupsd can't be asked.
    func finishedJobs(limit: Int) async -> [FinishedJob]?
}
