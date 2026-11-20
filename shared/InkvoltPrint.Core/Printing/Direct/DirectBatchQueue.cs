using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// Draws one batch file's pages and sends them as one job straight to the printer, then follows the job until the printer says
/// it ended (or goes quiet). <paramref name="onSending"/> is called at the point of no return, before the document goes out;
/// from there <paramref name="ct"/> no longer stops the job: a batch never cancels a job the printer has.
/// </summary>
/// <exception cref="DirectPrintException">The printer couldn't take the request, refused the job, or stopped it; or, before
/// anything went, didn't answer (<see cref="DirectPrintException.NotAnswering"/>).</exception>
public delegate Task DirectBatchSend(IBatchDocument document, BatchPrintJob job, DirectPrintRequest request, IProgress<string>? progress,
    Action onSending, CancellationToken ct);

/// <summary>
/// Batch print (roadmap 2.4) straight to a printer with no Windows queue, or one set to print straight (2.1): a Print-Job per
/// file through <see cref="DirectBatchSend"/> (the app draws the pages as Print a PDF does). The papers and two-sided come from the
/// printer's attributes; a printer that is stopped, reports an error or isn't taking jobs stops the batch before the next file; a
/// setting it can't keep, or pages this PC couldn't draw, fail that file with nothing sent. Each job is followed to its end before
/// the next goes (a printer without a driver often takes one job at a time), so once it's sent the batch waits for it however
/// long it prints (<see cref="EndsOnItsOwnOnceSpooling"/>): one the printer stopped or that may have printed stops the batch, and
/// the batch never sends it again by itself (<see cref="BatchQueueException.MayHaveSent"/>). Stop takes effect up to the point of
/// no return; past it the job finishes, as on a Windows queue.
/// </summary>
public sealed class DirectBatchQueue(string name, IppClient ipp, IppCapsCache caps, DirectBatchSend send) : IBatchQueue
{
    /// <exception cref="DirectPrintException">The printer didn't answer.</exception>
    public async Task<BatchQueueInfo?> ReadAsync(CancellationToken ct)
    {
        IppPrintCaps c;
        try
        {
            c = await caps.GetAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (DirectJob.NoAnswer(ex))
        {
            throw DirectPrintException.NoAnswerBeforeSending(ex);
        }
        if (!c.CanPrint) return null;
        return new BatchQueueInfo(name, c.PaperChoices().Select(p => new BatchPaper(p.Paper.Name, p.Label)).ToList(), c.DefaultPaper?.Name, c.TwoSided);
    }

    public async Task<string?> ProblemAsync(CancellationToken ct)
    {
        try
        {
            return DirectJob.PrinterProblem(await ipp.GetPrinterAttributesAsync(DirectJob.StateAttributes, ct).ConfigureAwait(false));
        }
        catch (Exception ex) when (DirectJob.NoAnswer(ex))
        {
            return CoreStrings.Direct_NotAnswering;
        }
    }

    public string NoAnswer => CoreStrings.Direct_NotAnswering;

    /// <summary>Drawing takes each copy the printer doesn't make itself again: the time to the point of no return counts them.</summary>
    public TimeSpan SendLimit(BatchPrintJob job, BatchPrintOptions options) =>
        options.SendTimeout + options.SendTimePerPage * ((long)job.Pages.Count * Math.Max(1, job.Copies));

    /// <summary>Sent, the job is followed until the printer says it ended or has said nothing new for two minutes.</summary>
    public bool EndsOnItsOwnOnceSpooling => true;

    /// <summary>What a batch file asks of the printer: copies, two-sided and the paper by its PWG name (null: the printer's default).</summary>
    public static DirectPrintRequest Request(BatchPrintJob job) => new(job.Copies, job.TwoSided) { PaperName = job.Paper };

    public async Task<BatchReceipt> SendAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, Action? onSpooling, CancellationToken ct)
    {
        var request = Request(job);
        IppPrintCaps printer;
        try
        {
            printer = await caps.GetAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (DirectJob.NoAnswer(ex))
        {
            throw new BatchQueueException(CoreStrings.Direct_NotAnswering, mayHaveSent: false);
        }
        // Checked before anything's drawn: a setting the printer can't keep fails this file, and the next may be fine.
        if (DirectPrintPlan.Choose(printer, request, out var problem) is null)
        {
            caps.Forget();
            throw new BatchSettingRefusedException(problem!);
        }

        var sending = false;
        try
        {
            await send(document, job, request, progress, () =>
            {
                sending = true;
                onSpooling?.Invoke();
            }, ct).ConfigureAwait(false);
        }
        catch (DirectPrintException ex) when (sending)
        {
            // The batch's summary reads it as a sentence ("Stopped at file 2 of 3 (b.pdf): The printer stopped the job. 1 sent…").
            throw new BatchQueueException(Sentence(ex.Message), ex.MayHavePrinted);
        }
        catch (DirectPrintException ex) when (ex.NotAnswering)
        {
            throw new BatchQueueException(ex.Message, mayHaveSent: false); // the printer went quiet: the rest wouldn't go either
        }
        catch (DirectPrintException ex)
        {
            throw new BatchFileException(ex.Message); // drawn wrong, or the printer changed since the check: nothing went
        }
        catch (OperationCanceledException) when (sending)
        {
            // Past the point of no return a stop must not read as "not sent": the printer may have the job.
            throw new BatchQueueException(CoreStrings.Batch_YouStopped, mayHaveSent: true);
        }
        catch (Exception ex) when (!sending && ex is IOException or UnauthorizedAccessException or FormatException or InvalidDataException)
        {
            // This PC's side (its disk, a page's drawing, the raster file): this file fails, the printer is fine.
            throw new BatchFileException(CoreStrings.Direct_NotDrawn);
        }
        return new BatchReceipt(job.Pages.Count, BatchPrintSettings.Sheets(job.Pages.Count, job.Copies, job.TwoSided));
    }

    private static string Sentence(string text)
    {
        var why = text.TrimEnd();
        return why.EndsWith('.') ? why : why + ".";
    }
}
