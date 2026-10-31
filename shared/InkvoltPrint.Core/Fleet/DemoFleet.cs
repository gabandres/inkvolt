using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Fleet;

/// <summary>
/// The demo PC's list, in one place so the app's <c>--demo</c> and the tests have the same entries: five remembered printers,
/// the made-up PC's Windows queues (three stand for printers of their own) and its WIA scanners (one is a printer's, one stands
/// alone). All made up, at RFC 5737 addresses.
/// </summary>
public static class DemoFleet
{
    public const string LaserUuid = "12345678-1234-4abc-8def-123456789abc"; // the fixtures' (fake) UUID
    public const string InkjetUuid = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"; // Fixtures/inkjet-demo (made up)
    public const string OfficeUuid = "3c9a7e51-8d2b-4f60-a1e4-5b7c9d0e2f13"; // made up
    public const string CdmUuid = "4d1e2c3b-0a9f-4e8d-b7c6-5a4b3c2d1e0f"; // Fixtures/cdm-laser (made up)

    /// <summary>The demo inkjet's address.</summary>
    public const string InkjetHost = "192.0.2.11";

    /// <summary>The demo office laser's address before the (made-up) router gave it a new one, and after.</summary>
    public const string OfficeOldHost = "192.0.2.12", OfficeNewHost = "192.0.2.23";

    /// <summary>The demo HP color laser that speaks CDM, not LEDM (newer HP models).</summary>
    public const string CdmHost = "192.0.2.13";

    /// <summary>The demo printer that answers SNMP only, and the demo color MFP behind a Windows TCP/IP port.</summary>
    public const string SnmpHost = "192.0.2.14", SnmpQueueHost = "192.0.2.15";

    public static readonly InkvoltPrinter Laser = new(LaserUuid, "Demo printer", null, FixtureHandler.DemoHost, new Uri($"http://{FixtureHandler.DemoHost}/eSCL/"));
    public static readonly InkvoltPrinter Inkjet = new(InkjetUuid, "Demo inkjet", null, InkjetHost, new Uri($"http://{InkjetHost}/eSCL/")) { IppUri = new Uri($"http://{InkjetHost}:631/ipp/print") };
    public static readonly InkvoltPrinter Office = new(OfficeUuid, "Demo office laser", null, OfficeOldHost, new Uri($"http://{OfficeOldHost}/eSCL/"));
    public static readonly InkvoltPrinter Cdm = new(CdmUuid, "Demo color laser (CDM)", null, CdmHost, null);

    /// <summary>Added by address, as an SNMP-only printer is (no UUID: its id comes from the address); what it says of itself is its made-up agent's.</summary>
    public static readonly InkvoltPrinter SnmpOnly = new(Model.PrinterId.Normalize(null, SnmpHost), "Demo Laser 5200 Series", null, SnmpHost, null)
    {
        Snmp = new SnmpDevice("DEMO0005200", "Demo Laser 5200 Series", "demo-laser"),
    };

    public static readonly IReadOnlyList<InkvoltPrinter> Printers = [Laser, Inkjet, Office, Cdm, SnmpOnly];

    /// <summary>
    /// The made-up PC's Windows queues: a USB laser that discovery can't see (paused in Windows, toner low as its driver reports it),
    /// a printer shared from another PC that is off, a color MFP on a Standard TCP/IP port (renamed, so its address comes from the
    /// port's configuration; read over SNMP), and two that stay out of the list: Microsoft Print to PDF (virtual) and the demo HP
    /// laser's own WSD queue (its device container is the printer's UUID, so it isn't listed twice).
    /// </summary>
    public static readonly IReadOnlyList<SpoolerQueue> Queues =
    [
        new("Demo USB laser", "USB001", "Demo Laser 2100 PCL6", SpoolerFlags.StatusTonerLow | SpoolerFlags.StatusPaused, SpoolerFlags.AttributeLocal, 0)
            { PortMonitor = "USB Monitor" },
        new(@"\\demo-pc\Front desk", @"\\demo-pc\Front desk", "Demo Inkjet 3700 Series", SpoolerFlags.StatusOffline, SpoolerFlags.AttributeNetwork, 0),
        new("Office color MFP", "Office color", "Demo Color MFP 4400 PCL6", 0, SpoolerFlags.AttributeLocal, 1)
            { PortMonitor = "Standard TCP/IP Port", PortAddress = SnmpQueueHost, PortCommunity = "public", Location = "Copy room" },
        new("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF", 0, SpoolerFlags.AttributeLocal, 0) { PortMonitor = "Local Monitor" },
        new("HP LaserJet MFP M234dw (demo)", "WSD-00000000-0000-4000-8000-000000000000", "Microsoft IPP Class Driver", 0, SpoolerFlags.AttributeLocal, 0)
            { PortMonitor = "WSD Port Monitor", ContainerId = LaserUuid },
    ];

    /// <summary>
    /// The made-up PC's scanners (WIA): the scanner part of the USB laser (glass and a feeder, color or grey, its own driver's
    /// resolutions; Windows lists it apart from the print queue, and its model number matches it to the queue's driver) and a USB
    /// photo flatbed that belongs to no printer, listed on its own.
    /// </summary>
    public static IReadOnlyList<FakeWiaScanner> Scanners(Func<WiaScanSettings, int, byte[]> draw) =>
    [
        new(new WiaDeviceInfo(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0000", "Demo Laser 2100", "Demo", "Demo Laser 2100 scanner", @"\\.\Usbscan0"),
            new WiaScannerInfo(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDetectFeedAvailable, 8500, 11690, 8500, 14000,
                WiaValues.Of(300, 100, 150, 200, 300, 600), [0, WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatBmp]), draw),
        new(new WiaDeviceInfo(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0001", "Demo Photo Scanner 40", "Demo", "Demo Photo Scanner 40", @"\\.\Usbscan1"),
            new WiaScannerInfo(null, 8500, 11700, null, null, WiaValues.Range(300, 50, 2400, 1), [WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatJpeg, WiaIds.FormatBmp]), draw),
    ];

    /// <summary>A demo queue's status: what <see cref="SpoolerStatus"/> makes of its made-up bits as <paramref name="current"/> has them now (no spooler is asked).</summary>
    public static IQueueStatusSource QueueStatus(SpoolerQueue queue, Func<SpoolerQueue, SpoolerQueue>? current = null) => new MadeUpQueue(queue, current);

    private sealed class MadeUpQueue(SpoolerQueue queue, Func<SpoolerQueue, SpoolerQueue>? current) : IQueueStatusSource
    {
        public string Origin => "Windows and the printer's driver";
        public bool HasSupplyLevels => false;

        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) =>
            Task.FromResult<QueueStatusRead?>(QueueStatusRead.From(SpoolerStatus.Describe(current?.Invoke(queue) ?? queue)));
    }
}

/// <summary>The demo PC as <see cref="FleetReader"/> reads it. Nothing reaches the network or this PC.</summary>
public sealed class DemoFleetPc(Func<HttpMessageHandler> transport, ISnmpTransport snmp, IWiaSystem wia, Func<SpoolerQueue, SpoolerQueue>? current = null) : IFleetPc
{
    public InkvoltPrinters Remembered { get; } = new(DemoFleet.Printers, new Dictionary<string, string>());
    public IReadOnlyCollection<string> Hidden { get; init; } = [];
    public PrinterRecipe Recipe(InkvoltPrinter printer) => new(transport, snmp);

    public Task<IReadOnlyList<SpoolerQueue>> QueuesAsync(Func<SpoolerQueue, bool> needsPresence, CancellationToken ct) => Task.FromResult(DemoFleet.Queues);

    public IQueueStatusSource QueueStatus(SpoolerQueue queue)
    {
        var windows = DemoFleet.QueueStatus(queue, current);
        return QueueKinds.SnmpAddress(queue) is { } host ? new SnmpQueueStatusSource(windows, host, snmp, queue.PortCommunity) : windows;
    }

    public Task<IReadOnlyList<WiaDeviceInfo>> ScannersAsync(CancellationToken ct) => wia.ListScannersAsync(ct);
    public IWiaSystem Wia => wia;
    public SupplyHistoryStore? History { get; init; }
}
