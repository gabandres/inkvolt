import Foundation

/// One read of a printer's CUPS queue, for job alerts (the Windows app's `JobQueueState`): whether macOS holds its jobs, whether
/// the queue says its printer can't be reached, and the jobs. Windows' Use Printer Offline has no macOS counterpart; the
/// offline reason stands in for the spooler's own "can't take it" bits on a job (PaperOut, Offline).
public struct JobQueueState: Equatable, Sendable {
    /// macOS stopped the queue (`printer-state` 5): paused by someone, or by macOS on a failed job.
    public var paused: Bool
    /// The queue says its printer can't be reached (`offline-report`, as `CupsStatus.describe` reads it).
    public var printerOffline: Bool
    /// Other computers may print to the queue (`CupsDestination.othersMayPrint`): a job that doesn't say where it came from
    /// may be another computer's (`JobOwner.owns`). True unless known otherwise.
    public var othersMayPrint: Bool
    public var jobs: [QueueJob]

    public init(paused: Bool, printerOffline: Bool, othersMayPrint: Bool = true, jobs: [QueueJob]) {
        self.paused = paused
        self.printerOffline = printerOffline
        self.othersMayPrint = othersMayPrint
        self.jobs = jobs
    }

    /// A job CUPS gave up on stays to be told this long after it finished: CUPS keeps finished jobs in its history, and a
    /// failure from before the app started is no news.
    public static let abortedKeptFor: TimeInterval = 15 * 60

    /// The state from a destination and its jobs as CUPS lists them (every job, finished ones included, or only the
    /// unfinished ones): printed and cancelled jobs have left the queue, as on Windows; a job CUPS gave up on stays while
    /// it's recent.
    public static func of(_ d: CupsDestination, jobs: [QueueJob], now: Date) -> JobQueueState {
        let kept = jobs.filter { j in
            switch j.state {
            case .completed, .canceled: false
            case .aborted: j.finished.map { now.timeIntervalSince($0) < abortedKeptFor } ?? true
            case .pending, .held, .processing, .stopped: true
            }
        }
        return JobQueueState(paused: d.state == 5, printerOffline: CupsStatus.describe(d).offline, othersMayPrint: d.othersMayPrint, jobs: kept)
    }
}

/// Who "you" are on a queue (the Windows app's `JobOwner`): this Mac's user to CUPS (`PrintQueues.user`). Stricter than
/// `QueueJobText.isOwner`, which only decides who sees a Cancel button: two computers sharing a printer often have the same
/// user name, so a job that says which domain or computer it came from must say this one. When in doubt the job isn't
/// yours: another person's document is never named. Stricter than Windows' in three ways, since a Mac's user has no domain
/// and `cupsGetJobs2` says nothing of where a job came from: a domain or computer this Mac can't compare with isn't a
/// match, a job that doesn't say where it came from is yours only on a queue no other computer prints to
/// (`othersMayPrint`), and one CUPS says came from this Mac (`job-originating-host-name` localhost, when the reader asks
/// for it) is yours on any queue. On the Mac: `userName` is `PrintQueues.user`, `domain` nil, `machine` the Mac's name.
public struct JobOwner: Equatable, Sendable {
    public var userName: String?
    public var domain: String?
    public var machine: String?

    public init(userName: String?, domain: String? = nil, machine: String? = nil) {
        self.userName = userName
        self.domain = domain
        self.machine = machine
    }

    /// `othersMayPrint`: other computers may print to the job's queue (`JobQueueState.othersMayPrint`).
    public func owns(_ job: QueueJob, othersMayPrint: Bool = true) -> Bool {
        let owner = job.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, let user = userName?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else { return false }
        let slash = owner.lastIndex(of: "\\")
        let name = slash.map { String(owner[owner.index(after: $0)...]) } ?? owner
        guard name.caseInsensitiveCompare(user) == .orderedSame else { return false }
        if let slash, slash > owner.startIndex {
            let domain = (domain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !domain.isEmpty, String(owner[..<slash]).caseInsensitiveCompare(domain) == .orderedSame else { return false }
        }
        if Self.isThisComputer(job.machine) { return true }
        let from = Self.host(job.machine), here = Self.host(machine)
        if from.isEmpty { return !othersMayPrint }
        return !here.isEmpty && from.caseInsensitiveCompare(here) == .orderedSame
    }

    /// "localhost", 127.x.x.x or ::1: what CUPS gives as `job-originating-host-name` for a job sent from this computer.
    static func isThisComputer(_ machine: String?) -> Bool {
        let host = (machine ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { p in JobRules.digits(p).flatMap { Int($0) }.map { $0 <= 255 } == true }
    }

    /// "\\PC.office.lan" as "PC", at most 15 characters: Windows' short name for a PC is cut there, its full name isn't.
    private static func host(_ machine: String?) -> String {
        var host = Substring((machine ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        while host.first == "\\" { host = host.dropFirst() }
        if let dot = host.firstIndex(of: "."), dot > host.startIndex { host = host[..<dot] }
        return String(host.prefix(15))
    }
}

/// What a printer's last read says for a job that isn't moving: it's idle, it says it's working, or it can't be expected to move it.
public enum PrinterWork: Equatable, Sendable { case notReady, ready, printing }

/// How far a job has got, as far as CUPS says (the Windows app's `JobProgress`): pages printed and pages (never from
/// `cupsGetJobs2`, which has no counts; kept for a reader that has them), its size, how far along it is (`JobRules.stage`),
/// and how many times someone restarted it. Forward is any of them above the furthest seen. A state going back and forth or
/// a count going down isn't forward, so flicker neither passes for progress nor hides a hung job.
public struct JobProgress: Equatable, Sendable {
    public var printed = 0, pages = 0, stage = 0
    public var bytes: Int64 = 0
    public var restarts = 0

    public init() {}

    public init(printed: Int, pages: Int, stage: Int, bytes: Int64, restarts: Int) {
        (self.printed, self.pages, self.stage, self.bytes, self.restarts) = (printed, pages, stage, bytes, restarts)
    }

    public static func of(_ job: QueueJob) -> JobProgress {
        JobProgress(printed: job.pagesPrinted, pages: job.pages ?? 0, stage: JobRules.stage(job.state), bytes: job.bytes, restarts: 0)
    }

    public func beyond(_ other: JobProgress) -> Bool {
        printed > other.printed || pages > other.pages || stage > other.stage || bytes > other.bytes || restarts > other.restarts
    }

    public func furthest(_ other: JobProgress) -> JobProgress {
        JobProgress(printed: max(printed, other.printed), pages: max(pages, other.pages), stage: max(stage, other.stage),
                    bytes: max(bytes, other.bytes), restarts: max(restarts, other.restarts))
    }
}

/// What a job's state means for job alerts (the Windows app's `JobRules`, on CUPS's `job-state` instead of the spooler's
/// bits). A job is one job for as long as its id and the moment it was submitted stay the same: `key` keeps a reused id
/// apart, and says nothing about the document, so it's what gets remembered in the state file.
public enum JobRules {
    public static let keyPrefix = "Job|"

    /// "Job|id|milliseconds since 1970" (Windows writes .NET ticks; the two apps' state files are their own).
    public static func key(_ job: QueueJob) -> String {
        let ms = Int64(exactly: (job.submitted.timeIntervalSince1970 * 1000).rounded()) ?? 0
        return "\(keyPrefix)\(job.id)|\(ms)"
    }

    /// A key this version wrote (remembered keys come from a file that may have been edited).
    public static func isKey(_ key: String) -> Bool {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "Job" && digits(parts[1]).flatMap { Int($0) } != nil && digits(parts[2]).flatMap { Int64($0) } != nil
    }

    /// The text when it's ASCII digits only (no sign, no other script's digits, which `Int("+7")` and the like would take).
    static func digits(_ s: Substring) -> Substring? { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } ? s : nil }

    /// Printed, or cancelled: it has left the queue, or will.
    public static func isFinishing(_ s: JobState) -> Bool { s == .completed || s == .canceled }

    /// The job can't go on without someone: CUPS stopped it (`processing-stopped`, the queue stopped under it) or gave up on
    /// it (`aborted`, a filter or the backend failed). `cupsGetJobs2` gives no `job-state-reasons`, so there's no telling
    /// a jam from a queue someone paused mid-job; a job held by hand isn't failing.
    public static func isFailed(_ s: JobState) -> Bool { s == .stopped || s == .aborted }

    /// Could be moving if nothing held it: waiting, printing, or stopped mid-job (a stopped first job stands for those behind
    /// it). Held by hand, finished and given up on aren't (CUPS prints the next job after an aborted one).
    public static func shouldMove(_ s: JobState) -> Bool { s == .pending || s == .processing || s == .stopped }

    /// How far along a job is: waiting, printing, done. Only ever read upward (`JobProgress`).
    public static func stage(_ s: JobState) -> Int {
        switch s {
        case .completed: 3
        case .processing, .stopped: 2
        case .pending, .held, .canceled, .aborted: 1
        }
    }

    /// Someone restarted it: a job CUPS had finished with (Restart-Job) is waiting or printing again. Windows has a bit for it.
    public static func isRestart(from old: JobState, to new: JobState) -> Bool {
        (old == .aborted || isFinishing(old)) && shouldMove(new) && new != .stopped
    }

    /// Why a failed job failed, after the printer's name in the notification.
    public static func reason(_ s: JobState) -> String { s == .aborted ? "macOS gave up on this job" : "macOS stopped this job" }

    /// Ready: answering, ready or asleep (it wakes for a job), nothing wrong, not waiting for someone at the manual feed.
    /// Printing: the same but saying it's printing, where the job may simply be long, so it gets the longer wait.
    public static func work(_ snap: PrinterSnapshot) -> PrinterWork {
        guard snap.reachable, let status = snap.status, !status.isUnavailable, status.severity != .error,
              !status.alerts.contains(where: { $0.severity == .error || $0.id.range(of: "manual", options: .caseInsensitive) != nil }) else {
            return .notReady
        }
        switch status.code {
        case "ready", "idle", "inPowerSave": return .ready
        case "processing", "printing": return .printing
        default: return .notReady
        }
    }
}

/// Text from outside the app (a document's name comes from whatever printed it; a printer's name from its queue or the
/// printer) made safe to show in a notification (the Windows app's `AlertText`). Nothing is interpreted: a notification's
/// text is plain text. This takes out what can make text lie about itself (right-to-left overrides, invisible characters,
/// line breaks that fake another line) and what's too long, and leaves whole characters. Lengths are counted in UTF-16, as
/// on Windows, so the two apps cut a name at the same place.
public enum AlertText {
    /// A document's name in a title, leaving room for the words around it in a balloon's 63 characters.
    public static let maxDocument = 48
    public static let maxPrinter = 60
    public static let untitled = "Untitled"

    /// A job's document as a notification names it: a path or address is cut to its last part, which also keeps folders
    /// and links off the screen.
    public static func document(_ name: String?) -> String {
        let shown = cut(lastPart(clean(name, Int.max)), maxDocument)
        return shown.isEmpty ? untitled : shown
    }

    public static func printer(_ name: String?) -> String {
        let shown = clean(name, maxPrinter)
        return shown.isEmpty ? "the printer" : shown
    }

    /// One line of visible characters: controls, invisible, private-use and unassigned characters out, runs of space as one.
    public static func clean(_ text: String?, _ max: Int) -> String {
        guard let text, !text.isEmpty else { return "" }
        var out = String.UnicodeScalarView()
        var kept = 0
        var pendingSpace = false
        for s in text.unicodeScalars {
            if kept >= 4096 { break }
            if s.properties.isWhitespace {
                pendingSpace = kept > 0
                continue
            }
            switch s.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator: continue
            default: break
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(s)
            kept += 1
        }
        return cut(String(out), max)
    }

    /// "C:\Users\me\Taxes\return.pdf", "/Users/me/Taxes/return.pdf" or "https://host/a/b.pdf?token=x" as the file's name; a
    /// plain title stays as it is.
    static func lastPart(_ text: String) -> String {
        let chars = Array(text)
        func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        func isSlash(_ c: Character) -> Bool { c == "\\" || c == "/" }
        let isAddress = text.contains("://")
        let isDrive = chars.count > 2 && isLetter(chars[0]) && chars[1] == ":" && isSlash(chars[2])
        let isPath = text.hasPrefix("\\\\") || isDrive || text.hasPrefix("/") || text.hasPrefix("~/")
        if !isAddress && !isPath {
            // "Microsoft Word - C:\Users\me\return.docx": the words stay, the folders don't.
            var inside: Int?
            for i in chars.indices where i + 2 < chars.count && chars[i] == " " && chars[i + 1] == "\\" && chars[i + 2] == "\\" {
                inside = i
                break
            }
            var i = 1
            while inside == nil && i + 3 < chars.count {
                if chars[i] == " " && isLetter(chars[i + 1]) && chars[i + 2] == ":" && isSlash(chars[i + 3]) { inside = i }
                i += 1
            }
            guard let inside else { return text }
            return String(chars[...inside]) + lastPart(String(chars[(inside + 1)...]))
        }
        var path = Substring(text)
        if isAddress, let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<end] }
        while let c = path.last, isSlash(c) { path = path.dropLast() }
        let last = path.lastIndex(where: isSlash).map { path[path.index(after: $0)...] } ?? path
        return !last.isEmpty && !last.hasSuffix(":") ? String(last) : text
    }

    /// At most `max` UTF-16 units, cut between whole characters (a pair or an accent is never split).
    static func cut(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        var head = ""
        var used = 0
        for c in text {
            let length = c.utf16.count
            if used + length > max - 1 { break }
            used += length
            head.append(c)
        }
        while head.last?.isWhitespace == true { head.removeLast() }
        return head + "…"
    }
}

extension AlertRules {
    /// The Settings checkbox's explanation ("Tell me when my own print job fails or gets stuck").
    public var jobsNote: String {
        "Naming the document and the printer: macOS stops or gives up on the job, or it hasn't moved for \(JobText.minutes(jobStuckAfter)) minutes "
            + "while the printer is ready, or \(JobText.minutes(jobHungAfter)) minutes while the printer says it's printing (macOS gives no page "
            + "counts, so a long job can raise this by mistake). A stuck job is told again only after real progress, at most \(jobMaxStuckAlerts) "
            + "times. Other people's jobs never raise one. The notification shows the document's name, also on the lock screen if macOS shows "
            + "notifications there; Inkvolt Print doesn't keep it or log it."
    }
}

/// The job notifications' words.
enum JobText {
    static func minutes(_ seconds: TimeInterval) -> Int { Int(exactly: (seconds / 60).rounded()) ?? 0 }

    static func failed(_ document: String, _ printer: String, _ reason: String) -> (title: String, body: String) {
        ("“\(document)” didn't print", "\(printer): \(reason). Open the queue to cancel it or print it again.")
    }

    static func stuck(_ document: String, _ printer: String, _ wait: TimeInterval) -> (title: String, body: String) {
        ("“\(document)” isn't moving",
         "\(printer) is ready, but this job hasn't moved for \(minutes(wait)) minutes. Open the queue to cancel it or print it again.")
    }

    static func hung(_ document: String, _ printer: String, _ wait: TimeInterval) -> (title: String, body: String) {
        ("“\(document)” may be stuck",
         "\(printer) says it's printing, but this job hasn't moved for \(minutes(wait)) minutes and may be stuck. Open the queue to cancel it or print it again.")
    }
}
