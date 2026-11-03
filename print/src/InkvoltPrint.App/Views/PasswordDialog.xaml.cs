using System.Windows;

namespace InkvoltPrint.App.Views;

public partial class PasswordDialog : Window
{
    private PasswordDialog() => InitializeComponent();

    /// <summary>The printer's web-page (EWS) admin password, needed to change settings.</summary>
    public static (string Password, bool Remember)? AskAdmin(Window? owner, string printer, bool rejected, string? fingerprint)
    {
        // Trust on first use: the first encrypted connection decides which certificate this PC accepts from now on.
        var cert = fingerprint is { Length: >= 16 }
            ? " " + string.Format(Strings.Password_CertRemembered, Format(fingerprint))
            : "";
        var dlg = Create(owner, Strings.Password_PrinterTitle, string.Format(Strings.Password_AdminHeading, printer),
            Strings.Password_AdminPrompt + cert,
            rejected, showRemember: true);
        return dlg.ShowDialog() == true ? (dlg.Password.Password, dlg.Remember.IsChecked == true) : null;
    }

    /// <summary>Password to open a protected PDF. Never stored.</summary>
    public static string? AskPdf(Window? owner, string fileName, bool wrong)
    {
        var dlg = Create(owner, Strings.Password_PdfTitle, string.Format(Strings.Password_PdfHeading, fileName),
            Strings.Password_PdfPrompt, wrong, showRemember: false);
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

    private static string Format(string hex) => string.Join(" ", Enumerable.Range(0, 4).Select(i => hex.Substring(i * 4, 4))) + " …";

    private void Password_Changed(object sender, RoutedEventArgs e) => Ok.IsEnabled = Password.Password.Length > 0;

    private void Ok_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
