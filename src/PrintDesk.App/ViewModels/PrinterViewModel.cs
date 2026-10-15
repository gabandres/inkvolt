using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PrintDesk.Core.Model;
using PrintDesk.Core.Probe;
using PrintDesk.Windows.Discovery;
using PrintDesk.Windows.Queues;
using PrintDesk.Windows.Security;

namespace PrintDesk.App.ViewModels;

/// <summary>
/// One printer. Owns a background loop: connect (probe) → read status → wait on device events → re-read.
/// Offline printers are retried quietly; nothing here polls faster than the device's own event feed.
/// </summary>
public sealed partial class PrinterViewModel : ObservableObject, IDisposable
{
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan FallbackRefresh = TimeSpan.FromSeconds(30);

    private readonly AppState _state;
    private readonly Action<PrinterViewModel> _remember;
    private CancellationTokenSource? _loop;
    private PrinterConnection? _connection;

    public PrinterViewModel(string uuid, string name, string? model, string host, Uri? esclRoot, AppState state, Action<PrinterViewModel> remember)
    {
        Uuid = uuid;
        Name = name;
        Model = model;
        Host = host;
        EsclRoot = esclRoot;
        _state = state;
        _remember = remember;
        Print = new PrintViewModel(uuid, state);
    }

    /// <summary>Print a PDF. Works through the Windows queue, so it doesn't need the device connection.</summary>
    public PrintViewModel Print { get; }

    public string Uuid { get; }
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
    [NotifyPropertyChangedFor(nameof(StatusKind))]
    public partial bool IsOnline { get; set; }

    [ObservableProperty] public partial string StatusMessage { get; set; } = "Connecting…";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind))]
    public partial Severity StatusSeverity { get; set; } = Severity.Info;

    /// <summary>For the status dot: connecting, offline, ok, warning, error.</summary>
    public string StatusKind => !IsOnline ? (IsConnecting ? "connecting" : "offline")
        : StatusSeverity switch { Severity.Error => "error", Severity.Warning => "warning", _ => "ok" };

    public ObservableCollection<PrinterAlert> Alerts { get; } = [];
    public ObservableCollection<SupplyViewModel> Supplies { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NeedsSetup), nameof(SetupResult))]
    [NotifyCanExecuteChangedFor(nameof(SetUpCommand))]
    public partial string? PrintEndpointId { get; set; }

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

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowScanShortcut))]
    public partial ScanViewModel? Scan { get; set; }
    [ObservableProperty] public partial SettingsViewModel? Settings { get; set; }

    /// <summary>Windows can see the printer but has no queue for it yet.</summary>
    public bool NeedsSetup => PrintEndpointId is not null && !QueueInstalled;

    public void Start()
    {
        if (_loop is not null) return;
        _loop = new CancellationTokenSource();
        _ = RunAsync(_loop.Token);
    }

    public void ApplyDiscovery(DiscoveredPrinter d)
    {
        PrintEndpointId = d.PrintEndpointId;
        QueueInstalled = d.QueueInstalled;
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
                var conn = await PrinterConnection.OpenAsync(Host!, EsclRoot, ct);
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
                Trace.WriteLine($"[{Name}] {ex}");
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
        if (Image is null) _ = LoadImageAsync(conn);

        // Rebind rather than replace, so scanned-but-unsaved pages survive a reconnect.
        if (conn.Scanner is not null && p.Scanner is not null)
        {
            if (Scan is null) Scan = new ScanViewModel(conn.Scanner, p.Scanner, _state);
            else Scan.Rebind(conn.Scanner);
        }
        if (conn.Ledm is not null)
        {
            if (Settings is null) Settings = new SettingsViewModel(conn, Uuid, Name);
            else Settings.Rebind(conn);
        }
        if (CredentialStore.Get(Uuid) is { } pw) conn.Http.SetCredentials("admin", pw);

        if (p.Uuid is not null && !string.Equals(p.Uuid, Uuid, StringComparison.OrdinalIgnoreCase))
            Trace.WriteLine($"[{Name}] UUID changed {Uuid} → {p.Uuid}");
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
            return;
        }
        IsConnecting = false;
        IsOnline = true;
        StatusMessage = status.Message;
        StatusDetail = status.Detail;
        StatusSeverity = status.Severity;
        Sync(Alerts, status.Alerts);

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
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || ex is PrintDesk.Core.Net.DeviceHttpException)
        {
            // Status is what matters; supplies refresh on the next event.
        }
    }

    private void SetOffline()
    {
        IsConnecting = false;
        IsOnline = false;
        StatusMessage = "Can't reach the printer";
        StatusDetail = $"Make sure it's turned on and connected to the same network as this PC{(Host is null ? "" : $" ({Host})")}. PrintDesk keeps trying in the background.";
        StatusSeverity = Severity.Error;
        Alerts.Clear();
    }

    /// <summary>The printer's own product photo (served by its web server), cached so it shows instantly next time.</summary>
    private async Task LoadImageAsync(PrinterConnection conn)
    {
        var cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PrintDesk", "images", $"{Uuid}.png");
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

    private bool CanSetUp() => PrintEndpointId is not null && !IsInstalling;

    /// <summary>
    /// One click: installs the Windows print queue (IPP Class Driver). The Windows scanner device is then added
    /// in the background — it's only for other apps; PrintDesk scans over eSCL without it.
    /// </summary>
    [RelayCommand(CanExecute = nameof(CanSetUp))]
    private async Task SetUpAsync()
    {
        IsInstalling = true;
        SetupMessage = "Setting up… Windows is adding the printer (about 30 seconds).";
        try
        {
            var print = await QueueInstaller.InstallAsync(PrintEndpointId!);
            if (print.Outcome is InstallOutcome.Installed or InstallOutcome.AlreadyInstalled)
            {
                QueueInstalled = true;
                SetupMessage = "Ready to print from any app.";
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
            SetupMessage = $"Setup failed: {ex.Message}";
        }
        finally
        {
            IsInstalling = false;
        }
    }

    [RelayCommand]
    private void OpenWebPage()
    {
        if (Host is not null) Process.Start(new ProcessStartInfo($"https://{Host}/") { UseShellExecute = true });
    }

    [RelayCommand]
    private void OpenPrintQueue() => Process.Start(new ProcessStartInfo("ms-settings:printers") { UseShellExecute = true });

    [RelayCommand]
    private void Reconnect() => Restart();

    public const int OverviewSection = 0, PrintSection = 1, ScanSection = 2, SettingsSection = 3;

    /// <summary>Index of the visible section tab (see the *Section constants).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowScanShortcut), nameof(ShowPrintShortcut))]
    public partial int SelectedSection { get; set; }

    public bool ShowScanShortcut => Scan is not null && SelectedSection != ScanSection;
    public bool ShowPrintShortcut => SelectedSection != PrintSection;

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
        _loop?.Cancel();
        _loop = null;
        _connection?.Dispose();
        _connection = null;
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
