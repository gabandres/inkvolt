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
    public static IReadOnlyList<string> Sections =>
        [CoreStrings.Palette_Overview, CoreStrings.Palette_Print, CoreStrings.Palette_Scan, CoreStrings.Palette_Copy, CoreStrings.Palette_Photos, CoreStrings.Palette_PrinterSettings];

    /// <summary>"Go to …" for each of <see cref="Sections"/>.</summary>
    private static string GoTo(int section) => section switch
    {
        0 => CoreStrings.Palette_GoToOverview,
        1 => CoreStrings.Palette_GoToPrint,
        2 => CoreStrings.Palette_GoToScan,
        3 => CoreStrings.Palette_GoToCopy,
        4 => CoreStrings.Palette_GoToPhotos,
        _ => CoreStrings.Palette_GoToPrinterSettings,
    };

    /// <summary>The printer menu's commands, in its order, as far as <paramref name="p"/> offers them: (id after "printer:", name, glyph).</summary>
    private static IEnumerable<(string Id, string Name, string Glyph)> Menu(Printer p)
    {
        yield return ("reconnect", CoreStrings.Palette_Reconnect, "\uE72C");
        if (p.CanPrint) yield return ("photos", CoreStrings.Palette_PrintPhotos, "\uEB9F");
        if (p.CanPrint) yield return ("batch", CoreStrings.Palette_BatchPrint, "\uE8A9");
        if (p.CanFix) yield return ("fix", CoreStrings.Palette_FixProblems, "\uE90F");
        if (p.IsNetwork) yield return ("maintenance", CoreStrings.Palette_Maintenance, "\uE90F");
        if (p.SnmpAccess) yield return ("snmp", CoreStrings.Palette_SnmpAccess, "\uE72E");
        yield return ("remove", CoreStrings.Palette_Remove, "\uE74D");
    }

    /// <summary>Every command the printer menu can have (the ids after "printer:").</summary>
    public static readonly IReadOnlySet<string> MenuIds = new HashSet<string> { "reconnect", "photos", "batch", "fix", "maintenance", "snmp", "remove" };

    /// <summary>The category of another printer's menu commands ("Name: command" entries, id "on:index:command").</summary>
    public static string OtherPrinters => CoreStrings.Palette_OtherPrinters;

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
            if (p.CanPrint) list.Add(new("printer:print", CoreStrings.Palette_PrintPdf, category, "", "\uE749"));
            if (p.CanScan) list.Add(new("printer:scan", CoreStrings.Palette_Scan, category, "", "\uE8FE"));
            if (p.NeedsSetup) list.Add(new("printer:setup", CoreStrings.Palette_SetUpInWindows, category, "", "\uE946"));
            bool[] has = [true, p.CanPrint, p.CanScan, p.CanCopy, p.CanPrint, p.HasSettings];
            for (var i = 0; i < Sections.Count; i++)
                if (has[i]) list.Add(new($"section:{i}", GoTo(i), category, "", "\uE8A7"));
            foreach (var (id, name, glyph) in Menu(p)) list.Add(new($"printer:{id}", name, category, "", glyph));
        }
        list.Add(new("app:add", CoreStrings.Palette_AddPrinter, "", "", "\uE710"));
        list.Add(new("app:fleet", CoreStrings.Palette_Fleet, "", "", "\uE8A9"));
        list.Add(new("app:search", CoreStrings.Palette_SearchAgain, "", "", "\uE72C"));
        list.Add(new("app:settings", CoreStrings.Palette_Settings, "", "", "\uE713"));
        list.Add(new("app:help", CoreStrings.Palette_Help, "", "F1", "\uE897"));
        list.Add(new("app:whatsnew", CoreStrings.Palette_WhatsNew, "", "", "\uE789"));
        list.Add(new("app:report", CoreStrings.Palette_ReportProblem, "", "", "\uE8BD"));
        list.Add(new("app:about", CoreStrings.Palette_About, "", "", "\uE946"));
        for (var i = 0; i < printers.Count; i++)
            if (i != selectedIndex) list.Add(new($"show:{i}", string.Format(CoreStrings.Palette_Show, printers[i]), CoreStrings.Palette_Printers, "", "\uE749"));
        if (every is not null)
            for (var i = 0; i < every.Count; i++)
                if (i != selectedIndex)
                    foreach (var (id, name, glyph) in Menu(every[i]))
                        list.Add(new($"on:{i}:{id}", $"{every[i].Name}: {name}", OtherPrinters, "", glyph));
        if (selected is { CanScan: true })
            for (var i = 0; i < presets.Count; i++)
                list.Add(new($"preset:{i}", string.Format(CoreStrings.Palette_ScanWith, presets[i]), CoreStrings.Palette_ScanPresets, i < 9 ? $"Ctrl+{i + 1}" : "", "\uE8FE"));
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
        return string.Format(CoreStrings.Palette_NoMatch, shown);
    }
}
