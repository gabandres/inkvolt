using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Maintenance;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Windows.Security;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Overview's Maintenance card: only the actions the printer advertises (HP internal pages and alignment, IPP
/// Identify-Printer), each confirmed first with what it uses, plus the printer's maintenance and web pages. Disabled, with
/// the reason, while the printer is offline, printing, in error or answering the last request.
/// </summary>
public sealed partial class MaintenanceViewModel(string uuid, string printerName, AppState state, Action openWebPage, bool isDemo) : ObservableObject
{
    private MaintenanceClient? _client;
    private Core.Net.DeviceHttp? _http;
    private int _generation;
    private bool _online;
    private PrinterStatus? _status;

    public ObservableCollection<MaintenanceItemViewModel> Items { get; } = [];

    /// <summary>Read from the printer at least once (the card shows from then on).</summary>
    [ObservableProperty] public partial bool IsLoaded { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSupplyPage))]
    public partial Uri? SupplyPage { get; set; }

    public bool HasSupplyPage => SupplyPage is not null;

    /// <summary>Why something isn't offered (no maintenance interface, no IPP standard for cleaning).</summary>
    [ObservableProperty] public partial string? Note { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    [ObservableProperty] public partial bool IsBusy { get; set; }

    /// <summary>"Printer maintenance…" was chosen: the card scrolls into view and takes focus once it's on screen.</summary>
    public bool FocusRequested { get; set; }

    /// <summary>A new connection: read what it offers (in the background; only GETs and Get-Printer-Attributes).</summary>
    public async Task AttachAsync(PrinterConnection connection)
    {
        var generation = ++_generation;
        var client = new MaintenanceClient(connection, isDemo ? "demo" : Environment.UserName);
        MaintenanceOptions options;
        try
        {
            options = await client.DetectAsync();
        }
        catch (Exception ex)
        {
            Log.Write($"[{printerName}] maintenance options not read: {ex.Message}");
            options = MaintenanceOptions.None;
        }
        if (generation != _generation) return; // a newer connection took over meanwhile
        _client = client;
        _http = connection.Http;
        Items.Clear();
        foreach (var a in options.Actions) Items.Add(new MaintenanceItemViewModel(a, this));
        SupplyPage = options.SupplyPage;
        Note = options.Note;
        IsLoaded = true;
        Refresh();
    }

    /// <summary>The printer's state changed: re-check which actions can run.</summary>
    public void Update(bool online, PrinterStatus? status)
    {
        _online = online;
        if (status is not null && !status.IsUnavailable) _status = status;
        Refresh();
    }

    private void Refresh()
    {
        foreach (var i in Items) i.Reason = MaintenanceAvailability.WhyNot(i.Action, _online, _status, IsBusy);
    }

    partial void OnIsBusyChanged(bool value) => Refresh();

    internal async Task RunAsync(MaintenanceItemViewModel item)
    {
        if (_client is not { } client || _http is not { } http || item.Reason is not null) return;
        if (!Prompt.Ask(item.Action.ConfirmText, item.Action.ConfirmButton)) return;
        IsBusy = true;
        Message = $"Sending to the printer: {item.Action.Label}…";
        MessageIsError = false;
        try
        {
            var result = await RunWithPasswordAsync(client, http, item.Action);
            Message = result.Message;
            MessageIsError = !result.Ok;
        }
        catch (OperationCanceledException)
        {
            Message = "Not sent.";
            MessageIsError = false;
        }
        catch (LedmAuthRequiredException ex)
        {
            Message = ex.Message;
            MessageIsError = true;
        }
        catch (HttpRequestException)
        {
            // Only a changed certificate gets here (MaintenanceClient reports other network failures itself).
            Message = "Not sent: the printer's security certificate changed since Inkvolt Print first connected. Check it under Printer settings.";
            MessageIsError = true;
        }
        catch (Exception ex)
        {
            Log.Write($"[{printerName}] maintenance {item.Action.Id} failed: {ex}");
            Message = $"The printer did not take it: {ex.Message}";
            MessageIsError = true;
        }
        finally
        {
            IsBusy = false;
        }
        if (Message is { } said) Prompt.Announce(said);
    }

    /// <summary>
    /// Like saving settings: without a password first (many printers have none); on 401 ask for the admin password, send
    /// again with it, and keep it when asked to. Only an authentication refusal is sent again: the printer didn't act on it.
    /// </summary>
    private async Task<MaintenanceResult> RunWithPasswordAsync(MaintenanceClient client, Core.Net.DeviceHttp http, MaintenanceAction action)
    {
        (string Password, bool Remember)? entered = null;
        while (true)
        {
            try
            {
                var result = await client.RunAsync(action);
                if (entered is { Remember: true } e && !isDemo) CredentialStore.Save(uuid, e.Password);
                return result;
            }
            catch (LedmAuthRequiredException ex) when (!isDemo)
            {
                if (ex.CredentialsWereSent) CredentialStore.Delete(uuid);
                entered = SettingsViewModel.AskPassword?.Invoke(printerName, ex.CredentialsWereSent, state.GetCertificatePin(uuid))
                          ?? throw new OperationCanceledException();
                http.SetCredentials("admin", entered.Value.Password);
            }
        }
    }

    [RelayCommand]
    private void OpenSupplyPage()
    {
        if (SupplyPage is { } page && !isDemo) Shell.Open(page.AbsoluteUri);
    }

    [RelayCommand]
    private void OpenWebPage() => openWebPage();
}

/// <summary>One action's button on the card, with the reason it's disabled.</summary>
public sealed partial class MaintenanceItemViewModel(MaintenanceAction action, MaintenanceViewModel owner) : ObservableObject
{
    public MaintenanceAction Action { get; } = action;

    public string Label => Action.Label;
    public string Summary => Action.Summary;

    /// <summary>Segoe Fluent Icons: Print for pages, Repair for cleaning and alignment, Volume for Identify.</summary>
    public string Glyph => Action.Kind switch
    {
        MaintenanceKind.Cleaning or MaintenanceKind.SmearCleaning or MaintenanceKind.Alignment => "",
        MaintenanceKind.Identify => "",
        _ => "",
    };

    /// <summary>Screen readers: the label plus what it uses, or why it can't run now.</summary>
    public string AccessibleText => Reason is null ? $"{Label}. {Action.Uses}" : $"{Label}. Not available: {Reason}";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsAvailable), nameof(AccessibleText))]
    [NotifyCanExecuteChangedFor(nameof(RunCommand))]
    public partial string? Reason { get; set; }

    public bool IsAvailable => Reason is null;

    [RelayCommand(CanExecute = nameof(IsAvailable))]
    private Task RunAsync() => owner.RunAsync(this);
}
