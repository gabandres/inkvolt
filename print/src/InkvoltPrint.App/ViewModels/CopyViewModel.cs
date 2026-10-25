using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Copy: scan (over eSCL, or through the scanner's Windows driver), then print what was scanned through the printer's Windows queue at actual size, in one step.
/// ID card copy scans the front from the glass, asks for the card to be turned over, scans the back and prints both on
/// one sheet (top and bottom halves). Needs a scanner and a Windows queue; says which one is missing otherwise.
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
        Blocked = reason;
    }

    public string? UnavailableReason =>
        Blocked is { } blocked ? blocked
        : !ScannerChecked ? "Connecting to the printer…"
        : !HasScanner ? "This printer has no scanner, so it can't copy. You can still print PDFs."
        : !HasQueue && demoPrint is null ? "Copies print through this printer's Windows queue, and it isn't set up in Windows yet. Use Set up at the top of the page."
        : null;

    public bool IsAvailable => UnavailableReason is null;

    /// <summary>ID card copy instead of a page copy.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CopyButtonText), nameof(EmptyHint), nameof(IsDocument), nameof(ShowTwoSided))]
    public partial bool IdCard { get; set; }

    public bool IsDocument => !IdCard;

    [ObservableProperty] public partial IReadOnlyList<Option<ScanSource>> Sources { get; set; } = [];
    [ObservableProperty] public partial Option<ScanSource>? Source { get; set; }
    public bool HasSourceChoice => Sources.Count > 1;

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

    /// <summary>Two-sided output is for page copies; an ID card copy is one sheet.</summary>
    public bool ShowTwoSided => CanTwoSided && !IdCard;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CopyCommand), nameof(ScanBackCommand), nameof(StartOverCommand), nameof(PrintAgainCommand))]
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

    public string CopyButtonText => IdCard ? "Copy ID card" : "Copy";

    public string EmptyHint => IdCard
        ? "Put the card face down in the corner of the scanner glass (by the arrow mark), then press Copy ID card. You'll turn it over halfway."
        : Source?.Value is ScanSource.Adf or ScanSource.AdfDuplex
            ? "Put the pages face up in the document feeder, then press Copy."
            : "Put the page face down on the scanner glass, then press Copy.";

    public string Summary => IdCard
        ? $"Front and back on one sheet{(Copies > 1 ? $", {Copies} copies" : "")}, actual size."
        : $"{(Copies == 1 ? "1 copy" : $"{Copies} copies")}, {(FitToPaper ? "fit to the paper" : "actual size")}{(TwoSided && CanTwoSided ? ", both sides of the paper" : "")}.";

    partial void OnIdCardChanged(bool value)
    {
        StartOver();
        OnPropertyChanged(nameof(Summary));
    }

    partial void OnSourceChanged(Option<ScanSource>? value) => OnPropertyChanged(nameof(EmptyHint));
    partial void OnSourcesChanged(IReadOnlyList<Option<ScanSource>> value) => OnPropertyChanged(nameof(HasSourceChoice));
    partial void OnCanTwoSidedChanged(bool value) => OnPropertyChanged(nameof(Summary));

    partial void OnCopiesChanged(int value)
    {
        if (value < 1) Copies = 1;
        else if (value > 99) Copies = 99;
    }

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
        else await CopyPagesAsync();
    }

    private async Task CopyPagesAsync()
    {
        if (_client is null || _caps is null) return;
        var source = Source?.Value ?? ScanSource.Platen;
        var dpi = Dpi(source);
        var size = ScanChoices.DefaultPageSize(ScanChoices.PageSizesFor(_caps, source), null, RegionInfo.CurrentRegion.IsMetric);
        Sheets.Clear();
        var sizing = Sizing;
        var pages = await ScanAsync(ScanChoices.ToRequest(source, Color, dpi, size), dpi, page =>
            Sheets.Add(Sheet(CopyLayout.Page(page.WidthInches * 96, page.HeightInches * 96, PreviewPaper.W, PreviewPaper.H, sizing), page.Image)));
        if (pages is not { Count: > 0 }) return;
        var copies = Copies;
        var twoSided = TwoSided && CanTwoSided;
        var sheets = (twoSided ? (pages.Count + 1) / 2 : pages.Count) * copies;
        await PrintAsync("Copy", sheets, queue => QueuePrinter.PrintPagesAsync(queue, pages, copies, twoSided, "Copy", sizing),
            $"{(pages.Count == 1 ? "1 page" : $"{pages.Count} pages")}{(copies > 1 ? $" × {copies} copies" : "")}");
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
            copies > 1 ? $"the card × {copies} copies" : "the card, both sides on one page");
    }

    [RelayCommand(CanExecute = nameof(NotBusy))]
    private void StartOver()
    {
        _front = null;
        ForgetPrintAgain();
        AwaitingBack = false;
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
            SetMessage("Scanning… (the first page takes longer if the printer was asleep)");
            await foreach (var jpeg in _client.ScanAsync(request, _cts.Token))
            {
                var (w, h, _) = PdfWriter.JpegInfo(jpeg);
                var (wIn, hIn) = CopyLayout.Inches(w, h, dpi);
                var page = new RenderedPage(jpeg, wIn, hIn);
                pages.Add(page);
                added?.Invoke(page);
                SetMessage($"Scanned page {pages.Count}…");
            }
            if (pages.Count == 0) SetMessage("The scanner returned no pages.", error: true);
            return pages.Count > 0 ? pages : null;
        }
        catch (OperationCanceledException)
        {
            SetMessage("Copy cancelled.");
        }
        catch (ScanException ex)
        {
            SetMessage(ex.Message, error: true);
        }
        catch (Exception ex)
        {
            Log.Write($"Copy scan failed: {ex}");
            SetMessage($"Scan failed: {ex.Message}", error: true);
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
                SetMessage($"Sent to the demo printer: {what}. Nothing really prints; the job is in the print queue on the Overview.");
                return;
            }
            if (await findQueue() is not { } queue)
            {
                SetMessage("This printer isn't set up in Windows yet. Press Set up at the top of the page, then Print again.", error: true);
                KeepForPrintAgain();
                return;
            }
            SetMessage("Sending the copy to the printer…");
            await print(queue);
            SetMessage($"Sent to the printer: {what}.");
        }
        catch (Exception ex)
        {
            // Spooler/driver/serializer errors come in many types; never let one escape the command.
            Log.Write($"Copy print failed: {ex}");
            SetMessage($"Could not print the copy: {ex.Message}", error: true);
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
        if (!CanTwoSided) TwoSided = false;
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
            new CopyImage(Thumbnail(front.Image), top, "Front"),
            new CopyImage(back is null ? null : Thumbnail(back.Image), bottom, "Back: turn the card over"),
        ]));
    }

    private static CopySheet Sheet(PagePlacement at, byte[] jpeg) =>
        new(PreviewPaper.W, PreviewPaper.H, PreviewHeight * PreviewPaper.W / PreviewPaper.H, PreviewHeight,
            [new CopyImage(Thumbnail(jpeg), at.At, null, at.Rotated)]);

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
