using System.IO;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Organize › Remove Blank Pages and Split at Blank Pages.</summary>
public static partial class Organize
{
    /// <summary>
    /// Remove Blank Pages and Split at Blank Pages: finds the blank pages (<see cref="BlankPages"/>, File › Scan's test),
    /// shows them to tick off, then deletes the ticked ones as one undoable edit, or saves the runs of pages between them
    /// as separate PDFs (the blank ones left out).
    /// </summary>
    public static async Task BlankPagesCommand(Window owner, DocumentTab tab, MainWindow host, bool split)
    {
        if (!await tab.SettleAsync()) return;
        var count = tab.PageView.PageCount;
        var engine = tab.Session.Engine;
        int[] blanks;
        List<System.Windows.Media.ImageSource?> thumbs;
        using (tab.BeginBusy(Strings.Organize_FindingBlank))
        {
            try
            {
                (blanks, thumbs) = await Task.Run(() =>
                {
                    var found = BlankPages.Find(engine);
                    return (found, found.Select(p => Thumbnail(engine, p)).ToList());
                });
            }
            catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException)
            {
                Log.Write($"Blank page search failed: {ex}");
                return; // the document closed or changed under the search
            }
        }
        if (Gone(owner, tab) || tab.PageView.PageCount != count) return;
        if (blanks.Length == 0)
        {
            Prompt.Info(owner, Strings.Organize_NoBlankTitle, Strings.Organize_NoBlankBody);
            return;
        }

        var dlg = new FormDialog(owner, split ? Strings.Organize_SplitBlankTitle : Strings.Organize_RemoveBlankTitle, null, 520);
        dlg.AddNote(Loc.Plural(blanks.Length, Strings.Organize_BlankFound_One, Strings.Organize_BlankFound_Many));
        var mode = dlg.AddChoice(Strings.Organize_BlankThen, [Strings.Organize_BlankDelete, Strings.Organize_BlankSplit], split ? 1 : 0);
        var grid = new System.Windows.Controls.WrapPanel();
        var boxes = new List<System.Windows.Controls.CheckBox>();
        for (var i = 0; i < blanks.Length; i++)
        {
            var name = Loc.Format(Strings.Organize_BlankPageName, tab.PageLabel(blanks[i]));
            var card = new System.Windows.Controls.StackPanel();
            if (thumbs[i] is { } image)
                card.Children.Add(new System.Windows.Controls.Image { Source = image, Width = 72, Height = 96, Stretch = System.Windows.Media.Stretch.Uniform });
            card.Children.Add(new System.Windows.Controls.TextBlock { Text = name, HorizontalAlignment = HorizontalAlignment.Center, FontSize = 12 });
            var box = new System.Windows.Controls.CheckBox { Content = card, IsChecked = true, Margin = new Thickness(0, 4, 12, 4) };
            System.Windows.Automation.AutomationProperties.SetName(box, name);
            boxes.Add(box);
            grid.Children.Add(box);
        }
        dlg.Add(null, new System.Windows.Controls.ScrollViewer { Content = grid, MaxHeight = 330, VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto });
        void OkText() => dlg.SetOkText(mode.SelectedIndex == 0 ? Strings.Common_Delete : Strings.Organize_SplitButton);
        mode.SelectionChanged += (_, _) => OkText();
        OkText();
        int[] chosen = [];
        dlg.Validate(() =>
        {
            chosen = [.. blanks.Where((_, i) => boxes[i].IsChecked == true)];
            if (chosen.Length == 0) return Strings.Organize_BlankNoneTicked;
            if (mode.SelectedIndex == 0) return chosen.Length >= count ? Strings.Organize_BlankAllPages : null;
            return BlankPages.SplitAt(count, chosen).Count == 0 ? Strings.Organize_BlankSplitNothing : null;
        });
        if (!dlg.ShowModal() || Gone(owner, tab) || !await tab.SettleAsync() || tab.PageView.PageCount != count) return;

        if (mode.SelectedIndex == 0)
        {
            await tab.RunEdit(Pages(chosen.Length, Strings.Organize_EditRemoveBlank_One, Strings.Organize_EditRemoveBlank_Many),
                (d, pw) => BlankPages.Remove(d, pw, chosen), Math.Min(chosen.Min(), count - chosen.Length - 1));
            return;
        }

        if (!ConfirmUnprotected(owner, tab, Strings.Organize_SplitUnprotected, Strings.Organize_SplitAnyway)) return;
        var folder = PdfFiles.PickFolder(owner, Strings.Organize_SaveSplitBlankTo, Path.GetDirectoryName(tab.Session.FilePath));
        if (folder is null) return;
        var parts = BlankPages.SplitAt(count, chosen);
        var stem = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        List<(string Path, Func<byte[]> Bytes)> files;
        try
        {
            files = [.. parts.Select((p, i) => (PdfFiles.UniquePath(folder, Loc.Format(Strings.Organize_BlankPartName, stem, i + 1) + ".pdf", reserved), (Func<byte[]>)(() => PageEditor.Extract(data, password, p))))];
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or NotSupportedException or UnauthorizedAccessException)
        {
            Prompt.Error(owner, Strings.Organize_SplitFailed, ex.Message);
            return;
        }
        using var busy = tab.BeginBusy(Loc.Format(Strings.Organize_Splitting, parts.Count));
        try
        {
            await Task.Run(() => PdfFiles.WriteBatch(files));
            host.ShowStatus(Loc.Format(Strings.Organize_SplitDone, parts.Count, folder));
            Shell.Open(folder);
        }
        catch (Exception ex)
        {
            Log.Write($"Split at blank pages failed: {ex}");
            Prompt.Error(owner, Strings.Organize_SplitFailed, BatchFailure(ex));
        }
    }

    /// <summary>A small picture of a page for a list to tick (null when it can't be drawn).</summary>
    private static System.Windows.Media.ImageSource? Thumbnail(PdfEngine engine, int page)
    {
        try
        {
            var g = engine.GetPage(page);
            var image = engine.Render(page, 96 / Math.Max(1, Math.Max(g.Width, g.Height)));
            var bitmap = System.Windows.Media.Imaging.BitmapSource.Create(image.Width, image.Height, 96, 96, System.Windows.Media.PixelFormats.Bgr24, null, image.Pixels, image.Stride);
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }
}
