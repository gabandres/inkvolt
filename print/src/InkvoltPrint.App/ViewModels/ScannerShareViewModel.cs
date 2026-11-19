using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Sharing;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Scan tab's "Share on the network" card for an entry's Windows scanner (roadmap 3.1, Inkvolt Pro): its switch, what
/// <see cref="ScannerShare"/> says and, while shared, the certificate's fingerprint. Shown for a WIA or TWAIN scanner, not for a
/// network scanner Windows reaches over eSCL itself. What it decides lives in Core; this only shows it, on the dispatcher.
/// </summary>
public sealed partial class ScannerShareViewModel : ObservableObject, IDisposable
{
    private readonly ScannerShare _share;
    private readonly Func<WiaScanner?> _scanner;
    private readonly WiaDeviceInfo? _listed;
    private readonly Action<string> _log;

    /// <param name="scanner">The entry's connected Windows scanner, or null.</param>
    /// <param name="listed">The scanner of an entry that is a scanner on its own (known before it connects).</param>
    public ScannerShareViewModel(ScannerShare share, Func<WiaScanner?> scanner, WiaDeviceInfo? listed, Action<string> log)
    {
        _share = share;
        _scanner = scanner;
        _listed = listed;
        _log = log;
        share.Changed += OnChanged;
    }

    private void OnChanged() => Ui(Refresh);

    public void Dispose() => _share.Changed -= OnChanged;

    /// <summary>
    /// The Windows scanner this card is about: the connected one, or the listed one while it's the shared one (waiting for it); never
    /// Windows' own eSCL driver's (that scanner is on the network already).
    /// </summary>
    private WiaDeviceInfo? Device => (_scanner()?.Device ?? (_listed is { } l && _share.IsShared(l.Id) ? l : null)) is { IsEscl: false } d ? d : null;

    public bool IsShown => Device is not null;

    public string Text => Device is { } d ? _share.Text(d.Id) : "";

    public bool IsOn
    {
        get => Device is { } d && _share.IsShared(d.Id);
        set
        {
            if (value == IsOn) return;
            _ = SwitchAsync(value);
        }
    }

    /// <summary>The certificate's fingerprint while this scanner is shared and listening, 16 bytes a line; null otherwise.</summary>
    public string? Fingerprint => IsOn && _share.State == ShareState.On && _share.Fingerprint is { } f
        ? f.Length > 48 ? f[..48] + "\n" + f[48..] : f
        : null;

    public bool HasFingerprint => Fingerprint is not null;

    private async Task SwitchAsync(bool on)
    {
        try
        {
            if (!on) await _share.StopAsync();
            else if (!Pro.Allows(ProFeature.ScannerSharing)) Views.ProWindow.Open(Application.Current?.MainWindow, ProFeature.ScannerSharing);
            else if (_scanner() is { Device.IsEscl: false } scanner) await _share.ShareAsync(scanner);
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

    private static void Ui(Action action)
    {
        if (Application.Current?.Dispatcher is not { } ui) return;
        if (ui.CheckAccess()) action();
        else ui.InvokeAsync(action);
    }
}
