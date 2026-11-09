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
        // Every group but the pointer tools is a split button whose body runs its first command at once
        // (docs/design/command-bar.md, "One click"); each has an icon of its own.
        var groups = CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().Where(e => e.IsGroup).ToList();
        Assert.Equal(["Edit", "Convert", "Comment", "FillSign", "Organize", "Protect", "ScanOcr"], groups.Where(g => g.HasMainJob).Select(g => g.Id));
        Assert.Equal(["EditContent", "ExportWord", "Highlight", "AddSignature", "Organize", "ProtectPassword", "RecognizeText"],
            groups.Where(g => g.HasMainJob).Select(g => g.Main.Name));
        Assert.All(groups.Where(g => g.HasMainJob), g => Assert.True(g.Glyph is { Length: 1 }, g.Id));
        Assert.False(CommandBarLayout.Group(CommandBarLayout.Pointer).HasMainJob);
    }

    [Fact]
    public void ConvertNamesTheFormatsAndRunsTheEditableOnesAtOnce()
    {
        // Convert's flyout names the format ("Word (.docx)"), not the command ("Export to Word…"); Word, Excel, PowerPoint,
        // text and HTML run at once (no "…"), pictures and PDF/A ask. Each file type has its own icon brush key, so a color
        // per format can be given later in App.xaml.
        var convert = CommandBarLayout.Group("Convert").Commands;
        Assert.All(convert, c => Assert.False(string.IsNullOrEmpty(c.Title), c.Name));
        Assert.Equal(["ExportWord", "ExportExcel", "ExportPowerPoint", "ExportText", "ExportHtml"], convert.Where(c => c.AtOnce).Select(c => c.Name));
        Assert.All(convert, c => Assert.Equal(!c.AtOnce, c.Title!.EndsWith('…')));
        Assert.All(convert, c => Assert.StartsWith("Format", c.IconBrush));
        Assert.Equal(convert.Count, convert.Select(c => c.IconBrush).Distinct().Count());
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

    // The bar's own table with its children's widths as measured in the app at 100 % (barstate: with their margins):
    // icons 36, the pointer group 52, a group's split button 60 as icons (body and arrow); separators 13. The room is
    // what the bar has beside the menus and the Commands button in a window of that width (under 1100 the Commands
    // button keeps only its icon).
    private static readonly Dictionary<string, (double Full, double Compact)> English = new()
    {
        ["Save"] = (36, 36), ["Print"] = (36, 36), ["Undo"] = (36, 36), ["Redo"] = (36, 36), ["Pointer"] = (52, 52),
        ["Edit"] = (82, 60), ["Convert"] = (107, 60), ["Comment"] = (120, 60), ["FillSign"] = (122, 60),
        ["Organize"] = (115, 60), ["Protect"] = (103, 60), ["ScanOcr"] = (134, 60),
    };

    private static (bool Compact, string[] Shown) FitBar(Dictionary<string, (double Full, double Compact)> widths, double room,
        Func<CommandBarLayout.Entry, int>? priority = null)
    {
        var items = CommandBarLayout.Bar.Select(e => e is null ? Sep : Cmd(widths[e.Id].Full, priority?.Invoke(e) ?? e.Priority, widths[e.Id].Compact)).ToList();
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
    public void At1280DipsTheFourCommonGroupsKeepTheirLabels()
    {
        // Print and Redo, then Scan & OCR, Protect and Organize go into "…" before any label does.
        var (compact, shown) = FitBar(English, 632);
        Assert.False(compact);
        Assert.Equal(["Save", "Undo", "Pointer", "Edit", "Convert", "Comment", "FillSign"], shown);
    }

    [Fact]
    public void ShorterStillThePointerToolsGoBeforeTheLabels()
    {
        // At 1100 DIPs (a little under the 617 the labeled groups and the pointer take): Hand, Select and Snapshot go into
        // "…" (H, T and G still work) and Edit, Convert, Comment and Fill & Sign keep their labels (the owner, 2026-11-08).
        var (compact, shown) = FitBar(English, 610);
        Assert.False(compact);
        Assert.Equal(["Save", "Undo", "Edit", "Convert", "Comment", "FillSign"], shown);
    }

    [Fact]
    public void AtTextSize150OnA1200DipWindowTheBarGoesIconsOnly()
    {
        // 318 DIPs of room: the four labels can't fit, so icons only; the highest priorities stay (save and undo,
        // Edit, Convert, Fill & Sign) and Comment and the pointer tools are in "…".
        var (compact, shown) = FitBar(English, 318);
        Assert.True(compact);
        Assert.Equal(["Save", "Undo", "Edit", "Convert", "FillSign"], shown);
    }

    // Editar, Convertir, Comentar, Llenar y firmar, Organizar, Proteger as measured in Spanish; Escanear y OCR estimated
    // (it never showed at these widths).
    private static readonly Dictionary<string, (double Full, double Compact)> Spanish = new(English)
    {
        ["Edit"] = (94, 60), ["Convert"] = (116, 60), ["Comment"] = (120, 60), ["FillSign"] = (147, 60),
        ["Organize"] = (119, 60), ["Protect"] = (112, 60), ["ScanOcr"] = (150, 60),
    };

    private static int InSpanish(CommandBarLayout.Entry e) =>
        e.Id == "FillSign" ? CommandBarLayout.FillSignPriority(new System.Globalization.CultureInfo("es")) : e.Priority;

    [Fact]
    public void InSpanishLlenarYFirmarGoesIntoTheOverflowBeforeTheLabels()
    {
        // The owner (2026-11-08): keep "Llenar y firmar", and let it go into "…" sooner rather than drop every label.
        Assert.True(CommandBarLayout.FillSignPriority(new System.Globalization.CultureInfo("es")) < CommandBarLayout.KeepsLabels);
        Assert.True(CommandBarLayout.FillSignPriority(System.Globalization.CultureInfo.InvariantCulture) >= CommandBarLayout.KeepsLabels);
        var (compact, shown) = FitBar(Spanish, 985, InSpanish); // 1700 DIPs: Scan & OCR and Redo give way
        Assert.False(compact);
        Assert.Equal(["Save", "Print", "Undo", "Pointer", "Edit", "Convert", "Comment", "FillSign", "Organize", "Protect"], shown);
        (compact, shown) = FitBar(Spanish, 584, InSpanish); // 1280 DIPs
        Assert.False(compact);
        Assert.Equal(["Save", "Undo", "Pointer", "Edit", "Convert", "Comment"], shown);
    }
}
