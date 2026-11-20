using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>A job on the printer as Get-Job-Attributes tells it (RFC 8011 §5.3.7 <c>job-state</c>: 3 pending … 9 completed).</summary>
public sealed record DirectJobState(int State, IReadOnlyList<string> Reasons, string? Message, int? PagesDone)
{
    public const int Pending = 3, Held = 4, Processing = 5, Stopped = 6, Canceled = 7, Aborted = 8, Completed = 9;

    public bool Ended => State >= Canceled;
}

/// <summary>Why a job didn't go, in plain words; <see cref="MayHavePrinted"/> says whether the printer may have it anyway.</summary>
public sealed class DirectPrintException(string message, bool mayHavePrinted) : Exception(message)
{
    public bool MayHavePrinted { get; } = mayHavePrinted;

    /// <summary>The IPP status the printer answered with, for the log (never shown).</summary>
    public ushort? IppStatus { get; init; }
}

/// <summary>
/// One job sent straight to a printer over IPP: Print-Job with the job's attributes and the raster after them, then
/// Get-Job-Attributes until it ends, then Cancel-Job if asked. The requests (<see cref="PrintJobRequest"/> and the rest) are
/// separate from the sending so the bytes are tested.
/// </summary>
public static class DirectJob
{
    /// <summary>
    /// Print-Job's attributes (RFC 8011 §4.2.1.1, PWG 5100.14 §6): the operation's (user, job name, document format), then
    /// the job's: <c>copies</c> with <c>multiple-document-handling</c> (collated), <c>sides</c>, <c>print-color-mode</c>, <c>print-quality</c> and <c>media-col</c> (size, margins,
    /// type and source), each only when it says something.
    /// </summary>
    public static byte[] PrintJobRequest(string printerUri, string user, string jobName, DirectPrintPlan plan, int requestId = 1)
    {
        var r = new IppRequest(IppCodec.PrintJob, requestId, printerUri)
            .Name("requesting-user-name", User(user))
            .Name("job-name", jobName.Length == 0 ? "Inkvolt Print" : jobName)
            .MimeMediaType("document-format", plan.DocumentFormat)
            .JobGroup();
        if (plan.Copies > 1)
        {
            // The plan has the printer make copies only when it collates them (PWG 5100.19's keyword); else it repeats the pages.
            r.Integer("copies", plan.Copies);
            r.Keyword("multiple-document-handling", "separate-documents-collated-copies");
        }
        r.Keyword("sides", plan.TwoSided ? "two-sided-long-edge" : "one-sided");
        if (plan.ColorMode is { } mode) r.Keyword("print-color-mode", mode);
        if (plan.Quality is { } q) r.Enum("print-quality", q);
        var paper = plan.Paper;
        r.Collection("media-col", c =>
        {
            c.Collection("media-size", s => s.Integer("x-dimension", paper.WidthHmm).Integer("y-dimension", paper.HeightHmm));
            c.Integer("media-bottom-margin", paper.Bottom).Integer("media-left-margin", paper.Left)
                .Integer("media-right-margin", paper.Right).Integer("media-top-margin", paper.Top);
            if (plan.MediaType is { } type) c.Keyword("media-type", type);
            if (paper.Source is { } source) c.Keyword("media-source", source);
        });
        return r.ToArray();
    }

    public static readonly string[] JobAttributes =
        ["job-id", "job-state", "job-state-reasons", "job-state-message", "job-impressions-completed", "job-media-sheets-completed"];

    public static byte[] GetJobAttributesRequest(string printerUri, string user, int jobId, int requestId = 1) =>
        new IppRequest(IppCodec.GetJobAttributes, requestId, printerUri)
            .Integer("job-id", jobId)
            .Name("requesting-user-name", User(user))
            .Keywords("requested-attributes", JobAttributes)
            .ToArray();

    public static byte[] CancelJobRequest(string printerUri, string user, int jobId, int requestId = 1) =>
        new IppRequest(IppCodec.CancelJob, requestId, printerUri)
            .Integer("job-id", jobId)
            .Name("requesting-user-name", User(user))
            .ToArray();

    /// <summary>A user name the printer can show: the account name, never empty.</summary>
    private static string User(string user) => user.Trim() is { Length: > 0 } u ? u : "Inkvolt Print";

    /// <summary>A job's state from a Get-Job-Attributes or Print-Job answer; null when it has none.</summary>
    public static DirectJobState? StateOf(IppResponse r)
    {
        if (r.Int("job-state") is not { } state || state is < 3 or > 9) return null;
        var reasons = r.Strs("job-state-reasons").Take(IppClient.MaxAlerts).Where(x => x.Length <= 255).ToList();
        var message = r.Str("job-state-message")?.ReplaceLineEndings(" ").Trim() is { Length: > 0 } m ? (m.Length > 200 ? m[..200] + "…" : m) : null;
        int? done = r.Int("job-impressions-completed") is { } i and >= 0 and <= 1_000_000 ? i
            : r.Int("job-media-sheets-completed") is { } s and >= 0 and <= 1_000_000 ? s : null;
        return new DirectJobState(state, reasons, message, done);
    }

    /// <summary>
    /// Sends the job. Returns its id (0 when the printer gave none), and the state it answered with. A refusal before the
    /// document was read (bad request, unsupported format, busy) has sent nothing; an error after, or no answer, may have.
    /// </summary>
    /// <exception cref="DirectPrintException">The printer refused or didn't answer.</exception>
    public static async Task<(int JobId, DirectJobState? State)> SendAsync(IppClient ipp, string user, string jobName, DirectPrintPlan plan,
        Stream document, CancellationToken ct = default)
    {
        IppResponse answer;
        try
        {
            answer = await ipp.PrintJobAsync(PrintJobRequest(ipp.PrinterUri, user, jobName, plan), document, SendTimeout(document), ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (NoAnswer(ex))
        {
            throw new DirectPrintException(CoreStrings.Direct_NoAnswer, mayHavePrinted: true);
        }
        if (!answer.Ok) throw new DirectPrintException(Refused(answer.StatusCode), mayHavePrinted: false) { IppStatus = answer.StatusCode };
        return (answer.Int("job-id") is { } id and > 0 ? id : 0, StateOf(answer));
    }

    /// <summary>The printer didn't answer, or not in a way that can be read: what a request to it throws besides a refusal.</summary>
    public static bool NoAnswer(Exception ex) =>
        ex is HttpRequestException or TimeoutException or IOException or Net.DeviceHttpException or FormatException
        || ex is TaskCanceledException { InnerException: TimeoutException };

    /// <summary>What <see cref="PrinterProblem"/> reads.</summary>
    public static readonly string[] StateAttributes =
        ["printer-state", "printer-state-reasons", "printer-state-message", "printer-is-accepting-jobs", "printer-alert", "printer-alert-description"];

    /// <summary>
    /// Why nothing should be sent to the printer now, in plain words, or null: it refused the question, isn't taking jobs, or is
    /// stopped or reports an error (a jam, no paper, a door open). Warnings (low ink) don't stop anything. The printer's own words
    /// are shortened to one line.
    /// </summary>
    public static string? PrinterProblem(IppResponse r)
    {
        if (!r.Ok) return Refused(r.StatusCode);
        if (r.Attributes.TryGetValue("printer-is-accepting-jobs", out var accepting) && accepting.FirstOrDefault() is false) return CoreStrings.Direct_NotAccepting;
        var status = IppClient.ToStatus(r);
        if (status.Severity != Model.Severity.Error) return null;
        var said = status.Alerts.FirstOrDefault(a => a.Severity == Model.Severity.Error)?.Message ?? status.Message;
        said = said.ReplaceLineEndings(" ").Trim().TrimEnd('.');
        if (said.Length > 120) said = said[..120] + "…";
        return (said.Length == 0 ? CoreStrings.Status_Stopped : said) + ".";
    }

    /// <summary>A minute, and a minute more for every 20 MB (a busy printer reads slowly), at most 30 minutes.</summary>
    internal static TimeSpan SendTimeout(Stream document) =>
        TimeSpan.FromMinutes(Math.Min(30, 1 + (document.CanSeek ? document.Length / (20L << 20) : 10)));

    /// <summary>RFC 8011 §13.1.4 client errors and §13.1.5 server errors, in plain words.</summary>
    public static string Refused(ushort status) => status switch
    {
        // forbidden, not-authenticated, not-authorized
        0x0401 or 0x0402 or 0x0403 => CoreStrings.Direct_RefusedSignIn,
        // request-entity-too-large
        0x0408 => CoreStrings.Direct_RefusedTooLarge,
        // document-format-not-supported, attributes-or-values-not-supported, conflicting-attributes, compression-not-supported,
        // compression-error, document-format-error, document-unprintable-error
        0x040A or 0x040B or 0x040E or 0x040F or 0x0410 or 0x0411 or 0x041B => CoreStrings.Direct_RefusedFormat,
        // service-unavailable, temporary-error, not-accepting-jobs, busy
        0x0502 or 0x0505 or 0x0506 or 0x0507 => CoreStrings.Direct_RefusedBusy,
        // job-canceled: cancelled at the printer while it came in
        0x0508 => CoreStrings.Direct_CanceledAtPrinter,
        // the rest (bad-request, uri-scheme-not-supported, internal-error, device-error…): refused, no more said
        _ => CoreStrings.Direct_Refused,
    };

    /// <summary>
    /// Asks how the job is doing every <paramref name="every"/> until it ends, reporting each change, and returns its last
    /// state. Stops asking (returning what it knows) when <paramref name="ct"/> is cancelled or nothing changes for
    /// <paramref name="quiet"/>: the printer has the job by then, and its own panel says the rest.
    /// </summary>
    public static async Task<DirectJobState?> WatchAsync(IppClient ipp, string user, int jobId, IProgress<DirectJobState>? progress,
        TimeSpan every, TimeSpan quiet, CancellationToken ct)
    {
        DirectJobState? last = null;
        var since = DateTime.UtcNow;
        var failures = 0;
        while (!ct.IsCancellationRequested && DateTime.UtcNow - since < quiet)
        {
            try
            {
                var r = await ipp.GetJobAttributesAsync(GetJobAttributesRequest(ipp.PrinterUri, user, jobId), ct).ConfigureAwait(false);
                if (r.StatusCode == 0x0406) return last ?? new DirectJobState(DirectJobState.Completed, [], null, null); // gone: done and forgotten
                if (StateOf(r) is { } state)
                {
                    if (last is null || state != last && (state.State != last.State || state.PagesDone != last.PagesDone || !state.Reasons.SequenceEqual(last.Reasons)))
                    {
                        progress?.Report(state);
                        since = DateTime.UtcNow;
                    }
                    last = state;
                    if (state.Ended) return state;
                }
                failures = 0;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex) when (NoAnswer(ex))
            {
                if (++failures >= 5) break; // the printer stopped answering about it: it has the job
            }
            try { await Task.Delay(every, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
        return last;
    }

    /// <summary>Cancel-Job, once. True when the printer took it (or the job was already gone).</summary>
    public static async Task<bool> CancelAsync(IppClient ipp, string user, int jobId, CancellationToken ct = default)
    {
        try
        {
            var r = await ipp.CancelJobAsync(CancelJobRequest(ipp.PrinterUri, user, jobId), ct).ConfigureAwait(false);
            // client-error-not-possible (it already ended), not-found, gone: nothing left to stop
            return r.Ok || r.StatusCode is 0x0404 or 0x0406 or 0x0407;
        }
        catch (Exception ex) when (NoAnswer(ex))
        {
            return false;
        }
    }

    /// <summary>
    /// The person cancelled a job the printer has: Cancel-Job, then an <see cref="OperationCanceledException"/> when the printer
    /// took it, or a <see cref="DirectPrintException"/> saying it may still print when the printer refused or didn't answer.
    /// Always throws.
    /// </summary>
    public static async Task StopAsync(IppClient ipp, string user, int jobId, CancellationToken cancelled)
    {
        if (!await CancelAsync(ipp, user, jobId).ConfigureAwait(false))
            throw new DirectPrintException(CoreStrings.Direct_CancelNotTaken, mayHavePrinted: true);
        throw new OperationCanceledException(cancelled);
    }

    /// <summary>The state in the app's words: "Printing page 3", "Printed", "Stopped: …", for the line under Print.</summary>
    public static string Describe(DirectJobState state, int pages)
    {
        var reason = Reason(state.Reasons);
        return state.State switch
        {
            DirectJobState.Completed when state.Reasons.Contains("job-completed-with-errors") => CoreStrings.Direct_DoneWithErrors,
            DirectJobState.Completed => CoreStrings.Direct_Printed,
            DirectJobState.Canceled => CoreStrings.Direct_CanceledAtPrinter,
            DirectJobState.Aborted => reason is null ? CoreStrings.Direct_Aborted : string.Format(System.Globalization.CultureInfo.CurrentCulture, CoreStrings.Direct_AbortedBecause, reason),
            DirectJobState.Stopped or DirectJobState.Held => string.Format(System.Globalization.CultureInfo.CurrentCulture, CoreStrings.Direct_Waiting,
                reason ?? state.Message ?? CoreStrings.Direct_PrinterStopped),
            DirectJobState.Processing when state.PagesDone is { } done && pages > 0 =>
                string.Format(System.Globalization.CultureInfo.CurrentCulture, CoreStrings.Direct_PrintingPage, Math.Min(done + 1, pages), pages),
            DirectJobState.Processing => CoreStrings.Direct_Printing,
            _ => CoreStrings.Direct_Queued,
        };
    }

    /// <summary>The job-state-reasons that need the person, in plain words (RFC 8011 §5.3.8, PWG 5100.7), or null.</summary>
    public static string? Reason(IEnumerable<string> reasons)
    {
        foreach (var r in reasons)
            switch (r)
            {
                case "document-format-error":
                case "unsupported-document-format":
                case "document-unprintable-error":
                    return CoreStrings.Direct_ReasonFormat;
                case "job-hold-until-specified":
                case "job-held-for-authorization":
                case "job-password-wait":
                    return CoreStrings.Direct_ReasonHeld;
                case "printer-stopped":
                case "printer-stopped-partly":
                    return CoreStrings.Direct_PrinterStopped;
                case "resources-are-not-ready":
                    return CoreStrings.Direct_ReasonPaper;
                case "job-canceled-at-device":
                    return CoreStrings.Direct_CanceledAtPrinter;
            }
        return null;
    }
}
