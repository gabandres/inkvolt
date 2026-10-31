namespace InkvoltPrint.Core.Imaging;

/// <summary>An 8-bit greyscale image, row by row with no padding (0 black, 255 white). The app decodes a downscaled copy of a scan into one.</summary>
public sealed record GrayImage(int Width, int Height, byte[] Pixels)
{
    public byte this[int x, int y] => Pixels[y * Width + x];

    /// <summary>The level most of the page has (the median): the paper on a document.</summary>
    internal static int Median(GrayImage img, int x0, int y0, int x1, int y1)
    {
        var histogram = new int[256];
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
                histogram[img.Pixels[y * img.Width + x]]++;
        var half = (x1 - x0) * (y1 - y0) / 2;
        for (int level = 0, seen = 0; level < 256; level++)
            if ((seen += histogram[level]) > half) return level;
        return 255;
    }
}

/// <summary>
/// Blank page detection for scans (the back of a one-sided sheet in the feeder, a separator sheet): a page is blank when
/// almost none of it is ink. Measured inside a margin (scanner edges, lid shadows and punched holes live there), against
/// the page's own paper level, and only ink pixels with an ink neighbour count, so specks of dust and JPEG noise don't.
/// Conservative on purpose: a page with as little as a short word on it is not blank.
/// </summary>
public static class BlankPage
{
    /// <summary>Fraction of the width and height left out on each side.</summary>
    public const double Margin = 0.06;

    /// <summary>How much darker than the paper a pixel must be to be ink (show-through from the back is lighter than this).</summary>
    public const int InkContrast = 48;

    /// <summary>Most ink a blank page may have: 0.02% of the area, a few specks; one short word is more.</summary>
    public const double MaxCoverage = 0.0002;

    /// <summary>The share of the page (inside the margin) that is ink, 0 to 1. A dark page (paper below mid-grey) counts as all ink.</summary>
    public static double InkCoverage(GrayImage img)
    {
        var (x0, y0) = ((int)(img.Width * Margin), (int)(img.Height * Margin));
        var (x1, y1) = (img.Width - x0, img.Height - y0);
        if (x1 - x0 < 3 || y1 - y0 < 3) return 1;
        var paper = GrayImage.Median(img, x0, y0, x1, y1);
        if (paper < 128) return 1; // a photo or a dark page: never "blank"
        var ink = paper - InkContrast;
        var count = 0;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
                if (img[x, y] < ink && HasInkNeighbour(img, x, y, ink)) count++;
        return count / (double)((x1 - x0) * (y1 - y0));
    }

    public static bool IsBlank(GrayImage img) => InkCoverage(img) <= MaxCoverage;

    private static bool HasInkNeighbour(GrayImage img, int x, int y, int ink)
    {
        for (var dy = -1; dy <= 1; dy++)
            for (var dx = -1; dx <= 1; dx++)
            {
                if (dx == 0 && dy == 0) continue;
                var (nx, ny) = (x + dx, y + dy);
                if (nx >= 0 && ny >= 0 && nx < img.Width && ny < img.Height && img[nx, ny] < ink) return true;
            }
        return false;
    }
}

/// <summary>
/// Skew detection for scanned documents (a page fed or laid a little crooked), by projection profile: the ink is projected
/// onto lines at each candidate angle, and text lines line up into sharp peaks only at the page's true angle. Small angles
/// only (±<see cref="MaxAngle"/>° by default; Inkvolt PDF's text recognition looks up to ±15°); pages with no clear
/// answer (photos, a few words, already straight) get 0, so they keep their original JPEG.
/// </summary>
public static class Deskew
{
    public const double MaxAngle = 10;

    /// <summary>Smaller skews aren't worth re-encoding the page for.</summary>
    public const double MinAngle = 0.4;

    private const int InkContrast = 60;
    private const int MinInkPixels = 200;
    private const int MaxInkPixels = 40_000;

    /// <summary>
    /// How far the page's content is turned, in degrees, clockwise positive as seen on screen; rotating it by the negative
    /// straightens it. 0 when the page is straight enough or the answer isn't clear. <paramref name="maxAngle"/> is the
    /// largest skew looked for (default <see cref="MaxAngle"/>).
    /// </summary>
    public static double Angle(GrayImage img, double maxAngle = MaxAngle) => Measure(img, maxAngle).Angle;

    /// <summary>
    /// <see cref="Angle"/>, and how sharply the ink lines up into lines at it: the best angle's profile score over the
    /// average angle's (1 for no lines at all; 1.25 or more is a page of lines). Comparing it with the same page turned a
    /// quarter tells whether its lines run across or down.
    /// </summary>
    public static (double Angle, double Strength) Measure(GrayImage img, double maxAngle = MaxAngle)
    {
        var (x0, y0) = ((int)(img.Width * 0.03), (int)(img.Height * 0.03));
        var (x1, y1) = (img.Width - x0, img.Height - y0);
        if (x1 - x0 < 16 || y1 - y0 < 16) return (0, 1);
        var paper = GrayImage.Median(img, x0, y0, x1, y1);
        if (paper < 128) return (0, 1);
        var ink = paper - InkContrast;

        // Ink pixels, relative to the centre; evenly thinned out on busy pages.
        var total = 0;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
                if (img[x, y] < ink) total++;
        if (total < MinInkPixels) return (0, 1);
        var step = Math.Max(1, total / MaxInkPixels);
        var (cx, cy) = (img.Width / 2.0, img.Height / 2.0);
        var xs = new List<float>(total / step + 1);
        var ys = new List<float>(total / step + 1);
        for (int y = y0, i = 0; y < y1; y++)
            for (var x = x0; x < x1; x++)
                if (img[x, y] < ink && i++ % step == 0)
                {
                    xs.Add((float)(x - cx));
                    ys.Add((float)(y - cy));
                }
        var bins = new int[(int)Math.Ceiling(Math.Sqrt(img.Width * (double)img.Width + img.Height * (double)img.Height)) + 2];

        double Score(double degrees)
        {
            Array.Clear(bins);
            var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
            var offset = bins.Length / 2;
            for (var i = 0; i < xs.Count; i++)
            {
                var bin = (int)Math.Round(ys[i] * cos - xs[i] * sin) + offset;
                if ((uint)bin < (uint)bins.Length) bins[bin]++;
            }
            double sum = 0;
            foreach (var c in bins) sum += (double)c * c;
            return sum;
        }

        // Coarse, then fine around the best.
        const double coarse = 0.5, fine = 0.05;
        var steps = (int)(maxAngle / coarse);
        var scores = new double[2 * steps + 1];
        var best = 0;
        for (var i = 0; i < scores.Length; i++)
        {
            scores[i] = Score((i - steps) * coarse);
            if (scores[i] > scores[best]) best = i;
        }
        var mean = scores.Average();
        var strength = mean > 0 ? scores[best] / mean : 1;
        if (best == 0 || best == scores.Length - 1) return (0, strength); // at the edge of the range: not a small skew
        if (strength < 1.25) return (0, strength); // a flat profile: no lines to go by

        var angle = (best - steps) * coarse;
        var bestScore = scores[best];
        for (var a = angle - coarse + fine; a < angle + coarse - fine / 2; a += fine)
        {
            var s = Score(a);
            if (s > bestScore) (bestScore, angle) = (s, a);
        }
        angle = Math.Round(angle / fine) * fine;
        return (Math.Abs(angle) < MinAngle ? 0 : angle, mean > 0 ? bestScore / mean : strength);
    }
}

/// <summary>A crop as fractions of the image (0 to 1): left, top, width, height.</summary>
public readonly record struct CropBox(double X, double Y, double Width, double Height)
{
    public static readonly CropBox Full = new(0, 0, 1, 1);

    /// <summary>The same area after the image turns <paramref name="quarterTurns"/> quarters clockwise (negative: anticlockwise).</summary>
    public CropBox Turn(int quarterTurns)
    {
        var box = this;
        for (var i = 0; i < ((quarterTurns % 4) + 4) % 4; i++)
            box = new CropBox(1 - box.Y - box.Height, box.X, box.Height, box.Width); // (x, y) → (1 − y, x)
        return box;
    }

    /// <summary>Kept inside the image, at least <paramref name="min"/> wide and tall.</summary>
    public CropBox Clamp(double min = 0.02)
    {
        var w = Math.Clamp(Width, min, 1);
        var h = Math.Clamp(Height, min, 1);
        return new CropBox(Math.Clamp(X, 0, 1 - w), Math.Clamp(Y, 0, 1 - h), w, h);
    }

    public bool IsFull => X <= 0.001 && Y <= 0.001 && Width >= 0.999 && Height >= 0.999;
}

/// <summary>
/// What's been done to a scanned page, applied in this order when the page is saved: straightened by
/// <see cref="Deskew"/> degrees (anticlockwise by that much), cropped to <see cref="Crop"/> (in the straightened page),
/// cleaned up by <see cref="Filters"/> (<see cref="PageCleanup"/>), then turned <see cref="QuarterTurns"/> quarters clockwise.
/// No edits: the scanner's own JPEG is saved untouched. <see cref="PageFilters.CropToPaper"/> only says where
/// <see cref="Crop"/> came from, so on its own (no paper's edge was found) it changes nothing.
/// </summary>
public sealed record PageEdits(int QuarterTurns = 0, double Deskew = 0, CropBox? Crop = null, PageFilters Filters = PageFilters.None)
{
    public static readonly PageEdits None = new();

    public bool IsEmpty => QuarterTurns % 4 == 0 && Deskew == 0 && (Crop is null || Crop.Value.IsFull) && (Filters & PageFilters.PixelFilters) == 0;

    public PageEdits Turned(int quarters) => this with { QuarterTurns = (((QuarterTurns + quarters) % 4) + 4) % 4 };

    /// <summary>The crop as seen on the turned page (what the crop view shows).</summary>
    public CropBox ShownCrop => (Crop ?? CropBox.Full).Turn(QuarterTurns);

    /// <summary>Sets the crop from a box drawn on the turned page.</summary>
    public PageEdits WithShownCrop(CropBox? shown) =>
        this with { Crop = shown is { } box && !box.IsFull ? box.Clamp().Turn(-QuarterTurns) : null, Filters = Filters & ~PageFilters.CropToPaper };
}

/// <summary>Arbitrary-angle rotation of raw pixels (straightening a page), bilinear, same size, uncovered corners white.</summary>
public static class PageRotate
{
    /// <summary>
    /// <paramref name="pixels"/> turned <paramref name="degrees"/> clockwise (as seen on screen) about the centre.
    /// <paramref name="channels"/>: 1 for grey, 3 for BGR; rows are <paramref name="stride"/> bytes apart. Uncovered corners
    /// get <paramref name="fill"/>.
    /// </summary>
    public static byte[] Rotate(byte[] pixels, int width, int height, int stride, int channels, double degrees, byte fill = 255)
    {
        var result = new byte[pixels.Length];
        Array.Fill(result, fill);
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        var (cx, cy) = ((width - 1) / 2.0, (height - 1) / 2.0);
        Parallel.For(0, height, y =>
        {
            var dy = y - cy;
            for (var x = 0; x < width; x++)
            {
                // Where this output pixel comes from in the original.
                var dx = x - cx;
                var sx = cos * dx + sin * dy + cx;
                var sy = -sin * dx + cos * dy + cy;
                if (sx <= -1 || sy <= -1 || sx >= width || sy >= height) continue;
                var (x0, y0) = ((int)Math.Floor(sx), (int)Math.Floor(sy));
                var (fx, fy) = (sx - x0, sy - y0);
                for (var c = 0; c < channels; c++)
                {
                    double At(int px, int py) => px < 0 || py < 0 || px >= width || py >= height ? fill : pixels[py * stride + px * channels + c];
                    var top = At(x0, y0) * (1 - fx) + At(x0 + 1, y0) * fx;
                    var bottom = At(x0, y0 + 1) * (1 - fx) + At(x0 + 1, y0 + 1) * fx;
                    result[y * stride + x * channels + c] = (byte)Math.Clamp(Math.Round(top * (1 - fy) + bottom * fy), 0, 255);
                }
            }
        });
        return result;
    }
}
