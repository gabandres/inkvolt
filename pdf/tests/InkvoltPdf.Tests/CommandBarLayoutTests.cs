using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using Item = InkvoltPdf.Core.CommandBarLayout.Item;

namespace InkvoltPdf.Tests;

public class CommandBarLayoutTests
{
    // ── The table ──

    [Fact]
    public void TheOldBarsCommandsAreAllStillReached()
    {
        // The twenty-odd icons of the bar before the groups (the drawing tools: Comment's Draw submenu), each once.
        string[] before =
        [
            "Save", "Print", "Undo", "Redo", "ToolHand", "ToolSelect", "ToolSnapshot", "ToolAddText", "ToolCheck", "ToolCross",
            "AddSignature", "Highlight", "AddNote", "AddImage", "ToolLink", "AddStamp", "Redact", "Organize", "RotateLeft",
            "RotateRight", "DeleteSelected", "Find", "Combine",
        ];
        var now = CommandBarLayout.AllCommands.ToList();
        Assert.Empty(before.Except(now));
        Assert.Equal(now.Count, now.Distinct().Count());
        Assert.Equal("Comment", CommandBarLayout.DrawsIn);
    }

    [Fact]
    public void TheGroupsComeInTheOrderOtherPdfEditorsUse()
    {
        // docs/design/command-bar.md: Edit and Convert first (Acrobat's top bar, Nitro's and Foxit's tabs), then Comment
        // and Fill & Sign, the pages, Protect (with Redact), Scan & OCR.
        var entries = CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().ToList();
        Assert.All(entries.Where(e => e.Label is null), e => Assert.Contains(e.Id, new[] { "Save", "Print", "Undo", "Redo" }));
        Assert.Equal(["Select", "Edit", "Convert", "Comment", "Fill & Sign", "Organize", "Protect", "Scan & OCR"],
            entries.Where(e => e.Label is not null).Select(e => e.Label));
        Assert.All(entries.Where(e => e.Label is not null), e => Assert.True(e.IsGroup, e.Id));
        Assert.All(CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().SelectMany(e => e.Commands).Concat(CommandBarLayout.Secondary),
            c => Assert.True(c.Glyph.Length == 1 && char.GetUnicodeCategory(c.Glyph[0]) == System.Globalization.UnicodeCategory.PrivateUse, c.Name));
    }

    [Fact]
    public void EachGroupLeadsWithItsMainJob()
    {
        // The first command of a group is the one its click will run (docs/design/command-bar.md, "One click").
        Assert.Equal(
            ["ToolHand", "EditContent", "ConvertWord", "Highlight", "AddSignature", "Organize", "ProtectPassword", "RecognizeText"],
            CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().Where(e => e.IsGroup).Select(e => e.Commands[0].Name));
        // Convert's flyout names the format ("Word (.docx)"), not the command ("Convert to Word"), and asks first only
        // where the name ends with "…".
        var convert = CommandBarLayout.Group("Convert").Commands;
        Assert.All(convert, c => Assert.False(string.IsNullOrEmpty(c.Title), c.Name));
        Assert.Equal(["ConvertWord"], convert.Where(c => !c.Title!.EndsWith('…')).Select(c => c.Name));
    }

    [Fact]
    public void EveryBarCommandIsInTheMenusSoThePaletteListsIt()
    {
        // The palette is built from the main menu (MainWindow.BuildPaletteItems); the drawing tools fill Review › Draw in code.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var xaml = File.ReadAllText(Path.Combine(dir.FullName, "pdf", "src", "InkvoltPdf.App", "MainWindow.xaml"));
        var menu = xaml[xaml.IndexOf("<Menu x:Name=\"MainMenu\"", StringComparison.Ordinal)..xaml.IndexOf("</Menu>", StringComparison.Ordinal)];
        var inMenu = Regex.Matches(menu, "Command=\"app:Cmd\\.(\\w+)\"").Select(m => m.Groups[1].Value).ToHashSet();
        var missing = CommandBarLayout.AllCommands.Where(c => !inMenu.Contains(c)).ToList();
        Assert.True(missing.Count == 0, $"Not in the menus: {string.Join(", ", missing)}");
    }

    [Fact]
    public void EachCommandOfAGroupSaysInALineWhatItDoes()
    {
        // The line under its name in the group's flyout: a few plain words, one line, no period, none twice.
        var commands = CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().Where(e => e.IsGroup).SelectMany(e => e.Commands).ToList();
        Assert.All(commands, c =>
        {
            Assert.InRange(c.Description.Length, 12, 50);
            Assert.True(char.IsUpper(c.Description[0]) && !c.Description.EndsWith('.') && !c.Description.Contains('\n'), c.Name);
        });
        Assert.Equal(commands.Count, commands.Select(c => c.Description).Distinct().Count());
        // At Text size 150 % a 1200-DIP window is 800 logical DIPs: short of room; at 100 % it isn't.
        Assert.InRange(CommandBarLayout.RoomyWidth, 800 + 1, 1200);
    }

    // ── Fitting ──

    private static Item Cmd(double full, int priority, double? compact = null) => new(full, compact ?? full, priority);
    private static readonly Item Sep = new(13, 13, 0, IsSeparator: true);

    [Fact]
    public void EverythingFitsWithLabels()
    {
        var fit = CommandBarLayout.Layout([Cmd(34, 100), Sep, Cmd(100, 90), Cmd(90, 80)], 400, 34);
        Assert.False(fit.Compact);
        Assert.Equal([true, true, true, true], fit.Shown);
        Assert.False(fit.MoreShown);
    }

    [Fact]
    public void TheLowestPriorityOverflowsFirstAndTheLaterOnATie()
    {
        // 34 + 13 + 100 + 90 + 80 = 317; with "…" (34) only 250 fits.
        var fit = CommandBarLayout.Layout([Cmd(34, 100), Sep, Cmd(100, 90), Cmd(90, 50), Cmd(80, 50)], 250, 34);
        Assert.Equal([true, true, true, false, false], fit.Shown);
        Assert.True(fit.MoreShown);
        var tie = CommandBarLayout.Layout([Cmd(34, 100), Sep, Cmd(100, 90), Cmd(90, 50), Cmd(80, 50)], 300, 34);
        Assert.Equal([true, true, true, true, false], tie.Shown);
    }

    [Fact]
    public void ALowPriorityGroupInTheMiddleGoesBeforeLaterOnes()
    {
        // Save | Pointer(40) | Fill & Sign(90): the pointer group goes, and its separators with it, but one stays between the rest.
        var fit = CommandBarLayout.Layout([Cmd(34, 100), Sep, Cmd(100, 40), Sep, Cmd(120, 90)], 34 + 13 + 120 + 34, 34);
        Assert.Equal([true, false, false, true, true], fit.Shown);
    }

    [Fact]
    public void SeparatorsNeverLeadTrailOrDouble()
    {
        var fit = CommandBarLayout.Layout([Sep, Cmd(34, 100), Sep, Sep, Cmd(34, 100), Sep], 500, 34);
        Assert.Equal([false, true, false, true, true, false], fit.Shown);
    }

    [Fact]
    public void LabelsStayWhileOnlyMinorCommandsOverflow()
    {
        // Losing a priority-60 command keeps the labels when the bar keeps labels from 80.
        var fit = CommandBarLayout.Layout([Cmd(34, 100), Cmd(110, 90, 50), Cmd(100, 60, 50)], 34 + 110 + 34, 34, keepsLabels: 80);
        Assert.False(fit.Compact);
        Assert.Equal([true, true, false], fit.Shown);
    }

    [Fact]
    public void IconsOnlyWhenAKeyCommandWouldOverflow()
    {
        var fit = CommandBarLayout.Layout([Cmd(34, 100), Cmd(110, 90, 50), Cmd(100, 60, 50)], 34 + 50 + 50 + 10, 34, keepsLabels: 80);
        Assert.True(fit.Compact);
        Assert.Equal([true, true, true], fit.Shown);
        Assert.False(fit.MoreShown);
    }

    [Fact]
    public void WithoutAKeepsLabelsPriorityAnyOverflowGoesIconsOnlyFirst()
    {
        // Organize's page actions: all labeled, equal priority; as before, labels go before any action overflows.
        var fit = CommandBarLayout.Layout([Cmd(100, 0, 40), Cmd(100, 0, 40), Cmd(100, 0, 40)], 200, 34);
        Assert.True(fit.Compact);
        Assert.Equal([true, true, true], fit.Shown);
    }

    [Fact]
    public void TheOverflowButtonShowsAlwaysWhenItHasCommandsOfItsOwn()
    {
        var fit = CommandBarLayout.Layout([Cmd(34, 100)], 100, 34, moreAlways: true);
        Assert.True(fit.MoreShown);
        Assert.Equal([true], fit.Shown);
        var tight = CommandBarLayout.Layout([Cmd(34, 100), Cmd(34, 100)], 70, 34, moreAlways: true);
        Assert.Equal([true, false], tight.Shown);
    }

    // The bar's own table with its children's widths as measured in the app at 100 % (barstate, plus the buttons' 1-DIP
    // margins): icons 36, groups 52 as icons; separators 13. The room is what the bar has beside the menus and the
    // Commands button in a window of that width (under 1100 the Commands button keeps only its icon).
    private static readonly Dictionary<string, (double Full, double Compact)> English = new()
    {
        ["Save"] = (36, 36), ["Print"] = (36, 36), ["Undo"] = (36, 36), ["Redo"] = (36, 36), ["Pointer"] = (52, 52),
        ["Edit"] = (83, 52), ["Convert"] = (108, 52), ["Comment"] = (121, 52), ["FillSign"] = (123, 52),
        ["Organize"] = (116, 52), ["Protect"] = (104, 52), ["ScanOcr"] = (135, 52),
    };

    private static (bool Compact, string[] Shown) FitBar(Dictionary<string, (double Full, double Compact)> widths, double room)
    {
        var items = CommandBarLayout.Bar.Select(e => e is null ? Sep : Cmd(widths[e.Id].Full, e.Priority, widths[e.Id].Compact)).ToList();
        var fit = CommandBarLayout.Layout(items, room, 36, moreAlways: true, keepsLabels: CommandBarLayout.KeepsLabels);
        return (fit.Compact, [.. CommandBarLayout.Bar.Where((e, i) => e is not null && fit.Shown[i]).Select(e => e!.Id)]);
    }

    [Fact]
    public void At1700DipsEveryGroupShowsWithItsLabel()
    {
        // Redo (Ctrl+Y, Edit › Redo) is the first to give way.
        var (compact, shown) = FitBar(English, 1034);
        Assert.False(compact);
        Assert.Equal(["Save", "Print", "Undo", "Pointer", "Edit", "Convert", "Comment", "FillSign", "Organize", "Protect", "ScanOcr"], shown);
    }

    [Fact]
    public void At1280DipsTheFiveCommonGroupsKeepTheirLabels()
    {
        // Print and Redo, then Scan & OCR, Protect and Organize go into "…" before any label does.
        var (compact, shown) = FitBar(English, 632);
        Assert.False(compact);
        Assert.Equal(["Save", "Undo", "Pointer", "Edit", "Convert", "Comment", "FillSign"], shown);
    }

    [Fact]
    public void At1100DipsTheBarGoesIconsOnly()
    {
        // 3 DIPs short of the five labels: icons only, and then all but Redo fit.
        var (compact, shown) = FitBar(English, 618);
        Assert.True(compact);
        Assert.Equal(["Save", "Print", "Undo", "Pointer", "Edit", "Convert", "Comment", "FillSign", "Organize", "Protect", "ScanOcr"], shown);
    }

    [Fact]
    public void AtTextSize150OnA1200DipWindowThePointerConvertAndFillSignStay()
    {
        // 318 DIPs of room, icons only: the highest priorities stay (save and undo, the pointer tools, Convert, Fill & Sign);
        // Edit and Comment are in "…".
        var (compact, shown) = FitBar(English, 318);
        Assert.True(compact);
        Assert.Equal(["Save", "Undo", "Pointer", "Convert", "FillSign"], shown);
    }

    [Fact]
    public void InSpanishAt1700DipsScanAndOcrGoesIntoTheOverflow()
    {
        // Editar, Convertir, Comentar, Llenar y firmar, Organizar, Proteger as measured; Escanear y OCR estimated (it
        // never showed): about a tenth longer than English, so Scan & OCR and Redo give way in the 985 DIPs there.
        var spanish = new Dictionary<string, (double Full, double Compact)>(English)
        {
            ["Edit"] = (95, 52), ["Convert"] = (117, 52), ["Comment"] = (121, 52), ["FillSign"] = (148, 52),
            ["Organize"] = (120, 52), ["Protect"] = (113, 52), ["ScanOcr"] = (150, 52),
        };
        var (compact, shown) = FitBar(spanish, 985);
        Assert.False(compact);
        Assert.Equal(["Save", "Print", "Undo", "Pointer", "Edit", "Convert", "Comment", "FillSign", "Organize", "Protect"], shown);
    }
}
