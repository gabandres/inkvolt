using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// Job alerts (roadmap 3.4) for a printer printed to straight (2.1): its own job list read as the Windows queue would be, for
/// <see cref="AlertTracker.ObserveJobs"/>. The jobs still to print are Get-Jobs' not-completed ones; of the ended ones only those
/// the printer gave up on (aborted) are added, for <see cref="EndedKept"/> after they ended, so a job that fails between two reads
/// is still told and one that ended before the watch began isn't. A printer that gives no creation time gets the moment a job
/// was first seen, kept per job id, so a job keeps one key (<see cref="JobRules.Key"/>) for as long as it's listed. One instance
/// per printer, read once a minute.
/// </summary>
public sealed class DirectJobWatch(Func<DateTime>? clock = null)
{
    /// <summary>How long a job the printer gave up on stays listed after it ended (CUPS's, on the Mac, the same).</summary>
    public static readonly TimeSpan EndedKept = TimeSpan.FromMinutes(15);

    /// <summary>A job id not listed for this long is forgotten.</summary>
    private static readonly TimeSpan Forget = TimeSpan.FromHours(1);

    private const int MaxRemembered = 4 * PrinterJobs.MaxJobs;

    private readonly Func<DateTime> _now = clock ?? (() => DateTime.Now);
    private readonly Dictionary<int, (DateTime First, DateTime Last)> _open = [], _ended = [];
    private bool _started;

    /// <summary>
    /// Asks the printer for its jobs and its ended jobs. Throws when the jobs to print can't be read (an unread queue says nothing
    /// about its jobs); a printer that won't list ended jobs only loses the failures that happen between two reads.
    /// </summary>
    public async Task<JobQueueState> ReadAsync(IppClient ipp, string user, CancellationToken ct = default)
    {
        var open = await ipp.GetJobsAsync(PrinterJobs.GetJobsRequest(ipp.PrinterUri, user), ct).ConfigureAwait(false);
        byte[]? ended = null;
        try
        {
            ended = await ipp.GetJobsAsync(PrinterJobs.GetJobsRequest(ipp.PrinterUri, user, 2, PrinterJobs.Completed), ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (DirectJob.NoAnswer(ex))
        {
        }
        return Read(open, ended);
    }

    /// <summary>One read: the not-completed answer, and the completed one (null: not read).</summary>
    /// <exception cref="DirectPrintException">The printer refused to list its jobs.</exception>
    public JobQueueState Read(ReadOnlySpan<byte> notCompleted, byte[]? completed)
    {
        var now = _now();
        var jobs = new List<QueueJob>();
        var ids = new HashSet<int>();
        foreach (var l in PrinterJobs.Read(notCompleted))
        {
            if (!ids.Add(l.Job.Id)) continue;
            // An id seen ended and now waiting again is a new job (a printer that restarted counts from 1 again).
            if (_ended.Remove(l.Job.Id)) _open.Remove(l.Job.Id);
            jobs.Add(Keyed(l, _open, now));
        }

        IReadOnlyList<PrinterJobs.Listed> done = [];
        if (completed is not null)
        {
            try { done = PrinterJobs.Read(completed); }
            catch (Exception ex) when (ex is DirectPrintException or FormatException) { } // which-jobs "completed" not offered: the open ones still count
        }
        foreach (var l in done)
        {
            if (l.State.State != DirectJobState.Aborted || !ids.Add(l.Job.Id)) continue; // printed and cancelled jobs have left the queue
            if (!_ended.TryGetValue(l.Job.Id, out var seen))
            {
                // First seen ended: when the printer says it ended, before the first read (it may be days old); else now.
                var at = !_started ? l.Ended ?? DateTime.MinValue : _open.ContainsKey(l.Job.Id) ? now : l.Ended ?? now;
                seen = (at, now);
            }
            _ended[l.Job.Id] = (seen.First, now);
            var age = now - seen.First;
            if (age > EndedKept || age < -EndedKept) continue; // a printer's clock far off says nothing either
            jobs.Add(Keyed(l, _open, now) with { Problem = DirectJob.Describe(l.State, 0) });
        }
        _started = true;
        Prune(_open, now);
        Prune(_ended, now);
        return new JobQueueState(Paused: false, WorkOffline: false, QueueJobText.Order(jobs));
    }

    /// <summary>The job with its creation time, or the moment its id was first seen.</summary>
    private static QueueJob Keyed(PrinterJobs.Listed l, Dictionary<int, (DateTime First, DateTime Last)> seen, DateTime now)
    {
        var first = seen.TryGetValue(l.Job.Id, out var s) ? s.First : now;
        seen[l.Job.Id] = (first, now);
        return l.Created is null ? l.Job with { Submitted = first } : l.Job;
    }

    private static void Prune(Dictionary<int, (DateTime First, DateTime Last)> seen, DateTime now)
    {
        foreach (var (id, s) in seen.ToList())
            if (now - s.Last > Forget) seen.Remove(id);
        if (seen.Count > MaxRemembered)
            foreach (var id in seen.OrderBy(x => x.Value.Last).Take(seen.Count - MaxRemembered).Select(x => x.Key).ToList()) seen.Remove(id);
    }
}
