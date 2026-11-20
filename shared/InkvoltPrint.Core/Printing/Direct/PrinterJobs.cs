using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// The jobs a printer printed to without a Windows queue holds (Get-Jobs), as <see cref="QueueJob"/>s: the print queue card's list
/// and Cancel-Job for one of them, and what job alerts read (<see cref="DirectJobWatch"/>).
/// </summary>
public static class PrinterJobs
{
    /// <summary>Most jobs listed: a printer holds a handful.</summary>
    public const int MaxJobs = 100;

    /// <summary>Get-Jobs' <c>which-jobs</c> (RFC 8011 §4.2.6.1): the jobs still to print or printing, and the ones that ended.</summary>
    public const string NotCompleted = "not-completed", Completed = "completed";

    private static readonly string[] Wanted =
    [
        "job-id", "job-name", "job-state", "job-state-reasons", "job-originating-user-name", "job-originating-host-name", "job-impressions",
        "job-impressions-completed", "date-time-at-creation", "date-time-at-completed",
    ];

    public static byte[] GetJobsRequest(string printerUri, string user, int requestId = 1, string which = NotCompleted) =>
        new IppRequest(IppCodec.GetJobs, requestId, printerUri)
            .Name("requesting-user-name", user.Trim() is { Length: > 0 } u ? u : "Inkvolt Print")
            .Integer("limit", MaxJobs)
            .Keyword("which-jobs", which)
            .Keywords("requested-attributes", Wanted)
            .ToArray();

    /// <summary>One job of a Get-Jobs answer: as the card lists it, its state, and the printer's times for it where it gave them (local time).</summary>
    public sealed record Listed(QueueJob Job, DirectJobState State, DateTime? Created, DateTime? Ended);

    /// <summary>
    /// The jobs in a Get-Jobs answer as the printer listed them, at most <see cref="MaxJobs"/>. A job's missing creation time is
    /// <see cref="DateTime.MinValue"/> in <see cref="Listed.Job"/>: the caller says what stands in for it.
    /// </summary>
    /// <exception cref="DirectPrintException">The printer refused the request.</exception>
    public static IReadOnlyList<Listed> Read(ReadOnlySpan<byte> answer)
    {
        var (status, groups) = IppCodec.DecodeGroups(answer);
        if (status >= 0x0100) throw new DirectPrintException(DirectJob.Refused(status), mayHavePrinted: false) { IppStatus = status };
        var jobs = new List<Listed>();
        foreach (var (tag, attrs) in groups)
        {
            if (tag != IppCodec.JobTag) continue;
            var job = new IppResponse(status, attrs);
            if (job.Int("job-id") is not { } id || id <= 0 || DirectJob.StateOf(job) is not { } state) continue;
            var name = job.Str("job-name")?.ReplaceLineEndings(" ").Trim() ?? "";
            var owner = job.Str("job-originating-user-name")?.Trim() ?? "";
            var pages = job.Int("job-impressions") is { } p and >= 0 and <= 1_000_000 ? p : 0;
            var created = Time(attrs, "date-time-at-creation");
            var listed = new QueueJob(id, Short(name, 120), pages, state.PagesDone ?? 0, Status(state), created ?? DateTime.MinValue, Short(owner, 60))
            {
                Machine = Host(job.Str("job-originating-host-name")),
            };
            jobs.Add(new Listed(listed, state, created, Time(attrs, "date-time-at-completed")));
            if (jobs.Count >= MaxJobs) break;
        }
        return jobs;
    }

    /// <summary>The jobs in a Get-Jobs answer in the card's order (oldest first); <paramref name="now"/> stands in for a job's missing creation time.</summary>
    public static IReadOnlyList<QueueJob> Parse(ReadOnlySpan<byte> answer, DateTime now) =>
        QueueJobText.Order(Read(answer).Select(l => l.Created is null ? l.Job with { Submitted = now } : l.Job).ToList());

    private static DateTime? Time(Dictionary<string, List<object>> attrs, string name) =>
        attrs.TryGetValue(name, out var when) && when.FirstOrDefault() is DateTimeOffset at ? at.LocalDateTime : null;

    /// <summary>
    /// The PC a job came from, where the printer names it (CUPS's <c>job-originating-host-name</c>). An address can't be held to a
    /// PC's name, so it's left out, as is anything that isn't a plain host name.
    /// </summary>
    private static string? Host(string? host)
    {
        var h = host?.Trim() ?? "";
        if (h.Length is 0 or > 255 || System.Net.IPAddress.TryParse(h.Trim('[', ']'), out _) || h.Equals("localhost", StringComparison.OrdinalIgnoreCase)) return null;
        return h.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.' or '_') ? h : null;
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
