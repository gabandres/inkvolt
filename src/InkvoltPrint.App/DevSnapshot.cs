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
/// <c>--scan</c> runs one scan first (with <c>--demo</c>: a generated page).
/// </summary>
internal static class DevSnapshot
{
    public static (double Width, double Height)? Size(string[] args) =>
        Array.IndexOf(args, "--size") is var i and >= 0 && i + 2 < args.Length
        && double.TryParse(args[i + 1], System.Globalization.CultureInfo.InvariantCulture, out var w)
        && double.TryParse(args[i + 2], System.Globalization.CultureInfo.InvariantCulture, out var h) && w > 0 && h > 0
            ? (w, h) : null;

    public static async Task RunAsync(MainWindow window, string path, string? tab, bool scan = false)
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        if (tab is not null && FindTabs(window) is { } tabs)
        {
            tabs.SelectedItem = tabs.Items.OfType<TabItem>().FirstOrDefault(t => (t.Header as string)?.Contains(tab, StringComparison.OrdinalIgnoreCase) == true);
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
        if (scan && window.DataContext is ViewModels.MainViewModel { Selected.Scan: { } scanner })
        {
            await scanner.ScanCommand.ExecuteAsync(null);
            await Task.Delay(TimeSpan.FromSeconds(2));
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
