using System.IO;
using InkvoltPrint.App.Printing;
using InkvoltPrint.App.Tray;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Wia;
using InkvoltPrint.Windows.Discovery;
using InkvoltPrint.Windows.Offline;
using InkvoltPrint.Windows.Printing;
using InkvoltPrint.Windows.Scanning;
using InkvoltPrint.Windows.Security;

namespace InkvoltPrint.App;

/// <summary>
/// This PC's environment: everything outside Inkvolt Print that the view models reach (the network, Windows' print queues and
/// scanners, the offline fixer's checks and repairs, saved printer passwords, the browser and other apps), each handed out as
/// an adapter. Chosen once at start-up (App): the real PC (<see cref="Real"/>), or demo mode's made-up one
/// (<see cref="Demo.Pc"/>). View models take what it hands out instead of asking whether they're in a demo, so demo mode's
/// safety rules hold by construction: its queue lookup finds no Windows queue (nothing ever prints for real), its passwords stay
/// in memory, nothing opens in the browser or another app, and no request reaches the network, this PC's queues or its scanners.
/// </summary>
public abstract class PcEnvironment
{
    public static PcEnvironment Real { get; } = new RealPc();

    /// <summary>The made-up PC of demo mode: only for wording that says so ("Demo: …") and the dev aids (DevSnapshot).</summary>
    public abstract bool IsDemo { get; }

    /// <summary>The remembered printers and preferences (the demo's live in memory only).</summary>
    public abstract AppState LoadState();

    // ---------------------------------------------------------------- the network

    /// <summary>A printer's web server for one connection: null for the real network.</summary>
    public abstract HttpMessageHandler? DeviceTransport();

    /// <summary>Where SNMP goes: UDP to the printer, or the demo's made-up agents.</summary>
    public abstract ISnmpTransport Snmp { get; }

    /// <summary>The network is up (the tray reads printers only then).</summary>
    public abstract bool NetworkUp();

    /// <summary>Finds printers on the network (mDNS, WSD); null where there is no network to search.</summary>
    public abstract PrinterDiscovery? CreateDiscovery();

    /// <summary>Why adding a printer by address can't be done here, or null when it can.</summary>
    public abstract string? AddByAddressOff { get; }

    /// <summary>
    /// Search my network (Add a printer): each address that may be a printer, as it's found (from any thread). The real network
    /// is searched only when this is called (<see cref="Core.Discovery.NetworkSearch"/>).
    /// </summary>
    public abstract Task SearchNetworkAsync(Action<string> found, IProgress<Core.Discovery.SearchProgress>? progress, CancellationToken ct);

    // ---------------------------------------------------------------- Windows' print queues and scanners

    /// <summary>
    /// The PC's queues and scanners when they are fixed and known at once (the made-up PC's); null: they're read from Windows
    /// now and then.
    /// </summary>
    public abstract (IReadOnlyList<SpoolerQueue> Queues, IReadOnlyList<WiaDeviceInfo> Scanners)? FixedDevices { get; }

    /// <summary>Scanners Windows has a driver for (WIA).</summary>
    public abstract IWiaSystem Wia { get; }

    /// <summary>
    /// Network printers' Windows queues are looked up (whether one is set up, and setting one up). False on the made-up PC,
    /// where every printer's queue counts as set up and is never looked for.
    /// </summary>
    public abstract bool HasWindowsQueues { get; }

    /// <summary>
    /// The Windows queue to print to for a printer: <paramref name="listed"/> for a printer known by its queue, else the queue
    /// whose device container is the printer, the queue Inkvolt Print created by address, or one whose port has the address.
    /// Always null on the made-up PC: nothing is ever sent to a real queue in demo mode.
    /// </summary>
    public abstract Task<string?> FindQueueAsync(string uuid, string? host, SpoolerQueue? listed, AppState state);

    /// <summary>
    /// Where a queue printer's status comes from: Windows and the driver; for a queue whose port has the printer's address, the
    /// printer itself over SNMP too (status, problems, supply levels), with the port's own SNMP community when it has one.
    /// </summary>
    public IQueueStatusSource QueueStatus(SpoolerQueue q)
    {
        var windows = SpoolerStatus(q);
        return QueueKinds.SnmpAddress(q) is { } host ? new SnmpQueueStatusSource(windows, host, Snmp, q.PortCommunity) : windows;
    }

    protected abstract IQueueStatusSource SpoolerStatus(SpoolerQueue q);

    /// <summary>A printer's print queue as a list of jobs (the queue card).</summary>
    public abstract IPrintJobs PrintJobs(Func<Task<string?>> findQueue);

    /// <summary>Where copies and preset scans "print" instead of a Windows queue (job name, sheets): the made-up queue; null: the Windows queue.</summary>
    public abstract Action<string, int>? MadeUpPrint { get; }

    /// <summary>The made-up queue's photo options and where its photo jobs "print"; null: the printer's Windows queue.</summary>
    public abstract DemoPhotoQueue? PhotoQueue(string uuid);

    // ---------------------------------------------------------------- the offline fixer

    public abstract IOfflineProbes OfflineProbes { get; }

    /// <summary>The fixer's repairs; <paramref name="setUpAgain"/> re-creates a discovered printer's queue (null: done, else why not).</summary>
    public abstract IOfflineRepairs OfflineRepairs(Func<Task<string?>> setUpAgain);

    /// <summary>Any printer can be paired (set up again) by the fixer, not only one discovery found: the made-up PC's.</summary>
    public abstract bool PairsAnyPrinter { get; }

    // ---------------------------------------------------------------- the user's things

    /// <summary>Printers' admin passwords: Windows Credential Manager, or (demo) memory.</summary>
    public abstract IPrinterPasswords Passwords { get; }

    /// <summary>Opens a page in the browser; null where nothing is opened (the demo printers' pages don't exist).</summary>
    public abstract Action<string>? Browser { get; }

    /// <summary>Other apps are started (Inkvolt PDF, the mail app); false on the made-up PC, whose scans only say what would happen.</summary>
    public abstract bool OpensOtherApps { get; }

    /// <summary>The user name sent with maintenance jobs.</summary>
    public abstract string UserName { get; }

    /// <summary>Where printers' product photos are cached; null: not cached (the demo writes nothing to the user's data).</summary>
    public abstract string? ImageCache { get; }

    /// <summary>Look for HP's own software (to offer removing it).</summary>
    public abstract bool ChecksHpSoftware { get; }

    /// <summary>
    /// The supply history (roadmap 1.1): one small file per printer under the data folder; the demo's in memory, with a made-up
    /// year behind each printer's first reading so its chart has something to show.
    /// </summary>
    public abstract Core.History.SupplyHistoryStore History { get; }

    /// <summary>
    /// What the made-up scanners hold for the next scan: a batch with separator sheets in the feeder when the scan splits into
    /// files, a few photos on the glass when it looks for them. Nothing on a real PC.
    /// </summary>
    public virtual void PrepareScan(bool feederBatch, bool photosOnGlass) { }

    private sealed class RealPc : PcEnvironment
    {
        public override bool IsDemo => false;
        public override AppState LoadState() => AppState.Load();
        public override HttpMessageHandler? DeviceTransport() => null;
        public override ISnmpTransport Snmp => UdpSnmpTransport.Instance;
        public override bool NetworkUp() => PowerInfo.NetworkUp();
        public override PrinterDiscovery? CreateDiscovery() => new();
        public override string? AddByAddressOff => null;

        public override Task SearchNetworkAsync(Action<string> found, IProgress<Core.Discovery.SearchProgress>? progress, CancellationToken ct) =>
            Core.Discovery.NetworkSearch.SearchAsync(Core.Discovery.SocketNetworkScanner.Instance, a => found(a.ToString()), progress, ct);

        public override (IReadOnlyList<SpoolerQueue>, IReadOnlyList<WiaDeviceInfo>)? FixedDevices => null;
        public override IWiaSystem Wia => WindowsWia.Instance;
        public override bool HasWindowsQueues => true;

        public override async Task<string?> FindQueueAsync(string uuid, string? host, SpoolerQueue? listed, AppState state)
        {
            if (listed is not null) return listed.Name;
            if (await QueueFinder.FindQueueNameAsync(uuid) is { } byContainer) return byContainer;
            if (state.GetQueueName(uuid) is { } created
                && (await QueueFinder.ListAsync()).Any(q => string.Equals(q.Name, created, StringComparison.OrdinalIgnoreCase)))
                return created;
            // Added in Windows Settings by address: Windows names the queue itself, but its port carries the address.
            if (host is null || await Task.Run(() => QueuePrinter.FindByHost(host)) is not { } byPort) return null;
            state.SetQueueName(uuid, byPort);
            return byPort;
        }

        protected override IQueueStatusSource SpoolerStatus(SpoolerQueue q) => new SpoolerStatusSource(q);
        public override IPrintJobs PrintJobs(Func<Task<string?>> findQueue) => new WindowsPrintJobs(findQueue);
        public override Action<string, int>? MadeUpPrint => null;
        public override DemoPhotoQueue? PhotoQueue(string uuid) => null;
        public override IOfflineProbes OfflineProbes { get; } = new WindowsOfflineProbes();
        public override IOfflineRepairs OfflineRepairs(Func<Task<string?>> setUpAgain) => new SettingUpAgain(new WindowsOfflineRepairs(), setUpAgain);
        public override bool PairsAnyPrinter => false;
        public override IPrinterPasswords Passwords { get; } = new CredentialManager();
        public override Action<string>? Browser => Shell.Open;
        public override bool OpensOtherApps => true;
        public override string UserName => Environment.UserName;
        public override string? ImageCache => Path.Combine(AppState.DataDirectory, "images");
        public override bool ChecksHpSoftware => Features.HpCleanup;
        public override Core.History.SupplyHistoryStore History { get; } = new(Path.Combine(AppState.DataDirectory, "history"), log: Log.Write);
    }

    /// <summary>Setting a discovered queue up again is pairing, which the printer does; everything else is the PC's.</summary>
    private sealed class SettingUpAgain(IOfflineRepairs inner, Func<Task<string?>> setUpAgain) : IOfflineRepairs
    {
        public async Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct)
        {
            if (repair.Kind != RepairKind.SetUpAgain) return await inner.AsUserAsync(repair, ct);
            return await setUpAgain() is { } error
                ? new Attempt(AttemptResult.Failed, char.ToUpperInvariant(error[0]) + error[1..] + (error.EndsWith('.') ? "" : "."))
                : Attempt.Done;
        }

        public Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct) => inner.ElevatedAsync(repair, ct);
    }

    private sealed class CredentialManager : IPrinterPasswords
    {
        public string? Get(string printerId) => CredentialStore.Get(printerId);
        public void Save(string printerId, string password) => CredentialStore.Save(printerId, password);
        public void Delete(string printerId) => CredentialStore.Delete(printerId);
        public void Rename(string oldId, string newId) => CredentialStore.Rename(oldId, newId);
    }
}

/// <summary>Printers' admin passwords (for settings and maintenance), by printer id.</summary>
public interface IPrinterPasswords
{
    string? Get(string printerId);
    void Save(string printerId, string password);
    void Delete(string printerId);
    void Rename(string oldId, string newId);
}

/// <summary>Passwords kept for this run only (demo mode: nothing is written to Windows Credential Manager).</summary>
public sealed class MemoryPasswords : IPrinterPasswords
{
    private readonly Dictionary<string, string> _saved = new(StringComparer.OrdinalIgnoreCase);
    public string? Get(string printerId) => _saved.GetValueOrDefault(printerId);
    public void Save(string printerId, string password) => _saved[printerId] = password;
    public void Delete(string printerId) => _saved.Remove(printerId);

    public void Rename(string oldId, string newId)
    {
        if (_saved.Remove(oldId, out var password)) _saved[newId] = password;
    }
}
