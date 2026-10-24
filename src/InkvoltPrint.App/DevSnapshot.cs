using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.App.Views;

namespace InkvoltPrint.App;

/// <summary>
/// Developer aid: <c>InkvoltPrint.exe --snapshot out.png [--tab Scan] [--size 1366 860] [--theme Dark] [--demo]</c> waits
/// for the printer to connect, renders the window to a PNG and exits. Used to verify the UI without screen capture;
/// with <c>--demo</c> (Demo.cs) it needs no printer, e.g. for screenshots. <c>--size</c> is the window size in DIPs;
/// <c>--scan [n]</c> runs one scan, or n, first (with <c>--demo</c>: generated pages, straight, crooked, blank in turn);
/// <c>--crop n</c> then opens the crop view on page n; <c>--scroll-end</c> scrolls the tab to its end; <c>--copy document|idcard-front|idcard</c> runs a copy
/// (with <c>--demo</c>: generated scans, "printed" to the made-up queue); <c>--printer n</c> shows the n-th printer in the
/// list first (with <c>--demo</c>: 2 is the inkjet, an IPP / eSCL printer without HP's interfaces).
/// </summary>
internal static class DevSnapshot
{
    public static (double Width, double Height)? Size(string[] args) =>
        Array.IndexOf(args, "--size") is var i and >= 0 && i + 2 < args.Length
        && double.TryParse(args[i + 1], System.Globalization.CultureInfo.InvariantCulture, out var w)
        && double.TryParse(args[i + 2], System.Globalization.CultureInfo.InvariantCulture, out var h) && w > 0 && h > 0
            ? (w, h) : null;

    public static async Task RunAsync(MainWindow window, string path, string? tab, int scans = 0, bool scrollToEnd = false,
        string? copy = null, int crop = 0, int printer = 0)
    {
        if (printer > 0 && window.DataContext is ViewModels.MainViewModel main && printer <= main.Printers.Count)
            main.Selected = main.Printers[printer - 1];
        await Task.Delay(TimeSpan.FromSeconds(5));
        if (tab is not null && FindTabs(window) is { } tabs)
        {
            tabs.SelectedItem = tabs.Items.OfType<TabItem>().FirstOrDefault(t => (t.Header as string)?.Contains(tab, StringComparison.OrdinalIgnoreCase) == true);
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
        if (scans > 0 && window.DataContext is ViewModels.MainViewModel { Selected.Scan: { } scanner })
        {
            for (var i = 0; i < scans; i++) await scanner.ScanCommand.ExecuteAsync(null);
            if (crop > 0 && crop <= scanner.Pages.Count) await scanner.CropCommand.ExecuteAsync(scanner.Pages[crop - 1]);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        if (copy is not null && window.DataContext is ViewModels.MainViewModel { Selected.Copy: { } copier })
        {
            copier.IdCard = copy.StartsWith("idcard", StringComparison.Ordinal);
            await copier.CopyCommand.ExecuteAsync(null);
            if (copy == "idcard") await copier.ScanBackCommand.ExecuteAsync(null);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        if (scrollToEnd && FindTabs(window) is { } shown)
        {
            foreach (var sv in Descendants<ScrollViewer>(shown)) sv.ScrollToEnd();
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        var content = (FrameworkElement)window.Content;
        var dpi = VisualTreeHelper.GetDpi(window);
        var bmp = new RenderTargetBitmap((int)(content.ActualWidth * dpi.DpiScaleX), (int)(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var bg = window.TryFindResource("SolidBackgroundFillColorBaseBrush") as Brush ?? window.Background ?? Brushes.White;
            dc.DrawRectangle(bg, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            // Map the content 1:1: by default a VisualBrush stretches the visual's bounds (which can overhang) to fit.
            var area = new Rect(0, 0, content.ActualWidth, content.ActualHeight);
            dc.DrawRectangle(new VisualBrush(content) { Viewbox = area, ViewboxUnits = BrushMappingMode.Absolute }, null, area);
        }
        bmp.Render(visual);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        await using (var fs = File.Create(path)) enc.Save(fs);
        Application.Current.Shutdown();
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T t) yield return t;
            foreach (var d in Descendants<T>(child)) yield return d;
        }
    }

    private static TabControl? FindTabs(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is TabControl t) return t;
            if (FindTabs(child) is { } found) return found;
        }
        return null;
    }
}

/// <summary>
/// Developer aid: <c>InkvoltPrint.exe file.pdf --autoprint result.txt</c> waits for the PDF to load, presses Print
/// in the selected printer's Print section, writes the outcome to <c>result.txt</c> and exits.
/// </summary>
internal static class DevAutoPrint
{
    public static async Task RunAsync(ViewModels.MainViewModel vm, string resultPath, int copies = 1, bool twoSided = false)
    {
        System.Diagnostics.Trace.Listeners.Add(new System.Diagnostics.TextWriterTraceListener(resultPath + ".log"));
        System.Diagnostics.Trace.AutoFlush = true;
        var print = vm.Selected?.Print;
        System.Diagnostics.Trace.WriteLine($"autoprint: printer={vm.Selected?.Name}");
        string result;
        if (print is null) result = "no printer selected";
        else
        {
            for (var i = 0; i < 40 && !print.PrintCommand.CanExecute(null); i++) await Task.Delay(250);
            print.Copies = copies;
            for (var i = 0; i < 40 && twoSided && !print.CanTwoSided; i++) await Task.Delay(250);
            print.TwoSided = twoSided && print.CanTwoSided;
            System.Diagnostics.Trace.WriteLine($"autoprint: copies={print.Copies} twoSided={print.TwoSided} summary={print.Summary}");
            var sw = System.Diagnostics.Stopwatch.StartNew();
            System.Diagnostics.Trace.WriteLine($"autoprint: canExecute={print.PrintCommand.CanExecute(null)} pages={print.PageCount}");
            await print.PrintCommand.ExecuteAsync(null);
            result = $"{sw.ElapsedMilliseconds} ms: {print.Message} (error={print.MessageIsError}; {print.Summary})";
        }
        await File.WriteAllTextAsync(resultPath, result);
        Application.Current.Shutdown();
    }
}
