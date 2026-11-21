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
