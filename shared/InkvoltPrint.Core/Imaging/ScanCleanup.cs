namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// A scanned page made ready for text recognition: straightened (<see cref="Skew"/> degrees undone), turned upright
/// (<see cref="QuarterTurns"/> quarters clockwise after straightening), noise smoothed, the paper evened out to white and
/// lone specks removed. <see cref="Gray"/> is what a recognizer reads; <see cref="Bgr"/> (when asked for) is the same page
/// in colour, to keep in the document. <see cref="UprightSure"/> is false when the page's lines didn't say which way up it
/// is (the caller may try the other way with its recognizer). <see cref="Perspective"/> and <see cref="Curve"/>: the page
/// photographed at an angle was straightened first, and its bent lines flattened (after straightening, or in its place for a
/// page tilted only by its bend; in the frame before the quarter turns), when those steps were asked for and found
/// something sure.
/// </summary>
public sealed record CleanedScan(GrayImage Gray, double Skew, int QuarterTurns, bool UprightSure, byte[]? Bgr, int SpecksRemoved)
{
    public Perspective? Perspective { get; init; }

    public LineCurve? Curve { get; init; }
}

/// <summary>
/// Cleans a scanned page before text recognition (Inkvolt PDF's Recognize Text, roadmap 2.2). Platform-neutral pixels in,
/// pixels out; each step is its own class so it can be tested and ported alone: <see cref="Trapezoid"/> (when asked),
/// <see cref="Deskew"/> (up to ±15° here), <see cref="PageRotate"/>, <see cref="Smooth"/>, <see cref="PaperLevel"/>,
/// <see cref="Despeckle"/>, <see cref="CurvedLines"/> (when asked), <see cref="Upright"/>.
/// </summary>
public static class ScanCleanup
{
    /// <summary>The largest skew straightened (a sheet laid on the glass by hand, a feeder that grabbed it crooked).</summary>
    public const double MaxSkew = 15;

    /// <summary>A page tilted by up to this (degrees) is first looked at for bent lines as it is (a book's page), before it is straightened.</summary>
    public const double MaxTiltOfBentLines = 3;

    /// <summary>
    /// <paramref name="pixels"/> (rows of <paramref name="width"/> × <paramref name="channels"/> bytes, 1 = grey, 3 = BGR) at
    /// <paramref name="dpi"/>. <paramref name="keepColor"/> also returns the cleaned page in colour (BGR input only).
    /// <paramref name="steps"/>: the further steps to try (a photographed page's trapezoid, bent lines); each changes the
    /// page only when it finds something sure.
    /// </summary>
    public static CleanedScan Clean(byte[] pixels, int width, int height, int channels, int dpi, bool keepColor = false, CancellationToken cancel = default,
        CleanupSteps steps = CleanupSteps.None)
    {
        var gray = channels == 1 ? pixels : ToGray(pixels, width, height);
        var color = keepColor && channels == 3 ? pixels : null;

        // A page photographed at an angle: warped to a rectangle first, so the rest sees a page lying flat.
        Perspective? perspective = null;
        if (steps.HasFlag(CleanupSteps.Trapezoid) && Trapezoid.Find(new GrayImage(width, height, gray), cancel) is { } found)
        {
            perspective = found;
            gray = found.Apply(gray, width, height, 1, cancel);
            if (color is not null) color = found.Apply(color, width, height, 3, cancel);
        }

        var factor = Math.Max(1, (int)Math.Round(dpi / 100.0));
        var (skew, sideways, axisSure) = Lines(Downscale(new GrayImage(width, height, gray), factor));
        cancel.ThrowIfCancellationRequested();

        // A book's bent lines look tilted on the whole: looked for on the page as it is (smoothed and whitened, so a desk,
        // a shadow or grey paper isn't ink), and when found, flattened without turning the page, so its margins stay
        // upright (turned, then flattened, the margins would lean by the tilt). Not found there, it isn't looked for again.
        LineCurve? curve = null;
        byte[]? smooth = null;
        PaperLevel.Map? paper = null;
        var bendLooked = false;
        if (steps.HasFlag(CleanupSteps.CurvedLines) && skew != 0 && Math.Abs(skew) <= MaxTiltOfBentLines)
        {
            bendLooked = true;
            var asIs = Smooth.Median3(gray, width, height, cancel);
            var level = PaperLevel.Estimate(asIs, width, height, dpi);
            PaperLevel.Whiten(asIs, level);
            if (CurvedLines.Find(new GrayImage(width, height, asIs), dpi, sideways, cancel) is { } tilted)
                (curve, skew, smooth, paper) = (tilted, 0, asIs, level);
        }

        if (skew != 0) gray = PageRotate.Rotate(gray, width, height, width, 1, -skew);
        if (smooth is null || paper is null)
        {
            smooth = Smooth.Median3(gray, width, height, cancel);
            paper = PaperLevel.Estimate(smooth, width, height, dpi);
            PaperLevel.Whiten(smooth, paper);
        }
        cancel.ThrowIfCancellationRequested();
        var specks = Despeckle.Remove(smooth, width, height, dpi);
        cancel.ThrowIfCancellationRequested();

        byte[]? bgr = null;
        if (color is not null)
        {
            bgr = skew != 0 ? PageRotate.Rotate(color, width, height, width * 3, 3, -skew) : (byte[])color.Clone();
            PaperLevel.WhitenColor(bgr, smooth, paper);
        }

        // Lines bent by a book's spine: flattened along the way they run, before telling which way up the page is.
        if (steps.HasFlag(CleanupSteps.CurvedLines) && curve is null && !bendLooked) curve = CurvedLines.Find(new GrayImage(width, height, smooth), dpi, sideways, cancel);
        if (curve is not null)
        {
            smooth = curve.Apply(smooth, width, height, 1, cancel);
            if (bgr is not null) bgr = curve.Apply(bgr, width, height, 3, cancel);
        }

        // Lines that run down the page are turned a quarter to run across; then which way up is told by the letters.
        var small = Downscale(new GrayImage(width, height, smooth), factor);
        if (sideways) small = new GrayImage(small.Height, small.Width, Turn(small.Pixels, small.Width, small.Height, 1, 1));
        var (flipped, waySure) = Upright.UpsideDown(small);
        var turns = (sideways ? 1 : 0) + (flipped ? 2 : 0);

        if (bgr is not null) bgr = Turn(bgr, width, height, 3, turns);
        var (w, h) = turns % 2 == 0 ? (width, height) : (height, width);
        return new CleanedScan(new GrayImage(w, h, Turn(smooth, width, height, 1, turns)), skew, turns, axisSure && waySure, bgr, specks)
        {
            Perspective = perspective,
            Curve = curve,
        };
    }

    /// <summary>
    /// How far a page's lines are turned (clockwise positive), up to ±<see cref="MaxSkew"/>, measured on a copy at about
    /// 100 dpi; 0 when straight or unclear. Lines that run down the page are measured on it turned a quarter.
    /// </summary>
    public static double SkewOf(GrayImage gray, int dpi) => Lines(Downscale(gray, Math.Max(1, (int)Math.Round(dpi / 100.0)))).Skew;

    /// <summary>
    /// The skew, whether the lines run down the page (it lies sideways), and whether that was clear. Lines are looked for
    /// across the page and down it (on the page turned a quarter): the way they line up more sharply is theirs. The
    /// search goes a degree past <see cref="MaxSkew"/> so a page at the limit isn't at the edge of it. Turning about the
    /// centre and straightening about the centre commute, so the skew found on the turned copy straightens the page itself.
    /// </summary>
    private static (double Skew, bool Sideways, bool Sure) Lines(GrayImage small)
    {
        var across = Deskew.Measure(small, MaxSkew + 1);
        var down = Deskew.Measure(new GrayImage(small.Height, small.Width, Turn(small.Pixels, small.Width, small.Height, 1, 1)), MaxSkew + 1);
        var sideways = down.Strength > across.Strength * 1.15;
        var sure = sideways || across.Strength > down.Strength * 1.15;
        var skew = sideways ? down.Angle : across.Angle;
        return (Math.Abs(skew) > MaxSkew + 0.25 ? 0 : skew, sideways, sure);
    }

    /// <summary>Luma of BGR pixels (the weights Rec. 601 uses, in integers).</summary>
    public static byte[] ToGray(byte[] bgr, int width, int height)
    {
        var g = new byte[width * height];
        Parallel.For(0, height, y =>
        {
            for (int x = 0, i = y * width, j = y * width * 3; x < width; x++, i++, j += 3)
                g[i] = (byte)((bgr[j] * 29 + bgr[j + 1] * 150 + bgr[j + 2] * 77) >> 8);
        });
        return g;
    }

    /// <summary>Averages <paramref name="factor"/> × <paramref name="factor"/> blocks (a smaller copy for measuring).</summary>
    public static GrayImage Downscale(GrayImage img, int factor)
    {
        if (factor <= 1) return img;
        var (w, h) = (img.Width / factor, img.Height / factor);
        var px = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var sum = 0;
                for (var dy = 0; dy < factor; dy++)
                    for (var dx = 0; dx < factor; dx++)
                        sum += img.Pixels[(y * factor + dy) * img.Width + x * factor + dx];
                px[y * w + x] = (byte)(sum / (factor * factor));
            }
        return new GrayImage(w, h, px);
    }

    /// <summary>
    /// <paramref name="pixels"/> turned <paramref name="quarters"/> quarter turns clockwise: a pixel at (x, y) of a
    /// W × H image goes to (H − 1 − y, x) for one turn. The same array when there's nothing to turn.
    /// </summary>
    public static byte[] Turn(byte[] pixels, int width, int height, int channels, int quarters)
    {
        quarters = ((quarters % 4) + 4) % 4;
        if (quarters == 0) return pixels;
        var result = new byte[pixels.Length];
        var (w2, _) = quarters % 2 == 0 ? (width, height) : (height, width);
        Parallel.For(0, height, y =>
        {
            for (var x = 0; x < width; x++)
            {
                var (tx, ty) = quarters switch
                {
                    1 => (height - 1 - y, x),
                    2 => (width - 1 - x, height - 1 - y),
                    _ => (y, width - 1 - x),
                };
                Buffer.BlockCopy(pixels, (y * width + x) * channels, result, (ty * w2 + tx) * channels, channels);
            }
        });
        return result;
    }
}

/// <summary>A 3 × 3 median: takes out the paper's grain and single-pixel noise, keeps the edges of letters.</summary>
public static class Smooth
{
    public static byte[] Median3(byte[] gray, int width, int height, CancellationToken cancel = default)
    {
        var result = new byte[gray.Length];
        Parallel.For(0, height, new ParallelOptions { CancellationToken = cancel }, y =>
        {
            Span<byte> v = stackalloc byte[9];
            for (var x = 0; x < width; x++)
            {
                var n = 0;
                for (var dy = -1; dy <= 1; dy++)
                {
                    var yy = Math.Clamp(y + dy, 0, height - 1);
                    for (var dx = -1; dx <= 1; dx++)
                        v[n++] = gray[yy * width + Math.Clamp(x + dx, 0, width - 1)];
                }
                result[y * width + x] = Median9(v);
            }
        });
        return result;
    }

    /// <summary>The median of nine values by a sorting network (19 compare-exchanges).</summary>
    private static byte Median9(Span<byte> p)
    {
        void S(Span<byte> a, int i, int j)
        {
            if (a[i] > a[j]) (a[i], a[j]) = (a[j], a[i]);
        }
        S(p, 1, 2); S(p, 4, 5); S(p, 7, 8); S(p, 0, 1); S(p, 3, 4); S(p, 6, 7); S(p, 1, 2); S(p, 4, 5); S(p, 7, 8);
        S(p, 0, 3); S(p, 5, 8); S(p, 4, 7); S(p, 3, 6); S(p, 1, 4); S(p, 2, 5); S(p, 4, 7); S(p, 4, 2); S(p, 6, 4); S(p, 4, 2);
        return p[4];
    }
}

/// <summary>
/// The paper's own level across the page (grey recycled paper, a lid's shadow, yellowed edges), so it can be evened out:
/// each pixel is divided by the paper behind it, and what is then nearly white becomes white. The paper is the bright
/// end (90th percentile) of each block about a sixth of an inch square; a dark block (a photo, a black bar) takes its
/// neighbours' paper instead, so it stays dark.
/// </summary>
public static class PaperLevel
{
    /// <summary>After evening out, levels at or above this share of white become white.</summary>
    public const double White = 0.92;

    public sealed record Map(int Width, int Height, int Block, int Columns, int Rows, float[] Levels)
    {
        /// <summary>The paper level at a pixel, bilinear between block centres.</summary>
        public float At(int x, int y)
        {
            var fx = Math.Clamp((x + 0.5f) / Block - 0.5f, 0, Columns - 1);
            var fy = Math.Clamp((y + 0.5f) / Block - 0.5f, 0, Rows - 1);
            var (x0, y0) = ((int)fx, (int)fy);
            var (x1, y1) = (Math.Min(x0 + 1, Columns - 1), Math.Min(y0 + 1, Rows - 1));
            var (ax, ay) = (fx - x0, fy - y0);
            var top = Levels[y0 * Columns + x0] * (1 - ax) + Levels[y0 * Columns + x1] * ax;
            var bottom = Levels[y1 * Columns + x0] * (1 - ax) + Levels[y1 * Columns + x1] * ax;
            return top * (1 - ay) + bottom * ay;
        }
    }

    public static Map Estimate(byte[] gray, int width, int height, int dpi)
    {
        var block = Math.Max(8, dpi / 6);
        var (cols, rows) = ((width + block - 1) / block, (height + block - 1) / block);
        var levels = new float[cols * rows];
        Parallel.For(0, rows, by =>
        {
            Span<int> histogram = stackalloc int[256];
            for (var bx = 0; bx < cols; bx++)
            {
                histogram.Clear();
                var (x0, y0) = (bx * block, by * block);
                var (x1, y1) = (Math.Min(width, x0 + block), Math.Min(height, y0 + block));
                for (var y = y0; y < y1; y++)
                    for (var x = x0; x < x1; x++)
                        histogram[gray[y * width + x]]++;
                var target = (x1 - x0) * (y1 - y0) * 9 / 10;
                var level = 255;
                for (int v = 0, seen = 0; v < 256; v++)
                    if ((seen += histogram[v]) > target)
                    {
                        level = v;
                        break;
                    }
                levels[by * cols + bx] = level;
            }
        });

        // A block much darker than the brightest of its neighbours is content, not paper: it takes theirs.
        var grown = new float[levels.Length];
        for (var by = 0; by < rows; by++)
            for (var bx = 0; bx < cols; bx++)
            {
                float max = 0;
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++)
                    {
                        var (nx, ny) = (bx + dx, by + dy);
                        if (nx >= 0 && ny >= 0 && nx < cols && ny < rows) max = Math.Max(max, levels[ny * cols + nx]);
                    }
                var own = levels[by * cols + bx];
                grown[by * cols + bx] = own < max * 0.8f ? max : own;
            }
        // Never below mid-grey: a page that dark is a photo or a dark form, not paper to even out.
        for (var i = 0; i < grown.Length; i++) grown[i] = Math.Max(128, grown[i]);
        return new Map(width, height, block, cols, rows, grown);
    }

    /// <summary>Divides each pixel by the paper behind it and turns the nearly white to white (in place).</summary>
    public static void Whiten(byte[] gray, Map paper, double white = White)
    {
        var (width, height) = (paper.Width, paper.Height);
        Parallel.For(0, height, y =>
        {
            for (var x = 0; x < width; x++)
            {
                var i = y * width + x;
                var even = gray[i] * 255f / paper.At(x, y);
                gray[i] = even >= 255 * white ? (byte)255 : (byte)Math.Clamp(even / white, 0, 255);
            }
        });
    }

    /// <summary>The colour page evened out the same way; white wherever the cleaned grey page is white.</summary>
    public static void WhitenColor(byte[] bgr, byte[] cleanedGray, Map paper)
    {
        var (width, height) = (paper.Width, paper.Height);
        Parallel.For(0, height, y =>
        {
            for (var x = 0; x < width; x++)
            {
                var i = y * width + x;
                if (cleanedGray[i] == 255)
                {
                    bgr[i * 3] = bgr[i * 3 + 1] = bgr[i * 3 + 2] = 255;
                    continue;
                }
                var scale = 255f / paper.At(x, y) / (float)White;
                for (var c = 0; c < 3; c++) bgr[i * 3 + c] = (byte)Math.Clamp(bgr[i * 3 + c] * scale, 0, 255);
            }
        });
    }
}

/// <summary>
/// Removes specks: small dark spots (dust, toner, a hole's shadow) with no other ink near them. Small means at most
/// <see cref="MaxArea"/> pixels at 300 dpi (a 9 × 9 dot, scaled with the resolution); near means within
/// <see cref="Isolation"/> of an inch. A full stop, a comma, the dot of an i or an accent is always near its letters,
/// so it stays.
/// </summary>
public static class Despeckle
{
    public const int MaxArea = 80;
    public const double Isolation = 1 / 20.0;
    private const byte Ink = 160;

    /// <summary>Turns lone specks white (in place); returns how many went.</summary>
    public static int Remove(byte[] gray, int width, int height, int dpi, CancellationToken cancel = default)
    {
        var maxArea = Math.Max(2, (int)(MaxArea * (dpi / 300.0) * (dpi / 300.0)));
        var reach = Math.Max(2, (int)Math.Round(dpi * Isolation));

        // Ink counts summed over the rectangle above and left of each pixel, to count the ink around a speck at once.
        var sums = new int[(width + 1) * (height + 1)];
        for (var y = 0; y < height; y++)
        {
            cancel.ThrowIfCancellationRequested();
            var row = 0;
            for (var x = 0; x < width; x++)
            {
                row += gray[y * width + x] < Ink ? 1 : 0;
                sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row;
            }
        }
        int InkIn(int x0, int y0, int x1, int y1)
        {
            (x0, y0, x1, y1) = (Math.Max(0, x0), Math.Max(0, y0), Math.Min(width, x1), Math.Min(height, y1));
            return sums[y1 * (width + 1) + x1] - sums[y0 * (width + 1) + x1] - sums[y1 * (width + 1) + x0] + sums[y0 * (width + 1) + x0];
        }

        var seen = new bool[gray.Length];
        var stack = new Stack<int>();
        var pixels = new List<int>();
        var removed = 0;
        for (var start = 0; start < gray.Length; start++)
        {
            if (start % width == 0) cancel.ThrowIfCancellationRequested();
            if (seen[start] || gray[start] >= Ink) continue;
            // One spot of ink (8-connected), given up on as soon as it is too big to be a speck.
            pixels.Clear();
            stack.Push(start);
            seen[start] = true;
            int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
            var big = false;
            while (stack.Count > 0)
            {
                var p = stack.Pop();
                var (px, py) = (p % width, p / width);
                if (!big)
                {
                    pixels.Add(p);
                    (minX, minY, maxX, maxY) = (Math.Min(minX, px), Math.Min(minY, py), Math.Max(maxX, px), Math.Max(maxY, py));
                    big = pixels.Count > maxArea;
                }
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++)
                    {
                        var (nx, ny) = (px + dx, py + dy);
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                        var n = ny * width + nx;
                        if (seen[n] || gray[n] >= Ink) continue;
                        seen[n] = true;
                        stack.Push(n);
                    }
            }
            if (big) continue;
            var own = InkIn(minX, minY, maxX + 1, maxY + 1);
            if (InkIn(minX - reach, minY - reach, maxX + 1 + reach, maxY + 1 + reach) > own) continue;
            foreach (var p in pixels) gray[p] = 255;
            // Its soft edge (lighter than ink) goes too.
            for (var y = Math.Max(0, minY - 1); y <= Math.Min(height - 1, maxY + 1); y++)
                for (var x = Math.Max(0, minX - 1); x <= Math.Min(width - 1, maxX + 1); x++)
                    gray[y * width + x] = 255;
            removed++;
        }
        return removed;
    }
}

/// <summary>
/// Whether a straightened page of horizontal text lines is upside down. In Latin script far more ink rises above the
/// middle of a line (capitals, b d f h k l t, accents, the dots of i and j) than hangs below it (g j p q y), so the side
/// of each line's middle band with more ink is the top. Which way the lines run is <see cref="Deskew.Measure"/>'s to say.
/// </summary>
public static class Upright
{
    private const int InkContrast = 60;

    /// <summary>Clear when one side has at least this much more ink than the other.</summary>
    public const double ClearRatio = 1.4;

    /// <summary>A run of inked rows taller than this many times the page's lines is left out (a picture, a shaded box; a heading twice the body's size stays).</summary>
    public const double MaxLineRatio = 3;

    /// <summary>Whether the page is upside down, and whether its lines said so clearly (not for a page with almost no text).</summary>
    public static (bool UpsideDown, bool Sure) UpsideDown(GrayImage horizontal)
    {
        var (above, below) = AboveBelow(horizontal);
        var ratio = (above + 1) / (below + 1);
        return (ratio < 1, above + below > 100 && (ratio >= ClearRatio || ratio <= 1 / ClearRatio));
    }

    /// <summary>Fewer rows than this aren't a line of text: a rule, an underline, a speck (about 100 dpi: 4 pt).</summary>
    public const int MinLineRows = 6;

    /// <summary>
    /// Ink above and below the middle band of each text line, summed over the page. A line is a run of rows with ink, its
    /// middle band the rows at least half as inked as its fullest. A run of lines set tight (no white between) is cut at the
    /// troughs between their bands; a run shorter than <see cref="MinLineRows"/> isn't a line, nor one more than
    /// <see cref="MaxLineRatio"/> times as tall as the page's lines (a picture, a shaded box), which are then left out and
    /// the lines read again without them (a wide picture's rows mustn't set how faint a narrow line's ink may be).
    /// </summary>
    public static (double Above, double Below) AboveBelow(GrayImage img)
    {
        var paper = GrayImage.Median(img, 0, 0, img.Width, img.Height);
        if (paper < 128) return (0, 0);
        var ink = paper - InkContrast;
        var profile = new int[img.Height];
        for (var y = 0; y < img.Height; y++)
            for (var x = 0; x < img.Width; x++)
                if (img.Pixels[y * img.Width + x] < ink) profile[y]++;

        var (lines, tall) = Lines(profile);
        if (tall.Count > 0)
        {
            // Without the pictures' rows: what is faint beside them is ink again.
            foreach (var (start, end) in tall)
                Array.Clear(profile, start, end - start);
            (lines, _) = Lines(profile);
        }
        double above = 0, below = 0;
        foreach (var (start, end) in lines)
        {
            var peak = Peak(profile, start, end);
            var bandTop = start;
            while (profile[bandTop] < peak * 0.5) bandTop++;
            var bandBottom = end - 1;
            while (profile[bandBottom] < peak * 0.5) bandBottom--;
            for (var j = start; j < bandTop; j++) above += profile[j];
            for (var j = bandBottom + 1; j < end; j++) below += profile[j];
        }
        return (above, below);
    }

    /// <summary>
    /// The profile's lines of text, and its runs far taller than them (pictures). A run is rows at least 3% as inked as the
    /// fullest; one holding several bands (rows at least half its fullest) is cut where they meet, a line each. The
    /// lines' height is the lower middle of the pieces' heights: on a page of a picture and its caption, the caption's.
    /// </summary>
    private static (List<(int Start, int End)> Lines, List<(int Start, int End)> Tall) Lines(int[] profile)
    {
        var max = profile.Length == 0 ? 0 : profile.Max();
        var floor = Math.Max(1, max * 0.03);
        var pieces = new List<(int Start, int End)>();
        for (var i = 0; i < profile.Length;)
        {
            if (profile[i] < floor)
            {
                i++;
                continue;
            }
            var start = i;
            while (i < profile.Length && profile[i] >= floor) i++;
            if (i - start < MinLineRows) continue; // a rule, an underline, a speck
            pieces.AddRange(Split(profile, start, i));
        }
        var lines = new List<(int, int)>();
        var tall = new List<(int, int)>();
        var heights = pieces.Select(p => p.End - p.Start).Where(h => h >= MinLineRows).Order().ToList();
        if (heights.Count == 0) return (lines, tall);
        var limit = MaxLineRatio * heights[(heights.Count - 1) / 2];
        foreach (var p in pieces)
        {
            if (p.End - p.Start < MinLineRows) continue;
            (p.End - p.Start > limit ? tall : lines).Add(p);
        }
        return (lines, tall);
    }

    /// <summary>A run cut between its bands (rows at least half its fullest) at the faintest row, one piece a band.</summary>
    private static IEnumerable<(int Start, int End)> Split(int[] profile, int start, int end)
    {
        var half = Peak(profile, start, end) * 0.5;
        var bands = new List<(int Start, int End)>();
        for (var j = start; j < end;)
        {
            if (profile[j] < half)
            {
                j++;
                continue;
            }
            var b = j;
            while (j < end && profile[j] >= half) j++;
            bands.Add((b, j));
        }
        var from = start;
        for (var k = 0; k + 1 < bands.Count; k++)
        {
            // Where the lines meet: after the faintest row between their bands (the last, if several are as faint).
            var cut = bands[k].End;
            for (var j = bands[k].End; j < bands[k + 1].Start; j++)
                if (profile[j] <= profile[cut]) cut = j;
            yield return (from, cut + 1);
            from = cut + 1;
        }
        yield return (from, end);
    }

    private static int Peak(int[] profile, int start, int end)
    {
        var peak = 0;
        for (var j = start; j < end; j++) peak = Math.Max(peak, profile[j]);
        return peak;
    }
}
