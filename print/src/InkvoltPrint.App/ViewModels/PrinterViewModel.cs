using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Presets;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Wia;
using InkvoltPrint.Windows.Discovery;
using InkvoltPrint.Windows.Queues;

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
    private readonly PcEnvironment _pc;
    private CancellationTokenSource? _loop;
    private CancellationTokenSource? _watch;
    private readonly PrinterSession _session;
    private bool _discoveredQueue;
    private bool _windowsQueue;
    private readonly List<string> _previousHosts = [];
    private readonly IQueueStatusSource? _queueSource;
    private readonly IWiaSystem? _wiaSystem;
    private WiaDeviceInfo? _wiaDevice;
    private WiaScanner? _wia;
    private bool _wiaConnecting;

    /// <param name="pc">This PC, or the demo's made-up one: the network, Windows' queues, the fixer's checks and repairs (<see cref="PcEnvironment"/>).</param>
    public PrinterViewModel(string uuid, string name, string? model, string? host, Uri? esclRoot, AppState state, ScanPresetLibrary presets,
        Action<PrinterViewModel> remember, PcEnvironment pc)
    {
        _presets = presets;
        Uuid = uuid;
        Name = name;
        Model = model;
        Host = host;
        EsclRoot = esclRoot;
        _state = state;
        _remember = remember;
        _pc = pc;
        _session = new PrinterSession(uuid, new PrinterRecipe(pc.DeviceTransport, pc.Snmp, new PinStore(state, uuid)),
            () => state.GetAcceptedUuids(uuid), uuids => state.AcceptUuids(uuid, uuids));
        Print = new PrintViewModel(FindQueueAsync, state);
        Jobs = new PrintJobsViewModel(pc.PrintJobs(FindQueueAsync));
        Copy = new CopyViewModel(FindQueueAsync, state, pc.MadeUpPrint) { HasQueue = QueueInstalled };
        Photos = new PhotosViewModel(FindQueueAsync, state, pc.PhotoQueue(uuid));
        Fixer = new OfflineFixerViewModel(FixerDevice, pc.OfflineProbes, pc.OfflineRepairs(ReinstallQueueAsync), AdoptAddress,
            canElevate: Features.ElevatedRepairs);
        Maintenance = new MaintenanceViewModel(uuid, name, state, OpenWebPage, pc);
        Copy.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(CopyViewModel.HasScanner)) OnPropertyChanged(nameof(ShowCopy));
        };
    }

    /// <summary>
    /// A printer known only by its Windows queue (USB, WSD, an older network printer, one shared from another PC): status from
    /// <paramref name="source"/> (the spooler and driver), the print queue card, Print a PDF and Print photos through the queue, and
    /// the offline fixer on that queue. No device connection, so no scanning, settings or maintenance. On the demo's made-up PC the
    /// queue is made up and nothing is printed.
    /// </summary>
    public PrinterViewModel(SpoolerQueue queue, IQueueStatusSource source, AppState state, ScanPresetLibrary presets,
        Action<PrinterViewModel> remember, PcEnvironment pc)
        : this(QueueKinds.IdFor(queue.Name), QueueKinds.DisplayName(queue), queue.DriverName, null, null, state, presets, remember, pc)
    {
        _queueSource = source;
        WindowsQueue = queue;
        Sync(About, new InfoRow?[]
        {
            new("Windows printer", queue.Name),
            queue.DriverName is { Length: > 0 } driver ? new("Driver", driver) : null,
            new("Connected via", QueueKinds.ConnectionDetail(queue)),
            queue.Location is { Length: > 0 } where ? new("Location", where) : null,
            queue.Comment is { Length: > 0 } comment ? new("Comment", comment) : null,
        }.OfType<InfoRow>().ToList());
    }

    /// <summary>
    /// A scanner Windows has a driver for (WIA) that belongs to no printer on the list: a USB flatbed, a sheet-fed scanner, an
    /// all-in-one whose printer part isn't here. Overview and Scan only (no queue: no Print, Copy or Photos). It's connected in the
    /// background, and again every 30 s while it doesn't answer.
    /// </summary>
    public PrinterViewModel(WiaDeviceInfo scanner, IWiaSystem wia, AppState state, ScanPresetLibrary presets,
        Action<PrinterViewModel> remember, PcEnvironment pc)
        : this(PrinterList.ScannerIdFor(scanner.Id), scanner.Name, scanner.Description, null, null, state, presets, remember, pc)
    {
        _wiaSystem = wia;
        ScannerDevice = scanner;
        QueueInstalled = false;
        Jobs.CanFix = false;
        Sync(About, new InfoRow?[]
        {
            new("Windows scanner", scanner.Name),
            scanner.Manufacturer is { Length: > 0 } maker ? new("Driver from", maker) : null,
            scanner.ConnectionText is { } via ? new("Connected via", scanner.IsEscl ? $"{via} (Windows' eSCL driver)" : via) : null,
        }.OfType<InfoRow>().ToList());
    }

    /// <summary>A scanner listed on its own (<see cref="ScannerDevice"/>), not a printer.</summary>
    public bool IsScannerOnly => ScannerDevice is not null;

    /// <summary>The WIA scanner this entry is (<see cref="IsScannerOnly"/>); null for printers.</summary>
    public WiaDeviceInfo? ScannerDevice { get; }

    /// <summary>A printer found on the network or added by address (not a Windows queue or a scanner on its own).</summary>
    public bool IsNetworkPrinter => !IsQueuePrinter && !IsScannerOnly;

    /// <summary>The icon when there's no product photo: a printer, or a scanner for a scanner on its own (Segoe Fluent Icons).</summary>
    public string Glyph => IsScannerOnly ? "" : "";

    public string AboutTitle => IsScannerOnly ? "About this scanner" : "About this printer";

    /// <summary>Print a PDF, Print photos and the print queue: every printer, not a scanner on its own.</summary>
    public bool CanPrint => !IsScannerOnly;

    /// <summary>The WIA scanner in use for this entry (its id), when there is one.</summary>
    public string? WiaDeviceId => _wiaDevice?.Id;

    /// <summary>
    /// Scanning through Windows would help: a queue printer, a scanner on its own, or a network printer that answered without
    /// eSCL. A network printer not connected yet isn't (it may well have eSCL).
    /// </summary>
    public bool WantsWindowsScanner => IsQueuePrinter || IsScannerOnly || (_session.Connection is { } c && c.Scanner is null);

    /// <summary>The Windows queue this printer is known by (<see cref="IsQueuePrinter"/>); null for a network printer.</summary>
    public SpoolerQueue? WindowsQueue { get; }

    /// <summary>Listed from its Windows queue, not found on the network: status comes from Windows and the driver.</summary>
    public bool IsQueuePrinter => _queueSource is not null;

    /// <summary>For the status card of a queue printer: where its status comes from and what that leaves out.</summary>
    public string? StatusSourceNote => IsScannerOnly
        ? "A scanner Windows has a driver for: Inkvolt Print scans with it through Windows (WIA). Scanners report no status " +
          "this way, so a problem (no paper in the feeder, a jam) shows when you scan."
        : _queueSource is not { } source ? null
        : source.HasSupplyLevels
        ? $"Status and supply levels from {source.Origin}. No settings or maintenance for this printer here" +
          (_wia is null ? ", and no scanning." : "; it scans through Windows.")
        : $"Status from {source.Origin}. That's less than Inkvolt Print reads from a printer it reaches over the network: " +
          "no ink or toner levels, and problems only as the driver reports them." + (_wia is null ? "" : " Scanning goes through Windows too.");

    /// <summary>The address on the header: the network address, or for a queue printer how the PC reaches it ("USB").</summary>
    public string? Where => Host ?? (WindowsQueue is { } q ? QueueKinds.ConnectionText(q) : ScannerDevice?.ConnectionText);

    /// <summary>The offline fixer: network printers (found by their ID on the network) and queue printers (their queue only); not a scanner on its own.</summary>
    public bool CanFix => !IsScannerOnly;

    /// <summary>A queue printer that answers but is paused or in trouble: the status card offers the fixer, which it otherwise does only offline.</summary>
    public bool ShowQueueFix => IsQueuePrinter && IsOnline && StatusSeverity != Severity.Info;

    // ---------------------------------------------------------------- what the Fleet page shows

    private DateTimeOffset? _lastReading;
    private int? _pages;

    /// <summary>This printer as the Fleet page lists it, from what's on screen: nothing is read from it here. <paramref name="known"/>: the supply history's last word, for one that hasn't answered.</summary>
    public Core.Fleet.FleetFacts FleetFacts(Core.Fleet.FleetLastKnown? known)
    {
        var live = Supplies.Select(s => s.Supply).ToList();
        var waiting = !IsOnline && IsConnecting;
        return new Core.Fleet.FleetFacts(Uuid, Name, IsScannerOnly ? Core.Fleet.FleetKind.Scanner : IsQueuePrinter ? Core.Fleet.FleetKind.Queue : Core.Fleet.FleetKind.Network)
        {
            Model = Model,
            Connection = IsScannerOnly ? "Windows scanner" : WindowsQueue is { } q ? Core.Fleet.FleetReader.ConnectionWord(QueueKinds.Connection(q))
                : _session.Connection is { } c ? string.Join(", ", c.Probe.Interfaces) : null,
            Reachable = IsOnline || waiting,
            Status = waiting ? PrinterStatus.Unavailable(StatusMessage) : new PrinterStatus("", StatusMessage, StatusSeverity, Alerts.ToList()),
            Supplies = live.Count > 0 ? live : known?.Supplies ?? [],
            Pages = _pages ?? known?.Pages,
            Firmware = _state.GetFirmware(Uuid)?.Version,
            LastReading = _lastReading,
            LastReadingDay = _lastReading is null ? known?.Day : null,
            LastKnown = !IsOnline && !waiting && (live.Count > 0 || known is not null || _pages is not null),
        };
    }

    /// <summary>A printer's fixer view for Fix all: a queue printer's queue, a network printer's own (null: a scanner on its own has none).</summary>
    public OfflineDevice? FleetFixDevice => IsScannerOnly ? null : FixerDevice();

    /// <summary>The Copy tab: always for network printers (it says when there's no scanner); for a queue printer once it has a scanner.</summary>
    public bool ShowCopy => IsNetworkPrinter || (IsQueuePrinter && Copy.HasScanner);

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
    private OfflineDevice FixerDevice() => WindowsQueue is { } queue ? OfflineDevice.ForQueue(queue.Name, Name, Model) : new(Uuid, Name, Model, Host)
    {
        PreviousHosts = _previousHosts.ToList(),
        StoredQueueName = _state.GetQueueName(Uuid), // never set on the made-up PC: its queue lookup finds none
        CanPair = PrintEndpointId is not null || _pc.PairsAnyPrinter,
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

    [RelayCommand(CanExecute = nameof(CanFix))]
    private async Task OpenFixerAsync()
    {
        SelectedSection = OverviewSection;
        await Fixer.OpenAsync();
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

    private void UpdateJobsVisibility() => Jobs.SetVisible(IsShown && SelectedSection == OverviewSection && CanPrint);

    /// <summary>Print a PDF. Works through the Windows queue, so it doesn't need the device connection.</summary>
    public PrintViewModel Print { get; }

    public string Uuid { get; }

    /// <summary>The PC this printer is reached from: the real one, or the demo's made-up one.</summary>
    public PcEnvironment Pc => _pc;
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

    /// <summary>
    /// The printer answered only SNMP when it was added (remembered with what it said about itself, since SNMP has no UUID).
    /// Only such a printer is read over SNMP; any other printer that doesn't answer HTTP for a moment is offline, as before.
    /// Null for every other printer, and once an SNMP-only printer answers LEDM, CDM or IPP (it then is a printer like the rest).
    /// </summary>
    public SnmpDevice? SnmpDevice { get; set; }

    /// <summary>Read over SNMP only (no LEDM, CDM or IPP answered): status, alerts and supply levels; no scanning or settings.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HpOnlyNote))]
    public partial bool IsSnmp { get; set; }

    public string? HpOnlyNote => IsSnmp
        ? "This printer answers only SNMP (the standard printer management protocol), so Inkvolt Print reads its status, alerts and " +
          "supply levels, but can't scan with it or change its settings. Change settings on the printer's web page or its control panel."
        : IsCdm
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
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Where))]
    public partial string? Host { get; set; }
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
    [NotifyPropertyChangedFor(nameof(StatusKind), nameof(IsStale), nameof(StaleSuffix), nameof(ListStatus), nameof(ShowQueueFix))]
    public partial bool IsOnline { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ListStatus))]
    public partial string StatusMessage { get; set; } = "Connecting…";

    /// <summary>The printer list's line: the state and, for a warning or error, its reason ("Ready · Yellow ink is low").</summary>
    public string ListStatus => IsOnline ? PrinterStatus.ListLine(StatusMessage, StatusSeverity, Alerts) : StatusMessage;

    /// <summary>
    /// Another device answers at this printer's address (it reports other UUIDs): nothing of it is shown, the scanner, copy
    /// and settings are unbound, and "This is my printer" lets the user accept it (a repair or reset gave the printer a new UUID).
    /// </summary>
    [ObservableProperty] public partial bool IsElsewhere { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind), nameof(ListStatus), nameof(ShowQueueFix))]
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
    public bool ShowPrintShortcut => SelectedSection != PrintSection && CanPrint;

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
        _ = IsScannerOnly ? RunScannerAsync(_loop.Token) : IsQueuePrinter ? RunQueueAsync(_loop.Token) : RunAsync(_loop.Token);
        if (_pc.HasWindowsQueues && IsNetworkPrinter) _ = RefreshQueueAsync();
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
        _session.AskIdentityFirst(); // between two checks (minutes apart) another device may take the address
        Jobs.SetVisible(false);
    }

    /// <summary>The window is back: the live loop again, on the same connection unless it was lost or the address changed.</summary>
    public void Resume()
    {
        if (!_suspended) return;
        _suspended = false;
        if (_loop is not null) return;
        _loop = new CancellationTokenSource();
        _session.AskIdentityFirst(); // time passed: the reused connection is asked who it is first
        _ = IsScannerOnly ? RunScannerAsync(_loop.Token)
            : IsQueuePrinter ? RunQueueAsync(_loop.Token) : RunAsync(_loop.Token, IsOnline && !_reprobe ? _session.Connection : null);
        _reprobe = false;
        UpdateJobsVisibility();
    }

    /// <summary>One read while suspended (the tray's low-frequency check): connects first when needed. True when it answered.</summary>
    public async Task<bool> CheckOnceAsync(CancellationToken ct)
    {
        try
        {
            if (IsScannerOnly) return IsOnline; // nothing to read: a scanner has no status over WIA
            if (IsQueuePrinter)
            {
                await ReadQueueAsync(ct);
                return IsOnline;
            }
            if (_session.Connection is null || !IsOnline || _reprobe)
            {
                _reprobe = false;
                if (!await ConnectAsync(ct)) return false;
            }
            // The session asks who answers before reading (another device may have taken the address since the last check).
            return await RefreshAsync(ct) && IsOnline;
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

    /// <summary>
    /// mDNS announces the printer at another address: DHCP may have moved it, or the announcement is of an address this PC
    /// can't use (a VM's or VPN's). It reconnects there (the old address still identifies its Windows queue's port) when the
    /// session finds the new address is this printer, or can't tell and the address in use no longer answers as this kind of
    /// printer (<see cref="PrinterSession.CheckAddressAsync"/>); an address the user typed that still works is kept.
    /// </summary>
    private async Task MoveIfSameDeviceAsync(DiscoveredPrinter d)
    {
        var host = d.Host!;
        try
        {
            var check = await _session.CheckAddressAsync(Reach(Host ?? host), new PrinterWhere(host, d.EsclRoot, d.IppUri), IsOnline && !IsElsewhere, d.Model);
            if (check == AddressCheck.Skipped) return;
            if (check != AddressCheck.Move)
            {
                Log.Write($"[{Name}] announced at another address that " +
                          $"{check switch { AddressCheck.AnotherDevice => "is another device", AddressCheck.NoId => "reports no ID", _ => "doesn't answer" }}; " +
                          "keeping its address, which still answers");
                return;
            }
            if (string.Equals(host, Host, StringComparison.OrdinalIgnoreCase)) return;
            if (Host is { } old && !_previousHosts.Contains(old, StringComparer.OrdinalIgnoreCase)) _previousHosts.Add(old);
            Host = host;
            if (d.EsclRoot is not null) EsclRoot = d.EsclRoot;
            if (d.IppUri is not null) IppUri = d.IppUri;
            Restart();
        }
        catch (Exception ex)
        {
            Log.Write($"[{Name}] announced at another address that couldn't be checked: {ex.Message}");
        }
    }

    /// <summary>
    /// This printer's Windows queue: the one whose device container is the printer (discovered/paired queues), or
    /// the queue Inkvolt Print created by address (Windows doesn't promise those share the printer's container id).
    /// </summary>
    public Task<string?> FindQueueAsync() => _pc.FindQueueAsync(Uuid, Host, WindowsQueue, _state); // none on the demo's made-up PC

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
                    if (!await ConnectAsync(ct))
                    {
                        await Task.Delay(RetryDelay, ct);
                        continue;
                    }
                    conn = _session.Connection!;
                }
                await foreach (var _ in conn.WatchAsync(FallbackRefresh, ct))
                {
                    switch (await _session.TryUpgradeAsync(Reach(), ct)) // asks who answers first
                    {
                        case SessionStep.Elsewhere elsewhere:
                            SetElsewhere(elsewhere);
                            break;
                        case SessionStep.Connected upgraded:
                            Upgrade(upgraded.Connection); // the session closed the SNMP connection
                            reuse = upgraded.Connection;  // watched from here on (its event feed, if it has one)
                            break;
                    }
                    if (IsElsewhere || reuse is not null) break;
                    // Still this printer? The session asks before reading (a reused connection at once, then every 30 s), so
                    // another device that took the address never has its status or alerts read under this printer's name.
                    if (!await RefreshAsync(ct)) break;
                    // Gone: connect again after a pause, which checks it's still this printer (DHCP may give its address to another device).
                    if (!IsOnline) break;
                }
                if (!IsOnline && reuse is null) await Task.Delay(RetryDelay, ct);
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

    private static readonly TimeSpan QueueRefresh = TimeSpan.FromSeconds(5);

    /// <summary>A queue printer's loop: the spooler is local and cheap to ask, so its status is read every few seconds.</summary>
    private async Task RunQueueAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await ReadQueueAsync(ct);
                await Task.Delay(QueueRefresh, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                Log.Write($"[{Name}] queue status: {ex.Message}");
                try { await Task.Delay(RetryDelay, ct); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    /// <summary>Windows no longer has this printer's queue (removed, or renamed): the queues are read again at once.</summary>
    public event Action? QueueMissing;

    private async Task ReadQueueAsync(CancellationToken ct)
    {
        var read = await _queueSource!.ReadAsync(ct);
        if (read is null)
        {
            SetOffline("Not found in Windows", "Windows no longer has this printer: it was probably removed or renamed in Settings.");
            QueueMissing?.Invoke();
            return;
        }
        ShowSupplies(read.Supplies, null);
        OnPropertyChanged(nameof(StatusSourceNote)); // SNMP may have started or stopped answering
        if (read.Offline)
        {
            SetOffline(read.Status.Message, read.Status.Detail ?? "");
            return;
        }
        IsConnecting = false;
        IsOnline = true;
        _lastReading = DateTimeOffset.Now;
        StatusMessage = read.Status.Message;
        StatusDetail = read.Status.Detail;
        StatusSeverity = read.Status.Severity;
        Sync(Alerts, read.Status.Alerts);
        OnPropertyChanged(nameof(ListStatus));
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(StaleSuffix));
        Observe(new PrinterSnapshot(Uuid, Name, true, read.Status, read.Supplies) { DaysLeft = _history?.DaysLeft, FirmwareChange = FirmwareNotice });
    }

    /// <summary>
    /// Connects through the session. False, with the status set, when nothing answers there or another device does: that device's
    /// status, supplies and alerts are never shown or alerted under this printer's name.
    /// </summary>
    private async Task<bool> ConnectAsync(CancellationToken ct)
    {
        switch (await _session.ConnectAsync(Reach(), ct))
        {
            case SessionStep.Connected connected:
                Attach(connected.Connection);
                return true;
            case SessionStep.Elsewhere elsewhere:
                SetElsewhere(elsewhere);
                return false;
            default:
                SetOffline();
                return false;
        }
    }

    /// <summary>Where the session reaches the printer: its address and hints as remembered now.</summary>
    private PrinterWhere Reach(string? host = null) => new(host ?? Host!, EsclRoot, IppUri, SnmpDevice);

    private IReadOnlyList<string> _foreignUuids = [];
    private SnmpIdentity? _foreignSnmp;

    /// <summary>The device a printer may answer to: its id, or a UUID the user accepted for it ("This is my printer").</summary>
    public bool IsKnownAs(string uuid) =>
        string.Equals(uuid, Uuid, StringComparison.OrdinalIgnoreCase) || _state.GetAcceptedUuids(Uuid).Contains(uuid, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// A printer read over SNMP answers LEDM, CDM or IPP now (<see cref="PrinterSession.TryUpgradeAsync"/>): it's connected over
    /// them (scanning, settings and the rest come with it) and isn't an SNMP-only printer any more.
    /// </summary>
    private void Upgrade(PrinterConnection richer)
    {
        Log.Write($"[{Name}] answers more than SNMP now: connected over {string.Join(", ", richer.Probe.Interfaces)}");
        SnmpDevice = null;
        EsclRoot = richer.Probe.EsclRoot ?? EsclRoot;
        Attach(richer);
    }

    /// <summary>
    /// Another device answers at the printer's address. The session has closed its connection and the printer's own, and the
    /// scanner, copy, settings and maintenance let go of them, so nothing (a jump-list preset scan included) reaches that
    /// device; scanned pages stay. The card says so and offers Fix it… and "This is my printer".
    /// </summary>
    private void SetElsewhere(SessionStep.Elsewhere elsewhere)
    {
        Log.Write($"[{Name}] a different device answers at its address; not connecting"); // never the UUIDs or serial numbers themselves
        _foreignUuids = elsewhere.Uuids;
        _foreignSnmp = elsewhere.Snmp;
        const string blocked = "Another device now answers at this printer's address, so Inkvolt Print doesn't scan or copy with it.";
        Scan?.Detach(blocked);
        Copy.Detach(blocked);
        Settings = null;
        IsElsewhere = true;
        SetOffline("A different device answers at this address",
            $"Another device now has {Host}, so its status isn't shown here. The printer probably got a new address: " +
            "Inkvolt Print watches for it on the network, or choose Fix it… to find it. If the printer was repaired or reset " +
            "and this really is it, choose This is my printer.");
    }

    /// <summary>"This is my printer": the device at the address is accepted as this printer from now on (its UUIDs remembered).</summary>
    [RelayCommand]
    private void AcceptDevice()
    {
        if (!IsElsewhere || (_foreignUuids.Count == 0 && _foreignSnmp is null)) return;
        if (!Prompt.Ask($"Use the device that now answers at {Host} as {Name}?\n\nOnly do this if it really is this printer, for example " +
                        "after a repair, a reset or a new network board gave it a new ID. Otherwise it's another device that took the " +
                        "printer's address, and Fix it… can find the printer.", "This is my printer"))
            return;
        if (_foreignUuids.Count > 0) _state.AcceptUuids(Uuid, _foreignUuids);
        if (_foreignSnmp is { } snmp) SnmpDevice = SnmpDevice.From(snmp); // remembered when it connects (Attach)
        Log.Write($"[{Name}] the user accepted the device at its address as this printer");
        IsElsewhere = false;
        Restart();
    }

    /// <summary>Binds the overview, scanner, settings and maintenance to the session's new connection (it closed the one before).</summary>
    private void Attach(PrinterConnection conn)
    {
        IsElsewhere = false;
        var p = conn.Probe;
        if (p.Product?.MakeAndModel is { } mm) Name = mm;
        Model = p.Model ?? Model;
        IppUri = p.IppEndpoint ?? IppUri;
        Brand = p.Brand;
        IsNonHp = !p.HasHpInterfaces;
        IsCdm = !p.HasHpInterfaces && p.Cdm is not null;
        IsSnmp = p.Snmp is not null;
        _webPage = p.WebPage;
        Sync(About, new InfoRow?[]
        {
            new("Model", p.Model ?? Model ?? Name),
            new("IP address", Host ?? "—"),
            p.Location is { } where ? new("Location", where) : null,
            p.SerialNumber is { } sn ? new("Serial number", sn) : null,
            p.Product?.ProductNumber is { } pn ? new("Product number", pn) : null,
            p.Firmware is { } fw ? new("Firmware", fw.Display) : null,
            new("Connected via", string.Join(", ", p.Interfaces)),
        }.OfType<InfoRow>().ToList());
        WatchFirmware(p.Firmware?.Display);
        if (Image is null && _pc.ImageCache is { } cache) _ = LoadImageAsync(conn, cache);
        _ = Maintenance.AttachAsync(conn); // reads only: what the printer offers

        BindScanner();
        if (conn.Probe.HasHpInterfaces) // settings are LEDM's
        {
            if (Settings is null) Settings = new SettingsViewModel(conn, Uuid, Name, _state, _pc.Passwords, _pc.Browser is null ? null : OpenWebPage);
            else Settings.Rebind(conn);
        }
        // A saved password is only attached once this printer's certificate is pinned. Without a pin (older
        // version, reset state) the first save asks for it instead, and that handshake pins the certificate.
        if (_pc.Passwords.Get(Uuid) is { } pw && _state.GetCertificatePin(Uuid) is not null)
            conn.Http.SetCredentials("admin", pw);

        _remember(this);
    }

    /// <summary>
    /// The Scan and Copy tabs get this printer's scanner: eSCL when the connection has it, else the Windows (WIA) scanner that
    /// belongs to it. A scanner offering neither glass nor feeder (only a camera, say) has nothing Inkvolt Print can scan from.
    /// The Scan tab is rebound rather than replaced, so scanned-but-unsaved pages survive a reconnect; it's made anew only when
    /// the kind of scanner changes and nothing is left unsaved.
    /// </summary>
    private void BindScanner()
    {
        IScanner? scanner = null;
        ScannerCapabilities? caps = null;
        if (_session.Connection is { Scanner: { } escl, Probe.Scanner: { } offered } && offered.Sources.Any()) (scanner, caps) = (escl, offered);
        else if (_wia is { } wia && wia.Capabilities.Sources.Any()) (scanner, caps) = (wia, wia.Capabilities);
        if (IsNetworkPrinter || scanner is not null) Copy.Attach(scanner, caps);
        else Copy.HasScanner = false;
        OnPropertyChanged(nameof(StatusSourceNote));
        if (scanner is null || caps is null)
        {
            Scan?.Detach("The scanner isn't connected now. Check that it's on and connected, then try again.");
            return;
        }
        if (Scan is null || (Scan.ViaWindows != (scanner is WiaScanner) && !Scan.HasUnsavedPages))
            Scan = new ScanViewModel(scanner, caps, _state, _presets, Name, FindQueueAsync, _pc);
        else Scan.Rebind(scanner);
    }

    /// <summary>
    /// The WIA scanner that belongs to this entry now (null: none). Connecting reads what it offers, in the background; one that
    /// doesn't answer (off, unplugged) is tried again the next time this is called. A scanner on its own gets its status from it.
    /// </summary>
    public async Task UseWiaScannerAsync(WiaDeviceInfo? device, IWiaSystem system)
    {
        if (device is null)
        {
            if (_wiaDevice is null) return;
            _wiaDevice = null;
            _wia = null;
            BindScanner();
            return;
        }
        if (_wiaConnecting || (_wia is not null && string.Equals(_wia.Device.Id, device.Id, StringComparison.OrdinalIgnoreCase))) return;
        _wiaDevice = device;
        _wiaConnecting = true;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            var scanner = await WiaScanner.OpenAsync(system, device, timeout.Token);
            if (!string.Equals(_wiaDevice?.Id, device.Id, StringComparison.OrdinalIgnoreCase)) return; // let go meanwhile
            _wia = scanner;
            BindScanner();
            if (IsScannerOnly)
            {
                IsConnecting = false;
                IsOnline = true;
                StatusSeverity = Severity.Info;
                StatusMessage = "Ready to scan";
                StatusDetail = null;
                _lastReading = DateTimeOffset.Now;
            }
        }
        catch (Exception ex) // any failure: this runs unobserved (fire and forget), and must not leave the scanner "connecting"
        {
            Log.Write($"[{Name}] Windows scanner not connected: {ex.Message}");
            if (IsScannerOnly)
            {
                // Not SetOffline: a scanner that's off isn't a printer problem to alert about from the notification area.
                IsConnecting = false;
                IsOnline = false;
                StatusSeverity = Severity.Info;
                StatusMessage = "Scanner not answering";
                StatusDetail = (ex is OperationCanceledException ? "The scanner didn't answer in time." : WiaErrors.Message(WiaErrors.From(ex).Code, false)) +
                               " Inkvolt Print tries again every 30 seconds.";
            }
        }
        finally
        {
            _wiaConnecting = false;
        }
    }

    private static readonly TimeSpan ScannerRetry = TimeSpan.FromSeconds(30);

    /// <summary>A scanner on its own: connect, and again every 30 s while it doesn't answer.</summary>
    private async Task RunScannerAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (_wia is null) await UseWiaScannerAsync(ScannerDevice, _wiaSystem!);
                await Task.Delay(ScannerRetry, ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>One read through the session, shown. False when another device answers at the address now (nothing of it is read).</summary>
    private async Task<bool> RefreshAsync(CancellationToken ct)
    {
        if (_session.Connection is null) return true;
        var step = await _session.ReadAsync(Reach(), ct);
        if (step is SessionStep.Elsewhere elsewhere)
        {
            SetElsewhere(elsewhere);
            return false;
        }
        var reading = ((SessionStep.Read)step).Reading;
        var status = reading.Status;
        if (reading.IsOffline)
        {
            SetOffline();
            return true;
        }
        IsConnecting = false;
        IsOnline = true;
        _lastReading = DateTimeOffset.Now;
        _pages = reading.Usage?.TotalImpressions ?? _pages;
        if (!status.IsUnavailable)
        {
            // An unusable reply (printer waking up) keeps the last good status instead of flashing an error.
            StatusMessage = status.Message;
            StatusDetail = status.Detail;
            StatusSeverity = status.Severity;
            Sync(Alerts, status.Alerts);
            OnPropertyChanged(nameof(ListStatus));
        }
        Maintenance.Update(true, status);

        // Supplies not read this time (null) stay as they were; they refresh on the next event.
        if (reading.Supplies is { } supplies) ShowSupplies(supplies, reading.Usage?.TotalImpressions);
        if (reading.Usage is { } u)
            Sync(Stats, new InfoRow?[]
            {
                u.TotalImpressions is { } t ? new($"{t:N0}", "pages printed") : null,
                u.DuplexSheets is { } d ? new($"{d:N0}", "two-sided sheets") : null,
                u.ScanImages is { } sc ? new($"{sc:N0}", "pages scanned") : null,
                u.JamEvents is { } j ? new($"{j:N0}", "paper jams") : null,
            }.OfType<InfoRow>().ToList());
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(StaleSuffix));
        Observe(new PrinterSnapshot(Uuid, Name, true, status.IsUnavailable ? null : status, reading.Supplies) { DaysLeft = _history?.DaysLeft, FirmwareChange = FirmwareNotice });
        return true;
    }

    /// <summary>The last firmware change while its notice shows on the status card (roadmap 1.5); the tray alerts it once.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(FirmwareNoticeHint), nameof(FirmwareNoticeAction))]
    public partial FirmwareChange? FirmwareNotice { get; set; }

    /// <summary>Under the notice: why it matters, and where to act on it.</summary>
    public string? FirmwareNoticeHint => FirmwareNotice is null ? null
        : Settings is not null
            ? "If it came from HP, cartridges with non-HP chips may stop working. Keep my cartridges working, on the Printer settings tab, turns automatic updates off."
            : "Firmware updates can change which cartridges a printer accepts. The printer's web page has its update settings.";

    /// <summary>The notice's button: the Firmware card for an HP printer whose settings Inkvolt Print writes, else the web page.</summary>
    public string? FirmwareNoticeAction => FirmwareNotice is null ? null
        : Settings is not null ? "Firmware settings"
        : _pc.Browser is not null && Host is not null ? "Printer web page"
        : null;

    partial void OnSettingsChanged(SettingsViewModel? oldValue, SettingsViewModel? newValue)
    {
        OnPropertyChanged(nameof(FirmwareNoticeHint));
        OnPropertyChanged(nameof(FirmwareNoticeAction));
    }

    /// <summary>The connection's firmware version against the one remembered: a change is kept and shown until dismissed (30 days at most).</summary>
    private void WatchFirmware(string? version)
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        var known = _state.GetFirmware(Uuid);
        var record = FirmwareWatch.Observe(known, version, today);
        if (record is not null && !ReferenceEquals(record, known))
        {
            _state.SetFirmware(Uuid, record);
            if (known is not null) Log.Write($"[{Name}] firmware version changed"); // never the versions: they can identify a unit
        }
        FirmwareNotice = FirmwareWatch.Notice(record, today);
    }

    [RelayCommand]
    private void DismissFirmwareNotice()
    {
        if (_state.GetFirmware(Uuid) is { } record) _state.SetFirmware(Uuid, record with { Dismissed = true });
        FirmwareNotice = null;
    }

    [RelayCommand]
    private void ActOnFirmwareNotice()
    {
        if (Settings is not null) SelectedSection = SettingsSection;
        else OpenWebPage();
    }

    private SupplyHistoryView? _history;
    private DateOnly _historyDay;

    /// <summary>The supply history's level chart on the supplies card (roadmap 1.1); nothing to draw until two days are kept.</summary>
    [ObservableProperty] public partial SupplyChartData? SupplyChart { get; set; }

    /// <summary>Why the chart isn't there yet ("fills in as days pass"); null when it draws or never will (no levels).</summary>
    [ObservableProperty] public partial string? SupplyChartNote { get; set; }

    /// <summary>
    /// A reading's supplies on the card, kept in the supply history first (one row a day per supply, under the data folder) so each
    /// supply's line and the chart include it. <paramref name="pages"/>: the printer's lifetime page count, when it gives one.
    /// </summary>
    private void ShowSupplies(IReadOnlyList<Consumable> supplies, int? pages)
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        var changed = _pc.History.Record(Uuid, supplies, pages, today);
        if (changed || _history is null || _historyDay != today)
        {
            _history = SupplyHistoryView.Of(_pc.History.Rows(Uuid), today);
            _historyDay = today;
            SupplyChart = _history.Chart.HasEnoughToDraw ? _history.Chart : null;
        }
        SupplyChartNote = _history.ChartNote(supplies);
        Sync(Supplies, supplies.Select(s => new SupplyViewModel(s) { HistoryLine = _history.LineFor(s) }).ToList());
        OnPropertyChanged(nameof(SuppliesTitle));
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
        OnPropertyChanged(nameof(ListStatus));
        Maintenance.Update(false, null);
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(StaleSuffix));
        Observe(new PrinterSnapshot(Uuid, Name, false, null, null));
    }

    /// <summary>The printer's own product photo (served by its web server), cached so it shows instantly next time.</summary>
    private async Task LoadImageAsync(PrinterConnection conn, string folder)
    {
        var cache = Path.Combine(folder, $"{PrinterId.FileName(Uuid)}.png");
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
        if (Host is not null) _pc.Browser?.Invoke(_webPage?.AbsoluteUri ?? $"https://{Host}/");
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
        if (IsElsewhere)
        {
            Prompt.Tell($"Another device now answers at {Name}'s address, so \"{preset.Name}\" didn't scan. Use Fix it… on its Overview to find the printer.");
            return;
        }
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
        _session.Dispose();
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
        "missing" => "Missing — install it",
        "full" => "Replace now",
        "almostFull" => "Replace soon",
        "out" => "Empty — replace now",
        _ when Supply.IsWaste => null,
        _ when Supply.EstimatedPagesRemaining is { } pages => $"About {pages:N0} pages left",
        _ when Supply.IsLow => "Running low",
        _ => "OK",
    };

    /// <summary>From the supply history: days left and pages on this cartridge, or why there's no estimate yet; null: nothing to say.</summary>
    public string? HistoryLine { get; init; }

    public string? Cartridge => string.Join("  ·  ", new[]
    {
        Supply.SelectibilityNumber is { } sel ? $"HP {sel}" : null, // LEDM (HP) only
        Supply.ProductNumber,
    }.Where(s => s is not null)) is { Length: > 0 } c ? $"Replacement: {c}" : null;

    public string Level => Supply.State is "out" or "full" or "missing" ? "empty" : IsLow ? "low" : "ok";

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
        "missing" => "Missing",
        "ok" => "OK",
        _ => "—",
    };

    public bool IsLow => Supply.IsLow;

    /// <summary>K, C, M, Y or #RRGGBB for the color swatch; null when the supply has no color (a waste box).</summary>
    public string? ColorCode => Supply.ColorCode;

    /// <summary>For screen readers: "Cyan ink, 55%, OK" or "Maintenance box, OK".</summary>
    public string AccessibleText => string.Join(", ", new[] { Name, PercentText, Headline is { } h && h != PercentText ? h : null, HistoryLine }.OfType<string>());
}
