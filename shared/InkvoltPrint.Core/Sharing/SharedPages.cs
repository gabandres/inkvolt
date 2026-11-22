namespace InkvoltPrint.Core.Sharing;

/// <summary>
/// How big a shared printer's job is drawn for its Windows queue (roadmap 4.10). Every page is fitted to the queue's paper, so it's drawn
/// at that size, at the <see cref="Dpi"/> the shared printer announces: never at the size the document names (a small PDF of 200 inch
/// pages, a 36-million-pixel raster page). The pages drawn are kept one at a time; all of a job's together, at most
/// <see cref="MaxJobBytes"/>.
/// </summary>
public static class SharedPages
{
    /// <summary>The resolution a page is drawn at: what the shared printer announces (printer-resolution-supported).</summary>
    public const int Dpi = 300;

    /// <summary>The pictures drawn for one job, all pages together: past it the job is the document's fault (too large).</summary>
    public const long MaxJobBytes = 400L * 1024 * 1024;

    /// <summary>
    /// The pixels a page of <paramref name="widthInches"/> × <paramref name="heightInches"/> is drawn with on <paramref name="media"/>:
    /// fitted to the paper (a landscape page on portrait paper turned, as the queue places it) at <see cref="Dpi"/>, its shape kept,
    /// at least 1 × 1. A size that isn't a number is drawn as the paper.
    /// </summary>
    public static (int Width, int Height) Pixels(double widthInches, double heightInches, string media)
    {
        var (w, h) = SharedPrinterMedia.Size(media);
        double paperShort = Math.Min(w, h) / 2540.0 * Dpi, paperLong = Math.Max(w, h) / 2540.0 * Dpi;
        if (!double.IsFinite(widthInches) || !double.IsFinite(heightInches) || widthInches <= 0 || heightInches <= 0)
            return ((int)Math.Round(paperShort), (int)Math.Round(paperLong));
        var k = Math.Min(paperLong / Math.Max(widthInches, heightInches), paperShort / Math.Min(widthInches, heightInches));
        return (Side(widthInches * k), Side(heightInches * k));
    }

    /// <summary>
    /// The size a picture of <paramref name="width"/> × <paramref name="height"/> pixels (a JPEG, a raster page) is drawn at: brought
    /// down to <see cref="Pixels"/> when larger, never enlarged (its pixels are all it has).
    /// </summary>
    public static (int Width, int Height) Fitted(int width, int height, double widthInches, double heightInches, string media)
    {
        var (mostW, mostH) = Pixels(widthInches, heightInches, media);
        if (width <= 0 || height <= 0) return (Math.Max(1, width), Math.Max(1, height));
        var k = Math.Min((double)mostW / width, (double)mostH / height);
        return k >= 1 ? (width, height) : (Side(width * k), Side(height * k));
    }

    private static int Side(double v) => (int)Math.Clamp(Math.Round(v), 1, 100_000);
}
