using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using Item = InkvoltPdf.Core.CommandBarLayout.Item;

namespace InkvoltPdf.Tests;

public class CommandBarLayoutTests
{
    // ── The table ──

    [Fact]
    public void TheOldBarsCommandsAreAllStillReachedInTheSameOrder()
    {
        // The twenty-odd icons of the bar before the groups, left to right.
        string[] before =
        [
            "Save", "Print", "Undo", "Redo", "ToolHand", "ToolSelect", "ToolSnapshot", "ToolAddText", "ToolCheck", "ToolCross",
            "AddSignature", "Highlight", "AddNote", "AddImage", "ToolLink", "AddStamp", "Redact", "Organize", "RotateLeft",
            "RotateRight", "DeleteSelected", "Find", "Combine",
        ];
        var now = CommandBarLayout.AllCommands.ToList();
        Assert.Equal(before, now.Where(before.Contains).ToArray());
        Assert.Equal(now.Count, now.Distinct().Count());
    }

    [Fact]
    public void AFewLabeledGroupsReplaceTheIcons()
    {
        var entries = CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().ToList();
        Assert.All(entries.Where(e => e.Label is null), e => Assert.Contains(e.Id, new[] { "Save", "Print", "Undo", "Redo" }));
        Assert.Equal(["Select", "Fill & Sign", "Comment", "Draw", "Redact", "Organize"], entries.Where(e => e.Label is not null).Select(e => e.Label));
        Assert.Equal(["Pointer", "FillSign", "Comment"], entries.Where(e => e.IsGroup).Select(e => e.Id));
        Assert.All(CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().SelectMany(e => e.Commands).Concat(CommandBarLayout.Secondary),
            c => Assert.True(c.Glyph.Length == 1 && char.GetUnicodeCategory(c.Glyph[0]) == System.Globalization.UnicodeCategory.PrivateUse, c.Name));
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

    [Fact]
    public void AtAnOrdinaryWidthTheGroupsKeepTheirLabels()
    {
        // The bar's own table with typical widths (icons 34, labeled groups as measured at 100 %), in the room a 1200-DIP
        // window leaves it beside the menus and the Commands button: save and undo, Select, Fill & Sign and Comment show,
        // labeled; the rest are in "…".
        var widths = new Dictionary<string, double>
        {
            ["Save"] = 34, ["Print"] = 34, ["Undo"] = 34, ["Redo"] = 34, ["Pointer"] = 87, ["FillSign"] = 115, ["Comment"] = 108,
            ["Draw"] = 85, ["Redact"] = 84, ["Organize"] = 99,
        };
        var items = CommandBarLayout.Bar.Select(e => e is null ? Sep : Cmd(widths[e.Id], e.Priority, e.Label is null ? null : 50)).ToList();
        var fit = CommandBarLayout.Layout(items, 560, 34, moreAlways: true, keepsLabels: CommandBarLayout.KeepsLabels);
        Assert.False(fit.Compact);
        var shown = CommandBarLayout.Bar.Where((e, i) => e is not null && fit.Shown[i]).Select(e => e!.Id);
        Assert.Equal(["Save", "Print", "Undo", "Redo", "Pointer", "FillSign", "Comment"], shown);
    }
}
