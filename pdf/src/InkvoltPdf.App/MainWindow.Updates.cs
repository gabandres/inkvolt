using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Microsoft Store updates for packaged installs: one check ~30 s after startup (Settings › "Check for updates when Inkvolt
/// PDF starts") and Help › Check for Updates. A ready update shows in the title bar; Update asks about unsaved documents
/// as closing does, closes them, then has the Store install it (Windows closes the app meanwhile). Decisions:
/// <see cref="UpdateCheck"/> (InkvoltPdf.Core, unit-tested); Store calls: <see cref="StoreUpdates"/>.
/// </summary>
public partial class MainWindow
{
    private IStoreUpdates? _storeUpdates;
    private bool _packagedForUpdates = AppEnvironment.IsPackaged;
    private bool _updateChecking;
    private bool _updateInstalling;
    private UpdateCheckResult _updateResult = UpdateCheckResult.Skipped;

    private IStoreUpdates StoreUpdater => _storeUpdates ??= new StoreUpdates(this);

    /// <summary>The startup check: in the background, a while after the window is up, silent unless an update is ready.</summary>
    public void StartUpdateCheck()
    {
        if (!AppEnvironment.IsPackaged || !AppSettings.Current.CheckForUpdates) return;
        _ = StartupUpdateCheckAsync();
    }

    private async Task StartupUpdateCheckAsync()
    {
        try
        {
            await Task.Delay(UpdateCheck.StartupDelay);
            if (_closed) return;
            await CheckForUpdatesAsync(UpdateCheckTrigger.Startup);
        }
        catch (Exception ex)
        {
            Log.Write($"Startup update check failed: {ex.Message}"); // never a reason to bother the user
        }
    }

    private async Task CheckForUpdatesAsync(UpdateCheckTrigger trigger)
    {
        if (_updateChecking || _updateInstalling) return;
        _updateChecking = true;
        UpdateCheckResult result;
        try
        {
            result = await UpdateCheck.RunAsync(StoreUpdater, trigger, _packagedForUpdates, AppSettings.Current.CheckForUpdates, Log.Write);
        }
        finally
        {
            _updateChecking = false;
        }
        if (_closed) return;
        if (UpdateCheck.ShowsNotice(result) || result == UpdateCheckResult.UpToDate) ShowUpdateNotice(result);
        if (trigger == UpdateCheckTrigger.Startup) return;
        switch (result)
        {
            case UpdateCheckResult.Ready or UpdateCheckResult.Mandatory:
                await OfferUpdateAsync();
                break;
            case UpdateCheckResult.UpToDate:
                ShowStatus(UpdateCheck.UpToDateText);
                break;
            case UpdateCheckResult.NotFromStore:
                Prompt.Info(this, "Check for Updates", UpdateCheck.NotFromStoreText);
                break;
            case UpdateCheckResult.Failed:
                Prompt.Info(this, "Couldn't check for updates", UpdateCheck.FailedText);
                break;
        }
    }

    /// <summary>The title bar's update button: shown while an update is ready, firmer when it is mandatory.</summary>
    private void ShowUpdateNotice(UpdateCheckResult result)
    {
        _updateResult = result;
        var show = UpdateCheck.ShowsNotice(result);
        var mandatory = result == UpdateCheckResult.Mandatory;
        UpdateButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        UpdateText.Text = mandatory ? "Update required" : "Update";
        UpdateIcon.Text = mandatory ? "" : "";
        UpdateIcon.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty,
            mandatory ? "SystemFillColorCautionBrush" : "AccentTextFillColorPrimaryBrush");
        var text = show ? UpdateCheck.NoticeText(mandatory) : "";
        UpdateButton.ToolTip = !show ? null : mandatory ? text : $"{text}: install it now";
        System.Windows.Automation.AutomationProperties.SetName(UpdateButton, text);
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, LayoutTabs);
    }

    private void OnUpdateButton(object sender, RoutedEventArgs e) => _ = OfferUpdateAsync();

    /// <summary>Update or Later; Update first settles unsaved documents as closing the window does.</summary>
    private async Task OfferUpdateAsync()
    {
        if (_updateInstalling) return;
        var mandatory = _updateResult == UpdateCheckResult.Mandatory;
        var choice = Prompt.Choose(this, mandatory ? "A required update to Inkvolt PDF is ready" : UpdateCheck.NoticeText(false),
            (mandatory ? "Please install it now. " : "") + "Windows closes Inkvolt PDF while it installs the update. You're asked about unsaved changes first.",
            ("Update", true), ("Later", false));
        if (choice != 0) return;
        await InstallUpdateAsync();
    }

    private async Task InstallUpdateAsync()
    {
        _updateInstalling = true;
        try
        {
            List<string> closed = [];
            var settled = await PrepareToCloseAll(() => [.. _tabs], () =>
            {
                // Everything is saved or let go: close the documents (their recovery copies go with them), remembering
                // them so "Reopen the files I had open" brings them back after the update.
                RememberOpenTabs();
                closed = [.. AppSettings.Current.OpenTabs];
                foreach (var m in _tabs.ToList()) Discard(m);
                _autosave.Copy(wait: true);
                SavePlacement();
                UpdateUi();
            });
            if (!settled || _closed) return;

            StoreInstallOutcome outcome;
            try
            {
                outcome = await StoreUpdater.InstallAsync();
            }
            catch (Exception ex)
            {
                Log.Write($"Store update install failed: {ex.GetType().Name}: {ex.Message}");
                outcome = StoreInstallOutcome.Failed;
            }
            if (_closed) return;
            // Still running: the install was canceled or failed (or finished without closing the app). Bring the documents back.
            if (closed.Count > 0) OpenFiles(closed);
            if (UpdateCheck.InstallMessage(outcome) is { } message) Prompt.Info(this, "Update not installed", message);
            else ShowUpdateNotice(UpdateCheckResult.UpToDate);
        }
        finally
        {
            _updateInstalling = false;
        }
    }

    /// <summary>Dev script: <c>updatefake none|ready|mandatory|error</c> answers as the Store would, as if packaged.</summary>
    internal void DevFakeStoreUpdates(IStoreUpdates fake)
    {
        _storeUpdates = fake;
        _packagedForUpdates = true;
    }

    internal Task DevCheckForUpdatesAsync(bool user) => CheckForUpdatesAsync(user ? UpdateCheckTrigger.User : UpdateCheckTrigger.Startup);

    internal string DevUpdateState() =>
        $"update: {_updateResult}, button {(UpdateButton.Visibility == Visibility.Visible ? $"'{UpdateText.Text}' ({UpdateButton.ToolTip})" : "hidden")}";
}
