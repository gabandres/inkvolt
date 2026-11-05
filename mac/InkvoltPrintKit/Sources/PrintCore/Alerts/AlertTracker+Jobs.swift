import Foundation

/// One job as job alerts follow it (the Windows app's `AlertTracker.JobTrack`).
final class JobTrack {
    let key: String
    var name = "", reason = "", printerName = ""
    var state = JobState.pending
    var seen = false, mine = false, failedTold = false, marked = false, dueWhilePrinting = false
    var stuckTold = 0
    /// The furthest the job has been seen, and how far it was at its last alert (`marked`: it has had one).
    var best = JobProgress(), mark = JobProgress()
    var firstSeen = Date.distantPast
    var failedSince: Date?, absentSince: Date?
    /// Reads in a row it was missing from, up to `AlertTracker.jobGoneAfterReads`.
    var missed = 0
    var due: AlertKind?

    init(_ key: String) { self.key = key }

    /// Stuck may be told: never told yet, or moved on since, and under the cap.
    func mayTellStuck(_ max: Int) -> Bool { stuckTold < max && (!marked || best.beyond(mark)) }

    /// Worth keeping across a restart.
    var remembered: Bool { failedTold || marked }

    func line() -> String {
        "\(key)|\(failedTold ? 1 : 0)|\(stuckTold)|\(mark.printed)|\(mark.pages)|\(mark.stage)|\(mark.bytes)|\(mark.restarts)"
    }

    static func parse(_ line: String) -> JobTrack? {
        let p = line.split(separator: "|", omittingEmptySubsequences: false)
        guard p.count == 10 else { return nil }
        let key = p[0..<3].joined(separator: "|")
        guard JobRules.isKey(key) else { return nil }
        func int(_ s: Substring) -> Int? { JobRules.digits(s).flatMap { Int($0) } }
        guard let failed = int(p[3]), let stuck = int(p[4]), let printed = int(p[5]), let pages = int(p[6]), let stage = int(p[7]),
              let bytes = JobRules.digits(p[8]).flatMap({ Int64($0) }), let restarts = int(p[9]) else { return nil }
        let t = JobTrack(key)
        let mark = JobProgress(printed: printed, pages: pages, stage: stage, bytes: bytes, restarts: restarts)
        (t.failedTold, t.stuckTold, t.marked, t.mark, t.best) = (failed != 0, stuck, true, mark, mark)
        return t
    }
}

/// A printer's queue as job alerts follow it: its jobs in the order first seen, and the stuck clock.
final class JobQueueTrack {
    var jobs: [String: JobTrack] = [:]
    var order: [String] = []
    /// The last queue read; nothing has moved since; the printer has said it's ready since; when the wait runs out.
    var lastRead: Date?, stillSince: Date?, readySince: Date?, stuckAt: Date?

    func track(_ key: String) -> JobTrack {
        if let t = jobs[key] { return t }
        let t = JobTrack(key)
        jobs[key] = t
        order.append(key)
        return t
    }

    func remove(_ key: String) {
        jobs[key] = nil
        order.removeAll { $0 == key }
    }
}

/// Job notifications (roadmap 3.4, the Windows app's `AlertTracker.Jobs`): fed each read of a printer's CUPS queue, it says
/// which of your own jobs to tell about.
/// - **Failed**: `JobRules.isFailed` for `AlertRules.errorHold`, whatever the printer says. Once per job, even if it had been
///   told stuck: a job that failed is news.
/// - **Stuck**: your first job in the queue, with nothing in the queue moving while the queue runs, for
///   `AlertRules.jobStuckAfter` with the printer saying it's ready, or `jobHungAfter` with it saying it's printing (worded
///   "may be stuck": with no page counts from CUPS a long job looks the same). Moving means `JobProgress` going forward on
///   any job in the queue, or a job leaving (missing from `jobGoneAfterReads` reads in a row, as of the first: one read
///   that misses a job decides nothing stuck, and doesn't start a wait again; Windows counts the first miss as leaving), so
///   a job waiting its turn isn't stuck, and flicker doesn't count. Jobs behind
///   your first one wait for it. The clock starts when the job is first seen, so a restart gives it the full time again.
/// - **Told again**: a job told stuck is told again only after real progress since its last alert, at most
///   `jobMaxStuckAlerts` times. What decides that survives restarts (`shown()`): the job's key, its counts and its progress
///   when last told, never the document's name.
/// Quiet hours, a pause and alerts turned off work as for any other alert. Jobs don't color the menu bar icon.
extension AlertTracker {
    static let maxRememberedJobs = 256
    /// A job missing from this many reads in a row has left the queue.
    static let jobGoneAfterReads = 2

    func rememberJob(_ uuid: String, _ line: String) {
        let q = printer(uuid).queue
        guard let t = JobTrack.parse(line), q.jobs.count < Self.maxRememberedJobs else { return }
        if q.jobs[t.key] == nil { q.order.append(t.key) }
        q.jobs[t.key] = t
    }

    /// Takes in one read of a printer's queue (nil: it has no queue now); returns the alerts to show now. `me`: who this
    /// Mac's user is to CUPS.
    public func observeJobs(_ uuid: String, printerName: String, _ queue: JobQueueState?, me: JobOwner, now: Date) -> [AlertNotice] {
        guard rules.jobs else { return release(now: now) }
        let p = printer(uuid)
        let q = p.queue
        // Reads come every minute: a gap as long as the shorter wait (the Mac slept) says nothing about what the job did meanwhile.
        if let last = q.lastRead, now.timeIntervalSince(last) > rules.jobStuckAfter { Self.restartJobClocks(q) }
        q.lastRead = now

        let jobs = QueueJobText.order(queue?.jobs ?? [])
        let moved = takeIn(jobs, q, printerName: printerName, me: me, othersMayPrint: queue?.othersMayPrint ?? true, now: now)
        let running = queue.map { !$0.paused && !$0.printerOffline } == true && (p.work == .ready || p.work == .printing)
        if !running {
            Self.stopStuckClock(q)
        } else {
            q.stillSince = Self.since(q.stillSince, moved, now)
            q.readySince = p.work != .ready ? nil : Self.since(q.readySince, moved, now)
        }
        decideFailed(jobs, q, now: now)
        decideStuck(jobs, p, now: now)
        return release(now: now)
    }

    /// A clock that started at `start`, after the queue moved at `moved`: started now if it wasn't running.
    private static func since(_ start: Date?, _ moved: Date?, _ now: Date) -> Date {
        guard let start else { return now }
        return moved.map { max(start, $0) } ?? start
    }

    /// The jobs listed now and the ones gone since: when the queue last moved, nil if it didn't.
    private func takeIn(_ jobs: [QueueJob], _ q: JobQueueTrack, printerName: String, me: JobOwner, othersMayPrint: Bool, now: Date) -> Date? {
        var moved: Date?
        var listed = Set<String>()
        for job in jobs {
            let key = JobRules.key(job)
            listed.insert(key)
            let t = q.track(key)
            if Self.takeIn(t, job, now) { moved = now }
            (t.absentSince, t.missed) = (nil, 0)
            (t.name, t.state, t.mine, t.printerName) = (job.name, job.state, me.owns(job, othersMayPrint: othersMayPrint), printerName)
        }
        for key in q.order where !listed.contains(key) {
            guard let t = q.jobs[key] else { continue }
            let gone = t.absentSince ?? now
            t.absentSince = gone
            t.due = nil
            guard t.missed < Self.jobGoneAfterReads else {
                // Kept a while once told: a read can miss a job that's still there, and it mustn't be told again when it's back.
                if !t.remembered || now.timeIntervalSince(gone) >= rules.clearHold { q.remove(key) }
                continue
            }
            t.missed += 1
            guard t.missed == Self.jobGoneAfterReads else { continue }
            if t.seen { moved = max(moved ?? gone, gone) } // a job left when it was first missed: the queue moved
            if !t.remembered || now.timeIntervalSince(gone) >= rules.clearHold { q.remove(key) }
        }
        return moved
    }

    /// A job a read missed that may still be there: whether the queue moved is known at the next read.
    private static func unsure(_ q: JobQueueTrack) -> Bool {
        q.jobs.values.contains { $0.seen && $0.absentSince != nil && $0.missed < jobGoneAfterReads }
    }

    private func decideFailed(_ jobs: [QueueJob], _ q: JobQueueTrack, now: Date) {
        for job in jobs {
            guard let t = q.jobs[JobRules.key(job)], t.mine, !t.failedTold else { continue }
            guard JobRules.isFailed(job.state) else {
                t.failedSince = nil
                if t.due == .jobFailed { t.due = nil }
                continue
            }
            let since = t.failedSince ?? now
            t.failedSince = since
            if now.timeIntervalSince(since) >= rules.errorHold {
                t.due = .jobFailed
                t.reason = JobRules.reason(job.state)
            }
        }
    }

    /// Your first job that should be moving; a failed one stands for those behind it.
    private func decideStuck(_ jobs: [QueueJob], _ p: Printer, now: Date) {
        let q = p.queue
        let first = Self.unsure(q) ? nil : jobs.lazy.compactMap { q.jobs[JobRules.key($0)] }.first { $0.mine && JobRules.shouldMove($0.state) }
        for key in q.order { if let t = q.jobs[key], t.due == .jobStuck, t !== first { t.due = nil } }
        q.stuckAt = nil
        guard let first else { return }
        var stuck = false
        if first.mayTellStuck(rules.jobMaxStuckAlerts), !JobRules.isFailed(first.state), let still = q.stillSince {
            let seen = max(still, first.firstSeen)
            let at = p.work == .ready ? max(seen, q.readySince ?? seen).addingTimeInterval(rules.jobStuckAfter) : seen.addingTimeInterval(rules.jobHungAfter)
            // What the printer says has to be from after the wait, not from minutes ago (pendingUntil asks for that read).
            stuck = now >= at && (p.lastObserved.map { $0 >= at } ?? false)
            q.stuckAt = stuck ? nil : at
        }
        if stuck {
            first.due = .jobStuck
            first.dueWhilePrinting = p.work == .printing
        } else if first.due == .jobStuck {
            first.due = nil
        }
    }

    /// One job's read: true when it went forward, which is what "the queue moved" means. A restart is a fresh try, so it
    /// starts from where the job is now.
    private static func takeIn(_ t: JobTrack, _ job: QueueJob, _ now: Date) -> Bool {
        let at = JobProgress.of(job)
        if !t.seen {
            (t.seen, t.firstSeen) = (true, now)
            t.best = t.best.furthest(at)
            return false
        }
        if JobRules.isRestart(from: t.state, to: job.state) {
            var fresh = at
            fresh.restarts = t.best.restarts + 1
            t.best = fresh
            return true
        }
        let forward = at.beyond(t.best)
        t.best = t.best.furthest(at)
        return forward
    }

    static func stopStuckClock(_ q: JobQueueTrack) {
        (q.stillSince, q.readySince, q.stuckAt) = (nil, nil, nil)
        for t in q.jobs.values where t.due == .jobStuck { t.due = nil }
    }

    static func restartJobClocks(_ q: JobQueueTrack) {
        stopStuckClock(q)
        for t in q.jobs.values {
            t.failedSince = nil
            t.due = nil
        }
    }

    /// A printer read: one that's neither ready nor printing stops the stuck clock; one printing ends its time of being ready.
    static func notePrinterRead(_ p: Printer, _ snap: PrinterSnapshot) {
        p.work = JobRules.work(snap)
        let q = p.queue
        switch p.work {
        case .notReady?:
            stopStuckClock(q)
        case .printing?:
            (q.readySince, q.stuckAt) = (nil, nil)
            for t in q.jobs.values where t.due == .jobStuck { t.due = nil } // the next queue read decides, by the longer wait
        default:
            break
        }
    }

    func jobsDue() -> [(uuid: String, track: JobTrack)] {
        printerOrder.flatMap { uuid in
            (printers[uuid]?.queue).map { q in q.order.compactMap { q.jobs[$0] }.filter { $0.due != nil }.map { (uuid, $0) } } ?? []
        }
    }

    /// A due job's alert goes out now, or goes unshown (`shown` false: paused, or off). Either way this episode is over.
    func tellJob(_ uuid: String, _ t: JobTrack, shown: Bool) -> AlertNotice? {
        let notice = shown ? jobNotice(uuid, t) : nil
        if t.due == .jobFailed { t.failedTold = true } else if shown { t.stuckTold += 1 }
        (t.marked, t.mark, t.due) = (true, t.best, nil)
        return notice
    }

    private func jobNotice(_ uuid: String, _ t: JobTrack) -> AlertNotice? {
        guard let kind = t.due else { return nil }
        let document = AlertText.document(t.name)
        let printer = AlertText.printer(t.printerName)
        let words = kind == .jobFailed ? JobText.failed(document, printer, t.reason)
            : t.dueWhilePrinting ? JobText.hung(document, printer, rules.jobHungAfter) : JobText.stuck(document, printer, rules.jobStuckAfter)
        return AlertNotice(uuid: uuid, printerName: printer, kind: kind, title: words.title, body: words.body, jobKey: t.key)
    }

    /// Remembered jobs only, per printer: what survives alerts being turned off and on (a job stays told).
    public func shownJobs() -> [String: [String]] {
        shown().compactMapValues { keys in
            let jobs = keys.filter { $0.hasPrefix(JobRules.keyPrefix) }
            return jobs.isEmpty ? nil : jobs
        }
    }
}
