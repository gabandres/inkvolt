import Foundation
import Synchronization

/// Job alerts (roadmap 3.4) for a printer printed to straight (2.1; Windows' `DirectJobWatch`): its own job list read as a
/// macOS queue would be, for `AlertTracker.observeJobs`. The jobs still to print are Get-Jobs' not-completed ones; of the ended
/// ones only those the printer gave up on (aborted) are added, for `endedKept` after they ended, so a job that fails between two
/// reads is still told and one that ended before the watch began isn't. A printer that gives no creation time gets the moment a
/// job was first seen, kept per job id while it's listed (and for the read it leaves, so it keeps its key, `JobRules.key`, when
/// it shows up ended), so an id the printer uses again for a new job is a new job. One instance per printer, read once a minute.
/// Mac difference: the state says no other computer prints there (`JobQueueState.othersMayPrint` false), so a job that doesn't
/// say where it came from, or names it by address, is taken as yours when its user is, as Windows takes it; the printer names
/// this Mac by its address, which the list leaves out (`PrinterJobs.read`).
public final class DirectJobWatch: Sendable {
    /// How long a job the printer gave up on stays listed after it ended (CUPS's history, `JobQueueState.abortedKeptFor`).
    public static let endedKept: TimeInterval = 15 * 60

    /// A job id not listed for this long is forgotten.
    private static let forget: TimeInterval = 60 * 60

    private static let maxRemembered = 4 * PrinterJobs.maxJobs

    private struct Seen {
        var first: Date
        var last: Date
    }

    private struct Memory {
        /// Jobs listed waiting or printing, by id.
        var open: [Int: Seen] = [:]
        /// Jobs that left the open list, by id: when first seen open (their key), when they left.
        var left: [Int: Seen] = [:]
        /// Aborted jobs seen in the ended list, by id: when they ended as far as known, when last listed.
        var ended: [Int: Seen] = [:]
        /// An ended list has been read: from then on, a job given up on that wasn't there before is new.
        var endedRead = false
    }

    private let now: @Sendable () -> Date
    private let memory = Mutex(Memory())

    public init(clock: @escaping @Sendable () -> Date = { Date() }) { now = clock }

    /// Asks the printer for its jobs and its ended jobs. Throws when the jobs to print can't be read (an unread queue says
    /// nothing about its jobs); a printer that won't list ended jobs only loses the failures that happen between two reads.
    public func read(_ ipp: IppClient, user: String) async throws -> JobQueueState {
        let open = try await ipp.getJobs(PrinterJobs.getJobsRequest(ipp.printerUri, user: user))
        var ended: [UInt8]?
        do {
            ended = try await ipp.getJobs(PrinterJobs.getJobsRequest(ipp.printerUri, user: user, requestId: 2, which: PrinterJobs.completed))
        } catch let error where DirectJob.noAnswer(error) {
            ended = nil
        }
        return try read(open, ended)
    }

    /// One read: the not-completed answer, and the completed one (nil: not read). Throws `DirectPrintError` when the printer
    /// refused to list its jobs.
    public func read(_ notCompleted: [UInt8], _ completed: [UInt8]?) throws -> JobQueueState {
        let open = try PrinterJobs.read(notCompleted)
        var done: [PrinterJobs.Listed]?
        if let completed { done = try? PrinterJobs.read(completed) } // which-jobs "completed" not offered: the open ones still count
        let at = now()
        let jobs = memory.withLock { m in Self.read(&m, open, done, at) }
        return JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: QueueJobText.order(jobs))
    }

    private static func read(_ m: inout Memory, _ open: [PrinterJobs.Listed], _ done: [PrinterJobs.Listed]?, _ now: Date) -> [QueueJob] {
        var jobs: [QueueJob] = []
        var ids = Set<Int>()
        for l in open {
            guard ids.insert(l.job.id).inserted else { continue }
            // An id seen given up on and now waiting again is a new job (a printer that restarted counts from 1 again).
            if m.ended.removeValue(forKey: l.job.id) != nil { m.open.removeValue(forKey: l.job.id) }
            m.left.removeValue(forKey: l.job.id)
            let first = m.open[l.job.id]?.first ?? now
            m.open[l.job.id] = Seen(first: first, last: now)
            var job = l.job
            if l.created == nil { job.submitted = first }
            jobs.append(job)
        }
        // A complete list (not cut at the limit) says which jobs left: their first sight moves aside, so a new job under the
        // same id isn't given the old one's time, and the old one keeps its key if it shows up ended.
        if open.count < PrinterJobs.maxJobs {
            for (id, seen) in m.open where !ids.contains(id) {
                m.open.removeValue(forKey: id)
                m.left[id] = Seen(first: seen.first, last: now)
            }
        }

        for l in done ?? [] {
            // Printed and cancelled jobs have left the queue.
            guard l.state.state == DirectJobState.aborted, ids.insert(l.job.id).inserted else { continue }
            let left = m.left[l.job.id]
            var seen: Seen
            if let kept = m.ended[l.job.id] {
                seen = kept
            } else {
                // Seen waiting or printing, it ended since; before the first ended list, when the printer says (it may be days
                // old; no time: old); after it, when the printer says, else now.
                let at = left != nil ? now : !m.endedRead ? l.ended ?? .distantPast : l.ended ?? now
                seen = Seen(first: at, last: now)
            }
            seen.last = now
            m.ended[l.job.id] = seen
            if let left { m.left[l.job.id] = Seen(first: left.first, last: now) }
            let age = now.timeIntervalSince(seen.first)
            if age > endedKept || age < -endedKept { continue } // a printer's clock far off says nothing either
            // Its key: when first seen open, else when it ended (kept above): the same at every read.
            var job = l.job
            if l.created == nil { job.submitted = left?.first ?? seen.first }
            job.problem = DirectJob.describe(l.state, pages: 0)
            jobs.append(job)
        }
        if done != nil { m.endedRead = true }
        prune(&m.open, now)
        prune(&m.left, now)
        prune(&m.ended, now)
        return jobs
    }

    private static func prune(_ seen: inout [Int: Seen], _ now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value.last) <= forget }
        if seen.count > maxRemembered {
            for (id, _) in seen.sorted(by: { $0.value.last < $1.value.last }).prefix(seen.count - maxRemembered) { seen.removeValue(forKey: id) }
        }
    }
}
