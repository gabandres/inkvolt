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
    private (byte[] Data, Dictionary<int, IReadOnlyList<(RectD Area, MeasureScale Scale)>> Pages, Dictionary<int, double> Units)? _viewports;

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
                _viewports = cached = (data, Measurements.Viewports(data, Session.Password), Measurements.UserUnits(data, Session.Password));
            }
            catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException or PdfSharp.PdfSharpException)
            {
                Log.Write($"Measure: viewports unreadable: {ex.Message}");
                _viewports = cached = (data, [], []);
            }
        }
        return Measurements.ScaleAt(cached.Pages.GetValueOrDefault(page), at)
               ?? MeasureScale.Default with { UserUnit = cached.Units.GetValueOrDefault(page, 1) };
    }

    /// <summary>The edit's name, as Undo and the toast's Undo button know it.</summary>
    private static string MeasureEditName(MeasureKind kind) => kind switch
    {
        MeasureKind.Distance => Strings.Measure_EditDistance,
        MeasureKind.Perimeter => Strings.Measure_EditPerimeter,
        _ => Strings.Measure_EditArea,
    };

    private static bool IsMeasureEdit(string? label) =>
        label is not null && (label == Strings.Measure_EditDistance || label == Strings.Measure_EditPerimeter || label == Strings.Measure_EditArea);

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
        if (await RunEdit(MeasureEditName(kind), (d, pw) => Measurements.Add(d, pw, page, kind, pts, scale, author, id), quiet: true))
        {
            var said = kind switch
            {
                MeasureKind.Area => Loc.Format(Strings.Measure_ResultArea, text,
                    scale.FormatValue(MeasureKind.Perimeter, MeasureGeometry.Length(pts, closed: true) * scale.PerUnit), scale.Ratio),
                MeasureKind.Perimeter => Loc.Format(Strings.Measure_ResultPerimeter, text, scale.Ratio),
                _ => Loc.Format(Strings.Measure_ResultDistance, text, scale.Ratio),
            };
            Notify(said, Strings.Common_Undo, () => { if (!IsBusy && IsMeasureEdit(Session.UndoLabel)) Undo(); });
        }
    }

    /// <summary>Calibrate: the line just drawn is given its real length, which sets the scale.</summary>
    private async Task Calibrate(MeasureRequest r)
    {
        if (Window.GetWindow(this) is not { } owner) return;
        var current = ScaleAt(r.PageIndex, r.Points[0]);
        var points = MeasureGeometry.Distance(r.Points[0], r.Points[^1]) * current.UserUnit; // in points, whatever the page's unit
        if (points < 1)
        {
            Notify(Strings.Measure_TooShort);
            return;
        }
        var dlg = new FormDialog(owner, Strings.Measure_CalibrateTitle, Strings.Measure_SetScaleButton, 460);
        dlg.AddNote(Loc.Format(Strings.Measure_CalibrateNote, points / 72));
        var (row, length, unit) = LengthRow(current.Unit);
        dlg.Add(Strings.Measure_RealLength, row);
        var decimals = dlg.AddChoice(Strings.Measure_Decimals, ["0", "1", "2", "3", "4"], Math.Clamp(current.Decimals, 0, 4));
        var pages = dlg.AddChoice(Strings.Measure_UseFor, [Loc.Format(Strings.Measure_ThisPage, PageLabel(r.PageIndex)), Strings.Common_AllPages]);
        double real = 0;
        dlg.Validate(() => FormDialog.TryNumber(length.Text, 1e-9, 1e12, out real) ? null : Strings.Measure_TypeRealLength);
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
        var dlg = new FormDialog(owner, Strings.Measure_SetScaleTitle, Strings.Measure_SetScaleButton, 480);
        dlg.AddNote(Loc.Format(Strings.Measure_SetScaleNote, current.Ratio));
        var docValue = new TextBox { Text = "1", Width = 64 };
        var docUnit = new ComboBox { ItemsSource = MeasureScale.Units, SelectedItem = "in", Width = 72, Margin = new Thickness(6, 0, 0, 0) };
        var (realRow, realValue, realUnit) = LengthRow(current.Unit == "units" ? "ft" : current.Unit);
        realValue.Text = "1";
        System.Windows.Automation.AutomationProperties.SetName(docValue, Strings.Measure_PageLength);
        System.Windows.Automation.AutomationProperties.SetName(docUnit, Strings.Measure_PageUnit);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(docValue);
        row.Children.Add(docUnit);
        row.Children.Add(new TextBlock { Text = "=", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 12, 0), FontSize = 16 });
        row.Children.Add(realRow);
        dlg.Add(Strings.Measure_PageEqualsReal, row);
        var decimals = dlg.AddChoice(Strings.Measure_Decimals, ["0", "1", "2", "3", "4"], Math.Clamp(current.Decimals, 0, 4));
        var pages = dlg.AddChoice(Strings.Measure_UseFor, [Loc.Format(Strings.Measure_ThisPage, PageLabel(page)), Strings.Common_AllPages]);
        dlg.AddNote(Strings.Measure_SavedNote);
        MeasureScale? scale = null;
        dlg.Validate(() =>
        {
            if (!FormDialog.TryNumber(docValue.Text, 1e-9, 1e9, out var dv) || !FormDialog.TryNumber(realValue.Text, 1e-9, 1e12, out var rv))
                return Strings.Measure_TypeBoth;
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
        System.Windows.Automation.AutomationProperties.SetName(value, Strings.Measure_RealLength);
        System.Windows.Automation.AutomationProperties.SetName(units, Strings.Measure_RealUnit);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(value);
        row.Children.Add(units);
        return (row, value, units);
    }

    /// <param name="page">One page, or null for all.</param>
    private async Task SetScale(MeasureScale scale, int? page)
    {
        int[] pages = page is { } p ? [p] : [.. Enumerable.Range(0, Viewer.PageCount)];
        if (await RunEdit(Strings.Measure_EditSetScale, (d, pw) => Measurements.SetPageScale(d, pw, pages, scale), quiet: true))
            Notify(page is null ? Loc.Format(Strings.Measure_ScaleSetAll, scale.Ratio) : Loc.Format(Strings.Measure_ScaleSetPage, scale.Ratio, PageLabel(page.Value)));
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
