import Foundation

/// A job on the printer as Get-Job-Attributes tells it (RFC 8011 §5.3.7 `job-state`: 3 pending … 9 completed).
public struct DirectJobState: Equatable, Sendable {
    public static let pending = 3, held = 4, processing = 5, stopped = 6, canceled = 7, aborted = 8, completed = 9

    public var state: Int
    public var reasons: [String]
    public var message: String?
    public var pagesDone: Int?

    public init(_ state: Int, _ reasons: [String], _ message: String?, _ pagesDone: Int?) {
        (self.state, self.reasons, self.message, self.pagesDone) = (state, reasons, message, pagesDone)
    }

    public var ended: Bool { state >= Self.canceled }
}

/// Why a job didn't go, in plain words; `mayHavePrinted` says whether the printer may have it anyway (Windows'
/// DirectPrintException).
public struct DirectPrintError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let mayHavePrinted: Bool
    /// The IPP status the printer answered with, for the log (never shown).
    public var ippStatus: UInt16?
    /// The printer didn't answer a question asked before anything was sent.
    public var notAnswering = false

    public init(_ message: String, mayHavePrinted: Bool, ippStatus: UInt16? = nil) {
        (self.message, self.mayHavePrinted, self.ippStatus) = (message, mayHavePrinted, ippStatus)
    }

    public var description: String { message }

    /// What an IPP call asked before sending throws when the printer doesn't answer: nothing went.
    public static func noAnswerBeforeSending() -> DirectPrintError {
        var e = DirectPrintError(loc("The printer doesn't answer. Nothing was sent."), mayHavePrinted: false)
        e.notAnswering = true
        return e
    }
}

/// One job sent straight to a printer over IPP: Print-Job with the job's attributes and the raster after them, then
/// Get-Job-Attributes until it ends, then Cancel-Job if asked. The requests are separate from the sending so the bytes are
/// tested.
public enum DirectJob {
    /// Print-Job's attributes (RFC 8011 §4.2.1.1, PWG 5100.14 §6): the operation's (user, job name, document format), then the
    /// job's: `copies` with `multiple-document-handling` (collated), `sides`, `print-color-mode`, `print-quality` and
    /// `media-col` (size, margins, type and source), each only when it says something.
    public static func printJobRequest(_ printerUri: String, user: String, jobName: String, _ plan: DirectPrintPlan, requestId: Int32 = 1) -> [UInt8] {
        var r = IppRequest(IppCodec.printJob, requestId: requestId, printerUri: printerUri)
        r.name("requesting-user-name", userName(user))
        r.name("job-name", jobName.isEmpty ? "Inkvolt Print" : jobName)
        r.mimeMediaType("document-format", plan.documentFormat)
        r.jobGroup()
        if plan.copies > 1 {
            // The plan has the printer make copies only when it collates them (PWG 5100.19's keyword); else it repeats the pages.
            r.integer("copies", plan.copies)
            r.keyword("multiple-document-handling", "separate-documents-collated-copies")
        }
        r.keyword("sides", plan.twoSided ? "two-sided-long-edge" : "one-sided")
        if let mode = plan.colorMode { r.keyword("print-color-mode", mode) }
        if let q = plan.quality { r.enumeration("print-quality", q) }
        let paper = plan.paper
        r.collection("media-col") { c in
            c.collection("media-size") { s in
                s.integer("x-dimension", paper.widthHmm)
                s.integer("y-dimension", paper.heightHmm)
            }
            c.integer("media-bottom-margin", paper.bottom)
            c.integer("media-left-margin", paper.left)
            c.integer("media-right-margin", paper.right)
            c.integer("media-top-margin", paper.top)
            if let type = plan.mediaType { c.keyword("media-type", type) }
            if let source = paper.source { c.keyword("media-source", source) }
        }
        return r.finished()
    }

    public static let jobAttributes = ["job-id", "job-state", "job-state-reasons", "job-state-message", "job-impressions-completed", "job-media-sheets-completed"]

    public static func getJobAttributesRequest(_ printerUri: String, user: String, jobId: Int, requestId: Int32 = 1) -> [UInt8] {
        var r = IppRequest(IppCodec.getJobAttributes, requestId: requestId, printerUri: printerUri)
        r.integer("job-id", jobId)
        r.name("requesting-user-name", userName(user))
        r.keywords("requested-attributes", jobAttributes)
        return r.finished()
    }

    public static func cancelJobRequest(_ printerUri: String, user: String, jobId: Int, requestId: Int32 = 1) -> [UInt8] {
        var r = IppRequest(IppCodec.cancelJob, requestId: requestId, printerUri: printerUri)
        r.integer("job-id", jobId)
        r.name("requesting-user-name", userName(user))
        return r.finished()
    }

    /// A user name the printer can show: the account name, never empty.
    static func userName(_ user: String) -> String {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? "Inkvolt Print" : u
    }

    /// A job's state from a Get-Job-Attributes or Print-Job answer; nil when it has none.
    public static func stateOf(_ r: IppResponse) -> DirectJobState? {
        guard let state = r.int("job-state"), (3...9).contains(state) else { return nil }
        let reasons = r.strs("job-state-reasons").prefix(IppClient.maxAlerts).filter { $0.utf8.count <= 255 }
        var message: String?
        let m = (r.str("job-state-message") ?? "").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { message = m.count > 200 ? String(m.prefix(200)) + "…" : m }
        var done: Int?
        if let i = r.int("job-impressions-completed"), (0...1_000_000).contains(i) { done = i }
        else if let s = r.int("job-media-sheets-completed"), (0...1_000_000).contains(s) { done = s }
        return DirectJobState(state, Array(reasons), message, done)
    }

    /// Sends the job: `upload`, a `DirectJobFile` begun with `printJobRequest`. Returns its id (0 when the printer gave none)
    /// and the state it answered with. A refusal before the document was read (bad request, unsupported format, busy) has sent
    /// nothing; an error after, or no answer, may have. Never cut by the caller's cancellation (Windows sends with
    /// `CancellationToken.None`): a job stopped halfway may print anyway, so once it starts it goes to the end, and a cancel
    /// after it is Cancel-Job (`stop`). Throws only `DirectPrintError`.
    public static func send(_ ipp: IppClient, _ upload: DirectJobUpload) async throws -> (jobId: Int, state: DirectJobState?) {
        let sending = Task.detached { () async throws -> IppResponse in
            try await ipp.printJob(file: upload.url, timeout: sendTimeout(upload.bytes))
        }
        let answer: IppResponse
        do {
            answer = try await sending.value
        } catch {
            throw DirectPrintError(loc("The printer stopped answering while the job was sent. Check it before printing again: it may have the job."),
                                   mayHavePrinted: true)
        }
        guard answer.ok else { throw DirectPrintError(refused(answer.statusCode), mayHavePrinted: false, ippStatus: answer.statusCode) }
        let id = answer.int("job-id").flatMap { $0 > 0 ? $0 : nil } ?? 0
        return (id, stateOf(answer))
    }

    /// Sends `document` (a whole raster, for the checks): written to a job file of its own first, deleted after.
    public static func send(_ ipp: IppClient, user: String, jobName: String, _ plan: DirectPrintPlan, document: [UInt8]) async throws -> (jobId: Int, state: DirectJobState?) {
        let url = DirectJobFile.temporaryUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try DirectJobFile(url, request: printJobRequest(ipp.printerUri, user: user, jobName: jobName, plan))
        try file.append(document)
        return try await send(ipp, try file.finish())
    }

    /// A job past `DirectJobFile.maxBytes`: refused before anything was sent, in the printer's own too-large words.
    public static func tooLarge() -> DirectPrintError { DirectPrintError(refused(0x0408), mayHavePrinted: false) }

    /// The printer didn't answer, or not in a way that can be read: what a request to it throws besides a refusal.
    public static func noAnswer(_ error: any Error) -> Bool {
        error is DeviceNetworkError || error is DeviceHttpError || error is IppFormatError
    }

    /// What `printerProblem` reads.
    public static let stateAttributes = ["printer-state", "printer-state-reasons", "printer-state-message", "printer-is-accepting-jobs",
                                         "printer-alert", "printer-alert-description"]

    /// Why nothing should be sent to the printer now, in plain words, or nil: it refused the question, isn't taking jobs, or
    /// is stopped (also with warnings alone) or reports an error (a jam, no paper, a door open, paused). Warnings (low ink)
    /// on a printer that isn't stopped don't stop anything. The printer's own words are shortened to one line.
    public static func printerProblem(_ r: IppResponse) -> String? {
        if !r.ok { return refused(r.statusCode) }
        if r.bool("printer-is-accepting-jobs") == false { return loc("The printer isn't taking jobs now.") }
        let status = IppClient.toStatus(r)
        // Stopped is a problem whatever the reasons say (a printer paused at its panel may list only warnings).
        if status.severity != .error && status.code != "stopped" { return nil }
        var said = status.alerts.first { $0.severity == .error }?.message ?? status.message
        said = said.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        while said.hasSuffix(".") { said.removeLast() }
        if said.count > 120 { said = String(said.prefix(120)) + "…" }
        return (said.isEmpty ? loc("Stopped") : said) + "."
    }

    /// A minute, and a minute more for every 20 MB (a busy printer reads slowly), at most 30 minutes.
    static func sendTimeout(_ bytes: Int) -> Duration { .seconds(60 * min(30, 1 + bytes / (20 << 20))) }

    /// RFC 8011 §13.1.4 client errors and §13.1.5 server errors, in plain words.
    public static func refused(_ status: UInt16) -> String {
        switch status {
        // forbidden, not-authenticated, not-authorized
        case 0x0401, 0x0402, 0x0403:
            // Mac difference: the way round it is a macOS queue (Set Up in macOS), not a Windows one.
            return loc("The printer wants a signed-in user for printing. Set it up in macOS and print through it, or allow printing without signing in on its web page.")
        // request-entity-too-large
        case 0x0408: return loc("The printer can't take a job this large. Print fewer pages at a time.")
        // document-format-not-supported, attributes-or-values-not-supported, conflicting-attributes, compression-not-supported,
        // compression-error, document-format-error, document-unprintable-error
        case 0x040A, 0x040B, 0x040E, 0x040F, 0x0410, 0x0411, 0x041B:
            return loc("The printer refused the pages: it didn't take their format or settings. Nothing was printed.")
        // service-unavailable, temporary-error, not-accepting-jobs, busy
        case 0x0502, 0x0505, 0x0506, 0x0507: return loc("The printer is busy and took nothing. Try again in a minute.")
        // job-canceled: cancelled at the printer while it came in
        case 0x0508: return loc("Cancelled at the printer")
        // the rest (bad-request, uri-scheme-not-supported, internal-error, device-error…): refused, no more said
        default: return loc("The printer refused the job. Nothing was printed.")
        }
    }

    /// The longest a job is followed, however it keeps changing (a printer whose page count goes back and forth): 2 hours.
    public static let watchLongest: Duration = .seconds(2 * 60 * 60)

    /// Asks how the job is doing every `every` until it ends, reporting each change, and returns its last state. Stops asking
    /// (returning what it knows) when the task is cancelled, nothing changes for `quiet`, or after `longest` in all: the
    /// printer has the job by then, and its own panel says the rest (`followedTooLong` says which).
    public static func watch(_ ipp: IppClient, user: String, jobId: Int, every: Duration, quiet: Duration, longest: Duration = watchLongest,
                             clock: ContinuousClock = ContinuousClock(), progress: (@Sendable (DirectJobState) -> Void)? = nil) async -> DirectJobState? {
        var last: DirectJobState?
        let started = clock.now
        var since = started
        var failures = 0
        while !Task.isCancelled && clock.now - since < quiet && clock.now - started < longest {
            do {
                let r = try await ipp.getJobAttributes(getJobAttributesRequest(ipp.printerUri, user: user, jobId: jobId))
                if r.statusCode == 0x0406 { return last ?? DirectJobState(DirectJobState.completed, [], nil, nil) } // gone: done and forgotten
                if let state = stateOf(r) {
                    if last == nil || (state != last && (state.state != last!.state || state.pagesDone != last!.pagesDone || state.reasons != last!.reasons)) {
                        progress?(state)
                        since = clock.now
                    }
                    last = state
                    if state.ended { return state }
                }
                failures = 0
            } catch {
                if Task.isCancelled { break }
                failures += 1
                if failures >= 5 { break } // the printer stopped answering about it: it has the job
            }
            do { try await Task.sleep(for: every) } catch { break }
        }
        return last
    }

    /// What the end of a watch says when it stopped after `longest` with the job not ended, or nil (it ended, went quiet, or
    /// stopped answering: its last state says the rest).
    public static func followedTooLong(_ last: DirectJobState?, after followed: Duration, longest: Duration = watchLongest) -> String? {
        guard last?.ended != true, followed >= longest else { return nil }
        return loc("Inkvolt Print stopped following the job after 2 hours. The printer's control panel shows how it's going.")
    }

    /// Cancel-Job, once. True when the printer took it (or the job was already gone). Sent whether or not the caller is
    /// cancelled (Windows' CancelAsync has no token): it's what a cancel asks for.
    public static func cancel(_ ipp: IppClient, user: String, jobId: Int) async -> Bool {
        let request = cancelJobRequest(ipp.printerUri, user: user, jobId: jobId)
        let asking = Task.detached { () async -> Bool in
            do {
                let r = try await ipp.cancelJob(request)
                // client-error-not-possible (it already ended), not-found, gone: nothing left to stop
                return r.ok || [0x0404, 0x0406, 0x0407].contains(r.statusCode)
            } catch {
                return false
            }
        }
        return await asking.value
    }

    /// The person cancelled a job the printer has: Cancel-Job, then a `CancellationError` when the printer took it, or a
    /// `DirectPrintError` saying it may still print when the printer refused or didn't answer. Always throws.
    public static func stop(_ ipp: IppClient, user: String, jobId: Int) async throws -> Never {
        if !(await cancel(ipp, user: user, jobId: jobId)) {
            throw DirectPrintError(loc("The printer didn't take the cancel, so the job may still print. Cancel it on the printer's control panel."),
                                   mayHavePrinted: true)
        }
        throw CancellationError()
    }

    /// The state in the app's words: "Printing page 3 of 4", "Printed", "Waiting: …", for the line under Print.
    public static func describe(_ state: DirectJobState, pages: Int) -> String {
        let reason = self.reason(state.reasons)
        switch state.state {
        case DirectJobState.completed where state.reasons.contains("job-completed-with-errors"): return loc("Printed, with errors the printer reported")
        case DirectJobState.completed: return loc("Printed")
        case DirectJobState.canceled: return loc("Cancelled at the printer")
        case DirectJobState.aborted: return reason.map { loc("The printer stopped the job: {0}", $0) } ?? loc("The printer stopped the job")
        case DirectJobState.stopped, DirectJobState.held: return loc("Waiting: {0}", reason ?? state.message ?? loc("the printer is stopped"))
        case DirectJobState.processing:
            if let done = state.pagesDone, pages > 0 { return loc("Printing page {0} of {1}", min(done + 1, pages), pages) }
            return loc("Printing")
        default: return loc("Waiting its turn at the printer")
        }
    }

    /// The job-state-reasons that need the person, in plain words (RFC 8011 §5.3.8, PWG 5100.7), or nil.
    public static func reason(_ reasons: [String]) -> String? {
        for r in reasons {
            switch r {
            case "document-format-error", "unsupported-document-format", "document-unprintable-error": return loc("it couldn't read the pages")
            case "job-hold-until-specified", "job-held-for-authorization", "job-password-wait": return loc("it holds the job until it's released at the printer")
            case "printer-stopped", "printer-stopped-partly": return loc("the printer is stopped")
            case "resources-are-not-ready": return loc("it needs paper, or another paper")
            case "job-canceled-at-device": return loc("Cancelled at the printer")
            default: continue
            }
        }
        return nil
    }
}

/// Where a print goes: the printer's macOS queue (Windows: its Windows queue), straight to the printer over IPP, or nowhere.
public enum PrintRoute: Sendable, Equatable {
    case none, queue, direct
}

public enum PrintRoutes {
    /// The queue stays the default where one exists; straight to the printer when there is none, or when the person chose it
    /// for this printer. Either needs the printer to take one of the raster formats. Mac difference: the app never passes
    /// `personChoseDirect` (no choice is offered: a macOS queue for an IPP printer is already driverless, AirPrint or IPP
    /// Everywhere, where a Windows queue may carry a maker's driver that fails).
    public static func choose(hasQueue: Bool, printerTakesRaster: Bool, personChoseDirect: Bool) -> PrintRoute {
        if printerTakesRaster && (personChoseDirect || !hasQueue) { return .direct }
        return hasQueue ? .queue : .none
    }
}

/// The jobs a printer printed to without a queue holds (Get-Jobs), as `QueueJob`s (Windows' `PrinterJobs`, the parts the Mac
/// uses: the list a direct printer's queue card would show is Open, PLAN P12 2.1).
public enum PrinterJobs {
    /// Most jobs listed: a printer holds a handful.
    public static let maxJobs = 100

    /// Get-Jobs' `which-jobs` (RFC 8011 §4.2.6.1): the jobs still to print or printing, and the ones that ended.
    public static let notCompleted = "not-completed", completed = "completed"

    private static let wanted = [
        "job-id", "job-name", "job-state", "job-state-reasons", "job-originating-user-name", "job-originating-host-name", "job-impressions",
        "job-impressions-completed", "date-time-at-creation", "date-time-at-completed",
    ]

    public static func getJobsRequest(_ printerUri: String, user: String, requestId: Int32 = 1, which: String = notCompleted) -> [UInt8] {
        var r = IppRequest(IppCodec.getJobs, requestId: requestId, printerUri: printerUri)
        r.name("requesting-user-name", DirectJob.userName(user))
        r.integer("limit", maxJobs)
        r.keyword("which-jobs", which)
        r.keywords("requested-attributes", wanted)
        return r.finished()
    }

    /// The jobs in a Get-Jobs answer in the card's order (oldest first); `now` stands in for a job's missing creation time.
    public static func parse(_ answer: [UInt8], now: Date) throws -> [QueueJob] {
        let (status, groups, _) = try IppCodec.decodeGroups(answer)
        if status >= 0x0100 { throw DirectPrintError(DirectJob.refused(status), mayHavePrinted: false, ippStatus: status) }
        var jobs: [QueueJob] = []
        for g in groups where g.tag == IppCodec.jobTag {
            let job = IppResponse(statusCode: status, attributes: g.attributes)
            guard let id = job.int("job-id"), id > 0, let state = DirectJob.stateOf(job), let jobState = JobState(rawValue: state.state) else { continue }
            let name = (job.str("job-name") ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let owner = (job.str("job-originating-user-name") ?? "").trimmingCharacters(in: .whitespaces)
            let pages = job.int("job-impressions").flatMap { (0...1_000_000).contains($0) ? $0 : nil }
            var created: Date?
            if case .date(let d)? = g.attributes["date-time-at-creation"]?.first { created = d }
            var ended: Date?
            if case .date(let d)? = g.attributes["date-time-at-completed"]?.first { ended = d }
            jobs.append(QueueJob(id: id, name: short(name, 120), pages: pages, pagesPrinted: state.pagesDone ?? 0, state: jobState,
                                 submitted: created ?? now, owner: short(owner, 60), finished: ended, machine: host(job.str("job-originating-host-name"))))
            if jobs.count >= maxJobs { break }
        }
        return QueueJobText.order(jobs)
    }

    /// The computer a job came from, where the printer names it; an address, `localhost` or anything that isn't a plain host
    /// name is left out.
    private static func host(_ host: String?) -> String? {
        let h = (host ?? "").trimmingCharacters(in: .whitespaces)
        guard (1...255).contains(h.utf8.count), h.lowercased() != "localhost" else { return nil }
        let bare = h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") || bare.split(separator: ".").count == 4 && bare.split(separator: ".").allSatisfy({ Int($0) != nil }) { return nil }
        return h.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0)) } ? h : nil
    }

    private static func short(_ s: String, _ most: Int) -> String { s.count > most ? String(s.prefix(most)) + "…" : s }
}
