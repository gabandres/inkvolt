using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// Where the old page's points are on the new page: turned <see cref="Angle"/> degrees clockwise about
/// (<see cref="CenterX"/>, <see cref="CenterY"/>), then shifted by (<see cref="Dx"/>, <see cref="Dy"/>) points.
/// </summary>
public readonly record struct PageAlignment(double Dx, double Dy, double Angle, double CenterX, double CenterY)
{
    public static PageAlignment None { get; } = new(0, 0, 0, 0, 0);

    public bool IsNone => Dx == 0 && Dy == 0 && Angle == 0;

    /// <summary>A point of the old page, on the new page.</summary>
    public (double X, double Y) ToNew(double x, double y)
    {
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        var (rx, ry) = (x - CenterX, y - CenterY);
        return (CenterX + rx * cos - ry * sin + Dx, CenterY + rx * sin + ry * cos + Dy);
    }

    /// <summary>A point of the new page, on the old page.</summary>
    public (double X, double Y) ToOld(double x, double y)
    {
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        var (rx, ry) = (x - Dx - CenterX, y - Dy - CenterY);
        return (CenterX + rx * cos + ry * sin, CenterY - rx * sin + ry * cos);
    }

    /// <summary>The upright box around a box of the old page, on the new page.</summary>
    public RectD BoxToNew(RectD r) => Around(ToNew(r.X, r.Y), ToNew(r.Right, r.Y), ToNew(r.X, r.Bottom), ToNew(r.Right, r.Bottom));

    /// <summary>The upright box around a box of the new page, on the old page.</summary>
    public RectD BoxToOld(RectD r) => Around(ToOld(r.X, r.Y), ToOld(r.Right, r.Y), ToOld(r.X, r.Bottom), ToOld(r.Right, r.Bottom));

    private static RectD Around(params (double X, double Y)[] p) =>
        RectD.FromEdges(p.Min(c => c.X), p.Min(c => c.Y), p.Max(c => c.X), p.Max(c => c.Y));
}

/// <summary>
/// Lines up two scans of a page before they are overlaid: a page fed a little crooked or a few millimetres off shouldn't
/// read as different all over. The turn comes from each page's own lines of text (<see cref="ScanCleanup.SkewOf"/>), the
/// shift from where the ink of the two pages falls; an alignment that doesn't make the ink agree better isn't used.
/// </summary>
public static class CompareAlign
{
    /// <summary>Resolution the ink is compared at (pixels per point: 100 dpi).</summary>
    private const double WorkScale = 100.0 / 72;

    /// <summary>Largest shift looked for, as a share of the page's sides.</summary>
    private const double MaxShiftShare = 0.08;

    /// <summary>Largest turn believed (degrees): as far as the scan cleanup straightens.</summary>
    private const double MaxAngle = 15;

    private const byte Ink = 160;

    /// <summary>Finds the alignment of two pages, rendered at any one scale. <see cref="PageAlignment.None"/> when none helps.</summary>
    public static PageAlignment Find(PdfEngine oldPdf, int oldPage, PdfEngine newPdf, int newPage, CancellationToken cancel = default) =>
        Find(oldPdf.Render(oldPage, WorkScale, null, cancel), newPdf.Render(newPage, WorkScale, null, cancel), WorkScale, cancel);

    /// <param name="scale">Pixels per point of both images.</param>
    public static PageAlignment Find(RenderedImage oldImage, RenderedImage newImage, double scale, CancellationToken cancel = default)
    {
        var (w, h) = (Math.Max(oldImage.Width, newImage.Width), Math.Max(oldImage.Height, newImage.Height));
        if (w < 16 || h < 16) return PageAlignment.None;
        var oldGray = Gray(oldImage, w, h);
        var newGray = Gray(newImage, w, h);
        var dpi = (int)Math.Round(scale * 72);
        var turn = ScanCleanup.SkewOf(new GrayImage(w, h, newGray), dpi) - ScanCleanup.SkewOf(new GrayImage(w, h, oldGray), dpi);
        if (Math.Abs(turn) > MaxAngle) turn = 0;
        cancel.ThrowIfCancellationRequested();

        var (cx, cy) = (w / 2.0, h / 2.0);
        var oldInk = Mask(oldGray);
        var plain = ShiftFor(oldInk, Mask(newGray), w, h, cancel);
        var best = (Angle: 0.0, plain.Dx, plain.Dy, plain.Agreement);
        // The measured turn, and the turn a hair either side of it: the two estimates each carry a little error.
        foreach (var angle in new[] { turn, turn - 0.15, turn + 0.15 })
        {
            if (angle == 0) continue;
            cancel.ThrowIfCancellationRequested();
            var turned = Mask(Turned(newGray, w, h, angle, cx, cy));
            var s = ShiftFor(oldInk, turned, w, h, cancel);
            if (s.Agreement > best.Agreement) best = (angle, s.Dx, s.Dy, s.Agreement);
        }

        // Closer still: at the far edge of a page a twentieth of a degree is a third of a point.
        if (best.Angle != 0)
            foreach (var angle in new[] { best.Angle - 0.05, best.Angle + 0.05 })
            {
                cancel.ThrowIfCancellationRequested();
                var s = ShiftFor(oldInk, Mask(Turned(newGray, w, h, angle, cx, cy)), w, h, cancel);
                if (s.Agreement > best.Agreement) best = (angle, s.Dx, s.Dy, s.Agreement);
            }

        // Only if it helps: pages unlike each other have no "right" place, and a chance overlap mustn't move one.
        var asIs = Agreement(oldInk, Mask(newGray), w, h, 0, 0);
        if (best.Agreement <= asIs + 0.02) return PageAlignment.None;
        // The shift was found on the turned page, so on the new page it is turned too.
        var (sin, cos) = Math.SinCos(best.Angle * Math.PI / 180);
        return new PageAlignment((best.Dx * cos - best.Dy * sin) / scale, (best.Dx * sin + best.Dy * cos) / scale, best.Angle, cx / scale, cy / scale);
    }

    /// <summary>
    /// The new page as seen through <paramref name="a"/>: <paramref name="width"/> × <paramref name="height"/> pixels of the old
    /// page's space, starting at (<paramref name="x0"/>, <paramref name="y0"/>) points. White where the new page doesn't reach.
    /// </summary>
    /// <param name="source">The rendered part of the new page.</param>
    /// <param name="sourceX">Where <paramref name="source"/> starts on the new page, in points.</param>
    /// <param name="sourceY">Where <paramref name="source"/> starts on the new page, in points.</param>
    public static RenderedImage Resample(RenderedImage source, double sourceX, double sourceY, double scale, PageAlignment a, int width, int height, double x0 = 0, double y0 = 0,
        CancellationToken cancel = default)
    {
        var output = GC.AllocateUninitializedArray<byte>(width * height * 3);
        var (sw, sh, stride, px) = (source.Width, source.Height, source.Stride, source.Pixels);
        for (var y = 0; y < height; y++)
        {
            if ((y & 63) == 0) cancel.ThrowIfCancellationRequested();
            var row = y * width * 3;
            for (var x = 0; x < width; x++)
            {
                var (nx, ny) = a.ToNew(x0 + (x + 0.5) / scale, y0 + (y + 0.5) / scale);
                var (sx, sy) = ((nx - sourceX) * scale - 0.5, (ny - sourceY) * scale - 0.5);
                var (ix, iy) = ((int)Math.Floor(sx), (int)Math.Floor(sy));
                var at = row + x * 3;
                if (ix < -1 || iy < -1 || ix >= sw || iy >= sh)
                {
                    output[at] = output[at + 1] = output[at + 2] = 255;
                    continue;
                }
                var (fx, fy) = (sx - ix, sy - iy);
                for (var c = 0; c < 3; c++)
                {
                    var v = Sample(px, stride, sw, sh, ix, iy, c) * (1 - fx) * (1 - fy) + Sample(px, stride, sw, sh, ix + 1, iy, c) * fx * (1 - fy)
                            + Sample(px, stride, sw, sh, ix, iy + 1, c) * (1 - fx) * fy + Sample(px, stride, sw, sh, ix + 1, iy + 1, c) * fx * fy;
                    output[at + c] = (byte)Math.Clamp(v + 0.5, 0, 255);
                }
            }
        }
        return new RenderedImage(width, height, output);
    }

    private static int Sample(byte[] px, int stride, int w, int h, int x, int y, int channel) =>
        x < 0 || y < 0 || x >= w || y >= h ? 255 : px[y * stride + x * 3 + channel];

    /// <summary>Brightness, the image padded with white to the common size.</summary>
    private static byte[] Gray(RenderedImage img, int w, int h)
    {
        var gray = new byte[w * h];
        Array.Fill(gray, (byte)255);
        for (var y = 0; y < img.Height; y++)
            for (var x = 0; x < img.Width; x++)
            {
                var i = y * img.Stride + x * 3;
                gray[y * w + x] = (byte)((img.Pixels[i + 2] * 299 + img.Pixels[i + 1] * 587 + img.Pixels[i] * 114) / 1000);
            }
        return gray;
    }

    private static bool[] Mask(byte[] gray)
    {
        var mask = new bool[gray.Length];
        for (var i = 0; i < gray.Length; i++) mask[i] = gray[i] < Ink;
        return mask;
    }

    /// <summary>Gray as if the page were turned back by <paramref name="angle"/> clockwise: each pixel taken from where it was.</summary>
    private static byte[] Turned(byte[] gray, int w, int h, double angle, double cx, double cy)
    {
        var (sin, cos) = Math.SinCos(angle * Math.PI / 180);
        var turned = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var (rx, ry) = (x + 0.5 - cx, y + 0.5 - cy);
                var sx = (int)Math.Floor(cx + rx * cos - ry * sin);
                var sy = (int)Math.Floor(cy + rx * sin + ry * cos);
                turned[y * w + x] = sx < 0 || sy < 0 || sx >= w || sy >= h ? (byte)255 : gray[sy * w + sx];
            }
        return turned;
    }

    /// <summary>
    /// The shift of the new ink that best meets the old: first from the ink's profile along each side, then tried around
    /// that on the pixels themselves. In whole pixels: a new pixel (x, y) lands at (x - dx, y - dy).
    /// </summary>
    private static (int Dx, int Dy, double Agreement) ShiftFor(bool[] oldInk, bool[] newInk, int w, int h, CancellationToken cancel)
    {
        var (maxX, maxY) = ((int)(w * MaxShiftShare), (int)(h * MaxShiftShare));
        var dx0 = BestProfileShift(Profile(oldInk, w, h, alongX: true), Profile(newInk, w, h, alongX: true), maxX);
        var dy0 = BestProfileShift(Profile(oldInk, w, h, alongX: false), Profile(newInk, w, h, alongX: false), maxY);
        var best = (dx0, dy0, Agreement(oldInk, newInk, w, h, dx0, dy0));
        for (var dy = dy0 - 3; dy <= dy0 + 3; dy++)
        {
            cancel.ThrowIfCancellationRequested();
            for (var dx = dx0 - 3; dx <= dx0 + 3; dx++)
            {
                if (dx == dx0 && dy == dy0) continue;
                var score = Agreement(oldInk, newInk, w, h, dx, dy);
                if (score > best.Item3) best = (dx, dy, score);
            }
        }
        return best;
    }

    /// <summary>Ink counted per column (along x) or per row.</summary>
    private static int[] Profile(bool[] ink, int w, int h, bool alongX)
    {
        var profile = new int[alongX ? w : h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                if (ink[y * w + x]) profile[alongX ? x : y]++;
        return profile;
    }

    private static int BestProfileShift(int[] oldProfile, int[] newProfile, int max)
    {
        var (best, bestScore) = (0, long.MinValue);
        for (var d = -max; d <= max; d++)
        {
            var score = 0L;
            for (var i = Math.Max(0, -d); i < oldProfile.Length && i + d < newProfile.Length; i++) score += (long)oldProfile[i] * newProfile[i + d];
            if (score > bestScore || (score == bestScore && Math.Abs(d) < Math.Abs(best))) (best, bestScore) = (d, score);
        }
        return best;
    }

    /// <summary>The share of ink the two pages have in common at this shift (Jaccard, 0 to 1).</summary>
    private static double Agreement(bool[] oldInk, bool[] newInk, int w, int h, int dx, int dy)
    {
        int both = 0, either = 0;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var (nx, ny) = (x + dx, y + dy);
                var n = nx >= 0 && ny >= 0 && nx < w && ny < h && newInk[ny * w + nx];
                var o = oldInk[y * w + x];
                if (o && n) both++;
                if (o || n) either++;
            }
        return either == 0 ? 0 : (double)both / either;
    }
}

/// <summary>What looks different on a row: areas of the old page (points) that aren't explained by the words on it.</summary>
public static class VisualAreas
{
    /// <summary>How much of an area must lie off the text for it to count.</summary>
    private const double MinOffText = 0.5;

    /// <summary>
    /// A row's text sits in the same place on both pages, so what looks different there has changed in itself. Text that has
    /// reflowed moves everything below it: every picture and rule then "looks different" and says nothing.
    /// </summary>
    public static bool SameLayout(PageText oldText, PageText newText)
    {
        var oldLines = Lines(oldText);
        if (oldLines.Count == 0 || newText.IsEmpty) return true;
        var newLines = Lines(newText);
        var same = oldLines.Count(newLines.Contains);
        return same >= Math.Min(oldLines.Count, newLines.Count) * 0.8;

        static HashSet<(string, int, int)> Lines(PageText page)
        {
            var lines = new HashSet<(string, int, int)>();
            var s = page.Text;
            for (var start = 0; start < s.Length;)
            {
                var end = s.IndexOf('\n', start);
                if (end < 0) end = s.Length;
                if (end > start)
                {
                    var box = page.BoxAt(start);
                    lines.Add((s[start..end], (int)Math.Round(box.X), (int)Math.Round(box.Y)));
                }
                start = end + 1;
            }
            return lines;
        }
    }

    /// <summary>
    /// The areas of <paramref name="regions"/> (points of the old page) that are mostly not under text on either page: where
    /// the words differ the text compare has said so. The new page's text is brought over through <paramref name="alignment"/>.
    /// </summary>
    public static List<RectD> OffText(IReadOnlyList<RectD> regions, PageText oldText, PageText newText, PageAlignment alignment)
    {
        if (regions.Count == 0) return [];
        var boxes = oldText.IsEmpty ? [] : oldText.GetRects(0, oldText.Text.Length);
        if (!newText.IsEmpty) boxes.AddRange(newText.GetRects(0, newText.Text.Length).Select(alignment.BoxToOld));
        var kept = new List<RectD>();
        foreach (var r in regions)
        {
            const int Grid = 12;
            var off = 0;
            for (var j = 0; j < Grid; j++)
                for (var i = 0; i < Grid; i++)
                {
                    var (x, y) = (r.X + (i + 0.5) * r.Width / Grid, r.Y + (j + 0.5) * r.Height / Grid);
                    if (!boxes.Any(b => x >= b.X - 1 && x <= b.Right + 1 && y >= b.Y - 1 && y <= b.Bottom + 1)) off++;
                }
            if (off >= Grid * Grid * MinOffText) kept.Add(r);
        }
        return kept;
    }
}
