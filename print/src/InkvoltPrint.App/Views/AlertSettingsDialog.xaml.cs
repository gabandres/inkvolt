using System.Windows;
using InkvoltPrint.App.Tray;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>"Notification area and alerts" (sidebar link, the tray icon's menu). Changes apply right away; Close (Esc) closes.</summary>
public partial class AlertSettingsDialog : Window
{
    private static AlertSettingsDialog? _open;

    private AlertSettingsDialog(TrayController tray)
    {
        InitializeComponent();
        DataContext = new AlertSettingsViewModel(tray);
        Loaded += (_, _) => EnabledBox.Focus();
        Closed += (_, _) =>
        {
            ((AlertSettingsViewModel)DataContext).Detach();
            _open = null;
        };
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    public static AlertSettingsDialog Create(TrayController tray) => new(tray);

    /// <summary>Opens it (once: from the hidden app's menu it gets its own taskbar-less window, centered on screen).</summary>
    public static void Open(Window? owner, TrayController tray)
    {
        if (_open is { } shown)
        {
            shown.Activate();
            return;
        }
        var dlg = _open = Create(tray);
        dlg.Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null;
        if (dlg.Owner is null)
        {
            dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            dlg.ShowInTaskbar = true; // no owner on screen: keep it findable
            dlg.Show();
            dlg.Activate();
            return;
        }
        dlg.ShowDialog();
    }
}
