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

    /// <param name="Caps">The printer's attributes, read once for this connection and kept a while (<see cref="IppCapsCache"/>).</param>
    /// <param name="Sent">Called with the job's name and pages once the printer has it (the demo's made-up print queue card).</param>
    public sealed record Direct(IppClient Ipp, string User, IppCapsCache Caps, Action<string, int>? Sent = null) : PrintTarget
    {
        /// <summary>A target with a cache of its own (the developer check).</summary>
        public static Direct For(IppClient ipp, string user, Action<string, int>? sent = null) => new(ipp, user, CapsOf(ipp), sent);

        /// <summary>A cache reading this printer's attributes for driverless printing.</summary>
        public static IppCapsCache CapsOf(IppClient ipp) =>
            new(async ct => IppPrintCaps.From(await ipp.GetPrinterAttributesAsync(IppPrintCaps.Requested, ct).ConfigureAwait(false)));
    }
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

    /// <summary>What the printer can do (two-sided, papers…), from the target's cache: asked once a while, not for every check.</summary>
    public static Task<IppPrintCaps> ReadCapsAsync(PrintTarget.Direct target, CancellationToken ct = default) => target.Caps.GetAsync(ct);

    /// <summary>
    /// Draws, sends and follows one job. <paramref name="onSending"/> marks the point of no return (the document starts going
    /// out); <paramref name="onSent"/> the printer has it, after which <paramref name="ct"/> cancels it at the printer (Cancel-Job),
    /// unless <paramref name="finishOnceSent"/> (a batch): then the job is followed to its end whatever <paramref name="ct"/> says.
    /// Returns true when the printer said the job was printed, false when it has it but didn't say yet.
    /// </summary>
    /// <exception cref="DirectPrintException">The printer can't take the request, refused it, or stopped it, or didn't take a
    /// cancel (<see cref="DirectPrintException.MayHavePrinted"/> says whether it may have the job).</exception>
    /// <exception cref="OperationCanceledException">Cancelled before sending, or cancelled at the printer after (it took the cancel).</exception>
    public static async Task<bool> PrintAsync(PrintTarget.Direct target, string jobName, DirectPrintRequest request,
        Func<Size, PrintImages, DocumentPaginator> paginator, IProgress<string>? progress, CancellationToken ct,
        Action? onSending = null, Action? onSent = null, bool finishOnceSent = false)
    {
        IppPrintCaps caps;
        try { caps = await ReadCapsAsync(target, ct); }
        catch (Exception ex) when (DirectJob.NoAnswer(ex))
        {
            throw DirectPrintException.NoAnswerBeforeSending(ex); // only the printer's silence: a disk or drawing error below is its own
        }
        if (OnlyFormat is { } only)
        {
            request = request with { Format = only };
            // ippeveprinter lists application/PCLm but drops every pclm-* attribute it's given: the check says 600 dpi for it.
            if (only == RasterFormat.Pclm && caps.PclmDpis.Count == 0)
                caps = caps with { PclmDpis = [600], Formats = [.. caps.Formats, RasterFormat.Pclm] };
        }
        if (DirectPrintPlan.Choose(caps, request, out var problem) is not { } plan)
        {
            target.Caps.Forget(); // the printer may have changed (a tray, a setting): read it again next time
            throw new DirectPrintException(problem!, mayHavePrinted: false);
        }
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
        (int JobId, DirectJobState? State) sent;
        try { sent = await DirectJob.SendAsync(target.Ipp, target.User, jobName, plan, document, CancellationToken.None); }
        catch (DirectPrintException)
        {
            target.Caps.Forget();
            throw;
        }
        var (jobId, state) = sent;
        Log.Write($"Direct print: {plan.DocumentFormat} {plan.Dpi} dpi {plan.Color} {plan.Paper.Name}, {pages} page(s) × {plan.Copies * plan.Repeat}, {document.Length:N0} bytes, job {jobId}");
        target.Sent?.Invoke(jobName, pages);
        onSent?.Invoke();
        if (jobId == 0) return state is { State: DirectJobState.Completed };

        var impressions = plan.PagesPerCopy(pages) * plan.Repeat * plan.Copies;
        var watched = new Progress<DirectJobState>(s => progress?.Report(DirectJob.Describe(s, impressions)));
        if (state is not null) progress?.Report(DirectJob.Describe(state, impressions));
        var watching = finishOnceSent ? CancellationToken.None : ct;
        var last = await DirectJob.WatchAsync(target.Ipp, target.User, jobId, watched, WatchEvery, WatchQuiet, watching) ?? state;
        if (watching.IsCancellationRequested) await DirectJob.StopAsync(target.Ipp, target.User, jobId, ct); // says whether the printer took it
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
        return RasterPage.FromBgra(w, h, w * 4, pixels, plan.Color, plan.Grey).Enlarged(k).Fitted(job.WidthPixels, job.HeightPixels);
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
        var pages = await RenderAsync(pdf, options.Pages, progress, ct);
        return await PrintPagesAsync(target, pages, options.Copies, options.TwoSided, options.JobName, options.Sizing, progress, ct, onSpooling, onSent);
    }

    /// <summary>The PDF's pages drawn for printing, at <see cref="QueuePrinter.RenderDpi"/>.</summary>
    public static async Task<List<RenderedPage>> RenderAsync(PdfSource pdf, IReadOnlyList<int> numbers, IProgress<string> progress, CancellationToken ct,
        int dpi = QueuePrinter.RenderDpi)
    {
        var pages = new List<RenderedPage>(numbers.Count);
        for (var i = 0; i < numbers.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            progress.Report(string.Format(Strings.Print_PreparingPage, i + 1, numbers.Count));
            pages.Add(await pdf.RenderAsync(numbers[i], dpi, ct: ct));
        }
        return pages;
    }

    /// <summary>
    /// Print a PDF on both sides by hand (roadmap 4.2): its pages drawn once, then the fronts, the reload prompt and the backs
    /// (<see cref="HandDuplexPrinting"/>), each copy starting on a sheet of its own.
    /// </summary>
    public static async Task<HandDuplexOutcome> PrintPdfByHandAsync(PrintTarget target, PdfSource pdf, PrintOptions options, HandDuplexPrinter printer,
        IProgress<string> progress, CancellationToken ct, Action? onSpooling = null, Action? onSent = null)
    {
        var pages = await RenderAsync(pdf, options.Pages, progress, ct);
        var plan = HandDuplexPlan.For([.. Enumerable.Range(0, pages.Count)], options.Copies, i => options.Pages[i]);
        return await HandDuplexPrinting.PrintAsync(target, pages, CopyLayout.Sides(pages.Count, 1), 1, plan, options.JobName, options.Sizing, printer,
            progress, ct, onSpooling, onSent);
    }

    /// <summary>A page copy on both sides by hand: its sides laid out as <see cref="PrintCopyAsync"/>'s, collated or not, in the plan's two passes.</summary>
    public static Task<HandDuplexOutcome> PrintCopyByHandAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, int copies, bool collate, int pagesPerSheet,
        string jobName, PageSizing sizing, HandDuplexPrinter printer, IProgress<string>? progress = null, CancellationToken ct = default)
    {
        var sides = CopyLayout.Sides(pages.Count, pagesPerSheet);
        var (order, repeat) = CopyLayout.Order(sides.Count, copies, collate, twoSided: true);
        return HandDuplexPrinting.PrintAsync(target, pages, sides, pagesPerSheet, HandDuplexPlan.For(order, repeat, side => side * pagesPerSheet + 1),
            jobName, sizing, printer, progress, ct);
    }

    /// <summary>
    /// Pages already drawn, each on its own sheet (<see cref="QueuePrinter.PagesPaginator.OnePerSheet"/>): Print a PDF and a scan preset's
    /// print step. Returns true when the printer said it printed the job (straight to the printer only).
    /// </summary>
    public static async Task<bool> PrintPagesAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, int copies, bool twoSided, string jobName,
        PageSizing sizing, IProgress<string>? progress = null, CancellationToken ct = default, Action? onSending = null, Action? onSent = null)
    {
        switch (target)
        {
            case PrintTarget.Queue q:
                onSending?.Invoke();
                await QueuePrinter.PrintPagesAsync(q.Name, pages, copies, twoSided, jobName, sizing);
                onSent?.Invoke();
                return false;
            case PrintTarget.Direct d:
                return await DirectPrinter.PrintAsync(d, jobName, new DirectPrintRequest(copies, twoSided),
                    (paper, images) => QueuePrinter.PagesPaginator.OnePerSheet(pages, paper, sizing, images), progress, ct, onSending, onSent);
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
    }

    /// <summary>
    /// A page copy laid out by the PC (<see cref="QueuePrinter.PrintCopyAsync"/>'s layout): its sides in order, collated here when
    /// asked not to be, else the copies collated by the printer or sent again (<see cref="DirectPrintPlan"/>). Progress and
    /// cancel go through drawing, sending and the printer's job.
    /// </summary>
    public static Task PrintCopyAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, int copies, bool twoSided, bool collate, int pagesPerSheet,
        string jobName, PageSizing sizing, IProgress<string>? progress = null, CancellationToken ct = default)
    {
        if (target is PrintTarget.Queue q) return QueuePrinter.PrintCopyAsync(q.Name, pages, copies, twoSided, collate, pagesPerSheet, jobName, sizing);
        var sides = CopyLayout.Sides(pages.Count, pagesPerSheet);
        var (order, printerCopies) = CopyLayout.Order(sides.Count, copies, collate, twoSided);
        return DirectPrinter.PrintAsync((PrintTarget.Direct)target, jobName, new DirectPrintRequest(printerCopies, twoSided),
            (paper, images) => new QueuePrinter.PagesPaginator(pages, sides, order, pagesPerSheet, paper, sizing, images), progress, ct);
    }

    /// <summary>ID card copy: front and back on one sheet.</summary>
    public static Task PrintIdCardAsync(PrintTarget target, RenderedPage front, RenderedPage back, int copies, string jobName,
        IProgress<string>? progress = null, CancellationToken ct = default) =>
        target switch
        {
            PrintTarget.Queue q => QueuePrinter.PrintIdCardAsync(q.Name, front, back, copies, jobName),
            PrintTarget.Direct d => DirectPrinter.PrintAsync(d, jobName, new DirectPrintRequest(copies),
                (paper, images) => new QueuePrinter.IdCardPaginator(front, back, paper, images), progress, ct),
            _ => throw new ArgumentOutOfRangeException(nameof(target)),
        };
}
