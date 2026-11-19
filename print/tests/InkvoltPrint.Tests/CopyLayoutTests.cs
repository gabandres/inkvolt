using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class CopyLayoutTests
{
    // Letter paper and sides in DIPs (96 per inch), like the spooler hands them to the paginator.
    private const double LetterW = 816, LetterH = 1056;
    private static readonly (double, double) CardScan = (4.5 * 96, 3 * 96);

    [Fact]
    public void Id_card_sides_print_at_actual_size_centred_in_each_half()
    {
        var (front, back) = CopyLayout.IdCard(LetterW, LetterH, CardScan, CardScan);

        Assert.Equal(new Placement((816 - 432) / 2.0, (528 - 288) / 2.0, 432, 288), front);
        Assert.Equal(new Placement((816 - 432) / 2.0, 528 + (528 - 288) / 2.0, 432, 288), back);
        Assert.True(front.Y + front.Height <= LetterH / 2);
        Assert.True(back.Y >= LetterH / 2);
    }

    [Fact]
    public void Oversized_sides_shrink_together_to_fit_their_half_with_margins()
    {
        // A whole Letter page scanned by mistake for the back: both sides take its (smaller) scale.
        var (front, back) = CopyLayout.IdCard(LetterW, LetterH, CardScan, (LetterW, LetterH));

        Assert.True(back.Height <= LetterH / 2 - 2 * CopyLayout.IdCardMargin + 1e-9);
        Assert.True(back.Y >= LetterH / 2 + CopyLayout.IdCardMargin - 1e-9);
        var scale = back.Height / LetterH;
        Assert.Equal(CardScan.Item1 * scale, front.Width, 6);
        Assert.Equal(CardScan.Item2 * scale, front.Height, 6);
    }

    [Fact]
    public void Id_card_on_a4_stays_actual_size()
    {
        var (front, _) = CopyLayout.IdCard(793.7, 1122.5, CardScan, CardScan);

        Assert.Equal((432, 288), (front.Width, front.Height));
    }

    [Fact]
    public void Copied_page_is_centred_at_actual_size_and_only_shrinks()
    {
        Assert.Equal(new PagePlacement(new Placement(0, 0, LetterW, LetterH), false), CopyLayout.Page(LetterW, LetterH, LetterW, LetterH));
        Assert.Equal(new PagePlacement(new Placement(216, 336, 384, 384), false), CopyLayout.Page(384, 384, LetterW, LetterH)); // small page: not enlarged

        var a4OnLetter = CopyLayout.Page(793.7, 1122.5, LetterW, LetterH).At;
        Assert.Equal(LetterH, a4OnLetter.Height, 6);
        Assert.Equal(0, a4OnLetter.Y, 6);
    }

    [Fact]
    public void Landscape_copy_is_turned_like_it_prints()
    {
        // A 6 × 4 in photo on portrait Letter: turned a quarter (as the print path does), not shrunk.
        var p = CopyLayout.Page(576, 384, LetterW, LetterH);

        Assert.True(p.Rotated);
        Assert.Equal(new Placement((LetterW - 384) / 2, (LetterH - 576) / 2, 384, 576), p.At);
    }

    [Fact]
    public void Scanned_size_in_inches_from_pixels_and_dpi()
    {
        Assert.Equal((8.5, 11), CopyLayout.Inches(2550, 3300, 300));
        Assert.Equal((4.5, 3), CopyLayout.Inches(675, 450, 150));
        Assert.Equal((0, 0), CopyLayout.Inches(100, 100, 0));
    }

    [Fact]
    public void Id_card_scan_is_the_glass_corner_and_fits_the_m234dw_platen()
    {
        var caps = ScannerCapabilities.Parse(Fixture.Xml("eSCL_ScannerCapabilities.xml"));
        var request = CopyLayout.IdCardRequest(ScanColor.Grayscale, 300);

        var settings = EsclXml.BuildScanSettings(request, caps);
        var region = settings.Descendants(EsclXml.Pwg + "ScanRegion").Single();

        Assert.Equal(ScanSource.Platen, request.Source);
        Assert.Equal("1350", region.Element(EsclXml.Pwg + "Width")!.Value);
        Assert.Equal("900", region.Element(EsclXml.Pwg + "Height")!.Value);
        Assert.Equal("0", region.Element(EsclXml.Pwg + "XOffset")!.Value);
        Assert.Equal("Grayscale8", settings.Descendants(EsclXml.Scan + "ColorMode").Single().Value);
    }

    // ------------------------------------------------------------------ 2-up, 4-up, collation

    private static readonly (double W, double H) LetterPage = (LetterW, LetterH);

    [Fact]
    public void Pages_are_grouped_by_side_in_reading_order()
    {
        Assert.Equal([[0, 1], [2, 3], [4]], CopyLayout.Sides(5, 2));
        Assert.Equal([[0, 1, 2, 3], [4]], CopyLayout.Sides(5, 4));
        Assert.Equal([[0], [1]], CopyLayout.Sides(2, 1));
        Assert.Empty(CopyLayout.Sides(0, 4));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(-2)]
    [InlineData(int.MaxValue)]
    public void Only_one_two_or_four_pages_per_sheet(int perSheet)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => CopyLayout.Sides(3, perSheet));
        Assert.Throws<ArgumentOutOfRangeException>(() => CopyLayout.NUp([LetterPage], perSheet, LetterW, LetterH));
    }

    [Fact]
    public void Two_up_on_portrait_paper_turns_the_pages_and_stacks_them_first_on_top()
    {
        var placed = CopyLayout.NUp([LetterPage, LetterPage], 2, LetterW, LetterH);

        Assert.Equal(2, placed.Count);
        Assert.All(placed, p => Assert.True(p.Rotated)); // portrait pages in landscape cells: the sheet reads turned
        var (top, bottom) = (placed[0].At, placed[1].At);
        Assert.True(top.Y + top.Height <= bottom.Y + 1e-9);
        Assert.Equal(top.Width, bottom.Width, 6);
        Assert.Equal(LetterW / LetterH, top.Height / top.Width, 6); // turned, proportions kept
        AssertInside(placed, LetterW, LetterH);
    }

    [Fact]
    public void Two_up_on_landscape_paper_puts_them_side_by_side_unturned()
    {
        var placed = CopyLayout.NUp([LetterPage, LetterPage], 2, LetterH, LetterW);

        Assert.All(placed, p => Assert.False(p.Rotated));
        Assert.True(placed[0].At.X + placed[0].At.Width <= placed[1].At.X + 1e-9);
        Assert.Equal(placed[0].At.Y, placed[1].At.Y, 6);
        AssertInside(placed, LetterH, LetterW);
    }

    [Fact]
    public void Four_up_goes_left_to_right_then_top_to_bottom()
    {
        var placed = CopyLayout.NUp([LetterPage, LetterPage, LetterPage, LetterPage], 4, LetterW, LetterH);

        Assert.All(placed, p => Assert.False(p.Rotated));
        var at = placed.Select(p => p.At).ToList();
        Assert.True(at[0].X < at[1].X && at[0].Y == at[1].Y);
        Assert.True(at[2].X == at[0].X && at[2].Y > at[0].Y);
        Assert.True(at[3].X == at[1].X && at[3].Y == at[2].Y);
        Assert.True(at[0].Y + at[0].Height <= at[2].Y + 1e-9 && at[0].X + at[0].Width <= at[1].X + 1e-9); // no overlap
        AssertInside(placed, LetterW, LetterH);
    }

    [Fact]
    public void Four_up_turns_landscape_pages_and_leaves_short_sides_empty()
    {
        var placed = CopyLayout.NUp([(LetterH, LetterW), (LetterH, LetterW), (LetterH, LetterW)], 4, LetterW, LetterH);

        Assert.Equal(3, placed.Count);
        Assert.All(placed, p => Assert.True(p.Rotated));
    }

    [Fact]
    public void One_page_per_sheet_is_the_plain_copy()
    {
        var placed = Assert.Single(CopyLayout.NUp([(400, 300)], 1, LetterW, LetterH, PageSizing.FitToPaper));
        Assert.Equal(CopyLayout.Page(400, 300, LetterW, LetterH, PageSizing.FitToPaper), placed);
    }

    [Fact]
    public void A_page_with_no_size_lands_somewhere_finite()
    {
        var placed = CopyLayout.NUp([(0, 0), (-5, double.Epsilon), LetterPage], 4, LetterW, LetterH);

        Assert.All(placed, p => Assert.True(double.IsFinite(p.At.X) && double.IsFinite(p.At.Y) && double.IsFinite(p.At.Width) && double.IsFinite(p.At.Height)));
        Assert.Empty(CopyLayout.NUp([], 2, LetterW, LetterH));
    }

    private static void AssertInside(IEnumerable<PagePlacement> placed, double paperW, double paperH)
    {
        foreach (var (at, _) in placed)
        {
            Assert.True(at.X >= CopyLayout.NUpMargin - 1e-9 && at.Y >= CopyLayout.NUpMargin - 1e-9, $"{at}");
            Assert.True(at.X + at.Width <= paperW - CopyLayout.NUpMargin + 1e-9 && at.Y + at.Height <= paperH - CopyLayout.NUpMargin + 1e-9, $"{at}");
        }
    }

    [Fact]
    public void Collated_copies_print_each_side_once_and_leave_the_copies_to_the_queue()
    {
        Assert.Equal(("0 1 2", 2), Order(3, 2, collate: true, twoSided: false));
        Assert.Equal(("0 1 2 3", 2), Order(4, 2, collate: true, twoSided: true)); // even: each copy ends on a full sheet
        Assert.Equal(("0 1", 1), Order(2, 1, collate: false, twoSided: true)); // one copy: nothing to collate
        Assert.Equal(("0 1 2", 1), Order(3, 1, collate: true, twoSided: true)); // one copy: its last back is blank anyway
    }

    [Fact]
    public void Collated_two_sided_copies_of_an_odd_count_each_end_on_a_blank_back()
    {
        // Left to the queue's copy count, copy 2 would start on copy 1's last back: made here instead, one copy on the ticket.
        Assert.Equal(("0 1 2 -1 0 1 2 -1 0 1 2 -1", 1), Order(3, 3, collate: true, twoSided: true));
        Assert.Equal(("0 -1 0 -1", 1), Order(1, 2, collate: true, twoSided: true));
        Assert.Equal(6, CopyLayout.Sheets(5, 2, 3, twoSided: true)); // 3 sides: 2 sheets a copy, as the order prints them
    }

    [Theory]
    [InlineData(5, 2, 0, "0 1")]
    [InlineData(5, 2, 2, "4")]
    [InlineData(5, 2, 3, "")]
    [InlineData(5, 4, -1, "")]
    [InlineData(int.MaxValue, 4, int.MaxValue, "")]
    public void A_side_holds_its_pages_and_a_side_past_the_end_none(int pages, int perSheet, int side, string expected) =>
        Assert.Equal(expected, string.Join(' ', CopyLayout.PagesOnSide(pages, perSheet, side)));

    [Fact]
    public void Uncollated_copies_repeat_each_sheet_with_one_copy_on_the_ticket()
    {
        Assert.Equal(("0 0 1 1 2 2", 1), Order(3, 2, collate: false, twoSided: false));
        // Two-sided: a sheet is a side and its back; the odd last side gets a blank back so each copy is its own sheet.
        Assert.Equal(("0 1 0 1 2 -1 2 -1", 1), Order(3, 2, collate: false, twoSided: true));
    }

    [Fact]
    public void Odd_counts_are_harmless()
    {
        Assert.Equal(("", 5), Order(0, 5, collate: false, twoSided: true));
        Assert.Equal(("0", 1), Order(1, 0, collate: false, twoSided: false));
        Assert.Equal(("0", 1), Order(1, -7, collate: true, twoSided: false));
    }

    /// <summary>The order as text ("0 1 -1"), so a tuple compares by value.</summary>
    private static (string, int) Order(int sides, int copies, bool collate, bool twoSided)
    {
        var (order, ticket) = CopyLayout.Order(sides, copies, collate, twoSided);
        return (string.Join(' ', order), ticket);
    }

    [Theory]
    [InlineData(5, 1, 1, false, 5)]
    [InlineData(5, 2, 1, false, 3)]
    [InlineData(5, 2, 3, true, 6)] // 3 sides, 2 sheets two-sided, 3 copies
    [InlineData(9, 4, 2, true, 4)] // 3 sides, 2 sheets two-sided, 2 copies
    [InlineData(0, 4, 3, false, 0)]
    public void Sheets_count_sides_paper_and_copies(int pages, int perSheet, int copies, bool twoSided, int expected) =>
        Assert.Equal(expected, CopyLayout.Sheets(pages, perSheet, copies, twoSided));
}
