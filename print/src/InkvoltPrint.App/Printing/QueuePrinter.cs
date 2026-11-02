using System.IO;
using System.Printing;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.Printing;

public sealed record PrintOptions(IReadOnlyList<int> Pages, int Copies, bool TwoSided, string JobName, PageSizing Sizing = PageSizing.ActualSize);

/// <summary>
/// Prints rendered PDF pages, and scanned pages for copies, to a Windows print queue (for IPP printers: the Microsoft IPP Class Driver,
/// which converts to whatever the printer speaks — PCLm/PWG raster for the M234dw). Each page is
/// auto-rotated to match the paper's orientation and sized per <see cref="PageSizing"/>, keeping its proportions.
/// </summary>
public static class QueuePrinter
{
    public const int RenderDpi = 300;

    public static PrintQueue Open(string queueName) => new(new LocalPrintServer(), queueName);

    /// <summary>
    /// The installed queue whose port is this host: "192.0.2.10", "IP_192.0.2.10" (Standard TCP/IP) or
    /// "http://192.0.2.10:631/ipp/print" (IPP). The host has to stand alone, so 192.0.2.1 doesn't match 192.0.2.10.
    /// </summary>
    public static string? FindByHost(string host)
    {
        try
        {
            using var server = new LocalPrintServer();
            foreach (var queue in server.GetPrintQueues([EnumeratedPrintQueueTypes.Local]))
                using (queue)
                {
                    try { if (queue.QueuePort?.Name is { } port && PortIsHost(port, host)) return queue.Name; }
                    catch (PrintSystemException) { } // a queue being deleted; skip it
                }
        }
        catch (PrintSystemException ex)
        {
            System.Diagnostics.Trace.WriteLine($"queue ports: {ex.Message}");
        }
        return null;
    }

    public static bool PortIsHost(string port, string host) =>
        Regex.IsMatch(port, $@"(?<![A-Za-z0-9.-]){Regex.Escape(host)}(?![A-Za-z0-9-]|\.[A-Za-z0-9])", RegexOptions.IgnoreCase);

    public static bool SupportsTwoSided(PrintQueue queue)
    {
        try { return queue.GetPrintCapabilities().DuplexingCapability.Contains(Duplexing.TwoSidedLongEdge); }
        catch (PrintQueueException) { return false; }
    }

    /// <summary>
    /// Renders the selected pages, then spools them as one job. The XPS write runs synchronously on its own
    /// STA thread with its own queue objects: the async XpsDocumentWriter path can stall the spooler with
    /// an empty job, and a synchronous write on the UI thread would freeze the window.
    /// </summary>
    public static async Task PrintAsync(string queueName, PdfSource pdf, PrintOptions options, IProgress<string> progress, CancellationToken ct,
        Action? onSpooling = null)
    {
        // 1. Render: JPEG at 300 dpi is ~0.3-1 MB a page.
        var pages = new List<RenderedPage>(options.Pages.Count);
        for (var i = 0; i < options.Pages.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            progress.Report($"Preparing page {i + 1} of {options.Pages.Count}…");
            pages.Add(await pdf.RenderAsync(options.Pages[i], RenderDpi, ct: ct));
        }
        ct.ThrowIfCancellationRequested();
        // From here the job belongs to the spooler: aborting a half-written XPS job leaves it stuck in the queue.
        onSpooling?.Invoke();
        progress.Report($"Sending {(pages.Count == 1 ? "the page" : $"{pages.Count} pages")} to the printer…");
        await SpoolAsync(queueName, options.Copies, options.TwoSided, options.JobName, (paper, images) => new RenderedPaginator(pages, paper, options.Sizing, images));
    }

    /// <summary>Copies: scanned pages, each centred on its own sheet at actual size (larger pages shrink to fit) or fit to the paper.</summary>
    public static Task PrintPagesAsync(string queueName, IReadOnlyList<RenderedPage> pages, int copies, bool twoSided, string jobName,
        PageSizing sizing = PageSizing.ActualSize) =>
        SpoolAsync(queueName, copies, twoSided, jobName, (paper, images) => new RenderedPaginator(pages, paper, sizing, images));

    /// <summary>A batch's file: pages already drawn, on the ticket <paramref name="makeTicket"/> validated.</summary>
    internal static Task PrintPagesAsync(string queueName, IReadOnlyList<RenderedPage> pages, string jobName, PageSizing sizing, Func<PrintQueue, PrintTicket> makeTicket) =>
        SpoolAsync(queueName, jobName, makeTicket, (_, _, paper, images) => new RenderedPaginator(pages, paper, sizing, images));

    /// <summary>ID card copy: front on the top half of one sheet, back on the bottom half, actual size (<see cref="CopyLayout.IdCard"/>).</summary>
    public static Task PrintIdCardAsync(string queueName, RenderedPage front, RenderedPage back, int copies, string jobName) =>
        SpoolAsync(queueName, copies, twoSided: false, jobName, (paper, images) => new IdCardPaginator(front, back, paper, images));

    /// <summary>
    /// Ticket + spool on a dedicated STA thread. The paginator is made there too, once the validated ticket says
    /// which paper the queue will use.
    /// </summary>
    private static Task SpoolAsync(string queueName, int copies, bool twoSided, string jobName, Func<Size, PrintImages, DocumentPaginator> paginator) =>
        SpoolAsync(queueName, jobName, queue =>
        {
            var ticket = queue.DefaultPrintTicket.Clone();
            ticket.CopyCount = copies;
            ticket.Collation = Collation.Collated;
            ticket.Duplexing = twoSided ? Duplexing.TwoSidedLongEdge : Duplexing.OneSided;
            ticket.PageOrientation = PageOrientation.Portrait;
            return queue.MergeAndValidatePrintTicket(queue.DefaultPrintTicket, ticket).ValidatedPrintTicket;
        }, (_, _, paper, images) => paginator(paper, images));

    /// <summary>
    /// Spools one job on a dedicated STA thread with its own queue objects: <paramref name="makeTicket"/> returns the
    /// validated ticket, then <paramref name="paginator"/> lays the pages out on the paper it names (DIPs), with its pictures
    /// in <see cref="PrintImages"/> (removed once the job is written).
    /// </summary>
    internal static async Task SpoolAsync(string queueName, string jobName, Func<PrintQueue, PrintTicket> makeTicket,
        Func<PrintQueue, PrintTicket, Size, PrintImages, DocumentPaginator> paginator)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                using var server = new LocalPrintServer();
                using var queue = new PrintQueue(server, queueName);
                using var images = new PrintImages();
                var ticket = makeTicket(queue);
                var paper = new Size(ticket.PageMediaSize?.Width ?? 816, ticket.PageMediaSize?.Height ?? 1056); // DIPs; Letter fallback

                queue.CurrentJobSettings.Description = jobName;
                var writer = PrintQueue.CreateXpsDocumentWriter(queue);
                writer.Write(paginator(queue, ticket, paper, images), ticket);
                done.SetResult();
            }
            catch (Exception ex)
            {
                System.Diagnostics.Trace.WriteLine($"spool: FAILED {ex}");
                done.SetException(ex);
            }
        })
        { IsBackground = true, Name = "Inkvolt Print spool" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await done.Task;
    }

    private sealed class RenderedPaginator(IReadOnlyList<RenderedPage> pages, Size paper, PageSizing sizing, PrintImages images) : DocumentPaginator
    {
        public override bool IsPageCountValid => true;
        public override int PageCount => pages.Count;
        public override Size PageSize { get => paper; set { } }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber)
        {
            var src = pages[pageNumber];
            var bitmap = images.Jpeg(src.Image);

            // Landscape page on portrait paper: rotate rather than shrink it (the copy preview places it the same way).
            var (at, rotate) = PageFit.Place(src.WidthInches * 96, src.HeightInches * 96, paper.Width, paper.Height, sizing);

            var image = new Image
            {
                Source = bitmap,
                Stretch = Stretch.Fill,
                Width = rotate ? at.Height : at.Width,
                Height = rotate ? at.Width : at.Height,
                LayoutTransform = rotate ? new RotateTransform(90) : Transform.Identity,
            };
            // A Canvas, not a FixedPage: the XPS serializer wraps each page visual in its own FixedPage.
            var page = new Canvas { Width = paper.Width, Height = paper.Height, Background = Brushes.White };
            Canvas.SetLeft(image, at.X);
            Canvas.SetTop(image, at.Y);
            page.Children.Add(image);
            return Finish(page, paper);
        }
    }

    /// <summary>One sheet: the card's front on the top half, its back on the bottom half.</summary>
    private sealed class IdCardPaginator(RenderedPage front, RenderedPage back, Size paper, PrintImages images) : DocumentPaginator
    {
        public override bool IsPageCountValid => true;
        public override int PageCount => 1;
        public override Size PageSize { get => paper; set { } }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber)
        {
            var (top, bottom) = CopyLayout.IdCard(paper.Width, paper.Height,
                (front.WidthInches * 96, front.HeightInches * 96), (back.WidthInches * 96, back.HeightInches * 96));
            var page = new Canvas { Width = paper.Width, Height = paper.Height, Background = Brushes.White };
            foreach (var (side, at) in new[] { (front, top), (back, bottom) })
            {
                var image = new Image { Source = images.Jpeg(side.Image), Stretch = Stretch.Fill, Width = at.Width, Height = at.Height };
                Canvas.SetLeft(image, at.X);
                Canvas.SetTop(image, at.Y);
                page.Children.Add(image);
            }
            return Finish(page, paper);
        }
    }

    private static DocumentPage Finish(Canvas page, Size paper)
    {
        page.Measure(paper);
        page.Arrange(new Rect(paper));
        page.UpdateLayout();
        return new DocumentPage(page, paper, new Rect(paper), new Rect(paper));
    }

    /// <summary>A JPEG for the screen (thumbnails, previews), optionally decoded smaller.</summary>
    public static BitmapImage Decode(byte[] image, int decodeWidth = 0)
    {
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        if (decodeWidth > 0) bitmap.DecodePixelWidth = decodeWidth;
        bitmap.StreamSource = new MemoryStream(image);
        bitmap.EndInit();
        bitmap.Freeze();
        return bitmap;
    }
}
