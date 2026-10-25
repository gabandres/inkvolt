using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Tests;

/// <summary>
/// Several photos on the glass: rectangles found on synthetic flatbed scans (the whole glass, 8.5 × 11.7 in at 100 dpi, as the
/// app analyses it: a noisy white lid with prints laid on it, straight or turned) and each one cut out straight.
/// </summary>
public class GlassPhotoTests
{
    private const int W = 850, H = 1170;
    private const double Ppi = 100;

    /// <summary>A print on the glass, in inches: centre, size, turned <c>Degrees</c> clockwise.</summary>
    private sealed record Print(double X, double Y, double Width, double Height, double Degrees, bool BrightSky = false);

    /// <summary>The lid (level 246 with scanner noise) with each print drawn on it: mid tones in soft blotches, a bright sky band if asked.</summary>
    private static GrayImage Glass(params Print[] prints) => new(W, H, GlassPixels(prints));

    private static byte[] GlassPixels(Print[] prints, int seed = 5)
    {
        var random = new Random(seed);
        var pixels = new byte[W * H];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)(246 + random.Next(-6, 7));
        foreach (var p in prints)
        {
            var (sin, cos) = Math.SinCos(p.Degrees * Math.PI / 180);
            for (var y = 0; y < H; y++)
                for (var x = 0; x < W; x++)
                {
                    // Where this pixel is on the print (inches from its centre, along its sides).
                    var (dx, dy) = (x / Ppi - p.X, y / Ppi - p.Y);
                    var u = cos * dx + sin * dy;
                    var v = -sin * dx + cos * dy;
                    if (Math.Abs(u) > p.Width / 2 || Math.Abs(v) > p.Height / 2) continue;
                    var level = p.BrightSky && v < -p.Height / 6
                        ? 220 + 4 * Math.Sin(u * 9)
                        : 120 + 70 * Math.Sin(u * 3.1) * Math.Cos(v * 2.3) + random.Next(-8, 9);
                    pixels[y * W + x] = (byte)Math.Clamp(level, 0, 255);
                }
        }
        return pixels;
    }

    private static void AssertFound(Print expected, PhotoBox box)
    {
        // Box units are the scan's width: 8.5 in here.
        var inch = 1 / 8.5;
        Assert.InRange(box.CenterX / inch, expected.X - 0.08, expected.X + 0.08);
        Assert.InRange(box.CenterY / inch, expected.Y - 0.08, expected.Y + 0.08);
        Assert.InRange(box.Width / inch, expected.Width - 0.16, expected.Width + 0.04);   // trimmed a little, never larger
        Assert.InRange(box.Height / inch, expected.Height - 0.16, expected.Height + 0.04);
        Assert.InRange(box.Angle, expected.Degrees - 0.75, expected.Degrees + 0.75);
    }

    [Fact]
    public void Finds_three_prints_straight_and_turned_in_reading_order()
    {
        var prints = new[]
        {
            new Print(2.4, 2.2, 4, 3, 0),
            new Print(6.4, 2.5, 3, 4.2, 7),
            new Print(4.2, 8.3, 5, 3.5, -12),
        };

        var boxes = PhotoFinder.Find(Glass(prints), Ppi);

        Assert.Equal(3, boxes.Count);
        for (var i = 0; i < 3; i++) AssertFound(prints[i], boxes[i]);
    }

    [Fact]
    public void Steep_angles_come_back_within_45_degrees()
    {
        var boxes = PhotoFinder.Find(Glass(new Print(4.25, 5.5, 5, 3, 32)), Ppi);

        var box = Assert.Single(boxes);
        AssertFound(new Print(4.25, 5.5, 5, 3, 32), box);

        // Turned 60°, a 5 × 3 print is a 3 × 5 one turned -30°.
        box = Assert.Single(PhotoFinder.Find(Glass(new Print(4.25, 5.5, 5, 3, 60)), Ppi));
        AssertFound(new Print(4.25, 5.5, 3, 5, -30), box);
    }

    [Fact]
    public void A_bright_sky_inside_a_print_stays_part_of_it()
    {
        var print = new Print(4.25, 5, 6, 4, 4, BrightSky: true);

        AssertFound(print, Assert.Single(PhotoFinder.Find(Glass(print), Ppi)));
    }

    [Fact]
    public void Prints_against_the_glass_edge_and_close_together()
    {
        var corner = new Print(1.5, 1, 3, 2, 0);          // pushed into the corner of the glass
        var left = new Print(2.0, 6, 3.6, 2.5, 0);
        var right = new Print(6.15, 6, 4, 2.5, 0);        // 0.35 in from the left one
        var boxes = PhotoFinder.Find(Glass(corner, left, right), Ppi);

        Assert.Equal(3, boxes.Count);
        AssertFound(corner, boxes[0]);
        AssertFound(left, boxes[1]);
        AssertFound(right, boxes[2]);
    }

    [Fact]
    public void A_print_just_short_of_the_edge_doesnt_grow_to_it()
    {
        var nearTop = new Print(3, 1.8, 4, 3.5, 0);    // its top 0.05 in below the glass's edge
        var nearLeft = new Print(1.6, 6.5, 3, 3, -3);  // a corner 0.03 in from the left edge

        var boxes = PhotoFinder.Find(Glass(nearTop, nearLeft), Ppi);

        Assert.Equal(2, boxes.Count);
        AssertFound(nearTop, boxes[0]);
        AssertFound(nearLeft, boxes[1]);
        Assert.InRange((boxes[0].CenterY - boxes[0].Height / 2) * 8.5, 0.045, 0.1); // the top stays where the print's is, not the glass's
        Assert.InRange(boxes[1].Corners().Min(c => c.X) * 8.5, 0.02, 0.08);
    }

    [Fact]
    public void Empty_glass_dust_hairs_and_lid_shadows_are_no_photos()
    {
        var pixels = GlassPixels([]);
        for (var x = 0; x < W; x++) for (var y = 0; y < 5; y++) pixels[y * W + x] = 150;   // the lid's shadow along the top
        for (var i = 0; i < 400; i++) pixels[(300 + i) * W + 200 + i / 3] = 60;             // a hair
        foreach (var (x, y) in new[] { (100, 900), (700, 400), (420, 610) })
            for (var d = 0; d < 9; d++) pixels[(y + d / 3) * W + x + d % 3] = 40;            // dust

        Assert.Empty(PhotoFinder.Find(new GrayImage(W, H, pixels), Ppi));
        Assert.Empty(PhotoFinder.Find(Glass(new Print(4, 4, 0.4, 0.5, 0)), Ppi));            // a stamp, not a photo
    }

    // ---- Cutting each photo out ----

    /// <summary>A grey 3-channel page (stride padded) with one turned rectangle of colour (60, 120, 200) on white.</summary>
    private static (byte[] Pixels, int Stride) ColourPage(Print print)
    {
        var stride = (W * 3 + 3) & ~3;
        var pixels = new byte[stride * H];
        Array.Fill(pixels, (byte)255);
        var (sin, cos) = Math.SinCos(print.Degrees * Math.PI / 180);
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
            {
                var (dx, dy) = (x / Ppi - print.X, y / Ppi - print.Y);
                if (Math.Abs(cos * dx + sin * dy) > print.Width / 2 || Math.Abs(-sin * dx + cos * dy) > print.Height / 2) continue;
                (pixels[y * stride + x * 3], pixels[y * stride + x * 3 + 1], pixels[y * stride + x * 3 + 2]) = (60, 120, 200);
            }
        return (pixels, stride);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(9)]
    [InlineData(-21)]
    public void Cuts_a_turned_photo_out_straight(double degrees)
    {
        var print = new Print(4, 5, 4, 2.5, degrees);
        var (page, stride) = ColourPage(print);
        var box = new PhotoBox(4 / 8.5, 5 / 8.5, 3.9 / 8.5, 2.4 / 8.5, degrees); // a little inside the print, as found

        var (x, y, w, h) = PhotoCrop.Bounds(box, W, H);
        var region = new byte[((w * 3 + 3) & ~3) * h];
        for (var row = 0; row < h; row++) Array.Copy(page, (y + row) * stride + x * 3, region, row * ((w * 3 + 3) & ~3), w * 3);
        var photo = PhotoCrop.Straighten(region, w, h, (w * 3 + 3) & ~3, 3, box, W, x, y);

        Assert.InRange(photo.Width, 388, 392);
        Assert.InRange(photo.Height, 238, 242);
        // Every pixel is the print's colour: no white corners from the glass.
        for (var row = 0; row < photo.Height; row++)
            for (var col = 0; col < photo.Width; col++)
            {
                var i = row * photo.Stride + col * 3;
                Assert.True(Math.Abs(photo.Pixels[i] - 60) < 20 && Math.Abs(photo.Pixels[i + 2] - 200) < 20, $"pixel {col},{row}");
            }
    }

    [Fact]
    public void Bounds_stay_inside_the_scan()
    {
        var (x, y, w, h) = PhotoCrop.Bounds(new PhotoBox(0.02, 0.02, 0.2, 0.1, 30), W, H);

        Assert.Equal((0, 0), (x, y));
        Assert.True(w > 0 && h > 0 && x + w <= W && y + h <= H);
    }

    [Fact]
    public void Presets_say_when_they_find_photos()
    {
        var preset = new Core.Presets.ScanPreset { Id = "photos", Name = "Photos", FindPhotos = true };

        Assert.Contains("each photo on the glass by itself", Core.Presets.ScanPresetText.Summary(preset));
        Assert.True(Core.Presets.ScanPresets.Normalize(new() { Items = [preset] })[0].FindPhotos);
    }

    // ---- Adjusting a box in the review ----

    [Fact]
    public void Dragging_a_corner_keeps_the_opposite_one()
    {
        var box = new PhotoBox(0.5, 0.5, 0.4, 0.2, 30);
        var corners = box.Corners();

        var resized = box.WithCorner(2, corners[2].X + 0.05, corners[2].Y + 0.02);

        Assert.Equal(corners[0].X, resized.Corners()[0].X, 9);
        Assert.Equal(corners[0].Y, resized.Corners()[0].Y, 9);
        Assert.Equal(30, resized.Angle);
        Assert.True(resized.Width > box.Width);
    }

    [Fact]
    public void Corner_order_and_containment()
    {
        var box = new PhotoBox(0.5, 0.5, 0.4, 0.2, 0);

        Assert.Equal([(0.3, 0.4), (0.7, 0.4), (0.7, 0.6), (0.3, 0.6)], box.Corners().Select(c => (Math.Round(c.X, 9), Math.Round(c.Y, 9))));
        Assert.True(box.Contains(0.6, 0.55));
        Assert.False(box.Contains(0.6, 0.65));
        Assert.True((box with { Angle = 90 }).Contains(0.55, 0.65)); // turned a quarter: 0.2 wide, 0.4 tall
    }
}
