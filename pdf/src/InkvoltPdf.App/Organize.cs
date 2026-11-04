using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;
using PageRange = InkvoltPdf.Core.PageRange;

namespace InkvoltPdf.App;

/// <summary>The Organize menu: each command gathers options in a dialog, then runs one undoable page edit.</summary>
public static class Organize
{
    /// <summary>Paper sizes for blank pages; names are read when the dialog is built (after the language is set).</summary>
    private static readonly (Func<string> Name, double W, double H)[] PaperSizes =
    [
        (() => Strings.Organize_PaperLetter, 612, 792),
        (() => Strings.Organize_PaperLegal, 612, 1008),
        (() => Strings.Organize_PaperTabloid, 792, 1224),
        (() => "A3 (297 × 420 mm)", 842, 1191),
        (() => "A4 (210 × 297 mm)", 595, 842),
        (() => "A5 (148 × 210 mm)", 420, 595),
    ];

    /// <summary>"Rotate 1 page" / "Rotate 3 pages": the edit's name from the pair of resources for that verb.</summary>
    private static string Pages(int n, string one, string many) => Loc.Plural(n, one, many);

    /// <summary>
    /// The page "current page" means for a command: the focused card while organizing (the reader's page is hidden then),
    /// else the reader's page.
    /// </summary>
    public static int CurrentPage(DocumentTab tab)
    {
        var count = tab.PageView.PageCount;
        var page = tab.IsOrganizing && tab.Organizer.FocusedPage is >= 0 and var focused ? focused : tab.ActiveView.CurrentPage;
        return count == 0 ? 0 : Math.Clamp(page, 0, count - 1);
    }

    /// <summary>For CanExecute of the selection commands (rotate, delete, duplicate): false in Organize with no card selected.</summary>
    public static bool HasSelection(DocumentTab tab) => tab.SelectedPages.Length > 0;

    public static Task RotateSelected(DocumentTab tab, int degrees)
    {
        var pages = tab.SelectedPages;
        if (pages.Length == 0) return Task.CompletedTask;
        return Reselect(tab, pages, tab.RunEdit(Pages(pages.Length, Strings.Organize_EditRotate_One, Strings.Organize_EditRotate_Many), (d, pw) => PageEditor.Rotate(d, pw, pages, degrees)));
    }

    public static async Task RotateDialog(Window owner, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, Strings.Organize_RotateTitle, Strings.Organize_RotateButton);
        var dir = dlg.AddChoice(Strings.Organize_Direction, [Strings.Organize_Clockwise, Strings.Organize_Counterclockwise, "180°"]);
        var range = dlg.AddRange(tab);
        var orient = dlg.AddChoice(Strings.Organize_OnlyThese, [Strings.Organize_PortraitAndLandscape, Strings.Organize_PortraitOnly, Strings.Organize_LandscapeOnly]);
        int[] pages = [];
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            var engine = tab.Session.Engine;
            pages = orient.SelectedIndex switch
            {
                1 => [.. pages.Where(p => engine.GetPage(p).Height >= engine.GetPage(p).Width)],
                2 => [.. pages.Where(p => engine.GetPage(p).Width > engine.GetPage(p).Height)],
                _ => pages,
            };
            return pages.Length == 0 ? Strings.Organize_NoOrientation : null;
        });
        if (!dlg.ShowModal()) return;
        var degrees = dir.SelectedIndex switch { 0 => 90, 1 => -90, _ => 180 };
        await Reselect(tab, pages, tab.RunEdit(Pages(pages.Length, Strings.Organize_EditRotate_One, Strings.Organize_EditRotate_Many), (d, pw) => PageEditor.Rotate(d, pw, pages, degrees)));
    }

    public static Task DeleteSelected(DocumentTab tab)
    {
        var pages = tab.SelectedPages;
        return Delete(tab, pages);
    }

    public static async Task DeleteDialog(Window owner, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, Strings.Organize_DeleteTitle, Strings.Common_Delete);
        var range = dlg.AddRange(tab);
        int[] pages = [];
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            return pages.Length >= tab.PageView.PageCount ? Strings.Organize_CantDeleteAll : null;
        });
        if (dlg.ShowModal()) await Delete(tab, pages);
    }

    private static Task Delete(DocumentTab tab, int[] pages)
    {
        if (pages.Length == 0) return Task.CompletedTask;
        if (pages.Length >= tab.PageView.PageCount)
        {
            Prompt.Info(Window.GetWindow(tab), Strings.Organize_OnePageTitle, Strings.Organize_OnePageBody);
            return Task.CompletedTask;
        }
        return tab.RunEdit(Pages(pages.Length, Strings.Organize_EditDelete_One, Strings.Organize_EditDelete_Many), (d, pw) => PageEditor.Delete(d, pw, pages), pages.Min());
    }

    public static async Task InsertFromFile(Window owner, DocumentTab tab)
    {
        var path = PdfFiles.PickPdf(owner, Strings.Organize_InsertFromPick);
        if (path is null || PdfFiles.LoadForImport(owner, path) is not { } source) return;

        int srcCount;
        using (var e = PdfEngine.Open(source.Data, MuPDFCore.InputFileTypes.PDF, source.Password)) srcCount = e.PageCount;

        var dlg = new FormDialog(owner, Strings.Organize_InsertTitle, Strings.Organize_InsertButton);
        dlg.AddNote(Loc.Plural(srcCount, Strings.Organize_InsertFrom_One, Strings.Organize_InsertFrom_Many, Path.GetFileName(path)));
        var srcRange = dlg.AddText(Strings.Organize_PagesToInsert, $"1-{srcCount}");
        var pos = dlg.AddPosition(tab.PageView.PageCount, CurrentPage(tab));
        int[] srcPages = [];
        var before = 0;
        dlg.Validate(() =>
        {
            if (!PageRange.TryParse(srcRange.Text, srcCount, out srcPages, out var err)) return err;
            return pos.TryGet(out before, out err) ? null : err;
        });
        if (!dlg.ShowModal()) return;
        await tab.RunEdit(Loc.Plural(srcPages.Length, Strings.Organize_EditInsertFrom_One, Strings.Organize_EditInsertFrom_Many, source.Name), (d, pw) => PageEditor.Insert(d, pw, source, srcPages, before), before);
    }

    public static async Task InsertBlank(Window owner, DocumentTab tab)
    {
        var currentPage = CurrentPage(tab);
        var current = tab.Session.Engine.GetPage(currentPage);
        var dlg = new FormDialog(owner, Strings.Organize_BlankTitle, Strings.Organize_InsertButton);
        var count = dlg.AddText(Strings.Organize_NumberOfPages, "1");
        var size = dlg.AddChoice(Strings.Organize_PageSize, [Loc.Format(Strings.Organize_SameAsCurrent, Inches(current.Width), Inches(current.Height)), .. PaperSizes.Select(p => p.Name())]);
        var orient = dlg.AddChoice(Strings.Organize_Orientation, [Strings.Organize_Portrait, Strings.Organize_Landscape], current.Width > current.Height ? 1 : 0);
        var pos = dlg.AddPosition(tab.PageView.PageCount, currentPage);
        var n = 1;
        var before = 0;
        dlg.Validate(() =>
        {
            if (!int.TryParse(count.Text.Trim(), out n) || n < 1 || n > 1000) return Strings.Organize_EnterBlankCount;
            return pos.TryGet(out before, out var err) ? null : err;
        });
        if (!dlg.ShowModal()) return;

        var (w, h) = size.SelectedIndex == 0 ? (current.Width, current.Height) : (PaperSizes[size.SelectedIndex - 1].W, PaperSizes[size.SelectedIndex - 1].H);
        var landscape = orient.SelectedIndex == 1;
        if (landscape != w > h) (w, h) = (h, w);
        await tab.RunEdit(Pages(n, Strings.Organize_EditInsert_One, Strings.Organize_EditInsert_Many), (d, pw) => PageEditor.InsertBlank(d, pw, before, n, w, h), before);
    }

    public static async Task Extract(Window owner, DocumentTab tab, MainWindow host)
    {
        if (!await tab.SettleAsync()) return;
        var dlg = new FormDialog(owner, Strings.Organize_ExtractTitle, Strings.Organize_ExtractButton);
        var range = dlg.AddRange(tab);
        var mode = dlg.AddChoice(Strings.Organize_ExtractTo, [Strings.Organize_ExtractNewDocument, Strings.Organize_ExtractOneFile, Strings.Organize_ExtractFilePerPage]);
        var delete = dlg.AddCheck(Strings.Organize_ExtractDelete);
        int[] pages = [];
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            return delete.IsChecked == true && pages.Length >= tab.PageView.PageCount ? Strings.Organize_CantDeleteAll : null;
        });
        if (!dlg.ShowModal() || !await tab.SettleAsync()) return;
        if (pages.Any(p => p >= tab.PageView.PageCount)) return; // the document changed meanwhile
        if (!ConfirmUnprotected(owner, tab, Strings.Organize_ExtractUnprotected, Strings.Organize_ExtractAnyway)) return;

        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        var data = tab.Session.Data;
        var pw = tab.Session.Password;
        var label = PageRange.Format(pages);
        // Held from here, also while the save dialogs are open, so no edit lands between reading the pages and writing them.
        var busy = tab.BeginBusy(null);
        try
        {
            switch (mode.SelectedIndex)
            {
                case 0:
                {
                    busy.Dispose();
                    busy = tab.BeginBusy(Strings.Organize_Extracting);
                    var bytes = await Task.Run(() => PageEditor.Extract(data, pw, pages));
                    host.OpenSession(DocumentSession.FromBytes(bytes, Loc.Format(Strings.Organize_ExtractFileName, name, label), pw));
                    break;
                }
                case 1:
                {
                    string? path;
                    while (true)
                    {
                        path = PdfFiles.PickSavePath(owner, Loc.Format(Strings.Organize_ExtractFileName, name, label), Path.GetDirectoryName(tab.Session.FilePath));
                        if (path is null) return;
                        // Writing over a document open in a tab would swap the file under it (and the tab wouldn't know).
                        if (!PdfFiles.IsOpenInTab(path)) break;
                        Prompt.Info(owner, Loc.Format(Strings.Organize_OpenInTabTitle, Path.GetFileName(path)), Strings.Organize_OpenInTabBody);
                    }
                    busy.Dispose();
                    busy = tab.BeginBusy(Strings.Organize_Extracting);
                    var bytes = await Task.Run(() => PageEditor.Extract(data, pw, pages));
                    await Task.Run(() => AtomicFile.WriteAllBytes(path, bytes));
                    host.ShowStatus(Loc.Format(Strings.Organize_Saved, Path.GetFileName(path)));
                    break;
                }
                default:
                {
                    var folder = PdfFiles.PickFolder(owner, Strings.Organize_SaveExtractedTo, Path.GetDirectoryName(tab.Session.FilePath));
                    if (folder is null) return;
                    var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    var files = pages.Select(p => (PdfFiles.UniquePath(folder, Loc.Format(Strings.Organize_ExtractPageFileName, name, p + 1), reserved), (Func<byte[]>)(() => PageEditor.Extract(data, pw, [p])))).ToList();
                    busy.Dispose();
                    busy = tab.BeginBusy(Strings.Organize_Extracting);
                    await Task.Run(() => PdfFiles.WriteBatch(files));
                    host.ShowStatus(Loc.Plural(pages.Length, Strings.Organize_SavedPagesTo_One, Strings.Organize_SavedPagesTo_Many, folder));
                    Shell.Open(folder);
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Write($"Extract failed: {ex}");
            Prompt.Error(owner, Strings.Organize_ExtractFailed, BatchFailure(ex));
            return;
        }
        finally
        {
            busy.Dispose();
        }

        if (delete.IsChecked == true)
            await tab.RunEdit(Pages(pages.Length, Strings.Organize_EditDelete_One, Strings.Organize_EditDelete_Many), (d, p2) => PageEditor.Delete(d, p2, pages), pages.Min());
    }

    public static async Task Split(Window owner, DocumentTab tab, MainWindow host)
    {
        if (!await tab.SettleAsync()) return;
        var count = tab.PageView.PageCount;
        var outline = tab.Session.Engine.GetOutline();
        var dlg = new FormDialog(owner, Strings.Organize_SplitTitle, Strings.Organize_SplitButton, 480);
        var mode = dlg.AddChoice(Strings.Organize_SplitBy, [Strings.Organize_NumberOfPages, Strings.Organize_PageRanges, Strings.Organize_TopBookmarks]);
        var every = dlg.AddText(Strings.Organize_PagesPerFile, "1");
        var ranges = dlg.AddText(Strings.Organize_PageRangesLabel, count > 1 ? $"1-{Math.Max(1, count / 2)}; {Math.Max(1, count / 2) + 1}-{count}" : "1");
        dlg.AddNote(outline.Count == 0 ? Strings.Organize_NoBookmarksNote : Loc.Plural(outline.Count, Strings.Organize_TopBookmarksCount_One, Strings.Organize_TopBookmarksCount_Many));
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        var folderBox = dlg.AddText(Strings.Organize_SaveToFolder, Path.GetDirectoryName(tab.Session.FilePath) ?? AppSettings.Current.LastFolder);
        var browse = new Button { Content = Strings.Common_Browse, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        browse.Click += (_, _) => { if (PdfFiles.PickFolder(dlg, Strings.Organize_SaveSplitTo, folderBox.Text) is { } f) folderBox.Text = f; };
        dlg.Add(null, browse);
        var pattern = dlg.AddText(Strings.Organize_FileNamePattern, Strings.Organize_FileNamePatternDefault);

        List<(int[] Pages, string Label)> parts = [];
        List<string> targets = [];
        dlg.Validate(() =>
        {
            parts = [];
            switch (mode.SelectedIndex)
            {
                case 0:
                    if (!int.TryParse(every.Text.Trim(), out var n) || n < 1 || n > count) return Loc.Format(Strings.Organize_EnterPageCount, count);
                    parts = [.. PageEditor.ChunksOf(count, n).Select(c => (c, ""))];
                    break;
                case 1:
                    foreach (var part in ranges.Text.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    {
                        if (!PageRange.TryParse(part, count, out var pages, out var err)) return err;
                        parts.Add((pages, ""));
                    }
                    break;
                default:
                    var starts = outline.Select(o => o.PageIndex).Where(p => p >= 0 && p < count).Append(0).Distinct().Order().ToList();
                    if (outline.Count == 0) return Strings.Organize_NoBookmarks;
                    for (var i = 0; i < starts.Count; i++)
                    {
                        var end = i + 1 < starts.Count ? starts[i + 1] : count;
                        var title = outline.FirstOrDefault(o => o.PageIndex == starts[i])?.Title ?? "";
                        parts.Add(([.. Enumerable.Range(starts[i], end - starts[i])], title));
                    }
                    break;
            }
            if (parts.Count == 0) return Strings.Organize_NothingToSplit;
            if (!Directory.Exists(folderBox.Text)) return Strings.Organize_ChooseFolder;
            if (!pattern.Text.Contains("{n}") && mode.SelectedIndex != 2) return Strings.Organize_NeedsN;

            // Pick every file name before writing anything (long bookmark titles are shortened, duplicates numbered).
            targets = [];
            var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                for (var i = 0; i < parts.Count; i++)
                {
                    var file = pattern.Text.Replace("{name}", name).Replace("{n}", (i + 1).ToString());
                    var label = parts[i].Label.Trim();
                    if (label.Length > 0 && !pattern.Text.Contains("{n}")) file = $"{name} - {label}";
                    else if (label.Length > 0) file += $" - {label}";
                    targets.Add(PdfFiles.UniquePath(folderBox.Text, file + ".pdf", reserved));
                }
            }
            catch (Exception ex) when (ex is IOException or ArgumentException or NotSupportedException)
            {
                return ex.Message;
            }
            return null;
        });
        if (!dlg.ShowModal() || !await tab.SettleAsync() || tab.PageView.PageCount != count) return;
        if (!ConfirmUnprotected(owner, tab, Strings.Organize_SplitUnprotected, Strings.Organize_SplitAnyway)) return;

        var data = tab.Session.Data;
        var pw = tab.Session.Password;
        var folder = folderBox.Text;
        var files = parts.Select((p, i) => (targets[i], (Func<byte[]>)(() => PageEditor.Extract(data, pw, p.Pages)))).ToList();
        using var busy = tab.BeginBusy(Loc.Format(Strings.Organize_Splitting, parts.Count));
        try
        {
            await Task.Run(() => PdfFiles.WriteBatch(files));
            host.ShowStatus(Loc.Format(Strings.Organize_SplitDone, parts.Count, folder));
            Shell.Open(folder);
        }
        catch (Exception ex)
        {
            Log.Write($"Split failed: {ex}");
            Prompt.Error(owner, Strings.Organize_SplitFailed, BatchFailure(ex));
        }
    }

    /// <summary>The error message, plus which files a partly finished batch did write.</summary>
    private static string BatchFailure(Exception ex)
    {
        if (ex is not BatchWriteException batch) return ex.Message;
        if (batch.Written.Count == 0) return Loc.Format(Strings.Organize_BatchNoneWritten, batch.Message);
        var names = string.Join(", ", batch.Written.Take(5).Select(Path.GetFileName));
        return batch.Written.Count > 5
            ? Loc.Format(Strings.Organize_BatchWrittenMore, batch.Message, names, batch.Written.Count - 5)
            : Loc.Format(Strings.Organize_BatchWritten, batch.Message, names);
    }

    // Tabs already warned that extracting/splitting drops the password (once per tab, like page edits).
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<DocumentTab, object> ProtectionWarned = new();

    /// <summary>Warns once per tab that output from a password-protected PDF (extracted pages, split files, exports) is written without the password.</summary>
    internal static bool ConfirmUnprotected(Window owner, DocumentTab tab, string body, string confirm)
    {
        if (!tab.Session.Engine.IsEncrypted || ProtectionWarned.TryGetValue(tab, out _)) return true;
        if (!Prompt.Confirm(owner, Strings.Organize_ProtectedTitle, body, confirm, warning: true)) return false;
        ProtectionWarned.AddOrUpdate(tab, true);
        return true;
    }

    public static async Task Move(Window owner, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, Strings.Organize_MoveTitle, Strings.Organize_MoveButton);
        var range = dlg.AddRange(tab);
        var pos = dlg.AddPosition(tab.PageView.PageCount, tab.PageView.PageCount - 1, Strings.Organize_MoveTo);
        int[] pages = [];
        var before = 0;
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            return pos.TryGet(out before, out err) ? null : err;
        });
        if (!dlg.ShowModal()) return;
        var order = PageEditor.MoveOrder(tab.PageView.PageCount, pages, before);
        if (order.SequenceEqual(Enumerable.Range(0, order.Length))) return;
        var first = Array.IndexOf(order, pages[0]);
        await Reselect(tab, [.. Enumerable.Range(first, pages.Length)],
            tab.RunEdit(Pages(pages.Length, Strings.Organize_EditMove_One, Strings.Organize_EditMove_Many), (d, pw) => PageEditor.Reorder(d, pw, order), first));
    }

    public static Task Duplicate(DocumentTab tab)
    {
        var pages = tab.SelectedPages;
        if (pages.Length == 0) return Task.CompletedTask;
        // The copy of the last selected page lands after every earlier copy.
        return tab.RunEdit(Pages(pages.Length, Strings.Organize_EditDuplicate_One, Strings.Organize_EditDuplicate_Many), (d, pw) => PageEditor.Duplicate(d, pw, pages), pages[^1] + pages.Length);
    }

    public static Task Reverse(DocumentTab tab)
    {
        var count = tab.PageView.PageCount;
        // The same pages stay selected (at their new, mirrored positions), in the organizer and the thumbnails.
        var selected = tab.SelectedPages;
        return Reselect(tab, [.. selected.Select(p => count - 1 - p).Order()],
            tab.RunEdit(Strings.Organize_EditReverse, (d, pw) => PageEditor.Reverse(d, pw, count)));
    }

    public static async Task Crop(Window owner, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, Strings.Organize_CropTitle, Strings.Common_Apply, 460);
        dlg.AddNote(Strings.Organize_CropNote);
        var units = dlg.AddChoice(Strings.Organize_Units, [Strings.Organize_Inches, Strings.Organize_Millimeters, Strings.Organize_Points]);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        TextBox Cell(string label, string spoken, int row, int col)
        {
            while (grid.RowDefinitions.Count <= row) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var tb = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(col == 0 ? 0 : 16, 4, 8, 4) };
            var box = new TextBox { Text = "0", Margin = new Thickness(0, 4, 0, 4) };
            System.Windows.Automation.AutomationProperties.SetName(box, spoken);
            Grid.SetRow(tb, row);
            Grid.SetColumn(tb, col);
            Grid.SetRow(box, row);
            Grid.SetColumn(box, col + 1);
            grid.Children.Add(tb);
            grid.Children.Add(box);
            return box;
        }
        var top = Cell(Strings.Organize_Top, Strings.Organize_TopMargin, 0, 0);
        var bottom = Cell(Strings.Organize_Bottom, Strings.Organize_BottomMargin, 0, 2);
        var left = Cell(Strings.Organize_Left, Strings.Organize_LeftMargin, 1, 0);
        var right = Cell(Strings.Organize_Right, Strings.Organize_RightMargin, 1, 2);
        dlg.Add(Strings.Organize_MarginsToRemove, grid);
        var remove = dlg.AddCheck(Strings.Organize_RemoveCropInstead);
        var range = dlg.AddRange(tab);

        int[] pages = [];
        Margins m = default;
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            if (remove.IsChecked == true) return null;
            var factor = units.SelectedIndex switch { 0 => 72.0, 1 => 72 / 25.4, _ => 1.0 };
            double[] v = new double[4];
            var boxes = new[] { left, top, right, bottom };
            for (var i = 0; i < 4; i++)
                if (!FormDialog.TryNumber(boxes[i].Text, 0, 100_000, out v[i])) return Strings.Organize_MarginsNumbers;
            m = new Margins(v[0] * factor, v[1] * factor, v[2] * factor, v[3] * factor);
            return m == default ? Strings.Organize_EnterMargin : null;
        });
        if (!dlg.ShowModal()) return;

        if (remove.IsChecked == true)
            await Reselect(tab, pages, tab.RunEdit(Pages(pages.Length, Strings.Organize_EditUncrop_One, Strings.Organize_EditUncrop_Many), (d, pw) => PageEditor.Uncrop(d, pw, pages)));
        else
            await Reselect(tab, pages, tab.RunEdit(Pages(pages.Length, Strings.Organize_EditCrop_One, Strings.Organize_EditCrop_Many), (d, pw) => PageEditor.Crop(d, pw, pages, m)));
    }

    public static async Task Combine(Window owner, MainWindow host, IEnumerable<string>? initial = null)
    {
        var dlg = new CombineDialog(owner, initial ?? []);
        if (dlg.ShowDialog() != true) return;

        var sources = new List<PdfSource>();
        foreach (var f in dlg.Files)
        {
            if (PdfFiles.LoadForImport(owner, f) is not { } s) return;
            sources.Add(s);
        }
        var bookmarks = dlg.BookmarkPerFile;
        host.ShowStatus(Loc.Format(Strings.Organize_Combining, sources.Count));
        using var taskbar = new TaskbarProgress(host);
        try
        {
            var bytes = await Task.Run(() => PageEditor.Merge(sources, bookmarks));
            host.OpenSession(DocumentSession.FromBytes(bytes, Strings.Organize_CombinedName));
            host.ShowStatus(Loc.Format(Strings.Organize_Combined, sources.Count));
        }
        catch (Exception ex)
        {
            Prompt.Error(owner, Strings.Organize_CombineFailed, ex.Message);
        }
    }

    /// <summary>After an edit that keeps page positions, re-select the edited pages in the thumbnails.</summary>
    private static async Task Reselect(DocumentTab tab, int[] pages, Task<bool> edit)
    {
        if (await edit) tab.SelectPages(pages);
    }

    internal static string Inches(double pt) => (pt / 72).ToString("0.##");
}
