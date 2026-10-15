using System.Windows;

namespace PrintDesk.App.Views;

public partial class PasswordDialog : Window
{
    private PasswordDialog() => InitializeComponent();

    /// <summary>The printer's web-page (EWS) admin password, needed to change settings.</summary>
    public static (string Password, bool Remember)? AskAdmin(Window? owner, string printer, bool rejected)
    {
        var dlg = Create(owner, "Printer password", $"Enter the admin password for {printer}",
            "It's the password for the printer's web page (user name \"admin\"). It's only sent to the printer, over an encrypted connection.",
            rejected, showRemember: true);
        return dlg.ShowDialog() == true ? (dlg.Password.Password, dlg.Remember.IsChecked == true) : null;
    }

    /// <summary>Password to open a protected PDF. Never stored.</summary>
    public static string? AskPdf(Window? owner, string fileName, bool wrong)
    {
        var dlg = Create(owner, "Protected PDF", $"\"{fileName}\" is password protected",
            "Enter the password to open it for printing.", wrong, showRemember: false);
        return dlg.ShowDialog() == true ? dlg.Password.Password : null;
    }

    private static PasswordDialog Create(Window? owner, string title, string heading, string prompt, bool rejected, bool showRemember)
    {
        var dlg = new PasswordDialog { Owner = owner is { IsLoaded: true } ? owner : null, Title = title };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.Heading.Text = heading;
        dlg.Prompt.Text = prompt;
        dlg.Rejected.Visibility = rejected ? Visibility.Visible : Visibility.Collapsed;
        dlg.Remember.Visibility = showRemember ? Visibility.Visible : Visibility.Collapsed;
        dlg.Loaded += (_, _) => dlg.Password.Focus();
        return dlg;
    }

    private void Password_Changed(object sender, RoutedEventArgs e) => Ok.IsEnabled = Password.Password.Length > 0;

    private void Ok_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
