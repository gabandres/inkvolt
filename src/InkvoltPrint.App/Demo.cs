using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App;

/// <summary>
/// <c>InkvoltPrint.exe --demo</c>: made-up printers for screenshots and trying the app without a printer. The HP laser's
/// web server is a <see cref="FixtureHandler"/> over the scrubbed test fixtures (embedded from
/// <c>tests/InkvoltPrint.Tests/Fixtures/m234dw</c>) at <see cref="FixtureHandler.DemoHost"/>; the inkjet (an Epson-style
/// IPP Everywhere / eSCL printer with no HP interfaces) answers IPP and eSCL from <c>Fixtures/inkjet-demo</c>, written from
/// the public specs, at <see cref="InkjetHost"/>. A <see cref="HostRouter"/> sends each request to its printer. Demo mode makes no network
/// access: no discovery, no probes, no Windows print queue, no HP software check; state lives in memory only
/// (the remembered-printers file is neither read nor written). Scanning returns generated pages in turn: a straight page,
/// the same page fed a little crooked, a blank sheet (for the scan review's Straighten and Skip blank pages); a made-up
/// ID card for card-sized regions; the print queue card shows <see cref="DemoPrintJobs"/> (one made-up queue for both
/// printers), where copies also "print". A third printer, the "Demo office laser", shows the offline fixer: it's remembered
/// at <see cref="OfficeOldHost"/>, where nothing answers, while the made-up network (<see cref="OfflinePc"/>) finds it at
/// <see cref="OfficeNewHost"/> and its made-up Windows queue still prints to the old address with "Use Printer Offline" on.
/// </summary>
internal static class Demo
{
    private const string Uuid = "12345678-1234-4abc-8def-123456789abc"; // the fixtures' (fake) UUID
    private const string InkjetUuid = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"; // Fixtures/inkjet-demo (made up)
    private const string OfficeUuid = "3c9a7e51-8d2b-4f60-a1e4-5b7c9d0e2f13"; // made up
    private const string ResourcePrefix = "Demo.", InkjetPrefix = "DemoInkjet.";

    /// <summary>The demo office laser's address before the (made-up) router gave it a new one, and after.</summary>
    public const string OfficeOldHost = "192.0.2.12", OfficeNewHost = "192.0.2.23";

    /// <summary>The demo inkjet's address: RFC 5737 documentation range, like <see cref="FixtureHandler.DemoHost"/>.</summary>
    public const string InkjetHost = "192.0.2.11";

    public static AppState CreateState() => new()
    {
        IsInMemory = true,
        Printers =
        [
            new KnownPrinter(Uuid, "Demo printer", null, FixtureHandler.DemoHost, $"http://{FixtureHandler.DemoHost}/eSCL/"),
            new KnownPrinter(InkjetUuid, "Demo inkjet", null, InkjetHost, $"http://{InkjetHost}/eSCL/", $"http://{InkjetHost}:631/ipp/print"),
            new KnownPrinter(OfficeUuid, "Demo office laser", null, OfficeOldHost, $"http://{OfficeOldHost}/eSCL/"),
        ],
        SelectedUuid = Uuid,
    };

    public static HttpMessageHandler CreateTransport() => new HostRouter(new Dictionary<string, HttpMessageHandler>
    {
        [FixtureHandler.DemoHost] = new FixtureHandler(name => Document(ResourcePrefix + name), scanArea: Scan),
        [InkjetHost] = new FixtureHandler(name => Document(InkjetPrefix + name), scanArea: Scan),
        // The office laser answers only at its new address: the HP fixtures under its own name and UUID.
        [OfficeNewHost] = new FixtureHandler(name => OfficeDocument(ResourcePrefix + name), scanArea: Scan),
    });

    private static byte[]? OfficeDocument(string resource) => Document(resource) is not { } bytes ? null
        : resource.EndsWith("ProductConfigDyn.xml", StringComparison.Ordinal) || resource.EndsWith("ScannerCapabilities.xml", StringComparison.Ordinal)
            ? System.Text.Encoding.UTF8.GetBytes(System.Text.Encoding.UTF8.GetString(bytes)
                .Replace("HP LaserJet MFP M234dw", "Demo office laser").Replace(Uuid, OfficeUuid))
            : bytes;

    /// <summary>The made-up PC and network the demo printers' offline fixer looks at and repairs.</summary>
    public static DemoOfflinePc OfflinePc { get; } = new([(Uuid, FixtureHandler.DemoHost), (InkjetUuid, InkjetHost)], OfficeUuid);

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

    private static byte[]? Document(string resource)
    {
        using var s = typeof(Demo).Assembly.GetManifestResourceStream(resource);
        if (s is null) return null;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>The demo printers' made-up Windows queue (shared: nothing is printed anyway).</summary>
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

    /// <summary>
    /// The demo printers' photo options: the inkjet takes photo paper in color and prints borderless on everything but Legal;
    /// the lasers take plain paper and labels, in black, with margins. Jobs "print" to <see cref="PrintJobs"/>.
    /// </summary>
    public static ViewModels.DemoPhotoQueue PhotoQueue(string uuid)
    {
        static PaperChoice Paper(string key, double w, double h) => new(key, Core.Photos.PhotoPaperText.Paper(key, w, h), w, h, null);
        static List<ViewModels.Option<string>> Names(Func<string, string> label, params string[] names) =>
            [.. names.Select(n => new ViewModels.Option<string>(n, label(n)))];
        var inkjet = uuid == InkjetUuid;
        var papers = inkjet
            ? new[] { Paper("NorthAmericaLetter", 8.5, 11), Paper("ISOA4", 8.27, 11.69), Paper("NorthAmerica4x6", 4, 6), Paper("NorthAmerica5x7", 5, 7),
                Paper("NorthAmerica8x10", 8, 10), Paper("NorthAmericaLegal", 8.5, 14) }
            : [Paper("NorthAmericaLetter", 8.5, 11), Paper("NorthAmericaLegal", 8.5, 14), Paper("ISOA4", 8.27, 11.69), Paper("ISOA5", 5.83, 8.27)];
        var options = inkjet
            ? new PhotoQueueOptions(papers, "NorthAmericaLetter",
                Names(Core.Photos.PhotoPaperText.MediaType, "Plain", "Photographic", "PhotographicGlossy", "PhotographicSemiGloss", "PhotographicMatte"), "Plain",
                Names(Core.Photos.PhotoPaperText.Quality, "Draft", "Normal", "High", "Photographic"), "Normal",
                Names(Core.Photos.PhotoPaperText.Color, "Color", "Grayscale"), "Color")
            : new PhotoQueueOptions(papers, "NorthAmericaLetter",
                Names(Core.Photos.PhotoPaperText.MediaType, "Plain", "Label", "CardStock", "Transparency"), "Plain",
                Names(Core.Photos.PhotoPaperText.Quality, "Draft", "Normal"), "Normal",
                Names(Core.Photos.PhotoPaperText.Color, "Monochrome"), "Monochrome");
        var margin = inkjet ? 0.125 : 1 / 6.0;
        return new ViewModels.DemoPhotoQueue(options,
            paper => new PaperSetup(inkjet && paper.Key != "NorthAmericaLegal",
                new Core.Photos.SheetPaper(paper.WidthIn, paper.HeightIn, margin, margin, margin, margin)),
            PrintJobs.Add);
    }

    /// <summary>
    /// Sample pictures for the Photos tab, drawn here (no photos ship with the app) and saved under %TEMP%: a landscape JPEG,
    /// a portrait JPEG stored on its side with EXIF orientation 6 (it must show upright), a PNG, a two-page TIFF and a small
    /// BMP that prints soft.
    /// </summary>
    public static IReadOnlyList<string> SamplePhotos()
    {
        var folder = Path.Combine(Path.GetTempPath(), "Inkvolt Print demo photos");
        Directory.CreateDirectory(folder);
        // Written once and reused; several demo copies at once (snapshots) each write a temporary file and the first one wins.
        string Save(string name, BitmapEncoder encoder)
        {
            var path = Path.Combine(folder, name);
            if (File.Exists(path)) return path;
            var temp = Path.Combine(folder, $"{Guid.NewGuid():N}.tmp");
            using (var fs = File.Create(temp)) encoder.Save(fs);
            try { File.Move(temp, path); }
            catch (IOException) { File.Delete(temp); }
            return path;
        }
        var lake = Scene(3000, 2000, Color.FromRgb(0xF6, 0x9A, 0x5B), Color.FromRgb(0x5B, 0x3E, 0x8C), Color.FromRgb(0x2E, 0x4A, 0x6B), "Lake");
        var park = Scene(1800, 2400, Color.FromRgb(0xA8, 0xD8, 0xF0), Color.FromRgb(0x4A, 0x90, 0xC8), Color.FromRgb(0x4E, 0x8A, 0x3C), "Park");
        var beach = Scene(2400, 1600, Color.FromRgb(0x9E, 0xE0, 0xF5), Color.FromRgb(0x2D, 0x9C, 0xDB), Color.FromRgb(0xE8, 0xD3, 0x9A), "Beach");
        var hills = Scene(2000, 1400, Color.FromRgb(0xFF, 0xE0, 0xA8), Color.FromRgb(0xE0, 0x7A, 0x5F), Color.FromRgb(0x6B, 0x8E, 0x4E), "Hills");
        var snow = Scene(1400, 2000, Color.FromRgb(0xDD, 0xE6, 0xF0), Color.FromRgb(0x8A, 0xA4, 0xC0), Color.FromRgb(0xF4, 0xF6, 0xF8), "Snow");
        var small = Scene(320, 240, Color.FromRgb(0xC9, 0xE4, 0xCA), Color.FromRgb(0x55, 0x82, 0x5A), Color.FromRgb(0x2F, 0x4F, 0x2F), "Small");

        var paths = new List<string>();
        var jpeg = new JpegBitmapEncoder { QualityLevel = 88 };
        jpeg.Frames.Add(BitmapFrame.Create(lake));
        paths.Add(Save("Lake at sunset.jpg", jpeg));

        // Stored a quarter turn left, tagged "turn 90° clockwise to view".
        var sideways = new TransformedBitmap(park, new RotateTransform(-90));
        var meta = new BitmapMetadata("jpg");
        try { meta.SetQuery("/app1/ifd/{ushort=274}", (ushort)6); }
        catch (Exception ex) when (ex is NotSupportedException or InvalidOperationException or ArgumentException) { Log.Write($"Demo EXIF: {ex.Message}"); }
        var tagged = new JpegBitmapEncoder { QualityLevel = 88 };
        tagged.Frames.Add(BitmapFrame.Create(sideways, null, meta, null));
        paths.Add(Save("Walk in the park.jpg", tagged));

        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(beach));
        paths.Add(Save("Beach.png", png));

        var tiff = new TiffBitmapEncoder { Compression = TiffCompressOption.Lzw };
        tiff.Frames.Add(BitmapFrame.Create(hills));
        tiff.Frames.Add(BitmapFrame.Create(snow));
        paths.Add(Save("Two pages.tif", tiff));

        var bmp = new BmpBitmapEncoder();
        bmp.Frames.Add(BitmapFrame.Create(small));
        paths.Add(Save("Small picture.bmp", bmp));
        return paths;
    }

    /// <summary>A made-up landscape: sky gradient, sun, two mountain ridges, ground, and the label top-left (which side is up).</summary>
    private static BitmapSource Scene(int w, int h, Color skyTop, Color skyBottom, Color ground, string label)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(new LinearGradientBrush(skyTop, skyBottom, 90), null, new Rect(0, 0, w, h));
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(0xFF, 0xF1, 0xB8)), null, new Point(w * 0.72, h * 0.3), Math.Min(w, h) * 0.09, Math.Min(w, h) * 0.09);
            Geometry Ridge(double baseY, double[] peaks)
            {
                var g = new StreamGeometry();
                using (var ctx = g.Open())
                {
                    ctx.BeginFigure(new Point(0, h), true, true);
                    for (var i = 0; i < peaks.Length; i++) ctx.LineTo(new Point(w * i / (peaks.Length - 1.0), h * (baseY - peaks[i])), true, false);
                    ctx.LineTo(new Point(w, h), true, false);
                }
                g.Freeze();
                return g;
            }
            dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(0xC0, 0x3A, 0x3F, 0x5C)), null, Ridge(0.62, [0.05, 0.22, 0.1, 0.3, 0.12, 0.2, 0.04]));
            dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(0xE0, 0x2C, 0x33, 0x40)), null, Ridge(0.72, [0.02, 0.1, 0.16, 0.06, 0.14, 0.03]));
            dc.DrawRectangle(new SolidColorBrush(ground), null, new Rect(0, h * 0.74, w, h * 0.26));
            var size = Math.Max(12, Math.Min(w, h) * 0.07);
            dc.DrawText(new FormattedText($"↑ {label}", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI Semibold"), size, Brushes.White, 1), new Point(size * 0.6, size * 0.5));
        }
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        return bmp;
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
