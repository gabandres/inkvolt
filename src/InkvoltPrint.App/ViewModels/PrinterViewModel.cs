using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Windows.Discovery;
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

    public const int OverviewSection = 0, PrintSection = 1, ScanSection = 2, SettingsSection = 3;

    private readonly AppState _state;
    private readonly Action<PrinterViewModel> _remember;
    private readonly Func<HttpMessageHandler>? _transport;
    private CancellationTokenSource? _loop;
    private CancellationTokenSource? _watch;
    private PrinterConnection? _connection;
    private bool _discoveredQueue;
    private bool _windowsQueue;

    /// <param name="transport">Demo mode: the printer's web server (no network, no Windows queue, no cached image).</param>
    public PrinterViewModel(string uuid, string name, string? model, string host, Uri? esclRoot, AppState state, Action<PrinterViewModel> remember,
        Func<HttpMessageHandler>? transport = null)
    {
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
    }

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
    private Uri IppUrl => new UriBuilder("http", Host!, 631, "ipp/print").Uri;

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
    }

    public void Start()
    {
        if (_loop is not null) return;
        _loop = new CancellationTokenSource();
        _ = RunAsync(_loop.Token);
        if (!IsDemo) _ = RefreshQueueAsync();
    }

    public void ApplyDiscovery(DiscoveredPrinter d)
    {
        PrintEndpointId = d.PrintEndpointId;
        _discoveredQueue = d.QueueInstalled;
        QueueInstalled = _discoveredQueue || _windowsQueue;
        ScanEndpointId = d.ScanEndpointId;
        ScannerInstalled = d.ScannerInstalled;
        Model ??= d.Model;
        if (d.EsclRoot is not null) EsclRoot = d.EsclRoot;
        if (d.Host is not null && d.Host != Host)
        {
            // DHCP moved it: reconnect at the new address.
            Host = d.Host;
            Restart();
        }
        else if (!IsOnline && !IsConnecting && d.Host is not null)
        {
            Restart(); // mDNS just saw it again; don't wait for the retry timer
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
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Restart()
    {
        _loop?.Cancel();
        _loop = null;
        Start();
    }

    private async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                IsConnecting = true;
                var conn = await PrinterConnection.OpenAsync(Host!, EsclRoot, ct, new PinStore(_state, Uuid), _transport?.Invoke());
                if (!conn.Probe.Reachable)
                {
                    conn.Dispose();
                    SetOffline();
                    await Task.Delay(RetryDelay, ct);
                    continue;
                }
                Attach(conn);
                await foreach (var _ in conn.WatchAsync(FallbackRefresh, ct))
                    await RefreshAsync(ct);
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

    private void Attach(PrinterConnection conn)
    {
        var old = _connection;
        _connection = conn;
        var p = conn.Probe;
        if (p.Product?.MakeAndModel is { } mm) Name = mm;
        Model = p.Model ?? Model;
        Sync(About, new InfoRow?[]
        {
            new("Model", p.Model ?? Model ?? Name),
            new("IP address", Host ?? "—"),
            p.Product?.SerialNumber is { } sn ? new("Serial number", sn) : null,
            p.Product?.ProductNumber is { } pn ? new("Product number", pn) : null,
            p.Product?.FirmwareDate is { } fw ? new("Firmware", fw) : null,
            new("Connected via", string.Join(", ", p.Interfaces)),
        }.OfType<InfoRow>().ToList());
        if (Image is null && !IsDemo) _ = LoadImageAsync(conn);

        // Rebind rather than replace, so scanned-but-unsaved pages survive a reconnect.
        if (conn.Scanner is not null && p.Scanner is not null)
        {
            if (Scan is null) Scan = new ScanViewModel(conn.Scanner, p.Scanner, _state);
            else Scan.Rebind(conn.Scanner);
        }
        if (conn.Ledm is not null)
        {
            if (Settings is null) Settings = new SettingsViewModel(conn, Uuid, Name, _state);
            else Settings.Rebind(conn);
        }
        // A saved password is only attached once this printer's certificate is pinned. Without a pin (older
        // version, reset state) the first save asks for it instead, and that handshake pins the certificate.
        if (!IsDemo && CredentialStore.Get(Uuid) is { } pw && _state.GetCertificatePin(Uuid) is not null)
            conn.Http.SetCredentials("admin", pw);

        if (p.Uuid is not null && !string.Equals(p.Uuid, Uuid, StringComparison.OrdinalIgnoreCase))
            Log.Write($"[{Name}] UUID changed {Uuid} → {p.Uuid}");
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

        try
        {
            var supplies = await suppliesTask;
            Sync(Supplies, supplies.Select(s => new SupplyViewModel(s)).ToList());
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
    }

    private static void ObserveQuietly(params Task[] tasks)
    {
        foreach (var t in tasks) _ = t.ContinueWith(x => _ = x.Exception, TaskContinuationOptions.OnlyOnFaulted);
    }

    private void SetOffline()
    {
        IsConnecting = false;
        IsOnline = false;
        StatusMessage = "Can't reach the printer";
        StatusDetail = $"Make sure it's turned on and connected to the same network as this PC{(Host is null ? "" : $" ({Host})")}. Inkvolt Print keeps trying in the background.";
        StatusSeverity = Severity.Error;
        Alerts.Clear();
        OnPropertyChanged(nameof(IsStale));
        OnPropertyChanged(nameof(StaleSuffix));
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
                foreach (var path in new[] { "/ipp/images/printer-large.png", "/ipp/images/printer.png" })
                    if ((bytes = await conn.Http.GetBytesOrNullAsync(conn.Http.Http(path))) is not null) break;
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
        Print.QueueBusy = true; // no new jobs while the queue is being re-created
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
            Print.QueueBusy = false;
        }
    }

    [RelayCommand]
    private void OpenWebPage()
    {
        if (Host is not null && !IsDemo) Shell.Open($"https://{Host}/");
    }

    [RelayCommand]
    private void OpenPrintQueue() => Shell.Open("ms-settings:printers");

    [RelayCommand]
    private void Reconnect() => Restart();

    [RelayCommand]
    private void GoToScan() => SelectedSection = ScanSection;

    [RelayCommand]
    private void GoToPrint() => SelectedSection = PrintSection;

    /// <summary>Drag-and-drop / "Open with": jump to Print and load the file.</summary>
    public Task OpenPdfAsync(string path)
    {
        SelectedSection = PrintSection;
        return Print.OpenAsync(path);
    }

    public void Dispose()
    {
        Jobs.SetVisible(false);
        _loop?.Cancel();
        _loop = null;
        _watch?.Cancel();
        _watch = null;
        _connection?.Dispose();
        _connection = null;
    }

    /// <summary>Certificate fingerprint remembered per printer UUID in the app state.</summary>
    private sealed class PinStore(AppState state, string uuid) : ICertificatePin
    {
        public string? Get() => state.GetCertificatePin(uuid);
        public string SetIfAbsent(string sha256Hex) => state.SetCertificatePinIfAbsent(uuid, sha256Hex);
    }
}

public sealed record InfoRow(string Label, string Value);

public sealed record SupplyViewModel(Consumable Supply)
{
    /// <summary>"About 100 pages left", or the state when no estimate is available.</summary>
    public string Headline => Supply.State switch
    {
        "out" => "Empty — replace now",
        _ when Supply.EstimatedPagesRemaining is { } pages => $"About {pages:N0} pages left",
        _ when Supply.IsLow => "Running low",
        _ => "OK",
    };

    public string? Cartridge => string.Join("  ·  ", new[]
    {
        Supply.SelectibilityNumber is { } sel ? $"HP {sel}" : null,
        Supply.ProductNumber,
    }.Where(s => s is not null)) is { Length: > 0 } c ? $"Replacement: {c}" : null;

    public string Level => Supply.State == "out" ? "empty" : IsLow ? "low" : "ok";

    public string Name => Supply.Name;
    public double Percent => Supply.PercentRemaining ?? 0;
    public string PercentText => Supply.PercentRemaining is { } p ? $"{p}%" : "—";
    public bool IsLow => Supply.IsLow;
    public string ColorCode => Supply.ColorCode ?? "K";
}
