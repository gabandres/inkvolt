using System.Windows.Media;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Capture;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Scan tab's phone panel while a phone scan is open (roadmap 4.6): the QR code of the page's address, the address itself, the
/// certificate's fingerprint and the line about the phone (<see cref="PhoneScan.StatusText"/>). Done ends the session as the phone's
/// Done does. What is served and to whom is <see cref="PhoneSession"/>'s; this only shows it, on the dispatcher.
/// </summary>
public sealed partial class PhoneScanViewModel : ObservableObject, IDisposable
{
    private readonly PhoneLink _link;

    public PhoneScanViewModel(PhoneLink link)
    {
        _link = link;
        Qr = QrImage(link.Qr());
        link.Session.Changed += OnChanged;
    }

    private void OnChanged() => UiThread.Run(() =>
    {
        OnPropertyChanged(nameof(Status));
        FinishCommand.NotifyCanExecuteChanged();
    });

    public void Dispose() => _link.Session.Changed -= OnChanged;

    /// <summary>The QR code, a pixel per module with its quiet zone (shown scaled up without smoothing).</summary>
    public BitmapSource Qr { get; }

    public string Url => _link.Url;

    /// <summary>The first eight bytes of the certificate's fingerprint, as a browser's certificate view shows them.</summary>
    public string Fingerprint => string.Format(Strings.Phone_Fingerprint, _link.Fingerprint.Length > 23 ? _link.Fingerprint[..23] : _link.Fingerprint);

    public string Status => PhoneScan.StatusText(_link.Session.State, _link.Session.Received);

    private bool CanFinish() => _link.Session.State != PhoneState.Finished;

    [RelayCommand(CanExecute = nameof(CanFinish))]
    private void Finish() => _link.Session.Finish();

    private static BitmapSource QrImage(bool[,] modules)
    {
        const int quiet = 4;
        var (rows, cols) = (modules.GetLength(0), modules.GetLength(1));
        var (w, h) = (cols + 2 * quiet, rows + 2 * quiet);
        var pixels = new byte[w * h];
        Array.Fill(pixels, (byte)255);
        for (var y = 0; y < rows; y++)
            for (var x = 0; x < cols; x++)
                if (modules[y, x]) pixels[(y + quiet) * w + x + quiet] = 0;
        var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Gray8, null, pixels, w);
        bmp.Freeze();
        return bmp;
    }
}
