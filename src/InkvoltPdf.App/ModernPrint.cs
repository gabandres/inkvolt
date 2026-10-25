using System.Collections;
using System.IO;
using System.IO.Packaging;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Xps.Packaging;
using InkvoltPdf.Core;
using Windows.Graphics.Printing;
using Windows.Graphics.Printing.OptionDetails;
using WinRT;

namespace InkvoltPdf.App;

/// <summary>
/// Print through the Windows 11 print dialog, with its preview. The app is the dialog's document source (a COM object
/// made by <see cref="PrintSourceWrappers"/>); the sheets are the classic path's (<see cref="FileActions.RenderSheet"/>):
/// the preview draws them into a Direct3D texture the dialog shows, and the job is written by WPF's XPS writer one sheet
/// at a time, each handed to the print job through the XPS object model. Windows 10, an elevated app (the dialog's host
/// process refuses it) or a dialog that doesn't come up print with the classic dialog instead.
/// </summary>
internal static class ModernPrint
{
    private static bool _unavailable;
    private static PrintSession? _active;

    /// <summary>The Windows 11 print dialog can be used (not before Windows 11, not elevated, not after it failed).</summary>
    public static bool Available => !_unavailable && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) && !IsElevated();

    /// <summary>
    /// Opens the Windows print dialog for the tab, laid out with <paramref name="setup"/>. False when it couldn't come up
    /// (print with the classic dialog instead); true once it is up (the job, if any, follows on its own).
    /// </summary>
    public static async Task<bool> PrintAsync(Window owner, DocumentTab tab, PrintSetup setup, int current)
    {
        if (!Available) return false;
        if (_active is not null)
        {
            (owner as MainWindow)?.ShowStatus("The print dialog is already open");
            return true;
        }
        var hwnd = new WindowInteropHelper(owner).Handle;
        if (hwnd == IntPtr.Zero) return false;
        PrintManager manager;
        try
        {
            manager = PrintManagerInterop.GetForWindow(hwnd);
        }
        catch (Exception ex)
        {
            Log.Write($"Print dialog unavailable: {ex.Message}");
            _unavailable = true;
            return false;
        }

        var dpi = Math.Clamp(VisualTreeHelper.GetDpi(owner).PixelsPerInchX, 96, 240);
        var session = new PrintSession(owner, tab, setup, current, (float)dpi, manager);
        _active = session;
        session.Ended += () => { if (_active == session) _active = null; };
        bool shown;
        try
        {
            shown = await PrintManagerInterop.ShowPrintUIForWindowAsync(hwnd);
        }
        catch (Exception ex)
        {
            Log.Write($"Print dialog didn't open: {ex.Message}");
            shown = false;
        }
        if (shown) return true;
        // Nothing comes back when the dialog's host can't show it, and printing would silently do nothing.
        Log.Write("Print dialog didn't open; using the classic dialog from now on");
        _unavailable = true;
        session.End();
        return false;
    }

    private static bool IsElevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    /// <summary>Dev check: writes the job the dialog would send (Letter paper, quarter-inch margins) into an XPS file.</summary>
    internal static async Task<int> WriteJobXps(PdfEngine engine, int[] pages, string path, PrintSetup? setup = null)
    {
        var paper = new Size(816, 1056);
        var plan = new PrintPlan(pages, FileActions.SizesOf(engine), new RectD(24, 24, 768, 1008), setup ?? new PrintSetup());
        File.Delete(path);
        using var writer = XpsJobWriter.ForFile(path);
        for (var i = 0; i < plan.SheetCount; i++)
        {
            var n = i;
            var sheet = await Task.Run(() => FileActions.RenderSheet(engine, plan, n, PrintSession.Dpi));
            writer.AddSheet(PrintSession.SheetXps(sheet, paper), n + 1);
        }
        writer.Close();
        return plan.SheetCount;
    }
}

/// <summary>
/// One opening of the print dialog: the print task, its options and the document source the dialog asks for preview pages
/// and, once Print is pressed, for the job. The tab stays busy (its engine unchanged) until the dialog is done and the job
/// is written. The dialog calls the source on its own threads; WPF drawing is sent to the window's thread.
/// </summary>
internal sealed class PrintSession
{
    /// <summary>Print resolution of the job (pixels per inch of paper), as in the classic path.</summary>
    public const double Dpi = 300;

    private const string SizingOption = "inkvolt.sizing";
    private const uint ApplicationDefinedPage = 0xFFFFFFFF; // JOB_PAGE_APPLICATION_DEFINED: the app picks the page shown first

    private readonly Window _owner;
    private readonly Dispatcher _ui;
    private readonly PdfEngine _engine;
    private readonly Func<int, (double W, double H)> _sizes;
    private readonly int _pageCount;
    private readonly PrintSetup _setup;
    private readonly int _current;
    private readonly float _previewDpi;
    private readonly string _title;
    private readonly PrintManager _manager;
    private readonly DocumentTab.BusyLease _busy;
    private readonly CancellationTokenSource _cancel = new();
    private readonly Lock _gate = new();

    private IntPtr _previewTarget; // IPrintPreviewDxgiPackageTarget
    private PrintTaskOptions? _previewOptions;
    private Layout? _preview;
    private IntPtr _device; // ID3D11Device for the preview pages
    private IntPtr _marshaler; // free-threaded marshaler aggregated by the COM object
    private bool _completed;
    private bool _submitted;
    private int _making;
    private bool _documentDone;
    private bool _ended;

    private sealed record Layout(PrintPlan Plan, Size Paper, PrintSetup Setup);

    public event Action? Ended;

    public PrintSession(Window owner, DocumentTab tab, PrintSetup setup, int current, float previewDpi, PrintManager manager)
    {
        _owner = owner;
        _ui = owner.Dispatcher;
        _engine = tab.ViewEngine;
        _sizes = FileActions.SizesOf(_engine);
        _pageCount = tab.PageView.PageCount;
        _setup = setup;
        _current = current;
        _previewDpi = previewDpi;
        _title = tab.Session.DisplayName;
        _manager = manager;
        _busy = tab.BeginBusy(null);
        _manager.PrintTaskRequested += OnRequested;
    }

    /// <summary>Lets the tab go and drops what the dialog left (UI thread).</summary>
    public void End()
    {
        if (_ended) return;
        _ended = true;
        _manager.PrintTaskRequested -= OnRequested;
        _cancel.Cancel();
        _busy.Dispose();
        lock (_gate)
        {
            Native.Release(ref _previewTarget);
            Native.Release(ref _device);
            Native.Release(ref _marshaler);
            _previewOptions = null;
        }
        Ended?.Invoke();
    }

    private void OnRequested(PrintManager sender, PrintTaskRequestedEventArgs e)
    {
        try
        {
            var task = e.Request.CreatePrintTask(_title, args =>
            {
                try
                {
                    args.SetSource(DocumentSource());
                }
                catch (Exception ex)
                {
                    Log.Write($"Print dialog source failed: {ex}");
                    throw;
                }
            });
            task.IsPreviewEnabled = true;
            var options = task.Options;
            options.PageRangeOptions.AllowAllPages = true;
            options.PageRangeOptions.AllowCurrentPage = true;
            options.PageRangeOptions.AllowCustomSetOfPages = true;
            // The list is what the dialog shows, so it is replaced: every printer setting there is (the dialog leaves out
            // what the printer can't do; it has no button for the driver's own settings), and the pages to print.
            var shown = options.DisplayedOptions;
            shown.Clear();
            foreach (var name in new[]
            {
                StandardPrintTaskOptions.Copies, StandardPrintTaskOptions.Orientation, StandardPrintTaskOptions.ColorMode,
                StandardPrintTaskOptions.Duplex, StandardPrintTaskOptions.Collation, StandardPrintTaskOptions.MediaSize,
                StandardPrintTaskOptions.MediaType, StandardPrintTaskOptions.PrintQuality, StandardPrintTaskOptions.InputBin,
                StandardPrintTaskOptions.Binding, StandardPrintTaskOptions.Staple, StandardPrintTaskOptions.HolePunch,
                StandardPrintTaskOptions.CustomPageRanges,
            }) shown.Add(name);
            if (_setup.Handling == PrintHandling.Booklet) options.Duplex = PrintDuplex.TwoSidedShortEdge;
            var details = PrintTaskOptionDetails.GetFromPrintTaskOptions(options);
            details.OptionChanged += (_, a) =>
            {
                if (a.OptionId as string == SizingOption) InvalidatePreview();
            };
            if (_setup.Handling == PrintHandling.Fit)
            {
                // Page sizing, the preview following it.
                var sizing = details.CreateItemListOption(SizingOption, "Page sizing");
                sizing.AddItem("actual", "Actual size (only pages larger than the paper shrink)");
                sizing.AddItem("fit", "Fit to paper (small pages grow too)");
                sizing.TrySetValue(_setup.Sizing == PrintSizing.FitToPaper ? "fit" : "actual");
                shown.Add(SizingOption);
            }
            task.Submitting += (_, _) => _submitted = true;
            task.Completed += (_, a) => _ui.BeginInvoke(() => OnCompleted(a.Completion));
        }
        catch (Exception ex)
        {
            Log.Write($"Print task failed: {ex}");
            throw;
        }
    }

    private void OnCompleted(PrintTaskCompletion completion)
    {
        Log.Write($"Print dialog: {completion}");
        _completed = true;
        if (completion == PrintTaskCompletion.Failed) Prompt.Error(_owner, "Printing didn't work", "Windows couldn't print the document.");
        if (completion == PrintTaskCompletion.Submitted && !_documentDone && Volatile.Read(ref _making) == 0)
        {
            // Submitted can come before Windows asks for the job: wait for it a while, the tab still held.
            var wait = new DispatcherTimer(TimeSpan.FromSeconds(15), DispatcherPriority.Normal, (s, _) =>
            {
                ((DispatcherTimer)s!).Stop();
                _documentDone = true;
                TryEnd();
            }, _ui);
            wait.Start();
            return;
        }
        TryEnd();
    }

    private void TryEnd()
    {
        if (_completed && Volatile.Read(ref _making) == 0 && (_documentDone || !_submitted)) End();
    }

    /// <summary>This session as the dialog's IPrintDocumentSource.</summary>
    private IPrintDocumentSource DocumentSource()
    {
        var unknown = PrintSourceWrappers.Instance.GetOrCreateComInterfaceForObject(this, CreateComInterfaceFlags.None);
        try
        {
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, in PrintSourceWrappers.IidDocumentSource, out var source));
            try
            {
                return MarshalInterface<IPrintDocumentSource>.FromAbi(source);
            }
            finally
            {
                Marshal.Release(source);
            }
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }

    /// <summary>The free-threaded marshaler's IMarshal (AddRef'd), so the dialog may call the source from any thread.</summary>
    internal IntPtr Marshaler()
    {
        lock (_gate)
        {
            if (_marshaler == IntPtr.Zero)
            {
                var outer = PrintSourceWrappers.Instance.GetOrCreateComInterfaceForObject(this, CreateComInterfaceFlags.None);
                try
                {
                    Marshal.ThrowExceptionForHR(Native.CoCreateFreeThreadedMarshaler(outer, out _marshaler));
                }
                finally
                {
                    Marshal.Release(outer);
                }
            }
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(_marshaler, in PrintSourceWrappers.IidMarshal, out var marshal));
            return marshal;
        }
    }

    /// <summary>
    /// The sheets for the dialog's current choices (paper, printable area, page sizing), of every page: the dialog numbers
    /// the preview's pages, and its page ranges ("Current page" is the one in the preview) use those numbers, so the
    /// preview keeps them all and the job picks from them (<see cref="SheetsFor"/>).
    /// </summary>
    private Layout LayoutFor(PrintTaskOptions options)
    {
        var d = options.GetPageDescription(1);
        var paper = d.PageSize.Width > 0 && d.PageSize.Height > 0 ? new Size(d.PageSize.Width, d.PageSize.Height) : new Size(816, 1056);
        var ia = d.ImageableRect;
        var area = ia.Width > 0 && ia.Height > 0
            ? new RectD(ia.X, ia.Y, ia.Width, ia.Height)
            : new RectD(24, 24, Math.Max(1, paper.Width - 48), Math.Max(1, paper.Height - 48));
        var setup = _setup;
        if (setup.Handling == PrintHandling.Fit && SizingFor(options) is { } sizing) setup = setup with { Sizing = sizing };
        return new Layout(new PrintPlan([.. Enumerable.Range(0, _pageCount)], _sizes, area, setup), paper, setup);
    }

    /// <summary>
    /// The sheets to print (0-based), in the dialog's numbering: the pages chosen ("1-3, 7", or the current one) or all of
    /// them. Printing one page per sheet, these are the document's page numbers.
    /// </summary>
    private static int[] SheetsFor(PrintTaskOptions options, int sheetCount)
    {
        var sheets = new List<int>();
        foreach (var r in options.CustomPageRanges)
        {
            var first = Math.Max(1, r.FirstPageNumber);
            var last = r.LastPageNumber <= 0 ? sheetCount : Math.Min(sheetCount, r.LastPageNumber);
            for (var p = first; p <= last; p++) sheets.Add(p - 1);
        }
        return sheets.Count > 0 ? [.. sheets] : [.. Enumerable.Range(0, sheetCount)];
    }

    private static PrintSizing? SizingFor(PrintTaskOptions options)
    {
        var details = PrintTaskOptionDetails.GetFromPrintTaskOptions(options);
        return details.Options.TryGetValue(SizingOption, out var o) && o.Value is string v
            ? v == "fit" ? PrintSizing.FitToPaper : PrintSizing.ActualSize
            : null;
    }

    private IntPtr PreviewTarget()
    {
        lock (_gate)
        {
            if (_previewTarget != IntPtr.Zero) Marshal.AddRef(_previewTarget);
            return _previewTarget;
        }
    }

    /// <summary>A choice of ours changed: the dialog asks for the pages again (it doesn't on its own).</summary>
    private void InvalidatePreview()
    {
        var target = PreviewTarget();
        if (target == IntPtr.Zero) return;
        try
        {
            Native.InvalidatePreview(target);
        }
        finally
        {
            Marshal.Release(target);
        }
    }

    // IPrintDocumentPageSource

    internal unsafe int GetPreviewPageCollection(IntPtr packageTarget, IntPtr* collection)
    {
        *collection = IntPtr.Zero;
        var hr = Native.GetPackageTarget(packageTarget, Native.IidPreviewDxgiTarget, Native.IidPreviewDxgiTarget, out var target);
        if (hr < 0) return hr;
        lock (_gate)
        {
            Native.Release(ref _previewTarget);
            _previewTarget = target;
        }
        var unknown = PrintSourceWrappers.Instance.GetOrCreateComInterfaceForObject(this, CreateComInterfaceFlags.None);
        try
        {
            hr = Marshal.QueryInterface(unknown, in PrintSourceWrappers.IidPreviewPageCollection, out var pages);
            *collection = pages;
            return hr;
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }

    // IPrintPreviewPageCollection

    internal int Paginate(IntPtr options)
    {
        var o = PrintTaskOptions.FromAbi(options);
        var layout = LayoutFor(o);
        lock (_gate)
        {
            _previewOptions = o;
            _preview = layout;
        }
        var target = PreviewTarget();
        if (target == IntPtr.Zero) return unchecked((int)0x80070057); // E_INVALIDARG
        try
        {
            var hr = Native.InvalidatePreview(target);
            return hr < 0 ? hr : Native.SetJobPageCount(target, (uint)layout.Plan.SheetCount);
        }
        finally
        {
            Marshal.Release(target);
        }
    }

    internal int MakePage(uint desiredJobPage, float width, float height)
    {
        Layout? layout;
        PrintTaskOptions? options;
        lock (_gate) (layout, options) = (_preview, _previewOptions);
        if (layout is null || options is null || width <= 0 || height <= 0) return unchecked((int)0x80070057);
        var jobPage = desiredJobPage == ApplicationDefinedPage ? FirstJobPage(layout.Plan) : desiredJobPage;
        if (jobPage < 1 || jobPage > layout.Plan.SheetCount) return unchecked((int)0x80070057);

        // The dialog gives the space it has (DIPs); the sheet is drawn into it at the screen's resolution.
        var paper = layout.Paper;
        var scale = Math.Min(width / paper.Width, height / paper.Height);
        var sheet = FileActions.RenderSheet(_engine, layout.Plan, (int)jobPage - 1, Math.Max(24, _previewDpi * scale), _cancel.Token);
        var w = (int)Math.Ceiling(width * _previewDpi / 96);
        var h = (int)Math.Ceiling(height * _previewDpi / 96);
        var pixels = _ui.Invoke(() =>
        {
            var visual = FileActions.DrawSheet(sheet, out _);
            visual.Transform = new ScaleTransform(scale, scale);
            var background = new DrawingVisual();
            using (var dc = background.RenderOpen()) dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, width, height));
            var bitmap = new RenderTargetBitmap(w, h, _previewDpi, _previewDpi, PixelFormats.Pbgra32);
            bitmap.Render(background);
            bitmap.Render(visual);
            var buffer = new byte[w * h * 4];
            bitmap.CopyPixels(buffer, w * 4, 0);
            return buffer;
        });

        var target = PreviewTarget();
        if (target == IntPtr.Zero) return unchecked((int)0x80070057);
        try
        {
            IntPtr device;
            lock (_gate)
            {
                if (_device == IntPtr.Zero) _device = Native.CreateDevice();
                device = _device;
                Marshal.AddRef(device);
            }
            try
            {
                var surface = Native.CreateSurface(device, w, h, pixels);
                try
                {
                    var hr = Native.DrawPage(target, jobPage, surface, _previewDpi);
                    if (hr < 0) Log.Write($"Print preview page {jobPage}: 0x{hr:X8}");
                    return hr;
                }
                finally
                {
                    Marshal.Release(surface);
                }
            }
            finally
            {
                Marshal.Release(device);
            }
        }
        finally
        {
            Marshal.Release(target);
        }
    }

    /// <summary>The sheet the preview opens on: the one with the page being read (1-based).</summary>
    private uint FirstJobPage(PrintPlan plan)
    {
        for (var i = 0; i < Math.Min(plan.SheetCount, 5000); i++)
            if (plan.Sheet(i).Pages.Any(p => p.Page == _current)) return (uint)i + 1;
        return 1;
    }

    // IPrintDocumentPageSource: Print was pressed

    internal int MakeDocument(IntPtr options, IntPtr packageTarget)
    {
        Interlocked.Increment(ref _making);
        ProgressPrompt? progress = null;
        try
        {
            var o = PrintTaskOptions.FromAbi(options);
            var layout = LayoutFor(o);
            var chosen = SheetsFor(o, layout.Plan.SheetCount);
            var sheets = chosen.Length;
            var unit = layout.Setup.Handling == PrintHandling.Fit ? "page" : "sheet";
            var what = sheets == 1 ? $"1 {unit}" : $"{sheets} {unit}s";
            progress = _ui.Invoke(() => new ProgressPrompt(_owner, "Printing", $"Preparing {what}…"));
            var cancel = CancellationTokenSource.CreateLinkedTokenSource(_cancel.Token, progress.Token).Token;
            try
            {
                using var writer = XpsJobWriter.ForPrintJob(packageTarget);
                for (var i = 0; i < sheets; i++)
                {
                    cancel.ThrowIfCancellationRequested();
                    var sheet = FileActions.RenderSheet(_engine, layout.Plan, chosen[i], Dpi, cancel);
                    var xps = _ui.Invoke(() => SheetXps(sheet, layout.Paper));
                    cancel.ThrowIfCancellationRequested();
                    writer.AddSheet(xps, i + 1);
                    progress.Report($"Sending {unit} {i + 1} of {sheets} to the printer…", (i + 1.0) / sheets);
                }
                writer.Close();
                Log.Write($"Printed {what} ({layout.Setup.Handling})");
                if (_setup.Handling == PrintHandling.Fit)
                {
                    var fit = layout.Setup.Sizing == PrintSizing.FitToPaper;
                    _ui.BeginInvoke(() =>
                    {
                        var s = AppSettings.Current;
                        if (s.PrintFitToPaper == fit) return;
                        s.PrintFitToPaper = fit;
                        s.Save();
                    });
                }
            }
            catch (Exception) when (cancel.IsCancellationRequested)
            {
                Native.CancelJob(packageTarget);
                Log.Write("Printing cancelled");
                _ui.BeginInvoke(() => (_owner as MainWindow)?.ShowStatus("Printing cancelled"));
            }
            return 0;
        }
        catch (Exception ex)
        {
            // Our message, and the job dropped (an error back would have Windows show one of its own as well).
            Log.Write($"Print failed: {ex}");
            Native.CancelJob(packageTarget);
            _ui.BeginInvoke(() => Prompt.Error(_owner, "Printing didn't work", ex.Message));
            return 0;
        }
        finally
        {
            if (progress is not null) _ui.BeginInvoke(progress.Dispose);
            Interlocked.Decrement(ref _making);
            _ui.BeginInvoke(() =>
            {
                _documentDone = true;
                TryEnd();
            });
        }
    }

    /// <summary>One sheet as a one-page XPS package, written by WPF's XPS writer (UI thread).</summary>
    internal static byte[] SheetXps(FileActions.RenderedSheet sheet, Size paper)
    {
        using var ms = new MemoryStream();
        using (var package = Package.Open(ms, FileMode.Create, FileAccess.ReadWrite))
        using (var xps = new XpsDocument(package, CompressionOption.SuperFast))
            XpsDocument.CreateXpsDocumentWriter(xps).Write(new OnePage(FileActions.SheetPage(sheet, paper), paper));
        return ms.ToArray();
    }

    private sealed class OnePage(DocumentPage page, Size paper) : DocumentPaginator
    {
        public override bool IsPageCountValid => true;
        public override int PageCount => 1;
        public override Size PageSize { get => paper; set { } }
        public override IDocumentPaginatorSource? Source => null;
        public override DocumentPage GetPage(int pageNumber) => page;
    }
}

/// <summary>
/// Writes a print job (or, for the dev check, an XPS file) a sheet at a time: each sheet's one-page XPS package is read
/// with the XPS object model and its page added under its own part name.
/// </summary>
internal sealed class XpsJobWriter : IDisposable
{
    private IntPtr _factory; // IXpsOMObjectFactory
    private IntPtr _writer; // IXpsOMPackageWriter

    private XpsJobWriter(IntPtr factory, IntPtr writer)
    {
        _factory = factory;
        _writer = writer;
        Native.StartDocument(factory, writer);
    }

    public static XpsJobWriter ForPrintJob(IntPtr packageTarget)
    {
        Marshal.ThrowExceptionForHR(Native.GetPackageTarget(packageTarget, Native.IdXpsTarget, Native.IidXpsDocumentPackageTarget, out var target));
        try
        {
            var factory = Native.XpsFactory(target);
            try
            {
                return new XpsJobWriter(factory, Native.JobWriter(factory, target));
            }
            catch
            {
                Marshal.Release(factory);
                throw;
            }
        }
        finally
        {
            Marshal.Release(target);
        }
    }

    public static XpsJobWriter ForFile(string path)
    {
        var factory = Native.CreateXpsFactory();
        try
        {
            return new XpsJobWriter(factory, Native.FileWriter(factory, path));
        }
        catch
        {
            Marshal.Release(factory);
            throw;
        }
    }

    /// <summary>Adds the page of a one-page XPS package as page <paramref name="number"/> (1-based).</summary>
    public void AddSheet(byte[] xps, int number) => Native.AddPage(_factory, _writer, xps, number);

    public void Close() => Native.CloseWriter(_writer);

    public void Dispose()
    {
        Native.Release(ref _writer);
        Native.Release(ref _factory);
    }
}

/// <summary>
/// The COM object the print dialog talks to, for a <see cref="PrintSession"/>: IPrintDocumentSource (WinRT, no methods of
/// its own; also answers for IInspectable), IPrintDocumentPageSource and IPrintPreviewPageCollection, plus IAgileObject and IMarshal (the free-threaded
/// marshaler) since the dialog calls it from its own threads.
/// </summary>
internal sealed unsafe class PrintSourceWrappers : ComWrappers
{
    public static readonly PrintSourceWrappers Instance = new();

    public static readonly Guid IidDocumentSource = GuidGenerator.GetIID(typeof(IPrintDocumentSource));
    private static readonly Guid IidPageSource = new("a96bb1db-172e-4667-82b5-ad97a252318f");
    public static readonly Guid IidPreviewPageCollection = new("0b31cc62-d7ec-4747-9d6e-f2537d870f2b");
    private static readonly Guid IidInspectable = new("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");
    private static readonly Guid IidAgileObject = new("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
    public static readonly Guid IidMarshal = new("00000003-0000-0000-c000-000000000046");
    private const string RuntimeClass = "Windows.Graphics.Printing.IPrintDocumentSource";

    private const int EntryCount = 6;
    private static readonly ComInterfaceEntry* Entries = CreateEntries();

    private static ComInterfaceEntry* CreateEntries()
    {
        GetIUnknownImpl(out var qi, out var addRef, out var release);
        IntPtr* Table(int size)
        {
            var t = (IntPtr*)RuntimeHelpers.AllocateTypeAssociatedMemory(typeof(PrintSourceWrappers), size * IntPtr.Size);
            t[0] = qi;
            t[1] = addRef;
            t[2] = release;
            return t;
        }

        var inspectable = Table(6);
        inspectable[3] = (IntPtr)(delegate* unmanaged<IntPtr, uint*, Guid**, int>)&GetIids;
        inspectable[4] = (IntPtr)(delegate* unmanaged<IntPtr, IntPtr*, int>)&GetRuntimeClassName;
        inspectable[5] = (IntPtr)(delegate* unmanaged<IntPtr, int*, int>)&GetTrustLevel;
        var pageSource = Table(5);
        pageSource[3] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, IntPtr, IntPtr*, int>)&GetPreviewPageCollection;
        pageSource[4] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, IntPtr, IntPtr, int>)&MakeDocument;
        var pages = Table(5);
        pages[3] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, uint, IntPtr, int>)&Paginate;
        pages[4] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, uint, float, float, int>)&MakePage;
        var agile = Table(3);
        var marshal = Table(9);
        marshal[3] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, Guid*, IntPtr, uint, IntPtr, uint, Guid*, int>)&GetUnmarshalClass;
        marshal[4] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, Guid*, IntPtr, uint, IntPtr, uint, uint*, int>)&GetMarshalSizeMax;
        marshal[5] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, IntPtr, Guid*, IntPtr, uint, IntPtr, uint, int>)&MarshalInterface;
        marshal[6] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, IntPtr, Guid*, IntPtr*, int>)&UnmarshalInterface;
        marshal[7] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, IntPtr, int>)&ReleaseMarshalData;
        marshal[8] = (IntPtr)(delegate* unmanaged<ComInterfaceDispatch*, uint, int>)&DisconnectObject;

        var entries = (ComInterfaceEntry*)RuntimeHelpers.AllocateTypeAssociatedMemory(typeof(PrintSourceWrappers), sizeof(ComInterfaceEntry) * EntryCount);
        entries[0] = new ComInterfaceEntry { IID = IidDocumentSource, Vtable = (IntPtr)inspectable };
        entries[1] = new ComInterfaceEntry { IID = IidPageSource, Vtable = (IntPtr)pageSource };
        entries[2] = new ComInterfaceEntry { IID = IidPreviewPageCollection, Vtable = (IntPtr)pages };
        entries[3] = new ComInterfaceEntry { IID = IidAgileObject, Vtable = (IntPtr)agile };
        entries[4] = new ComInterfaceEntry { IID = IidMarshal, Vtable = (IntPtr)marshal };
        entries[5] = new ComInterfaceEntry { IID = IidInspectable, Vtable = (IntPtr)inspectable };
        return entries;
    }

    protected override ComInterfaceEntry* ComputeVtables(object obj, CreateComInterfaceFlags flags, out int count)
    {
        count = EntryCount;
        return Entries;
    }

    protected override object CreateObject(IntPtr externalComObject, CreateObjectFlags flags) => throw new NotSupportedException();

    protected override void ReleaseObjects(IEnumerable objects) => throw new NotSupportedException();

    private static PrintSession Session(ComInterfaceDispatch* self) => ComInterfaceDispatch.GetInstance<PrintSession>(self);

    private static int Failed(Exception ex, string where)
    {
        Log.Write($"Print dialog {where} failed: {ex}");
        return ex.HResult < 0 ? ex.HResult : unchecked((int)0x80004005); // E_FAIL
    }

    // IInspectable

    [UnmanagedCallersOnly]
    private static int GetIids(IntPtr self, uint* count, Guid** iids)
    {
        var p = (Guid*)Marshal.AllocCoTaskMem(sizeof(Guid));
        *p = IidDocumentSource;
        *iids = p;
        *count = 1;
        return 0;
    }

    [UnmanagedCallersOnly]
    private static int GetRuntimeClassName(IntPtr self, IntPtr* name) => Native.WindowsCreateString(RuntimeClass, RuntimeClass.Length, out *name);

    [UnmanagedCallersOnly]
    private static int GetTrustLevel(IntPtr self, int* level)
    {
        *level = 0; // BaseTrust
        return 0;
    }

    // IPrintDocumentPageSource

    [UnmanagedCallersOnly]
    private static int GetPreviewPageCollection(ComInterfaceDispatch* self, IntPtr target, IntPtr* collection)
    {
        try { return Session(self).GetPreviewPageCollection(target, collection); }
        catch (Exception ex) { return Failed(ex, "preview"); }
    }

    [UnmanagedCallersOnly]
    private static int MakeDocument(ComInterfaceDispatch* self, IntPtr options, IntPtr target)
    {
        try { return Session(self).MakeDocument(options, target); }
        catch (Exception ex) { return Failed(ex, "job"); }
    }

    // IPrintPreviewPageCollection

    [UnmanagedCallersOnly]
    private static int Paginate(ComInterfaceDispatch* self, uint currentJobPage, IntPtr options)
    {
        try { return Session(self).Paginate(options); }
        catch (Exception ex) { return Failed(ex, "layout"); }
    }

    [UnmanagedCallersOnly]
    private static int MakePage(ComInterfaceDispatch* self, uint desiredJobPage, float width, float height)
    {
        try { return Session(self).MakePage(desiredJobPage, width, height); }
        catch (OperationCanceledException) { return unchecked((int)0x800704C7); } // ERROR_CANCELLED
        catch (Exception ex) { return Failed(ex, "preview page"); }
    }

    // IMarshal, passed on to the free-threaded marshaler

    private static int WithMarshaler(ComInterfaceDispatch* self, int slot, Func<IntPtr, IntPtr, int> call)
    {
        try
        {
            var m = Session(self).Marshaler();
            try { return call(m, Native.Slot(m, slot)); }
            finally { Marshal.Release(m); }
        }
        catch (Exception ex) { return Failed(ex, "marshaling"); }
    }

    [UnmanagedCallersOnly]
    private static int GetUnmarshalClass(ComInterfaceDispatch* self, Guid* riid, IntPtr pv, uint destContext, IntPtr pvDestContext, uint flags, Guid* clsid)
    {
        var (r, c) = ((IntPtr)riid, (IntPtr)clsid);
        return WithMarshaler(self, 3, (m, f) => ((delegate* unmanaged<IntPtr, IntPtr, IntPtr, uint, IntPtr, uint, IntPtr, int>)f)(m, r, pv, destContext, pvDestContext, flags, c));
    }

    [UnmanagedCallersOnly]
    private static int GetMarshalSizeMax(ComInterfaceDispatch* self, Guid* riid, IntPtr pv, uint destContext, IntPtr pvDestContext, uint flags, uint* size)
    {
        var (r, s) = ((IntPtr)riid, (IntPtr)size);
        return WithMarshaler(self, 4, (m, f) => ((delegate* unmanaged<IntPtr, IntPtr, IntPtr, uint, IntPtr, uint, IntPtr, int>)f)(m, r, pv, destContext, pvDestContext, flags, s));
    }

    [UnmanagedCallersOnly]
    private static int MarshalInterface(ComInterfaceDispatch* self, IntPtr stream, Guid* riid, IntPtr pv, uint destContext, IntPtr pvDestContext, uint flags)
    {
        var r = (IntPtr)riid;
        return WithMarshaler(self, 5, (m, f) => ((delegate* unmanaged<IntPtr, IntPtr, IntPtr, IntPtr, uint, IntPtr, uint, int>)f)(m, stream, r, pv, destContext, pvDestContext, flags));
    }

    [UnmanagedCallersOnly]
    private static int UnmarshalInterface(ComInterfaceDispatch* self, IntPtr stream, Guid* riid, IntPtr* ppv)
    {
        var (r, p) = ((IntPtr)riid, (IntPtr)ppv);
        return WithMarshaler(self, 6, (m, f) => ((delegate* unmanaged<IntPtr, IntPtr, IntPtr, IntPtr, int>)f)(m, stream, r, p));
    }

    [UnmanagedCallersOnly]
    private static int ReleaseMarshalData(ComInterfaceDispatch* self, IntPtr stream) =>
        WithMarshaler(self, 7, (m, f) => ((delegate* unmanaged<IntPtr, IntPtr, int>)f)(m, stream));

    [UnmanagedCallersOnly]
    private static int DisconnectObject(ComInterfaceDispatch* self, uint reserved) =>
        WithMarshaler(self, 8, (m, f) => ((delegate* unmanaged<IntPtr, uint, int>)f)(m, reserved));
}

/// <summary>
/// The few COM calls printing needs (print preview, XPS object model, Direct3D 11), through vtable slots: 0–2 are
/// IUnknown's, then each interface's own methods in declaration order (base interfaces' first).
/// </summary>
internal static unsafe class Native
{
    public static readonly Guid IidPreviewDxgiTarget = new("1a6dd0ad-1e2a-4e99-a5ba-91f17818290e"); // also ID_PREVIEWPACKAGETARGET_DXGI
    public static readonly Guid IdXpsTarget = new("9cae40a8-ded1-41c9-a9fd-d735ef33aeda"); // ID_DOCUMENTPACKAGETARGET_MSXPS
    public static readonly Guid IidXpsDocumentPackageTarget = new("3b0b6d38-53ad-41da-b212-d37637a6714e");
    private static readonly Guid ClsidXpsFactory = new("e974d26d-3d9b-4d47-88cc-3872f2dc3585");
    private static readonly Guid IidXpsFactory = new("f9b2a685-a50d-4fc2-b764-b56e093ea0ca");
    private static readonly Guid IidDxgiSurface = new("cafcb56c-6ac3-4889-bf47-9e23bbd260ec");

    public static IntPtr Slot(IntPtr p, int slot) => (*(IntPtr**)p)[slot];

    public static void Release(ref IntPtr p)
    {
        if (p != IntPtr.Zero) Marshal.Release(p);
        p = IntPtr.Zero;
    }

    private static IntPtr Check(int hr, IntPtr result)
    {
        Marshal.ThrowExceptionForHR(hr);
        return result;
    }

    // IPrintDocumentPackageTarget: GetPackageTargetTypes, GetPackageTarget, Cancel

    public static int GetPackageTarget(IntPtr target, Guid type, Guid iid, out IntPtr result)
    {
        IntPtr r;
        var hr = ((delegate* unmanaged<IntPtr, Guid*, Guid*, IntPtr*, int>)Slot(target, 4))(target, &type, &iid, &r);
        result = r;
        return hr;
    }

    public static void CancelJob(IntPtr target)
    {
        var hr = ((delegate* unmanaged<IntPtr, int>)Slot(target, 5))(target);
        if (hr < 0) Log.Write($"Print job cancel: 0x{hr:X8}");
    }

    // IPrintPreviewDxgiPackageTarget: SetJobPageCount, DrawPage, InvalidatePreview

    public static int SetJobPageCount(IntPtr target, uint count) =>
        ((delegate* unmanaged<IntPtr, int, uint, int>)Slot(target, 3))(target, 0 /* FinalPageCount */, count);

    public static int DrawPage(IntPtr target, uint jobPage, IntPtr surface, float dpi) =>
        ((delegate* unmanaged<IntPtr, uint, IntPtr, float, float, int>)Slot(target, 4))(target, jobPage, surface, dpi, dpi);

    public static int InvalidatePreview(IntPtr target) => ((delegate* unmanaged<IntPtr, int>)Slot(target, 5))(target);

    // Direct3D 11: a device, and a texture holding a preview page

    [StructLayout(LayoutKind.Sequential)]
    private struct Texture2DDesc
    {
        public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CpuAccessFlags, MiscFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SubresourceData
    {
        public void* SysMem;
        public uint Pitch, SlicePitch;
    }

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels, uint levels,
        uint sdkVersion, out IntPtr device, out int level, out IntPtr context);

    /// <summary>A Direct3D 11 device (the graphics card's, else the WARP software one), for preview textures.</summary>
    public static IntPtr CreateDevice()
    {
        const uint BgraSupport = 0x20;
        var hr = D3D11CreateDevice(IntPtr.Zero, 1 /* HARDWARE */, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, 7, out var device, out _, out var context);
        if (hr < 0) hr = D3D11CreateDevice(IntPtr.Zero, 5 /* WARP */, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, 7, out device, out _, out context);
        Marshal.ThrowExceptionForHR(hr);
        Release(ref context);
        return device;
    }

    /// <summary>A texture of BGRA pixels (w × h) as an IDXGISurface.</summary>
    public static IntPtr CreateSurface(IntPtr device, int w, int h, byte[] pixels)
    {
        var desc = new Texture2DDesc
        {
            Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1, Format = 87 /* B8G8R8A8_UNORM */, SampleCount = 1,
            Usage = 0 /* DEFAULT */, BindFlags = 0x20 | 0x8 /* RENDER_TARGET | SHADER_RESOURCE */,
        };
        IntPtr texture;
        fixed (byte* p = pixels)
        {
            var data = new SubresourceData { SysMem = p, Pitch = (uint)w * 4 };
            Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, Texture2DDesc*, SubresourceData*, IntPtr*, int>)Slot(device, 5))(device, &desc, &data, &texture));
        }
        try
        {
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(texture, in IidDxgiSurface, out var surface));
            return surface;
        }
        finally
        {
            Marshal.Release(texture);
        }
    }

    // XPS object model

    [StructLayout(LayoutKind.Sequential)]
    private struct XpsSize
    {
        public float Width, Height;
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(in Guid clsid, IntPtr outer, uint context, in Guid iid, out IntPtr result);

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern int CoCreateFreeThreadedMarshaler(IntPtr outer, out IntPtr marshaler);

    [DllImport("shlwapi.dll", ExactSpelling = true)]
    private static extern IntPtr SHCreateMemStream(byte* init, uint size);

    [DllImport("combase.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    public static extern int WindowsCreateString(string source, int length, out IntPtr hstring);

    public static IntPtr CreateXpsFactory() => Check(CoCreateInstance(ClsidXpsFactory, IntPtr.Zero, 1 /* INPROC_SERVER */, IidXpsFactory, out var f), f);

    // IXpsDocumentPackageTarget: GetXpsOMPackageWriter, GetXpsOMFactory, GetXpsType

    public static IntPtr XpsFactory(IntPtr target)
    {
        IntPtr f;
        return Check(((delegate* unmanaged<IntPtr, IntPtr*, int>)Slot(target, 4))(target, &f), f);
    }

    public static IntPtr JobWriter(IntPtr factory, IntPtr target)
    {
        var sequence = PartUri(factory, "/FixedDocumentSequence.fdseq");
        try
        {
            IntPtr w;
            return Check(((delegate* unmanaged<IntPtr, IntPtr, IntPtr, IntPtr*, int>)Slot(target, 3))(target, sequence, IntPtr.Zero, &w), w);
        }
        finally
        {
            Marshal.Release(sequence);
        }
    }

    // IXpsOMObjectFactory: CreatePackageFromStream (2), CreatePackageWriterOnFile (33), CreatePartUri (35)

    private static IntPtr PartUri(IntPtr factory, string name)
    {
        IntPtr uri;
        fixed (char* n = name)
            return Check(((delegate* unmanaged<IntPtr, char*, IntPtr*, int>)Slot(factory, 3 + 35))(factory, n, &uri), uri);
    }

    public static IntPtr FileWriter(IntPtr factory, string path)
    {
        var sequence = PartUri(factory, "/FixedDocumentSequence.fdseq");
        try
        {
            IntPtr w;
            fixed (char* p = path)
                return Check(((delegate* unmanaged<IntPtr, char*, IntPtr, uint, int, int, IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, IntPtr*, int>)Slot(factory, 3 + 33))(
                    factory, p, IntPtr.Zero, 0x80 /* NORMAL */, 0, 1 /* XPS_INTERLEAVING_OFF */, sequence, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, &w), w);
        }
        finally
        {
            Marshal.Release(sequence);
        }
    }

    // IXpsOMPackageWriter: StartNewDocument, AddPage, AddResource, Close, IsClosed

    public static void StartDocument(IntPtr factory, IntPtr writer)
    {
        var document = PartUri(factory, "/Documents/1/FixedDocument.fdoc");
        try
        {
            Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, int>)Slot(writer, 3))(
                writer, document, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero));
        }
        finally
        {
            Marshal.Release(document);
        }
    }

    public static void CloseWriter(IntPtr writer) => Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, int>)Slot(writer, 6))(writer));

    /// <summary>Reads a one-page XPS package and adds its page to <paramref name="writer"/> as page <paramref name="number"/>.</summary>
    public static void AddPage(IntPtr factory, IntPtr writer, byte[] xps, int number)
    {
        IntPtr stream, package = 0, sequence = 0, documents = 0, document = 0, references = 0, reference = 0, page = 0, name = 0;
        fixed (byte* b = xps) stream = SHCreateMemStream(b, (uint)xps.Length);
        if (stream == IntPtr.Zero) throw new OutOfMemoryException();
        try
        {
            IntPtr r;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, IntPtr, int, IntPtr*, int>)Slot(factory, 3 + 2))(factory, stream, 0, &r));
            package = r;
            // IXpsOMPackage.GetDocumentSequence; IXpsOMDocumentSequence (an IXpsOMPart: GetPartName, SetPartName) .GetDocuments
            package.Get(3, out sequence);
            sequence.Get(6, out documents);
            documents.GetAt(0, out document); // IXpsOMDocumentCollection: GetCount, GetAt
            document.Get(6, out references); // IXpsOMDocument (an IXpsOMPart): GetOwner, GetPageReferences
            references.GetAt(0, out reference);
            reference.Get(4, out page); // IXpsOMPageReference: GetOwner, GetPage
            name = PartUri(factory, $"/Documents/1/Pages/{number}.fpage");
            Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, IntPtr, int>)Slot(page, 4))(page, name)); // IXpsOMPart.SetPartName
            XpsSize size;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, XpsSize*, int>)Slot(page, 7))(page, &size)); // IXpsOMPage.GetPageDimensions
            Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, IntPtr, XpsSize*, IntPtr, IntPtr, IntPtr, IntPtr, int>)Slot(writer, 4))(
                writer, page, &size, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero));
        }
        finally
        {
            foreach (var p in new[] { name, page, reference, references, document, documents, sequence, package, stream })
                if (p != IntPtr.Zero) Marshal.Release(p);
        }
    }

    private static void Get(this IntPtr obj, int slot, out IntPtr result)
    {
        IntPtr r;
        Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, IntPtr*, int>)Slot(obj, slot))(obj, &r));
        result = r;
    }

    private static void GetAt(this IntPtr collection, uint index, out IntPtr result)
    {
        IntPtr r;
        Marshal.ThrowExceptionForHR(((delegate* unmanaged<IntPtr, uint, IntPtr*, int>)Slot(collection, 4))(collection, index, &r));
        result = r;
    }
}
