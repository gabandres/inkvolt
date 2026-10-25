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
    private readonly PcEnvironment _pc;
    private readonly CancellationTokenSource _queueWatch = new();
    private readonly SemaphoreSlim _relist = new(0, 1);
    private IReadOnlyList<SpoolerQueue> _queues = [];
    private bool _sweepDone;
    private string? _wantedSelection, _wantedScanner;
    private readonly IWiaSystem _wia;
    private IReadOnlyList<WiaDeviceInfo> _scanners = [];
    private bool _scannersRead;

    /// <param name="pc">This PC, or demo mode's made-up one (<c>--demo</c>): there every printer talks to made-up web servers instead
    /// of the network, the queues and scanners are made up, and discovery, adding by address and the HP software check are off.</param>
    public MainViewModel(AppState state, PcEnvironment pc)
    {
        _state = state;
        _pc = pc;
        _wia = pc.Wia;
        Presets = new ScanPresetLibrary(state, demo: pc.IsDemo);
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
                pc.Passwords.Rename(k.Uuid, id);
            }
            catch (Exception ex)
            {
                Log.Write($"Id migration skipped for one printer: {ex.Message}");
            }
        }
        state.Printers = state.Printers.Select(k => k with { Uuid = PrinterId.Normalize(k.Uuid, k.Host) })
            .DistinctBy(k => k.Uuid, StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var k in state.Printers)
            Printers.Add(new PrinterViewModel(k.Uuid, k.Name, k.Model, k.Host, k.EsclRoot is null ? null : new Uri(k.EsclRoot), state, Presets, Remember, pc)
            {
                IppUri = Uri.TryCreate(k.IppUri, UriKind.Absolute, out var ipp) ? ipp : null,
                SnmpDevice = k.Snmp,
            });
        // A queue printer chosen last time is listed a moment later (after the queues are read): selected then.
        _wantedSelection = QueueKinds.IsQueueId(state.SelectedUuid) ? state.SelectedUuid : null;
        _wantedScanner = PrinterList.IsScannerId(state.SelectedUuid) ? state.SelectedUuid : null;
        Selected = Printers.FirstOrDefault(p => p.Uuid == state.SelectedUuid) ?? Printers.FirstOrDefault();
        foreach (var p in Printers) p.Start();

        if (pc.FixedDevices is var (queues, scanners)) // the made-up PC's: known at once, never read from Windows
        {
            IsSearching = false;
            _sweepDone = true;
            _queues = queues;
            _scanners = scanners;
            _scannersRead = true;
            Reconcile(queues: true);
            return;
        }
        _ = WatchQueuesAsync(_queueWatch.Token);
        if (pc.ChecksHpSoftware) _ = CheckHpSoftwareAsync();
        if (pc.CreateDiscovery() is not { } discovery) return;
        _discovery = discovery;
        _discovery.Changed += list => Application.Current?.Dispatcher.InvokeAsync(() => Merge(list));
        _discovery.InitialSweepCompleted += () => Application.Current?.Dispatcher.InvokeAsync(() =>
        {
            IsSearching = false;
            if (_sweepDone || _queueWatch.IsCancellationRequested) return;
            _sweepDone = true;
            Reconcile(queues: true); // network queues no network printer claimed after the first sweep show now
        });
        _discovery.Start();
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
                if (d.Host is null || _state.IsForgotten(d.Uuid)) continue;
                vm = new PrinterViewModel(d.Uuid, d.Name, d.Model, d.Host, d.EsclRoot, _state, Presets, Remember, _pc);
                Printers.Add(vm);
                vm.Start();
                Selected ??= vm;
                NotifyEmpty();
            }
            vm.ApplyDiscovery(d);
        }
        Reconcile(queues: true); // a printer found on the network takes the place of its Windows queue's entry
    }

    // ---------------------------------------------------------------- printers known only by their Windows queue

    private static readonly TimeSpan QueueListInterval = TimeSpan.FromSeconds(30);

    /// <summary>Discovery's first sweep can take this long; network queues show after it at the latest.</summary>
    private static readonly TimeSpan SweepLimit = TimeSpan.FromSeconds(45);

    /// <summary>
    /// Reads Windows' queues now and then (local and cheap), so a USB printer plugged in, or a queue added in Settings, shows up;
    /// at once when a queue printer's queue went missing (renamed, perhaps). A network queue (TCP/IP, WSD, IPP) shows only once
    /// discovery's first sweep is done, so a printer discovery finds doesn't flash up as its queue first and then move.
    /// </summary>
    private async Task WatchQueuesAsync(CancellationToken ct)
    {
        try
        {
            var started = DateTime.UtcNow;
            await Task.Delay(TimeSpan.FromSeconds(3), ct);
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    var claims = PrinterList.Claims(Printers.Select(Listed));
                    var before = _queues;
                    var queues = await InstalledQueues.ListAsync(q => QueueKinds.NeedsPresence(q, claims));
                    ct.ThrowIfCancellationRequested(); // closed meanwhile: no printers made after Dispose
                    _queues = queues;
                    if (DateTime.UtcNow - started > SweepLimit) _sweepDone = true;
                    Reconcile(queues: true, QueueKinds.Renamed(before, queues));
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    Log.Write($"Reading Windows' printers failed: {ex.Message}");
                }
                try
                {
                    _scanners = await _wia.ListScannersAsync(ct);
                    _scannersRead = true;
                    Reconcile(queues: false);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    Log.Write($"Reading Windows' scanners failed: {ex.Message}");
                }
                await _relist.WaitAsync(QueueListInterval, ct);
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException) { }
    }

    /// <summary>A queue printer's queue went missing: read the queues now rather than in up to 30 s.</summary>
    private void RelistQueues()
    {
        try
        {
            if (_relist.CurrentCount == 0) _relist.Release();
        }
        catch (Exception ex) when (ex is SemaphoreFullException or ObjectDisposedException) { }
    }

    /// <summary>A printer on the list as the list module (<see cref="PrinterList"/>) sees it.</summary>
    private ListedPrinter Listed(PrinterViewModel p) =>
        p.IsScannerOnly ? new(p.Uuid, ListedKind.Scanner, p.Name, p.Model) { HasUnsavedScans = p.Scan?.HasUnsavedPages == true }
        : p.IsQueuePrinter ? new(p.Uuid, ListedKind.Queue, p.Name, p.Model) { Queue = p.WindowsQueue, WantsWindowsScanner = p.WantsWindowsScanner }
        : new(p.Uuid, ListedKind.Network, p.Name, p.Model, p.Host, p.EsclRoot)
        {
            WantsWindowsScanner = p.WantsWindowsScanner,
            AcceptedUuids = _state.GetAcceptedUuids(p.Uuid),
            QueueName = _state.GetQueueName(p.Uuid),
        };

    /// <summary>
    /// The list follows Windows (<see cref="PrinterList.Reconcile"/>): queue printers follow Windows' real queues that no network
    /// printer here stands for (the selection moves to the printer that now does, or follows a renamed queue); Windows' scanners
    /// go to the printer they belong to when it would take one (its Scan and Copy tabs then work through Windows), else are listed
    /// on their own; entries the user removed stay hidden until Windows no longer has them.
    /// </summary>
    /// <param name="queues">The queue printers too, from the last listing (else only the scanners).</param>
    /// <param name="renamed">Queues renamed in Windows since the listing before: old id → the queue now.</param>
    private void Reconcile(bool queues, IReadOnlyDictionary<string, SpoolerQueue>? renamed = null)
    {
        if (queues ? _queueWatch.IsCancellationRequested : !_scannersRead) return; // closed: nothing new is made or started
        var change = PrinterList.Reconcile(new PrinterListInput(Printers.Select(Listed).ToList(), Selected?.Uuid, queues ? _queues : null, _sweepDone,
            _scannersRead ? _scanners : null, _state.GetForgotten()) { Renamed = renamed, WantedQueue = _wantedSelection, WantedScanner = _wantedScanner });
        _state.Forget(change.Forget);
        _state.Unforget(change.Unforget);
        foreach (var id in change.Removed)
            if (Printers.FirstOrDefault(p => string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase)) is { } gone)
            {
                Printers.Remove(gone);
                gone.Dispose();
            }
        foreach (var q in change.AddedQueues)
        {
            var vm = new PrinterViewModel(q, _pc.QueueStatus(q), _state, Presets, Remember, _pc);
            vm.QueueMissing += RelistQueues;
            Printers.Add(vm);
            vm.Start();
        }
        foreach (var d in change.AddedScanners)
        {
            var vm = new PrinterViewModel(d, _wia, _state, Presets, Remember, _pc);
            Printers.Add(vm);
            vm.Start();
        }
        if (change.WindowsScanners is { } windowsScanners)
        {
            foreach (var p in Printers.Where(p => !p.IsScannerOnly).ToList())
                _ = p.UseWiaScannerAsync(windowsScanners.GetValueOrDefault(p.Uuid), _wia);
            _wantedScanner = null;
        }
        _wantedSelection = change.WantedQueue;
        var selected = Printers.FirstOrDefault(p => string.Equals(p.Uuid, change.Selected, StringComparison.OrdinalIgnoreCase));
        if (selected != Selected) Selected = selected;
        NotifyEmpty();
    }

    private void Remember(PrinterViewModel p)
    {
        if (p.Host is null || !Printers.Contains(p)) return;
        Reconcile(queues: false); // it just connected: with no eSCL, a scanner Windows has for it may stand in
        _state.RememberPrinter(new KnownPrinter(p.Uuid, p.Name, p.Model, p.Host, p.EsclRoot?.AbsoluteUri, p.IppUri?.AbsoluteUri, p.SnmpDevice));
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
        if (_pc.AddByAddressOff is { } off)
        {
            ManualError = off;
            return;
        }
        IsAdding = true;
        try
        {
            using var http = new InkvoltPrint.Core.Net.DeviceHttp(host, _pc.DeviceTransport());
            var probe = await PrinterConnection.ProbeAsync(http, snmp: _pc.Snmp); // SNMP-only printers can be added too
            if (!probe.Reachable)
            {
                ManualError = $"No printer answered at {host}. Check the address and that the printer is on.";
                return;
            }
            var uuid = PrinterId.Normalize(probe.Uuid, host);
            _state.Unforget([uuid]);
            var vm = Printers.FirstOrDefault(p => string.Equals(p.Uuid, uuid, StringComparison.OrdinalIgnoreCase));
            // Answering only SNMP now makes it an SNMP-only printer (it's asked over HTTP again later, in case it was asleep).
            var snmpOnly = probe.Snmp is { } snmp ? SnmpDevice.From(snmp) : null;
            if (vm is null)
            {
                vm = new PrinterViewModel(uuid, probe.Model ?? host, probe.Model, host, probe.EsclRoot, _state, Presets, Remember, _pc)
                    { IppUri = probe.IppEndpoint, SnmpDevice = snmpOnly };
                Printers.Add(vm);
                vm.Start();
                NotifyEmpty();
            }
            else vm.SnmpDevice ??= snmpOnly;
            Remember(vm);
            Selected = vm;
            ManualAddress = "";
            IsAddOpen = false;
            Reconcile(queues: true);
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
        _state.RemovePrinter(p.Uuid);
        // A network printer's own Windows queues and its Windows scanner go with it, so they don't show up again as entries of their own.
        _state.Forget(PrinterList.HiddenWith(Listed(p), Printers.Select(Listed).ToList(), _queues, _scanners));
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
        _queueWatch.Dispose();
        _relist.Dispose();
        _discovery?.Dispose();
        foreach (var p in Printers) p.Dispose();
    }
}
