using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.App.Views;

namespace InkvoltPrint.App;

/// <summary>
/// Developer aid: <c>InkvoltPrint.exe --snapshot out.png [--tab Scan] [--size 1366 860] [--theme Dark] [--demo]</c> waits
/// for the printer to connect, renders the window to a PNG and exits. Used to verify the UI without screen capture;
/// with <c>--demo</c> (Demo.cs) it needs no printer, e.g. for screenshots. <c>--size</c> is the window size in DIPs;
/// <c>--scan [n]</c> runs one scan, or n, first (with <c>--demo</c>: generated pages, straight, crooked, blank in turn);
/// <c>--crop n</c> then opens the crop view on page n; <c>--source glass|feeder|duplex</c>, <c>--split none|patch|blank|either</c> and
/// <c>--keep-separators</c> set the tab before scanning (with <c>--preset</c>, demo only: the preset scans a feeder batch and splits it);
/// <c>--find-photos</c> turns on Several photos on the glass first (with <c>--demo</c>: the glass holds three made-up prints), and
/// <c>--crop n</c> then opens the photo view on page n, <c>--photo-box n</c> selecting its n-th photo; <c>--scroll-end</c> scrolls the tab to its end; <c>--copy document|idcard-front|idcard</c> runs a copy
/// (with <c>--demo</c>: generated scans, "printed" to the made-up queue); <c>--printer n</c> shows the n-th printer in the
/// list first (with <c>--demo</c>: 2 is the inkjet, an IPP / eSCL printer without HP's interfaces, 3 the office laser that moved
/// to a new address, 5 a printer that answers SNMP only, 6 a USB laser, 7 a printer shared from another PC and 8 a color MFP on a TCP/IP
/// port read over SNMP, the last three listed from the made-up PC's Windows queues, the USB laser scanning through its made-up WIA
/// scanner, and 9 a made-up WIA photo flatbed listed as a scanner of its own); <c>--fix</c> opens the offline fixer and runs its checks, <c>--fix all</c> then applies every repair it
/// offers, answering yes to its questions, <c>--fix waiting</c> starts the first repair needing permission and leaves the made-up
/// prompt unanswered, <c>--fix cancel</c> then presses its Cancel (only ever with <c>--demo</c>: the demo printers' fixer works on a made-up PC);
/// <c>--preset id|name</c> runs a scan preset (with <c>--demo</c>: saved under %TEMP%\Inkvolt Print demo scans);
/// <c>--then print|email|pdf</c> gives it that after-saving step first (demo only); <c>--photos [layout]</c> fills the Photos tab with
/// generated sample pictures (options: see <see cref="PhotosAsync"/>); <c>--maintenance [n]</c> scrolls to the Maintenance card
/// and runs its n-th action (demo only, see <see cref="MaintenanceAsync"/>); <c>--presets [n]</c> opens the presets editor on its n-th preset and renders the editor instead of the main window;
/// <c>--dialog settings|help|whatsnew|report|addprinter [--dialog-wait ms]</c> renders that window instead.
/// With <c>--tray</c> (the notification-area icon, on in demo mode): <c>--simulate-alerts</c> feeds a toner drop on the first demo
/// printer and a paper jam on the second through the alert rules; <c>--tray-shot menu|hidden|alert|settings</c> renders the icon's
/// menu (hidden: after closing the window to the tray and one background check of each printer), the last alert as Windows shows it (a preview: the real one is drawn by Windows), or the alert settings instead of the window.
/// Without <c>--snapshot</c>, <c>--demo --tray --simulate-alerts</c> shows the real notification after the printers connect.
/// </summary>
internal static class DevSnapshot
{
    public static (double Width, double Height)? Size(string[] args) =>
        Array.IndexOf(args, "--size") is var i and >= 0 && i + 2 < args.Length
        && double.TryParse(args[i + 1], System.Globalization.CultureInfo.InvariantCulture, out var w)
        && double.TryParse(args[i + 2], System.Globalization.CultureInfo.InvariantCulture, out var h) && w > 0 && h > 0
            ? (w, h) : null;

    public static async Task RunAsync(MainWindow window, string path, string? tab, int scans = 0, bool scrollToEnd = false,
        string? copy = null, int crop = 0, int printer = 0, string? fix = null, string? preset = null, int editPresets = 0, string? then = null,
        string? tray = null, bool simulateAlerts = false, string[]? args = null)
    {
        args ??= [];
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
            // --source glass|feeder|duplex, --split none|patch|blank|either and --keep-separators set the tab first.
            if (Value(args, "--source") is { } source
                && scanner.Sources.FirstOrDefault(s => s.Value == source switch { "feeder" => Core.Escl.ScanSource.Adf, "duplex" => Core.Escl.ScanSource.AdfDuplex, _ => Core.Escl.ScanSource.Platen }) is { } chosen)
                scanner.Source = chosen;
            if (Value(args, "--split") is { } split)
                scanner.SplitMode = scanner.SplitChoices.FirstOrDefault(c => c.Value == split switch
                {
                    "patch" => Core.Imaging.SplitAt.PatchCode, "blank" => Core.Imaging.SplitAt.BlankPage,
                    "either" => Core.Imaging.SplitAt.PatchCodeOrBlankPage, _ => Core.Imaging.SplitAt.None,
                });
            if (args.Contains("--keep-separators")) scanner.KeepSeparators = true;
            if (args.Contains("--find-photos")) scanner.FindPhotos = true;
            for (var i = 0; i < scans; i++) await scanner.ScanCommand.ExecuteAsync(null);
            if (crop > 0 && crop <= scanner.Pages.Count) await scanner.CropCommand.ExecuteAsync(scanner.Pages[crop - 1]);
            // --photo-box n: select the n-th photo in the photo view (opened by --crop on a scan of photos).
            if (int.TryParse(Value(args, "--photo-box"), out var photoBox) && scanner.IsEditingPhotos && photoBox <= scanner.EditedPhotos.Count)
                scanner.SelectedPhoto = photoBox - 1;
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        if (preset is not null && window.DataContext is ViewModels.MainViewModel presetMain)
        {
            // --then print|email|pdf: try the preset's after-saving step (demo only: it never reaches a real queue or mail app).
            if (then is not null && presetMain.Presets.IsDemo && presetMain.Presets.Find(preset) is { } chosen
                && Enum.TryParse<Core.Presets.PresetAfter>(then switch { "pdf" => "OpenInInkvoltPdf", var t => t }, ignoreCase: true, out var after))
                presetMain.Presets.Update(chosen with { After = after });
            // --find-photos: the preset finds the photos on the glass and saves each as a JPEG, without the review (demo only).
            if (args.Contains("--find-photos") && presetMain.Presets.IsDemo && presetMain.Presets.Find(preset) is { } photos)
                presetMain.Presets.Update(photos with { FindPhotos = true, Review = false, FileType = Core.Presets.PresetFileType.Jpeg, Source = Core.Presets.PresetSource.Glass });
            // --split patch|blank|either: the preset scans a batch from the feeder and splits it (demo only).
            if (Value(args, "--split") is { } presetSplit && presetMain.Presets.IsDemo && presetMain.Presets.Find(preset) is { } splitting)
                presetMain.Presets.Update(splitting with
                {
                    Source = Core.Presets.PresetSource.Feeder, KeepSeparators = args.Contains("--keep-separators"),
                    SplitAt = presetSplit switch { "blank" => Core.Imaging.SplitAt.BlankPage, "either" => Core.Imaging.SplitAt.PatchCodeOrBlankPage, _ => Core.Imaging.SplitAt.PatchCode },
                });
            var ask = ViewModels.Prompt.Confirm;
            ViewModels.Prompt.Confirm = (_, _) => true; // "discard the pages scanned above?"
            try { await presetMain.RunPresetWhenReadyAsync(preset); }
            finally { ViewModels.Prompt.Confirm = ask; }
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        if (copy is not null && window.DataContext is ViewModels.MainViewModel { Selected.Copy: { } copier })
        {
            copier.IdCard = copy.StartsWith("idcard", StringComparison.Ordinal);
            await copier.CopyCommand.ExecuteAsync(null);
            if (copy == "idcard") await copier.ScanBackCommand.ExecuteAsync(null);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        if (args.Contains("--photos") && window.DataContext is ViewModels.MainViewModel { Selected: { } photoPrinter })
            await PhotosAsync(photoPrinter, args);
        if (args.Contains("--maintenance") && window.DataContext is ViewModels.MainViewModel { Selected: { } maintained })
            await MaintenanceAsync(maintained, args);
        if (fix is not null && window.DataContext is ViewModels.MainViewModel { Selected: { } fixing })
        {
            await fixing.OpenFixerCommand.ExecuteAsync(null);
            if (fix is "waiting" or "cancel" && fixing.Pc.IsDemo
                && fixing.Fixer.Repairs.FirstOrDefault(r => r.Repair.AdminOnly && !r.Repair.ManualOnly) is { } elevated)
            {
                // The first repair needing permission, its prompt left unanswered; "cancel" then presses Cancel.
                DemoOfflinePc.PermissionWaits = true;
                var ask = ViewModels.Prompt.Confirm;
                ViewModels.Prompt.Confirm = (_, _) => true;
                var running = elevated.FixCommand.ExecuteAsync(null);
                ViewModels.Prompt.Confirm = ask;
                await Task.Delay(TimeSpan.FromSeconds(1));
                if (fix == "cancel")
                {
                    elevated.CancelCommand.Execute(null);
                    await running;
                }
            }
            if (fix == "all" && fixing.Pc.IsDemo)
            {
                var ask = ViewModels.Prompt.Confirm;
                ViewModels.Prompt.Confirm = (_, _) => true;
                try
                {
                    for (var i = 0; i < 10; i++)
                    {
                        var next = fixing.Fixer.Repairs.FirstOrDefault(r => !r.IsAlternative && !r.Repair.ManualOnly && r.Message is null);
                        if (next is null) break;
                        await next.FixCommand.ExecuteAsync(null);
                    }
                }
                finally
                {
                    ViewModels.Prompt.Confirm = ask;
                }
            }
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        if (scrollToEnd && FindTabs(window) is { } shown)
        {
            foreach (var sv in Descendants<ScrollViewer>(shown)) sv.ScrollToEnd();
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        var trayController = (Application.Current as App)?.Tray;
        if (simulateAlerts && trayController is not null)
        {
            trayController.Simulate();
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        if (tray is not null && trayController is not null && await TrayShotAsync(trayController, tray, path)) return;
        Window shot = window;
        if (editPresets > 0 && window.DataContext is ViewModels.MainViewModel editMain)
        {
            var editor = ScanPresetsDialog.Create(editMain.Presets, editMain.Selected?.Name ?? "Demo printer");
            editor.Owner = window;
            if (editor.DataContext is ViewModels.ScanPresetsViewModel evm && editPresets <= evm.Items.Count) evm.Selected = evm.Items[editPresets - 1];
            editor.Show();
            await Task.Delay(TimeSpan.FromSeconds(2));
            if (scrollToEnd)
            {
                foreach (var sv in Descendants<ScrollViewer>(editor)) sv.ScrollToEnd();
                await Task.Delay(TimeSpan.FromSeconds(1));
            }
            shot = editor;
        }
        // --dialog settings|help|whatsnew|report|addprinter: that window instead of the main one.
        if (Value(args, "--dialog") is { } name && window.DataContext is ViewModels.MainViewModel dialogMain)
        {
            Window? dialog = name switch
            {
                "settings" => SettingsWindow.Create(dialogMain, trayController),
                "help" => HelpDialog.Create(dialogMain),
                "whatsnew" => WhatsNewDialog.Create(AppHelp.Notes()),
                "report" => ReportProblemDialog.Create(AppHelp.Report(dialogMain)),
                "addprinter" => AddPrinterWindow.Create(dialogMain),
                _ => null,
            };
            if (dialog is not null)
            {
                dialog.Owner = window;
                dialog.Show();
                // Add a printer searches the (made-up) network first: about three seconds.
                await Task.Delay(Value(args, "--dialog-wait") is { } ms ? TimeSpan.FromMilliseconds(int.Parse(ms)) : TimeSpan.FromSeconds(name == "addprinter" ? 5 : 1));
                shot = dialog;
            }
        }
        // A dialog's content has a margin, which a VisualBrush would shift by: take the window's own root instead.
        var content = shot == window ? (FrameworkElement)shot.Content : (FrameworkElement)VisualTreeHelper.GetChild(shot, 0);
        var dpi = VisualTreeHelper.GetDpi(shot);
        var bmp = new RenderTargetBitmap((int)(content.ActualWidth * dpi.DpiScaleX), (int)(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var bg = shot.TryFindResource("SolidBackgroundFillColorBaseBrush") as Brush ?? shot.Background ?? Brushes.White;
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

    private static string? Value(string[] args, string name) =>
        Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal) ? args[i + 1] : null;

    /// <summary>
    /// <c>--maintenance [n]</c>: scrolls to the Maintenance card ("Printer maintenance…") and, with <c>--demo</c> only, runs
    /// its n-th action, answering yes to the question (demo printers accept and forget it: nothing is sent anywhere).
    /// </summary>
    private static async Task MaintenanceAsync(ViewModels.PrinterViewModel printer, string[] args)
    {
        for (var i = 0; i < 20 && !printer.Maintenance.IsLoaded; i++) await Task.Delay(250);
        printer.ShowMaintenanceCommand.Execute(null);
        await Task.Delay(TimeSpan.FromSeconds(1));
        if (!printer.Pc.IsDemo || !int.TryParse(Value(args, "--maintenance"), out var n) || n < 1 || n > printer.Maintenance.Items.Count) return;
        var ask = ViewModels.Prompt.Confirm;
        ViewModels.Prompt.Confirm = (_, _) => true;
        try { await printer.Maintenance.Items[n - 1].RunCommand.ExecuteAsync(null); }
        finally { ViewModels.Prompt.Confirm = ask; }
        printer.ShowMaintenanceCommand.Execute(null); // the result line made the card taller
        await Task.Delay(TimeSpan.FromSeconds(1));
    }

    /// <summary>
    /// <c>--photos [layout]</c>: the Photos tab with the demo's generated sample pictures (Demo.SamplePhotos), in a layout
    /// (full, 4x6in, 5x7in, 8x10in, 10x15cm, 13x18cm, wallet, contact); <c>--paper key</c> (e.g. NorthAmerica4x6),
    /// <c>--borderless</c>, <c>--fit</c>, <c>--one-per-sheet</c>, <c>--per-sheet n</c>, <c>--photo-zoom n</c> (zoom the n-th photo and move
    /// its crop) and <c>--photo-sheets folder</c>: each sheet rendered to a PNG there by the print job's own paginator (what
    /// the printer would get, at 100 dpi), so the print path is checked without printing.
    /// </summary>
    private static async Task PhotosAsync(ViewModels.PrinterViewModel printer, string[] args)
    {
        printer.SelectedSection = ViewModels.PrinterViewModel.PhotosSection;
        var vm = printer.Photos;
        await Task.Delay(TimeSpan.FromSeconds(1)); // the queue's options
        await vm.AddAsync(Demo.SamplePhotos());
        if (Value(args, "--photos") is { } layout && ViewModels.PhotosViewModel.Layouts.FirstOrDefault(l => l.Key == layout) is { } chosen) vm.Layout = chosen;
        if (Value(args, "--paper") is { } key && vm.Papers.FirstOrDefault(p => p.Key == key) is { } paper)
        {
            vm.Paper = paper;
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        if (int.TryParse(Value(args, "--per-sheet"), out var perSheet) && ViewModels.PhotosViewModel.ContactCounts.FirstOrDefault(c => c.Value == perSheet) is { } count)
            vm.PerSheet = count;
        if (args.Contains("--borderless")) vm.Borderless = true;
        if (args.Contains("--fit")) vm.Fill = false;
        if (args.Contains("--one-per-sheet")) vm.OnePhotoPerSheet = true;
        if (int.TryParse(Value(args, "--photo-zoom"), out var nth) && nth >= 1 && nth <= vm.Photos.Count)
        {
            vm.Selected = vm.Photos[nth - 1];
            vm.Selected.ZoomPercent = 160;
            vm.Selected.SetCrop(vm.Selected.Crop with { PanX = 0.8, PanY = -0.5 });
        }
        await Task.Delay(TimeSpan.FromSeconds(1));
        if (Value(args, "--photo-sheets") is not { } folder) return;
        Directory.CreateDirectory(folder);
        var (sheets, photos, sheetPaper) = vm.PrintPlan();
        var size = new Size(sheetPaper.Width * 96, sheetPaper.Height * 96);
        using var images = new Printing.PrintImages();
        var paginator = new Printing.PhotoPrinting.PhotoPaginator(sheets, photos, size, images);
        for (var i = 0; i < paginator.PageCount; i++)
        {
            var page = paginator.GetPage(i);
            const double dpi = 100;
            var bmp = new RenderTargetBitmap((int)Math.Ceiling(size.Width * dpi / 96), (int)Math.Ceiling(size.Height * dpi / 96), dpi, dpi, PixelFormats.Pbgra32);
            bmp.Render(page.Visual);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(bmp));
            await using var fs = File.Create(Path.Combine(folder, $"sheet-{i + 1}.png"));
            enc.Save(fs);
        }
        // The same pages through the XPS serializer the spooler gets (job.xps: its images should stay JPEG).
        var xpsPath = Path.Combine(folder, "job.xps");
        File.Delete(xpsPath);
        using var xps = new System.Windows.Xps.Packaging.XpsDocument(xpsPath, FileAccess.ReadWrite);
        System.Windows.Xps.Packaging.XpsDocument.CreateXpsDocumentWriter(xps).Write(new Printing.PhotoPrinting.PhotoPaginator(sheets, photos, size, images));
    }

    /// <summary><c>--demo --tray --simulate-alerts</c> without a snapshot: the real notification, once the demo printers are read.</summary>
    public static async Task SimulateAlertsAsync(Tray.TrayController? tray)
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        tray?.Simulate();
    }

    /// <summary>The tray's menu, alert or settings rendered to <paramref name="path"/>; false for an unknown name.</summary>
    private static async Task<bool> TrayShotAsync(Tray.TrayController tray, string what, string path)
    {
        FrameworkElement content;
        Window? host = null;
        System.Windows.Controls.ContextMenu? menu = null;
        switch (what)
        {
            case "hidden" or "menu":
                if (what == "hidden")
                {
                    // Closed to the tray: live connections stop, then one low-frequency check of each printer, then the menu.
                    tray.HideWindow();
                    await tray.CheckNowAsync();
                }
                menu = tray.BuildMenu();
                menu.Placement = System.Windows.Controls.Primitives.PlacementMode.AbsolutePoint;
                menu.HorizontalOffset = menu.VerticalOffset = 100;
                menu.IsOpen = true;
                await Task.Delay(TimeSpan.FromSeconds(1));
                content = menu;
                break;
            case "alert":
                content = AlertPreview(tray);
                content.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                content.Arrange(new Rect(content.DesiredSize));
                content.UpdateLayout();
                break;
            case "settings":
                host = Views.SettingsWindow.Create((ViewModels.MainViewModel)Application.Current.MainWindow.DataContext, tray);
                host.Owner = Application.Current.MainWindow;
                host.Show();
                await Task.Delay(TimeSpan.FromSeconds(1));
                content = (FrameworkElement)VisualTreeHelper.GetChild(host, 0);
                break;
            default:
                return false;
        }
        var dpi = VisualTreeHelper.GetDpi(Application.Current.MainWindow);
        var bmp = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * dpi.DpiScaleX), (int)Math.Ceiling(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var area = new Rect(0, 0, content.ActualWidth, content.ActualHeight);
            var bg = Application.Current.MainWindow.TryFindResource("SolidBackgroundFillColorBaseBrush") as Brush ?? Brushes.White;
            dc.DrawRectangle(bg, null, area);
            dc.DrawRectangle(new VisualBrush(content) { Viewbox = area, ViewboxUnits = BrushMappingMode.Absolute }, null, area);
        }
        bmp.Render(visual);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        await using (var fs = File.Create(path)) enc.Save(fs);
        if (menu is not null)
        {
            // Shutting down while the just-closed menu's capture is being released hung in WPF's pen/touch thread
            // (HwndSource.Dispose → ReleaseCapture → PenThreadWorker): let the close finish first.
            menu.IsOpen = false;
            await Task.Delay(TimeSpan.FromMilliseconds(500));
        }
        host?.Close();
        ExitSoon();
        Application.Current.Shutdown();
        return true;
    }

    /// <summary>
    /// Dev aid only: the PNG is written, so if WPF's shutdown still hangs (the pen/touch thread has, after a menu), end the
    /// process a few seconds later rather than leave it running.
    /// </summary>
    private static void ExitSoon() =>
        new Thread(() =>
        {
            Thread.Sleep(TimeSpan.FromSeconds(10));
            Log.Write("Snapshot: shutdown didn't finish in 10 s; exiting");
            Environment.Exit(0);
        }) { IsBackground = true, Name = "Snapshot exit" }.Start();

    /// <summary>
    /// The last alert laid out like a Windows notification (app name, badge icon, title, text). Windows draws the real one,
    /// which a window snapshot can't capture; this shows what it will say.
    /// </summary>
    private static FrameworkElement AlertPreview(Tray.TrayController tray)
    {
        var (title, text) = tray.LastNotices.Count > 0 ? Tray.TrayController.NoticeText(tray.LastNotices) : ("(no alert yet)", "Run with --simulate-alerts.");
        var level = tray.LastNotices.Count > 0 ? tray.LastNotices.Max(n => n.Level) : Core.Alerts.AlertLevel.Ok;
        var badge = level switch
        {
            Core.Alerts.AlertLevel.Error => "error", Core.Alerts.AlertLevel.Warning => "warning", Core.Alerts.AlertLevel.Offline => "offline", _ => null,
        };
        var icon = BitmapDecoder.Create(new Uri(badge is null ? "pack://application:,,,/InkvoltPrint.ico" : $"pack://application:,,,/Tray/InkvoltPrint-{badge}.ico"),
            BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames.OrderBy(f => f.PixelWidth).First(f => f.PixelWidth >= 48);
        var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        header.Children.Add(new Image { Width = 16, Height = 16, Source = AppIcon.Frame(16 * VisualTreeHelper.GetDpi(Application.Current.MainWindow).DpiScaleX), Margin = new Thickness(0, 0, 8, 0) });
        header.Children.Add(new TextBlock { Text = "Inkvolt Print", FontSize = 12 });
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
        var row = new DockPanel();
        var image = new Image { Width = 48, Height = 48, Source = icon, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(image, Dock.Left);
        row.Children.Add(image);
        row.Children.Add(body);
        var stack = new StackPanel();
        stack.Children.Add(header);
        stack.Children.Add(row);
        var card = new Border
        {
            Width = 364, Padding = new Thickness(16), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = stack,
            Margin = new Thickness(12),
        };
        card.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorTertiaryBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        card.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorPrimaryBrush");
        var outer = new Border { Child = card };
        outer.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        return outer;
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
