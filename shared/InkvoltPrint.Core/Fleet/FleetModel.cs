using System.Globalization;
using System.Text;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Fleet;

/// <summary>What a fleet entry is: <see cref="Queues.ListedKind"/> as the Fleet page and the JSON say it.</summary>
public enum FleetKind { Network, Queue, Scanner }

/// <summary>How much trouble a printer is in, in the list's order (the worst first): an error outranks a low supply, which outranks a printer that's off, as the tray icon ranks them (<see cref="Alerts.AlertLevel"/>).</summary>
public enum FleetTrouble { Error, Warning, Offline, Unknown, Ok }

/// <summary>One supply as the fleet shows it. <paramref name="Level"/> is 0 to 100, or null when the printer gives none.</summary>
public sealed record FleetSupply(string Name, string? Color, int? Level, string State);

/// <summary>What is known of a printer, as read (the sources' own text, not trusted): <see cref="FleetPrinter.Of"/> makes the entry.</summary>
public sealed record FleetFacts(string Id, string Name, FleetKind Kind)
{
    public string? Model { get; init; }

    /// <summary>How it's reached: its interfaces ("LEDM, eSCL") or how its queue is connected ("USB").</summary>
    public string? Connection { get; init; }

    /// <summary>It answered, now. No: its status says why, and the rest is what's <see cref="LastKnown"/>.</summary>
    public bool Reachable { get; init; }

    /// <summary>Null, or <see cref="PrinterStatus.IsUnavailable"/>: it answered without a usable status.</summary>
    public PrinterStatus? Status { get; init; }

    public IReadOnlyList<Consumable> Supplies { get; init; } = [];
    public int? Pages { get; init; }
    public string? Firmware { get; init; }

    /// <summary>When it last gave a reading.</summary>
    public DateTimeOffset? LastReading { get; init; }

    /// <summary>The day it last gave a reading, when only the supply history knows (one row a day).</summary>
    public DateOnly? LastReadingDay { get; init; }

    /// <summary>Its supplies, pages and firmware are from its last reading, not from now.</summary>
    public bool LastKnown { get; init; }
}

/// <summary>
/// One entry of the Fleet page and the export: every text cleaned and bounded (<see cref="FleetText"/>), since a printer writes
/// most of it, and its trouble decided in one place. It holds no serial number, address or UUID; <see cref="Id"/> tells entries
/// apart on the page and is never written out.
/// </summary>
public sealed record FleetPrinter(string Id, string Name, FleetKind Kind, FleetTrouble Trouble, string Status)
{
    public const int MaxText = 240, MaxItems = 16;

    public string? Model { get; init; }
    public string? Connection { get; init; }
    public IReadOnlyList<string> Problems { get; init; } = [];
    public IReadOnlyList<FleetSupply> Supplies { get; init; } = [];
    public int? Pages { get; init; }
    public string? Firmware { get; init; }
    public DateTimeOffset? LastReading { get; init; }
    public DateOnly? LastReadingDay { get; init; }
    public bool LastKnown { get; init; }

    public static FleetPrinter Of(FleetFacts f)
    {
        var usable = f.Status is { IsUnavailable: false } ? f.Status : null;
        return new FleetPrinter(f.Id, FleetText.Clean(f.Name, MaxText) ?? "Printer with no name", f.Kind, TroubleOf(f, usable),
            FleetText.Clean(f.Status?.Message, MaxText) ?? "Status not available")
        {
            Model = FleetText.Clean(f.Model, MaxText),
            Connection = FleetText.Clean(f.Connection, MaxText),
            Problems = (usable?.Alerts ?? []).Where(a => a.Severity != Severity.Info).OrderByDescending(a => a.Severity)
                .Select(a => FleetText.Clean(a.Message, MaxText)).OfType<string>().Distinct().Take(MaxItems).ToList(),
            Supplies = f.Supplies.Take(MaxItems).Select(s => new FleetSupply(FleetText.Clean(s.Name, MaxText) ?? s.Kind,
                FleetText.Clean(s.ColorCode, 24), s.PercentRemaining is { } p and >= -1 and not -1 ? Math.Clamp(p, 0, 100) : null,
                FleetText.Clean(s.State, 24) ?? "unknown")).ToList(),
            Pages = f.Pages is >= 0 ? f.Pages : null,
            Firmware = FleetText.Clean(f.Firmware, MaxText),
            LastReading = f.LastReading,
            LastReadingDay = f.LastReadingDay,
            LastKnown = f.LastKnown,
        };
    }

    private static FleetTrouble TroubleOf(FleetFacts f, PrinterStatus? status)
    {
        if (!f.Reachable) return FleetTrouble.Offline;
        var trouble = status is null ? FleetTrouble.Unknown : status.Severity switch
        {
            Severity.Error => FleetTrouble.Error,
            Severity.Warning => FleetTrouble.Warning,
            _ => FleetTrouble.Ok,
        };
        foreach (var s in f.Supplies)
        {
            if (s.State is "out" or "full" or "missing") return FleetTrouble.Error;
            if (s.IsLow && trouble > FleetTrouble.Warning) trouble = FleetTrouble.Warning;
        }
        return trouble;
    }
}

/// <summary>The list's order: most trouble first, then by name and id, so it doesn't jump about between reads.</summary>
public static class FleetOrder
{
    public static IReadOnlyList<FleetPrinter> Sort(IEnumerable<FleetPrinter> printers) =>
        printers.OrderBy(p => p.Trouble).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ThenBy(p => p.Id, StringComparer.OrdinalIgnoreCase).ToList();
}

/// <summary>Text a printer or a driver wrote, made fit to show and write out.</summary>
public static class FleetText
{
    /// <summary>
    /// One line at most <paramref name="max"/> long, or null when nothing is left: no control or invisible characters (a
    /// right-to-left override turns a line round on screen, a line break forges a row), no half surrogate pairs, single spaces.
    /// </summary>
    public static string? Clean(string? text, int max)
    {
        if (text is null) return null;
        var clean = new StringBuilder(Math.Min(text.Length, max + 8));
        var space = false;
        // Past this nothing would be kept: a printer's megabyte of text costs no more than its first few hundred characters.
        var end = Math.Min(text.Length, max * 4 + 64);
        for (var i = 0; i < end && clean.Length <= max + 1; i++)
        {
            var c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                if (space && clean.Length > 0) clean.Append(' ');
                space = false;
                clean.Append(c).Append(text[++i]);
                continue;
            }
            switch (char.GetUnicodeCategory(c))
            {
                case UnicodeCategory.Control when char.IsWhiteSpace(c):
                case UnicodeCategory.SpaceSeparator or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator:
                    space = true;
                    break;
                case UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.Surrogate or UnicodeCategory.PrivateUse or UnicodeCategory.OtherNotAssigned:
                    break;
                default:
                    if (space && clean.Length > 0) clean.Append(' ');
                    space = false;
                    clean.Append(c);
                    break;
            }
        }
        if (clean.Length == 0) return null;
        if (clean.Length <= max) return clean.ToString();
        var cut = max - 1; // room for the ellipsis, and never half a pair
        if (char.IsLowSurrogate(clean[cut])) cut--;
        return clean.ToString(0, cut).TrimEnd() + "…";
    }
}

/// <summary>What the supply history says of a printer that isn't answering: its last day's levels and page count.</summary>
public sealed record FleetLastKnown(DateOnly Day, int? Pages, IReadOnlyList<Consumable> Supplies)
{
    public static FleetLastKnown? From(IReadOnlyList<SupplyRow> rows)
    {
        if (rows.Count == 0) return null;
        var day = rows.Max(r => r.Day);
        var last = rows.Where(r => r.Day == day).ToList();
        return new FleetLastKnown(day, rows.Where(r => r.Pages is not null).OrderBy(r => r.Day).LastOrDefault()?.Pages,
            last.Select(r => new Consumable(r.Supply, "", r.Color, r.Percent, r.State, null, null, null, null, null)).ToList());
    }
}
