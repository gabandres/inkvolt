using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>How far two-sided by hand got.</summary>
public enum HandDuplexOutcome
{
    /// <summary>Both sides printed.</summary>
    Both,

    /// <summary>One sheet, nothing on its back: printed once.</summary>
    OneSide,

    /// <summary>The fronts printed; the person stopped at the reload prompt.</summary>
    FrontsOnly,
}

/// <summary>Which way up this printer's sheets land, and keeping the person's answer for it.</summary>
/// <param name="Face">What's known now: the person's last answer for this printer, else what the printer says, else face down.</param>
/// <param name="Remember">Keeps the person's answer for this printer.</param>
public sealed record HandDuplexPrinter(Func<OutputFace> Face, Action<OutputFace> Remember);

/// <summary>
/// Two-sided printing by hand (roadmap 4.2), the Windows half: the fronts as one job, the reload prompt (<see cref="AskReload"/>),
/// then the backs as another, in the order <see cref="HandDuplexPlan"/> gives for the way the stack went back. Each pass goes where
/// the printer's other prints go: its Windows queue (one-sided, as the driver can't do both) or straight to the printer, which is
/// followed until it says the fronts are done before the prompt shows. A blank side is drawn blank
/// (<see cref="QueuePrinter.PagesPaginator"/>).
/// </summary>
public static class HandDuplexPrinting
{
    /// <summary>
    /// Set by the app: the prompt between the passes (Views.HandDuplexDialog). Args: the job's name, the plan, the face to show
    /// first. Returns the face the person confirmed, or null when they stopped (no backs). Called on the UI thread.
    /// </summary>
    public static Func<string, HandDuplexPlan, OutputFace, OutputFace?>? AskReload { get; set; }

    /// <summary>
    /// Developer aid (<c>--hand-duplex</c>): every printer is taken as one that can't print both sides, so two-sided by hand can be
    /// tried with paper on a printer that has a duplexer.
    /// </summary>
    public static bool Forced { get; set; }

    /// <summary>
    /// The fronts, the prompt, the backs. <paramref name="pages"/> drawn, <paramref name="sides"/> the pages on each side
    /// (<see cref="CopyLayout.Sides"/>), the plan's numbers being sides. <paramref name="onSending"/> and <paramref name="onSent"/>
    /// mark each pass's point of no return and its end.
    /// </summary>
    public static Task<HandDuplexOutcome> PrintAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, IReadOnlyList<int[]> sides, int pagesPerSheet,
        HandDuplexPlan plan, string jobName, PageSizing sizing, HandDuplexPrinter printer, IProgress<string>? progress, CancellationToken ct,
        Action? onSending = null, Action? onSent = null) =>
        PrintAsync(target, plan, order => (paper, images) => new QueuePrinter.PagesPaginator(pages, sides, order, pagesPerSheet, paper, sizing, images),
            jobName, printer, progress, ct, onSending, onSent);

    /// <summary>
    /// The fronts, the prompt, the backs, each pass drawn by <paramref name="pass"/> from the sides it prints (−1: blank), the plan's
    /// numbers being those sides (Print a PDF's layouts, <see cref="SheetPrinting"/>).
    /// </summary>
    public static async Task<HandDuplexOutcome> PrintAsync(PrintTarget target, HandDuplexPlan plan,
        Func<IReadOnlyList<int>, Func<System.Windows.Size, PrintImages, System.Windows.Documents.DocumentPaginator>> pass,
        string jobName, HandDuplexPrinter printer, IProgress<string>? progress, CancellationToken ct, Action? onSending = null, Action? onSent = null)
    {
        await PassAsync(target, pass(plan.Fronts), plan.Fronts.Count, string.Format(Strings.Hand_FrontsJob, jobName), progress, ct, onSending, onSent);
        if (!plan.HasBacks) return HandDuplexOutcome.OneSide;
        ct.ThrowIfCancellationRequested();
        if (Ask(jobName, plan, printer) is not { } chosen) return HandDuplexOutcome.FrontsOnly;
        ct.ThrowIfCancellationRequested();
        progress?.Report(Strings.Hand_PrintingBacks);
        var backs = plan.Backs(chosen);
        await PassAsync(target, pass(backs), backs.Count, string.Format(Strings.Hand_BacksJob, jobName), progress, ct, onSending, onSent);
        return HandDuplexOutcome.Both;
    }

    /// <summary>
    /// The reload prompt (<see cref="AskReload"/>) with this printer's face chosen first; a different answer is kept for the printer.
    /// The face confirmed, or null when the person stopped. On the UI thread (Print a PDF, Copy, and Batch through the dispatcher).
    /// </summary>
    public static OutputFace? Ask(string jobName, HandDuplexPlan plan, HandDuplexPrinter printer)
    {
        var face = printer.Face();
        if (AskReload?.Invoke(jobName, plan, face) is not { } chosen) return null;
        if (chosen != face) printer.Remember(chosen);
        return chosen;
    }

    /// <summary>One pass: <paramref name="count"/> sides drawn by <paramref name="paginator"/>, one copy, one-sided, through the queue or straight to the printer.</summary>
    private static async Task PassAsync(PrintTarget target, Func<System.Windows.Size, PrintImages, System.Windows.Documents.DocumentPaginator> paginator, int count,
        string jobName, IProgress<string>? progress, CancellationToken ct, Action? onSending, Action? onSent)
    {
        switch (target)
        {
            case PrintTarget.Queue q:
                ct.ThrowIfCancellationRequested();
                onSending?.Invoke();
                progress?.Report(Core.Plural.Of(count, Strings.Print_SendingPages_One, Strings.Print_SendingPages_Many));
                await QueuePrinter.PrintPassAsync(q.Name, twoSided: false, jobName, paginator);
                onSent?.Invoke();
                break;
            case PrintTarget.Direct d:
                await DirectPrinter.PrintAsync(d, jobName, new DirectPrintRequest(1, TwoSided: false), paginator, progress, ct, onSending, onSent);
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
    }
}
