using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

/// <summary>
/// Two-sided printing by hand (roadmap 4.2): the fronts, the stack put back as the prompt says, the backs in the order that stack
/// feeds them (<see cref="HandDuplexPlan"/>), checked on a model of the paper: each sheet ends with its own back. And which way up a
/// printer delivers its sheets, from its IPP answer (<see cref="HandDuplex.FaceOf(string?, IEnumerable{string})"/>).
/// </summary>
public class HandDuplexTests
{
    private sealed class Sheet(int number)
    {
        public int Number { get; } = number;
        public int? Front { get; set; }
        public int? Back { get; set; }
    }

    /// <summary>
    /// The paper, as a printer and a person handle it: the fronts print one sheet at a time, each landing on top of the output stack
    /// (face up or down, the last on top either way); the person sets the top sheet aside when told, puts the stack back as told
    /// (turned over like a page: its order reverses; else as it is), and the tray feeds from the top for the backs.
    /// </summary>
    private static List<Sheet> Run(HandDuplexPlan plan, OutputFace face)
    {
        var output = new List<Sheet>(); // last = top
        for (var i = 0; i < plan.Fronts.Count; i++) output.Add(new Sheet(i) { Front = plan.Fronts[i] });
        var all = output.ToList();
        var reload = plan.Reload(face);
        Sheet? aside = null;
        if (reload.SetAside)
        {
            aside = output[^1];
            output.RemoveAt(output.Count - 1);
        }
        if (reload.TurnOver) output.Reverse();
        var tray = new Stack<Sheet>(output); // pushes bottom first: the top of the output is the top of the tray
        foreach (var back in plan.Backs(face)) tray.Pop().Back = back;
        Assert.Empty(tray); // every sheet went through, none left in the tray
        Assert.True(aside is null || aside.Number == plan.Sheets - 1, "the sheet set aside is the last one");
        return all;
    }

    [Theory]
    [InlineData(OutputFace.Down)]
    [InlineData(OutputFace.Up)]
    public void Every_sheet_gets_its_own_back(OutputFace face)
    {
        foreach (var (pages, copies) in new[] { (1, 1), (2, 1), (3, 1), (4, 1), (7, 1), (10, 1), (3, 2), (4, 3), (5, 3) })
        {
            var plan = HandDuplexPlan.For([.. Enumerable.Range(0, pages)], copies);
            var sheets = Run(plan, face);
            for (var i = 0; i < sheets.Count; i++)
            {
                Assert.Equal(plan.Fronts[i], sheets[i].Front);
                Assert.Equal(plan.SheetBacks[i] < 0 ? null : plan.SheetBacks[i], sheets[i].Back < 0 ? null : sheets[i].Back);
            }
        }
    }

    [Fact]
    public void Five_pages_face_down_go_back_as_they_came_and_the_backs_run_last_sheet_first()
    {
        var plan = HandDuplexPlan.For([0, 1, 2, 3, 4]);
        Assert.Equal([0, 2, 4], plan.Fronts);
        Assert.Equal([1, 3, -1], plan.SheetBacks);
        Assert.Equal([3, 1], plan.Backs(OutputFace.Down)); // page 5's sheet is set aside, not sent through blank
        Assert.Equal(new HandDuplexReload(OutputFace.Down, 3, TurnOver: false, SetAside: true, BlankBacks: 0, LastPage: 5), plan.Reload(OutputFace.Down));
    }

    [Fact]
    public void Face_up_the_stack_is_turned_over_and_the_backs_run_in_order()
    {
        var plan = HandDuplexPlan.For([0, 1, 2, 3]);
        Assert.Equal([1, 3], plan.Backs(OutputFace.Up));
        Assert.Equal([3, 1], plan.Backs(OutputFace.Down));
        var reload = plan.Reload(OutputFace.Up);
        Assert.True(reload.TurnOver);
        Assert.False(reload.SetAside);
        Assert.Null(reload.LastPage);
    }

    [Fact]
    public void Copies_each_start_on_a_sheet_of_their_own()
    {
        var plan = HandDuplexPlan.For([0, 1, 2], copies: 2);
        Assert.Equal([0, 2, 0, 2], plan.Fronts);
        Assert.Equal([1, -1, 1, -1], plan.SheetBacks);
        Assert.Equal([1, -1, 1], plan.Backs(OutputFace.Down)); // the first copy's last sheet goes through blank
        var reload = plan.Reload(OutputFace.Down);
        Assert.Equal(1, reload.BlankBacks);
        Assert.Equal(3, reload.LastPage);
        Assert.Equal(4, plan.Sheets);
        Assert.Equal(BatchPrintSettings.Sheets(3, 2, twoSided: true), plan.Sheets); // the estimate the batch made
    }

    [Fact]
    public void The_sheet_set_aside_is_named_by_its_page_in_the_document()
    {
        // Pages 2, 4 and 6 printed: the last sheet shows page 6, not the third position.
        Assert.Equal(6, HandDuplexPlan.For([0, 1, 2], pageNumber: i => new[] { 2, 4, 6 }[i]).Reload(OutputFace.Down).LastPage);
        // Copy's collated copies of 3 pages come as one padded order: the last sheet is page 3 of its copy, not position 7.
        Assert.Equal(3, HandDuplexPlan.For([0, 1, 2, -1, 0, 1, 2, -1]).Reload(OutputFace.Down).LastPage);
        // Two pages a side: side 2 starts with page 5.
        Assert.Equal(5, HandDuplexPlan.For([0, 1, 2], pageNumber: side => side * 2 + 1).Reload(OutputFace.Up).LastPage);
    }

    [Fact]
    public void One_page_has_no_backs_and_a_copy_sides_order_is_kept()
    {
        Assert.False(HandDuplexPlan.For([0]).HasBacks);
        Assert.True(HandDuplexPlan.For([0, 1]).HasBacks);
        // A copy's sides with a blank one (Copy's 2-up layout ends on a blank side): kept where it is.
        var plan = HandDuplexPlan.For([0, 1, -1, 2]);
        Assert.Equal([0, -1], plan.Fronts);
        Assert.Equal([1, 2], plan.SheetBacks);
    }

    [Fact]
    public void Offered_only_where_the_printer_said_it_cant()
    {
        Assert.True(HandDuplex.Offered(false));
        Assert.False(HandDuplex.Offered(true));
        Assert.False(HandDuplex.Offered(null)); // not known yet
    }

    [Fact]
    public void Face_from_the_printers_output_tray_or_its_default_bin()
    {
        // As an HP LaserJet MFP M234dw answers (no identifiers in it).
        Assert.Equal(OutputFace.Down, HandDuplex.FaceOf("face-down",
            ["type=unRemovableBin;maxcapacity=125;remaining=-3;status=0;name=face-down;stackingorder=firstToLast;pagedelivery=faceDown"]));
        Assert.Equal(OutputFace.Up, HandDuplex.FaceOf("rear", ["name=top;pagedelivery=faceDown", "name=rear;pagedelivery=faceUp;"]));
        Assert.Equal(OutputFace.Up, HandDuplex.FaceOf("face-up", []));
        Assert.Equal(OutputFace.Down, HandDuplex.FaceOf(null, ["pagedelivery=faceDown"])); // one tray: that one
        Assert.Null(HandDuplex.FaceOf("top", []));
        Assert.Null(HandDuplex.FaceOf(null, []));
        Assert.Null(HandDuplex.FaceOf(null, ["name=a;pagedelivery=faceUp", "name=b;pagedelivery=faceDown"])); // which one isn't said
        Assert.Null(HandDuplex.FaceOf(null, [new string('x', 5000) + ";pagedelivery=faceUp"])); // too long to read
    }
}
