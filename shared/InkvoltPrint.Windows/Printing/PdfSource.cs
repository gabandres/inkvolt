using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace InkvoltPrint.Windows.Printing;

/// <summary>A rendered page: encoded image plus the page's physical size in inches.</summary>
public sealed record RenderedPage(byte[] Image, double WidthInches, double HeightInches);

/// <summary>
/// Opens PDFs with the PDF engine built into Windows (Windows.Data.Pdf, the one Edge uses):
/// no third-party PDF library. Renders pages to images for previews and printing.
/// </summary>
public sealed class PdfSource
{
    private readonly PdfDocument _doc;

    private PdfSource(PdfDocument doc, string path)
    {
        _doc = doc;
        Path = path;
    }

    public string Path { get; }
    public int PageCount => (int)_doc.PageCount;

    /// <exception cref="PdfOpenException">Not a PDF, damaged, or password protected.</exception>
    public static async Task<PdfSource> OpenAsync(string path, string? password = null)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(System.IO.Path.GetFullPath(path));
            var doc = password is null ? await PdfDocument.LoadFromFileAsync(file) : await PdfDocument.LoadFromFileAsync(file, password);
            return new PdfSource(doc, path);
        }
        catch (Exception ex) when (ex.HResult == unchecked((int)0x8007052B)) // ERROR_WRONG_PASSWORD
        {
            throw new PdfOpenException("This PDF is password protected.", isPasswordProtected: true);
        }
        catch (Exception ex) when (ex is not PdfOpenException and not OperationCanceledException)
        {
            throw new PdfOpenException($"Could not open the PDF: {ex.Message}", isPasswordProtected: false);
        }
    }

    /// <summary>Page size in inches (PDF pages report size in 1/96 in).</summary>
    public (double Width, double Height) PageSizeInches(int pageNumber)
    {
        using var page = _doc.GetPage((uint)(pageNumber - 1));
        return (page.Size.Width / 96.0, page.Size.Height / 96.0);
    }

    /// <summary>
    /// Renders a 1-based page at <paramref name="dpi"/> (or to <paramref name="maxWidthPx"/> wide for thumbnails).
    /// JPEG keeps memory and spool size small; text stays crisp at 300 dpi on a laser printer.
    /// </summary>
    public async Task<RenderedPage> RenderAsync(int pageNumber, int dpi, int? maxWidthPx = null, CancellationToken ct = default)
    {
        using var page = _doc.GetPage((uint)(pageNumber - 1));
        var wIn = page.Size.Width / 96.0;
        var hIn = page.Size.Height / 96.0;
        var scale = maxWidthPx is { } max ? max / page.Size.Width : dpi / 96.0;
        // Cap at ~50 MP (about A2 at 300 dpi): larger pages are rendered at lower resolution instead of failing.
        const double MaxPixels = 50_000_000;
        var pixels = page.Size.Width * scale * page.Size.Height * scale;
        if (pixels > MaxPixels) scale *= Math.Sqrt(MaxPixels / pixels);
        var options = new PdfPageRenderOptions
        {
            DestinationWidth = (uint)Math.Max(1, Math.Round(page.Size.Width * scale)),
            DestinationHeight = (uint)Math.Max(1, Math.Round(page.Size.Height * scale)),
            BitmapEncoderId = BitmapEncoder.JpegEncoderId,
        };
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, options).AsTask(ct);
        var bytes = new byte[stream.Size];
        stream.Seek(0);
        await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None).AsTask(ct);
        return new RenderedPage(bytes, wIn, hIn);
    }
}

public sealed class PdfOpenException(string message, bool isPasswordProtected) : Exception(message)
{
    public bool IsPasswordProtected { get; } = isPasswordProtected;
}
