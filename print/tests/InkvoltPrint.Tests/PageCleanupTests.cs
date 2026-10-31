using System.Diagnostics;
using System.Text.Json;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

/// <summary>The scan review's filters (roadmap 2.3), on made-up pages. What they do for Windows' recognizer: pdf/tools/ocr-corpus, cleanup.</summary>
public class PageCleanupTests
{
    private const int Dpi = 300;

    /// <summary>A page: paper at <paramref name="paper"/>, lines of blocky "words" (ink level <paramref name="ink"/>) in the given area.</summary>
    private static byte[] TextPage(int w, int h, byte paper = 230, byte ink = 30, int? left = null, int? top = null, int? right = null, int? bottom = null)
    {
        var px = new byte[w * h];
        Array.Fill(px, paper);
        Words(px, w, left ?? w / 10, top ?? h / 10, right ?? w - w / 10, bottom ?? h - h / 10, ink);
        return px;
    }

    private static void Words(byte[] px, int w, int left, int top, int right, int bottom, byte ink)
    {
        var rng = new Random(7);
        for (var y = top; y + 30 < bottom; y += 50)
            for (var x = left; x < right - 40;)
            {
                var letters = 3 + rng.Next(6);
                for (var l = 0; l < letters && x < right - 20; l++, x += 22)
                    Fill(px, w, x, y, 14, 28, ink);
                x += 24;
            }
    }

    private static void Fill(byte[] px, int w, int x, int y, int bw, int bh, byte level)
    {
        for (var yy = y; yy < y + bh; yy++)
            for (var xx = x; xx < x + bw; xx++)
                px[yy * w + xx] = level;
    }

    private static void Noise(byte[] px, double sigma, int seed = 3)
    {
        var rng = new Random(seed);
        for (var i = 0; i < px.Length; i++)
        {
            var g = Math.Sqrt(-2 * Math.Log(1 - rng.NextDouble())) * Math.Cos(2 * Math.PI * rng.NextDouble());
            px[i] = (byte)Math.Clamp(px[i] + g * sigma, 0, 255);
        }
    }

    /// <summary>A sheet (its own pixels) on a lid of the given level; the scan is w × h at 100 pixels an inch (the analysis copy).</summary>
    private static byte[] OnLid(byte[] sheet, int sw, int sh, int w, int h, int x0, int y0, byte lid)
    {
        var px = new byte[w * h];
        Array.Fill(px, lid);
        for (var y = 0; y < sh; y++) Array.Copy(sheet, y * sw, px, (y + y0) * w + x0, sw);
        return px;
    }

    private static void Inside(CropBox? found, double x, double y, double right, double bottom, double tolerance = 0.012)
    {
        Assert.NotNull(found);
        var b = found.Value;
        Assert.InRange(b.X, x - tolerance, x + 0.002);
        Assert.InRange(b.Y, y - tolerance, y + 0.002);
        Assert.InRange(b.X + b.Width, right - 0.002, right + tolerance);
        Assert.InRange(b.Y + b.Height, bottom - 0.002, bottom + tolerance);
    }

    // ---- Crop to the paper ----

    private const int GlassW = 850, GlassH = 1170, Ppi = 100; // a whole glass at the analysis copy's size

    private static byte[] SmallSheet(byte paper, byte ink = 40) => TextPageSmall(600, 800, paper, ink);

    private static byte[] TextPageSmall(int w, int h, byte paper, byte ink)
    {
        var px = new byte[w * h];
        Array.Fill(px, paper);
        for (var y = 60; y < h - 60; y += 22)
            for (var x = 60; x < w - 60; x += 7)
                if ((x + y) % 41 != 0 && x % 49 > 7) Fill(px, w, x, y, 5, 10, ink);
        return px;
    }

    [Fact]
    public void A_grey_sheet_on_a_white_lid_is_cropped_to_its_edge()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 120, 150, 245);
        Inside(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi), 120.0 / GlassW, 150.0 / GlassH, 720.0 / GlassW, 950.0 / GlassH);
    }

    [Fact]
    public void A_sheet_in_the_corner_of_the_glass_shows_lid_on_two_sides_only()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 0, 0, 245);
        Inside(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi), 0, 0, 600.0 / GlassW, 800.0 / GlassH);
    }

    [Fact]
    public void A_dark_sheet_on_a_white_lid_keeps_all_of_itself()
    {
        var scan = OnLid(SmallSheet(40, 220), 600, 800, GlassW, GlassH, 100, 100, 245);
        Inside(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi), 100.0 / GlassW, 100.0 / GlassH, 700.0 / GlassW, 900.0 / GlassH);
    }

    [Fact]
    public void A_page_printed_to_its_edges_is_kept_whole()
    {
        var page = new byte[GlassW * GlassH];
        Array.Fill(page, (byte)240);
        for (var y = 0; y + 12 < GlassH; y += 22)
            for (var x = 0; x + 6 < GlassW; x += 7)
                Fill(page, GlassW, x, y, 5, 10, 30);
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, page), Ppi));
    }

    [Fact]
    public void An_all_dark_page_is_kept_whole()
    {
        var page = new byte[GlassW * GlassH];
        Array.Fill(page, (byte)25);
        Fill(page, GlassW, 200, 300, 400, 300, 220);
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, page), Ppi));
    }

    [Fact]
    public void A_white_sheet_under_a_white_lid_is_kept_whole()
    {
        var page = TextPageSmall(GlassW, GlassH, 240, 40);
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, page), Ppi));
    }

    [Fact]
    public void A_picture_with_a_caption_below_it_is_not_mistaken_for_a_sheet()
    {
        var page = new byte[GlassW * GlassH];
        Array.Fill(page, (byte)240);
        Fill(page, GlassW, 150, 150, 500, 500, 120);
        for (var x = 150; x < 600; x += 8) Fill(page, GlassW, x, 700, 5, 10, 30); // the caption
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, page), Ppi));
    }

    [Fact]
    public void A_faint_note_outside_a_picture_stops_the_crop()
    {
        var page = new byte[GlassW * GlassH];
        Array.Fill(page, (byte)240);
        Fill(page, GlassW, 150, 150, 500, 500, 120);
        Fill(page, GlassW, 150, 800, 300, 2, 228); // twelve levels under the paper, a pencil line
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, page), Ppi));
    }

    [Fact]
    public void Dust_outside_the_sheet_does_not_stop_the_crop()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 120, 150, 245);
        foreach (var (x, y) in new[] { (20, 30), (800, 100), (50, 1100), (780, 1000) }) Fill(scan, GlassW, x, y, 3, 3, 60);
        Assert.NotNull(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi));
    }

    [Fact]
    public void A_line_of_tiny_letters_outside_stops_the_crop()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 120, 150, 245);
        for (var x = 150; x < 450; x += 6) Fill(scan, GlassW, x, 1050, 3, 4, 80); // each no bigger than dust, together a caption
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi));
    }

    [Fact]
    public void A_lone_letter_outside_stops_the_crop()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 120, 150, 245);
        Fill(scan, GlassW, 780, 1050, 12, 14, 40);
        Assert.Null(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi));
    }

    [Fact]
    public void A_noisy_scan_still_finds_the_sheet()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 120, 150, 245);
        Noise(scan, 4);
        Inside(PaperEdge.Find(new GrayImage(GlassW, GlassH, scan), Ppi), 120.0 / GlassW, 150.0 / GlassH, 720.0 / GlassW, 950.0 / GlassH, 0.03);
    }

    [Fact]
    public void A_crooked_sheet_is_cropped_in_the_straightened_page()
    {
        var scan = OnLid(SmallSheet(205), 600, 800, GlassW, GlassH, 120, 150, 245);
        var turned = PageRotate.Rotate(scan, GlassW, GlassH, GlassW, 1, 4, 245);
        Inside(PaperEdge.Find(new GrayImage(GlassW, GlassH, turned), Ppi, deskew: 4), 120.0 / GlassW, 150.0 / GlassH, 720.0 / GlassW, 950.0 / GlassH, 0.02);
    }

    [Theory]
    [InlineData(1, 1)]
    [InlineData(2, 500)]
    [InlineData(31, 31)]
    public void Tiny_images_have_no_edge(int w, int h) => Assert.Null(PaperEdge.Find(new GrayImage(w, h, new byte[w * h]), Ppi));

    // ---- Whiten ----

    private static byte[] Whitened(byte[] px, int w, int h, int channels = 1, int dpi = Dpi) =>
        PageCleanup.Apply(px, w, h, channels, dpi, PageFilters.Whiten).Pixels;

    private static double WhiteShare(byte[] px, int x0, int y0, int x1, int y1, int w)
    {
        var (white, all) = (0, 0);
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++, all++)
                if (px[y * w + x] == 255) white++;
        return (double)white / all;
    }

    [Fact]
    public void A_grey_page_goes_white_and_its_text_stays()
    {
        const int w = 1200, h = 1500;
        var page = TextPage(w, h, 190, 30);
        Noise(page, 5);
        var clean = Whitened(page, w, h);
        Assert.True(WhiteShare(clean, 0, 0, w, h / 20, w) > 0.97, $"{WhiteShare(clean, 0, 0, w, h / 20, w):P1} of the margin is white");
        Assert.True(clean[(h / 10 + 14) * w + w / 10 + 7] < 90, "ink stays dark");
    }

    [Fact]
    public void Uneven_paper_goes_white_all_over()
    {
        const int w = 1200, h = 1500;
        var page = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                page[y * w + x] = (byte)(236 - 60.0 * x * x / (w * w));
        Noise(page, 3);
        var clean = Whitened(page, w, h);
        Assert.True(WhiteShare(clean, 0, 0, w, h, w) > 0.97, $"{WhiteShare(clean, 0, 0, w, h, w):P1}");
    }

    [Theory]
    [InlineData(25, 0)] // a pencil line 25 levels under the paper, one pixel wide
    [InlineData(25, 4)]
    [InlineData(40, 10)]
    public void A_faint_thin_signature_survives(int contrast, double noise)
    {
        const int w = 1200, h = 1500;
        const byte paper = 225;
        var page = TextPage(w, h, paper, 30, top: 100, bottom: 700);
        // A curve one pixel wide, like a signature in hard pencil.
        var stroke = new List<int>();
        var last = 1000;
        for (var x = 200; x < 1000; x++)
        {
            var y = 1000 + (int)(80 * Math.Sin(x / 30.0));
            for (var yy = Math.Min(y, last); yy <= Math.Max(y, last); yy++)
            {
                page[yy * w + x] = (byte)(paper - contrast);
                stroke.Add(yy * w + x);
            }
            last = y;
        }
        var noisy = (byte[])page.Clone();
        if (noise > 0) Noise(noisy, noise);
        var clean = Whitened(noisy, w, h);
        var kept = stroke.Count(i => clean[i] < 250);
        Assert.True(kept > stroke.Count * 0.7, $"{kept} of {stroke.Count} pixels of the stroke kept");
    }

    [Fact]
    public void A_dark_page_is_left_alone()
    {
        const int w = 800, h = 1000;
        var page = TextPage(w, h, 40, 220);
        var result = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.Whiten);
        Assert.Equal(PageFilters.None, result.Done);
        Assert.Equal(page, result.Pixels);
    }

    [Fact]
    public void A_photo_on_the_page_is_not_washed_out()
    {
        const int w = 1200, h = 1500;
        var page = TextPage(w, h, 235, 30, top: 900);
        // A picture of mid-tones: a gradient with detail, its bright parts close to the paper.
        for (var y = 100; y < 800; y++)
            for (var x = 200; x < 1000; x++)
                page[y * w + x] = (byte)(60 + 170.0 * (y - 100) / 700 + 12 * Math.Sin(x / 5.0));
        var clean = Whitened(page, w, h);
        double before = 0, after = 0;
        var white = 0;
        for (var y = 150; y < 750; y++)
            for (var x = 250; x < 950; x++)
            {
                before += page[y * w + x];
                after += clean[y * w + x];
                if (clean[y * w + x] == 255) white++;
            }
        const int count = 600 * 700;
        Assert.InRange(after / count, before / count - 5, before / count + 25);
        Assert.True(white < count / 20, $"{white} of {count} pixels went white"); // only its lightest end, where it meets the paper's level
    }

    [Fact]
    public void A_colored_stamp_stays_its_color()
    {
        const int w = 800, h = 1000;
        var page = new byte[w * h * 3];
        for (var i = 0; i < page.Length; i += 3) (page[i], page[i + 1], page[i + 2]) = (195, 205, 210);
        for (var y = 400; y < 500; y++)
            for (var x = 300; x < 500; x++)
                (page[(y * w + x) * 3], page[(y * w + x) * 3 + 1], page[(y * w + x) * 3 + 2]) = (40, 40, 170);
        var clean = Whitened(page, w, h, channels: 3);
        var at = (450 * w + 400) * 3;
        Assert.True(clean[at + 2] > clean[at] + 80, $"BGR {clean[at]},{clean[at + 1]},{clean[at + 2]}");
        Assert.Equal((255, 255, 255), (clean[3], clean[4], clean[5]));
    }

    [Fact]
    public void Lone_specks_go_and_a_full_stop_stays()
    {
        const int w = 1200, h = 1500;
        var page = TextPage(w, h, 230, 30, top: 200, bottom: 600);
        Fill(page, w, 600, 1200, 6, 6, 40); // a speck, far from anything
        Fill(page, w, 130, 232, 5, 5, 30); // a full stop on a line of text
        var result = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.Whiten);
        Assert.True(result.Specks >= 1);
        Assert.Equal(255, result.Pixels[1203 * w + 603]);
        Assert.True(result.Pixels[234 * w + 132] < 128, "the full stop");
    }

    [Fact]
    public void The_scan_itself_is_never_written_to()
    {
        const int w = 800, h = 1000;
        var page = TextPage(w, h, 190, 30);
        Noise(page, 8);
        var copy = (byte[])page.Clone();
        var result = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.PixelFilters);
        Assert.Equal(copy, page);
        Assert.NotSame(page, result.Pixels);
    }

    [Fact]
    public void Filters_give_the_same_page_twice()
    {
        const int w = 800, h = 1000;
        var page = TextPage(w, h, 190, 30);
        Noise(page, 8);
        Assert.Equal(PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.PixelFilters).Pixels, PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.PixelFilters).Pixels);
    }

    // ---- Descreen ----

    /// <summary>A screen of round dots at 45°, period given, so a mid-grey of level tone.</summary>
    private static void Screen(byte[] px, int w, int x0, int y0, int x1, int y1, double period, double tone)
    {
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
            {
                var (u, v) = ((x + y) / Math.Sqrt(2), (x - y) / Math.Sqrt(2));
                var spot = (Math.Cos(2 * Math.PI * u / period) + Math.Cos(2 * Math.PI * v / period)) / 4 + 0.5; // 0..1
                px[y * w + x] = spot > tone ? (byte)25 : (byte)235;
            }
    }

    private static (double Mean, double Spread) Stats(byte[] px, int w, int x0, int y0, int x1, int y1)
    {
        double sum = 0, squares = 0;
        var n = 0;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++, n++)
            {
                sum += px[y * w + x];
                squares += (double)px[y * w + x] * px[y * w + x];
            }
        var mean = sum / n;
        return (mean, Math.Sqrt(Math.Max(0, squares / n - mean * mean)));
    }

    [Theory]
    [InlineData(4.6, 300)] // 65 lines an inch, newspaper
    [InlineData(3.5, 300)] // 85
    [InlineData(5.6, 600)] // 106 at 600 dpi
    [InlineData(9.2, 600)]
    public void Halftone_dots_go_and_the_tone_stays(double period, int dpi)
    {
        const int w = 1400, h = 1800;
        var page = new byte[w * h];
        Array.Fill(page, (byte)235);
        Screen(page, w, 200, 200, 1200, 1000, period, 0.55);
        var before = Stats(page, w, 300, 300, 1100, 900);
        var result = PageCleanup.Apply(page, w, h, 1, dpi, PageFilters.Descreen);
        Assert.Equal(PageFilters.Descreen, result.Done);
        var after = Stats(result.Pixels, w, 300, 300, 1100, 900);
        Assert.True(after.Spread < before.Spread * 0.15, $"spread {before.Spread:0.0} → {after.Spread:0.0}");
        Assert.InRange(after.Mean, before.Mean - 3, before.Mean + 3);
    }

    [Fact]
    public void Descreening_leaves_text_beside_the_picture_byte_for_byte()
    {
        const int w = 1400, h = 1800;
        var page = TextPage(w, h, 235, 30, top: 1100, bottom: 1700);
        Screen(page, w, 200, 100, 1200, 900, 4.6, 0.55);
        var result = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.Descreen);
        Assert.Equal(PageFilters.Descreen, result.Done);
        for (var y = 1050; y < h; y++)
            Assert.True(page.AsSpan(y * w, w).SequenceEqual(result.Pixels.AsSpan(y * w, w)), $"row {y}");
    }

    [Fact]
    public void A_page_of_text_has_nothing_to_descreen()
    {
        const int w = 1200, h = 1500;
        var page = TextPage(w, h, 235, 30);
        var result = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.Descreen);
        Assert.Equal(PageFilters.None, result.Done);
        Assert.Equal(page, result.Pixels);
    }

    [Fact]
    public void A_bar_code_has_nothing_to_descreen()
    {
        const int w = 1200, h = 1500;
        var page = new byte[w * h];
        Array.Fill(page, (byte)240);
        for (var x = 200; x < 1000; x += 6) Fill(page, w, x, 300, 3, 600, 20);
        Assert.Equal(PageFilters.None, PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.Descreen).Done);
    }

    [Fact]
    public void A_preview_at_low_resolution_is_left_alone()
    {
        const int w = 480, h = 620;
        var page = new byte[w * h];
        Screen(page, w, 0, 0, w, h, 4.6, 0.5);
        Assert.Equal(PageFilters.None, PageCleanup.Apply(page, w, h, 1, 60, PageFilters.Descreen).Done);
    }

    // ---- Restore colors ----

    private static byte[] ColorPage(int w, int h, Func<int, int, (byte B, byte G, byte R)> at)
    {
        var page = new byte[w * h * 3];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                (page[(y * w + x) * 3], page[(y * w + x) * 3 + 1], page[(y * w + x) * 3 + 2]) = at(x, y);
        return page;
    }

    [Fact]
    public void A_faded_print_gets_its_range_and_its_neutrals_back()
    {
        const int w = 600, h = 400;
        // A grey ramp with a cast: blacks lifted, reds kept while blues and greens fade.
        var page = ColorPage(w, h, (x, _) =>
        {
            var v = 255.0 * x / (w - 1);
            return ((byte)(90 + v * 0.45), (byte)(70 + v * 0.55), (byte)(60 + v * 0.75));
        });
        var result = PageCleanup.Apply(page, w, h, 3, Dpi, PageFilters.RestoreColors);
        Assert.Equal(PageFilters.RestoreColors, result.Done);
        var px = result.Pixels;
        byte[] Pixel(int x) => [px[(200 * w + x) * 3], px[(200 * w + x) * 3 + 1], px[(200 * w + x) * 3 + 2]];
        Assert.All(Pixel(5), v => Assert.True(v < 25, $"black {v}"));
        Assert.All(Pixel(w - 6), v => Assert.True(v > 235, $"white {v}"));
        var middle = Pixel(w / 2);
        Assert.True(middle.Max() - middle.Min() < 30, $"BGR {middle[0]},{middle[1]},{middle[2]}");
    }

    [Fact]
    public void Faded_grey_text_gets_darker()
    {
        const int w = 800, h = 1000;
        var page = TextPage(w, h, 225, 150);
        var px = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.RestoreColors).Pixels;
        Assert.True(px[(h / 10 + 14) * w + w / 10 + 7] < 30);
        Assert.True(px[5] > 245);
    }

    [Fact]
    public void A_page_at_full_range_is_nearly_unchanged()
    {
        const int w = 512, h = 256;
        var page = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                page[y * w + x] = (byte)(x / 2);
        var px = PageCleanup.Apply(page, w, h, 1, Dpi, PageFilters.RestoreColors).Pixels;
        for (var i = 0; i < page.Length; i += 97) Assert.InRange(px[i] - page[i], -5, 5);
    }

    [Fact]
    public void A_dark_page_and_a_blank_page_are_left_alone()
    {
        const int w = 400, h = 400;
        var dark = TextPage(w, h, 40, 10);
        Assert.Equal(PageFilters.None, PageCleanup.Apply(dark, w, h, 1, Dpi, PageFilters.RestoreColors).Done);
        var blank = new byte[w * h];
        Array.Fill(blank, (byte)233);
        Assert.Equal(PageFilters.None, PageCleanup.Apply(blank, w, h, 1, Dpi, PageFilters.RestoreColors).Done);
    }

    // ---- Any page ----

    [Theory]
    [InlineData(1, 1)]
    [InlineData(3, 2)]
    [InlineData(8, 8)]
    [InlineData(7, 2000)]
    [InlineData(2000, 7)]
    public void Tiny_and_thin_pages_come_through(int w, int h)
    {
        foreach (var channels in new[] { 1, 3 })
        {
            var page = new byte[w * h * channels];
            new Random(1).NextBytes(page);
            Assert.Equal(page.Length, PageCleanup.Apply(page, w, h, channels, Dpi, PageFilters.PixelFilters).Pixels.Length);
        }
    }

    [Fact]
    public void A_page_too_large_is_left_as_it_is_before_any_memory_is_taken()
    {
        var page = new byte[16];
        var result = PageCleanup.Apply(page, 20_000, 20_000, 3, 1200, PageFilters.PixelFilters);
        Assert.Same(page, result.Pixels);
        Assert.Equal(PageFilters.None, result.Done);
    }

    [Fact]
    public void A_cancelled_token_stops_before_anything_starts()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => PageCleanup.Apply(new byte[100], 10, 10, 1, Dpi, PageFilters.Whiten, cancelled.Token));
    }

    [Fact]
    public void A_huge_page_is_cleaned_in_reasonable_time_and_cancels_quickly()
    {
        // 600 dpi Letter in grey: 33.7 million pixels. The limits are generous: other builds run beside these tests.
        const int w = 5100, h = 6600;
        var page = TextPage(w, h, 200, 30);
        Screen(page, w, 500, 500, 2500, 2500, 9.2, 0.5);
        var clock = Stopwatch.StartNew();
        var result = PageCleanup.Apply(page, w, h, 1, 600, PageFilters.PixelFilters);
        Assert.True(clock.Elapsed < TimeSpan.FromMinutes(2), $"{clock.Elapsed.TotalSeconds:0.0} s");
        Assert.Equal(PageFilters.PixelFilters, result.Done);

        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        clock.Restart();
        Assert.ThrowsAny<OperationCanceledException>(() => PageCleanup.Apply(page, w, h, 1, 600, PageFilters.PixelFilters, cancel.Token));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(20), $"cancelled after {clock.Elapsed.TotalSeconds:0.0} s");
    }

    // ---- Edits, recovery, presets ----

    [Fact]
    public void A_filter_makes_a_page_edited_and_the_crop_flag_alone_does_not()
    {
        Assert.False((PageEdits.None with { Filters = PageFilters.Whiten }).IsEmpty);
        Assert.True((PageEdits.None with { Filters = PageFilters.CropToPaper }).IsEmpty);
        Assert.NotEqual(PageEdits.None with { Filters = PageFilters.Whiten }, PageEdits.None with { Filters = PageFilters.Descreen });
    }

    [Fact]
    public void Cropping_by_hand_means_the_crop_is_no_longer_the_papers()
    {
        var edits = new PageEdits(Crop: new CropBox(0.1, 0.1, 0.5, 0.5), Filters: PageFilters.CropToPaper | PageFilters.Whiten);
        var drawn = edits.WithShownCrop(new CropBox(0.2, 0.2, 0.4, 0.4));
        Assert.Equal(PageFilters.Whiten, drawn.Filters);
    }

    [Fact]
    public void A_kept_page_keeps_its_filters_and_language()
    {
        var kept = new KeptPage("p.jpg", 300, true, Filters: PageFilters.Descreen | PageFilters.CropToPaper, OcrLanguage: "ru");
        var back = JsonSerializer.Deserialize<KeptPage>(JsonSerializer.Serialize(kept))!;
        Assert.Equal(PageFilters.Descreen | PageFilters.CropToPaper, back.Edits.Filters);
        Assert.Equal("ru", back.OcrLanguage);
        // A list written before filters existed reads as none.
        Assert.Equal(PageFilters.None, JsonSerializer.Deserialize<KeptPage>("""{"File":"p.jpg","Dpi":300,"Ocr":true}""")!.Edits.Filters);
    }

    [Fact]
    public void Presets_keep_their_filters_off_unless_asked_and_unknown_bits_are_dropped()
    {
        Assert.All(ScanPresets.BuiltIns(), p => Assert.Equal(PageFilters.None, p.Cleanup));
        var stored = new ScanPresetSettings { Items = [new ScanPreset { Id = "a", Name = "A", Cleanup = (PageFilters)0xFF, OcrLanguage = "ja" }] };
        var preset = ScanPresets.Normalize(JsonSerializer.Deserialize<ScanPresetSettings>(JsonSerializer.Serialize(stored)))[0];
        Assert.Equal(PageFilters.All, preset.Cleanup);
        Assert.Equal("ja", preset.OcrLanguage);
        Assert.Contains("whitened", ScanPresetText.Summary(preset));
    }

    [Fact]
    public void A_preset_written_before_filters_reads_as_none()
    {
        var old = JsonSerializer.Deserialize<ScanPresetSettings>("""{"Version":1,"Items":[{"Id":"a","Name":"A"}]}""");
        Assert.Equal(PageFilters.None, ScanPresets.Normalize(old)[0].Cleanup);
    }
}
