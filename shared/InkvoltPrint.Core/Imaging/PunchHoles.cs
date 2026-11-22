namespace InkvoltPrint.Core.Imaging;

/// <summary>A punch hole found on a page: its centre and radius in the page's pixels.</summary>
public readonly record struct PunchHole(double X, double Y, double Radius);

/// <summary>
/// Removes punch holes (roadmap 4.7, as Epson Scan 2's punch hole removal): the dark round shadows a two- or three-hole punched
/// sheet leaves near its edges (the feeder's backing or the lid's shadow seen through the hole), each filled with the paper's
/// color around it. Only what is surely a hole is touched: round (a disc, or a ring around one), 0.14 to 0.5 inch across, its
/// centre within <see cref="Band"/> inch of an edge, whole on the page and on its own (nothing within a sixteenth of an inch
/// around it), so a letter "O" in a line of text, a bullet, a logo in the page's middle or a hole cut by the page's edge stay.
/// Grey or BGR pixels, rows packed.
/// </summary>
public static class PunchHoles
{
    /// <summary>How far from an edge (inches) a hole's centre may be: punches put them 0.3 to 0.6 inch in.</summary>
    public const double Band = 1.0;

    /// <summary>A hole's size across (inches): 4 to 10 mm holes, with their shadow.</summary>
    public const double MinSide = 0.14, MaxSide = 0.5;

    private const double MaxAspect = 1.35, MinFill = 0.78, MaxFill = 1.15, Gap = 0.06, Halo = 0.03, MaxOthers = 0.04;

    /// <summary>How much darker than the paper a hole's shadow is (on the grid's averaged cells).</summary>
    private const int Contrast = 45;

    /// <summary>At most this many holes on a page: more round marks along the edges are a pattern, not punching.</summary>
    public const int MaxHoles = 12;

    /// <summary>Fills each hole found with the paper's color around it, in place; returns how many.</summary>
    public static int Remove(byte[] pixels, int width, int height, int channels, int dpi, CancellationToken cancel = default)
    {
        var holes = Find(pixels, width, height, channels, dpi, cancel);
        foreach (var hole in holes)
        {
            cancel.ThrowIfCancellationRequested();
            Fill(pixels, width, height, channels, hole, dpi);
        }
        return holes.Count;
    }

    /// <summary>The holes on the page, in the page's pixels; none when it is too small to hold one or not sure.</summary>
    public static List<PunchHole> Find(byte[] pixels, int width, int height, int channels, int dpi, CancellationToken cancel = default)
    {
        if (width < 1 || height < 1 || dpi < 30 || channels is not (1 or 3) || (long)width * height * channels > pixels.Length
            || Math.Min(width, height) < 2 * MaxSide * dpi) return [];

        // A grid of about 50 cells an inch, each its average lightness.
        var step = Math.Max(1, (int)Math.Round(dpi / 50.0));
        var (gw, gh) = (width / step, height / step);
        var cpi = dpi / (double)step;
        var grid = new byte[gw * gh];
        var options = new ParallelOptions { CancellationToken = cancel };
        Parallel.For(0, gh, options, gy =>
        {
            for (var gx = 0; gx < gw; gx++)
            {
                long sum = 0;
                for (var y = gy * step; y < (gy + 1) * step; y++)
                    for (var x = gx * step; x < (gx + 1) * step; x++)
                    {
                        var i = (y * width + x) * channels;
                        sum += channels == 1 ? pixels[i] : (pixels[i] * 114 + pixels[i + 1] * 587 + pixels[i + 2] * 299) / 1000;
                    }
                grid[gy * gw + gx] = (byte)(sum / (step * step));
            }
        });
        var paper = GrayImage.Median(new GrayImage(gw, gh, grid), 0, 0, gw, gh);
        if (paper < 128) return []; // a dark page or a photo: no paper to tell a hole from
        var mask = new bool[grid.Length];
        for (var i = 0; i < grid.Length; i++) mask[i] = grid[i] < paper - Contrast;

        var band = Band * cpi;
        var holes = new List<PunchHole>();
        var seen = new bool[mask.Length];
        var queue = new Queue<int>();
        var cells = new List<int>();
        for (var start = 0; start < mask.Length; start++)
        {
            if (!mask[start] || seen[start]) continue;
            var (sx, sy) = (start % gw, start / gw);
            if (sx > band && sx < gw - 1 - band && sy > band && sy < gh - 1 - band) continue; // never near an edge
            cells.Clear();
            seen[start] = true;
            queue.Enqueue(start);
            int minX = sx, maxX = sx, minY = sy, maxY = sy;
            while (queue.Count > 0)
            {
                var i = queue.Dequeue();
                cells.Add(i);
                var (x, y) = (i % gw, i / gw);
                (minX, maxX, minY, maxY) = (Math.Min(minX, x), Math.Max(maxX, x), Math.Min(minY, y), Math.Max(maxY, y));
                foreach (var n in (ReadOnlySpan<int>)[x > 0 ? i - 1 : -1, x < gw - 1 ? i + 1 : -1, y > 0 ? i - gw : -1, y < gh - 1 ? i + gw : -1])
                    if (n >= 0 && mask[n] && !seen[n])
                    {
                        seen[n] = true;
                        queue.Enqueue(n);
                    }
            }
            if (Hole(mask, gw, gh, cells, minX, minY, maxX, maxY, cpi, band) is { } found)
            {
                holes.Add(new PunchHole((found.X + 0.5) * step, (found.Y + 0.5) * step, found.Radius * step + Halo * dpi));
                if (holes.Count > MaxHoles) return [];
            }
        }
        return holes;
    }

    /// <summary>The component as a hole on the grid (centre and radius in cells), or null when it isn't surely one.</summary>
    private static PunchHole? Hole(bool[] mask, int gw, int gh, List<int> cells, int minX, int minY, int maxX, int maxY, double cpi, double band)
    {
        if (minX == 0 || minY == 0 || maxX == gw - 1 || maxY == gh - 1) return null; // cut by the page's edge: not sure
        var (w, h) = (maxX - minX + 1, maxY - minY + 1);
        if (Math.Min(w, h) < MinSide * cpi || Math.Max(w, h) > MaxSide * cpi || Math.Max(w, h) > MaxAspect * Math.Min(w, h)) return null;
        var (cx, cy) = (minX + (w - 1) / 2.0, minY + (h - 1) / 2.0);
        if (Math.Min(Math.Min(cx, gw - 1 - cx), Math.Min(cy, gh - 1 - cy)) > band) return null;

        // Its outline filled (a ring's middle is the hole too), then how round: a disc fills π/4 of its box.
        var (pw, ph) = (w + 2, h + 2);
        var own = new bool[pw * ph];
        foreach (var i in cells) own[(i / gw - minY + 1) * pw + i % gw - minX + 1] = true;
        PhotoFinder.FillHoles(own, pw, ph);
        var area = own.Count(c => c);
        var fill = area / (Math.PI / 4 * w * h);
        if (fill < MinFill || fill > MaxFill) return null;

        // On its own: around it, within the gap, next to nothing else dark (a letter has neighbours in its line).
        var gap = Math.Max(1, (int)Math.Ceiling(Gap * cpi));
        var (x0, y0, x1, y1) = (Math.Max(0, minX - gap), Math.Max(0, minY - gap), Math.Min(gw - 1, maxX + gap), Math.Min(gh - 1, maxY + gap));
        int others = 0, ring = 0;
        for (var y = y0; y <= y1; y++)
            for (var x = x0; x <= x1; x++)
            {
                if (x >= minX && x <= maxX && y >= minY && y <= maxY) continue;
                ring++;
                if (mask[y * gw + x]) others++;
            }
        if (ring == 0 || others > MaxOthers * ring) return null;
        return new PunchHole(cx, cy, Math.Max(w, h) / 2.0);
    }

    /// <summary>The hole's disc painted with the paper's color around it (each channel's median just outside), its rim blended.</summary>
    private static void Fill(byte[] pixels, int width, int height, int channels, PunchHole hole, int dpi)
    {
        var r = hole.Radius;
        var outer = r + Math.Max(2, 0.06 * dpi);
        var paper = new byte[channels];
        var histograms = new int[channels, 256];
        var counted = 0;
        var (x0, y0) = (Math.Max(0, (int)Math.Floor(hole.X - outer)), Math.Max(0, (int)Math.Floor(hole.Y - outer)));
        var (x1, y1) = (Math.Min(width - 1, (int)Math.Ceiling(hole.X + outer)), Math.Min(height - 1, (int)Math.Ceiling(hole.Y + outer)));
        for (var y = y0; y <= y1; y++)
            for (var x = x0; x <= x1; x++)
            {
                var d = Math.Sqrt((x - hole.X) * (x - hole.X) + (y - hole.Y) * (y - hole.Y));
                if (d <= r || d > outer) continue;
                var i = (y * width + x) * channels;
                for (var c = 0; c < channels; c++) histograms[c, pixels[i + c]]++;
                counted++;
            }
        if (counted == 0) return;
        for (var c = 0; c < channels; c++)
            for (int level = 0, seen = 0; level < 256; level++)
                if ((seen += histograms[c, level]) * 2 > counted) { paper[c] = (byte)level; break; }

        const double soft = 1.5; // pixels of rim blended into what's around
        for (var y = y0; y <= y1; y++)
            for (var x = x0; x <= x1; x++)
            {
                var d = Math.Sqrt((x - hole.X) * (x - hole.X) + (y - hole.Y) * (y - hole.Y));
                if (d > r + soft) continue;
                var weight = d <= r ? 1 : (r + soft - d) / soft;
                var i = (y * width + x) * channels;
                for (var c = 0; c < channels; c++)
                    pixels[i + c] = (byte)Math.Round(pixels[i + c] + (paper[c] - pixels[i + c]) * weight);
            }
    }
}
