using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// The print queue card for a printer printed to without a Windows queue: the jobs the printer itself holds (Get-Jobs,
/// not-completed), as <see cref="QueueJob"/>s, and Cancel-Job for one of them.
/// </summary>
public static class PrinterJobs
{
    /// <summary>Most jobs listed: a printer holds a handful.</summary>
    public const int MaxJobs = 100;

    private static readonly string[] Wanted =
    [
        "job-id", "job-name", "job-state", "job-state-reasons", "job-originating-user-name", "job-impressions",
        "job-impressions-completed", "date-time-at-creation",
    ];

    public static byte[] GetJobsRequest(string printerUri, string user, int requestId = 1) =>
        new IppRequest(IppCodec.GetJobs, requestId, printerUri)
            .Name("requesting-user-name", user.Trim() is { Length: > 0 } u ? u : "Inkvolt Print")
            .Integer("limit", MaxJobs)
            .Keyword("which-jobs", "not-completed")
            .Keywords("requested-attributes", Wanted)
            .ToArray();

    /// <summary>The jobs in a Get-Jobs answer in the card's order (oldest first); <paramref name="now"/> stands in for a job's missing creation time.</summary>
    public static IReadOnlyList<QueueJob> Parse(ReadOnlySpan<byte> answer, DateTime now)
    {
        var (status, groups) = IppCodec.DecodeGroups(answer);
        if (status >= 0x0100) throw new DirectPrintException(DirectJob.Refused(status), mayHavePrinted: false);
        var jobs = new List<QueueJob>();
        foreach (var (tag, attrs) in groups)
        {
            if (tag != IppCodec.JobTag) continue;
            var job = new IppResponse(status, attrs);
            if (job.Int("job-id") is not { } id || id <= 0 || DirectJob.StateOf(job) is not { } state) continue;
            var name = job.Str("job-name")?.ReplaceLineEndings(" ").Trim() ?? "";
            var owner = job.Str("job-originating-user-name")?.Trim() ?? "";
            var pages = job.Int("job-impressions") is { } p and >= 0 and <= 1_000_000 ? p : 0;
            var submitted = attrs.TryGetValue("date-time-at-creation", out var when) && when.FirstOrDefault() is DateTimeOffset at ? at.LocalDateTime : now;
            jobs.Add(new QueueJob(id, Short(name, 120), pages, state.PagesDone ?? 0, Status(state), submitted, Short(owner, 60)));
            if (jobs.Count >= MaxJobs) break;
        }
        return QueueJobText.Order(jobs);
    }

    private static string Short(string s, int max) => s.Length > max ? s[..max] + "…" : s;

    /// <summary>The printer's job state as the spooler's status bits the card already words.</summary>
    internal static JobStatus Status(DirectJobState s)
    {
        var bits = s.State switch
        {
            DirectJobState.Held => JobStatus.Paused,
            DirectJobState.Processing => JobStatus.Printing,
            DirectJobState.Stopped => JobStatus.Blocked,
            DirectJobState.Canceled => JobStatus.Deleted,
            DirectJobState.Aborted => JobStatus.Error,
            DirectJobState.Completed => JobStatus.Completed,
            _ => JobStatus.None,
        };
        if (s.Reasons.Contains("resources-are-not-ready") || s.Reasons.Any(r => r.StartsWith("media-", StringComparison.Ordinal))) bits |= JobStatus.PaperOut;
        if (s.Reasons.Contains("printer-stopped")) bits |= JobStatus.UserIntervention;
        return bits;
    }
}

/// <summary>Where a print goes: the printer's Windows queue, straight to the printer over IPP, or nowhere.</summary>
public enum PrintRoute
{
    None,
    Queue,
    Direct,
}

public static class PrintRoutes
{
    /// <summary>
    /// The Windows queue stays the default where one exists; straight to the printer when there is none, or when the
    /// person chose it for this printer. Either needs the printer to take one of the raster formats.
    /// </summary>
    public static PrintRoute Choose(bool hasQueue, bool printerTakesRaster, bool personChoseDirect) =>
        printerTakesRaster && (personChoseDirect || !hasQueue) ? PrintRoute.Direct
        : hasQueue ? PrintRoute.Queue
        : PrintRoute.None;
}
