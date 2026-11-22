using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Tests;

/// <summary>Joining two halves of an original too big for the glass (roadmap 4.8), on made-up scans at 100 pixels an inch.</summary>
public class HalvesJoinTests
{
    private const int Ppi = 100;

    /// <summary>A made-up drawing <paramref name="w"/> × <paramref name="h"/>: paper, ruled boxes and blocky labels all over.</summary>
    private static byte[] Drawing(int w, int h, int seed = 3)
    {
        var px = new byte[w * h];
        Array.Fill(px, (byte)240);
        var rng = new Random(seed);
        for (var i = 0; i < w * h / 4000; i++)
        {
            var (x, y, bw, bh) = (rng.Next(w - 60), rng.Next(h - 60), 10 + rng.Next(50), 6 + rng.Next(50));
            var level = (byte)rng.Next(20, 160);
            var outline = rng.Next(2) == 0;
            for (var yy = y; yy < y + bh; yy++)
                for (var xx = x; xx < x + bw; xx++)
                    if (!outline || yy < y + 2 || yy >= y + bh - 2 || xx < x + 2 || xx >= x + bw - 2) px[yy * w + xx] = level;
        }
        return px;
    }

    /// <summary>The part of <paramref name="src"/> (width <paramref name="sw"/>) from (x, y), <paramref name="w"/> × <paramref name="h"/>; outside it white (the lid).</summary>
    private static byte[] Part(byte[] src, int sw, int sh, int x, int y, int w, int h)
    {
        var px = new byte[w * h];
        Array.Fill(px, (byte)250);
        for (var yy = 0; yy < h; yy++)
            for (var xx = 0; xx < w; xx++)
                if (x + xx >= 0 && y + yy >= 0 && x + xx < sw && y + yy < sh) px[yy * w + xx] = src[(y + yy) * sw + x + xx];
        return px;
    }

    private static byte[] Turn(byte[] px)
    {
        var turned = (byte[])px.Clone();
        Array.Reverse(turned);
        return turned;
    }

    private static void Noise(byte[] px, int seed)
    {
        var rng = new Random(seed);
        for (var i = 0; i < px.Length; i++) px[i] = (byte)Math.Clamp(px[i] + rng.Next(-4, 5), 0, 255);
    }

    [Fact]
    public void Two_halves_side_by_side_are_found_and_joined()
    {
        const int w = 1500, h = 1000; // a 15 × 10 inch original on an 8.5 inch wide glass
        var original = Drawing(w, h);
        var first = Part(original, w, h, 0, 0, 850, h);
        var second = Part(original, w, h, 650, -15, 850, h); // two inches of overlap, laid 0.15 inch higher on the glass
        Noise(first, 1);
        Noise(second, 2);
        var found = HalvesJoin.Find(new GrayImage(850, h, first), new GrayImage(850, h, second), Ppi);
        Assert.True(found.Sure, $"score {found.Score:0.000}, next {found.Next:0.000}, {found.Placement}");
        Assert.Equal(new JoinPlacement(JoinSide.Right, false, 650, -15), found.Placement);

        var joined = HalvesJoin.Join(first, 850, h, second, 850, h, 1, found.Placement)!.Value;
        Assert.Equal((1500, 1015), (joined.Width, joined.Height));
        // Each side of the seam is its half: the original, give or take the scan's noise.
        foreach (var (x, y) in new[] { (100, 300), (740, 500), (760, 500), (1400, 900) })
            Assert.InRange(joined.Pixels[(y + 15) * 1500 + x] - original[y * w + x], -4, 4); // the page starts 0.15 inch above the first half
    }

    [Fact]
    public void A_second_half_scanned_the_other_way_round_is_turned()
    {
        const int w = 1500, h = 1000;
        var original = Drawing(w, h, seed: 9);
        var first = Part(original, w, h, 0, 0, 850, h);
        var second = Turn(Part(original, w, h, 700, 0, 850, h)); // the original turned round on the glass for its other half
        var found = HalvesJoin.Find(new GrayImage(850, h, first), new GrayImage(850, h, second), Ppi);
        Assert.True(found.Sure);
        Assert.Equal(new JoinPlacement(JoinSide.Right, true, 700, 0), found.Placement);
        var joined = HalvesJoin.Join(first, 850, h, second, 850, h, 1, found.Placement)!.Value;
        Assert.Equal(original[600 * w + 1300], joined.Pixels[600 * 1550 + 1300]);
    }

    [Fact]
    public void A_huge_page_is_searched_on_a_small_copy_and_still_found()
    {
        // Halves said to be at 12 pixels an inch, 1600 pixels long (133 inches): searched on copies that size, every placement takes
        // minutes (hours for a page as tall); on copies of at most 400 pixels a side, a moment.
        const int w = 2700, h = 200;
        var original = Drawing(w, h, seed: 7);
        var first = Part(original, w, h, 0, 0, 1600, h);
        var second = Part(original, w, h, 1100, 0, 1600, h);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var found = HalvesJoin.Find(new GrayImage(1600, h, first), new GrayImage(1600, h, second), 12);
        Assert.InRange(watch.Elapsed, TimeSpan.Zero, Timing.Limit(TimeSpan.FromSeconds(10)));
        Assert.Equal(new JoinPlacement(JoinSide.Right, false, 1100, 0), found.Placement);
    }

    [Fact]
    public void Finding_the_overlap_stops_when_cancelled()
    {
        var original = Drawing(1500, 1000);
        var (first, second) = (Part(original, 1500, 1000, 0, 0, 850, 1000), Part(original, 1500, 1000, 650, 0, 850, 1000));
        Assert.ThrowsAny<OperationCanceledException>(() =>
            HalvesJoin.Find(new GrayImage(850, 1000, first), new GrayImage(850, 1000, second), Ppi, new CancellationToken(canceled: true)));
    }

    [Fact]
    public void Halves_one_above_the_other_and_given_in_either_order()
    {
        const int w = 1000, h = 1500;
        var original = Drawing(w, h, seed: 4);
        var top = Part(original, w, h, 0, 0, w, 850);
        var bottom = Part(original, w, h, 8, 650, w, 850);
        var below = HalvesJoin.Find(new GrayImage(w, 850, top), new GrayImage(w, 850, bottom), Ppi);
        Assert.True(below.Sure);
        Assert.Equal(new JoinPlacement(JoinSide.Below, false, 8, 650), below.Placement);
        var above = HalvesJoin.Find(new GrayImage(w, 850, bottom), new GrayImage(w, 850, top), Ppi); // the bottom half scanned first
        Assert.True(above.Sure);
        Assert.Equal(new JoinPlacement(JoinSide.Above, false, -8, -650), above.Placement);
    }

    /// <summary>A plan on squared paper: the grid repeats every half inch, so only its few labels tell the overlap from a step of it.</summary>
    [Fact]
    public void A_ruled_grid_isnt_taken_for_the_overlap()
    {
        const int w = 1400, h = 1100;
        var plan = new byte[w * h];
        Array.Fill(plan, (byte)245);
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                if (x % 50 == 0 || y % 50 == 0) plan[y * w + x] = 150;
        var rng = new Random(5);
        for (var i = 0; i < 25; i++)
        {
            var (x0, y0) = (rng.Next(w - 80), rng.Next(h - 30));
            for (var y = y0; y < y0 + 20; y++)
                for (var x = x0; x < x0 + 70; x++)
                    if ((x + y) % 3 != 0) plan[y * w + x] = 30;
        }
        var first = Part(plan, w, h, 0, 0, 850, h);
        var second = Turn(Part(plan, w, h, 550, 10, 850, h));
        Noise(first, 3);
        Noise(second, 4);
        var found = HalvesJoin.Find(new GrayImage(850, h, first), new GrayImage(850, h, second), Ppi);
        Assert.True(found.Sure, $"score {found.Score:0.000}, next {found.Next:0.000}, {found.Placement}");
        Assert.Equal(new JoinPlacement(JoinSide.Right, true, 550, 10), found.Placement);
    }

    [Fact]
    public void Halves_that_dont_overlap_are_a_guess_to_nudge()
    {
        const int w = 850, h = 1000;
        var first = Drawing(w, h, seed: 1);
        var second = Drawing(w, h, seed: 2); // another drawing: nothing in common
        var found = HalvesJoin.Find(new GrayImage(w, h, first), new GrayImage(w, h, second), Ppi);
        Assert.False(found.Sure);

        // Squared paper with nothing on it: every step of the grid matches as well as any other.
        var grid = new byte[w * h];
        for (var i = 0; i < grid.Length; i++) grid[i] = (byte)(i % w % 50 == 0 || i / w % 50 == 0 ? 140 : 245);
        var (gridA, gridB) = ((byte[])grid.Clone(), (byte[])grid.Clone());
        Noise(gridA, 5);
        Noise(gridB, 6); // two scans are never the same to the pixel
        Assert.False(HalvesJoin.Find(new GrayImage(w, h, gridA), new GrayImage(w, h, gridB), Ppi).Sure);

        var blank = new byte[w * h];
        Array.Fill(blank, (byte)245);
        var plain = HalvesJoin.Find(new GrayImage(w, h, blank), new GrayImage(w, h, blank), Ppi);
        Assert.False(plain.Sure);
        Assert.Equal(HalvesJoin.EdgeToEdge(JoinSide.Right, false, w, h, w, h), plain.Placement); // edge to edge, to start the nudge from
    }

    /// <summary>
    /// The app finds the overlap on copies a third the size: a copy leaves out the half's last columns, which, the half turned
    /// round, are its first, so the placement moves back by them at full size.
    /// </summary>
    [Fact]
    public void A_turned_half_found_on_smaller_copies_lands_to_the_pixel()
    {
        const int w = 1500, h = 999, factor = 3;
        var original = Drawing(w, h, seed: 12);
        var first = Part(original, w, h, 0, 0, 850, h);
        var second = Turn(Part(original, w, h, 652, 0, 848, h)); // 848 = 3 × 282 + 2: two columns more than the copy holds
        var found = HalvesJoin.Find(HalvesJoin.Gray(first, 850, h, 1, factor), HalvesJoin.Gray(second, 848, h, 1, factor), Ppi / (double)factor);
        Assert.True(found.Sure);
        Assert.Equal(new JoinPlacement(JoinSide.Right, true, 652, 0), HalvesJoin.FromCopy(found.Placement, factor, 848, h));
        Assert.Equal(new JoinPlacement(JoinSide.Right, true, 654, 0), found.Placement.Scaled(factor)); // scaled alone: two pixels off
        Assert.Equal(found.Placement, HalvesJoin.ToCopy(new JoinPlacement(JoinSide.Right, true, 652, 0), factor, 848, h));
        // Unturned, a copy's columns start where the half's do.
        Assert.Equal(new JoinPlacement(JoinSide.Right, false, 651, 3), HalvesJoin.FromCopy(new JoinPlacement(JoinSide.Right, false, 217, 1), factor, 848, h));
        var joined = HalvesJoin.Join(first, 850, h, second, 848, h, 1, HalvesJoin.FromCopy(found.Placement, factor, 848, h))!.Value;
        Assert.Equal(original.AsSpan(500 * w + 1000, 400).ToArray(), joined.Pixels.AsSpan(500 * 1500 + 1000, 400).ToArray());
    }

    [Fact]
    public void A_nudge_and_a_scale_move_the_placement()
    {
        var at = new JoinPlacement(JoinSide.Right, false, 650, 15);
        Assert.Equal(new JoinPlacement(JoinSide.Right, false, 655, 10), at.Nudged(5, -5));
        Assert.Equal(new JoinPlacement(JoinSide.Right, false, 1950, 45), at.Scaled(3));
        Assert.Equal(new JoinPlacement(JoinSide.Below, true, 0, 300), HalvesJoin.EdgeToEdge(JoinSide.Below, true, 200, 300, 200, 300));
        Assert.Equal(new JoinPlacement(JoinSide.Left, false, -200, -50), HalvesJoin.EdgeToEdge(JoinSide.Left, false, 200, 300, 200, 400));
    }

    [Fact]
    public void Color_halves_join_and_a_join_too_large_is_refused()
    {
        var first = new byte[4 * 2 * 3];
        var second = new byte[4 * 2 * 3];
        Array.Fill(first, (byte)10);
        Array.Fill(second, (byte)200);
        var joined = HalvesJoin.Join(first, 4, 2, second, 4, 2, 3, new JoinPlacement(JoinSide.Right, false, 2, 1))!.Value;
        Assert.Equal((6, 3), (joined.Width, joined.Height));
        Assert.Equal(10, joined.Pixels[(1 * 6 + 2) * 3]); // left of the seam (x 3): the first half
        Assert.Equal(200, joined.Pixels[(1 * 6 + 3) * 3]); // from the seam on: the second
        Assert.Equal(255, joined.Pixels[(0 * 6 + 5) * 3]); // neither: white
        Assert.Null(HalvesJoin.Join(first, 4, 2, second, 4, 2, 3, new JoinPlacement(JoinSide.Right, false, 20_000, 20_000))); // a page past the limit
        Assert.Null(HalvesJoin.Join(first, 40, 2, second, 4, 2, 3, new JoinPlacement(JoinSide.Right, false, 2, 0))); // fewer pixels than it says
    }
}
