using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App;

/// <summary>
/// <c>InkvoltPrint.exe --demo</c>: one made-up printer for screenshots and trying the app without a printer. Its web
/// server is a <see cref="FixtureHandler"/> over the scrubbed test fixtures (embedded from
/// <c>tests/InkvoltPrint.Tests/Fixtures/m234dw</c>) at <see cref="FixtureHandler.DemoHost"/>. Demo mode makes no network
/// access: no discovery, no probes, no Windows print queue, no HP software check; state lives in memory only
/// (the remembered-printers file is neither read nor written). Scanning returns generated pages in turn: a straight page,
/// the same page fed a little crooked, a blank sheet (for the scan review's Straighten and Skip blank pages); a made-up
/// ID card for card-sized regions; the print queue card shows <see cref="DemoPrintJobs"/>, where copies also "print".
/// </summary>
internal static class Demo
{
    private const string Uuid = "12345678-1234-4abc-8def-123456789abc"; // the fixtures' (fake) UUID
    private const string ResourcePrefix = "Demo.";

    public static AppState CreateState() => new()
    {
        IsInMemory = true,
        Printers = [new KnownPrinter(Uuid, "Demo printer", null, FixtureHandler.DemoHost, $"http://{FixtureHandler.DemoHost}/eSCL/")],
        SelectedUuid = Uuid,
    };

    public static HttpMessageHandler CreateTransport() => new FixtureHandler(Document, scanArea: Scan);

    // WPF drawing needs the UI thread; the handler runs wherever the scan's awaits continue.
    private static readonly Lazy<byte[]>[] Pages =
        [new(() => Application.Current.Dispatcher.Invoke(() => ScanPage(0))), new(() => Application.Current.Dispatcher.Invoke(() => ScanPage(2.5))),
            new(() => Application.Current.Dispatcher.Invoke(BlankSheet))];

    private static int _cardSide, _page = -1;

    /// <summary>A page for page-sized regions; for a small region (ID card copy), a made-up card, front and back in turn.</summary>
    private static byte[] Scan(int width, int height) =>
        width <= 1800 && height <= 1500
            ? Application.Current.Dispatcher.Invoke(() => ScanCard(width, height, back: Interlocked.Increment(ref _cardSide) % 2 == 0))
            : Pages[Interlocked.Increment(ref _page) % Pages.Length].Value;

    private static byte[]? Document(string name)
    {
        using var s = typeof(Demo).Assembly.GetManifestResourceStream(ResourcePrefix + name);
        if (s is null) return null;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>The demo printer's made-up Windows queue (one demo printer, so one queue).</summary>
    public static DemoPrintJobs PrintJobs { get; } = new();

    /// <summary>
    /// A synthetic letter-size page at 300 dpi: a heading, grey text bars and a picture box, turned <paramref name="skew"/>
    /// degrees clockwise as if fed crooked. Never a real scan.
    /// </summary>
    private static byte[] ScanPage(double skew)
    {
        const int w = 1275, h = 1650; // drawn at 150 dpi, rendered at 300
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(2, 2));
            dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, w, h));
            dc.PushTransform(new RotateTransform(skew, w / 2.0, h / 2.0));
            var ink = new SolidColorBrush(Color.FromRgb(0x30, 0x34, 0x3A));
            var grey = new SolidColorBrush(Color.FromRgb(0xC4, 0xC8, 0xCE));
            dc.DrawRoundedRectangle(ink, null, new Rect(150, 160, 620, 46), 6, 6);
            dc.DrawRoundedRectangle(grey, null, new Rect(150, 230, 380, 22), 4, 4);
            var y = 330.0;
            for (var i = 0; i < 20; i++, y += 44)
            {
                if (i == 9) { dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0xE3, 0xE8, 0xEF)), null, new Rect(150, y, 975, 300)); y += 340; }
                var len = i % 7 == 6 ? 520 : 975 - (i * 37 % 90);
                dc.DrawRoundedRectangle(grey, null, new Rect(150, y, len, 18), 4, 4);
            }
        }
        return Jpeg(visual, w * 2, h * 2);
    }

    /// <summary>The back of a one-sided sheet: white paper, a few specks of dust and a grey feeder edge.</summary>
    private static byte[] BlankSheet()
    {
        const int w = 1275, h = 1650;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(2, 2));
            dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0xF6, 0xF5, 0xF2)), null, new Rect(0, 0, w, h));
            dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0xB8, 0xB8, 0xB8)), null, new Rect(0, 0, w, 6));
            foreach (var (x, y) in new[] { (310.0, 420.0), (880, 1210), (640, 760) })
                dc.DrawEllipse(Brushes.Gray, null, new Point(x, y), 0.6, 0.6);
        }
        return Jpeg(visual, w * 2, h * 2);
    }

    /// <summary>
    /// A made-up ID card (ID-1 size, 3.37 × 2.13 in at 300 dpi) in the corner of a <paramref name="width"/> ×
    /// <paramref name="height"/> pixel scan: photo box and text bars on the front, a stripe and lines on the back.
    /// </summary>
    private static byte[] ScanCard(int width, int height, bool back)
    {
        const double cw = 1011, ch = 638, x = 30, y = 30;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, width, height));
            var card = new SolidColorBrush(Color.FromRgb(0xE4, 0xEC, 0xF6));
            var ink = new SolidColorBrush(Color.FromRgb(0x30, 0x34, 0x3A));
            var grey = new SolidColorBrush(Color.FromRgb(0xA9, 0xB2, 0xBE));
            dc.DrawRoundedRectangle(card, new Pen(grey, 3), new Rect(x, y, cw, ch), 38, 38);
            if (!back)
            {
                dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(0x2B, 0x5C, 0x9E)), null, new Rect(x, y + 40, cw, 70), 0, 0);
                dc.DrawRoundedRectangle(grey, null, new Rect(x + 50, y + 160, 250, 320), 14, 14);
                for (var i = 0; i < 5; i++)
                    dc.DrawRoundedRectangle(i == 0 ? ink : grey, null, new Rect(x + 350, y + 175 + i * 64, i == 0 ? 460 : 560 - i * 50, i == 0 ? 34 : 24), 8, 8);
                dc.DrawRoundedRectangle(ink, null, new Rect(x + 350, y + 520, 300, 40), 6, 6);
            }
            else
            {
                dc.DrawRectangle(ink, null, new Rect(x, y + 70, cw, 120));
                for (var i = 0; i < 6; i++)
                    dc.DrawRoundedRectangle(grey, null, new Rect(x + 60, y + 250 + i * 52, 880 - i * 70, 22), 6, 6);
            }
        }
        return Jpeg(visual, width, height);
    }

    private static byte[] Jpeg(Visual visual, int pixelWidth, int pixelHeight)
    {
        var bmp = new RenderTargetBitmap(pixelWidth, pixelHeight, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        var enc = new JpegBitmapEncoder { QualityLevel = 85 };
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var outStream = new MemoryStream();
        enc.Save(outStream);
        return outStream.ToArray();
    }
}

/// <summary>
/// A pretend print queue: a few jobs, one of them someone else's (so Cancel is refused like Windows would), and the
/// first job printing a page each time the list is read. Finished jobs leave the queue, so it empties after a while.
/// </summary>
internal sealed class DemoPrintJobs : IPrintJobs
{
    private readonly object _lock = new();
    private readonly List<QueueJob> _jobs;
    private int _nextId = 14;

    public DemoPrintJobs()
    {
        var now = DateTime.Now;
        var me = Environment.UserName;
        _jobs =
        [
            new(11, "Quarterly report.pdf", 12, 3, JobStatus.Printing, now.AddMinutes(-2), me),
            new(12, "Shipping label.pdf", 1, 0, JobStatus.None, now.AddMinutes(-1), me),
            new(13, "Team schedule.docx", 2, 0, JobStatus.None, now.AddSeconds(-40), "alex"),
        ];
    }

    /// <summary>A job "printed" by the demo printer (copies, the Copy tab), queued behind the others.</summary>
    public void Add(string name, int pages)
    {
        lock (_lock) _jobs.Add(new(_nextId++, name, pages, 0, JobStatus.None, DateTime.Now, Environment.UserName));
    }

    public Task<IReadOnlyList<QueueJob>?> ListAsync()
    {
        lock (_lock)
        {
            if (_jobs.Count > 0)
            {
                var first = _jobs[0];
                var printed = first.Status.HasFlag(JobStatus.Printing) ? first.PagesPrinted + 1 : 0;
                if (printed >= first.Pages) _jobs.RemoveAt(0);
                else _jobs[0] = first with { Status = JobStatus.Printing, PagesPrinted = printed };
            }
            return Task.FromResult<IReadOnlyList<QueueJob>?>(_jobs.ToList());
        }
    }

    public Task CancelAsync(int jobId)
    {
        lock (_lock)
        {
            var job = _jobs.FirstOrDefault(j => j.Id == jobId) ?? throw new PrintJobCancelException("The job couldn't be cancelled. It may have just finished.", false);
            if (!QueueJobText.IsOwner(job.Owner, Environment.UserName))
                throw new PrintJobCancelException("Windows didn't allow it: only the person who printed it, or an administrator, can cancel it.", true);
            _jobs.Remove(job);
        }
        return Task.CompletedTask;
    }
}
