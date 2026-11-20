using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// Where the old page's points are on the new page: turned <see cref="Angle"/> degrees clockwise about
/// (<see cref="CenterX"/>, <see cref="CenterY"/>) and made <see cref="Scale"/> times as large there, then shifted by
/// (<see cref="Dx"/>, <see cref="Dy"/>) points. A page scanned a quarter turn off has an angle near 90, 180 or 270; one
/// scanned at another size, a scale other than 1.
/// </summary>
public readonly record struct PageAlignment(double Dx, double Dy, double Angle, double CenterX, double CenterY, double Scale = 1)
{
    public static PageAlignment None { get; } = new(0, 0, 0, 0, 0);

    public bool IsNone => Dx == 0 && Dy == 0 && Angle == 0 && S == 1;

    /// <summary>The scale, 1 for a default value.</summary>
    private double S => Scale > 0 && double.IsFinite(Scale) ? Scale : 1;

    /// <summary>A point of the old page, on the new page.</summary>
    public (double X, double Y) ToNew(double x, double y)
    {
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        var (rx, ry) = (x - CenterX, y - CenterY);
        return (CenterX + S * (rx * cos - ry * sin) + Dx, CenterY + S * (rx * sin + ry * cos) + Dy);
    }

    /// <summary>A point of the new page, on the old page.</summary>
    public (double X, double Y) ToOld(double x, double y)
    {
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        var (rx, ry) = ((x - Dx - CenterX) / S, (y - Dy - CenterY) / S);
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
/// shift from where the ink of the two pages falls; a page scanned at another size or a quarter turn off is first brought
/// to the other's size and way up, from where most of each page's ink lies. An alignment that doesn't make the ink agree
/// better isn't used.
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

    /// <summary>
    /// Finds the alignment of two pages rendered at <paramref name="scale"/>: first as they lie (turned a little, shifted);
    /// then, for a page scanned at another size or a quarter turn off, the new page brought to the old one's frame (each
    /// quarter turn, at the size that makes the two pages' ink as large) and lined up the same way. The one whose ink agrees
    /// best is kept, if it agrees better than the pages as they lie.
    /// </summary>
    /// <param name="scale">Pixels per point of both images.</param>
    public static PageAlignment Find(RenderedImage oldImage, RenderedImage newImage, double scale, CancellationToken cancel = default)
    {
        var (w, h) = (Math.Max(oldImage.Width, newImage.Width), Math.Max(oldImage.Height, newImage.Height));
        if (w < 16 || h < 16 || Math.Min(oldImage.Width, oldImage.Height) < 16 || Math.Min(newImage.Width, newImage.Height) < 16) return PageAlignment.None;
        var oldGray = Gray(oldImage, w, h);
        var asLaid = Lined(oldGray, Gray(newImage, w, h), w, h, scale, cancel);
        var best = asLaid;

        // Another size or a quarter turn: the new page's ink framed like the old page's, tried coarsely for each turn.
        var (ow, oh) = (oldImage.Width, oldImage.Height);
        var oldOwn = Gray(oldImage, ow, oh);
        var newOwn = Gray(newImage, newImage.Width, newImage.Height);
        if (InkBox(oldOwn, ow, oh) is { } oldBox && InkBox(newOwn, newImage.Width, newImage.Height) is { } newBox)
        {
            var oldInk = Mask(oldOwn);
            var oldCoarse = Coarse(oldInk, ow, oh, CoarseCell);
            double Agrees((bool[] Ink, int W, int H) old, Frame f, int cell) =>
                ShiftFor(old.Ink, Coarse(Mask(Framed(newOwn, newImage.Width, newImage.Height, ow, oh, f)), ow, oh, cell).Ink, old.W, old.H, cancel).Agreement;
            var plainCoarse = ShiftFor(oldCoarse.Ink, Coarse(Mask(Gray(newImage, ow, oh)), ow, oh, CoarseCell).Ink, oldCoarse.W, oldCoarse.H, cancel).Agreement;
            var frames = Frames(oldBox, newBox).Select(f => (Frame: f, Agreement: Agrees(oldCoarse, f, CoarseCell)))
                .Where(f => f.Agreement > plainCoarse + 0.02).OrderByDescending(f => f.Agreement).Take(1);
            foreach (var (rough, _) in frames)
            {
                cancel.ThrowIfCancellationRequested();
                // The ink boxes give the size to a percent or so (a stamp in the margin moves one, a few lines measure
                // poorly), and at a page's edge a percent is several points: tried a little smaller and larger, at 2 pixels.
                var fine = Coarse(oldInk, ow, oh, 2);
                var sized = (Frame: rough, Agreement: Agrees(fine, rough, 2));
                foreach (var (step, count) in new[] { (0.01, 5), (0.003, 2) })
                {
                    var around = sized.Frame.Scale;
                    for (var k = -count; k <= count; k++)
                    {
                        cancel.ThrowIfCancellationRequested();
                        if (k == 0 || around * (1 + k * step) is < MinScale or > MaxScale) continue;
                        var f = sized.Frame with { Scale = around * (1 + k * step) };
                        if (Agrees(fine, f, 2) is var a && a > sized.Agreement) sized = (f, a);
                    }
                }
                var frame = sized.Frame;
                var framed = Lined(oldOwn, Framed(newOwn, newImage.Width, newImage.Height, ow, oh, frame), ow, oh, scale, cancel);
                if (framed.Agreement > best.Agreement) best = (Then(framed.Alignment, frame, scale), framed.Agreement, framed.AsIs);
            }
        }
        // Only if it helps: pages unlike each other have no "right" place, and a chance overlap mustn't move one.
        return best.Agreement <= asLaid.AsIs + 0.02 ? PageAlignment.None : best.Alignment;
    }

    /// <summary>
    /// How the new page is laid in the old page's frame (pixels): a point m of the frame is the new page's point
    /// <c>NewCenter + Scale · turn(m − OldCenter)</c>, turned <see cref="Quarter"/> quarter turns clockwise.
    /// </summary>
    private readonly record struct Frame(int Quarter, double Scale, double OldX, double OldY, double NewX, double NewY)
    {
        public (double X, double Y) ToNew(double x, double y)
        {
            var (rx, ry) = (x - OldX, y - OldY);
            var (tx, ty) = Quarter switch { 1 => (-ry, rx), 2 => (-rx, -ry), 3 => (ry, -rx), _ => (rx, ry) };
            return (NewX + Scale * tx, NewY + Scale * ty);
        }
    }

    /// <summary>Smallest and largest size of one page's ink to the other's looked for.</summary>
    private const double MinScale = 0.33, MaxScale = 3;

    /// <summary>
    /// The frames worth trying: each quarter turn whose ink box, turned, has the old box's proportions (within an eighth),
    /// at the size that makes them as large; not the page as it lies (<see cref="Lined"/> has it).
    /// </summary>
    private static IEnumerable<Frame> Frames(RectD oldBox, RectD newBox)
    {
        for (var q = 0; q < 4; q++)
        {
            var (bw, bh) = q % 2 == 0 ? (newBox.Width, newBox.Height) : (newBox.Height, newBox.Width);
            var (sx, sy) = (bw / oldBox.Width, bh / oldBox.Height);
            if (Math.Max(sx, sy) / Math.Min(sx, sy) > 1.125) continue;
            var s = Math.Sqrt(sx * sy);
            if (s is < MinScale or > MaxScale || (q == 0 && Math.Abs(s - 1) < 0.02)) continue;
            yield return new Frame(q, s, oldBox.CenterX, oldBox.CenterY, newBox.CenterX, newBox.CenterY);
        }
    }

    /// <summary>The new page's gray laid in the old page's frame (<paramref name="w"/> × <paramref name="h"/>), white beyond it.</summary>
    private static byte[] Framed(byte[] gray, int gw, int gh, int w, int h, Frame f)
    {
        var framed = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var (nx, ny) = f.ToNew(x + 0.5, y + 0.5);
                var (sx, sy) = ((int)Math.Floor(nx), (int)Math.Floor(ny));
                framed[y * w + x] = sx < 0 || sy < 0 || sx >= gw || sy >= gh ? (byte)255 : gray[sy * gw + sx];
            }
        return framed;
    }

    /// <summary>
    /// The alignment of the old page with the new one, from <paramref name="a"/> (old page to the framed new page) and the
    /// frame (framed to new): <c>new = NewCenter + s·Q·(C + R(old − C) + D − OldCenter)</c>, which is again a turn about C,
    /// a scale and a shift.
    /// </summary>
    private static PageAlignment Then(PageAlignment a, Frame f, double scale)
    {
        var (cx, cy) = (a.IsNone ? 0 : a.CenterX, a.IsNone ? 0 : a.CenterY);
        var (mx, my) = f.ToNew((cx + a.Dx) * scale, (cy + a.Dy) * scale);
        return new PageAlignment(mx / scale - cx, my / scale - cy, a.Angle + 90 * f.Quarter, cx, cy, f.Scale);
    }

    /// <summary>
    /// Where most of a page's ink is (pixels): the box between the 1st and 99th hundredth of it along each side, so a speck
    /// at the edge doesn't move it; null for a page with too little ink or ink in too narrow a band to measure.
    /// </summary>
    private static RectD? InkBox(byte[] gray, int w, int h)
    {
        var ink = Mask(gray);
        var (cols, rows) = (Profile(ink, w, h, alongX: true), Profile(ink, w, h, alongX: false));
        long total = cols.Sum();
        if (total < 200) return null;
        var (x0, x1) = (Hundredth(cols, total, 0.01), Hundredth(cols, total, 0.99));
        var (y0, y1) = (Hundredth(rows, total, 0.01), Hundredth(rows, total, 0.99));
        if (x1 - x0 < w / 25 || y1 - y0 < h / 25) return null;
        return RectD.FromEdges(x0, y0, x1 + 1, y1 + 1);

        static int Hundredth(int[] profile, long total, double share)
        {
            var (sum, want) = (0L, (long)Math.Ceiling(total * share));
            for (var i = 0; i < profile.Length; i++)
                if ((sum += profile[i]) >= want) return i;
            return profile.Length - 1;
        }
    }

    /// <summary>Pixels a coarse ink cell is wide and high, to tell which way up the new page goes.</summary>
    private const int CoarseCell = 4;

    /// <summary>The ink in cells of <paramref name="cell"/> pixels (a cell with any ink is ink): quicker to try a frame on.</summary>
    private static (bool[] Ink, int W, int H) Coarse(bool[] ink, int w, int h, int cell)
    {
        var (cw, ch) = ((w + cell - 1) / cell, (h + cell - 1) / cell);
        var coarse = new bool[cw * ch];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                if (ink[y * w + x]) coarse[y / cell * cw + x / cell] = true;
        return (coarse, cw, ch);
    }

    /// <summary>
    /// The pages as they lie (both <paramref name="w"/> × <paramref name="h"/>): turned a little and shifted to make their ink
    /// agree best. Agreement: of that alignment; AsIs: of the pages unmoved. The alignment is <see cref="PageAlignment.None"/>
    /// when nothing beat unmoved.
    /// </summary>
    private static (PageAlignment Alignment, double Agreement, double AsIs) Lined(byte[] oldGray, byte[] newGray, int w, int h, double scale, CancellationToken cancel)
    {
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

        var asIs = Agreement(oldInk, Mask(newGray), w, h, 0, 0);
        if (best.Agreement <= asIs + 0.02) return (PageAlignment.None, asIs, asIs);
        // The shift was found on the turned page, so on the new page it is turned too.
        var (sin, cos) = Math.SinCos(best.Angle * Math.PI / 180);
        return (new PageAlignment((best.Dx * cos - best.Dy * sin) / scale, (best.Dx * sin + best.Dy * cos) / scale, best.Angle, cx / scale, cy / scale),
            best.Agreement, asIs);
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

    /// <summary>Brightness, the image padded with white (or cut) to <paramref name="w"/> × <paramref name="h"/>.</summary>
    private static byte[] Gray(RenderedImage img, int w, int h)
    {
        var gray = new byte[w * h];
        Array.Fill(gray, (byte)255);
        for (var y = 0; y < Math.Min(img.Height, h); y++)
            for (var x = 0; x < Math.Min(img.Width, w); x++)
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
