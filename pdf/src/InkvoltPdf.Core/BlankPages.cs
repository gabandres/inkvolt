using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// Blank pages of a document (the back of a one-sided sheet, a separator sheet): a page is blank when its picture, as it
/// shows with its comments, is almost all paper, by the test File › Scan uses to skip blank pages (<see cref="BlankPage"/>,
/// the shared scanning code): a page with as little as a short word on it is not blank, specks and show-through are.
/// Remove Blank Pages, Split at Blank Pages and their Batch actions go through here.
/// </summary>
public static class BlankPages
{
    /// <summary>The longer side of the picture a page is judged on, in pixels (as File › Scan judges a scan).</summary>
    public const int AnalysisSize = 1100;

    /// <summary>Whether <paramref name="page"/> is blank. A page that can't be drawn is not: no page is ever lost to the check.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    public static bool IsBlank(PdfEngine engine, int page, CancellationToken cancel = default)
    {
        var g = engine.GetPage(page);
        var longest = Math.Max(g.Width, g.Height);
        if (!double.IsFinite(longest) || longest <= 0) return false;
        RenderedImage image;
        try
        {
            image = engine.Render(page, AnalysisSize / longest, cancel: cancel);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return false;
        }
        return BlankPage.IsBlank(Gray(image));
    }

    /// <summary>The blank pages among <paramref name="pages"/> (all when null), in page order.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    public static int[] Find(PdfEngine engine, IReadOnlyList<int>? pages = null, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        var look = pages ?? [.. Enumerable.Range(0, engine.PageCount)];
        var blank = new List<int>();
        for (var i = 0; i < look.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report((i, look.Count));
            if (look[i] >= 0 && look[i] < engine.PageCount && IsBlank(engine, look[i], cancel)) blank.Add(look[i]);
        }
        progress?.Report((look.Count, look.Count));
        return [.. blank.Distinct().Order()];
    }

    /// <summary>
    /// The documents a stack with blank separator sheets holds: the runs of pages between blank ones, the blank pages left
    /// out. Several blank pages in a row (a sheet's two sides) separate once; runs of no page are dropped.
    /// </summary>
    public static List<int[]> SplitAt(int pageCount, IReadOnlyCollection<int> blanks)
    {
        var separators = blanks.ToHashSet();
        var parts = new List<int[]>();
        var run = new List<int>();
        for (var p = 0; p < pageCount; p++)
        {
            if (!separators.Contains(p))
            {
                run.Add(p);
                continue;
            }
            if (run.Count > 0) parts.Add([.. run]);
            run.Clear();
        }
        if (run.Count > 0) parts.Add([.. run]);
        return parts;
    }

    /// <summary>
    /// Removes the blank pages <paramref name="blanks"/> (as found by <see cref="Find"/> and reviewed), with the bookmarks
    /// and links that led to them, as Delete Pages does.
    /// </summary>
    /// <exception cref="InvalidOperationException">Every page is blank: a document keeps at least one page.</exception>
    public static byte[] Remove(byte[] data, string? password, IReadOnlyCollection<int> blanks) => PageEditor.Delete(data, password, blanks);

    /// <summary>A BGR picture as 8-bit grey (0 black, 255 white), as the scan's test reads it.</summary>
    internal static GrayImage Gray(RenderedImage image)
    {
        var px = image.Pixels;
        var gray = new byte[image.Width * image.Height];
        for (int i = 0, s = 0; i < gray.Length; i++, s += 3)
            gray[i] = (byte)((px[s] * 29 + px[s + 1] * 150 + px[s + 2] * 77) >> 8);
        return new GrayImage(image.Width, image.Height, gray);
    }
}
