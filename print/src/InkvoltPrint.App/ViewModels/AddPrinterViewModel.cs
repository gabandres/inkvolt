using System.Collections.ObjectModel;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Discovery;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Windows.Discovery;

namespace InkvoltPrint.App.ViewModels;

public enum FoundState { CanAdd, Adding, Added, Listed }

/// <summary>A printer the Add a printer window found: one the search turned up, or one removed from the list earlier.</summary>
public sealed partial class FoundPrinter : ObservableObject
{
    public required string Name { get; init; }
    public required string Host { get; init; }

    /// <summary>The address, and where the printer says it is ("192.168.1.40 · Office, 2nd floor"), or why it's offered.</summary>
    public required string Detail { get; init; }

    public ProbeResult? Probe { get; init; }
    public DiscoveredPrinter? Removed { get; init; }

    [ObservableProperty]
    public partial FoundState State { get; set; }

    [ObservableProperty]
    public partial string? Error { get; set; }

    /// <summary>The list's entry for it, once it's there.</summary>
    public PrinterViewModel? Printer { get; set; }

    public string AddName => $"Add {Name}";
    public string ShowName => $"Show {Name} in the list";
}

/// <summary>
/// Add a printer: searches this PC's network as soon as the window opens (printers found show as they're identified, those
/// already listed marked so), puts back printers removed earlier, points a USB printer at Windows' settings, and takes an
/// address (IP, name, or an ipp:// / http://host:port URL) as the last resort.
/// </summary>
public sealed partial class AddPrinterViewModel(MainViewModel main) : ObservableObject, IDisposable
{
    // A handful at a time: each one asked is a few HTTP requests (and SNMP for a printer without them).
    private readonly SemaphoreSlim _identifying = new(6);
    private CancellationTokenSource? _search;
    private readonly HashSet<string> _seen = new(StringComparer.OrdinalIgnoreCase);

    public ObservableCollection<FoundPrinter> Found { get; } = [];

    /// <summary>Raised to close the window (a printer was added by address).</summary>
    public event Action? CloseRequested;

    [ObservableProperty, NotifyCanExecuteChangedFor(nameof(SearchCommand))]
    public partial bool IsSearching { get; set; }

    /// <summary>0 to 1: the share of addresses asked.</summary>
    [ObservableProperty]
    public partial double Progress { get; set; }

    /// <summary>What the search is doing, or what it found.</summary>
    [ObservableProperty]
    public partial string Status { get; set; } = "";

    /// <summary>The search found nothing to add: say what may hide a printer.</summary>
    [ObservableProperty]
    public partial bool NothingFound { get; set; }

    [ObservableProperty, NotifyCanExecuteChangedFor(nameof(AddAddressCommand))]
    public partial string Address { get; set; } = "";

    [ObservableProperty]
    public partial string? AddressError { get; set; }

    [ObservableProperty, NotifyCanExecuteChangedFor(nameof(AddAddressCommand))]
    public partial bool IsAddingAddress { get; set; }

    /// <summary>Lists printers removed earlier that are on the network, then starts the search.</summary>
    public void Start()
    {
        foreach (var d in main.RemovedNearby())
        {
            _seen.Add(d.Host!);
            Insert(new FoundPrinter { Name = d.Name, Host = d.Host!, Detail = $"{d.Host} · Removed from your list earlier", Removed = d });
        }
        if (main.AddPrinterOff is { } off)
        {
            Status = off;
            return;
        }
        _ = SearchAsync();
    }

    private bool CanSearch() => !IsSearching;

    [RelayCommand(CanExecute = nameof(CanSearch))]
    private async Task SearchAsync()
    {
        _search?.Dispose();
        _search = new CancellationTokenSource();
        var ct = _search.Token;
        IsSearching = true;
        NothingFound = false;
        Progress = 0;
        Status = "Looking for printers on your network…";
        var total = 0;
        var identifying = new List<Task>();
        var ui = Application.Current.Dispatcher;
        var progress = new Progress<SearchProgress>(p =>
        {
            total = p.Total;
            Progress = (double)p.Checked / p.Total;
            if (IsSearching) Status = $"Looking for printers on your network… {p.Checked} of {p.Total} addresses";
        });
        try
        {
            await main.SearchNetworkAsync(host => ui.InvokeAsync(() =>
            {
                if (_seen.Add(host)) identifying.Add(IdentifyAsync(host, ct));
            }), progress, ct);
            await ui.InvokeAsync(() => { }); // the last addresses reported are queued: count them in
            Status = "Checking what answered…";
            await Task.WhenAll(identifying);
            Done(total);
        }
        catch (OperationCanceledException)
        {
            Status = "Search stopped.";
        }
        catch (Exception ex)
        {
            Log.Write($"Network search failed: {ex}");
            Status = "The search didn't work. You can still add a printer by its address.";
        }
        finally
        {
            IsSearching = false;
            Progress = 0;
        }
    }

    private void Done(int total)
    {
        var listed = Found.Count(f => f.State == FoundState.Listed);
        var others = Found.Count - listed;
        NothingFound = others == 0;
        Status = total == 0
            ? "This PC isn't on a home or office network that can be searched."
            : (others, listed) switch
            {
                (0, 0) => "No printers answered on your network.",
                (0, 1) => "The printer that answered is in your list already.",
                (0, _) => $"The {listed} printers that answered are in your list already.",
                (1, _) => "Found a printer you can add.",
                _ => $"Found {others} printers you can add.",
            };
    }

    [RelayCommand]
    private void StopSearch() => _search?.Cancel();

    private async Task IdentifyAsync(string host, CancellationToken ct)
    {
        await _identifying.WaitAsync(ct);
        try
        {
            var probe = await main.IdentifyAsync(host, null, ct);
            if (!probe.Reachable) return; // something else takes connections on a printer port
            var listed = main.Listed(probe, host);
            Insert(new FoundPrinter
            {
                Name = listed?.Name ?? probe.Model ?? host,
                Host = host,
                Detail = probe.Location is { } where ? $"{host} · {where}" : host,
                Probe = probe,
                State = listed is null ? FoundState.CanAdd : FoundState.Listed,
                Printer = listed,
            });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Log.Write($"[{host}] not identified: {ex.Message}");
        }
        finally
        {
            _identifying.Release();
        }
    }

    /// <summary>Ones to add first, then those listed; by name within each.</summary>
    private void Insert(FoundPrinter f)
    {
        var at = 0;
        while (at < Found.Count && Compare(Found[at], f) <= 0) at++;
        Found.Insert(at, f);

        static int Compare(FoundPrinter a, FoundPrinter b) => (a.State == FoundState.Listed).CompareTo(b.State == FoundState.Listed) is var c and not 0
            ? c : string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase);
    }

    [RelayCommand]
    private void Add(FoundPrinter? f)
    {
        if (f is not { State: FoundState.CanAdd }) return;
        f.State = FoundState.Adding;
        try
        {
            f.Printer = f.Removed is { } d ? main.AddBack(d) : main.Add(f.Probe!, f.Host);
            f.State = FoundState.Added;
        }
        catch (Exception ex)
        {
            Log.Write($"Adding {f.Host} failed: {ex}");
            f.Error = $"Couldn't add it: {ex.Message}";
            f.State = FoundState.CanAdd;
        }
    }

    /// <summary>Shows a listed (or just added) printer in the main window.</summary>
    [RelayCommand]
    private void Show(FoundPrinter? f)
    {
        if (f?.Printer is not { } p || !main.Printers.Contains(p)) return;
        main.ShowPrinter(p);
        CloseRequested?.Invoke();
    }

    [RelayCommand]
    private static void OpenWindowsSettings() => Shell.Open("ms-settings:printers");

    private bool CanAddAddress() => !string.IsNullOrWhiteSpace(Address) && !IsAddingAddress;

    [RelayCommand(CanExecute = nameof(CanAddAddress))]
    private async Task AddAddressAsync()
    {
        AddressError = null;
        var a = PrinterAddress.Parse(Address);
        if (a.Error is { } error)
        {
            AddressError = error;
            return;
        }
        if (main.AddPrinterOff is { } off)
        {
            AddressError = off;
            return;
        }
        IsAddingAddress = true;
        try
        {
            var probe = await main.IdentifyAsync(a.Host!, a.Ipp, CancellationToken.None);
            if (!probe.Reachable)
            {
                AddressError = $"No printer answered at {a.Host}. Check the address, and that the printer is on and on this network.";
                return;
            }
            if (main.Listed(probe, a.Host!) is { } listed) main.ShowPrinter(listed);
            else main.Add(probe, a.Host!);
            CloseRequested?.Invoke();
        }
        catch (Exception ex)
        {
            Log.Write($"Add by address failed: {ex}");
            AddressError = $"Couldn't add {a.Host}: {ex.Message}";
        }
        finally
        {
            IsAddingAddress = false;
        }
    }

    public void Dispose()
    {
        _search?.Cancel();
        _search?.Dispose();
    }
}
