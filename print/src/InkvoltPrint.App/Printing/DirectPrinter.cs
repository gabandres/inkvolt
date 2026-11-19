using System.IO;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Core.Printing.Raster;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>Where a job goes: the printer's Windows queue, or straight to the printer over IPP (roadmap 2.1).</summary>
public abstract record PrintTarget
{
    public sealed record Queue(string Name) : PrintTarget;

    /// <param name="Sent">Called with the job's name and pages once the printer has it (the demo's made-up print queue card).</param>
    public sealed record Direct(IppClient Ipp, string User, Action<string, int>? Sent = null) : PrintTarget;
}

/// <summary>
/// Driverless printing (roadmap 2.1): the same pages Print a PDF, Copy and Print photos lay out for a Windows queue
/// (their <see cref="DocumentPaginator"/>s), drawn by WPF at the plan's resolution on the printer's own paper
/// (<c>media-col-database</c>), turned into PWG raster, Apple raster or PCLm (<see cref="RasterWriter"/>) in a temporary file,
/// sent with Print-Job, then followed with Get-Job-Attributes until the printer says it's done. What to send and how is
/// decided in Core (<see cref="DirectPrintPlan"/>, <see cref="DirectJob"/>); this draws and hands over.
/// </summary>
public static class DirectPrinter
{
    private static readonly TimeSpan WatchEvery = TimeSpan.FromSeconds(1), WatchQuiet = TimeSpan.FromMinutes(2);

    /// <summary>Developer check only (<see cref="DevDirectPrint"/>): a folder each job's raster is copied into before it's sent.</summary>
    internal static string? KeepCopyIn { get; set; }

    /// <summary>Developer check only: the one raster format sent.</summary>
    internal static RasterFormat? OnlyFormat { get; set; }

    /// <summary>What the printer can do for the Print and Copy tabs (two-sided), read off the UI thread.</summary>
    public static async Task<IppPrintCaps> ReadCapsAsync(PrintTarget.Direct target, CancellationToken ct = default) =>
        IppPrintCaps.From(await target.Ipp.GetPrinterAttributesAsync(IppPrintCaps.Requested, ct).ConfigureAwait(false));

    /// <summary>
    /// Draws, sends and follows one job. <paramref name="onSending"/> marks the point of no return (the document starts going
    /// out); <paramref name="onSent"/> the printer has it, after which <paramref name="ct"/> cancels it at the printer (Cancel-Job).
    /// Returns true when the printer said the job was printed, false when it has it but didn't say yet.
    /// </summary>
    /// <exception cref="DirectPrintException">The printer can't take the request, refused it, or stopped it.</exception>
    /// <exception cref="OperationCanceledException">Cancelled before sending, or cancelled at the printer after.</exception>
    public static async Task<bool> PrintAsync(PrintTarget.Direct target, string jobName, DirectPrintRequest request,
        Func<Size, PrintImages, DocumentPaginator> paginator, IProgress<string>? progress, CancellationToken ct,
        Action? onSending = null, Action? onSent = null)
    {
        var caps = await ReadCapsAsync(target, ct);
        if (OnlyFormat is { } only)
        {
            request = request with { Format = only };
            // ippeveprinter lists application/PCLm but drops every pclm-* attribute it's given: the check says 600 dpi for it.
            if (only == RasterFormat.Pclm && caps.PclmDpis.Count == 0)
                caps = caps with { PclmDpis = [600], Formats = [.. caps.Formats, RasterFormat.Pclm] };
        }
        var plan = DirectPrintPlan.Choose(caps, request, out var problem) ?? throw new DirectPrintException(problem!, mayHavePrinted: false);
        Directory.CreateDirectory(PrintImages.Root);
        var path = Path.Combine(PrintImages.Root, $"{Guid.NewGuid():N}.raster");
        await using var document = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1 << 16, FileOptions.DeleteOnClose);
        var pages = await DrawAsync(plan, paginator, document, progress, ct);
        document.Position = 0;
        if (KeepCopyIn is { } keep)
        {
            await using (var copy = File.Create(Path.Combine(keep, $"{jobName}.{plan.Format.ToString().ToLowerInvariant()}")))
                await document.CopyToAsync(copy, ct);
            document.Position = 0;
        }
        ct.ThrowIfCancellationRequested();

        onSending?.Invoke();
        progress?.Report(Core.Plural.Of(pages, Strings.Print_SendingPages_One, Strings.Print_SendingPages_Many));
        var (jobId, state) = await DirectJob.SendAsync(target.Ipp, target.User, jobName, plan, document, CancellationToken.None);
        Log.Write($"Direct print: {plan.DocumentFormat} {plan.Dpi} dpi {plan.Color} {plan.Paper.Name}, {pages} page(s) × {plan.Copies * plan.Repeat}, {document.Length:N0} bytes, job {jobId}");
        target.Sent?.Invoke(jobName, pages);
        onSent?.Invoke();
        if (jobId == 0) return state is { State: DirectJobState.Completed };

        var impressions = plan.PagesPerCopy(pages) * plan.Repeat * plan.Copies;
        var watched = new Progress<DirectJobState>(s => progress?.Report(DirectJob.Describe(s, impressions)));
        if (state is not null) progress?.Report(DirectJob.Describe(state, impressions));
        var last = await DirectJob.WatchAsync(target.Ipp, target.User, jobId, watched, WatchEvery, WatchQuiet, ct) ?? state;
        if (ct.IsCancellationRequested)
        {
            await DirectJob.CancelAsync(target.Ipp, target.User, jobId);
            throw new OperationCanceledException(ct);
        }
        if (last is { State: DirectJobState.Aborted or DirectJobState.Canceled })
            throw new DirectPrintException(DirectJob.Describe(last, impressions), mayHavePrinted: true);
        return last is { State: DirectJobState.Completed };
    }

    /// <summary>
    /// Draws every page into the raster file on an STA thread of its own (WPF's drawing needs one), with its own pictures
    /// (<see cref="PrintImages"/>): each page on white at the plan's drawing resolution, enlarged to the printer's when it is
    /// a multiple, then encoded and let go. Copies the printer doesn't make are drawn again; a two-sided copy with an odd
    /// count gets a blank back. Returns one copy's pages.
    /// </summary>
    private static Task<int> DrawAsync(DirectPrintPlan plan, Func<Size, PrintImages, DocumentPaginator> paginator, Stream output,
        IProgress<string>? progress, CancellationToken ct)
    {
        var done = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                using var images = new PrintImages();
                var paper = new Size(plan.Paper.WidthInches * 96, plan.Paper.HeightInches * 96);
                var pages = paginator(paper, images);
                var count = pages.PageCount;
                if (count < 1) throw new DirectPrintException(Strings.Print_FewerPages, mayHavePrinted: false);
                var perCopy = plan.PagesPerCopy(count);
                var writer = RasterWriter.For(output, plan.Job(perCopy));
                var total = perCopy * plan.Repeat;
                for (var copy = 0; copy < plan.Repeat; copy++)
                    for (var i = 0; i < perCopy; i++)
                    {
                        ct.ThrowIfCancellationRequested();
                        progress?.Report(string.Format(Strings.Print_DirectDrawing, writer.Written + 1, total));
                        writer.Write(i < count ? Draw(pages.GetPage(i).Visual, writer.Job, plan) : RasterPage.Blank(writer.Job.WidthPixels, writer.Job.HeightPixels, plan.Color));
                    }
                writer.Finish();
                done.SetResult(count);
            }
            catch (Exception ex)
            {
                done.SetException(ex);
            }
        })
        { IsBackground = true, Name = "Inkvolt Print direct" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    private static RasterPage Draw(Visual visual, RasterJob job, DirectPrintPlan plan)
    {
        var k = plan.Enlarge;
        var (w, h) = ((job.WidthPixels + k - 1) / k, (job.HeightPixels + k - 1) / k);
        var bitmap = new RenderTargetBitmap(w, h, plan.RenderDpi, plan.RenderDpi, PixelFormats.Pbgra32);
        var white = new DrawingVisual();
        using (var dc = white.RenderOpen()) dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, w * 96.0 / plan.RenderDpi, h * 96.0 / plan.RenderDpi));
        bitmap.Render(white);
        bitmap.Render(visual);
        var pixels = new byte[w * h * 4];
        bitmap.CopyPixels(pixels, w * 4, 0);
        return RasterPage.FromBgra(w, h, w * 4, pixels, plan.Color).Enlarged(k).Fitted(job.WidthPixels, job.HeightPixels);
    }
}

/// <summary>
/// Print a PDF, Copy and Print photos send through here: to the Windows queue as before (<see cref="QueuePrinter"/>), or
/// straight to the printer (<see cref="DirectPrinter"/>) with the same pages.
/// </summary>
public static class PrintTargets
{
    /// <summary>Whether two-sided can be offered. A queue asks its driver (the last answer is shown while it does); a printer its IPP attributes.</summary>
    public static async Task<bool> SupportsTwoSidedAsync(PrintTarget target, AppState state)
    {
        switch (target)
        {
            case PrintTarget.Direct direct:
                return (await DirectPrinter.ReadCapsAsync(direct)).TwoSided;
            case PrintTarget.Queue { Name: var queue }:
                var can = await Task.Run(() =>
                {
                    using var q = QueuePrinter.Open(queue);
                    return QueuePrinter.SupportsTwoSided(q);
                });
                state.SetTwoSided(queue, can);
                return can;
            default:
                return false;
        }
    }

    /// <summary>Returns true when the printer said it printed the job (straight to the printer only).</summary>
    public static async Task<bool> PrintPdfAsync(PrintTarget target, PdfSource pdf, PrintOptions options, IProgress<string> progress, CancellationToken ct,
        Action? onSpooling = null, Action? onSent = null)
    {
        if (target is PrintTarget.Queue queue)
        {
            await QueuePrinter.PrintAsync(queue.Name, pdf, options, progress, ct, onSpooling);
            return false;
        }
        var pages = new List<RenderedPage>(options.Pages.Count);
        for (var i = 0; i < options.Pages.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            progress.Report(string.Format(Strings.Print_PreparingPage, i + 1, options.Pages.Count));
            pages.Add(await pdf.RenderAsync(options.Pages[i], QueuePrinter.RenderDpi, ct: ct));
        }
        return await DirectPrinter.PrintAsync((PrintTarget.Direct)target, options.JobName, new DirectPrintRequest(options.Copies, options.TwoSided),
            (paper, images) => new QueuePrinter.RenderedPaginator(pages, paper, options.Sizing, images), progress, ct, onSpooling, onSent);
    }

    /// <summary>Copies: scanned pages, each on its own sheet.</summary>
    public static Task PrintPagesAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, int copies, bool twoSided, string jobName,
        PageSizing sizing = PageSizing.ActualSize) =>
        target switch
        {
            PrintTarget.Queue q => QueuePrinter.PrintPagesAsync(q.Name, pages, copies, twoSided, jobName, sizing),
            PrintTarget.Direct d => DirectPrinter.PrintAsync(d, jobName, new DirectPrintRequest(copies, twoSided),
                (paper, images) => new QueuePrinter.RenderedPaginator(pages, paper, sizing, images), null, CancellationToken.None),
            _ => throw new ArgumentOutOfRangeException(nameof(target)),
        };

    /// <summary>ID card copy: front and back on one sheet.</summary>
    public static Task PrintIdCardAsync(PrintTarget target, RenderedPage front, RenderedPage back, int copies, string jobName) =>
        target switch
        {
            PrintTarget.Queue q => QueuePrinter.PrintIdCardAsync(q.Name, front, back, copies, jobName),
            PrintTarget.Direct d => DirectPrinter.PrintAsync(d, jobName, new DirectPrintRequest(copies),
                (paper, images) => new QueuePrinter.IdCardPaginator(front, back, paper, images), null, CancellationToken.None),
            _ => throw new ArgumentOutOfRangeException(nameof(target)),
        };
}
