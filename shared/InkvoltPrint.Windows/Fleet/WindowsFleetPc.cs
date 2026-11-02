using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;
using InkvoltPrint.Windows.Printing;
using InkvoltPrint.Windows.Scanning;

namespace InkvoltPrint.Windows.Fleet;

/// <summary>
/// This PC as <c>status --all</c> reads it: the printers in Inkvolt Print's state file wherever it is installed, the network, Windows'
/// queues and scanners, the supply history. Read only, since the app may be running beside it: no state, pin or history is
/// written. With no pin given a printer's certificate is taken as it comes and not remembered; nothing secret is sent to it (no
/// password goes out on this path), and the device still says who it is before it's read.
/// </summary>
public sealed class WindowsFleetPc : IFleetPc
{
    public WindowsFleetPc(string localAppData)
    {
        var state = InkvoltPaths.CurrentStateFile(localAppData);
        Remembered = InkvoltPrinters.Load(state);
        if (state is not null && Path.GetDirectoryName(state) is { } folder) History = new SupplyHistoryStore(Path.Combine(folder, "history"));
    }

    public InkvoltPrinters Remembered { get; }
    public IReadOnlyCollection<string> Hidden => Remembered.Forgotten;
    public SupplyHistoryStore? History { get; }
    public IWiaSystem Wia => WindowsWia.Instance;

    public PrinterRecipe Recipe(InkvoltPrinter printer) => new(() => null, UdpSnmpTransport.Instance);

    public Task<IReadOnlyList<SpoolerQueue>> QueuesAsync(Func<SpoolerQueue, bool> needsPresence, CancellationToken ct) => InstalledQueues.ListAsync(needsPresence);

    public IQueueStatusSource QueueStatus(SpoolerQueue queue)
    {
        var windows = new SpoolerStatusSource(queue);
        return QueueKinds.SnmpAddress(queue) is { } host ? new SnmpQueueStatusSource(windows, host, UdpSnmpTransport.Instance, queue.PortCommunity) : windows;
    }

    public Task<IReadOnlyList<WiaDeviceInfo>> ScannersAsync(CancellationToken ct) => WindowsWia.Instance.ListScannersAsync(ct);

    /// <summary>The Pro key for a run of the command: read from where both apps keep it, never moved or written.</summary>
    public IProStore ProStore(string localAppData) => new ReadOnlyKey(localAppData, Remembered.ProKey);

    private sealed class ReadOnlyKey(string localAppData, string? fromState) : IProStore
    {
        public string? Read() => ProKeyFile.Read(localAppData) ?? fromState;
        public void Write(string? key) { }
    }
}
