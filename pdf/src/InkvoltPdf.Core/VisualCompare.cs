namespace InkvoltPdf.Core;

/// <summary>
/// The overlay of two renders: ink both share in grey, ink only the old one has in red, ink only the new one has in
/// blue. <see cref="Regions"/> are the areas that differ (pixel coordinates of <see cref="Image"/>), grouped so a
/// changed word or detail is one box.
/// </summary>
public sealed record VisualDiff(RenderedImage Image, int ChangedPixels, double ChangedShare, IReadOnlyList<RectD> Regions);

/// <summary>Pixel comparison of two pages rendered at the same scale, for drawings and scans without text.</summary>
public static class VisualCompare
{
    /// <summary>Ink only the old page has (removed): red.</summary>
    public static readonly (byte R, byte G, byte B) RemovedColor = (220, 40, 40);

    /// <summary>Ink only the new page has (added): blue.</summary>
    public static readonly (byte R, byte G, byte B) AddedColor = (40, 90, 230);

    /// <summary>
    /// Overlays two renders aligned at their top-left corners (the result is as large as the larger one; the smaller is
    /// white beyond its edge). A pixel differs when its brightness differs by more than <paramref name="tolerance"/>
    /// (0-255), so faint scanner noise and tints don't count; a <paramref name="block"/>-pixel square counts toward a
    /// region only with at least <paramref name="minPixels"/> differing pixels, so a lone speck doesn't either.
    /// </summary>
    /// <param name="slack">
    /// Pixels a difference may be off by and still be the same ink (two scans never fall on exactly the same pixels): a pixel
    /// counts only if the other image has nothing like it this close. 0 for pages made by a program.
    /// </param>
    public static VisualDiff Overlay(RenderedImage oldImage, RenderedImage newImage, int tolerance = 48, int block = 8, int minPixels = 2,
        CancellationToken cancel = default, int slack = 0)
    {
        var w = Math.Max(oldImage.Width, newImage.Width);
        var h = Math.Max(oldImage.Height, newImage.Height);
        var stride = w * 3;
        var output = GC.AllocateUninitializedArray<byte>(stride * h);
        var bw = (w + block - 1) / block;
        var bh = (h + block - 1) / block;
        var counts = new int[bw * bh];
        var bounds = new (int X0, int Y0, int X1, int Y1)[bw * bh];
        var changed = 0;
        var (rr, rg, rb) = RemovedColor;
        var (ar, ag, ab) = AddedColor;

        for (var y = 0; y < h; y++)
        {
            if ((y & 63) == 0) cancel.ThrowIfCancellationRequested();
            var row = y * stride;
            for (var x = 0; x < w; x++)
            {
                var lo = Luma(oldImage, x, y);
                var ln = Luma(newImage, x, y);
                var i = row + x * 3;
                var d = lo - ln;
                if (Math.Abs(d) <= tolerance || (slack > 0 && (d < 0 ? Near(newImage, x, y, lo, tolerance, slack) : Near(oldImage, x, y, ln, tolerance, slack))))
                {
                    // Shared: grey, lightened so the colors stand out.
                    var g = (byte)(255 - (255 - ln) * 55 / 100);
                    output[i] = output[i + 1] = output[i + 2] = g;
                    continue;
                }
                changed++;
                var s = Math.Min(255, Math.Abs(d) * 7 / 5); // strength 0..255
                var (cr, cg, cb) = d < 0 ? (rr, rg, rb) : (ar, ag, ab); // old darker: removed
                output[i] = (byte)(255 - (255 - cb) * s / 255);
                output[i + 1] = (byte)(255 - (255 - cg) * s / 255);
                output[i + 2] = (byte)(255 - (255 - cr) * s / 255);

                var b = y / block * bw + x / block;
                bounds[b] = counts[b]++ == 0 ? (x, y, x, y) : (Math.Min(bounds[b].X0, x), Math.Min(bounds[b].Y0, y), Math.Max(bounds[b].X1, x), Math.Max(bounds[b].Y1, y));
            }
        }

        var regions = Regions(counts, bounds, bw, bh, minPixels);
        return new VisualDiff(new RenderedImage(w, h, output), changed, w * h == 0 ? 0 : (double)changed / (w * h), regions);
    }

    /// <summary>Scale to check two scans at: lower, the slack below takes in whole changed words.</summary>
    public const double ScanCheckScale = 1.5;

    /// <summary>The overlay of two scans rendered at <paramref name="scale"/> pixels per point: ink may land a point and a half off, and a speck doesn't count.</summary>
    public static VisualDiff OverlayScans(RenderedImage oldImage, RenderedImage newImage, double scale, CancellationToken cancel = default) =>
        Overlay(oldImage, newImage, minPixels: 6, cancel: cancel, slack: (int)Math.Clamp(Math.Round(1.5 * scale), 2, 6));

    /// <summary>A scan's thin strokes come out this light where a program's are nearly black: still ink.</summary>
    private const int FaintInk = 205;

    /// <summary>Whether <paramref name="image"/> has ink as dark as this within <paramref name="slack"/> pixels of (x, y).</summary>
    private static bool Near(RenderedImage image, int x, int y, int luma, int tolerance, int slack)
    {
        for (var dy = -slack; dy <= slack; dy++)
            for (var dx = -slack; dx <= slack; dx++)
                if (x + dx >= 0 && y + dy >= 0 && Luma(image, x + dx, y + dy) <= Math.Max(luma + tolerance, FaintInk)) return true;
        return false;
    }

    /// <summary>Brightness 0-255 of a BGR pixel; white outside the image.</summary>
    private static int Luma(RenderedImage img, int x, int y)
    {
        if (x >= img.Width || y >= img.Height) return 255;
        var i = y * img.Stride + x * 3;
        var p = img.Pixels;
        return (p[i + 2] * 299 + p[i + 1] * 587 + p[i] * 114) / 1000;
    }

    /// <summary>Groups changed blocks lying within two blocks of each other and returns each group's tight pixel box.</summary>
    private static List<RectD> Regions(int[] counts, (int X0, int Y0, int X1, int Y1)[] bounds, int bw, int bh, int minPixels)
    {
        var regions = new List<RectD>();
        var seen = new bool[counts.Length];
        var stack = new Stack<int>();
        for (var start = 0; start < counts.Length; start++)
        {
            if (seen[start] || counts[start] < minPixels) continue;
            seen[start] = true;
            stack.Push(start);
            var box = bounds[start];
            while (stack.Count > 0)
            {
                var b = stack.Pop();
                int bx = b % bw, by = b / bw;
                for (var dy = -2; dy <= 2; dy++)
                    for (var dx = -2; dx <= 2; dx++)
                    {
                        int nx = bx + dx, ny = by + dy;
                        if (nx < 0 || ny < 0 || nx >= bw || ny >= bh) continue;
                        var n = ny * bw + nx;
                        if (seen[n] || counts[n] < minPixels) continue;
                        seen[n] = true;
                        var nb = bounds[n];
                        box = (Math.Min(box.X0, nb.X0), Math.Min(box.Y0, nb.Y0), Math.Max(box.X1, nb.X1), Math.Max(box.Y1, nb.Y1));
                        stack.Push(n);
                    }
            }
            regions.Add(new RectD(box.X0, box.Y0, box.X1 - box.X0 + 1, box.Y1 - box.Y0 + 1));
        }
        return regions;
    }
}
