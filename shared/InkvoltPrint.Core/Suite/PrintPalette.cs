namespace InkvoltPrint.Core.Suite;

/// <summary>
/// Inkvolt Print's command palette (Ctrl+K), the same as Inkvolt PDF's: every command of the sidebar, the printer's
/// header buttons, sections and menu, then each printer to switch to and each scan preset to run, so everything is a
/// few keys away without the mouse. <see cref="Build"/> lists what applies right now (a section the printer doesn't
/// have isn't offered); the app runs an entry by its <see cref="Entry.Id"/>.
/// </summary>
public static class PrintPalette
{
    /// <summary>One line of the palette. <see cref="Id"/>: "app:…", "section:n", "printer:…", "show:n" (a printer), "preset:n".</summary>
    public sealed record Entry(string Id, string Name, string Category, string Gesture, string Glyph);

    /// <summary>What the selected printer offers (null: no printer selected).</summary>
    public sealed record Printer(string Name, bool CanPrint, bool CanScan, bool CanCopy, bool HasSettings, bool NeedsSetup,
        bool CanFix, bool IsNetwork, bool SnmpAccess = false);

    /// <summary>The sections, in the tabs' order (the indexes are PrinterViewModel's).</summary>
    public static readonly IReadOnlyList<string> Sections = ["Overview", "Print", "Scan", "Copy", "Photos", "Printer settings"];

    /// <summary>The printer menu's commands, in its order, as far as <paramref name="p"/> offers them: (id after "printer:", name, glyph).</summary>
    private static IEnumerable<(string Id, string Name, string Glyph)> Menu(Printer p)
    {
        yield return ("reconnect", "Reconnect", "\uE72C");
        if (p.CanPrint) yield return ("photos", "Print photos…", "\uEB9F");
        if (p.CanPrint) yield return ("batch", "Batch print: many files…", "\uE8A9");
        if (p.CanFix) yield return ("fix", "Fix printing problems…", "\uE90F");
        if (p.IsNetwork) yield return ("maintenance", "Printer maintenance…", "\uE90F");
        if (p.SnmpAccess) yield return ("snmp", "SNMP access…", "\uE72E");
        yield return ("remove", "Remove from Inkvolt Print…", "\uE74D");
    }

    /// <summary>Every command the printer menu can have (the ids after "printer:").</summary>
    public static readonly IReadOnlySet<string> MenuIds = new HashSet<string> { "reconnect", "photos", "batch", "fix", "maintenance", "snmp", "remove" };

    /// <summary>The category of another printer's menu commands ("Name: command" entries, id "on:index:command").</summary>
    public const string OtherPrinters = "Other printers";

    /// <summary>
    /// The palette's entries: the selected printer's (<paramref name="selectedIndex"/> in <paramref name="printers"/>, -1 for none), the app's, the other
    /// printers, the scan presets; and, given <paramref name="every"/> (each printer's offer, in <paramref name="printers"/>' order), every other
    /// printer's menu commands as "Name: command", run on that printer without showing it first. Those wait for a word typed
    /// (<see cref="ShownWhenEmpty"/>), so the list Ctrl+K opens on stays as short as before.
    /// </summary>
    public static List<Entry> Build(Printer? selected, int selectedIndex, IReadOnlyList<string> printers, IReadOnlyList<string> presets,
        IReadOnlyList<Printer>? every = null)
    {
        var list = new List<Entry>();
        if (selected is { } p)
        {
            var category = p.Name;
            if (p.CanPrint) list.Add(new("printer:print", "Print a PDF…", category, "", "\uE749"));
            if (p.CanScan) list.Add(new("printer:scan", "Scan", category, "", "\uE8FE"));
            if (p.NeedsSetup) list.Add(new("printer:setup", "Set up in Windows", category, "", "\uE946"));
            bool[] has = [true, p.CanPrint, p.CanScan, p.CanCopy, p.CanPrint, p.HasSettings];
            for (var i = 0; i < Sections.Count; i++)
                if (has[i]) list.Add(new($"section:{i}", $"Go to {Sections[i]}", category, "", "\uE8A7"));
            foreach (var (id, name, glyph) in Menu(p)) list.Add(new($"printer:{id}", name, category, "", glyph));
        }
        list.Add(new("app:add", "Add a printer…", "", "", "\uE710"));
        list.Add(new("app:fleet", "Show the Fleet page (every printer)", "", "", "\uE8A9"));
        list.Add(new("app:search", "Search again for printers", "", "", "\uE72C"));
        list.Add(new("app:settings", "Settings", "", "", "\uE713"));
        list.Add(new("app:help", "Help and shortcuts", "", "F1", "\uE897"));
        list.Add(new("app:whatsnew", "What's new", "", "", "\uE789"));
        list.Add(new("app:report", "Report a problem…", "", "", "\uE8BD"));
        list.Add(new("app:about", "About Inkvolt Print", "", "", "\uE946"));
        for (var i = 0; i < printers.Count; i++)
            if (i != selectedIndex) list.Add(new($"show:{i}", $"Show {printers[i]}", "Printers", "", "\uE749"));
        if (every is not null)
            for (var i = 0; i < every.Count; i++)
                if (i != selectedIndex)
                    foreach (var (id, name, glyph) in Menu(every[i]))
                        list.Add(new($"on:{i}:{id}", $"{every[i].Name}: {name}", OtherPrinters, "", glyph));
        if (selected is { CanScan: true })
            for (var i = 0; i < presets.Count; i++)
                list.Add(new($"preset:{i}", $"Scan with {presets[i]}", "Scan presets", i < 9 ? $"Ctrl+{i + 1}" : "", "\uE8FE"));
        return list;
    }

    /// <summary>Listed before anything is typed: everything but other printers' commands.</summary>
    public static bool ShownWhenEmpty(Entry e) => !e.Id.StartsWith("on:", StringComparison.Ordinal);

    /// <summary>"on:index:command": which printer and which of its menu commands; null for any other id.</summary>
    public static (int Index, string Command)? OnOther(string id)
    {
        var parts = id.Split(':');
        return parts is ["on", var n, var command] && int.TryParse(n, out var index) && index >= 0 && MenuIds.Contains(command) ? (index, command) : null;
    }

    /// <summary>The palette's words when nothing matches: what to try next.</summary>
    public static string NoMatch(string query)
    {
        var q = query.Trim();
        var shown = q.Length > 40 ? q[..40] + "…" : q;
        return $"Nothing matches “{shown}”. Try another word, a printer's name or a scan preset.";
    }
}
