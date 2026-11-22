using System.IO;
using System.Windows;
using InkvoltPdf.Core;
using PageRange = InkvoltPdf.Core.PageRange;

namespace InkvoltPdf.App;

/// <summary>Organize › Replace Pages.</summary>
public static partial class Organize
{
    /// <summary>
    /// Replace Pages: pages of this document swapped one for one for pages of another PDF
    /// (<see cref="PageEditor.Replace"/>: what led to a replaced page leads to its replacement).
    /// </summary>
    public static async Task Replace(Window owner, DocumentTab tab)
    {
        var path = PdfFiles.PickPdf(owner, Strings.Organize_ReplacePick);
        if (path is null || await PdfFiles.LoadForImportAsync(owner, path) is not { } source || Gone(owner, tab)) return;
        int srcCount;
        using (var e = PdfEngine.Open(source.Data, MuPDFCore.InputFileTypes.PDF, source.Password)) srcCount = e.PageCount;

        var dlg = new FormDialog(owner, Strings.Organize_ReplaceTitle, Strings.Organize_ReplaceButton, 480);
        dlg.AddNote(Loc.Plural(srcCount, Strings.Organize_ReplaceFrom_One, Strings.Organize_ReplaceFrom_Many, Path.GetFileName(path)));
        var range = dlg.AddRange(tab, Strings.Organize_ReplaceThese);
        var count = tab.PageView.PageCount;
        var srcRange = dlg.AddText(Strings.Organize_ReplaceWith, srcCount > 1 ? $"1-{Math.Min(srcCount, Math.Max(1, tab.SelectedPages.Length))}" : "1");
        dlg.AddNote(Strings.Organize_ReplaceNote);
        int[] pages = [], srcPages = [];
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err) || !PageRange.TryParse(srcRange.Text, srcCount, out srcPages, out err)) return err;
            return pages.Length == srcPages.Length ? null : Loc.Format(Strings.Organize_ReplaceCountsDiffer, pages.Length, srcPages.Length);
        });
        if (!dlg.ShowModal() || Gone(owner, tab) || tab.PageView.PageCount != count) return;
        await Reselect(tab, pages, tab.RunEdit(Loc.Plural(pages.Length, Strings.Organize_EditReplace_One, Strings.Organize_EditReplace_Many, source.Name),
            (d, pw) => PageEditor.Replace(d, pw, pages, source, srcPages), pages.Min()));
    }
}
