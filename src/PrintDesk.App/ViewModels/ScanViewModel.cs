using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using PrintDesk.Core.Escl;
using PrintDesk.Core.Net;
using PrintDesk.Core.Pdf;
using PrintDesk.Windows.Ocr;

namespace PrintDesk.App.ViewModels;

public sealed record Option<T>(T Value, string Label)
{
    public override string ToString() => Label;
}

/// <summary>
/// Scan straight from the device over eSCL. Each page lands as a JPEG (no re-encode), OCR runs in the
/// background while the next page scans, and Save assembles a searchable PDF locally.
/// </summary>
public sealed partial class ScanViewModel : ObservableObject
{
    private readonly AppState _state;
    private EsclClient _client;
    private CancellationTokenSource? _scanCts;

    public ScanViewModel(EsclClient client, ScannerCapabilities caps, AppState state)
    {
        _client = client;
        _state = state;
        Sources = caps.Sources.Select(s => new Option<ScanSource>(s, s switch
        {
            ScanSource.Platen => "Scanner glass",
            ScanSource.Adf => "Document feeder",
            _ => "Document feeder (both sides)",
        })).ToList();
        Source = Sources.FirstOrDefault();
        Resolutions = (caps.Platen ?? caps.Adf)!.Resolutions.Select(r => new Option<int>(r, r switch
        {
            <= 150 => $"{r} dpi (draft)",
            <= 200 => $"{r} dpi (screen)",
            <= 300 => $"{r} dpi (documents)",
            _ => $"{r} dpi (photos, slower)",
        })).ToList();
        Resolution = Resolutions.MinBy(r => Math.Abs(r.Value - state.ScanResolution));
        IsColor = state.ScanColor;
        UseOcr = state.ScanOcr && OcrAvailable;
        Pages.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasPages));
            OnPropertyChanged(nameof(PageCountText));
            SaveCommand.NotifyCanExecuteChanged();
        };
    }

    public IReadOnlyList<Option<ScanSource>> Sources { get; }
    public IReadOnlyList<Option<int>> Resolutions { get; }
    public bool HasSourceChoice => Sources.Count > 1;
    public bool OcrAvailable { get; } = WindowsOcr.IsAvailable;

    public ObservableCollection<ScanPageViewModel> Pages { get; } = [];

    [ObservableProperty] public partial Option<ScanSource>? Source { get; set; }
    [ObservableProperty] public partial Option<int>? Resolution { get; set; }
    [ObservableProperty] public partial bool IsColor { get; set; }
    [ObservableProperty] public partial bool UseOcr { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ScanCommand), nameof(SaveCommand), nameof(ClearCommand))]
    public partial bool IsBusy { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial string? LastSavedPath { get; set; }

    public bool HasPages => Pages.Count > 0;
    public string PageCountText => Pages.Count switch { 0 => "No pages yet", 1 => "1 page", var n => $"{n} pages" };

    /// <summary>True only while pages are coming off the scanner (not while saving).</summary>
    [ObservableProperty] public partial bool IsScanning { get; set; }

    partial void OnIsColorChanged(bool value) { _state.ScanColor = value; _state.Save(); }
    partial void OnUseOcrChanged(bool value) { _state.ScanOcr = value; _state.Save(); }
    partial void OnResolutionChanged(Option<int>? value)
    {
        if (value is null) return;
        _state.ScanResolution = value.Value;
        _state.Save();
    }

    public void Rebind(EsclClient client) => _client = client;

    private bool NotBusy() => !IsBusy;
    private bool CanSave(string? format) => !IsBusy && Pages.Count > 0;

    /// <summary>Scans and appends pages, so multi-page documents from the glass are just "Scan" again.</summary>
    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task ScanAsync()
    {
        IsBusy = true;
        IsScanning = true;
        LastSavedPath = null;
        _scanCts = new CancellationTokenSource();
        var dpi = Resolution?.Value ?? 300;
        var request = new ScanRequest(Source?.Value ?? ScanSource.Platen, IsColor ? ScanColor.Color : ScanColor.Grayscale, dpi);
        var sw = Stopwatch.StartNew();
        var added = 0;
        try
        {
            Message = "Scanning…";
            await foreach (var jpeg in _client.ScanAsync(request, _scanCts.Token))
            {
                var page = new ScanPageViewModel(jpeg, dpi, UseOcr);
                Pages.Add(page);
                added++;
                Message = $"Scanned page {Pages.Count}. Scanning…";
            }
            Message = added == 0
                ? "The scanner returned no pages."
                : request.Source == ScanSource.Platen
                    ? "Done. To add another page, put it on the glass and press Scan again."
                    : $"Done: {added} page{(added == 1 ? "" : "s")} from the feeder.";
        }
        catch (OperationCanceledException)
        {
            Message = "Scan cancelled.";
        }
        catch (ScanException ex)
        {
            Message = ex.Message;
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException or DeviceHttpException)
        {
            Message = $"Scan failed: {ex.Message}";
        }
        finally
        {
            _scanCts.Dispose();
            _scanCts = null;
            IsBusy = false;
            IsScanning = false;
        }
    }

    [RelayCommand]
    private void Cancel() => _scanCts?.Cancel();

    [RelayCommand]
    private void RemovePage(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        Pages.Remove(page);
    }

    [RelayCommand]
    private void MovePageUp(ScanPageViewModel? page)
    {
        var i = page is null ? -1 : Pages.IndexOf(page);
        if (i > 0) Pages.Move(i, i - 1);
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void Clear()
    {
        Pages.Clear();
        Message = null;
        LastSavedPath = null;
    }

    /// <param name="format">"pdf" (default) or "jpg".</param>
    [RelayCommand(CanExecute = nameof(CanSave))]
    private async Task SaveAsync(string? format)
    {
        var jpg = format == "jpg";
        var folder = _state.ScanFolder is { } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var dialog = new SaveFileDialog
        {
            Title = jpg ? "Save scan as images" : "Save scan as PDF",
            InitialDirectory = folder,
            FileName = $"Scan {DateTime.Now:yyyy-MM-dd HHmm}",
            Filter = jpg ? "JPEG image (*.jpg)|*.jpg" : "PDF document (*.pdf)|*.pdf",
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        _state.ScanFolder = Path.GetDirectoryName(dialog.FileName);
        _state.Save();

        IsBusy = true;
        try
        {
            if (dialog.FileName.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase))
            {
                LastSavedPath = await SaveJpegsAsync(dialog.FileName);
            }
            else
            {
                if (Pages.Any(p => !p.Ocr.IsCompleted)) Message = "Finishing text recognition…";
                var pages = new List<PdfPage>();
                foreach (var p in Pages) pages.Add(new PdfPage(p.Jpeg, p.Dpi, await p.Ocr));
                var title = Path.GetFileNameWithoutExtension(dialog.FileName);
                await Task.Run(() =>
                {
                    using var fs = File.Create(dialog.FileName);
                    PdfWriter.Write(fs, pages, title);
                });
                LastSavedPath = dialog.FileName;
            }
            Message = $"Saved {Path.GetFileName(LastSavedPath)}.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Message = $"Could not save: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task<string> SaveJpegsAsync(string path)
    {
        if (Pages.Count == 1)
        {
            await File.WriteAllBytesAsync(path, Pages[0].Jpeg);
            return path;
        }
        var dir = Path.GetDirectoryName(path)!;
        var stem = Path.GetFileNameWithoutExtension(path);
        for (var i = 0; i < Pages.Count; i++)
            await File.WriteAllBytesAsync(Path.Combine(dir, $"{stem} ({i + 1}).jpg"), Pages[i].Jpeg);
        return Path.Combine(dir, $"{stem} (1).jpg");
    }

    [RelayCommand]
    private void OpenSaved()
    {
        if (LastSavedPath is not null) Process.Start(new ProcessStartInfo(LastSavedPath) { UseShellExecute = true });
    }

    [RelayCommand]
    private void ShowSavedInFolder()
    {
        if (LastSavedPath is not null) Process.Start("explorer.exe", $"/select,\"{LastSavedPath}\"");
    }
}

public sealed class ScanPageViewModel
{
    public ScanPageViewModel(byte[] jpeg, int dpi, bool ocr)
    {
        Jpeg = jpeg;
        Dpi = dpi;
        Thumbnail = Decode(jpeg, 360);
        Ocr = ocr ? RunOcrAsync(jpeg, dpi) : Task.FromResult<IReadOnlyList<OcrWord>?>(null);
    }

    public byte[] Jpeg { get; }
    public int Dpi { get; }
    public BitmapSource Thumbnail { get; }
    public Task<IReadOnlyList<OcrWord>?> Ocr { get; }
    public string SizeText => $"{Jpeg.Length / 1024:N0} KB";

    private static async Task<IReadOnlyList<OcrWord>?> RunOcrAsync(byte[] jpeg, int dpi)
    {
        try { return await Task.Run(() => WindowsOcr.RecognizeAsync(jpeg, dpi)); }
        catch (Exception ex)
        {
            Trace.WriteLine($"OCR failed: {ex.Message}");
            return null; // page still saves, just without a text layer
        }
    }

    private static BitmapSource Decode(byte[] jpeg, int width)
    {
        var img = new BitmapImage();
        img.BeginInit();
        img.CacheOption = BitmapCacheOption.OnLoad;
        img.DecodePixelWidth = width;
        img.StreamSource = new MemoryStream(jpeg);
        img.EndInit();
        img.Freeze();
        return img;
    }
}
