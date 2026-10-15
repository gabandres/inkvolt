using System.Collections.ObjectModel;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PrintDesk.Core.Probe;
using PrintDesk.Windows.Discovery;

namespace PrintDesk.App.ViewModels;

public sealed partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly AppState _state;
    private readonly PrinterDiscovery _discovery = new();

    public MainViewModel(AppState state)
    {
        _state = state;
        foreach (var k in state.Printers)
            Printers.Add(new PrinterViewModel(k.Uuid, k.Name, k.Model, k.Host, k.EsclRoot is null ? null : new Uri(k.EsclRoot), state, Remember));
        Selected = Printers.FirstOrDefault(p => p.Uuid == state.SelectedUuid) ?? Printers.FirstOrDefault();
        foreach (var p in Printers) p.Start();

        _discovery.Changed += list => Application.Current?.Dispatcher.InvokeAsync(() => Merge(list));
        _discovery.InitialSweepCompleted += () => Application.Current?.Dispatcher.InvokeAsync(() => IsSearching = false);
        _discovery.Start();
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
    public partial bool IsAdding { get; set; }

    public bool IsEmpty => Printers.Count == 0;

    private void NotifyEmpty()
    {
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(ShowSearching));
        OnPropertyChanged(nameof(ShowNoPrinters));
    }

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
    }

    private void Merge(IReadOnlyList<DiscoveredPrinter> found)
    {
        foreach (var d in found)
        {
            var vm = Printers.FirstOrDefault(p => string.Equals(p.Uuid, d.Uuid, StringComparison.OrdinalIgnoreCase));
            if (vm is null)
            {
                if (d.Host is null) continue;
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
        if (p.Host is null) return;
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
        IsAdding = true;
        try
        {
            using var http = new PrintDesk.Core.Net.DeviceHttp(host);
            var probe = await PrinterConnection.ProbeAsync(http);
            if (!probe.Reachable)
            {
                ManualError = $"No printer answered at {host}.";
                return;
            }
            var uuid = probe.Uuid ?? host;
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
        catch (Exception ex) when (ex is ArgumentException or UriFormatException)
        {
            ManualError = $"\"{host}\" is not a valid address.";
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
        _state.Printers.RemoveAll(k => k.Uuid == p.Uuid);
        _state.Save();
        p.Dispose();
        Printers.Remove(p);
        if (Selected == p) Selected = Printers.FirstOrDefault();
        NotifyEmpty();
    }

    public void Dispose()
    {
        _discovery.Dispose();
        foreach (var p in Printers) p.Dispose();
    }
}
