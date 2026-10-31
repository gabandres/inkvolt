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
/// ID card for card-sized regions; a batch with a Patch T separator sheet and a blank page from the feeder when the scan
/// splits into files (<see cref="FeederBatch"/>); the print queue card shows <see cref="DemoPrintJobs"/> (one made-up queue for both
/// printers), where copies also "print". A third printer, the "Demo office laser", shows the offline fixer: it's remembered
/// at <see cref="OfficeOldHost"/>, where nothing answers, while the made-up network (<see cref="OfflinePc"/>) finds it at
/// <see cref="OfficeNewHost"/> and its made-up Windows queue still prints to the old address with "Use Printer Offline" on.
/// A fourth, at <see cref="CdmHost"/>, is a newer HP color laser that answers HP's CDM only (<c>Fixtures/cdm-laser</c>, JSON
/// written from public sources): status, toner and details without LEDM. A fifth, at <see cref="SnmpHost"/>, answers SNMP only
/// (no IPP, LEDM or CDM): status, alerts and toner from the Printer MIB of a made-up agent (<see cref="Snmp"/>,
/// <c>Fixtures/snmp-demo</c>). Three more come from the made-up PC's Windows queues (<see cref="Queues"/>): a USB laser and a
/// printer shared from another PC, with status as Windows and the driver report it, and a color MFP on a TCP/IP port at
/// <see cref="SnmpQueueHost"/>, whose status and toner come from the printer over SNMP.
/// </summary>
internal static class Demo
{
    private const string Uuid = Core.Fleet.DemoFleet.LaserUuid, InkjetUuid = Core.Fleet.DemoFleet.InkjetUuid, OfficeUuid = Core.Fleet.DemoFleet.OfficeUuid;
    private const string ResourcePrefix = "Demo.", InkjetPrefix = "DemoInkjet.", CdmPrefix = "DemoCdm.";

    /// <summary>The demo HP color laser that speaks CDM, not LEDM (newer HP models).</summary>
    public const string CdmHost = Core.Fleet.DemoFleet.CdmHost;

    /// <summary>The demo office laser's address before the (made-up) router gave it a new one, and after.</summary>
    public const string OfficeOldHost = Core.Fleet.DemoFleet.OfficeOldHost, OfficeNewHost = Core.Fleet.DemoFleet.OfficeNewHost;

    /// <summary>The demo printer that answers SNMP only, and the demo color MFP behind a Windows TCP/IP port.</summary>
    public const string SnmpHost = Core.Fleet.DemoFleet.SnmpHost, SnmpQueueHost = Core.Fleet.DemoFleet.SnmpQueueHost;

    /// <summary>A demo laser on the network that isn't listed: only Add a printer's Search my network finds it (SNMP only).</summary>
    public const string UnlistedHost = "192.0.2.16";

    /// <summary>The demo inkjet's address: RFC 5737 documentation range, like <see cref="FixtureHandler.DemoHost"/>.</summary>
    public const string InkjetHost = Core.Fleet.DemoFleet.InkjetHost;

    /// <summary>The made-up PC: every adapter the app reaches outside itself, made up (see <see cref="PcEnvironment"/>).</summary>
    public static PcEnvironment Pc { get; } = new DemoPc(empty: false);

    /// <summary><c>--demo --no-printers</c>: a made-up PC that finds no printer at all (the empty printer list).</summary>
    public static PcEnvironment EmptyPc { get; } = new DemoPc(empty: true);

    private sealed class DemoPc(bool empty) : PcEnvironment
    {
        public override bool IsDemo => true;
        public override AppState LoadState() => empty ? new AppState { IsInMemory = true } : CreateState();
        public override HttpMessageHandler? DeviceTransport() => CreateTransport();
        public override Core.Snmp.ISnmpTransport Snmp => Demo.Snmp;
        public override bool NetworkUp() => true;
        public override Windows.Discovery.PrinterDiscovery? CreateDiscovery() => null;
        // Adding works against the made-up printers only: the demo's transports reach no real address.
        public override string? AddByAddressOff => null;

        public override Task SearchNetworkAsync(Action<string> found, IProgress<Core.Discovery.SearchProgress>? progress, CancellationToken ct) =>
            Demo.SearchNetworkAsync(empty, found, progress, ct);

        // Made up: this PC's queues and scanners are never asked in demo mode.
        public override (IReadOnlyList<Core.Queues.SpoolerQueue>, IReadOnlyList<Core.Wia.WiaDeviceInfo>)? FixedDevices =>
            empty ? ([], []) : (Queues, Demo.Wia.Scanners.Select(s => s.Device).ToList());

        public override Core.Wia.IWiaSystem Wia => Demo.Wia;
        public override bool HasWindowsQueues => false;
        public override Task<string?> FindQueueAsync(string uuid, string? host, Core.Queues.SpoolerQueue? listed, AppState state) => Task.FromResult<string?>(null);
        protected override Core.Queues.IQueueStatusSource SpoolerStatus(Core.Queues.SpoolerQueue q) => Demo.QueueStatus(q);
        public override IPrintJobs PrintJobs(Func<Task<string?>> findQueue) => Demo.PrintJobs;
        public override Action<string, int>? MadeUpPrint => Demo.PrintJobs.Add;
        public override ViewModels.DemoPhotoQueue? PhotoQueue(string uuid) => Demo.PhotoQueue(uuid);

        // The made-up PC's fixer never reads or touches this PC's queues; its "elevation" is made up too.
        public override Core.Offline.IOfflineProbes OfflineProbes => OfflinePc;
        public override Core.Offline.IOfflineRepairs OfflineRepairs(Func<Task<string?>> setUpAgain) => OfflinePc;
        public override bool PairsAnyPrinter => true;

        public override IPrinterPasswords Passwords { get; } = new MemoryPasswords();
        public override Action<string>? Browser => null;
        public override bool OpensOtherApps => false;
        public override string UserName => "demo";
        public override string? ImageCache => null;
        public override bool ChecksHpSoftware => false;
        public override Core.History.SupplyHistoryStore History { get; } = new(null, Core.History.DemoSupplyHistory.Seed);

        public override void PrepareScan(bool feederBatch, bool photosOnGlass)
        {
            FeederBatch = feederBatch;
            PhotosOnGlass = photosOnGlass;
        }
    }

    /// <summary>What <c>--demo status --all</c> reads: the made-up PC, or with <paramref name="empty"/> (<c>--no-printers</c>) one with nothing on it.</summary>
    public static Core.Fleet.IFleetPc FleetPc(bool empty) =>
        empty ? new EmptyFleetPc() : new Core.Fleet.DemoFleetPc(CreateTransport, Snmp, Wia, OfflinePc.Current);

    /// <summary>A made-up PC with nothing on it.</summary>
    private sealed class EmptyFleetPc : Core.Fleet.IFleetPc
    {
        public Core.Suite.InkvoltPrinters Remembered => Core.Suite.InkvoltPrinters.Empty;
        public IReadOnlyCollection<string> Hidden => [];
        public Core.Probe.PrinterRecipe Recipe(Core.Suite.InkvoltPrinter printer) => throw new InvalidOperationException("No printers on this made-up PC.");
        public Task<IReadOnlyList<Core.Queues.SpoolerQueue>> QueuesAsync(Func<Core.Queues.SpoolerQueue, bool> needsPresence, CancellationToken ct) => Task.FromResult<IReadOnlyList<Core.Queues.SpoolerQueue>>([]);
        public Core.Queues.IQueueStatusSource QueueStatus(Core.Queues.SpoolerQueue queue) => throw new InvalidOperationException("No queues on this made-up PC.");
        public Task<IReadOnlyList<Core.Wia.WiaDeviceInfo>> ScannersAsync(CancellationToken ct) => Task.FromResult<IReadOnlyList<Core.Wia.WiaDeviceInfo>>([]);
        public Core.Wia.IWiaSystem Wia => Demo.Wia;
        public Core.History.SupplyHistoryStore? History => null;
    }

    public static AppState CreateState() => new()
    {
        IsInMemory = true,
        Printers = [.. Core.Fleet.DemoFleet.Printers.Select(p => new KnownPrinter(p.Uuid, p.Name, p.Model, p.Host, p.EsclRoot?.AbsoluteUri, p.IppUri?.AbsoluteUri, p.Snmp))],
        SelectedUuid = Uuid,
        // The firmware watch's notice (roadmap 1.5): the demo printer had an older version until today's connection.
        Firmware = new(StringComparer.OrdinalIgnoreCase) { [Uuid] = new Core.History.FirmwareRecord("2023-11-02", new DateOnly(2025, 11, 20)) },
    };

    public static HttpMessageHandler CreateTransport() => new HostRouter(new Dictionary<string, HttpMessageHandler>
    {
        [FixtureHandler.DemoHost] = new FixtureHandler(name => Document(ResourcePrefix + name), scanArea: Scan),
        [InkjetHost] = new FixtureHandler(name => InkjetDocument(InkjetPrefix + name), scanArea: Scan, feederBatch: () => FeederBatch ? Batch.Value : null),
        // The office laser answers only at its new address: the HP fixtures under its own name and UUID.
        [OfficeNewHost] = new FixtureHandler(name => OfficeDocument(ResourcePrefix + name), scanArea: Scan),
        // A newer HP model: status, supplies and identity over CDM only (no LEDM, no IPP or eSCL fixtures).
        [CdmHost] = new FixtureHandler(name => Document(CdmPrefix + name)),
    });

    /// <summary>
    /// The inkjet's documents, its feeder sending PDF only (roadmap 1.3: some feeders offer nothing else): the review shows the
    /// pictures taken out of each PDF, and a preset saving PDF without changes keeps the scanner's own.
    /// </summary>
    private static byte[]? InkjetDocument(string resource) => Document(resource) is not { } bytes ? null
        : resource.EndsWith("ScannerCapabilities.xml", StringComparison.Ordinal) ? FeederPdfOnly(bytes) : bytes;

    /// <summary>The capabilities with JPEG taken out of the named "feeder" profile (the part before the glass's).</summary>
    internal static byte[] FeederPdfOnly(byte[] capabilities)
    {
        var text = System.Text.Encoding.UTF8.GetString(capabilities);
        var glass = text.IndexOf("<scan:Platen>", StringComparison.Ordinal);
        var feeder = System.Text.RegularExpressions.Regex.Replace(text[..glass],
            @"\s*<(pwg:DocumentFormat|scan:DocumentFormatExt)>image/jpeg</\1>", "");
        return System.Text.Encoding.UTF8.GetBytes(feeder + text[glass..]);
    }

    private static byte[]? OfficeDocument(string resource) => Document(resource) is not { } bytes ? null
        : resource.EndsWith("ProductConfigDyn.xml", StringComparison.Ordinal) || resource.EndsWith("ScannerCapabilities.xml", StringComparison.Ordinal)
            ? System.Text.Encoding.UTF8.GetBytes(System.Text.Encoding.UTF8.GetString(bytes)
                .Replace("HP LaserJet MFP M234dw", "Demo office laser").Replace(Uuid, OfficeUuid))
            : bytes;

    /// <summary>
    /// The made-up SNMP agents: the SNMP-only laser and the color MFP behind the TCP/IP queue (objects written from the MIBs,
    /// <c>Fixtures/snmp-demo</c>). Every other address stays silent, so no SNMP goes to the network in demo mode.
    /// </summary>
    public static Core.Snmp.ISnmpTransport Snmp { get; } = new Core.Snmp.SnmpRouter(new Dictionary<string, Core.Snmp.ISnmpTransport>
    {
        [SnmpHost] = SnmpAgent("workgroup-laser.txt"),
        [SnmpQueueHost] = SnmpAgent("color-mfp.txt"),
        [UnlistedHost] = SnmpAgent("workgroup-laser.txt", text => text.Replace("Demo Laser 5200 Series", "Demo Laser 3100")
            .Replace("Demo Laser 5200", "Demo Laser 3100").Replace("DEMO0005200", "DEMO0003100").Replace("demo-laser", "basement-laser")
            .Replace("Office, 2nd floor", "Basement")),
    });

    /// <summary>
    /// Search my network on the made-up network: 253 addresses over about three seconds, finding the HP laser and the SNMP-only
    /// laser (both listed already) and <see cref="UnlistedHost"/>; on the empty PC's network, nothing.
    /// </summary>
    public static async Task SearchNetworkAsync(bool empty, Action<string> found, IProgress<Core.Discovery.SearchProgress>? progress, CancellationToken ct)
    {
        const int total = 253;
        var printers = empty ? new Dictionary<int, string>()
            : new Dictionary<int, string> { [10] = FixtureHandler.DemoHost, [14] = SnmpHost, [16] = UnlistedHost };
        for (var i = 1; i <= total; i++)
        {
            if (i % 16 == 0) await Task.Delay(180, ct);
            if (printers.TryGetValue(i, out var host)) found(host);
            progress?.Report(new Core.Discovery.SearchProgress(i, total));
        }
    }

    private static Core.Snmp.SnmpAgent SnmpAgent(string name, Func<string, string>? change = null) =>
        new(Core.Snmp.SnmpAgent.ParseWalk((change ?? (t => t))(System.Text.Encoding.UTF8.GetString(Document("DemoSnmp." + name) ?? []))));

    /// <summary>The made-up PC and network the demo printers' offline fixer looks at and repairs.</summary>
    public static DemoOfflinePc OfflinePc { get; } = new([(Uuid, FixtureHandler.DemoHost), (InkjetUuid, InkjetHost)], OfficeUuid);

    // WPF drawing needs the UI thread; the handler runs wherever the scan's awaits continue.
    private static readonly Lazy<byte[]>[] Pages =
        [new(() => Application.Current.Dispatcher.Invoke(() => ScanPage(0))), new(() => Application.Current.Dispatcher.Invoke(() => ScanPage(2.5))),
            new(() => Application.Current.Dispatcher.Invoke(BlankSheet))];

    private static int _cardSide, _page = -1;

    /// <summary>The next feeder scan splits into files: the made-up feeder then holds <see cref="Batch"/> (set by the Scan tab).</summary>
    public static bool FeederBatch { get; set; }

    /// <summary>
    /// Two documents and a one-page third: a straight page and a crooked one, a Patch T separator sheet, a page, a blank sheet,
    /// a page. Split at patch codes, that's two files (the blank page skipped); at patch codes or blank pages, three.
    /// </summary>
    private static readonly Lazy<IReadOnlyList<byte[]>> Batch = new(() => Application.Current.Dispatcher.Invoke(() =>
        (IReadOnlyList<byte[]>)[Pages[0].Value, Pages[1].Value, SeparatorSheetPage(), ScanPage(0), Pages[2].Value, ScanPage(-1.5)]));

    /// <summary>The printable separator sheet (<see cref="Core.Pdf.SeparatorSheet"/>'s own layout) as scanned at 300 dpi.</summary>
    private static byte[] SeparatorSheetPage()
    {
        const int w = 1275, h = 1650; // 150 per inch, rendered at 300 dpi
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(2, 2));
            dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, w, h));
            var ink = new SolidColorBrush(Color.FromRgb(0x1C, 0x1C, 0x1C));
            foreach (var r in Core.Pdf.SeparatorSheet.Layout(Core.Imaging.PatchCode.PatchT, 8.5, 11))
                dc.DrawRectangle(ink, null, new Rect(r.X * 150, r.Y * 150, r.Width * 150, r.Height * 150));
            var face = new Typeface("Segoe UI");
            void Line(string text, double size, double y)
            {
                var ft = new FormattedText(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, size, ink, 1);
                dc.DrawText(ft, new Point((w - ft.Width) / 2, y));
            }
            Line("Separator sheet", 54, 120);
            Line("Patch T", 38, 200);
            Line("Inkvolt Print starts a new file at this sheet.", 22, 300);
        }
        return Jpeg(visual, w * 2, h * 2);
    }

    /// <summary>A page for page-sized regions; for a small region (ID card copy), a made-up card, front and back in turn.</summary>
    private static byte[] Scan(int width, int height) =>
        width <= 1800 && height <= 1500
            ? Application.Current.Dispatcher.Invoke(() => ScanCard(width, height, back: Interlocked.Increment(ref _cardSide) % 2 == 0))
            : PhotosOnGlass ? Application.Current.Dispatcher.Invoke(() => GlassWithPhotos(width, height))
            : Pages[Interlocked.Increment(ref _page) % Pages.Length].Value;

    /// <summary>The next glass scan looks for photos: the made-up glass then holds three prints (set by the Scan tab).</summary>
    public static bool PhotosOnGlass { get; set; }

    /// <summary>
    /// Three made-up prints laid on the glass, each a little crooked, on a slightly grey lid: a 4.8 × 3.4 in landscape, a 4 × 6 in
    /// portrait print on its side and a small square one, all within a letter or A4 page. <paramref name="width"/> × <paramref name="height"/> pixels at 300 dpi.
    /// </summary>
    private static byte[] GlassWithPhotos(int width, int height)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0xF3, 0xF3, 0xF1)), null, new Rect(0, 0, width, height));
            Print(dc, 0.3, 0.3, 4.8, 3.4, -4, Color.FromRgb(0x6F, 0xA8, 0xDC), Color.FromRgb(0x4E, 0x8B, 0x3A));
            Print(dc, 5.9, 0.5, 2.4, 2.4, 3, Color.FromRgb(0x9B, 0x7F, 0xD4), Color.FromRgb(0x2E, 0x4A, 0x7A));
            Print(dc, 1.5, 3.8, 4, 6, 90 + 6, Color.FromRgb(0xF2, 0xA6, 0x5A), Color.FromRgb(0x8C, 0x4A, 0x2F)); // on its side
        }
        return Jpeg(visual, width, height);

        // A print with its top-left corner at (x, y) inches, turned clockwise about its centre: sky, hills and a sun.
        static void Print(DrawingContext dc, double x, double y, double w, double h, double degrees, Color sky, Color land)
        {
            var r = new Rect(x * 300, y * 300, w * 300, h * 300);
            dc.PushTransform(new RotateTransform(degrees, r.X + r.Width / 2, r.Y + r.Height / 2));
            dc.DrawRectangle(new LinearGradientBrush(sky, Color.FromRgb((byte)((sky.R + 200) / 2), (byte)((sky.G + 200) / 2), (byte)((sky.B + 200) / 2)), 90), null, r);
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(0xFF, 0xD8, 0x4D)), null, new Point(r.X + r.Width * 0.75, r.Y + r.Height * 0.28), r.Height * 0.1, r.Height * 0.1);
            dc.PushClip(new RectangleGeometry(r));
            dc.DrawEllipse(new SolidColorBrush(land), null, new Point(r.X + r.Width * 0.3, r.Bottom), r.Width * 0.55, r.Height * 0.45);
            dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(0xDD, land.R, land.G, land.B)), null, new Point(r.X + r.Width * 0.85, r.Bottom), r.Width * 0.45, r.Height * 0.35);
            dc.Pop();
            dc.Pop();
        }
    }

    private static byte[]? Document(string resource)
    {
        using var s = typeof(Demo).Assembly.GetManifestResourceStream(resource);
        if (s is null) return null;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>The made-up PC's Windows queues (<see cref="Core.Fleet.DemoFleet.Queues"/>).</summary>
    public static IReadOnlyList<Core.Queues.SpoolerQueue> Queues => Core.Fleet.DemoFleet.Queues;

    /// <summary>
    /// The made-up PC's scanners (WIA, <see cref="Core.Fleet.DemoFleet.Scanners"/>), so the Scan and Copy tabs of printers without eSCL
    /// can be tried. Pages are the demo's generated ones; nothing on this PC is asked.
    /// </summary>
    public static Core.Wia.FakeWiaSystem Wia { get; } = MadeUpScanners();

    private static Core.Wia.FakeWiaSystem MadeUpScanners()
    {
        var scanners = Core.Fleet.DemoFleet.Scanners(WiaPage);
        scanners[0].FeederStack = () => FeederBatch ? Batch.Value.Count : 3;
        scanners[0].HandlingStatus = Core.Wia.WiaIds.FeedReady;
        return new(scanners);
    }

    /// <summary>A demo WIA page: the feeder batch's next page when the scan splits into files, else what an eSCL demo scan of that area gives.</summary>
    private static byte[] WiaPage(Core.Wia.WiaScanSettings s, int page) =>
        s.Feeder && FeederBatch ? Batch.Value[page % Batch.Value.Count]
            : Scan((int)((long)s.Width * 300 / s.Resolution), (int)((long)s.Height * 300 / s.Resolution));

    /// <summary>A demo queue's status: what <see cref="Core.Queues.SpoolerStatus"/> makes of its made-up bits (no spooler is asked).</summary>
    public static Core.Queues.IQueueStatusSource QueueStatus(Core.Queues.SpoolerQueue queue) => Core.Fleet.DemoFleet.QueueStatus(queue, OfflinePc.Current);

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
