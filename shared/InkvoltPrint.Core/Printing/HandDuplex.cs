using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Printing;

/// <summary>Which way up printed sheets land in a printer's output tray.</summary>
public enum OutputFace
{
    /// <summary>Printed side down, the last sheet on top (most laser printers: the paper turns over on its way out).</summary>
    Down,

    /// <summary>Printed side up, the last sheet on top (most inkjets with a tray at the back, a straight paper path).</summary>
    Up,
}

/// <summary>What the person is told between the fronts and the backs (the app's words come from it).</summary>
/// <param name="Face">Which way up the fronts came out, as the person confirmed or the printer said.</param>
/// <param name="Sheets">How many sheets the fronts printed on.</param>
/// <param name="TurnOver">The stack goes back turned over like a page (face up: the printed side has to face down in the tray);
/// false: as it came out, without turning it over (face down).</param>
/// <param name="SetAside">The last sheet has nothing on its back: it lies on top of the output stack and is set aside before the
/// stack goes back, then put at the end of the finished stack.</param>
/// <param name="BlankBacks">Sheets in the stack whose back is blank (copies of an odd page count): they go through again with nothing printed.</param>
/// <param name="LastPage">The number of the sheet set aside's page, for the words ("page 7"), or null.</param>
public sealed record HandDuplexReload(OutputFace Face, int Sheets, bool TurnOver, bool SetAside, int BlankBacks, int? LastPage);

/// <summary>
/// Two-sided printing by hand (roadmap 4.2, print/GLOSSARY.md "two-sided by hand"): the sides of each sheet, in reading order, as
/// <see cref="Fronts"/> to print first and <see cref="Backs"/> to print once the stack is back in the tray. A sheet's back is
/// −1 when it has nothing on it. The backs' order depends on how the stack goes back (<see cref="OutputFace"/>): printed face down,
/// it goes back as it came out and the backs go last sheet first; face up, it's turned over like a page and they go in order. The
/// last sheet with no back is set aside rather than sent through blank, so a driver that drops a blank page can't shift every back.
/// </summary>
public sealed record HandDuplexPlan
{
    private readonly IReadOnlyList<int> _backs;

    private HandDuplexPlan(IReadOnlyList<int> fronts, IReadOnlyList<int> backs, IReadOnlyList<int> pages)
    {
        Fronts = fronts;
        _backs = backs;
        SheetPages = pages;
    }

    /// <summary>Each sheet's front, first sheet first: what's printed first.</summary>
    public IReadOnlyList<int> Fronts { get; }

    /// <summary>Each sheet's back, first sheet first (−1: nothing on it).</summary>
    public IReadOnlyList<int> SheetBacks => _backs;

    /// <summary>The page number shown on each sheet's front (for "page 7"): the side's index plus one within its copy.</summary>
    internal IReadOnlyList<int> SheetPages { get; }

    public int Sheets => Fronts.Count;

    /// <summary>The last sheet has no back: it's set aside, not sent through.</summary>
    public bool SetAside => _backs.Count > 0 && _backs[^1] < 0;

    /// <summary>There's something to print on the backs at all (one page alone has none).</summary>
    public bool HasBacks => _backs.Any(b => b >= 0);

    /// <summary>The backs in the order the reloaded stack feeds them (−1: a blank pass for a sheet in the middle whose back is empty).</summary>
    public IReadOnlyList<int> Backs(OutputFace face)
    {
        var sent = SetAside ? _backs.Take(_backs.Count - 1) : _backs;
        return face == OutputFace.Down ? [.. sent.Reverse()] : [.. sent];
    }

    public HandDuplexReload Reload(OutputFace face) =>
        new(face, Sheets, TurnOver: face == OutputFace.Up, SetAside, BlankBacks: Backs(face).Count(b => b < 0),
            LastPage: SetAside ? SheetPages[^1] : null);

    /// <summary>
    /// The plan for <paramref name="order"/>, the sides of one copy in reading order (−1: a blank side), times
    /// <paramref name="copies"/>: each copy starts on a sheet of its own (an odd copy ends on a blank back), so no two copies share a sheet.
    /// </summary>
    public static HandDuplexPlan For(IReadOnlyList<int> order, int copies = 1)
    {
        copies = Math.Clamp(copies, 1, 999);
        var sequence = new List<int>(order.Count * copies + copies);
        var pages = new List<int>();
        for (var c = 0; c < copies; c++)
        {
            sequence.AddRange(order);
            if (order.Count % 2 == 1) sequence.Add(-1);
        }
        var fronts = new List<int>();
        var backs = new List<int>();
        for (var i = 0; i < sequence.Count; i += 2)
        {
            fronts.Add(sequence[i]);
            backs.Add(i + 1 < sequence.Count ? sequence[i + 1] : -1);
            pages.Add(i % (order.Count + order.Count % 2) + 1);
        }
        return new HandDuplexPlan(fronts, backs, pages);
    }
}

/// <summary>Whether to offer two-sided by hand, and which way up a printer delivers its sheets.</summary>
public static class HandDuplex
{
    /// <summary>
    /// Two-sided by hand is offered where the printer (or its queue's driver) said it can't print both sides: never while that isn't
    /// known yet, never beside the printer's own two-sided.
    /// </summary>
    public static bool Offered(bool? printerTwoSided) => printerTwoSided == false;

    /// <summary>
    /// The face its sheets land: the default output tray's <c>pagedelivery</c> in <c>printer-output-tray</c> (PWG 5100.13) when it says
    /// <c>faceUp</c> or <c>faceDown</c>, else <c>output-bin-default</c> when it's <c>face-up</c> or <c>face-down</c> (RFC 8011's
    /// keywords); null when it says neither (the app then asks with face down chosen, the common case). Values are the printer's:
    /// 16 trays and 1 KB each at most are looked at.
    /// </summary>
    public static OutputFace? FaceOf(string? outputBinDefault, IEnumerable<string> outputTrays)
    {
        var trays = outputTrays.Take(16).Where(t => t.Length <= 1024).Select(Fields).ToList();
        var tray = trays.FirstOrDefault(t => outputBinDefault is not null && t.TryGetValue("name", out var n) && string.Equals(n, outputBinDefault, StringComparison.OrdinalIgnoreCase))
                   ?? (trays.Count == 1 ? trays[0] : null);
        if (tray is not null && tray.TryGetValue("pagedelivery", out var delivery))
        {
            if (delivery.StartsWith("faceUp", StringComparison.OrdinalIgnoreCase)) return OutputFace.Up;
            if (delivery.StartsWith("faceDown", StringComparison.OrdinalIgnoreCase)) return OutputFace.Down;
        }
        return outputBinDefault?.Trim().ToLowerInvariant() switch
        {
            "face-up" => OutputFace.Up,
            "face-down" => OutputFace.Down,
            _ => null,
        };

        static Dictionary<string, string> Fields(string tray) =>
            tray.Split(';', StringSplitOptions.RemoveEmptyEntries).Take(32).Select(f => f.Split('=', 2)).Where(kv => kv.Length == 2)
                .GroupBy(kv => kv[0].Trim(), StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First()[1].Trim(), StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>The face from a printer's Get-Printer-Attributes answer (<see cref="FaceOf(string?, IEnumerable{string})"/>).</summary>
    public static OutputFace? FaceOf(IppResponse? printer) =>
        printer is null ? null : FaceOf(printer.Str("output-bin-default"), printer.Strs("printer-output-tray"));
}
