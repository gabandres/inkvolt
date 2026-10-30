using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Alerts;

/// <summary>What an alert is about. Supplies and waste boxes come from the supplies; the rest from the printer's status.</summary>
public enum AlertKind { SupplyLow, SupplyEmpty, WasteAlmostFull, WasteFull, PaperJam, PaperOut, CoverOpen, Error, Offline }

/// <summary>The tray icon's state, in rank order: an error outranks a low supply, which outranks a printer that's off.</summary>
public enum AlertLevel { Ok, Offline, Warning, Error }

/// <summary>
/// One printer as last read: reachable or not, its status (null when the reply was unusable, e.g. the printer was waking up)
/// and its supplies (null when unknown). Unknown parts keep what was known before; they never count as "the problem is gone".
/// </summary>
public sealed record PrinterSnapshot(string Uuid, string Name, bool Reachable, PrinterStatus? Status, IReadOnlyList<Consumable>? Supplies)
{
    /// <summary>Days left per supply (<see cref="History.SupplyRow.KeyOf(Consumable)"/>) where the history can tell: the low-supply alert names them.</summary>
    public IReadOnlyDictionary<string, int>? DaysLeft { get; init; }
}

/// <summary>A problem seen on a printer. <see cref="Key"/> is stable while it lasts ("SupplyLow|Black toner|K").</summary>
public sealed record AlertCondition(string Key, AlertKind Kind, string Title, string Body)
{
    public AlertLevel Level => LevelOf(Kind);

    public static AlertLevel LevelOf(AlertKind kind) => kind switch
    {
        AlertKind.SupplyLow or AlertKind.WasteAlmostFull => AlertLevel.Warning,
        AlertKind.Offline => AlertLevel.Offline,
        _ => AlertLevel.Error,
    };

    /// <summary>The kind a key was made for, or null for a key this version doesn't know.</summary>
    public static AlertKind? KindOf(string key) =>
        Enum.GetNames<AlertKind>().Contains(key.Split('|')[0]) ? Enum.Parse<AlertKind>(key.Split('|')[0]) : null;

    /// <summary>Kinds read from the supplies (unknown while the supplies are).</summary>
    public static bool IsSupply(AlertKind kind) => kind is AlertKind.SupplyLow or AlertKind.SupplyEmpty or AlertKind.WasteAlmostFull or AlertKind.WasteFull;
}

/// <summary>
/// Turns a <see cref="PrinterSnapshot"/> into the problems worth telling someone about: supplies at or under the threshold
/// or empty, waste boxes almost full or full, paper jams, no paper, open covers, other printer errors, and the printer not
/// answering. Warnings the printer itself raises (paper low, toner low by its own measure) aren't alerts; supply levels come
/// from the supplies, never from status reasons, so one empty cartridge is one alert. The scanner's document feeder only
/// matters while someone is scanning, so it's left out.
/// </summary>
public static class AlertConditions
{
    /// <param name="isActive">Whether a key is already an ongoing alert: a low supply then stays low until it is
    /// <see cref="AlertRules.Hysteresis"/> points above the threshold, so a level wobbling around it alerts once.</param>
    public static IReadOnlyList<AlertCondition> Find(PrinterSnapshot snap, AlertRules rules, Func<string, bool> isActive)
    {
        var found = new List<AlertCondition>();
        if (!snap.Reachable)
        {
            found.Add(new AlertCondition("Offline", AlertKind.Offline, $"{snap.Name} is offline",
                "Inkvolt Print can't reach it. It may be turned off, asleep or off the network."));
            return found;
        }
        if (snap.Status is { } status) AddStatus(found, snap.Name, status);
        foreach (var s in snap.Supplies ?? []) AddSupply(found, snap.Name, s, rules, isActive, snap.DaysLeft);
        return found;
    }

    private static void AddStatus(List<AlertCondition> found, string printer, PrinterStatus status)
    {
        var problems = status.Alerts.Where(a => a.Severity == Severity.Error).Select(a => (a.Id, a.Message)).ToList();
        // The status code says the same as its error alerts (IPP "stopped" because of "media-jam"); alone, it counts.
        if (problems.Count == 0 && status.Severity == Severity.Error && !status.IsUnavailable && status.Code is not ("offline" or "ready" or "idle" or "inPowerSave"))
            problems.Add((status.Code, status.Message));
        foreach (var (rawId, message) in problems)
        {
            var id = Reason(rawId);
            if (id.StartsWith("scanner", StringComparison.OrdinalIgnoreCase) || IsSupplyReason(id)) continue;
            var (kind, title, body) = Classify(id, message, printer);
            var key = kind == AlertKind.Error ? $"Error|{id}" : kind.ToString();
            if (found.All(f => f.Key != key)) found.Add(new AlertCondition(key, kind, title, body));
        }
    }

    /// <summary>IPP reasons may carry a -error / -warning / -report suffix (RFC 8011 §5.4.12).</summary>
    private static string Reason(string id)
    {
        foreach (var suffix in new[] { "-error", "-warning", "-report" })
            if (id.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return id[..^suffix.Length];
        return id;
    }

    private static bool Has(string id, string part) => id.Contains(part, StringComparison.OrdinalIgnoreCase);

    /// <summary>Supply levels and waste boxes (LEDM cartridge*, IPP toner-*, marker-*): read from the supplies instead.</summary>
    private static bool IsSupplyReason(string id)
    {
        if (Has(id, "waste")) return true;
        var supply = Has(id, "toner") || Has(id, "marker") || Has(id, "cartridge") || Has(id, "developer") || Has(id, "ink");
        return supply && (Has(id, "low") || Has(id, "empty") || id.EndsWith("Out", StringComparison.OrdinalIgnoreCase));
    }

    private static (AlertKind, string Title, string Body) Classify(string id, string message, string printer)
    {
        if (Has(id, "jam")) return (AlertKind.PaperJam, "Paper jam", $"{printer}: clear the jam to keep printing.");
        if (id is "media-empty" or "media-needed" or "trayEmptyOrOpen" or "mediaPrompt" or "input-tray-missing")
            return (AlertKind.PaperOut, message, $"{printer}: load paper to keep printing.");
        if (Has(id, "cover") || Has(id, "door") || id == "interlock-open")
            return (AlertKind.CoverOpen, message, $"{printer}: close it to keep printing.");
        return (AlertKind.Error, message, $"{printer}: check the printer.");
    }

    private static void AddSupply(List<AlertCondition> found, string printer, Consumable s, AlertRules rules, Func<string, bool> isActive,
        IReadOnlyDictionary<string, int>? daysLeft)
    {
        var detail = $"{s.Name}|{s.ColorCode}";
        if (s.IsWaste)
        {
            var full = s.State == "full";
            if (full) found.Add(new($"{AlertKind.WasteFull}|{detail}", AlertKind.WasteFull, $"{s.Name} full", $"{printer}: replace it to keep printing."));
            if (full || s.State == "almostFull")
                found.Add(new($"{AlertKind.WasteAlmostFull}|{detail}", AlertKind.WasteAlmostFull, $"{s.Name} almost full", $"{printer}: replace it soon."));
            return;
        }
        var lowKey = $"{AlertKind.SupplyLow}|{detail}";
        var empty = s.State == "out" || s.PercentRemaining <= 0;
        var low = empty || (s.PercentRemaining is { } p
            ? p <= rules.LowPercent + (isActive(lowKey) ? rules.Hysteresis : 0)
            : s.State is "low" or "veryLow");
        if (empty) found.Add(new($"{AlertKind.SupplyEmpty}|{detail}", AlertKind.SupplyEmpty, $"{s.Name} empty", $"{printer}: replace it to keep printing."));
        if (!low) return;
        var left = s.EstimatedPagesRemaining is { } pages and > 0 ? $"about {pages:N0} pages left" : null;
        if (daysLeft is not null && daysLeft.TryGetValue(History.SupplyRow.KeyOf(s), out var days))
        {
            var word = days == 1 ? "day" : "days";
            left = left is null ? $"about {days:N0} {word} left at this rate" : $"{left}, about {days:N0} {word} at this rate";
        }
        var part = Part(s) is { } number ? $"Replacement: {number}." : null;
        var body = $"{printer}: {left ?? "running low"}." + (part is null ? "" : $" {part}");
        found.Add(new(lowKey, AlertKind.SupplyLow, s.PercentRemaining is { } pct ? $"{s.Name} low ({pct}%)" : $"{s.Name} low", body));
    }

    /// <summary>The cartridge number the supplies card already shows (HP's selectability number, then the product number).</summary>
    private static string? Part(Consumable s) =>
        string.Join(" · ", new[] { s.SelectibilityNumber is { } sel ? $"HP {sel}" : null, s.ProductNumber }.OfType<string>()) is { Length: > 0 } p ? p : null;
}
