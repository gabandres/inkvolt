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
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Print a PDF: open it (button, drag-and-drop or "Open with"), see how many pages it has with
/// thumbnails, pick pages / copies / two-sided, and send it to this printer's Windows queue.
/// </summary>
public sealed partial class PrintViewModel(Func<Task<string?>> findQueue, AppState state) : ObservableObject
{
    private const int MaxThumbnails = 60;

    private PdfSource? _pdf;
    private CancellationTokenSource? _cts;
    private int _openGeneration;
    private bool _twoSidedChecked;

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

    [ObservableProperty] public partial bool CanTwoSided { get; set; }

    /// <summary>Enlarge small pages (labels, receipts) to fill the paper; off prints them at their own size.</summary>
    [ObservableProperty] public partial bool FitToPaper { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand), nameof(BrowseCommand))]
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
            var perCopy = TwoSided ? (pages.Count + 1) / 2 : pages.Count;
            var sheets = perCopy * Copies;
            var paper = TwoSided
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

    /// <summary>Loads a PDF: page count immediately, thumbnails stream in after.</summary>
    public async Task OpenAsync(string path)
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
            state.PrintFolder = Path.GetDirectoryName(path);
            state.Save();
            FileName = Path.GetFileName(path);
            RangeText = "";
            AllPages = true;
            PageCount = pdf.PageCount;
            var (w, h) = pdf.PageSizeInches(1);
            PaperText = PaperName(w, h);
            OnPropertyChanged(nameof(Summary));
            PrintCommand.NotifyCanExecuteChanged();
            _ = RefreshTwoSidedAsync();
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

    /// <summary>The printer's Windows queue was just created or removed: re-check what it can do.</summary>
    public void QueueChanged()
    {
        Batch?.QueueChanged();
        _twoSidedChecked = false;
        if (_pdf is not null) _ = RefreshTwoSidedAsync();
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

    /// <summary>Asks the Windows queue once whether the printer can do two-sided (off the UI thread).</summary>
    private async Task RefreshTwoSidedAsync()
    {
        if (_twoSidedChecked) return;
        try
        {
            var queue = await findQueue();
            if (queue is null)
            {
                CanTwoSided = false;
            }
            else
            {
                // Asking the driver can take several seconds (it queries the printer): show the last known answer now.
                if (state.GetTwoSided(queue) is { } known) CanTwoSided = known;
                CanTwoSided = await Task.Run(() =>
                {
                    using var q = QueuePrinter.Open(queue);
                    return QueuePrinter.SupportsTwoSided(q);
                });
                state.SetTwoSided(queue, CanTwoSided);
                _twoSidedChecked = true;
            }
        }
        catch (Exception ex)
        {
            Log.Write($"Two-sided check failed: {ex}");
            CanTwoSided = false;
        }
        if (!CanTwoSided) TwoSided = false;
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
            var queueName = await findQueue();
            if (queueName is null)
            {
                SetMessage(Strings.Print_NotSetUp, error: true);
                return;
            }
            var progress = new Progress<string>(m => SetMessage(m));
            await QueuePrinter.PrintAsync(queueName, _pdf, new PrintOptions(pages, Copies, TwoSided && CanTwoSided, FileName ?? "PDF",
                    FitToPaper ? PageSizing.FitToPaper : PageSizing.ActualSize),
                progress, _cts.Token, onSpooling: () => IsSpooling = true);
            SetMessage(string.Format(Strings.Print_Sent, PagesAndCopies(pages.Count, Copies), sw.Elapsed.TotalSeconds));
            RatingRequest.NoteSuccess(state);
        }
        catch (OperationCanceledException)
        {
            SetMessage(Strings.Print_Cancelled);
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
