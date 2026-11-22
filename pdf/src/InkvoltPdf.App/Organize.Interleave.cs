using System.Windows;
using InkvoltPdf.Core;
using PageRange = InkvoltPdf.Core.PageRange;

namespace InkvoltPdf.App;

/// <summary>Organize › Interleave Pages, and what Scan the Backs shares with it.</summary>
public static partial class Organize
{
    /// <summary>
    /// Interleave Pages: the fronts and the backs of two-sided sheets, either two ranges of this document or this
    /// document (the fronts) and another PDF (the backs). <see cref="PageEditor.InterleaveOrder"/> decides the order.
    /// </summary>
    public static async Task Interleave(Window owner, DocumentTab tab)
    {
        var count = tab.PageView.PageCount;
        var half = (count + 1) / 2;
        var dlg = new FormDialog(owner, Strings.Organize_InterleaveTitle, Strings.Organize_InterleaveButton, 480);
        dlg.AddNote(Strings.Organize_InterleaveNote);
        var from = dlg.AddChoice(Strings.Organize_InterleaveBacksFrom, [Strings.Organize_InterleaveThisDoc, Strings.Organize_InterleaveOtherFile], count > 1 ? 0 : 1);
        var frontBox = dlg.AddText(Strings.Organize_InterleaveFronts, half > 1 ? $"1-{half}" : "1");
        var backBox = dlg.AddText(Strings.Organize_InterleaveBacks, count > half + 1 ? $"{half + 1}-{count}" : count.ToString());
        var reversed = dlg.AddCheck(Strings.Organize_InterleaveReversed, true);
        void Enable() => frontBox.IsEnabled = backBox.IsEnabled = from.SelectedIndex == 0;
        from.SelectionChanged += (_, _) => Enable();
        Enable();
        int[] fronts = [], backs = [];
        dlg.Validate(() =>
        {
            if (from.SelectedIndex == 1) return null;
            if (!PageRange.TryParse(frontBox.Text, count, out fronts, out var err) || !PageRange.TryParse(backBox.Text, count, out backs, out err)) return err;
            try
            {
                PageEditor.InterleaveOrder(count, fronts, backs, reversed.IsChecked == true);
                return null;
            }
            catch (ArgumentException ex)
            {
                return ex.Message;
            }
        });
        if (!dlg.ShowModal() || Gone(owner, tab)) return;
        var reverse = reversed.IsChecked == true;

        if (from.SelectedIndex == 0)
        {
            if (tab.PageView.PageCount != count || !ConfirmUneven(owner, fronts.Length, backs.Length)) return;
            await tab.RunEdit(Strings.Organize_EditInterleave, (d, pw) => PageEditor.Interleave(d, pw, fronts, backs, reverse), Math.Min(fronts.Min(), backs.Min()));
            return;
        }
        var path = PdfFiles.PickPdf(owner, Strings.Organize_InterleavePick);
        if (path is null || await PdfFiles.LoadForImportAsync(owner, path) is not { } source || Gone(owner, tab)) return;
        int backCount;
        using (var e = PdfEngine.Open(source.Data, MuPDFCore.InputFileTypes.PDF, source.Password)) backCount = e.PageCount;
        if (!ConfirmUneven(owner, tab.PageView.PageCount, backCount)) return;
        await tab.RunEdit(Strings.Organize_EditInterleave, (d, pw) => PageEditor.InterleaveWith(d, pw, source, reverse), 0);
    }

    /// <summary>Fronts and backs of different counts are allowed (what is left over follows), after the user says so.</summary>
    internal static bool ConfirmUneven(Window owner, int fronts, int backs) =>
        fronts == backs || Prompt.Confirm(owner, Strings.Organize_InterleaveUnevenTitle, Loc.Format(Strings.Organize_InterleaveUnevenBody, fronts, backs), Strings.Organize_InterleaveAnyway);
}
