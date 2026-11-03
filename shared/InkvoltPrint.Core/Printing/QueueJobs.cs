using System.Globalization;

namespace InkvoltPrint.Core.Printing;

/// <summary>Windows print job status bits (<c>JOB_STATUS_*</c>; the same values as System.Printing's <c>PrintJobStatus</c>).</summary>
[Flags]
public enum JobStatus
{
    None = 0,
    Paused = 0x1,
    Error = 0x2,
    Deleting = 0x4,
    Spooling = 0x8,
    Printing = 0x10,
    Offline = 0x20,
    PaperOut = 0x40,
    Printed = 0x80,
    Deleted = 0x100,
    Blocked = 0x200,
    UserIntervention = 0x400,
    Restarted = 0x800,
    Completed = 0x1000,
    Retained = 0x2000,
}

/// <summary>One job in a printer's Windows queue, as the spooler reports it. <see cref="Pages"/> is 0 while it's still spooling.</summary>
public sealed record QueueJob(int Id, string Name, int Pages, int PagesPrinted, JobStatus Status, DateTime Submitted, string Owner)
{
    /// <summary>The PC it was printed from, where the reader gets it; null: not known.</summary>
    public string? Machine { get; init; }

    /// <summary>The job's size in bytes as spooled so far, where the reader gets it (JOB_INFO_2); 0: not known. It grows while the job is written.</summary>
    public long Bytes { get; init; }
}

/// <summary>What the print queue card shows for a job: plain words for the spooler's status bits, pages, time, owner.</summary>
public static class QueueJobText
{
    /// <summary>The most important state first: a job that is printing but out of paper is "Out of paper".</summary>
    public static string Status(JobStatus s) => s switch
    {
        _ when s.HasFlag(JobStatus.Deleting) || s.HasFlag(JobStatus.Deleted) => CoreStrings.Status_JobCancelling,
        _ when s.HasFlag(JobStatus.PaperOut) => CoreStrings.Status_OutOfPaper,
        _ when s.HasFlag(JobStatus.Offline) => CoreStrings.Status_JobPrinterOffline,
        _ when s.HasFlag(JobStatus.UserIntervention) => CoreStrings.Status_JobNeedsAttention,
        _ when s.HasFlag(JobStatus.Error) => CoreStrings.Status_JobError,
        _ when s.HasFlag(JobStatus.Blocked) => CoreStrings.Status_JobBlocked,
        _ when s.HasFlag(JobStatus.Paused) => CoreStrings.Status_JobPaused,
        _ when s.HasFlag(JobStatus.Printed) || s.HasFlag(JobStatus.Completed) => CoreStrings.Status_JobPrinted,
        _ when s.HasFlag(JobStatus.Printing) => CoreStrings.Status_JobPrinting, // before Retained: a real queue says Printing | Retained while it's still trying
        _ when s.HasFlag(JobStatus.Retained) => CoreStrings.Status_JobPrinted,
        _ when s.HasFlag(JobStatus.Spooling) => CoreStrings.Status_JobPreparing,
        _ => CoreStrings.Status_JobWaiting,
    };

    /// <summary>A job that needs the user, not just patience.</summary>
    public static bool IsProblem(JobStatus s) =>
        (s & (JobStatus.Error | JobStatus.PaperOut | JobStatus.Offline | JobStatus.UserIntervention | JobStatus.Blocked)) != 0;

    /// <summary>"3 pages", "Page 2 of 3" while printing, "" while the page count is still unknown.</summary>
    public static string Pages(int pages, int printed, JobStatus s)
    {
        if (pages <= 0) return "";
        if (s.HasFlag(JobStatus.Printing) && printed > 0 && printed < pages) return string.Format(CoreStrings.Status_JobPageOf, printed + 1, pages);
        return Plural.Of(pages, CoreStrings.Status_JobPages_One, CoreStrings.Status_JobPages_Many);
    }

    /// <summary>Submitted time: just the time for today's jobs, else the date too.</summary>
    public static string Submitted(DateTime local, DateTime now, CultureInfo culture) =>
        local.Date == now.Date
            ? local.ToString("t", culture)
            : $"{local.ToString(culture.DateTimeFormat.MonthDayPattern, culture)}, {local.ToString("t", culture)}";

    /// <summary>The spooler's submitter is a bare user name; tolerate "DOMAIN\user" on either side.</summary>
    public static bool IsOwner(string owner, string user) =>
        string.Equals(Bare(owner), Bare(user), StringComparison.OrdinalIgnoreCase);

    /// <summary>One line under the card title: "2 jobs, 1 printing".</summary>
    public static string Summary(IReadOnlyCollection<QueueJob> jobs)
    {
        if (jobs.Count == 0) return CoreStrings.Status_JobsNone;
        var printing = jobs.Count(j => j.Status.HasFlag(JobStatus.Printing));
        return printing > 0 && jobs.Count > 1
            ? string.Format(CoreStrings.Status_JobsPrinting, jobs.Count, printing)
            : Plural.Of(jobs.Count, CoreStrings.Status_Jobs_One, CoreStrings.Status_Jobs_Many);
    }

    /// <summary>Oldest first, like the Windows queue window.</summary>
    public static IReadOnlyList<QueueJob> Order(IEnumerable<QueueJob> jobs) => jobs.OrderBy(j => j.Submitted).ThenBy(j => j.Id).ToList();

    private static string Bare(string name) => name[(name.LastIndexOf('\\') + 1)..];
}

/// <summary>
/// Keeps overlapping refreshes of one list in order (the 3 s poll and the re-read after a cancel can both be in flight):
/// only the most recently started one may apply its result, so a slower, older read never puts finished jobs back.
/// Also counts consecutive failures, so a queue that keeps failing (spooler stopped) is reported instead of hidden.
/// </summary>
public sealed class RefreshGate(int failuresBeforeReport = 3)
{
    private int _latest;
    private int _failures;

    /// <summary>Call before reading; pass the ticket to <see cref="Succeeded"/> or <see cref="Failed"/>.</summary>
    public int Begin() => ++_latest;

    /// <summary>True when this read is the latest one started, so its result should be shown.</summary>
    public bool Succeeded(int ticket)
    {
        if (ticket != _latest) return false;
        _failures = 0;
        return true;
    }

    /// <summary>True when this (latest) read failed and so did enough before it in a row to say so.</summary>
    public bool Failed(int ticket) => ticket == _latest && ++_failures >= failuresBeforeReport;
}
