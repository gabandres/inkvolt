using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Tests;

/// <summary>Blank page and skew detection on synthetic scans: a letter page at 100 dpi (850 × 1100), as the app analyses it.</summary>
public class ImagingTests
{
    private const int W = 850, H = 1100;

    /// <summary>Off-white paper with scanner noise (±6 levels, repeatable).</summary>
    private static byte[] Paper(byte level = 242, int seed = 1)
    {
        var random = new Random(seed);
        var pixels = new byte[W * H];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)(level + random.Next(-6, 7));
        return pixels;
    }

    private static void Fill(byte[] pixels, int x, int y, int w, int h, byte level)
    {
        for (var yy = y; yy < y + h; yy++)
            for (var xx = x; xx < x + w; xx++)
                pixels[yy * W + xx] = level;
    }

    /// <summary>A page of text lines (word-shaped bars, 8 px tall every 24 px), turned <paramref name="degrees"/> clockwise.</summary>
    private static GrayImage TextPage(double degrees, int lines = 30)
    {
        var pixels = Paper();
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
            {
                // Where this pixel was on the straight page.
                var (dx, dy) = (x - W / 2.0, y - H / 2.0);
                var qx = cos * dx + sin * dy + W / 2.0;
                var qy = -sin * dx + cos * dy + H / 2.0;
                var row = (qy - 150) / 24;
                if (qx < 110 || qx > 740 || row < 0 || row >= lines || qy - 150 - (int)row * 24 >= 8) continue;
                if ((int)(qx - 110) % 70 < 58) pixels[y * W + x] = 40; // words with gaps
            }
        return new GrayImage(W, H, pixels);
    }

    [Fact]
    public void Plain_paper_with_noise_specks_and_dark_edges_is_blank()
    {
        var pixels = Paper();
        foreach (var (x, y) in new[] { (200, 300), (500, 640), (610, 900), (333, 333) }) pixels[y * W + x] = 20; // lone dust specks
        Fill(pixels, 0, 0, W, 30, 30);   // lid shadow along the top edge
        Fill(pixels, 0, 0, 20, H, 60);   // feeder edge
        Fill(pixels, 30, 500, 20, 20, 0); // punched hole in the margin

        var page = new GrayImage(W, H, pixels);

        Assert.True(BlankPage.IsBlank(page), $"coverage {BlankPage.InkCoverage(page):P4}");
    }

    [Fact]
    public void Show_through_from_the_back_is_still_blank()
    {
        var pixels = Paper();
        for (var row = 0; row < 30; row++) Fill(pixels, 110, 150 + row * 24, 630, 8, 210); // faint mirror of the back's text

        Assert.True(BlankPage.IsBlank(new GrayImage(W, H, pixels)));
    }

    [Fact]
    public void One_short_word_is_not_blank()
    {
        var pixels = Paper();
        Fill(pixels, 400, 520, 40, 10, 50); // about "Page 2" at 100 dpi, as a solid bar

        Assert.False(BlankPage.IsBlank(new GrayImage(W, H, pixels)));
    }

    [Fact]
    public void Text_and_dark_pages_are_not_blank()
    {
        Assert.False(BlankPage.IsBlank(TextPage(0)));
        Assert.False(BlankPage.IsBlank(new GrayImage(W, H, Paper(level: 70)))); // a dark photo, even if smooth
    }

    [Theory]
    [InlineData(3)]
    [InlineData(-2.5)]
    [InlineData(1.2)]
    [InlineData(-7)]
    [InlineData(9.5)]
    public void Finds_the_skew_of_a_text_page(double degrees) =>
        Assert.Equal(degrees, Deskew.Angle(TextPage(degrees)), 0.15);

    [Fact]
    public void Straight_and_nearly_straight_pages_are_left_alone()
    {
        Assert.Equal(0, Deskew.Angle(TextPage(0)));
        Assert.Equal(0, Deskew.Angle(TextPage(0.2)));
    }

    [Fact]
    public void No_text_lines_no_answer()
    {
        Assert.Equal(0, Deskew.Angle(new GrayImage(W, H, Paper()))); // blank

        // A photo-like page: smooth blotches, no lines.
        var pixels = Paper();
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
                pixels[y * W + x] = (byte)(128 + 100 * Math.Sin(x / 37.0) * Math.Cos(y / 53.0));
        Assert.Equal(0, Deskew.Angle(new GrayImage(W, H, pixels)));
    }

    [Fact]
    public void Turning_a_skewed_page_back_straightens_it()
    {
        var skewed = TextPage(4);

        var straight = PageRotate.Rotate(skewed.Pixels, W, H, W, 1, -4);

        Assert.Equal(0, Deskew.Angle(new GrayImage(W, H, straight)));
        Assert.Equal(255, straight[0]); // the corner the page turned away from is white
        Assert.Equal(skewed.Pixels, PageRotate.Rotate(skewed.Pixels, W, H, W, 1, 0));
    }

    [Fact]
    public void Rotation_keeps_colour_channels_apart()
    {
        // 3 × 3 BGR, stride padded to 12: a quarter turn moves the blue top-left pixel to the top-right.
        var pixels = new byte[3 * 12];
        Array.Fill(pixels, (byte)200);
        (pixels[0], pixels[1], pixels[2]) = (255, 0, 0);

        var turned = PageRotate.Rotate(pixels, 3, 3, 12, 3, 90);

        Assert.Equal(new byte[] { 255, 0, 0 }, turned[6..9]);
        Assert.Equal(new byte[] { 200, 200, 200 }, turned[0..3]);
    }

    [Fact]
    public void Crop_follows_the_page_when_it_turns()
    {
        var box = new CropBox(0.1, 0.2, 0.3, 0.4);

        Assert.Equal(new CropBox(0.4, 0.1, 0.4, 0.3), box.Turn(1)); // top-left area → top-right after a clockwise quarter
        Assert.Equal(box, box.Turn(4));
        Assert.Equal(box.Turn(3), box.Turn(-1));
        AssertClose(box, box.Turn(1).Turn(-1));
    }

    [Fact]
    public void Edits_keep_the_crop_in_the_straightened_page()
    {
        var turned = PageEdits.None.Turned(1);
        var shown = new CropBox(0.5, 0, 0.5, 1); // right half of the turned page = top half of the scan

        var edits = turned.WithShownCrop(shown);

        AssertClose(new CropBox(0, 0, 1, 0.5), edits.Crop!.Value);
        AssertClose(shown, edits.ShownCrop);
        Assert.Equal(3, PageEdits.None.Turned(-1).QuarterTurns);
        Assert.True(PageEdits.None.Turned(4).IsEmpty);
        Assert.True(PageEdits.None.WithShownCrop(CropBox.Full).IsEmpty);
        Assert.False(edits.IsEmpty);
    }

    private static void AssertClose(CropBox expected, CropBox actual)
    {
        Assert.Equal(expected.X, actual.X, 9);
        Assert.Equal(expected.Y, actual.Y, 9);
        Assert.Equal(expected.Width, actual.Width, 9);
        Assert.Equal(expected.Height, actual.Height, 9);
    }
}
