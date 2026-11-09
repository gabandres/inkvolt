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
    private readonly DriverScanners _wia;
    private IReadOnlyList<WiaDeviceInfo> _scanners = [];
    private bool _scannersRead;
    private IDisposable? _usbWatch;

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
                pc.SnmpLogins.Rename(k.Uuid, id);
                pc.History.Rename(k.Uuid, id);
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
            _ = ReadNeedsDriverAsync(queues, _queueWatch.Token);
            return;
        }
        _usbWatch = pc.NeedsDriver.Watch(RelistQueues); // a USB printer plugged in or out: the queues and USB printers are read again at once
        _wia.TwainChanged += RelistQueues; // TWAIN's sources read (after WIA's were shown): listed now
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

    /// <summary>The Fleet page: every printer at once (roadmap 2.6). Made when first shown.</summary>
    public FleetViewModel Fleet => _fleet ??= new FleetViewModel(this, _pc);

    private FleetViewModel? _fleet;

    /// <summary>The main pane shows the Fleet page instead of the selected printer.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowPrinterPane), nameof(ShowNoPrinterHint), nameof(ShowNeedsDriverPane))]
    public partial bool IsFleetShown { get; set; }

    public bool ShowPrinterPane => Selected is not null && !IsFleetShown && SelectedNeedsDriver is null;
    public bool ShowNoPrinterHint => Selected is null && !IsFleetShown && SelectedNeedsDriver is null;

    partial void OnIsFleetShownChanged(bool value)
    {
        if (value) SelectedNeedsDriver = null;
        if (value) Fleet.Show();
        else _fleet?.Hide();
        // The queue card refreshes only while its printer is on screen.
        if (Selected is { } shown) shown.IsShown = !value;
    }

    /// <summary>A printer's page, from wherever: the selection may not change, and the Fleet page gives way all the same.</summary>
    public void ShowPrinter(PrinterViewModel printer)
    {
        Selected = printer;
        IsFleetShown = false;
    }

    /// <summary>Remembered printers and preferences (the tray's settings live there too).</summary>
    public AppState State => _state;

    /// <summary>Scan presets, shared by every printer (Scan tab, Overview scan card, Ctrl+1…9, jump list).</summary>
    public ScanPresetLibrary Presets { get; }

    /// <summary>Ctrl+1…Ctrl+9: the n-th preset on the selected printer.</summary>
    [RelayCommand]
    private async Task RunPresetAtAsync(string? number)
    {
        if (!int.TryParse(number, out var n) || n < 1 || n > Presets.Items.Count || Selected is not { Scan: not null } printer) return;
        IsFleetShown = false; // the scan shows on the printer's page
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
            Prompt.Tell(string.Format(Strings.Main_PresetNoScanner, preset.Name));
            return;
        }
        IsFleetShown = false; // the scan shows on the printer's page
        await printer.RunPresetAsync(preset);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowPrinterPane), nameof(ShowNoPrinterHint))]
    public partial PrinterViewModel? Selected { get; set; }

    /// <summary>
    /// True until Windows finishes its first mDNS sweep (~30 s). Printers usually appear within 2 s, so this only
    /// drives the empty-list state, never a spinner next to a list that already has printers.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowSearching), nameof(ShowNoPrinters))]
    public partial bool IsSearching { get; set; } = true;

    public bool ShowSearching => IsEmpty && IsSearching;
    public bool ShowNoPrinters => IsEmpty && !IsSearching;

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

    public string HpAppNames => HpApps.Select(a => a.DisplayName)
        .Concat(HpLeftoversFound?.Any == true ? [Strings.Main_HpBackgroundServices] : [])
        .Aggregate("", (list, name) => list.Length == 0 ? name : string.Format(Strings.Main_ListAnd, list, name));

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
        if (!Prompt.Ask(string.Format(Strings.Main_HpRemoveAsk, HpAppNames) + "\n\n" + Strings.Main_HpRemoveKeepsWorking +
                        "\n\n" + Strings.Main_HpRemoveAdmin +
                        (removesPrintApp ? "\n\n" + Strings.Main_HpRemoveSetUpAgain : ""),
                Strings.Common_Remove)) return;
        IsRemovingHp = true;
        var failures = new List<string>();
        try
        {
            foreach (var app in HpApps.ToList())
            {
                HpMessage = string.Format(Strings.Main_HpRemoving, app.DisplayName);
                if (await HpSoftware.RemoveAsync(app) is { } error) failures.Add($"{app.DisplayName}: {error}");
            }
            // HP's print app leaves services and a virtual queue behind, and Windows would re-install it on the next
            // printer setup. One elevated step handles both.
            if ((await HpLeftovers.FindAsync()).Any || (removesPrintApp && !HpLeftovers.ManufacturerAppsBlocked()))
            {
                HpMessage = Strings.Main_HpRemovingServices;
                if (await HpLeftovers.RemoveAsync() is { } error) failures.Add(error);
            }
            // Queues created while HP's print app was attached keep handing every job to it; with the app gone,
            // Windows cancels each job a few seconds in. Recreating the queue clears that association.
            if (removesPrintApp)
                foreach (var p in Printers.Where(p => p.QueueInstalled && p.PrintEndpointId is not null).ToList())
                {
                    HpMessage = string.Format(Strings.Main_HpSettingUpAgain, p.Name);
                    if (await p.ReinstallQueueAsync() is { } error) failures.Add($"{p.Name}: {error}");
                }
        }
        finally
        {
            IsRemovingHp = false;
        }
        await CheckHpSoftwareAsync();
        HpMessage = failures.Count == 0
            ? Strings.Main_HpRemoved
            : string.Format(Strings.Main_HpRemoveFailed, string.Join(" ", failures));
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

    // ---------------------------------------------------------------- supply history

    /// <summary>
    /// Export history…: one CSV of every printer's supply history (roadmap 1.1, Inkvolt Pro). Without the licence the Pro window
    /// says what it does and where to get it; the chart and days left stay free.
    /// </summary>
    [RelayCommand]
    private void ExportHistory()
    {
        var csv = Core.History.SupplyHistoryCsv.Export(_pc.History, Printers.Select(p => (p.Uuid, p.Name)).ToList());
        if (csv is null)
        {
            Views.ProWindow.Open(Application.Current?.MainWindow, Core.ProFeature.SupplyHistoryExport);
            return;
        }
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = Strings.Supplies_ExportTitle,
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            FileName = string.Format(Strings.Supplies_ExportFileName, DateTime.Now),
            Filter = Strings.Supplies_CsvFilter,
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            // With a byte order mark, so Excel reads the names as UTF-8.
            System.IO.File.WriteAllText(dialog.FileName, csv, new System.Text.UTF8Encoding(true));
            Prompt.Announce(string.Format(Strings.Supplies_Saved, System.IO.Path.GetFileName(dialog.FileName)));
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException)
        {
            Log.Write($"Supply history export failed: {ex.Message}");
            Prompt.Tell(string.Format(Strings.Supplies_SaveFailed, ex.Message));
        }
    }

    // ---------------------------------------------------------------- printers

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
        if (value is not null) SelectedNeedsDriver = null;
        OnPropertyChanged(nameof(ListSelected));
        _state.SelectedUuid = value?.Uuid;
        _state.Save();
        value?.EnsureSectionLoaded();
    }

    partial void OnSelectedChanged(PrinterViewModel? oldValue, PrinterViewModel? newValue)
    {
        if (oldValue is not null) oldValue.IsShown = false;
        if (newValue is not null) newValue.IsShown = !IsFleetShown;
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

    // ---------------------------------------------------------------- USB printers plugged in that need their driver

    /// <summary>USB printers Windows sees that nothing can print to (<see cref="NeedsDriver"/>), listed under the printers.</summary>
    public ObservableCollection<NeedsDriverViewModel> NeedsDriver { get; } = [];

    public string NeedsDriverListName => NeedsDriverText.ListName;

    /// <summary>The one whose page shows instead of the selected printer's (the selected printer stays selected underneath).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowPrinterPane), nameof(ShowNoPrinterHint), nameof(ShowNeedsDriverPane), nameof(ListSelected))]
    public partial NeedsDriverViewModel? SelectedNeedsDriver { get; set; }

    public bool ShowNeedsDriverPane => SelectedNeedsDriver is not null && !IsFleetShown;

    partial void OnSelectedNeedsDriverChanged(NeedsDriverViewModel? value)
    {
        if (value is not null) IsFleetShown = false;
    }

    /// <summary>
    /// The printer list's selection: the selected printer, or none while a USB printer needing its driver is shown (so choosing the
    /// same printer again shows it). Choosing one shows it.
    /// </summary>
    public PrinterViewModel? ListSelected
    {
        get => SelectedNeedsDriver is null ? Selected : null;
        set
        {
            if (value is null && SelectedNeedsDriver is not null) return; // the list letting go while the other page shows
            if (value is not null) SelectedNeedsDriver = null;
            if (value == Selected) OnPropertyChanged();
            else Selected = value;
        }
    }

    /// <summary>
    /// Reads the USB printers needing their driver after a queue list (cheap: one PnP query, none of it shown elsewhere) and follows
    /// them: one set up or unplugged goes, a new one is added, one whose driver came in moves on to "Set it up".
    /// </summary>
    private async Task ReadNeedsDriverAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct)
    {
        NeedsDriverRead read;
        try
        {
            read = await _pc.NeedsDriver.ReadAsync(queues, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Log.Write($"Reading USB printers failed: {ex.Message}");
            return;
        }
        if (ct.IsCancellationRequested) return;
        var ids = read.Printers.Select(p => p.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var gone in NeedsDriver.Where(v => !ids.Contains(v.Id) && !v.IsGettingDriver && !v.ShowConfirm && !v.IsWaitingForInstall).ToList())
        {
            if (SelectedNeedsDriver == gone) SelectedNeedsDriver = null;
            gone.SetUpDone -= RelistQueues;
            gone.DriverInstalled -= OnDriverInstalled;
            NeedsDriver.Remove(gone);
            Log.Write($"[{gone.Name}] no longer needs its driver here (set up, or unplugged)");
        }
        foreach (var p in read.Printers)
        {
            if (NeedsDriver.FirstOrDefault(v => string.Equals(v.Id, p.Id, StringComparison.OrdinalIgnoreCase)) is { } listed)
            {
                if (listed.Printer.Stage != p.Stage) Log.Write(NeedsDriverText.LogLine(p));
                listed.Update(p, read.ProtectedPrint);
                continue;
            }
            var vm = new NeedsDriverViewModel(p, read.ProtectedPrint, _pc.NeedsDriver, IsThereAsync);
            vm.SetUpDone += RelistQueues;
            vm.DriverInstalled += OnDriverInstalled;
            NeedsDriver.Add(vm);
            Log.Write(NeedsDriverText.LogLine(p) + (read.ProtectedPrint ? " (Windows protected print mode is on)" : ""));
        }
        OnPropertyChanged(nameof(NeedsDriverScanners));
        OnPropertyChanged(nameof(HasNeedsDriverScanners));
    }

    /// <summary>The scanners among them: the Scan tab says so too.</summary>
    public IReadOnlyList<NeedsDriverViewModel> NeedsDriverScanners => NeedsDriver.Where(v => v.IsScanner).ToList();

    public bool HasNeedsDriverScanners => NeedsDriver.Any(v => v.IsScanner);

    [RelayCommand]
    private void ShowNeedsDriver(NeedsDriverViewModel? which)
    {
        if (which is not null) SelectedNeedsDriver = which;
    }

    /// <summary>The WIA scanner each device's driver went in for (by the device's id), once Windows lists it. UI thread only.</summary>
    private readonly Dictionary<string, WiaDeviceInfo> _installedScanners = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Whether Windows has the device now, after its driver's installer: a scanner when WIA lists one of its model (never a TWAIN
    /// source: WIA is what the Scan tab uses first), a printer when it no longer needs its driver. Asked from any thread (the
    /// driver flow's); run on the UI thread, as the list's own reads are, so the scanners and queues it reads and keeps are never
    /// touched off it.
    /// </summary>
    private Task<bool> IsThereAsync(NeedsDriverPrinter device, CancellationToken ct) =>
        Application.Current?.Dispatcher is { } ui && !ui.CheckAccess()
            ? ui.InvokeAsync(() => IsThereOnUiAsync(device, ct)).Task.Unwrap()
            : IsThereOnUiAsync(device, ct);

    private async Task<bool> IsThereOnUiAsync(NeedsDriverPrinter device, CancellationToken ct)
    {
        // Plugged in and working: an unplugged device (as an installer may ask) is still waited for, never "found".
        var now = DeviceState.Of(device, await _pc.NeedsDriver.DeviceNodesAsync(device, ct), _queues);
        if (now != DeviceNow.Working) return false;
        if (!device.IsScanner) return DeviceState.Found(device, now, wiaLists: false);
        var listed = await _wia.ListNowAsync(ct);
        var match = listed.FirstOrDefault(d => !d.IsTwain && UsbScanners.SameModel(device.Name, d.Name));
        if (!DeviceState.Found(device, now, match is not null)) return false;
        _installedScanners[device.Id] = match!;
        _scanners = listed;
        _scannersRead = true;
        return true;
    }

    /// <summary>Its driver went in: the list reads Windows again, and a scanner is selected with its Scan tab shown.</summary>
    private void OnDriverInstalled(NeedsDriverViewModel which)
    {
        RelistQueues();
        if (!which.IsScanner || !_installedScanners.Remove(which.Id, out var scanner)) return;
        var id = PrinterList.ScannerIdFor(scanner.Id);
        _wantedScanner = id;
        Reconcile(queues: false);
        var shown = Printers.FirstOrDefault(p => string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase))
                    ?? Printers.FirstOrDefault(p => p.Scan is not null && UsbScanners.SameModel(which.Name, p.Name));
        if (shown is null) return;
        SelectedNeedsDriver = null;
        IsFleetShown = false;
        Selected = shown;
        shown.SelectedSection = PrinterViewModel.ScanSection;
        Log.Write($"[{which.Name}] driver installed: selected in the Scan tab as {scanner.Name}");
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
                await ReadNeedsDriverAsync(_queues, ct);
                try
                {
                    _scanners = await _wia.ListNowAsync(ct); // TWAIN's sources as read before; a new read lists again (TwainChanged)
                    _scannersRead = true;
                    Reconcile(queues: false);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // WIA failing with nothing in its place (no TWAIN source either): the scanner list said it, once.
                    if (!ReferenceEquals(ex, _wia.WiaFailure)) Log.Write($"Reading Windows' scanners failed: {ex.Message}");
                }
                // A driver the user is installing from the maker's link (a Store copy): is the device there now?
                foreach (var waiting in NeedsDriver.Where(v => v.IsWaitingForInstall).ToList()) await waiting.CheckAgainAsync();
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
                if (gone.Scan is { HasUnsavedPages: true } unsaved)
                {
                    KeepForScans(gone, unsaved);
                    continue;
                }
                if (_keptForScans.Remove(gone, out var saved)) saved.PropertyChanged -= KeptScanChanged;
                Printers.Remove(gone);
                gone.Dispose();
            }
        // Only a pass over the queues can tell a kept printer's queue is back (a scanners-only pass never removes queue printers).
        if (queues)
            foreach (var back in _keptForScans.Keys.Where(p => !change.Removed.Contains(p.Uuid, StringComparer.OrdinalIgnoreCase)).ToList())
                LetGo(back); // its queue is back
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
        if (selected != Selected && !(Selected is { } shown && _keptForScans.ContainsKey(shown))) Selected = selected; // not away from pages being reviewed
        NotifyEmpty();
    }

    /// <summary>Queue printers the list would drop (see <see cref="KeepForScans"/>), with the Scan tab watched for its pages being saved.</summary>
    private readonly Dictionary<PrinterViewModel, ScanViewModel> _keptForScans = [];

    /// <summary>
    /// A queue printer whose Windows queue went (removed or renamed), or that a network printer found later now stands for, stays
    /// listed while its Scan tab has pages not saved yet, as a scanner on its own does: they can still be reviewed and saved (and
    /// stay kept on disk). Once they're saved or cleared the queues are read again, and it goes.
    /// </summary>
    private void KeepForScans(PrinterViewModel p, ScanViewModel scan)
    {
        if (_keptForScans.ContainsKey(p)) return;
        Log.Write($"[{p.Name}] stays listed until its unsaved scanned pages are saved or cleared");
        _keptForScans[p] = scan;
        p.QueueMissing -= RelistQueues; // known: not read again every few seconds
        scan.PropertyChanged += KeptScanChanged;
    }

    private void LetGo(PrinterViewModel p)
    {
        if (!_keptForScans.Remove(p, out var scan)) return;
        scan.PropertyChanged -= KeptScanChanged;
        p.QueueMissing += RelistQueues;
    }

    private void KeptScanChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ScanViewModel.HasUnsavedPages) && sender is ScanViewModel { HasUnsavedPages: false }) RelistQueues();
    }

    private void Remember(PrinterViewModel p)
    {
        if (p.Host is null || !Printers.Contains(p)) return;
        Reconcile(queues: false); // it just connected: with no eSCL, a scanner Windows has for it may stand in
        _state.RememberPrinter(new KnownPrinter(p.Uuid, p.Name, p.Model, p.Host, p.EsclRoot?.AbsoluteUri, p.IppUri?.AbsoluteUri, p.SnmpDevice));
    }

    [RelayCommand]
    private void Forget(PrinterViewModel? p)
    {
        if (p is null) return;
        var warning = p.Scan?.HasUnsavedPages == true ? "\n\n" + string.Format(Strings.Main_ForgetUnsaved, p.Scan.PageCountText.ToLowerInvariant()) : "";
        var again = !p.IsNetworkPrinter
            ? Strings.Main_ForgetNotFromWindowsLocal
            : Strings.Main_ForgetNotFromWindowsNetwork;
        if (!Prompt.Ask(string.Format(Strings.Main_ForgetAsk, p.Name) + warning + "\n\n" + again, Strings.Common_Remove))
            return;
        _state.RemovePrinter(p.Uuid);
        _pc.History.Forget(p.Uuid);
        _pc.SnmpLogins.Delete(p.Uuid); // its community goes with it: Add a printer asks for it again
        // A network printer's own Windows queues and its Windows scanner go with it, so they don't show up again as entries of their own.
        _state.Forget(PrinterList.HiddenWith(Listed(p), Printers.Select(Listed).ToList(), _queues, _scanners));
        _state.Save();
        if (_keptForScans.Remove(p, out var kept)) kept.PropertyChanged -= KeptScanChanged;
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
        if (Selected is { CanPrint: true }) IsFleetShown = false; // what's handed in shows on the printer's page
        return Selected is { CanPrint: true } p ? p : null;
    }

    public Task OpenPdfAsync(string path)
    {
        if (Printer() is { } p) return p.OpenPdfAsync(path);
        Prompt.Tell(string.Format(Strings.Main_NoPrinterForPdf, System.IO.Path.GetFileName(path)));
        return Task.CompletedTask;
    }

    /// <summary>"Open with" / InkvoltPrint.exe photo.jpg …: the pictures go to the selected printer's Photos tab.</summary>
    public Task OpenPhotosAsync(IReadOnlyList<string> paths)
    {
        if (Printer() is { } p) return p.OpenPhotosAsync(paths);
        Prompt.Tell(Strings.Main_NoPrinterForPhotos);
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _fleet?.Hide();
        _queueWatch.Cancel();
        _queueWatch.Dispose();
        _wia.TwainChanged -= RelistQueues;
        _relist.Dispose();
        _usbWatch?.Dispose();
        _discovery?.Dispose();
        foreach (var p in Printers) p.Dispose();
    }
}
