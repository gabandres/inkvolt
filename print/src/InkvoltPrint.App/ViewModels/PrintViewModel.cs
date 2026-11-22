using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Printing;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Print a PDF: open it (button, drag-and-drop or "Open with"), see how many pages it has with
/// thumbnails, pick pages / copies / two-sided, and send it to this printer's Windows queue, or straight to the printer
/// over IPP when it has none or the person chose that (roadmap 2.1, <see cref="PrintTarget"/>).
/// </summary>
public sealed partial class PrintViewModel(Func<Task<PrintTarget?>> findTarget, AppState state) : ObservableObject
{
    private const int MaxThumbnails = 60;

    private PdfSource? _pdf;
    private CancellationTokenSource? _cts;
    private int _openGeneration;

    public ObservableCollection<PdfThumbnail> Thumbnails { get; } = [];

    /// <summary>Print › Batch: many files at once.</summary>
    public BatchPrintViewModel? Batch { get; init; }

    /// <summary>The tab shows Batch rather than one PDF.</summary>
    [ObservableProperty] public partial bool ShowBatch { get; set; }

    partial void OnShowBatchChanged(bool value)
    {
        if (value) Batch?.Shown();
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasDocument))]
    public partial string? FileName { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PageCountText), nameof(AllPagesText), nameof(Summary), nameof(MoreThumbnailsText))]
    public partial int PageCount { get; set; }

    [ObservableProperty] public partial string? PaperText { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand))]
    public partial bool AllPages { get; set; } = true;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand))]
    public partial string RangeText { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial int Copies { get; set; } = 1;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial bool TwoSided { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowTwoSided), nameof(TwoSidedText), nameof(Summary))]
    public partial bool CanTwoSided { get; set; }

    /// <summary>The printer said it can't print both sides: two-sided by hand is offered in its place (roadmap 4.2).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowTwoSided), nameof(TwoSidedText), nameof(Summary))]
    public partial bool OffersByHand { get; set; }

    /// <summary>Set by the printer: which way up its sheets land, for two-sided by hand.</summary>
    public HandDuplexPrinter? ByHand { get; init; }

    public bool ShowTwoSided => CanTwoSided || OffersByHand;

    public string TwoSidedText => CanTwoSided ? Strings.PrintTab_BothSides : Strings.Hand_BothSides;

    /// <summary>Two-sided is asked and the printer can't: the fronts, the reload prompt, the backs.</summary>
    private bool PrintsByHand => TwoSided && !CanTwoSided && OffersByHand && ByHand is not null;

    /// <summary>Enlarge small pages (labels, receipts) to fill the paper; off prints them at their own size.</summary>
    [ObservableProperty] public partial bool FitToPaper { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand), nameof(BrowseCommand), nameof(PrintClipboardCommand))]
    [NotifyPropertyChangedFor(nameof(CanCancel))]
    public partial bool IsBusy { get; set; }

    /// <summary>The job is being handed to Windows; it can no longer be cancelled from here (use the Windows queue).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCancel))]
    public partial bool IsSpooling { get; set; }

    public bool CanCancel => IsBusy && !IsSpooling;

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    public bool HasDocument => FileName is not null;
    public string PageCountText => Core.Plural.Of(PageCount, Strings.Print_Pages_One, Strings.Print_Pages_Many);
    public string AllPagesText => Core.Plural.Of(PageCount, Strings.Print_AllPages_One, Strings.Print_AllPages_Many);
    public string? MoreThumbnailsText => PageCount > MaxThumbnails
        ? Core.Plural.Of(PageCount - MaxThumbnails, Strings.Print_MorePages_One, Strings.Print_MorePages_Many)
        : null;

    /// <summary>Error for the page-range box, or null.</summary>
    public string? RangeError => AllPages || PageCount == 0 || PageRange.TryParse(RangeText, PageCount, out _, out var e) ? null : e;

    /// <summary>"Prints 3 pages × 2 copies on 6 sheets of paper."</summary>
    public string Summary
    {
        get
        {
            if (PageCount == 0 || !TrySelectedPages(out var pages)) return "";
            var both = TwoSided && ShowTwoSided;
            var perCopy = both ? (pages.Count + 1) / 2 : pages.Count;
            var sheets = perCopy * Copies;
            var paper = PrintsByHand
                ? Core.Plural.Of(sheets, Strings.Hand_Sheets_One, Strings.Hand_Sheets_Many)
                : both
                ? Core.Plural.Of(sheets, Strings.Print_SheetsBothSides_One, Strings.Print_SheetsBothSides_Many)
                : Core.Plural.Of(sheets, Strings.Print_Sheets_One, Strings.Print_Sheets_Many);
            return string.Format(Strings.Print_Summary, PagesAndCopies(pages.Count, Copies), paper);
        }
    }

    /// <summary>"3 pages", or "3 pages × 2 copies".</summary>
    private static string PagesAndCopies(int pages, int copies)
    {
        var what = Core.Plural.Of(pages, Strings.Print_Pages_One, Strings.Print_Pages_Many);
        return copies > 1 ? string.Format(Strings.Print_PagesTimesCopies, what, copies) : what;
    }

    partial void OnRangeTextChanged(string value)
    {
        if (value.Length > 0) AllPages = false;
        OnPropertyChanged(nameof(RangeError));
    }

    partial void OnAllPagesChanged(bool value) => OnPropertyChanged(nameof(RangeError));

    partial void OnCopiesChanged(int value)
    {
        if (value < 1) Copies = 1;
        else if (value > 99) Copies = 99;
    }

    [RelayCommand] private void MoreCopies() => Copies++;
    [RelayCommand] private void FewerCopies() => Copies--;

    private bool NotBusy() => !IsBusy;

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private async Task BrowseAsync()
    {
        var dialog = new OpenFileDialog
        {
            Title = Strings.Print_ChoosePdf,
            Filter = Strings.Print_PdfFilter + "|*.pdf",
            InitialDirectory = state.PrintFolder is { } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };
        if (dialog.ShowDialog() == true) await OpenAsync(dialog.FileName);
    }

    /// <summary>Set by the view: asks for a PDF's password. Args: file name, previous attempt was wrong.</summary>
    public static Func<string, bool, string?>? AskPdfPassword { get; set; }

    /// <summary>Loads a PDF: page count immediately, thumbnails stream in after. <paramref name="rememberFolder"/>: Browse starts there next time.</summary>
    public async Task OpenAsync(string path, bool rememberFolder = true)
    {
        if (IsBusy)
        {
            SetMessage(string.Format(Strings.Print_StillSending, Path.GetFileName(path)), error: true);
            return;
        }
        var generation = ++_openGeneration;
        SetMessage(null);
        Thumbnails.Clear();
        try
        {
            PdfSource? pdf = null;
            string? password = null;
            for (var attempt = 0; pdf is null; attempt++)
            {
                try
                {
                    pdf = await PdfSource.OpenAsync(path, password);
                }
                catch (PdfOpenException ex) when (ex.IsPasswordProtected)
                {
                    password = AskPdfPassword?.Invoke(Path.GetFileName(path), attempt > 0);
                    if (password is null) throw;
                }
            }
            if (generation != _openGeneration) return;
            _pdf = pdf;
            if (rememberFolder)
            {
                state.PrintFolder = Path.GetDirectoryName(path);
                state.Save();
            }
            FileName = Path.GetFileName(path);
            RangeText = "";
            AllPages = true;
            PageCount = pdf.PageCount;
            var (w, h) = pdf.PageSizeInches(1);
            PaperText = PaperName(w, h);
            OnPropertyChanged(nameof(Summary));
            PrintCommand.NotifyCanExecuteChanged();
            _ = TwoSidedRead.AskAsync();
            await LoadThumbnailsAsync(pdf, generation);
        }
        catch (PdfOpenException ex)
        {
            Clear();
            SetMessage(ex.IsPasswordProtected ? Strings.Print_PasswordNotEntered : ex.Message, error: true);
        }
        catch (Exception ex)
        {
            Log.Write($"Open PDF failed: {ex}");
            Clear();
            SetMessage(string.Format(Strings.Print_CouldNotOpen, ex.Message), error: true);
        }
    }

    /// <summary>Where the printer's jobs go (<see cref="PrintRouting"/>): this tab hears when that changes.</summary>
    public required PrintRouting Routing
    {
        get;
        init
        {
            field = value;
            value.Changed += RoutingChanged;
        }
    }

    /// <summary>The printer takes PWG raster, Apple raster or PCLm and it has a Windows queue too: the person may choose (roadmap 2.1).</summary>
    public bool CanChooseDirect => Routing.CanChooseDirect;

    /// <summary>Print straight to the printer rather than through its Windows queue (kept per printer).</summary>
    public bool PrintDirect
    {
        get => Routing.ChoseDirect;
        set => _ = Routing.ChooseDirectAsync(value);
    }

    /// <summary>The line saying pages go straight to the printer, or null when they go through the Windows queue.</summary>
    public string? RouteNote => Routing.Note switch
    {
        PrintRouteNote.Direct => Strings.Print_RouteDirect,
        PrintRouteNote.DirectChosen => Strings.Print_RouteDirectChosen,
        _ => null,
    };

    /// <summary>The route, the choice or the Windows queue changed: show it, and check two-sided again once it was checked (Batch hears it itself).</summary>
    private void RoutingChanged()
    {
        OnPropertyChanged(nameof(CanChooseDirect));
        OnPropertyChanged(nameof(PrintDirect));
        OnPropertyChanged(nameof(RouteNote));
        TwoSidedRead.RouteChanged();
    }

    private async Task LoadThumbnailsAsync(PdfSource pdf, int generation)
    {
        try
        {
            for (var n = 1; n <= Math.Min(pdf.PageCount, MaxThumbnails); n++)
            {
                var page = await pdf.RenderAsync(n, dpi: 0, maxWidthPx: 220);
                if (generation != _openGeneration) return;
                Thumbnails.Add(new PdfThumbnail(n, Decode(page.Image)));
            }
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Thumbnail failed: {ex.Message}"); // preview only; printing renders again
        }
    }

    /// <summary>Whether the printer can do two-sided, asked once a PDF is open and again after a change of route (<see cref="RouteRead"/>).</summary>
    private RouteRead TwoSidedRead => field ??= new(CheckTwoSidedAsync);

    /// <summary>Asks the Windows queue (or the printer) whether it can do two-sided, off the UI thread. True when it answered.</summary>
    private async Task<bool> CheckTwoSidedAsync()
    {
        var answered = false;
        try
        {
            var target = await findTarget();
            if (target is null)
            {
                CanTwoSided = false;
            }
            else
            {
                // Asking the driver can take several seconds (it queries the printer): show the last known answer now.
                if (target is PrintTarget.Queue { Name: var queue } && state.GetTwoSided(queue) is { } known) CanTwoSided = known;
                CanTwoSided = await PrintTargets.SupportsTwoSidedAsync(target, state);
                answered = true;
            }
        }
        catch (Exception ex)
        {
            Log.Write($"Two-sided check failed: {ex}");
            CanTwoSided = false;
        }
        if (HandDuplexPrinting.Forced) CanTwoSided = false;
        OffersByHand = ByHand is not null && answered && HandDuplex.Offered(CanTwoSided);
        if (!ShowTwoSided) TwoSided = false;
        return answered;
    }

    /// <summary>The printer's Windows queue is being re-created (HP clean-up): hold printing until it's back.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand))]
    public partial bool QueueBusy { get; set; }

    partial void OnQueueBusyChanged(bool value)
    {
        if (Batch is not null) Batch.QueueBusy = value;
    }

    private bool CanPrint() => !IsBusy && !QueueBusy && _pdf is not null && (AllPages || PageRange.TryParse(RangeText, PageCount, out _, out _));

    [RelayCommand(CanExecute = nameof(CanPrint))]
    private async Task PrintAsync()
    {
        if (_pdf is null || !TrySelectedPages(out var pages)) return;
        IsBusy = true;
        _cts = new CancellationTokenSource();
        var sw = Stopwatch.StartNew();
        try
        {
            var target = await findTarget();
            if (target is null)
            {
                SetMessage(Strings.Print_NotSetUp, error: true);
                return;
            }
            var progress = new Progress<string>(m => { if (IsBusy) SetMessage(m); }); // a late report never covers the result
            var sizing = FitToPaper ? PageSizing.FitToPaper : PageSizing.ActualSize;
            if (PrintsByHand)
            {
                var outcome = await PrintTargets.PrintPdfByHandAsync(target, _pdf, new PrintOptions(pages, Copies, false, FileName ?? "PDF", sizing), ByHand!,
                    progress, _cts.Token, onSpooling: () => IsSpooling = true, onSent: () => IsSpooling = false);
                SetMessage(outcome switch
                {
                    HandDuplexOutcome.FrontsOnly => Strings.Hand_FrontsOnly,
                    HandDuplexOutcome.OneSide => string.Format(Strings.Print_Sent, PagesAndCopies(pages.Count, Copies), sw.Elapsed.TotalSeconds),
                    _ => string.Format(Strings.Hand_Done, PagesAndCopies(pages.Count, Copies)),
                });
                if (outcome == HandDuplexOutcome.Both) RatingRequest.NoteSuccess(state);
                return;
            }
            var printed = await PrintTargets.PrintPdfAsync(target, _pdf, new PrintOptions(pages, Copies, TwoSided && CanTwoSided, FileName ?? "PDF", sizing),
                progress, _cts.Token, onSpooling: () => IsSpooling = true, onSent: () => IsSpooling = false);
            SetMessage(string.Format(printed ? Strings.Print_SentDirect : Strings.Print_Sent, PagesAndCopies(pages.Count, Copies), sw.Elapsed.TotalSeconds));
            RatingRequest.NoteSuccess(state);
        }
        catch (OperationCanceledException)
        {
            SetMessage(Strings.Print_Cancelled);
        }
        catch (Core.Printing.Direct.DirectPrintException ex)
        {
            Log.Write($"Direct print failed: {ex.Message} (IPP status {(ex.IppStatus is { } s ? $"0x{s:X4}" : "none")})");
            SetMessage(ex.Message, error: true);
        }
        catch (Exception ex)
        {
            // Spooler/driver/serializer errors come in many types; never let one escape the command.
            Log.Write($"Print failed: {ex}");
            SetMessage(string.Format(Strings.Print_CouldNotPrint, ex.Message), error: true);
        }
        finally
        {
            _cts.Dispose();
            _cts = null;
            IsBusy = false;
            IsSpooling = false;
        }
    }

    /// <summary>Set by the printer: opens pictures in its Print photos (the clipboard's picture, pictures copied in File Explorer).</summary>
    public Func<IReadOnlyList<string>, Task>? OpenPictures { get; init; }

    /// <summary>What the clipboard holds and its picture; the developer snapshot puts made-up content here (never the real clipboard).</summary>
    public static Func<(ClipboardContent Content, BitmapSource? Picture)> ReadClipboard { get; set; } = ClipboardPrinting.Read;

    /// <summary>
    /// Print the clipboard (roadmap 4.13): what's on it goes where it prints with the usual options (<see cref="ClipboardPrint.Choose"/>):
    /// text laid out on pages into Print a PDF, a picture or pictures into Print photos, one PDF into Print a PDF, several files into Batch.
    /// </summary>
    [RelayCommand(CanExecute = nameof(NotBusy))]
    public async Task PrintClipboardAsync()
    {
        SetMessage(null);
        ClipboardContent content;
        BitmapSource? picture;
        try
        {
            (content, picture) = ReadClipboard();
        }
        catch (ClipboardBusyException)
        {
            SetMessage(Strings.Clip_Busy, error: true);
            return;
        }
        var plan = ClipboardPrint.Choose(content);
        var name = ClipboardPrint.Name(DateTime.Now, Strings.Clip_FileWord);
        try
        {
            switch (plan.What)
            {
                case ClipboardWhat.Pdf:
                    ShowBatch = false;
                    await OpenAsync(plan.Files[0]);
                    break;
                case ClipboardWhat.Batch when Batch is not null:
                    ShowBatch = true;
                    await Batch.AddAsync(plan.Files);
                    break;
                case ClipboardWhat.Pictures when OpenPictures is not null:
                    await OpenPictures(plan.Files);
                    break;
                case ClipboardWhat.Picture when picture is not null && OpenPictures is not null:
                    await OpenPictures([ClipboardPrinting.SavePicture(picture, name)]);
                    break;
                case ClipboardWhat.Text:
                    ShowBatch = false;
                    // Laid out off the UI thread, busy (Cancel stops it) so nothing else opens meanwhile; a file opened or removed
                    // before it's done (Remove isn't held) is left as it is.
                    var generation = _openGeneration;
                    (string? Path, int Pages, bool Cut) made;
                    IsBusy = true;
                    _cts = new CancellationTokenSource();
                    try
                    {
                        SetMessage(Strings.Clip_LayingOut);
                        made = await ClipboardPrinting.TextPdfAsync(content.Text!, name, System.Globalization.RegionInfo.CurrentRegion.IsMetric, _cts.Token);
                    }
                    finally
                    {
                        _cts.Dispose();
                        _cts = null;
                        IsBusy = false;
                    }
                    if (made.Path is not { } path)
                    {
                        SetMessage(Strings.Clip_Nothing, error: true);
                        break;
                    }
                    if (generation != _openGeneration)
                    {
                        SetMessage(Strings.Clip_NotOpened);
                        break;
                    }
                    await OpenAsync(path, rememberFolder: false);
                    SetMessage(made.Cut ? string.Format(Strings.Clip_TextCut, ClipboardPrint.MaxPages) : Core.Plural.Of(made.Pages, Strings.Clip_Text_One, Strings.Clip_Text_Many));
                    break;
                case ClipboardWhat.NotPrintable:
                    SetMessage(Strings.Clip_NotPrintable, error: true);
                    break;
                case ClipboardWhat.TooBig:
                    SetMessage(Strings.Clip_TooBig, error: true);
                    break;
                default:
                    SetMessage(Strings.Clip_Nothing, error: true);
                    break;
            }
        }
        catch (OperationCanceledException)
        {
            SetMessage(Strings.Clip_Cancelled);
        }
        catch (Exception ex) // whatever the clipboard, the disk or the drawing throws: a plain message, the details in the log
        {
            Log.Write($"Print the clipboard failed: {ex}");
            SetMessage(Strings.Clip_Failed, error: true);
        }
    }

    [RelayCommand]
    private void Cancel() => _cts?.Cancel();

    [RelayCommand]
    private void Clear()
    {
        _openGeneration++;
        _pdf = null;
        FileName = null;
        PageCount = 0;
        PaperText = null;
        Thumbnails.Clear();
        SetMessage(null);
        PrintCommand.NotifyCanExecuteChanged();
    }

    [RelayCommand]
    private void OpenPrintQueue()
    {
        Shell.Open("ms-settings:printers");
    }

    private bool TrySelectedPages(out IReadOnlyList<int> pages)
    {
        if (AllPages) return PageRange.TryParse(null, PageCount, out pages, out _);
        return PageRange.TryParse(RangeText, PageCount, out pages, out _);
    }

    private void SetMessage(string? text, bool error = false)
    {
        Message = text;
        MessageIsError = error;
    }

    private static string PaperName(double w, double h)
    {
        var (a, b) = (Math.Min(w, h), Math.Max(w, h));
        bool Near(double x, double y) => Math.Abs(a - x) < 0.08 && Math.Abs(b - y) < 0.08;
        var name = Near(8.5, 11) ? Strings.Print_PaperLetter : Near(8.5, 14) ? Strings.Print_PaperLegal : Near(8.27, 11.69) ? "A4" : Near(5.83, 8.27) ? "A5" : null;
        if (name is null) return string.Format(Strings.Print_PaperInches, w, h);
        return w > h ? string.Format(Strings.Print_PaperLandscape, name) : name;
    }

    private static BitmapSource Decode(byte[] jpeg)
    {
        var img = new BitmapImage();
        img.BeginInit();
        img.CacheOption = BitmapCacheOption.OnLoad;
        img.StreamSource = new MemoryStream(jpeg);
        img.EndInit();
        img.Freeze();
        return img;
    }
}

public sealed record PdfThumbnail(int Number, BitmapSource Image);
