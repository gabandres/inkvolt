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
        [new Option<string?>(null, Strings.Scan_OcrWindowsLanguage), .. WindowsRecognizer.Languages().Select(l => new Option<string?>(l.Tag, l.Name))];
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

    // Built when asked for, not once: the labels are in the interface's language.
    private static Option<ScanArea>[] AllPageSizes =>
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
            <= 150 => string.Format(Strings.Scan_ResolutionDraft, r),
            <= 200 => string.Format(Strings.Scan_ResolutionScreen, r),
            <= 300 => string.Format(Strings.Scan_ResolutionDocuments, r),
            _ => string.Format(Strings.Scan_ResolutionPhotos, r),
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
    public string UndoText => History.Next is { } next ? string.Format(Strings.Scan_UndoWhat, $"{char.ToLowerInvariant(next[0])}{next[1..]}") : Strings.Scan_UndoNothing;

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
            Message = string.Format(Strings.Scan_Undone, what);
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
            if (EditedPhotos.Count == 0) return Strings.Scan_PhotosNoneMarked;
            if (SelectedPhoto < 0 || SelectedPhoto >= EditedPhotos.Count)
                return Plural.Of(EditedPhotos.Count, Strings.Scan_PhotosSaved_One, Strings.Scan_PhotosSaved_Many);
            var b = EditedPhotos[SelectedPhoto];
            var inches = page.WidthInches;
            return string.Format(CultureInfo.CurrentCulture, b.QuarterTurns % 4 == 0 ? Strings.Scan_PhotoStatus : Strings.Scan_PhotoStatusTurned,
                SelectedPhoto + 1, EditedPhotos.Count, b.Width * inches, b.Height * inches, b.Angle, 90 * b.QuarterTurns);
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
            Message = string.Format(Strings.Scan_CouldntShowScan, ex.Message);
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
        Prompt.Announce(string.Format(Strings.Scan_PhotoAdded, EditedPhotos.Count));
    }

    private bool HasSelectedPhoto() => SelectedPhoto >= 0 && SelectedPhoto < EditedPhotos.Count;

    [RelayCommand(CanExecute = nameof(HasSelectedPhoto))]
    private void RemovePhoto()
    {
        if (!HasSelectedPhoto()) return;
        var removed = SelectedPhoto;
        EditedPhotos.RemoveAt(removed);
        SelectedPhoto = Math.Min(removed, EditedPhotos.Count - 1);
        Prompt.Announce(string.Format(Strings.Scan_PhotoRemoved, removed + 1, EditedPhotos.Count));
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
        Prompt.Announce(Plural.Of(found.Count, Strings.Scan_PhotosFound_One, Strings.Scan_PhotosFound_Many));
    }

    [RelayCommand]
    private void ApplyPhotos()
    {
        if (PhotoPage is { } page)
        {
            RecordLook(string.Format(Strings.Scan_UndoChangePhotos, page.Number), page);
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
            var text = kept == 0 ? Pages.Count == 0 ? Strings.Scan_NoPagesYet : Strings.Scan_NoPagesToSave
                : files.Count > 1 ? Plural.Of(kept, Strings.Scan_PagesInFiles_One, Strings.Scan_PagesInFiles_Many, files.Count)
                : Plural.Of(kept, Strings.Scan_Pages_One, Strings.Scan_Pages_Many);
            var photos = files.Sum(f => f.Sum(p => p.HasPhotos ? p.Photos!.Count : 0));
            if (photos > 0) text = string.Format(Strings.Scan_CountWithPhotos, text, Plural.Of(photos, Strings.Scan_Photos_One, Strings.Scan_Photos_Many));
            var skipped = Pages.Count(p => p.IsSkipped && !p.IsSeparator);
            var separators = _batchKeep ? 0 : Pages.Count(p => p.IsSeparator);
            if (separators > 0) text += "  ·  " + Plural.Of(separators, Strings.Scan_SeparatorsLeftOut_One, Strings.Scan_SeparatorsLeftOut_Many);
            return skipped == 0 ? text : text + "  ·  " + Plural.Of(skipped, Strings.Scan_BlankLeftOut_One, Strings.Scan_BlankLeftOut_Many);
        }
    }

    public string ScanButtonText => HasPages ? Strings.Scan_ScanMorePages : Strings.Common_Scan;

    public string EmptyHint => Source?.Value == ScanSource.Platen || Source is null
        ? Strings.Scan_EmptyHintGlass
        : Strings.Scan_EmptyHintFeeder;

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
        RecordRole(string.Format(page.StartsFile ? Strings.Scan_UndoJoinFile : Strings.Scan_UndoStartFile, page.Number), page);
        page.StartsFile = !page.StartsFile;
        Prompt.Announce(page.FileStart > 0 ? string.Format(Strings.Scan_PageStartsFile, page.Number, page.FileStart) : string.Format(Strings.Scan_PageSameFile, page.Number));
    }

    /// <summary>A page taken for a separator sheet is an ordinary page again (the files on either side join).</summary>
    [RelayCommand]
    private void NotSeparator(ScanPageViewModel? page)
    {
        if (page is null || IsBusy || !page.IsSeparator) return;
        RecordRole(string.Format(Strings.Scan_UndoKeepAsPage, page.Number), page);
        page.Separator = SeparatorFound.None;
        _ = page.OcrAsync();
        Prompt.Announce(string.Format(Strings.Scan_PageNotSeparator, page.Number));
    }

    /// <summary>Any page as a separator sheet: a new file starts after it.</summary>
    [RelayCommand]
    private void MarkSeparator(ScanPageViewModel? page)
    {
        if (page is null || IsBusy || page.IsSeparator) return;
        RecordRole(string.Format(Strings.Scan_UndoUseAsSeparator, page.Number), page);
        page.StartsFile = false;
        page.IsSkipped = false;
        page.Separator = new SeparatorFound(SeparatorKind.ByHand);
        Prompt.Announce(string.Format(Strings.Scan_PageIsSeparator, page.Number));
    }

    /// <summary>Saves a separator sheet (Patch T; Letter, or A4 by region) as a PDF and opens it, to print at actual size.</summary>
    [RelayCommand]
    private void PrintSeparatorSheet()
    {
        var metric = RegionInfo.CurrentRegion.IsMetric;
        var dialog = new SaveFileDialog
        {
            Title = Strings.Scan_SeparatorDialogTitle,
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            FileName = Strings.Scan_SeparatorFileName,
            Filter = Strings.Scan_PdfFilter,
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            using (var fs = File.Create(dialog.FileName))
                SeparatorSheet.Write(fs, PatchCode.PatchT, metric ? 210 / 25.4 : 8.5, metric ? 297 / 25.4 : 11);
            Message = string.Format(Strings.Scan_SeparatorSaved, Path.GetFileName(dialog.FileName));
            Shell.Open(dialog.FileName);
        }
        catch (Exception ex)
        {
            Log.Write($"Separator sheet failed: {ex}");
            Message = string.Format(Strings.Scan_SeparatorSaveFailed, ex.Message);
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
        ? string.Format(Strings.Scan_ViaWindowsNote, wia.Device.Name)
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
            Message = Strings.Scan_Scanning;
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
                Message = string.Format(Strings.Scan_ScannedPage, Pages.Count);
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
                !findPhotos ? "" : photos == 0 ? Strings.Scan_NoPhotosFound
                    : Plural.Of(photos, Strings.Scan_PhotosFoundSaved_One, Strings.Scan_PhotosFoundSaved_Many),
                separators == 0 ? job.Split == SplitAt.None ? "" : Strings.Scan_NoSeparatorsFound
                    : Plural.Of(separators, Strings.Scan_SeparatorsFound_One, Strings.Scan_SeparatorsFound_Many, Plural.Of(files, Strings.Scan_Files_One, Strings.Scan_Files_Many)),
                blank == 0 ? "" : Plural.Of(blank, Strings.Scan_BlankLeftOutNote_One, Strings.Scan_BlankLeftOutNote_Many),
                straightened == 0 ? "" : Plural.Of(straightened, Strings.Scan_Straightened_One, Strings.Scan_Straightened_Many),
                cleaned,
                request.Source == ScanSource.AdfDuplex && job.Split is SplitAt.BlankPage or SplitAt.PatchCodeOrBlankPage
                    ? Strings.Scan_DuplexBlankNote : "",
                PdfNote(added, request),
            }.Concat(job.Notes).Where(n => n.Length > 0));
            Message = added.Count == 0
                ? Strings.Scan_NoPagesReturned
                : (request.Source == ScanSource.Platen
                    ? Strings.Scan_DoneGlass
                    : Plural.Of(added.Count, Strings.Scan_DoneFeeder_One, Strings.Scan_DoneFeeder_Many)) + (notes.Length > 0 ? " " + notes : "");
            return added.Count;
        }
        catch (OperationCanceledException)
        {
            Message = Strings.Scan_Cancelled;
        }
        catch (ScanException ex)
        {
            Message = ex.Message;
        }
        catch (Exception ex)
        {
            Log.Write($"Scan failed: {ex}");
            Message = string.Format(Strings.Scan_Failed, ex.Message);
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
            History.Record(changed.Count == 1 ? string.Format(Strings.Scan_CleanPage, changed[0].Number) : string.Format(Strings.Scan_UndoCleanPages_Many, changed.Count), () =>
            {
                foreach (var (page, edits) in before) page.Edits = page.Edits with { Crop = edits.Crop, Filters = edits.Filters };
            });
        }
        // Every page the crop was tried on, not only those something else changed: with crop alone, one with no edge has no other change.
        var noEdge = cleanup.HasFlag(PageFilters.CropToPaper)
            ? added.Count(p => !p.LooksBlank && !p.IsSkipped && !p.IsSeparator && !p.HasPhotos && !p.FindsPhotos && !p.Edits.Filters.HasFlag(PageFilters.CropToPaper)) : 0;
        var text = changed.Count == 0 ? "" : Plural.Of(changed.Count, Strings.Scan_CleanedUp_One, Strings.Scan_CleanedUp_Many);
        return noEdge == 0 ? text : (text + " " + Plural.Of(noEdge, Strings.Scan_NoEdge_One, Strings.Scan_NoEdge_Many)).TrimStart();
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
        History.Record(string.Format(Strings.Scan_UndoDeletePage, page.Number), () =>
        {
            page.PropertyChanged += PageChanged;
            Pages.Insert(Math.Min(index, Pages.Count), page);
        });
        page.PropertyChanged -= PageChanged;
        Pages.Remove(page);
        Message = string.Format(Strings.Scan_DeletedPage, index + 1);
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
        History.Record(string.Format(Strings.Scan_UndoMovePage, from + 1), () =>
        {
            if (Pages.IndexOf(page!) is var at and >= 0 && from < Pages.Count) Pages.Move(at, from);
        });
        Pages.Move(from, index);
        _dirty = true;
        _changes++;
        OnPropertyChanged(nameof(HasUnsavedPages));
        return string.Format(Strings.Scan_MovedTo, index + 1, Pages.Count);
    }

    /// <summary>Turns the page; a scan of photos on the glass turns every photo instead.</summary>
    [RelayCommand]
    private void RotateLeft(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        RecordLook(string.Format(Strings.Scan_UndoTurnLeft, page.Number), page);
        if (page.HasPhotos) page.Photos = [.. page.Photos!.Select(b => b with { QuarterTurns = (b.QuarterTurns + 3) % 4 })];
        else page.Edits = page.Edits.Turned(-1);
    }

    [RelayCommand]
    private void RotateRight(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        RecordLook(string.Format(Strings.Scan_UndoTurnRight, page.Number), page);
        if (page.HasPhotos) page.Photos = [.. page.Photos!.Select(b => b with { QuarterTurns = (b.QuarterTurns + 1) % 4 })];
        else page.Edits = page.Edits.Turned(1);
    }

    /// <summary>A page found blank goes back into what's saved.</summary>
    [RelayCommand]
    private void KeepPage(ScanPageViewModel? page)
    {
        if (page is null || IsBusy) return;
        RecordRole(string.Format(Strings.Scan_UndoKeepPage, page.Number), page);
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
            Message = string.Format(Strings.Scan_CouldntShowPage, ex.Message);
            CropPage = null;
        }
    }

    [RelayCommand]
    private void ApplyCrop()
    {
        if (CropPage is { } page && page.Edits.WithShownCrop(CropBox) is var cropped && cropped != page.Edits)
        {
            RecordLook(string.Format(Strings.Scan_UndoCropPage, page.Number), page);
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

    public string CleanTitle => CleanPage is not { } page ? "" : string.Format(page.HasPhotos ? Strings.Scan_CleanPhotosTitle : Strings.Scan_CleanPage, page.Number);

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
        CleanStatus = Strings.Scan_Working;
        try
        {
            var edits = await page.EditsWithAsync(choices, cts.Token);
            var photos = page.Photos;
            var image = await Task.Run(() => photos is { Count: > 0 } boxes
                ? ScanImaging.PhotoPreview(page.Original, boxes[0], choices, 1600, page.Dpi, cts.Token)
                : ScanImaging.Render(page.Original, edits, 1600, page.Dpi, cts.Token), cts.Token);
            if (CleanPage != page || cts != _cleanCts) return;
            CleanImage = image;
            CleanStatus = ShowOriginal ? Strings.Scan_AsScanned : page.CleanNote(choices, edits);
            Prompt.Announce(CleanStatus);
        }
        catch (OperationCanceledException)
        {
            // a newer choice, or the view closed
        }
        catch (Exception ex)
        {
            Log.Write($"Clean up preview failed: {ex}");
            if (cts == _cleanCts) CleanStatus = string.Format(Strings.Scan_CouldntShowPage, ex.Message);
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
                RecordLook(string.Format(Strings.Scan_CleanPage, page.Number), page);
                page.Edits = edits;
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Log.Write($"Clean up failed: {ex}");
            Message = string.Format(Strings.Scan_CouldntCleanPage, page.Number, ex.Message);
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
        CleanStatus = Strings.Scan_Working;
        var results = new List<(ScanPageViewModel Page, PageEdits Before, PageEdits After)>();
        foreach (var page in targets)
        {
            var edits = await page.EditsWithAsync(choices, default);
            if (edits != page.Edits) results.Add((page, page.Edits, edits));
        }
        if (results.Count > 0)
        {
            History.Record(Plural.Of(results.Count, Strings.Scan_UndoCleanPages_One, Strings.Scan_UndoCleanPages_Many), () =>
            {
                foreach (var (page, before, _) in results) page.Edits = before;
            });
            foreach (var (page, _, after) in results) page.Edits = after;
        }
        CancelClean();
        Message = Plural.Of(results.Count, Strings.Scan_CleanedUp_One, Strings.Scan_CleanedUp_Many);
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
        if (HasUnsavedPages && !Prompt.Ask(Plural.Of(Pages.Count, Strings.Scan_DiscardUnsaved_One, Strings.Scan_DiscardUnsaved_Many), Strings.Scan_Discard)) return;
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
        Message = Plural.Of(pages.Count, Strings.Recovery_Restored_One, Strings.Recovery_Restored_Many);
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
            Title = files.Count > 1 ? string.Format(jpg ? Strings.Scan_SaveAsImageSetsTitle : Strings.Scan_SaveAsPdfsTitle, files.Count)
                : jpg ? Strings.Scan_SaveAsImagesTitle : Strings.Scan_SaveAsPdfTitle,
            InitialDirectory = folder,
            FileName = string.Format(Strings.Scan_DefaultFileName, DateTime.Now),
            Filter = jpg ? Strings.Scan_JpegFilter : Strings.Scan_PdfFilter,
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        _state.ScanFolder = Path.GetDirectoryName(dialog.FileName);
        _state.Save();

        var targets = Targets(dialog.FileName, [.. files.Select(f => f.Sum(p => p.ImageCount))], jpg);
        var all = targets.SelectMany(t => t).ToList();
        // The dialog already asked about the name typed; numbered files (images, several PDFs) are siblings it never saw.
        if (all.Count > 1 && all.Where(t => t != dialog.FileName && File.Exists(t)).ToList() is { Count: > 0 } clobbered &&
            !Prompt.Ask(Plural.Of(clobbered.Count, Strings.Scan_ReplaceExisting_One, Strings.Scan_ReplaceExisting_Many, Path.GetFileName(clobbered[0])), Strings.Scan_Replace))
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
            Message = SavedText(Path.GetFileName(LastSavedPath), all.Count, files.Count, jpg)
                      + (jpg ? "" : AsSentNote(files));
            RatingRequest.NoteSuccess(_state);
            if (!jpg && OpenInInkvoltPdf && InkvoltPdfInstalled) OpenSavedInInkvoltPdf();
        }
        catch (OperationCanceledException)
        {
            Message = Strings.Scan_SaveCancelled;
        }
        catch (Exception ex)
        {
            Log.Write($"Save failed: {ex}");
            Message = string.Format(Strings.Scan_SaveFailed, ex.Message);
        }
        finally
        {
            EndSave();
            IsBusy = false;
        }
    }

    /// <summary>"Saved Scan.pdf and 2 more (3 files) in C:\Scans." after a save; <paramref name="folder"/> null leaves the "in" out.</summary>
    private static string SavedText(string name, int count, int files, bool jpg, string? folder = null)
    {
        var inFolder = folder is not null;
        var text = count <= 1 ? (inFolder ? Strings.Scan_SavedIn : Strings.Scan_Saved)
            : files <= 1 ? (inFolder ? Strings.Scan_SavedMoreIn : Strings.Scan_SavedMore)
            : jpg ? (inFolder ? Strings.Scan_SavedMoreSetsIn : Strings.Scan_SavedMoreSets)
            : inFolder ? Strings.Scan_SavedMoreFilesIn : Strings.Scan_SavedMoreFiles;
        return string.Format(text, name, count - 1, files, folder);
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
            return " " + (plans.Count == 1 ? Strings.Scan_AsSentOne : Strings.Scan_AsSentMany);
        return " " + plans.Select(ScannerPdf.WhyNotAsSent).OfType<string>().First();
    }

    /// <summary>After a scan from a source that sends only PDF: what that means, in words.</summary>
    private static string PdfNote(List<ScanPageViewModel> added, ScanRequest request)
    {
        if (added.FirstOrDefault(p => p.FromPdf is not null)?.FromPdf is not { } origin) return "";
        var glass = request.Source == ScanSource.Platen;
        return origin.Rendered
            ? string.Format(glass ? Strings.Scan_PdfNoteRenderedGlass : Strings.Scan_PdfNoteRenderedFeeder, request.Resolution)
            : glass ? Strings.Scan_PdfNoteExtractedGlass : Strings.Scan_PdfNoteExtractedFeeder;
    }

    /// <summary>The PDF's pages: each page with its text layer, or for a scan of photos on the glass, each photo (no text).</summary>
    private async Task<List<PdfPage>> PdfPagesAsync(List<ScanPageViewModel> kept)
    {
        if (kept.Any(p => !p.HasPhotos && !p.OcrAsync().IsCompleted)) Message = Strings.Scan_FinishingOcr;
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
                Message = Strings.Scan_InkvoltPdfNotStarted;
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

    public string SavePresetText => ActivePreset is { } p ? string.Format(Strings.Scan_SaveWithPreset, p.Name) : "";

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
                    Plural.Of(Pages.Count, Strings.Scan_DiscardAndScanQuestion_One, Strings.Scan_DiscardAndScanQuestion_Many, preset.Name), Strings.Scan_DiscardAndScan))
                return;
            DropPages();
        }
        ActivePreset = preset;
        Prompt.Announce(string.Format(Strings.Scan_ScanningWith, preset.Name));
        var added = await ScanPagesAsync(() => PlanAsync(preset));
        if (added <= 0) return;
        if (!preset.Review) await SaveWithPresetAsync();
        else Message += " " + string.Format(Strings.Scan_CheckThenSave, SavePresetText);
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
                ? Strings.Scan_NothingToSaveSeparators
                : Strings.Scan_NothingToSaveBlank;
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
            Message = SavedText(Path.GetFileName(saved[0]), saved.Count, files.Count, jpg, folder)
                + (before.Count == 0 ? "" : " " + string.Format(Strings.Scan_AlreadySaved, string.Join(", ", before.Select(Path.GetFileName))))
                + (jpg ? "" : AsSentNote(files))
                + string.Concat(_presetNotes.Select(n => " " + n));
            Prompt.Announce(Message);
            RatingRequest.NoteSuccess(_state);
        }
        catch (OperationCanceledException)
        {
            Message = Strings.Scan_SaveCancelled;
            return;
        }
        catch (Exception ex)
        {
            Log.Write($"Preset save failed: {ex}");
            Message = saved.Count == 0 ? string.Format(Strings.Scan_SaveFailed, ex.Message)
                : string.Format(Strings.Scan_PartSaveFailed, done, files.Count, string.Join(", ", saved.Select(Path.GetFileName)), done + 1, ex.Message);
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
            if (demo) Message += " " + Strings.Scan_DemoNoInkvoltPdf;
            else if (!InkvoltPdfInstalled) Message += " " + Strings.Scan_InkvoltPdfNotInstalled;
            else OpenSavedInInkvoltPdf();
        }
        switch (preset.After)
        {
            case PresetAfter.Print:
                await PrintCopyAsync(saved[0], kept);
                break;
            case PresetAfter.Email when demo:
                Message += " " + Strings.Mail_DemoNote;
                break;
            case PresetAfter.Email:
                var before = Message;
                var said = Message += " " + Strings.Mail_Opening;
                var note = await MailHandoff.SendAsync(saved, Path.GetFileNameWithoutExtension(saved[0])) switch
                {
                    MailHandoff.Result.Attached => " " + Strings.Mail_Attached,
                    MailHandoff.Result.Cancelled => " " + Strings.Mail_Cancelled,
                    _ => " " + (saved.Count == 1 ? Strings.Mail_AttachByHandOne : string.Format(Strings.Mail_AttachByHandMany, saved.Count)),
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
            Message += " " + Strings.Scan_DemoPrinted;
            return;
        }
        try
        {
            if (await _findQueue() is not { } queue)
            {
                Message += " " + Strings.Scan_PrintNotSetUp;
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
            Message += " " + Strings.Scan_CopyPrinting;
        }
        catch (Exception ex)
        {
            Log.Write($"Preset print failed: {ex}");
            Message += " " + string.Format(Strings.Scan_PrintFailed, ex.Message);
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
            return string.Format(Strings.Scan_TooLargeToClean, (long)_size.Width * _size.Height / 1_000_000);
        if (wanted.HasFlag(PageFilters.CropToPaper) && !edits.Filters.HasFlag(PageFilters.CropToPaper) && !HasPhotos)
            return Strings.Scan_NoEdgeHere;
        return wanted == PageFilters.None ? Strings.Scan_AsScanned : string.Format(Strings.Scan_Shown, PageCleanup.Describe(wanted));
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
    public string FileStartText => string.Format(Strings.Scan_FileNumber, FileStart);
    public string FileStartMenuText => StartsFile ? Strings.Scan_DontStartFileHere : Strings.Scan_StartFileHere;

    /// <summary>"Separator: Patch T sheet" over the thumbnail.</summary>
    public string SeparatorText => IsSeparator ? string.Format(Strings.Scan_SeparatorLabel, Separator.Description) : "";

    public string SeparatorStatus => SeparatorKept ? Strings.Scan_SeparatorKeptStatus : Strings.Scan_SeparatorNotSavedStatus;

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
    public string CropText => FindsPhotos ? Strings.Scan_AdjustPhotos : Strings.Scan_CropPage;
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
            var label = IsSeparator ? string.Format(SeparatorKept ? Strings.Scan_LabelSeparatorKept : Strings.Scan_LabelSeparatorNotSaved, Number, Separator.Description)
                : Note.Length == 0 ? string.Format(Strings.Scan_LabelPage, Number) : string.Format(Strings.Scan_LabelPageNote, Number, Note.ToLowerInvariant());
            return FileStart > 0 ? string.Format(Strings.Scan_LabelStartsFile, label, FileStart) : label;
        }
    }

    /// <summary>What happened to the page, under its number: "Straightened", "Edited", "Blank, not saved", or nothing.</summary>
    public string Note => IsSeparator ? (SeparatorKept ? Strings.Scan_NoteSeparatorKept : Strings.Scan_NoteSeparatorNotSaved)
        : IsSkipped ? Strings.Scan_NoteBlank
        : HasPhotos ? Edits.Filters != PageFilters.None
            ? Plural.Of(Photos!.Count, Strings.Scan_PhotosCleaned_One, Strings.Scan_PhotosCleaned_Many, PageCleanup.Describe(Edits.Filters))
            : Plural.Of(Photos!.Count, Strings.Scan_Photos_One, Strings.Scan_Photos_Many)
        : FindsPhotos ? Strings.Scan_NoteNoPhotos
        : Edits.Filters != PageFilters.None ? Capitalized(PageCleanup.Describe(Edits.Filters))
        : Edits.Deskew != 0 && Edits.Crop is null && Edits.QuarterTurns % 4 == 0 ? Strings.Scan_NoteStraightened : IsEdited ? Strings.Scan_NoteEdited : "";

    private static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    partial void OnEditsChanged(PageEdits value) => _ = RefreshThumbnailAsync(value);

    /// <summary>The page as saved: the scanner's JPEG, or the edited page encoded once per set of edits.</summary>
    public Task<byte[]> JpegAsync()
    {
        var edits = Edits.For(_size.Width, _size.Height); // too large to clean: saved as scanned, as the view says, and not decoded for nothing
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
                // The edge was found on the page straightened by angle: a page edited meanwhile keeps its whole page.
                if (!looksBlank && !separator.IsSeparator && Edits.CleanedUp(cleanup, photos is { Count: > 0 }, crop, angle) is { } cleaned)
                {
                    BeforeCleanup = Edits;
                    Edits = cleaned;
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
