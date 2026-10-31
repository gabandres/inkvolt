using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Presets;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.ViewModels;

/// <summary>A place to save into, as the editor's "Save to" list shows it. <see cref="IsBrowse"/>: "Other folder…".</summary>
public sealed record FolderChoice(string Label, PresetFolder Kind, string? Path, bool IsBrowse = false)
{
    public override string ToString() => Label;
}

/// <summary>
/// "Manage presets": edits a working copy of the presets (create, rename, duplicate, delete, reorder, every setting);
/// Save checks them and replaces the library's list, Cancel leaves it as it was.
/// </summary>
public sealed partial class ScanPresetsViewModel : ObservableObject
{
    private readonly ScanPresetLibrary _library;

    public ScanPresetsViewModel(ScanPresetLibrary library, IReadOnlyList<SyncFolder> syncFolders, string printerName)
    {
        _library = library;
        PrinterName = printerName;
        Folders.Add(new("Documents", PresetFolder.Documents, null));
        Folders.Add(new("Pictures", PresetFolder.Pictures, null));
        foreach (var f in syncFolders) Folders.Add(new($"{f.Name}  ({f.Path})", PresetFolder.Custom, f.Path));
        Folders.Add(Browse);
        foreach (var p in library.Items) Items.Add(new PresetItem(this, p));
        Selected = Items.FirstOrDefault();
    }

    public string PrinterName { get; }

    /// <summary>Presets from a newer Inkvolt Print: shown, not saved (<see cref="ScanPresetLibrary.IsReadOnly"/>).</summary>
    public bool IsReadOnly => _library.IsReadOnly;

    public bool CanSave => !IsReadOnly;

    /// <summary>Asks the user for a folder (the dialog's OpenFolderDialog); null when cancelled. Unset: no browsing.</summary>
    public Func<string?, string?>? PickFolder { get; set; }

    public static readonly FolderChoice Browse = new("Other folder…", PresetFolder.Custom, null, IsBrowse: true);

    public ObservableCollection<FolderChoice> Folders { get; } = [];
    public ObservableCollection<PresetItem> Items { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelection))]
    [NotifyCanExecuteChangedFor(nameof(DuplicateCommand), nameof(DeleteCommand), nameof(MoveUpCommand), nameof(MoveDownCommand))]
    public partial PresetItem? Selected { get; set; }

    public bool HasSelection => Selected is not null;

    /// <summary>Why Save didn't close the editor.</summary>
    [ObservableProperty] public partial string? Error { get; set; }

    public static IReadOnlyList<Option<PresetSource>> Sources { get; } =
    [
        new(PresetSource.Auto, "Feeder if it has pages, else glass"),
        new(PresetSource.Glass, "Scanner glass"),
        new(PresetSource.Feeder, "Document feeder"),
    ];

    public static IReadOnlyList<Option<PresetFileType>> FileTypes { get; } =
    [
        new(PresetFileType.SearchablePdf, "PDF, searchable (text recognition)"),
        new(PresetFileType.Pdf, "PDF"),
        new(PresetFileType.Jpeg, "JPEG images (one per page)"),
    ];

    public static IReadOnlyList<Option<int>> Resolutions { get; } =
        [new(150, "150 dpi (draft)"), new(200, "200 dpi (screen)"), new(300, "300 dpi (documents)"), new(600, "600 dpi (photos, slower)"), new(1200, "1200 dpi (slowest)")];

    public static IReadOnlyList<Option<string?>> PageSizes { get; } =
        [new(null, "Letter or A4 (by region)"), .. ScanChoices.PageSizes.Select(p => new Option<string?>(p.Key, p.Label))];

    public static IReadOnlyList<Option<SplitAt>> Splits { get; } = [.. Enum.GetValues<SplitAt>().Select(s => new Option<SplitAt>(s, Separators.Label(s)))];

    public static IReadOnlyList<Option<PresetAfter>> Afters { get; } =
    [
        new(PresetAfter.None, "Nothing else"),
        new(PresetAfter.OpenInInkvoltPdf, "Open it in Inkvolt PDF"),
        new(PresetAfter.Print, "Print a copy"),
        new(PresetAfter.Email, "Email it (opens your mail app)"),
    ];

    public static string TokenHelp =>
        "{date}  {date:yyyy-MM}  {time}  {time:HH.mm}  {preset}  {printer}  {n}  {n:000}  {pages}";

    /// <summary>The choice for a stored folder; a custom folder not in the list is added (above "Other folder…").</summary>
    public FolderChoice ChoiceFor(PresetFolder kind, string? path)
    {
        if (kind != PresetFolder.Custom || string.IsNullOrWhiteSpace(path)) return Folders.First(f => f.Kind == (kind == PresetFolder.Pictures ? PresetFolder.Pictures : PresetFolder.Documents));
        if (Folders.FirstOrDefault(f => !f.IsBrowse && f.Kind == PresetFolder.Custom && string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase)) is { } known)
            return known;
        var added = new FolderChoice(path, PresetFolder.Custom, path);
        Folders.Insert(Folders.Count - 1, added);
        return added;
    }

    [RelayCommand]
    private void New()
    {
        var item = new PresetItem(this, ScanPresets.Create(Snapshot()));
        Items.Add(item);
        Selected = item;
        Prompt.Announce($"Added {item.Name}");
    }

    [RelayCommand(CanExecute = nameof(HasSelection))]
    private void Duplicate()
    {
        if (Selected is not { } source) return;
        var item = new PresetItem(this, ScanPresets.Duplicate(Snapshot(), source.ToPreset()));
        Items.Insert(Items.IndexOf(source) + 1, item);
        Selected = item;
        Prompt.Announce($"Added {item.Name}");
    }

    [RelayCommand(CanExecute = nameof(HasSelection))]
    private void Delete()
    {
        if (Selected is not { } item || !Prompt.Ask($"Delete the preset \"{item.Name}\"? Files it saved stay where they are.", "Delete")) return;
        var i = Items.IndexOf(item);
        Items.Remove(item);
        Selected = Items.Count == 0 ? null : Items[Math.Min(i, Items.Count - 1)];
        Prompt.Announce($"Deleted {item.Name}");
    }

    private bool CanMoveUp() => Selected is { } s && Items.IndexOf(s) > 0;
    private bool CanMoveDown() => Selected is { } s && Items.IndexOf(s) < Items.Count - 1;

    [RelayCommand(CanExecute = nameof(CanMoveUp))]
    private void MoveUp() => Move(-1);

    [RelayCommand(CanExecute = nameof(CanMoveDown))]
    private void MoveDown() => Move(1);

    private void Move(int by)
    {
        if (Selected is not { } item) return;
        var from = Items.IndexOf(item);
        if (from + by < 0 || from + by >= Items.Count) return;
        Items.Move(from, from + by);
        Selected = item;
        MoveUpCommand.NotifyCanExecuteChanged();
        MoveDownCommand.NotifyCanExecuteChanged();
        Prompt.Announce($"Moved to position {from + by + 1} of {Items.Count}");
    }

    private List<ScanPreset> Snapshot() => Items.Select(i => i.ToPreset()).ToList();

    /// <summary>Checks every preset; on a problem selects that preset and says what's wrong. True when saved.</summary>
    public bool Save()
    {
        if (IsReadOnly) return false;
        var all = Snapshot();
        foreach (var item in Items)
        {
            if (item.Problem(all) is { } problem)
            {
                Selected = item;
                Error = $"{item.Name}: {problem}";
                Prompt.Announce(Error);
                return false;
            }
        }
        _library.Replace(all.Select(p => p with { Name = p.Name.Trim() }));
        return true;
    }

    /// <summary>"Other folder…" was picked for <paramref name="item"/>: ask, or put the previous choice back.</summary>
    internal FolderChoice BrowseFor(FolderChoice previous)
    {
        var path = PickFolder?.Invoke(previous.Path);
        return path is null ? previous : ChoiceFor(PresetFolder.Custom, path);
    }
}

/// <summary>One preset being edited (the record's fields as bindable properties).</summary>
public sealed partial class PresetItem : ObservableObject
{
    private readonly ScanPresetsViewModel _owner;
    private readonly ScanPreset _original;
    private bool _browsing;

    public PresetItem(ScanPresetsViewModel owner, ScanPreset preset)
    {
        _owner = owner;
        _original = preset;
        Name = preset.Name;
        Source = ScanPresetsViewModel.Sources.First(o => o.Value == preset.Source);
        TwoSided = preset.TwoSided;
        Color = preset.Color;
        Resolution = ScanPresetsViewModel.Resolutions.MinBy(o => Math.Abs(o.Value - preset.Resolution))!;
        PageSize = ScanPresetsViewModel.PageSizes.FirstOrDefault(o => o.Value == preset.PageSize) ?? ScanPresetsViewModel.PageSizes[0];
        FileType = ScanPresetsViewModel.FileTypes.First(o => o.Value == preset.FileType);
        Review = preset.Review;
        SkipBlank = preset.SkipBlank;
        Straighten = preset.Straighten;
        CropToPaper = preset.Cleanup.HasFlag(Core.Imaging.PageFilters.CropToPaper);
        WhitenPages = preset.Cleanup.HasFlag(Core.Imaging.PageFilters.Whiten);
        DescreenPages = preset.Cleanup.HasFlag(Core.Imaging.PageFilters.Descreen);
        RestoreColors = preset.Cleanup.HasFlag(Core.Imaging.PageFilters.RestoreColors);
        OcrLanguage = OcrLanguages.FirstOrDefault(o => o.Value == preset.OcrLanguage) ?? OcrLanguages[0];
        SplitAt = ScanPresetsViewModel.Splits.First(o => o.Value == preset.SplitAt);
        KeepSeparators = preset.KeepSeparators;
        FindPhotos = preset.FindPhotos;
        Folder = owner.ChoiceFor(preset.Folder, preset.FolderPath);
        Subfolder = preset.Subfolder;
        FileName = preset.FileName;
        After = ScanPresetsViewModel.Afters.First(o => o.Value == preset.After);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NameError), nameof(Example))]
    public partial string Name { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Note))]
    public partial Option<PresetSource> Source { get; set; }

    [ObservableProperty] public partial bool TwoSided { get; set; }
    [ObservableProperty] public partial bool Color { get; set; }
    [ObservableProperty] public partial Option<int> Resolution { get; set; }
    [ObservableProperty] public partial Option<string?> PageSize { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Example), nameof(Note), nameof(IsPdf))]
    public partial Option<PresetFileType> FileType { get; set; }

    [ObservableProperty] public partial bool Review { get; set; }
    [ObservableProperty] public partial bool SkipBlank { get; set; }
    [ObservableProperty] public partial bool Straighten { get; set; }
    [ObservableProperty] public partial bool CropToPaper { get; set; }
    [ObservableProperty] public partial bool WhitenPages { get; set; }
    [ObservableProperty] public partial bool DescreenPages { get; set; }
    [ObservableProperty] public partial bool RestoreColors { get; set; }

    /// <summary>The OCR languages to choose from; more than Windows' own only when more are installed.</summary>
    public IReadOnlyList<Option<string?>> OcrLanguages { get; } = OcrLanguageChoices.List();
    public bool HasOcrLanguageChoice => OcrLanguages.Count > 2;
    [ObservableProperty] public partial Option<string?> OcrLanguage { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Splits), nameof(Example))]
    public partial Option<SplitAt> SplitAt { get; set; }

    [ObservableProperty] public partial bool KeepSeparators { get; set; }
    [ObservableProperty] public partial bool FindPhotos { get; set; }

    public bool Splits => SplitAt.Value != Core.Imaging.SplitAt.None;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Example))]
    public partial FolderChoice Folder { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SubfolderError), nameof(Example))]
    public partial string Subfolder { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(FileNameError), nameof(Example))]
    public partial string FileName { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Note))]
    public partial Option<PresetAfter> After { get; set; }

    public bool IsPdf => FileType.Value != PresetFileType.Jpeg;

    partial void OnFolderChanged(FolderChoice oldValue, FolderChoice newValue)
    {
        if (!newValue.IsBrowse || _browsing) return;
        _browsing = true;
        var previous = oldValue is { IsBrowse: false } ? oldValue : _owner.Folders[0];
        // Let the ComboBox finish its own selection change before putting a real folder in its place.
        System.Windows.Application.Current?.Dispatcher.InvokeAsync(() =>
        {
            try { Folder = _owner.BrowseFor(previous); }
            finally { _browsing = false; }
        });
    }

    /// <summary>Checked against the other presets as they are in the editor right now.</summary>
    public string? NameError => ScanPresets.NameProblem(_owner.Items.Where(i => i != this).Select(i => new ScanPreset { Id = "other", Name = i.Name }), "this", Name);
    public string? FileNameError => FileNameTemplate.Problem(FileName);
    public string? SubfolderError => FileNameTemplate.Problem(Subfolder);

    /// <summary>What the next scan would be called and where it would go (with today's date and two pages).</summary>
    public string Example
    {
        get
        {
            var ctx = new NameContext(DateTime.Now, string.IsNullOrWhiteSpace(Name) ? "Preset" : Name.Trim(), _owner.PrinterName, _original.NextNumber, 2,
                CultureInfo.CurrentCulture);
            var folder = Folder.IsBrowse ? "…" : Folder.Kind == PresetFolder.Custom ? Folder.Path ?? "" : Folder.Label;
            var sub = FileNameTemplate.Subfolder(Subfolder, ctx);
            var name = FileNameTemplate.FileName(FileName, ctx);
            var file = FileType.Value == PresetFileType.Jpeg ? $"{name} (1).jpg" : $"{name}.pdf";
            return Path.Combine(folder, sub, file) + (Splits ? "  (one per file, each with its own {n})" : "");
        }
    }

    /// <summary>Things worth knowing about the choices (not errors).</summary>
    public string? Note =>
        After.Value == PresetAfter.OpenInInkvoltPdf && FileType.Value == PresetFileType.Jpeg ? "Inkvolt PDF opens PDFs: JPEG scans are only saved."
        : After.Value == PresetAfter.Email ? "Inkvolt Print sends nothing itself: your mail app opens a new message with the file attached, for you to address and send."
        : FileType.Value == PresetFileType.SearchablePdf && !InkvoltPrint.Windows.Ocr.WindowsOcr.IsAvailable ? "Text recognition isn't available on this PC: PDFs won't be searchable."
        : null;

    /// <summary>The first thing that stops this preset being saved, or null.</summary>
    public string? Problem(IReadOnlyList<ScanPreset> all) =>
        ScanPresets.NameProblem(all, _original.Id, Name)
        ?? (FileNameError is { } f ? $"File name: {f}" : null)
        ?? (SubfolderError is { } s ? $"Subfolder: {s}" : null)
        ?? (Folder.IsBrowse ? "Choose a folder to save into." : null);

    public ScanPreset ToPreset() => _original with
    {
        Name = Name,
        Source = Source.Value,
        TwoSided = TwoSided,
        Color = Color,
        Resolution = Resolution.Value,
        PageSize = PageSize.Value,
        FileType = FileType.Value,
        Review = Review,
        SkipBlank = SkipBlank,
        Straighten = Straighten,
        Cleanup = (CropToPaper ? Core.Imaging.PageFilters.CropToPaper : 0) | (WhitenPages ? Core.Imaging.PageFilters.Whiten : 0)
            | (DescreenPages ? Core.Imaging.PageFilters.Descreen : 0) | (RestoreColors ? Core.Imaging.PageFilters.RestoreColors : 0),
        OcrLanguage = OcrLanguage.Value,
        SplitAt = SplitAt.Value,
        KeepSeparators = KeepSeparators,
        FindPhotos = FindPhotos,
        Folder = Folder.IsBrowse ? _original.Folder : Folder.Kind,
        FolderPath = Folder.Kind == PresetFolder.Custom && !Folder.IsBrowse ? Folder.Path : null,
        Subfolder = Subfolder ?? "",
        FileName = FileName ?? "",
        After = After.Value,
    };

    public override string ToString() => Name;
}
