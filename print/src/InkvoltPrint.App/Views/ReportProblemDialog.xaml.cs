using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Recording;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.Views;

/// <summary>
/// Report a problem (Help): shows the scrubbed details first, then copies them; GitHub opens for the user to paste and send. It can also
/// record the printer shown (<see cref="ReportRecording"/>, as <c>inkvoltprint record</c>): a .zip the user reads and attaches by hand. Nothing is sent.
/// </summary>
public partial class ReportProblemDialog : Window
{
    private readonly PrinterViewModel? _printer;
    private readonly CancellationTokenSource _closing = new();
    private string? _recording;

    private ReportProblemDialog(string details, PrinterViewModel? printer)
    {
        InitializeComponent();
        Details.Text = details;
        _printer = printer;
        Closed += (_, _) => _closing.Cancel(); // a recording under way stops, and leaves nothing behind
        RecordButton.IsEnabled = printer?.RecordHost is not null;
        RecordNote.Text = printer is null ? "To record a printer, show it first and come back here."
            : printer.RecordHost is null ? $"{printer.Name} has no network address, so there's nothing to record."
            : $"Also useful: record {printer.Name}. Every reply Inkvolt Print reads from it, read only, with serial numbers, addresses and names taken out, saved as a .zip file for you to read and attach. It can take a minute or two.";
    }

    public static ReportProblemDialog Create(string details, PrinterViewModel? printer) => new(details, printer);

    public static void Open(Window owner, string details, PrinterViewModel? printer)
    {
        var dlg = new ReportProblemDialog(details, printer) { Owner = owner.IsLoaded ? owner : null };
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

    private async void Record_Click(object sender, RoutedEventArgs e) => await RecordAsync();

    /// <summary>Records the printer shown; the dev aid's <c>--record</c> waits for it. Never throws: what went wrong is said in the dialog.</summary>
    public async Task RecordAsync()
    {
        if (_printer is null) return;
        var ct = _closing.Token;
        var who = Diagnostics.Identity.Current;
        RecordButton.IsEnabled = false;
        ShowRecording.Visibility = Visibility.Collapsed;
        Say($"Recording {_printer.Name}. Close this window to stop.");
        try
        {
            var done = await _printer.RecordForReportAsync(ct);
            if (ct.IsCancellationRequested) return;
            _recording = done.Zip;
            Details.Text = Details.Text.TrimEnd() + Environment.NewLine + Environment.NewLine + ReportRecording.ReportLine(done, who) + Environment.NewLine;
            Say(_printer.OpensOtherApps
                ? $"Saved as {Path.GetFileName(done.Zip)} in {Path.GetDirectoryName(done.Zip)}. Read it before you share it, then attach it to the issue."
                : $"Demo: saved as {Path.GetFileName(done.Zip)} in {Path.GetDirectoryName(done.Zip)}, from the made-up printer.");
            ShowRecording.Visibility = _printer.OpensOtherApps ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { } // closed: nothing left to say it in
        catch (Exception ex)
        {
            Log.Write(ReportRecording.FailureText(ex, who)); // no address, no names: the log's rule
            if (!ct.IsCancellationRequested) Say(ReportRecording.FailureText(ex, who));
        }
        finally
        {
            if (!ct.IsCancellationRequested) RecordButton.IsEnabled = true;
        }
    }

    private void ShowRecording_Click(object sender, RoutedEventArgs e)
    {
        if (_recording is { } zip && Path.GetDirectoryName(zip) is { } folder) Shell.Open(folder);
    }

    private void Copy_Click(object sender, RoutedEventArgs e) => Copy();

    private void CopyAndIssue_Click(object sender, RoutedEventArgs e)
    {
        if (!Copy()) return;
        Shell.Open(AppHelp.IssueUrl());
        Say("Copied. Paste the details into the issue under Details, then submit it.");
    }
}
