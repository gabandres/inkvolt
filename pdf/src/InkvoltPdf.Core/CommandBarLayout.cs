namespace InkvoltPdf.Core;

/// <summary>
/// The document command bar, as Fluent 2 lays one out: a few primary commands with their labels, grouped in the order
/// people know (save and undo; the pointer tools; fill and sign; comment; draw; redact; pages), and a "…" overflow that
/// keeps the labels. Each group is one labeled button that drops a menu of its commands; the rest of the old bar's
/// icons (rotate, delete pages, find, combine) are secondary and always in the overflow. The command palette and the
/// menus list every command, so nothing here is the only way to reach anything.
/// </summary>
public static class CommandBarLayout
{
    /// <summary>One command of a group: the <c>Cmd</c> field it runs, its icon (Segoe Fluent Icons) and page-view letter key.</summary>
    public sealed record Command(string Name, string Glyph, string? Key = null);

    /// <summary>
    /// A place on the bar. <see cref="Priority"/>: when room runs short the lowest goes into the overflow first (on a tie,
    /// the later one). <see cref="Label"/> null: an icon whose meaning is universal (save, print, undo, redo).
    /// </summary>
    public sealed record Entry(string Id, string? Label, int Priority, IReadOnlyList<Command> Commands)
    {
        /// <summary>A labeled button that drops a menu of its commands, rather than running one.</summary>
        public bool IsGroup => Commands.Count > 1;
    }

    /// <summary>Priority from which a command keeps the bar labeled: if one of these would overflow with labels, the bar goes icons-only first.</summary>
    public const int KeepsLabels = 80;

    /// <summary>The pointer tools' group (labeled with the tool in use).</summary>
    public const string Pointer = "Pointer";
    /// <summary>The drawing tools' group (Draw: its menu is the drawing tools, its icon the last one used).</summary>
    public const string Draw = "Draw";

    /// <summary>The bar, left to right; null is a separator between groups.</summary>
    public static readonly IReadOnlyList<Entry?> Bar =
    [
        new("Save", null, 100, [new("Save", "\uE74E")]),
        new("Print", null, 100, [new("Print", "\uE749")]),
        new("Undo", null, 100, [new("Undo", "\uE7A7")]),
        new("Redo", null, 100, [new("Redo", "\uE7A6")]),
        null,
        new(Pointer, "Select", 85, [new("ToolHand", "\uE7C9", "H"), new("ToolSelect", "\uE8E9", "T"), new("ToolSnapshot", "\uE722", "G")]),
        null,
        new("FillSign", "Fill & Sign", 90,
            [new("ToolAddText", "\uE8D2", "A"), new("ToolCheck", "\uE73E", "K"), new("ToolCross", "\uE711", "X"), new("AddSignature", "\uE76D")]),
        new("Comment", "Comment", 80,
            [new("Highlight", "\uE7E6"), new("Underline", "\uE8DC"), new("StrikeOut", "\uE738"), new("AddNote", "\uE90A"),
             new("AddImage", "\uE91B", "I"), new("ToolLink", "\uE71B", "N"), new("AddStamp", "\uEB95", "S")]),
        new(Draw, "Draw", 60, []),
        new("Redact", "Redact", 50, [new("Redact", "\uE73B")]),
        null,
        new("Organize", "Organize", 70, [new("Organize", "\uE8B3")]),
    ];

    /// <summary>Always in the overflow, after what didn't fit: page commands and the rest of the old bar.</summary>
    public static readonly IReadOnlyList<Command> Secondary =
    [
        new("RotateLeft", "\uE7AD"), new("RotateRight", "\uE7AD"), new("DeleteSelected", "\uE74D"),
        new("Find", "\uE721"), new("Combine", "\uE8F1"),
    ];

    public static Entry Group(string id) => Bar.First(e => e?.Id == id)!;

    /// <summary>Every command the bar reaches, on the bar or in a group or the overflow (the drawing tools aside).</summary>
    public static IEnumerable<string> AllCommands =>
        Bar.OfType<Entry>().SelectMany(e => e.Commands).Concat(Secondary).Select(c => c.Name);

    // ── Fitting ──

    /// <summary>A child of the bar: its width with its label and without, its priority; or a separator.</summary>
    public readonly record struct Item(double Full, double Compact, int Priority, bool IsSeparator = false);

    /// <summary>What shows: labels or icons only, each child, and the overflow button.</summary>
    public sealed record Fit(bool Compact, bool[] Shown, bool MoreShown);

    /// <summary>
    /// Lays the bar out in <paramref name="available"/> width: with labels, dropping the lowest priority into the
    /// overflow until it fits; icons-only instead when that would drop a command of priority
    /// <paramref name="keepsLabels"/> or more. A separator shows only between two shown commands, never two in a row.
    /// The overflow button (<paramref name="more"/> wide) shows when something overflowed or <paramref name="moreAlways"/>.
    /// </summary>
    public static Fit Layout(IReadOnlyList<Item> items, double available, double more, bool moreAlways = false, int keepsLabels = int.MinValue)
    {
        var labeled = Place(items, available, more, moreAlways, compact: false);
        var dropsKey = items.Where((it, i) => !it.IsSeparator && !labeled[i] && it.Priority >= keepsLabels).Any();
        var compact = dropsKey && items.Any(it => !it.IsSeparator && it.Compact < it.Full);
        var shown = compact ? Place(items, available, more, moreAlways, compact: true) : labeled;
        var hidden = items.Where((it, i) => !it.IsSeparator && !shown[i]).Any();
        return new Fit(compact, shown, hidden || moreAlways);
    }

    private static bool[] Place(IReadOnlyList<Item> items, double available, double more, bool moreAlways, bool compact)
    {
        var shown = items.Select(it => !it.IsSeparator).ToArray();
        while (true)
        {
            ShowSeparators(items, shown);
            var hidden = items.Where((it, i) => !it.IsSeparator && !shown[i]).Any();
            var width = items.Where((_, i) => shown[i]).Sum(it => compact ? it.Compact : it.Full) + (hidden || moreAlways ? more : 0);
            if (width <= available) return shown;
            var drop = -1;
            for (var i = 0; i < items.Count; i++)
                if (!items[i].IsSeparator && shown[i] && (drop < 0 || items[i].Priority <= items[drop].Priority)) drop = i;
            if (drop < 0) return shown;
            shown[drop] = false;
        }
    }

    private static void ShowSeparators(IReadOnlyList<Item> items, bool[] shown)
    {
        var any = false;
        var pending = -1;
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].IsSeparator)
            {
                shown[i] = false;
                if (any) pending = i;
            }
            else if (shown[i])
            {
                if (pending >= 0) shown[pending] = true;
                pending = -1;
                any = true;
            }
        }
    }
}
