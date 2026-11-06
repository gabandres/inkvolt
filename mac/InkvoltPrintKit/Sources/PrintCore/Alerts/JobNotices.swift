import Foundation

/// One job from an IPP Get-Jobs reply's job-attributes group, for job alerts (roadmap 3.4). PrintMac asks cupsd over its
/// socket, not `cupsGetJobs2`, because only Get-Jobs gives `job-originating-host-name` (`localhost` for a job this Mac sent:
/// `JobOwner` then knows it's yours on a shared queue too) and the sheets printed; seen on ignia-mac, 2026-11-05. Values come
/// as text by attribute name (the first value of each); what cupsd hides of other users' jobs is simply missing.
public enum QueueJobAttributes {
    public static let requested = [
        "job-id", "job-name", "job-state", "job-originating-user-name", "job-originating-host-name", "time-at-creation",
        "time-at-completed", "job-k-octets", "job-media-sheets-completed",
    ]

    /// The jobs CUPS gave up on read each time, newest first (Get-Jobs' `limit`; cupsd lists finished jobs by when they
    /// finished, the latest first): read every minute, only one from the last `JobQueueState.abortedKeptFor` is followed, so
    /// a queue's whole history isn't read each minute.
    public static let abortedLimit = 20

    /// A document's name, a user and a host are kept to this many characters (a notification shows far fewer).
    public static let maxName = 1024

    /// The job, or nil without a job id or a job state it knows. Numbers out of range are left at nothing: a size or a count
    /// from a hostile reply never overflows, and a time before 1970 is 1970.
    public static func job(_ a: [String: String]) -> QueueJob? {
        guard let id = number(a["job-id"]), id > 0, id <= Int(Int32.max),
              let raw = number(a["job-state"]), let state = JobState(rawValue: raw) else { return nil }
        let name = text(a["job-name"])
        let kilobytes = number(a["job-k-octets"]).map { Int64($0) } ?? 0
        let bytes = kilobytes > 0 && kilobytes <= Int64(Int32.max) ? kilobytes * 1024 : 0
        return QueueJob(id: id, name: name.isEmpty ? AlertText.untitled : name, pages: nil,
                        pagesPrinted: max(0, min(number(a["job-media-sheets-completed"]) ?? 0, Int(Int32.max))), state: state,
                        submitted: time(a["time-at-creation"]) ?? Date(timeIntervalSince1970: 0), owner: text(a["job-originating-user-name"]),
                        bytes: bytes, finished: time(a["time-at-completed"]), machine: a["job-originating-host-name"].map(text))
    }

    private static func number(_ s: String?) -> Int? {
        guard let s, let n = Int(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return n
    }

    /// Seconds since 1970 (CUPS's times); nil when missing or not a number, 1970 for one before it.
    private static func time(_ s: String?) -> Date? {
        guard let n = number(s), n < Int(Int32.max) * 4 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(max(0, n)))
    }

    private static func text(_ s: String?) -> String { String((s ?? "").prefix(maxName)) }
}

/// How the alerts read at once become notifications (the Windows app's `AlertToasts.PerPrinter` and `Text`, for jobs): the
/// printers' problems together, as before (`TrayText.notice`), and each job its own, with Open the queue, except that more
/// than `maxJobNotices` from one printer at once share one, so a dead printer doesn't fill the screen.
public enum JobNotices {
    public static let maxJobNotices = 3

    /// The printers' alerts, and the job notifications in the order their printers first appear.
    public static func split(_ notices: [AlertNotice]) -> (printers: [AlertNotice], jobs: [[AlertNotice]]) {
        let printers = notices.filter { $0.jobKey == nil }
        var order: [String] = []
        var byPrinter: [String: [AlertNotice]] = [:]
        for n in notices where n.jobKey != nil {
            let key = n.uuid.lowercased()
            if byPrinter[key] == nil { order.append(key) }
            byPrinter[key, default: []].append(n)
        }
        let jobs = order.flatMap { key -> [[AlertNotice]] in
            let list = byPrinter[key] ?? []
            return list.count > maxJobNotices ? [list] : list.map { [$0] }
        }
        return (printers, jobs)
    }

    /// One job notification's title and text: one job as it is; several, a count and the first few.
    public static func text(_ jobs: [AlertNotice]) -> (title: String, text: String) {
        guard jobs.count > 1 else { return (jobs.first?.title ?? "", jobs.first?.body ?? "") }
        var lines = jobs.prefix(maxJobNotices).map(\.title)
        if jobs.count > lines.count { lines.append(loc("and {0} more", jobs.count - lines.count)) }
        return (loc("{0} print jobs need attention", jobs.count), lines.joined(separator: "\n"))
    }
}
