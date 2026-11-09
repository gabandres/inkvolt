using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.App.Views;

namespace InkvoltPrint.App;

/// <summary>
/// Developer aid: <c>InkvoltPrint.exe --snapshot out.png [--tab Scan] [--size 1366 860] [--theme Dark] [--lang es] [--demo]</c> waits
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
/// and runs its n-th action (demo only, see <see cref="MaintenanceAsync"/>); <c>--delete n</c> deletes the n-th scanned page and <c>--undo</c> undoes the last review change; <c>--cleanup crop,whiten,descreen,restore</c> sets the tab's clean up before scanning and <c>--clean n</c> opens the clean up view on the n-th page; <c>--presets [n]</c> opens the presets editor on its n-th preset and renders the editor instead of the main window;
/// <c>--dialog settings|help|whatsnew|report|addprinter|confirm|pro [--dialog-wait ms]</c> renders that window instead (<c>pro</c>: Help › Inkvolt Pro;
/// <c>--record</c> with <c>report</c> records the printer shown first; <c>--pro-key KEY</c> enters a key first, <c>--pro-enforce</c> shows the wording with the gate on; demo keeps the key in memory); <c>--a11y-audit findings.txt</c> writes the
/// shown window's controls without an accessible name or under 24 × 24 (<see cref="UiInspection"/>) before the snapshot;
/// <c>--needs-driver [scanner]</c> shows the first USB printer (or scanner) that needs its driver (with <c>--demo</c>: a made-up one), <c>--get-driver</c> then presses Get the driver (<c>--driver-link</c>: as a Store copy does it); <c>--nav open</c> opens the folded sidebar (a narrow window or a large Text size folds it); <c>--palette [words]</c> opens the
/// command palette with the words typed, and <c>--run-palette</c> then runs its first entry.
/// With <c>--tray</c> (the notification-area icon, on in demo mode): <c>--simulate-alerts</c> feeds a toner drop on the first demo
/// printer and a paper jam on the second through the alert rules; <c>--tray-shot menu|hidden|alert|settings</c> renders the icon's
/// menu (hidden: after closing the window to the tray and one background check of each printer), the last alert as Windows shows it (a preview: the real one is drawn by Windows), or the alert settings instead of the window.
/// Without <c>--snapshot</c>, <c>--demo --tray --simulate-alerts</c> shows the real notifications after the printers connect (toasts in the
/// packaged copy, one per printer; balloons from a build in bin\). <c>--simulate-jobs</c> turns job alerts on and reads the made-up queues
/// through the same rules (<c>--tray-shot alert</c> then previews the toasts from their XML); <c>--open-queue n</c> does what clicking a job's notification for the n-th printer does.
/// </summary>
internal static class DevSnapshot
{
    public static (double Width, double Height)? Size(string[] args) =>
        Array.IndexOf(args, "--size") is var i and >= 0 && i + 2 < args.Length
        && double.TryParse(args[i + 1], System.Globalization.CultureInfo.InvariantCulture, out var w)
        && double.TryParse(args[i + 2], System.Globalization.CultureInfo.InvariantCulture, out var h) && w > 0 && h > 0
            ? (w, h) : null;

    /// <summary>Renders <paramref name="window"/> to <paramref name="path"/> as the flags in <paramref name="args"/> (above) say, then exits.</summary>
    public static async Task RunAsync(MainWindow window, string path, string[] args)
    {
        var tab = Value(args, "--tab");
        var scans = !args.Contains("--scan") ? 0 : int.TryParse(Value(args, "--scan"), out var n) ? n : 1;
        var scrollToEnd = args.Contains("--scroll-end");
        var copy = Value(args, "--copy");
        var crop = int.TryParse(Value(args, "--crop"), out var page) ? page : 0;
        var printer = int.TryParse(Value(args, "--printer"), out var nth) ? nth : 0;
        var fix = !args.Contains("--fix") ? null : Value(args, "--fix") is "all" or "waiting" or "cancel" ? Value(args, "--fix") : "check";
        var preset = Value(args, "--preset");
        var then = Value(args, "--then");
        var editPresets = !args.Contains("--presets") ? 0 : int.TryParse(Value(args, "--presets"), out var p) ? p : 1;
        var tray = Value(args, "--tray-shot");
        var simulateAlerts = args.Contains("--simulate-alerts");
        if (printer > 0 && window.DataContext is ViewModels.MainViewModel main && printer <= main.Printers.Count)
            main.Selected = main.Printers[printer - 1];
        await Task.Delay(TimeSpan.FromSeconds(5));
        // --needs-driver: shows the first USB printer that needs its driver (with --demo: the made-up USB laser).
        // --needs-driver scanner: the first scanner instead (with --demo: the made-up Epson scanner); --get-driver then presses
        // Get the driver (with --demo: a made-up find, nothing downloaded).
        if (args.Contains("--needs-driver") && window.DataContext is ViewModels.MainViewModel { NeedsDriver: [var first, ..] } withUsb)
        {
            var needing = Value(args, "--needs-driver") == "scanner" ? withUsb.NeedsDriver.FirstOrDefault(v => v.IsScanner) ?? first : first;
            withUsb.SelectedNeedsDriver = needing;
            if (args.Contains("--driver-link")) DemoDriverGetter.Forced = Core.Drivers.DriverMode.OpenLink; // the Store copy's flow
            if (args.Contains("--get-driver") && needing.CanGetDriver) await needing.GetDriverCommand.ExecuteAsync(null);
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        if (tab is not null && FindTabs(window) is { } tabs)
        {
            // By the tab's Tag (overview, print, scan, copy, photos, settings: the same in every language), else its header.
            tabs.SelectedItem = tabs.Items.OfType<TabItem>().FirstOrDefault(t => string.Equals(t.Tag as string, tab, StringComparison.OrdinalIgnoreCase))
                ?? tabs.Items.OfType<TabItem>().FirstOrDefault(t => (t.Header as string)?.Contains(tab, StringComparison.OrdinalIgnoreCase) == true);
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
        if (scans > 0 && window.DataContext is ViewModels.MainViewModel { Selected.Scan: { } scanner })
        {
            // --source glass|feeder|duplex, --split none|patch|blank|either and --keep-separators set the tab first.
            if (Value(args, "--source") is { } source
                && scanner.Sources.FirstOrDefault(s => s.Value == source switch { "feeder" => Core.Escl.ScanSource.Adf, "duplex" => Core.Escl.ScanSource.AdfDuplex, _ => Core.Escl.ScanSource.Platen }) is { } chosen)
                scanner.Source = chosen;
            if (Value(args, "--color") is { } color
                && scanner.ColorModes.FirstOrDefault(c => c.Value == color switch { "grey" => Core.Escl.ScanColor.Grayscale, "bw" => Core.Escl.ScanColor.BlackAndWhite, _ => Core.Escl.ScanColor.Color }) is { } mode)
                scanner.ColorMode = mode;
            if (Value(args, "--split") is { } split)
                scanner.SplitMode = scanner.SplitChoices.FirstOrDefault(c => c.Value == split switch
                {
                    "patch" => Core.Imaging.SplitAt.PatchCode, "blank" => Core.Imaging.SplitAt.BlankPage,
                    "either" => Core.Imaging.SplitAt.PatchCodeOrBlankPage, _ => Core.Imaging.SplitAt.None,
                });
            if (args.Contains("--keep-separators")) scanner.KeepSeparators = true;
            if (args.Contains("--find-photos")) scanner.FindPhotos = true;
            // --cleanup crop,whiten,descreen,restore: the tab's clean up, before scanning.
            if (Value(args, "--cleanup") is { } cleanup)
            {
                scanner.CropToPaper = cleanup.Contains("crop");
                scanner.WhitenPages = cleanup.Contains("whiten");
                scanner.DescreenPages = cleanup.Contains("descreen");
                scanner.RestoreColors = cleanup.Contains("restore");
            }
            for (var i = 0; i < scans; i++) await scanner.ScanCommand.ExecuteAsync(null);
            if (crop > 0 && crop <= scanner.Pages.Count) await scanner.CropCommand.ExecuteAsync(scanner.Pages[crop - 1]);
            // --delete n: delete page n, as the Delete key does (the review then offers Undo); --undo puts it back.
            if (int.TryParse(Value(args, "--delete"), out var delete) && delete > 0 && delete <= scanner.Pages.Count)
                scanner.RemovePageCommand.Execute(scanner.Pages[delete - 1]);
            if (args.Contains("--undo")) scanner.UndoCommand.Execute(null);
            // --move n: page n one place later, as Alt+Shift+Right does (the review's motion slides it in from the left).
            if (int.TryParse(Value(args, "--move"), out var move) && move > 0 && move < scanner.Pages.Count)
                scanner.MovePage(scanner.Pages[move - 1], move);
            // --clean n: the clean up view on the n-th page.
            if (int.TryParse(Value(args, "--clean"), out var cleanPage) && cleanPage > 0 && cleanPage <= scanner.Pages.Count)
            {
                await scanner.CleanUpCommand.ExecuteAsync(scanner.Pages[cleanPage - 1]);
                await Task.Delay(500);
            }
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
        // --batch: Print › Batch with sample files (demo only), the locked one opened with its password; --batch-decline leaves it out,
        // --batch-run sends them to the made-up queue, --batch-stop n with it jams the queue after n jobs, --batch-resume then clears the jam and
        // presses Print again, --batch-cancel presses Stop just after Print; --batch-list file saves the list and opens it again first;
        // --batch-report file writes each row's state and the message.
        if (args.Contains("--batch") && window.DataContext is ViewModels.MainViewModel { Selected: { Pc.IsDemo: true } batchPrinter })
        {
            ViewModels.PrintViewModel.AskPdfPassword = (_, _) => args.Contains("--batch-decline") ? null : "demo";
            if (int.TryParse(Value(args, "--batch-stop"), out var jamAfter)) DemoBatchQueue.ProblemAfter = jamAfter;
            await batchPrinter.OpenBatchAsync(Demo.SampleBatch());
            var batch = batchPrinter.Print.Batch!;
            if (batch.Rows.Count > 1) batch.Rows[1].Copies = 2;
            if (batch.Rows.Count > 1) batch.Rows[1].TwoSided = true;
            if (batch.Rows.Count > 1) batch.Rows[1].Range = "1-3";
            if (Value(args, "--batch-list") is { } listFile)
            {
                Core.Printing.BatchPrintList.Save(listFile, batch.Rows.Select(r => new Core.Printing.BatchListEntry(r.Path, r.Settings)));
                var ask = ViewModels.Prompt.Confirm;
                ViewModels.Prompt.Confirm = (_, _) => true; // "replace the list?"
                try { await batch.OpenListAsync(listFile); }
                finally { ViewModels.Prompt.Confirm = ask; }
            }
            if (args.Contains("--batch-cancel"))
            {
                var printing = batch.PrintCommand.ExecuteAsync(null);
                batch.StopCommand.Execute(null);
                await printing;
            }
            else if (args.Contains("--batch-run")) await batch.PrintCommand.ExecuteAsync(null);
            if (args.Contains("--batch-resume"))
            {
                DemoBatchQueue.ProblemAfter = null;
                await batch.PrintCommand.ExecuteAsync(null);
            }
            if (Value(args, "--batch-report") is { } batchReport)
                await File.WriteAllLinesAsync(batchReport, [.. batch.Rows.Select(r => $"{r.Name} | {r.StateText} | {r.SheetsText} | {r.Message}"),
                    $"message: {batch.Message}", $"estimate: {batch.EstimateText}", $"can print: {batch.PrintCommand.CanExecute(null)}"]);
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
        // --fleet [fix]: the Fleet page; fix runs Fix all, answering yes (demo only); --fleet-export file writes its CSV or JSON.
        if (args.Contains("--fleet") && window.DataContext is ViewModels.MainViewModel fleetMain)
        {
            window.ShowFleet();
            await Task.Delay(TimeSpan.FromSeconds(1));
            if (Value(args, "--fleet") == "fix" && fleetMain.Presets.IsDemo)
            {
                var ask = ViewModels.Prompt.Confirm;
                ViewModels.Prompt.Confirm = (_, _) => true;
                try { await fleetMain.Fleet.FixAllCommand.ExecuteAsync(null); }
                finally { ViewModels.Prompt.Confirm = ask; }
                await Task.Delay(TimeSpan.FromSeconds(6)); // the made-up queues' next read
            }
            if (Value(args, "--fleet-export") is { } fleetFile) await fleetMain.Fleet.WriteAsync(fleetFile);
            fleetMain.Fleet.Refresh();
            await Task.Delay(TimeSpan.FromSeconds(1));
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
        if (args.Contains("--simulate-jobs") && trayController is not null)
        {
            await trayController.SimulateJobsAsync();
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        // --open-queue n: as if a job's notification for the n-th printer was clicked.
        if (int.TryParse(Value(args, "--open-queue"), out var queueOf) && trayController is not null && window.DataContext is ViewModels.MainViewModel queueMain && queueMain.Printers.ElementAtOrDefault(queueOf - 1) is { } queuePrinter)
        {
            trayController.HandleToast("queue:" + queuePrinter.Uuid);
            await Task.Delay(TimeSpan.FromSeconds(2));
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
        // --nav open: the folded sidebar opened over the page (a narrow window or a large Text size folds it).
        if (Value(args, "--nav") == "open")
        {
            window.ShowSidebar(open: true);
            await Task.Delay(TimeSpan.FromMilliseconds(600));
        }
        // --palette [words]: the command palette open, with the words typed; --run-palette then runs the first entry.
        if (args.Contains("--palette"))
        {
            window.OpenPalette();
            if (Value(args, "--palette") is { } words) window.TypeInPalette(words);
            await Task.Delay(TimeSpan.FromMilliseconds(600));
            if (args.Contains("--run-palette"))
            {
                window.RunPaletteSelection(); // the first entry, as Enter runs it
                await Task.Delay(TimeSpan.FromSeconds(2));
            }
        }
        // --dialog settings|help|whatsnew|report|addprinter|confirm|pro|snmp|snmp3: that window instead of the main one.
        if (Value(args, "--dialog") is { } name && window.DataContext is ViewModels.MainViewModel dialogMain)
        {
            if (name == "pro" && args.Contains("--pro-enforce")) Core.Pro.Enforced = true; // the locked wording (demo: memory only)
            Window? dialog = name switch
            {
                "settings" => SettingsWindow.Create(dialogMain, trayController),
                "help" => HelpDialog.Create(dialogMain),
                "whatsnew" => WhatsNewDialog.Create(AppHelp.Notes()),
                "report" => ReportProblemDialog.Create(AppHelp.Report(dialogMain), dialogMain.Selected),
                "addprinter" => AddPrinterWindow.Create(dialogMain),
                "pro" => ProWindow.Create(window),
                "confirm" => ConfirmDialog.Preview(window),
                "snmp" => SnmpAccessDialog.Create(dialogMain.Selected?.Name ?? "Demo printer", Core.Snmp.SnmpLogin.Public),
                "snmp3" => SnmpAccessDialog.Create(dialogMain.Selected?.Name ?? "Demo printer",
                    Core.Snmp.SnmpLogin.ForUser("inkvolt-reader", "demo-auth-pass", "demo-priv-pass", out _)!),
                _ => null,
            };
            if (dialog is ProWindow pro && Value(args, "--pro-key") is { } proKey) pro.DevEnter(proKey);
            // --dialog report --record: the printer shown recorded (demo: a made-up printer, into a temp folder), the result in the dialog.
            if (dialog is ReportProblemDialog report && args.Contains("--record"))
            {
                dialog.Owner = window;
                dialog.Show();
                await report.RecordAsync();
            }
            if (dialog is not null)
            {
                dialog.Owner = window;
                dialog.Show();
                // Add a printer searches the (made-up) network first: about three seconds.
                await Task.Delay(Value(args, "--dialog-wait") is { } ms ? TimeSpan.FromMilliseconds(int.Parse(ms)) : TimeSpan.FromSeconds(name == "addprinter" ? 5 : 1));
                if (scrollToEnd)
                {
                    foreach (var sv in Descendants<ScrollViewer>(dialog)) sv.ScrollToEnd();
                    await Task.Delay(TimeSpan.FromMilliseconds(500));
                }
                shot = dialog;
            }
        }
        // --a11y-audit findings.txt: the shown window's controls without an accessible name or under 24 × 24 (UiAudit's rules).
        if (Value(args, "--a11y-audit") is { } auditPath)
        {
            var lines = new List<string>();
            foreach (var w in new[] { shot, window }.Distinct())
            {
                var findings = UiInspection.Audit(w);
                lines.Add($"'{w.Title}': {findings.Count} findings");
                lines.AddRange(findings.Select(f => "  " + f));
            }
            await File.WriteAllLinesAsync(auditPath, lines);
        }
        // The window's own root, not its Content: a dialog's content has a margin, which a VisualBrush would shift by,
        // and the adorner layer (placeholders, focus rings) sits above the content.
        var content = (FrameworkElement)VisualTreeHelper.GetChild(shot, 0);
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

    /// <summary><c>--demo --tray --simulate-jobs</c> without a snapshot: the real notification for the made-up stuck jobs.</summary>
    public static async Task SimulateJobsAsync(Tray.TrayController? tray)
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        if (tray is not null) await tray.SimulateJobsAsync();
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

    /// <summary>The job toasts from the very XML Windows would be given (texts, attribution, buttons), each laid out like a notification.</summary>
    private static FrameworkElement JobToastPreview(IReadOnlyList<Core.Alerts.AlertNotice> notices)
    {
        var column = new StackPanel { Margin = new Thickness(12) };
        foreach (var toast in Core.Alerts.AlertToasts.PerPrinter(notices))
        {
            var xml = System.Xml.Linq.XDocument.Parse(Core.Alerts.AlertToasts.Xml(toast)).Root!;
            var texts = xml.Element("visual")!.Element("binding")!.Elements("text").ToList();
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = "Inkvolt Print", FontSize = 12, Margin = new Thickness(0, 0, 0, 10) });
            stack.Children.Add(new TextBlock { Text = texts[0].Value, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            stack.Children.Add(new TextBlock { Text = texts[1].Value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
            stack.Children.Add(new TextBlock { Text = texts[2].Value, FontSize = 12, Opacity = 0.7, Margin = new Thickness(0, 4, 0, 10) });
            var buttons = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1 };
            foreach (var action in xml.Element("actions")!.Elements("action"))
                buttons.Children.Add(new Button { Content = action.Attribute("content")!.Value, Margin = new Thickness(2) });
            stack.Children.Add(buttons);
            var card = new Border { Width = 364, Padding = new Thickness(16), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = stack, Margin = new Thickness(0, 0, 0, 8) };
            card.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorTertiaryBrush");
            card.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
            card.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorPrimaryBrush");
            column.Children.Add(card);
        }
        var outer = new Border { Child = column };
        outer.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        return outer;
    }

    /// <summary>
    /// The last alert laid out like a Windows notification (app name, badge icon, title, text). Windows draws the real one,
    /// which a window snapshot can't capture; this shows what it will say.
    /// </summary>
    private static FrameworkElement AlertPreview(Tray.TrayController tray)
    {
        if (tray.LastNotices.Any(n => n.JobKey is not null)) return JobToastPreview(tray.LastNotices);
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

/// <summary>
/// Developer aid and end-to-end check: <c>InkvoltPrint.exe --demo --sample-pdf --size 860 560 --press-print report.txt</c>
/// opens a made-up three-page PDF in the first demo printer's Print section (as Choose a PDF… does), checks the Print button
/// is on screen, whole and at least 24 × 24 (no ancestor cuts it off), presses it like a person would (its automation peer,
/// so a hidden or disabled button can't be pressed) and writes what happened to <c>report.txt</c>, then exits (PrintFlowTests).
/// </summary>
internal static class DevPressPrint
{
    /// <summary>The made-up PDF <c>--sample-pdf</c> opens, under %TEMP%.</summary>
    public static string SamplePdf()
    {
        var path = Path.Combine(Path.GetTempPath(), "Inkvolt Print demo sample.pdf");
        File.WriteAllBytes(path, Core.Printing.BatchPrintSamples.Pdf(3, "Sample"));
        return path;
    }

    /// <summary><c>--sample-pdf [--printer n]</c>: the made-up PDF opened in the n-th demo printer's Print section (else the selected one's).</summary>
    public static async Task OpenSampleAsync(ViewModels.MainViewModel vm, int printer)
    {
        for (var i = 0; i < 80 && vm.Printers.Count < Math.Max(1, printer); i++) await Task.Delay(250);
        if (printer > 0 && printer <= vm.Printers.Count) vm.Selected = vm.Printers[printer - 1];
        if (vm.Selected is { } selected) await selected.OpenPdfAsync(SamplePdf());
    }

    public static async Task RunAsync(Window window, ViewModels.MainViewModel vm, string reportPath)
    {
        var report = new List<string> { $"window: {window.ActualWidth:0} x {window.ActualHeight:0}" };
        try
        {
            ViewModels.PrintViewModel? print = null;
            for (var i = 0; i < 120 && !((print = vm.Selected?.Print) is { HasDocument: true } && print.PrintCommand.CanExecute(null)); i++)
                await Task.Delay(250);
            if (print is not { HasDocument: true })
            {
                report.Add("result: no document loaded");
                return;
            }
            await Task.Delay(1000); // the section shown and laid out
            window.UpdateLayout();
            var button = Descendants(window).OfType<Button>().FirstOrDefault(b => b.Command == print.PrintCommand && b.IsVisible);
            if (button is null)
            {
                report.Add("print button: not shown");
                return;
            }
            var box = button.TransformToAncestor(window).TransformBounds(new Rect(button.RenderSize));
            var cutBy = CutBy(button);
            report.Add($"print button: {box.Width:0} x {box.Height:0} at {box.Left:0},{box.Top:0}");
            report.Add(cutBy is null && box.Width >= 24 && box.Height >= 24 ? "print button: in sight" : $"print button: cut off by {cutBy ?? "its size"}");
            if (cutBy is not null) return;
            var before = Demo.PrintJobs.Current().Count;
            var peer = new System.Windows.Automation.Peers.ButtonAutomationPeer(button);
            ((System.Windows.Automation.Provider.IInvokeProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Invoke)).Invoke();
            for (var i = 0; i < 120 && (print.IsBusy || print.Message is null); i++) await Task.Delay(250);
            report.Add($"pressed: {print.Message} (error={print.MessageIsError})");
            report.Add($"jobs added: {Demo.PrintJobs.Current().Count - before}");
        }
        catch (Exception e)
        {
            report.Add($"result: {e.GetType().Name}: {e.Message}");
        }
        finally
        {
            await File.WriteAllLinesAsync(reportPath, report);
            Application.Current.Shutdown();
        }
    }

    /// <summary>The first ancestor (or the window) whose bounds don't hold the element whole, by type name; null when none.</summary>
    private static string? CutBy(FrameworkElement element)
    {
        for (var parent = VisualTreeHelper.GetParent(element); parent is not null; parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is not FrameworkElement fe) continue;
            var box = element.TransformToAncestor(fe).TransformBounds(new Rect(element.RenderSize));
            if (box.Left < -0.5 || box.Top < -0.5 || box.Right > fe.ActualWidth + 0.5 || box.Bottom > fe.ActualHeight + 0.5)
                return fe.GetType().Name + (string.IsNullOrEmpty(fe.Name) ? "" : $" {fe.Name}");
        }
        return null;
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var d in Descendants(child)) yield return d;
        }
    }
}
