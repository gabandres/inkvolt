namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// A photo on the scanner glass: a rectangle that may be turned. All lengths are in units of the scan's width (so the box
/// keeps its shape on any copy of the scan: multiply by that copy's pixel width), x to the right, y down. <see cref="Angle"/>
/// is how far the photo is turned clockwise as seen on screen, within ±45°; <see cref="QuarterTurns"/> turns the saved photo
/// a further quarter clockwise each (a portrait print laid on its side).
/// </summary>
public readonly record struct PhotoBox(double CenterX, double CenterY, double Width, double Height, double Angle, int QuarterTurns = 0)
{
    /// <summary>The corners, clockwise from the photo's own top-left.</summary>
    public (double X, double Y)[] Corners()
    {
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        var (cx, cy, hw, hh) = (CenterX, CenterY, Width / 2, Height / 2);
        return [.. new[] { (-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh) }.Select(c => (cx + c.Item1 * cos - c.Item2 * sin, cy + c.Item1 * sin + c.Item2 * cos))];
    }

    /// <summary>A point in the box's own frame: along its width and its height, from its centre.</summary>
    public (double U, double V) ToLocal(double x, double y)
    {
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        var (dx, dy) = (x - CenterX, y - CenterY);
        return (cos * dx + sin * dy, -sin * dx + cos * dy);
    }

    public bool Contains(double x, double y)
    {
        var (u, v) = ToLocal(x, y);
        return Math.Abs(u) <= Width / 2 && Math.Abs(v) <= Height / 2;
    }

    /// <summary>Corner <paramref name="corner"/> (as <see cref="Corners"/> numbers them) dragged to (x, y), the opposite corner staying put.</summary>
    public PhotoBox WithCorner(int corner, double x, double y, double min = 0.02)
    {
        var opposite = Corners()[(corner + 2) % 4];
        var (ou, ov) = ToLocal(opposite.X, opposite.Y);
        var (pu, pv) = ToLocal(x, y);
        // Keep the dragged corner on its own side of the opposite one, at least min away.
        var su = corner is 1 or 2 ? 1 : -1;
        var sv = corner is 2 or 3 ? 1 : -1;
        pu = ou + su * Math.Max(min, su * (pu - ou));
        pv = ov + sv * Math.Max(min, sv * (pv - ov));
        var (mu, mv) = ((pu + ou) / 2, (pv + ov) / 2);
        var (sin, cos) = Math.SinCos(Angle * Math.PI / 180);
        return this with
        {
            CenterX = CenterX + mu * cos - mv * sin,
            CenterY = CenterY + mu * sin + mv * cos,
            Width = Math.Abs(pu - ou),
            Height = Math.Abs(pv - ov),
        };
    }

    /// <summary>The same box turned <paramref name="degrees"/> more, kept within ±45° by swapping its sides.</summary>
    public PhotoBox Turned(double degrees) => Normalized(this with { Angle = Angle + degrees });

    internal static PhotoBox Normalized(PhotoBox box)
    {
        var angle = box.Angle % 180;
        if (angle > 90) angle -= 180;
        if (angle <= -90) angle += 180;
        if (angle > 45) return box with { Angle = angle - 90, Width = box.Height, Height = box.Width };
        if (angle <= -45) return box with { Angle = angle + 90, Width = box.Height, Height = box.Width };
        return box with { Angle = angle };
    }
}

/// <summary>
/// Finds the photos laid on the glass in a flatbed scan of the whole glass: the lid's level is the most common light level;
/// whatever differs from it is a print. On a coarse grid (about 50 cells per inch) the mask loses specks, hairs and thin lid
/// shadows (opening), closes small gaps and light patches inside prints (closing, then holes filled), and each remaining
/// connected component that's at least an inch on a side, mostly filling its box, becomes the smallest rectangle around it
/// (rotating calipers over its convex hull), trimmed a little at the edges. Prints laid closer than about 0.2 in can come out
/// as one; prints with white borders lose the border (it looks like the lid). Returned in reading order.
/// </summary>
public static class PhotoFinder
{
    /// <summary>How far from the lid's level a pixel must be to be part of a print.</summary>
    private const int Contrast = 16;

    /// <summary>Smallest print side, in inches.</summary>
    public const double MinSide = 0.9;

    /// <summary>Trimmed off each edge, in inches: the print's edge, its shadow and the grid's coarseness.</summary>
    public const double Trim = 0.02;

    public static List<PhotoBox> Find(GrayImage img, double pixelsPerInch)
    {
        if (img.Width < 32 || img.Height < 32 || pixelsPerInch < 20) return [];
        var lid = LidLevel(img);
        if (lid < 0) return [];

        // The grid: each cell is a print cell when most of its pixels differ from the lid.
        var cell = Math.Max(1, (int)Math.Round(pixelsPerInch / 50));
        var (gw, gh) = ((img.Width + cell - 1) / cell, (img.Height + cell - 1) / cell);
        var mask = new bool[gw * gh];
        for (var gy = 0; gy < gh; gy++)
            for (var gx = 0; gx < gw; gx++)
            {
                int on = 0, all = 0;
                for (var y = gy * cell; y < Math.Min(img.Height, (gy + 1) * cell); y++)
                    for (var x = gx * cell; x < Math.Min(img.Width, (gx + 1) * cell); x++, all++)
                        if (Math.Abs(img[x, y] - lid) > Contrast) on++;
                mask[gy * gw + gx] = 2 * on > all;
            }
        var cellsPerInch = pixelsPerInch / cell;
        var open = Math.Max(1, (int)Math.Round(0.04 * cellsPerInch));
        var close = Math.Max(1, (int)Math.Round(0.08 * cellsPerInch));
        mask = Dilate(Erode(mask, gw, gh, open), gw, gh, open);
        mask = Close(mask, gw, gh, close);
        FillHoles(mask, gw, gh);

        var boxes = new List<PhotoBox>();
        var seen = new bool[mask.Length];
        var stack = new Stack<int>();
        var cells = new List<int>();
        for (var start = 0; start < mask.Length; start++)
        {
            if (!mask[start] || seen[start]) continue;
            cells.Clear();
            seen[start] = true;
            stack.Push(start);
            while (stack.Count > 0)
            {
                var i = stack.Pop();
                cells.Add(i);
                var (x, y) = (i % gw, i / gw);
                if (x > 0) Visit(i - 1);
                if (x < gw - 1) Visit(i + 1);
                if (y > 0) Visit(i - gw);
                if (y < gh - 1) Visit(i + gw);
            }
            if (Box(cells, mask, gw, gh, cellsPerInch) is { } found)
            {
                // Grid cells → units of the scan's width, trimmed.
                var scale = cell / (double)img.Width;
                var trim = 2 * Trim * pixelsPerInch / img.Width;
                boxes.Add(found with
                {
                    CenterX = found.CenterX * scale, CenterY = found.CenterY * scale,
                    Width = found.Width * scale - trim, Height = found.Height * scale - trim,
                });
            }
        }
        return ReadingOrder(boxes);

        void Visit(int j)
        {
            if (!mask[j] || seen[j]) return;
            seen[j] = true;
            stack.Push(j);
        }
    }

    /// <summary>The lid's level: the most common light level (smoothed histogram peak at 128 or above); -1 for a dark lid.</summary>
    private static int LidLevel(GrayImage img)
    {
        var histogram = new long[256];
        foreach (var p in img.Pixels) histogram[p]++;
        int best = -1;
        long bestCount = 0;
        for (var level = 128; level < 256; level++)
        {
            long sum = 0;
            for (var k = Math.Max(0, level - 3); k <= Math.Min(255, level + 3); k++) sum += histogram[k];
            if (sum > bestCount) (best, bestCount) = (level, sum);
        }
        return bestCount * 10 < img.Pixels.Length ? -1 : best; // under a tenth of the glass: no lid to go by
    }

    /// <summary>The smallest rectangle around a component, in grid cells; null when it isn't print-shaped.</summary>
    private static PhotoBox? Box(List<int> cells, bool[] mask, int gw, int gh, double cellsPerInch)
    {
        var minSide = MinSide * cellsPerInch;
        if (cells.Count < minSide * minSide) return null;

        // The corners of the component's edge cells.
        var points = new List<(double X, double Y)>();
        foreach (var i in cells)
        {
            var (x, y) = (i % gw, i / gw);
            var edge = x == 0 || y == 0 || x == gw - 1 || y == gh - 1 || !mask[i - 1] || !mask[i + 1] || !mask[i - gw] || !mask[i + gw];
            if (!edge) continue;
            points.Add((x, y));
            points.Add((x + 1, y));
            points.Add((x, y + 1));
            points.Add((x + 1, y + 1));
        }
        var hull = ConvexHull(points);
        if (hull.Count < 3) return null;

        PhotoBox? best = null;
        var bestArea = double.MaxValue;
        for (var e = 0; e < hull.Count; e++)
        {
            var (a, b) = (hull[e], hull[(e + 1) % hull.Count]);
            var angle = Math.Atan2(b.Y - a.Y, b.X - a.X);
            var (sin, cos) = Math.SinCos(angle);
            double minU = double.MaxValue, maxU = double.MinValue, minV = double.MaxValue, maxV = double.MinValue;
            foreach (var (px, py) in hull)
            {
                var u = cos * px + sin * py;
                var v = -sin * px + cos * py;
                (minU, maxU, minV, maxV) = (Math.Min(minU, u), Math.Max(maxU, u), Math.Min(minV, v), Math.Max(maxV, v));
            }
            var area = (maxU - minU) * (maxV - minV);
            if (area >= bestArea) continue;
            bestArea = area;
            var (mu, mv) = ((minU + maxU) / 2, (minV + maxV) / 2);
            best = PhotoBox.Normalized(new PhotoBox(cos * mu - sin * mv, sin * mu + cos * mv, maxU - minU, maxV - minV, angle * 180 / Math.PI));
        }
        if (best is not { } box || box.Width < minSide || box.Height < minSide || cells.Count < 0.5 * bestArea) return null;
        return Math.Abs(box.Angle) < 0.25 ? box with { Angle = 0 } : box with { Angle = Math.Round(box.Angle, 2) };
    }

    /// <summary>Andrew's monotone chain; counter-clockwise in a y-up frame.</summary>
    private static List<(double X, double Y)> ConvexHull(List<(double X, double Y)> points)
    {
        var sorted = points.Distinct().OrderBy(p => p.X).ThenBy(p => p.Y).ToList();
        if (sorted.Count < 3) return sorted;
        var hull = new List<(double X, double Y)>(2 * sorted.Count);
        foreach (var pass in new[] { sorted, Enumerable.Reverse(sorted).ToList() })
        {
            var start = hull.Count;
            foreach (var p in pass)
            {
                while (hull.Count >= start + 2 && Cross(hull[^2], hull[^1], p) <= 0) hull.RemoveAt(hull.Count - 1);
                hull.Add(p);
            }
            hull.RemoveAt(hull.Count - 1);
        }
        return hull;

        static double Cross((double X, double Y) o, (double X, double Y) a, (double X, double Y) b) =>
            (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);
    }

    /// <summary>Rows top to bottom (a box joins a row when its centre is above the middle of the row's first box's lower half), each left to right.</summary>
    private static List<PhotoBox> ReadingOrder(List<PhotoBox> boxes)
    {
        var ordered = new List<PhotoBox>();
        var rest = boxes.OrderBy(b => b.CenterY).ToList();
        while (rest.Count > 0)
        {
            var first = rest[0];
            var limit = first.CenterY + first.Height / 2;
            var row = rest.TakeWhile(b => b.CenterY < limit).ToList();
            ordered.AddRange(row.OrderBy(b => b.CenterX));
            rest.RemoveRange(0, row.Count);
        }
        return ordered;
    }

    // ---- Binary morphology on the grid (square window of radius r; the window is clipped at the edges, so prints
    //      against the edge of the glass keep their edge) ----

    private static int[] Sums(bool[] mask, int w, int h)
    {
        var sums = new int[(w + 1) * (h + 1)];
        for (var y = 0; y < h; y++)
            for (int x = 0, row = 0; x < w; x++)
            {
                row += mask[y * w + x] ? 1 : 0;
                sums[(y + 1) * (w + 1) + x + 1] = sums[y * (w + 1) + x + 1] + row;
            }
        return sums;
    }

    private static bool[] Window(bool[] mask, int w, int h, int r, bool dilate)
    {
        var sums = Sums(mask, w, h);
        var result = new bool[mask.Length];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var (x0, y0, x1, y1) = (Math.Max(0, x - r), Math.Max(0, y - r), Math.Min(w, x + r + 1), Math.Min(h, y + r + 1));
                var count = sums[y1 * (w + 1) + x1] - sums[y0 * (w + 1) + x1] - sums[y1 * (w + 1) + x0] + sums[y0 * (w + 1) + x0];
                result[y * w + x] = dilate ? count > 0 : count == (x1 - x0) * (y1 - y0);
            }
        return result;
    }

    internal static bool[] Dilate(bool[] mask, int w, int h, int r) => Window(mask, w, h, r, dilate: true);
    internal static bool[] Erode(bool[] mask, int w, int h, int r) => Window(mask, w, h, r, dilate: false);

    /// <summary>
    /// Closing on a grid padded with lid all round, so a gap between a print and the edge of the glass stays open (the clipped
    /// window alone would fill it), while a print against the edge keeps its edge.
    /// </summary>
    internal static bool[] Close(bool[] mask, int w, int h, int r)
    {
        var (pw, ph) = (w + 2 * r, h + 2 * r);
        var padded = new bool[pw * ph];
        for (var y = 0; y < h; y++) Array.Copy(mask, y * w, padded, (y + r) * pw + r, w);
        padded = Erode(Dilate(padded, pw, ph, r), pw, ph, r);
        var result = new bool[mask.Length];
        for (var y = 0; y < h; y++) Array.Copy(padded, (y + r) * pw + r, result, y * w, w);
        return result;
    }

    /// <summary>Lid cells the lid around the edges can't reach (light patches inside a print) become print.</summary>
    internal static void FillHoles(bool[] mask, int w, int h)
    {
        var outside = new bool[mask.Length];
        var stack = new Stack<int>();
        for (var x = 0; x < w; x++) { Seed(x); Seed((h - 1) * w + x); }
        for (var y = 0; y < h; y++) { Seed(y * w); Seed(y * w + w - 1); }
        while (stack.Count > 0)
        {
            var i = stack.Pop();
            var (x, y) = (i % w, i / w);
            if (x > 0) Seed(i - 1);
            if (x < w - 1) Seed(i + 1);
            if (y > 0) Seed(i - w);
            if (y < h - 1) Seed(i + w);
        }
        for (var i = 0; i < mask.Length; i++) if (!outside[i]) mask[i] = true;

        void Seed(int i)
        {
            if (mask[i] || outside[i]) return;
            outside[i] = true;
            stack.Push(i);
        }
    }
}

/// <summary>Cuts a found photo out of the full-size scan, straight: only the pixels around it are read and turned (<see cref="PageRotate"/>).</summary>
public static class PhotoCrop
{
    /// <summary>The pixels to read for <paramref name="box"/> from a <paramref name="width"/> × <paramref name="height"/> scan: its corners, a little around, inside the scan.</summary>
    public static (int X, int Y, int Width, int Height) Bounds(PhotoBox box, int width, int height)
    {
        var corners = box.Corners();
        var x0 = Math.Clamp((int)Math.Floor(corners.Min(c => c.X) * width) - 2, 0, width - 1);
        var y0 = Math.Clamp((int)Math.Floor(corners.Min(c => c.Y) * width) - 2, 0, height - 1);
        var x1 = Math.Clamp((int)Math.Ceiling(corners.Max(c => c.X) * width) + 2, x0 + 1, width);
        var y1 = Math.Clamp((int)Math.Ceiling(corners.Max(c => c.Y) * width) + 2, y0 + 1, height);
        return (x0, y0, x1 - x0, y1 - y0);
    }

    /// <summary>
    /// The photo, turned straight: <paramref name="region"/> is the part of the scan <see cref="Bounds"/> gave (at
    /// <paramref name="regionX"/>, <paramref name="regionY"/>, rows <paramref name="stride"/> bytes apart, 1 or 3 channels), the
    /// scan <paramref name="scanWidth"/> pixels wide. Rows of the result are padded to 4 bytes.
    /// </summary>
    public static (byte[] Pixels, int Width, int Height, int Stride) Straighten(byte[] region, int regionWidth, int regionHeight, int stride,
        int channels, PhotoBox box, int scanWidth, int regionX, int regionY)
    {
        var turned = box.Angle == 0 ? region : PageRotate.Rotate(region, regionWidth, regionHeight, stride, channels, -box.Angle);
        // Where the box's centre is in the turned region (turned about the region's centre, as PageRotate does).
        var (rcx, rcy) = ((regionWidth - 1) / 2.0, (regionHeight - 1) / 2.0);
        var (dx, dy) = (box.CenterX * scanWidth - regionX - rcx, box.CenterY * scanWidth - regionY - rcy);
        var (sin, cos) = Math.SinCos(box.Angle * Math.PI / 180);
        var (cx, cy) = (cos * dx + sin * dy + rcx, -sin * dx + cos * dy + rcy);

        var w = Math.Max(1, (int)Math.Round(box.Width * scanWidth));
        var h = Math.Max(1, (int)Math.Round(box.Height * scanWidth));
        var x0 = Math.Clamp((int)Math.Round(cx - w / 2.0), 0, regionWidth - 1);
        var y0 = Math.Clamp((int)Math.Round(cy - h / 2.0), 0, regionHeight - 1);
        w = Math.Min(w, regionWidth - x0);
        h = Math.Min(h, regionHeight - y0);
        var outStride = (w * channels + 3) & ~3;
        var pixels = new byte[outStride * h];
        for (var row = 0; row < h; row++)
            Array.Copy(turned, (y0 + row) * stride + x0 * channels, pixels, row * outStride, w * channels);
        return (pixels, w, h, outStride);
    }
}
