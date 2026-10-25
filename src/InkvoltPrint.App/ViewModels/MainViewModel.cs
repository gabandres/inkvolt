using System.Collections.ObjectModel;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Presets;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;
using InkvoltPrint.Windows.Cleanup;
using InkvoltPrint.Windows.Discovery;
using InkvoltPrint.Windows.Printing;
using InkvoltPrint.Windows.Scanning;

namespace InkvoltPrint.App.ViewModels;

/// <summary>Yes/no questions the view models ask; wired to a real dialog by the app.</summary>
public static class Prompt
{
    /// <summary>Args: message, confirm-button wording. Returns true to go ahead. Unset (tests): always yes.</summary>
    public static Func<string, string, bool>? Confirm { get; set; }

    public static bool Ask(string message, string confirm) => Confirm?.Invoke(message, confirm) ?? true;

    /// <summary>Information only: one OK button. Unset (tests): no-op.</summary>
    public static Action<string>? Inform { get; set; }

    public static void Tell(string message) => Inform?.Invoke(message);

    /// <summary>Screen-reader announcement (UI Automation notification). Unset (tests): no-op.</summary>
    public static Action<string>? Announcer { get; set; }

    public static void Announce(string message) => Announcer?.Invoke(message);

    /// <summary>Opens the scan presets editor (Views.ScanPresetsDialog); the printer name is for its file-name example. Unset (tests): no-op.</summary>
    public static Action<ScanPresetLibrary, string>? EditPresets { get; set; }
}

public sealed partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly AppState _state;
    private readonly PrinterDiscovery? _discovery;
    private readonly Func<HttpMessageHandler>? _transport;
    private readonly CancellationTokenSource _queueWatch = new();
    private IReadOnlyList<SpoolerQueue> _queues = [];
    private string? _wantedSelection, _wantedScanner;
    private readonly IWiaSystem _wia;
    private IReadOnlyList<WiaDeviceInfo> _scanners = [];
    private bool _scannersRead;

    /// <param name="transport">Demo mode (<c>--demo</c>): every printer talks to this instead of the network, and
    /// discovery, adding by address and the HP software check are off.</param>
    public MainViewModel(AppState state, Func<HttpMessageHandler>? transport = null)
    {
        _state = state;
        _transport = transport;
        _wia = transport is null ? WindowsWia.Instance : Demo.Wia;
        Presets = new ScanPresetLibrary(state, demo: transport is not null);
        // Older state files may hold non-GUID ids (printers added by address): normalise once.
        foreach (var k in state.Printers.ToList())
        {
            var id = PrinterId.Normalize(k.Uuid, k.Host);
            if (string.Equals(id, k.Uuid, StringComparison.OrdinalIgnoreCase)) continue;
            // Only migrate into an id no other remembered printer already owns.
            if (state.Printers.Any(o => !ReferenceEquals(o, k) && string.Equals(o.Uuid, id, StringComparison.OrdinalIgnoreCase))) continue;
            try
            {
                state.RenamePrinterId(k.Uuid, id);
                InkvoltPrint.Windows.Security.CredentialStore.Rename(k.Uuid, id);
            }
            catch (Exception ex)
            {
                Log.Write($"Id migration skipped for one printer: {ex.Message}");
            }
        }
        state.Printers = state.Printers.Select(k => k with { Uuid = PrinterId.Normalize(k.Uuid, k.Host) })
            .DistinctBy(k => k.Uuid, StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var k in state.Printers)
            Printers.Add(new PrinterViewModel(k.Uuid, k.Name, k.Model, k.Host, k.EsclRoot is null ? null : new Uri(k.EsclRoot), state, Presets, Remember, transport)
            {
                IppUri = Uri.TryCreate(k.IppUri, UriKind.Absolute, out var ipp) ? ipp : null,
            });
        // A queue printer chosen last time is listed a moment later (after the queues are read): selected then.
        _wantedSelection = QueueKinds.IsQueueId(state.SelectedUuid) ? state.SelectedUuid : null;
        _wantedScanner = PrinterViewModel.IsScannerId(state.SelectedUuid) ? state.SelectedUuid : null;
        Selected = Printers.FirstOrDefault(p => p.Uuid == state.SelectedUuid) ?? Printers.FirstOrDefault();
        foreach (var p in Printers) p.Start();

        if (transport is not null)
        {
            IsSearching = false;
            _queues = Demo.Queues;
            ReconcileQueues();
            _scanners = Demo.Wia.Scanners.Select(s => s.Device).ToList(); // made up: this PC's scanners are never asked in demo mode
            _scannersRead = true;
            ReconcileScanners();
            return;
        }
        _ = WatchQueuesAsync(_queueWatch.Token);
        _discovery = new PrinterDiscovery();
        _discovery.Changed += list => Application.Current?.Dispatcher.InvokeAsync(() => Merge(list));
        _discovery.InitialSweepCompleted += () => Application.Current?.Dispatcher.InvokeAsync(() => IsSearching = false);
        _discovery.Start();
        if (Features.HpCleanup) _ = CheckHpSoftwareAsync();
    }

    public ObservableCollection<PrinterViewModel> Printers { get; } = [];

    /// <summary>Remembered printers and preferences (the tray's settings live there too).</summary>
    public AppState State => _state;

    /// <summary>Scan presets, shared by every printer (Scan tab, Overview scan card, Ctrl+1…9, jump list).</summary>
    public ScanPresetLibrary Presets { get; }

    /// <summary>Ctrl+1…Ctrl+9: the n-th preset on the selected printer.</summary>
    [RelayCommand]
    private async Task RunPresetAtAsync(string? number)
    {
        if (!int.TryParse(number, out var n) || n < 1 || n > Presets.Items.Count || Selected is not { Scan: not null } printer) return;
        await printer.RunPresetAsync(Presets.Items[n - 1]);
    }

    /// <summary>
    /// A preset asked for from outside (the jump list's <c>--preset id</c>, at start or forwarded to the running copy): waits up
    /// to 30 s for the selected printer's scanner to connect, then runs it on the Scan tab.
    /// </summary>
    public async Task RunPresetWhenReadyAsync(string idOrName)
    {
        if (Presets.Find(idOrName) is not { } preset)
        {
            Log.Write("A preset asked for on the command line doesn't exist any more");
            return;
        }
        for (var i = 0; i < 120 && Selected?.Scan is null; i++) await Task.Delay(250);
        if (Selected is not { Scan: not null } printer)
        {
            Prompt.Tell($"No scanner is connected yet, so \"{preset.Name}\" didn't scan. Try again when the printer shows up.");
            return;
        }
        await printer.RunPresetAsync(preset);
    }

    [ObservableProperty]
    public partial PrinterViewModel? Selected { get; set; }

    /// <summary>
    /// True until Windows finishes its first mDNS sweep (~30 s). Printers usually appear within 2 s, so this only
    /// drives the empty-list state, never a spinner next to a list that already has printers.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowSearching), nameof(ShowNoPrinters))]
    public partial bool IsSearching { get; set; } = true;

    [ObservableProperty]
    public partial bool IsAddOpen { get; set; }

    public bool ShowSearching => IsEmpty && IsSearching;
    public bool ShowNoPrinters => IsEmpty && !IsSearching;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddByAddressCommand))]
    public partial string ManualAddress { get; set; } = "";

    [ObservableProperty]
    public partial string? ManualError { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddByAddressCommand))]
    public partial bool IsAdding { get; set; }

    public bool IsEmpty => Printers.Count == 0;

    private void NotifyEmpty()
    {
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(ShowSearching));
        OnPropertyChanged(nameof(ShowNoPrinters));
    }

    // ---------------------------------------------------------------- HP software clean-up

    /// <summary>HP Store apps still installed (HP Smart, HP's Print Support App). Empty when clean or dismissed.</summary>
    public ObservableCollection<InstalledApp> HpApps { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RemoveHpSoftwareCommand))]
    public partial bool IsRemovingHp { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowHpBanner))]
    public partial string? HpMessage { get; set; }

    /// <summary>HP services / virtual queue left outside the Store packages (need admin to remove).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowHpBanner), nameof(HpAppNames), nameof(HasHpSoftware))]
    public partial HpLeftovers.Found? HpLeftoversFound { get; set; }

    public bool HasHpSoftware => HpApps.Count > 0 || HpLeftoversFound?.Any == true;
    public bool ShowHpBanner => HasHpSoftware || HpMessage is not null;

    public string HpAppNames => string.Join(" and ", HpApps.Select(a => a.DisplayName)
        .Concat(HpLeftoversFound?.Any == true ? ["HP's background services"] : []));

    private async Task CheckHpSoftwareAsync()
    {
        try
        {
            var apps = await Task.Run(HpSoftware.Find);
            var leftovers = await HpLeftovers.FindAsync();
            // Dismissal sticks until a different set of HP software appears (e.g. Windows re-installs it).
            var fingerprint = Fingerprint(apps, leftovers);
            HpApps.Clear();
            HpLeftoversFound = null;
            if ((apps.Count > 0 || leftovers.Any) && fingerprint != _state.DismissedHpApps)
            {
                foreach (var a in apps) HpApps.Add(a);
                HpLeftoversFound = leftovers;
            }
        }
        catch (Exception ex)
        {
            Log.Write($"HP software check failed: {ex}");
        }
        OnPropertyChanged(nameof(ShowHpBanner));
        OnPropertyChanged(nameof(HpAppNames));
        OnPropertyChanged(nameof(HasHpSoftware));
    }

    private static string Fingerprint(IEnumerable<InstalledApp> apps, HpLeftovers.Found leftovers) =>
        string.Join("|", apps.Select(a => a.FullName).Order().Concat(leftovers.Any ? [leftovers.ToString()] : []));

    private bool CanRemoveHp() => !IsRemovingHp;

    [RelayCommand(CanExecute = nameof(CanRemoveHp))]
    private async Task RemoveHpSoftwareAsync()
    {
        if (!HasHpSoftware || !Features.HpCleanup) return;
        var removesPrintApp = HpApps.Any(a => a.IsPrintSupportApp);
        if (!Prompt.Ask($"Remove {HpAppNames}?\n\nInkvolt Print does what they did for this printer, and printing keeps working " +
                        "through Windows' own driver. HP's apps can be reinstalled from the Microsoft Store at any time." +
                        "\n\nWindows will ask for administrator permission once, to remove HP's background services and to turn off " +
                        "Windows' \"automatically download manufacturers' apps and custom icons\" for this PC (it's what re-installs " +
                        "HP's print app; it applies to all devices). To turn it back on: Control Panel › Devices and Printers › " +
                        "right-click this PC › Device installation settings." +
                        (removesPrintApp ? "\n\nYour HP printers are then set up again in Windows (about 30 seconds each), so printing keeps working." : ""),
                "Remove")) return;
        IsRemovingHp = true;
        var failures = new List<string>();
        try
        {
            foreach (var app in HpApps.ToList())
            {
                HpMessage = $"Removing {app.DisplayName}…";
                if (await HpSoftware.RemoveAsync(app) is { } error) failures.Add($"{app.DisplayName}: {error}");
            }
            // HP's print app leaves services and a virtual queue behind, and Windows would re-install it on the next
            // printer setup. One elevated step handles both.
            if ((await HpLeftovers.FindAsync()).Any || (removesPrintApp && !HpLeftovers.ManufacturerAppsBlocked()))
            {
                HpMessage = "Removing HP's background services… approve the Windows permission prompt.";
                if (await HpLeftovers.RemoveAsync() is { } error) failures.Add(error);
            }
            // Queues created while HP's print app was attached keep handing every job to it; with the app gone,
            // Windows cancels each job a few seconds in. Recreating the queue clears that association.
            if (removesPrintApp)
                foreach (var p in Printers.Where(p => p.QueueInstalled && p.PrintEndpointId is not null).ToList())
                {
                    HpMessage = $"Setting up {p.Name} again in Windows…";
                    if (await p.ReinstallQueueAsync() is { } error) failures.Add($"{p.Name}: {error}");
                }
        }
        finally
        {
            IsRemovingHp = false;
        }
        await CheckHpSoftwareAsync();
        HpMessage = failures.Count == 0
            ? "HP software removed. If Windows adds HP's print app again, Inkvolt Print will tell you."
            : $"Some HP software could not be removed. {string.Join(" ", failures)}";
    }

    [RelayCommand]
    private void DismissHpBanner()
    {
        if (HasHpSoftware)
        {
            _state.DismissedHpApps = Fingerprint(HpApps, HpLeftoversFound ?? new HpLeftovers.Found([], false, false));
            _state.Save();
        }
        HpApps.Clear();
        HpLeftoversFound = null;
        HpMessage = null;
        OnPropertyChanged(nameof(ShowHpBanner));
    }

    // ---------------------------------------------------------------- printers

    [RelayCommand]
    private void ToggleAdd()
    {
        IsAddOpen = !IsAddOpen;
        ManualError = null;
    }

    /// <summary>A second window with the made-up demo printer (App: --try), for anyone without a supported printer at hand.</summary>
    [RelayCommand]
    private static void TryDemo()
    {
        if (Environment.ProcessPath is not { } exe) return;
        try { System.Diagnostics.Process.Start(exe, "--try")?.Dispose(); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { Log.Write($"Demo didn't start: {ex.Message}"); }
    }

    [RelayCommand]
    private void SearchAgain()
    {
        if (_discovery is null) return;
        IsSearching = true;
        _discovery.Restart();
    }

    partial void OnSelectedChanged(PrinterViewModel? value)
    {
        _state.SelectedUuid = value?.Uuid;
        _state.Save();
        value?.EnsureSectionLoaded();
    }

    partial void OnSelectedChanged(PrinterViewModel? oldValue, PrinterViewModel? newValue)
    {
        if (oldValue is not null) oldValue.IsShown = false;
        if (newValue is not null) newValue.IsShown = true;
    }

    private void Merge(IReadOnlyList<DiscoveredPrinter> found)
    {
        foreach (var d in found)
        {
            if (!PrinterId.IsValid(d.Uuid)) continue; // mDNS TXT is untrusted text: only real UUIDs become printers
            var vm = Printers.FirstOrDefault(p => p.IsKnownAs(d.Uuid));
            if (vm is null)
            {
                if (d.Host is null || _state.ForgottenUuids.Contains(d.Uuid, StringComparer.OrdinalIgnoreCase)) continue;
                vm = new PrinterViewModel(d.Uuid, d.Name, d.Model, d.Host, d.EsclRoot, _state, Presets, Remember);
                Printers.Add(vm);
                vm.Start();
                Selected ??= vm;
                NotifyEmpty();
            }
            vm.ApplyDiscovery(d);
        }
        ReconcileQueues(); // a printer found on the network takes the place of its Windows queue's entry
    }

    // ---------------------------------------------------------------- printers known only by their Windows queue

    private static readonly TimeSpan QueueListInterval = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Reads Windows' queues now and then (local and cheap), so a USB printer plugged in, or a queue added in Settings, shows up.
    /// The first read waits a few seconds: discovery usually finds network printers by then, so their queues don't flash up as
    /// separate entries first.
    /// </summary>
    private async Task WatchQueuesAsync(CancellationToken ct)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(3), ct);
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    _queues = await InstalledQueues.ListAsync();
                    ReconcileQueues();
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    Log.Write($"Reading Windows' printers failed: {ex.Message}");
                }
                try
                {
                    _scanners = await _wia.ListScannersAsync(ct);
                    _scannersRead = true;
                    ReconcileScanners();
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    Log.Write($"Reading Windows' scanners failed: {ex.Message}");
                }
                await Task.Delay(QueueListInterval, ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>The network printers on the list, as queue matching sees them (accepted UUIDs count as theirs too, without a name).</summary>
    private InkvoltPrinters Claims(IEnumerable<PrinterViewModel> printers)
    {
        var list = new List<InkvoltPrinter>();
        var queueNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in printers.Where(p => p.IsNetworkPrinter))
        {
            list.Add(new InkvoltPrinter(p.Uuid, p.Name, p.Model, p.Host ?? "", p.EsclRoot));
            list.AddRange(_state.GetAcceptedUuids(p.Uuid).Select(u => new InkvoltPrinter(u, "", null, "", null)));
            if (_state.GetQueueName(p.Uuid) is { } q) queueNames[p.Uuid] = q;
        }
        return new InkvoltPrinters(list, queueNames);
    }

    /// <summary>
    /// The queue printers on the list follow Windows' real queues that no network printer here already stands for: new ones are
    /// added, ones Windows removed or a network printer now covers go (the selection moves to that printer). Queues the user
    /// removed from the list stay hidden until Windows no longer has them.
    /// </summary>
    private void ReconcileQueues()
    {
        var claims = Claims(Printers);
        var wanted = QueueKinds.Unclaimed(_queues, claims)
            .Where(q => !_state.ForgottenUuids.Contains(QueueKinds.IdFor(q.Name), StringComparer.OrdinalIgnoreCase))
            .DistinctBy(q => QueueKinds.IdFor(q.Name)).ToList();
        var ids = wanted.Select(q => QueueKinds.IdFor(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var gone in Printers.Where(p => p.IsQueuePrinter && !ids.Contains(p.Uuid)).ToList())
        {
            var wasSelected = Selected == gone;
            Printers.Remove(gone);
            gone.Dispose();
            if (wasSelected)
                Selected = (QueueMatch.Match(new QueueInfo(gone.WindowsQueue!.Name, gone.WindowsQueue.PortName, gone.WindowsQueue.ContainerId), claims) is { } owner
                    ? Printers.FirstOrDefault(p => string.Equals(p.Uuid, owner.Uuid, StringComparison.OrdinalIgnoreCase)) : null) ?? Printers.FirstOrDefault();
        }
        foreach (var q in wanted)
        {
            var id = QueueKinds.IdFor(q.Name);
            if (Printers.Any(p => string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase))) continue;
            var vm = new PrinterViewModel(q, QueueStatusSource(q), _state, Presets, Remember, _transport);
            Printers.Add(vm);
            vm.Start();
            if (Selected is null || string.Equals(id, _wantedSelection, StringComparison.OrdinalIgnoreCase)) Selected = vm;
        }
        if (_queues.Count > 0)
        {
            _wantedSelection = null;
            // Hidden queues come back once Windows no longer has them (set up again later, they show again).
            var present = _queues.Select(q => QueueKinds.IdFor(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (_state.ForgottenUuids.RemoveAll(f => QueueKinds.IsQueueId(f) && !present.Contains(f)) > 0) _state.Save();
        }
        ReconcileScanners(); // a printer that came or went may own one of the scanners
        NotifyEmpty();
    }

    // ---------------------------------------------------------------- scanners Windows has a driver for (WIA)

    /// <summary>A printer on the list as WIA matching sees it: its names (and its queue's and driver's) and addresses.</summary>
    private static ScanTarget Target(PrinterViewModel p) => new(p.Uuid,
        new[] { p.Name, p.Model, p.WindowsQueue?.Name, p.WindowsQueue?.DriverName }.OfType<string>().Where(n => n.Length > 0).ToList(),
        new[] { p.Host, p.WindowsQueue?.PortAddress }.OfType<string>().Where(h => h.Length > 0).ToList());

    /// <summary>Which printer on the list each WIA scanner belongs to (<see cref="WiaMatch"/>); null for one no printer claims.</summary>
    private IEnumerable<(WiaDeviceInfo Device, PrinterViewModel? Owner)> Owners()
    {
        var targets = Printers.Where(p => !p.IsScannerOnly).Select(Target).ToList();
        foreach (var d in _scanners)
            yield return (d, WiaMatch.Match(d, targets) is { } id
                ? Printers.FirstOrDefault(p => !p.IsScannerOnly && string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase)) : null);
    }

    /// <summary>
    /// Windows' scanners (WIA) follow the list: one that belongs to a printer without eSCL (a queue printer, or a network printer
    /// that answered without it) becomes that printer's scanner, so its Scan and Copy tabs work through Windows; one that belongs
    /// to a printer with eSCL is left alone (eSCL is used); one no printer claims is listed as a scanner of its own. Scanners the
    /// user removed stay hidden until Windows no longer has them; one with unsaved scans stays until they're saved.
    /// </summary>
    private void ReconcileScanners()
    {
        if (!_scannersRead) return;
        var owners = Owners().ToList();
        var given = new Dictionary<PrinterViewModel, WiaDeviceInfo>();
        foreach (var (device, owner) in owners)
            if (owner is { WantsWindowsScanner: true } && !given.ContainsKey(owner)) given[owner] = device;
        foreach (var p in Printers.Where(p => !p.IsScannerOnly).ToList())
            _ = p.UseWiaScannerAsync(given.GetValueOrDefault(p), _wia);

        var wanted = owners.Where(o => o.Owner is null).Select(o => o.Device)
            .Where(d => !_state.ForgottenUuids.Contains(PrinterViewModel.ScannerIdFor(d.Id), StringComparer.OrdinalIgnoreCase))
            .DistinctBy(d => PrinterViewModel.ScannerIdFor(d.Id)).ToList();
        var ids = wanted.Select(d => PrinterViewModel.ScannerIdFor(d.Id)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var gone in Printers.Where(p => p.IsScannerOnly && !ids.Contains(p.Uuid) && p.Scan?.HasUnsavedPages != true).ToList())
        {
            var wasSelected = Selected == gone;
            Printers.Remove(gone);
            gone.Dispose();
            if (wasSelected)
                Selected = owners.FirstOrDefault(o => PrinterViewModel.ScannerIdFor(o.Device.Id) == gone.Uuid).Owner ?? Printers.FirstOrDefault();
        }
        foreach (var d in wanted)
        {
            var id = PrinterViewModel.ScannerIdFor(d.Id);
            if (Printers.Any(p => string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase))) continue;
            var vm = new PrinterViewModel(d, _wia, _state, Presets, Remember, _transport);
            Printers.Add(vm);
            vm.Start();
            if (Selected is null || string.Equals(id, _wantedScanner, StringComparison.OrdinalIgnoreCase)) Selected = vm;
        }
        _wantedScanner = null;
        var present = _scanners.Select(d => PrinterViewModel.ScannerIdFor(d.Id)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (_state.ForgottenUuids.RemoveAll(f => PrinterViewModel.IsScannerId(f) && !present.Contains(f)) > 0) _state.Save();
        NotifyEmpty();
    }

    /// <summary>
    /// Where a queue printer's status comes from: Windows and the driver; for a queue whose port has the printer's address, the
    /// printer itself over SNMP too (status, problems, supply levels), with the port's own SNMP community when it has one.
    /// </summary>
    private IQueueStatusSource QueueStatusSource(SpoolerQueue q)
    {
        IQueueStatusSource windows = _transport is null ? new SpoolerStatusSource(q) : Demo.QueueStatus(q);
        return QueueKinds.SnmpAddress(q) is { } host
            ? new SnmpQueueStatusSource(windows, host, _transport is null ? UdpSnmpTransport.Instance : Demo.Snmp, q.PortCommunity)
            : windows;
    }

    private void Remember(PrinterViewModel p)
    {
        if (p.Host is null || !Printers.Contains(p)) return;
        ReconcileScanners(); // it just connected: with no eSCL, a scanner Windows has for it may stand in
        _state.Printers.RemoveAll(k => string.Equals(k.Uuid, p.Uuid, StringComparison.OrdinalIgnoreCase));
        _state.Printers.Add(new KnownPrinter(p.Uuid, p.Name, p.Model, p.Host, p.EsclRoot?.AbsoluteUri, p.IppUri?.AbsoluteUri));
        _state.Save();
    }

    private bool CanAddByAddress() => !string.IsNullOrWhiteSpace(ManualAddress) && !IsAdding;

    /// <summary>Add a printer that mDNS can't see (other subnet, VPN): probe it directly by IP or host name.</summary>
    [RelayCommand(CanExecute = nameof(CanAddByAddress))]
    private async Task AddByAddressAsync()
    {
        var host = ManualAddress.Trim();
        if (Uri.TryCreate(host, UriKind.Absolute, out var u)) host = u.Host;
        ManualError = null;
        if (Uri.CheckHostName(host) == UriHostNameType.Unknown)
        {
            ManualError = $"\"{host}\" is not a valid address.";
            return;
        }
        if (_transport is not null)
        {
            ManualError = "Adding printers is turned off in demo mode.";
            return;
        }
        IsAdding = true;
        try
        {
            using var http = new InkvoltPrint.Core.Net.DeviceHttp(host);
            var probe = await PrinterConnection.ProbeAsync(http, snmp: UdpSnmpTransport.Instance); // SNMP-only printers can be added too
            if (!probe.Reachable)
            {
                ManualError = $"No printer answered at {host}. Check the address and that the printer is on.";
                return;
            }
            var uuid = PrinterId.Normalize(probe.Uuid, host);
            _state.ForgottenUuids.RemoveAll(f => string.Equals(f, uuid, StringComparison.OrdinalIgnoreCase));
            var vm = Printers.FirstOrDefault(p => string.Equals(p.Uuid, uuid, StringComparison.OrdinalIgnoreCase));
            if (vm is null)
            {
                vm = new PrinterViewModel(uuid, probe.Model ?? host, probe.Model, host, probe.EsclRoot, _state, Presets, Remember) { IppUri = probe.IppEndpoint };
                Printers.Add(vm);
                vm.Start();
                NotifyEmpty();
            }
            Remember(vm);
            Selected = vm;
            ManualAddress = "";
            IsAddOpen = false;
            ReconcileQueues();
        }
        catch (Exception ex)
        {
            Log.Write($"Add by address failed: {ex}");
            ManualError = $"Could not add {host}: {ex.Message}";
        }
        finally
        {
            IsAdding = false;
        }
    }

    [RelayCommand]
    private void Forget(PrinterViewModel? p)
    {
        if (p is null) return;
        var warning = p.Scan?.HasUnsavedPages == true ? $"\n\nYou'll lose {p.Scan.PageCountText.ToLowerInvariant()} you scanned and haven't saved." : "";
        var again = !p.IsNetworkPrinter
            ? "It stays hidden here while Windows has it; if it's removed from Windows and set up again, it shows again."
            : "To see it again, add it by address.";
        if (!Prompt.Ask($"Remove {p.Name} from Inkvolt Print?{warning}\n\nThis doesn't remove it from Windows. {again}", "Remove"))
            return;
        _state.Printers.RemoveAll(k => string.Equals(k.Uuid, p.Uuid, StringComparison.OrdinalIgnoreCase));
        // A network printer's own Windows queues go with it, so they don't show up again as separate entries.
        IEnumerable<string> hidden = !p.IsNetworkPrinter ? [p.Uuid]
            : QueueKinds.Unclaimed(_queues, InkvoltPrinters.Empty).Where(q => QueueMatch.Match(new QueueInfo(q.Name, q.PortName, q.ContainerId), Claims([p])) is not null)
                .Select(q => QueueKinds.IdFor(q.Name)).Prepend(p.Uuid);
        // Its Windows scanner goes with it too, so it doesn't show up again as a scanner of its own.
        hidden = hidden.Concat(Owners().Where(o => o.Owner == p).Select(o => PrinterViewModel.ScannerIdFor(o.Device.Id))).ToList();
        foreach (var id in hidden)
            if (!_state.ForgottenUuids.Contains(id, StringComparer.OrdinalIgnoreCase)) _state.ForgottenUuids.Add(id);
        _state.Save();
        p.Dispose();
        Printers.Remove(p);
        if (Selected == p) Selected = Printers.FirstOrDefault();
        NotifyEmpty();
    }

    /// <summary>Printers holding scanned pages that haven't been saved (checked before the window closes).</summary>
    public IReadOnlyList<PrinterViewModel> PrintersWithUnsavedScans => Printers.Where(p => p.Scan?.HasUnsavedPages == true).ToList();

    /// <summary>A PDF handed to Inkvolt Print from outside (Open with, a second launch, drag-and-drop).</summary>
    /// <summary>The printer something handed in goes to: the selected one, or the first printer when a scanner on its own is selected.</summary>
    private PrinterViewModel? Printer()
    {
        if (Selected is { CanPrint: false } && Printers.FirstOrDefault(p => p.CanPrint) is { } printer) Selected = printer;
        return Selected is { CanPrint: true } p ? p : null;
    }

    public Task OpenPdfAsync(string path)
    {
        if (Printer() is { } p) return p.OpenPdfAsync(path);
        Prompt.Tell($"Inkvolt Print hasn't found a printer yet, so \"{System.IO.Path.GetFileName(path)}\" can't be printed. " +
                    "Wait for your printer to appear (or add it by address), then open the file again.");
        return Task.CompletedTask;
    }

    /// <summary>"Open with" / InkvoltPrint.exe photo.jpg …: the pictures go to the selected printer's Photos tab.</summary>
    public Task OpenPhotosAsync(IReadOnlyList<string> paths)
    {
        if (Printer() is { } p) return p.OpenPhotosAsync(paths);
        Prompt.Tell("Inkvolt Print hasn't found a printer yet, so the photos can't be printed. " +
                    "Wait for your printer to appear (or add it by address), then open them again.");
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _queueWatch.Cancel();
        _discovery?.Dispose();
        foreach (var p in Printers) p.Dispose();
    }
}
