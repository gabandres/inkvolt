using System.Runtime.CompilerServices;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Core.Suite;

/// <summary>What became of a page a scanner sent: kept, left out as blank (on request), or unreadable (no JPEG size: left out).</summary>
public enum ScanPageFate { Kept, Blank, Unreadable }

public sealed record ScanRunPage(byte[] Jpeg, ScanPageFate Fate);

/// <summary>A preset's Clean up for <see cref="ScanRun.Clean"/>: its filters, the scan's resolution, and the app's JPEG codec (WIC).</summary>
/// <param name="Decode">A JPEG as pixels: grey (1 channel) or BGR (3), rows packed.</param>
/// <param name="Encode">Pixels as <paramref name="Decode"/> gives them, as a JPEG.</param>
public sealed record ScanRunCleanup(PageFilters Filters, int Dpi, Func<byte[], (byte[] Pixels, int Width, int Height, int Channels)> Decode,
    Func<byte[], int, int, int, byte[]> Encode);

/// <summary>
/// One scan job as Inkvolt PDF's Scan dialog runs it, on any <see cref="IScanner"/> (eSCL, WIA, TWAIN): each page the scanner
/// sends, checked for blankness when asked (<see cref="BlankPage"/> on a small greyscale copy, off the caller's thread), then
/// the kept pages as one PDF with each JPEG embedded as it came. Shared so the dialog's page handling is tested with a fake scanner.
/// </summary>
public static class ScanRun
{
    /// <param name="analysis">The greyscale copy of a page to judge (the app decodes with WIC); null keeps every page.</param>
    /// <param name="cleanup">A preset's Clean up (<see cref="Clean"/>), applied to each kept page off the caller's thread; null: pages as scanned.</param>
    public static async IAsyncEnumerable<ScanRunPage> PagesAsync(IScanner scanner, ScanRequest request, Func<byte[], GrayImage>? analysis,
        [EnumeratorCancellation] CancellationToken ct = default, ScanRunCleanup? cleanup = null)
    {
        await foreach (var jpeg in scanner.ScanAsync(request, ct).ConfigureAwait(false))
        {
            var fate = await FateAsync(jpeg, analysis, ct).ConfigureAwait(false);
            if (fate != ScanPageFate.Kept || cleanup is null || cleanup.Filters == PageFilters.None)
            {
                yield return new ScanRunPage(jpeg, fate);
                continue;
            }
            yield return new ScanRunPage(await Task.Run(() => Clean(jpeg, cleanup, ct), ct).ConfigureAwait(false), fate);
        }
    }

    /// <summary>
    /// A page cleaned as a preset's Clean up says, as Inkvolt Print's Scan tab cleans it (<see cref="PaperEdge"/> for the crop, on a
    /// copy at about 100 dpi; <see cref="PageCleanup"/> for the pixels): the same JPEG when nothing changed it, else the cleaned page
    /// encoded again. A page that can't be decoded or cleaned is kept as scanned: never lose a page to the cleanup.
    /// </summary>
    public static byte[] Clean(byte[] jpeg, ScanRunCleanup cleanup, CancellationToken ct = default)
    {
        if (cleanup.Filters == PageFilters.None) return jpeg;
        try
        {
            var (pixels, width, height, channels) = cleanup.Decode(jpeg);
            if (width < 1 || height < 1 || channels is not (1 or 3) || pixels.Length < (long)width * height * channels) return jpeg;
            var changed = false;
            if (cleanup.Filters.HasFlag(PageFilters.CropToPaper))
            {
                var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
                var factor = Math.Max(1, (int)Math.Round(cleanup.Dpi / 100.0));
                if (PaperEdge.Find(ScanCleanup.Downscale(new GrayImage(width, height, gray), factor), cleanup.Dpi / (double)factor) is { IsFull: false } crop)
                {
                    (pixels, width, height) = Cut(pixels, width, height, channels, crop);
                    changed = true;
                }
            }
            ct.ThrowIfCancellationRequested();
            if ((cleanup.Filters & PageFilters.PixelFilters) != 0)
            {
                var cleaned = PageCleanup.Apply(pixels, width, height, channels, cleanup.Dpi, cleanup.Filters, ct);
                if (cleaned.Done != PageFilters.None)
                {
                    pixels = cleaned.Pixels;
                    changed = true;
                }
            }
            return changed ? cleanup.Encode(pixels, width, height, channels) : jpeg;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return jpeg;
        }
    }

    private static (byte[] Pixels, int Width, int Height) Cut(byte[] px, int w, int h, int channels, CropBox crop)
    {
        var x = Math.Clamp((int)Math.Round(crop.X * w), 0, w - 1);
        var y = Math.Clamp((int)Math.Round(crop.Y * h), 0, h - 1);
        var cw = Math.Clamp((int)Math.Round(crop.Width * w), 1, w - x);
        var ch = Math.Clamp((int)Math.Round(crop.Height * h), 1, h - y);
        var cut = new byte[cw * ch * channels];
        for (var row = 0; row < ch; row++) Buffer.BlockCopy(px, ((y + row) * w + x) * channels, cut, row * cw * channels, cw * channels);
        return (cut, cw, ch);
    }

    private static async Task<ScanPageFate> FateAsync(byte[] jpeg, Func<byte[], GrayImage>? analysis, CancellationToken ct)
    {
        try
        {
            PdfWriter.JpegInfo(jpeg);
        }
        catch (FormatException)
        {
            return ScanPageFate.Unreadable;
        }
        if (analysis is null) return ScanPageFate.Kept;
        try
        {
            return await Task.Run(() => BlankPage.IsBlank(analysis(jpeg)), ct).ConfigureAwait(false) ? ScanPageFate.Blank : ScanPageFate.Kept;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return ScanPageFate.Kept; // a page that can't be judged is kept: never lose a page to the check
        }
    }

    /// <summary>
    /// The pages as one PDF at their scan resolution: each JPEG as it is; or, for a page scanned in black and white
    /// (<c>OneBit</c>), the page at 1 bit (<see cref="Bilevel"/>) as lossless JBIG2, CCITT G4 or Flate, whichever is smallest
    /// (<see cref="PdfWriter.OneBit"/>): a twentieth to a fiftieth of its JPEG. A page that can't be decoded stays its JPEG.
    /// </summary>
    /// <param name="decodeGray">A JPEG as grey pixels (rows of Width bytes, 0 black); the app decodes with WIC. Null: every page as its JPEG.</param>
    public static byte[] ToPdf(IReadOnlyList<(byte[] Jpeg, int Dpi, bool OneBit)> pages, string title,
        Func<byte[], (byte[] Gray, int Width, int Height)>? decodeGray = null, CancellationToken cancel = default)
    {
        var written = new PdfPage[pages.Count];
        Parallel.For(0, pages.Count, new ParallelOptions { CancellationToken = cancel, MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount / 2, 1, 4) }, i =>
        {
            var (jpeg, dpi, oneBit) = pages[i];
            written[i] = oneBit && decodeGray is not null && OneBit(jpeg, dpi, decodeGray, cancel) is { } bits
                ? PdfPage.BlackAndWhite(bits, dpi) with { Jbig2 = true }
                : new PdfPage(jpeg, dpi);
        });
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, written, title);
        return ms.ToArray();
    }

    private static BitImage? OneBit(byte[] jpeg, int dpi, Func<byte[], (byte[] Gray, int Width, int Height)> decode, CancellationToken cancel)
    {
        try
        {
            var (gray, width, height) = decode(jpeg);
            if (width < 1 || height < 1 || (long)width * height > BitImage.MaxPixels || gray.Length < (long)width * height) return null;
            return Bilevel.FromScan(gray, width, height, dpi, cancel);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null; // kept as scanned: never lose a page to the conversion
        }
    }

    /// <summary>The dialog's line once a job ends: pages added, blank pages left out, what to do next.</summary>
    /// <param name="glass">The job was from the glass (one page per job).</param>
    /// <param name="finish">The finish button's words ("Open as new document").</param>
    public static string DoneText(int kept, int blank, int unreadable, bool glass, string finish)
    {
        var left = new List<string>();
        if (blank > 0) left.Add(blank == 1 ? "1 blank page left out" : $"{blank} blank pages left out");
        if (unreadable > 0) left.Add(unreadable == 1 ? "1 page that couldn't be read left out" : $"{unreadable} pages that couldn't be read left out");
        var also = left.Count == 0 ? "" : $" ({string.Join(", ", left)})";
        if (kept == 0)
            return blank > 0 && unreadable == 0
                ? $"Every page scanned looked blank, so none were added{also}. Clear \"Leave out blank pages\" to keep them."
                : $"The scanner returned no pages{also}.";
        return glass
            ? $"Done{also}. For another page, put it on the glass and press Scan another page; or press {finish}."
            : $"Done: {Pages(kept)} from the feeder{also}.";
    }

    public static string Pages(int n) => n == 1 ? "1 page" : $"{n} pages";
}
