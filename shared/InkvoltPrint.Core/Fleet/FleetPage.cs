using System.Globalization;

namespace InkvoltPrint.Core.Fleet;

/// <summary>One supply on a row of the Fleet page: "Black 42%", its bar and whether it's low.</summary>
public sealed record FleetSupplyRow(string Text, int? Level, string? Color, bool IsLow);

/// <summary>One row of the Fleet page, in words: what the view binds to and a screen reader reads.</summary>
public sealed record FleetRow(FleetPrinter Printer, string StatusLine, IReadOnlyList<FleetSupplyRow> Supplies, string? NoSuppliesText, string PagesText, string FirmwareText,
    string LastReadText, string AccessibleText);

/// <summary>What the Fleet page says: a row per printer and the line above them. Pure, so the words are tested without a window.</summary>
public static class FleetPage
{
    public static IReadOnlyList<FleetRow> Rows(IEnumerable<FleetPrinter> printers, DateTimeOffset now) =>
        FleetOrder.Sort(printers).Select(p => Row(p, now)).ToList();

    public static FleetRow Row(FleetPrinter p, DateTimeOffset now)
    {
        var supplies = p.Supplies.Select(s => new FleetSupplyRow(SupplyText(s), s.Level, s.Color, IsLow(s))).ToList();
        var status = p.Problems.Count == 0 ? p.Status
            : string.Equals(p.Problems[0], p.Status, StringComparison.OrdinalIgnoreCase) ? string.Join(" · ", p.Problems)
            : $"{p.Status} · {string.Join(" · ", p.Problems)}";
        var known = p.LastKnown ? " (last known)" : "";
        var pages = p.Pages is { } n ? $"{n.ToString("N0", CultureInfo.InvariantCulture)} pages printed{known}" : p.Kind == FleetKind.Scanner ? "Pages: a scanner has no count" : "Pages not reported";
        var firmware = p.Firmware is { } f ? $"Firmware {f}{known}" : "Firmware not reported";
        var read = LastRead(p, now);
        var none = supplies.Count > 0 ? null : p.Kind == FleetKind.Scanner ? "No supplies: it's a scanner" : "Supplies not reported";
        var said = string.Join(". ", new[]
        {
            p.Name, TroubleText(p.Trouble), status,
            supplies.Count > 0 ? string.Join(", ", supplies.Select(s => s.IsLow ? $"{s.Text}, low" : s.Text)) : none,
            pages, firmware, read,
        }.OfType<string>());
        return new FleetRow(p, status, supplies, none, pages, firmware, read, said + ".");
    }

    /// <summary>"9 printers: 1 with an error, 3 needing attention, 2 can't be reached, 3 fine."</summary>
    public static string Summary(IReadOnlyCollection<FleetPrinter> printers)
    {
        if (printers.Count == 0) return "No printers yet.";
        int Count(FleetTrouble t) => printers.Count(p => p.Trouble == t);
        var parts = new (int Count, string Text)[]
        {
            (Count(FleetTrouble.Error), Count(FleetTrouble.Error) == 1 ? "with an error" : "with errors"),
            (Count(FleetTrouble.Warning), "needing attention"),
            (Count(FleetTrouble.Offline), "can't be reached"),
            (Count(FleetTrouble.Unknown), "not known yet"),
            (Count(FleetTrouble.Ok), "fine"),
        }.Where(p => p.Count > 0).Select(p => $"{p.Count} {p.Text}");
        return $"{printers.Count} {(printers.Count == 1 ? "printer" : "printers")}: {string.Join(", ", parts)}.";
    }

    public static string TroubleText(FleetTrouble trouble) => trouble switch
    {
        FleetTrouble.Error => "Error",
        FleetTrouble.Warning => "Needs attention",
        FleetTrouble.Offline => "Can't be reached",
        FleetTrouble.Unknown => "Not known yet",
        _ => "Fine",
    };

    private static string SupplyText(FleetSupply s) => s.Level is { } level ? $"{s.Name} {level}%" : s.State switch
    {
        "full" => $"{s.Name}: full",
        "almostFull" => $"{s.Name}: almost full",
        "out" => $"{s.Name}: empty",
        "missing" => $"{s.Name}: missing",
        "low" or "veryLow" => $"{s.Name}: low",
        "ok" => $"{s.Name}: OK",
        _ => s.Name,
    };

    private static bool IsLow(FleetSupply s) => s.State is "low" or "veryLow" or "out" or "almostFull" or "full" or "missing";

    private static string LastRead(FleetPrinter p, DateTimeOffset now)
    {
        if (p.LastReading is { } time)
        {
            var ago = now - time;
            if (ago < TimeSpan.FromMinutes(1)) return "Read just now";
            if (ago < TimeSpan.FromHours(1)) return (int)ago.TotalMinutes == 1 ? "Read 1 minute ago" : $"Read {(int)ago.TotalMinutes} minutes ago";
            if (ago < TimeSpan.FromHours(24)) return (int)ago.TotalHours == 1 ? "Read 1 hour ago" : $"Read {(int)ago.TotalHours} hours ago";
            return $"Last read {time.ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture)}";
        }
        return p.LastReadingDay is { } day ? $"Last read {day.ToString("d MMM yyyy", CultureInfo.CurrentCulture)}" : "Not read yet";
    }
}
