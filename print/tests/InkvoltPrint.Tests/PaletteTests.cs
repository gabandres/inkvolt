using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>The command palette both apps share (PaletteSearch), Inkvolt Print's list (PrintPalette), and the sidebar's fold (NavPane).</summary>
public class PaletteTests
{
    private static readonly PrintPalette.Printer Mfp = new("HP LaserJet MFP M234dw", CanPrint: true, CanScan: true, CanCopy: true,
        HasSettings: true, NeedsSetup: false, CanFix: true, IsNetwork: true);

    private static List<PrintPalette.Entry> Build(PrintPalette.Printer? selected = null, int index = 0) =>
        PrintPalette.Build(selected, selected is null ? -1 : index, ["HP LaserJet MFP M234dw", "Demo inkjet", "Front desk"], ["Document to PDF", "Photo", "Receipt"]);

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

    [Fact]
    public void EveryEntryHasAnIcon() =>
        Assert.All(Build(Mfp), e => Assert.True(e.Glyph.Length == 1 && char.GetUnicodeCategory(e.Glyph[0]) == System.Globalization.UnicodeCategory.PrivateUse, e.Name));

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
