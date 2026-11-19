using System.Net;
using System.Xml.Linq;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Core.Ledm;

/// <summary>Where this PC stands on the printer's Scan to Computer list.</summary>
public enum PanelState
{
    /// <summary>Being added (or checked).</summary>
    Adding,

    /// <summary>On the list, as this app added it: a press reaches this PC.</summary>
    Listed,

    /// <summary>A computer by this PC's name is on the list already, not added by this app (HP's software, say): not added twice.</summary>
    ListedByOther,

    /// <summary>The printer wants its admin password to add a computer.</summary>
    NeedsPassword,

    /// <summary>The printer refused, its list changed shape, or its list doesn't show this PC after adding it.</summary>
    Refused,

    /// <summary>The printer doesn't answer, or answered with an error: tried again a little later.</summary>
    NotReached,

    /// <summary>Something went wrong here (not the printer's answer): stopped until turned off and on.</summary>
    Failed,
}

/// <summary>Who this PC is on a printer's list: the name the panel shows, and the host name that marks the destination as this app's.</summary>
public sealed record PanelOwner(string Name, string Marker);

/// <summary>
/// What looking for the panel found: <paramref name="Panel"/> when the printer offers it; null with <paramref name="Read"/> true
/// when it doesn't; <paramref name="Read"/> false when the printer couldn't be read (no answer, an error, an unreadable reply), to
/// be tried again.
/// </summary>
public sealed record PanelFound(ScanToComputer? Panel, bool Read);

/// <summary>
/// This PC on an HP printer's panel under Scan to Computer (<see cref="LedmWalkupScan"/>), over one connection: found by reading
/// only (the tree, the manifest, the list), then added with one POST when the person turns it on, kept there while
/// <see cref="RunAsync"/> runs (added again after the printer restarts or drops it: its <c>PowerUpEvent</c>, a lost connection),
/// and removed with one DELETE (<see cref="RemoveAsync"/>). This app's destination is known by its host name
/// (<see cref="PanelOwner.Marker"/>), not by the answer to the POST, so one whose answer was lost is still found and removed. A
/// press of this PC on the panel comes as a scan event in the printer's EventTable, read through the connection's one shared
/// long poll (<see cref="LedmClient.Events"/>: no second poll, no port opened on this PC), and is told once. Writes go over HTTPS
/// (<see cref="LedmClient"/>); the POST is never resent by the connection (a second would list the PC twice).
/// </summary>
public sealed class ScanToComputer
{
    private readonly LedmClient _ledm;
    private readonly string _listPath, _eventPath;
    private readonly Lock _gate = new();
    private string? _path;

    private ScanToComputer(LedmClient ledm, string listPath, string eventPath)
    {
        _ledm = ledm;
        _listPath = listPath;
        _eventPath = eventPath;
    }

    /// <summary>The printer's list of computers.</summary>
    public string ListPath => _listPath;

    /// <summary>This PC's destination on the printer, as this app added it; null while it isn't (or isn't known to be).</summary>
    public string? Path
    {
        get { lock (_gate) return _path; }
    }

    /// <summary>Whether the printer's panel offers Scan to Computer in the names this code knows (GETs only), or couldn't be read.</summary>
    public static async Task<PanelFound> DetectAsync(PrinterConnection connection, CancellationToken ct = default) =>
        connection.Ledm is { } ledm ? await DetectAsync(ledm, ct).ConfigureAwait(false) : new PanelFound(null, Read: true);

    public static async Task<PanelFound> DetectAsync(LedmClient ledm, CancellationToken ct = default)
    {
        try
        {
            if (await ledm.GetTreeAsync(ct).ConfigureAwait(false) is not { HasEvents: true } tree || LedmWalkupScan.ManifestPath(tree) is not { } manifestPath
                || await ledm.GetPathAsync(manifestPath, ct).ConfigureAwait(false) is not { } manifest || LedmWalkupScan.Paths(manifest) is not var (list, ev)
                || await ledm.GetPathAsync(list, ct).ConfigureAwait(false) is not { } doc || LedmWalkupScan.Read(doc) is null)
                return new PanelFound(null, Read: true);
            return new PanelFound(new ScanToComputer(ledm, list, ev), Read: true);
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return new PanelFound(null, Read: false);
        }
    }

    /// <summary>
    /// Makes sure this PC is on the list: this app's destination (its <see cref="PanelOwner.Marker"/>) is kept wherever it is; a
    /// computer by this PC's name without the marker is another program's and nothing is added; else one POST adds it. Never
    /// throws for the printer's answers (they're the state): no answer or an error answer is <see cref="PanelState.NotReached"/>,
    /// to try again later.
    /// </summary>
    public async Task<PanelState> EnsureListedAsync(PanelOwner owner, CancellationToken ct = default)
    {
        var (list, listed, problem) = await ReadListAsync(ct).ConfigureAwait(false);
        if (problem is { } p) return p;

        if (Mine(listed!, owner) is { } mine)
        {
            lock (_gate) _path = mine;
            return PanelState.Listed;
        }
        lock (_gate) _path = null;
        if (listed!.Any(d => Same(d.Name, owner.Name) || Same(d.Hostname, owner.Name))) return PanelState.ListedByOther;

        string? location;
        try
        {
            location = await _ledm.PostPathAsync(_listPath, LedmWalkupScan.Build(list!, owner.Name, owner.Marker), ct).ConfigureAwait(false);
        }
        catch (LedmAuthRequiredException)
        {
            return PanelState.NeedsPassword;
        }
        catch (DeviceHttpException ex) when (Busy(ex.Status))
        {
            return PanelState.NotReached; // try again later: if it was added anyway, its marker finds it
        }
        catch (DeviceHttpException)
        {
            return PanelState.Refused;
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException)
        {
            return PanelState.NotReached; // sent, maybe: the next check finds it by its marker
        }

        var path = LedmWalkupScan.OwnPath(location, _listPath);
        if (path is null)
        {
            // No usable Location: the list says where it went.
            var (_, again, trouble) = await ReadListAsync(ct).ConfigureAwait(false);
            if (trouble is not null) return PanelState.NotReached;
            path = Mine(again!, owner);
        }
        lock (_gate) _path = path;
        return path is null ? PanelState.Refused : PanelState.Listed;
    }

    /// <summary>
    /// Takes this PC off the list: one DELETE of this app's destination (found by its marker when the path isn't known), nothing
    /// else on the printer touched. True when it's gone or there was none; false when the printer didn't answer in time or refused.
    /// </summary>
    public async Task<bool> RemoveAsync(PanelOwner owner, CancellationToken ct = default)
    {
        try
        {
            string? path;
            lock (_gate) path = _path;
            if (path is null)
            {
                var (_, listed, problem) = await ReadListAsync(ct).ConfigureAwait(false);
                if (problem is not null) return problem == PanelState.Refused; // no list of that shape: nothing of ours to remove
                if ((path = Mine(listed!, owner)) is null) return true;
            }
            await _ledm.DeletePathAsync(path, ct).ConfigureAwait(false);
            lock (_gate)
                if (_path == path) _path = null;
            return true;
        }
        catch (Exception ex) when (ex is LedmAuthRequiredException or OperationCanceledException || PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return false; // it stays on the list, and the next run finds it again by its marker
        }
    }

    /// <summary>How often a quiet printer's list is looked at again, at most, when its EventTable changes.</summary>
    public static readonly TimeSpan Recheck = TimeSpan.FromMinutes(10);

    /// <summary>How long after a check that got no answer (or an error answer) the next one comes, the EventTable quiet or not.</summary>
    public TimeSpan RetryDelay { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Keeps this PC on the list and tells each press of it, until <paramref name="ct"/> is cancelled (it isn't removed then:
    /// <see cref="RemoveAsync"/> does that). The first table the printer answered with is where it starts (an outage before it
    /// doesn't count): only events after it count, each once (<see cref="SeenEvents"/>). A press is told only when the event names
    /// this PC's destination and the event document says scan (<see cref="LedmWalkupScan.IsStart"/>). A check that got no answer is
    /// tried again after <see cref="RetryDelay"/>; one refused (or wanting a password) waits until turned off and on (a new run);
    /// anything else going wrong ends in <see cref="PanelState.Failed"/>, said, not a run left hanging.
    /// </summary>
    /// <param name="state">Each check's outcome (from the thread pool).</param>
    /// <param name="pressed">A press of this PC on the panel (from the thread pool).</param>
    public async Task RunAsync(PanelOwner owner, Action<PanelState> state, Action pressed, CancellationToken ct)
    {
        var seen = new SeenEvents();
        var started = false;
        var check = true;
        var stopped = false;
        var checkedAt = DateTime.MinValue;
        var tables = _ledm.Events.SubscribeAsync(ct).GetAsyncEnumerator(ct);
        Task<bool>? next = null;
        try
        {
            next = tables.MoveNextAsync().AsTask();
            while (true)
            {
                if (!stopped && (check || DateTime.UtcNow - checkedAt > Recheck))
                {
                    PanelState now;
                    try
                    {
                        now = await EnsureListedAsync(owner, ct).ConfigureAwait(false);
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException and not OutOfMemoryException)
                    {
                        now = PanelState.Failed;
                    }
                    state(now);
                    checkedAt = DateTime.UtcNow;
                    check = now is PanelState.NotReached;
                    stopped = now is PanelState.Refused or PanelState.NeedsPassword or PanelState.Failed;
                }
                if (check && !stopped && await Task.WhenAny(next, Task.Delay(RetryDelay, ct)).ConfigureAwait(false) != next)
                {
                    ct.ThrowIfCancellationRequested();
                    continue; // time to try again, the EventTable quiet
                }
                if (!await next.ConfigureAwait(false)) return; // the printer has no EventTable after all
                var table = tables.Current;
                next = tables.MoveNextAsync().AsTask();
                if (!table.Answered)
                {
                    check = true; // back: look at the list again
                    continue;
                }
                var fresh = seen.Take(table.Events, start: !started);                started = true;
                if (fresh.Any(e => e.Category == LedmWalkupScan.PowerUpCategory)) check = true; // a restarted printer forgets its list
                if (Path is not { } own) continue;
                foreach (var e in fresh.Where(e => LedmWalkupScan.IsPressFor(e, own)))
                {
                    if (await ReadEventAsync(ct).ConfigureAwait(false) is { } type && LedmWalkupScan.IsStart(type)) pressed();
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        finally
        {
            if (next is not null)
            {
                try { await next.ConfigureAwait(false); }
                catch (Exception) { } // cancelled with the run
            }
            await tables.DisposeAsync().ConfigureAwait(false);
        }
    }

    private async Task<(XDocument? List, IReadOnlyList<WalkupDestination>? Listed, PanelState? Problem)> ReadListAsync(CancellationToken ct)
    {
        try
        {
            var list = await _ledm.GetPathAsync(_listPath, ct).ConfigureAwait(false);
            // The list went, or changed shape: nothing written on a guess.
            return list is not null && LedmWalkupScan.Read(list) is { } listed ? (list, listed, null) : (null, null, PanelState.Refused);
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return (null, null, PanelState.NotReached); // no answer, an error answer, an unreadable one: later
        }
    }

    private static string? Mine(IReadOnlyList<WalkupDestination> listed, PanelOwner owner) =>
        listed.LastOrDefault(d => d.Path is not null && Same(d.Hostname, owner.Marker))?.Path;

    /// <summary>A refusal that may pass: busy, overloaded, a server error.</summary>
    private static bool Busy(HttpStatusCode status) =>
        status is HttpStatusCode.RequestTimeout or HttpStatusCode.Conflict or HttpStatusCode.TooManyRequests || (int)status >= 500;

    private async Task<string?> ReadEventAsync(CancellationToken ct)
    {
        try
        {
            return await _ledm.GetPathAsync(_eventPath, ct).ConfigureAwait(false) is { } doc ? LedmWalkupScan.EventType(doc) : null;
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return null;
        }
    }

    private static bool Same(string? a, string? b) => a is not null && b is not null && string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// The EventTable entries already handled, by category and <c>AgingStamp</c>: a rolling window of at most <see cref="Max"/> that
/// never drops an entry the printer's table still holds (those are touched on every table and evicted last), so an old event
/// never comes back as new.
/// </summary>
internal sealed class SeenEvents
{
    public const int Max = 256;

    private readonly Dictionary<string, long> _seen = new(StringComparer.Ordinal);
    private long _clock;

    /// <summary>The table's events not seen before (none when <paramref name="start"/>: they're the starting point); all of them are seen after.</summary>
    public List<LedmEvent> Take(IReadOnlyList<LedmEvent> events, bool start)
    {
        var fresh = new List<LedmEvent>();
        foreach (var e in events)
        {
            if (e.AgingStamp is not { } stamp) continue;
            var key = e.Category + "\n" + stamp;
            if (!_seen.ContainsKey(key) && !start) fresh.Add(e);
            _seen[key] = ++_clock; // the table's own entries are the newest
        }
        if (_seen.Count > Max)
            foreach (var old in _seen.OrderBy(kv => kv.Value).Take(_seen.Count - Max).Select(kv => kv.Key).ToList())
                _seen.Remove(old);
        return fresh;
    }

    public int Count => _seen.Count;
}
