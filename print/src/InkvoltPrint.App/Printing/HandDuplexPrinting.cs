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
    public static async Task<HandDuplexOutcome> PrintAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, IReadOnlyList<int[]> sides, int pagesPerSheet,
        HandDuplexPlan plan, string jobName, PageSizing sizing, HandDuplexPrinter printer, IProgress<string>? progress, CancellationToken ct,
        Action? onSending = null, Action? onSent = null)
    {
        await SidesAsync(target, pages, sides, pagesPerSheet, plan.Fronts, string.Format(Strings.Hand_FrontsJob, jobName), sizing, progress, ct, onSending, onSent);
        if (!plan.HasBacks) return HandDuplexOutcome.OneSide;
        var face = printer.Face();
        if (AskReload?.Invoke(jobName, plan, face) is not { } chosen) return HandDuplexOutcome.FrontsOnly;
        if (chosen != face) printer.Remember(chosen);
        ct.ThrowIfCancellationRequested();
        progress?.Report(Strings.Hand_PrintingBacks);
        await SidesAsync(target, pages, sides, pagesPerSheet, plan.Backs(chosen), string.Format(Strings.Hand_BacksJob, jobName), sizing, progress, ct, onSending, onSent);
        return HandDuplexOutcome.Both;
    }

    /// <summary>One pass: these sides (−1: blank), one copy, one-sided, through the queue or straight to the printer.</summary>
    private static async Task SidesAsync(PrintTarget target, IReadOnlyList<RenderedPage> pages, IReadOnlyList<int[]> sides, int pagesPerSheet, IReadOnlyList<int> order,
        string jobName, PageSizing sizing, IProgress<string>? progress, CancellationToken ct, Action? onSending, Action? onSent)
    {
        switch (target)
        {
            case PrintTarget.Queue q:
                ct.ThrowIfCancellationRequested();
                onSending?.Invoke();
                progress?.Report(Core.Plural.Of(order.Count, Strings.Print_SendingPages_One, Strings.Print_SendingPages_Many));
                await QueuePrinter.PrintSidesAsync(q.Name, pages, sides, order, pagesPerSheet, jobName, sizing);
                onSent?.Invoke();
                break;
            case PrintTarget.Direct d:
                await DirectPrinter.PrintAsync(d, jobName, new DirectPrintRequest(1, TwoSided: false),
                    (paper, images) => new QueuePrinter.PagesPaginator(pages, sides, order, pagesPerSheet, paper, sizing, images), progress, ct, onSending, onSent);
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
    }
}
