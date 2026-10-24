using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows.Ocr;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPrint.App.ViewModels;

public sealed record Option<T>(T Value, string Label)
{
    public override string ToString() => Label;
}

/// <summary>Scan area in 1/300 inch (eSCL units). Null size = the whole glass.</summary>
public sealed record ScanArea(string Key, int? Width, int? Height);

/// <summary>
/// Scan straight from the device over eSCL. Each page lands as a JPEG (no re-encode), OCR runs in the
/// background while the next page scans, and Save assembles a searchable PDF locally.
/// </summary>
public sealed partial class ScanViewModel : ObservableObject
{
    private readonly AppState _state;
    private EsclClient _client;
    private CancellationTokenSource? _scanCts;
    private bool _dirty;
    private readonly ScannerCapabilities _caps;

    private static readonly Option<ScanArea>[] AllPageSizes =
        [.. ScanChoices.PageSizes.Select(p => new Option<ScanArea>(new(p.Key, p.Width, p.Height), p.Label))];

    public ScanViewModel(EsclClient client, ScannerCapabilities caps, AppState state)
    {
        _client = client;
        _state = state;
        _caps = caps;
        Sources = caps.Sources.Select(s => new Option<ScanSource>(s, ScanChoices.SourceLabel(s))).ToList();
        Source = Sources.FirstOrDefault();
        var input = (caps.Platen ?? caps.Adf)!;
        Resolutions = input.Resolutions.Select(r => new Option<int>(r, r switch
        {
            <= 150 => $"{r} dpi (draft)",
            <= 200 => $"{r} dpi (screen)",
            <= 300 => $"{r} dpi (documents)",
            _ => $"{r} dpi (photos, slower)",
        })).ToList();
        Resolution = Resolutions.MinBy(r => Math.Abs(r.Value - state.ScanResolution));

        RefreshPageSizes(state.ScanPageSize ?? (RegionInfo.CurrentRegion.IsMetric ? "a4" : "letter"));

        IsColor = state.ScanColor;
        UseOcr = state.ScanOcr && OcrAvailable;
        OpenInInkvoltPdf = state.OpenScansInInkvoltPdf;
        Pages.CollectionChanged += (_, _) =>
        {
            _dirty = Pages.Count > 0;
            OnPropertyChanged(nameof(HasPages));
            OnPropertyChanged(nameof(PageCountText));
            OnPropertyChanged(nameof(HasUnsavedPages));
            SaveCommand.NotifyCanExecuteChanged();
        };
    }

    public IReadOnlyList<Option<ScanSource>> Sources { get; }
    public IReadOnlyList<Option<int>> Resolutions { get; }
    [ObservableProperty] public partial IReadOnlyList<Option<ScanArea>> PageSizes { get; set; } = [];

    /// <summary>Only sizes the current source can scan (a few pixels of tolerance); keeps the choice when still valid.</summary>
    private void RefreshPageSizes(string? preferredKey)
    {
        if (_caps.For(Source?.Value ?? ScanSource.Platen) is not { } input) return;
        PageSizes = AllPageSizes.Where(o => o.Value.Width is null || (o.Value.Width <= input.MaxWidth + 5 && o.Value.Height <= input.MaxHeight + 5)).ToList();
        _adjustingPageSize = true; // a forced fallback (size not available on this source) isn't the user's choice
        try { PageSize = PageSizes.FirstOrDefault(p => p.Value.Key == preferredKey) ?? PageSizes[0]; }
        finally { _adjustingPageSize = false; }
    }

    private bool _adjustingPageSize;

    partial void OnSourceChanged(Option<ScanSource>? value)
    {
        if (_caps is not null) RefreshPageSizes(_state.ScanPageSize ?? PageSize?.Value.Key);
    }
    public bool HasSourceChoice => Sources.Count > 1;
    public bool OcrAvailable { get; } = WindowsOcr.IsAvailable;

    /// <summary>Inkvolt PDF (the Inkvolt suite's PDF app) is installed: offer to open saved PDFs in it.</summary>
    public bool InkvoltPdfInstalled { get; } = InkvoltApps.Find(InkvoltApps.InkvoltPdf) is not null;

    /// <summary>Open each scan saved as PDF in Inkvolt PDF right away (a setting, remembered).</summary>
    [ObservableProperty] public partial bool OpenInInkvoltPdf { get; set; }

    partial void OnOpenInInkvoltPdfChanged(bool value) { _state.OpenScansInInkvoltPdf = value; _state.Save(); }

    public bool CanOpenSavedInInkvoltPdf => InkvoltPdfInstalled && LastSavedPath?.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) == true;

    partial void OnLastSavedPathChanged(string? value) => OnPropertyChanged(nameof(CanOpenSavedInInkvoltPdf));

    public ObservableCollection<ScanPageViewModel> Pages { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(EmptyHint))]
    public partial Option<ScanSource>? Source { get; set; }

    [ObservableProperty] public partial Option<int>? Resolution { get; set; }
    [ObservableProperty] public partial Option<ScanArea>? PageSize { get; set; }
    [ObservableProperty] public partial bool IsColor { get; set; }
    [ObservableProperty] public partial bool UseOcr { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ScanCommand), nameof(SaveCommand), nameof(ClearCommand))]
    public partial bool IsBusy { get; set; }

    /// <summary>True only while pages are coming off the scanner (not while saving).</summary>
    [ObservableProperty] public partial bool IsScanning { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial string? LastSavedPath { get; set; }

    public bool HasPages => Pages.Count > 0;
    public bool HasUnsavedPages => _dirty && Pages.Count > 0;
    public string PageCountText => Pages.Count switch { 0 => "No pages yet", 1 => "1 page", var n => $"{n} pages" };

    public string EmptyHint => Source?.Value == ScanSource.Platen || Source is null
        ? "Put a page face down on the scanner glass, then press Scan."
        : "Put the pages face up in the document feeder, then press Scan.";

    partial void OnIsColorChanged(bool value) { _state.ScanColor = value; _state.Save(); }
    partial void OnUseOcrChanged(bool value) { _state.ScanOcr = value; _state.Save(); }

    partial void OnResolutionChanged(Option<int>? value)
    {
        if (value is null) return;
        _state.ScanResolution = value.Value;
        _state.Save();
    }

    partial void OnPageSizeChanged(Option<ScanArea>? value)
    {
        if (value is null || _adjustingPageSize) return;
        _state.ScanPageSize = value.Value.Key;
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
        var area = PageSize?.Value;
        var request = new ScanRequest(Source?.Value ?? ScanSource.Platen, IsColor ? ScanColor.Color : ScanColor.Grayscale, dpi,
            Width: area?.Width, Height: area?.Height);
        var added = 0;
        try
        {
            Message = "Scanning… (the first page takes longer if the printer was asleep)";
            await foreach (var jpeg in _client.ScanAsync(request, _scanCts.Token))
            {
                Pages.Add(new ScanPageViewModel(jpeg, dpi, UseOcr));
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
        catch (Exception ex)
        {
            Log.Write($"Scan failed: {ex}");
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
        var i = page is null || IsBusy ? -1 : Pages.IndexOf(page);
        if (i > 0) Pages.Move(i, i - 1);
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void Clear()
    {
        if (HasUnsavedPages && !Prompt.Ask($"Discard {PageCountText.ToLowerInvariant()} you haven't saved?", "Discard")) return;
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

        var targets = jpg ? ImagePaths(dialog.FileName) : [dialog.FileName];
        // The dialog already asked about the name typed; multi-page image saves write numbered siblings it never saw.
        if (jpg && Pages.Count > 1 && targets.Where(File.Exists).ToList() is { Count: > 0 } clobbered &&
            !Prompt.Ask($"{clobbered.Count} file{(clobbered.Count == 1 ? "" : "s")} like \"{Path.GetFileName(clobbered[0])}\" already exist. Replace them?", "Replace"))
            return;

        IsBusy = true;
        try
        {
            if (jpg)
            {
                for (var i = 0; i < Pages.Count; i++) await File.WriteAllBytesAsync(targets[i], Pages[i].Jpeg);
            }
            else
            {
                if (Pages.Any(p => !p.Ocr.IsCompleted)) Message = "Finishing text recognition…";
                var pages = new List<PdfPage>();
                foreach (var p in Pages) pages.Add(new PdfPage(p.Jpeg, p.Dpi, await p.Ocr));
                var title = Path.GetFileNameWithoutExtension(dialog.FileName);
                var target = dialog.FileName;
                await Task.Run(() =>
                {
                    var tmp = target + ".partial";
                    using (var fs = File.Create(tmp)) PdfWriter.Write(fs, pages, title);
                    File.Move(tmp, target, overwrite: true); // never leave a half-written PDF behind
                });
            }
            LastSavedPath = targets[0];
            _dirty = false;
            OnPropertyChanged(nameof(HasUnsavedPages));
            Message = $"Saved {Path.GetFileName(LastSavedPath)}{(jpg && Pages.Count > 1 ? $" and {Pages.Count - 1} more" : "")}.";
            if (!jpg && OpenInInkvoltPdf && InkvoltPdfInstalled) OpenSavedInInkvoltPdf();
        }
        catch (Exception ex)
        {
            Log.Write($"Save failed: {ex}");
            Message = $"Could not save: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private List<string> ImagePaths(string chosen)
    {
        if (Pages.Count == 1) return [chosen];
        var dir = Path.GetDirectoryName(chosen)!;
        var stem = Path.GetFileNameWithoutExtension(chosen);
        return Enumerable.Range(1, Pages.Count).Select(i => Path.Combine(dir, $"{stem} ({i}).jpg")).ToList();
    }

    [RelayCommand]
    private void OpenSaved()
    {
        if (LastSavedPath is not null) Shell.Open(LastSavedPath);
    }

    /// <summary>Hands the saved PDF to Inkvolt PDF (a running Inkvolt PDF opens it in a new tab).</summary>
    [RelayCommand]
    private void OpenSavedInInkvoltPdf()
    {
        if (LastSavedPath is null) return;
        if (!InkvoltApps.Launch(InkvoltApps.InkvoltPdf, LastSavedPath)) Message = "Inkvolt PDF couldn't be started.";
    }

    [RelayCommand]
    private void ShowSavedInFolder()
    {
        if (LastSavedPath is not null) Shell.ShowInFolder(LastSavedPath);
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
