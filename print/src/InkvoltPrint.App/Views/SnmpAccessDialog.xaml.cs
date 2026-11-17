using System.Windows;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.App.Views;

/// <summary>
/// The printer's menu › SNMP access…: the community or SNMPv3 user a printer read over SNMP is asked with. Save asks the printer
/// with it first (<see cref="SnmpLoginSave"/>): kept once it answers as itself; a refusal says which part and keeps nothing;
/// another device keeps nothing; no answer (it may be off, or ignore a wrong community) turns Save into Save anyway. What it asks
/// and what came of it are announced to screen readers (<see cref="Prompt.Announce"/>).
/// </summary>
public partial class SnmpAccessDialog : Window
{
    private SnmpLogin? _chosen;
    private SnmpLoginSave? _save;
    private readonly CancellationTokenSource _closed = new();

    private SnmpAccessDialog()
    {
        InitializeComponent();
        Fields.Edited += () =>
        {
            Problem.Visibility = Visibility.Collapsed;
            Ok.Content = Strings.Common_Save;
            _save?.Edited(); // the same login typed back is asked again, never kept unasked
        };
        Closed += (_, _) =>
        {
            _closed.Cancel(); // closed while asking: the answer is dropped
            _closed.Dispose();
        };
    }

    /// <summary>The login to keep for <paramref name="printer"/> (checked with the printer through <paramref name="save"/>); null when cancelled.</summary>
    public static SnmpLogin? Ask(Window? owner, string printer, SnmpLoginSave save, SnmpLogin current)
    {
        var dlg = Create(printer, current, save);
        dlg.Owner = owner is { IsLoaded: true } ? owner : null;
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        return dlg.ShowDialog() == true ? dlg._chosen : null;
    }

    /// <summary>
    /// The dialog, not shown yet (dev snapshots: <c>--dialog snmp</c>, <c>snmp3</c>, and <c>snmp-noanswer</c>, <c>snmp-refused</c>,
    /// <c>snmp-other</c> with Save pressed against a made-up answer). Without <paramref name="save"/>, Save keeps what's typed unasked.
    /// </summary>
    public static SnmpAccessDialog Create(string printer, SnmpLogin current, SnmpLoginSave? save = null)
    {
        var dlg = new SnmpAccessDialog();
        dlg.Heading.Text = string.Format(Strings.Snmp_Heading, printer);
        dlg.Fields.Show(current);
        dlg._save = save; // after Show: filling the fields isn't an edit
        dlg.Loaded += (_, _) => dlg.Fields.FocusFirst();
        return dlg;
    }

    /// <summary>Presses Save (dev snapshots).</summary>
    internal Task DevSaveAsync() => SaveAsync();

    private async void Ok_Click(object sender, RoutedEventArgs e) => await SaveAsync();

    private async Task SaveAsync()
    {
        if (Fields.Read() is not { } login) return;
        if (_save is null)
        {
            Keep(login);
            return;
        }
        var closed = _closed.Token;
        Problem.Visibility = Visibility.Collapsed;
        Asking.Visibility = Visibility.Visible;
        Prompt.Announce(Strings.Snmp_Asking);
        Ok.IsEnabled = Fields.IsEnabled = false; // nothing edited while it's asked
        (bool Keep, string? Problem) outcome;
        try
        {
            outcome = await _save.SaveAsync(login, closed);
        }
        catch (OperationCanceledException)
        {
            return; // closed meanwhile
        }
        finally
        {
            Asking.Visibility = Visibility.Collapsed;
            Ok.IsEnabled = Fields.IsEnabled = true;
        }
        if (closed.IsCancellationRequested) return; // answered just as it was closed: nothing kept
        if (outcome.Keep)
        {
            Keep(login);
            return;
        }
        Problem.Text = outcome.Problem;
        Problem.Visibility = Visibility.Visible;
        Ok.Content = _save.IsSaveAnyway(login) ? Strings.Snmp_SaveAnyway : Strings.Common_Save;
        Ok.Focus(); // the keyboard was on Save (or a field) before it was disabled: back on Save (anyway)
        if (outcome.Problem is { } problem) Prompt.Announce(problem);
    }

    private void Keep(SnmpLogin login)
    {
        _chosen = login;
        DialogResult = true;
    }
}
