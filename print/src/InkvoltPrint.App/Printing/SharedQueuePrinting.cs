using System.IO;
using System.Printing;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Raster;
using InkvoltPrint.Core.Sharing;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// A shared printer's jobs on its Windows queue (roadmap 4.10; what's taken and how is <see cref="SharedPrinter"/>'s): the document drawn
/// as pages and spooled through <see cref="QueuePrinter"/>, each fitted to the queue's paper, like Print a PDF. A PDF is drawn by Windows'
/// own PDF engine (at most <see cref="MaxPages"/> pages); a JPEG is decoded and encoded again, so only a picture this app made reaches the
/// spooler; PWG and Apple Raster are read by the core's <see cref="RasterReader"/>. Monochrome jobs are made grey here. A document that
/// can't be read is a <see cref="FormatException"/> (the phone is told the job was its document's fault).
/// </summary>
public sealed class SharedQueuePrinting : ISharedPrintSink
{
    public const int MaxPages = 200;

    /// <summary>The largest picture taken: 36 million pixels (as the raster pages).</summary>
    private const long MaxPixels = 36_000_000;

    public async Task PrintAsync(SharedPrintJob job, CancellationToken ct)
    {
        var pages = await PagesAsync(job, ct).ConfigureAwait(false);
        if (pages.Count == 0) throw new FormatException("no pages");
        ct.ThrowIfCancellationRequested();
        // From here the job belongs to the spooler (a half-written XPS job gets stuck in the queue): no more cancelling.
        await QueuePrinter.PrintPagesAsync(job.Queue, pages, job.Copies, job.TwoSided, job.JobName, PageSizing.FitToPaper).ConfigureAwait(false);
    }

    /// <summary>The document's pages as JPEG pictures with their size in inches (grey for a monochrome job).</summary>
    internal static async Task<IReadOnlyList<RenderedPage>> PagesAsync(SharedPrintJob job, CancellationToken ct)
    {
        switch (job.Format)
        {
            case "application/pdf":
            {
                PdfSource pdf;
                try
                {
                    pdf = await PdfSource.OpenAsync(Stream(job.Document), "", null).ConfigureAwait(false);
                }
                catch (PdfOpenException ex)
                {
                    throw new FormatException(ex.Message, ex);
                }
                if (pdf.PageCount is < 1 or > MaxPages) throw new FormatException($"{pdf.PageCount} pages");
                var pages = new List<RenderedPage>(pdf.PageCount);
                for (var n = 1; n <= pdf.PageCount; n++)
                {
                    ct.ThrowIfCancellationRequested();
                    var page = await pdf.RenderAsync(n, QueuePrinter.RenderDpi, ct: ct).ConfigureAwait(false);
                    pages.Add(job.Monochrome ? await StaThread.RunAsync(() => Grey(page)).ConfigureAwait(false) : page);
                }
                return pages;
            }
            case "image/jpeg":
                return [await StaThread.RunAsync(() => Picture(job.Document, job.Monochrome)).ConfigureAwait(false)];
            case "image/pwg-raster" or "image/urf":
                return await StaThread.RunAsync(() =>
                {
                    var data = job.Document;
                    var limits = new RasterLimits { MaxPages = MaxPages, MaxPixels = MaxPixels }; // the PDF's limits: no more pages through raster
                    var read = job.Format == "image/urf" ? RasterReader.ReadUrf(data, limits) : RasterReader.ReadPwg(data, limits);
                    var pages = new List<RenderedPage>();
                    foreach (var page in read)
                    {
                        ct.ThrowIfCancellationRequested();
                        pages.Add(Raster(page, job.Monochrome));
                    }
                    return (IReadOnlyList<RenderedPage>)pages;
                }).ConfigureAwait(false);
            default:
                throw new FormatException("not a document this printer takes");
        }
    }

    /// <summary>A picture decoded (its size checked first) and encoded again; its size from its resolution, 96 dpi when it names none.</summary>
    /// <summary>The document's bytes as a read-only stream over them, not a copy.</summary>
    private static MemoryStream Stream(ReadOnlyMemory<byte> data) =>
        System.Runtime.InteropServices.MemoryMarshal.TryGetArray(data, out var segment)
            ? new MemoryStream(segment.Array!, segment.Offset, segment.Count, writable: false)
            : new MemoryStream(data.ToArray(), writable: false);

    private static RenderedPage Picture(ReadOnlyMemory<byte> jpeg, bool grey)
    {
        // Its size is read from the header first (nothing decoded yet), then the pixels are decoded and encoded again, all inside the
        // try: a damaged picture is the document's fault (document-format-error), not this PC's.
        try
        {
            var frame = new JpegBitmapDecoder(Stream(jpeg), BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile,
                BitmapCacheOption.None).Frames[0];
            if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 || (long)frame.PixelWidth * frame.PixelHeight > MaxPixels) throw new FormatException("picture too large");
            var dpiX = frame.DpiX is > 1 and < 5000 ? frame.DpiX : 96;
            var dpiY = frame.DpiY is > 1 and < 5000 ? frame.DpiY : 96;
            BitmapSource source = grey ? new FormatConvertedBitmap(frame, PixelFormats.Gray8, null, 0) : frame;
            return new RenderedPage(Encode(source), frame.PixelWidth / dpiX, frame.PixelHeight / dpiY);
        }
        catch (Exception ex) when (ex is NotSupportedException or FileFormatException or ArgumentException or InvalidOperationException
                                       or System.Runtime.InteropServices.COMException or OverflowException or IOException)
        {
            throw new FormatException("not a JPEG picture", ex);
        }
    }

    private static RenderedPage Raster(RasterDocumentPage page, bool grey)
    {
        var p = page.Page;
        var format = p.Color == RasterColor.Gray8 ? PixelFormats.Gray8 : PixelFormats.Rgb24;
        BitmapSource source = BitmapSource.Create(p.Width, p.Height, page.DpiX, page.DpiY, format, null, p.Pixels, p.BytesPerLine);
        if (grey && p.Color != RasterColor.Gray8) source = new FormatConvertedBitmap(source, PixelFormats.Gray8, null, 0);
        return new RenderedPage(Encode(source), page.WidthInches, page.HeightInches);
    }

    private static RenderedPage Grey(RenderedPage page)
    {
        var frame = BitmapFrame.Create(new MemoryStream(page.Image), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return page with { Image = Encode(new FormatConvertedBitmap(frame, PixelFormats.Gray8, null, 0)) };
    }

    private static byte[] Encode(BitmapSource source)
    {
        var encoder = new JpegBitmapEncoder { QualityLevel = 90 };
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    /// <summary>
    /// What a queue offers phones (roadmap 4.10): color and long-edge two-sided from its capabilities, its default paper; null for a queue
    /// that can't be read (removed, its driver failing). Read on a thread of its own: a driver can take its time.
    /// </summary>
    public static async Task<SharedQueue?> DescribeAsync(string queue, CancellationToken ct)
    {
        try
        {
            return await StaThread.RunAsync(() =>
            {
                using var server = new LocalPrintServer();
                using var q = new PrintQueue(server, queue);
                var caps = q.GetPrintCapabilities();
                var color = caps.OutputColorCapability.Contains(OutputColor.Color);
                var duplex = caps.DuplexingCapability.Contains(Duplexing.TwoSidedLongEdge);
                var media = SharedPrinterMedia.FromWindows(q.DefaultPrintTicket?.PageMediaSize?.PageMediaSizeName?.ToString());
                return (SharedQueue?)new SharedQueue(queue, color, duplex, media);
            }).WaitAsync(TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is PrintSystemException or TimeoutException or InvalidOperationException)
        {
            Log.Write($"Printer sharing: a queue couldn't be read: {ex.GetType().Name}");
            return null;
        }
    }
}
