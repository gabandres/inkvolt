using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using InkvoltPrint.App.Presets;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows.Ocr;
using InkvoltPrint.Windows.Printing;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPrint.App.ViewModels;

public sealed record Option<T>(T Value, string Label)
{
    public override string ToString() => Label;
}

/// <summary>Scan area in 1/300 inch (eSCL units). Null size = the whole glass.</summary>
public sealed record ScanArea(string Key, int? Width, int? Height);

/// <summary>
/// Scan straight from the device over eSCL. Each page lands as a JPEG (no re-encode), is checked for being blank or
/// crooked, and OCR runs in the background while the next page scans. Before saving, the pages can be reviewed:
/// turned, cropped, reordered (drag, or Alt+Shift+arrows), deleted, and more scanned onto the end. Save assembles a
/// searchable PDF locally; pages nobody edited keep the scanner's own JPEG. A preset (one click) scans with its own
/// settings and saves by itself into its folder under its file-name template, then opens, prints or emails the file;
/// presets with the review step stop on the pages first and save with "Save (preset)".
/// </summary>
/// <param name="findQueue">The printer's Windows queue, for presets that print a copy.</param>
/// <param name="demoPrint">Demo printer: "prints" here instead of a Windows queue.</param>
public sealed partial class ScanViewModel : ObservableObject
{
    private readonly AppState _state;
    private EsclClient _client;
    private CancellationTokenSource? _scanCts;
    private bool _dirty;
    private readonly ScannerCapabilities _caps;
    private readonly ScanPresetLibrary _presets;
    private readonly string _printerName;
    private readonly Func<Task<string?>> _findQueue;
    private readonly Action<string, int>? _demoPrint;

    private static readonly Option<ScanArea>[] AllPageSizes =
        [.. ScanChoices.PageSizes.Select(p => new Option<ScanArea>(new(p.Key, p.Width, p.Height), p.Label))];

    public ScanViewModel(EsclClient client, ScannerCapabilities caps, AppState state, ScanPresetLibrary presets, string printerName,
        Func<Task<string?>> findQueue, Action<string, int>? demoPrint = null)
    {
        _client = client;
        _state = state;
        _caps = caps;
        _presets = presets;
        _printerName = printerName;
        _findQueue = findQueue;
        _demoPrint = demoPrint;
        Sources = caps.Sources.Select(s => new Option<ScanSource>(s, ScanChoices.SourceLabel(s))).ToList();
        Source = Sources.FirstOrDefault();
        var input = (caps.Platen ?? caps.Adf)!;
        // A scanner that lists no resolutions (or only ranges nothing usual fits) still accepts the common ones.
        IReadOnlyList<int> offered = input.Resolutions.Count > 0 ? input.Resolutions : [150, 200, 300, 600];
        Resolutions = offered.Select(r => new Option<int>(r, r switch
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
        SkipBlank = state.ScanSkipBlank;
        Straighten = state.ScanStraighten;
        Pages.CollectionChanged += (_, _) =>
        {
            for (var i = 0; i < Pages.Count; i++) Pages[i].Number = i + 1;
            _dirty = Pages.Count > 0;
            PagesChanged();
        };
    }

    private void PagesChanged()
    {
        OnPropertyChanged(nameof(HasPages));
        OnPropertyChanged(nameof(PageCountText));
        OnPropertyChanged(nameof(HasUnsavedPages));
        OnPropertyChanged(nameof(ScanButtonText));
        SaveCommand.NotifyCanExecuteChanged();
    }

    /// <summary>A page was edited, skipped or kept: there is something new to save.</summary>
    private void PageChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(ScanPageViewModel.Edits) or nameof(ScanPageViewModel.IsSkipped))) return;
        _dirty = true;
        PagesChanged();
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

    /// <summary>Leave near-blank pages out of what's saved (they stay in the review, dimmed, with Keep).</summary>
    [ObservableProperty] public partial bool SkipBlank { get; set; }

    /// <summary>Straighten pages scanned a little crooked (up to 10°).</summary>
    [ObservableProperty] public partial bool Straighten { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ScanCommand), nameof(SaveCommand), nameof(ClearCommand), nameof(RunPresetCommand), nameof(SaveWithPresetCommand))]
    public partial bool IsBusy { get; set; }

    /// <summary>True only while pages are coming off the scanner (not while saving).</summary>
    [ObservableProperty] public partial bool IsScanning { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial string? LastSavedPath { get; set; }

    public bool HasPages => Pages.Count > 0;
    public bool HasUnsavedPages => _dirty && Pages.Count > 0;

    /// <summary>The pages that will be saved, in order.</summary>
    private List<ScanPageViewModel> Kept => Pages.Where(p => !p.IsSkipped).ToList();

    public string PageCountText
    {
        get
        {
            var kept = Kept.Count;
            var text = kept switch { 0 => Pages.Count == 0 ? "No pages yet" : "No pages to save", 1 => "1 page", var n => $"{n} pages" };
            var skipped = Pages.Count - kept;
            return skipped == 0 ? text : $"{text}  ·  {skipped} blank left out";
        }
    }

    public string ScanButtonText => HasPages ? "Scan more pages" : "Scan";

    public string EmptyHint => Source?.Value == ScanSource.Platen || Source is null
        ? "Put a page face down on the scanner glass, then press Scan."
        : "Put the pages face up in the document feeder, then press Scan.";

    partial void OnIsColorChanged(bool value) { _state.ScanColor = value; _state.Save(); }
    partial void OnUseOcrChanged(bool value) { _state.ScanOcr = value; _state.Save(); }
    partial void OnSkipBlankChanged(bool value) { _state.ScanSkipBlank = value; _state.Save(); }
    partial void OnStraightenChanged(bool value) { _state.ScanStraighten = value; _state.Save(); }

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
    private bool CanSave(string? format) => !IsBusy && Pages.Any(p => !p.IsSkipped);

    /// <summary>What one scan uses: the tab's settings, or a preset's matched to this scanner.</summary>
    private sealed record ScanJob(ScanRequest Request, bool Ocr, bool SkipBlank, bool Straighten, IReadOnlyList<string> Notes);

    private ScanJob TabJob()
    {
        var area = PageSize?.Value;
        var request = new ScanRequest(Source?.Value ?? ScanSource.Platen, IsColor ? ScanColor.Color : ScanColor.Grayscale, Resolution?.Value ?? 300,
            Width: area?.Width, Height: area?.Height);
        return new(request, UseOcr, SkipBlank, Straighten, []);
    }

    /// <summary>
    /// Scans and appends pages, so multi-page documents from the glass are just "Scan" again. "Scan more pages" after a
    /// preset keeps scanning with the preset's settings; a fresh scan uses the tab's.
    /// </summary>
    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task ScanAsync()
    {
        if (!HasPages) ActivePreset = null;
        var preset = ActivePreset;
        await ScanPagesAsync(() => preset is null ? Task.FromResult(TabJob()) : PlanAsync(preset));
    }

    /// <summary>Scans with the job <paramref name="makeJob"/> gives (it may ask the scanner first). Returns the pages added; -1 when it failed or was cancelled.</summary>
    private async Task<int> ScanPagesAsync(Func<Task<ScanJob>> makeJob)
    {
        IsBusy = true;
        IsScanning = true;
        LastSavedPath = null;
        _scanCts = new CancellationTokenSource();
        var added = new List<ScanPageViewModel>();
        var checks = new List<Task>();
        try
        {
            Message = "Scanning… (the first page takes longer if the printer was asleep)";
            var job = await makeJob();
            var request = job.Request;
            var dpi = request.Resolution;
            await foreach (var jpeg in _client.ScanAsync(request, _scanCts.Token))
            {
                var page = new ScanPageViewModel(jpeg, dpi, job.Ocr);
                page.PropertyChanged += PageChanged;
                Pages.Add(page);
                added.Add(page);
                checks.Add(page.AnalyseAsync(job.SkipBlank, job.Straighten)); // while the next page scans
                Message = $"Scanned page {Pages.Count}. Scanning…";
            }
            await Task.WhenAll(checks);
            var blank = added.Count(p => p.IsSkipped);
            var straightened = added.Count(p => p.Edits.Deskew != 0);
            var notes = string.Join(" ", new List<string>
            {
                blank == 0 ? "" : blank == 1 ? "1 blank page is left out (Keep puts it back)." : $"{blank} blank pages are left out (Keep puts them back).",
                straightened == 0 ? "" : straightened == 1 ? "1 page was straightened." : $"{straightened} pages were straightened.",
            }.Concat(job.Notes).Where(n => n.Length > 0));
            Message = added.Count == 0
                ? "The scanner returned no pages."
                : (request.Source == ScanSource.Platen
                    ? "Done. To add another page, put it on the glass and press Scan more pages."
                    : $"Done: {added.Count} page{(added.Count == 1 ? "" : "s")} from the feeder.") + (notes.Length > 0 ? " " + notes : "");
            return added.Count;
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
        return -1;
    }

    [RelayCommand]
    private void Cancel() => _scanCts?.Cancel();

    [RelayCommand]
    private void RemovePage(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        if (CropPage == page) CancelCrop();
        page.PropertyChanged -= PageChanged;
        Pages.Remove(page);
    }

    [RelayCommand]
    private void MovePageEarlier(ScanPageViewModel? page) => MovePage(page, page is null ? -1 : Pages.IndexOf(page) - 1);

    [RelayCommand]
    private void MovePageLater(ScanPageViewModel? page) => MovePage(page, page is null ? -1 : Pages.IndexOf(page) + 1);

    /// <summary>Moves a page to <paramref name="index"/> (drag and drop, Alt+Shift+arrows). Returns what to announce, or null if it didn't move.</summary>
    public string? MovePage(ScanPageViewModel? page, int index)
    {
        var from = page is null || IsBusy ? -1 : Pages.IndexOf(page);
        if (from < 0 || index < 0 || index >= Pages.Count || index == from) return null;
        Pages.Move(from, index);
        _dirty = true;
        OnPropertyChanged(nameof(HasUnsavedPages));
        return $"Moved to position {index + 1} of {Pages.Count}";
    }

    [RelayCommand]
    private void RotateLeft(ScanPageViewModel? page)
    {
        if (page is not null && !IsBusy) page.Edits = page.Edits.Turned(-1);
    }

    [RelayCommand]
    private void RotateRight(ScanPageViewModel? page)
    {
        if (page is not null && !IsBusy) page.Edits = page.Edits.Turned(1);
    }

    /// <summary>A page found blank goes back into what's saved.</summary>
    [RelayCommand]
    private void KeepPage(ScanPageViewModel? page)
    {
        if (page is not null) page.IsSkipped = false;
        if (page is not null) _ = page.OcrAsync();
    }

    // ---- Crop: an enlarged view of one page (straightened and turned, not cropped) with the crop box drawn on it ----

    /// <summary>The page being cropped; null when the crop view is closed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCropping))]
    public partial ScanPageViewModel? CropPage { get; set; }

    [ObservableProperty] public partial BitmapSource? CropImage { get; set; }

    /// <summary>The crop on the page as shown, as fractions of it.</summary>
    [ObservableProperty] public partial CropBox CropBox { get; set; } = CropBox.Full;

    public bool IsCropping => CropPage is not null;

    [RelayCommand]
    private async Task CropAsync(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        CropPage = page;
        CropBox = page.Edits.ShownCrop;
        CropImage = null;
        var edits = page.Edits with { Crop = null };
        try
        {
            var image = await Task.Run(() => ScanImaging.Render(page.Original, edits, 1600));
            if (CropPage == page) CropImage = image;
        }
        catch (Exception ex)
        {
            Log.Write($"Crop preview failed: {ex}");
            Message = $"Couldn't show the page: {ex.Message}";
            CropPage = null;
        }
    }

    [RelayCommand]
    private void ApplyCrop()
    {
        if (CropPage is { } page) page.Edits = page.Edits.WithShownCrop(CropBox);
        CancelCrop();
    }

    [RelayCommand]
    private void ResetCrop() => CropBox = CropBox.Full;

    [RelayCommand]
    private void CancelCrop()
    {
        CropPage = null;
        CropImage = null;
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void Clear()
    {
        if (HasUnsavedPages && !Prompt.Ask($"Discard {(Pages.Count == 1 ? "1 page" : $"{Pages.Count} pages")} you haven't saved?", "Discard")) return;
        DropPages();
    }

    private void DropPages()
    {
        CancelCrop();
        foreach (var page in Pages) page.PropertyChanged -= PageChanged;
        Pages.Clear();
        Message = null;
        LastSavedPath = null;
        ActivePreset = null;
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

        var kept = Kept;
        var targets = jpg ? ImagePaths(dialog.FileName, kept.Count) : [dialog.FileName];
        // The dialog already asked about the name typed; multi-page image saves write numbered siblings it never saw.
        if (jpg && kept.Count > 1 && targets.Where(File.Exists).ToList() is { Count: > 0 } clobbered &&
            !Prompt.Ask($"{clobbered.Count} file{(clobbered.Count == 1 ? "" : "s")} like \"{Path.GetFileName(clobbered[0])}\" already exist. Replace them?", "Replace"))
            return;

        CancelCrop();
        IsBusy = true;
        try
        {
            if (jpg)
            {
                for (var i = 0; i < kept.Count; i++) await File.WriteAllBytesAsync(targets[i], await kept[i].JpegAsync());
            }
            else
            {
                var pages = await PdfPagesAsync(kept);
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
            Message = $"Saved {Path.GetFileName(LastSavedPath)}{(jpg && kept.Count > 1 ? $" and {kept.Count - 1} more" : "")}.";
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

    private async Task<List<PdfPage>> PdfPagesAsync(List<ScanPageViewModel> kept)
    {
        if (kept.Any(p => !p.OcrAsync().IsCompleted)) Message = "Finishing text recognition…";
        var pages = new List<PdfPage>();
        foreach (var p in kept) pages.Add(new PdfPage(await p.JpegAsync(), p.Dpi, await p.OcrAsync()));
        return pages;
    }

    private static List<string> ImagePaths(string chosen, int count)
    {
        if (count == 1) return [chosen];
        var dir = Path.GetDirectoryName(chosen)!;
        var stem = Path.GetFileNameWithoutExtension(chosen);
        return Enumerable.Range(1, count).Select(i => Path.Combine(dir, $"{stem} ({i}).jpg")).ToList();
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

    // ---- Presets: one click scans with a preset's settings and saves (or stops on the review first) ----

    /// <summary>Shared by every printer; the editor changes them for all.</summary>
    public ObservableCollection<ScanPreset> Presets => _presets.Items;

    /// <summary>The preset the pages on screen were scanned with: "Scan more pages" keeps using it, "Save (name)" saves with it.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasActivePreset), nameof(SavePresetText))]
    [NotifyCanExecuteChangedFor(nameof(SaveWithPresetCommand))]
    public partial ScanPreset? ActivePreset { get; set; }

    public bool HasActivePreset => ActivePreset is not null;

    /// <summary>What the last preset scan couldn't do as asked (kept for the message after saving).</summary>
    private IReadOnlyList<string> _presetNotes = [];

    [RelayCommand]
    private void ManagePresets() => Prompt.EditPresets?.Invoke(_presets, _printerName);

    public string SavePresetText => ActivePreset is { } p ? $"Save ({p.Name})" : "";

    /// <summary>The preset matched to this scanner; with Auto, asks whether the feeder holds pages (a short status read).</summary>
    private async Task<ScanJob> PlanAsync(ScanPreset preset)
    {
        bool? loaded = null;
        if (preset.Source == PresetSource.Auto && _caps.Adf is not null && _caps.Platen is not null)
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_scanCts?.Token ?? default);
                timeout.CancelAfter(TimeSpan.FromSeconds(5));
                var status = await _client.GetStatusAsync(timeout.Token);
                loaded = status.AdfState is null ? null : status.AdfLoaded;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || _scanCts?.IsCancellationRequested != true)
            {
                Log.Write($"Feeder check before a preset scan failed (scanning from the glass): {ex.Message}");
            }
        }
        var plan = PresetPlan.For(preset, _caps, loaded, OcrAvailable, RegionInfo.CurrentRegion.IsMetric);
        var r = plan.Request;
        Log.Write($"Preset scan: {r.Source}, {r.Color}, {r.Resolution} dpi, area {(r.Width is null ? "whole" : $"{r.Width}x{r.Height}")}, feeder loaded {loaded?.ToString() ?? "unknown"}");
        _presetNotes = plan.Notes;
        return new(plan.Request, plan.Ocr, preset.SkipBlank, preset.Straighten, plan.Notes);
    }

    /// <summary>One click: scan with the preset, then save it to its folder (unless it stops on the review first).</summary>
    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task RunPresetAsync(ScanPreset? preset)
    {
        if (preset is null || IsBusy) return;
        preset = _presets.Find(preset.Id) ?? preset;
        if (HasUnsavedPages && !Prompt.Ask(
                $"Discard {(Pages.Count == 1 ? "1 page" : $"{Pages.Count} pages")} you haven't saved and scan with \"{preset.Name}\"?", "Discard and scan"))
            return;
        DropPages();
        ActivePreset = preset;
        Prompt.Announce($"Scanning with {preset.Name}");
        var added = await ScanPagesAsync(() => PlanAsync(preset));
        if (added <= 0) return;
        if (!preset.Review) await SaveWithPresetAsync();
        else Message += $" Check the pages, then press {SavePresetText}.";
    }

    private bool CanSaveWithPreset() => ActivePreset is not null && !IsBusy;

    /// <summary>Saves the kept pages into the preset's folder under its file-name template (never over another file), then its "after saving" step.</summary>
    [RelayCommand(CanExecute = nameof(CanSaveWithPreset))]
    private async Task SaveWithPresetAsync()
    {
        if (ActivePreset is not { } active) return;
        var preset = _presets.Find(active.Id) ?? active; // the counter may have moved on
        var kept = Kept;
        if (kept.Count == 0)
        {
            Message = "No pages to save: every page was left out as blank. Keep puts a page back.";
            return;
        }
        if (_presets.Folder(preset, out var problem) is not { } root)
        {
            Message = problem;
            return;
        }
        CancelCrop();
        IsBusy = true;
        try
        {
            var ctx = new NameContext(DateTime.Now, preset.Name, _printerName, preset.NextNumber, kept.Count);
            var folder = Path.Combine(root, FileNameTemplate.Subfolder(preset.Subfolder, ctx));
            Directory.CreateDirectory(folder);
            var stem = FileNameTemplate.FileName(preset.FileName, ctx);
            var jpg = preset.FileType == PresetFileType.Jpeg;
            var saved = jpg ? await WriteImagesAsync(kept, folder, stem) : [await WritePdfAsync(await PdfPagesAsync(kept), folder, stem)];

            preset = preset with { NextNumber = preset.NextNumber + 1 };
            _presets.Update(preset);
            ActivePreset = preset;
            LastSavedPath = saved[0];
            _dirty = false;
            OnPropertyChanged(nameof(HasUnsavedPages));
            Message = $"Saved {Path.GetFileName(saved[0])}{(saved.Count > 1 ? $" and {saved.Count - 1} more" : "")} in {folder}."
                + string.Concat(_presetNotes.Select(n => " " + n));
            Prompt.Announce(Message);
            await AfterSaveAsync(preset, saved, kept, jpg);
        }
        catch (Exception ex)
        {
            Log.Write($"Preset save failed: {ex}");
            Message = $"Could not save: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Writes the PDF next to its final name, then moves it there only if that name is still free (else the next one).</summary>
    private static Task<string> WritePdfAsync(List<PdfPage> pages, string folder, string stem) => Task.Run(() =>
    {
        var tmp = Path.Combine(folder, $"{stem}.{Guid.NewGuid():N}.partial");
        try
        {
            using (var fs = File.Create(tmp)) PdfWriter.Write(fs, pages, stem);
            for (var attempt = 0; ; attempt++)
            {
                var target = FileNameTemplate.UniquePath(folder, stem, ".pdf", File.Exists);
                try
                {
                    File.Move(tmp, target, overwrite: false);
                    return target;
                }
                catch (IOException) when (attempt < 5 && File.Exists(target))
                {
                    // Another file took the name meanwhile: take the next one.
                }
            }
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    });

    private static async Task<List<string>> WriteImagesAsync(List<ScanPageViewModel> kept, string folder, string stem)
    {
        var targets = FileNameTemplate.UniquePaths(folder, stem, ".jpg", kept.Count, File.Exists);
        for (var i = 0; i < kept.Count; i++)
        {
            var bytes = await kept[i].JpegAsync();
            await using var fs = new FileStream(targets[i], FileMode.CreateNew, FileAccess.Write); // never over another file
            await fs.WriteAsync(bytes);
        }
        return [.. targets];
    }

    /// <summary>The preset's step after saving: open in Inkvolt PDF, print a copy, or hand the file to the mail app.</summary>
    private async Task AfterSaveAsync(ScanPreset preset, List<string> saved, List<ScanPageViewModel> kept, bool jpg)
    {
        var demo = _presets.IsDemo;
        if (!jpg && (preset.After == PresetAfter.OpenInInkvoltPdf || OpenInInkvoltPdf))
        {
            if (demo) Message += " (Demo: nothing is opened in Inkvolt PDF.)";
            else if (!InkvoltPdfInstalled) Message += " Inkvolt PDF isn't installed, so it wasn't opened.";
            else OpenSavedInInkvoltPdf();
        }
        switch (preset.After)
        {
            case PresetAfter.Print:
                await PrintCopyAsync(saved[0], kept);
                break;
            case PresetAfter.Email when demo:
                Message += " (Demo: in a real scan your mail app would open a new message with it attached.)";
                break;
            case PresetAfter.Email:
                Message += await MailHandoff.SendAsync(saved, Path.GetFileNameWithoutExtension(saved[0])) switch
                {
                    MailHandoff.Result.Attached => " It's attached to a new message in your mail app.",
                    MailHandoff.Result.Cancelled => " The email was cancelled; the file is saved.",
                    _ => " Your mail app has no attachment hand-off, so a new message and the file's folder opened: drag the file into the message.",
                };
                break;
        }
    }

    /// <summary>Prints the saved pages through this printer's Windows queue at actual size (like a copy).</summary>
    private async Task PrintCopyAsync(string file, List<ScanPageViewModel> kept)
    {
        var name = Path.GetFileName(file);
        if (_demoPrint is not null)
        {
            _demoPrint(name, kept.Count);
            Message += " A copy went to the (demo) print queue.";
            return;
        }
        try
        {
            if (await _findQueue() is not { } queue)
            {
                Message += " It wasn't printed: this printer isn't set up in Windows yet (Set up, at the top of the page).";
                return;
            }
            var pages = new List<RenderedPage>();
            foreach (var p in kept)
            {
                var jpeg = await p.JpegAsync();
                var (w, h, _) = PdfWriter.JpegInfo(jpeg);
                var (wIn, hIn) = CopyLayout.Inches(w, h, p.Dpi);
                pages.Add(new RenderedPage(jpeg, wIn, hIn));
            }
            await QueuePrinter.PrintPagesAsync(queue, pages, copies: 1, twoSided: false, name);
            Message += " A copy is printing.";
        }
        catch (Exception ex)
        {
            Log.Write($"Preset print failed: {ex}");
            Message += $" It couldn't be printed: {ex.Message}";
        }
    }
}

/// <summary>
/// A scanned page under review. <see cref="Original"/> is the scanner's JPEG and is what's saved until the page is
/// edited (<see cref="Edits"/>: straightened, cropped, turned); then the edited page is encoded once, when needed, and
/// text recognition runs again on it. A skipped page (blank) stays listed but isn't saved.
/// </summary>
public sealed partial class ScanPageViewModel : ObservableObject
{
    private const int ThumbnailWidth = 480;

    private readonly bool _ocr;
    private (PageEdits Edits, Task<byte[]> Jpeg)? _jpeg;
    private (PageEdits Edits, Task<IReadOnlyList<OcrWord>?> Words)? _words;

    public ScanPageViewModel(byte[] jpeg, int dpi, bool ocr)
    {
        Original = jpeg;
        Dpi = dpi;
        _ocr = ocr;
        Thumbnail = ScanImaging.Render(jpeg, PageEdits.None, ThumbnailWidth);
    }

    public byte[] Original { get; }
    public int Dpi { get; }

    [ObservableProperty] public partial BitmapSource Thumbnail { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Label), nameof(Note), nameof(IsEdited))]
    public partial PageEdits Edits { get; set; } = PageEdits.None;

    /// <summary>Left out when saving (found blank); Keep puts it back.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Label), nameof(Note))]
    public partial bool IsSkipped { get; set; }

    /// <summary>1-based position in the list.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Label))]
    public partial int Number { get; set; }

    /// <summary>The checks after scanning (blank, crooked) are done.</summary>
    [ObservableProperty] public partial bool IsAnalysed { get; set; }

    public bool IsEdited => !Edits.IsEmpty;

    /// <summary>Screen reader name: "Page 2", "Page 3, straightened", "Page 4, blank, not saved".</summary>
    public string Label => Note.Length == 0 ? $"Page {Number}" : $"Page {Number}, {Note.ToLowerInvariant()}";

    /// <summary>What happened to the page, under its number: "Straightened", "Edited", "Blank, not saved", or nothing.</summary>
    public string Note => IsSkipped ? "Blank, not saved" : Edits.Deskew != 0 && Edits.Crop is null && Edits.QuarterTurns % 4 == 0 ? "Straightened" : IsEdited ? "Edited" : "";

    partial void OnEditsChanged(PageEdits value) => _ = RefreshThumbnailAsync(value);

    /// <summary>The page as saved: the scanner's JPEG, or the edited page encoded once per set of edits.</summary>
    public Task<byte[]> JpegAsync()
    {
        var edits = Edits;
        if (edits.IsEmpty) return Task.FromResult(Original);
        if (_jpeg is { } cached && cached.Edits == edits && !cached.Jpeg.IsFaulted) return cached.Jpeg;
        var task = Task.Run(() => ScanImaging.Jpeg(ScanImaging.Render(Original, edits)));
        _jpeg = (edits, task);
        return task;
    }

    /// <summary>Recognised text for the page as saved (null: OCR off or failed; the page still saves).</summary>
    public Task<IReadOnlyList<OcrWord>?> OcrAsync()
    {
        if (!_ocr) return Task.FromResult<IReadOnlyList<OcrWord>?>(null);
        var edits = Edits;
        if (_words is { } cached && cached.Edits == edits) return cached.Words;
        var task = RunOcrAsync(JpegAsync(), Dpi);
        _words = (edits, task);
        return task;
    }

    /// <summary>Blank and skew checks, then OCR in the background (on the straightened page when it was straightened).</summary>
    public async Task AnalyseAsync(bool skipBlank, bool straighten)
    {
        try
        {
            if (skipBlank || straighten)
            {
                var (blank, angle) = await Task.Run(() =>
                {
                    var image = ScanImaging.Analysis(Original);
                    var isBlank = skipBlank && BlankPage.IsBlank(image);
                    return (isBlank, straighten && !isBlank ? Deskew.Angle(image) : 0);
                });
                IsSkipped = blank;
                if (angle != 0 && Edits.IsEmpty) Edits = PageEdits.None with { Deskew = angle };
            }
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Page check failed: {ex.Message}"); // the page stays as scanned
        }
        IsAnalysed = true;
        if (!IsSkipped) _ = OcrAsync();
    }

    private async Task RefreshThumbnailAsync(PageEdits edits)
    {
        try
        {
            var thumbnail = await Task.Run(() => ScanImaging.Render(Original, edits, ThumbnailWidth));
            if (edits == Edits) Thumbnail = thumbnail; // a later edit's thumbnail wins
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Thumbnail failed: {ex.Message}");
        }
    }

    private static async Task<IReadOnlyList<OcrWord>?> RunOcrAsync(Task<byte[]> jpeg, int dpi)
    {
        try
        {
            var bytes = await jpeg;
            return await Task.Run(() => WindowsOcr.RecognizeAsync(bytes, dpi));
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"OCR failed: {ex.Message}");
            return null; // page still saves, just without a text layer
        }
    }
}
