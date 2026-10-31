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
        bool CanFix, bool IsNetwork);

    /// <summary>The sections, in the tabs' order (the indexes are PrinterViewModel's).</summary>
    public static readonly IReadOnlyList<string> Sections = ["Overview", "Print", "Scan", "Copy", "Photos", "Printer settings"];

    /// <summary>The palette's entries: the selected printer's (<paramref name="selectedIndex"/> in <paramref name="printers"/>, -1 for none), the app's, the other printers, the scan presets.</summary>
    public static List<Entry> Build(Printer? selected, int selectedIndex, IReadOnlyList<string> printers, IReadOnlyList<string> presets)
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
            list.Add(new("printer:reconnect", "Reconnect", category, "", "\uE72C"));
            if (p.CanPrint) list.Add(new("printer:photos", "Print photos…", category, "", "\uEB9F"));
            if (p.CanFix) list.Add(new("printer:fix", "Fix printing problems…", category, "", "\uE90F"));
            if (p.IsNetwork) list.Add(new("printer:maintenance", "Printer maintenance…", category, "", "\uE90F"));
            list.Add(new("printer:remove", "Remove from Inkvolt Print…", category, "", "\uE74D"));
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
        if (selected is { CanScan: true })
            for (var i = 0; i < presets.Count; i++)
                list.Add(new($"preset:{i}", $"Scan with {presets[i]}", "Scan presets", i < 9 ? $"Ctrl+{i + 1}" : "", "\uE8FE"));
        return list;
    }

    /// <summary>The palette's words when nothing matches: what to try next.</summary>
    public static string NoMatch(string query)
    {
        var q = query.Trim();
        var shown = q.Length > 40 ? q[..40] + "…" : q;
        return $"Nothing matches “{shown}”. Try another word, a printer's name or a scan preset.";
    }
}
