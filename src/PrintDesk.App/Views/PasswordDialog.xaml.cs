using System.Windows;

namespace PrintDesk.App.Views;

public partial class PasswordDialog : Window
{
    private PasswordDialog() => InitializeComponent();

    public static (string Password, bool Remember)? Ask(Window? owner, string printer, bool rejected)
    {
        var dlg = new PasswordDialog { Owner = owner };
        dlg.Prompt.Text = $"Changing settings on {printer} needs its admin password (the one for the printer's web page; user name \"admin\").";
        dlg.Rejected.Visibility = rejected ? Visibility.Visible : Visibility.Collapsed;
        dlg.Loaded += (_, _) => dlg.Password.Focus();
        return dlg.ShowDialog() == true ? (dlg.Password.Password, dlg.Remember.IsChecked == true) : null;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        if (Password.Password.Length > 0) DialogResult = true;
    }
}
