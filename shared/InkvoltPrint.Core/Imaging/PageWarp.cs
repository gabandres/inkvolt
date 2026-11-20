namespace InkvoltPrint.Core.Imaging;

/// <summary>The cleanup's further steps, beyond straightening, turning, smoothing, whitening and despeckling (roadmap 2.2).</summary>
[Flags]
public enum CleanupSteps
{
    None = 0,

    /// <summary>A page photographed at an angle (a trapezoid on a darker desk) is warped back to a rectangle (<see cref="Trapezoid"/>).</summary>
    Trapezoid = 1,

    /// <summary>Lines of text bent by a book's spine are flattened (<see cref="CurvedLines"/>).</summary>
    CurvedLines = 2,

    All = Trapezoid | CurvedLines,
}

/// <summary>
/// A projective map of the plane (a homography): (x, y) goes to ((a x + b y + c) / w, (d x + e y + f) / w) with
/// w = g x + h y + 1. Maps the straightened page onto the photo it was taken from.
/// </summary>
public sealed class Homography
{
    private readonly double[] _h;

    private Homography(double[] h) => _h = h;

    public (double X, double Y) Apply(double x, double y)
    {
        var w = _h[6] * x + _h[7] * y + 1;
        return ((_h[0] * x + _h[1] * y + _h[2]) / w, (_h[3] * x + _h[4] * y + _h[5]) / w);
    }

    /// <summary>The map taking each of four points <paramref name="from"/> to its partner in <paramref name="to"/>; null when three of them line up.</summary>
    public static Homography? Between(IReadOnlyList<(double X, double Y)> from, IReadOnlyList<(double X, double Y)> to)
    {
        if (from.Count != 4 || to.Count != 4) throw new ArgumentException("Four points each.");
        // Two equations a point: a x + b y + c − g x u − h y u = u, and the same for v.
        var m = new double[8, 9];
        for (var i = 0; i < 4; i++)
        {
            var (x, y) = from[i];
            var (u, v) = to[i];
            double[] r1 = [x, y, 1, 0, 0, 0, -x * u, -y * u, u];
            double[] r2 = [0, 0, 0, x, y, 1, -x * v, -y * v, v];
            for (var j = 0; j < 9; j++)
            {
                m[2 * i, j] = r1[j];
                m[2 * i + 1, j] = r2[j];
            }
        }
        // Gaussian elimination with partial pivoting.
        for (var col = 0; col < 8; col++)
        {
            var pivot = col;
            for (var r = col + 1; r < 8; r++)
                if (Math.Abs(m[r, col]) > Math.Abs(m[pivot, col])) pivot = r;
            if (Math.Abs(m[pivot, col]) < 1e-9) return null;
            if (pivot != col)
                for (var j = 0; j < 9; j++) (m[col, j], m[pivot, j]) = (m[pivot, j], m[col, j]);
            for (var r = 0; r < 8; r++)
            {
                if (r == col) continue;
                var k = m[r, col] / m[col, col];
                if (k == 0) continue;
                for (var j = col; j < 9; j++) m[r, j] -= k * m[col, j];
            }
        }
        var h = new double[8];
        for (var i = 0; i < 8; i++) h[i] = m[i, 8] / m[i, i];
        return h.All(double.IsFinite) ? new Homography(h) : null;
    }
}

/// <summary>
/// A page photographed at an angle, straightened: the cleaned image (the photo's size) holds the page in the rectangle
/// <see cref="Left"/>…<see cref="Right"/> × <see cref="Top"/>…<see cref="Bottom"/> (its proportions as the photo shows
/// them, centred, white around it), and <see cref="Map"/> takes a point of it to where it was in the photo.
/// <see cref="Corners"/>: the page's corners in the photo, clockwise from the top left.
/// </summary>
public sealed record Perspective(Homography Map, double Left, double Top, double Right, double Bottom, IReadOnlyList<(double X, double Y)> Corners)
{
    /// <summary>Where a point of the straightened page (pixels, continuous: a pixel's centre at +0.5) was in the photo.</summary>
    public (double X, double Y) Source(double x, double y) => Map.Apply(x, y);

    /// <summary>The photo's pixels (rows of <paramref name="width"/> × <paramref name="channels"/> bytes) warped onto the straightened page: same size, white outside the page.</summary>
    public byte[] Apply(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        var result = new byte[pixels.Length];
        Parallel.For(0, height, new ParallelOptions { CancellationToken = cancel }, y =>
        {
            var cy = y + 0.5;
            for (var x = 0; x < width; x++)
            {
                var o = (y * width + x) * channels;
                var cx = x + 0.5;
                if (cx < Left || cx > Right || cy < Top || cy > Bottom)
                {
                    for (var c = 0; c < channels; c++) result[o + c] = 255;
                    continue;
                }
                var (sx, sy) = Map.Apply(cx, cy);
                PageWarp.Sample(pixels, width, height, channels, sx - 0.5, sy - 0.5, result, o);
            }
        });
        return result;
    }
}

/// <summary>Sampling shared by the warps.</summary>
internal static class PageWarp
{
    /// <summary>The largest image the warps take (pixels): a page at 300 dpi up to about 25 × 25 inches. Larger is left as it is.</summary>
    public const long MaxPixels = 80_000_000;

    /// <summary>Bilinear sample at (<paramref name="x"/>, <paramref name="y"/>) (pixel indices, fractional) into <paramref name="into"/>[<paramref name="at"/>…]; white outside the image.</summary>
    public static void Sample(byte[] pixels, int width, int height, int channels, double x, double y, byte[] into, int at)
    {
        if (!(x > -1 && y > -1 && x < width && y < height))
        {
            for (var c = 0; c < channels; c++) into[at + c] = 255;
            return;
        }
        var (x0, y0) = ((int)Math.Floor(x), (int)Math.Floor(y));
        var (fx, fy) = (x - x0, y - y0);
        for (var c = 0; c < channels; c++)
        {
            double At(int px, int py) => px < 0 || py < 0 || px >= width || py >= height ? 255 : pixels[(py * width + px) * channels + c];
            var top = At(x0, y0) * (1 - fx) + At(x0 + 1, y0) * fx;
            var bottom = At(x0, y0 + 1) * (1 - fx) + At(x0 + 1, y0 + 1) * fx;
            into[at + c] = (byte)Math.Clamp(Math.Round(top * (1 - fy) + bottom * fy), 0, 255);
        }
    }

    /// <summary>A least-squares polynomial of <paramref name="degree"/> through (t, value) points; null when they can't fix one.</summary>
    public static double[]? Fit(IReadOnlyList<double> t, IReadOnlyList<double> values, int degree)
    {
        var n = degree + 1;
        if (t.Count < n) return null;
        var m = new double[n, n + 1];
        for (var k = 0; k < t.Count; k++)
        {
            var powers = new double[2 * n];
            powers[0] = 1;
            for (var i = 1; i < powers.Length; i++) powers[i] = powers[i - 1] * t[k];
            for (var i = 0; i < n; i++)
            {
                for (var j = 0; j < n; j++) m[i, j] += powers[i + j];
                m[i, n] += powers[i] * values[k];
            }
        }
        for (var col = 0; col < n; col++)
        {
            var pivot = col;
            for (var r = col + 1; r < n; r++)
                if (Math.Abs(m[r, col]) > Math.Abs(m[pivot, col])) pivot = r;
            if (Math.Abs(m[pivot, col]) < 1e-12) return null;
            if (pivot != col)
                for (var j = 0; j <= n; j++) (m[col, j], m[pivot, j]) = (m[pivot, j], m[col, j]);
            for (var r = 0; r < n; r++)
            {
                if (r == col) continue;
                var k = m[r, col] / m[col, col];
                for (var j = col; j <= n; j++) m[r, j] -= k * m[col, j];
            }
        }
        var coefficients = new double[n];
        for (var i = 0; i < n; i++) coefficients[i] = m[i, n] / m[i, i];
        return coefficients.All(double.IsFinite) ? coefficients : null;
    }

    public static double Eval(double[] coefficients, double t)
    {
        double v = 0;
        for (var i = coefficients.Length - 1; i >= 0; i--) v = v * t + coefficients[i];
        return v;
    }
}

/// <summary>
/// Trapezoid correction (ABBYY's name for it): a page photographed at an angle shows as a four-sided shape lighter than
/// the desk around it. The page is the light region not reached from the photo's edges through darker pixels; its outline's
/// four sides are fitted as straight lines, and their corners give the map that straightens it. Only when sure: the desk
/// clearly darker than the paper, the page whole in the photo (no corner cut off by its edge), four straight sides that
/// the outline follows closely, corners between 50° and 130°, and the page filling its four sides. A page lying square
/// (a scan, or a photo taken straight on) isn't warped: straightening it is <see cref="Deskew"/>'s.
/// </summary>
public static class Trapezoid
{
    /// <summary>The page is looked for on a copy at most this many pixels across.</summary>
    public const int MeasureSize = 800;

    /// <summary>A corner off square by less than this (degrees), with opposite sides within 1.5% of each other, is a page lying square.</summary>
    public const double SquareWithin = 1.5;

    /// <summary>The page's straightening, or null when the photo shows no page on a darker desk clearly enough.</summary>
    public static Perspective? Find(GrayImage gray, CancellationToken cancel = default)
    {
        var (w, h) = (gray.Width, gray.Height);
        if (w < 64 || h < 64 || (long)w * h > PageWarp.MaxPixels) return null;
        var f = Math.Max(1, (int)Math.Ceiling(Math.Max(w, h) / (double)MeasureSize));
        var small = ScanCleanup.Downscale(gray, f);
        cancel.ThrowIfCancellationRequested();
        if (FindQuad(small) is not { } quad) return null;
        var corners = quad.Select(c => (c.X * f, c.Y * f)).ToList();

        // The page's proportions as the photo shows them (the mean of each pair of opposite sides), as large as fits, centred.
        static double Length((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
        var across = (Length(corners[0], corners[1]) + Length(corners[3], corners[2])) / 2;
        var down = (Length(corners[0], corners[3]) + Length(corners[1], corners[2])) / 2;
        if (across < 1 || down < 1) return null;
        var scale = Math.Min(w / across, h / down);
        var (pw, ph) = (across * scale, down * scale);
        var (left, top) = ((w - pw) / 2, (h - ph) / 2);
        (double, double)[] rect = [(left, top), (left + pw, top), (left + pw, top + ph), (left, top + ph)];
        return Homography.Between(rect, corners) is { } map ? new Perspective(map, left, top, left + pw, top + ph, corners) : null;
    }

    /// <summary>The page's corners on the measuring copy (continuous pixels, clockwise from the top left), or null.</summary>
    internal static (double X, double Y)[]? FindQuad(GrayImage img)
    {
        var (w, h, px) = (img.Width, img.Height, img.Pixels);
        var n = w * h;

        // Paper from desk: Otsu's threshold, and the two sides clearly apart.
        var hist = new long[256];
        foreach (var p in px) hist[p]++;
        double sumAll = 0;
        for (var i = 0; i < 256; i++) sumAll += i * (double)hist[i];
        double sumDark = 0, bestVar = -1;
        long dark = 0;
        var threshold = 0;
        for (var t = 0; t < 255; t++)
        {
            dark += hist[t];
            sumDark += t * (double)hist[t];
            if (dark == 0 || dark == n) continue;
            var (m0, m1) = (sumDark / dark, (sumAll - sumDark) / (n - dark));
            var between = (double)dark * (n - dark) * (m1 - m0) * (m1 - m0);
            if (between > bestVar) (bestVar, threshold) = (between, t);
        }
        double darkSum = 0, lightSum = 0;
        long darkCount = 0;
        for (var i = 0; i <= threshold; i++)
        {
            darkSum += i * (double)hist[i];
            darkCount += hist[i];
        }
        lightSum = sumAll - darkSum;
        if (darkCount == 0 || darkCount == n) return null;
        if (lightSum / (n - darkCount) - darkSum / darkCount < 50) return null;

        // The desk: dark pixels reached from the photo's edges.
        var desk = new bool[n];
        var stack = new Stack<int>();
        void Seed(int i)
        {
            if (!desk[i] && px[i] <= threshold)
            {
                desk[i] = true;
                stack.Push(i);
            }
        }
        for (var x = 0; x < w; x++)
        {
            Seed(x);
            Seed((h - 1) * w + x);
        }
        for (var y = 0; y < h; y++)
        {
            Seed(y * w);
            Seed(y * w + w - 1);
        }
        var deskCount = 0;
        while (stack.Count > 0)
        {
            var i = stack.Pop();
            deskCount++;
            var (x, y) = (i % w, i / w);
            if (x > 0) Seed(i - 1);
            if (x < w - 1) Seed(i + 1);
            if (y > 0) Seed(i - w);
            if (y < h - 1) Seed(i + w);
        }
        if (deskCount < 0.02 * n) return null;

        // The page: the largest region the desk doesn't reach (its print and pictures are inside it).
        var label = new int[n];
        int best = 0, bestCount = 0, next = 0;
        for (var start = 0; start < n; start++)
        {
            if (desk[start] || label[start] != 0) continue;
            next++;
            label[start] = next;
            stack.Push(start);
            var count = 0;
            while (stack.Count > 0)
            {
                var i = stack.Pop();
                count++;
                var (x, y) = (i % w, i / w);
                void Visit(int j)
                {
                    if (!desk[j] && label[j] == 0)
                    {
                        label[j] = next;
                        stack.Push(j);
                    }
                }
                if (x > 0) Visit(i - 1);
                if (x < w - 1) Visit(i + 1);
                if (y > 0) Visit(i - w);
                if (y < h - 1) Visit(i + w);
            }
            if (count > bestCount) (best, bestCount) = (next, count);
        }
        if (bestCount < 0.2 * n) return null;

        // Its outline: pixels of it beside the desk. One on the photo's edge means a corner may be cut off: not sure.
        var outline = new List<(double X, double Y)>();
        var onEdge = 0;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var i = y * w + x;
                if (label[i] != best) continue;
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1)
                {
                    onEdge++;
                    continue;
                }
                if (label[i - 1] != best || label[i + 1] != best || label[i - w] != best || label[i + w] != best) outline.Add((x + 0.5, y + 0.5));
            }
        if (onEdge > 0 || outline.Count < 40) return null;

        var hull = Hull(outline);
        var four = Reduce(hull, 4);
        if (four.Count != 4) return null;

        // Each side fitted to the outline along its middle 80%, straight within a pixel and a half, followed nearly all along.
        var lines = new (double Px, double Py, double Dx, double Dy)[4];
        for (var s = 0; s < 4; s++)
        {
            var (a, b) = (four[s], four[(s + 1) % 4]);
            var len = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
            if (len < 20) return null;
            var (dx, dy) = ((b.X - a.X) / len, (b.Y - a.Y) / len);
            var near = Math.Max(3, 0.03 * len);
            var bins = new bool[20];
            var points = new List<(double X, double Y)>();
            foreach (var p in outline)
            {
                var along = ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len;
                var off = -(p.X - a.X) * dy + (p.Y - a.Y) * dx;
                if (along < 0.1 || along > 0.9 || Math.Abs(off) > near) continue;
                points.Add(p);
                bins[Math.Clamp((int)((along - 0.1) / 0.8 * 20), 0, 19)] = true;
            }
            if (bins.Count(x => x) < 17 || points.Count < 10) return null;
            var (mx, my) = (points.Average(p => p.X), points.Average(p => p.Y));
            double sxx = 0, syy = 0, sxy = 0;
            foreach (var p in points)
            {
                sxx += (p.X - mx) * (p.X - mx);
                syy += (p.Y - my) * (p.Y - my);
                sxy += (p.X - mx) * (p.Y - my);
            }
            var angle = 0.5 * Math.Atan2(2 * sxy, sxx - syy);
            var (ux, uy) = (Math.Cos(angle), Math.Sin(angle));
            var rms = Math.Sqrt(points.Average(p => Math.Pow(-(p.X - mx) * uy + (p.Y - my) * ux, 2)));
            if (rms > 1.5) return null;
            lines[s] = (mx, my, ux, uy);
        }

        // Corners where the sides meet: inside the photo, a convex shape, each corner 50° to 130°.
        var corners = new (double X, double Y)[4];
        for (var s = 0; s < 4; s++)
        {
            var (p, q) = (lines[(s + 3) % 4], lines[s]);
            var det = p.Dx * q.Dy - p.Dy * q.Dx;
            if (Math.Abs(det) < 1e-6) return null;
            var t = ((q.Px - p.Px) * q.Dy - (q.Py - p.Py) * q.Dx) / det;
            corners[s] = (p.Px + t * p.Dx, p.Py + t * p.Dy);
            if (!(corners[s].X >= 1 && corners[s].Y >= 1 && corners[s].X <= w - 1 && corners[s].Y <= h - 1)) return null;
        }
        corners = Clockwise(corners);
        var angles = new double[4];
        double? turn = null;
        for (var s = 0; s < 4; s++)
        {
            var (prev, at, next2) = (corners[(s + 3) % 4], corners[s], corners[(s + 1) % 4]);
            var (ax, ay) = (prev.X - at.X, prev.Y - at.Y);
            var (bx, by) = (next2.X - at.X, next2.Y - at.Y);
            var cross = ax * by - ay * bx;
            if (turn is { } sign && Math.Sign(cross) != Math.Sign(sign)) return null;
            turn = cross;
            angles[s] = Math.Abs(Math.Atan2(cross, ax * bx + ay * by)) * 180 / Math.PI;
            if (angles[s] < 50 || angles[s] > 130) return null;
        }

        // The page fills its four sides (not a torn sheet, nor two pages side by side).
        var area = 0.0;
        for (var s = 0; s < 4; s++) area += corners[s].X * corners[(s + 1) % 4].Y - corners[(s + 1) % 4].X * corners[s].Y;
        area = Math.Abs(area) / 2;
        var fill = bestCount / area;
        if (fill < 0.95 || fill > 1.04) return null;

        // Lying square: nothing to straighten here.
        static double Side((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
        var (top, right, bottom, left) = (Side(corners[0], corners[1]), Side(corners[1], corners[2]), Side(corners[2], corners[3]), Side(corners[3], corners[0]));
        if (angles.All(a => Math.Abs(a - 90) < SquareWithin) && Math.Abs(top - bottom) <= 0.015 * Math.Max(top, bottom) && Math.Abs(left - right) <= 0.015 * Math.Max(left, right))
            return null;
        return corners;
    }

    /// <summary>Four points in clockwise order as seen (y down), the top left first.</summary>
    private static (double X, double Y)[] Clockwise((double X, double Y)[] points)
    {
        var (cx, cy) = (points.Average(p => p.X), points.Average(p => p.Y));
        var sorted = points.OrderBy(p => Math.Atan2(p.Y - cy, p.X - cx)).ToList();
        var first = sorted.IndexOf(sorted.MinBy(p => p.X + p.Y));
        return [.. Enumerable.Range(0, 4).Select(i => sorted[(first + i) % 4])];
    }

    /// <summary>The convex hull (Andrew's monotone chain).</summary>
    private static List<(double X, double Y)> Hull(List<(double X, double Y)> points)
    {
        var p = points.Distinct().OrderBy(q => q.X).ThenBy(q => q.Y).ToList();
        if (p.Count < 3) return p;
        static double Cross((double X, double Y) o, (double X, double Y) a, (double X, double Y) b) => (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);
        var hull = new List<(double X, double Y)>();
        foreach (var q in p)
        {
            while (hull.Count >= 2 && Cross(hull[^2], hull[^1], q) <= 0) hull.RemoveAt(hull.Count - 1);
            hull.Add(q);
        }
        var lower = hull.Count + 1;
        for (var i = p.Count - 2; i >= 0; i--)
        {
            while (hull.Count >= lower && Cross(hull[^2], hull[^1], p[i]) <= 0) hull.RemoveAt(hull.Count - 1);
            hull.Add(p[i]);
        }
        hull.RemoveAt(hull.Count - 1);
        return hull;
    }

    /// <summary>A polygon reduced to <paramref name="count"/> corners, each time dropping the corner whose triangle with its neighbours is smallest (Visvalingam).</summary>
    private static List<(double X, double Y)> Reduce(List<(double X, double Y)> polygon, int count)
    {
        var p = new List<(double X, double Y)>(polygon);
        while (p.Count > count)
        {
            var (smallest, at) = (double.MaxValue, -1);
            for (var i = 0; i < p.Count; i++)
            {
                var (a, b, c) = (p[(i + p.Count - 1) % p.Count], p[i], p[(i + 1) % p.Count]);
                var area = Math.Abs((b.X - a.X) * (c.Y - a.Y) - (b.Y - a.Y) * (c.X - a.X));
                if (area < smallest) (smallest, at) = (area, i);
            }
            p.RemoveAt(at);
        }
        return p;
    }
}

/// <summary>
/// Lines of text bent on the page (a book's pages curving towards its spine, photographed or scanned open), and how to
/// flatten them. Each line is shifted across its run by an amount that changes along it: at a place u along the lines, a
/// point v across them came from v + <see cref="ShiftAt"/>(u) + <see cref="StretchAt"/>(u) × (v − <see cref="AcrossCenter"/>),
/// so lines can bow, sag towards the spine and fan out (closer together at one end) at once. Past the stretch it was
/// measured on, the map goes on with the page's tilt there (<paramref name="ShiftSlope"/>, <paramref name="StretchSlope"/>:
/// a page flattened in place of being straightened keeps no tilt at its lines' ends). Letters aren't narrowed or widened
/// along the line: the squeeze near a spine stays, as the bend of a line says how the page curves up out of the picture's
/// plane only together with the camera's distance, which a photo doesn't give.
/// </summary>
/// <param name="Vertical">The lines run down the image (a page lying sideways): u is y and v is x.</param>
/// <param name="Shift">Polynomial in t = (u − <paramref name="AlongMid"/>) / <paramref name="AlongHalf"/>, pixels.</param>
/// <param name="Stretch">Polynomial in t, pixels per pixel.</param>
/// <param name="ShiftSlope">The shift's straight-line fit's slope (per unit of t), followed past the measured stretch.</param>
/// <param name="StretchSlope">The same for the stretch.</param>
public sealed record LineCurve(bool Vertical, double AlongMid, double AlongHalf, double AlongFrom, double AlongTo,
    double AcrossCenter, double AcrossFrom, double AcrossTo, double[] Shift, double[] Stretch, double ShiftSlope = 0, double StretchSlope = 0)
{
    private double T(double u) => (Math.Clamp(u, AlongFrom, AlongTo) - AlongMid) / AlongHalf;

    /// <summary>How far past the measured stretch <paramref name="u"/> is (in t), 0 inside it.</summary>
    private double Beyond(double u) => (u - Math.Clamp(u, AlongFrom, AlongTo)) / AlongHalf;

    public double ShiftAt(double u) => PageWarp.Eval(Shift, T(u)) + ShiftSlope * Beyond(u);

    public double StretchAt(double u) => PageWarp.Eval(Stretch, T(u)) + StretchSlope * Beyond(u);

    /// <summary>Where a point across the lines at <paramref name="u"/> along them came from, across.</summary>
    public double SourceAcross(double u, double v) => v + ShiftAt(u) + StretchAt(u) * (Math.Clamp(v, AcrossFrom, AcrossTo) - AcrossCenter);

    /// <summary>Where a point of the flattened image (continuous pixels) was in the bent one.</summary>
    public (double X, double Y) Source(double x, double y) => Vertical ? (SourceAcross(y, x), y) : (x, SourceAcross(x, y));

    /// <summary>The bent image's pixels flattened (same size; white where nothing comes from).</summary>
    public byte[] Apply(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        var result = new byte[pixels.Length];
        var along = Vertical ? height : width;
        var (shift, stretch) = (new double[along], new double[along]);
        for (var u = 0; u < along; u++) (shift[u], stretch[u]) = (ShiftAt(u + 0.5), StretchAt(u + 0.5));
        Parallel.For(0, height, new ParallelOptions { CancellationToken = cancel }, y =>
        {
            for (var x = 0; x < width; x++)
            {
                var (u, v) = Vertical ? (y, x) : (x, y);
                var cv = v + 0.5;
                var sv = cv + shift[u] + stretch[u] * (Math.Clamp(cv, AcrossFrom, AcrossTo) - AcrossCenter) - 0.5;
                var (sx, sy) = Vertical ? (sv, (double)y) : (x, sv);
                PageWarp.Sample(pixels, width, height, channels, sx, sy, result, (y * width + x) * channels);
            }
        });
        return result;
    }
}

/// <summary>
/// Finds how a page's lines of text are bent (<see cref="LineCurve"/>), on a straightened, whitened page at about 100 dpi.
/// The page is cut into strips across its lines, a third of an inch apart; each strip's ink per row is a profile of its
/// lines. Going out from the strip with most ink near the middle, each strip's profile is matched to its neighbour's
/// (shifted and stretched by at most under half a line step, so a line is never matched to the next), and the matches,
/// chained, say where each line is in each strip; smooth curves through them (polynomials of degree 4 at most) are the
/// map. Only when sure: lines in rows (a clear line step), every match close (correlation 0.5 or more), the curves through
/// the matches within a third of a line step, the matched strips spanning most of the text, and the lines bent by
/// <see cref="MinBend"/> of a line step or more once one tilt of the whole page is taken out (less is left as it is). A page of pictures, tables or few lines is left as it is.
/// </summary>
public static class CurvedLines
{
    private const byte Ink = 128;

    /// <summary>Lines bent less than this share of a line step from straight are left as they are.</summary>
    public const double MinBend = 0.15;

    /// <summary>The bend of <paramref name="img"/>'s lines (full size; <paramref name="vertical"/>: they run down it), or null.</summary>
    public static LineCurve? Find(GrayImage img, int dpi, bool vertical = false, CancellationToken cancel = default)
    {
        if (img.Width < 64 || img.Height < 64 || (long)img.Width * img.Height > PageWarp.MaxPixels) return null;
        var f = Math.Max(1, (int)Math.Round(dpi / 100.0));
        var small = ScanCleanup.Downscale(img, f);
        var smallDpi = Math.Max(30, dpi / (double)f);
        var (along, across) = vertical ? (small.Height, small.Width) : (small.Width, small.Height);
        var sw = small.Width;
        var px = small.Pixels;
        bool IsInk(int u, int v) => (vertical ? px[u * sw + v] : px[v * sw + u]) < Ink;

        // Where the text is, along and across.
        var alongInk = new int[along];
        var acrossInk = new int[across];
        for (var u = 0; u < along; u++)
            for (var v = 0; v < across; v++)
                if (IsInk(u, v))
                {
                    alongInk[u]++;
                    acrossInk[v]++;
                }
        var (uFrom, uTo) = Extent(alongInk, 2);
        var (vFrom, vTo) = Extent(acrossInk, 2);
        if (uTo - uFrom < 60 || vTo - vFrom < 30) return null;
        // Columns: a gap of a quarter of an inch or more with no ink all the way across the lines. Two columns' lines
        // needn't be level with each other, so only the column with most ink is measured (the others follow its map).
        (uFrom, uTo) = WidestColumn(alongInk, uFrom, uTo, (int)Math.Ceiling(smallDpi / 4));
        if (uTo - uFrom < 60) return null;
        cancel.ThrowIfCancellationRequested();

        // Strips across the lines, about a third of an inch apart, each half again as wide.
        var stripCount = (int)((uTo - uFrom + 1) / (smallDpi / 3));
        if (stripCount < 6) return null;
        var spacing = (uTo - uFrom + 1) / (double)stripCount;
        var half = Math.Max(3, (int)Math.Round(spacing * 0.75));
        var centres = new double[stripCount];
        var profiles = new double[stripCount][];
        var inkIn = new double[stripCount];
        for (var k = 0; k < stripCount; k++)
        {
            centres[k] = uFrom + (k + 0.5) * spacing;
            var (a, b) = (Math.Max(0, (int)(centres[k] - half)), Math.Min(along, (int)(centres[k] + half)));
            var raw = new double[across];
            for (var u = a; u < b; u++)
                for (var v = vFrom; v <= vTo; v++)
                    if (IsInk(u, v)) raw[v]++;
            var smooth = new double[across];
            for (var v = vFrom; v <= vTo; v++)
                smooth[v] = (raw[Math.Max(vFrom, v - 1)] + 2 * raw[v] + raw[Math.Min(vTo, v + 1)]) / 4;
            profiles[k] = smooth;
            inkIn[k] = raw.Sum();
        }
        var minInk = 0.01 * 2 * half * (vTo - vFrom + 1);

        // The reference: the strip with most ink in the middle half.
        var reference = -1;
        for (var k = stripCount / 4; k < stripCount - stripCount / 4; k++)
            if (inkIn[k] >= minInk && (reference < 0 || inkIn[k] > inkIn[reference])) reference = k;
        if (reference < 0) return null;
        if (LineStep(profiles[reference], vFrom, vTo, smallDpi) is not { } step) return null;
        var limit = 0.45 * step;
        var vc = (vFrom + vTo + 1) / 2.0;
        var halfAcross = Math.Max(vc - vFrom, vTo + 1 - vc);

        // Chained out from the reference: each strip against the last one matched.
        var shift = new double?[stripCount];
        var stretch = new double[stripCount];
        shift[reference] = 0;
        foreach (var direction in new[] { -1, 1 })
        {
            var (lastK, a, b) = (reference, 0.0, 0.0);
            for (var k = reference + direction; k >= 0 && k < stripCount; k += direction)
            {
                cancel.ThrowIfCancellationRequested();
                if (inkIn[k] < minInk) continue;
                var (da, db, corr) = Match(profiles[lastK], profiles[k], vFrom, vTo, vc, halfAcross, limit);
                if (corr < 0.5) break;
                // This strip's map after the last one's: v ↦ vc + da + (1 + db)(a + (1 + b)(v − vc)).
                (a, b) = (da + (1 + db) * a, (1 + db) * (1 + b) - 1);
                shift[k] = a;
                stretch[k] = b;
                lastK = k;
            }
        }
        var matched = Enumerable.Range(0, stripCount).Where(k => shift[k] is not null).ToList();
        if (matched.Count < 5) return null;
        var (first, last) = (centres[matched[0]], centres[matched[^1]]);
        if (last - first < 0.6 * (uTo - uFrom)) return null;

        // Smooth curves through the matches.
        var mid = (first + last) / 2;
        var halfAlong = Math.Max(1, (last - first) / 2);
        var ts = matched.Select(k => (centres[k] - mid) / halfAlong).ToList();
        var degree = Math.Min(4, matched.Count / 2);
        if (PageWarp.Fit(ts, [.. matched.Select(k => shift[k]!.Value)], degree) is not { } shiftCurve
            || PageWarp.Fit(ts, [.. matched.Select(k => stretch[k])], degree) is not { } stretchCurve) return null;
        for (var i = 0; i < matched.Count; i++)
        {
            var miss = Math.Abs(shift[matched[i]]!.Value - PageWarp.Eval(shiftCurve, ts[i])) + Math.Abs(stretch[matched[i]] - PageWarp.Eval(stretchCurve, ts[i])) * halfAcross;
            if (miss > step / 3) return null;
        }

        // Bent enough to be worth it: how far the top, middle and bottom lines are from straight once one tilt of the whole
        // page (the middle line's, Deskew's to straighten) and a shift of each line as a whole are taken out.
        var samples = Enumerable.Range(0, 41).Select(i => -1 + i / 20.0).ToList();
        List<double> Line(double v) => [.. samples.Select(t => PageWarp.Eval(shiftCurve, t) + PageWarp.Eval(stretchCurve, t) * (v - vc))];
        if (PageWarp.Fit(samples, Line(vc), 1) is not { } tilt) return null;
        var bend = 0.0;
        foreach (var v in new[] { (double)vFrom, vTo + 1.0, vc })
        {
            var off = Line(v).Select((d, i) => d - PageWarp.Eval(tilt, samples[i])).ToList();
            var mean = off.Average();
            bend = Math.Max(bend, off.Max(d => Math.Abs(d - mean)));
        }
        if (bend < Math.Max(1.5, MinBend * step)) return null;

        // The same map at full size, its tilt going on past the measured stretch.
        var shiftTilt = PageWarp.Fit(ts, [.. matched.Select(k => shift[k]!.Value)], 1)?[1] ?? 0;
        var stretchTilt = PageWarp.Fit(ts, [.. matched.Select(k => stretch[k])], 1)?[1] ?? 0;
        return new LineCurve(vertical, mid * f, halfAlong * f, first * f, last * f, vc * f, vFrom * (double)f, (vTo + 1.0) * f,
            [.. shiftCurve.Select(c => c * f)], stretchCurve, shiftTilt * f, stretchTilt);
    }

    /// <summary>
    /// Of the text from <paramref name="from"/> to <paramref name="to"/>, the column with most ink: the stretches between
    /// gaps of <paramref name="gap"/> or more with no ink.
    /// </summary>
    internal static (int From, int To) WidestColumn(int[] ink, int from, int to, int gap)
    {
        var (best, bestInk) = ((from, to), -1L);
        var start = from;
        for (var u = from; u <= to + 1; u++)
        {
            var empty = 0;
            while (u + empty <= to && ink[u + empty] < 2) empty++;
            if (u <= to && (empty < gap || empty == 0))
            {
                u += empty;
                continue;
            }
            var end = u - 1;
            long sum = 0;
            for (var k = start; k <= end; k++) sum += ink[k];
            if (end >= start && sum > bestInk) (best, bestInk) = ((start, end), sum);
            start = u + empty;
            u += empty;
        }
        return best;
    }

    /// <summary>The first and last index with at least <paramref name="min"/> (−1, −1 when none).</summary>
    private static (int From, int To) Extent(int[] counts, int min)
    {
        var from = Array.FindIndex(counts, c => c >= min);
        var to = Array.FindLastIndex(counts, c => c >= min);
        return from < 0 ? (-1, -1) : (from, to);
    }

    /// <summary>The distance from one line to the next in a profile (its autocorrelation's first clear peak, a twentieth to two thirds of an inch), or null for no rows of lines.</summary>
    internal static double? LineStep(double[] profile, int from, int to, double dpi)
    {
        var n = to - from + 1;
        var mean = 0.0;
        for (var v = from; v <= to; v++) mean += profile[v];
        mean /= n;
        double R(int lag)
        {
            double s = 0;
            for (var v = from; v + lag <= to; v++) s += (profile[v] - mean) * (profile[v + lag] - mean);
            return s / Math.Max(1, n - lag);
        }
        var r0 = R(0);
        if (r0 <= 0) return null;
        var (minLag, maxLag) = (Math.Max(3, (int)(dpi / 20)), Math.Min(n / 3, (int)(dpi * 2 / 3)));
        if (maxLag <= minLag + 1) return null;
        var r = new double[maxLag + 2];
        for (var lag = minLag - 1; lag <= maxLag + 1; lag++) r[lag] = R(lag);
        int? best = null;
        for (var lag = minLag; lag <= maxLag; lag++)
            if (r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] && r[lag] >= 0.25 * r0 && (best is null || r[lag] > r[best.Value])) best = lag;
        return best;
    }

    /// <summary>
    /// The shift and stretch that best lay <paramref name="next"/> over <paramref name="prev"/>: next at vc + a + (1 + b)(v − vc)
    /// matches prev at v. Searched within <paramref name="limit"/> pixels of movement anywhere across, then refined; with
    /// the correlation it reaches.
    /// </summary>
    private static (double A, double B, double Corr) Match(double[] prev, double[] next, int from, int to, double vc, double halfAcross, double limit)
    {
        double Corr(double a, double b)
        {
            double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
            var n = 0;
            for (var v = from; v <= to; v++)
            {
                var at = vc + a + (1 + b) * (v + 0.5 - vc) - 0.5;
                if (at < from || at > to) continue;
                var i = (int)at;
                var fr = at - i;
                var y = i + 1 <= to ? next[i] * (1 - fr) + next[i + 1] * fr : next[i];
                var x = prev[v];
                sx += x;
                sy += y;
                sxx += x * x;
                syy += y * y;
                sxy += x * y;
                n++;
            }
            if (n < 10) return -1;
            var cov = sxy - sx * sy / n;
            var vx = sxx - sx * sx / n;
            var vy = syy - sy * sy / n;
            return vx <= 0 || vy <= 0 ? -1 : cov / Math.Sqrt(vx * vy);
        }
        var (bestA, bestB, best) = (0.0, 0.0, Corr(0, 0));
        var bLimit = limit / halfAcross;
        for (var a = -limit; a <= limit; a += 0.5)
            for (var b = -bLimit; b <= bLimit; b += 0.5 / halfAcross)
            {
                if (Math.Abs(a) + Math.Abs(b) * halfAcross > limit) continue;
                var c = Corr(a, b);
                if (c > best) (bestA, bestB, best) = (a, b, c);
            }
        var (a0, b0) = (bestA, bestB);
        for (var a = a0 - 0.5; a <= a0 + 0.5; a += 0.1)
            for (var b = b0 - 0.5 / halfAcross; b <= b0 + 0.5 / halfAcross; b += 0.1 / halfAcross)
            {
                if (Math.Abs(a) + Math.Abs(b) * halfAcross > limit) continue;
                var c = Corr(a, b);
                if (c > best) (bestA, bestB, best) = (a, b, c);
            }
        return (bestA, bestB, best);
    }
}
