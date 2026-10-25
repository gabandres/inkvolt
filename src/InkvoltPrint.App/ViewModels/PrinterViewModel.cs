using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Presets;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Windows.Discovery;
using InkvoltPrint.Windows.Offline;
using InkvoltPrint.Windows.Printing;
using InkvoltPrint.Windows.Queues;
using InkvoltPrint.Windows.Security;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// One printer. Owns a background loop: connect (probe) → read status → wait on device events → re-read.
/// Offline printers are retried quietly; nothing here polls faster than the device's own event feed.
/// </summary>
public sealed partial class PrinterViewModel : ObservableObject, IDisposable
{
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan FallbackRefresh = TimeSpan.FromSeconds(30);

    public const int OverviewSection = 0, PrintSection = 1, ScanSection = 2, CopySection = 3, PhotosSection = 4, SettingsSection = 5;

    private readonly AppState _state;
    private readonly ScanPresetLibrary _presets;
    private readonly Action<PrinterViewModel> _remember;
    private readonly Func<HttpMessageHandler>? _transport;
    private CancellationTokenSource? _loop;
    private CancellationTokenSource? _watch;
    private PrinterConnection? _connection;
    private bool _discoveredQueue;
    private bool _windowsQueue;
    private readonly List<string> _previousHosts = [];

    /// <param name="transport">Demo mode: the printer's web server (no network, no Windows queue, no cached image).</param>
    public PrinterViewModel(string uuid, string name, string? model, string host, Uri? esclRoot, AppState state, ScanPresetLibrary presets,
        Action<PrinterViewModel> remember, Func<HttpMessageHandler>? transport = null)
    {
        _presets = presets;
        Uuid = uuid;
        Name = name;
        Model = model;
        Host = host;
        EsclRoot = esclRoot;
        _state = state;
        _remember = remember;
        _transport = transport;
        Print = new PrintViewModel(FindQueueAsync, state);
        Jobs = new PrintJobsViewModel(IsDemo ? Demo.PrintJobs : new Printing.WindowsPrintJobs(FindQueueAsync));
        Copy = new CopyViewModel(FindQueueAsync, state, IsDemo ? Demo.PrintJobs.Add : null) { HasQueue = QueueInstalled };
        Photos = new PhotosViewModel(FindQueueAsync, state, IsDemo ? Demo.PhotoQueue(uuid) : null);
        // Demo printers get a made-up PC (Demo.OfflinePc): the fixer never reads or touches this PC's queues for them.
        Fixer = new OfflineFixerViewModel(FixerDevice,
            IsDemo ? Demo.OfflinePc : new WindowsOfflineProbes(),
            new FixerRepairs(IsDemo ? Demo.OfflinePc : new WindowsOfflineRepairs(), this),
            AdoptAddress, canElevate: Features.ElevatedRepairs); // the demo PC's "elevation" is made up too
        Maintenance = new MaintenanceViewModel(uuid, name, state, OpenWebPage, IsDemo);
    }

    /// <summary>The Overview's Maintenance card: configuration page, cleaning, alignment, Identify, where the printer offers them.</summary>
    public MaintenanceViewModel Maintenance { get; }

    /// <summary>"Printer maintenance…" in the printer's menu: the view showing this printer's card scrolls to it and focuses it.</summary>
    public static event Action<PrinterViewModel>? MaintenanceRequested;

    [RelayCommand]
    private void ShowMaintenance()
    {
        SelectedSection = OverviewSection;
        Maintenance.FocusRequested = true; // the card takes it when it's (re)loaded, or right away below
        MaintenanceRequested?.Invoke(this);
    }

    /// <summary>"Printer offline? Fix it": the troubleshooter panel on the Overview.</summary>
    public OfflineFixerViewModel Fixer { get; }

    /// <summary>The printer as the fixer sees it: addresses it had, the queue Inkvolt Print knows, whether Windows can pair it.</summary>
    private OfflineDevice FixerDevice() => new(Uuid, Name, Model, Host)
    {
        PreviousHosts = _previousHosts.ToList(),
        StoredQueueName = IsDemo ? null : _state.GetQueueName(Uuid),
        CanPair = PrintEndpointId is not null || IsDemo,
    };

    /// <summary>The fixer found the printer at a new address (mDNS by UUID): reconnect there and remember it.</summary>
    private void AdoptAddress(string host)
    {
        if (string.Equals(host, Host, StringComparison.OrdinalIgnoreCase)) return;
        if (Host is { } old && !_previousHosts.Contains(old, StringComparer.OrdinalIgnoreCase)) _previousHosts.Add(old);
        Host = host;
        Restart();
        _remember(this);
    }

    [RelayCommand]
    private async Task OpenFixerAsync()
    {
        SelectedSection = OverviewSection;
        await Fixer.OpenAsync();
    }

    /// <summary>Setting a discovered queue up again is pairing, which this view model does; everything else is the PC's.</summary>
    private sealed class FixerRepairs(IOfflineRepairs inner, PrinterViewModel printer) : IOfflineRepairs
    {
        public async Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct)
        {
            if (repair.Kind != RepairKind.SetUpAgain || printer.IsDemo) return await inner.AsUserAsync(repair, ct);
            return await printer.ReinstallQueueAsync() is { } error
                ? new Attempt(AttemptResult.Failed, char.ToUpperInvariant(error[0]) + error[1..] + (error.EndsWith('.') ? "" : "."))
                : Attempt.Done;
        }

        public Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct) => inner.ElevatedAsync(repair, ct);
    }

    /// <summary>Copy and ID card copy: scan here, print through the Windows queue.</summary>
    public CopyViewModel Copy { get; }

    /// <summary>Print photos and other pictures with layouts, through the Windows queue.</summary>
    public PhotosViewModel Photos { get; }

    partial void OnQueueInstalledChanged(bool value) => Copy.HasQueue = value;

    /// <summary>This printer's Windows print queue (a card on the Overview).</summary>
    public PrintJobsViewModel Jobs { get; }

    /// <summary>This is the printer on screen (set by the main view model); the queue card refreshes only then.</summary>
    [ObservableProperty] public partial bool IsShown { get; set; }

    partial void OnIsShownChanged(bool value) => UpdateJobsVisibility();

    private void UpdateJobsVisibility() => Jobs.SetVisible(IsShown && SelectedSection == OverviewSection);

    /// <summary>Print a PDF. Works through the Windows queue, so it doesn't need the device connection.</summary>
    public PrintViewModel Print { get; }

    public string Uuid { get; }
    public bool IsDemo => _transport is not null;
    public Uri? EsclRoot { get; private set; }

    /// <summary>IPP URL from DNS-SD or the last connection (tried first when connecting); null: the IPP Everywhere default.</summary>
    public Uri? IppUri { get; set; }

    /// <summary>Who made it (HP when its LEDM interface answers); Other until connected.</summary>
    [ObservableProperty] public partial PrinterBrand Brand { get; set; }

    /// <summary>
    /// Connected, and not over HP's LEDM interface: a Canon, Epson, Brother or other IPP / eSCL printer. Status, supplies,
    /// scanning, copying and printing work; printer settings, firmware updates and page counts are HP only.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HpOnlyNote))]
    public partial bool IsNonHp { get; set; }

    /// <summary>A newer HP printer read over HP's CDM interface (no LEDM): status, supplies and details only.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HpOnlyNote))]
    public partial bool IsCdm { get; set; }

    public string? HpOnlyNote => IsCdm
        ? "This newer HP printer uses HP's CDM interface: Inkvolt Print reads its status, supplies and details, but its settings, " +
          "firmware updates and page counts aren't supported yet. Change settings on the printer's web page or its control panel."
        : IsNonHp
        ? "Printer settings, firmware updates and page counts use HP's own interface, so they're HP only. " +
          "Change settings on the printer's web page or its control panel."
        : null;

    /// <summary>"Toner", "Ink", or "Supplies" when the printer reports a mix (drums, waste boxes…).</summary>
    public string SuppliesTitle
    {
        get
        {
            if (Supplies.Count == 0 || Supplies.Any(s => s.Supply.IsWaste && s.Supply.Kind.Contains("toner", StringComparison.OrdinalIgnoreCase)))
                return "Supplies";
            var kinds = Supplies.Where(s => !s.Supply.IsWaste).Select(s => s.Supply.Kind).ToList();
            if (kinds.Count > 0 && kinds.All(k => k.Contains("toner", StringComparison.OrdinalIgnoreCase)) && kinds.Count == Supplies.Count)
                return "Toner";
            if (kinds.Count > 0 && kinds.All(k => k.Contains("ink", StringComparison.OrdinalIgnoreCase))) return "Ink";
            return "Supplies";
        }
    }

    private Uri? _webPage;

    [ObservableProperty] public partial string Name { get; set; }
    [ObservableProperty] public partial string? Model { get; set; }
    [ObservableProperty] public partial string? Host { get; set; }
    [ObservableProperty] public partial BitmapSource? Image { get; set; }
    [ObservableProperty] public partial string? StatusDetail { get; set; }

    /// <summary>"About this printer" rows: model, address, serial, firmware…</summary>
    public ObservableCollection<InfoRow> About { get; } = [];

    /// <summary>Lifetime counters as big-number tiles.</summary>
    public ObservableCollection<InfoRow> Stats { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind))]
    public partial bool IsConnecting { get; set; } = true;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind), nameof(IsStale), nameof(StaleSuffix))]
    public partial bool IsOnline { get; set; }

    [ObservableProperty] public partial string StatusMessage { get; set; } = "Connecting…";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind))]
    public partial Severity StatusSeverity { get; set; } = Severity.Info;

    /// <summary>For the status dot: connecting, offline, ok, warning, error.</summary>
    public string StatusKind => !IsOnline ? (IsConnecting ? "connecting" : "offline")
        : StatusSeverity switch { Severity.Error => "error", Severity.Warning => "warning", _ => "ok" };

    /// <summary>Toner and usage figures on screen are from before the printer went offline.</summary>
    public bool IsStale => !IsOnline && (Supplies.Count > 0 || Stats.Count > 0);

    public string StaleSuffix => IsStale ? "  ·  last known" : "";

    public ObservableCollection<PrinterAlert> Alerts { get; } = [];
    public ObservableCollection<SupplyViewModel> Supplies { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NeedsSetup), nameof(SetupResult), nameof(SetupNeedsAdmin), nameof(SetupInSettings))]
    [NotifyCanExecuteChangedFor(nameof(SetUpCommand))]
    public partial string? PrintEndpointId { get; set; }

    /// <summary>A Windows print queue exists for this printer (seen by discovery or found among installed queues).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NeedsSetup), nameof(SetupResult))]
    public partial bool QueueInstalled { get; set; } = true;

    [ObservableProperty] public partial string? ScanEndpointId { get; set; }
    [ObservableProperty] public partial bool ScannerInstalled { get; set; } = true;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SetUpCommand))]
    public partial bool IsInstalling { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SetupResult))]
    public partial string? SetupMessage { get; set; }

    /// <summary>Outcome line shown after the setup banner has gone away.</summary>
    public string? SetupResult => NeedsSetup ? null : SetupMessage;

    /// <summary>No Windows queue yet. Discovered printers pair; printers added by address get an IPP queue (one UAC prompt).</summary>
    public bool NeedsSetup => !QueueInstalled && (PrintEndpointId is not null || Host is not null);

    /// <summary>True when setup will need administrator permission (printer added by address).</summary>
    public bool SetupNeedsAdmin => PrintEndpointId is null && Features.ElevatedQueueSetup;

    /// <summary>Printer added by address in a packaged copy: Windows Settings adds the queue (<see cref="Features.ElevatedQueueSetup"/>).</summary>
    public bool SetupInSettings => PrintEndpointId is null && !Features.ElevatedQueueSetup;

    /// <summary>The address Windows' "Add a printer using an IP address or hostname" needs for this printer.</summary>
    private Uri IppUrl => IppUri is { Scheme: "http" } known && known.Host == Host ? known : new UriBuilder("http", Host!, 631, "ipp/print").Uri;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowScanShortcut))]
    public partial ScanViewModel? Scan { get; set; }

    [ObservableProperty] public partial SettingsViewModel? Settings { get; set; }

    /// <summary>Index of the visible section tab (see the *Section constants).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowScanShortcut), nameof(ShowPrintShortcut))]
    public partial int SelectedSection { get; set; }

    public bool ShowScanShortcut => Scan is not null && SelectedSection != ScanSection;
    public bool ShowPrintShortcut => SelectedSection != PrintSection;

    partial void OnSelectedSectionChanged(int value)
    {
        EnsureSectionLoaded();
        UpdateJobsVisibility();
    }

    partial void OnSettingsChanged(SettingsViewModel? value) => EnsureSectionLoaded();

    /// <summary>Settings are read from the printer only when their section is shown (also after switching printers).</summary>
    public void EnsureSectionLoaded()
    {
        if (SelectedSection == SettingsSection && Settings is { IsLoaded: false } s && s.LoadCommand.CanExecute(null))
            s.LoadCommand.Execute(null);
        if (SelectedSection == CopySection) Copy.Shown();
        if (SelectedSection == PhotosSection) Photos.Shown();
    }

    public void Start()
    {
        if (_loop is not null || _suspended) return;
        _loop = new CancellationTokenSource();
        _ = RunAsync(_loop.Token);
        if (!IsDemo) _ = RefreshQueueAsync();
    }

    /// <summary>Each status read (or failure to reach the printer): the tray's alerts (Tray/TrayController) follow these.</summary>
    public event Action<PrinterSnapshot>? Observed;

    /// <summary>The last of those reads, for a listener that comes later.</summary>
    public PrinterSnapshot? LastSnapshot { get; private set; }

    private void Observe(PrinterSnapshot snap)
    {
        LastSnapshot = snap;
        Observed?.Invoke(snap);
    }

    private bool _suspended, _reprobe;

    /// <summary>
    /// The window went to the notification area: stop the live connection loop (LEDM event feed, IPP refresh every 30 s,
    /// retries every 20 s). The tray then reads this printer now and then with <see cref="CheckOnceAsync"/>. The connection
    /// object stays (no request is made on it while idle), so unsaved scans and a scan in progress keep theirs.
    /// </summary>
    public void Suspend()
    {
        _suspended = true;
        _loop?.Cancel();
        _loop = null;
        Jobs.SetVisible(false);
    }

    /// <summary>The window is back: the live loop again, on the same connection unless it was lost or the address changed.</summary>
    public void Resume()
    {
        if (!_suspended) return;
        _suspended = false;
        if (_loop is not null) return;
        _loop = new CancellationTokenSource();
        _ = RunAsync(_loop.Token, IsOnline && !_reprobe ? _connection : null);
        _reprobe = false;
        UpdateJobsVisibility();
    }

    /// <summary>One read while suspended (the tray's low-frequency check): connects first when needed. True when it answered.</summary>
    public async Task<bool> CheckOnceAsync(CancellationToken ct)
    {
        try
        {
            if (_connection is null || !IsOnline || _reprobe)
            {
                _reprobe = false;
                if (await ConnectAsync(ct) is not { } conn) return false;
                Attach(conn);
            }
            await RefreshAsync(ct);
            return IsOnline;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            Log.Write($"[{Name}] check failed: {ex.Message}");
            SetOffline();
            return false;
        }
    }

    public void ApplyDiscovery(DiscoveredPrinter d)
    {
        PrintEndpointId = d.PrintEndpointId;
        _discoveredQueue = d.QueueInstalled;
        QueueInstalled = _discoveredQueue || _windowsQueue;
        ScanEndpointId = d.ScanEndpointId;
        ScannerInstalled = d.ScannerInstalled;
        Model ??= d.Model;
        if (d.Host is not null && !string.Equals(d.Host, Host, StringComparison.OrdinalIgnoreCase))
        {
            _ = MoveIfSameDeviceAsync(d);
            return;
        }
        if (d.EsclRoot is not null) EsclRoot = d.EsclRoot;
        if (d.IppUri is not null) IppUri = d.IppUri;
        if (!IsOnline && !IsConnecting && d.Host is not null)
            Restart(); // mDNS just saw it again; don't wait for the retry timer
    }

    private string? _checkingHost;
    private (string Host, DateTime At)? _refusedHost;

    /// <summary>
    /// mDNS announces the printer at another address: DHCP may have moved it, or the announcement is of an address this PC
    /// can't use (a VM's or VPN's). The address in use, perhaps typed by the user, is kept unless the new one answers with
    /// this printer's UUID; then it reconnects there (the old one still identifies its Windows queue's port).
    /// </summary>
    private async Task MoveIfSameDeviceAsync(DiscoveredPrinter d)
    {
        var host = d.Host!;
        if (string.Equals(_checkingHost, host, StringComparison.OrdinalIgnoreCase)) return;
        if (_refusedHost is { } refused && string.Equals(refused.Host, host, StringComparison.OrdinalIgnoreCase)
            && DateTime.UtcNow - refused.At < RetryDelay * 3)
            return; // announced again and again: that address is asked again only now and then
        _checkingHost = host;
        try
        {
            DeviceIdentity identity;
            bool answers;
            using (var http = new DeviceHttp(host, _transport?.Invoke()))
            {
                var probe = await PrinterConnection.ProbeAsync(http, d.EsclRoot, ippHint: d.IppUri);
                answers = probe.Reachable;
                identity = answers ? PrinterId.Identify(Uuid, host, probe.ReportedUuids) : DeviceIdentity.Unknown;
            }
            // A printer that reports no UUID over HTTP is taken at its word (mDNS) only when the old address no longer works.
            if (identity != DeviceIdentity.Same && !(identity == DeviceIdentity.Unknown && answers && !IsOnline))
            {
                _refusedHost = (host, DateTime.UtcNow);
                Log.Write($"[{Name}] announced at another address that " +
                          $"{(identity == DeviceIdentity.Different ? "is another device" : "doesn't answer as this printer")}; keeping its address");
                return;
            }
            _refusedHost = null;
            if (string.Equals(host, Host, StringComparison.OrdinalIgnoreCase)) return;
            if (Host is { } old && !_previousHosts.Contains(old, StringComparer.OrdinalIgnoreCase)) _previousHosts.Add(old);
            Host = host;
            if (d.EsclRoot is not null) EsclRoot = d.EsclRoot;
            if (d.IppUri is not null) IppUri = d.IppUri;
            Restart();
        }
        catch (Exception ex)
        {
            _refusedHost = (host, DateTime.UtcNow);
            Log.Write($"[{Name}] announced at another address that couldn't be checked: {ex.Message}");
        }
        finally
        {
            _checkingHost = null;
        }
    }

    /// <summary>
    /// This printer's Windows queue: the one whose device container is the printer (discovered/paired queues), or
    /// the queue Inkvolt Print created by address (Windows doesn't promise those share the printer's container id).
    /// </summary>
    public async Task<string?> FindQueueAsync()
    {
        if (IsDemo) return null; // never print to a real queue
        if (await QueueFinder.FindQueueNameAsync(Uuid) is { } byContainer) return byContainer;
        if (_state.GetQueueName(Uuid) is { } created
            && (await QueueFinder.ListAsync()).Any(q => string.Equals(q.Name, created, StringComparison.OrdinalIgnoreCase)))
            return created;
        // Added in Windows Settings by address: Windows names the queue itself, but its port carries the address.
        if (Host is not { } host || await Task.Run(() => Printing.QueuePrinter.FindByHost(host)) is not { } byPort) return null;
        _state.SetQueueName(Uuid, byPort);
        return byPort;
    }

    /// <summary>Looks for an installed Windows queue for this printer.</summary>
    public async Task RefreshQueueAsync()
    {
        try
        {
            _windowsQueue = await FindQueueAsync() is not null;
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"[{Name}] queue lookup failed: {ex.Message}");
            return;
        }
        QueueInstalled = _discoveredQueue || _windowsQueue;
        OnPropertyChanged(nameof(SetupNeedsAdmin));
        OnPropertyChanged(nameof(SetupInSettings));
    }

    /// <summary>After sending the user to Settings: notice the new queue when it appears (checks for ten minutes).</summary>
    private async Task WatchForQueueAsync(CancellationToken ct)
    {
        try
        {
            for (var i = 0; i < 120 && !QueueInstalled; i++)
            {
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
                await RefreshQueueAsync();
            }
            if (QueueInstalled)
            {
                SetupMessage = "Ready to print from any app.";
                Print.QueueChanged();
                Copy.QueueChanged();
                Photos.QueueChanged();
                Jobs.QueueChanged();
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Restart()
    {
        if (_suspended)
        {
            _reprobe = true; // the next check (or Resume) connects again, at the new address
            return;
        }
        _loop?.Cancel();
        _loop = null;
        Start();
    }

    /// <param name="reuse">A connection still good from before <see cref="Suspend"/>: watched again without probing.</param>
    private async Task RunAsync(CancellationToken ct, PrinterConnection? reuse = null)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var conn = reuse;
                reuse = null;
                if (conn is null)
                {
                    IsConnecting = true;
                    conn = await ConnectAsync(ct);
                    if (conn is null)
                    {
                        await Task.Delay(RetryDelay, ct);
                        continue;
                    }
                    Attach(conn);
                }
                await foreach (var _ in conn.WatchAsync(FallbackRefresh, ct))
                {
                    await RefreshAsync(ct);
                    // Gone: connect again after a pause, which checks it's still this printer (DHCP may give its address to another device).
                    if (!IsOnline) break;
                }
                if (!IsOnline) await Task.Delay(RetryDelay, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                Log.Write($"[{Name}] connection loop: {ex}");
                SetOffline();
                try { await Task.Delay(RetryDelay, ct); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    /// <summary>
    /// Probes the printer's address. Null, with the status set, when nothing answers there or another device does (it reports
    /// other UUIDs): that device's status, supplies and alerts are never shown or alerted under this printer's name.
    /// </summary>
    private async Task<PrinterConnection?> ConnectAsync(CancellationToken ct)
    {
        var conn = await PrinterConnection.OpenAsync(Host!, EsclRoot, ct, new PinStore(_state, Uuid), _transport?.Invoke(), IppUri);
        if (!conn.Probe.Reachable)
        {
            conn.Dispose();
            SetOffline();
            return null;
        }
        if (PrinterId.Identify(Uuid, Host!, conn.Probe.ReportedUuids) == DeviceIdentity.Different)
        {
            conn.Dispose();
            Log.Write($"[{Name}] a different device answers at its address; not connecting"); // never the UUIDs themselves
            SetOffline("A different device answers at this address",
                $"Another device now has {Host}, so its status isn't shown here. The printer probably got a new address: " +
                "Inkvolt Print watches for it on the network, or choose Fix it… to find it.");
            return null;
        }
        return conn;
    }

    private void Attach(PrinterConnection conn)
    {
        var old = _connection;
        _connection = conn;
        var p = conn.Probe;
        if (p.Product?.MakeAndModel is { } mm) Name = mm;
        Model = p.Model ?? Model;
        IppUri = p.IppEndpoint ?? IppUri;
        Brand = p.Brand;
        IsNonHp = !p.HasHpInterfaces;
        IsCdm = !p.HasHpInterfaces && p.Cdm is not null;
        _webPage = p.WebPage;
        Sync(About, new InfoRow?[]
        {
            new("Model", p.Model ?? Model ?? Name),
            new("IP address", Host ?? "—"),
            p.Location is { } where ? new("Location", where) : null,
            p.Product?.SerialNumber is { } sn ? new("Serial number", sn) : null,
            p.Product?.ProductNumber is { } pn ? new("Product number", pn) : null,
            p.Firmware is { } fw ? new("Firmware", fw.Display) : null,
            new("Connected via", string.Join(", ", p.Interfaces)),
        }.OfType<InfoRow>().ToList());
        if (Image is null && !IsDemo) _ = LoadImageAsync(conn);
        _ = Maintenance.AttachAsync(conn); // reads only: what the printer offers

        // A scanner offering neither glass nor feeder (only a camera, say) has nothing Inkvolt Print can scan from.
        var scanner = conn.Scanner is not null && p.Scanner?.Sources.Any() == true ? conn.Scanner : null;
        Copy.Attach(scanner, scanner is null ? null : p.Scanner);
        // Rebind rather than replace, so scanned-but-unsaved pages survive a reconnect.
        if (scanner is not null && p.Scanner is not null)
        {
            if (Scan is null) Scan = new ScanViewModel(scanner, p.Scanner, _state, _presets, Name, FindQueueAsync, IsDemo ? Demo.PrintJobs.Add : null);
            else Scan.Rebind(scanner);
        }
        if (conn.Ledm is not null)
        {
            if (Settings is null) Settings = new SettingsViewModel(conn, Uuid, Name, _state, IsDemo ? null : OpenWebPage);
            else Settings.Rebind(conn);
        }
        // A saved password is only attached once this printer's certificate is pinned. Without a pin (older
        // version, reset state) the first save asks for it instead, and that handshake pins the certificate.
        if (!IsDemo && CredentialStore.Get(Uuid) is { } pw && _state.GetCertificatePin(Uuid) is not null)
            conn.Http.SetCredentials("admin", pw);

        _remember(this);
        old?.Dispose();
    }

    private async Task RefreshAsync(CancellationToken ct)
    {
        var conn = _connection;
        if (conn is null) return;
        var statusTask = conn.GetStatusAsync(ct);
        var suppliesTask = conn.GetSuppliesAsync(ct);
        var usageTask = conn.Ledm?.GetUsageAsync(ct) ?? Task.FromResult<UsageCounters?>(null);

        var status = await statusTask;
        if (status.Code == "offline")
        {
            SetOffline();
            ObserveQuietly(suppliesTask, usageTask);
            return;
        }
        IReadOnlyList<Consumable>? read = null;
        IsConnecting = false;
        IsOnline = true;
        if (!status.IsUnavailable)
        {
            // An unusable reply (printer waking up) keeps the last good status instead of flashing an error.
            StatusMessage = status.Message;
            StatusDetail = status.Detail;
            StatusSeverity = status.Severity;
            Sync(Alerts, status.Alerts);
        }
        Maintenance.Update(true, status);

        try
        {
            var supplies = await suppliesTask;
            read = supplies;
            Sync(Supplies, supplies.Select(s => new SupplyViewModel(s)).ToList());
            OnPropertyChanged(nameof(SuppliesTitle));
            if (await usageTask is { } u)
                Sync(Stats, new InfoRow?[]
                {
                    u.TotalImpressions is { } t ? new($"{t:N0}", "pages printed") : null,
                    u.DuplexSheets is { } d ? new($"{d:N0}", "two-sided sheets") : null,
                    u.ScanImages is { } sc ? new($"{sc:N0}", "pages scanned") : null,
                    u.JamEvents is { } j ? new($"{j:N0}", "paper jams") : null,
                }.OfType<InfoRow>().ToList());
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            // Status is what matters; supplies refresh on the next event.
        }
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(StaleSuffix));
        Observe(new PrinterSnapshot(Uuid, Name, true, status.IsUnavailable ? null : status, read));
    }

    private static void ObserveQuietly(params Task[] tasks)
    {
        foreach (var t in tasks) _ = t.ContinueWith(x => _ = x.Exception, TaskContinuationOptions.OnlyOnFaulted);
    }

    private void SetOffline() => SetOffline("Can't reach the printer",
        $"Make sure it's turned on and connected to the same network as this PC{(Host is null ? "" : $" ({Host})")}. Inkvolt Print keeps trying in the background.");

    private void SetOffline(string message, string detail)
    {
        IsConnecting = false;
        IsOnline = false;
        StatusMessage = message;
        StatusDetail = detail;
        StatusSeverity = Severity.Error;
        Alerts.Clear();
        Maintenance.Update(false, null);
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(StaleSuffix));
        Observe(new PrinterSnapshot(Uuid, Name, false, null, null));
    }

    /// <summary>The printer's own product photo (served by its web server), cached so it shows instantly next time.</summary>
    private async Task LoadImageAsync(PrinterConnection conn)
    {
        var cache = Path.Combine(AppState.DataDirectory, "images", $"{PrinterId.FileName(Uuid)}.png");
        try
        {
            byte[]? bytes = File.Exists(cache) ? await File.ReadAllBytesAsync(cache) : null;
            if (bytes is null)
            {
                // IPP printer-icons first (any IPP Everywhere printer), then the paths HP printers serve.
                var urls = conn.Probe.Icons.Concat(new[] { "/ipp/images/printer-large.png", "/ipp/images/printer.png" }.Select(conn.Http.Http));
                foreach (var url in urls)
                    if ((bytes = await conn.Http.GetBytesOrNullAsync(url)) is not null) break;
                if (bytes is null) return;
                Directory.CreateDirectory(Path.GetDirectoryName(cache)!);
                await File.WriteAllBytesAsync(cache, bytes);
            }
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.DecodePixelWidth = 256;
            img.StreamSource = new MemoryStream(bytes);
            img.EndInit();
            img.Freeze();
            Image = img;
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"[{Name}] no printer image: {ex.Message}"); // cosmetic only
        }
    }

    private static void Sync<T>(ObservableCollection<T> target, IReadOnlyList<T> source)
    {
        if (target.SequenceEqual(source)) return;
        target.Clear();
        foreach (var s in source) target.Add(s);
    }

    private bool CanSetUp() => !IsInstalling && (PrintEndpointId is not null || Host is not null);

    /// <summary>
    /// One click. Discovered printers: pairs the IPP endpoint (no prompt), then adds the Windows scanner in the
    /// background (only other apps need it; Inkvolt Print scans over eSCL). Printers added by address: creates an
    /// IPP Class Driver queue from the printer's IPP URL, which Windows only allows with one UAC prompt.
    /// </summary>
    [RelayCommand(CanExecute = nameof(CanSetUp))]
    private async Task SetUpAsync()
    {
        if (SetupInSettings)
        {
            var url = IppUrl.AbsoluteUri;
            try { System.Windows.Clipboard.SetText(url); }
            catch (Exception ex) { Trace.WriteLine($"[{Name}] clipboard: {ex.Message}"); } // the message shows the address too
            Shell.Open("ms-settings:printers");
            SetupMessage = "In Settings, choose Add device, then “Add manually” › “Add a printer using an IP address or hostname”. " +
                $"Pick “IPP Device” and paste {url} (it’s on the clipboard). Inkvolt Print notices the printer when it’s added.";
            _watch?.Cancel();
            _watch = new CancellationTokenSource();
            _ = WatchForQueueAsync(_watch.Token);
            return;
        }
        IsInstalling = true;
        SetupMessage = SetupNeedsAdmin
            ? "Setting up… approve the Windows permission prompt to add the printer."
            : "Setting up… Windows is adding the printer (about 30 seconds).";
        try
        {
            InstallResult print;
            if (PrintEndpointId is { } endpoint)
            {
                print = await QueueInstaller.InstallAsync(endpoint);
            }
            else
            {
                var queueName = IppQueueInstaller.SafeQueueName($"{Name} ({Host})");
                print = await IppQueueInstaller.InstallAsync(queueName, IppUrl);
                if (print.Outcome is InstallOutcome.Installed or InstallOutcome.AlreadyInstalled)
                    _state.SetQueueName(Uuid, IppQueueInstaller.SafeQueueName(queueName));
            }

            if (print.Outcome is InstallOutcome.Installed or InstallOutcome.AlreadyInstalled)
            {
                _windowsQueue = true;
                QueueInstalled = true;
                SetupMessage = "Ready to print from any app.";
                Print.QueueChanged();
                Copy.QueueChanged();
                Photos.QueueChanged();
                Jobs.QueueChanged();
                if (ScanEndpointId is { } scan && !ScannerInstalled)
                    _ = QueueInstaller.InstallAsync(scan, timeout: TimeSpan.FromSeconds(90)); // best effort
            }
            else
            {
                SetupMessage = print.Message;
            }
        }
        catch (Exception ex)
        {
            Log.Write($"[{Name}] setup failed: {ex}");
            SetupMessage = $"Setup failed: {ex.Message}";
        }
        finally
        {
            IsInstalling = false;
        }
    }

    /// <summary>Removes and re-creates this printer's Windows queue (pairing). Returns null on success.</summary>
    public async Task<string?> ReinstallQueueAsync()
    {
        if (PrintEndpointId is not { } endpoint) return "not discovered on the network, so it can't be set up again automatically";
        // Removing the queue only to fail re-adding it would leave every app unable to print: only start when the
        // printer is awake and answering, and nothing is printing through Inkvolt Print.
        if (!IsOnline) return "the printer isn't reachable right now. Turn it on, then use Set up";
        if (Print.IsBusy) return "a print job is being sent. Try again when it's done";
        IsInstalling = true;
        Print.QueueBusy = Photos.QueueBusy = true; // no new jobs while the queue is being re-created
        try
        {
            if (!await QueueInstaller.UninstallAsync(endpoint)) return "Windows didn't remove the old printer";
            InstallResult result = new(InstallOutcome.Failed, "not attempted");
            for (var attempt = 0; attempt < 3; attempt++)
            {
                await Task.Delay(TimeSpan.FromSeconds(3 + attempt * 5)); // let the spooler finish; give a sleeping printer time
                result = await QueueInstaller.InstallAsync(endpoint);
                if (result.Outcome is InstallOutcome.Installed or InstallOutcome.AlreadyInstalled) break;
            }
            _windowsQueue = result.Outcome is InstallOutcome.Installed or InstallOutcome.AlreadyInstalled;
            QueueInstalled = _discoveredQueue || _windowsQueue;
            Print.QueueChanged();
            Copy.QueueChanged();
            Photos.QueueChanged();
            Jobs.QueueChanged();
            return _windowsQueue ? null : $"{result.Message} Use Set up on this printer to add it again.";
        }
        catch (Exception ex)
        {
            Log.Write($"[{Name}] reinstall failed: {ex}");
            return ex.Message;
        }
        finally
        {
            IsInstalling = false;
            Print.QueueBusy = Photos.QueueBusy = false;
        }
    }

    [RelayCommand]
    private void OpenWebPage()
    {
        if (Host is not null && !IsDemo) Shell.Open(_webPage?.AbsoluteUri ?? $"https://{Host}/");
    }

    [RelayCommand]
    private void OpenPrintQueue() => Shell.Open("ms-settings:printers");

    [RelayCommand]
    private void Reconnect() => Restart();

    [RelayCommand]
    private void GoToScan() => SelectedSection = ScanSection;

    /// <summary>A preset button on the Overview's scan card (or Ctrl+1…9, or the jump list): run it on the Scan tab.</summary>
    [RelayCommand]
    public async Task RunPresetAsync(ScanPreset? preset)
    {
        if (Scan is not { } scan || preset is null) return;
        SelectedSection = ScanSection;
        if (scan.RunPresetCommand.CanExecute(preset)) await scan.RunPresetCommand.ExecuteAsync(preset);
    }

    [RelayCommand]
    private void GoToPrint() => SelectedSection = PrintSection;

    /// <summary>Drag-and-drop / "Open with": jump to Print and load the file.</summary>
    public Task OpenPdfAsync(string path)
    {
        SelectedSection = PrintSection;
        return Print.OpenAsync(path);
    }

    /// <summary>Drag-and-drop / "Open with" for pictures: jump to Photos and add them.</summary>
    public Task OpenPhotosAsync(IReadOnlyList<string> paths)
    {
        SelectedSection = PhotosSection;
        return Photos.AddAsync(paths);
    }

    [RelayCommand]
    private void GoToPhotos() => SelectedSection = PhotosSection;

    public void Dispose()
    {
        Jobs.SetVisible(false);
        _loop?.Cancel();
        _loop = null;
        _watch?.Cancel();
        _watch = null;
        Fixer.CloseCommand.Execute(null);
        _connection?.Dispose();
        _connection = null;
    }

    /// <summary>Certificate fingerprint remembered per printer UUID in the app state.</summary>
    private sealed class PinStore(AppState state, string uuid) : ICertificatePin
    {
        public string? Get(int port) => state.GetCertificatePin(uuid, port);
        public string SetIfAbsent(int port, string sha256Hex) => state.SetCertificatePinIfAbsent(uuid, port, sha256Hex);
    }
}

public sealed record InfoRow(string Label, string Value);

public sealed record SupplyViewModel(Consumable Supply)
{
    /// <summary>"About 100 pages left", or the state when no estimate is available; null for a waste box with room left.</summary>
    public string? Headline => Supply.State switch
    {
        "full" => "Replace now",
        "almostFull" => "Replace soon",
        "out" => "Empty — replace now",
        _ when Supply.IsWaste => null,
        _ when Supply.EstimatedPagesRemaining is { } pages => $"About {pages:N0} pages left",
        _ when Supply.IsLow => "Running low",
        _ => "OK",
    };

    public string? Cartridge => string.Join("  ·  ", new[]
    {
        Supply.SelectibilityNumber is { } sel ? $"HP {sel}" : null, // LEDM (HP) only
        Supply.ProductNumber,
    }.Where(s => s is not null)) is { Length: > 0 } c ? $"Replacement: {c}" : null;

    public string Level => Supply.State is "out" or "full" ? "empty" : IsLow ? "low" : "ok";

    public string Name => Supply.Name;
    public double Percent => Supply.PercentRemaining ?? 0;

    /// <summary>A percentage to show (and a bar). Waste boxes and unknown levels have none.</summary>
    public bool HasPercent => Supply.PercentRemaining is not null;

    /// <summary>The big figure: "45%", or for supplies without a level their state ("OK", "Almost full", "Full", "—").</summary>
    public string PercentText => Supply.PercentRemaining is { } p ? $"{p}%" : Supply.State switch
    {
        "full" => "Full",
        "almostFull" => "Almost full",
        "out" => "Empty",
        "ok" => "OK",
        _ => "—",
    };

    public bool IsLow => Supply.IsLow;

    /// <summary>K, C, M, Y or #RRGGBB for the color swatch; null when the supply has no color (a waste box).</summary>
    public string? ColorCode => Supply.ColorCode;

    /// <summary>For screen readers: "Cyan ink, 55%, OK" or "Maintenance box, OK".</summary>
    public string AccessibleText => string.Join(", ", new[] { Name, PercentText, Headline is { } h && h != PercentText ? h : null }.OfType<string>());
}
