using System.Collections.ObjectModel;
using System.Xml.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Windows.Security;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Device settings over LEDM: read Dyn + Cap, edit, PUT only what changed. Firmware auto-update comes from the
/// FirmwareUpdate interface (its own manifest and Config resource) and saves the same way.
/// </summary>
/// <param name="openWebPage">Opens the printer's web page (EWS); the demo printer has none.</param>
public sealed partial class SettingsViewModel(PrinterConnection connection, string uuid, string printerName, AppState state,
    Action? openWebPage = null) : ObservableObject
{
    private static readonly (string Dyn, string Cap)[] Resources =
    [
        (LedmResource.ProductConfigDyn, LedmResource.ProductConfigCap),
        (LedmResource.PrintConfigDyn, LedmResource.PrintConfigCap),
        (LedmResource.MediaHandlingDyn, LedmResource.MediaHandlingCap),
    ];

    private PrinterConnection _connection = connection;
    private readonly Dictionary<string, XDocument> _dyn = new();

    /// <summary>
    /// Set by the view: asks for the admin password. Args: printer name, previous attempt rejected, and the
    /// fingerprint of the certificate this PC pinned for the printer (shown so a first-use trust is visible).
    /// </summary>
    public static Func<string, bool, string?, (string Password, bool Remember)?>? AskPassword { get; set; }

    public ObservableCollection<SettingItemViewModel> Items { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ApplyCommand), nameof(LoadCommand))]
    public partial bool IsBusy { get; set; }

    [ObservableProperty] public partial bool IsLoaded { get; set; }
    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    /// <summary>The printer presented a different TLS certificate than the one first seen; writes are blocked.</summary>
    [ObservableProperty] public partial bool CertificateChanged { get; set; }

    /// <summary>Firmware version and automatic updates; null until loaded.</summary>
    [ObservableProperty] public partial FirmwareViewModel? Firmware { get; set; }

    public bool HasChanges => Items.Any(i => i.IsDirty) || Firmware?.IsDirty == true;

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
            Firmware = new FirmwareViewModel(OfferedFirmwareChoices(await TryGetFirmwareUpdateAsync(ledm)), _connection.Probe.Firmware?.Display,
                OnItemChanged, openWebPage);
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
                await PutWithAuthAsync(() => ledm.PutAsync(group.Key, body));
            }
            string? firmwareNote = null;
            if (Firmware is { IsDirty: true, Settings: { ConfigPath: { } path } fw, Selected: { } mode })
            {
                await PutWithAuthAsync(() => ledm.PutPathAsync(path, fw.BuildPut(mode.Value)));
                firmwareNote = await CheckFirmwareKeptAsync(ledm, fw, mode.Value);
            }
            IsBusy = false;
            await LoadAsync(); // read back what the printer actually stored
            if (!MessageIsError) Message = firmwareNote ?? "Saved.";
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
            Fail("Not saved: the printer's security certificate changed since Inkvolt Print first connected. If you reset or " +
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
    private async Task PutWithAuthAsync(Func<Task> put)
    {
        (string Password, bool Remember)? entered = null;
        while (true)
        {
            try
            {
                await put();
                if (entered is { Remember: true } e) CredentialStore.Save(uuid, e.Password);
                return;
            }
            catch (LedmAuthRequiredException ex)
            {
                if (ex.CredentialsWereSent) CredentialStore.Delete(uuid);
                entered = AskPassword?.Invoke(printerName, ex.CredentialsWereSent, state.GetCertificatePin(uuid)) ?? throw new OperationCanceledException();
                _connection.Http.SetCredentials("admin", entered.Value.Password);
            }
        }
    }

    [RelayCommand]
    private void TrustNewCertificate()
    {
        state.ClearCertificatePin(uuid);
        // The saved password must not ride along on the first handshake with the new certificate unattended.
        CredentialStore.Delete(uuid);
        _connection.Http.ClearCredentials();
        _connection.Http.ResetCertificateChanged();
        CertificateChanged = false;
        Message = "OK. Save again to trust the printer's current certificate; you'll be asked for the admin password.";
        MessageIsError = false;
    }

    [RelayCommand]
    private void Revert()
    {
        foreach (var i in Items) i.Value = i.Setting.Value;
        Firmware?.Revert();
    }

    /// <summary>Notify is left out for printers that don't keep it (unless one reads back Notify now).</summary>
    private FirmwareUpdateSettings? OfferedFirmwareChoices(FirmwareUpdateSettings? fw) =>
        fw is { Mode: not FirmwareUpdateMode.Notify }
        && (!state.KeepsFirmwareNotify(uuid) || FirmwareUpdateSettings.KnownNotToKeepNotify(_connection.Probe.Model))
            ? fw.WithoutNotify()
            : fw;

    /// <summary>
    /// Reads the firmware switches back after a write. A printer that ties the check to installs (Notify read back as
    /// Automatic) is set back to what it was before, remembered, and no longer offered Notify. Returns what to tell the user,
    /// or null when the printer kept the choice.
    /// </summary>
    private async Task<string?> CheckFirmwareKeptAsync(LedmClient ledm, FirmwareUpdateSettings before, FirmwareUpdateMode chosen)
    {
        if (await TryGetFirmwareUpdateAsync(ledm) is not { } back) return null;
        switch (FirmwareUpdateSettings.Judge(chosen, back.Mode))
        {
            case FirmwareUpdateWriteResult.Kept:
                return null;
            case FirmwareUpdateWriteResult.NotifyInstalls:
                Log.Write("Firmware: the printer read back Automatic after Notify was written; setting it back and no longer offering Notify");
                state.SetNoFirmwareNotify(uuid);
                if (back.Mode != before.Mode && back.ConfigPath is { } path)
                {
                    await PutWithAuthAsync(() => ledm.PutPathAsync(path, back.BuildPut(before.Mode)));
                    if (await TryGetFirmwareUpdateAsync(ledm) is not { } restored || restored.Mode != before.Mode)
                        return "This printer can't check for updates without installing them: it turned on automatic installs, and " +
                               "it didn't take the old setting back. Check automatic updates on its web page.";
                }
                return "This printer can't check for updates without installing them (it turned on automatic installs), so " +
                       $"automatic updates were set back to \"{FirmwareViewModel.Label(before.Mode)}\". \"{FirmwareViewModel.Label(FirmwareUpdateMode.Notify)}\" " +
                       "is no longer offered for it.";
            default:
                return $"Saved, but the printer reads back automatic updates as \"{FirmwareViewModel.Label(back.Mode)}\".";
        }
    }

    /// <summary>Firmware update settings are optional: a printer without them (or that fails to answer) still shows the rest.</summary>
    private static async Task<FirmwareUpdateSettings?> TryGetFirmwareUpdateAsync(LedmClient ledm)
    {
        try
        {
            return await ledm.GetFirmwareUpdateAsync();
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            Log.Write($"Firmware update settings not read: {ex.Message}");
            return null;
        }
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

/// <summary>
/// The Firmware card: version, and the printer's automatic firmware updates as one choice (install automatically /
/// check and tell me / don't check) where the printer lets apps change them. HP updates can bring "dynamic security",
/// which stops cartridges with non-HP chips from working, so the choice comes with that explanation.
/// </summary>
public sealed partial class FirmwareViewModel : ObservableObject
{
    private readonly Action _changed;
    private readonly Action? _openWebPage;

    public FirmwareViewModel(FirmwareUpdateSettings? settings, string? version, Action changed, Action? openWebPage)
    {
        Settings = settings;
        Version = version is { Length: > 0 } v ? v : "Not reported";
        _changed = changed;
        _openWebPage = openWebPage;
        Choices = settings?.Choices.Select(m => new Option<FirmwareUpdateMode>(m, Label(m))).ToList() ?? [];
        Selected = Choices.FirstOrDefault(c => c.Value == settings?.Mode);
    }

    public FirmwareUpdateSettings? Settings { get; }
    public string Version { get; }
    public IReadOnlyList<Option<FirmwareUpdateMode>> Choices { get; }
    public bool CanChange => Settings?.CanChange == true;
    public string? StatusMessage => Settings?.StatusMessage;
    public bool CanOpenWebPage => _openWebPage is not null;

    /// <summary>The printer reports the setting but doesn't let apps change it (or doesn't report it at all).</summary>
    public string? ReadOnlyText => CanChange ? null
        : Settings is { } s ? $"Automatic updates: {Label(s.Mode).ToLowerInvariant()}. This printer doesn't let apps change it; use its web page."
        : "This printer doesn't let apps see or change its firmware updates. Its web page has the update settings.";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsDirty), nameof(ModeHint))]
    public partial Option<FirmwareUpdateMode>? Selected { get; set; }

    public bool IsDirty => CanChange && Selected is not null && Selected.Value != Settings!.Mode;

    public string? ModeHint => Selected?.Value switch
    {
        FirmwareUpdateMode.Automatic => "The printer installs HP's updates by itself, as soon as they're out.",
        FirmwareUpdateMode.Notify => "The printer checks for updates; nothing installs until you install it from its web page.",
        FirmwareUpdateMode.Off => "The printer never checks. You can still update it from its web page.",
        _ => null,
    };

    partial void OnSelectedChanged(Option<FirmwareUpdateMode>? value) => _changed();

    public void Revert() => Selected = Choices.FirstOrDefault(c => c.Value == Settings?.Mode);

    [RelayCommand]
    private void OpenWebPage() => _openWebPage?.Invoke();

    internal static string Label(FirmwareUpdateMode m) => m switch
    {
        FirmwareUpdateMode.Automatic => "Install automatically",
        FirmwareUpdateMode.Notify => "Check, don't install",
        _ => "Off",
    };
}