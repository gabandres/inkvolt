using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>The command palette both apps share (PaletteSearch), Inkvolt Print's list (PrintPalette), and the sidebar's fold (NavPane).</summary>
public class PaletteTests
{
    private static readonly PrintPalette.Printer Mfp = new("HP LaserJet MFP M234dw", CanPrint: true, CanScan: true, CanCopy: true,
        HasSettings: true, NeedsSetup: false, CanFix: true, IsNetwork: true);

    private static List<PrintPalette.Entry> Build(PrintPalette.Printer? selected = null, int index = 0) =>
        PrintPalette.Build(selected, selected is null ? -1 : index, ["HP LaserJet MFP M234dw", "Demo inkjet", "Front desk"], ["Document to PDF", "Photo", "Receipt"]);

    [Fact]
    public void AnEntryKeepsMeaningThePrinterItNamed_WhenTheListMoves()
    {
        string a = "A", b = "B", c = "C";
        IReadOnlyList<string> built = [a, b, c];

        Assert.Same(b, PrintPalette.Target(1, built, [a, b, c]));
        Assert.Same(b, PrintPalette.Target(1, built, [c, a, b])); // a new one sorted in, or the order changed
        Assert.Null(PrintPalette.Target(1, built, [a, c])); // removed meanwhile: nothing runs, not the next one's command
        Assert.Null(PrintPalette.Target(3, built, [a, b, c]));
        Assert.Null(PrintPalette.Target(-1, built, [a, b, c]));
    }

    // ── The list ──

    [Fact]
    public void EveryCommandOfTheSidebarHeaderTabsAndMenuIsListed()
    {
        var names = Build(Mfp).Select(e => e.Name).ToList();
        // Sidebar
        Assert.Contains("Add a printer…", names);
        Assert.Contains("Settings", names);
        Assert.Contains("Help and shortcuts", names);
        Assert.Contains("About Inkvolt Print", names);
        Assert.Contains("Search again for printers", names);
        // The printer's header buttons and sections
        Assert.Contains("Print a PDF…", names);
        Assert.Contains("Scan", names);
        Assert.Equal(["Go to Overview", "Go to Print", "Go to Scan", "Go to Copy", "Go to Photos", "Go to Printer settings"], names.Where(n => n.StartsWith("Go to ")));
        // Its menu
        Assert.Contains("Reconnect", names);
        Assert.Contains("Print photos…", names);
        Assert.Contains("Fix printing problems…", names);
        Assert.Contains("Printer maintenance…", names);
        Assert.Contains("Remove from Inkvolt Print…", names);
        Assert.Equal(names.Count, Build(Mfp).Select(e => e.Id).Distinct().Count());
    }

    [Fact]
    public void OnlyWhatThePrinterOffers()
    {
        var scannerOnly = new PrintPalette.Printer("Photo Scanner", CanPrint: false, CanScan: true, CanCopy: false, HasSettings: false,
            NeedsSetup: false, CanFix: false, IsNetwork: false);
        var names = Build(scannerOnly).Select(e => e.Name).ToList();
        Assert.DoesNotContain("Print a PDF…", names);
        Assert.DoesNotContain("Go to Print", names);
        Assert.DoesNotContain("Go to Photos", names);
        Assert.DoesNotContain("Fix printing problems…", names);
        Assert.Equal(["Go to Overview", "Go to Scan"], names.Where(n => n.StartsWith("Go to ")));
        Assert.Contains(Build(Mfp with { NeedsSetup = true }), e => e.Name == "Set up in Windows");
    }

    [Fact]
    public void TheOtherPrintersAndTheScanPresetsWithTheirShortcuts()
    {
        var list = Build(Mfp);
        Assert.Equal(["Show Demo inkjet", "Show Front desk"], list.Where(e => e.Category == "Printers").Select(e => e.Name));
        Assert.Equal(["show:1", "show:2"], list.Where(e => e.Category == "Printers").Select(e => e.Id));
        var presets = list.Where(e => e.Category == "Scan presets").ToList();
        Assert.Equal(["Scan with Document to PDF", "Scan with Photo", "Scan with Receipt"], presets.Select(e => e.Name));
        Assert.Equal(["Ctrl+1", "Ctrl+2", "Ctrl+3"], presets.Select(e => e.Gesture));
        // A printer that can't scan has no presets to run.
        Assert.DoesNotContain(Build(Mfp with { CanScan = false }), e => e.Category == "Scan presets");
    }

    [Fact]
    public void WithoutAPrinterTheAppCommandsAndEveryPrinter()
    {
        var list = Build();
        Assert.DoesNotContain(list, e => e.Id.StartsWith("printer:") || e.Id.StartsWith("section:") || e.Id.StartsWith("preset:"));
        Assert.Equal(3, list.Count(e => e.Category == "Printers"));
        Assert.Contains(list, e => e.Id == "app:add");
    }

    // ── Another printer's menu, without showing it first ──

    private static readonly PrintPalette.Printer Inkjet = new("Demo inkjet", CanPrint: true, CanScan: true, CanCopy: true,
        HasSettings: false, NeedsSetup: false, CanFix: true, IsNetwork: true, SnmpAccess: false);

    private static readonly PrintPalette.Printer FrontDesk = new("Front desk", CanPrint: true, CanScan: false, CanCopy: false,
        HasSettings: false, NeedsSetup: false, CanFix: true, IsNetwork: false);

    private static List<PrintPalette.Entry> BuildAll(int selected = 0) =>
        PrintPalette.Build(selected < 0 ? null : new[] { Mfp, Inkjet, FrontDesk }[selected], selected,
            ["HP LaserJet MFP M234dw", "Demo inkjet", "Front desk"], ["Document to PDF"], [Mfp, Inkjet, FrontDesk]);

    [Fact]
    public void Another_printers_menu_commands_are_entries_of_their_own()
    {
        var other = BuildAll().Where(e => e.Id.StartsWith("on:")).ToList();
        Assert.Equal(
            ["Demo inkjet: Reconnect", "Demo inkjet: Print photos…", "Demo inkjet: Batch print: many files…", "Demo inkjet: Fix printing problems…",
             "Demo inkjet: Printer maintenance…", "Demo inkjet: Remove from Inkvolt Print…",
             "Front desk: Reconnect", "Front desk: Print photos…", "Front desk: Batch print: many files…", "Front desk: Fix printing problems…",
             "Front desk: Remove from Inkvolt Print…"],
            other.Select(e => e.Name));
        Assert.Equal(["on:1:reconnect", "on:1:photos", "on:1:batch", "on:1:fix", "on:1:maintenance", "on:1:remove"], other.Take(6).Select(e => e.Id));
        Assert.All(other, e => Assert.Equal("Other printers", e.Category));
        Assert.DoesNotContain(other, e => e.Name.StartsWith("HP LaserJet")); // the selected printer's are its plain entries
        // The same commands as the selected printer's menu, and what the printer offers only.
        Assert.Equal(BuildAll(1).Where(e => e.Id.StartsWith("printer:") && e.Category == "Demo inkjet" && PrintPalette.MenuIds.Contains(e.Id[8..])).Select(e => e.Name),
            other.Take(6).Select(e => e.Name["Demo inkjet: ".Length..]));
        Assert.Equal(BuildAll().Count(e => e.Id.StartsWith("on:")), BuildAll().Where(e => e.Id.StartsWith("on:")).Select(e => e.Id).Distinct().Count());
    }

    [Fact]
    public void They_wait_for_a_word_so_the_list_stays_short()
    {
        var all = BuildAll();
        var empty = PaletteSearch.Filter(all, "", e => e.Name, e => e.Category, showWhenEmpty: PrintPalette.ShownWhenEmpty);
        Assert.DoesNotContain(empty, e => e.Id.StartsWith("on:"));
        Assert.Equal(all.Count(e => !e.Id.StartsWith("on:")), empty.Count);

        var fix = PaletteSearch.Filter(all, "front fix", e => e.Name, e => e.Category, showWhenEmpty: PrintPalette.ShownWhenEmpty);
        Assert.Equal("on:2:fix", fix[0].Id);
        Assert.Single(fix);
        var inkjet = PaletteSearch.Filter(all, "inkjet maint", e => e.Name, e => e.Category, showWhenEmpty: PrintPalette.ShownWhenEmpty);
        Assert.Equal("on:1:maintenance", Assert.Single(inkjet).Id);
    }

    [Fact]
    public void An_entry_for_another_printer_names_which_and_what()
    {
        Assert.Equal((1, "fix"), PrintPalette.OnOther("on:1:fix"));
        Assert.Null(PrintPalette.OnOther("printer:fix"));
        Assert.Null(PrintPalette.OnOther("on:x:fix"));
        Assert.Null(PrintPalette.OnOther("on:1:"));
    }

    [Fact]
    public void Without_the_printers_details_only_Show_entries_as_before() =>
        Assert.DoesNotContain(Build(Mfp), e => e.Id.StartsWith("on:"));

    [Fact]
    public void EveryEntryHasAnIcon() =>
        Assert.All(BuildAll(), e => Assert.True(e.Glyph.Length == 1 && char.GetUnicodeCategory(e.Glyph[0]) == System.Globalization.UnicodeCategory.PrivateUse, e.Name));

    [Fact]
    public void NothingMatchesSaysWhatToTry()
    {
        Assert.Equal("Nothing matches “zzz”. Try another word, a printer's name or a scan preset.", PrintPalette.NoMatch(" zzz "));
        Assert.Contains(new string('x', 40) + "…", PrintPalette.NoMatch(new string('x', 80)));
    }

    // ── Matching (both apps) ──

    [Fact]
    public void ANameStartingWithTheWordRanksFirst()
    {
        var result = PaletteSearch.Filter(Build(Mfp), "scan", e => e.Name, e => e.Category);
        Assert.Equal("Scan", result[0].Name);
        Assert.Contains(result, e => e.Name == "Go to Scan");
        Assert.Contains(result, e => e.Name == "Scan with Photo");
        Assert.DoesNotContain(result, e => e.Name == "Settings");
    }

    [Fact]
    public void EveryWordMustMatchInTheNameOrCategory()
    {
        var result = PaletteSearch.Filter(Build(Mfp), "presets receipt", e => e.Name, e => e.Category);
        Assert.Equal(["Scan with Receipt"], result.Select(e => e.Name));
        Assert.Empty(PaletteSearch.Filter(Build(Mfp), "scan zebra", e => e.Name, e => e.Category));
    }

    [Fact]
    public void NothingTypedListsTheFirstOnesShownWhenEmpty()
    {
        string[] items = ["Open", "recent.pdf", "Save"];
        Assert.Equal(["Open", "Save"], PaletteSearch.Filter(items, "  ", i => i, _ => "", showWhenEmpty: i => !i.EndsWith(".pdf")));
        Assert.Equal(["Open"], PaletteSearch.Filter(items, "", i => i, _ => "", max: 1));
    }

    [Fact]
    public void ACommandOutranksAFileOnATie()
    {
        string[] items = ["report.pdf", "Report a problem"];
        var result = PaletteSearch.Filter(items, "report", i => i, _ => "", isCommand: i => !i.EndsWith(".pdf"));
        Assert.Equal("Report a problem", result[0]);
    }

    [Fact]
    public void ScoresStartOfNameOverStartOfWordOverInside()
    {
        Assert.True(PaletteSearch.Score("Scan", "", ["sc"]) > PaletteSearch.Score("Go to Scan", "", ["sc"]));
        Assert.True(PaletteSearch.Score("Go to Scan", "", ["sc"]) > PaletteSearch.Score("Rescan", "", ["sc"]));
        Assert.Equal(0, PaletteSearch.Score("Scan", "", ["print"]));
    }

    // ── The sidebar ──

    [Theory]
    [InlineData(1180, 1.0, false)] // the default window
    [InlineData(860, 1.0, false)] // the window's minimum width: never folded at 100 %
    [InlineData(1180, 1.25, false)]
    [InlineData(1180, 1.5, true)] // 787 DIPs of room
    [InlineData(1920, 2.0, false)] // a wide window keeps it even at 200 %
    [InlineData(1366, 2.25, true)]
    public void TheSidebarFoldsWhenThePageWouldBeTooNarrow(double window, double textSize, bool folds) =>
        Assert.Equal(folds, NavPane.Folds(window / textSize));
}
