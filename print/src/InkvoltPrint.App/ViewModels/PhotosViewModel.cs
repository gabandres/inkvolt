using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Photos;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>A layout in the Photos tab's list: full page, a standard print size, or a contact sheet.</summary>
public sealed record PhotoLayoutChoice(string Key, string Label, PhotoLayoutKind Kind, PhotoSize? Size = null)
{
    public override string ToString() => Label;
}

/// <summary>
/// Print photos: add pictures (button, drag-and-drop, "Open with"), pick a layout (full page, 4 × 6 in and other print
/// sizes, wallets, a contact sheet), paper size and type, borderless when the queue offers it, quality and color; turn,
/// crop (drag, zoom) and set copies per photo; every sheet is previewed as it will print. Prints through the printer's
/// Windows queue (<see cref="PhotoPrinting"/>); the layout arithmetic is Core's <see cref="PhotoLayout"/>.
/// </summary>
/// <param name="demo">Demo printer: the made-up queue's options, and "prints" there (job name, sheets).</param>
public sealed partial class PhotosViewModel(Func<Task<string?>> findQueue, AppState state, DemoPhotoQueue? demo = null) : ObservableObject
{
    public const int MaxPhotos = 500;

    /// <summary>Thumbnails are decoded this wide: sharp in the sheet previews and crop view, a few hundred KB each.</summary>
    private const int ThumbnailWidth = 480;

    /// <summary>Sheet previews: this tall on screen; at most this many are drawn (the rest are counted).</summary>
    private const double PreviewHeight = 300;
    private const int MaxPreviews = 60;

    private static readonly bool Metric = RegionInfo.CurrentRegion.IsMetric;

    /// <summary>Until the queue says otherwise: Letter or A4 by region, ¼ in margins.</summary>
    private static readonly PaperChoice FallbackPaper = Metric
        ? new PaperChoice("ISOA4", PhotoPaperText.Paper(null, 210 / 25.4, 297 / 25.4), 210 / 25.4, 297 / 25.4, null)
        : new PaperChoice("NorthAmericaLetter", PhotoPaperText.Paper(null, 8.5, 11), 8.5, 11, null);

    public static IReadOnlyList<PhotoLayoutChoice> Layouts { get; } =
    [
        new("full", "Full page", PhotoLayoutKind.FullPage),
        .. PhotoSizes.All.Select(s => new PhotoLayoutChoice(SizeKey(s), s.Name, PhotoLayoutKind.PrintSize, s)),
        new("contact", "Contact sheet", PhotoLayoutKind.ContactSheet),
    ];

    private static string SizeKey(PhotoSize s) => s == PhotoSizes.Wallet ? "wallet" : s.Name.Replace(" ", "").Replace("×", "x");

    public static IReadOnlyList<Option<int>> ContactCounts { get; } =
        [.. new[] { 6, 12, 20, 30, 48 }.Select(n => new Option<int>(n, $"{n} per sheet"))];

    private PaperSetup? _setup;
    private int _sheetCount;
    private int _paperGeneration;
    private bool _optionsRead;
    private bool _loadingOptions;

    public ObservableCollection<PhotoItemViewModel> Photos { get; } = [];
    public ObservableCollection<PhotoSheetPreview> Sheets { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelection))]
    [NotifyCanExecuteChangedFor(nameof(RemoveCommand), nameof(RotateLeftCommand), nameof(RotateRightCommand), nameof(ResetCropCommand),
        nameof(MoreCopiesCommand), nameof(FewerCopiesCommand))]
    public partial PhotoItemViewModel? Selected { get; set; }

    public bool HasSelection => Selected is not null;
    public bool HasPhotos => Photos.Count > 0;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsPrintSize), nameof(IsContactSheet), nameof(ShowFit), nameof(ShowCrop))]
    public partial PhotoLayoutChoice Layout { get; set; } = Layouts.FirstOrDefault(l => l.Key == state.PhotoLayout) ?? Layouts[1];

    public bool IsPrintSize => Layout.Kind == PhotoLayoutKind.PrintSize;
    public bool IsContactSheet => Layout.Kind == PhotoLayoutKind.ContactSheet;
    public bool ShowFit => !IsContactSheet;

    /// <summary>Crop and zoom apply to full-page and print-size layouts (a contact sheet shows every photo whole).</summary>
    public bool ShowCrop => !IsContactSheet && HasSelection;

    /// <summary>Fill the cell, cropping what doesn't fit (the default for prints); off: the whole photo with white bands.</summary>
    [ObservableProperty] public partial bool Fill { get; set; } = true;

    [ObservableProperty] public partial Option<int> PerSheet { get; set; } = ContactCounts[1];

    /// <summary>Print sizes: fill each sheet with one photo (a sheet of wallets); copies then count sheets.</summary>
    [ObservableProperty] public partial bool OnePhotoPerSheet { get; set; }

    /// <summary>The print size fits more than once on the paper, so "one photo per sheet" means something.</summary>
    [ObservableProperty] public partial bool ShowOnePerSheet { get; set; }

    [ObservableProperty] public partial IReadOnlyList<PaperChoice> Papers { get; set; } = [FallbackPaper];
    [ObservableProperty] public partial PaperChoice? Paper { get; set; } = FallbackPaper;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasMediaTypes))]
    public partial IReadOnlyList<Option<string>> MediaTypes { get; set; } = [];

    [ObservableProperty] public partial Option<string>? MediaType { get; set; }
    public bool HasMediaTypes => MediaTypes.Count > 1;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasQualities))]
    public partial IReadOnlyList<Option<string>> Qualities { get; set; } = [];

    [ObservableProperty] public partial Option<string>? Quality { get; set; }
    public bool HasQualities => Qualities.Count > 1;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasColors))]
    public partial IReadOnlyList<Option<string>> Colors { get; set; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PreviewInGrey))]
    public partial Option<string>? ColorMode { get; set; }

    public bool HasColors => Colors.Count > 1;

    /// <summary>Printing in grey (a black-and-white printer, or chosen): the preview is grey too.</summary>
    public bool PreviewInGrey => ColorMode?.Value is "Grayscale" or "Monochrome";

    partial void OnColorModeChanged(Option<string>? value) => Relayout();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(BorderlessNote))]
    public partial bool CanBorderless { get; set; }

    [ObservableProperty] public partial bool Borderless { get; set; }

    /// <summary>Said under the paper choices when the queue has no borderless printing for this paper.</summary>
    public string? BorderlessNote => CanBorderless || _setup is null ? null : "This printer prints with margins on this paper (no borderless option).";

    /// <summary>The queue's options are being read (the driver can take a few seconds).</summary>
    [ObservableProperty] public partial bool IsReadingOptions { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand), nameof(AddPhotosCommand), nameof(ClearCommand))]
    public partial bool IsBusy { get; set; }

    [ObservableProperty] public partial string? Summary { get; set; }
    [ObservableProperty] public partial string? Warning { get; set; }
    [ObservableProperty] public partial string? MoreSheetsText { get; set; }
    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    /// <summary>The selected photo's first print: what the crop view shows and drags.</summary>
    [ObservableProperty] public partial PhotoCell? SelectedCell { get; set; }

    public string FormatsText => PhotoFiles.FormatsText;

    partial void OnLayoutChanged(PhotoLayoutChoice value)
    {
        state.PhotoLayout = value.Key;
        state.Save();
        Relayout();
    }

    partial void OnFillChanged(bool value) => Relayout();
    partial void OnPerSheetChanged(Option<int> value) => Relayout();
    partial void OnOnePhotoPerSheetChanged(bool value) => Relayout();
    partial void OnBorderlessChanged(bool value) => Relayout();
    partial void OnPaperChanged(PaperChoice? value) => _ = ReadPaperAsync();

    partial void OnSelectedChanged(PhotoItemViewModel? value)
    {
        OnPropertyChanged(nameof(ShowCrop));
        UpdateSelectedCell();
        foreach (var sheet in Sheets) sheet.Touch(); // the selected photo's prints are outlined
    }

    // ---------------- Adding photos ----------------

    private bool NotBusy() => !IsBusy;

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task AddPhotosAsync()
    {
        var dialog = new OpenFileDialog
        {
            Title = "Choose photos to print",
            Filter = PhotoFiles.DialogFilter,
            Multiselect = true,
            InitialDirectory = state.PhotoFolder is { } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        };
        if (dialog.ShowDialog() == true) await AddAsync(dialog.FileNames);
    }

    /// <summary>Adds pictures (TIFF pages each count as one); files it can't read are listed in the message, the rest are added.</summary>
    public Task AddAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return Task.CompletedTask;
        if (IsBusy)
        {
            SetMessage("Still sending the photos to the printer. Add more when it's done.", error: true);
            return Task.CompletedTask;
        }
        // "Open with" on several files starts one launch per file: each is added after the one before.
        return _adding = AddAfterAsync(_adding, paths);
    }

    private Task _adding = Task.CompletedTask;

    /// <summary>Pictures are being opened (Print waits for them).</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand))]
    public partial bool IsAdding { get; set; }

    private async Task AddAfterAsync(Task previous, IReadOnlyList<string> paths)
    {
        await previous; // never throws: see below
        IsAdding = true;
        SetMessage(paths.Count == 1 ? $"Opening {Path.GetFileName(paths[0])}…" : $"Opening {paths.Count} files…");
        var problems = new List<string>();
        var added = 0;
        try
        {
            foreach (var path in paths)
            {
                if (Photos.Count >= MaxPhotos)
                {
                    problems.Add($"only {MaxPhotos} photos fit in one job");
                    break;
                }
                if (PhotoFiles.MissingCodec(path) is { } missing)
                {
                    problems.Add($"{Path.GetFileName(path)}: {missing}");
                    continue;
                }
                try
                {
                    var room = MaxPhotos - Photos.Count;
                    var items = await Task.Run(() => PhotoFiles.Read(path)
                        .Take(room)
                        .Select(source => (source, thumb: PhotoFiles.Decode(source, ThumbnailWidth)))
                        .ToList());
                    foreach (var (source, thumb) in items)
                    {
                        var item = new PhotoItemViewModel(source, thumb, this);
                        Photos.Add(item);
                        added++;
                    }
                    state.PhotoFolder = Path.GetDirectoryName(path);
                }
                catch (Exception ex) when (ex is NotSupportedException or FileFormatException or IOException or UnauthorizedAccessException
                                               or ArgumentException or InvalidOperationException or System.Runtime.InteropServices.COMException)
                {
                    Log.Write($"Photo open failed: {path}: {ex.Message}");
                    problems.Add($"{Path.GetFileName(path)}: {Reason(path, ex)}");
                }
            }
            state.Save();
        }
        catch (Exception ex)
        {
            Log.Write($"Adding photos failed: {ex}"); // the next add waits on this one: never let it throw
        }
        finally
        {
            IsAdding = false;
        }
        Selected ??= Photos.FirstOrDefault();
        OnPropertyChanged(nameof(HasPhotos));
        Relayout();
        if (problems.Count > 0)
            SetMessage($"{(added > 0 ? $"Added {Count(added, "photo")}. " : "")}Couldn't add {string.Join("; ", problems.Take(3))}" +
                       $"{(problems.Count > 3 ? $" and {problems.Count - 3} more" : "")}.", error: true);
        else SetMessage(null);
        if (added > 0) Prompt.Announce($"Added {Count(added, "photo")}. {Summary}");
        if (!_optionsRead) _ = ReadOptionsAsync();
    }

    private static string Reason(string path, Exception ex) => ex switch
    {
        // The HEIF extension reads the file, but most HEIC photos are HEVC inside, a separate Windows extension.
        _ when Path.GetExtension(path).ToLowerInvariant() is ".heic" or ".heif" or ".hif" =>
            "Windows couldn't decode it (HEIC photos also need the HEVC Video Extensions from the Microsoft Store)",
        NotSupportedException => "not a picture Windows can open",
        FileFormatException => "the file is damaged or not a picture",
        UnauthorizedAccessException => "no permission to read it",
        _ => ex.Message,
    };

    private bool HasSelectionNotBusy() => Selected is not null && !IsBusy;

    [RelayCommand(CanExecute = nameof(HasSelectionNotBusy))]
    private void Remove()
    {
        if (Selected is not { } item) return;
        var index = Photos.IndexOf(item);
        Photos.Remove(item);
        Selected = Photos.Count == 0 ? null : Photos[Math.Min(index, Photos.Count - 1)];
        OnPropertyChanged(nameof(HasPhotos));
        Relayout();
        Prompt.Announce($"Removed {item.Name}.");
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void Clear()
    {
        Photos.Clear();
        Selected = null;
        OnPropertyChanged(nameof(HasPhotos));
        SetMessage(null);
        Relayout();
    }

    [RelayCommand(CanExecute = nameof(HasSelectionNotBusy))]
    private void RotateLeft() => Selected?.Turn(-1);

    [RelayCommand(CanExecute = nameof(HasSelectionNotBusy))]
    private void RotateRight() => Selected?.Turn(1);

    [RelayCommand(CanExecute = nameof(HasSelectionNotBusy))]
    private void MoreCopies() => Selected?.SetCopies(Selected.Copies + 1);

    [RelayCommand(CanExecute = nameof(HasSelectionNotBusy))]
    private void FewerCopies() => Selected?.SetCopies(Selected.Copies - 1);

    [RelayCommand(CanExecute = nameof(HasSelectionNotBusy))]
    private void ResetCrop() => Selected?.SetCrop(PhotoCrop.None);

    /// <summary>A sheet preview was clicked on one of its prints.</summary>
    public void Select(int photo)
    {
        if (photo >= 0 && photo < Photos.Count) Selected = Photos[photo];
    }

    /// <summary>
    /// The photo in <paramref name="cell"/> was dragged by (<paramref name="dx"/>, <paramref name="dy"/>) inches on the paper:
    /// move its crop (sheet previews and the crop view).
    /// </summary>
    public void Drag(PhotoCell cell, double dx, double dy)
    {
        if (IsContactSheet || cell.Photo < 0 || cell.Photo >= Photos.Count) return;
        var item = Photos[cell.Photo];
        var input = item.Job.Input;
        item.SetCrop(PhotoLayout.Drag(cell.Cell, input.Width, input.Height, Fill ? PhotoFit.Fill : PhotoFit.Fit, item.Crop, cell.Turned, dx, dy));
    }

    /// <summary>Arrow keys in the crop view: move the selected photo's crop a tenth of its cell (Shift: a half).</summary>
    public void Nudge(int x, int y, bool large)
    {
        if (SelectedCell is not { } cell) return;
        var step = large ? 0.5 : 0.1;
        Drag(cell, -x * cell.Cell.Width * step, -y * cell.Cell.Height * step);
    }

    // ---------------- The printer's options ----------------

    /// <summary>The Photos tab is on screen: read the queue's paper sizes, types and quality (once).</summary>
    public void Shown()
    {
        if (!_optionsRead) _ = ReadOptionsAsync();
    }

    /// <summary>The printer's Windows queue appeared or went away: read its options again.</summary>
    public void QueueChanged()
    {
        _optionsRead = false;
        _ = ReadOptionsAsync();
    }

    private async Task ReadOptionsAsync()
    {
        if (_loadingOptions) return;
        _loadingOptions = true;
        IsReadingOptions = true;
        try
        {
            PhotoQueueOptions? options;
            if (demo is not null) options = demo.Options;
            else options = await findQueue() is { } queue ? await Task.Run(() => PhotoPrinting.ReadOptions(queue)) : null;
            _optionsRead = true;
            if (options is null) return; // not set up in Windows yet: the fallback paper until it is
            Papers = options.Papers.Count > 0 ? options.Papers : [FallbackPaper];
            MediaTypes = options.MediaTypes;
            Qualities = options.Qualities;
            Colors = options.Colors;
            // Keep what was chosen when the new list has it; else the queue's default.
            Paper = Papers.FirstOrDefault(p => p.Key == Paper?.Key) ?? Papers.FirstOrDefault(p => p.Key == options.DefaultPaper) ?? Papers[0];
            MediaType = MediaTypes.FirstOrDefault(m => m.Value == MediaType?.Value) ?? MediaTypes.FirstOrDefault(m => m.Value == options.DefaultMediaType) ?? MediaTypes.FirstOrDefault();
            Quality = Qualities.FirstOrDefault(m => m.Value == Quality?.Value) ?? Qualities.FirstOrDefault(m => m.Value == options.DefaultQuality) ?? Qualities.FirstOrDefault();
            ColorMode = Colors.FirstOrDefault(m => m.Value == ColorMode?.Value) ?? Colors.FirstOrDefault(m => m.Value == options.DefaultColor) ?? Colors.FirstOrDefault();
            await ReadPaperAsync();
        }
        catch (Exception ex)
        {
            // A driver that can't answer: print with its defaults on the fallback paper.
            Log.Write($"Photo options failed: {ex}");
            _optionsRead = true;
        }
        finally
        {
            _loadingOptions = false;
            IsReadingOptions = false;
        }
    }

    /// <summary>Borderless support and margins for the chosen paper, then the sheets again.</summary>
    private async Task ReadPaperAsync()
    {
        var generation = ++_paperGeneration;
        var paper = Paper ?? FallbackPaper;
        PaperSetup? setup = null;
        try
        {
            if (demo is not null) setup = demo.Setup(paper);
            else if (paper.Media is not null && await findQueue() is { } queue)
            {
                var settings = Settings(paper);
                setup = await Task.Run(() => PhotoPrinting.ReadPaper(queue, settings));
            }
        }
        catch (Exception ex)
        {
            Log.Write($"Photo paper check failed: {ex}");
        }
        if (generation != _paperGeneration) return;
        _setup = setup;
        CanBorderless = setup?.CanBorderless == true;
        if (!CanBorderless) Borderless = false;
        OnPropertyChanged(nameof(BorderlessNote));
        Relayout();
    }

    private PhotoJobSettings Settings(PaperChoice? paper) =>
        new(paper, MediaType?.Value, Quality?.Value, ColorMode?.Value, Borderless && CanBorderless);

    /// <summary>The sheet as laid out: the queue's printable area when known, none when borderless, else ¼ in.</summary>
    private SheetPaper SheetPaper
    {
        get
        {
            var paper = Paper ?? FallbackPaper;
            if (Borderless && CanBorderless) return new SheetPaper(paper.WidthIn, paper.HeightIn, 0, 0, 0, 0);
            return _setup?.Paper is { } known && Math.Abs(known.Width - paper.WidthIn) < 0.01 ? known
                : new SheetPaper(paper.WidthIn, paper.HeightIn, 0.25, 0.25, 0.25, 0.25);
        }
    }

    public PhotoLayoutOptions Options => new()
    {
        Kind = Layout.Kind,
        Size = Layout.Size ?? PhotoSizes.In4x6,
        PerSheet = PerSheet.Value,
        Fit = Fill ? PhotoFit.Fill : PhotoFit.Fit,
        OnePhotoPerSheet = OnePhotoPerSheet && ShowOnePerSheet,
    };

    // ---------------- Layout and preview ----------------

    /// <summary>A photo's turn, copies or crop changed.</summary>
    internal void PhotoChanged() => Relayout();

    private void Relayout()
    {
        var paper = SheetPaper;
        var photos = Photos.Select(p => p.Job).ToList();
        var grid = PhotoLayout.Grid(Options with { OnePhotoPerSheet = false }, paper, preferLandscape: false);
        ShowOnePerSheet = IsPrintSize && grid.Cells.Count > 1;
        var sheets = PhotoLayout.Sheets(photos.Select(p => p.Input).ToList(), Options, paper);

        _sheetCount = sheets.Count;
        var thumbs = Photos.Select(p => PreviewInGrey ? p.GreyThumbnail : p.Thumbnail).ToList();
        var shown = Math.Min(sheets.Count, MaxPreviews);
        while (Sheets.Count > shown) Sheets.RemoveAt(Sheets.Count - 1);
        while (Sheets.Count < shown) Sheets.Add(new PhotoSheetPreview(this));
        for (var i = 0; i < shown; i++)
            Sheets[i].Set(sheets[i], paper, photos, thumbs, $"Sheet {i + 1} of {sheets.Count}", PreviewHeight * paper.Width / paper.Height, PreviewHeight);
        MoreSheetsText = sheets.Count > MaxPreviews ? $"+ {sheets.Count - MaxPreviews} more sheets" : null;

        // Resolution each photo prints at (its smallest print), and the warnings that go with it.
        foreach (var item in Photos) item.Dpi = null;
        foreach (var cell in sheets.SelectMany(s => s.Cells))
        {
            var item = Photos[cell.Photo];
            var input = photos[cell.Photo].Input;
            var dpi = PhotoLayout.Dpi(input.Width, input.Height, cell.Image, cell.Turned);
            if (item.Dpi is not { } known || dpi < known) item.Dpi = dpi;
        }

        var paperName = (Paper ?? FallbackPaper).Label;
        var prints = sheets.Sum(s => s.Cells.Count);
        Summary = Photos.Count == 0 ? null
            : IsContactSheet ? $"{Count(Photos.Count, "photo")} on {Count(sheets.Count, "sheet")} of {paperName}, {PerSheet.Value} per sheet with their file names."
            : $"{Count(Photos.Count, "photo")}, {Count(prints, "print")} on {Count(sheets.Count, "sheet")} of {paperName}.";
        var warnings = new List<string>();
        if (grid.Shrunk && Layout.Size is { } size)
            warnings.Add($"{size.Name} doesn't fit inside this paper's printable area, so it prints a little smaller." +
                         (CanBorderless && !Borderless ? " Turn on Borderless or choose larger paper." : " Choose larger paper."));
        if (!IsContactSheet && Photos.Where(p => p.IsLowResolution).ToList() is { Count: > 0 } soft)
            warnings.Add(soft.Count == 1
                ? $"{soft[0].Name} prints at about {soft[0].Dpi:0} dpi, so it may look soft. A smaller size prints it sharper."
                : $"{soft.Count} photos print below {PhotoLayout.LowDpi:0} dpi and may look soft (marked in the list).");
        Warning = warnings.Count > 0 ? string.Join(" ", warnings) : null;
        PrintCommand.NotifyCanExecuteChanged();
        UpdateSelectedCell();
    }

    private void UpdateSelectedCell()
    {
        var index = Selected is null ? -1 : Photos.IndexOf(Selected);
        SelectedCell = index < 0 ? null : Sheets.SelectMany(s => s.Sheet.Cells).FirstOrDefault(c => c.Photo == index);
    }

    private static string Count(int n, string what) => n == 1 ? $"1 {what}" : $"{n} {what}s";

    // ---------------- Printing ----------------

    /// <summary>The sheets as laid out now, for the snapshot aid's print rendering (DevSnapshot --photo-sheets).</summary>
    internal (IReadOnlyList<PhotoSheet> Sheets, IReadOnlyList<PhotoJobPhoto> Photos, SheetPaper Paper) PrintPlan()
    {
        var photos = Photos.Select(p => p.Job).ToList();
        return (PhotoLayout.Sheets(photos.Select(p => p.Input).ToList(), Options, SheetPaper), photos, SheetPaper);
    }

    /// <summary>The printer's Windows queue is being re-created (HP clean-up): hold printing until it's back.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand))]
    public partial bool QueueBusy { get; set; }

    private bool CanPrint() => !IsBusy && !IsAdding && !QueueBusy && Sheets.Count > 0;

    [RelayCommand(CanExecute = nameof(CanPrint))]
    private async Task PrintAsync()
    {
        var photos = Photos.Select(p => p.Job).ToList();
        var layout = Options;
        var settings = Settings(Paper);
        var sheets = _sheetCount;
        IsBusy = true;
        try
        {
            if (demo is not null)
            {
                demo.Print("Photos", sheets);
                SetMessage($"Sent to the demo printer: {Count(sheets, "sheet")}. Nothing really prints; the job is in the print queue on the Overview.");
                return;
            }
            if (await findQueue() is not { } queue)
            {
                SetMessage("This printer isn't set up in Windows yet. Press Set up at the top of the page, then print again.", error: true);
                return;
            }
            SetMessage("Sending the photos to the printer…");
            var sent = await PhotoPrinting.PrintAsync(queue, settings, photos, layout, "Photos");
            SetMessage($"Sent to the printer: {Count(sent, "sheet")}.");
        }
        catch (Exception ex)
        {
            // Spooler/driver/serializer errors come in many types; never let one escape the command.
            Log.Write($"Photo print failed: {ex}");
            SetMessage($"Could not print the photos: {ex.Message}", error: true);
        }
        finally
        {
            IsBusy = false;
        }
        if (Message is { } said) Prompt.Announce(said);
    }

    private void SetMessage(string? text, bool error = false)
    {
        Message = text;
        MessageIsError = error;
    }
}

/// <summary>One picture in the Photos tab: its thumbnail, the user's turns, copies and crop.</summary>
public sealed partial class PhotoItemViewModel(PhotoSource source, BitmapSource thumbnail, PhotosViewModel owner) : ObservableObject
{
    public PhotoSource Source { get; } = source;

    /// <summary>Stored orientation, <see cref="PhotoFiles.Decode"/>d small: drawn turned like the print.</summary>
    public BitmapSource Thumbnail { get; } = thumbnail;

    public string Name => Source.Name;

    /// <summary>The thumbnail in shades of grey, for printers (or choices) that print in black only.</summary>
    public BitmapSource GreyThumbnail => _grey ??= Grey(Thumbnail);

    private BitmapSource? _grey;

    /// <summary>Flattened on white first: transparent areas print as paper, not black.</summary>
    private static BitmapSource Grey(BitmapSource color)
    {
        var visual = new System.Windows.Media.DrawingVisual();
        var area = new System.Windows.Rect(0, 0, color.PixelWidth, color.PixelHeight);
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(System.Windows.Media.Brushes.White, null, area);
            dc.DrawImage(color, area);
        }
        var flat = new RenderTargetBitmap(color.PixelWidth, color.PixelHeight, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        flat.Render(visual);
        var grey = new FormatConvertedBitmap(flat, System.Windows.Media.PixelFormats.Gray8, null, 0);
        grey.Freeze();
        return grey;
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Turns), nameof(ThumbnailAngle))]
    public partial int UserTurns { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CopiesText), nameof(AccessibleText))]
    public partial int Copies { get; private set; } = 1;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ZoomPercent))]
    public partial PhotoCrop Crop { get; private set; } = PhotoCrop.None;

    /// <summary>The resolution its smallest print comes out at (null: not printed in this layout).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsLowResolution), nameof(DpiText), nameof(AccessibleText))]
    public partial double? Dpi { get; set; }

    public bool IsLowResolution => Dpi is { } d and > 0 && d < PhotoLayout.LowDpi;
    public string? DpiText => Dpi is { } d and > 0 ? $"Prints at about {d:0} dpi{(IsLowResolution ? ": may look soft" : "")}" : null;

    public int Turns => ExifOrientation.Turns(Source.Orientation, UserTurns);
    public bool Mirror => ExifOrientation.Transform(Source.Orientation).Mirror;

    /// <summary>For the list's thumbnail (an Image with a RotateTransform).</summary>
    public double ThumbnailAngle => Turns * 90;
    public double ThumbnailScaleX => Mirror ? -1 : 1;

    public string CopiesText => Copies == 1 ? "1 copy" : $"{Copies} copies";
    public string AccessibleText => $"{Name}, {CopiesText}{(IsLowResolution ? ", low resolution" : "")}";

    public PhotoJobPhoto Job => new(Source, UserTurns, Copies, Crop);

    /// <summary>Zoom slider, 100-400%.</summary>
    public double ZoomPercent
    {
        get => Crop.Zoom * 100;
        set => SetCrop(Crop with { Zoom = Math.Clamp(value / 100, 1, PhotoCrop.MaxZoom) });
    }

    public void Turn(int quarters)
    {
        UserTurns = ((UserTurns + quarters) % 4 + 4) % 4;
        Crop = PhotoCrop.None; // the old crop was for the other shape
        owner.PhotoChanged();
        Prompt.Announce($"{Name} turned {(quarters < 0 ? "left" : "right")}.");
    }

    public void SetCopies(int copies)
    {
        copies = Math.Clamp(copies, 1, 99);
        if (copies == Copies) return;
        Copies = copies;
        owner.PhotoChanged();
    }

    /// <summary>Text box binding for copies.</summary>
    public int CopiesInput
    {
        get => Copies;
        set
        {
            SetCopies(value);
            OnPropertyChanged();
        }
    }

    partial void OnCopiesChanged(int value) => OnPropertyChanged(nameof(CopiesInput));

    public void SetCrop(PhotoCrop crop)
    {
        if (crop == Crop) return;
        Crop = crop;
        owner.PhotoChanged();
    }
}

/// <summary>
/// One sheet in the preview: the layout, the paper and what to draw the photos with. Kept and updated in place when the
/// layout changes (<see cref="Version"/>), so a drag on a preview isn't cut off by its view being made again.
/// </summary>
public sealed partial class PhotoSheetPreview(PhotosViewModel owner) : ObservableObject
{
    public PhotosViewModel Owner { get; } = owner;
    public PhotoSheet Sheet { get; private set; } = new([]);
    public SheetPaper Paper { get; private set; }
    public IReadOnlyList<PhotoJobPhoto> Photos { get; private set; } = [];
    public IReadOnlyList<BitmapSource> Thumbnails { get; private set; } = [];

    [ObservableProperty] public partial string Label { get; private set; } = "";
    [ObservableProperty] public partial double PreviewWidth { get; private set; }
    [ObservableProperty] public partial double PreviewHeight { get; private set; }

    /// <summary>Bumped on every change: the view redraws.</summary>
    [ObservableProperty] public partial int Version { get; private set; }

    public void Set(PhotoSheet sheet, SheetPaper paper, IReadOnlyList<PhotoJobPhoto> photos, IReadOnlyList<BitmapSource> thumbnails, string label,
        double width, double height)
    {
        (Sheet, Paper, Photos, Thumbnails) = (sheet, paper, photos, thumbnails);
        (Label, PreviewWidth, PreviewHeight) = (label, width, height);
        Version++;
    }

    public void Touch() => Version++;
}

/// <summary>Demo mode: a made-up queue's photo options, and where its jobs "print".</summary>
public sealed record DemoPhotoQueue(PhotoQueueOptions Options, Func<PaperChoice, PaperSetup> Setup, Action<string, int> Print);
