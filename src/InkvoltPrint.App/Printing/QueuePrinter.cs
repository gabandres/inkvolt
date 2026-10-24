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
/// Prints rendered PDF pages to a Windows print queue (for IPP printers: the Microsoft IPP Class Driver,
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

        // 2. Ticket + spool on a dedicated STA thread.
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                using var server = new LocalPrintServer();
                using var queue = new PrintQueue(server, queueName);
                var ticket = queue.DefaultPrintTicket.Clone();
                ticket.CopyCount = options.Copies;
                ticket.Collation = Collation.Collated;
                ticket.Duplexing = options.TwoSided ? Duplexing.TwoSidedLongEdge : Duplexing.OneSided;
                ticket.PageOrientation = PageOrientation.Portrait;
                ticket = queue.MergeAndValidatePrintTicket(queue.DefaultPrintTicket, ticket).ValidatedPrintTicket;
                var paper = new Size(ticket.PageMediaSize?.Width ?? 816, ticket.PageMediaSize?.Height ?? 1056); // DIPs; Letter fallback

                queue.CurrentJobSettings.Description = options.JobName;
                var writer = PrintQueue.CreateXpsDocumentWriter(queue);
                writer.Write(new RenderedPaginator(pages, paper, options.Sizing), ticket);
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

    private sealed class RenderedPaginator(IReadOnlyList<RenderedPage> pages, Size paper, PageSizing sizing) : DocumentPaginator
    {
        public override bool IsPageCountValid => true;
        public override int PageCount => pages.Count;
        public override Size PageSize { get => paper; set { } }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber)
        {
            var src = pages[pageNumber];
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = new MemoryStream(src.Image);
            bitmap.EndInit();
            bitmap.Freeze();

            // Landscape page on portrait paper: rotate rather than shrink it.
            var landscapePage = src.WidthInches > src.HeightInches;
            var rotate = landscapePage != (paper.Width > paper.Height);
            var pageW = (rotate ? src.HeightInches : src.WidthInches) * 96;
            var pageH = (rotate ? src.WidthInches : src.HeightInches) * 96;
            var scale = PageFit.Scale(pageW, pageH, paper.Width, paper.Height, sizing);
            var w = pageW * scale;
            var h = pageH * scale;

            var image = new Image
            {
                Source = bitmap,
                Stretch = Stretch.Fill,
                Width = rotate ? h : w,
                Height = rotate ? w : h,
                LayoutTransform = rotate ? new RotateTransform(90) : Transform.Identity,
            };
            // A Canvas, not a FixedPage: the XPS serializer wraps each page visual in its own FixedPage.
            var page = new Canvas { Width = paper.Width, Height = paper.Height, Background = Brushes.White };
            Canvas.SetLeft(image, (paper.Width - w) / 2);
            Canvas.SetTop(image, (paper.Height - h) / 2);
            page.Children.Add(image);
            page.Measure(paper);
            page.Arrange(new Rect(paper));
            page.UpdateLayout();
            return new DocumentPage(page, paper, new Rect(paper), new Rect(paper));
        }
    }
}
