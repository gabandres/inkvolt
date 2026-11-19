using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Copy: scan (over eSCL, or through the scanner's Windows driver), then print what was scanned through the printer's Windows queue at actual size, in one step.
/// Pages can go 2 or 4 to a side, uncollated, and wait in the preview for Print. ID card copy scans the front from the glass,
/// asks for the card to be turned over, scans the back and prints both on one sheet (top and bottom halves). Needs a scanner
/// and a Windows queue; says which one is missing otherwise. An HP printer whose own copier takes requests
/// (<see cref="PrinterCopier"/>) copies by itself instead, unless the user picks Through this PC (<see cref="CopyRoute"/>).
/// </summary>
/// <param name="demoPrint">Demo printer: instead of a Windows queue, "prints" here (job name, sheets).</param>
public sealed partial class CopyViewModel(Func<Task<string?>> findQueue, AppState state, Action<string, int>? demoPrint = null) : ObservableObject
{
    private const int CopyDpi = 300;
    private const double PreviewHeight = 520;

    private IScanner? _client;
    private ScannerCapabilities? _caps;
    private CancellationTokenSource? _cts;
    private RenderedPage? _front;
    private bool _twoSidedChecked;

    /// <summary>The last copy that didn't reach the queue, kept (scans included) so it can be sent again without rescanning.</summary>
    private Func<Task>? _printAgain;

    /// <summary>The printer's own copier (HP LEDM), when it takes requests; null otherwise.</summary>
    private PrinterCopier? _printer;

    /// <summary>Pages scanned for a copy that waits in the preview for Print (<see cref="PreviewFirst"/>).</summary>
    private List<RenderedPage>? _previewed;

    /// <summary>Paper for the preview: Letter or A4 by region (the queue decides the real paper when printing).</summary>
    private static readonly (double W, double H) PreviewPaper = RegionInfo.CurrentRegion.IsMetric ? (793.7, 1122.5) : (816, 1056);

    public ObservableCollection<CopySheet> Sheets { get; } = [];

    /// <summary>The printer connected and said whether it has a scanner.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(UnavailableReason), nameof(IsAvailable))]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand))]
    public partial bool ScannerChecked { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(UnavailableReason), nameof(IsAvailable))]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand))]
    public partial bool HasScanner { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(UnavailableReason), nameof(IsAvailable))]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand))]
    public partial bool HasQueue { get; set; }

    /// <summary>Another device answers at the printer's address: copying is off until the printer is back (<see cref="Attach"/>).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(UnavailableReason), nameof(IsAvailable))]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand))]
    public partial string? Blocked { get; set; }

    public void Detach(string reason)
    {
        _client = null;
        AttachPrinterCopy(null);
        Blocked = reason;
    }

    /// <summary>The printer connected: its own copier when it takes requests (<see cref="PrinterCopier.DetectAsync"/>), else null.</summary>
    public void AttachPrinterCopy(PrinterCopier? copier)
    {
        _printer = copier;
        HasPrinterCopy = copier is not null;
        RouteChanged();
    }

    /// <summary>The printer's own copier takes requests (an HP printer listing LEDM's copy settings with a start).</summary>
    [ObservableProperty] public partial bool HasPrinterCopy { get; private set; }

    /// <summary>Copy with the printer itself (the default when it can), not through this PC.</summary>
    [ObservableProperty] public partial bool OnPrinterChosen { get; set; } = true;

    /// <summary>This copy is made by the printer by itself: no scan comes to the PC, no Windows queue is used.</summary>
    public bool OnPrinter => CopyRoute.OnPrinter(HasPrinterCopy, OnPrinterChosen, IdCard);

    /// <summary>The choice between the printer itself and this PC: only when the printer offers it, for page copies.</summary>
    public bool ShowWhere => HasPrinterCopy && !IdCard;

    /// <summary>Options only the PC's copy has: the scan source, size, pages per sheet, the preview.</summary>
    public bool ShowPcOptions => IsDocument && !OnPrinter;

    public bool ShowSource => HasSourceChoice && ShowPcOptions;
    public bool ShowCopies => !OnPrinter || _printer?.Offer.CanSetCopies == true;
    public bool ShowColor => !OnPrinter || _printer?.Offer.CanColor == true;
    public bool ShowCollate => IsDocument && Copies > 1 && (!OnPrinter || _printer?.Offer.CanCollate == true);

    partial void OnOnPrinterChosenChanged(bool value) => RouteChanged();

    /// <summary>The way a copy goes changed (printer found or gone, the choice, ID card): everything shown that depends on it.</summary>
    private void RouteChanged()
    {
        foreach (var name in new[] { nameof(OnPrinter), nameof(ShowWhere), nameof(ShowPcOptions), nameof(ShowSource), nameof(ShowCopies),
                     nameof(ShowColor), nameof(ShowCollate), nameof(ShowTwoSided), nameof(UnavailableReason), nameof(IsAvailable),
                     nameof(EmptyHint), nameof(Summary) })
            OnPropertyChanged(name);
        CopyCommand.NotifyCanExecuteChanged();
        Copies = ClampCopies(Copies);
    }

    public string? UnavailableReason =>
        Blocked is { } blocked ? blocked
        : CopyRoute.Blocker(OnPrinter, ScannerChecked, HasScanner, HasQueue || demoPrint is not null) switch
        {
            CopyBlocker.Connecting => Strings.Copy_Connecting,
            CopyBlocker.NoScanner => Strings.Copy_NoScanner,
            CopyBlocker.NoQueue => Strings.Copy_NoQueue,
            _ => null,
        };

    public bool IsAvailable => UnavailableReason is null;

    /// <summary>ID card copy instead of a page copy.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CopyButtonText), nameof(EmptyHint), nameof(IsDocument), nameof(ShowTwoSided))]
    public partial bool IdCard { get; set; }

    public bool IsDocument => !IdCard;

    [ObservableProperty] public partial IReadOnlyList<Option<ScanSource>> Sources { get; set; } = [];
    [ObservableProperty] public partial Option<ScanSource>? Source { get; set; }
    public bool HasSourceChoice => Sources.Count > 1;

    // Made when the first Copy tab is: the interface's language is chosen at start-up, before that.
    private static readonly IReadOnlyList<Option<int>> PerSheetChoices =
        [.. CopyLayout.PagesPerSheetChoices.Select(n => new Option<int>(n, n == 1 ? Strings.Copy_PerSheet_One : string.Format(Strings.Copy_PerSheet_Many, n)))];

    public IReadOnlyList<Option<int>> PagesPerSheetChoices => PerSheetChoices;

    /// <summary>Pages on each side of paper: 1, 2-up or 4-up (<see cref="CopyLayout.NUp"/>).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial Option<int>? PagesPerSheet { get; set; } = PerSheetChoices[0];

    private int PerSheet => PagesPerSheet?.Value ?? 1;

    /// <summary>Each copy whole, in page order (1 2 3, 1 2 3); off: page by page (1 1, 2 2, 3 3).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial bool Collate { get; set; } = true;

    /// <summary>Scan, show the sheets as they'll print, and wait for Print.</summary>
    [ObservableProperty] public partial bool PreviewFirst { get; set; }

    /// <summary>A scanned copy waits in the preview for Print.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintPreviewedCommand))]
    public partial bool AwaitingPrint { get; set; }

    partial void OnPagesPerSheetChanged(Option<int>? value) => ShowPreviewed();
    partial void OnFitToPaperChanged(bool value) => ShowPreviewed();

    /// <summary>Scan in color. Off by default: the printers Inkvolt Print knows print in black only.</summary>
    [ObservableProperty] public partial bool IsColor { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial int Copies { get; set; } = 1;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial bool TwoSided { get; set; }

    /// <summary>Enlarge or shrink each page to fill the paper (a receipt made readable, an A4 page on Letter), instead of actual size.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary))]
    public partial bool FitToPaper { get; set; }

    private PageSizing Sizing => FitToPaper ? PageSizing.FitToPaper : PageSizing.ActualSize;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowTwoSided))]
    public partial bool CanTwoSided { get; set; }

    /// <summary>Two-sided output is for page copies (an ID card copy is one sheet), when the queue or the printer's own copier can.</summary>
    public bool ShowTwoSided => OnPrinter ? _printer?.Offer.CanTwoSided == true : CanTwoSided && !IdCard;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand), nameof(ScanBackCommand), nameof(StartOverCommand), nameof(PrintAgainCommand), nameof(PrintPreviewedCommand))]
    public partial bool IsBusy { get; set; }

    /// <summary>Pages are coming off the scanner (Cancel is possible); false while the copy is handed to Windows.</summary>
    [ObservableProperty] public partial bool IsScanning { get; set; }

    /// <summary>ID card: the front is scanned; waiting for the card to be turned over.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand), nameof(ScanBackCommand))]
    public partial bool AwaitingBack { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    /// <summary>The last copy failed to print (spooler or driver error, no queue yet); its scans are kept for Print again.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintAgainCommand))]
    public partial bool CanPrintAgain { get; set; }

    public string CopyButtonText => IdCard ? Strings.Copy_CopyIdCard : Strings.Common_Copy;

    public string EmptyHint => IdCard
        ? Strings.Copy_HintIdCard
        : OnPrinter
            ? Strings.Copy_HintPrinter
            : Source?.Value is ScanSource.Adf or ScanSource.AdfDuplex
                ? Strings.Copy_HintFeeder
                : Strings.Copy_HintGlass;

    public string Summary
    {
        get
        {
            if (IdCard) return Copies > 1 ? string.Format(Strings.Copy_SummaryIdCardCopies, Copies) : Strings.Copy_SummaryIdCard;
            var parts = new List<string> { Core.Plural.Of(Copies, Strings.Copy_Copies_One, Strings.Copy_Copies_Many) };
            if (OnPrinter) parts.Add(Strings.Copy_SummaryOnPrinter);
            else
            {
                if (PerSheet > 1) parts.Add(string.Format(Strings.Copy_PerSheet_Many, PerSheet));
                parts.Add(FitToPaper ? Strings.Copy_SummaryFit : Strings.Copy_SummaryActual);
            }
            if (TwoSided && ShowTwoSided) parts.Add(Strings.Copy_SummaryBothSides);
            if (!Collate && ShowCollate) parts.Add(Strings.Copy_SummaryUncollated);
            return string.Join(", ", parts) + ".";
        }
    }

    partial void OnIdCardChanged(bool value)
    {
        StartOver();
        RouteChanged();
    }

    partial void OnSourceChanged(Option<ScanSource>? value) => OnPropertyChanged(nameof(EmptyHint));

    partial void OnSourcesChanged(IReadOnlyList<Option<ScanSource>> value)
    {
        OnPropertyChanged(nameof(HasSourceChoice));
        OnPropertyChanged(nameof(ShowSource));
    }

    partial void OnCanTwoSidedChanged(bool value) => OnPropertyChanged(nameof(Summary));

    partial void OnCopiesChanged(int value)
    {
        if (ClampCopies(value) is var clamped && clamped != value) Copies = clamped;
        OnPropertyChanged(nameof(ShowCollate));
    }

    /// <summary>1 to 99, and no more than the printer's own copier takes when it makes the copy.</summary>
    private int ClampCopies(int value) => Math.Clamp(value, 1, OnPrinter && _printer is { } p ? p.Offer.MaxCopies : LedmCopy.MaxCopies);

    [RelayCommand] private void MoreCopies() => Copies++;
    [RelayCommand] private void FewerCopies() => Copies--;

    /// <summary>The printer connected: its scanner (null when it has none).</summary>
    public void Attach(IScanner? client, ScannerCapabilities? caps)
    {
        ScannerChecked = true;
        Blocked = null;
        HasScanner = client is not null && caps is not null;
        _client = client;
        if (caps is null || ReferenceEquals(caps, _caps)) return;
        _caps = caps;
        Sources = caps.Sources.Select(s => new Option<ScanSource>(s, ScanChoices.SourceLabel(s))).ToList();
        Source = Sources.FirstOrDefault();
    }

    /// <summary>The printer's Windows queue appeared or went away: re-check two-sided printing.</summary>
    public void QueueChanged()
    {
        _twoSidedChecked = false;
        _ = RefreshTwoSidedAsync();
    }

    /// <summary>The Copy tab is on screen: find out (once) whether the queue prints two-sided.</summary>
    public void Shown() => _ = RefreshTwoSidedAsync();

    private bool CanCopy() => IsAvailable && !IsBusy && !AwaitingBack;

    [RelayCommand(CanExecute = nameof(CanCopy))]
    private async Task CopyAsync()
    {
        if (IdCard) await ScanFrontAsync();
        else if (OnPrinter) await CopyOnPrinterAsync();
        else await CopyPagesAsync();
    }

    /// <summary>Asks the printer's own copier for the copy: one request, nothing scanned to the PC, no queue.</summary>
    private async Task CopyOnPrinterAsync()
    {
        if (_printer is not { } printer) return;
        StartOver();
        IsBusy = true;
        try
        {
            SetMessage(Strings.Copy_StartingPrinter);
            var offer = printer.Offer;
            var copies = offer.CanSetCopies ? ClampCopies(Copies) : 1;
            var result = await printer.CopyAsync(new PrinterCopyRequest(copies, Collate, TwoSided && offer.CanTwoSided, IsColor && offer.CanColor));
            if (result.Problem is { } problem) SetMessage(problem, error: true);
            else
            {
                SetMessage(string.Format(Strings.Copy_SentPrinter, Core.Plural.Of(copies, Strings.Copy_Copies_One, Strings.Copy_Copies_Many)));
                RatingRequest.NoteSuccess(state);
            }
        }
        catch (LedmAuthRequiredException ex)
        {
            SetMessage(string.Format(Strings.Copy_PrinterNeedsPassword, ex.Message), error: true);
        }
        catch (Exception ex)
        {
            Log.Write($"Copy on the printer failed: {ex}");
            SetMessage(Strings.Copy_PrinterFailed, error: true);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task CopyPagesAsync()
    {
        if (_client is null || _caps is null) return;
        var source = Source?.Value ?? ScanSource.Platen;
        var dpi = Dpi(source);
        var size = ScanChoices.DefaultPageSize(ScanChoices.PageSizesFor(_caps, source), null, RegionInfo.CurrentRegion.IsMetric);
        _previewed = null;
        AwaitingPrint = false;
        _thumbnails.Clear();
        Sheets.Clear();
        var scanned = new List<RenderedPage>();
        var pages = await ScanAsync(ScanChoices.ToRequest(source, Color, dpi, size), dpi, page =>
        {
            scanned.Add(page);
            ShowSheets(scanned);
        });
        if (pages is not { Count: > 0 }) return;
        if (PreviewFirst)
        {
            _previewed = pages;
            AwaitingPrint = true;
            SetMessage(Strings.Copy_PreviewReady);
            return;
        }
        await PrintPagesAsync(pages);
    }

    /// <summary>Prints the copy waiting in the preview, with the options as they are now.</summary>
    [RelayCommand(CanExecute = nameof(CanPrintPreviewed))]
    private async Task PrintPreviewedAsync()
    {
        if (_previewed is not { } pages) return;
        AwaitingPrint = false;
        _previewed = null;
        await PrintPagesAsync(pages);
    }

    private bool CanPrintPreviewed() => AwaitingPrint && !IsBusy;

    private Task PrintPagesAsync(List<RenderedPage> pages)
    {
        var copies = Copies;
        var twoSided = TwoSided && CanTwoSided;
        var (perSheet, collate, sizing) = (PerSheet, Collate, Sizing);
        var sheets = CopyLayout.Sheets(pages.Count, perSheet, copies, twoSided);
        return PrintAsync("Copy", sheets, queue => QueuePrinter.PrintCopyAsync(queue, pages, copies, twoSided, collate, perSheet, "Copy", sizing),
            copies > 1 ? Core.Plural.Of(pages.Count, Strings.Copy_WhatPagesCopies_One, Strings.Copy_WhatPagesCopies_Many, copies)
                : Core.Plural.Of(pages.Count, Strings.Copy_WhatPages_One, Strings.Copy_WhatPages_Many));
    }

    /// <summary>The previewed copy laid out again after its pages per sheet or size changed.</summary>
    private void ShowPreviewed()
    {
        if (_previewed is { } pages) ShowSheets(pages);
    }

    /// <summary>The preview: each side of paper as it prints, with its pages placed (<see cref="CopyLayout.NUp"/>), one copy's worth.</summary>
    private void ShowSheets(IReadOnlyList<RenderedPage> pages)
    {
        var perSheet = PerSheet;
        var sizing = Sizing;
        var sides = CopyLayout.Sides(pages.Count, perSheet);
        for (var s = 0; s < sides.Count; s++)
        {
            var on = sides[s];
            var placed = CopyLayout.NUp([.. on.Select(i => (pages[i].WidthInches * 96, pages[i].HeightInches * 96))], perSheet, PreviewPaper.W, PreviewPaper.H, sizing);
            var images = new List<CopyImage>();
            for (var i = 0; i < placed.Count; i++)
                images.Add(new CopyImage(Thumbnail(pages[on[i]]), placed[i].At, null, placed[i].Rotated));
            var sheet = new CopySheet(PreviewPaper.W, PreviewPaper.H, PreviewHeight * PreviewPaper.W / PreviewPaper.H, PreviewHeight, images);
            if (s < Sheets.Count) Sheets[s] = sheet;
            else Sheets.Add(sheet);
        }
        while (Sheets.Count > sides.Count) Sheets.RemoveAt(Sheets.Count - 1);
    }

    private async Task ScanFrontAsync()
    {
        Sheets.Clear();
        var pages = await ScanAsync(CopyLayout.IdCardRequest(Color, Dpi(ScanSource.Platen)), Dpi(ScanSource.Platen), null);
        if (pages is not [var front, ..]) return;
        _front = front;
        ShowIdCard(front, null);
        AwaitingBack = true;
        SetMessage(null);
    }

    private bool CanScanBack() => AwaitingBack && !IsBusy;

    [RelayCommand(CanExecute = nameof(CanScanBack))]
    private async Task ScanBackAsync()
    {
        if (_front is not { } front) return;
        var pages = await ScanAsync(CopyLayout.IdCardRequest(Color, Dpi(ScanSource.Platen)), Dpi(ScanSource.Platen), null);
        if (pages is not [var back, ..]) return;
        ShowIdCard(front, back);
        AwaitingBack = false;
        _front = null;
        var copies = Copies;
        await PrintAsync("ID card copy", copies, queue => QueuePrinter.PrintIdCardAsync(queue, front, back, copies, "ID card copy"),
            copies > 1 ? string.Format(Strings.Copy_WhatCardCopies, copies) : Strings.Copy_WhatCard);
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void StartOver()
    {
        _front = null;
        ForgetPrintAgain();
        AwaitingBack = false;
        _previewed = null;
        AwaitingPrint = false;
        _thumbnails.Clear();
        Sheets.Clear();
        SetMessage(null);
    }

    private bool NotBusy() => !IsBusy;

    private bool CanRetryPrint() => CanPrintAgain && !IsBusy;

    /// <summary>Sends the copy that failed to print again, from the scans already made.</summary>
    [RelayCommand(CanExecute = nameof(CanRetryPrint))]
    private Task PrintAgainAsync() => _printAgain?.Invoke() ?? Task.CompletedTask;

    private void ForgetPrintAgain()
    {
        _printAgain = null;
        CanPrintAgain = false;
    }

    [RelayCommand]
    private void Cancel() => _cts?.Cancel();

    /// <summary>One scan job; null when it failed or was cancelled (the message says why).</summary>
    private async Task<List<RenderedPage>?> ScanAsync(ScanRequest request, int dpi, Action<RenderedPage>? added)
    {
        if (_client is null) return null;
        ForgetPrintAgain(); // a new scan replaces whatever didn't print
        IsBusy = true;
        IsScanning = true;
        _cts = new CancellationTokenSource();
        var pages = new List<RenderedPage>();
        try
        {
            SetMessage(Strings.Copy_Scanning);
            await foreach (var jpeg in _client.ScanAsync(request, _cts.Token))
            {
                var (w, h, _) = PdfWriter.JpegInfo(jpeg);
                var (wIn, hIn) = CopyLayout.Inches(w, h, dpi);
                var page = new RenderedPage(jpeg, wIn, hIn);
                pages.Add(page);
                added?.Invoke(page);
                SetMessage(string.Format(Strings.Copy_ScannedPage, pages.Count));
            }
            if (pages.Count == 0) SetMessage(Strings.Copy_NoPages, error: true);
            return pages.Count > 0 ? pages : null;
        }
        catch (OperationCanceledException)
        {
            SetMessage(Strings.Copy_Cancelled);
        }
        catch (ScanException ex)
        {
            SetMessage(ex.Message, error: true);
        }
        catch (Exception ex)
        {
            Log.Write($"Copy scan failed: {ex}");
            SetMessage(string.Format(Strings.Copy_ScanFailed, ex.Message), error: true);
        }
        finally
        {
            _cts.Dispose();
            _cts = null;
            IsScanning = false;
            IsBusy = false;
        }
        return null;
    }

    /// <summary>Hands the scanned copy to the printer's Windows queue (the demo printer's made-up queue in demo mode).</summary>
    private async Task PrintAsync(string jobName, int sheets, Func<string, Task> print, string what)
    {
        ForgetPrintAgain();
        IsBusy = true;
        try
        {
            if (demoPrint is not null)
            {
                demoPrint(jobName, sheets);
                SetMessage(string.Format(Strings.Copy_SentDemo, what));
                return;
            }
            if (await findQueue() is not { } queue)
            {
                SetMessage(Strings.Copy_NotSetUp, error: true);
                KeepForPrintAgain();
                return;
            }
            SetMessage(Strings.Copy_Sending);
            await print(queue);
            SetMessage(string.Format(Strings.Copy_Sent, what));
            RatingRequest.NoteSuccess(state);
        }
        catch (Exception ex)
        {
            // Spooler/driver/serializer errors come in many types; never let one escape the command.
            Log.Write($"Copy print failed: {ex}");
            SetMessage(string.Format(Strings.Copy_PrintFailed, ex.Message), error: true);
            KeepForPrintAgain();
        }
        finally
        {
            IsBusy = false;
        }

        void KeepForPrintAgain()
        {
            _printAgain = () => PrintAsync(jobName, sheets, print, what);
            CanPrintAgain = true;
        }
    }

    private async Task RefreshTwoSidedAsync()
    {
        if (_twoSidedChecked || demoPrint is not null) return;
        try
        {
            if (await findQueue() is not { } queue)
            {
                CanTwoSided = false;
            }
            else
            {
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
            Log.Write($"Two-sided check (copy) failed: {ex}");
            CanTwoSided = false;
        }
        if (!CanTwoSided && !OnPrinter) TwoSided = false;
        OnPropertyChanged(nameof(ShowTwoSided));
    }

    private ScanColor Color => IsColor ? ScanColor.Color : ScanColor.Grayscale;

    private int Dpi(ScanSource source) => _caps is null ? CopyDpi : ScanChoices.Resolutions(_caps, source, [CopyDpi])[0];

    private void ShowIdCard(RenderedPage front, RenderedPage? back)
    {
        var frontSize = (front.WidthInches * 96, front.HeightInches * 96);
        var backSize = back is null ? frontSize : (back.WidthInches * 96, back.HeightInches * 96);
        var (top, bottom) = CopyLayout.IdCard(PreviewPaper.W, PreviewPaper.H, frontSize, backSize);
        Sheets.Clear();
        Sheets.Add(new CopySheet(PreviewPaper.W, PreviewPaper.H, PreviewHeight * PreviewPaper.W / PreviewPaper.H, PreviewHeight,
        [
            new CopyImage(Thumbnail(front.Image), top, Strings.Copy_Front),
            new CopyImage(back is null ? null : Thumbnail(back.Image), bottom, Strings.Copy_BackTurnOver),
        ]));
    }

    /// <summary>Each scanned page decoded once for the preview, however often it's laid out again.</summary>
    private readonly Dictionary<RenderedPage, BitmapSource?> _thumbnails = new(ReferenceEqualityComparer.Instance);

    private BitmapSource? Thumbnail(RenderedPage page)
    {
        if (!_thumbnails.TryGetValue(page, out var thumbnail)) _thumbnails[page] = thumbnail = Thumbnail(page.Image);
        return thumbnail;
    }

    private static BitmapSource? Thumbnail(byte[] jpeg)
    {
        try { return QueuePrinter.Decode(jpeg, decodeWidth: 600); }
        catch (Exception ex)
        {
            Trace.WriteLine($"Copy preview: {ex.Message}"); // preview only; printing decodes again
            return null;
        }
    }

    private void SetMessage(string? text, bool error = false)
    {
        Message = text;
        MessageIsError = error;
    }
}

/// <summary>A sheet in the copy preview, in DIPs: the paper and what goes on it.</summary>
public sealed record CopySheet(double PaperWidth, double PaperHeight, double PreviewWidth, double PreviewHeight, IReadOnlyList<CopyImage> Images);

/// <summary>
/// A scanned image on a preview sheet; no <see cref="Image"/> yet: a dashed placeholder labelled <see cref="Label"/>.
/// <see cref="Rotated"/>: turned a quarter clockwise to the paper's orientation, as it prints (<see cref="PageFit.Place"/>).
/// </summary>
public sealed record CopyImage(BitmapSource? Image, Placement At, string? Label, bool Rotated = false)
{
    public double Angle => Rotated ? 90 : 0;
    public double X => At.X;
    public double Y => At.Y;
    public double Width => At.Width;
    public double Height => At.Height;
    public bool IsPlaceholder => Image is null;
}
