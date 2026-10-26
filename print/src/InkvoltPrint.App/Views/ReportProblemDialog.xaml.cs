using System.Runtime.InteropServices;
using System.Windows;

namespace InkvoltPrint.App.Views;

/// <summary>Report a problem (Help): shows the scrubbed details first, then copies them; GitHub opens for the user to paste and send.</summary>
public partial class ReportProblemDialog : Window
{
    private ReportProblemDialog(string details)
    {
        InitializeComponent();
        Details.Text = details;
    }

    public static ReportProblemDialog Create(string details) => new(details);

    public static void Open(Window owner, string details)
    {
        var dlg = new ReportProblemDialog(details) { Owner = owner.IsLoaded ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private bool Copy()
    {
        try
        {
            Clipboard.SetText(Details.Text);
            Say("Copied.");
            return true;
        }
        catch (COMException ex) // another app holds the clipboard
        {
            Log.Write($"Diagnostics not copied: {ex.Message}");
            Say("The clipboard is busy; try again, or select the text and press Ctrl+C.");
            return false;
        }
    }

    private void Say(string text)
    {
        Status.Text = text;
        Status.Visibility = Visibility.Visible;
    }

    private void Copy_Click(object sender, RoutedEventArgs e) => Copy();

    private void CopyAndIssue_Click(object sender, RoutedEventArgs e)
    {
        if (!Copy()) return;
        Shell.Open(AppHelp.IssueUrl());
        Say("Copied. Paste the details into the issue under Details, then submit it.");
    }
}
