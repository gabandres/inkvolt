using System.Runtime.CompilerServices;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Core.Suite;

/// <summary>What became of a page a scanner sent: kept, left out as blank (on request), or unreadable (no JPEG size: left out).</summary>
public enum ScanPageFate { Kept, Blank, Unreadable }

public sealed record ScanRunPage(byte[] Jpeg, ScanPageFate Fate);

/// <summary>
/// One scan job as Inkvolt PDF's Scan dialog runs it, on any <see cref="IScanner"/> (eSCL, WIA, TWAIN): each page the scanner
/// sends, checked for blankness when asked (<see cref="BlankPage"/> on a small greyscale copy, off the caller's thread), then
/// the kept pages as one PDF with each JPEG embedded as it came. Shared so the dialog's page handling is tested with a fake scanner.
/// </summary>
public static class ScanRun
{
    /// <param name="analysis">The greyscale copy of a page to judge (the app decodes with WIC); null keeps every page.</param>
    public static async IAsyncEnumerable<ScanRunPage> PagesAsync(IScanner scanner, ScanRequest request, Func<byte[], GrayImage>? analysis,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        await foreach (var jpeg in scanner.ScanAsync(request, ct).ConfigureAwait(false))
        {
            yield return new ScanRunPage(jpeg, await FateAsync(jpeg, analysis, ct).ConfigureAwait(false));
        }
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

    /// <summary>The pages as one PDF, each JPEG as it is, at its scan resolution.</summary>
    public static byte[] ToPdf(IReadOnlyList<(byte[] Jpeg, int Dpi)> pages, string title)
    {
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, [.. pages.Select(p => new PdfPage(p.Jpeg, p.Dpi))], title);
        return ms.ToArray();
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
