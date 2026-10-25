using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>A measuring tool finished: the points it clicked (page space) on <see cref="PageIndex"/>.</summary>
public sealed record MeasureRequest(int PageIndex, ViewerTool Tool, IReadOnlyList<PointD> Points);

/// <summary>
/// Measuring: distance (two clicks), perimeter and area (a click per corner; double-click or Enter finishes, Backspace
/// takes the last corner back, Esc cancels), and calibration (a distance whose real length the host asks for). Shift
/// keeps a segment horizontal, vertical or at 45°. The value under way shows by the pointer at the scale the host gives
/// for that spot (<see cref="MeasureScaleAt"/>); the host turns each finished measurement into an annotation.
/// </summary>
public sealed partial class PageViewer
{
    private int _measurePage = -1;
    private readonly List<PointD> _measurePts = [];
    private PointD? _measureHover;

    /// <summary>The scale at a point of a page (the page's viewport there, else the one the user set).</summary>
    public Func<int, PointD, MeasureScale>? MeasureScaleAt { get; set; }

    public event EventHandler<MeasureRequest>? MeasureRequested;

    public static bool IsMeasureTool(ViewerTool tool) =>
        tool is ViewerTool.MeasureDistance or ViewerTool.MeasurePerimeter or ViewerTool.MeasureArea or ViewerTool.MeasureCalibrate;

    private static MeasureKind KindOf(ViewerTool tool) => tool switch
    {
        ViewerTool.MeasurePerimeter => MeasureKind.Perimeter,
        ViewerTool.MeasureArea => MeasureKind.Area,
        _ => MeasureKind.Distance,
    };

    /// <summary>The measurement under way, for the dev script and screen readers: its points and value.</summary>
    public string? MeasureInProgress =>
        _measurePage < 0 ? null : $"{_measurePts.Count} point(s), {CurrentValue(includeHover: false)}";

    private void CancelMeasure()
    {
        if (_measurePage < 0 && _measureHover is null) return;
        _measurePage = -1;
        _measurePts.Clear();
        _measureHover = null;
        _surface.InvalidateVisual();
    }

    private bool HandleMeasureDown(MouseButtonEventArgs e, int page, Point sp)
    {
        if (!IsMeasureTool(_tool) || e.ChangedButton != MouseButton.Left || _engine is null) return false;
        e.Handled = true;
        _pressLink = null; // measuring over a link doesn't follow it
        Focus();
        if (page < 0) return true;
        if (_measurePage >= 0 && page != _measurePage) CancelMeasure(); // a click on another page starts over there
        var pt = ClampToPage(page, ToPagePoint(page, sp));
        var p = Snap(new PointD(pt.X, pt.Y));
        if (_measurePage < 0)
        {
            _measurePage = page;
            _measurePts.Clear();
        }
        // A double-click finishes a perimeter or area (its second click lands on the corner just added).
        if (e.ClickCount >= 2 && KindOf(_tool) != MeasureKind.Distance)
        {
            FinishMeasure();
            return true;
        }
        if (_measurePts.Count == 0 || MeasureGeometry.Distance(_measurePts[^1], p) > 0.01) _measurePts.Add(p);
        if (KindOf(_tool) == MeasureKind.Distance && _measurePts.Count == 2) FinishMeasure();
        _surface.InvalidateVisual();
        return true;
    }

    /// <summary>With Shift, the new point lies horizontally, vertically or at 45° from the last one.</summary>
    private PointD Snap(PointD p) =>
        (Keyboard.Modifiers & ModifierKeys.Shift) != 0 && _measurePts.Count > 0 ? DrawingGeometry.SnapAngle(_measurePts[^1], p) : p;

    private bool MoveMeasure(Point sp)
    {
        if (!IsMeasureTool(_tool) || _measurePage < 0) return false;
        var pt = ClampToPage(_measurePage, ToPagePoint(_measurePage, sp));
        _measureHover = Snap(new PointD(pt.X, pt.Y));
        _surface.InvalidateVisual();
        return true;
    }

    private bool HandleMeasureKey(KeyEventArgs e)
    {
        if (!IsMeasureTool(_tool)) return false;
        switch (e.Key)
        {
            case Key.Escape when _measurePage >= 0:
                CancelMeasure();
                return true;
            case Key.Escape:
                Tool = ViewerTool.Hand;
                return true;
            case Key.Enter when _measurePage >= 0:
                FinishMeasure();
                return true;
            case Key.Back when _measurePts.Count > 0:
                _measurePts.RemoveAt(_measurePts.Count - 1);
                if (_measurePts.Count == 0) CancelMeasure();
                _surface.InvalidateVisual();
                return true;
        }
        return false;
    }

    private void FinishMeasure()
    {
        var page = _measurePage;
        var pts = _measurePts.ToList();
        var need = KindOf(_tool) switch { MeasureKind.Area => 3, _ => 2 };
        if (page < 0 || pts.Count < need) return; // not enough points yet: keep going
        CancelMeasure();
        MeasureRequested?.Invoke(this, new MeasureRequest(page, _tool, pts));
    }

    /// <summary>For the dev script: a measurement as if clicked.</summary>
    internal void DevMeasure(int page, ViewerTool tool, IReadOnlyList<PointD> points) =>
        MeasureRequested?.Invoke(this, new MeasureRequest(page, tool, points));

    private string CurrentValue(bool includeHover)
    {
        if (_measurePage < 0) return "";
        var pts = _measurePts.ToList();
        if (includeHover && _measureHover is { } h) pts.Add(h);
        if (pts.Count == 0) return "";
        var scale = MeasureScaleAt?.Invoke(_measurePage, pts[0]) ?? MeasureScale.Default;
        var kind = KindOf(_tool);
        if (kind == MeasureKind.Area && pts.Count >= 3)
            return $"{scale.Format(MeasureKind.Area, pts)} · perimeter {scale.FormatValue(MeasureKind.Perimeter, MeasureGeometry.Length(pts, closed: true) * scale.PerUnit)}";
        return scale.Format(MeasureKind.Distance, pts);
    }

    private void PaintMeasure(DrawingContext dc, int page)
    {
        if (_measurePage != page || _measurePts.Count == 0) return;
        var pts = _measurePts.ToList();
        if (_measureHover is { } h) pts.Add(h);
        var color = Color.FromRgb(0xCC, 0x1A, 0x1A);
        var pen = Frozen(new Pen(Frozen(new SolidColorBrush(color)), 1.5));
        var dashed = Frozen(new Pen(Frozen(new SolidColorBrush(color)), 1) { DashStyle = DashStyles.Dash });
        var screen = pts.Select(p => ToSurfacePoint(page, p.X, p.Y)).ToList();
        var area = KindOf(_tool) == MeasureKind.Area;
        if (area && screen.Count >= 3)
        {
            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(screen[0], true, true);
                ctx.PolyLineTo(screen.Skip(1).ToList(), true, true);
            }
            geo.Freeze();
            dc.DrawGeometry(Frozen(new SolidColorBrush(Color.FromArgb(0x30, color.R, color.G, color.B))), null, geo);
            dc.DrawLine(dashed, screen[^1], screen[0]);
        }
        for (var i = 1; i < screen.Count; i++) dc.DrawLine(pen, screen[i - 1], screen[i]);
        foreach (var s in screen.Take(_measurePts.Count)) dc.DrawEllipse(Brushes.White, pen, s, 3, 3);

        // The value so far, by the pointer.
        var text = CurrentValue(includeHover: true);
        if (text.Length == 0) return;
        var ft = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12,
            Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        var at = screen[^1] + new Vector(14, 14);
        var box = new Rect(at.X - 6, at.Y - 3, ft.Width + 12, ft.Height + 6);
        dc.DrawRoundedRectangle(Frozen(new SolidColorBrush(Color.FromArgb(0xE6, 0x20, 0x20, 0x20))), null, box, 4, 4);
        dc.DrawText(ft, at);
    }
}
