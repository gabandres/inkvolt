using System.Globalization;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Alerts;

/// <summary>
/// Job notifications (roadmap 3.4): fed each read of a printer's Windows queue, it says which of your own jobs to tell about.
/// <list type="bullet">
/// <item><b>Failed</b>: <see cref="JobRules.IsFailed"/> for <see cref="AlertRules.ErrorHold"/>, whatever the printer says. Once per job,
/// even if it had been told stuck: a job that failed is news.</item>
/// <item><b>Stuck</b>: your first job in the queue, with nothing in the queue moving while the queue runs, for
/// <see cref="AlertRules.JobStuckAfter"/> with the printer saying it's ready, or <see cref="AlertRules.JobHungAfter"/> with it saying it's
/// printing (worded "may be stuck": a big job on a driver that counts no pages looks the same, and can raise one false alert). Moving means
/// <see cref="JobProgress"/> going forward, on any job in the queue, or a job leaving (missing from <see cref="JobGoneAfterReads"/> reads in a
/// row, as of the first: one read that misses a job decides nothing stuck and starts no wait again): another person's job printing ahead of yours counts,
/// so a job waiting its turn isn't stuck, and flicker (a state going back and forth, a count going down) doesn't count, so it can't hide a hung
/// job either. Jobs behind your first one wait for it, so they aren't told as well. The clock starts when the job is first seen, not when it was
/// submitted, so a restart gives it the full time again.</item>
/// <item><b>Told again</b>: a job told stuck is told again only after real progress since its last alert, and at most
/// <see cref="AlertRules.JobMaxStuckAlerts"/> times. What decides that survives restarts (<see cref="Shown"/>): the job's
/// <see cref="JobRules.Key"/>, its counts and its progress when last told, never the document's name.</item>
/// </list>
/// Quiet hours, a pause and alerts turned off work as for any other alert. Jobs don't color the tray icon: it shows printers.
/// </summary>
public sealed partial class AlertTracker
{
    private const int MaxRememberedJobs = 256;

    /// <summary>A job missing from this many reads in a row has left the queue.</summary>
    private const int JobGoneAfterReads = 2;

    private sealed class JobTrack(string key)
    {
        public string Key { get; } = key;
        public string Name = "", Reason = "", PrinterName = "";
        public JobStatus Status;
        public bool Seen, Mine, FailedTold, Marked, DueWhilePrinting;
        public int StuckTold;
        /// <summary>The furthest the job has been seen, and how far it was at its last alert (<see cref="Marked"/>: it has had one).</summary>
        public JobProgress Best, Mark;
        public DateTimeOffset FirstSeen;
        public DateTimeOffset? FailedSince, AbsentSince;
        /// <summary>Reads in a row it was missing from, up to <see cref="JobGoneAfterReads"/>.</summary>
        public int Missed;
        public AlertKind? Due;

        /// <summary>Stuck may be told: never told yet, or moved on since, and under the cap.</summary>
        public bool MayTellStuck(int max) => StuckTold < max && (!Marked || Best.Beyond(Mark));

        /// <summary>Worth keeping across a restart.</summary>
        public bool Remembered => FailedTold || Marked;

        public string Line() => string.Create(CultureInfo.InvariantCulture,
            $"{Key}|{(FailedTold ? 1 : 0)}|{StuckTold}|{Mark.Printed}|{Mark.Pages}|{Mark.Stage}|{Mark.Bytes}|{Mark.Restarts}");

        public static JobTrack? Parse(string line)
        {
            var p = line.Split('|');
            if (p.Length != 10 || !JobRules.IsKey(string.Join('|', p[..3]))) return null;
            static bool Int(string s, out int v) => int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out v);
            if (!Int(p[3], out var failed) || !Int(p[4], out var stuck) || !Int(p[5], out var printed) || !Int(p[6], out var pages) || !Int(p[7], out var stage)
                || !long.TryParse(p[8], NumberStyles.None, CultureInfo.InvariantCulture, out var bytes) || !Int(p[9], out var restarts)) return null;
            var mark = new JobProgress(printed, pages, stage, bytes, restarts);
            return new JobTrack(string.Join('|', p[..3])) { FailedTold = failed != 0, StuckTold = stuck, Marked = true, Mark = mark, Best = mark };
        }
    }

    private sealed class JobQueueTrack
    {
        public readonly Dictionary<string, JobTrack> Jobs = new(StringComparer.Ordinal);

        /// <summary>Nothing has moved since; the printer has said it's ready since; when the wait runs out.</summary>
        public DateTimeOffset? LastRead, StillSince, ReadySince, StuckAt;
    }

    /// <summary>A printer's remembered lines from the last run: the newest <see cref="MaxRememberedJobs"/> of those that make sense.</summary>
    private void RememberJobs(string uuid, IEnumerable<string> lines)
    {
        var jobs = PrinterOf(uuid).Queue.Jobs;
        var parsed = new Dictionary<string, JobTrack>(jobs, StringComparer.Ordinal); // another spelling of the same printer's id, read before
        foreach (var line in lines)
            if (JobTrack.Parse(line) is { } t) parsed[t.Key] = t;
        jobs.Clear();
        foreach (var t in Newest(parsed.Values)) jobs[t.Key] = t;
    }

    /// <summary>The newest <see cref="MaxRememberedJobs"/> of these, oldest first: by when they were submitted (in the key), then by id.</summary>
    private static IEnumerable<JobTrack> Newest(IEnumerable<JobTrack> tracks) =>
        tracks.Select(t => (Track: t, Parts: t.Key.Split('|')))
            .OrderBy(x => long.Parse(x.Parts[2], CultureInfo.InvariantCulture)).ThenBy(x => int.Parse(x.Parts[1], CultureInfo.InvariantCulture))
            .ThenBy(x => x.Track.Key, StringComparer.Ordinal)
            .Select(x => x.Track).TakeLast(MaxRememberedJobs);

    /// <summary>Takes in one read of a printer's queue (null: it has no queue now); returns the alerts to show now.</summary>
    public IReadOnlyList<AlertNotice> ObserveJobs(string uuid, string printerName, JobQueueState? queue, JobOwner me, DateTimeOffset now)
    {
        if (!Rules.Jobs) return Release(now);
        var printer = PrinterOf(uuid);
        var q = printer.Queue;
        // Reads come every minute: a gap as long as the shorter wait (the PC slept) says nothing about what the job did meanwhile.
        if (q.LastRead is { } last && now - last > Rules.JobStuckAfter) RestartJobClocks(q);
        q.LastRead = now;

        var jobs = QueueJobText.Order(queue?.Jobs ?? []);
        var moved = TakeIn(q, jobs, printerName, me, now);

        var running = queue is { Paused: false, WorkOffline: false } && printer.Work is PrinterWork.Ready or PrinterWork.Printing
                                                                     && !jobs.Any(j => JobRules.SaysPrinterNotReady(j.Status));
        if (!running) StopStuckClock(q);
        else
        {
            q.StillSince = Since(q.StillSince, moved, now);
            q.ReadySince = printer.Work != PrinterWork.Ready ? null : Since(q.ReadySince, moved, now);
        }

        foreach (var job in jobs)
        {
            var t = q.Jobs[JobRules.Key(job)];
            if (!t.Mine || t.FailedTold) continue;
            if (!JobRules.IsFailed(job.Status))
            {
                t.FailedSince = null;
                if (t.Due == AlertKind.JobFailed) t.Due = null;
                continue;
            }
            t.FailedSince ??= now;
            if (now - t.FailedSince >= Rules.ErrorHold)
            {
                t.Due = AlertKind.JobFailed;
                // Compared with the word Status gives a plain error, so it holds in any language.
                t.Reason = QueueJobText.Status(job.Status) is var said && said == QueueJobText.Status(JobStatus.Error) ? CoreStrings.Alert_JobErrorReason : said;
            }
        }

        // Your first job that should be moving; a failed one stands for those behind it.
        var first = Unsure(q) ? null : jobs.Select(j => q.Jobs[JobRules.Key(j)]).FirstOrDefault(t => t.Mine && JobRules.ShouldMove(t.Status));
        foreach (var t in q.Jobs.Values.Where(t => t.Due == AlertKind.JobStuck && t != first)) t.Due = null;
        q.StuckAt = null;
        if (first is not null)
        {
            var stuck = false;
            if (first.MayTellStuck(Rules.JobMaxStuckAlerts) && !JobRules.IsFailed(first.Status) && q.StillSince is { } still)
            {
                var seen = Later(still, first.FirstSeen);
                var at = printer.Work == PrinterWork.Ready ? Later(seen, q.ReadySince!.Value) + Rules.JobStuckAfter : seen + Rules.JobHungAfter;
                // What the printer says has to be from after the wait, not from minutes ago (PendingUntil asks for that read).
                stuck = now >= at && printer.LastObserved >= at;
                q.StuckAt = stuck ? null : at;
            }
            if (stuck)
            {
                first.Due = AlertKind.JobStuck;
                first.DueWhilePrinting = printer.Work == PrinterWork.Printing;
            }
            else if (first.Due == AlertKind.JobStuck) first.Due = null;
        }
        return Release(now);
    }

    /// <summary>The jobs listed now and the ones gone since: when the queue last moved, null if it didn't.</summary>
    private DateTimeOffset? TakeIn(JobQueueTrack q, IReadOnlyList<QueueJob> jobs, string printerName, JobOwner me, DateTimeOffset now)
    {
        DateTimeOffset? moved = null;
        var listed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var job in jobs)
        {
            var key = JobRules.Key(job);
            listed.Add(key);
            if (!q.Jobs.TryGetValue(key, out var t)) q.Jobs[key] = t = new JobTrack(key);
            if (TakeIn(t, job, now)) moved = now;
            (t.AbsentSince, t.Missed) = (null, 0);
            (t.Name, t.Status, t.Mine, t.PrinterName) = (job.Name, job.Status, me.Owns(job), printerName);
        }
        foreach (var (key, t) in q.Jobs.ToList())
        {
            if (listed.Contains(key)) continue;
            var gone = t.AbsentSince ??= now;
            t.Due = null;
            if (t.Missed < JobGoneAfterReads)
            {
                // One read can miss a job that's still there: whether it left is known at the next.
                if (++t.Missed < JobGoneAfterReads) continue;
                if (t.Seen) moved = moved is { } m && m > gone ? m : gone; // a job left when it was first missed: the queue moved
            }
            // Kept a while once told: a read can miss a job that's still there, and it mustn't be told again when it's back.
            if (!t.Remembered || now - gone >= Rules.ClearHold) q.Jobs.Remove(key);
        }
        return moved;
    }

    /// <summary>A clock that started at <paramref name="start"/>, after the queue moved at <paramref name="moved"/>: started now if it wasn't running.</summary>
    private static DateTimeOffset Since(DateTimeOffset? start, DateTimeOffset? moved, DateTimeOffset now) =>
        start is not { } s ? now : moved is { } m ? Later(s, m) : s;

    /// <summary>A job a read missed that may still be there: whether the queue moved is known at the next read.</summary>
    private static bool Unsure(JobQueueTrack q) => q.Jobs.Values.Any(t => t.Seen && t.AbsentSince is not null && t.Missed < JobGoneAfterReads);

    /// <summary>When your failed jobs still within their hold (<see cref="AlertRules.ErrorHold"/>) will be due (<see cref="PendingUntil"/> asks for a read then).</summary>
    private IEnumerable<DateTimeOffset?> FailedHolds(JobQueueTrack q) =>
        q.Jobs.Values.Where(t => t.Mine && !t.FailedTold && t.Due is null && t.AbsentSince is null && t.FailedSince is not null)
            .Select(t => (DateTimeOffset?)(t.FailedSince!.Value + Rules.ErrorHold));

    /// <summary>One job's read: true when it went forward, which is what "the queue moved" means. A restart is a fresh try, so it starts from where the job is now.</summary>
    private static bool TakeIn(JobTrack t, QueueJob job, DateTimeOffset now)
    {
        var at = JobProgress.Of(job);
        if (!t.Seen)
        {
            (t.Seen, t.FirstSeen) = (true, now);
            t.Best = t.Best.Furthest(at);
            return false;
        }
        if (job.Status.HasFlag(JobStatus.Restarted) && !t.Status.HasFlag(JobStatus.Restarted))
        {
            t.Best = at with { Restarts = t.Best.Restarts + 1 };
            return true;
        }
        var forward = at.Beyond(t.Best);
        t.Best = t.Best.Furthest(at);
        return forward;
    }

    private static DateTimeOffset Later(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

    private static void StopStuckClock(JobQueueTrack q)
    {
        (q.StillSince, q.ReadySince, q.StuckAt) = (null, null, null);
        foreach (var t in q.Jobs.Values.Where(t => t.Due == AlertKind.JobStuck)) t.Due = null;
    }

    private static void RestartJobClocks(JobQueueTrack q)
    {
        StopStuckClock(q);
        foreach (var t in q.Jobs.Values)
        {
            t.FailedSince = null;
            t.Due = null;
        }
    }

    /// <summary>A printer read: one that's neither ready nor printing stops the stuck clock; one printing ends its time of being ready.</summary>
    private static void NotePrinterRead(Printer printer, PrinterSnapshot snap)
    {
        printer.Work = JobRules.Work(snap);
        var q = printer.Queue;
        if (printer.Work == PrinterWork.NotReady)
        {
            StopStuckClock(q);
        }
        else if (printer.Work == PrinterWork.Printing)
        {
            (q.ReadySince, q.StuckAt) = (null, null);
            foreach (var t in q.Jobs.Values.Where(t => t.Due == AlertKind.JobStuck)) t.Due = null; // the next queue read decides, by the longer wait
        }
    }

    private IEnumerable<(string Uuid, JobTrack Track)> JobsDue() =>
        _printers.SelectMany(p => p.Value.Queue.Jobs.Values.Where(t => t.Due is not null).Select(t => (p.Key, t)));

    /// <summary>A due job's alert goes out now, or goes unshown (<paramref name="shown"/> false: paused, or off). Either way this episode is over.</summary>
    private AlertNotice? TellJob(string uuid, JobTrack t, bool shown)
    {
        var notice = shown ? JobNotice(uuid, t) : null;
        if (t.Due == AlertKind.JobFailed) t.FailedTold = true;
        else if (shown) t.StuckTold++;
        (t.Marked, t.Mark, t.Due) = (true, t.Best, null);
        return notice;
    }

    private AlertNotice JobNotice(string uuid, JobTrack t)
    {
        var document = AlertText.Document(t.Name);
        var printer = AlertText.Printer(t.PrinterName);
        var (title, body) = t.Due == AlertKind.JobFailed
            ? (string.Format(CoreStrings.Alert_JobFailedTitle, document), string.Format(CoreStrings.Alert_JobFailedBody, printer, t.Reason))
            : t.DueWhilePrinting
                ? (string.Format(CoreStrings.Alert_JobHungTitle, document), string.Format(CoreStrings.Alert_JobHungBody, printer, Rules.JobHungAfter.TotalMinutes))
                : (string.Format(CoreStrings.Alert_JobStuckTitle, document), string.Format(CoreStrings.Alert_JobStuckBody, printer, Rules.JobStuckAfter.TotalMinutes));
        return new AlertNotice(uuid, printer, t.Due!.Value, title, body) { JobKey = t.Key };
    }

    /// <summary>Remembered jobs only, per printer: what survives alerts being turned off and on (a job stays told).</summary>
    public Dictionary<string, IReadOnlyList<string>> ShownJobs() =>
        Shown().Select(p => (p.Key, Keys: p.Value.Where(k => k.StartsWith(JobRules.KeyPrefix, StringComparison.Ordinal)).ToList()))
            .Where(p => p.Keys.Count > 0)
            .ToDictionary(p => p.Key, p => (IReadOnlyList<string>)p.Keys, StringComparer.OrdinalIgnoreCase);
}
