using System.Collections.ObjectModel;
using System.Xml.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PrintDesk.Core.Ledm;
using PrintDesk.Core.Net;
using PrintDesk.Core.Probe;
using PrintDesk.Windows.Security;

namespace PrintDesk.App.ViewModels;

/// <summary>Device settings over LEDM: read Dyn + Cap, edit, PUT only what changed.</summary>
public sealed partial class SettingsViewModel(PrinterConnection connection, string uuid, string printerName, AppState state) : ObservableObject
{
    private static readonly (string Dyn, string Cap)[] Resources =
    [
        (LedmResource.ProductConfigDyn, LedmResource.ProductConfigCap),
        (LedmResource.PrintConfigDyn, LedmResource.PrintConfigCap),
        (LedmResource.MediaHandlingDyn, LedmResource.MediaHandlingCap),
    ];

    private PrinterConnection _connection = connection;
    private readonly Dictionary<string, XDocument> _dyn = new();

    /// <summary>Set by the view: asks for the admin password. Args: printer name, previous attempt rejected.</summary>
    public static Func<string, bool, (string Password, bool Remember)?>? AskPassword { get; set; }

    public ObservableCollection<SettingItemViewModel> Items { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ApplyCommand), nameof(LoadCommand))]
    public partial bool IsBusy { get; set; }

    [ObservableProperty] public partial bool IsLoaded { get; set; }
    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    /// <summary>The printer presented a different TLS certificate than the one first seen; writes are blocked.</summary>
    [ObservableProperty] public partial bool CertificateChanged { get; set; }

    public bool HasChanges => Items.Any(i => i.IsDirty);

    public void Rebind(PrinterConnection connection) => _connection = connection;

    private bool NotBusy() => !IsBusy;
    private bool CanApply() => !IsBusy && HasChanges && Items.All(i => i.Error is null);

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task LoadAsync()
    {
        var ledm = _connection.Ledm;
        if (ledm is null) return;
        IsBusy = true;
        Message = null;
        MessageIsError = false;
        try
        {
            var items = new List<SettingItemViewModel>();
            foreach (var (dyn, cap) in Resources)
            {
                var dynDoc = await ledm.GetAsync(dyn);
                if (dynDoc is null) continue;
                _dyn[dyn] = dynDoc;
                var capDoc = await ledm.GetAsync(cap);
                items.AddRange(LedmSettingCatalog.Read(LedmSettingCatalog.All.Where(d => d.DynResource == dyn), dynDoc, capDoc)
                    .Select(s => new SettingItemViewModel(s, OnItemChanged)));
            }
            Items.Clear();
            foreach (var i in items) Items.Add(i);
            IsLoaded = true;
            OnItemChanged();
        }
        catch (Exception ex)
        {
            Log.Write($"Settings load failed: {ex}");
            Fail($"Could not read settings: {ex.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand(CanExecute = nameof(CanApply))]
    private async Task ApplyAsync()
    {
        var ledm = _connection.Ledm;
        if (ledm is null) return;
        IsBusy = true;
        Message = "Saving…";
        MessageIsError = false;
        try
        {
            foreach (var group in Items.Where(i => i.IsDirty).GroupBy(i => i.Setting.Def.DynResource))
            {
                var body = LedmSettingCatalog.BuildPut(_dyn[group.Key], group.Select(i => (i.Setting.Def, i.Value)));
                await PutWithAuthAsync(ledm, group.Key, body);
            }
            IsBusy = false;
            await LoadAsync(); // read back what the printer actually stored
            if (!MessageIsError) Message = "Saved.";
        }
        catch (OperationCanceledException)
        {
            Message = "Not saved.";
        }
        catch (LedmAuthRequiredException ex)
        {
            Fail(ex.Message);
        }
        catch (HttpRequestException) when (_connection.Http.CertificateChanged)
        {
            CertificateChanged = true;
            Fail("Not saved: the printer's security certificate changed since PrintDesk first connected. If you reset or " +
                 "updated the printer, choose \"Trust the new certificate\". Otherwise another device may be impersonating it.");
        }
        catch (Exception ex)
        {
            Log.Write($"Settings save failed: {ex}");
            Fail($"The printer did not accept the change: {ex.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Unauthenticated first (many printers have no password); on 401 ask, retry, optionally remember.</summary>
    private async Task PutWithAuthAsync(LedmClient ledm, string resource, XDocument body)
    {
        (string Password, bool Remember)? entered = null;
        while (true)
        {
            try
            {
                await ledm.PutAsync(resource, body);
                if (entered is { Remember: true } e) CredentialStore.Save(uuid, e.Password);
                return;
            }
            catch (LedmAuthRequiredException ex)
            {
                if (ex.CredentialsWereSent) CredentialStore.Delete(uuid);
                entered = AskPassword?.Invoke(printerName, ex.CredentialsWereSent) ?? throw new OperationCanceledException();
                _connection.Http.SetCredentials("admin", entered.Value.Password);
            }
        }
    }

    [RelayCommand]
    private void TrustNewCertificate()
    {
        state.ClearCertificatePin(uuid);
        CertificateChanged = false;
        Message = "OK. The printer's current certificate will be trusted when you save again.";
        MessageIsError = false;
    }

    [RelayCommand]
    private void Revert()
    {
        foreach (var i in Items) i.Value = i.Setting.Value;
    }

    [RelayCommand]
    private void ForgetPassword()
    {
        CredentialStore.Delete(uuid);
        _connection.Http.ClearCredentials();
        Message = "Saved password removed.";
        MessageIsError = false;
    }

    private void OnItemChanged()
    {
        OnPropertyChanged(nameof(HasChanges));
        ApplyCommand.NotifyCanExecuteChanged();
    }

    private void Fail(string message)
    {
        Message = message;
        MessageIsError = true;
    }
}

public sealed partial class SettingItemViewModel : ObservableObject
{
    private readonly Action _changed;

    public SettingItemViewModel(LedmSetting setting, Action changed)
    {
        Setting = setting;
        _changed = changed;
        Choices = setting.Choices.Select(c => new Option<string>(c, setting.Display(c))).ToList();
        Value = setting.Value;
    }

    public LedmSetting Setting { get; }
    public string Label => Setting.Def.Label;
    public string Group => Setting.Def.Group;
    public IReadOnlyList<Option<string>> Choices { get; }
    public bool IsChoice => Setting.Def.Kind == SettingKind.Choice;
    public bool IsText => !IsChoice;
    public int MaxLength => Setting.MaxLength ?? 0;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsDirty), nameof(SelectedChoice))]
    public partial string Value { get; set; }

    [ObservableProperty] public partial string? Error { get; set; }

    public bool IsDirty => Value != Setting.Value;

    public Option<string>? SelectedChoice
    {
        get => Choices.FirstOrDefault(c => c.Value == Value);
        set { if (value is not null) Value = value.Value; }
    }

    partial void OnValueChanged(string value)
    {
        Error = Setting.Def.Kind switch
        {
            SettingKind.Integer when !int.TryParse(value, out var n) => "Enter a number",
            SettingKind.Integer when int.TryParse(value, out var n) && (n < (Setting.Min ?? int.MinValue) || n > (Setting.Max ?? int.MaxValue))
                => $"Between {Setting.Min} and {Setting.Max}",
            SettingKind.Text when Setting.MaxLength is { } max && value.Length > max => $"At most {max} characters",
            _ => null,
        };
        _changed?.Invoke();
    }
}
