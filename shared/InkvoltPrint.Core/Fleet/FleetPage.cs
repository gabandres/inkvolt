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
        var pages = p.Pages is { } n ? string.Format(p.LastKnown ? CoreStrings.Fleet_PagesPrintedLastKnown : CoreStrings.Fleet_PagesPrinted, n.ToString("N0", CultureInfo.InvariantCulture))
            : p.Kind == FleetKind.Scanner ? CoreStrings.Fleet_PagesScanner : CoreStrings.Fleet_PagesNotReported;
        var firmware = p.Firmware is { } f ? string.Format(p.LastKnown ? CoreStrings.Fleet_FirmwareLastKnown : CoreStrings.Fleet_Firmware, f) : CoreStrings.Fleet_FirmwareNotReported;
        var read = LastRead(p, now);
        var none = supplies.Count > 0 ? null : p.Kind == FleetKind.Scanner ? CoreStrings.Fleet_NoSuppliesScanner : CoreStrings.Fleet_SuppliesNotReported;
        var said = string.Join(". ", new[]
        {
            p.Name, TroubleText(p.Trouble), status,
            supplies.Count > 0 ? string.Join(", ", supplies.Select(s => s.IsLow ? string.Format(CoreStrings.Fleet_SupplyLowSpoken, s.Text) : s.Text)) : none,
            pages, firmware, read,
        }.OfType<string>());
        return new FleetRow(p, status, supplies, none, pages, firmware, read, said + ".");
    }

    /// <summary>"9 printers: 1 with an error, 3 needing attention, 2 can't be reached, 3 fine."</summary>
    public static string Summary(IReadOnlyCollection<FleetPrinter> printers)
    {
        if (printers.Count == 0) return CoreStrings.Fleet_NoPrinters;
        int Count(FleetTrouble t) => printers.Count(p => p.Trouble == t);
        var parts = new (int Count, string One, string Many)[]
        {
            (Count(FleetTrouble.Error), CoreStrings.Fleet_SummaryError_One, CoreStrings.Fleet_SummaryError_Many),
            (Count(FleetTrouble.Warning), CoreStrings.Fleet_SummaryWarning_One, CoreStrings.Fleet_SummaryWarning_Many),
            (Count(FleetTrouble.Offline), CoreStrings.Fleet_SummaryOffline_One, CoreStrings.Fleet_SummaryOffline_Many),
            (Count(FleetTrouble.Unknown), CoreStrings.Fleet_SummaryUnknown_One, CoreStrings.Fleet_SummaryUnknown_Many),
            (Count(FleetTrouble.Ok), CoreStrings.Fleet_SummaryOk_One, CoreStrings.Fleet_SummaryOk_Many),
        }.Where(p => p.Count > 0).Select(p => Plural.Of(p.Count, p.One, p.Many));
        return Plural.Of(printers.Count, CoreStrings.Fleet_Summary_One, CoreStrings.Fleet_Summary_Many, string.Join(", ", parts));
    }

    public static string TroubleText(FleetTrouble trouble) => trouble switch
    {
        FleetTrouble.Error => CoreStrings.Fleet_TroubleError,
        FleetTrouble.Warning => CoreStrings.Fleet_TroubleWarning,
        FleetTrouble.Offline => CoreStrings.Fleet_TroubleOffline,
        FleetTrouble.Unknown => CoreStrings.Fleet_TroubleUnknown,
        _ => CoreStrings.Fleet_TroubleOk,
    };

    private static string SupplyText(FleetSupply s) => s.Level is { } level ? $"{s.Name} {level}%" : s.State switch
    {
        "full" => string.Format(CoreStrings.Fleet_SupplyFull, s.Name),
        "almostFull" => string.Format(CoreStrings.Fleet_SupplyAlmostFull, s.Name),
        "out" => string.Format(CoreStrings.Fleet_SupplyEmpty, s.Name),
        "missing" => string.Format(CoreStrings.Fleet_SupplyMissing, s.Name),
        "low" or "veryLow" => string.Format(CoreStrings.Fleet_SupplyLow, s.Name),
        "ok" => string.Format(CoreStrings.Fleet_SupplyOk, s.Name),
        _ => s.Name,
    };

    private static bool IsLow(FleetSupply s) => s.State is "low" or "veryLow" or "out" or "almostFull" or "full" or "missing";

    private static string LastRead(FleetPrinter p, DateTimeOffset now)
    {
        if (p.LastReading is { } time)
        {
            var ago = now - time;
            if (ago < TimeSpan.FromMinutes(1)) return CoreStrings.Fleet_ReadJustNow;
            if (ago < TimeSpan.FromHours(1)) return Plural.Of((int)ago.TotalMinutes, CoreStrings.Fleet_ReadMinutesAgo_One, CoreStrings.Fleet_ReadMinutesAgo_Many);
            if (ago < TimeSpan.FromHours(24)) return Plural.Of((int)ago.TotalHours, CoreStrings.Fleet_ReadHoursAgo_One, CoreStrings.Fleet_ReadHoursAgo_Many);
            return string.Format(CoreStrings.Fleet_LastRead, time.ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture));
        }
        return p.LastReadingDay is { } day ? string.Format(CoreStrings.Fleet_LastRead, day.ToString("d MMM yyyy", CultureInfo.CurrentCulture)) : CoreStrings.Fleet_NotReadYet;
    }
}
