using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Setup;

namespace InkvoltPrint.App.ViewModels;

/// <summary>One printer's network nearby, as the guide lists it: its name, the maker it names, what kind and whether it asks for a password.</summary>
public sealed record SetupNetworkRow(SetupCandidate Candidate, string Name, string Detail);

/// <summary>
/// Set up a new printer (roadmap 4.17): the window over <see cref="PrinterSetupGuide"/>, which decides every step; this shows them, passes
/// on the person's clicks, opens the printer's page and Windows' Wi-Fi list, and once back watches the printer list for the new printer
/// (<see cref="PrinterSetupGuide.FoundPrinter"/>). Closing the window while away goes back first.
/// </summary>
public sealed partial class PrinterSetupViewModel : ObservableObject, IDisposable
{
    private readonly PrinterSetupGuide _guide;
    private readonly MainViewModel _main;
    private readonly PcEnvironment _pc;
    private readonly CancellationTokenSource _closing = new();
    private HashSet<string> _before = [];
    private (string Id, string Name)? _found;

    public PrinterSetupViewModel(MainViewModel main, PcEnvironment pc)
    {
        _main = main;
        _pc = pc;
        _guide = new PrinterSetupGuide(pc.Wifi, line => Log.Write(line));
        _guide.Changed += OnChanged;
    }

    public PrinterSetupGuide Guide => _guide;

    private void OnChanged() => UiThread.Run(Refresh);

    public void Dispose()
    {
        _guide.Changed -= OnChanged;
        _closing.Cancel();
    }

    public ObservableCollection<SetupNetworkRow> Networks { get; } = [];

    public SetupStep Step => _guide.Step;

    public bool IsLooking => Step is SetupStep.Looking;
    public bool IsChoosing => Step is SetupStep.Choose;
    public bool HasNetworks => IsChoosing && Networks.Count > 0;
    public bool IsBusy => Step is SetupStep.Looking or SetupStep.Connecting or SetupStep.InWindows or SetupStep.Returning;
    public bool IsOnPrinter => Step is SetupStep.OnPrinter;
    public bool HasPage => IsOnPrinter && _guide.Page is not null;
    public bool IsBack => Step is SetupStep.Back;
    public bool CouldNotReturn => Step is SetupStep.CouldNotReturn;
    public bool CanLookAgain => Step is SetupStep.Choose or SetupStep.LocationOff or SetupStep.Back;
    public bool IsLocationOff => Step is SetupStep.LocationOff;

    /// <summary>What's happening, in a line.</summary>
    public string Status => Step switch
    {
        SetupStep.Looking => Strings.Setup_Looking,
        SetupStep.Choose => Networks.Count > 0 ? Strings.Setup_Choose : "",
        SetupStep.Connecting => string.Format(Strings.Setup_Connecting, _guide.Joined?.Network.Name),
        SetupStep.OnPrinter => string.Format(Strings.Setup_OnPrinter, _guide.Joined?.Network.Name),
        SetupStep.Returning => string.Format(Strings.Setup_Returning, _guide.HomeName ?? Strings.Setup_YourNetwork),
        SetupStep.Back => _found is { } found ? string.Format(Strings.Setup_Found, found.Name)
            : string.Format(_guide.HomeName is null ? Strings.Setup_BackOffWifi : Strings.Setup_Back, _guide.HomeName),
        _ => "",
    };

    public string? Problem => _guide.Problem;

    public bool HasProblem => Problem is not null;

    public string? PageAddress => _guide.Page?.Host;

    public bool HasFound => IsBack && _found is not null;

    public void Refresh()
    {
        if (Step == SetupStep.Choose)
        {
            Networks.Clear();
            foreach (var c in _guide.Candidates)
                Networks.Add(new SetupNetworkRow(c, c.Network.Name, string.Format(c.Kind == SetupNetworkKind.Setup ? Strings.Setup_KindSetup : Strings.Setup_KindDirect, c.Maker)
                    + (c.Network.Secured ? " · " + Strings.Setup_AsksPassword : "")));
        }
        foreach (var name in new[]
                 {
                     nameof(Step), nameof(IsLooking), nameof(IsChoosing), nameof(HasNetworks), nameof(IsBusy), nameof(IsOnPrinter), nameof(HasPage),
                     nameof(IsBack), nameof(CouldNotReturn), nameof(CanLookAgain), nameof(IsLocationOff), nameof(Status), nameof(Problem),
                     nameof(HasProblem), nameof(PageAddress), nameof(HasFound),
                 })
            OnPropertyChanged(name);
        if (Step == SetupStep.Back && _found is null) _ = WatchForPrinterAsync();
    }

    [RelayCommand]
    public async Task LookAsync()
    {
        try
        {
            await _guide.LookAsync(_closing.Token);
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Connect: the person's click on one network. The printers listed now are what "new" is measured against.</summary>
    [RelayCommand]
    private async Task ConnectAsync(SetupNetworkRow? row)
    {
        if (row is null) return;
        _before = [.. _main.Printers.Select(p => p.Uuid)];
        _found = null;
        try
        {
            await _guide.ConnectAsync(row.Candidate, _pc.OpenWifiList, _closing.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Write($"Printer setup: {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>Opens the printer's own setup page in the browser (only the address its network gave: <see cref="SetupNetworks.SetupPage"/>).</summary>
    [RelayCommand]
    private void OpenPage()
    {
        if (_guide.Page is not { } page) return;
        if (_pc.Browser is { } open) open(page.AbsoluteUri);
        else Prompt.Tell(string.Format(Strings.Setup_DemoPage, page.AbsoluteUri));
    }

    /// <summary>Done on the printer's page (or Cancel): back to the network the PC was on.</summary>
    [RelayCommand]
    private async Task ReturnAsync()
    {
        try
        {
            await _guide.ReturnAsync(CancellationToken.None);
        }
        catch (Exception ex)
        {
            Log.Write($"Printer setup: {ex.GetType().Name}: {ex.Message}");
        }
    }

    [RelayCommand]
    private void OpenWifiList() => _pc.OpenWifiList();

    [RelayCommand]
    private void OpenLocationSettings() => _pc.OpenSettings("ms-settings:privacy-location");

    [RelayCommand]
    private async Task CheckBackAsync() => await _guide.CheckBackAsync(CancellationToken.None);

    /// <summary>Shows the printer found on the home network in the main window.</summary>
    [RelayCommand]
    private void ShowFound()
    {
        if (_found is not { } found || _main.Printers.FirstOrDefault(p => p.Uuid == found.Id) is not { } printer) return;
        _main.IsFleetShown = false;
        _main.Selected = printer;
        CloseRequested?.Invoke();
    }

    public event Action? CloseRequested;

    /// <summary>Back home: the app's printer list is watched for two minutes for a printer that wasn't there before.</summary>
    private bool _watching;

    private async Task WatchForPrinterAsync()
    {
        if (_watching) return;
        _watching = true;
        try
        {
            for (var i = 0; i < 60 && !_closing.IsCancellationRequested && _found is null && Step == SetupStep.Back; i++)
            {
                _found = PrinterSetupGuide.FoundPrinter(_main.Printers.Select(p => (p.Uuid, p.Name)), _before, _guide.Joined?.Maker);
                if (_found is not null) break;
                await Task.Delay(TimeSpan.FromSeconds(2), _closing.Token);
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            _watching = false;
        }
        OnPropertyChanged(nameof(Status));
        OnPropertyChanged(nameof(HasFound));
    }

    private bool _returningToClose, _toldHow;

    /// <summary>
    /// The window is asked to close: true when it may now. While the PC is on the printer's network it may not: the guide goes back
    /// first (the window shows "Going back…" and stays responsive) and <paramref name="close"/> is called once it's back. If it can't go
    /// back, the window stays open saying how; asked again after that, it closes.
    /// </summary>
    public bool MayClose(Action close)
    {
        if (_returningToClose) return false;
        if (!_guide.IsAway || _toldHow)
        {
            Dispose();
            return true;
        }
        _returningToClose = true;
        _closing.Cancel(); // a join under way stops and goes back by itself
        _ = ReturnThenCloseAsync(close);
        return false;
    }

    private async Task ReturnThenCloseAsync(Action close)
    {
        try
        {
            await _guide.ReturnAsync(CancellationToken.None);
        }
        catch (Exception ex)
        {
            Log.Write($"Printer setup: not back on closing: {ex.GetType().Name}: {ex.Message}");
        }
        UiThread.Run(() =>
        {
            _returningToClose = false;
            _toldHow = _guide.Step == SetupStep.CouldNotReturn; // stays open to say how; the next Close closes
            if (!_toldHow) close();
        });
    }
}
