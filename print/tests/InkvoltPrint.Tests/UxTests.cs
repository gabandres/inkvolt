using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>The UI audit's rules (names and target sizes) and the dialog heading / body split both apps use.</summary>
public class UxTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("")]          // a Segoe Fluent Icons glyph as a button's only content
    [InlineData(" ")]
    [InlineData("…")]
    public void UnnamedWhenNothingToSay(string? name) => Assert.True(UiAudit.IsUnnamed(name));

    [Theory]
    [InlineData("Close")]
    [InlineData(" Close")]
    [InlineData("Página 3")]
    public void NamedWhenThereAreWords(string name) => Assert.False(UiAudit.IsUnnamed(name));

    [Fact]
    public void SmallTargetsAreFlaggedUnlessInline()
    {
        Assert.True(UiAudit.IsSmallTarget(new UiControl("Button", "Close", 20, 20, "Bar")));
        Assert.True(UiAudit.IsSmallTarget(new UiControl("Button", "Close", 40, 16, "Bar")));
        Assert.False(UiAudit.IsSmallTarget(new UiControl("Button", "Close", 24, 24, "Bar")));
        Assert.False(UiAudit.IsSmallTarget(new UiControl("Button", "Close", 23.6, 24, "Bar"))); // layout rounding
        Assert.False(UiAudit.IsSmallTarget(new UiControl("Button", "more", 40, 16, "Text", IsInline: true)));
        Assert.False(UiAudit.IsSmallTarget(new UiControl("Button", "hidden", 0, 0, "Bar"))); // not laid out: not a target
    }

    [Fact]
    public void FindingsNameEachProblemOnce()
    {
        var lines = UiAudit.Findings(
        [
            new UiControl("Button", "", 20, 20, "FindBar"),
            new UiControl("TextBox", "Find in document", 230, 32, "FindBar"),
            new UiControl("ToggleButton", "Match case", 34, 34, "FindBar"),
        ]);
        Assert.Equal(2, lines.Count);
        Assert.Contains("No accessible name: Button at FindBar", lines[0]);
        Assert.Contains("Small target: Button", lines[1]);
        Assert.Contains("20×20", lines[1]);
    }

    [Fact]
    public void QuestionBecomesTheHeading()
    {
        var (heading, body) = DialogText.Split("Remove Office laser from Inkvolt Print?\n\nThis doesn't remove it from Windows. It comes back if discovery finds it.");
        Assert.Equal("Remove Office laser from Inkvolt Print?", heading);
        Assert.Equal("This doesn't remove it from Windows. It comes back if discovery finds it.", body);
    }

    [Fact]
    public void QuestionAfterAnExplanationStillLeads()
    {
        var (heading, body) = DialogText.Split("You have 3 scanned pages that you haven't saved. Close Inkvolt Print anyway?");
        Assert.Equal("Close Inkvolt Print anyway?", heading);
        Assert.Equal("You have 3 scanned pages that you haven't saved.", body);
    }

    [Fact]
    public void OneSentenceHasNoBody()
    {
        var (heading, body) = DialogText.Split("Discard 2 pages you haven't saved?");
        Assert.Equal("Discard 2 pages you haven't saved?", heading);
        Assert.Null(body);
    }

    [Fact]
    public void StatementSplitsAtTheFirstSentence()
    {
        var (heading, body) = DialogText.Split("Nothing was changed. The printer answered with an error, e.g. a busy signal; try again later.");
        Assert.Equal("Nothing was changed.", heading);
        Assert.Equal("The printer answered with an error, e.g. a busy signal; try again later.", body);
    }

    [Fact]
    public void NumbersAndAbbreviationsDoNotEndSentences()
    {
        var (heading, body) = DialogText.Split("Use the device at 192.0.2.5 as Office laser? Only do this if it really is this printer.");
        Assert.Equal("Use the device at 192.0.2.5 as Office laser?", heading);
        Assert.Equal("Only do this if it really is this printer.", body);
    }

    [Fact]
    public void EmptyMessageIsSafe()
    {
        var (heading, body) = DialogText.Split("  ");
        Assert.Equal("", heading);
        Assert.Null(body);
    }
}

/// <summary>The scan review's Undo: newest first, each step reversed once, bounded.</summary>
public class UndoHistoryTests
{
    [Fact]
    public void UndoReversesTheNewestStepFirst()
    {
        var turns = 0;
        var history = new InkvoltPrint.Core.Model.UndoHistory();
        history.Record("Turn page 1", () => turns -= 1);
        turns += 1;
        history.Record("Delete page 2", () => turns += 100);
        Assert.Equal("Delete page 2", history.Next);
        Assert.Equal("Delete page 2", history.Undo());
        Assert.Equal(101, turns);
        Assert.Equal("Turn page 1", history.Undo());
        Assert.Equal(100, turns);
        Assert.False(history.CanUndo);
        Assert.Null(history.Undo()); // nothing left: nothing happens
        Assert.Equal(100, turns);
    }

    [Fact]
    public void KeepsOnlyTheNewestSteps()
    {
        var history = new InkvoltPrint.Core.Model.UndoHistory();
        for (var i = 0; i < InkvoltPrint.Core.Model.UndoHistory.Limit + 5; i++) history.Record($"Step {i}", () => { });
        Assert.Equal(InkvoltPrint.Core.Model.UndoHistory.Limit, history.Count);
        Assert.Equal($"Step {InkvoltPrint.Core.Model.UndoHistory.Limit + 4}", history.Next);
    }

    [Fact]
    public void ChangedFollowsEveryRecordUndoAndClear()
    {
        var history = new InkvoltPrint.Core.Model.UndoHistory();
        var changes = 0;
        history.Changed += (_, _) => changes++;
        history.Record("Crop page 1", () => { });
        history.Undo();
        history.Clear(); // empty: no change
        history.Record("Crop page 1", () => { });
        history.Clear();
        Assert.Equal(4, changes);
    }
}

/// <summary>Windows' Text size, as both apps scale by it.</summary>
public class TextSizeTests
{
    [Theory]
    [InlineData(1.0, 1.0)]
    [InlineData(1.5, 1.5)]
    [InlineData(2.25, 2.25)]
    [InlineData(3.0, 2.25)]     // past what Windows offers
    [InlineData(0.5, 1.0)]      // never smaller
    [InlineData(double.NaN, 1.0)]
    public void FactorStaysInWindowsRange(double raw, double expected) => Assert.Equal(expected, TextSize.Factor(raw));

    [Theory]
    [InlineData("1.5", 1.5)]
    [InlineData("150", 1.5)]
    [InlineData(" 200% ", 2.0)]
    [InlineData("100", 1.0)]
    public void ParsesTheOverride(string text, double expected) => Assert.Equal(expected, TextSize.Parse(text));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("big")]
    public void NoOverrideWithoutANumber(string? text) => Assert.Null(TextSize.Parse(text));

    [Fact]
    public void DialogsWidenWithinTheScreen()
    {
        Assert.Equal(600, TextSize.Widen(400, 1.5, 1900));
        Assert.Equal(700, TextSize.Widen(400, 2, 700));     // only as wide as the room
        Assert.Equal(800, TextSize.Widen(800, 1.5, 700));   // already wider than the room: left as designed
        Assert.Equal(400, TextSize.Widen(400, 1, 1900));
        Assert.True(double.IsNaN(TextSize.Widen(double.NaN, 1.5, 1900)));
    }
}
