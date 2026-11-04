using System.IO;
using System.Printing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Print, export to images, and document properties.</summary>
public static class FileActions
{
    /// <summary>
    /// Print: the Windows 11 print dialog with its preview (<see cref="ModernPrint"/>), each page fit to the paper the way
    /// the last Page Sizing &amp; Handling chose (actual size or fit to paper, also in the dialog's More settings).
    /// <paramref name="withOptions"/> asks for Page Sizing &amp; Handling (pages per sheet, booklet, poster) first, on the
    /// default printer's paper; the dialog's preview shows the sheets on the paper chosen there. Where that dialog can't be
    /// used: the classic one, then straight to the printer.
    /// </summary>
    public static async Task Print(Window owner, DocumentTab tab, bool withOptions = false)
    {
        // Let a value still being typed land first: the dialog takes focus, which would commit it mid-print.
        if (!await tab.SettleAsync()) return;
        PrintSetup? chosen = null;
        if (ModernPrint.Available)
        {
            chosen = withOptions ? AskHandling(owner, tab) : DefaultSetup();
            if (chosen is null || !await tab.SettleAsync()) return;
            if (await ModernPrint.PrintAsync(owner, tab, chosen, Organize.CurrentPage(tab))) return;
        }
        await PrintClassic(owner, tab, withOptions, chosen);
    }

    private static PrintSetup DefaultSetup() =>
        new() { Sizing = AppSettings.Current.PrintFitToPaper ? PrintSizing.FitToPaper : PrintSizing.ActualSize };

    /// <summary>Page Sizing &amp; Handling before the Windows dialog: the default printer's paper stands in for the one chosen there.</summary>
    private static PrintSetup? AskHandling(Window owner, DocumentTab tab)
    {
        var paper = new Size(816, 1056);
        var printable = new RectD(24, 24, 768, 1008);
        var duplex = false;
        try
        {
            var dlg = new PrintDialog();
            var (origin, area) = ImageableArea(dlg);
            paper = new Size(dlg.PrintableAreaWidth, dlg.PrintableAreaHeight);
            printable = new RectD(origin.X, origin.Y, area.Width, area.Height);
            duplex = CanPrintBothSides(dlg);
        }
        catch (Exception ex) when (ex is PrintQueueException or PrintSystemException or InvalidOperationException)
        {
            Log.Write($"Default printer unavailable: {ex.Message}");
        }
        var pages = Enumerable.Range(0, tab.PageView.PageCount).ToArray();
        return PrintHandlingDialog.Ask(owner, pages, SizesOf(tab.ViewEngine), paper, printable, duplex);
    }

    /// <summary>The classic Windows print dialog; <paramref name="chosen"/> is the page handling already asked for, if any.</summary>
    private static async Task PrintClassic(Window owner, DocumentTab tab, bool withOptions, PrintSetup? chosen)
    {
        var count = tab.PageView.PageCount;
        var selection = tab.SelectedPages;
        var current = Organize.CurrentPage(tab);
        var dlg = new PrintDialog
        {
            UserPageRangeEnabled = true,
            CurrentPageEnabled = true,
            SelectedPagesEnabled = selection.Length > 1,
            MinPage = 1,
            MaxPage = (uint)count,
            PageRange = new System.Windows.Controls.PageRange(1, count),
        };
        PrinterCheck.Prewarm(); // the default printer's status, while the dialog is open
        if (dlg.ShowDialog() != true || !await tab.SettleAsync()) return;
        if (!await ConfirmPrinterReady(owner, PrinterCheck.Describe(dlg.PrintQueue))) return;
        count = tab.PageView.PageCount;

        int[] pages = dlg.PageRangeSelection switch
        {
            PageRangeSelection.UserPages => [.. Enumerable.Range(Math.Max(1, dlg.PageRange.PageFrom) - 1,
                Math.Max(0, Math.Min(count, dlg.PageRange.PageTo) - Math.Max(1, dlg.PageRange.PageFrom) + 1))],
            PageRangeSelection.CurrentPage => [current],
            PageRangeSelection.SelectedPages => selection,
            _ => [.. Enumerable.Range(0, count)],
        };
        pages = [.. pages.Where(p => p >= 0 && p < count)];
        if (pages.Length == 0) return;

        // Page sizing & handling (Print with Options): fit, pages per sheet, booklet, poster (the paper is known now).
        var (origin, area) = ImageableArea(dlg);
        var paper = new Size(dlg.PrintableAreaWidth, dlg.PrintableAreaHeight);
        var printable = new RectD(origin.X, origin.Y, area.Width, area.Height);
        var duplex = CanPrintBothSides(dlg);
        var setup = chosen ?? (withOptions
            ? PrintHandlingDialog.Ask(owner, pages, SizesOf(tab.ViewEngine), paper, printable, duplex)
            : DefaultSetup());
        if (setup is null || !await tab.SettleAsync()) return;
        if (pages.Any(p => p >= tab.PageView.PageCount)) return; // the document changed meanwhile
        if (setup.Handling == PrintHandling.Booklet && duplex) dlg.PrintTicket.Duplexing = Duplexing.TwoSidedShortEdge;

        // Busy before anything else can run: the print holds this engine until it is done.
        using var busy = tab.BeginBusy(Loc.Plural(pages.Length, Strings.Print_PrintingPages_One, Strings.Print_PrintingPages_Many));
        var engine = tab.ViewEngine;
        var plan = new PrintPlan(pages, SizesOf(engine), printable, setup);
        var sheets = plan.SheetCount;
        var unit = setup.Handling == PrintHandling.Fit ? "page" : "sheet";
        using var progress = new ProgressPrompt(owner, Strings.Print_Printing, Loc.Plural(pages.Length, Strings.Print_PreparingPages_One, Strings.Print_PreparingPages_Many));
        var paginator = new PdfPaginator(engine, plan, paper, progress.Token);
        try
        {
            // Pages render on a background thread (PdfPaginator.GetPageAsync), so the window stays responsive.
            var writer = PrintQueue.CreateXpsDocumentWriter(dlg.PrintQueue);
            progress.Cancelled += () =>
            {
                try { writer.CancelAsync(); } catch (InvalidOperationException) { }
            };
            writer.WritingProgressChanged += (_, e) =>
            {
                if (e.WritingLevel == System.Windows.Documents.Serialization.WritingProgressChangeLevel.FixedPageWritingProgress)
                    progress.Report(Loc.Format(setup.Handling == PrintHandling.Fit ? Strings.Print_SendingPage : Strings.Print_SendingSheet, Math.Min(e.Number, sheets), sheets), (double)e.Number / sheets);
            };
            await WriteAsync(writer, paginator, dlg.PrintTicket);
            Log.Write($"Printed {Pages(pages.Length)} ({setup.Handling}, {sheets} {unit}s)");
        }
        catch (Exception ex) when (ex is OperationCanceledException || progress.Token.IsCancellationRequested)
        {
            Log.Write("Printing cancelled");
            (Window.GetWindow(tab) as MainWindow)?.ShowStatus(Strings.Print_Cancelled);
        }
        catch (Exception ex)
        {
            Log.Write($"Print failed: {ex}");
            Prompt.Error(owner, Strings.Print_Failed, ex.Message);
        }
    }

    private static string Pages(int n) => n == 1 ? "1 page" : $"{n} pages";

    /// <summary>Page sizes as shown, in DIPs, for the print layout.</summary>
    internal static Func<int, (double W, double H)> SizesOf(PdfEngine engine) => p =>
    {
        var g = engine.GetPage(p);
        return (g.Width * 96 / 72, g.Height * 96 / 72);
    };

    /// <summary>True when the chosen printer prints both sides flipping on the short edge (what a booklet needs).</summary>
    private static bool CanPrintBothSides(PrintDialog dlg)
    {
        try
        {
            return dlg.PrintQueue.GetPrintCapabilities(dlg.PrintTicket).DuplexingCapability.Contains(Duplexing.TwoSidedShortEdge);
        }
        catch (Exception ex) when (ex is PrintQueueException or PrintSystemException or InvalidOperationException)
        {
            Log.Write($"Printer capabilities unavailable: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Inkvolt suite: when the chosen queue is a printer Inkvolt Print knows, shows its status (ready, sleeping, toner) and asks
    /// before printing to one that is offline or has an error. Takes at most <see cref="PrinterCheck.Budget"/>; without an
    /// answer, printing goes ahead.
    /// </summary>
    private static async Task<bool> ConfirmPrinterReady(Window owner, InkvoltPrint.Core.Suite.QueueInfo? queue)
    {
        if (queue is null || await PrinterCheck.CheckAsync(queue) is not { } check) return true;
        var (printer, health) = (check.Printer, check.Health);
        Log.Write($"Printer check: {printer.Name}: {health.State}");
        if (!health.ShouldWarn)
        {
            (owner as MainWindow)?.ShowStatus($"{printer.Name}: {health.Summary}"); // in every language: only names and values, no words
            return true;
        }
        var body = health.State == InkvoltPrint.Core.Suite.Readiness.Offline
            ? Strings.Print_NoAnswer
            : Loc.Format(Strings.Print_FixFirst, health.Summary);
        return Prompt.Confirm(owner, PrinterCheck.Problem(health, printer.Name), body, Strings.Print_PrintAnyway, warning: true);
    }

    private static Task WriteAsync(System.Windows.Xps.XpsDocumentWriter writer, DocumentPaginator paginator, System.Printing.PrintTicket? ticket)
    {
        var done = new TaskCompletionSource();
        writer.WritingCompleted += (_, e) =>
        {
            if (e.Error is not null) done.TrySetException(e.Error);
            else if (e.Cancelled) done.TrySetCanceled();
            else done.TrySetResult();
        };
        writer.WritingCancelled += (_, _) => done.TrySetCanceled();
        if (ticket is null) writer.WriteAsync(paginator);
        else writer.WriteAsync(paginator, ticket);
        return done.Task;
    }

    /// <summary>Dev check: runs the print pipeline into an XPS file (Letter paper, quarter-inch margins).</summary>
    internal static async Task<int> WriteXps(PdfEngine engine, int[] pages, string path, PrintSetup? setup = null)
    {
        var paper = new Size(816, 1056);
        var plan = new PrintPlan(pages, SizesOf(engine), new RectD(24, 24, 768, 1008), setup ?? new PrintSetup());
        var paginator = new PdfPaginator(engine, plan, paper);
        File.Delete(path);
        using var xps = new System.Windows.Xps.Packaging.XpsDocument(path, FileAccess.ReadWrite);
        await WriteAsync(System.Windows.Xps.Packaging.XpsDocument.CreateXpsDocumentWriter(xps), paginator, null);
        return paginator.PageCount;
    }

    /// <summary>The printer's imageable area in DIPs; falls back to quarter-inch margins.</summary>
    private static (Point Origin, Size Area) ImageableArea(PrintDialog dlg)
    {
        var paper = new Size(dlg.PrintableAreaWidth, dlg.PrintableAreaHeight);
        try
        {
            var caps = dlg.PrintQueue.GetPrintCapabilities(dlg.PrintTicket);
            if (caps.PageImageableArea is { } ia && ia.ExtentWidth > 0 && ia.ExtentHeight > 0)
                return (new Point(ia.OriginWidth, ia.OriginHeight), new Size(ia.ExtentWidth, ia.ExtentHeight));
        }
        catch (Exception ex) when (ex is PrintQueueException or PrintSystemException or InvalidOperationException)
        {
            Log.Write($"Printer capabilities unavailable: {ex.Message}");
        }
        return (new Point(24, 24), new Size(Math.Max(1, paper.Width - 48), Math.Max(1, paper.Height - 48)));
    }

    /// <summary>A sheet's pages rendered, ready to draw (<see cref="DrawSheet"/>).</summary>
    internal sealed record RenderedSheet(PrintSheet Sheet, BitmapSource[] Images);

    /// <summary>
    /// Renders the pages of one sheet of a <see cref="PrintPlan"/> at <paramref name="dpi"/> pixels per inch of paper (one
    /// page, several, two booklet pages or a poster tile: only the part of the page that sheet shows). Any thread.
    /// </summary>
    internal static RenderedSheet RenderSheet(PdfEngine engine, PrintPlan plan, int sheetNumber, double dpi, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        var sheet = plan.Sheet(sheetNumber);
        var images = new BitmapSource[sheet.Pages.Count];
        for (var i = 0; i < images.Length; i++)
        {
            var p = sheet.Pages[i];
            var g = engine.GetPage(p.Page);
            // The part of the page shown, in points (the plan works in DIPs).
            var region = p.Source is { } src ? new RectD(src.X * 0.75, src.Y * 0.75, src.Width * 0.75, src.Height * 0.75) : new RectD(0, 0, g.Width, g.Height);
            // Its size on paper (DIPs) over its size on the page (points), at the resolution asked for.
            var across = p.Turns == 1 ? p.Box.Height : p.Box.Width;
            var pxScale = dpi / 96 * across / region.Width;
            while (region.Width * region.Height * pxScale * pxScale > 60_000_000) pxScale *= 0.85;
            images[i] = PageViewer.ToBitmap(engine.Render(p.Page, pxScale, p.Source is null ? null : region, cancel));
        }
        return new RenderedSheet(sheet, images);
    }

    /// <summary>Draws a rendered sheet in paper DIPs; <paramref name="content"/> is the part drawn on. UI thread.</summary>
    internal static DrawingVisual DrawSheet(RenderedSheet r, out Rect content)
    {
        var visual = new DrawingVisual();
        content = Rect.Empty;
        using (var dc = visual.RenderOpen())
        {
            var border = new Pen(Brushes.Gray, 0.75);
            for (var i = 0; i < r.Images.Length; i++)
            {
                var p = r.Sheet.Pages[i];
                var box = new Rect(p.Box.X, p.Box.Y, p.Box.Width, p.Box.Height);
                content.Union(box);
                if (p.Turns == 1)
                {
                    // Turn the page 90° clockwise into the (W × H) box.
                    dc.PushTransform(new TranslateTransform(box.X + box.Width, box.Y));
                    dc.PushTransform(new RotateTransform(90));
                    dc.DrawImage(r.Images[i], new Rect(0, 0, box.Height, box.Width));
                    dc.Pop();
                    dc.Pop();
                }
                else
                {
                    dc.DrawImage(r.Images[i], box);
                }
                if (r.Sheet.Borders) dc.DrawRectangle(null, border, box);
            }
            var mark = new Pen(Brushes.Black, 0.75);
            foreach (var m in r.Sheet.Marks)
            {
                dc.DrawLine(mark, new Point(m.X1, m.Y1), new Point(m.X2, m.Y2));
                content.Union(new Rect(new Point(m.X1, m.Y1), new Point(m.X2, m.Y2)));
            }
        }
        return visual;
    }

    /// <summary>A rendered sheet as a printable page of <paramref name="paper"/> (DIPs). UI thread.</summary>
    internal static DocumentPage SheetPage(RenderedSheet r, Size paper)
    {
        var visual = DrawSheet(r, out var content);
        return new DocumentPage(visual, paper, new Rect(paper), content.IsEmpty ? new Rect(paper) : content);
    }

    /// <summary>
    /// Renders each sheet of a <see cref="PrintPlan"/> at print resolution when the printer asks for it, so memory stays
    /// bounded by a sheet.
    /// </summary>
    private sealed class PdfPaginator(PdfEngine engine, PrintPlan plan, Size paper, CancellationToken cancel = default) : DocumentPaginator
    {
        private const double Dpi = 300;

        public override bool IsPageCountValid => true;
        public override int PageCount => plan.SheetCount;
        public override Size PageSize { get => paper; set { } }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber) => SheetPage(RenderSheet(engine, plan, pageNumber, Dpi, cancel), paper);

        /// <summary>Renders on a worker thread and completes on the UI thread (used by XpsDocumentWriter.WriteAsync).</summary>
        public override void GetPageAsync(int pageNumber, object userState)
        {
            Task.Run(() => RenderSheet(engine, plan, pageNumber, Dpi, cancel), cancel).ContinueWith(t => OnGetPageCompleted(
                    t.IsCanceled || cancel.IsCancellationRequested ? new GetPageCompletedEventArgs(null, pageNumber, null, true, userState)
                    : t.IsFaulted ? new GetPageCompletedEventArgs(null, pageNumber, t.Exception!.InnerException, false, userState)
                    : new GetPageCompletedEventArgs(SheetPage(t.Result, paper), pageNumber, null, false, userState)),
                CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.FromCurrentSynchronizationContext());
        }
    }

    public static async Task ExportImages(Window owner, DocumentTab tab, MainWindow host)
    {
        if (!await tab.SettleAsync()) return;
        var dlg = new FormDialog(owner, Strings.File_ExportImagesTitle, Strings.File_Export);
        var range = dlg.AddRange(tab, preferSelection: false);
        var format = dlg.AddChoice(Strings.File_Format, [Strings.File_FormatPng, Strings.File_FormatJpeg]);
        var dpi = dlg.AddChoice(Strings.File_Resolution, [.. new[] { 72, 96, 150, 200, 300, 600 }.Select(n => Loc.Format(Strings.File_Dpi, n))], 2);
        var folder = dlg.AddText(Strings.File_SaveToFolder, Path.GetDirectoryName(tab.Session.FilePath) ?? AppSettings.Current.LastFolder);
        var browse = new Button { Content = Strings.Common_Browse, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        browse.Click += (_, _) => { if (PdfFiles.PickFolder(dlg, Strings.File_ExportImagesTo, folder.Text) is { } f) folder.Text = f; };
        dlg.Add(null, browse);
        int[] pages = [];
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            return Directory.Exists(folder.Text) ? null : Strings.File_ChooseExisting;
        });
        if (!dlg.ShowModal() || !await tab.SettleAsync()) return;
        if (!Organize.ConfirmUnprotected(owner, tab, Strings.File_ImagesUnprotected, Strings.Comments_ExportAnyway)) return;
        pages = [.. pages.Where(p => p < tab.PageView.PageCount)];
        if (pages.Length == 0) return;

        var jpeg = format.SelectedIndex == 1;
        var res = new[] { 72, 96, 150, 200, 300, 600 }[dpi.SelectedIndex];
        var dir = folder.Text;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        var engine = tab.ViewEngine; // what is shown (chosen layers included)

        // Clamp the resolution of very large pages so one image can't exhaust memory.
        var dpiFor = pages.Distinct().ToDictionary(p => p, p => PageImages.ClampDpi(engine.GetPage(p), res));
        var clamped = dpiFor.Values.Where(d => d < res).ToList();
        // Busy from here (also while asking about large pages), so nothing replaces the engine this export reads.
        using var busy = tab.BeginBusy(Loc.Plural(pages.Length, Strings.Export_Exporting_One, Strings.Export_Exporting_Many));
        if (clamped.Count > 0)
        {
            var lowest = clamped.Min();
            var many = clamped.Count > 1;
            if (!Prompt.Confirm(owner, Strings.File_VeryLarge,
                    Loc.Plural(clamped.Count, Strings.File_TooLarge_One, Strings.File_TooLarge_Many, res, lowest, PageImages.MaxPixels / 1e6),
                    Strings.File_Export)) return;
            Log.Write($"Export: {clamped.Count} page(s) clamped below {res} dpi (lowest {lowest:0})");
        }

        var ext = jpeg ? "jpg" : "png";
        var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var targets = new List<(int Page, string Path)>();
        try
        {
            foreach (var p in pages) targets.Add((p, PdfFiles.UniquePath(dir, Loc.Format(Strings.File_PageImageName, name, p + 1, ext), reserved)));
        }
        catch (IOException ex)
        {
            Prompt.Error(owner, Strings.File_CantExportFolder, ex.Message);
            return;
        }

        var done = 0;
        using var progress = new ProgressPrompt(owner, Strings.File_ExportingImages, Loc.Plural(pages.Length, Strings.Export_Exporting_One, Strings.Export_Exporting_Many));
        var cancel = progress.Token;
        try
        {
            await Task.Run(() =>
            {
                foreach (var (p, path) in targets)
                {
                    cancel.ThrowIfCancellationRequested();
                    progress.Report(Loc.Format(Strings.File_ExportingPage, p + 1, done + 1, targets.Count), (double)done / targets.Count);
                    try
                    {
                        engine.SaveImage(p, dpiFor[p], path, jpeg, cancel);
                    }
                    catch (OperationCanceledException)
                    {
                        try { File.Delete(path); } catch (Exception) { } // don't leave half an image behind
                        throw;
                    }
                    Interlocked.Increment(ref done);
                }
            }, cancel);
            host.ShowStatus(Loc.Format(Strings.File_ExportedImages, done, dir));
            Shell.Open(dir);
        }
        catch (OperationCanceledException)
        {
            Log.Write($"Export cancelled after {done} of {targets.Count} image(s)");
            host.ShowStatus(Loc.Format(Strings.File_ExportCancelledImages, done, dir));
        }
        catch (Exception ex)
        {
            Log.Write($"Export failed after {done} image(s): {ex}");
            Prompt.Error(owner, Loc.Format(Strings.File_ExportStopped, done), ex.Message);
        }
    }

    public static async Task ShowProperties(Window owner, DocumentTab tab)
    {
        var s = tab.Session;
        var page = Organize.CurrentPage(tab);
        var g = s.Engine.GetPage(page);
        PdfMetadata? meta = null;
        if (s.IsPdf)
        {
            try
            {
                meta = PageEditor.ReadMetadata(s.Data, s.Password);
            }
            catch (Exception ex) when (ex is InvalidOperationException or PdfSharp.PdfSharpException)
            {
                Log.Write($"Metadata unreadable: {ex.Message}");
            }
        }

        var dlg = new FormDialog(owner, Strings.File_PropertiesTitle, s.IsPdf ? Strings.File_SaveChanges : Strings.Common_Close, 520);
        var info = new Grid();
        // The labels' column: as wide as the longest label (Spanish's "Tamaño del archivo"), never narrower than English's.
        info.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 120 });
        info.ColumnDefinitions.Add(new ColumnDefinition());
        void Row(string label, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            var r = info.RowDefinitions.Count;
            info.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var l = new TextBlock { Text = label, Margin = new Thickness(0, 2, 8, 2), Style = (Style)Application.Current.FindResource("Caption") };
            var v = new TextBox { Text = value, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0), Margin = new Thickness(0, 2, 0, 2), TextWrapping = TextWrapping.Wrap };
            System.Windows.Automation.AutomationProperties.SetName(v, label); // read-only, but a screen reader still lands on it
            Grid.SetRow(l, r);
            Grid.SetRow(v, r);
            Grid.SetColumn(v, 1);
            info.Children.Add(l);
            info.Children.Add(v);
        }
        Row(Strings.File_PropFile, s.DisplayName);
        Row(Strings.File_PropLocation, s.FilePath is null ? Strings.File_NotSavedYet : Path.GetDirectoryName(s.FilePath));
        Row(Strings.File_PropSize, FormatSize(s.Data.Length));
        Row(Strings.Common_Pages, s.Engine.PageCount.ToString());
        Row(Strings.File_PageSize, Loc.Format(Strings.File_PropPageSize, Organize.Inches(g.Width), Organize.Inches(g.Height), g.Width * 25.4 / 72, g.Height * 25.4 / 72, page + 1));
        Row(Strings.File_PropVersion, meta?.Version);
        Row(Strings.File_PropSecurity, SecurityActions.Describe(s));
        Row(Strings.File_PropCreator, meta?.Creator);
        Row(Strings.File_PropProducer, meta?.Producer);
        Row(Strings.File_PropCreated, meta?.Created?.ToString("g"));
        Row(Strings.File_PropModified, meta?.Modified?.ToString("g"));
        dlg.Add(Strings.Viewer_Document, info);
        if (s.IsPdf) dlg.AddFooterButton(Strings.File_WhatsInPdfButton).Click += (_, _) => _ = InventoryActions.Show(dlg, tab, null);

        TextBox? title = null, author = null, subject = null, keywords = null;
        if (meta is not null)
        {
            title = dlg.AddText(Strings.Access_Title, meta.Title);
            author = dlg.AddText(Strings.File_Author, meta.Author);
            subject = dlg.AddText(Strings.File_Subject, meta.Subject);
            keywords = dlg.AddText(Strings.File_Keywords, meta.Keywords);
        }
        if (!dlg.ShowModal() || meta is null) return;

        if (title!.Text == meta.Title && author!.Text == meta.Author && subject!.Text == meta.Subject && keywords!.Text == meta.Keywords) return;
        var (t, a, sub, k) = (title.Text, author!.Text, subject!.Text, keywords!.Text);
        await tab.RunEdit(Strings.File_EditPropsLabel, (d, pw) => PageEditor.WriteMetadata(d, pw, t, a, sub, k));
    }

    internal static string FormatSize(long bytes) => bytes switch
    {
        < 1024 => Loc.Format(Strings.Form_Bytes, bytes),
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB", // in every language: unit symbol
        _ => $"{bytes / 1024.0 / 1024.0:0.##} MB", // in every language: unit symbol
    };
}
