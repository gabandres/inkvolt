using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// One decision of where a printer's jobs go (<see cref="PrintRoutes.Choose"/>), with what it was made from: the Windows queue
/// found (null: none) and the printer's IPP client when it takes a raster format (null: it doesn't, or isn't connected).
/// </summary>
public sealed record RouteChoice(PrintRoute Route, string? Queue, IppClient? Ipp)
{
    public static readonly RouteChoice None = new(PrintRoute.None, null, null);
}

/// <summary>
/// The one place a printer's route is decided and remembered (roadmap 2.1). Every print (Print a PDF, Copy, Photos, Batch print, a
/// scan preset's print step) decides afresh with <see cref="ChooseAsync"/>, looking the Windows queue up again; job alerts, asked
/// every minute, follow the last decision (<see cref="ForWatchingAsync"/>), deciding once when none was made yet, so they watch
/// where the jobs went. The app also decides when what it's made from changes (a connection, a queue set up or removed, the
/// person's choice), so the last decision stays current. Callbacks run where the caller's context resumes (no
/// <c>ConfigureAwait(false)</c>): the app's read its view state.
/// </summary>
public sealed class PrintRouter(Func<Task<string?>> findQueue, Func<IppClient?> rasterIpp, Func<bool> personChoseDirect)
{
    private volatile RouteChoice? _last;

    /// <summary>The last decision; null before the first.</summary>
    public RouteChoice? Last => _last;

    /// <summary>Decides now: the Windows queue is looked up, the connection and the person's choice read.</summary>
    public async Task<RouteChoice> ChooseAsync()
    {
        var queue = await findQueue();
        var ipp = rasterIpp();
        var choice = new RouteChoice(PrintRoutes.Choose(queue is not null, ipp is not null, personChoseDirect()), queue, ipp);
        _last = choice;
        return choice;
    }

    /// <summary>
    /// The last decision, without looking the queue up again; decided now if there was none. Straight to the printer, the
    /// connection's current client when there is one (a reconnect makes a new one).
    /// </summary>
    public async Task<RouteChoice> ForWatchingAsync()
    {
        var last = _last ?? await ChooseAsync();
        return last.Route == PrintRoute.Direct && rasterIpp() is { } now && !ReferenceEquals(now, last.Ipp) ? last with { Ipp = now } : last;
    }
}

/// <summary>
/// A printer's batch jobs where its other prints go: its Windows queue, or straight to the printer (<see cref="DirectBatchQueue"/>,
/// made by <paramref name="direct"/> for the client chosen) as <paramref name="router"/> decides for each call. What the batch
/// asks between calls (<see cref="NoAnswer"/>, the limits) follows the queue chosen last: the runner asks whether the printer is
/// ready (<see cref="ProblemAsync"/>) just before each file.
/// </summary>
public sealed class RoutedBatchQueue(IBatchQueue queue, PrintRouter router, Func<IppClient, IBatchQueue> direct) : IBatchQueue
{
    private volatile IBatchQueue? _chosen;

    private IBatchQueue Chosen => _chosen ?? queue;

    private async Task<IBatchQueue> RouteAsync()
    {
        var choice = await router.ChooseAsync();
        return _chosen = choice is { Route: PrintRoute.Direct, Ipp: { } ipp } ? direct(ipp) : queue;
    }

    public async Task<BatchQueueInfo?> ReadAsync(CancellationToken ct) => await (await RouteAsync()).ReadAsync(ct);

    public async Task<string?> ProblemAsync(CancellationToken ct) => await (await RouteAsync()).ProblemAsync(ct);

    public async Task<BatchReceipt> SendAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, Action? onSpooling, CancellationToken ct) =>
        await (await RouteAsync()).SendAsync(document, job, progress, onSpooling, ct);

    public string NoAnswer => Chosen.NoAnswer;

    public TimeSpan SendLimit(BatchPrintJob job, BatchPrintOptions options) => Chosen.SendLimit(job, options);

    public bool EndsOnItsOwnOnceSpooling => Chosen.EndsOnItsOwnOnceSpooling;
}

/// <summary>
/// Job alerts for a printer that may print without its Windows queue: while its jobs go straight (the last route chosen,
/// <see cref="PrintRouter.ForWatchingAsync"/>), the printer's own job list (<see cref="DirectJobWatch"/>); else the Windows queue's
/// (<paramref name="queue"/>). Never both: a printer with a queue on the IPP class driver lists the spooler's jobs too, under its
/// own ids, and each would be told twice.
/// </summary>
public sealed class RoutedJobQueue(Func<Task<JobQueueState?>> queue, PrintRouter router, string user, DirectJobWatch? watch = null)
{
    private readonly DirectJobWatch _watch = watch ?? new DirectJobWatch();

    /// <summary>The queue now, or null when the printer has none. Throws when it couldn't be read.</summary>
    public async Task<JobQueueState?> ReadAsync() =>
        await router.ForWatchingAsync() is { Route: PrintRoute.Direct, Ipp: { } ipp } ? await _watch.ReadAsync(ipp, user) : await queue();
}
