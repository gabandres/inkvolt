using System.Collections.ObjectModel;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PrintDesk.Core.Model;
using PrintDesk.Core.Probe;
using PrintDesk.Windows.Cleanup;
using PrintDesk.Windows.Discovery;

namespace PrintDesk.App.ViewModels;

/// <summary>Yes/no questions the view models ask; wired to a real dialog by the app.</summary>
public static class Prompt
{
    /// <summary>Args: message, confirm-button wording. Returns true to go ahead. Unset (tests): always yes.</summary>
    public static Func<string, string, bool>? Confirm { get; set; }

    public static bool Ask(string message, string confirm) => Confirm?.Invoke(message, confirm) ?? true;

    /// <summary>Information only: one OK button. Unset (tests): no-op.</summary>
    public static Action<string>? Inform { get; set; }

    public static void Tell(string message) => Inform?.Invoke(message);
}

public sealed partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly AppState _state;
    private readonly PrinterDiscovery _discovery = new();

    public MainViewModel(AppState state)
    {
        _state = state;
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
                PrintDesk.Windows.Security.CredentialStore.Rename(k.Uuid, id);
            }
            catch (Exception ex)
            {
                Log.Write($"Id migration skipped for one printer: {ex.Message}");
            }
        }
        state.Printers = state.Printers.Select(k => k with { Uuid = PrinterId.Normalize(k.Uuid, k.Host) })
            .DistinctBy(k => k.Uuid, StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var k in state.Printers)
            Printers.Add(new PrinterViewModel(k.Uuid, k.Name, k.Model, k.Host, k.EsclRoot is null ? null : new Uri(k.EsclRoot), state, Remember));
        Selected = Printers.FirstOrDefault(p => p.Uuid == state.SelectedUuid) ?? Printers.FirstOrDefault();
        foreach (var p in Printers) p.Start();

        _discovery.Changed += list => Application.Current?.Dispatcher.InvokeAsync(() => Merge(list));
        _discovery.InitialSweepCompleted += () => Application.Current?.Dispatcher.InvokeAsync(() => IsSearching = false);
        _discovery.Start();
        if (Features.HpCleanup) _ = CheckHpSoftwareAsync();
    }

    public ObservableCollection<PrinterViewModel> Printers { get; } = [];

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
        if (!Prompt.Ask($"Remove {HpAppNames}?\n\nPrintDesk does what they did for this printer, and printing keeps working " +
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
            ? "HP software removed. If Windows adds HP's print app again, PrintDesk will tell you."
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

    [RelayCommand]
    private void SearchAgain()
    {
        IsSearching = true;
        _discovery.Restart();
    }

    partial void OnSelectedChanged(PrinterViewModel? value)
    {
        _state.SelectedUuid = value?.Uuid;
        _state.Save();
        value?.EnsureSectionLoaded();
    }

    private void Merge(IReadOnlyList<DiscoveredPrinter> found)
    {
        foreach (var d in found)
        {
            if (!PrinterId.IsValid(d.Uuid)) continue; // mDNS TXT is untrusted text: only real UUIDs become printers
            var vm = Printers.FirstOrDefault(p => string.Equals(p.Uuid, d.Uuid, StringComparison.OrdinalIgnoreCase));
            if (vm is null)
            {
                if (d.Host is null || _state.ForgottenUuids.Contains(d.Uuid, StringComparer.OrdinalIgnoreCase)) continue;
                vm = new PrinterViewModel(d.Uuid, d.Name, d.Model, d.Host, d.EsclRoot, _state, Remember);
                Printers.Add(vm);
                vm.Start();
                Selected ??= vm;
                NotifyEmpty();
            }
            vm.ApplyDiscovery(d);
        }
    }

    private void Remember(PrinterViewModel p)
    {
        if (p.Host is null || !Printers.Contains(p)) return;
        _state.Printers.RemoveAll(k => string.Equals(k.Uuid, p.Uuid, StringComparison.OrdinalIgnoreCase));
        _state.Printers.Add(new KnownPrinter(p.Uuid, p.Name, p.Model, p.Host, p.EsclRoot?.AbsoluteUri));
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
        IsAdding = true;
        try
        {
            using var http = new PrintDesk.Core.Net.DeviceHttp(host);
            var probe = await PrinterConnection.ProbeAsync(http);
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
                vm = new PrinterViewModel(uuid, probe.Model ?? host, probe.Model, host, probe.EsclRoot, _state, Remember);
                Printers.Add(vm);
                vm.Start();
                NotifyEmpty();
            }
            Remember(vm);
            Selected = vm;
            ManualAddress = "";
            IsAddOpen = false;
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
        if (!Prompt.Ask($"Remove {p.Name} from PrintDesk?{warning}\n\nThis doesn't remove it from Windows. To see it again, add it by address.", "Remove"))
            return;
        _state.Printers.RemoveAll(k => string.Equals(k.Uuid, p.Uuid, StringComparison.OrdinalIgnoreCase));
        if (!_state.ForgottenUuids.Contains(p.Uuid, StringComparer.OrdinalIgnoreCase)) _state.ForgottenUuids.Add(p.Uuid);
        _state.Save();
        p.Dispose();
        Printers.Remove(p);
        if (Selected == p) Selected = Printers.FirstOrDefault();
        NotifyEmpty();
    }

    /// <summary>Printers holding scanned pages that haven't been saved (checked before the window closes).</summary>
    public IReadOnlyList<PrinterViewModel> PrintersWithUnsavedScans => Printers.Where(p => p.Scan?.HasUnsavedPages == true).ToList();

    /// <summary>A PDF handed to PrintDesk from outside (Open with, a second launch, drag-and-drop).</summary>
    public Task OpenPdfAsync(string path)
    {
        if (Selected is { } p) return p.OpenPdfAsync(path);
        Prompt.Tell($"PrintDesk hasn't found a printer yet, so \"{System.IO.Path.GetFileName(path)}\" can't be printed. " +
                    "Wait for your printer to appear (or add it by address), then open the file again.");
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _discovery.Dispose();
        foreach (var p in Printers) p.Dispose();
    }
}
