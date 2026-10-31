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
using InkvoltPrint.Core.Model;
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

/// <summary>The OCR languages a scan or preset can read in: Windows' own choice, then each installed on this PC.</summary>
public static class OcrLanguageChoices
{
    public static IReadOnlyList<Option<string?>> List() =>
        [new Option<string?>(null, "Windows' language"), .. WindowsRecognizer.Languages().Select(l => new Option<string?>(l.Tag, l.Name))];
}

/// <summary>Scan area in 1/300 inch (eSCL units). Null size = the whole glass.</summary>
public sealed record ScanArea(string Key, int? Width, int? Height);

/// <summary>
/// Scan straight from the device over eSCL, or through the scanner's Windows driver (WIA) when it has no eSCL. Each page lands as a JPEG (no re-encode), is checked for being blank or
/// crooked, and OCR runs in the background while the next page scans. Before saving, the pages can be reviewed:
/// turned, cropped, reordered (drag, or Alt+Shift+arrows), deleted, and more scanned onto the end. Save assembles a
/// searchable PDF locally; pages nobody edited keep the scanner's own JPEG. A preset (one click) scans with its own
/// settings and saves by itself into its folder under its file-name template, then opens, prints or emails the file;
/// presets with the review step stop on the pages first and save with "Save (preset)".
/// </summary>
/// <param name="findQueue">The printer's Windows queue, for presets that print a copy.</param>
/// <param name="pc">This PC, or the demo's made-up one: where a made-up printer "prints", whether other apps are started.</param>
public sealed partial class ScanViewModel : ObservableObject
{
    private readonly AppState _state;
    private IScanner _client;
    private CancellationTokenSource? _scanCts;
    private bool _dirty;
    private readonly ScannerCapabilities _caps;
    private readonly ScanPresetLibrary _presets;
    private readonly string _printerName;
    private readonly Func<Task<string?>> _findQueue;
    private readonly PcEnvironment _pc;

    private static readonly Option<ScanArea>[] AllPageSizes =
        [.. ScanChoices.PageSizes.Select(p => new Option<ScanArea>(new(p.Key, p.Width, p.Height), p.Label))];

    public ScanViewModel(IScanner client, ScannerCapabilities caps, AppState state, ScanPresetLibrary presets, string printerName,
        Func<Task<string?>> findQueue, PcEnvironment pc)
    {
        _client = client;
        _state = state;
        _caps = caps;
        _presets = presets;
        _printerName = printerName;
        _findQueue = findQueue;
        _pc = pc;
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
        SkipBlank = state.ScanSkipBlank;
        Straighten = state.ScanStraighten;
        var cleanup = (PageFilters)state.ScanCleanup & PageFilters.All;
        CropToPaper = cleanup.HasFlag(PageFilters.CropToPaper);
        WhitenPages = cleanup.HasFlag(PageFilters.Whiten);
        DescreenPages = cleanup.HasFlag(PageFilters.Descreen);
        RestoreColors = cleanup.HasFlag(PageFilters.RestoreColors);
        OcrLanguage = OcrLanguages.FirstOrDefault(o => o.Value == state.ScanOcrLanguage) ?? OcrLanguages[0];
        SplitMode = SplitChoices.FirstOrDefault(o => (int)o.Value == state.ScanSplitAt) ?? SplitChoices[0];
        KeepSeparators = _batchKeep = state.ScanKeepSeparators;
        FindPhotos = state.ScanFindPhotos;
        EditedPhotos.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PhotoStatus));
            RemovePhotoCommand.NotifyCanExecuteChanged();
            TurnPhotoCommand.NotifyCanExecuteChanged();
        };
        History.Changed += (_, _) =>
        {
            OnPropertyChanged(nameof(UndoText));
            UndoCommand.NotifyCanExecuteChanged();
        };
        Pages.CollectionChanged += (_, _) =>
        {
            for (var i = 0; i < Pages.Count; i++) Pages[i].Number = i + 1;
            _dirty = Pages.Count > 0;
            _changes++;
            _savedParts.Clear();
            RefreshFiles();
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
        if (e.PropertyName is not (nameof(ScanPageViewModel.Edits) or nameof(ScanPageViewModel.IsSkipped)
                or nameof(ScanPageViewModel.Separator) or nameof(ScanPageViewModel.StartsFile) or nameof(ScanPageViewModel.Photos))) return;
        _dirty = true;
        _changes++;
        _savedParts.Clear(); // a page changed: what was saved isn't what's on screen any more
        if (e.PropertyName != nameof(ScanPageViewModel.Edits)) RefreshFiles();
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

    /// <summary>Open each scan saved as PDF in Inkvolt PDF right away (Settings).</summary>
    private bool OpenInInkvoltPdf => _state.OpenScansInInkvoltPdf;

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

    // The tab's clean up: what each scanned page gets (a preset has its own). Each can be changed on a page in the review.
    [ObservableProperty] public partial bool CropToPaper { get; set; }
    [ObservableProperty] public partial bool WhitenPages { get; set; }
    [ObservableProperty] public partial bool DescreenPages { get; set; }
    [ObservableProperty] public partial bool RestoreColors { get; set; }

    private PageFilters TabCleanup =>
        (CropToPaper ? PageFilters.CropToPaper : 0) | (WhitenPages ? PageFilters.Whiten : 0) | (DescreenPages ? PageFilters.Descreen : 0) | (RestoreColors ? PageFilters.RestoreColors : 0);

    private void SaveCleanup()
    {
        _state.ScanCleanup = (int)TabCleanup;
        _state.Save();
    }

    partial void OnCropToPaperChanged(bool value) => SaveCleanup();
    partial void OnWhitenPagesChanged(bool value) => SaveCleanup();
    partial void OnDescreenPagesChanged(bool value) => SaveCleanup();
    partial void OnRestoreColorsChanged(bool value) => SaveCleanup();

    /// <summary>The OCR languages to choose from: Windows' own choice, then each one installed on this PC.</summary>
    public IReadOnlyList<Option<string?>> OcrLanguages { get; } = OcrLanguageChoices.List();

    public bool HasOcrLanguageChoice => OcrLanguages.Count > 2;

    [ObservableProperty] public partial Option<string?>? OcrLanguage { get; set; }

    partial void OnOcrLanguageChanged(Option<string?>? value)
    {
        if (value is null) return;
        _state.ScanOcrLanguage = value.Value;
        _state.Save();
    }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ScanCommand), nameof(SaveCommand), nameof(ClearCommand), nameof(RunPresetCommand), nameof(SaveWithPresetCommand), nameof(UndoCommand))]
    public partial bool IsBusy { get; set; }

    /// <summary>The review's changes, newest first, so Undo (Ctrl+Z) puts each one back: a deleted page is a scan to redo otherwise.</summary>
    public UndoHistory History { get; } = new();

    /// <summary>The Undo button's tooltip: what it puts back.</summary>
    public string UndoText => History.Next is { } next ? $"Undo {char.ToLowerInvariant(next[0])}{next[1..]} (Ctrl+Z)" : "Undo (Ctrl+Z)";

    private bool CanUndo() => !IsBusy && History.CanUndo;

    [RelayCommand(CanExecute = nameof(CanUndo))]
    private void Undo()
    {
        if (!CanUndo()) return;
        CancelCrop();
        CancelPhotos();
        CancelClean();
        if (History.Undo() is { } what)
        {
            Message = $"Undone: {what}.";
            Prompt.Announce(Message);
        }
    }

    /// <summary>Records how to put a page's look back (its turns, crop, photos), before the change.</summary>
    private void RecordLook(string what, ScanPageViewModel page)
    {
        var (edits, photos) = (page.Edits, page.Photos);
        History.Record(what, () =>
        {
            page.Edits = edits;
            page.Photos = photos;
        });
    }

    /// <summary>Records how to put a page's place in the files back (file start, separator, skipped), before the change.</summary>
    private void RecordRole(string what, ScanPageViewModel page)
    {
        var (startsFile, separator, skipped) = (page.StartsFile, page.Separator, page.IsSkipped);
        History.Record(what, () =>
        {
            page.Separator = separator;
            page.StartsFile = startsFile;
            page.IsSkipped = skipped;
        });
    }

    /// <summary>True only while pages are coming off the scanner (not while saving).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCancelWork))]
    public partial bool IsScanning { get; set; }

    /// <summary>A save is under way: cleaning huge pages takes time, so it can be cancelled.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCancelWork))]
    public partial bool IsSaving { get; set; }

    public bool CanCancelWork => IsScanning || IsSaving;

    private CancellationTokenSource? _saveCts;

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial string? LastSavedPath { get; set; }

    public bool HasPages => Pages.Count > 0;
    public bool HasUnsavedPages => _dirty && Pages.Count > 0;

    /// <summary>Counts the changes to the pages, so a save marks them saved only if nothing changed while it ran.</summary>
    private int _changes;

    /// <summary>A save or clear is under way, its dialogs included.</summary>
    private int _holding;

    /// <summary>Pages a crashed run left can be put back now: not scanning, saving or clearing (<see cref="Restore"/>).</summary>
    public bool TakesRestoredPages => !IsBusy && _holding == 0;

    /// <summary>Holds restored pages back until the save or clear (with its questions) is over.</summary>
    private Holding HoldRestore() => new(this);

    private readonly struct Holding : IDisposable
    {
        private readonly ScanViewModel _scan;

        public Holding(ScanViewModel scan)
        {
            _scan = scan;
            scan._holding++;
        }

        public void Dispose() => _scan._holding--;
    }

    /// <summary>The pages saved as they were when the save started (<paramref name="changes"/>): marked saved, unless they changed meanwhile.</summary>
    private void MarkSaved(int changes)
    {
        if (_changes == changes) _dirty = false;
        OnPropertyChanged(nameof(HasUnsavedPages));
    }

    /// <summary>
    /// The files the pages are saved as: one, or with separator sheets (or splits set by hand) several, each its pages in
    /// order (<see cref="BatchSplit"/>). Skipped pages and dropped separators are in none.
    /// </summary>
    private List<List<ScanPageViewModel>> Files()
    {
        var pages = Pages.ToList();
        return [.. BatchSplit.Parts([.. pages.Select(p => p.AsBatchPage)], _batchKeep).Select(part => part.Select(i => pages[i]).ToList())];
    }

    // ---- Several photos on the glass: each saved as its own picture ----

    /// <summary>Find the photos on a scan of the glass and save each one by itself, cut out straight.</summary>
    [ObservableProperty] public partial bool FindPhotos { get; set; }

    partial void OnFindPhotosChanged(bool value) { _state.ScanFindPhotos = value; _state.Save(); }

    /// <summary>The page whose photos are being adjusted; null when the photo view is closed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEditingPhotos), nameof(IsAdjustingPage))]
    public partial ScanPageViewModel? PhotoPage { get; set; }

    public bool IsEditingPhotos => PhotoPage is not null;

    /// <summary>The whole scan, large (as scanned: photos are found and cut on the original).</summary>
    [ObservableProperty] public partial BitmapSource? PhotoImage { get; set; }

    /// <summary>The photos being adjusted (the view edits them in place).</summary>
    public ObservableCollection<PhotoBox> EditedPhotos { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PhotoStatus))]
    [NotifyCanExecuteChangedFor(nameof(RemovePhotoCommand), nameof(TurnPhotoCommand))]
    public partial int SelectedPhoto { get; set; } = -1;

    /// <summary>"Photo 2 of 3: 6.0 × 4.0 in, turned 3°" for the selected photo, or how many there are.</summary>
    public string PhotoStatus
    {
        get
        {
            if (PhotoPage is not { } page) return "";
            if (EditedPhotos.Count == 0) return "No photos marked: the whole scan is saved as one picture. Drag over a photo to mark it.";
            if (SelectedPhoto < 0 || SelectedPhoto >= EditedPhotos.Count)
                return EditedPhotos.Count == 1 ? "1 photo, saved as its own picture." : $"{EditedPhotos.Count} photos, each saved as its own picture.";
            var b = EditedPhotos[SelectedPhoto];
            var inches = page.WidthInches;
            var turns = b.QuarterTurns % 4 == 0 ? "" : $", saved turned {90 * b.QuarterTurns}°";
            return string.Create(CultureInfo.CurrentCulture,
                $"Photo {SelectedPhoto + 1} of {EditedPhotos.Count}: {b.Width * inches:0.0} × {b.Height * inches:0.0} in, straightened by {b.Angle:0.#}°{turns}.");
        }
    }

    [RelayCommand]
    private async Task EditPhotosAsync(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        CancelCrop();
        PhotoPage = page;
        EditedPhotos.Clear();
        foreach (var box in page.Photos ?? []) EditedPhotos.Add(box);
        SelectedPhoto = EditedPhotos.Count > 0 ? 0 : -1;
        PhotoImage = null;
        try
        {
            var image = await Task.Run(() => ScanImaging.Render(page.Original, PageEdits.None, 1600));
            if (PhotoPage == page) PhotoImage = image;
        }
        catch (Exception ex)
        {
            Log.Write($"Photo view failed: {ex}");
            Message = $"Couldn't show the scan: {ex.Message}";
            PhotoPage = null;
        }
        OnPropertyChanged(nameof(PhotoStatus));
    }

    partial void OnSelectedPhotoChanged(int value)
    {
        if (IsEditingPhotos && value >= 0) Prompt.Announce(PhotoStatus);
    }

    [RelayCommand]
    private void AddPhoto()
    {
        if (PhotoPage is not { } page) return;
        var aspect = page.HeightInches / page.WidthInches; // the scan's height in units of its width
        EditedPhotos.Add(new PhotoBox(0.5, aspect / 2, 0.4, 0.3, 0));
        SelectedPhoto = EditedPhotos.Count - 1;
        Prompt.Announce($"Photo {EditedPhotos.Count} added in the middle. Arrow keys move it, Shift+arrows resize it.");
    }

    private bool HasSelectedPhoto() => SelectedPhoto >= 0 && SelectedPhoto < EditedPhotos.Count;

    [RelayCommand(CanExecute = nameof(HasSelectedPhoto))]
    private void RemovePhoto()
    {
        if (!HasSelectedPhoto()) return;
        var removed = SelectedPhoto;
        EditedPhotos.RemoveAt(removed);
        SelectedPhoto = Math.Min(removed, EditedPhotos.Count - 1);
        Prompt.Announce($"Photo {removed + 1} removed. {EditedPhotos.Count} left.");
    }

    /// <summary>The selected photo is saved turned a further quarter clockwise (a portrait print laid on its side).</summary>
    [RelayCommand(CanExecute = nameof(HasSelectedPhoto))]
    private void TurnPhoto()
    {
        if (!HasSelectedPhoto()) return;
        var b = EditedPhotos[SelectedPhoto];
        EditedPhotos[SelectedPhoto] = b with { QuarterTurns = (b.QuarterTurns + 1) % 4 };
        OnPropertyChanged(nameof(PhotoStatus));
        Prompt.Announce(PhotoStatus);
    }

    /// <summary>Looks for the photos again, dropping the changes made here.</summary>
    [RelayCommand]
    private async Task FindPhotosAgainAsync()
    {
        if (PhotoPage is not { } page) return;
        var found = await Task.Run(() => ScanPageViewModel.FindPhotosOn(page.Original, page.Dpi));
        if (PhotoPage != page) return;
        EditedPhotos.Clear();
        foreach (var box in found) EditedPhotos.Add(box);
        SelectedPhoto = EditedPhotos.Count > 0 ? 0 : -1;
        OnPropertyChanged(nameof(PhotoStatus));
        Prompt.Announce(found.Count == 1 ? "1 photo found" : $"{found.Count} photos found");
    }

    [RelayCommand]
    private void ApplyPhotos()
    {
        if (PhotoPage is { } page)
        {
            RecordLook($"Change the photos on page {page.Number}", page);
            page.Photos = [.. EditedPhotos];
        }
        CancelPhotos();
    }

    [RelayCommand]
    private void CancelPhotos()
    {
        PhotoPage = null;
        PhotoImage = null;
        EditedPhotos.Clear();
        SelectedPhoto = -1;
    }

    /// <summary>Whether this batch keeps its separator sheets: the preset's or the tab's setting when it was scanned.</summary>
    private bool _batchKeep;

    /// <summary>Marks the first page of each file on the thumbnails (only when there is more than one).</summary>
    private void RefreshFiles()
    {
        var starts = BatchSplit.FileStarts([.. Pages.Select(p => p.AsBatchPage)], _batchKeep);
        var count = starts.Length == 0 ? 0 : starts.Max();
        for (var i = 0; i < Pages.Count; i++)
        {
            Pages[i].FileStart = count > 1 ? starts[i] : 0;
            Pages[i].SeparatorKept = _batchKeep;
        }
        OnPropertyChanged(nameof(PageCountText));
    }

    public string PageCountText
    {
        get
        {
            var files = Files();
            var kept = files.Sum(f => f.Count);
            var text = kept switch { 0 => Pages.Count == 0 ? "No pages yet" : "No pages to save", 1 => "1 page", var n => $"{n} pages" };
            if (files.Count > 1) text += $" in {files.Count} files";
            var photos = files.Sum(f => f.Sum(p => p.HasPhotos ? p.Photos!.Count : 0));
            if (photos > 0) text += $" ({(photos == 1 ? "1 photo" : $"{photos} photos")})";
            var skipped = Pages.Count(p => p.IsSkipped && !p.IsSeparator);
            var separators = _batchKeep ? 0 : Pages.Count(p => p.IsSeparator);
            if (separators > 0) text += $"  ·  {separators} separator{(separators == 1 ? "" : "s")} left out";
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

    // ---- Batch scanning: one feeder run split into several files at separator sheets ----

    public IReadOnlyList<Option<SplitAt>> SplitChoices { get; } = [.. Enum.GetValues<SplitAt>().Select(s => new Option<SplitAt>(s, Separators.Label(s)))];

    /// <summary>What starts a new file: nothing, patch code sheets, blank pages, or either.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Splits))]
    public partial Option<SplitAt>? SplitMode { get; set; }

    public bool Splits => SplitMode?.Value is { } s && s != SplitAt.None;

    /// <summary>Separator sheets stay in, as the first page of the file they start.</summary>
    [ObservableProperty] public partial bool KeepSeparators { get; set; }

    partial void OnSplitModeChanged(Option<SplitAt>? value)
    {
        if (value is null) return;
        _state.ScanSplitAt = (int)value.Value;
        _state.Save();
    }

    partial void OnKeepSeparatorsChanged(bool value)
    {
        _state.ScanKeepSeparators = value;
        _state.Save();
        if (ActivePreset is not null) return; // a preset's batch keeps the preset's choice
        _batchKeep = value;
        RefreshFiles();
        PagesChanged();
    }

    /// <summary>A new file starts at this page (or no longer does): moves a split point, together with <see cref="NotSeparator"/>.</summary>
    [RelayCommand]
    private void ToggleFileStart(ScanPageViewModel? page)
    {
        if (page is null || IsBusy || page.IsSeparator) return;
        RecordRole(page.StartsFile ? $"Join page {page.Number} to the file before it" : $"Start a new file at page {page.Number}", page);
        page.StartsFile = !page.StartsFile;
        Prompt.Announce(page.FileStart > 0 ? $"Page {page.Number} starts file {page.FileStart}" : $"Page {page.Number} is in the same file as the page before it");
    }

    /// <summary>A page taken for a separator sheet is an ordinary page again (the files on either side join).</summary>
    [RelayCommand]
    private void NotSeparator(ScanPageViewModel? page)
    {
        if (page is null || IsBusy || !page.IsSeparator) return;
        RecordRole($"Keep page {page.Number} as a page", page);
        page.Separator = SeparatorFound.None;
        _ = page.OcrAsync();
        Prompt.Announce($"Page {page.Number} is a page again, not a separator");
    }

    /// <summary>Any page as a separator sheet: a new file starts after it.</summary>
    [RelayCommand]
    private void MarkSeparator(ScanPageViewModel? page)
    {
        if (page is null || IsBusy || page.IsSeparator) return;
        RecordRole($"Use page {page.Number} as a separator", page);
        page.StartsFile = false;
        page.IsSkipped = false;
        page.Separator = new SeparatorFound(SeparatorKind.ByHand);
        Prompt.Announce($"Page {page.Number} is a separator sheet");
    }

    /// <summary>Saves a separator sheet (Patch T; Letter, or A4 by region) as a PDF and opens it, to print at actual size.</summary>
    [RelayCommand]
    private void PrintSeparatorSheet()
    {
        var metric = RegionInfo.CurrentRegion.IsMetric;
        var dialog = new SaveFileDialog
        {
            Title = "Save a separator sheet to print",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            FileName = "Separator sheet (Patch T)",
            Filter = "PDF document (*.pdf)|*.pdf",
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            using (var fs = File.Create(dialog.FileName))
                SeparatorSheet.Write(fs, PatchCode.PatchT, metric ? 210 / 25.4 : 8.5, metric ? 297 / 25.4 : 11);
            Message = $"Saved {Path.GetFileName(dialog.FileName)}. Print it at actual size (100%) and put a copy in front of each document in the feeder.";
            Shell.Open(dialog.FileName);
        }
        catch (Exception ex)
        {
            Log.Write($"Separator sheet failed: {ex}");
            Message = $"Could not save the separator sheet: {ex.Message}";
        }
    }

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

    /// <summary>What the scanner offers (from eSCL, or from its Windows driver).</summary>
    public ScannerCapabilities Capabilities => _caps;

    /// <summary>Scanning goes through the scanner's Windows driver (WIA), not eSCL: the tab says so.</summary>
    public bool ViaWindows => _client is Core.Wia.WiaScanner;

    /// <summary>The line under the tab's settings for a scanner reached through Windows; null over eSCL.</summary>
    public string? ScannerNote => _client is Core.Wia.WiaScanner wia
        ? $"Scanning through Windows with the scanner's own driver ({wia.Device.Name})."
        : null;

    public void Rebind(IScanner client)
    {
        _client = client;
        _blocked = null;
        OnPropertyChanged(nameof(ViaWindows));
        OnPropertyChanged(nameof(ScannerNote));
    }

    /// <summary>Why scanning is off for now (another device answers at the printer's address); null when it may scan.</summary>
    private string? _blocked;

    /// <summary>
    /// Another device answers at the printer's address: no scan (a preset from the jump list included) reaches it. Pages
    /// already scanned stay, to be saved; <see cref="Rebind"/> lifts it when the printer is back.
    /// </summary>
    public void Detach(string reason) => _blocked = reason;

    private bool NotBusy() => !IsBusy;
    private bool CanSave(string? format) => !IsBusy && Pages.Any(p => !p.IsSkipped && !p.IsSeparator);

    /// <summary>What one scan uses: the tab's settings, or a preset's matched to this scanner.</summary>
    private sealed record ScanJob(ScanRequest Request, bool Ocr, bool SkipBlank, bool Straighten, IReadOnlyList<string> Notes,
        SplitAt Split = SplitAt.None, bool KeepSeparators = false, bool FindPhotos = false, PageFilters Cleanup = PageFilters.None, string? OcrLanguage = null);

    private ScanJob TabJob()
    {
        var area = PageSize?.Value;
        var request = new ScanRequest(Source?.Value ?? ScanSource.Platen, IsColor ? ScanColor.Color : ScanColor.Grayscale, Resolution?.Value ?? 300,
            Width: area?.Width, Height: area?.Height);
        return new(request, UseOcr, SkipBlank, Straighten, [], SplitMode?.Value ?? SplitAt.None, KeepSeparators, FindPhotos, TabCleanup, OcrLanguage?.Value);
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
        if (_blocked is { } why)
        {
            Message = why;
            Prompt.Announce(why);
            return -1;
        }
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
            _batchKeep = job.KeepSeparators;
            var findPhotos = job.FindPhotos && request.Source == ScanSource.Platen; // photos lie on the glass, not in the feeder
            _pc.PrepareScan(feederBatch: job.Split != SplitAt.None, photosOnGlass: findPhotos); // what made-up scanners then hold
            await foreach (var jpeg in _client.ScanAsync(request, _scanCts.Token))
            {
                var page = new ScanPageViewModel(jpeg, dpi, job.Ocr, job.OcrLanguage);
                page.PropertyChanged += PageChanged;
                Pages.Add(page);
                added.Add(page);
                checks.Add(page.AnalyseAsync(job.SkipBlank, job.Straighten, job.Split, findPhotos, job.Cleanup)); // while the next page scans
                Message = $"Scanned page {Pages.Count}. Scanning…";
            }
            await Task.WhenAll(checks);
            if (request.Source == ScanSource.AdfDuplex) SeparatorBacks(added);
            RefreshFiles();
            var blank = added.Count(p => p.IsSkipped);
            var straightened = added.Count(p => p.Edits.Deskew != 0);
            var separators = added.Count(p => p.IsSeparator);
            var files = Files().Count;
            var photos = added.Sum(p => p.Photos?.Count ?? 0);
            var cleaned = RecordCleanup(added, job.Cleanup);
            var notes = string.Join(" ", new List<string>
            {
                !findPhotos ? "" : photos == 0 ? "No photos were found on the glass: the whole scan is saved. Crop (or the photo view) marks them by hand."
                    : $"{(photos == 1 ? "1 photo" : $"{photos} photos")} found, each saved as its own picture. Check the boxes with the crop button.",
                separators == 0 ? job.Split == SplitAt.None ? "" : "No separator sheets were found: it's one file."
                    : $"{(separators == 1 ? "1 separator sheet" : $"{separators} separator sheets")} found: {(files == 1 ? "1 file" : $"{files} files")}.",
                blank == 0 ? "" : blank == 1 ? "1 blank page is left out (Keep puts it back)." : $"{blank} blank pages are left out (Keep puts them back).",
                straightened == 0 ? "" : straightened == 1 ? "1 page was straightened." : $"{straightened} pages were straightened.",
                cleaned,
                request.Source == ScanSource.AdfDuplex && job.Split is SplitAt.BlankPage or SplitAt.PatchCodeOrBlankPage
                    ? "Scanning both sides: a blank back starts a new file too, so patch code sheets suit two-sided batches better." : "",
                PdfNote(added, request),
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

    /// <summary>
    /// A scan cleaned up by its settings is one step back with Undo, however many pages it has. What to say about it: how many
    /// pages, and any whose paper's edge couldn't be found (they stay whole).
    /// </summary>
    private string RecordCleanup(List<ScanPageViewModel> added, PageFilters cleanup)
    {
        if (cleanup == PageFilters.None) return "";
        var changed = added.Where(p => p.BeforeCleanup is not null).ToList();
        if (changed.Count > 0)
        {
            var before = changed.Select(p => (Page: p, Edits: p.BeforeCleanup!)).ToList();
            History.Record(changed.Count == 1 ? $"Clean up page {changed[0].Number}" : $"Clean up {changed.Count} pages", () =>
            {
                foreach (var (page, edits) in before) page.Edits = page.Edits with { Crop = edits.Crop, Filters = edits.Filters };
            });
        }
        var noEdge = cleanup.HasFlag(PageFilters.CropToPaper) ? changed.Count(p => !p.Edits.Filters.HasFlag(PageFilters.CropToPaper) && !p.HasPhotos) : 0;
        var text = changed.Count == 0 ? "" : changed.Count == 1 ? "1 page was cleaned up (Undo puts it back)." : $"{changed.Count} pages were cleaned up (Undo puts them back).";
        return noEdge == 0 ? text : $"{text} The paper's edge couldn't be told from the lid on {(noEdge == 1 ? "1 page" : $"{noEdge} pages")}: kept whole.";
    }

    /// <summary>
    /// Two-sided scans: the other side of a patch code sheet is part of the sheet (<see cref="BatchSplit.DuplexSeparatorBacks"/>),
    /// so it neither starts the next file nor ends up in it.
    /// </summary>
    private static void SeparatorBacks(List<ScanPageViewModel> added)
    {
        var backs = BatchSplit.DuplexSeparatorBacks([.. added.Select(p => p.Separator.Kind == SeparatorKind.PatchCode)], [.. added.Select(p => p.LooksBlank)]);
        foreach (var back in backs.Select(i => added[i]).Where(p => !p.IsSeparator))
        {
            back.IsSkipped = false;
            back.Separator = new SeparatorFound(SeparatorKind.SheetBack);
            back.Edits = PageEdits.None; // not straightened: it isn't saved (unless separators are kept)
        }
    }

    [RelayCommand]
    private void Cancel()
    {
        _scanCts?.Cancel();
        if (_saveCts is { } save)
        {
            save.Cancel();
            foreach (var page in Pages) page.CancelWork();
        }
    }

    [RelayCommand]
    private void RemovePage(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        if (CropPage == page) CancelCrop();
        var index = Pages.IndexOf(page);
        if (index < 0) return;
        History.Record($"Delete page {page.Number}", () =>
        {
            page.PropertyChanged += PageChanged;
            Pages.Insert(Math.Min(index, Pages.Count), page);
        });
        page.PropertyChanged -= PageChanged;
        Pages.Remove(page);
        Message = $"Deleted page {index + 1}. Undo (Ctrl+Z) puts it back.";
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
        History.Record($"Move page {from + 1}", () =>
        {
            if (Pages.IndexOf(page!) is var at and >= 0 && from < Pages.Count) Pages.Move(at, from);
        });
        Pages.Move(from, index);
        _dirty = true;
        _changes++;
        OnPropertyChanged(nameof(HasUnsavedPages));
        return $"Moved to position {index + 1} of {Pages.Count}";
    }

    /// <summary>Turns the page; a scan of photos on the glass turns every photo instead.</summary>
    [RelayCommand]
    private void RotateLeft(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        RecordLook($"Turn page {page.Number} left", page);
        if (page.HasPhotos) page.Photos = [.. page.Photos!.Select(b => b with { QuarterTurns = (b.QuarterTurns + 3) % 4 })];
        else page.Edits = page.Edits.Turned(-1);
    }

    [RelayCommand]
    private void RotateRight(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        RecordLook($"Turn page {page.Number} right", page);
        if (page.HasPhotos) page.Photos = [.. page.Photos!.Select(b => b with { QuarterTurns = (b.QuarterTurns + 1) % 4 })];
        else page.Edits = page.Edits.Turned(1);
    }

    /// <summary>A page found blank goes back into what's saved.</summary>
    [RelayCommand]
    private void KeepPage(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        RecordRole($"Keep page {page.Number}", page);
        page.IsSkipped = false;
        _ = page.OcrAsync();
    }

    // ---- Crop: an enlarged view of one page (straightened and turned, not cropped) with the crop box drawn on it ----

    /// <summary>The page being cropped; null when the crop view is closed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCropping), nameof(IsAdjustingPage))]
    public partial ScanPageViewModel? CropPage { get; set; }

    [ObservableProperty] public partial BitmapSource? CropImage { get; set; }

    /// <summary>The crop on the page as shown, as fractions of it.</summary>
    [ObservableProperty] public partial CropBox CropBox { get; set; } = CropBox.Full;

    public bool IsCropping => CropPage is not null;

    /// <summary>The crop or photo view is open: it takes the whole pane, the review's toolbar and status line too.</summary>
    public bool IsAdjustingPage => IsCropping || IsEditingPhotos || IsCleaning;

    [RelayCommand]
    private async Task CropAsync(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        CancelClean();
        if (page.FindsPhotos)
        {
            await EditPhotosAsync(page); // a scan of photos: adjust the photos instead
            return;
        }
        CropPage = page;
        CropBox = page.Edits.ShownCrop;
        CropImage = null;
        var edits = page.Edits with { Crop = null };
        try
        {
            // The crop box goes on the page as it is, filters and all, without the wait for a full-size clean up.
            var image = await Task.Run(() => ScanImaging.Render(page.Original, edits, 1600, page.Dpi));
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
        if (CropPage is { } page && page.Edits.WithShownCrop(CropBox) is var cropped && cropped != page.Edits)
        {
            RecordLook($"Crop page {page.Number}", page);
            page.Edits = cropped;
        }
        CancelCrop();
    }

    [RelayCommand]
    private void ResetCrop() => CropBox = CropBox.Full;

    // ---- Clean up: one page, large, with the filters to turn on and off ----

    /// <summary>The page being cleaned up; null when the view is closed.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsCleaning), nameof(IsAdjustingPage), nameof(CleanTitle), nameof(CleansWholePage))]
    public partial ScanPageViewModel? CleanPage { get; set; }

    public bool IsCleaning => CleanPage is not null;

    /// <summary>A scan of photos is cleaned photo by photo: no paper to crop to, no background to whiten.</summary>
    public bool CleansWholePage => CleanPage is { HasPhotos: false };

    public string CleanTitle => CleanPage is not { } page ? "" : page.HasPhotos ? $"Clean up the photos on page {page.Number} (photo 1 shown)" : $"Clean up page {page.Number}";

    [ObservableProperty] public partial BitmapSource? CleanImage { get; set; }

    /// <summary>What the view says about the choices: still working, what a filter found nothing to do on, a page too large.</summary>
    [ObservableProperty] public partial string? CleanStatus { get; set; }

    [ObservableProperty] public partial bool CleanCrop { get; set; }
    [ObservableProperty] public partial bool CleanWhiten { get; set; }
    [ObservableProperty] public partial bool CleanDescreen { get; set; }
    [ObservableProperty] public partial bool CleanRestore { get; set; }

    /// <summary>Held down or on: shows the page as scanned (straightened and turned), to compare.</summary>
    [ObservableProperty] public partial bool ShowOriginal { get; set; }

    private bool _settingCleanChoices;
    private CancellationTokenSource? _cleanCts;

    private PageFilters CleanChoices =>
        (CleanCrop ? PageFilters.CropToPaper : 0) | (CleanWhiten ? PageFilters.Whiten : 0) | (CleanDescreen ? PageFilters.Descreen : 0) | (CleanRestore ? PageFilters.RestoreColors : 0);

    partial void OnCleanCropChanged(bool value) => CleanChoiceChanged();
    partial void OnCleanWhitenChanged(bool value) => CleanChoiceChanged();
    partial void OnCleanDescreenChanged(bool value) => CleanChoiceChanged();
    partial void OnCleanRestoreChanged(bool value) => CleanChoiceChanged();
    partial void OnShowOriginalChanged(bool value) => CleanChoiceChanged();

    private void CleanChoiceChanged()
    {
        if (!_settingCleanChoices && CleanPage is not null) _ = PreviewCleanAsync();
    }

    [RelayCommand]
    private async Task CleanUpAsync(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        CancelCrop();
        CancelPhotos();
        CleanPage = page;
        CleanImage = null;
        _settingCleanChoices = true;
        var filters = page.Edits.Filters;
        (CleanCrop, CleanWhiten, CleanDescreen, CleanRestore) = (filters.HasFlag(PageFilters.CropToPaper), filters.HasFlag(PageFilters.Whiten), filters.HasFlag(PageFilters.Descreen), filters.HasFlag(PageFilters.RestoreColors));
        ShowOriginal = false;
        _settingCleanChoices = false;
        await PreviewCleanAsync();
    }

    /// <summary>The page with what's chosen, drawn off the UI thread at the view's size; a newer choice cancels it.</summary>
    private async Task PreviewCleanAsync()
    {
        if (CleanPage is not { } page) return;
        _cleanCts?.Cancel();
        var cts = _cleanCts = new CancellationTokenSource();
        var choices = ShowOriginal ? PageFilters.None : CleanChoices;
        CleanStatus = "Working…";
        try
        {
            var edits = await page.EditsWithAsync(choices, cts.Token);
            var photos = page.Photos;
            var image = await Task.Run(() => photos is { Count: > 0 } boxes
                ? ScanImaging.PhotoPreview(page.Original, boxes[0], choices, 1600, page.Dpi, cts.Token)
                : ScanImaging.Render(page.Original, edits, 1600, page.Dpi, cts.Token), cts.Token);
            if (CleanPage != page || cts != _cleanCts) return;
            CleanImage = image;
            CleanStatus = ShowOriginal ? "As scanned." : page.CleanNote(choices, edits);
            Prompt.Announce(CleanStatus);
        }
        catch (OperationCanceledException)
        {
            // a newer choice, or the view closed
        }
        catch (Exception ex)
        {
            Log.Write($"Clean up preview failed: {ex}");
            if (cts == _cleanCts) CleanStatus = $"Couldn't show the page: {ex.Message}";
        }
    }

    /// <summary>Done: the page gets what's chosen, one step back with Undo.</summary>
    [RelayCommand]
    private async Task ApplyCleanAsync()
    {
        if (CleanPage is not { } page) return;
        var choices = CleanChoices;
        try
        {
            var edits = await page.EditsWithAsync(choices, default);
            if (edits != page.Edits)
            {
                RecordLook($"Clean up page {page.Number}", page);
                page.Edits = edits;
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Log.Write($"Clean up failed: {ex}");
            Message = $"Couldn't clean up page {page.Number}: {ex.Message}";
        }
        CancelClean();
    }

    /// <summary>What's chosen, on every page that can take it; one step back with Undo.</summary>
    [RelayCommand]
    private async Task ApplyCleanToAllAsync()
    {
        if (CleanPage is null) return;
        var choices = CleanChoices;
        var targets = Pages.Where(p => !p.IsSeparator && !p.IsSkipped).ToList();
        CleanStatus = "Working…";
        var results = new List<(ScanPageViewModel Page, PageEdits Before, PageEdits After)>();
        foreach (var page in targets)
        {
            var edits = await page.EditsWithAsync(choices, default);
            if (edits != page.Edits) results.Add((page, page.Edits, edits));
        }
        if (results.Count > 0)
        {
            History.Record($"Clean up {results.Count} pages", () =>
            {
                foreach (var (page, before, _) in results) page.Edits = before;
            });
            foreach (var (page, _, after) in results) page.Edits = after;
        }
        CancelClean();
        Message = results.Count == 1 ? "1 page was cleaned up (Undo puts it back)." : $"{results.Count} pages were cleaned up (Undo puts them back).";
        Prompt.Announce(Message);
    }

    [RelayCommand]
    private void CancelClean()
    {
        _cleanCts?.Cancel();
        _cleanCts = null;
        CleanPage = null;
        CleanImage = null;
        CleanStatus = null;
    }

    [RelayCommand]
    private void CancelCrop()
    {
        CropPage = null;
        CropImage = null;
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void Clear()
    {
        using var hold = HoldRestore();
        if (HasUnsavedPages && !Prompt.Ask($"Discard {(Pages.Count == 1 ? "1 page" : $"{Pages.Count} pages")} you haven't saved?", "Discard")) return;
        DropPages();
    }

    /// <summary>
    /// Pages a run of Inkvolt Print left unsaved (it crashed, was ended, or Windows signed out), put back as they were in the
    /// review: added after any pages here, unsaved.
    /// </summary>
    public void Restore(IReadOnlyList<(byte[] Jpeg, KeptPage Kept)> pages)
    {
        CancelCrop();
        CancelPhotos();
        CancelClean();
        foreach (var (jpeg, kept) in pages)
        {
            var page = new ScanPageViewModel(jpeg, kept.Dpi, kept.Ocr, kept.OcrLanguage) { Edits = kept.Edits, IsSkipped = kept.Skipped, StartsFile = kept.StartsFile, IsAnalysed = true };
            page.PropertyChanged += PageChanged;
            Pages.Add(page);
        }
        RefreshFiles();
        Message = pages.Count == 1
            ? "Restored 1 scanned page that wasn't saved when Inkvolt Print closed."
            : $"Restored {pages.Count} scanned pages that weren't saved when Inkvolt Print closed.";
        Prompt.Announce(Message);
    }

    private void DropPages()
    {
        CancelCrop();
        CancelPhotos();
        CancelClean();
        foreach (var page in Pages) page.PropertyChanged -= PageChanged;
        Pages.Clear();
        History.Clear(); // the question before it was the safeguard
        Message = null;
        LastSavedPath = null;
        ActivePreset = null;
    }

    /// <param name="format">"pdf" (default) or "jpg".</param>
    [RelayCommand(CanExecute = nameof(CanSave))]
    private async Task SaveAsync(string? format)
    {
        using var hold = HoldRestore();
        var changes = _changes;
        var jpg = format == "jpg";
        var folder = _state.ScanFolder is { } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var files = Files();
        var dialog = new SaveFileDialog
        {
            Title = files.Count > 1 ? $"Save scan as {files.Count} {(jpg ? "sets of images" : "PDFs")} (numbered)" : jpg ? "Save scan as images" : "Save scan as PDF",
            InitialDirectory = folder,
            FileName = $"Scan {DateTime.Now:yyyy-MM-dd HHmm}",
            Filter = jpg ? "JPEG image (*.jpg)|*.jpg" : "PDF document (*.pdf)|*.pdf",
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        _state.ScanFolder = Path.GetDirectoryName(dialog.FileName);
        _state.Save();

        var targets = Targets(dialog.FileName, [.. files.Select(f => f.Sum(p => p.ImageCount))], jpg);
        var all = targets.SelectMany(t => t).ToList();
        // The dialog already asked about the name typed; numbered files (images, several PDFs) are siblings it never saw.
        if (all.Count > 1 && all.Where(t => t != dialog.FileName && File.Exists(t)).ToList() is { Count: > 0 } clobbered &&
            !Prompt.Ask($"{clobbered.Count} file{(clobbered.Count == 1 ? "" : "s")} like \"{Path.GetFileName(clobbered[0])}\" already exist. Replace them?", "Replace"))
            return;

        CancelCrop();
        CancelPhotos();
        CancelClean();
        IsBusy = true;
        BeginSave();
        try
        {
            for (var n = 0; n < files.Count; n++)
            {
                if (jpg)
                {
                    var k = 0;
                    foreach (var page in files[n])
                        foreach (var image in await page.ImagesAsync()) await File.WriteAllBytesAsync(targets[n][k++], image);
                    continue;
                }
                var asSent = ScannerPdf.KeepAsSent(ToSave(files[n]));
                var pages = asSent is null ? await PdfPagesAsync(files[n]) : null;
                var target = targets[n][0];
                var title = Path.GetFileNameWithoutExtension(target);
                await Task.Run(() =>
                {
                    var tmp = target + ".partial";
                    using (var fs = File.Create(tmp))
                        if (asSent is not null) fs.Write(asSent); // the scanner's own PDF, as it sent it
                        else PdfWriter.Write(fs, pages!, title);
                    File.Move(tmp, target, overwrite: true); // never leave a half-written PDF behind
                });
            }
            LastSavedPath = all[0];
            _savedPdfs = jpg ? [] : all;
            MarkSaved(changes);
            Message = $"Saved {Path.GetFileName(LastSavedPath)}{(all.Count > 1 ? $" and {all.Count - 1} more" : "")}{(files.Count > 1 ? $" ({files.Count} {(jpg ? "sets" : "files")})" : "")}."
                      + (jpg ? "" : AsSentNote(files));
            RatingRequest.NoteSuccess(_state);
            if (!jpg && OpenInInkvoltPdf && InkvoltPdfInstalled) OpenSavedInInkvoltPdf();
        }
        catch (OperationCanceledException)
        {
            Message = "Save cancelled.";
        }
        catch (Exception ex)
        {
            Log.Write($"Save failed: {ex}");
            Message = $"Could not save: {ex.Message}";
        }
        finally
        {
            EndSave();
            IsBusy = false;
        }
    }

    private void BeginSave()
    {
        _saveCts = new CancellationTokenSource();
        IsSaving = true;
    }

    private void EndSave()
    {
        IsSaving = false;
        _saveCts?.Dispose();
        _saveCts = null;
    }

    /// <summary>What <see cref="ScannerPdf.KeepAsSent"/> needs to know of a file's pages: where each came from, and whether it changed.</summary>
    private static List<PageToSave> ToSave(List<ScanPageViewModel> file) =>
        [.. file.Select(p => new PageToSave(p.FromPdf, p.IsEdited || p.HasPhotos || p.Ocr))];

    /// <summary>After a PDF save from a scanner that sends PDF: whether the files are its own PDF, and if not, why.</summary>
    private static string AsSentNote(List<List<ScanPageViewModel>> files)
    {
        var plans = files.Select(ToSave).Where(f => f.Any(p => p.Origin is not null)).ToList();
        if (plans.Count == 0) return "";
        if (plans.All(f => ScannerPdf.KeepAsSent(f) is not null))
            return plans.Count == 1 ? " It is the scanner's own PDF, as it sent it." : " They are the scanner's own PDFs, as it sent them.";
        return " " + plans.Select(ScannerPdf.WhyNotAsSent).OfType<string>().First();
    }

    /// <summary>After a scan from a source that sends only PDF: what that means, in words.</summary>
    private static string PdfNote(List<ScanPageViewModel> added, ScanRequest request)
    {
        if (added.FirstOrDefault(p => p.FromPdf is not null)?.FromPdf is not { } origin) return "";
        var from = request.Source == ScanSource.Platen ? "the glass" : "the feeder";
        return origin.Rendered
            ? $"This scanner sends PDF from {from}: its pages were drawn as pictures at {request.Resolution} dpi for the review."
            : $"This scanner sends PDF from {from}: its pictures were taken out as they came, so the review, text recognition and presets work as usual.";
    }

    /// <summary>The PDF's pages: each page with its text layer, or for a scan of photos on the glass, each photo (no text).</summary>
    private async Task<List<PdfPage>> PdfPagesAsync(List<ScanPageViewModel> kept)
    {
        if (kept.Any(p => !p.HasPhotos && !p.OcrAsync().IsCompleted)) Message = "Finishing text recognition…";
        var pages = new List<PdfPage>();
        foreach (var p in kept)
        {
            if (p.HasPhotos) pages.AddRange((await p.ImagesAsync()).Select(jpeg => new PdfPage(jpeg, p.Dpi)));
            else pages.Add(new PdfPage(await p.JpegAsync(), p.Dpi, await p.OcrAsync()));
        }
        return pages;
    }

    private static List<string> ImagePaths(string chosen, int count)
    {
        if (count == 1) return [chosen];
        var dir = Path.GetDirectoryName(chosen)!;
        var stem = Path.GetFileNameWithoutExtension(chosen);
        return Enumerable.Range(1, count).Select(i => Path.Combine(dir, $"{stem} ({i}).jpg")).ToList();
    }

    /// <summary>
    /// Where each file's pages go: one file is saved as chosen (images numbered "(1)", "(2)"…); several are numbered after the
    /// chosen name, "Scan (1).pdf", "Scan (2).pdf", or for images "Scan (2-1).jpg", "Scan (2-2).jpg"…
    /// </summary>
    /// <param name="images">How many images each file has (pages, or photos cut out of a page).</param>
    private static List<List<string>> Targets(string chosen, List<int> images, bool jpg)
    {
        if (images.Count == 1) return [jpg ? ImagePaths(chosen, images[0]) : [chosen]];
        var dir = Path.GetDirectoryName(chosen)!;
        var stem = Path.GetFileNameWithoutExtension(chosen);
        return [.. images.Select((count, f) => jpg
            ? count == 1 ? [Path.Combine(dir, $"{stem} ({f + 1}).jpg")] : Enumerable.Range(1, count).Select(i => Path.Combine(dir, $"{stem} ({f + 1}-{i}).jpg")).ToList()
            : new List<string> { Path.Combine(dir, $"{stem} ({f + 1}).pdf") })];
    }

    /// <summary>Every PDF the last save wrote (a batch: one per file), for Open in Inkvolt PDF.</summary>
    private List<string> _savedPdfs = [];

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
        // A batch saved as several PDFs opens them all (Inkvolt PDF puts each in a tab of the window already open).
        foreach (var pdf in _savedPdfs.Contains(LastSavedPath) ? _savedPdfs : [LastSavedPath])
            if (!InkvoltApps.Launch(InkvoltApps.InkvoltPdf, pdf))
            {
                Message = "Inkvolt PDF couldn't be started.";
                return;
            }
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
        return new(plan.Request, plan.Ocr, preset.SkipBlank, preset.Straighten, plan.Notes, preset.SplitAt, preset.KeepSeparators, preset.FindPhotos, preset.Cleanup, preset.OcrLanguage);
    }

    /// <summary>One click: scan with the preset, then save it to its folder (unless it stops on the review first).</summary>
    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task RunPresetAsync(ScanPreset? preset)
    {
        if (preset is null || IsBusy) return;
        preset = _presets.Find(preset.Id) ?? preset;
        using (HoldRestore())
        {
            if (HasUnsavedPages && !Prompt.Ask(
                    $"Discard {(Pages.Count == 1 ? "1 page" : $"{Pages.Count} pages")} you haven't saved and scan with \"{preset.Name}\"?", "Discard and scan"))
                return;
            DropPages();
        }
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
        var preset = _presets.FindById(active.Id) ?? active; // edited meanwhile, or deleted (then saved as it was)
        var changes = _changes;
        var files = Files();
        var kept = files.SelectMany(f => f).ToList();
        if (kept.Count == 0)
        {
            Message = Pages.Any(p => p.IsSeparator)
                ? "No pages to save: every page was left out as blank or as a separator sheet."
                : "No pages to save: every page was left out as blank. Keep puts a page back.";
            return;
        }
        if (_presets.Folder(preset, out var problem) is not { } root)
        {
            Message = problem;
            return;
        }
        CancelCrop();
        CancelPhotos();
        CancelClean();
        IsBusy = true;
        BeginSave();
        var saved = new List<string>();
        var before = new List<string>(); // written by an earlier save that failed part-way: not written again
        var done = 0;
        var jpg = preset.FileType == PresetFileType.Jpeg;
        try
        {
            string? folder = null;
            var now = DateTime.Now;
            var numbers = new PartNumbers(preset.NextNumber);
            foreach (var file in files)
            {
                if (_savedParts.Find(file) is { } earlier)
                {
                    saved.AddRange(earlier);
                    before.AddRange(earlier);
                    done++;
                    continue;
                }
                // {n} is taken now, in one step on the UI thread, so a scan saved meanwhile (another printer) can't get it too;
                // a batch takes one per file (counting on by itself if the preset was deleted meanwhile), and {pages} is each file's own.
                var number = numbers.Take(_presets.IncrementCounter(preset.Id));
                var ctx = new NameContext(now, preset.Name, _printerName, number, file.Sum(p => p.ImageCount));
                var into = Path.Combine(root, FileNameTemplate.Subfolder(preset.Subfolder, ctx));
                folder ??= into;
                Directory.CreateDirectory(into);
                var stem = FileNameTemplate.FileName(preset.FileName, ctx);
                var asSent = jpg ? null : ScannerPdf.KeepAsSent(ToSave(file));
                List<string> written = jpg ? await WriteImagesAsync(file, into, stem)
                    : [await WritePdfAsync(asSent is null ? await PdfPagesAsync(file) : null, asSent, into, stem)];
                _savedParts.Add(file, written);
                saved.AddRange(written);
                done++;
            }
            _savedParts.Clear(); // all saved: a deliberate Save again writes everything again
            folder ??= Path.GetDirectoryName(saved[0]);

            ActivePreset = _presets.FindById(preset.Id) ?? preset;
            LastSavedPath = saved[0];
            _savedPdfs = jpg ? [] : saved;
            MarkSaved(changes);
            Message = $"Saved {Path.GetFileName(saved[0])}{(saved.Count > 1 ? $" and {saved.Count - 1} more" : "")}"
                + $"{(files.Count > 1 ? $" ({files.Count} {(jpg ? "sets" : "files")})" : "")} in {folder}."
                + (before.Count == 0 ? "" : $" Already saved the first time, not written again: {string.Join(", ", before.Select(Path.GetFileName))}.")
                + (jpg ? "" : AsSentNote(files))
                + string.Concat(_presetNotes.Select(n => " " + n));
            Prompt.Announce(Message);
            RatingRequest.NoteSuccess(_state);
        }
        catch (OperationCanceledException)
        {
            Message = "Save cancelled.";
            return;
        }
        catch (Exception ex)
        {
            Log.Write($"Preset save failed: {ex}");
            Message = saved.Count == 0 ? $"Could not save: {ex.Message}"
                : $"Saved {done} of {files.Count} files ({string.Join(", ", saved.Select(Path.GetFileName))}), then could not save file {done + 1}: {ex.Message} "
                  + "Save again saves only the files not saved yet.";
            if (saved.Count > 0) LastSavedPath = saved[0];
            return;
        }
        finally
        {
            EndSave();
            IsBusy = false;
        }
        // Not busy any more: a mail app's new-message window (classic Outlook's stays open until it's sent) doesn't hold up the tab.
        await AfterSaveAsync(preset, saved, kept, jpg);
    }

    /// <summary>Files of this batch a preset save wrote before failing part-way: Save again writes only the others.</summary>
    private readonly SavedParts<ScanPageViewModel> _savedParts = new();

    /// <summary>File.Move that never replaces: false when <paramref name="to"/> exists.</summary>
    private static bool TryMove(string from, string to)
    {
        try
        {
            File.Move(from, to, overwrite: false);
            return true;
        }
        catch (IOException) when (File.Exists(to))
        {
            return false;
        }
    }

    /// <summary>
    /// Writes the PDF next to its final name, then moves it there only if that name is still free (else the next one): made from
    /// <paramref name="pages"/>, or the scanner's own PDF <paramref name="asSent"/> as it is.
    /// </summary>
    private static Task<string> WritePdfAsync(List<PdfPage>? pages, byte[]? asSent, string folder, string stem) => Task.Run(() =>
    {
        var tmp = TempName(folder);
        try
        {
            using (var fs = File.Create(tmp))
                if (asSent is not null) fs.Write(asSent);
                else PdfWriter.Write(fs, pages!, stem);
            return FileNameTemplate.PlaceSet([tmp], folder, stem, ".pdf", File.Exists, TryMove)[0];
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    });

    /// <summary>Writes every image under a temporary name first, then names them as one set (<see cref="FileNameTemplate.PlaceSet"/>).</summary>
    private static async Task<List<string>> WriteImagesAsync(List<ScanPageViewModel> kept, string folder, string stem)
    {
        var temps = new List<string>();
        try
        {
            foreach (var page in kept)
                foreach (var image in await page.ImagesAsync())
                {
                    var tmp = TempName(folder);
                    temps.Add(tmp);
                    await File.WriteAllBytesAsync(tmp, image);
                }
            return [.. await Task.Run(() => FileNameTemplate.PlaceSet(temps, folder, stem, ".jpg", File.Exists, TryMove))];
        }
        finally
        {
            foreach (var tmp in temps.Where(File.Exists)) File.Delete(tmp); // only left over when something failed
        }
    }

    private static string TempName(string folder) => Path.Combine(folder, $"~inkvolt-{Guid.NewGuid():N}.partial");

    /// <summary>The preset's step after saving: open in Inkvolt PDF, print a copy, or hand the file to the mail app.</summary>
    private async Task AfterSaveAsync(ScanPreset preset, List<string> saved, List<ScanPageViewModel> kept, bool jpg)
    {
        var demo = !_pc.OpensOtherApps; // the made-up PC's scans only say what would happen
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
                var before = Message;
                var said = Message += " Opening a new message in your mail app…";
                var note = await MailHandoff.SendAsync(saved, Path.GetFileNameWithoutExtension(saved[0])) switch
                {
                    MailHandoff.Result.Attached => " The file was attached to a new message in your mail app.",
                    MailHandoff.Result.Cancelled => " The email was cancelled; the file is saved.",
                    _ => saved.Count == 1
                        ? " Your mail app can't take attachments from other apps, so a new message and the file's folder opened: attach the selected file to the message (drag it in)."
                        : $" Your mail app can't take attachments from other apps, so a new message and the files' folder opened: attach the {saved.Count} files to the message (drag them in).",
                };
                // The tab may have moved on (another scan) while the message window was open: don't write over that.
                if (Message == said) Message = before + note;
                break;
        }
    }

    /// <summary>Prints the saved pages through this printer's Windows queue at actual size (like a copy).</summary>
    private async Task PrintCopyAsync(string file, List<ScanPageViewModel> kept)
    {
        var name = Path.GetFileName(file);
        if (_pc.MadeUpPrint is { } madeUp)
        {
            madeUp(name, kept.Sum(p => p.ImageCount));
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
                foreach (var jpeg in await p.ImagesAsync())
                {
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
    private CancellationTokenSource _work = new();

    public ScanPageViewModel(byte[] jpeg, int dpi, bool ocr, string? ocrLanguage = null)
    {
        Original = jpeg;
        Dpi = dpi;
        _ocr = ocr;
        OcrLanguage = ocrLanguage;
        FromPdf = ScannerPdf.OriginOf(jpeg);
        try
        {
            var (w, h, _) = PdfWriter.JpegInfo(jpeg);
            _size = (w, h);
        }
        catch (FormatException)
        {
            _size = (8 * dpi, 11 * dpi); // unreadable header: the save says so later; a letter page for the checks meanwhile
        }
        Thumbnail = ScanImaging.Render(jpeg, PageEdits.None, ThumbnailWidth);
    }

    public byte[] Original { get; }
    public int Dpi { get; }

    /// <summary>The scanner's PDF this page came out of (a scanner that sends only PDF), or null for a JPEG page.</summary>
    public PdfOrigin? FromPdf { get; }

    /// <summary>Gets an OCR text layer when saved as PDF.</summary>
    public bool Ocr => _ocr;

    /// <summary>The language to read it in; null: Windows' first display language that has OCR.</summary>
    public string? OcrLanguage { get; }

    /// <summary>What the page's look was before the scan's settings cleaned it up; null when they didn't.</summary>
    public PageEdits? BeforeCleanup { get; private set; }

    /// <summary>A save was cancelled: what's being encoded stops, and the next save starts it again.</summary>
    public void CancelWork()
    {
        _work.Cancel();
        _work = new CancellationTokenSource();
    }

    /// <summary>The page's edits with <paramref name="filters"/> in place of its filters; the paper's edge is looked for when asked for and not found yet.</summary>
    public async Task<PageEdits> EditsWithAsync(PageFilters filters, CancellationToken cancel)
    {
        var edits = Edits;
        var photos = HasPhotos;
        var wantsCrop = filters.HasFlag(PageFilters.CropToPaper) && !photos;
        if (wantsCrop == edits.Filters.HasFlag(PageFilters.CropToPaper))
            return edits with { Filters = (filters & PageFilters.PixelFilters) | (wantsCrop ? PageFilters.CropToPaper : 0) };
        if (!wantsCrop) return edits with { Crop = null, Filters = filters & PageFilters.PixelFilters };
        var (original, dpi, width, deskew) = (Original, Dpi, _size.Width, edits.Deskew);
        var crop = await Task.Run(() =>
        {
            var image = ScanImaging.Analysis(original);
            return PaperEdge.Find(image, image.Width * (double)dpi / width, deskew);
        }, cancel);
        // No edge found: what was there stays, and the view says so.
        return crop is { } found
            ? edits with { Crop = found, Filters = (filters & PageFilters.PixelFilters) | PageFilters.CropToPaper }
            : edits with { Filters = filters & PageFilters.PixelFilters };
    }

    /// <summary>What the clean up view says after drawing <paramref name="edits"/> for <paramref name="wanted"/>.</summary>
    public string CleanNote(PageFilters wanted, PageEdits edits)
    {
        if (PageCleanup.TooLarge(_size.Width, _size.Height) && (wanted & PageFilters.PixelFilters) != 0)
            return $"This page is too large to clean up ({(long)_size.Width * _size.Height / 1_000_000} million pixels): it is saved as scanned.";
        if (wanted.HasFlag(PageFilters.CropToPaper) && !edits.Filters.HasFlag(PageFilters.CropToPaper) && !HasPhotos)
            return "The paper's edge can't be told from the lid here (a white sheet on a white lid, a page printed to its edges): the page is kept whole.";
        return wanted == PageFilters.None ? "As scanned." : $"Shown {PageCleanup.Describe(wanted)}.";
    }

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

    /// <summary>A separator sheet (batch scanning): a new file starts after it; left out unless the batch keeps separators.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsSeparator), nameof(SeparatorText), nameof(Label), nameof(Note))]
    public partial SeparatorFound Separator { get; set; } = SeparatorFound.None;

    public bool IsSeparator => Separator.IsSeparator;

    /// <summary>A new file starts with this page (set in the review).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Label), nameof(FileStartMenuText))]
    public partial bool StartsFile { get; set; }

    /// <summary>The file (1-based) this page is the first of when the pages are saved as several; 0 otherwise. Set by the list.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Label), nameof(ShowsFileStart), nameof(FileStartText))]
    public partial int FileStart { get; set; }

    /// <summary>The batch keeps its separator sheets (set by the list).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SeparatorStatus), nameof(Label), nameof(Note))]
    public partial bool SeparatorKept { get; set; }

    /// <summary>Found blank by the checks (whether or not it's left out).</summary>
    public bool LooksBlank { get; private set; }

    public bool ShowsFileStart => FileStart > 0;
    public string FileStartText => $"File {FileStart}";
    public string FileStartMenuText => StartsFile ? "Don't start a new file here" : "Start a new file here";

    /// <summary>"Separator: Patch T sheet" over the thumbnail.</summary>
    public string SeparatorText => IsSeparator ? $"Separator: {Separator.Description}" : "";

    public string SeparatorStatus => SeparatorKept ? "Kept: first page of the next file" : "Won't be saved";

    public BatchPage AsBatchPage => new(IsSeparator, StartsFile, IsSkipped);

    /// <summary>
    /// A scan of photos on the glass: the photos found (and adjusted in the review), each saved as its own picture instead of
    /// the page. Null when the page wasn't looked at for photos; empty when none were found (the page is saved whole).
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPhotos), nameof(FindsPhotos), nameof(ImageCount), nameof(Note), nameof(Label), nameof(CropText))]
    public partial IReadOnlyList<PhotoBox>? Photos { get; set; }

    public bool HasPhotos => Photos is { Count: > 0 };

    /// <summary>The crop button's name: a scan of photos adjusts its photos instead.</summary>
    public string CropText => FindsPhotos ? "Adjust photos" : "Crop page";
    public bool FindsPhotos => Photos is not null;

    /// <summary>The pictures this page saves as: one, or one per photo.</summary>
    public int ImageCount => HasPhotos ? Photos!.Count : 1;

    /// <summary>The scan's size in inches.</summary>
    public double WidthInches => _size.Width / (double)Dpi;
    public double HeightInches => _size.Height / (double)Dpi;
    private (int Width, int Height) _size;

    partial void OnPhotosChanged(IReadOnlyList<PhotoBox>? value) => _ = RefreshThumbnailAsync(Edits);

    private (IReadOnlyList<PhotoBox> Photos, PageFilters Filters, Task<IReadOnlyList<byte[]>> Images)? _images;

    /// <summary>The pictures as saved: the page's JPEG, or each photo cut out straight (encoded once per set of boxes).</summary>
    public async Task<IReadOnlyList<byte[]>> ImagesAsync()
    {
        if (Photos is not { Count: > 0 } photos) return [await JpegAsync()];
        var filters = Edits.Filters & (PageFilters.Descreen | PageFilters.RestoreColors);
        if (_images is { } cached && ReferenceEquals(cached.Photos, photos) && cached.Filters == filters && !cached.Images.IsFaulted && !cached.Images.IsCanceled) return await cached.Images;
        var (original, dpi, cancel) = (Original, Dpi, _work.Token);
        var task = Task.Run(() => (IReadOnlyList<byte[]>)ScanImaging.Photos(original, photos, filters, dpi, cancel), cancel);
        _images = (photos, filters, task);
        return await task;
    }

    /// <summary>The photos on a scan of the glass (decodes the analysis copy).</summary>
    public static List<PhotoBox> FindPhotosOn(byte[] jpeg, int dpi)
    {
        var image = ScanImaging.Analysis(jpeg);
        return PhotoFinder.Find(image, image.Width * (double)dpi / PdfWriter.JpegInfo(jpeg).Width);
    }

    public bool IsEdited => !Edits.IsEmpty;

    /// <summary>Screen reader name: "Page 2", "Page 3, straightened", "Page 4, blank, not saved", "Page 5, starts file 2".</summary>
    public string Label
    {
        get
        {
            var label = IsSeparator ? $"Page {Number}, separator: {Separator.Description}, {(SeparatorKept ? "kept" : "not saved")}"
                : Note.Length == 0 ? $"Page {Number}" : $"Page {Number}, {Note.ToLowerInvariant()}";
            return FileStart > 0 ? $"{label}, starts file {FileStart}" : label;
        }
    }

    /// <summary>What happened to the page, under its number: "Straightened", "Edited", "Blank, not saved", or nothing.</summary>
    public string Note => IsSeparator ? (SeparatorKept ? "Separator, kept" : "Separator, not saved")
        : IsSkipped ? "Blank, not saved"
        : HasPhotos ? (Photos!.Count == 1 ? "1 photo" : $"{Photos.Count} photos") + (Edits.Filters != PageFilters.None ? $", {PageCleanup.Describe(Edits.Filters)}" : "")
        : FindsPhotos ? "No photos found"
        : Edits.Filters != PageFilters.None ? Capitalized(PageCleanup.Describe(Edits.Filters))
        : Edits.Deskew != 0 && Edits.Crop is null && Edits.QuarterTurns % 4 == 0 ? "Straightened" : IsEdited ? "Edited" : "";

    private static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    partial void OnEditsChanged(PageEdits value) => _ = RefreshThumbnailAsync(value);

    /// <summary>The page as saved: the scanner's JPEG, or the edited page encoded once per set of edits.</summary>
    public Task<byte[]> JpegAsync()
    {
        var edits = Edits;
        if (edits.IsEmpty) return Task.FromResult(Original);
        if (_jpeg is { } cached && cached.Edits == edits && !cached.Jpeg.IsFaulted && !cached.Jpeg.IsCanceled) return cached.Jpeg;
        var (original, dpi, cancel) = (Original, Dpi, _work.Token);
        var task = Task.Run(() => ScanImaging.Jpeg(ScanImaging.Render(original, edits, 0, dpi, cancel)), cancel);
        _jpeg = (edits, task);
        return task;
    }

    /// <summary>Recognised text for the page as saved (null: OCR off or failed; the page still saves).</summary>
    public Task<IReadOnlyList<OcrWord>?> OcrAsync()
    {
        if (!_ocr) return Task.FromResult<IReadOnlyList<OcrWord>?>(null);
        var edits = Edits;
        if (_words is { } cached && cached.Edits == edits && !cached.Words.IsCanceled) return cached.Words;
        var task = RunOcrAsync(JpegAsync(), Dpi, OcrLanguage);
        _words = (edits, task);
        return task;
    }

    /// <summary>
    /// Separator, blank and skew checks, then OCR in the background (on the straightened page when it was straightened).
    /// A separator sheet is neither skipped nor straightened.
    /// </summary>
    /// <param name="findPhotos">A scan of photos on the glass: find them (each is saved by itself), don't straighten the page.</param>
    /// <param name="cleanup">What the scan's settings clean each page up with (a blank page or separator stays as it came, a scan of photos gets what suits a print).</param>
    public async Task AnalyseAsync(bool skipBlank, bool straighten, SplitAt split = SplitAt.None, bool findPhotos = false, PageFilters cleanup = PageFilters.None)
    {
        try
        {
            if (skipBlank || straighten || split != SplitAt.None || findPhotos || cleanup != PageFilters.None)
            {
                var (blank, angle, separator, looksBlank, photos, crop) = await Task.Run(() =>
                {
                    var image = ScanImaging.Analysis(Original);
                    var ppi = image.Width * (double)Dpi / _size.Width;
                    var separator = Separators.Detect(image, ppi, split);
                    var looksBlank = separator.Kind == SeparatorKind.BlankPage || BlankPage.IsBlank(image);
                    var isBlank = skipBlank && looksBlank && !separator.IsSeparator;
                    var photos = findPhotos && !isBlank && !separator.IsSeparator ? PhotoFinder.Find(image, ppi) : null;
                    var angle = straighten && !isBlank && !separator.IsSeparator && photos is null ? Deskew.Angle(image) : 0;
                    var crop = cleanup.HasFlag(PageFilters.CropToPaper) && !isBlank && !looksBlank && !separator.IsSeparator && photos is null ? PaperEdge.Find(image, ppi, angle) : null;
                    return (isBlank, angle, separator, looksBlank, photos, crop);
                });
                LooksBlank = looksBlank;
                Separator = separator;
                IsSkipped = blank;
                if (photos is not null) Photos = photos;
                if (angle != 0 && Edits.IsEmpty) Edits = PageEdits.None with { Deskew = angle };
                if (cleanup != PageFilters.None && !blank && !looksBlank && !separator.IsSeparator && Edits.Filters == PageFilters.None && Edits.Crop is null)
                {
                    var filters = cleanup & (photos is { Count: > 0 } ? PageFilters.Descreen | PageFilters.RestoreColors : PageFilters.PixelFilters);
                    if (crop is not null) filters |= PageFilters.CropToPaper;
                    if (filters != PageFilters.None)
                    {
                        BeforeCleanup = Edits;
                        Edits = Edits with { Crop = crop, Filters = filters };
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Page check failed: {ex.Message}"); // the page stays as scanned
        }
        IsAnalysed = true;
        if (!IsSkipped && !IsSeparator && !HasPhotos) _ = OcrAsync();
    }

    private async Task RefreshThumbnailAsync(PageEdits edits)
    {
        try
        {
            var photos = Photos;
            var thumbnail = await Task.Run(() => ScanImaging.Render(Original, photos is { Count: > 0 } ? PageEdits.None : edits, ThumbnailWidth, Dpi));
            // A later edit's thumbnail wins; photos are drawn over the scan as found (on the UI thread: it's drawing).
            if (edits == Edits && ReferenceEquals(photos, Photos)) Thumbnail = photos is { Count: > 0 } ? ScanImaging.WithPhotos(thumbnail, photos) : thumbnail;
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Thumbnail failed: {ex.Message}");
        }
    }

    private static async Task<IReadOnlyList<OcrWord>?> RunOcrAsync(Task<byte[]> jpeg, int dpi, string? language)
    {
        try
        {
            var bytes = await jpeg;
            return await Task.Run(() => WindowsOcr.RecognizeAsync(bytes, dpi, default, language));
        }
        catch (OperationCanceledException)
        {
            throw; // the save was cancelled: not an answer to keep
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"OCR failed: {ex.Message}");
            return null; // page still saves, just without a text layer
        }
    }
}
