namespace InkvoltPrint.Core.Imaging;

/// <summary>What a scanned page is cleaned up with, per scan and per preset (Inkvolt Print's review, roadmap 2.3).</summary>
[Flags]
public enum PageFilters
{
    None = 0,

    /// <summary>The crop was (or is to be) found at the paper's edge (<see cref="PaperEdge"/>).</summary>
    CropToPaper = 1,

    /// <summary>Whiten the background, remove specks (<see cref="PageBackground"/>).</summary>
    Whiten = 2,

    /// <summary>Take the screen out of printed pictures (<see cref="Descreen"/>).</summary>
    Descreen = 4,

    /// <summary>Restore a faded print's range and colors (<see cref="FadedColors"/>).</summary>
    RestoreColors = 8,

    /// <summary>The filters that change pixels.</summary>
    PixelFilters = Whiten | Descreen | RestoreColors,

    All = CropToPaper | PixelFilters,
}

/// <summary>What <see cref="PageCleanup.Apply"/> gives: the page, what really changed it, and the specks removed.</summary>
public sealed record CleanedPage(byte[] Pixels, PageFilters Done, int Specks);

/// <summary>
/// The review's filters on a page's pixels: descreen, then restore colors, then whiten, each on what the one before left.
/// Pixels in, new pixels out: the input (the scan) is never written to. Rows of width × channels bytes, no padding; 1 = grey, 3 = BGR.
/// </summary>
public static class PageCleanup
{
    /// <summary>
    /// Past this a page is left as it is, with nothing done (a 1200 dpi A3 page is 278 million pixels). The filters take about
    /// five times the page's own memory at their peak.
    /// </summary>
    public const long MaxPixels = 300_000_000;

    public static bool TooLarge(int width, int height) => (long)width * height > MaxPixels;

    public static CleanedPage Apply(byte[] pixels, int width, int height, int channels, int dpi, PageFilters filters, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        if ((filters & PageFilters.PixelFilters) == 0 || TooLarge(width, height) || width < 1 || height < 1) return new CleanedPage(pixels, PageFilters.None, 0);
        var page = (byte[])pixels.Clone();
        var done = PageFilters.None;
        var specks = 0;
        if (filters.HasFlag(PageFilters.Descreen) && Descreen.Apply(page, width, height, channels, dpi, cancel)) done |= PageFilters.Descreen;
        if (filters.HasFlag(PageFilters.RestoreColors) && FadedColors.Restore(page, width, height, channels, cancel)) done |= PageFilters.RestoreColors;
        if (filters.HasFlag(PageFilters.Whiten) && PageBackground.Whiten(page, width, height, channels, dpi, out specks, cancel)) done |= PageFilters.Whiten;
        return new CleanedPage(page, done, specks);
    }

    /// <summary>"cropped to the paper, whitened": what a set of filters does, in the review's words. Empty for none.</summary>
    public static string Describe(PageFilters filters)
    {
        var parts = new List<string>();
        if (filters.HasFlag(PageFilters.CropToPaper)) parts.Add("cropped to the paper");
        if (filters.HasFlag(PageFilters.Whiten)) parts.Add("whitened");
        if (filters.HasFlag(PageFilters.Descreen)) parts.Add("descreened");
        if (filters.HasFlag(PageFilters.RestoreColors)) parts.Add("colors restored");
        return string.Join(", ", parts);
    }
}

/// <summary>
/// Finds the sheet on a scan of the glass, by the lid's level as <see cref="PhotoFinder"/> does: what differs from the lid is
/// the sheet. The lid is looked for along the scan's four edges (a sheet in a corner of the glass touches two of them), each
/// level tried in turn. A crop only ever removes lid: it is refused unless what differs from the level is one solid rectangle
/// and nothing else lies outside it but specks, faint marks included. So a page printed to its edges, a white sheet under a
/// white lid (no edge to see), a dark lid or a page with a picture and a caption is kept whole.
/// </summary>
public static class PaperEdge
{
    private const int Contrast = 16;
    private const double MinSide = 1, MinShare = 0.25, MinFill = 0.92, Pad = 0.03, NothingToCrop = 0.99;

    /// <summary>Marks this close (inches) belong together; dust is under <see cref="DustSide"/> inches on its shorter side.</summary>
    private const double Together = 0.1, DustSide = 0.09;

    /// <summary>
    /// The sheet as a crop of the straightened page (<paramref name="deskew"/> degrees undone), or null when there is no edge to
    /// be sure of. <paramref name="img"/> is the scan as scanned, at <paramref name="ppi"/> pixels an inch (the analysis copy).
    /// </summary>
    public static CropBox? Find(GrayImage img, double ppi, double deskew = 0)
    {
        if (img.Width < 32 || img.Height < 32 || ppi < 20) return null;
        foreach (var lid in LidLevels(img, ppi))
        {
            var pixels = deskew == 0 ? img.Pixels : PageRotate.Rotate(img.Pixels, img.Width, img.Height, img.Width, 1, -deskew, (byte)lid);
            if (Sheet(pixels, img.Width, img.Height, lid, ppi) is { } box) return box;
        }
        return null;
    }

    /// <summary>The light level each edge of the scan mostly has, when it mostly has one.</summary>
    private static List<int> LidLevels(GrayImage img, double ppi)
    {
        var strip = Math.Max(2, (int)Math.Round(ppi * 0.05));
        var (w, h) = (img.Width, img.Height);
        var levels = new List<int>();
        foreach (var (x0, y0, x1, y1) in new[] { (0, 0, w, strip), (0, h - strip, w, h), (0, 0, strip, h), (w - strip, 0, w, h) })
        {
            var level = GrayImage.Median(img, x0, y0, x1, y1);
            if (level < 128) continue; // a dark lid or a dark page: nothing here tells them apart
            int near = 0, all = 0;
            for (var y = y0; y < y1; y++)
                for (var x = x0; x < x1; x++, all++)
                    if (Math.Abs(img[x, y] - level) <= Contrast) near++;
            if (near * 10 >= all * 6 && !levels.Any(l => Math.Abs(l - level) <= Contrast / 2)) levels.Add(level);
        }
        return levels;
    }

    private static CropBox? Sheet(byte[] pixels, int w, int h, int lid, double ppi)
    {
        var cell = Math.Max(1, (int)Math.Round(ppi / 50));
        var (gw, gh) = ((w + cell - 1) / cell, (h + cell - 1) / cell);
        var mask = new bool[gw * gh];
        for (var gy = 0; gy < gh; gy++)
            for (var gx = 0; gx < gw; gx++)
            {
                int on = 0, all = 0;
                for (var y = gy * cell; y < Math.Min(h, (gy + 1) * cell); y++)
                    for (var x = gx * cell; x < Math.Min(w, (gx + 1) * cell); x++, all++)
                        if (Math.Abs(pixels[y * w + x] - lid) > Contrast) on++;
                mask[gy * gw + gx] = 2 * on > all;
            }
        var cellsPerInch = ppi / cell;
        var open = Math.Max(1, (int)Math.Round(0.04 * cellsPerInch));
        var close = Math.Max(1, (int)Math.Round(0.08 * cellsPerInch));
        mask = PhotoFinder.Dilate(PhotoFinder.Erode(mask, gw, gh, open), gw, gh, open);
        mask = PhotoFinder.Close(mask, gw, gh, close);
        PhotoFinder.FillHoles(mask, gw, gh);
        if (Largest(mask, gw, gh) is not { } part) return null;

        var (bw, bh) = (part.MaxX - part.MinX + 1, part.MaxY - part.MinY + 1);
        if (part.Count < MinFill * bw * bh) return null; // not a solid rectangle
        if (bw * bh < MinShare * gw * gh || bw < MinSide * cellsPerInch || bh < MinSide * cellsPerInch) return null;

        var pad = (int)Math.Ceiling(Pad * ppi);
        var (x0, y0) = (Math.Max(0, part.MinX * cell - pad), Math.Max(0, part.MinY * cell - pad));
        var (x1, y1) = (Math.Min(w, (part.MaxX + 1) * cell + pad), Math.Min(h, (part.MaxY + 1) * cell + pad));
        if ((x1 - x0) >= NothingToCrop * w && (y1 - y0) >= NothingToCrop * h) return null;
        if (AnythingOutside(pixels, w, h, lid, x0, y0, x1, y1, ppi)) return null;
        return new CropBox((double)x0 / w, (double)y0 / h, (double)(x1 - x0) / w, (double)(y1 - y0) / h).Clamp();
    }

    private static (int Count, int MinX, int MinY, int MaxX, int MaxY)? Largest(bool[] mask, int w, int h)
    {
        var seen = new bool[mask.Length];
        var stack = new Stack<int>();
        (int Count, int MinX, int MinY, int MaxX, int MaxY)? best = null;
        for (var start = 0; start < mask.Length; start++)
        {
            if (!mask[start] || seen[start]) continue;
            int count = 0, minX = w, minY = h, maxX = -1, maxY = -1;
            seen[start] = true;
            stack.Push(start);
            while (stack.Count > 0)
            {
                var i = stack.Pop();
                var (x, y) = (i % w, i / w);
                count++;
                (minX, minY, maxX, maxY) = (Math.Min(minX, x), Math.Min(minY, y), Math.Max(maxX, x), Math.Max(maxY, y));
                if (x > 0 && mask[i - 1] && !seen[i - 1]) { seen[i - 1] = true; stack.Push(i - 1); }
                if (x < w - 1 && mask[i + 1] && !seen[i + 1]) { seen[i + 1] = true; stack.Push(i + 1); }
                if (y > 0 && mask[i - w] && !seen[i - w]) { seen[i - w] = true; stack.Push(i - w); }
                if (y < h - 1 && mask[i + w] && !seen[i + w]) { seen[i + w] = true; stack.Push(i + w); }
            }
            if (best is not { } b || count > b.Count) best = (count, minX, minY, maxX, maxY);
        }
        return best;
    }

    /// <summary>
    /// Whether anything but dust differs from the lid outside the box, down to faint marks: a threshold just above the scan's
    /// noise out there (measured, at least 8 levels). Marks a tenth of an inch apart count as one, so a line of tiny letters is
    /// seen for what it is. Dust is what stays small (<see cref="DustSide"/>), a lone letter isn't.
    /// </summary>
    private static bool AnythingOutside(byte[] pixels, int w, int h, int lid, int x0, int y0, int x1, int y1, double ppi)
    {
        var histogram = new int[256];
        var outside = 0;
        bool In(int x, int y) => x >= x0 && x < x1 && y >= y0 && y < y1;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                if (!In(x, y))
                {
                    histogram[Math.Abs(pixels[y * w + x] - lid)]++;
                    outside++;
                }
        if (outside == 0) return false;
        int median = 0, seenSoFar = 0;
        while (median < 255 && (seenSoFar += histogram[median]) <= outside / 2) median++;
        var limit = Math.Max(8, median * 3 + 2);

        // Marks: pixels past the limit with another beside them (a lone one is noise).
        var marks = new List<int>();
        var isMark = new bool[pixels.Length];
        bool Past(int x, int y) => x >= 0 && y >= 0 && x < w && y < h && !In(x, y) && Math.Abs(pixels[y * w + x] - lid) > limit;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                if (!Past(x, y)) continue;
                var alone = true;
                for (var dy = -1; dy <= 1 && alone; dy++)
                    for (var dx = -1; dx <= 1 && alone; dx++)
                        if ((dx != 0 || dy != 0) && Past(x + dx, y + dy)) alone = false;
                if (alone) continue;
                isMark[y * w + x] = true;
                marks.Add(y * w + x);
            }

        var reach = Math.Max(2, (int)Math.Round(ppi * Together));
        var longest = ppi * Together * 4;
        var dust = ppi * DustSide;
        var seen = new bool[pixels.Length];
        var stack = new Stack<int>();
        foreach (var start in marks)
        {
            if (seen[start]) continue;
            int minX = w, minY = h, maxX = -1, maxY = -1;
            seen[start] = true;
            stack.Push(start);
            while (stack.Count > 0)
            {
                var i = stack.Pop();
                var (x, y) = (i % w, i / w);
                (minX, minY, maxX, maxY) = (Math.Min(minX, x), Math.Min(minY, y), Math.Max(maxX, x), Math.Max(maxY, y));
                for (var ny = Math.Max(0, y - reach); ny <= Math.Min(h - 1, y + reach); ny++)
                    for (var nx = Math.Max(0, x - reach); nx <= Math.Min(w - 1, x + reach); nx++)
                    {
                        var n = ny * w + nx;
                        if (seen[n] || !isMark[n]) continue;
                        seen[n] = true;
                        stack.Push(n);
                    }
            }
            var (across, down) = (maxX - minX + 1, maxY - minY + 1);
            if (Math.Max(across, down) >= longest || Math.Min(across, down) >= dust) return true;
        }
        return false;
    }
}

/// <summary>
/// Evens the paper out to white, for keeps (<see cref="PaperLevel"/> only readies a page for a recognizer, and whitens photos
/// and thin strokes along with it). The white point follows the scan's own noise, so a quiet scan keeps marks a few levels
/// darker than its paper. A thin stroke a median would smooth away (a hairline, a pencil signature) is found as a connected run
/// of pixels darker than the noise and keeps them. Blocks that aren't paper (a picture: mostly mid-tones or dark, or at a level
/// no slow shading leads to) are divided by the paper around them, never darkened, and never snapped to white. A page whose paper is dark is left alone. Then lone specks go (<see cref="Despeckle"/>).
/// </summary>
public static class PageBackground
{
    private const int FlatBand = 12, MinStrokePixels = 16;
    private const float MinStrokeContrast = 10, MaxStep = 0.03f;

    /// <summary>Whether it changed the page. In place.</summary>
    public static bool Whiten(byte[] pixels, int width, int height, int channels, int dpi, out int specks, CancellationToken cancel = default)
    {
        specks = 0;
        if (width < 8 || height < 8) return false;
        var options = new ParallelOptions { CancellationToken = cancel };
        var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
        var smooth = Smooth.Median3(gray, width, height, cancel);
        cancel.ThrowIfCancellationRequested();

        var block = Math.Max(8, dpi / 6);
        var (cols, rows) = ((width + block - 1) / block, (height + block - 1) / block);
        var levels = new float[cols * rows];
        var picture = new bool[cols * rows];
        var noiseRaw = new float[cols * rows];
        var noiseSmooth = new float[cols * rows];
        Parallel.For(0, rows, options, by =>
        {
            Span<int> hs = stackalloc int[256];
            Span<int> hr = stackalloc int[256];
            for (var bx = 0; bx < cols; bx++)
            {
                hs.Clear();
                hr.Clear();
                var (x0, y0) = (bx * block, by * block);
                var (x1, y1) = (Math.Min(width, x0 + block), Math.Min(height, y0 + block));
                for (var y = y0; y < y1; y++)
                    for (var x = x0; x < x1; x++)
                    {
                        hs[smooth[y * width + x]]++;
                        hr[gray[y * width + x]]++;
                    }
                var all = (x1 - x0) * (y1 - y0);
                var level = Percentile(hs, all, 90);
                int mid = 0, dark = 0;
                for (var v = 0; v < level - FlatBand && v < 256; v++)
                    if (v <= 0.35 * level) dark += hs[v];
                    else mid += hs[v];
                var i = by * cols + bx;
                levels[i] = level;
                picture[i] = mid * 100 >= all * 60 || dark * 100 >= all * 60;
                // Noise: the spread of the paper's top half, 90th percentile to the top half's middle, in a block that is mostly paper.
                noiseSmooth[i] = (level - PercentileOfTop(hs, level, FlatBand)) / 0.67f;
                var levelRaw = Percentile(hr, all, 90);
                noiseRaw[i] = (levelRaw - Percentile(hr, all, 70)) / 0.75f;
            }
        });

        var candidates = Enumerable.Range(0, levels.Length).Where(i => !picture[i]).Select(i => levels[i]).Order().ToList();
        if (candidates.Count == 0) return false;
        var paper = candidates[(int)(candidates.Count * 0.9)];
        if (paper < 128) return false; // a dark page, not paper to whiten

        // Paper is what connects to the page's lightest level in small steps: shading changes slowly, a picture's edge doesn't.
        var known = PaperBlocks(levels, picture, paper, cols, rows);
        var paperBlocks = Enumerable.Range(0, levels.Length).Where(i => known[i]).ToList();
        if (paperBlocks.Count == 0) return false;
        var sigmaRaw = Median(paperBlocks.Select(i => noiseRaw[i]));
        var sigmaSmooth = Median(paperBlocks.Select(i => noiseSmooth[i]));
        var isPaper = (bool[])known.Clone();
        FillUnknown(levels, known, cols, rows);
        var map = new PaperLevel.Map(width, height, block, cols, rows, levels);

        var white = Math.Clamp(1 - 3.8f * sigmaSmooth / paper, 0.90f, 0.97f); // below 90% thin serifs go (ocr-corpus README)
        var strokes = Strokes(gray, width, height, map, Math.Max(MinStrokeContrast, 2.5f * sigmaRaw), Math.Max(8, MinStrokePixels * dpi / 300), cancel);
        var result = new byte[gray.Length];
        Parallel.For(0, height, options, y =>
        {
            for (var x = 0; x < width; x++)
            {
                var i = y * width + x;
                var level = map.At(x, y);
                if (!isPaper[y / block * cols + x / block])
                {
                    result[i] = (byte)Math.Clamp(gray[i] * 255f / Math.Max(level, gray[i]), 0, 254);
                    continue;
                }
                if (smooth[i] >= white * level) result[i] = strokes[i] ? (byte)Math.Clamp(gray[i] * 255f / (level * white), 0, 254) : (byte)255;
                else result[i] = (byte)Math.Clamp(Math.Min(smooth[i], gray[i]) * 255f / (level * white), 0, 254); // the darker of the two: a serif the median thins stays
            }
        });
        cancel.ThrowIfCancellationRequested();
        specks = Despeckle.Remove(result, width, height, dpi, cancel);

        if (channels == 1)
        {
            Buffer.BlockCopy(result, 0, pixels, 0, result.Length);
            return true;
        }
        Parallel.For(0, height, options, y =>
        {
            for (var x = 0; x < width; x++)
            {
                var i = y * width + x;
                if (result[i] == 255)
                {
                    pixels[i * 3] = pixels[i * 3 + 1] = pixels[i * 3 + 2] = 255;
                    continue;
                }
                // Every channel by what the grey level got, so a colored stamp stays its color.
                var scale = gray[i] > 0 ? result[i] / (float)gray[i] : 1;
                if (result[i] < gray[i]) scale = 1; // a pixel the smoothing darkened keeps its color as it was
                for (var c = 0; c < 3; c++) pixels[i * 3 + c] = (byte)Math.Clamp(pixels[i * 3 + c] * scale, 0, 255);
            }
        });
        return true;
    }

    private static int Percentile(ReadOnlySpan<int> histogram, int all, int percent)
    {
        var target = all * percent / 100;
        for (int v = 0, seen = 0; v < 256; v++)
            if ((seen += histogram[v]) > target) return v;
        return 255;
    }

    /// <summary>The middle of the pixels within <paramref name="band"/> below <paramref name="level"/> and above: the paper's own.</summary>
    private static int PercentileOfTop(ReadOnlySpan<int> histogram, int level, int band)
    {
        var from = Math.Max(0, level - band);
        var all = 0;
        for (var v = from; v < 256; v++) all += histogram[v];
        for (int v = from, seen = 0; v < 256; v++)
            if ((seen += histogram[v]) * 2 > all) return v;
        return level;
    }

    private static float Median(IEnumerable<float> values)
    {
        var list = values.Order().ToList();
        return list.Count == 0 ? 0 : list[list.Count / 2];
    }

    /// <summary>Blocks with no paper of their own take the average of their neighbours', from the edges of the known ones inward.</summary>
    private static void FillUnknown(float[] levels, bool[] known, int cols, int rows)
    {
        var pending = true;
        while (pending)
        {
            pending = false;
            var next = (bool[])known.Clone();
            for (var y = 0; y < rows; y++)
                for (var x = 0; x < cols; x++)
                {
                    var i = y * cols + x;
                    if (known[i]) continue;
                    float sum = 0;
                    var n = 0;
                    for (var dy = -1; dy <= 1; dy++)
                        for (var dx = -1; dx <= 1; dx++)
                        {
                            var (nx, ny) = (x + dx, y + dy);
                            if (nx < 0 || ny < 0 || nx >= cols || ny >= rows || !known[ny * cols + nx]) continue;
                            sum += levels[ny * cols + nx];
                            n++;
                        }
                    if (n > 0)
                    {
                        levels[i] = sum / n;
                        next[i] = true;
                    }
                    else pending = true;
                }
            Array.Copy(next, known, known.Length);
        }
    }

    /// <summary>Blocks reached from the lightest ones through neighbours close in level, never through a picture.</summary>
    private static bool[] PaperBlocks(float[] levels, bool[] picture, float paper, int cols, int rows)
    {
        var known = new bool[levels.Length];
        var stack = new Stack<int>();
        for (var i = 0; i < levels.Length; i++)
            if (!picture[i] && levels[i] >= paper - FlatBand)
            {
                known[i] = true;
                stack.Push(i);
            }
        while (stack.Count > 0)
        {
            var i = stack.Pop();
            var (x, y) = (i % cols, i / cols);
            if (x > 0) Visit(i - 1, i);
            if (x < cols - 1) Visit(i + 1, i);
            if (y > 0) Visit(i - cols, i);
            if (y < rows - 1) Visit(i + cols, i);
        }
        return known;

        void Visit(int n, int from)
        {
            if (known[n] || picture[n] || levels[n] < 0.55f * paper || Math.Abs(levels[n] - levels[from]) > MaxStep * levels[from]) return;
            known[n] = true;
            stack.Push(n);
        }
    }

    /// <summary>
    /// Pixels on a line of faint ink a median would smooth away: darker than the paper by more than the noise, in a connected run
    /// too long for chance (a hairline, hard pencil, a signature's tail). Noise this far out of the paper's range is sparse, so it
    /// rarely links up.
    /// </summary>
    private static bool[] Strokes(byte[] gray, int width, int height, PaperLevel.Map map, float contrast, int minPixels, CancellationToken cancel)
    {
        var candidate = new bool[gray.Length];
        Parallel.For(0, height, new ParallelOptions { CancellationToken = cancel }, y =>
        {
            for (var x = 0; x < width; x++)
                candidate[y * width + x] = gray[y * width + x] < map.At(x, y) - contrast;
        });
        var strokes = new bool[gray.Length];
        var seen = new bool[gray.Length];
        var stack = new Stack<int>();
        var run = new List<int>();
        for (var start = 0; start < gray.Length; start++)
        {
            if (start % width == 0) cancel.ThrowIfCancellationRequested();
            if (!candidate[start] || seen[start]) continue;
            run.Clear();
            seen[start] = true;
            stack.Push(start);
            while (stack.Count > 0)
            {
                var i = stack.Pop();
                run.Add(i);
                var (x, y) = (i % width, i / width);
                // Two pixels away still counts: a pencil line has gaps in its grain.
                for (var dy = -2; dy <= 2; dy++)
                    for (var dx = -2; dx <= 2; dx++)
                    {
                        var (nx, ny) = (x + dx, y + dy);
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                        var n = ny * width + nx;
                        if (seen[n] || !candidate[n]) continue;
                        seen[n] = true;
                        stack.Push(n);
                    }
            }
            if (run.Count >= minPixels)
                foreach (var i in run) strokes[i] = true;
        }
        return strokes;
    }
}

/// <summary>
/// Takes the printing screen out of pictures: blocks whose pixels repeat at a short period both across and down (a halftone at
/// any usual angle; text repeats at most along a line, a bar code in one direction) are blurred just enough to lose the dots,
/// fading out at their edges. Everything else keeps its pixels byte for byte. Below 150 dpi there are no dots left to take out.
/// </summary>
public static class Descreen
{
    private const double MinCorrelation = 0.3;
    private const int MinVariance = 16, Samples = 6;

    /// <summary>Whether any of the page was a screen. In place.</summary>
    public static bool Apply(byte[] pixels, int width, int height, int channels, int dpi, CancellationToken cancel = default)
    {
        if (dpi < 150 || width < 64 || height < 64) return false;
        var options = new ParallelOptions { CancellationToken = cancel };
        var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
        var block = Math.Max(32, dpi / 6);
        var maxLag = Math.Max(8, dpi / 25);
        var (cols, rows) = (width / block, height / block);
        if (cols < 1 || rows < 1) return false;
        var periods = new int[cols * rows];
        Parallel.For(0, rows, options, by =>
        {
            for (var bx = 0; bx < cols; bx++) periods[by * cols + bx] = BlockPeriod(gray, width, bx * block, by * block, block, maxLag);
        });

        var screened = new bool[cols * rows];
        for (var y = 0; y < rows; y++)
            for (var x = 0; x < cols; x++)
            {
                if (periods[y * cols + x] == 0) continue;
                // One block alone is chance: a screen goes on.
                var company = 0;
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++)
                        if ((dx != 0 || dy != 0) && x + dx >= 0 && y + dy >= 0 && x + dx < cols && y + dy < rows && periods[(y + dy) * cols + x + dx] != 0) company++;
                screened[y * cols + x] = company >= 2;
            }
        var found = periods.Where((p, i) => screened[i]).Order().ToList();
        if (found.Count == 0) return false;
        var period = found[found.Count / 2];

        var grown = PhotoFinder.Dilate(screened, cols, rows, 1);
        PhotoFinder.FillHoles(grown, cols, rows);
        grown = PhotoFinder.Erode(grown, cols, rows, 1);
        for (var i = 0; i < grown.Length; i++) grown[i] |= screened[i];

        // Where the blur goes: every block of the screen, with room for its fading edge.
        int minX = cols, minY = rows, maxX = -1, maxY = -1;
        for (var y = 0; y < rows; y++)
            for (var x = 0; x < cols; x++)
                if (grown[y * cols + x]) (minX, minY, maxX, maxY) = (Math.Min(minX, x), Math.Min(minY, y), Math.Max(maxX, x), Math.Max(maxY, y));
        var fade = Math.Max(2, block / 8);
        var (x0, y0) = (Math.Max(0, minX * block - fade), Math.Max(0, minY * block - fade));
        var x1 = maxX == cols - 1 ? width : Math.Min(width, (maxX + 1) * block + fade);
        var y1 = maxY == rows - 1 ? height : Math.Min(height, (maxY + 1) * block + fade);
        var (rw, rh) = (x1 - x0, y1 - y0);

        // Just enough to lose the dots (about 4% of their strength left), so type on a tint stays readable.
        var sigma = 0.4 * period;
        var radius = Math.Max(1, (int)(sigma * 0.7));
        var passes = Math.Max(3, (int)Math.Ceiling(sigma * sigma / (radius * (radius + 1) / 3.0)));
        var blurred = new byte[rw * rh * channels];
        for (var y = 0; y < rh; y++) Buffer.BlockCopy(pixels, (y0 + y) * width * channels + x0 * channels, blurred, y * rw * channels, rw * channels);
        for (var pass = 0; pass < passes; pass++)
        {
            cancel.ThrowIfCancellationRequested();
            BoxAcross(blurred, rw, rh, channels, radius, options);
            BoxDown(blurred, rw, rh, channels, radius, options);
        }

        // Weight by distance to a screened block's edge, per pixel from its block's neighbours.
        Parallel.For(0, rh, options, ry =>
        {
            var y = y0 + ry;
            for (var rx = 0; rx < rw; rx++)
            {
                var x = x0 + rx;
                var weight = Weight(grown, cols, rows, block, fade, x, y, width, height);
                if (weight <= 0) continue;
                for (var c = 0; c < channels; c++)
                {
                    var at = (y * width + x) * channels + c;
                    pixels[at] = (byte)(pixels[at] + (blurred[(ry * rw + rx) * channels + c] - pixels[at]) * weight);
                }
            }
        });
        return true;
    }

    private static float Weight(bool[] grown, int cols, int rows, int block, int fade, int x, int y, int width, int height)
    {
        float best = 0;
        var (bx, by) = (Math.Min(x / block, cols - 1), Math.Min(y / block, rows - 1));
        for (var dy = -1; dy <= 1; dy++)
            for (var dx = -1; dx <= 1; dx++)
            {
                var (nx, ny) = (bx + dx, by + dy);
                if (nx < 0 || ny < 0 || nx >= cols || ny >= rows || !grown[ny * cols + nx]) continue;
                // A last row or column of blocks reaches the page's edge.
                var (left, top) = (nx * block, ny * block);
                var right = nx == cols - 1 ? width : left + block;
                var bottom = ny == rows - 1 ? height : top + block;
                var outX = Math.Max(Math.Max(left - x, x - (right - 1)), 0);
                var outY = Math.Max(Math.Max(top - y, y - (bottom - 1)), 0);
                var outside = Math.Max(outX, outY);
                if (outside >= fade) continue;
                best = Math.Max(best, 1 - (float)outside / fade);
            }
        return best;
    }

    /// <summary>The screen's period in a block in pixels, or 0 when it repeats at no short period both across and down.</summary>
    private static int BlockPeriod(byte[] gray, int width, int x0, int y0, int block, int maxLag)
    {
        long sum = 0, squares = 0;
        for (var y = y0; y < y0 + block; y++)
            for (var x = x0; x < x0 + block; x++)
            {
                int v = gray[y * width + x];
                sum += v;
                squares += v * v;
            }
        var n = block * block;
        var mean = (double)sum / n;
        if (squares / (double)n - mean * mean < MinVariance) return 0;

        var across = FirstPeak(block, maxLag, Samples, (line, i) => gray[(y0 + (line * 2 + 1) * block / (Samples * 2)) * width + x0 + i]);
        if (across == 0) return 0;
        var down = FirstPeak(block, maxLag, Samples, (line, i) => gray[(y0 + i) * width + x0 + (line * 2 + 1) * block / (Samples * 2)]);
        if (down == 0 || Math.Max(across, down) > 2 * Math.Min(across, down)) return 0;
        // A screen at 45° repeats less often along a row than its dots lie apart; along the diagonal it says so. The dots' true wavelength.
        var wave = Math.Max(across, down);
        var diagonal = FirstPeak(block, maxLag, Samples, (line, i) =>
        {
            var start = (line * 2 + 1) * block / (Samples * 2);
            return gray[(y0 + (start + i) % block) * width + x0 + i];
        });
        return diagonal > 0 ? (int)Math.Max(2, Math.Round(Math.Min(wave, diagonal * Math.Sqrt(2)))) : wave;
    }

    /// <summary>The first lag of at least 2 where sample lines correlate with themselves, at a local peak of correlation; 0 when none. Each line is measured against its own mean, so a line of one level says nothing.</summary>
    private static int FirstPeak(int length, int maxLag, int lines, Func<int, int, byte> at)
    {
        var limit = Math.Min(maxLag + 1, length / 3);
        Span<double> r = stackalloc double[limit + 1];
        Span<double> values = stackalloc double[length];
        double energy = 0;
        for (var line = 0; line < lines; line++)
        {
            double mean = 0;
            for (var i = 0; i < length; i++) mean += values[i] = at(line, i);
            mean /= length;
            for (var i = 0; i < length; i++)
            {
                values[i] -= mean;
                energy += values[i] * values[i];
            }
            for (var lag = 1; lag <= limit; lag++)
            {
                double s = 0;
                for (var i = 0; i + lag < length; i++) s += values[i] * values[i + lag];
                r[lag] += s * length / (length - lag);
            }
        }
        if (energy < lines * length) return 0; // less than a level's variation
        for (var lag = 2; lag < limit; lag++)
            if (r[lag] / energy >= MinCorrelation && r[lag] > r[lag - 1] && r[lag] >= r[lag + 1]) return lag;
        return 0;
    }

    private static void BoxAcross(byte[] data, int w, int h, int channels, int radius, ParallelOptions options)
    {
        Parallel.For(0, h, options, () => new int[w], (y, _, line) =>
        {
            for (var c = 0; c < channels; c++)
            {
                var sum = 0;
                for (var x = -radius; x <= radius; x++) sum += data[(y * w + Math.Clamp(x, 0, w - 1)) * channels + c];
                for (var x = 0; x < w; x++)
                {
                    line[x] = (sum + radius) / (2 * radius + 1); // rounded: truncating darkens the page a level a pass
                    sum += data[(y * w + Math.Min(w - 1, x + radius + 1)) * channels + c] - data[(y * w + Math.Max(0, x - radius)) * channels + c];
                }
                for (var x = 0; x < w; x++) data[(y * w + x) * channels + c] = (byte)line[x];
            }
            return line;
        }, _ => { });
    }

    private static void BoxDown(byte[] data, int w, int h, int channels, int radius, ParallelOptions options)
    {
        Parallel.For(0, w, options, () => new int[h], (x, _, line) =>
        {
            for (var c = 0; c < channels; c++)
            {
                var sum = 0;
                for (var y = -radius; y <= radius; y++) sum += data[(Math.Clamp(y, 0, h - 1) * w + x) * channels + c];
                for (var y = 0; y < h; y++)
                {
                    line[y] = (sum + radius) / (2 * radius + 1);
                    sum += data[(Math.Min(h - 1, y + radius + 1) * w + x) * channels + c] - data[(Math.Max(0, y - radius) * w + x) * channels + c];
                }
                for (var y = 0; y < h; y++) data[(y * w + x) * channels + c] = (byte)line[y];
            }
            return line;
        }, _ => { });
    }
}

/// <summary>
/// Restores a faded print: each channel's darkest and lightest levels (0.5% in from each end) are spread to the full range, which
/// brings blacks back and takes out a color cast; then the mid-tones of the channels are brought level (colored scans). A page
/// with little range (blank), a dark page, or one already at full range is left as it is, or nearly.
/// </summary>
public static class FadedColors
{
    private const int MinRange = 32, DarkPage = 110, MaxGainRange = 64;

    /// <summary>Whether it changed the page. In place.</summary>
    public static bool Restore(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        if (width < 1 || height < 1) return false;
        var histograms = new long[channels][];
        for (var c = 0; c < channels; c++) histograms[c] = new long[256];
        var rowStep = Math.Max(1, height / 2000);
        var columnStep = Math.Max(1, width / 2000);
        for (var y = 0; y < height; y += rowStep)
        {
            cancel.ThrowIfCancellationRequested();
            for (var x = 0; x < width; x += columnStep)
                for (var c = 0; c < channels; c++) histograms[c][pixels[(y * width + x) * channels + c]]++;
        }
        var luts = new byte[channels][];
        for (var c = 0; c < channels; c++)
        {
            var (low, high) = Ends(histograms[c]);
            if (high < DarkPage || high - low < MinRange) return false;
            if (high - low < MaxGainRange) low = high - MaxGainRange; // a gain past 4 only spreads noise
            var lut = new byte[256];
            for (var v = 0; v < 256; v++) lut[v] = (byte)Math.Clamp((v - low) * 255 / Math.Max(1, high - low), 0, 255);
            luts[c] = lut;
        }

        if (channels == 3) BalanceMidTones(luts, pixels, width, height, rowStep, columnStep);

        var changed = false;
        foreach (var lut in luts)
            for (var v = 0; v < 256; v++)
                if (lut[v] != v) changed = true;
        if (!changed) return false;
        Parallel.For(0, height, new ParallelOptions { CancellationToken = cancel }, y =>
        {
            var at = y * width * channels;
            for (var x = 0; x < width; x++)
                for (var c = 0; c < channels; c++, at++) pixels[at] = luts[c][pixels[at]];
        });
        return true;
    }

    /// <summary>The levels 0.5% from each end, leaving pure white out (the corners a straightening uncovers, a whitened background).</summary>
    private static (int Low, int High) Ends(long[] histogram)
    {
        long all = 0;
        for (var v = 0; v < 255; v++) all += histogram[v];
        if (all == 0) return (255, 255);
        var cut = all / 200;
        int low = 0, high = 254;
        for (long seen = 0; low < 254 && (seen += histogram[low]) <= cut;) low++;
        for (long seen = 0; high > 0 && (seen += histogram[high]) <= cut;) high--;
        return (low, high);
    }

    private static void BalanceMidTones(byte[][] luts, byte[] pixels, int width, int height, int rowStep, int columnStep)
    {
        var sums = new double[3];
        long count = 0, all = 0;
        for (var y = 0; y < height; y += rowStep)
            for (var x = 0; x < width; x += columnStep, all++)
            {
                var i = (y * width + x) * 3;
                var (b, g, r) = (luts[0][pixels[i]], luts[1][pixels[i + 1]], luts[2][pixels[i + 2]]);
                var luma = (b * 29 + g * 150 + r * 77) >> 8;
                if (luma is < 40 or > 215) continue;
                sums[0] += b;
                sums[1] += g;
                sums[2] += r;
                count++;
            }
        if (count * 20 < all) return; // a page of text and paper has no mid-tones to go by
        var target = (sums[0] + sums[1] + sums[2]) / 3 / count / 255;
        for (var c = 0; c < 3; c++)
        {
            var mean = sums[c] / count / 255;
            var gamma = Math.Clamp(Math.Log(target) / Math.Log(mean), 0.7, 1.4);
            for (var v = 0; v < 256; v++) luts[c][v] = (byte)Math.Clamp(Math.Round(255 * Math.Pow(luts[c][v] / 255.0, gamma)), 0, 255);
        }
    }
}
