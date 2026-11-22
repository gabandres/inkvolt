using System.Text.Json;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

/// <summary>Clean up's "Drop a color" and "Remove punch holes" (roadmap 4.7), on made-up scans.</summary>
public class CleanUpMarksTests
{
    private const int Dpi = 300;

    /// <summary>A color page (BGR) of paper at <paramref name="paper"/>.</summary>
    private static byte[] Page(int w, int h, (byte R, byte G, byte B) paper)
    {
        var px = new byte[w * h * 3];
        for (var i = 0; i < w * h; i++) (px[i * 3], px[i * 3 + 1], px[i * 3 + 2]) = (paper.B, paper.G, paper.R);
        return px;
    }

    private static void Box(byte[] px, int w, int x, int y, int bw, int bh, (byte R, byte G, byte B) c)
    {
        for (var yy = y; yy < y + bh; yy++)
            for (var xx = x; xx < x + bw; xx++)
                (px[(yy * w + xx) * 3], px[(yy * w + xx) * 3 + 1], px[(yy * w + xx) * 3 + 2]) = (c.B, c.G, c.R);
    }

    private static (byte R, byte G, byte B) At(byte[] px, int w, int x, int y) => (px[(y * w + x) * 3 + 2], px[(y * w + x) * 3 + 1], px[(y * w + x) * 3]);

    private static void Noise(byte[] px, double sigma, int seed = 5)
    {
        var rng = new Random(seed);
        for (var i = 0; i < px.Length; i++)
        {
            var g = Math.Sqrt(-2 * Math.Log(1 - rng.NextDouble())) * Math.Cos(2 * Math.PI * rng.NextDouble());
            px[i] = (byte)Math.Clamp(px[i] + g * sigma, 0, 255);
        }
    }

    /// <summary>A red-ruled form with black print on it, a blue pen's note and a green stamp: what each drop leaves.</summary>
    private static byte[] Form(int w, int h)
    {
        var px = Page(w, h, (250, 249, 245));
        for (var y = 100; y < h - 100; y += 60) Box(px, w, 60, y, w - 120, 3, (215, 45, 50)); // the form's red rules
        for (var x = 80; x < w - 120; x += 40) Box(px, w, x, 140, 24, 30, (25, 25, 28)); // black print crossing a rule
        Box(px, w, 80, 300, 300, 6, (40, 70, 190)); // a blue pen's line
        Box(px, w, 500, 300, 80, 80, (40, 150, 70)); // a green stamp
        Box(px, w, 100, 155, 30, 4, (25, 25, 28)); // black over the red rule at y = 160
        return px;
    }

    [Fact]
    public void Red_drops_to_white_and_black_print_stays()
    {
        const int w = 800, h = 600;
        var page = Form(w, h);
        Noise(page, 3);
        var result = PageCleanup.Apply(page, w, h, 3, Dpi, PageFilters.DropColor, drop: DropColor.Red);
        Assert.Equal(PageFilters.DropColor, result.Done);
        var rule = At(result.Pixels, w, 700, 101);
        Assert.True(rule.R > 235 && rule.G > 235 && rule.B > 235, $"the red rule is {rule}");
        var print = At(result.Pixels, w, 90, 150);
        Assert.True(print.R < 60 && print.G < 60 && print.B < 60, $"the black print is {print}");
        var blue = At(result.Pixels, w, 100, 302);
        Assert.True(blue.B > 150 && blue.R < 80, $"the blue pen is {blue}");
        var green = At(result.Pixels, w, 540, 340);
        Assert.True(green.G > 120 && green.R < 80, $"the green stamp is {green}");
        Assert.NotSame(page, result.Pixels); // the scan itself is never written to
    }

    [Fact]
    public void Blue_and_green_drop_by_their_own_hue()
    {
        const int w = 800, h = 600;
        var blue = PageCleanup.Apply(Form(w, h), w, h, 3, Dpi, PageFilters.DropColor, drop: DropColor.Blue).Pixels;
        Assert.True(At(blue, w, 100, 302).R > 235, "the blue pen went white");
        Assert.True(At(blue, w, 700, 101).G < 80, "the red rule stayed");
        var green = PageCleanup.Apply(Form(w, h), w, h, 3, Dpi, PageFilters.DropColor, drop: DropColor.Green).Pixels;
        Assert.True(At(green, w, 540, 340).R > 235, "the stamp went white");
        Assert.True(At(green, w, 100, 302).R < 80, "the blue pen stayed");
    }

    [Fact]
    public void A_picked_color_drops_that_hue_only()
    {
        const int w = 400, h = 300;
        var page = Page(w, h, (250, 250, 250));
        Box(page, w, 20, 20, 100, 40, (150, 60, 180)); // a purple highlighter
        Box(page, w, 200, 20, 100, 40, (215, 45, 50)); // red
        var picked = new DropColor(150, 60, 180);
        Assert.True(picked.IsColorful);
        Assert.False(picked.IsNamed);
        var px = PageCleanup.Apply(page, w, h, 3, Dpi, PageFilters.DropColor, drop: picked).Pixels;
        Assert.True(At(px, w, 50, 40).G > 235);
        Assert.True(At(px, w, 250, 40).G < 80);
    }

    [Fact]
    public void Grey_has_no_hue_to_pick_and_grey_scans_have_no_color_to_drop()
    {
        Assert.False(new DropColor(120, 120, 128).IsColorful);
        Assert.False(new DropColor(30, 30, 30).IsColorful);
        const int w = 100, h = 100;
        var grey = new byte[w * h];
        Array.Fill(grey, (byte)90);
        var result = PageCleanup.Apply(grey, w, h, 1, Dpi, PageFilters.DropColor, drop: DropColor.Red);
        Assert.Equal(PageFilters.None, result.Done);
        Assert.Equal(grey, result.Pixels);
    }

    [Fact]
    public void A_page_without_the_color_is_left_as_it_is()
    {
        const int w = 200, h = 200;
        var page = Page(w, h, (240, 235, 220)); // cream paper: a hue, but hardly any color
        Box(page, w, 20, 20, 100, 20, (20, 20, 20));
        Assert.Equal(PageFilters.None, PageCleanup.Apply(page, w, h, 3, Dpi, PageFilters.DropColor, drop: DropColor.Red).Done);
    }

    [Theory]
    [InlineData("#D22B2B", true)]
    [InlineData("d22b2b", true)]
    [InlineData("#12345", false)]
    [InlineData("#GGGGGG", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Colors_are_read_back_only_as_written(string? hex, bool valid)
    {
        var color = DropColor.Parse(hex);
        Assert.Equal(valid, color is not null);
        if (color is { } c) Assert.Equal(DropColor.Red, c);
        Assert.Equal("#2B55C8", DropColor.Blue.Hex);
        Assert.Equal(DropColor.Blue, DropColor.Parse(DropColor.Blue.Hex));
    }

    [Fact]
    public void The_edits_carry_the_color_only_with_the_filter()
    {
        var dropping = PageEdits.None.WithFilters(PageFilters.DropColor | PageFilters.Whiten, DropColor.Blue);
        Assert.Equal(DropColor.Blue, dropping.Drop);
        Assert.False(dropping.IsEmpty);
        Assert.Null(dropping.WithFilters(PageFilters.Whiten, DropColor.Blue).Drop);
        Assert.Equal(DropColor.Red, PageEdits.None.WithFilters(PageFilters.DropColor, null).Drop); // red unless told
        Assert.NotEqual(PageEdits.None.WithFilters(PageFilters.DropColor, DropColor.Red), dropping.WithFilters(PageFilters.DropColor, DropColor.Blue));

        var cleaned = PageEdits.None.CleanedUp(PageFilters.DropColor | PageFilters.PunchHoles, photos: false, paperEdge: null, measuredAt: 0, DropColor.Green);
        Assert.Equal(DropColor.Green, cleaned!.Drop);
        Assert.Equal(PageFilters.DropColor | PageFilters.PunchHoles, cleaned.Filters);
        // A scan of photos gets what suits a print only: no color dropped, no holes looked for.
        Assert.Null(PageEdits.None.CleanedUp(PageFilters.DropColor | PageFilters.PunchHoles, photos: true, paperEdge: null, measuredAt: 0, DropColor.Green));
    }

    [Fact]
    public void A_kept_page_keeps_its_color()
    {
        var kept = new KeptPage("p.jpg", 300, false, Filters: PageFilters.DropColor, Drop: "#2E9E4F");
        var back = JsonSerializer.Deserialize<KeptPage>(JsonSerializer.Serialize(kept))!;
        Assert.Equal(DropColor.Green, back.Edits.Drop);
        Assert.Null(new KeptPage("p.jpg", 300, false, Filters: PageFilters.Whiten, Drop: "#2E9E4F").Edits.Drop);
        Assert.Equal(DropColor.Red, new KeptPage("p.jpg", 300, false, Filters: PageFilters.DropColor, Drop: "nonsense").Edits.Drop);
    }

    [Fact]
    public void Presets_keep_a_color_they_can_read()
    {
        var list = ScanPresets.Normalize(new ScanPresetSettings
        {
            Items =
            [
                new ScanPreset { Id = "a", Name = "Forms", Cleanup = PageFilters.DropColor | PageFilters.PunchHoles, DropColor = "#2b55c8" },
                new ScanPreset { Id = "b", Name = "Odd", Cleanup = PageFilters.DropColor, DropColor = "blue-ish" },
            ],
        });
        Assert.Equal("#2B55C8", list[0].DropColor);
        Assert.Equal(PageFilters.DropColor | PageFilters.PunchHoles, list[0].Cleanup);
        Assert.Null(list[1].DropColor);
        Assert.Contains("blue dropped", ScanPresetText.Summary(list[0]));
        Assert.Contains("punch holes removed", ScanPresetText.Summary(list[0]));
        Assert.Contains("red dropped", ScanPresetText.Summary(list[1]));
    }

    // ---- Punch holes ----

    /// <summary>A grey page (letter at 300 dpi scaled down to <paramref name="dpi"/>) with lines of blocky words from 1.2 inch in.</summary>
    private static byte[] TextPage(int w, int h, int dpi, byte paper = 238)
    {
        var px = new byte[w * h];
        Array.Fill(px, paper);
        var rng = new Random(11);
        var (letter, line) = (dpi / 20, dpi / 6);
        for (var y = (int)(1.2 * dpi); y + letter < h - 1.2 * dpi; y += line)
            for (var x = (int)(1.2 * dpi); x < w - 1.2 * dpi;)
            {
                var n = 2 + rng.Next(7);
                for (var l = 0; l < n && x < w - 1.2 * dpi; l++, x += letter + 3)
                    for (var yy = y; yy < y + letter; yy++)
                        for (var xx = x; xx < x + letter; xx++) px[yy * w + xx] = 30;
                x += letter;
            }
        return px;
    }

    private static void Disc(byte[] px, int w, double cx, double cy, double r, byte level, double inner = 0, byte innerLevel = 0)
    {
        for (var y = (int)(cy - r - 1); y <= cy + r + 1; y++)
            for (var x = (int)(cx - r - 1); x <= cx + r + 1; x++)
            {
                var d = Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
                if (d <= r) px[y * w + x] = d < inner ? innerLevel : level;
            }
    }

    [Fact]
    public void Three_punched_holes_are_filled_with_the_paper()
    {
        const int w = 2550, h = 3300; // letter at 300 dpi
        var page = TextPage(w, h, Dpi);
        var holes = new[] { 0.95, 5.5, 10.05 }.Select(y => (X: 0.5 * Dpi, Y: y * Dpi)).ToList(); // a three-hole punch on the left
        foreach (var (x, y) in holes) Disc(page, w, x, y, 0.14 * Dpi, 70); // the feeder's dark backing through each hole
        Noise(page, 3);
        var text = page[(int)(3 * Dpi) * w + (int)(1.2 * Dpi)];

        var result = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.PunchHoles);
        Assert.Equal(PageFilters.PunchHoles, result.Done);
        Assert.Equal(3, result.Holes);
        foreach (var (x, y) in holes)
        {
            Assert.InRange(result.Pixels[(int)y * w + (int)x], 225, 250);
            Assert.InRange(result.Pixels[(int)(y + 0.13 * Dpi) * w + (int)x], 225, 250); // the rim too
        }
        Assert.Equal(text, result.Pixels[(int)(3 * Dpi) * w + (int)(1.2 * Dpi)]); // the text is as it was
    }

    [Fact]
    public void A_ring_shadow_and_holes_at_the_top_are_found_too()
    {
        const int w = 2550, h = 3300;
        var page = TextPage(w, h, Dpi);
        Disc(page, w, 0.5 * Dpi, 5.5 * Dpi, 0.15 * Dpi, 110, inner: 0.11 * Dpi, innerLevel: 245); // a hole's shadow, the lid's white in it
        Disc(page, w, 3 * Dpi, 0.45 * Dpi, 0.13 * Dpi, 60);
        Disc(page, w, 5.5 * Dpi, 0.45 * Dpi, 0.13 * Dpi, 60);
        var found = PunchHoles.Find(page, w, h, 1, Dpi);
        Assert.Equal(3, found.Count);
        Assert.Contains(found, f => Math.Abs(f.X - 0.5 * Dpi) < 10 && Math.Abs(f.Y - 5.5 * Dpi) < 10);
    }

    [Fact]
    public void Round_marks_that_arent_holes_stay()
    {
        const int w = 2550, h = 3300;
        var page = TextPage(w, h, Dpi);
        Disc(page, w, 4 * Dpi, 5 * Dpi, 0.15 * Dpi, 40); // a dot in the page's middle
        Disc(page, w, 0.5 * Dpi, 3 * Dpi, 0.04 * Dpi, 40); // a bullet in the margin: too small
        Disc(page, w, 0.6 * Dpi, 7 * Dpi, 0.6 * Dpi, 40); // a big logo: too big
        Disc(page, w, 0.06 * Dpi, 9 * Dpi, 0.14 * Dpi, 40); // a hole cut by the page's edge: not sure what it is
        // A heading's "O" near the edge, between its letters.
        Disc(page, w, 1.0 * Dpi, 1.0 * Dpi, 0.12 * Dpi, 30, inner: 0.07 * Dpi, innerLevel: 238);
        for (var x = 0; x < 2; x++)
            for (var yy = (int)(0.88 * Dpi); yy < 1.12 * Dpi; yy++)
                for (var xx = 0; xx < 0.15 * Dpi; xx++)
                    page[yy * w + (int)((x == 0 ? 0.68 : 1.15) * Dpi) + xx] = 30;
        Assert.Empty(PunchHoles.Find(page, w, h, 1, Dpi));
        Assert.Equal(PageFilters.None, PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.PunchHoles).Done);
    }

    [Fact]
    public void Holes_on_a_color_page_get_its_own_paper_color()
    {
        const int w = 1275, h = 1650; // letter at 150 dpi
        const int dpi = 150;
        var page = Page(w, h, (245, 238, 205)); // yellowish paper
        foreach (var y in new[] { 4.0, 7.0 })
            for (var yy = (int)((y - 0.14) * dpi); yy <= (y + 0.14) * dpi; yy++)
                for (var xx = (int)(0.36 * dpi); xx <= 0.64 * dpi; xx++)
                    if (Math.Pow(xx - 0.5 * dpi, 2) + Math.Pow(yy - y * dpi, 2) <= Math.Pow(0.14 * dpi, 2))
                        (page[(yy * w + xx) * 3], page[(yy * w + xx) * 3 + 1], page[(yy * w + xx) * 3 + 2]) = (40, 40, 40);
        var result = PageCleanup.Apply(page, w, h, 3, dpi, PageFilters.PunchHoles);
        Assert.Equal(2, result.Holes);
        Assert.Equal((245, 238, 205), At(result.Pixels, w, (int)(0.5 * dpi), 4 * dpi));
    }

    [Fact]
    public void A_dark_page_or_one_too_small_has_no_holes()
    {
        var dark = new byte[600 * 600];
        Array.Fill(dark, (byte)60);
        Assert.Empty(PunchHoles.Find(dark, 600, 600, 1, 300));
        Assert.Empty(PunchHoles.Find(new byte[100], 10, 10, 1, 300));
        Assert.Empty(PunchHoles.Find(new byte[10], 100, 100, 1, 300)); // fewer pixels than it says: nothing read past the end
    }
}
