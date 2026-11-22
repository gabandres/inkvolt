using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Organize › Page Labels.</summary>
public static partial class Organize
{
    /// <summary>The numberings Page Labels offers, in its list's order.</summary>
    private static readonly (PageNumbering Numbering, Func<string> Name)[] Numberings =
    [
        (PageNumbering.Decimal, () => "1, 2, 3"),
        (PageNumbering.LowerRoman, () => "i, ii, iii"),
        (PageNumbering.UpperRoman, () => "I, II, III"),
        (PageNumbering.LowerLetters, () => "a, b, c"),
        (PageNumbering.UpperLetters, () => "A, B, C"),
        (PageNumbering.None, () => Strings.Organize_LabelsNone),
    ];

    /// <summary>
    /// Page Labels: a numbering, prefix and first number for a range of pages, with what they will show; the pages after
    /// can be numbered from 1 again, or every label removed (<see cref="PageLabels"/>).
    /// </summary>
    public static async Task EditPageLabels(Window owner, DocumentTab tab)
    {
        var count = tab.PageView.PageCount;
        var current = CurrentPage(tab);
        PageLabelStyle at;
        try
        {
            at = PageLabels.At(tab.Session.Data, tab.Session.Password, current);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or PdfSharp.PdfSharpException)
        {
            at = new PageLabelStyle(PageNumbering.Decimal, "", current + 1);
        }
        var dlg = new FormDialog(owner, Strings.Organize_LabelsTitle, Strings.Common_Apply, 460);
        dlg.AddNote(Strings.Organize_LabelsNote);
        var range = dlg.AddRange(tab);
        var numbering = dlg.AddChoice(Strings.Organize_LabelsNumbering, Numberings.Select(n => n.Name()), Math.Max(0, Array.FindIndex(Numberings, n => n.Numbering == at.Numbering)));
        var prefix = dlg.AddText(Strings.Organize_LabelsPrefix, at.Prefix);
        var start = dlg.AddText(Strings.Organize_LabelsStart, at.Start.ToString(System.Globalization.CultureInfo.CurrentCulture));
        var restart = dlg.AddCheck(Strings.Organize_LabelsRestart, !tab.HasPageLabels && current == 0 && count > 1);
        var preview = dlg.AddNote("");
        var plain = dlg.AddFooterButton(Strings.Organize_LabelsPlain);
        plain.IsEnabled = tab.HasPageLabels;
        var removeAll = false;
        plain.Click += (_, _) =>
        {
            removeAll = true;
            dlg.DialogResult = true;
        };

        PageLabelStyle? Style(out string? error)
        {
            error = null;
            if (!int.TryParse(start.Text.Trim(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.CurrentCulture, out var first) || first < 1 || first > PageLabels.MaxStart)
            {
                error = Loc.Format(Strings.Organize_LabelsEnterStart, PageLabels.MaxStart);
                return null;
            }
            var style = new PageLabelStyle(Numberings[Math.Max(0, numbering.SelectedIndex)].Numbering, prefix.Text, first);
            try
            {
                PageLabels.Check(style);
                return style;
            }
            catch (ArgumentException ex)
            {
                error = ex.Message;
                return null;
            }
        }
        void Preview()
        {
            var style = Style(out var error);
            preview.Text = style is null ? error ?? "" : Loc.Format(Strings.Organize_LabelsPreview, string.Join(", ", Enumerable.Range(0, 4).Select(style.Format)) + "…");
        }
        numbering.SelectionChanged += (_, _) => Preview();
        prefix.TextChanged += (_, _) => Preview();
        start.TextChanged += (_, _) => Preview();
        Preview();

        int[] pages = [];
        PageLabelStyle? chosen = null;
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            chosen = Style(out err);
            return err;
        });
        if (!dlg.ShowModal() || Gone(owner, tab) || tab.PageView.PageCount != count) return;
        if (removeAll)
        {
            await tab.RunEdit(Strings.Organize_EditLabelsRemove, (d, pw) => PageLabels.Remove(d, pw));
            return;
        }
        if (chosen is not { } set) return;
        var after = restart.IsChecked == true;
        await Reselect(tab, pages, tab.RunEdit(Strings.Organize_EditLabels, (d, pw) => PageLabels.Write(d, pw, pages, set, after)));
    }
}
