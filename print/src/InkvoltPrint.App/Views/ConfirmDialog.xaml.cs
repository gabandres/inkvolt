using System.Windows;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.Views;

/// <summary>
/// Yes/no question whose buttons say what will happen ("Discard", "Remove"), with Cancel as the safe default. The
/// question is the heading and the window's title (what Alt+Tab and a screen reader say), the rest the explanation
/// (<see cref="DialogText.Split"/>).
/// </summary>
public partial class ConfirmDialog : Window
{
    private ConfirmDialog() => InitializeComponent();

    public static bool Ask(Window? owner, string message, string confirmText)
    {
        var dlg = Create(owner, message);
        dlg.Confirm.Content = confirmText;
        return dlg.ShowDialog() == true;
    }

    /// <summary>Information-only variant: a single Close button (nothing to confirm, so not "OK").</summary>
    public static void Tell(Window? owner, string message)
    {
        var dlg = Create(owner, message);
        dlg.Confirm.Content = "Close";
        dlg.Confirm.IsDefault = true;
        dlg.Cancel.IsDefault = false;
        dlg.Cancel.Visibility = Visibility.Collapsed; // Esc still closes it (IsCancel)
        dlg.ShowDialog();
    }

    /// <summary>For the dev snapshot (<c>--dialog confirm</c>): a sample question, shown without blocking.</summary>
    internal static ConfirmDialog Preview(Window? owner)
    {
        var dlg = Create(owner, "Remove Demo inkjet from Inkvolt Print?\n\nThis doesn't remove it from Windows. It comes back if it's found on the network again.");
        dlg.Confirm.Content = "Remove";
        return dlg;
    }

    private static ConfirmDialog Create(Window? owner, string message)
    {
        var dlg = new ConfirmDialog { Owner = owner is { IsLoaded: true } ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var (heading, body) = DialogText.Split(message);
        dlg.Title = heading.Length > 0 ? heading : "Inkvolt Print";
        dlg.Heading.Text = heading;
        dlg.Message.Text = body ?? "";
        dlg.Message.Visibility = body is null ? Visibility.Collapsed : Visibility.Visible;
        return dlg;
    }

    private void Confirm_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
