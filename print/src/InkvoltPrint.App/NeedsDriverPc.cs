using InkvoltPrint.Core.Drivers;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App;

/// <summary>
/// "Plugged in, needs its driver" as the PC has it (<see cref="PcEnvironment.NeedsDriver"/>): the USB printers and scanners Windows
/// sees that have no working driver, a word when one comes or goes, getting a maker's driver, setting a printer up, and opening a
/// page for the user. Demo mode's made-up PC has one made-up printer and one made-up scanner, and downloads, opens or changes nothing.
/// </summary>
public interface INeedsDriverPc
{
    Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct);

    /// <summary>One device's nodes, whatever their driver, plugged in only (whether it is there and working: <see cref="DeviceState"/>).</summary>
    Task<IReadOnlyList<UsbPrinterNode>> DeviceNodesAsync(NeedsDriverPrinter device, CancellationToken ct);

    Task<UsbSetUpResult> SetUpAsync(NeedsDriverPrinter printer);

    /// <summary>Calls <paramref name="changed"/> (from any thread) when a USB printer or scanner comes or goes; null where nothing changes.</summary>
    IDisposable? Watch(Action changed);

    /// <summary>Opens a web page or a Windows Settings page; false when nothing is opened (demo mode).</summary>
    bool Open(string target);

    /// <summary>Windows' Add printer, for setting one up by hand.</summary>
    bool OpenAddPrinter();

    /// <summary>"Get the driver": the maker's download found, checked and run on the user's click.</summary>
    IDriverGetter Drivers { get; }
}

internal sealed class RealNeedsDriverPc : INeedsDriverPc
{
    public static RealNeedsDriverPc Instance { get; } = new();

    public Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct) => UsbPrinters.ReadAsync(queues, ct);

    public Task<IReadOnlyList<UsbPrinterNode>> DeviceNodesAsync(NeedsDriverPrinter device, CancellationToken ct) => UsbPrinters.DeviceNodesAsync(device, ct);

    public Task<UsbSetUpResult> SetUpAsync(NeedsDriverPrinter printer) => UsbPrinters.SetUpAsync(printer);

    public IDisposable? Watch(Action changed)
    {
        var watcher = new UsbPrinterWatcher();
        watcher.Changed += changed;
        watcher.Start();
        return watcher;
    }

    public bool Open(string target)
    {
        Shell.Open(target);
        return true;
    }

    public bool OpenAddPrinter()
    {
        UsbPrinters.OpenAddPrinterWizard();
        return true;
    }

    public IDriverGetter Drivers => _drivers.Value;

    private readonly Lazy<IDriverGetter> _drivers = new(() => WindowsDrivers.Create(Features.DriverMode));
}

/// <summary>The made-up PC's: a made-up USB laser and a made-up USB scanner with no driver, so the pages show in demo mode and its screenshots.</summary>
internal sealed class DemoNeedsDriverPc : INeedsDriverPc
{
    public static DemoNeedsDriverPc Instance { get; } = new();

    public static readonly NeedsDriverPrinter Printer =
        new("usb-needs-driver:demo", "Demo USB laser (no driver)", "HP", "USB009", DriverStage.NoDriver) { IsMadeUp = true };

    public static readonly NeedsDriverPrinter Scanner =
        new("usb-needs-driver:scanner-demo", "Epson Demo Scanner (no driver)", "Epson", null, DriverStage.NoDriver)
            { IsMadeUp = true, Kind = NeedsDriverKind.Scanner, UsbId = "04B8:0000" };

    public Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct) =>
        Task.FromResult(new NeedsDriverRead([Printer, Scanner], ProtectedPrint: false));

    public Task<UsbSetUpResult> SetUpAsync(NeedsDriverPrinter printer) => Task.FromResult(new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.Demo));

    public Task<IReadOnlyList<UsbPrinterNode>> DeviceNodesAsync(NeedsDriverPrinter device, CancellationToken ct) => Task.FromResult<IReadOnlyList<UsbPrinterNode>>([]);

    public IDisposable? Watch(Action changed) => null;

    public bool Open(string target) => false;

    public bool OpenAddPrinter() => false;

    public IDriverGetter Drivers { get; } = new DemoDriverGetter();
}

/// <summary>Demo mode's "Get the driver": a made-up find for the made-up scanner; nothing is downloaded, written or run.</summary>
internal sealed class DemoDriverGetter : IDriverGetter
{
    private static readonly Uri Page = new("https://epson.com/Support/sl/s");

    /// <summary>The flow this copy has (a Store copy's demo shows the link), so either can be seen in demo mode.</summary>
    public DriverMode Mode => Forced ?? Features.DriverMode;

    /// <summary>Set by the snapshot aid (<c>--driver-link</c>) to show the Store copy's flow from any build.</summary>
    internal static DriverMode? Forced { get; set; }

    public bool LooksUp(NeedsDriverPrinter device) => device.IsMadeUp && device.IsScanner;

    public Uri? LinkFor(DriverOffer offer, NeedsDriverPrinter device) => offer.Download;

    public Task<bool> LookAgainAsync(Func<CancellationToken, Task<bool>> isThere, CancellationToken ct) => Task.FromResult(false);

    public async Task<DriverLookup> FindAsync(NeedsDriverPrinter device, CancellationToken ct)
    {
        await Task.Delay(300, ct);
        return DriverLookup.Found(new DriverOffer("Scanner Driver (made up)", "1.0.0.0", "12.0 MB", Page, "demo-driver.exe", Page));
    }

    public async Task<DriverDownload> DownloadAsync(DriverOffer offer, NeedsDriverPrinter device, IProgress<long>? progress, CancellationToken ct)
    {
        await Task.Delay(300, ct);
        progress?.Report(12L << 20);
        return new DriverDownload(new DriverReady(offer, "Epson", "", 12L << 20, "Demo Signer (made up)"));
    }

    public Task<InstallResult> InstallAsync(DriverReady ready, Func<CancellationToken, Task<bool>> isThere, CancellationToken ct) =>
        Task.FromResult(new InstallResult(InstallOutcome.Failed));

    public void Discard(DriverReady ready) { }
}
