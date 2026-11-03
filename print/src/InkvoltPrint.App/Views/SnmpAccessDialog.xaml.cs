using System.Windows;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.App.Views;

/// <summary>The printer's menu › SNMP access…: the community a printer read over SNMP is asked with.</summary>
public partial class SnmpAccessDialog : Window
{
    private SnmpLogin? _chosen;

    private SnmpAccessDialog() => InitializeComponent();

    /// <summary>The login to keep for <paramref name="printer"/>; null when cancelled.</summary>
    public static SnmpLogin? Ask(Window? owner, string printer, SnmpLogin current)
    {
        var dlg = Create(printer, current);
        dlg.Owner = owner is { IsLoaded: true } ? owner : null;
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        return dlg.ShowDialog() == true ? dlg._chosen : null;
    }

    /// <summary>The dialog, not shown yet (dev snapshots: <c>--dialog snmp</c>).</summary>
    public static SnmpAccessDialog Create(string printer, SnmpLogin current)
    {
        var dlg = new SnmpAccessDialog();
        dlg.Heading.Text = $"SNMP access for {printer}";
        dlg.CommunityBox.Text = current.IsDefault ? "" : current.Community;
        dlg.Loaded += (_, _) =>
        {
            dlg.CommunityBox.Focus();
            dlg.CommunityBox.SelectAll();
        };
        return dlg;
    }

    private void Community_Changed(object sender, System.Windows.Controls.TextChangedEventArgs e) => Error.Visibility = Visibility.Collapsed;

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        _chosen = SnmpLogin.ForCommunity(CommunityBox.Text, out var error);
        if (_chosen is null)
        {
            Error.Text = error;
            Error.Visibility = Visibility.Visible;
            return;
        }
        DialogResult = true;
    }
}
