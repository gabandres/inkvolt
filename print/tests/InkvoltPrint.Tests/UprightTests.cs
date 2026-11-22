using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Tests;

/// <summary>
/// Which way up a straightened page of text is (<see cref="Upright"/>, shared with Inkvolt PDF's Recognize Text and
/// Compare): more ink rises above a line's middle than hangs below it. A synthetic page at 100 dpi (850 × 1100).
/// </summary>
public class UprightTests
{
    private const int W = 850, H = 1100;

    private static byte[] Paper() => Enumerable.Repeat((byte)245, W * H).ToArray();

    /// <summary>
    /// A line of "text" from <paramref name="top"/>, 15 rows: a dense middle band 8 rows tall, ascenders (4 rows, a third
    /// inked) above it and descenders (3 rows, an eighth inked) below.
    /// </summary>
    private static void Text(byte[] px, int top, int x0 = 100, int x1 = 750)
    {
        for (var x = x0; x < x1; x++)
        {
            for (var y = top; y < top + 4; y++) if (x % 3 == 0) px[y * W + x] = 20;
            for (var y = top + 4; y < top + 12; y++) if (x % 7 != 6) px[y * W + x] = 20;
            for (var y = top + 12; y < top + 15; y++) if (x % 8 == 0) px[y * W + x] = 20;
        }
    }

    /// <summary>A shaded picture from <paramref name="top"/>, 300 rows: dark all across at its top, less and less of it to its foot.</summary>
    private static void Picture(byte[] px, int top)
    {
        for (var y = top; y < top + 300; y++)
            for (var x = 100; x < 100 + 650 * (top + 300 - y) / 300; x++)
                px[y * W + x] = 20;
    }

    /// <summary><paramref name="lines"/> lines of text 26 rows apart from row 80; a picture from <paramref name="pictureTop"/>.</summary>
    private static GrayImage Page(int lines, int? pictureTop = null)
    {
        var px = Paper();
        for (var l = 0; l < lines; l++) Text(px, 80 + l * 26);
        if (pictureTop is { } p) Picture(px, p);
        return new GrayImage(W, H, px);
    }

    private static GrayImage UpsideDown(GrayImage g) => new(g.Width, g.Height, [.. g.Pixels.Reverse()]);

    private static void ReadsUpright(GrayImage page)
    {
        Assert.Equal((false, true), Upright.UpsideDown(page));
        Assert.Equal((true, true), Upright.UpsideDown(UpsideDown(page)));
    }

    [Fact]
    public void A_page_of_text_reads_which_way_up_it_is() => ReadsUpright(Page(30));

    // ---- PageUpright: the scan review's turn (roadmap 4.3) ----

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public void A_page_fed_any_way_round_is_turned_upright(int fedTurns)
    {
        var page = Page(30);
        var fed = new GrayImage(fedTurns % 2 == 0 ? W : H, fedTurns % 2 == 0 ? H : W, ScanCleanup.Turn(page.Pixels, W, H, 1, fedTurns));
        var found = PageUpright.Find(fed, 100);
        Assert.True(found.Sure);
        Assert.Equal((4 - fedTurns) % 4, found.Turns);
    }

    [Fact]
    public void A_page_it_isnt_sure_of_isnt_turned()
    {
        // Blank paper, a picture alone, lines with as much ink above as below (bars): no turn.
        Assert.Equal(0, PageUpright.Find(new GrayImage(W, H, Paper()), 100).Turns);
        var picture = Paper();
        Picture(picture, 300);
        Assert.False(PageUpright.Find(new GrayImage(W, H, picture), 100).Sure);
        var bars = Paper();
        for (var l = 0; l < 30; l++)
            for (var y = 80 + l * 26; y < 92 + l * 26; y++)
                for (var x = 100; x < 750; x++)
                    bars[y * W + x] = 20;
        var found = PageUpright.Find(new GrayImage(W, H, bars), 100);
        Assert.Equal(0, found.Turns);
        Assert.Equal(UprightFound.Unsure, PageUpright.Find(new GrayImage(10, 10, new byte[100]), 100));
        Assert.Equal(UprightFound.Unsure, PageUpright.Find(Page(30), double.NaN));
    }

    [Fact]
    public void A_copy_finer_than_150_dpi_is_read_at_about_100()
    {
        // The same page at 300 dpi (each pixel 3 × 3): read as at 100.
        var page = UpsideDown(Page(30));
        var big = new byte[W * 3 * H * 3];
        for (var y = 0; y < H * 3; y++)
            for (var x = 0; x < W * 3; x++)
                big[y * W * 3 + x] = page.Pixels[y / 3 * W + x / 3];
        Assert.Equal(2, PageUpright.Find(new GrayImage(W * 3, H * 3, big), 300).Turns);
    }

    [Theory]
    [InlineData(null, true)]
    [InlineData("", true)]
    [InlineData("en-US", true)]
    [InlineData("es", true)]
    [InlineData("ru-RU", true)]
    [InlineData("el", true)]
    [InlineData("he-IL", false)]
    [InlineData("ar", false)]
    [InlineData("fa-IR", false)]
    [InlineData("zh-Hans-CN", false)]
    [InlineData("ja", false)]
    [InlineData("hi-IN", false)]
    [InlineData("not a tag!", true)]
    public void Only_scripts_whose_letters_rise_above_the_line_are_turned(string? language, bool suits) =>
        Assert.Equal(suits, PageUpright.SuitsLanguage(language));

    [Theory]
    [InlineData(0.2, 0)]
    [InlineData(-3.5, -3.5)]
    [InlineData(12, 0)]
    [InlineData(double.NaN, 0)]
    public void A_sideways_page_is_straightened_within_the_reviews_limits(double skew, double expected) =>
        Assert.Equal(expected, PageUpright.StraightenBy(skew));

    [Fact]
    public void A_shaded_picture_doesnt_turn_a_page_of_text_over() =>
        // Ten lines of text above a picture whose shading ends in paper at its foot: as a "line", nearly all of it lies
        // below its darkest rows and outweighed the text.
        ReadsUpright(Page(10, pictureTop: 500));

    [Fact]
    public void A_picture_and_its_one_line_caption()
    {
        // Two runs, the picture's 300 rows and the caption's 15: the lines' height is the caption's, not the picture's.
        var px = Paper();
        Picture(px, 400);
        Text(px, 720);
        ReadsUpright(new GrayImage(W, H, px));
    }

    [Fact]
    public void A_form_whose_rules_outnumber_its_lines()
    {
        // Rules 4 rows thick between and below the lines: too short to be text, they don't set the lines' height.
        var px = Paper();
        for (var l = 0; l < 8; l++) Text(px, 80 + l * 26);
        for (var r = 0; r < 14; r++)
            for (var y = 99 + r * 26; y < 103 + r * 26; y++)
                for (var x = 100; x < 750; x++)
                    px[y * W + x] = 20;
        ReadsUpright(new GrayImage(W, H, px));
    }

    [Fact]
    public void A_wide_picture_and_a_narrow_column_of_text()
    {
        // The picture's rows set how faint ink may be to count; a column 40 px wide has ascenders and descenders fainter
        // than that, read once the picture is left out.
        var px = Paper();
        for (var y = 80; y < 280; y++)
            for (var x = 60; x < 790; x++)
                px[y * W + x] = 20;
        for (var l = 0; l < 12; l++) Text(px, 400 + l * 26, 100, 140);
        ReadsUpright(new GrayImage(W, H, px));
    }

    [Fact]
    public void Tight_paragraphs_beside_one_line_items_are_lines()
    {
        // Eight lines set with no white between are one run of 120 rows; three items apart. The run is cut into its lines
        // and counts, not left out as a picture.
        var px = Paper();
        for (var l = 0; l < 8; l++) Text(px, 80 + l * 15);
        var items = Paper();
        foreach (var top in new[] { 400, 426, 452 })
        {
            Text(px, top);
            Text(items, top);
        }
        var page = new GrayImage(W, H, px);
        ReadsUpright(page);
        var (above, _) = Upright.AboveBelow(page);
        var (itemsAbove, _) = Upright.AboveBelow(new GrayImage(W, H, items));
        Assert.True(above > 3 * itemsAbove, $"{above} / {itemsAbove}");
    }

    [Fact]
    public void A_heading_twice_the_bodys_height_is_still_a_line()
    {
        // The heading's own rows count: its ascenders are what say which way is up here, with only two body lines.
        var px = Page(2).Pixels;
        for (var x = 100; x < 750; x++)
        {
            for (var y = 20; y < 28; y++) if (x % 3 == 0) px[y * W + x] = 20;
            for (var y = 28; y < 44; y++) if (x % 7 != 6) px[y * W + x] = 20;
            for (var y = 44; y < 50; y++) if (x % 8 == 0) px[y * W + x] = 20;
        }
        var (above, below) = Upright.AboveBelow(new GrayImage(W, H, px));
        var (bodyAbove, bodyBelow) = Upright.AboveBelow(Page(2));
        Assert.True(above > bodyAbove && below > bodyBelow, $"{above} {below} / {bodyAbove} {bodyBelow}");
    }
}
