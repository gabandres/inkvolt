using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PrintDesk.App.Views;

namespace PrintDesk.App;

/// <summary>
/// Developer aid: <c>PrintDesk.exe --snapshot out.png [--tab Scan]</c> waits for the printer to connect,
/// renders the window to a PNG and exits. Used to verify the UI without screen capture.
/// </summary>
internal static class DevSnapshot
{
    public static async Task RunAsync(MainWindow window, string path, string? tab)
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        if (tab is not null && FindTabs(window) is { } tabs)
        {
            tabs.SelectedItem = tabs.Items.OfType<TabItem>().FirstOrDefault(t => (t.Header as string)?.Contains(tab, StringComparison.OrdinalIgnoreCase) == true);
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
        var content = (FrameworkElement)window.Content;
        var dpi = VisualTreeHelper.GetDpi(window);
        var bmp = new RenderTargetBitmap((int)(content.ActualWidth * dpi.DpiScaleX), (int)(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(window.Background ?? Brushes.White, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            dc.DrawRectangle(new VisualBrush(content), null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
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
/// Developer aid: <c>PrintDesk.exe file.pdf --autoprint result.txt</c> waits for the PDF to load, presses Print
/// in the selected printer's Print section, writes the outcome to <c>result.txt</c> and exits.
/// </summary>
internal static class DevAutoPrint
{
    public static async Task RunAsync(ViewModels.MainViewModel vm, string resultPath)
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
            var sw = System.Diagnostics.Stopwatch.StartNew();
            System.Diagnostics.Trace.WriteLine($"autoprint: canExecute={print.PrintCommand.CanExecute(null)} pages={print.PageCount}");
            await print.PrintCommand.ExecuteAsync(null);
            result = $"{sw.ElapsedMilliseconds} ms: {print.Message} (error={print.MessageIsError})";
        }
        await File.WriteAllTextAsync(resultPath, result);
        Application.Current.Shutdown();
    }
}
