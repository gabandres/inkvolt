using System.Windows;

namespace PrintDesk.App.Views;

/// <summary>Yes/no question whose buttons say what will happen ("Discard", "Remove"), with Cancel as the safe default.</summary>
public partial class ConfirmDialog : Window
{
    private ConfirmDialog() => InitializeComponent();

    public static bool Ask(Window? owner, string message, string confirmText)
    {
        var dlg = new ConfirmDialog { Owner = owner is { IsLoaded: true } ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.Message.Text = message;
        dlg.Confirm.Content = confirmText;
        return dlg.ShowDialog() == true;
    }

    private void Confirm_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
