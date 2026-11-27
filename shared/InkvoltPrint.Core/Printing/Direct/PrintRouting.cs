using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>The line the Print tab shows about where its pages go; the words are the app's.</summary>
public enum PrintRouteNote
{
    /// <summary>Through the Windows queue, or nowhere yet: no line.</summary>
    None,

    /// <summary>Straight to the printer: Windows has no queue for it.</summary>
    Direct,

    /// <summary>Straight to the printer as the person chose, though Windows has a queue for it.</summary>
    DirectChosen,

    /// <summary>Straight to the printer: Windows has a queue for it, but the queue's driver isn't working.</summary>
    DirectQueueBroken,
}

/// <summary>
/// A printer's print routing (roadmap 2.1, print/GLOSSARY.md): what the tabs that print (Print a PDF, Batch print, Copy, Print photos, the
/// print queue card) know of where its jobs go, kept in one place. Whether Windows has a queue for it (<see cref="HasQueue"/>),
/// whether it can be set up in Windows (<see cref="CanSetUp"/>, <see cref="NeedsSetup"/>), whether it takes jobs straight and the
/// person may choose that (<see cref="CanChooseDirect"/>, <see cref="ChoseDirect"/>), the route last decided and its note.
/// <see cref="Changed"/> is raised when any of it changes, or when the queue was made again; every tab hears it, none is told by
/// hand. The decision is the router's (<see cref="Router"/>), which every print asks afresh; this keeps the last one the app asked
/// for, when what it's made from changed: discovery's word, a queue lookup, a queue set up, a connection, the person's choice.
/// What's known of the queue is told at once, the decision when it's made (a lookup can take seconds). Continues on the caller's
/// context, like the router: the app's tabs hear it on the dispatcher.
/// </summary>
public sealed class PrintRouting
{
    private readonly Action<bool> _rememberChoice;
    private readonly Action<string>? _log;
    private readonly bool _hasAddress;
    private bool _queueKnown, _discoveredQueue, _foundQueue, _pairs, _takesDirect;

    /// <param name="findQueue">Looks the printer's Windows queue up (null: none).</param>
    /// <param name="rasterIpp">The printer's IPP client when it takes a raster format; null when it doesn't or isn't connected.</param>
    /// <param name="hasAddress">A network printer: it can be set up in Windows by its address.</param>
    /// <param name="choseDirect">The person's choice as remembered for this printer.</param>
    /// <param name="rememberChoice">Keeps a new choice (<see cref="ChooseDirectAsync"/>).</param>
    /// <param name="queueWorks">Whether a queue's driver can be used (<see cref="PrintRouter"/>); null: taken as yes.</param>
    public PrintRouting(Func<Task<string?>> findQueue, Func<IppClient?> rasterIpp, bool hasAddress, bool choseDirect, Action<bool> rememberChoice,
        Action<string>? log = null, Func<string, Task<bool>>? queueWorks = null)
    {
        _hasAddress = hasAddress;
        _rememberChoice = rememberChoice;
        _log = log;
        ChoseDirect = choseDirect;
        Router = new PrintRouter(findQueue, rasterIpp, () => ChoseDirect, queueWorks);
    }

    /// <summary>Decides where each print, batch and job alert goes (<see cref="PrintRouter"/>), with the person's choice kept here.</summary>
    public PrintRouter Router { get; }

    /// <summary>
    /// Something here changed, or the Windows queue was made again: what a tab read of the old route is stale. Each subscriber is
    /// called on its own: one that throws is logged and the rest still hear it.
    /// </summary>
    public event Action? Changed;

    /// <summary>
    /// Windows has a print queue for it: discovery saw one or a lookup found one. Taken as yes until either has said, so a printer
    /// isn't offered setting up before anything was asked.
    /// </summary>
    public bool HasQueue => !_queueKnown || _discoveredQueue || _foundQueue;

    /// <summary>Its jobs have somewhere to go: a Windows queue, or the printer takes them straight (as of the last decision).</summary>
    public bool HasRoute => HasQueue || _takesDirect;

    /// <summary>Discovery can pair it with Windows (it has a print endpoint), or it's a network printer Windows can add by address.</summary>
    public bool CanSetUp => _pairs || _hasAddress;

    /// <summary>No Windows queue yet, and one can be set up: the Overview offers Set up.</summary>
    public bool NeedsSetup => !HasQueue && CanSetUp;

    /// <summary>The printer takes jobs straight and has a Windows queue too: the person may choose which.</summary>
    public bool CanChooseDirect { get; private set; }

    /// <summary>The person chose straight to the printer over its Windows queue (kept per printer).</summary>
    public bool ChoseDirect { get; private set; }

    /// <summary>Where its jobs went at the last decision; <see cref="PrintRoute.None"/> before the first.</summary>
    public PrintRoute Route { get; private set; }

    /// <summary>The Print tab's line for <see cref="Route"/>.</summary>
    public PrintRouteNote Note { get; private set; }

    /// <summary>What it's made from may have changed (a connection): decide again.</summary>
    public Task DecideAsync() => DecideAsync(Current);

    /// <summary>Discovery's word: whether Windows has a queue paired with it, and whether it can pair one.</summary>
    public Task DiscoveredAsync(bool queueInstalled, bool pairs)
    {
        var before = Current;
        _discoveredQueue = queueInstalled;
        _pairs = pairs;
        return QueueSaid(before);
    }

    /// <summary>A lookup of its Windows queue (<c>findQueue</c>, or none for a scanner on its own) found one or didn't.</summary>
    public Task QueueLookedUpAsync(bool found)
    {
        var before = Current;
        _foundQueue = found;
        return QueueSaid(before);
    }

    /// <summary>
    /// Its Windows queue was set up or made again (<paramref name="made"/>), or that failed: always told at once (the queue is new),
    /// then decided again.
    /// </summary>
    public Task QueueSetUpAsync(bool made)
    {
        _queueKnown = true;
        _foundQueue = made;
        Tell();
        return DecideAsync(Current);
    }

    /// <summary>The person chose straight to the printer, or the Windows queue: kept, decided again, told.</summary>
    public Task ChooseDirectAsync(bool direct)
    {
        if (direct == ChoseDirect) return Task.CompletedTask;
        var before = Current;
        ChoseDirect = direct;
        _rememberChoice(direct);
        return DecideAsync(before);
    }

    /// <summary>What's known of the queue is told at once; a change of whether it has one decides again.</summary>
    private Task QueueSaid(Facts before)
    {
        _queueKnown = true;
        var decide = HasQueue != before.HasQueue;
        if (Current != before) Tell();
        return decide ? DecideAsync(Current) : Task.CompletedTask;
    }

    /// <summary>
    /// Decides as a print decides, from one look at the queue and the connection. A decision that fails changes nothing: the route,
    /// its note and whether the printer takes jobs straight stay as the last one left them, and the next print decides again.
    /// </summary>
    private async Task DecideAsync(Facts before)
    {
        RouteChoice choice;
        try
        {
            choice = await Router.ChooseAsync();
        }
        catch (Exception ex)
        {
            _log?.Invoke($"Print route: {ex.Message}");
            if (Current != before) Tell(); // a choice made just before (ChooseDirectAsync) is still news
            return;
        }
        var queue = choice.Queue is not null;
        _takesDirect = choice.Ipp is not null;
        CanChooseDirect = _takesDirect && queue;
        Route = choice.Route;
        Note = choice.Route != PrintRoute.Direct ? PrintRouteNote.None
            : choice.QueueBroken ? PrintRouteNote.DirectQueueBroken
            : queue ? PrintRouteNote.DirectChosen : PrintRouteNote.Direct;
        if (Current != before) Tell();
    }

    private void Tell()
    {
        if (Changed is not { } changed) return;
        foreach (var hear in changed.GetInvocationList().Cast<Action>())
        {
            try
            {
                hear();
            }
            catch (Exception ex)
            {
                _log?.Invoke($"Print route: a tab failed to follow the change: {ex.Message}");
            }
        }
    }

    /// <summary>Everything a tab reads, to tell whether it changed.</summary>
    private readonly record struct Facts(bool HasQueue, bool HasRoute, bool CanSetUp, bool CanChooseDirect, bool ChoseDirect, PrintRoute Route,
        PrintRouteNote Note);

    private Facts Current => new(HasQueue, HasRoute, CanSetUp, CanChooseDirect, ChoseDirect, Route, Note);
}
