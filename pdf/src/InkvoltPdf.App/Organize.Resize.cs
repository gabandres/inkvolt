using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Organize › Resize Pages.</summary>
public static partial class Organize
{
    /// <summary>Resize Pages: a paper size (or one typed), scale or margins, which pages; <see cref="PageEditor.Resize"/> does it.</summary>
    public static async Task Resize(Window owner, DocumentTab tab)
    {
        var current = tab.Session.Engine.GetPage(CurrentPage(tab));
        var dlg = new FormDialog(owner, Strings.Organize_ResizeTitle, Strings.Organize_ResizeButton, 480);
        // A4 where the metric system is used, Letter elsewhere (as the printer's paper usually is).
        var metric = System.Globalization.RegionInfo.CurrentRegion.IsMetric;
        var size = dlg.AddChoice(Strings.Organize_PageSize, [.. PaperSizes.Select(p => p.Name()), Strings.Organize_ResizeCustom],
            Array.FindIndex(PaperSizes, p => p.W == (metric ? 595 : 612) && p.H == (metric ? 842 : 792)));
        var units = dlg.AddChoice(Strings.Organize_Units, [Strings.Organize_Inches, Strings.Organize_Millimeters]);
        var widthBox = dlg.AddText(Strings.Organize_ResizeWidth, Inches(Math.Min(current.Width, current.Height)));
        var heightBox = dlg.AddText(Strings.Organize_ResizeHeight, Inches(Math.Max(current.Width, current.Height)));
        var fit = dlg.AddChoice(Strings.Organize_ResizeContent, [Strings.Organize_ResizeScale, Strings.Organize_ResizeMargins]);
        var range = dlg.AddRange(tab, preferSelection: tab.SelectedPages.Length > 1);
        dlg.AddNote(Strings.Organize_ResizeNote);
        var custom = PaperSizes.Length;
        void Enable() => units.IsEnabled = widthBox.IsEnabled = heightBox.IsEnabled = size.SelectedIndex == custom;
        size.SelectionChanged += (_, _) => Enable();
        units.SelectionChanged += (_, _) =>
        {
            // The sizes typed stay the same length in the other unit.
            var (from, to) = units.SelectedIndex == 1 ? (72.0, 72 / 25.4) : (72 / 25.4, 72.0);
            foreach (var box in new[] { widthBox, heightBox })
                if (FormDialog.TryNumber(box.Text, 0, 1e6, out var v)) box.Text = (v * from / to).ToString(units.SelectedIndex == 1 ? "0" : "0.##");
        };
        Enable();

        int[] pages = [];
        double w = 0, h = 0;
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var err)) return err;
            if (size.SelectedIndex < custom)
            {
                (w, h) = (PaperSizes[size.SelectedIndex].W, PaperSizes[size.SelectedIndex].H);
                return null;
            }
            var factor = units.SelectedIndex == 1 ? 72 / 25.4 : 72.0;
            if (!FormDialog.TryNumber(widthBox.Text, 0, 1e6, out w) || !FormDialog.TryNumber(heightBox.Text, 0, 1e6, out h)) return Strings.Organize_ResizeEnterSize;
            (w, h) = (w * factor, h * factor);
            return w < PageEditor.MinPaper - 0.5 || h < PageEditor.MinPaper - 0.5 || w > PageEditor.MaxPaper + 0.5 || h > PageEditor.MaxPaper + 0.5
                ? Strings.Organize_ResizeEnterSize : null;
        });
        if (!dlg.ShowModal() || Gone(owner, tab)) return;
        (w, h) = (Math.Clamp(w, PageEditor.MinPaper, PageEditor.MaxPaper), Math.Clamp(h, PageEditor.MinPaper, PageEditor.MaxPaper));
        var how = fit.SelectedIndex == 0 ? ResizeFit.Scale : ResizeFit.Margins;
        await Reselect(tab, pages, tab.RunEdit(Pages(pages.Length, Strings.Organize_EditResize_One, Strings.Organize_EditResize_Many),
            (d, pw) => PageEditor.Resize(d, pw, pages, w, h, how)));
    }
}
