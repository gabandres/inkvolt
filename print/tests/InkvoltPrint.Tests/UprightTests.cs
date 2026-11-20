using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Tests;

/// <summary>
/// Which way up a straightened page of text is (<see cref="Upright"/>, shared with Inkvolt PDF's Recognize Text and
/// Compare): more ink rises above a line's middle than hangs below it. A synthetic page at 100 dpi (850 × 1100).
/// </summary>
public class UprightTests
{
    private const int W = 850, H = 1100;

    /// <summary>
    /// Lines of "text": a dense middle band 8 rows tall, ascenders (4 rows, a third inked) above it and descenders (3 rows,
    /// an eighth inked) below; a shaded picture from <paramref name="pictureTop"/> 300 rows tall, its ink thinning to its foot.
    /// </summary>
    private static GrayImage Page(int lines, int? pictureTop = null)
    {
        var px = Enumerable.Repeat((byte)245, W * H).ToArray();
        void Ink(int x, int y) => px[y * W + x] = 20;
        for (var l = 0; l < lines; l++)
        {
            var top = 80 + l * 26;
            for (var x = 100; x < 750; x++)
            {
                for (var y = top; y < top + 4; y++) if (x % 3 == 0) Ink(x, y);
                for (var y = top + 4; y < top + 12; y++) if (x % 7 != 6) Ink(x, y);
                for (var y = top + 12; y < top + 15; y++) if (x % 8 == 0) Ink(x, y);
            }
        }
        if (pictureTop is { } p)
            for (var y = p; y < p + 300; y++)
                for (var x = 100; x < 100 + 650 * (p + 300 - y) / 300; x++)
                    Ink(x, y); // dark all across at the top, less and less of it to the foot
        return new GrayImage(W, H, px);
    }

    private static GrayImage UpsideDown(GrayImage g) => new(g.Width, g.Height, [.. g.Pixels.Reverse()]);

    [Fact]
    public void A_page_of_text_reads_which_way_up_it_is()
    {
        var page = Page(30);
        Assert.Equal((false, true), Upright.UpsideDown(page));
        Assert.Equal((true, true), Upright.UpsideDown(UpsideDown(page)));
    }

    [Fact]
    public void A_shaded_picture_doesnt_turn_a_page_of_text_over()
    {
        // Ten lines of text above a picture whose shading ends in paper at its foot: as a "line", nearly all of it lies
        // below its darkest rows and outweighed the text.
        var page = Page(10, pictureTop: 500);
        Assert.Equal((false, true), Upright.UpsideDown(page));
        Assert.Equal((true, true), Upright.UpsideDown(UpsideDown(page)));
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
