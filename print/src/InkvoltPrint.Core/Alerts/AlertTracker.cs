namespace InkvoltPrint.Core.Alerts;

/// <summary>Quiet hours, local clock; may cross midnight (22:00–07:00). From == To is an empty range.</summary>
public sealed record QuietHours(TimeOnly From, TimeOnly To)
{
    public bool Contains(TimeOnly time) => From <= To ? time >= From && time < To : time >= From || time < To;
}

/// <summary>Alert settings and timing.</summary>
public sealed record AlertRules
{
    /// <summary>Show alerts at all (off: the tray icon still shows each printer's state).</summary>
    public bool Enabled { get; init; } = true;

    /// <summary>A supply at or under this percentage is low.</summary>
    public int LowPercent { get; init; } = 15;

    /// <summary>A low supply stays low until it is this many points above <see cref="LowPercent"/>.</summary>
    public int Hysteresis { get; init; } = 5;

    /// <summary>Alert when a printer stops answering.</summary>
    public bool Offline { get; init; } = true;

    public QuietHours? Quiet { get; init; }

    /// <summary>A jam, open cover or empty tray must last this long: someone at the printer is fixing it already.</summary>
    public TimeSpan ErrorHold { get; init; } = TimeSpan.FromMinutes(1);

    /// <summary>A printer must stay unreachable this long (sleep, Wi-Fi hiccups, a restart).</summary>
    public TimeSpan OfflineHold { get; init; } = TimeSpan.FromMinutes(15);

    /// <summary>A problem must be gone this long to count as over; if it comes back sooner it's the same one, no new alert.</summary>
    public TimeSpan ClearHold { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>A longer gap between two checks (the PC slept) starts the holds again.</summary>
    public TimeSpan MaxGap { get; init; } = TimeSpan.FromHours(2);

    public TimeSpan HoldFor(AlertKind kind) =>
        AlertCondition.IsSupply(kind) ? TimeSpan.Zero : kind == AlertKind.Offline ? OfflineHold : ErrorHold;
}

/// <summary>An alert to show now. <see cref="Uuid"/> picks the printer to open when it's clicked.</summary>
public sealed record AlertNotice(string Uuid, string PrinterName, AlertKind Kind, string Title, string Body)
{
    public AlertLevel Level => AlertCondition.LevelOf(Kind);
}

/// <summary>
/// The alert rules as a state machine, one per app: fed each printer's latest <see cref="PrinterSnapshot"/>, it says which
/// alerts to show now. Alerts fire on transitions only: a problem is told once while it lasts, after its hold time
/// (<see cref="AlertRules.HoldFor"/>), and only again once it has been gone for <see cref="AlertRules.ClearHold"/> and comes
/// back (so a flapping cover or a level wobbling around the threshold alerts once). Quiet hours hold alerts until they end
/// (<see cref="Release"/>), dropping those that cleared meanwhile; a pause or alerts turned off drop them. Alerts already
/// shown are remembered across restarts (<see cref="Shown"/>), so starting with Windows doesn't repeat yesterday's low toner.
/// Pure: the caller supplies the time.
/// </summary>
public sealed class AlertTracker
{
    private sealed class Track(AlertKind kind)
    {
        public AlertKind Kind { get; } = kind;
        public AlertCondition? Condition;
        public DateTimeOffset FirstSeen;
        public DateTimeOffset? AbsentSince;
        public bool Seen, Confirmed, Notified;
        public bool Present => Seen && AbsentSince is null;
        public bool Due => Present && Confirmed && !Notified;
    }

    private sealed class Printer
    {
        public string Name = "";
        public DateTimeOffset? LastObserved;
        public readonly Dictionary<string, Track> Tracks = new(StringComparer.Ordinal);
    }

    private readonly Dictionary<string, Printer> _printers = new(StringComparer.OrdinalIgnoreCase);

    /// <param name="shown">Keys of alerts already shown, per printer (<see cref="Shown"/> from the last run).</param>
    public AlertTracker(AlertRules rules, IReadOnlyDictionary<string, IReadOnlyList<string>>? shown = null)
    {
        Rules = rules;
        foreach (var (uuid, keys) in shown ?? new Dictionary<string, IReadOnlyList<string>>())
            foreach (var key in keys ?? [])
                if (key is not null && AlertCondition.KindOf(key) is { } kind)
                    PrinterOf(uuid).Tracks[key] = new Track(kind) { Notified = true, Confirmed = true };
    }

    public AlertRules Rules { get; set; }

    /// <summary>"Pause alerts": nothing is shown until then, and what came up meanwhile isn't shown later.</summary>
    public DateTimeOffset? PausedUntil { get; set; }

    private Printer PrinterOf(string uuid)
    {
        if (!_printers.TryGetValue(uuid, out var p)) _printers[uuid] = p = new Printer();
        return p;
    }

    /// <summary>Takes in one printer's latest state; returns the alerts to show now.</summary>
    public IReadOnlyList<AlertNotice> Observe(PrinterSnapshot snap, DateTimeOffset now)
    {
        var printer = PrinterOf(snap.Uuid);
        printer.Name = snap.Name;
        if (printer.LastObserved is { } last && now - last > Rules.MaxGap)
            foreach (var t in printer.Tracks.Values.Where(t => !t.Confirmed)) t.Seen = false; // its hold starts again below
        printer.LastObserved = now;

        var found = AlertConditions.Find(snap, Rules, key => printer.Tracks.TryGetValue(key, out var t) && t.Present && t.Confirmed);
        foreach (var c in found)
        {
            if (!printer.Tracks.TryGetValue(c.Key, out var t)) printer.Tracks[c.Key] = t = new Track(c.Kind);
            if (!t.Seen) t.FirstSeen = now;
            t.Seen = true;
            t.AbsentSince = null;
            t.Condition = c;
            if (now - t.FirstSeen >= Rules.HoldFor(c.Kind)) t.Confirmed = true;
        }
        foreach (var (key, t) in printer.Tracks.ToList())
        {
            if (found.Any(c => c.Key == key)) continue;
            if (!Observable(t.Kind, snap))
            {
                // Can't be seen now (printer off, unusable reply): a problem still within its hold is dropped, since its
                // hold can't run out unseen (and must not keep asking for a check); a confirmed one stands as known.
                if (!t.Confirmed) printer.Tracks.Remove(key);
                continue;
            }
            if (!t.Seen && !t.Notified) { printer.Tracks.Remove(key); continue; }
            t.AbsentSince ??= now;
            if (now - t.AbsentSince >= Rules.ClearHold || !t.Confirmed) printer.Tracks.Remove(key);
        }
        return Release(now);
    }

    /// <summary>Whether a snapshot shows this kind of problem at all (else what was known stands).</summary>
    private static bool Observable(AlertKind kind, PrinterSnapshot snap) =>
        kind == AlertKind.Offline || (snap.Reachable && (AlertCondition.IsSupply(kind) ? snap.Supplies is not null : snap.Status is not null));

    /// <summary>Alerts due and not shown yet: called after each check and on a timer (quiet hours ending).</summary>
    public IReadOnlyList<AlertNotice> Release(DateTimeOffset now)
    {
        var due = _printers.SelectMany(p => p.Value.Tracks.Values.Where(t => t.Due).Select(t => (Uuid: p.Key, p.Value.Name, Track: t))).ToList();
        if (due.Count == 0) return [];
        var silent = !Rules.Enabled || PausedUntil > now;
        if (!silent && Rules.Quiet is { } quiet && quiet.Contains(TimeOnly.FromDateTime(now.DateTime))) return []; // held till morning
        var notices = new List<AlertNotice>();
        foreach (var (uuid, name, t) in due)
        {
            t.Notified = true;
            if (silent || (t.Kind == AlertKind.Offline && !Rules.Offline) || Outranked(uuid, t)) continue;
            notices.Add(new AlertNotice(uuid, name, t.Kind, t.Condition!.Title, t.Condition.Body));
        }
        return notices;
    }

    /// <summary>An empty cartridge is also low, a full waste box also almost full: tell the worse one only.</summary>
    private bool Outranked(string uuid, Track t)
    {
        var worse = t.Kind switch { AlertKind.SupplyLow => AlertKind.SupplyEmpty, AlertKind.WasteAlmostFull => AlertKind.WasteFull, _ => (AlertKind?)null };
        if (worse is null) return false;
        var detail = t.Condition!.Key[(t.Condition.Key.IndexOf('|') + 1)..];
        return _printers[uuid].Tracks.TryGetValue($"{worse}|{detail}", out var w) && w.Present && w.Confirmed;
    }

    /// <summary>When a problem seen but still within its hold time will be due: check again then. Null: nothing pending.</summary>
    public DateTimeOffset? NextCheck => _printers.Keys.Select(PendingUntil).Min();

    /// <summary><see cref="NextCheck"/> for one printer.</summary>
    public DateTimeOffset? PendingUntil(string uuid) =>
        _printers.TryGetValue(uuid, out var p)
            ? p.Tracks.Values.Where(t => t.Present && !t.Confirmed).Select(t => (DateTimeOffset?)(t.FirstSeen + Rules.HoldFor(t.Kind))).Min()
            : null;

    /// <summary>Problems still within their hold time start it again (the PC woke up: the time it slept doesn't count).</summary>
    public void ResetPending()
    {
        foreach (var p in _printers.Values)
            foreach (var (key, t) in p.Tracks.ToList())
                if (!t.Confirmed) p.Tracks.Remove(key);
    }

    /// <summary>A printer was removed.</summary>
    public void Forget(string uuid) => _printers.Remove(uuid);

    private IEnumerable<Track> Current(string uuid) =>
        _printers.TryGetValue(uuid, out var p) ? p.Tracks.Values.Where(t => t.Present && t.Confirmed) : [];

    /// <summary>A printer's state for the tray: its worst ongoing problem.</summary>
    public AlertLevel Level(string uuid) => Current(uuid).Select(t => AlertCondition.LevelOf(t.Kind)).DefaultIfEmpty(AlertLevel.Ok).Max();

    /// <summary>The tray icon: the worst printer.</summary>
    public AlertLevel Overall => _printers.Keys.Select(Level).DefaultIfEmpty(AlertLevel.Ok).Max();

    /// <summary>A printer's worst ongoing problem in a few words ("Paper jam", "Offline"), or null when there's none.</summary>
    public string? Problem(string uuid) =>
        Current(uuid).OrderByDescending(t => AlertCondition.LevelOf(t.Kind)).ThenBy(t => t.Kind)
            .Select(t => t.Kind == AlertKind.Offline ? "Offline" : t.Condition!.Title).FirstOrDefault();

    /// <summary>Keys of the alerts shown that are still going on, per printer: kept across restarts.</summary>
    public Dictionary<string, IReadOnlyList<string>> Shown() =>
        _printers.Select(p => (p.Key, Keys: p.Value.Tracks.Where(t => t.Value.Notified).Select(t => t.Key).Order(StringComparer.Ordinal).ToList()))
            .Where(p => p.Keys.Count > 0)
            .ToDictionary(p => p.Key, p => (IReadOnlyList<string>)p.Keys, StringComparer.OrdinalIgnoreCase);
}

/// <summary>How often the tray checks printers while the window is closed: rarely, less on battery or a metered network, and
/// backing off from a printer that doesn't answer.</summary>
public static class AlertPolling
{
    public static readonly TimeSpan Normal = TimeSpan.FromMinutes(5), Saving = TimeSpan.FromMinutes(15), Longest = TimeSpan.FromMinutes(60);

    public static TimeSpan Interval(bool onBattery, bool metered, int failures)
    {
        var interval = onBattery || metered ? Saving : Normal;
        for (var i = 0; i < failures && interval < Longest; i++) interval *= 2;
        return interval < Longest ? interval : Longest;
    }
}

/// <summary>One printer's line in the tray tooltip and menu.</summary>
public sealed record PrinterLine(string Name, AlertLevel Level, string Text);

public static class TrayText
{
    /// <summary>The notification area's tooltip holds 127 characters (NOTIFYICONDATA.szTip).</summary>
    public const int MaxLength = 127;

    /// <summary>"Inkvolt Print" then a line per printer, problems first, cut to fit with "+n more".</summary>
    public static string Tooltip(IReadOnlyList<PrinterLine> printers, bool paused)
    {
        var text = paused ? "Inkvolt Print (alerts paused)" : "Inkvolt Print";
        var lines = printers.OrderByDescending(p => p.Level).Select(p => Cut($"{p.Name}: {p.Text}", 60)).ToList();
        for (var i = 0; i < lines.Count; i++)
        {
            var rest = lines.Count - i - 1;
            var more = rest > 0 ? $"\n+{rest} more" : "";
            if (text.Length + 1 + lines[i].Length + more.Length > MaxLength)
                return text + $"\n+{lines.Count - i} more";
            text += "\n" + lines[i];
        }
        return text;
    }

    private static string Cut(string s, int max) => s.Length <= max ? s : s[..(max - 1)].TrimEnd() + "…";
}
