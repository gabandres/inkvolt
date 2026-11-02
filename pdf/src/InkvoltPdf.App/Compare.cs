using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>One side of a comparison: a PDF's bytes as they are now, with the password that opens them.</summary>
internal sealed record CompareSide(string Name, byte[] Data, string? Password);

/// <summary>
/// File › Compare Files…: pick the original and the changed version (open tabs, the saved copy of a tab, or files: PDFs, Office
/// files made into PDFs by the installed Office, pictures of scanned pages), then compare.
/// </summary>
internal static class Comparing
{
    /// <summary>A choice in the pickers: an open tab as it is now, the saved file behind an open tab, or a file.</summary>
    private sealed record Choice(string Label, DocumentTab? Tab, string? Path, bool Saved = false)
    {
        public override string ToString() => Label;
    }

    public static async Task Start(MainWindow host)
    {
        var choices = new List<Choice>();
        var active = host.ActiveTab;
        foreach (var t in host.OpenTabs.Where(t => t.Session.IsPdf && !t.IsDisposed))
        {
            var unsaved = t.Session.IsDirty || t.HasPendingEdits;
            choices.Add(new Choice(unsaved ? $"{t.Session.DisplayName} (open, with unsaved changes)" : $"{t.Session.DisplayName} (open)", t, null));
            if (unsaved && t.Session.FilePath is { } path && File.Exists(path))
                choices.Add(new Choice($"{t.Session.DisplayName} (as saved on disk)", t, path, Saved: true));
        }

        // Recent files that aren't open, for the other side.
        foreach (var path in AppSettings.Current.RecentFiles.Where(p => p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)).Take(10))
        {
            if (choices.Exists(c => c.Tab?.Session.FilePath is { } open && string.Equals(open, path, StringComparison.OrdinalIgnoreCase)) || !File.Exists(path)) continue;
            choices.Add(new Choice($"{Path.GetFileName(path)} (recent)", null, path));
        }

        var dlg = new FormDialog(host, "Compare Files", "Compare", 520);
        dlg.AddNote("Shows what changed from the original to the changed version: text side by side with the differences " +
                    "highlighted, moves and formatting listed apart, or the pages overlaid to spot changes in drawings and scans. " +
                    "Either one can be a Word, Excel or PowerPoint file, or a scan: its words are recognized on this PC.");
        var original = Picker(dlg, host, "Original (older version)", choices);
        var changed = Picker(dlg, host, "Changed (newer version)", choices);
        var swap = new Button { Content = "Swap", Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        swap.Click += (_, _) => (original.SelectedItem, changed.SelectedItem) = (changed.SelectedItem, original.SelectedItem);
        System.Windows.Automation.AutomationProperties.SetName(swap, "Swap original and changed");
        dlg.Add(null, swap);

        // An open document with unsaved changes: compare them against its saved file. Otherwise the open document is
        // the changed one, and another open tab (if any) the original.
        if (active is not null && choices.FirstOrDefault(c => c.Tab == active && c.Saved) is { } saved)
        {
            original.SelectedItem = saved;
            changed.SelectedItem = choices.First(c => c.Tab == active && !c.Saved);
        }
        else if (active is not null && choices.FirstOrDefault(c => c.Tab == active) is { } current)
        {
            changed.SelectedItem = current;
            original.SelectedItem = choices.FirstOrDefault(c => c.Tab != active && !c.Saved);
        }

        dlg.Validate(() =>
        {
            if (original.SelectedItem is null) return "Choose the original: an open document or a file (Browse…).";
            if (changed.SelectedItem is null) return "Choose the changed version: an open document or a file (Browse…).";
            return original.SelectedItem == changed.SelectedItem ? "Choose two different documents." : null;
        });
        if (!dlg.ShowModal()) return;

        // An open document's latest change (a field being typed, a drawing being written) goes in first, as for Save.
        foreach (var c in new[] { (Choice)original.SelectedItem!, (Choice)changed.SelectedItem! })
            if (c.Tab is { IsDisposed: false } t && !c.Saved) await t.FlushPendingEditsAsync();

        if (await Load(host, (Choice)original.SelectedItem!) is not { } oldSide || await Load(host, (Choice)changed.SelectedItem!) is not { } newSide) return;
        CompareWindow.Open(host, oldSide, newSide);
    }

    private static ComboBox Picker(FormDialog dlg, Window owner, string label, List<Choice> choices)
    {
        var combo = new ComboBox { ItemsSource = choices, MinWidth = 340 };
        System.Windows.Automation.AutomationProperties.SetName(combo, label);
        var browse = new Button { Content = "Browse…", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(browse, $"Browse for the {label.Split(' ')[0].ToLowerInvariant()} file");
        browse.Click += (_, _) =>
        {
            if (PickFile(owner, $"{label.Split(' ')[0]} file") is not { } path) return;
            var existing = choices.FirstOrDefault(c => c.Path is not null && !c.Saved && string.Equals(c.Path, path, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                existing = new Choice(Path.GetFileName(path), null, path);
                choices.Add(existing);
                foreach (var c in FindCombos(dlg)) c.Items.Refresh();
            }
            combo.SelectedItem = existing;
        };
        var row = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        row.Children.Add(browse);
        row.Children.Add(combo);
        dlg.Add(label, row);
        return combo;
    }

    /// <summary>What Compare can read: PDFs, Office files if Office is here, and pictures of pages.</summary>
    private static string? PickFile(Window owner, string title)
    {
        var office = OfficeFiles.FilterPattern(OfficeConverter.InstalledApps);
        const string Pictures = "*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp";
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = title,
            InitialDirectory = AppSettings.Current.LastFolder,
            Filter = $"Documents|*.pdf;{(office.Length > 0 ? office + ";" : "")}{Pictures}|PDF files (*.pdf)|*.pdf" +
                     (office.Length > 0 ? $"|Office files (converted with Microsoft Office)|{office}" : "") +
                     $"|Pictures of scanned pages|{Pictures}|All files (*.*)|*.*",
        };
        return dlg.ShowDialog(owner) == true ? dlg.FileName : null;
    }

    private static IEnumerable<ComboBox> FindCombos(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is ComboBox c) yield return c;
            foreach (var d in FindCombos(child)) yield return d;
        }
    }

    /// <summary>The bytes to compare. Null (after saying why) when a file can't be read or its password isn't given.</summary>
    private static async Task<CompareSide?> Load(MainWindow owner, Choice choice)
    {
        if (choice.Tab is { } tab && !choice.Saved)
        {
            if (tab.IsDisposed)
            {
                Prompt.Info(owner, "That document was closed", "Choose it again from a file.");
                return null;
            }
            return new CompareSide(tab.Session.DisplayName, tab.Session.Data, tab.Session.Password);
        }
        var path = choice.Path!;
        if (choice.Saved && choice.Tab is { } t)
        {
            // The saved file usually opens with the tab's password; if not, ask.
            try
            {
                var data = File.ReadAllBytes(path);
                using (PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, t.Session.Password)) { }
                return new CompareSide($"{t.Session.DisplayName} (saved)", data, t.Session.Password);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PasswordRequiredException or MuPDFCore.MuPDFException or InvalidOperationException)
            {
                // fall through to the prompting loader
            }
        }
        if (!choice.Saved && !path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
            return await LoadFile(owner, path);
        return PdfFiles.LoadForImport(owner, path) is { } source
            ? new CompareSide(choice.Saved ? $"{source.Name} (saved)" : source.Name, source.Data, source.Password)
            : null;
    }

    /// <summary>A file as one side: a PDF as it is, an Office file made into a PDF by Office, a picture as a page. Null (after saying why) when it can't be.</summary>
    internal static async Task<CompareSide?> LoadFile(MainWindow owner, string path)
    {
        var name = Path.GetFileName(path);
        if (!path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && !ProGate.Check(owner, ProFeature.CompareOfficeAndScans)) return null;
        if (OfficeFiles.AppFor(path) is { } app)
        {
            if (OfficeConverter.Precheck(path, app) is { } problem)
            {
                Prompt.Info(owner, $"Can't compare {name}", problem);
                return null;
            }
            var appName = OfficeFiles.AppName(app);
            // As for opening one: automation opens files without Protected View, so one from the internet needs an OK first.
            var internet = OfficeConverter.ZoneOf(path) >= 3;
            if (internet && !Prompt.Confirm(owner, $"{name} came from the internet",
                    $"Windows marks this file as downloaded from the internet. {appName} opens it here without Protected View: its macros stay off, " +
                    "but it could still fetch content linked from elsewhere (a template, pictures, linked data). Convert it only if you trust where it came from.",
                    "Convert Anyway", warning: true))
                return null;
            using var progress = new ProgressPrompt(owner, $"Comparing {name}", $"Converting with {appName}…");
            try
            {
                var made = await OfficeConverter.ConvertAsync(path, app, internet, progress.Token);
                return new CompareSide(name, made.Pdf, null);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException)
            {
                progress.Dispose();
                Prompt.Error(owner, $"Couldn't convert {name}", ex.Message);
                return null;
            }
        }
        if (Path.GetExtension(path).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg" or ".tif" or ".tiff" or ".bmp")
        {
            try
            {
                var pdf = await Task.Run(() => ImageImport.ImagesToPdf([(File.ReadAllBytes(path), name)]));
                return new CompareSide(name, pdf, null);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException)
            {
                Prompt.Error(owner, $"Couldn't read {name}", ex.Message);
                return null;
            }
        }
        return PdfFiles.LoadForImport(owner, path) is { } source ? new CompareSide(source.Name, source.Data, source.Password) : null;
    }
}
