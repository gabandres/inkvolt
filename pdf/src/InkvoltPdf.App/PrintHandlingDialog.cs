using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Print › Page Sizing &amp; Handling (after the printer is chosen, so the paper is known): fit (actual size or fit to
/// paper), several pages per sheet, a booklet or a poster, with a sketch of the first sheet and how many sheets it takes.
/// The choices are remembered.
/// </summary>
public static class PrintHandlingDialog
{
    /// <summary>Poster overlaps offered, in DIPs (1/96 in).</summary>
    private static (string Name, double Dips)[] Overlaps => [(Strings.Common_None, 0), ("¼ in (6 mm)", 24), ("½ in (13 mm)", 48), ("1 in (25 mm)", 96)]; // in every language: measurements

    /// <summary>The setup chosen, or null when cancelled.</summary>
    /// <param name="size">A page's size as shown, in DIPs.</param>
    /// <param name="paper">The paper (DIPs) and its printable area.</param>
    /// <param name="duplex">The printer prints both sides by itself (a booklet is set to flip on the short edge).</param>
    public static PrintSetup? Ask(Window owner, IReadOnlyList<int> pages, Func<int, (double W, double H)> size, Size paper, RectD area, bool duplex)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, Strings.Print_SizingTitle, Strings.Common_Print, 760);
        var group = $"ph{dlg.GetHashCode()}";
        RadioButton Choice(string text, PrintHandling h) => new()
        {
            Content = text, GroupName = group, Margin = new Thickness(0, 8, 0, 2),
            IsChecked = string.Equals(s.PrintHandling, h.ToString(), StringComparison.Ordinal),
        };

        var fit = Choice(Strings.Print_FitOne, PrintHandling.Fit);
        var actual = new RadioButton { Content = Strings.Print_SizingActual, GroupName = group + "s", IsChecked = !s.PrintFitToPaper, Margin = new Thickness(24, 2, 0, 0) };
        var fill = new RadioButton { Content = Strings.Print_SizingFit, GroupName = group + "s", IsChecked = s.PrintFitToPaper, Margin = new Thickness(24, 2, 0, 0) };

        var multiple = Choice(Strings.Print_Multiple, PrintHandling.PagesPerSheet);
        var perSheet = Combo(PrintSetup.PagesPerSheetChoices.Select(n => n.ToString(CultureInfo.CurrentCulture)), Math.Max(0, PrintSetup.PagesPerSheetChoices.ToList().IndexOf(s.PrintPagesPerSheet)), Strings.Print_PagesPerSheet);
        var order = Combo([Strings.Print_AcrossDown, Strings.Print_DownAcross], s.PrintOrderDown ? 1 : 0, Strings.Print_PageOrder);
        var borders = new CheckBox { Content = Strings.Print_PageBorders, IsChecked = s.PrintBorders, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        var multipleRow = Row(perSheet, order, borders);

        var booklet = Choice(Strings.Print_Booklet, PrintHandling.Booklet);
        var binding = Combo([Strings.Print_BindingLeft, Strings.Print_BindingRight], s.PrintRightBinding ? 1 : 0, Strings.Print_Binding);
        var bookletRow = Row(binding);

        var poster = Choice(Strings.Print_Poster, PrintHandling.Poster);
        var percent = new TextBox { Text = s.PrintPosterPercent.ToString(CultureInfo.CurrentCulture), Width = 64, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(percent, Strings.Print_PosterSize);
        var overlap = Combo(Overlaps.Select(o => o.Name), Math.Clamp(s.PrintPosterOverlap, 0, Overlaps.Length - 1), Strings.Print_Overlap);
        var marks = new CheckBox { Content = Strings.Print_CutMarks, IsChecked = s.PrintCutMarks, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        var posterRow = Row(Labeled(Strings.Print_SizePercent, percent), Labeled(Strings.Print_Overlap, overlap), marks);

        if (new[] { fit, multiple, booklet, poster }.All(r => r.IsChecked != true)) fit.IsChecked = true;

        var summary = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 14, 0, 0) };
        var form = new StackPanel();
        foreach (var e in new UIElement[] { fit, actual, fill, multiple, multipleRow, booklet, bookletRow, poster, posterRow, summary }) form.Children.Add(e);
        var sketch = new SheetSketch(paper, area) { Width = 200, Height = 260, Margin = new Thickness(20, 4, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetName(sketch, Strings.Print_Sketch);
        var both = new DockPanel();
        DockPanel.SetDock(sketch, Dock.Right);
        both.Children.Add(sketch);
        both.Children.Add(form);
        dlg.Add(null, both);

        PrintSetup? Read(out string? error)
        {
            error = null;
            var handling = multiple.IsChecked == true ? PrintHandling.PagesPerSheet
                : booklet.IsChecked == true ? PrintHandling.Booklet
                : poster.IsChecked == true ? PrintHandling.Poster
                : PrintHandling.Fit;
            var pct = 100.0;
            if (handling == PrintHandling.Poster && !FormDialog.TryNumber(percent.Text, 25, 1000, out pct))
            {
                error = Strings.Print_PosterRange;
                return null;
            }
            return new PrintSetup
            {
                Handling = handling,
                Sizing = fill.IsChecked == true ? PrintSizing.FitToPaper : PrintSizing.ActualSize,
                PagesPerSheet = PrintSetup.PagesPerSheetChoices[Math.Max(0, perSheet.SelectedIndex)],
                Order = order.SelectedIndex == 1 ? PagesOrder.Down : PagesOrder.Across,
                Borders = borders.IsChecked == true,
                RightBinding = binding.SelectedIndex == 1,
                PosterScale = pct / 100,
                Overlap = Overlaps[Math.Max(0, overlap.SelectedIndex)].Dips,
                CutMarks = marks.IsChecked == true,
            };
        }

        void Update()
        {
            multipleRow.IsEnabled = multiple.IsChecked == true;
            actual.IsEnabled = fill.IsEnabled = fit.IsChecked == true;
            bookletRow.IsEnabled = booklet.IsChecked == true;
            posterRow.IsEnabled = poster.IsChecked == true;
            if (Read(out var error) is not { } setup)
            {
                summary.Text = error;
                sketch.Show(null, "");
                return;
            }
            var plan = new PrintPlan(pages, size, area, setup);
            sketch.Show(plan.SheetCount > 0 ? plan.Sheet(0) : null, setup.Handling == PrintHandling.Booklet ? Loc.Format(Strings.Print_SheetFront, plan.PaperCount)
                : plan.SheetCount == 1 ? Loc.Plural(1, Strings.Print_Sheets_One, Strings.Print_Sheets_Many) : Loc.Format(Strings.Print_SheetOf, plan.SheetCount));
            summary.Text = Summary(pages.Count, plan, setup, duplex);
        }
        foreach (var r in new[] { fit, actual, fill, multiple, booklet, poster }) r.Checked += (_, _) => Update();
        foreach (var c in new[] { perSheet, order, binding, overlap }) c.SelectionChanged += (_, _) => Update();
        foreach (var c in new[] { borders, marks }) c.Click += (_, _) => Update();
        percent.TextChanged += (_, _) =>
        {
            poster.IsChecked = true;
            Update();
        };
        Update();

        PrintSetup? result = null;
        dlg.Validate(() =>
        {
            result = Read(out var error);
            return error;
        });
        if (!dlg.ShowModal() || result is null) return null;

        s.PrintHandling = result.Handling.ToString();
        s.PrintFitToPaper = result.Sizing == PrintSizing.FitToPaper;
        s.PrintPagesPerSheet = result.PagesPerSheet;
        s.PrintOrderDown = result.Order == PagesOrder.Down;
        s.PrintBorders = result.Borders;
        s.PrintRightBinding = result.RightBinding;
        if (result.Handling == PrintHandling.Poster) s.PrintPosterPercent = (int)Math.Round(result.PosterScale * 100);
        s.PrintPosterOverlap = Math.Max(0, overlap.SelectedIndex);
        s.PrintCutMarks = result.CutMarks;
        s.Save();
        return result;
    }

    /// <summary>What the job takes, and for a booklet how to print and fold it.</summary>
    internal static string Summary(int pageCount, PrintPlan plan, PrintSetup setup, bool duplex)
    {
        string Pages(int n) => Loc.Plural(n, Strings.Print_Pages_One, Strings.Print_Pages_Many);
        string Sheets(int n) => Loc.Plural(n, Strings.Print_Sheets_One, Strings.Print_Sheets_Many);
        return setup.Handling switch
        {
            PrintHandling.Booklet =>
                (pageCount % 4 != 0 ? Loc.Format(Strings.Print_BookletBlank, Pages(pageCount), Sheets(plan.PaperCount), 4 - pageCount % 4)
                    : Loc.Format(Strings.Print_BookletSheets, Pages(pageCount), Sheets(plan.PaperCount))) + " " +
                (duplex ? Strings.Print_BookletDuplex : Strings.Print_BookletManualDuplex) + " " + Strings.Print_BookletFold,
            PrintHandling.Poster => Loc.Format(setup.CutMarks ? Strings.Print_PosterSummaryMarks : Strings.Print_PosterSummary, Pages(pageCount), Sheets(plan.SheetCount)),
            _ => Loc.Format(Strings.Print_SummaryOn, Pages(pageCount), Sheets(plan.SheetCount)),
        };
    }

    private static ComboBox Combo(IEnumerable<string> items, int selected, string name)
    {
        var c = new ComboBox { ItemsSource = items.ToList(), SelectedIndex = selected, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(c, name);
        return c;
    }

    private static StackPanel Labeled(string label, FrameworkElement control)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 8, 0) };
        p.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) });
        p.Children.Add(control);
        return p;
    }

    private static WrapPanel Row(params UIElement[] items)
    {
        var p = new WrapPanel { Margin = new Thickness(24, 4, 0, 0) };
        foreach (var i in items) p.Children.Add(i);
        return p;
    }

    /// <summary>The first sheet as boxes: the paper, its printable area, each page with its number (turned with it), cut marks.</summary>
    private sealed class SheetSketch(Size paper, RectD area) : FrameworkElement
    {
        private PrintSheet? _sheet;
        private string _label = "";

        public void Show(PrintSheet? sheet, string label)
        {
            _sheet = sheet;
            _label = label;
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            var caption = 20.0;
            var k = Math.Min(ActualWidth / paper.Width, (ActualHeight - caption) / paper.Height);
            if (!(k > 0)) return;
            var ox = (ActualWidth - paper.Width * k) / 2;
            Rect R(RectD r) => new(ox + r.X * k, r.Y * k, r.Width * k, r.Height * k);
            var line = (Brush)FindResource("TextFillColorSecondaryBrush");
            var pagePen = new Pen(line, 1);
            dc.DrawRectangle(Brushes.White, new Pen(line, 1), R(new RectD(0, 0, paper.Width, paper.Height)));
            dc.DrawRectangle(null, new Pen(Brushes.LightGray, 1) { DashStyle = DashStyles.Dash }, R(area));
            var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            if (_sheet is { } sheet)
            {
                foreach (var p in sheet.Pages)
                {
                    var box = R(p.Box);
                    dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0xE8, 0xEE, 0xF8)), pagePen, box);
                    var text = new FormattedText((p.Page + 1).ToString(CultureInfo.CurrentCulture), CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                        new Typeface("Segoe UI"), Math.Clamp(Math.Min(box.Width, box.Height) * 0.35, 7, 28), Brushes.DimGray, dpi);
                    dc.PushTransform(new TranslateTransform(box.X + box.Width / 2, box.Y + box.Height / 2));
                    if (p.Turns == 1) dc.PushTransform(new RotateTransform(90));
                    dc.DrawText(text, new Point(-text.Width / 2, -text.Height / 2));
                    if (p.Turns == 1) dc.Pop();
                    dc.Pop();
                }
                var mark = new Pen(Brushes.Black, 1);
                foreach (var m in sheet.Marks) dc.DrawLine(mark, new Point(ox + m.X1 * k, m.Y1 * k), new Point(ox + m.X2 * k, m.Y2 * k));
            }
            var label = new FormattedText(_label, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 12, line, dpi);
            dc.DrawText(label, new Point((ActualWidth - label.Width) / 2, paper.Height * k + 4));
        }
    }
}
