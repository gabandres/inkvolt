using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPrint.App.Tray;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPrint.App.Views;

/// <summary>
/// Inkvolt Print's own settings (a printer's are on its Printer settings tab): theme, where scans are saved, opening them in
/// Inkvolt PDF, scan presets, and the notification area and alerts. Changes apply as they're made; Close (Esc) closes.
/// The Scan tab keeps the choices made per scan (resolution, OCR, blank pages…).
/// </summary>
public partial class SettingsWindow : Window
{
    private static SettingsWindow? _open;

    private readonly MainViewModel _vm;
    private readonly TrayController? _tray;
    private bool _ready;

    private SettingsWindow(MainViewModel vm, TrayController? tray)
    {
        InitializeComponent();
        (_vm, _tray) = (vm, tray);
        MaxHeight = SystemParameters.WorkArea.Height * 0.9;
        OpenInPdfBox.Visibility = InkvoltApps.Find(InkvoltApps.InkvoltPdf) is not null ? Visibility.Visible : Visibility.Collapsed;
        AlertsSection.Visibility = tray is null ? Visibility.Collapsed : Visibility.Visible; // the --try window and dev runs have no tray
        Show(vm.State);
        Closed += (_, _) =>
        {
            (Alerts.DataContext as AlertSettingsViewModel)?.Detach();
            _open = null;
        };
    }

    /// <summary>Puts the current values in the controls.</summary>
    private void Show(AppState state)
    {
        _ready = false;
        foreach (var choice in ThemeChoices.Children.OfType<RadioButton>())
            choice.IsChecked = (string)choice.Tag == WindowFrame.Theme;
        FolderText.Text = ScanFolder(state);
        OpenInPdfBox.IsChecked = state.OpenScansInInkvoltPdf;
        (Alerts.DataContext as AlertSettingsViewModel)?.Detach();
        Alerts.DataContext = _tray is null ? null : new AlertSettingsViewModel(_tray);
        _ready = true;
    }

    private static string ScanFolder(AppState state) =>
        state.ScanFolder is { } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    /// <param name="alerts">Opened from the tray icon's "Alert settings…": scrolled to that part.</param>
    public static void Open(Window? owner, MainViewModel vm, TrayController? tray, bool alerts = false)
    {
        if (_open is { } shown)
        {
            shown.Activate();
            if (alerts) shown.ShowAlerts();
            return;
        }
        var dlg = _open = Create(vm, tray);
        if (alerts) dlg.Loaded += (_, _) => dlg.ShowAlerts();
        dlg.Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null;
        if (dlg.Owner is null)
        {
            dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            dlg.ShowInTaskbar = true; // no owner on screen (the window is in the notification area): keep it findable
            dlg.Show();
            dlg.Activate();
            return;
        }
        dlg.ShowDialog();
    }

    public static SettingsWindow Create(MainViewModel vm, TrayController? tray) => new(vm, tray);

    public void ShowAlerts()
    {
        if (AlertsSection.Visibility != Visibility.Visible) return;
        AlertsSection.BringIntoView();
        Alerts.FocusFirst();
    }

    private void Theme_Checked(object sender, RoutedEventArgs e)
    {
        if (!_ready || sender is not RadioButton { Tag: string theme }) return;
        WindowFrame.ApplyTheme(theme);
        _vm.State.Theme = theme == "System" ? null : theme;
        _vm.State.Save();
    }

    private void ChangeFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Save scans to", InitialDirectory = FolderText.Text };
        if (dialog.ShowDialog(this) != true) return;
        _vm.State.ScanFolder = FolderText.Text = dialog.FolderName;
        _vm.State.Save();
    }

    private void OpenInPdf_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _vm.State.OpenScansInInkvoltPdf = OpenInPdfBox.IsChecked == true;
        _vm.State.Save();
    }

    private void Presets_Click(object sender, RoutedEventArgs e) =>
        ScanPresetsDialog.Open(this, _vm.Presets, _vm.Selected?.Name ?? "this printer");

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        if (!ConfirmDialog.Ask(this, "Put the theme, the scan folder, Inkvolt PDF and the notification area and alerts back to how they start? "
                                     + "Your printers, presets and scans are kept.", "Reset")) return;
        _vm.State.ResetPreferences();
        WindowFrame.ApplyTheme(null);
        if (_tray is not null)
        {
            if (StartWithWindows.Unavailable(_tray.IsDemo) is null && StartWithWindows.IsOn) StartWithWindows.Set(false);
            _tray.Apply();
        }
        Log.Write("Settings reset to defaults");
        Show(_vm.State);
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
