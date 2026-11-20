using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// Draws one batch file's pages and sends them as one job straight to the printer, then follows the job until the printer says
/// it ended (or goes quiet). <paramref name="onSending"/> is called at the point of no return, before the document goes out;
/// from there <paramref name="ct"/> no longer stops the job: a batch never cancels a job the printer has.
/// </summary>
/// <exception cref="DirectPrintException">The printer couldn't take the request, refused the job, or stopped it.</exception>
public delegate Task DirectBatchSend(IBatchDocument document, BatchPrintJob job, DirectPrintRequest request, IProgress<string>? progress,
    Action onSending, CancellationToken ct);

/// <summary>
/// Batch print (roadmap 2.4) straight to a printer with no Windows queue, or one set to print straight (2.1): a Print-Job per
/// file through <see cref="DirectBatchSend"/> (the app draws the pages as Print a PDF does). The papers and two-sided come from the
/// printer's attributes; a printer that is stopped, reports an error or isn't taking jobs stops the batch before the next file; a
/// setting it can't keep fails that file with nothing sent. Each job is followed to its end before the next goes (a printer
/// without a driver often takes one job at a time): one the printer stopped or that may have printed stops the batch, and the
/// batch never sends it again by itself (<see cref="BatchQueueException.MayHaveSent"/>). Stop takes effect up to the point of no
/// return; past it the job finishes, as on a Windows queue.
/// </summary>
public sealed class DirectBatchQueue(string name, IppClient ipp, IppCapsCache caps, DirectBatchSend send) : IBatchQueue
{
    public async Task<BatchQueueInfo?> ReadAsync(CancellationToken ct)
    {
        var c = await caps.GetAsync(ct).ConfigureAwait(false);
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
            var why = ex.Message.TrimEnd();
            throw new BatchQueueException(why.EndsWith('.') ? why : why + ".", ex.MayHavePrinted);
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
        catch (Exception ex) when (!sending && DirectJob.NoAnswer(ex))
        {
            throw new BatchQueueException(CoreStrings.Direct_NotAnswering, mayHaveSent: false);
        }
        return new BatchReceipt(job.Pages.Count, BatchPrintSettings.Sheets(job.Pages.Count, job.Copies, job.TwoSided));
    }
}
