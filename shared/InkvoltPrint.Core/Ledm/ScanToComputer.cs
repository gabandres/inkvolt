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

    /// <summary>The printer refused, or its list doesn't show this PC after adding it.</summary>
    Refused,

    /// <summary>The printer doesn't answer: added again when it does.</summary>
    NotReached,
}

/// <summary>
/// This PC on an HP printer's panel under Scan to Computer (<see cref="LedmWalkupScan"/>), over one connection: found by reading
/// only (the tree, the manifest, the list), then added with one POST when the person turns it on, kept there while
/// <see cref="RunAsync"/> runs (added again after the printer restarts or drops it: its <c>PowerUpEvent</c>, a lost connection),
/// and removed with one DELETE (<see cref="RemoveAsync"/>). A press of this PC on the panel comes as a scan event in the
/// printer's EventTable (the same long poll the status uses: no port is opened on this PC) and is told once.
/// Writes go over HTTPS (<see cref="LedmClient"/>); the POST is never resent (a second would list the PC twice).
/// </summary>
public sealed class ScanToComputer
{
    private readonly LedmClient _ledm;
    private readonly string _listPath, _eventPath;
    private readonly Lock _gate = new();
    private string? _path;
    private bool _maybeSent;

    private ScanToComputer(LedmClient ledm, string listPath, string eventPath, string? path)
    {
        _ledm = ledm;
        _listPath = listPath;
        _eventPath = eventPath;
        _path = path;
    }

    /// <summary>The printer's list of computers (for the Scan tab and tests).</summary>
    public string ListPath => _listPath;

    /// <summary>This PC's destination on the printer, as this app added it; null while it isn't (or isn't known to be).</summary>
    public string? Path
    {
        get { lock (_gate) return _path; }
    }

    /// <summary>The printer's panel offers Scan to Computer in the names this code knows (GETs only); null otherwise, also when a document can't be read.</summary>
    /// <param name="remembered">The destination this app added on an earlier run (kept by the app), adopted while the printer still lists it.</param>
    public static async Task<ScanToComputer?> DetectAsync(PrinterConnection connection, string? remembered, CancellationToken ct = default) =>
        connection.Ledm is { } ledm ? await DetectAsync(ledm, remembered, ct).ConfigureAwait(false) : null;

    public static async Task<ScanToComputer?> DetectAsync(LedmClient ledm, string? remembered, CancellationToken ct = default)
    {
        try
        {
            if (await ledm.GetTreeAsync(ct).ConfigureAwait(false) is not { HasEvents: true } tree || LedmWalkupScan.ManifestPath(tree) is not { } manifestPath
                || await ledm.GetPathAsync(manifestPath, ct).ConfigureAwait(false) is not { } manifest || LedmWalkupScan.Paths(manifest) is not var (list, ev)
                || await ledm.GetPathAsync(list, ct).ConfigureAwait(false) is not { } doc || LedmWalkupScan.Read(doc) is null)
                return null;
            return new ScanToComputer(ledm, list, ev, remembered is not null && LedmWalkupScan.OwnPath(remembered, list) is { } own ? own : null);
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return null;
        }
    }

    /// <summary>
    /// Makes sure this PC is on the list: kept when the destination this app added is still listed, not added when a computer by
    /// its name is there already, else added with one POST. Never throws for the printer's answers (they're the state).
    /// </summary>
    public async Task<PanelState> EnsureListedAsync(string panelName, CancellationToken ct = default)
    {
        IReadOnlyList<WalkupDestination>? listed;
        XDocument? list;
        try
        {
            list = await _ledm.GetPathAsync(_listPath, ct).ConfigureAwait(false);
            listed = list is null ? null : LedmWalkupScan.Read(list);
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return PrinterConnection.IsOffline(ex) ? PanelState.NotReached : PanelState.Refused;
        }
        if (list is null || listed is null) return PanelState.Refused; // the list went, or changed shape: nothing written on a guess

        lock (_gate)
        {
            if (_path is { } own && listed.Any(d => Same(d.Path, own))) return PanelState.Listed;
            var mine = listed.FirstOrDefault(d => d.Path is not null && (Same(d.Name, panelName) || Same(d.Hostname, panelName)));
            if (mine is not null)
            {
                if (!_maybeSent) return PanelState.ListedByOther;
                // An earlier POST went without an answer, and the printer did add it: it's this app's.
                _path = mine.Path;
                _maybeSent = false;
                return PanelState.Listed;
            }
            _path = null;
        }

        string? location;
        try
        {
            location = await _ledm.PostPathAsync(_listPath, LedmWalkupScan.Build(list, panelName), ct).ConfigureAwait(false);
        }
        catch (LedmAuthRequiredException)
        {
            return PanelState.NeedsPassword;
        }
        catch (DeviceHttpException)
        {
            return PanelState.Refused;
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException)
        {
            lock (_gate) _maybeSent = Maintenance.MaintenanceClient.NeverSent(ex) is null; // sent, then no answer: it may be listed
            return PanelState.NotReached;
        }

        var path = LedmWalkupScan.OwnPath(location, _listPath);
        if (path is null)
        {
            // No usable Location: the list says where it went.
            try
            {
                var again = await _ledm.GetPathAsync(_listPath, ct).ConfigureAwait(false) is { } d ? LedmWalkupScan.Read(d) : null;
                path = again?.LastOrDefault(x => x.Path is not null && Same(x.Name, panelName))?.Path;
            }
            catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
            {
                lock (_gate) _maybeSent = true;
                return PanelState.NotReached;
            }
        }
        lock (_gate)
        {
            _path = path;
            _maybeSent = path is null;
        }
        return path is null ? PanelState.Refused : PanelState.Listed;
    }

    /// <summary>
    /// Takes this PC off the list (one DELETE of the destination this app added; nothing else on the printer is touched). True when
    /// it's gone or there was nothing to remove; false when the printer couldn't be reached or refused.
    /// </summary>
    public async Task<bool> RemoveAsync(CancellationToken ct = default)
    {
        string? path;
        lock (_gate) path = _path;
        if (path is null) return true;
        try
        {
            await _ledm.DeletePathAsync(path, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is LedmAuthRequiredException or OperationCanceledException || PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return false; // no answer in time (closing), or refused: it stays on the list, and the next run finds it again
        }
        lock (_gate)
            if (_path == path) _path = null;
        return true;
    }

    /// <summary>How often a quiet printer's list is looked at again, at most, when its EventTable changes.</summary>
    public static readonly TimeSpan Recheck = TimeSpan.FromMinutes(10);

    /// <summary>Stamps remembered to tell a new event from one already handled.</summary>
    private const int MaxSeen = 256;

    /// <summary>
    /// Keeps this PC on the list and tells each press of it, until <paramref name="ct"/> is cancelled (it isn't removed then:
    /// <see cref="RemoveAsync"/> does that). Events already in the first table read are old: only later ones count, each once (by
    /// its category and <c>AgingStamp</c>). A press is told only when the event names this PC's destination and the event document
    /// says scan (<see cref="LedmWalkupScan.IsStart"/>).
    /// </summary>
    /// <param name="state">Each check's outcome (from the thread pool).</param>
    /// <param name="pressed">A press of this PC on the panel (from the thread pool).</param>
    public async Task RunAsync(string panelName, Action<PanelState> state, Action pressed, CancellationToken ct)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var first = true;
        var check = true;
        var refused = false; // refused, or a password wanted: not POSTed again until turned off and on (a new run)
        var checkedAt = DateTime.MinValue;
        try
        {
            await foreach (var events in _ledm.WatchEventsAsync(ct).ConfigureAwait(false))
            {
                // An empty table also comes once when the printer stops answering: look at the list again.
                if (events.Count == 0) check = true;
                var fresh = new List<LedmEvent>();
                foreach (var e in events)
                {
                    if (e.AgingStamp is not { } stamp) continue;
                    if (seen.Count >= MaxSeen) seen.Clear();
                    if (seen.Add(e.Category + "\n" + stamp) && !first) fresh.Add(e);
                }
                if (fresh.Any(e => e.Category == LedmWalkupScan.PowerUpCategory)) check = true; // a restarted printer forgets its list
                if (!refused && (check || first || DateTime.UtcNow - checkedAt > Recheck))
                {
                    var now = await EnsureListedAsync(panelName, ct).ConfigureAwait(false);
                    state(now);
                    checkedAt = DateTime.UtcNow;
                    check = now is PanelState.NotReached;
                    refused = now is PanelState.Refused or PanelState.NeedsPassword;
                }
                first = false;
                if (Path is not { } own) continue;
                foreach (var e in fresh.Where(e => LedmWalkupScan.IsPressFor(e, own)))
                {
                    if (await ReadEventAsync(ct).ConfigureAwait(false) is { } type && LedmWalkupScan.IsStart(type)) pressed();
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    }

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
