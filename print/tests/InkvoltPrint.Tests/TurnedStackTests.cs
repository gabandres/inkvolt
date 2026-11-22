using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Two-sided scanning on a one-sided feeder (roadmap 4.1): the fronts, then the stack turned over and its backs, put in page
/// order (<see cref="TurnedStack"/>), and the preset option that asks for it (<see cref="PresetPlan"/>).
/// </summary>
public class TurnedStackTests
{
    /// <summary>Pages as the feeder sends them: "F1".."Fn" for the fronts, then the backs last sheet first, "B3", "B2", "B1".</summary>
    private static (List<string> Fronts, List<string> Backs) Stack(int sheets, bool reversed = true)
    {
        var fronts = Enumerable.Range(1, sheets).Select(n => $"F{n}").ToList();
        var backs = Enumerable.Range(1, sheets).Select(n => $"B{n}").ToList();
        if (reversed) backs.Reverse();
        return (fronts, backs);
    }

    [Fact]
    public void Backs_come_last_sheet_first_and_go_after_their_fronts()
    {
        var (fronts, backs) = Stack(4);
        Assert.Equal(["F1", "B1", "F2", "B2", "F3", "B3", "F4", "B4"], TurnedStack.Arrange(fronts, backs));
        Assert.Equal([0, 7, 1, 6, 2, 5, 3, 4], TurnedStack.Order(4, 4));
    }

    [Fact]
    public void A_tray_that_reverses_the_stack_sends_the_backs_first_sheet_first()
    {
        var (fronts, backs) = Stack(3, reversed: false);
        Assert.Equal(["F1", "B1", "F2", "B2", "F3", "B3"], TurnedStack.Arrange(fronts, backs, reversed: false));
    }

    [Fact]
    public void One_sheet_and_none()
    {
        Assert.Equal([0, 1], TurnedStack.Order(1, 1));
        Assert.Equal([0, 1, 2], TurnedStack.Order(3, 0));
        Assert.Equal([0, 1], TurnedStack.Order(0, 2));
        Assert.Empty(TurnedStack.Order(0, 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => TurnedStack.Order(-1, 2));
    }

    [Fact]
    public void A_back_short_matches_from_the_last_sheet_and_the_first_keeps_one_side()
    {
        // Four sheets, but the backs pass took three (the first sheet stayed behind): the backs scanned are sheets 4, 3, 2.
        var fronts = new List<string> { "F1", "F2", "F3", "F4" };
        var backs = new List<string> { "B4", "B3", "B2" };
        Assert.Equal(["F1", "F2", "B2", "F3", "B3", "F4", "B4"], TurnedStack.Arrange(fronts, backs));
        // Read first sheet first, the last sheet is the one without a back.
        Assert.Equal(["F1", "B4", "F2", "B3", "F3", "B2", "F4"], TurnedStack.Arrange(fronts, backs, reversed: false));
    }

    [Fact]
    public void A_back_too_many_goes_at_the_end_as_scanned()
    {
        // A sheet went through twice on the backs pass.
        var fronts = new List<string> { "F1", "F2" };
        var backs = new List<string> { "B2", "B1", "B1 again" };
        Assert.Equal(["F1", "B1", "F2", "B2", "B1 again"], TurnedStack.Arrange(fronts, backs));
    }

    [Fact]
    public void The_other_order_puts_the_stack_back_in_its_own_places()
    {
        // A page from an earlier scan before the stack and one scanned after it stay put; a back deleted in the review stays deleted.
        var earlier = new Page("earlier");
        var later = new Page("later");
        var f = new[] { new Page("F1"), new Page("F2"), new Page("F3") };
        var b = new[] { new Page("b3"), new Page("b2"), new Page("b1") }; // as scanned, last sheet first
        var ordered = TurnedStack.Rearrange([earlier, .. f, .. b], f, b, reversed: true);
        Assert.Equal("earlier F1 b1 F2 b2 F3 b3", Names(ordered));

        var current = ordered.Where(p => p.Name != "b2").Append(later).ToList();
        Assert.Equal("earlier F1 b3 F2 F3 b1 later", Names(TurnedStack.Rearrange(current, f, b, reversed: false)));
        // Undo's order: the fronts, then the backs as scanned, in the stack's places.
        Assert.Equal("earlier F1 F2 F3 b3 b1 later", Names(TurnedStack.InPlaces(current, [.. f, .. b])));
    }

    [Fact]
    public void A_separator_sheets_other_side_is_its_real_back_not_the_next_page()
    {
        // Four sheets, the first a patch sheet; the backs pass took two (sheets 4 and 3). Paired by position, the patch
        // sheet's "back" would be front 2, a page of the document; really its back wasn't scanned, so nothing is taken.
        bool[] sheet = [true, false, false, false, false, false];
        bool[] blank = [false, false, false, false, false, false];
        Assert.Empty(TurnedStack.SeparatorBacks(4, 2, reversed: true, sheet, blank));
        Assert.Equal([(3, 0), (2, 1)], TurnedStack.Pairs(4, 2));

        // Counts equal: the sheet's own back (scanned last, as the stack's last back) is taken whatever is on it.
        bool[] even = [true, false, false, false, false, false, false, false];
        Assert.Equal([7], TurnedStack.SeparatorBacks(4, 4, reversed: true, even, new bool[8]));
        Assert.Equal([4], TurnedStack.SeparatorBacks(4, 4, reversed: false, even, new bool[8]));
        // A sheet among the backs takes its front; counts differing, only a blank other side is taken.
        bool[] back = [false, false, false, true, false];
        Assert.Empty(TurnedStack.SeparatorBacks(3, 2, true, back, new bool[5]));
        Assert.Equal([2], TurnedStack.SeparatorBacks(3, 2, true, back, [false, false, true, false, false]));
        Assert.Throws<ArgumentException>(() => TurnedStack.SeparatorBacks(2, 2, true, new bool[3], new bool[4]));
    }

    [Fact]
    public void One_sided_feeders_offer_the_turned_stack_and_black_and_white_saves_one_bit()
    {
        Assert.True(ScanChoices.OffersTurnStack(Caps(duplex: false), ScanSource.Adf));
        Assert.False(ScanChoices.OffersTurnStack(Caps(duplex: true), ScanSource.Adf));
        Assert.False(ScanChoices.OffersTurnStack(Caps(duplex: false), ScanSource.Platen));
        Assert.True(ScanChoices.SavesOneBit(ScanColor.BlackAndWhite));
        Assert.False(ScanChoices.SavesOneBit(ScanColor.Grayscale));
    }

    private sealed record Page(string Name);

    private static string Names(IEnumerable<Page> pages) => string.Join(' ', pages.Select(p => p.Name));

    // ---- The preset option ----

    private static InputCaps Input() => new(0, 2550, 0, 4200, ["RGB24", "Grayscale8"], ["image/jpeg"], [150, 300, 600], ["Document"]);

    private static ScannerCapabilities Caps(bool duplex) => new("2.6", "Test", null, Input(), Input(), duplex);

    private static readonly ScanPreset TwoSided = ScanPresets.BuiltIns()[0] with { Source = PresetSource.Feeder, TwoSided = true };

    [Fact]
    public void A_preset_turns_the_stack_on_a_one_sided_feeder_only_when_asked()
    {
        var plain = PresetPlan.For(TwoSided, Caps(duplex: false), null, true, false, turnsStacks: true);
        Assert.False(plain.TurnStack);
        Assert.Contains(Core.CoreStrings.Preset_OneSideOnly, plain.Notes);

        var turning = PresetPlan.For(TwoSided with { TurnStack = true }, Caps(duplex: false), null, true, false, turnsStacks: true);
        Assert.True(turning.TurnStack);
        Assert.Equal(ScanSource.Adf, turning.Request.Source);
        Assert.DoesNotContain(Core.CoreStrings.Preset_OneSideOnly, turning.Notes);

        // A two-sided feeder does it itself; the glass has no stack; an app that can't (Inkvolt PDF's Scan) says one side only.
        var duplex = PresetPlan.For(TwoSided with { TurnStack = true }, Caps(duplex: true), null, true, false, turnsStacks: true);
        Assert.Equal((ScanSource.AdfDuplex, false), (duplex.Request.Source, duplex.TurnStack));
        Assert.False(PresetPlan.For(TwoSided with { TurnStack = true, Source = PresetSource.Glass }, Caps(false), null, true, false, turnsStacks: true).TurnStack);
        var pdfApp = PresetPlan.For(TwoSided with { TurnStack = true }, Caps(duplex: false), null, true, false);
        Assert.False(pdfApp.TurnStack);
        Assert.Contains(Core.CoreStrings.Preset_OneSideOnly, pdfApp.Notes);
        // Off with one side.
        Assert.False(PresetPlan.For(TwoSided with { TwoSided = false, TurnStack = true }, Caps(false), null, true, false, turnsStacks: true).TurnStack);
    }

    [Fact]
    public void The_summary_says_the_stack_is_turned_over()
    {
        Assert.Contains(Core.CoreStrings.Preset_TurnStackShort, ScanPresetText.Summary(TwoSided with { TurnStack = true }));
        Assert.DoesNotContain(Core.CoreStrings.Preset_TurnStackShort, ScanPresetText.Summary(TwoSided));
    }

    [Fact]
    public void Old_presets_read_without_the_new_settings_keep_their_ways()
    {
        // Written before 4.1, 4.3 and 4.4: no turned stack, no smaller file; pages turned upright (on unless turned off).
        var json = """{"Version":1,"Items":[{"Id":"abc","Name":"Old","TwoSided":true,"Source":2}]}""";
        var stored = System.Text.Json.JsonSerializer.Deserialize<ScanPresetSettings>(json)!;
        var preset = ScanPresets.Normalize(stored)[0];
        Assert.Equal((true, false, false, true), (preset.TwoSided, preset.TurnStack, preset.SmallerFile, preset.TurnUpright));
    }
}
