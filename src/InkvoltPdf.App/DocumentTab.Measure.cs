using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Measure: distance, perimeter and area measurements at the page's scale (its viewport where the document has
/// one, else real size), saved as measurement annotations; Set Scale writes a page's scale into the document, and
/// Calibrate works one out from a line of known length.
/// </summary>
public partial class DocumentTab
{
    private (byte[] Data, Dictionary<int, IReadOnlyList<(RectD Area, MeasureScale Scale)>> Pages)? _viewports;

    private void InitMeasure()
    {
        Viewer.MeasureScaleAt = ScaleAt;
        Viewer.MeasureRequested += (_, r) => _ = Measure(r);
    }

    /// <summary>The scale at a point (the document's viewport there, else real size), from viewports read once per document version.</summary>
    public MeasureScale ScaleAt(int page, PointD at)
    {
        if (!Session.IsPdf) return MeasureScale.Default;
        var data = Session.Data;
        if (_viewports is not { } cached || !ReferenceEquals(cached.Data, data))
        {
            try
            {
                _viewports = cached = (data, Measurements.Viewports(data, Session.Password));
            }
            catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException or PdfSharp.PdfSharpException)
            {
                Log.Write($"Measure: viewports unreadable: {ex.Message}");
                _viewports = cached = (data, []);
            }
        }
        return Measurements.ScaleAt(cached.Pages.GetValueOrDefault(page), at) ?? MeasureScale.Default;
    }

    private static string KindName(MeasureKind kind) => kind switch
    {
        MeasureKind.Distance => "Distance",
        MeasureKind.Perimeter => "Perimeter",
        _ => "Area",
    };

    private async Task Measure(MeasureRequest r)
    {
        if (!Session.IsPdf || IsBusy) return;
        if (r.Tool == ViewerTool.MeasureCalibrate)
        {
            await Calibrate(r);
            return;
        }
        var kind = r.Tool switch { ViewerTool.MeasurePerimeter => MeasureKind.Perimeter, ViewerTool.MeasureArea => MeasureKind.Area, _ => MeasureKind.Distance };
        var scale = ScaleAt(r.PageIndex, r.Points[0]);
        var (page, pts, author, id) = (r.PageIndex, r.Points, Author, Annotations.NewId());
        var text = scale.Format(kind, pts);
        if (await RunEdit($"Measure {KindName(kind).ToLowerInvariant()}", (d, pw) => Measurements.Add(d, pw, page, kind, pts, scale, author, id), quiet: true))
        {
            var extra = kind == MeasureKind.Area ? $", perimeter {scale.FormatValue(MeasureKind.Perimeter, MeasureGeometry.Length(pts, closed: true) * scale.PerPoint)}" : "";
            Notify($"{KindName(kind)}: {text}{extra} (scale {scale.Ratio}).", "Undo", () => { if (!IsBusy && Session.UndoLabel?.StartsWith("Measure", StringComparison.Ordinal) == true) Undo(); });
        }
    }

    /// <summary>Calibrate: the line just drawn is given its real length, which sets the scale.</summary>
    private async Task Calibrate(MeasureRequest r)
    {
        if (Window.GetWindow(this) is not { } owner) return;
        var points = MeasureGeometry.Distance(r.Points[0], r.Points[^1]);
        if (points < 1)
        {
            Notify("That line is too short to calibrate from. Click two points further apart.");
            return;
        }
        var current = ScaleAt(r.PageIndex, r.Points[0]);
        var dlg = new FormDialog(owner, "Calibrate Scale", "Set Scale", 460);
        dlg.AddNote($"The line you drew is {points / 72:0.###} in long on the page. How long is it really?");
        var (row, length, unit) = LengthRow(current.Unit);
        dlg.Add("Real length", row);
        var decimals = dlg.AddChoice("Decimals", ["0", "1", "2", "3", "4"], Math.Clamp(current.Decimals, 0, 4));
        var pages = dlg.AddChoice("Use it for", [$"This page ({PageLabel(r.PageIndex)})", "All pages"]);
        double real = 0;
        dlg.Validate(() => FormDialog.TryNumber(length.Text, 1e-9, 1e12, out real) ? null : "Type the real length, a number more than 0.");
        dlg.Loaded += (_, _) => length.Focus();
        if (!dlg.ShowModal()) return;
        var scale = MeasureScale.Calibrate(points, real, (string)unit.SelectedItem, decimals.SelectedIndex);
        await SetScale(scale, pages.SelectedIndex == 1 ? null : r.PageIndex);
    }

    /// <summary>Review › Measure › Set Scale: "1 in = 10 ft" for this page or all pages, saved in the document.</summary>
    public async Task SetMeasureScale()
    {
        if (!Session.IsPdf || IsBusy || Window.GetWindow(this) is not { } owner) return;
        var page = ActiveView.CurrentPage;
        var current = ScaleAt(page, new PointD(1, 1));
        var dlg = new FormDialog(owner, "Set Measuring Scale", "Set Scale", 480);
        dlg.AddNote($"What a length on the page stands for, as drawings say it (1 in = 10 ft, 1 cm = 1 m). Now: {current.Ratio}.");
        var docValue = new TextBox { Text = "1", Width = 64 };
        var docUnit = new ComboBox { ItemsSource = MeasureScale.Units, SelectedItem = "in", Width = 72, Margin = new Thickness(6, 0, 0, 0) };
        var (realRow, realValue, realUnit) = LengthRow(current.Unit == "units" ? "ft" : current.Unit);
        realValue.Text = "1";
        System.Windows.Automation.AutomationProperties.SetName(docValue, "Length on the page");
        System.Windows.Automation.AutomationProperties.SetName(docUnit, "Unit on the page");
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(docValue);
        row.Children.Add(docUnit);
        row.Children.Add(new TextBlock { Text = "=", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 12, 0), FontSize = 16 });
        row.Children.Add(realRow);
        dlg.Add("On the page = real", row);
        var decimals = dlg.AddChoice("Decimals", ["0", "1", "2", "3", "4"], Math.Clamp(current.Decimals, 0, 4));
        var pages = dlg.AddChoice("Use it for", [$"This page ({PageLabel(page)})", "All pages"]);
        dlg.AddNote("The scale is saved in the document, as Acrobat does, so later measurements here or in other apps use it. Measurements already made keep theirs. Parts of a page with a scale of their own (a detail) keep it.");
        MeasureScale? scale = null;
        dlg.Validate(() =>
        {
            if (!FormDialog.TryNumber(docValue.Text, 1e-9, 1e9, out var dv) || !FormDialog.TryNumber(realValue.Text, 1e-9, 1e12, out var rv))
                return "Type both lengths as numbers more than 0.";
            scale = MeasureScale.From(dv, (string)docUnit.SelectedItem, rv, (string)realUnit.SelectedItem, decimals.SelectedIndex);
            return null;
        });
        dlg.Loaded += (_, _) => realValue.Focus();
        if (!dlg.ShowModal() || scale is null) return;
        await SetScale(scale, pages.SelectedIndex == 1 ? null : page);
    }

    private static (StackPanel Row, TextBox Value, ComboBox Unit) LengthRow(string unit)
    {
        var value = new TextBox { Width = 96 };
        var units = new ComboBox { ItemsSource = MeasureScale.Units, SelectedItem = MeasureScale.Units.Contains(unit) ? unit : "ft", Width = 72, Margin = new Thickness(6, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(value, "Real length");
        System.Windows.Automation.AutomationProperties.SetName(units, "Real unit");
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(value);
        row.Children.Add(units);
        return (row, value, units);
    }

    /// <param name="page">One page, or null for all.</param>
    private async Task SetScale(MeasureScale scale, int? page)
    {
        int[] pages = page is { } p ? [p] : [.. Enumerable.Range(0, Viewer.PageCount)];
        if (await RunEdit("Set measuring scale", (d, pw) => Measurements.SetPageScale(d, pw, pages, scale), quiet: true))
            Notify($"Scale {scale.Ratio} set for {(page is null ? "all pages" : $"page {PageLabel(page.Value)}")}. Measure with Review › Measure.");
    }

    // ───────────── dev script ─────────────

    internal Task DevSetScale(string text, bool all)
    {
        if (!MeasureScale.TryParse(text, out var scale)) throw new ArgumentException($"not a scale: {text}");
        return SetScale(scale!, all ? null : ActiveView.CurrentPage);
    }

    internal string DevMeasurements()
    {
        var page = ActiveView.CurrentPage;
        var list = Measurements.Read(Session.Data, Session.Password, page);
        return $"measurements p{page + 1}: {list.Count} [{string.Join(" | ", list.Select(m => $"{m.Kind} {m.Text} @ {m.Scale.Ratio}"))}] scale here {ScaleAt(page, new PointD(1, 1)).Ratio}" +
               (Viewer.MeasureInProgress is { } live ? $"; in progress {live}" : "");
    }
}
