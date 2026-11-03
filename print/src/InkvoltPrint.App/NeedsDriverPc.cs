using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App;

/// <summary>
/// "Plugged in, needs its driver" as the PC has it (<see cref="PcEnvironment.NeedsDriver"/>): the USB printers Windows sees that
/// nothing can print to, a word when one comes or goes, setting one up, and opening a page for the user. Demo mode's made-up PC has
/// one made-up printer and opens or changes nothing.
/// </summary>
public interface INeedsDriverPc
{
    Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct);

    Task<UsbSetUpResult> SetUpAsync(NeedsDriverPrinter printer);

    /// <summary>Calls <paramref name="changed"/> (from any thread) when a USB printer comes or goes; null where nothing changes.</summary>
    IDisposable? Watch(Action changed);

    /// <summary>Opens a web page or a Windows Settings page; false when nothing is opened (demo mode).</summary>
    bool Open(string target);

    /// <summary>Windows' Add printer, for setting one up by hand.</summary>
    bool OpenAddPrinter();
}

internal sealed class RealNeedsDriverPc : INeedsDriverPc
{
    public static RealNeedsDriverPc Instance { get; } = new();

    public Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct) => UsbPrinters.ReadAsync(queues, ct);

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
}

/// <summary>The made-up PC's: one made-up USB laser with no driver, so the page shows in demo mode and its screenshots.</summary>
internal sealed class DemoNeedsDriverPc : INeedsDriverPc
{
    public static DemoNeedsDriverPc Instance { get; } = new();

    public static readonly NeedsDriverPrinter Printer =
        new("usb-needs-driver:demo", "Demo USB laser (no driver)", "HP", "USB009", DriverStage.NoDriver) { IsMadeUp = true };

    public Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct) =>
        Task.FromResult(new NeedsDriverRead([Printer], ProtectedPrint: false));

    public Task<UsbSetUpResult> SetUpAsync(NeedsDriverPrinter printer) => Task.FromResult(new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.Demo));

    public IDisposable? Watch(Action changed) => null;

    public bool Open(string target) => false;

    public bool OpenAddPrinter() => false;
}
