using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Alerts;

/// <summary>
/// Job notifications (roadmap 3.4): fed each read of a printer's Windows queue, it says which of your own jobs to tell about. Told
/// once per job, ever: a job that got stuck, recovered and stuck again, or got stuck and then failed, has been told about, and
/// stays told across restarts (<see cref="Shown"/> keeps <see cref="JobRules.Key"/>, never the document's name).
/// <list type="bullet">
/// <item><b>Failed</b>: <see cref="JobRules.IsFailed"/> for <see cref="AlertRules.ErrorHold"/>, whatever the printer says.</item>
/// <item><b>Stuck</b>: your first job in the queue, with nothing in the queue moving for <see cref="AlertRules.JobStuckAfter"/>
/// while the queue runs and the printer has said it's idle. Moving is pages counted, a job starting or leaving; another person's job printing
/// ahead of yours counts, so a job waiting its turn isn't stuck. Jobs behind your first one wait for it, so they aren't told as well.
/// The clock starts when the job is first seen, not when it was submitted, so a restart gives it the full time again.</item>
/// </list>
/// Quiet hours, a pause and alerts turned off work as for any other alert. Jobs don't color the tray icon: it shows printers.
/// </summary>
public sealed partial class AlertTracker
{
    private const int MaxRememberedJobs = 256;

    private sealed class JobTrack(string key)
    {
        public string Key { get; } = key;
        public string Name = "", Reason = "", PrinterName = "";
        public int Pages, Printed;
        public JobStatus Status;
        public bool Seen, Mine, Told;
        public DateTimeOffset FirstSeen;
        public DateTimeOffset? FailedSince, AbsentSince;
        public AlertKind? Due;
    }

    private sealed class JobQueueTrack
    {
        public readonly Dictionary<string, JobTrack> Jobs = new(StringComparer.Ordinal);
        public DateTimeOffset? LastRead, StillSince, StuckAt;
    }

    private void RememberJob(string uuid, string key)
    {
        var jobs = PrinterOf(uuid).Queue.Jobs;
        if (JobRules.IsKey(key) && jobs.Count < MaxRememberedJobs) jobs[key] = new JobTrack(key) { Told = true };
    }

    /// <summary>Takes in one read of a printer's queue (null: it has no queue now); returns the alerts to show now.</summary>
    public IReadOnlyList<AlertNotice> ObserveJobs(string uuid, string printerName, JobQueueState? queue, JobOwner me, DateTimeOffset now)
    {
        if (!Rules.Jobs) return Release(now);
        var printer = PrinterOf(uuid);
        var q = printer.Queue;
        // Reads come every minute: a gap as long as the wait itself (the PC slept) says nothing about what the job did meanwhile.
        if (q.LastRead is { } last && now - last > Rules.JobStuckAfter) RestartJobClocks(q);
        q.LastRead = now;

        var jobs = QueueJobText.Order(queue?.Jobs ?? []);
        var moved = false;
        var listed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var job in jobs)
        {
            var key = JobRules.Key(job);
            listed.Add(key);
            if (!q.Jobs.TryGetValue(key, out var t)) q.Jobs[key] = t = new JobTrack(key);
            if (!t.Seen) (t.Seen, t.FirstSeen) = (true, now);
            else if (Moved(t, job)) moved = true;
            t.AbsentSince = null;
            (t.Name, t.Pages, t.Printed, t.Status, t.Mine, t.PrinterName) = (job.Name, job.Pages, job.PagesPrinted, job.Status, me.Owns(job), printerName);
        }
        foreach (var (key, t) in q.Jobs.ToList())
        {
            if (listed.Contains(key)) continue;
            if (t.Seen && t.AbsentSince is null) moved = true; // a job left: the queue moved
            t.AbsentSince ??= now;
            t.Due = null;
            // Kept a while once told: a read can miss a job that's still there, and it mustn't be told again when it's back.
            if (!t.Told || now - t.AbsentSince >= Rules.ClearHold) q.Jobs.Remove(key);
        }

        var running = queue is { Paused: false, WorkOffline: false } && printer.Ready == true && !jobs.Any(j => JobRules.SaysPrinterNotReady(j.Status));
        if (!running) StopStuckClock(q);
        else if (moved || q.StillSince is null) q.StillSince = now;

        foreach (var job in jobs)
        {
            var t = q.Jobs[JobRules.Key(job)];
            if (!t.Mine || t.Told) continue;
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
                t.Reason = QueueJobText.Status(job.Status);
            }
        }

        // Your first job that should be moving; a failed one stands for those behind it.
        var first = jobs.Select(j => q.Jobs[JobRules.Key(j)]).FirstOrDefault(t => t.Mine && JobRules.ShouldMove(t.Status));
        foreach (var t in q.Jobs.Values.Where(t => t.Due == AlertKind.JobStuck && t != first)) t.Due = null;
        q.StuckAt = null;
        if (first is { Told: false } && !JobRules.IsFailed(first.Status) && q.StillSince is { } since)
        {
            var at = (since > first.FirstSeen ? since : first.FirstSeen) + Rules.JobStuckAfter;
            q.StuckAt = at;
            // "Ready" has to be what the printer says after the wait, not what it said minutes ago (PendingUntil asks for that read).
            if (now >= at && printer.LastObserved >= at) (first.Due, q.StuckAt) = (AlertKind.JobStuck, null);
        }
        return Release(now);
    }

    private static bool Moved(JobTrack t, QueueJob job)
    {
        const JobStatus moving = JobStatus.Printing | JobStatus.Spooling | JobStatus.Restarted;
        return job.PagesPrinted != t.Printed || job.Pages != t.Pages || ((job.Status ^ t.Status) & moving) != 0;
    }

    private static void StopStuckClock(JobQueueTrack q)
    {
        (q.StillSince, q.StuckAt) = (null, null);
        foreach (var t in q.Jobs.Values.Where(t => t.Due == AlertKind.JobStuck)) t.Due = null;
    }

    private static void RestartJobClocks(JobQueueTrack q)
    {
        StopStuckClock(q);
        foreach (var t in q.Jobs.Values.Where(t => !t.Told))
        {
            t.FailedSince = null;
            t.Due = null;
        }
    }

    /// <summary>A printer read: a printer that isn't idle stops the stuck clock there and then (a page may have just gone through).</summary>
    private static void NotePrinterRead(Printer printer, PrinterSnapshot snap)
    {
        printer.Ready = JobRules.PrinterReady(snap);
        if (printer.Ready != true) StopStuckClock(printer.Queue);
    }

    private IEnumerable<(string Uuid, JobTrack Track)> JobsDue() =>
        _printers.SelectMany(p => p.Value.Queue.Jobs.Values.Where(t => t.Due is not null && !t.Told).Select(t => (p.Key, t)));

    private AlertNotice JobNotice(string uuid, JobTrack t)
    {
        var document = AlertText.Document(t.Name);
        var printer = AlertText.Printer(t.PrinterName);
        var minutes = Rules.JobStuckAfter.TotalMinutes;
        var (title, body) = t.Due == AlertKind.JobFailed
            ? ($"“{document}” didn't print", $"{printer}: {t.Reason}. Open the queue to cancel it or print it again.")
            : ($"“{document}” isn't moving", $"{printer} is ready, but this job hasn't moved for {minutes:0} {(minutes == 1 ? "minute" : "minutes")}. Open the queue to cancel it or print it again.");
        return new AlertNotice(uuid, printer, t.Due!.Value, title, body) { JobKey = t.Key };
    }

    /// <summary>Remembered job keys only, per printer: what survives alerts being turned off and on (a job stays told).</summary>
    public Dictionary<string, IReadOnlyList<string>> ShownJobs() =>
        Shown().Select(p => (p.Key, Keys: p.Value.Where(JobRules.IsKey).ToList()))
            .Where(p => p.Keys.Count > 0)
            .ToDictionary(p => p.Key, p => (IReadOnlyList<string>)p.Keys, StringComparer.OrdinalIgnoreCase);
}
