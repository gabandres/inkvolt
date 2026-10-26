import Foundation

/// A print job's state (RFC 8011 `job-state`), as CUPS reports it.
public enum JobState: Int, Equatable, Sendable {
    case pending = 3, held, processing, stopped, canceled, aborted, completed
}

/// One job in a printer's CUPS queue. `pages` is nil when CUPS doesn't say.
public struct QueueJob: Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var pages: Int?
    public var pagesPrinted: Int
    public var state: JobState
    public var submitted: Date
    public var owner: String

    public init(id: Int, name: String, pages: Int? = nil, pagesPrinted: Int = 0, state: JobState, submitted: Date, owner: String) {
        self.id = id
        self.name = name
        self.pages = pages
        self.pagesPrinted = pagesPrinted
        self.state = state
        self.submitted = submitted
        self.owner = owner
    }
}

/// What the print queue card shows for a job (the Windows app's `QueueJobText`): plain words for its state, pages, time,
/// owner.
public enum QueueJobText {
    /// The job's state; a job the printer can't take now says why (`printerOffline`: its queue says the printer can't be
    /// reached).
    public static func status(_ s: JobState, printerOffline: Bool = false) -> String {
        if printerOffline && (s == .pending || s == .processing) { return "Printer offline" }
        return switch s {
        case .pending: "Waiting"
        case .held: "On hold"
        case .processing: "Printing"
        case .stopped: "Stopped"
        case .canceled: "Cancelled"
        case .aborted: "Error"
        case .completed: "Printed"
        }
    }

    /// A job that needs the user, not just patience.
    public static func isProblem(_ s: JobState, printerOffline: Bool = false) -> Bool {
        s == .stopped || s == .aborted || (printerOffline && (s == .pending || s == .processing))
    }

    /// Finished or going: never cancelled again.
    public static func isDone(_ s: JobState) -> Bool { s == .canceled || s == .aborted || s == .completed }

    /// "3 pages", "Page 2 of 3" while printing, "" while the page count isn't known.
    public static func pages(_ pages: Int?, _ printed: Int, _ s: JobState) -> String {
        guard let pages, pages > 0 else { return "" }
        if s == .processing && printed > 0 && printed < pages { return "Page \(printed + 1) of \(pages)" }
        return pages == 1 ? "1 page" : "\(pages) pages"
    }

    /// Submitted time: just the time for today's jobs, else the date too.
    public static func submitted(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.month(.wide).day()
        return "\(date.formatted(style)), \(time)"
    }

    /// CUPS's `job-originating-user-name` is the user's short name; a "DOMAIN\user" on either side is tolerated.
    public static func isOwner(_ owner: String, _ user: String) -> Bool {
        !owner.isEmpty && bare(owner).caseInsensitiveCompare(bare(user)) == .orderedSame
    }

    /// One line under the card title: "2 jobs, 1 printing".
    public static func summary(_ jobs: [QueueJob]) -> String {
        if jobs.isEmpty { return "Nothing waiting to print" }
        let printing = jobs.count(where: { $0.state == .processing })
        let what = jobs.count == 1 ? "1 job" : "\(jobs.count) jobs"
        return printing > 0 && jobs.count > 1 ? "\(what), \(printing) printing" : what
    }

    /// Oldest first, like the queue window.
    public static func order(_ jobs: [QueueJob]) -> [QueueJob] {
        jobs.sorted { ($0.submitted, $0.id) < ($1.submitted, $1.id) }
    }

    private static func bare(_ name: String) -> Substring {
        name.lastIndex(of: "\\").map { name[name.index(after: $0)...] } ?? name[...]
    }
}

/// Keeps overlapping refreshes of one list in order (the 3 s poll and the re-read after a cancel can both be in flight):
/// only the most recently started one may apply its result, so a slower, older read never puts finished jobs back. Also
/// counts failures in a row, so a queue that keeps failing is reported instead of hidden.
public struct RefreshGate: Sendable {
    private var latest = 0
    private var failures = 0
    private let failuresBeforeReport: Int

    public init(failuresBeforeReport: Int = 3) { self.failuresBeforeReport = failuresBeforeReport }

    /// Call before reading; pass the ticket to `succeeded` or `failed`.
    public mutating func begin() -> Int {
        latest += 1
        return latest
    }

    /// True when this read is the latest one started, so its result should be shown.
    public mutating func succeeded(_ ticket: Int) -> Bool {
        guard ticket == latest else { return false }
        failures = 0
        return true
    }

    /// True when this (latest) read failed and so did enough before it in a row to say so.
    public mutating func failed(_ ticket: Int) -> Bool {
        guard ticket == latest else { return false }
        failures += 1
        return failures >= failuresBeforeReport
    }
}
