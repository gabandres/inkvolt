using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Sharing;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Scan tab's "Share on the network" card for an entry's Windows scanner (roadmap 3.1, Inkvolt Pro). What it shows and when, and
/// the Pro check, are <see cref="ScannerShare.Card"/> and <see cref="ScannerShare.TurnOnAsync"/>; this only shows them, on the
/// dispatcher, and opens the Pro window when asked to.
/// </summary>
public sealed partial class ScannerShareViewModel : ObservableObject, IDisposable
{
    private readonly ScannerShare _share;
    private readonly Func<WiaScanner?> _scanner;
    private readonly Func<WiaDeviceInfo?> _known;
    private readonly Action<string> _log;

    /// <param name="scanner">The entry's connected Windows scanner, or null.</param>
    /// <param name="known">The Windows scanner the entry is known by, connected or not.</param>
    public ScannerShareViewModel(ScannerShare share, Func<WiaScanner?> scanner, Func<WiaDeviceInfo?> known, Action<string> log)
    {
        _share = share;
        _scanner = scanner;
        _known = known;
        _log = log;
        share.Changed += OnChanged;
    }

    private void OnChanged() => UiThread.Run(Refresh);

    public void Dispose() => _share.Changed -= OnChanged;

    private ShareCard Card => _share.Card(_scanner()?.Device, _known());

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

    public string? Fingerprint => Card.Fingerprint;

    public bool HasFingerprint => Fingerprint is not null;

    private async Task SwitchAsync(bool on)
    {
        try
        {
            if (!on) await _share.StopAsync();
            else await _share.TurnOnAsync(_scanner());
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            _log($"Scanner sharing not switched: {ex.Message}");
        }
        Refresh();
    }

    public void Refresh()
    {
        OnPropertyChanged(nameof(IsShown));
        OnPropertyChanged(nameof(Text));
        OnPropertyChanged(nameof(IsOn));
        OnPropertyChanged(nameof(Fingerprint));
        OnPropertyChanged(nameof(HasFingerprint));
    }
}
