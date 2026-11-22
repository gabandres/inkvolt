namespace InkvoltPdf.Core;

/// <summary>Whether a tab can go to another window (<see cref="DocumentWindows.CanMove"/>).</summary>
public enum TabMoveCheck
{
    /// <summary>It can: the tab leaves its window for the target.</summary>
    Moves,
    /// <summary>The target is the window the tab is already in.</summary>
    SameWindow,
    /// <summary>Printing, exporting or another job holds the document: it stays where its work was started.</summary>
    Busy,
    /// <summary>The tab or the window isn't open (any more).</summary>
    Unknown,
}

/// <summary>Whether a tab can become a window of its own (<see cref="DocumentWindows.CanTearOff"/>).</summary>
public enum TearOffCheck
{
    TearsOff,
    /// <summary>The window's only tab: it already has a window to itself (drag the window by its title bar instead).</summary>
    OnlyTab,
    Busy,
    Unknown,
}

/// <summary>What a tab move did (<see cref="DocumentWindows.Move"/>).</summary>
/// <param name="From">The window the tab left.</param>
/// <param name="FromEmptied">That window has no tab left: a window emptied by a move closes (the tab went on in another).</param>
public readonly record struct TabMoved(int From, bool FromEmptied);

/// <summary>
/// A launch's arguments as far as windows go: <c>--new-window</c> (the jump list's New Window, or File › New Window from
/// another launch) asks for a window of its own; the rest are files to open.
/// </summary>
public sealed record WindowLaunch(bool NewWindow, IReadOnlyList<string> Files)
{
    public const string NewWindowSwitch = "--new-window";

    public static WindowLaunch Parse(IEnumerable<string> args)
    {
        var list = args.ToList();
        var newWindow = list.Any(a => string.Equals(a, NewWindowSwitch, StringComparison.OrdinalIgnoreCase));
        return new WindowLaunch(newWindow, [.. list.Where(a => !string.Equals(a, NewWindowSwitch, StringComparison.OrdinalIgnoreCase))]);
    }
}

/// <summary>
/// Inkvolt PDF's main windows and the tabs each owns (roadmap 4.9, two documents side by side). A document is open in
/// one tab of one window at a time; a file asked for again goes to the tab that has it, in whichever window. Windows are
/// numbered as they open; the one used last (<see cref="Active"/>) takes files from other launches. A tab moves to another
/// window unless its document is busy; a window's only tab doesn't tear off; a window a move emptied closes. Which files
/// are remembered for the next start (<see cref="Remember"/>) is decided here too. The app's windows are adapters: each
/// tells this what it opened, closed, moved and activated.
/// </summary>
public sealed class DocumentWindows
{
    private sealed class Entry(int id)
    {
        public int Id { get; } = id;
        public List<long> Tabs { get; } = [];
    }

    private readonly List<Entry> _windows = []; // in the order they opened
    private readonly List<int> _used = []; // most recently activated first
    private readonly Dictionary<long, string?> _paths = [];
    private int _next = 1;
    private bool _sessionRemembered;

    /// <summary>The open windows, in the order they opened.</summary>
    public IReadOnlyList<int> Windows => [.. _windows.Select(w => w.Id)];

    public int Count => _windows.Count;

    /// <summary>The window used last (activated, or opened when none was activated since): where other launches' files go.</summary>
    public int? Active => _used.Count > 0 ? _used[0] : null;

    /// <summary>A new window, with no tab yet; it counts as the one used last.</summary>
    public int Open()
    {
        var id = _next++;
        _windows.Add(new Entry(id));
        _used.Insert(0, id);
        return id;
    }

    /// <summary>The window closed: it and its tabs are gone.</summary>
    public void Close(int window)
    {
        if (Find(window) is not { } entry) return;
        foreach (var tab in entry.Tabs) _paths.Remove(tab);
        _windows.Remove(entry);
        _used.Remove(window);
    }

    public void Activate(int window)
    {
        if (Find(window) is null) return;
        _used.Remove(window);
        _used.Insert(0, window);
    }

    /// <summary>A tab opened in <paramref name="window"/> (at <paramref name="index"/>, else at the end), showing <paramref name="path"/> (null: never saved).</summary>
    public void Add(int window, long tab, string? path, int? index = null)
    {
        if (Find(window) is not { } entry) throw new ArgumentException($"No window {window}", nameof(window));
        if (_paths.ContainsKey(tab)) throw new ArgumentException($"Tab {tab} is already open", nameof(tab));
        entry.Tabs.Insert(Math.Clamp(index ?? entry.Tabs.Count, 0, entry.Tabs.Count), tab);
        _paths[tab] = path;
    }

    /// <summary>The tab's document now has this file (Save As, a reload).</summary>
    public void SetPath(long tab, string? path)
    {
        if (_paths.ContainsKey(tab)) _paths[tab] = path;
    }

    /// <summary>The tab closed.</summary>
    public void Remove(long tab)
    {
        if (WindowEntryOf(tab) is { } entry) entry.Tabs.Remove(tab);
        _paths.Remove(tab);
    }

    public int? WindowOf(long tab) => WindowEntryOf(tab)?.Id;

    public IReadOnlyList<long> TabsOf(int window) => Find(window) is { } entry ? [.. entry.Tabs] : [];

    /// <summary>
    /// The tab showing <paramref name="path"/>, in any window (null: none). Paths are compared as Windows does, ignoring
    /// case; the caller gives full paths.
    /// </summary>
    public (int Window, long Tab)? FindFile(string path)
    {
        foreach (var w in _windows)
        foreach (var tab in w.Tabs)
            if (_paths[tab] is { } open && string.Equals(open, path, StringComparison.OrdinalIgnoreCase))
                return (w.Id, tab);
        return null;
    }

    private readonly HashSet<string> _opening = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// A window starts reading <paramref name="path"/> (a full path) into a new tab. False when that file is already on its
    /// way in any window (double-clicked twice, or asked for in two windows) or open in a tab: it isn't read again. Each
    /// true is followed by <see cref="EndOpening"/>, whether the tab opened or not.
    /// </summary>
    public bool BeginOpening(string path) => FindFile(path) is null && _opening.Add(path);

    /// <summary>The file asked for in <see cref="BeginOpening"/> opened as a tab (<see cref="Add"/> came first), or didn't.</summary>
    public void EndOpening(string path) => _opening.Remove(path);

    /// <summary>Whether <paramref name="tab"/> can go to <paramref name="target"/>; <paramref name="busy"/>: a job holds its document.</summary>
    public TabMoveCheck CanMove(long tab, int target, bool busy)
    {
        if (WindowEntryOf(tab) is not { } from || Find(target) is null) return TabMoveCheck.Unknown;
        if (from.Id == target) return TabMoveCheck.SameWindow;
        return busy ? TabMoveCheck.Busy : TabMoveCheck.Moves;
    }

    /// <summary>Whether <paramref name="tab"/> can become a window of its own.</summary>
    public TearOffCheck CanTearOff(long tab, bool busy)
    {
        if (WindowEntryOf(tab) is not { } from) return TearOffCheck.Unknown;
        if (from.Tabs.Count < 2) return TearOffCheck.OnlyTab;
        return busy ? TearOffCheck.Busy : TearOffCheck.TearsOff;
    }

    /// <summary>
    /// Moves <paramref name="tab"/> to <paramref name="target"/> at <paramref name="index"/> (clamped; past the end: last),
    /// after <see cref="CanMove"/> said <see cref="TabMoveCheck.Moves"/>; the target becomes the window used last. Moving
    /// within a window reorders its tabs.
    /// </summary>
    public TabMoved Move(long tab, int target, int index)
    {
        if (WindowEntryOf(tab) is not { } from) throw new ArgumentException($"No tab {tab}", nameof(tab));
        if (Find(target) is not { } to) throw new ArgumentException($"No window {target}", nameof(target));
        var at = from.Tabs.IndexOf(tab);
        from.Tabs.RemoveAt(at);
        if (from == to && index > at) index--; // the tab's own place no longer counts
        to.Tabs.Insert(Math.Clamp(index, 0, to.Tabs.Count), tab);
        Activate(target);
        return new TabMoved(from.Id, from != to && from.Tabs.Count == 0);
    }

    /// <summary>Every window is about to close at once (File › Exit, Windows ending the session): see <see cref="Remember"/>.</summary>
    public void CloseAllStarting() => _sessionRemembered = false;

    /// <summary>
    /// The files to reopen next time, as <paramref name="closing"/> closes; null leaves what was remembered. Closing one of
    /// several windows forgets its files (they were closed on purpose); the last window remembers its own. When every
    /// window goes at once (<paramref name="everyWindow"/>: File › Exit, Windows ending the session), the first to close
    /// remembers all windows' files, in window order, and the others leave that alone until <see cref="CloseAllStarting"/>.
    /// </summary>
    public IReadOnlyList<string>? Remember(int closing, bool everyWindow)
    {
        if (everyWindow)
        {
            if (_sessionRemembered) return null;
            _sessionRemembered = true;
            return Files(_windows);
        }
        if (_windows.Any(w => w.Id != closing)) return null;
        return Find(closing) is { } entry ? Files([entry]) : [];
    }

    private IReadOnlyList<string> Files(IEnumerable<Entry> windows) =>
        [.. windows.SelectMany(w => w.Tabs).Select(t => _paths[t]).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase)];

    private Entry? Find(int window) => _windows.FirstOrDefault(w => w.Id == window);

    private Entry? WindowEntryOf(long tab) => _windows.FirstOrDefault(w => w.Tabs.Contains(tab));
}

/// <summary>Where a tab dragged out of its strip lands (<see cref="TabDrag.Drop"/>).</summary>
public enum TabDropKind
{
    /// <summary>Nowhere: the tab stays as it was.</summary>
    None,
    /// <summary>Back on its own strip, at <see cref="TabDrop.Index"/>.</summary>
    Reorder,
    /// <summary>On another window's strip: the tab moves there, at <see cref="TabDrop.Index"/>.</summary>
    MoveToWindow,
    /// <summary>Away from every strip: the tab becomes a window of its own, where it was let go.</summary>
    TearOff,
}

public readonly record struct TabDrop(TabDropKind Kind, int Window = 0, int Index = 0);

/// <summary>A window's tab strip on the screen: its bounds and the middle of each tab, left to right (screen pixels).</summary>
public sealed record TabStripArea(int Window, RectD Bounds, IReadOnlyList<double> TabMiddles);

/// <summary>
/// Dragging a title-bar tab (roadmap 4.9): when a press becomes a drag, and where the tab lands. A strip catches a tab let
/// go within <see cref="Catch"/> above or below it, as Edge's and Explorer's do; strips are given front window first, so
/// the window on top wins where they overlap. Let go anywhere else, a tab tears off into a new window, unless it is its
/// window's only one.
/// </summary>
public static class TabDrag
{
    /// <summary>How far above or below a strip (in DIPs, times the screen's scale) a tab let go still lands on it.</summary>
    public const double Catch = 24;

    /// <summary>A press that moved this far (either way, Windows' drag distances) is a drag.</summary>
    public static bool Started(PointD pressed, PointD now, double minX, double minY) =>
        Math.Abs(now.X - pressed.X) >= minX || Math.Abs(now.Y - pressed.Y) >= minY;

    /// <summary>
    /// Where a tab of <paramref name="source"/> (which has <paramref name="sourceTabs"/> tabs) let go at
    /// <paramref name="at"/> lands; <paramref name="strips"/> front window first, <paramref name="scale"/> the screen's
    /// pixels per DIP.
    /// </summary>
    public static TabDrop Drop(int source, int sourceTabs, PointD at, IReadOnlyList<TabStripArea> strips, double scale = 1)
    {
        var margin = Catch * scale;
        foreach (var strip in strips)
        {
            var b = strip.Bounds;
            var caught = at.X >= b.X && at.X <= b.Right && at.Y >= b.Y - margin && at.Y <= b.Bottom + margin;
            if (!caught) continue;
            var index = Index(strip.TabMiddles, at.X);
            return strip.Window == source ? new TabDrop(TabDropKind.Reorder, source, index) : new TabDrop(TabDropKind.MoveToWindow, strip.Window, index);
        }
        return sourceTabs > 1 ? new TabDrop(TabDropKind.TearOff, source) : new TabDrop(TabDropKind.None, source);
    }

    /// <summary>The place a tab let go at <paramref name="x"/> takes: before the first tab whose middle is right of it.</summary>
    public static int Index(IReadOnlyList<double> middles, double x)
    {
        var i = 0;
        while (i < middles.Count && middles[i] < x) i++;
        return i;
    }
}
