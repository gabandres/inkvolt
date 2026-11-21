using System.Globalization;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Prepare Form's clicks, drags, keys and panel rules (<see cref="FormDesigner"/>, <see cref="FormDesignRules"/>), which
/// <c>PageViewer.FormDesign</c> and <c>DocumentTab.FormDesign</c> pass input to and draw. The Mac's
/// <c>FormDesignerTests</c> are the spec: their names where they apply, and Windows' own (the view's turn, the keys).
/// </summary>
public class FormDesignerTests
{
    private static DesignField Field(DesignFieldKind kind = DesignFieldKind.Text, RectD? rect = null, string name = "A", string id = "a", int page = 0, int tab = 0) =>
        FormDesign.NewField(kind, page, rect ?? new RectD(100, 100, 100, 20), [], name) with { Id = id, TabIndex = tab };

    private static FormDesigner Designer(params DesignField[] fields) => Turned(0, fields);

    private static FormDesigner Turned(int rotation, params DesignField[] fields)
    {
        var d = new FormDesigner(_ => new DesignPage(612, 792, rotation));
        d.SetFields(fields);
        return d;
    }

    private static DesignPress Press(FormDesigner d, double x, double y, int clicks = 1, int page = 0) => d.Press(page, new PointD(x, y), clicks, reach: 5);

    private static void Drag(FormDesigner d, double x, double y, bool shift = false) => d.Move(new PointD(x, y), shift, dragged: true);

    private static DesignPlacement Placed(DesignRelease? r) => Assert.IsType<DesignRelease.Placed>(r).Placement;

    private static DesignField Moved(DesignRelease? r) => Assert.IsType<DesignRelease.Moved>(r).Field;

    [Fact]
    public void AClickWithAToolPlacesTheUsualSizeKeptOnThePage()
    {
        var d = Designer();
        d.Kind = DesignFieldKind.Signature;
        Assert.Equal(DesignPress.None, Press(d, 600, 780));
        Assert.NotNull(d.NewBoxRect);
        Assert.Equal(new DesignPlacement(DesignFieldKind.Signature, 0, new RectD(432, 752, 180, 40)), Placed(d.Release()));
        Assert.Null(d.NewBoxRect);
    }

    [Fact]
    public void ADragWithAToolPlacesThatBoxAndCheckBoxesStaySquare()
    {
        var d = Designer();
        d.Kind = DesignFieldKind.Text;
        Press(d, 50, 50);
        Drag(d, 250, 80);
        Assert.Equal(new DesignPlacement(DesignFieldKind.Text, 0, new RectD(50, 50, 200, 30)), Placed(d.Release()));

        d.Kind = DesignFieldKind.CheckBox;
        Press(d, 50, 50);
        Drag(d, 90, 70);
        Assert.Equal(new DesignPlacement(DesignFieldKind.CheckBox, 0, new RectD(50, 50, 20, 20)), Placed(d.Release()));

        // Too small to be meant: the usual size.
        d.Kind = DesignFieldKind.Text;
        Press(d, 50, 50);
        Drag(d, 53, 53);
        Assert.Equal(new DesignPlacement(DesignFieldKind.Text, 0, new RectD(50, 50, 160, 20)), Placed(d.Release()));

        // A move that never went far enough to be a drag: a click.
        Press(d, 50, 50);
        d.Move(new PointD(250, 80), shift: false, dragged: false);
        Assert.Equal(new RectD(50, 50, 160, 20), Placed(d.Release()).Rect);

        // Drawn off the page: it stops at the page's edge.
        Press(d, 500, 700);
        Drag(d, 900, 900);
        Assert.Equal(new RectD(500, 700, 112, 92), Placed(d.Release()).Rect);
    }

    [Fact]
    public void AClickSelectsADragMovesAndTheFieldStaysOnThePage()
    {
        var d = Designer(Field());
        Assert.Equal(DesignPress.Selected, Press(d, 150, 110));
        Assert.Equal("a", d.SelectedId);
        // A press without a drag writes nothing.
        Assert.Null(d.Release());

        Press(d, 150, 110);
        Assert.Equal(0, d.PressPage);
        Drag(d, 160, 130);
        Assert.Equal(new RectD(110, 120, 100, 20), d.ShownRect(d.Fields[0]));
        var moved = Moved(d.Release());
        Assert.Null(d.PressPage);
        Assert.Equal(("a", new RectD(110, 120, 100, 20)), (moved.Id, moved.Rect));
        // It shows there until the document catches up.
        Assert.Equal(new RectD(110, 120, 100, 20), d.ShownRect(d.Fields[0]));
        d.SetFields([Field(rect: new RectD(110, 120, 100, 20))]);

        Press(d, 150, 130);
        Drag(d, 5000, -500);
        Assert.Equal(new RectD(512, 0, 100, 20), d.ShownRect(d.Fields[0]));
    }

    [Fact]
    public void HandlesResizeAndCheckBoxesKeepTheirShape()
    {
        var d = Designer(Field());
        Press(d, 150, 110);
        d.Release();
        // The bottom-right handle, pressed a little off it: the frame doesn't jump.
        Assert.Equal(new PointD(200, 120), DrawingGeometry.HandlePoint(new RectD(100, 100, 100, 20), DrawingGeometry.BottomRight));
        Assert.Equal(DrawingGeometry.BottomRight, d.HandleAt(0, new PointD(203, 118), reach: 5));
        Assert.Equal(DesignCursor.Resize(DrawingGeometry.BottomRight), d.Cursor(0, new PointD(203, 118), reach: 5));
        Assert.Equal(DesignPress.None, Press(d, 203, 118));
        Drag(d, 253, 138);
        Assert.Equal(new RectD(100, 100, 150, 40), Moved(d.Release()).Rect);

        // Shift keeps a corner's proportions.
        d.SetFields([Field()]);
        Press(d, 203, 118);
        Drag(d, 303, 128, shift: true);
        Assert.Equal(new RectD(100, 100, 200, 40), Moved(d.Release()).Rect);

        var c = Designer(Field(DesignFieldKind.CheckBox, new RectD(100, 100, 20, 20), id: "c"));
        Press(c, 110, 110);
        c.Release();
        Press(c, 120, 120);
        Drag(c, 160, 130);
        var f = Moved(c.Release());
        Assert.Equal(f.Rect.Width, f.Rect.Height);
    }

    [Fact]
    public void SignedFieldsSelectButNeverMove()
    {
        var d = Designer(Field(DesignFieldKind.Signature, new RectD(100, 100, 200, 40)) with { Signed = true });
        Press(d, 150, 110);
        Assert.Equal("a", d.SelectedId);
        Assert.False(d.IsDragging);
        Assert.Equal(-1, d.HandleAt(0, new PointD(100, 100), reach: 5));
        Assert.Equal(DesignCursor.Arrow, d.Cursor(0, new PointD(150, 110), reach: 5));
        d.Nudge(5, 0);
        Assert.False(d.HasNudge);
    }

    [Fact]
    public void ADoubleClickOpensPropertiesOrAddsASuggestion()
    {
        var d = Designer(Field());
        Assert.Equal(DesignPress.Properties, Press(d, 150, 110, clicks: 2));
        Assert.False(d.IsDragging);
        d.SetSuggestions([new FieldSuggestion(0, new RectD(100, 300, 100, 20), DesignFieldKind.Text, "S", false, "line")]);
        Assert.Equal(DesignPress.Selected, Press(d, 150, 310));
        Assert.Equal("S", d.SelectedSuggestion?.Name);
        Assert.Null(d.SelectedId);
        Assert.Equal(DesignCursor.PointingHand, d.Cursor(0, new PointD(150, 310), reach: 5));
        Assert.Equal(DesignPress.Accept, Press(d, 150, 310, clicks: 2));
    }

    [Fact]
    public void AnEmptySpotLetsGoAndPans()
    {
        var d = Designer(Field());
        Press(d, 150, 110);
        d.Release();
        Assert.Equal(DesignPress.Pan, Press(d, 400, 400));
        Assert.Null(d.SelectedId);
    }

    [Fact]
    public void TheCursorSaysWhatAPressWouldDo()
    {
        var d = Designer(Field(), Field(DesignFieldKind.Signature, new RectD(300, 300, 100, 40), id: "s") with { Signed = true });
        Assert.Equal(DesignCursor.Move, d.Cursor(0, new PointD(150, 110), reach: 5));
        Assert.Equal(DesignCursor.Arrow, d.Cursor(0, new PointD(350, 320), reach: 5));
        Assert.Equal(DesignCursor.Arrow, d.Cursor(0, new PointD(500, 500), reach: 5));
        d.Kind = DesignFieldKind.Text;
        Assert.Equal(DesignCursor.Crosshair, d.Cursor(0, new PointD(150, 110), reach: 5));
    }

    [Fact]
    public void TheSmallestFieldUnderThePointerWins()
    {
        var big = Field(rect: new RectD(100, 100, 300, 300), id: "big");
        var small = Field(DesignFieldKind.CheckBox, new RectD(150, 150, 14, 14), name: "B", id: "small");
        var d = Designer(big, small);
        Assert.Equal("small", d.FieldAt(0, new PointD(155, 155))?.Id);
        Assert.Equal("big", d.FieldAt(0, new PointD(300, 300))?.Id);
        Assert.Null(d.FieldAt(1, new PointD(155, 155)));
    }

    [Fact]
    public void TabGoesThroughFieldsThenSuggestionsPageByPage()
    {
        var d = Designer(Field(name: "B", id: "b", tab: 1), Field(rect: new RectD(100, 50, 100, 20), id: "a", tab: 0), Field(name: "C", id: "c", page: 1));
        d.SetSuggestions([new FieldSuggestion(0, new RectD(100, 300, 100, 20), DesignFieldKind.Text, "S", false, "line")]);
        Assert.Equal(50, d.Step(1)?.Rect.Y);
        Assert.Equal("a", d.SelectedId);
        d.Step(1);
        Assert.Equal("b", d.SelectedId);
        d.Step(1);
        Assert.True(d.SelectedSuggestionIndex == 0 && d.SelectedId is null);
        Assert.Equal(1, d.Step(1)?.Page);
        Assert.Equal("c", d.SelectedId);
        d.Step(1);
        Assert.Equal("a", d.SelectedId); // around
        d.Step(-1);
        Assert.Equal("c", d.SelectedId);
        Assert.Null(Designer().Step(1));
    }

    [Fact]
    public void ArrowsAddUpAndAreWrittenOnce()
    {
        var d = Designer(Field());
        d.Select("a");
        d.Nudge(1, 0);
        d.Nudge(10, 0);
        d.Nudge(0, -1);
        Assert.Equal(new RectD(111, 99, 100, 20), d.ShownRect(d.Fields[0]));
        Assert.Equal(new RectD(111, 99, 100, 20), d.FlushNudge()?.Rect);
        Assert.Null(d.FlushNudge());
        Assert.Equal(new RectD(111, 99, 100, 20), d.ShownRect(d.Fields[0]));
        d.Nudge(-5000, 0);
        Assert.Equal(0, d.FlushNudge()?.Rect.X);
    }

    [Fact]
    public void EscLetsGoStepByStep()
    {
        var d = Designer(Field());
        d.Select("a");
        d.Kind = DesignFieldKind.Text;
        Assert.Equal(DesignEscape.DroppedTool, d.Escape());
        Assert.Equal("a", d.SelectedId);
        Assert.Equal(DesignEscape.Deselected, d.Escape());
        Assert.Equal(DesignEscape.Leave, d.Escape());
    }

    [Fact]
    public void ReReadingKeepsTheSelectionWhileItsFieldIsThere()
    {
        var d = Designer(Field());
        d.Select("a");
        d.SetFields([Field()]);
        Assert.Equal("a", d.SelectedId);
        d.SetFields([]);
        Assert.Null(d.SelectedId);
    }

    [Fact]
    public void ReReadingSuggestionsKeepsTheSelectedOneAndLeavingForgetsEverything()
    {
        var s = new FieldSuggestion(0, new RectD(100, 300, 100, 20), DesignFieldKind.Text, "S", false, "line");
        var t = s with { Name = "T", Rect = new RectD(100, 400, 100, 20) };
        var d = Designer(Field());
        d.SetSuggestions([s, t]);
        d.SelectSuggestion(1);
        d.SetSuggestions([t]);
        Assert.Equal(0, d.SelectedSuggestionIndex);
        d.SetSuggestions([s]);
        Assert.Equal(-1, d.SelectedSuggestionIndex);

        d.Kind = DesignFieldKind.Text;
        d.ShowTabOrder = true;
        d.Select("a");
        d.Reset();
        Assert.True(d.Kind is null && d.SelectedId is null && d.Suggestions.Count == 0 && !d.ShowTabOrder);
    }

    // ───────────────────────────── Windows: keys and the view's turn ─────────────────────────────

    [Fact]
    public void KeysActOnTheSelectionAndLeaveTheRestToTheView()
    {
        var d = Designer(Field());
        Assert.Null(d.Key(DesignKey.Delete, DesignModifiers.None));
        Assert.Null(d.Key(DesignKey.Enter, DesignModifiers.None));
        Assert.Null(d.Key(DesignKey.Left, DesignModifiers.None));

        d.Select("a");
        Assert.Equal(DesignAction.Delete, d.Key(DesignKey.Delete, DesignModifiers.None)?.Action);
        Assert.Equal(DesignAction.Delete, d.Key(DesignKey.Backspace, DesignModifiers.None)?.Action);
        Assert.Equal(DesignAction.Properties, d.Key(DesignKey.Enter, DesignModifiers.None)?.Action);
        Assert.Equal(DesignAction.Duplicate, d.Key(DesignKey.D, DesignModifiers.Control)?.Action);
        Assert.Null(d.Key(DesignKey.D, DesignModifiers.None));
        Assert.Null(d.Key(DesignKey.Delete, DesignModifiers.Control));
        Assert.Null(d.Key(DesignKey.Tab, DesignModifiers.Control));

        // Shift+arrow: 10 points; the moves are written before the next action.
        Assert.True(d.Key(DesignKey.Right, DesignModifiers.Shift)?.Nudged);
        Assert.True(d.Key(DesignKey.Down, DesignModifiers.None)?.Nudged);
        Assert.Null(d.Key(DesignKey.Down, DesignModifiers.Control));
        var delete = d.Key(DesignKey.Delete, DesignModifiers.None);
        Assert.Equal(new RectD(110, 101, 100, 20), delete?.Written?.Rect);
        Assert.Equal(DesignAction.Delete, delete?.Action);

        d.SetSuggestions([new FieldSuggestion(0, new RectD(100, 300, 100, 20), DesignFieldKind.Text, "S", false, "line")]);
        d.SelectSuggestion(0);
        Assert.Equal(DesignAction.Reject, d.Key(DesignKey.Delete, DesignModifiers.None)?.Action);
        Assert.Equal(DesignAction.Accept, d.Key(DesignKey.Enter, DesignModifiers.None)?.Action);
        Assert.Null(d.Key(DesignKey.D, DesignModifiers.Control));

        // Tab and Shift+Tab step and say where to look; Esc lets go.
        Assert.Equal(new DesignReveal(0, new RectD(100, 100, 100, 20)), d.Key(DesignKey.Tab, DesignModifiers.None)?.Reveal);
        Assert.Equal(0, d.Key(DesignKey.Tab, DesignModifiers.Shift)?.Reveal?.Page);
        Assert.Equal(0, d.SelectedSuggestionIndex);
        Assert.Equal(DesignEscape.Deselected, d.Key(DesignKey.Escape, DesignModifiers.None)?.Escape);
        Assert.Equal(DesignEscape.Leave, d.Key(DesignKey.Escape, DesignModifiers.None)?.Escape);
        Assert.Null(d.Key(DesignKey.Escape, DesignModifiers.Shift));
    }

    [Fact]
    public void DuringAPressEscCancelsItAndOtherKeysWait()
    {
        // Drawing a check box: Esc cancels the box, the tool stays, and the release places nothing.
        var d = Designer(Field());
        d.Kind = DesignFieldKind.CheckBox;
        Press(d, 300, 300);
        Drag(d, 330, 330);
        Assert.Equal(DesignEscape.CancelledPress, d.Key(DesignKey.Escape, DesignModifiers.None)?.Escape);
        Assert.Equal(DesignFieldKind.CheckBox, d.Kind);
        Assert.Null(d.Release());

        // The box keeps the tool it started with.
        Press(d, 300, 300);
        Drag(d, 330, 330);
        d.Kind = DesignFieldKind.Text;
        Assert.Equal(DesignFieldKind.CheckBox, Placed(d.Release()).Kind);

        // Moving a field: Delete, Tab, arrows and Enter do nothing until the release, which writes the move.
        d.Kind = null;
        Press(d, 150, 110);
        Drag(d, 160, 130);
        foreach (var key in new[] { DesignKey.Delete, DesignKey.Tab, DesignKey.Right, DesignKey.Enter })
        {
            var r = d.Key(key, DesignModifiers.None);
            Assert.True(r is { Action: null, Reveal: null, Written: null, Nudged: false, Escape: null });
        }
        Assert.Equal("a", d.SelectedId);
        Assert.False(d.HasNudge);
        Assert.Equal(new RectD(110, 120, 100, 20), Moved(d.Release()).Rect);

        // Esc during a move: the field goes back and the release writes nothing.
        Press(d, 150, 130);
        Drag(d, 200, 200);
        Assert.Equal(DesignEscape.CancelledPress, d.Key(DesignKey.Escape, DesignModifiers.None)?.Escape);
        Assert.Equal(new RectD(110, 120, 100, 20), d.ShownRect(d.Fields[0]));
        Assert.Null(d.Release());
        Assert.Equal("a", d.SelectedId);
    }

    [Fact]
    public void ReReadingDuringAMoveGoesOnFromTheFieldAsRead()
    {
        // Moved to r1 (the edit still running), pressed again; the document catches up mid-drag.
        var d = Designer(Field());
        Press(d, 150, 110);
        Drag(d, 160, 130);
        Assert.Equal(new RectD(110, 120, 100, 20), Moved(d.Release()).Rect);
        Press(d, 150, 130);
        d.SetFields([Field(rect: new RectD(110, 120, 100, 20))]);
        Drag(d, 160, 130);
        Assert.Equal(new RectD(120, 120, 100, 20), d.ShownRect(d.Fields[0]));
        Assert.Equal(new RectD(120, 120, 100, 20), Moved(d.Release()).Rect);

        // The edit wasn't made (the field read back where it was): the drag goes on from there.
        Press(d, 150, 130);
        d.SetFields([Field()]);
        Drag(d, 160, 130);
        Assert.Equal(new RectD(110, 100, 100, 20), Moved(d.Release()).Rect);

        // The field went away: the press ends and writes nothing.
        d.SetFields([Field()]);
        Press(d, 150, 110);
        d.SetFields([]);
        Assert.False(d.IsDragging);
        Assert.False(d.Move(new PointD(200, 200), false, true));
        Assert.Null(d.Release());
    }

    [Fact]
    public void ASignedFieldTakesOnlyEnterAndEsc()
    {
        var d = Designer(Field(DesignFieldKind.Signature, new RectD(100, 100, 200, 40)) with { Signed = true });
        d.Select("a");
        Assert.Null(d.Key(DesignKey.Delete, DesignModifiers.None));
        Assert.Null(d.Key(DesignKey.D, DesignModifiers.Control));
        Assert.Null(d.Key(DesignKey.Right, DesignModifiers.None));
        Assert.Equal(DesignAction.Properties, d.Key(DesignKey.Enter, DesignModifiers.None)?.Action);
        Assert.Equal(DesignEscape.Deselected, d.Key(DesignKey.Escape, DesignModifiers.None)?.Escape);
    }

    [Fact]
    public void TabAndEscWriteTheArrowMovesFirst()
    {
        var d = Designer(Field(), Field(name: "B", id: "b", tab: 1));
        d.Select("a");
        d.Key(DesignKey.Left, DesignModifiers.None);
        var tab = d.Key(DesignKey.Tab, DesignModifiers.None);
        Assert.Equal(("a", 99.0), (tab?.Written?.Id, tab?.Written?.Rect.X));
        Assert.Equal("b", d.SelectedId);
        d.Key(DesignKey.Up, DesignModifiers.None);
        var esc = d.Key(DesignKey.Escape, DesignModifiers.None);
        Assert.Equal(("b", 99.0), (esc?.Written?.Id, esc?.Written?.Rect.Y));
        Assert.Equal(DesignEscape.Deselected, esc?.Escape);
        Assert.False(d.HasNudge);
    }

    [Fact]
    public void HandlesAndArrowsFollowTheViewsTurn()
    {
        // Turned a quarter clockwise: the field's page-space top-right corner shows at the bottom right.
        var d = Turned(90, Field());
        d.Select("a");
        Assert.Equal(DrawingGeometry.BottomRight, d.HandleAt(0, new PointD(200, 100), reach: 5));
        Assert.Equal(DrawingGeometry.TopLeft, d.HandleAt(0, new PointD(100, 120), reach: 5));

        // Right on screen is up the page.
        d.Key(DesignKey.Right, DesignModifiers.None);
        Assert.Equal(new RectD(100, 99, 100, 20), d.FlushNudge()?.Rect);

        // The shown bottom-right handle dragged 10 right and 20 down on screen: on the page, 20 wider and 10 taller upwards.
        d.SetFields([Field()]);
        Press(d, 200, 100);
        Drag(d, 220, 90);
        Assert.Equal(new RectD(100, 90, 120, 30), Moved(d.Release()).Rect);
    }

    // ───────────────────────────── FormDesignRules ─────────────────────────────

    [Fact]
    public void ARadioButtonDrawnWithOneSelectedJoinsItsGroup()
    {
        var first = Field(DesignFieldKind.Radio, new RectD(100, 100, 14, 14), name: "Pick") with { ExportValue = "Choice1", DefaultValue = "Choice1" };
        var joined = FormDesignRules.PlacedField(new DesignPlacement(DesignFieldKind.Radio, 1, new RectD(130, 100, 14, 14)), [first], first);
        Assert.True(joined is { Name: "Pick", ExportValue: "Choice2", DefaultValue: "Choice1", PageIndex: 1 });
        Assert.NotEqual(first.Id, joined.Id);
        var alone = FormDesignRules.PlacedField(new DesignPlacement(DesignFieldKind.Radio, 0, new RectD(130, 100, 14, 14)), [first], null);
        Assert.Equal("Group1", alone.Name);
        var tall = FormDesignRules.PlacedField(new DesignPlacement(DesignFieldKind.Text, 0, new RectD(0, 0, 100, 40)), [], null);
        Assert.True(tall.Multiline);
        Assert.False(FormDesignRules.PlacedField(new DesignPlacement(DesignFieldKind.Text, 0, new RectD(0, 0, 100, 30)), [], null).Multiline);
    }

    [Fact]
    public void ADuplicateGoesBelowElseBeside()
    {
        var f = Field();
        Assert.Equal(new RectD(100, 128, 100, 20), FormDesignRules.Duplicated(f, [f], 612, 792).Rect);
        var low = Field(rect: new RectD(100, 770, 100, 20));
        Assert.Equal(new RectD(208, 770, 100, 20), FormDesignRules.Duplicated(low, [low], 612, 792).Rect);
    }

    [Fact]
    public void AcceptedSuggestionsGetUniqueNamesAndRadioValues()
    {
        static FieldSuggestion S(DesignFieldKind kind, string name, bool multiline = false) => new(0, new RectD(0, 0, 50, 50), kind, name, multiline, "box");
        var existing = Field(DesignFieldKind.Radio, new RectD(0, 0, 14, 14), name: "R") with { ExportValue = "Choice2" };
        var made = FormDesignRules.AcceptedFields([S(DesignFieldKind.Text, "A", multiline: true), S(DesignFieldKind.Text, "A"), S(DesignFieldKind.Radio, "R"), S(DesignFieldKind.Radio, "R")], [existing]);
        Assert.Equal(["A", "A_2", "R", "R"], made.Select(f => f.Name));
        Assert.True(made[0].Multiline);
        Assert.Equal("Choice3", made[2].ExportValue);
        Assert.Equal("Choice4", made[3].ExportValue);
    }

    [Fact]
    public void AfterDeletingTheNextFieldWithItsOwnIdIsSelected()
    {
        DesignField a = Field(id: "a"), b = Field(id: "p0:1"), c = Field(id: "c");
        Assert.Equal("c", FormDesignRules.NextField(a, [a, b, c]));
        Assert.Equal("a", FormDesignRules.NextField(c, [a, b, c]));
        Assert.Null(FormDesignRules.NextField(a, [a]));
        Assert.True(FormDesignRules.IsPositionalId("p12:3"));
        Assert.False(FormDesignRules.IsPositionalId("page:3"));
        Assert.False(FormDesignRules.IsPositionalId("InkvoltPdf-abc"));
    }

    [Fact]
    public void ReviewingSuggestionsGoesOnWithTheNextOne()
    {
        Assert.Equal(1, FormDesignRules.SuggestionAfter(1, left: 3));
        Assert.Equal(1, FormDesignRules.SuggestionAfter(2, left: 2)); // the last went: the one before it
        Assert.Equal(0, FormDesignRules.SuggestionAfter(-1, left: 2));
        Assert.Equal(-1, FormDesignRules.SuggestionAfter(0, left: 0));
        Assert.Equal(-1, FormDesignRules.SuggestionAfter(0, left: 2, removed: 3)); // Accept All: nothing more to review
    }

    [Fact]
    public void TheSelectionFollowsAFieldsNewId()
    {
        var newIds = new Dictionary<string, string> { ["p0:2"] = "p0:1" };
        Assert.Equal("p0:1", FormDesignRules.FollowedId("p0:2", newIds));
        Assert.Equal("a", FormDesignRules.FollowedId("a", newIds));
        Assert.Null(FormDesignRules.FollowedId(null, newIds));
    }

    [Fact]
    public void TabOrderMovesWithinThePageAndStopsAtItsEnds()
    {
        DesignField a = Field(id: "a", tab: 0), b = Field(id: "b", tab: 1), other = Field(id: "o", page: 1);
        Assert.Equal(["b", "a"], FormDesignRules.TabOrder(a, 1, [a, b, other]));
        Assert.Equal(PdfStrings.Form_AlreadyFirst, Assert.Throws<DesignRefusal>(() => FormDesignRules.TabOrder(a, -1, [a, b])).Message);
        Assert.Equal(PdfStrings.Form_AlreadyLast, Assert.Throws<DesignRefusal>(() => FormDesignRules.TabOrder(b, 1, [a, b])).Message);
    }

    [Fact]
    public void AFieldCoveringASuggestionTakesItsPlace()
    {
        var s = new FieldSuggestion(0, new RectD(100, 100, 100, 20), DesignFieldKind.Text, "S", false, "line");
        Assert.Empty(FormDesignRules.StillSuggested([s], [Field()]));
        Assert.Equal([s], FormDesignRules.StillSuggested([s], [Field(page: 1)]));
        Assert.Equal([s], FormDesignRules.StillSuggested([s], [Field(rect: new RectD(100, 300, 100, 20))]));
    }

    [Fact]
    public void ARenameIsCheckedAgainstTheOtherFields()
    {
        DesignField a = Field(name: "A", id: "a"), b = Field(name: "B", id: "b");
        Assert.Same(a, FormDesignRules.Renamed(a, " A ", [a, b]));
        Assert.Equal("C", FormDesignRules.Renamed(a, " C ", [a, b]).Name);
        Assert.Throws<DesignRefusal>(() => FormDesignRules.Renamed(a, "B", [a, b]));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.Renamed(a, "B.c", [a, b]));
        // A group's other buttons don't clash with a rename of one of them, and another group can be joined.
        DesignField r1 = Field(DesignFieldKind.Radio, name: "R", id: "1"), r2 = Field(DesignFieldKind.Radio, name: "R", id: "2"), g = Field(DesignFieldKind.Radio, name: "G", id: "3");
        Assert.Equal("G", FormDesignRules.Renamed(r1, "G", [r1, r2, g]).Name);
    }

    [Fact]
    public void TypedLimitsAndValuesAreChecked()
    {
        var f = Field();
        Assert.Equal(12, FormDesignRules.WithMaxLength(f, "12").MaxLength);
        Assert.Equal(0, FormDesignRules.WithMaxLength(f with { MaxLength = 5 }, " ").MaxLength);
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithMaxLength(f, "many"));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithMaxLength(f, "-1"));
        Assert.Equal(PdfStrings.Form_MaxLengthInvalid, Assert.Throws<DesignRefusal>(() => FormDesignRules.WithMaxLength(f, "100001")).Message);

        var r1 = Field(DesignFieldKind.Radio, name: "R", id: "1") with { ExportValue = "One", DefaultValue = "One" };
        var r2 = Field(DesignFieldKind.Radio, name: "R", id: "2") with { ExportValue = "Two" };
        var renamed = FormDesignRules.WithExportValue(r1, "First", [r1, r2]);
        Assert.True(renamed is { ExportValue: "First", DefaultValue: "First" });
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithExportValue(r1, "Two", [r1, r2]));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithExportValue(r1, "Off", [r1, r2]));
        Assert.Same(r1, FormDesignRules.WithExportValue(r1, " One ", [r1, r2]));
    }

    [Fact]
    public void ChoicesAreOnePerLineWithShownTextAndValue()
    {
        var (options, labels) = FormDesignRules.ParseChoices("Gold = g\r\n\n Silver \nGold again = g\nBronze = \n");
        Assert.Equal(["g", "Silver", "Bronze ="], options);
        Assert.Equal(["Gold", "Silver", "Bronze ="], labels);

        var f = Field(DesignFieldKind.ComboBox) with { Options = ["g", "s"], OptionLabels = ["Gold", "s"], DefaultValue = "s" };
        Assert.Equal($"Gold = g{Environment.NewLine}s", FormDesignRules.ChoicesText(f));
        Assert.Same(f, FormDesignRules.WithChoices(f, "Gold = g\ns"));
        var changed = FormDesignRules.WithChoices(f, "a\nb");
        Assert.Equal(["a", "b"], changed.Options);
        Assert.Empty(changed.OptionLabels);
        Assert.Equal("", changed.DefaultValue);
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithChoices(f, "  \n"));

        Assert.Equal(2, FormDesignRules.DefaultChoiceIndex(f));
        Assert.Equal("g", FormDesignRules.WithDefaultChoice(f, 1).DefaultValue);
        Assert.Equal("", FormDesignRules.WithDefaultChoice(f, 0).DefaultValue);
    }

    [Fact]
    public void DefaultsAndSizes()
    {
        var check = Field(DesignFieldKind.CheckBox);
        Assert.Equal(check.ExportValue, FormDesignRules.WithDefaultOn(check, true).DefaultValue);
        Assert.Equal("", FormDesignRules.WithDefaultOn(check with { DefaultValue = "Yes" }, false).DefaultValue);
        // Turning off a radio button that isn't the default leaves the group's default.
        var radio = Field(DesignFieldKind.Radio) with { ExportValue = "A", DefaultValue = "B" };
        Assert.Equal("B", FormDesignRules.WithDefaultOn(radio, false).DefaultValue);
        Assert.Equal("", FormDesignRules.WithDefaultOn(radio with { DefaultValue = "A" }, false).DefaultValue);

        var before = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
            Assert.Equal(0, FormDesignRules.ParseSize("Auto"));
            Assert.Equal(0, FormDesignRules.ParseSize("auto"));
            Assert.Equal(0, FormDesignRules.ParseSize(""));
            Assert.Equal(0, FormDesignRules.ParseSize("Automático", "Automático"));
            Assert.Equal(12, FormDesignRules.ParseSize("12 pt"));
            Assert.Equal(10.5, FormDesignRules.ParseSize("10.5"));
            Assert.Null(FormDesignRules.ParseSize("300"));
            Assert.Null(FormDesignRules.ParseSize("big"));
            // Typed the way the interface's language writes numbers.
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("es-ES");
            Assert.Equal(10.5, FormDesignRules.ParseSize("10,5"));
        }
        finally
        {
            CultureInfo.CurrentCulture = before;
        }
    }

    [Fact]
    public void PanelListsSayWhatIsKept()
    {
        var plain = Field();
        Assert.Equal(0, FormDesignRules.FormatIndex(plain));
        Assert.Equal(3, FormDesignRules.FormatIndex(plain with { Format = new FieldFormat(FieldFormatKind.Number, 2, Currency: "$", CurrencyPrepend: true) }));
        Assert.Equal(-1, FormDesignRules.FormatIndex(plain with { Format = new FieldFormat(FieldFormatKind.Date, DatePattern: "d mmm") }));
        Assert.Equal(-1, FormDesignRules.FormatIndex(plain with { CustomFormat = true }));

        Assert.Equal(0, FormDesignRules.ColorIndex(FormDesignRules.BorderColors, null));
        Assert.Equal(2, FormDesignRules.ColorIndex(FormDesignRules.BorderColors, new AnnotColor(0.45, 0.46, 0.44)));
        Assert.Equal(-1, FormDesignRules.ColorIndex(FormDesignRules.FillColors, new AnnotColor(0.2, 0.3, 0.4)));

        Assert.Equal(1, FormDesignRules.SuggestionKindIndex(new FieldSuggestion(0, default, DesignFieldKind.Text, "S", true, "box")));
        Assert.Equal(6, FormDesignRules.SuggestionKindIndex(new FieldSuggestion(0, default, DesignFieldKind.Signature, "S", false, "box")));

        Assert.Equal(3, FormDesignRules.ButtonActionIndex(FieldButtonAction.Other));
        Assert.Equal(FieldButtonAction.Print, FormDesignRules.ButtonActionAt(FormDesignRules.ButtonActionIndex(FieldButtonAction.Print)));
        Assert.Null(FormDesignRules.ButtonActionAt(3)); // a button's own action is kept, not picked
    }

    [Fact]
    public void AChangeOnlyCountsWhenItShows()
    {
        var f = Field(DesignFieldKind.ComboBox) with { Options = ["a"], OptionLabels = [] };
        Assert.False(FormDesignRules.Differs(f, f with { OptionLabels = ["a"] }));
        Assert.True(FormDesignRules.Differs(f, f with { OptionLabels = ["A"] }));
        Assert.True(FormDesignRules.Differs(f, f with { Required = true }));
    }
}
