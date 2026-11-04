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
            choices.Add(new Choice(Loc.Format(unsaved ? Strings.Compare_OpenUnsaved : Strings.Compare_Open, t.Session.DisplayName), t, null));
            if (unsaved && t.Session.FilePath is { } path && File.Exists(path))
                choices.Add(new Choice(Loc.Format(Strings.Compare_AsSaved, t.Session.DisplayName), t, path, Saved: true));
        }

        // Recent files that aren't open, for the other side.
        foreach (var path in AppSettings.Current.RecentFiles.Where(p => p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)).Take(10))
        {
            if (choices.Exists(c => c.Tab?.Session.FilePath is { } open && string.Equals(open, path, StringComparison.OrdinalIgnoreCase)) || !File.Exists(path)) continue;
            choices.Add(new Choice(Loc.Format(Strings.Compare_Recent, Path.GetFileName(path)), null, path));
        }

        var dlg = new FormDialog(host, Strings.Compare_Title, Strings.Compare_Compare, 520);
        dlg.AddNote(Strings.Compare_Note);
        var original = Picker(dlg, host, Strings.Compare_Original, Strings.Compare_BrowseOriginal, Strings.Compare_OriginalFile, choices);
        var changed = Picker(dlg, host, Strings.Compare_Changed, Strings.Compare_BrowseChanged, Strings.Compare_ChangedFile, choices);
        var swap = new Button { Content = Strings.Compare_Swap, Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        swap.Click += (_, _) => (original.SelectedItem, changed.SelectedItem) = (changed.SelectedItem, original.SelectedItem);
        System.Windows.Automation.AutomationProperties.SetName(swap, Strings.Compare_SwapName);
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
            if (original.SelectedItem is null) return Strings.Compare_ChooseOriginal;
            if (changed.SelectedItem is null) return Strings.Compare_ChooseChanged;
            return original.SelectedItem == changed.SelectedItem ? Strings.Compare_ChooseTwo : null;
        });
        if (!dlg.ShowModal()) return;

        // An open document's latest change (a field being typed, a drawing being written) goes in first, as for Save.
        foreach (var c in new[] { (Choice)original.SelectedItem!, (Choice)changed.SelectedItem! })
            if (c.Tab is { IsDisposed: false } t && !c.Saved) await t.FlushPendingEditsAsync();

        if (await Load(host, (Choice)original.SelectedItem!) is not { } oldSide || await Load(host, (Choice)changed.SelectedItem!) is not { } newSide) return;
        CompareWindow.Open(host, oldSide, newSide);
    }

    private static ComboBox Picker(FormDialog dlg, Window owner, string label, string browseName, string pickTitle, List<Choice> choices)
    {
        var combo = new ComboBox { ItemsSource = choices, MinWidth = 340 };
        System.Windows.Automation.AutomationProperties.SetName(combo, label);
        var browse = new Button { Content = Strings.Common_Browse, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(browse, browseName);
        browse.Click += (_, _) =>
        {
            if (PickFile(owner, pickTitle) is not { } path) return;
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
            Filter = $"{Strings.Compare_FilterDocuments}|*.pdf;{(office.Length > 0 ? office + ";" : "")}{Pictures}|{Strings.Compare_FilterPdf}|*.pdf" +
                     (office.Length > 0 ? $"|{Strings.Compare_FilterOffice}|{office}" : "") +
                     $"|{Strings.Compare_FilterScans}|{Pictures}|{Strings.Compare_FilterAll}|*.*",
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
                Prompt.Info(owner, Strings.Compare_Closed, Strings.Compare_ChooseAgain);
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
                return new CompareSide(Loc.Format(Strings.Compare_Saved, t.Session.DisplayName), data, t.Session.Password);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PasswordRequiredException or MuPDFCore.MuPDFException or InvalidOperationException)
            {
                // fall through to the prompting loader
            }
        }
        if (!choice.Saved && !path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
            return await LoadFile(owner, path);
        return PdfFiles.LoadForImport(owner, path) is { } source
            ? new CompareSide(choice.Saved ? Loc.Format(Strings.Compare_Saved, source.Name) : source.Name, source.Data, source.Password)
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
                Prompt.Info(owner, Loc.Format(Strings.Compare_CantCompare, name), problem);
                return null;
            }
            var appName = OfficeFiles.AppName(app);
            // As for opening one: automation opens files without Protected View, so one from the internet needs an OK first.
            var internet = OfficeConverter.ZoneOf(path) >= 3;
            if (internet && !Prompt.Confirm(owner, Loc.Format(Strings.Compare_FromInternet, name),
                    Loc.Format(Strings.Compare_FromInternetBody, appName),
                    Strings.Compare_ConvertAnyway, warning: true))
                return null;
            using var progress = new ProgressPrompt(owner, Loc.Format(Strings.Compare_Comparing, name), Loc.Format(Strings.Compare_ConvertingWith, appName));
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
                Prompt.Error(owner, Loc.Format(Strings.Compare_CouldntConvert, name), ex.Message);
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
                Prompt.Error(owner, Loc.Format(Strings.Compare_CouldntRead, name), ex.Message);
                return null;
            }
        }
        return PdfFiles.LoadForImport(owner, path) is { } source ? new CompareSide(source.Name, source.Data, source.Password) : null;
    }
}
