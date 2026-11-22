namespace InkvoltPrint.Core.Imaging;

/// <summary>Where the second half goes, beside the first: to its right, below it, to its left or above it.</summary>
public enum JoinSide { Right, Below, Left, Above }

/// <summary>
/// Where the second half lies on the first: <see cref="Side"/>, turned half a turn (<see cref="Turned"/>: the original was
/// turned round on the glass for its other half), and its top-left corner at (<see cref="X"/>, <see cref="Y"/>) in the first
/// half's pixels (negative: left of or above it).
/// </summary>
public sealed record JoinPlacement(JoinSide Side, bool Turned, int X, int Y)
{
    /// <summary>The same placement in pixels <paramref name="factor"/> times as many (a smaller or larger copy of both halves).</summary>
    public JoinPlacement Scaled(double factor) => this with { X = (int)Math.Round(X * factor), Y = (int)Math.Round(Y * factor) };

    /// <summary>Moved by (<paramref name="dx"/>, <paramref name="dy"/>) pixels: the manual nudge.</summary>
    public JoinPlacement Nudged(int dx, int dy) => this with { X = X + dx, Y = Y + dy };
}

/// <summary>What <see cref="HalvesJoin.Find"/> found: the best placement, whether it is sure of it (else it's a guess to nudge), its match and the next best placement's.</summary>
public sealed record JoinFound(JoinPlacement Placement, bool Sure, double Score, double Next = -1);

/// <summary>
/// Joins two halves of an original too big for the glass, each scanned with an overlap (roadmap 4.8, as Canon IJ Scan Utility's
/// stitch): the overlap is found by matching the two scans (normalized cross-correlation, coarse at about 12 pixels an inch
/// over every side, either way up, then fine), and the halves are drawn onto one page, the seam in the middle of the overlap.
/// The halves come straightened (each page's own edits); only a shift is looked for. When the match isn't clearly better
/// than any other, the best guess is given as not sure, to be nudged by hand.
/// </summary>
public static class HalvesJoin
{
    /// <summary>The overlap looked for, inches: at least this much, at most <see cref="MaxOverlapShare"/> of the half.</summary>
    public const double MinOverlap = 0.3, MaxOverlapShare = 0.8;

    /// <summary>How far (inches) the halves may be offset along the seam.</summary>
    public const double MaxShift = 1.5;

    /// <summary>
    /// The match a sure overlap needs, and how far ahead of the next best placement it must be: the next leaves <see cref="Lead"/>
    /// times as much unmatched (1 − its score) or more. A grid or ruled lines match almost as well a step away; what is drawn on
    /// them doesn't.
    /// </summary>
    public const double SureScore = 0.7, Lead = 2;

    /// <summary>The largest page a join makes (pixels): past it the halves aren't joined.</summary>
    public const long MaxPixels = PageCleanup.MaxPixels;

    private const double CoarsePpi = 12, MinSpread = 6;

    /// <summary>How many of the coarse search's best placements are refined.</summary>
    private const int Refined = 6;

    /// <summary>The longest side of a copy <see cref="Find"/> reads (its sums are kept per row in an int).</summary>
    public const int MaxSide = 20_000;

    /// <summary>
    /// The overlap of <paramref name="first"/> and <paramref name="second"/> (grey copies at <paramref name="ppi"/> pixels an inch,
    /// both the same), as a placement in those pixels.
    /// </summary>
    public static JoinFound Find(GrayImage first, GrayImage second, double ppi, CancellationToken cancel = default)
    {
        var fallback = new JoinFound(EdgeToEdge(JoinSide.Right, false, first.Width, first.Height, second.Width, second.Height), false, 0);
        if (ppi < 4 || first.Width < 8 || first.Height < 8 || second.Width < 8 || second.Height < 8 || Math.Max(Math.Max(first.Width, first.Height), Math.Max(second.Width, second.Height)) > MaxSide)
            return fallback; // nothing to match, or not the analysis copies it is made for
        var factor = Math.Max(1, (int)Math.Round(ppi / CoarsePpi));
        var a = Shrink(first, factor);
        var coarsePpi = ppi / factor;
        var turnedSecond = Turned(second);
        var candidates = new List<(JoinSide Side, bool Turned, int X, int Y, double Score)>();
        foreach (var turned in new[] { false, true })
        {
            var b = Shrink(turned ? turnedSecond : second, factor);
            foreach (var side in Enum.GetValues<JoinSide>())
            {
                cancel.ThrowIfCancellationRequested();
                candidates.AddRange(Search(a, b, side, turned, coarsePpi, cancel));
            }
        }
        if (candidates.Count == 0) return fallback;
        // The best few placements, each at least half an inch from a better one (a grid or ruled lines repeat: the coarse copies can
        // take a step of them for the overlap), each refined on the copies given; the best of those, if well ahead of the rest.
        var far = coarsePpi / 2;
        var tops = new List<(JoinSide Side, bool Turned, int X, int Y, double Score)>();
        foreach (var c in candidates.OrderByDescending(c => c.Score))
        {
            if (tops.Any(t => t.Side == c.Side && t.Turned == c.Turned && Math.Abs(t.X - c.X) <= far && Math.Abs(t.Y - c.Y) <= far)) continue;
            tops.Add(c);
            if (tops.Count == Refined) break;
        }
        // Refined on copies at half the size given (when that still has 30 pixels an inch), then the best on the copies given.
        var half = ppi >= 60 ? 2 : 1;
        var (midFirst, midSecond, midTurned) = (Shrink(first, half), Shrink(second, half), Shrink(turnedSecond, half));
        var refined = new List<(JoinPlacement Placement, double Score)>();
        foreach (var top in tops)
        {
            cancel.ThrowIfCancellationRequested();
            var scale = factor / (double)half;
            refined.Add(Refine(midFirst, top.Turned ? midTurned : midSecond, new JoinPlacement(top.Side, top.Turned, top.X, top.Y).Scaled(scale),
                (int)Math.Ceiling(scale / 2) + 1));
        }
        var best = refined.MaxBy(r => r.Score);
        var other = refined.Where(r => r != best).Select(r => r.Score).DefaultIfEmpty(-1).Max();
        var (placement, score) = half == 1 ? best : Refine(first, best.Placement.Turned ? turnedSecond : second, best.Placement.Scaled(half), half + 1);
        // Ahead of the next: what the next leaves unmatched at least twice what the best does (a near-perfect match needs little
        // lead, a fair one a lot).
        return new JoinFound(placement, score >= SureScore && 1 - other >= Lead * (1 - best.Score), Math.Max(0, score), other);
    }

    /// <summary>The best placement within <paramref name="reach"/> pixels of <paramref name="near"/>, and its match.</summary>
    private static (JoinPlacement Placement, double Score) Refine(GrayImage a, GrayImage b, JoinPlacement near, int reach)
    {
        var (fx, fy, fine) = (near.X, near.Y, double.NegativeInfinity);
        for (var dy = -reach; dy <= reach; dy++)
            for (var dx = -reach; dx <= reach; dx++)
            {
                var score = Ncc(a, b, near.X + dx, near.Y + dy, 1);
                if (score > fine) (fx, fy, fine) = (near.X + dx, near.Y + dy, score);
            }
        return (near with { X = fx, Y = fy }, fine);
    }

    /// <summary>
    /// A placement found on copies <paramref name="factor"/> times smaller (<see cref="Gray"/>, <see cref="Shrink"/>) in the
    /// full-size pixels. A copy leaves out the last (size mod factor) columns and rows of the half, which, turned, are its first:
    /// a turned second half (<paramref name="secondWidth"/> × <paramref name="secondHeight"/> at full size) moves back by them.
    /// </summary>
    public static JoinPlacement FromCopy(JoinPlacement at, int factor, int secondWidth, int secondHeight) =>
        factor <= 1 ? at : at.Turned
            ? at with { X = at.X * factor - secondWidth % factor, Y = at.Y * factor - secondHeight % factor }
            : at.Scaled(factor);

    /// <summary>A full-size placement on copies <paramref name="factor"/> times smaller: <see cref="FromCopy"/> the other way.</summary>
    public static JoinPlacement ToCopy(JoinPlacement at, int factor, int secondWidth, int secondHeight) =>
        factor <= 1 ? at : at.Turned
            ? at with
            {
                X = (int)Math.Round((at.X + secondWidth % factor) / (double)factor),
                Y = (int)Math.Round((at.Y + secondHeight % factor) / (double)factor),
            }
            : at.Scaled(1.0 / factor);

    /// <summary>The second half edge to edge with the first on <paramref name="side"/>, centred along the seam: where a hand nudge starts.</summary>
    public static JoinPlacement EdgeToEdge(JoinSide side, bool turned, int w1, int h1, int w2, int h2) => side switch
    {
        JoinSide.Right => new(side, turned, w1, (h1 - h2) / 2),
        JoinSide.Left => new(side, turned, -w2, (h1 - h2) / 2),
        JoinSide.Below => new(side, turned, (w1 - w2) / 2, h1),
        _ => new(side, turned, (w1 - w2) / 2, -h2),
    };

    /// <summary>
    /// The two halves on one page (rows of width × <paramref name="channels"/> bytes, 1 grey or 3 BGR, both alike): the first,
    /// and the second turned as <paramref name="at"/> says, each up to the middle of their overlap; what neither covers is white.
    /// Null when the page would be larger than <see cref="MaxPixels"/>.
    /// </summary>
    public static (byte[] Pixels, int Width, int Height)? Join(byte[] first, int w1, int h1, byte[] second, int w2, int h2, int channels, JoinPlacement at)
    {
        if (channels is not (1 or 3) || w1 < 1 || h1 < 1 || w2 < 1 || h2 < 1
            || (long)w1 * h1 * channels > first.Length || (long)w2 * h2 * channels > second.Length) return null;
        var (x0, y0) = (Math.Min(0, at.X), Math.Min(0, at.Y));
        var (x1, y1) = (Math.Max(w1, (long)at.X + w2), Math.Max(h1, (long)at.Y + h2));
        var (w, h) = (x1 - x0, y1 - y0);
        if (w * h > MaxPixels || w > int.MaxValue / 4 || h > int.MaxValue / 4) return null;
        var (width, height) = ((int)w, (int)h);
        var pixels = new byte[(long)width * height * channels];
        Array.Fill(pixels, (byte)255);
        // The seam: the middle of the overlap across the join (or where they meet when they don't overlap).
        var seam = at.Side switch
        {
            JoinSide.Right => (at.X + w1) / 2.0,
            JoinSide.Left => (at.X + w2) / 2.0,
            JoinSide.Below => (at.Y + h1) / 2.0,
            _ => (at.Y + h2) / 2.0,
        };
        Parallel.For(0, height, y =>
        {
            var py = y + y0;
            for (var x = 0; x < width; x++)
            {
                var px = x + x0;
                var inFirst = px >= 0 && py >= 0 && px < w1 && py < h1;
                var (sx, sy) = (px - at.X, py - at.Y);
                var inSecond = sx >= 0 && sy >= 0 && sx < w2 && sy < h2;
                if (!inFirst && !inSecond) continue;
                var secondSide = at.Side switch
                {
                    JoinSide.Right => px >= seam,
                    JoinSide.Left => px < seam,
                    JoinSide.Below => py >= seam,
                    _ => py < seam,
                };
                var to = ((long)y * width + x) * channels;
                if (inSecond && (!inFirst || secondSide))
                {
                    if (at.Turned) (sx, sy) = (w2 - 1 - sx, h2 - 1 - sy);
                    Array.Copy(second, ((long)sy * w2 + sx) * channels, pixels, to, channels);
                }
                else Array.Copy(first, ((long)py * w1 + px) * channels, pixels, to, channels);
            }
        });
        return (pixels, width, height);
    }

    /// <summary>A grey copy <paramref name="factor"/> times smaller (each pixel the average of its square), from grey or BGR pixels.</summary>
    public static GrayImage Gray(byte[] pixels, int width, int height, int channels, int factor)
    {
        factor = Math.Max(1, factor);
        var (w, h) = (Math.Max(1, width / factor), Math.Max(1, height / factor));
        var result = new byte[w * h];
        Parallel.For(0, h, y =>
        {
            for (var x = 0; x < w; x++)
            {
                long sum = 0, n = 0;
                for (var yy = y * factor; yy < Math.Min(height, (y + 1) * factor); yy++)
                    for (var xx = x * factor; xx < Math.Min(width, (x + 1) * factor); xx++, n++)
                    {
                        var i = ((long)yy * width + xx) * channels;
                        sum += channels == 1 ? pixels[i] : (pixels[i] * 114 + pixels[i + 1] * 587 + pixels[i + 2] * 299) / 1000;
                    }
                result[y * w + x] = (byte)(n == 0 ? 255 : sum / n);
            }
        });
        return new GrayImage(w, h, result);
    }

    /// <summary>A copy <paramref name="factor"/> times smaller in each direction, grey or BGR (for the join's preview).</summary>
    public static (byte[] Pixels, int Width, int Height) Shrink(byte[] pixels, int width, int height, int channels, int factor)
    {
        factor = Math.Max(1, factor);
        var (w, h) = (Math.Max(1, width / factor), Math.Max(1, height / factor));
        var result = new byte[w * h * channels];
        Parallel.For(0, h, y =>
        {
            for (var x = 0; x < w; x++)
                for (var c = 0; c < channels; c++)
                {
                    long sum = 0, n = 0;
                    for (var yy = y * factor; yy < Math.Min(height, (y + 1) * factor); yy++)
                        for (var xx = x * factor; xx < Math.Min(width, (x + 1) * factor); xx++, n++)
                            sum += pixels[((long)yy * width + xx) * channels + c];
                    result[(y * w + x) * channels + c] = (byte)(n == 0 ? 255 : sum / n);
                }
        });
        return (result, w, h);
    }

    private static GrayImage Shrink(GrayImage img, int factor) => factor == 1 ? img : Gray(img.Pixels, img.Width, img.Height, 1, factor);

    private static GrayImage Turned(GrayImage img)
    {
        var px = (byte[])img.Pixels.Clone();
        Array.Reverse(px);
        return new GrayImage(img.Width, img.Height, px);
    }

    /// <summary>Every placement of <paramref name="b"/> on <paramref name="a"/>'s <paramref name="side"/> with its match score, on the coarse copies.</summary>
    private static List<(JoinSide, bool, int, int, double)> Search(GrayImage a, GrayImage b, JoinSide side, bool turned, double ppi, CancellationToken cancel)
    {
        var across = side is JoinSide.Right or JoinSide.Left;
        var span = across ? Math.Min(a.Width, b.Width) : Math.Min(a.Height, b.Height);
        var minOverlap = Math.Max(2, (int)Math.Ceiling(MinOverlap * ppi));
        var maxOverlap = (int)(span * MaxOverlapShare);
        var shift = (int)Math.Ceiling(MaxShift * ppi);
        var results = new List<(JoinSide, bool, int, int, double)>();
        if (maxOverlap < minOverlap) return results;
        var gate = new Lock();
        Parallel.For(minOverlap, maxOverlap + 1, new ParallelOptions { CancellationToken = cancel }, overlap =>
        {
            var found = new List<(JoinSide, bool, int, int, double)>();
            for (var s = -shift; s <= shift; s++)
            {
                var (x, y) = side switch
                {
                    JoinSide.Right => (a.Width - overlap, (a.Height - b.Height) / 2 + s),
                    JoinSide.Left => (overlap - b.Width, (a.Height - b.Height) / 2 + s),
                    JoinSide.Below => ((a.Width - b.Width) / 2 + s, a.Height - overlap),
                    _ => ((a.Width - b.Width) / 2 + s, overlap - b.Height),
                };
                var score = Ncc(a, b, x, y, minArea: 4 * minOverlap * minOverlap);
                if (score > double.NegativeInfinity) found.Add((side, turned, x, y, score));
            }
            lock (gate) results.AddRange(found);
        });
        return results;
    }

    /// <summary>
    /// How alike the two are where <paramref name="b"/>, its top-left at (<paramref name="x"/>, <paramref name="y"/>), lies over
    /// <paramref name="a"/>: −1 to 1; −∞ when the overlap is smaller than <paramref name="minArea"/> or either side of it is plain.
    /// </summary>
    private static double Ncc(GrayImage a, GrayImage b, int x, int y, int minArea)
    {
        var (x0, y0) = (Math.Max(0, x), Math.Max(0, y));
        var (x1, y1) = (Math.Min(a.Width, x + b.Width), Math.Min(a.Height, y + b.Height));
        if (x1 <= x0 || y1 <= y0 || (long)(x1 - x0) * (y1 - y0) < minArea) return double.NegativeInfinity;
        // A large overlap (the fine search) is read every other row: plenty to tell a match by, half the time.
        var rowStep = (long)(x1 - x0) * (y1 - y0) > 100_000 ? 2 : 1;
        long sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0, count = 0;
        for (var py = y0; py < y1; py += rowStep)
        {
            var rowA = a.Pixels.AsSpan(py * a.Width + x0, x1 - x0);
            var rowB = b.Pixels.AsSpan((py - y) * b.Width + x0 - x, x1 - x0);
            int ra = 0, rb = 0, raa = 0, rbb = 0, rab = 0; // a row's sums fit an int (255² × a row's width)
            for (var i = 0; i < rowA.Length; i++)
            {
                int va = rowA[i], vb = rowB[i];
                ra += va; rb += vb; raa += va * va; rbb += vb * vb; rab += va * vb;
            }
            (sa, sb, saa, sbb, sab) = (sa + ra, sb + rb, saa + raa, sbb + rbb, sab + rab);
            count += rowA.Length;
        }
        double n = count;
        var varA = saa - sa * (double)sa / n;
        var varB = sbb - sb * (double)sb / n;
        if (varA < MinSpread * MinSpread * n || varB < MinSpread * MinSpread * n) return double.NegativeInfinity; // plain paper: nothing to match
        return (sab - sa * (double)sb / n) / Math.Sqrt(varA * varB);
    }
}
