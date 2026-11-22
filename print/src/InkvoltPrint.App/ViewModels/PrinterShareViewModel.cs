using CommunityToolkit.Mvvm.ComponentModel;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Sharing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Print tab's "Share with phones" card for an entry's Windows queue (roadmap 4.10, free). What it shows and when is
/// <see cref="PrinterShare.Card"/>; this only shows it, on the dispatcher, and passes the switch on.
/// </summary>
public sealed partial class PrinterShareViewModel : ObservableObject, IDisposable
{
    private readonly PrinterShare _share;
    private readonly Func<SpoolerQueue?> _queue;
    private readonly Action<string> _log;

    /// <param name="queue">The Windows queue the entry is known by, or null (a network printer, which phones reach themselves).</param>
    public PrinterShareViewModel(PrinterShare share, Func<SpoolerQueue?> queue, Action<string> log)
    {
        _share = share;
        _queue = queue;
        _log = log;
        share.Changed += OnChanged;
    }

    private void OnChanged() => UiThread.Run(Refresh);

    public void Dispose() => _share.Changed -= OnChanged;

    private PrinterShareCard Card => _share.Card(_queue());

    public bool IsShown => Card.IsShown;

    public string Text => Card.Text;

    public bool IsOn
    {
        get => Card.IsOn;
        set
        {
            if (value == IsOn) return;
            _ = SwitchAsync(value);
        }
    }

    private async Task SwitchAsync(bool on)
    {
        try
        {
            if (_queue() is not { } queue) return;
            if (!on) await _share.TurnOffAsync(queue.Name);
            else await _share.TurnOnAsync(queue);
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            _log($"Printer sharing not switched: {ex.Message}");
        }
        Refresh();
    }

    public void Refresh()
    {
        OnPropertyChanged(nameof(IsShown));
        OnPropertyChanged(nameof(Text));
        OnPropertyChanged(nameof(IsOn));
    }
}
