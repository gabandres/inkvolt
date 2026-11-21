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
/// for that spot (<see cref="MeasureScaleAt"/>); the host turns each finished measurement into an annotation. Core's
/// <see cref="MeasureDraft"/> decides what each click, move and key does; this turns the mouse and keys into its inputs
/// and draws its <see cref="MeasureDraft.Sketch"/>.
/// </summary>
public sealed partial class PageViewer
{
    private MeasureDraft? _measure;

    /// <summary>The scale at a point of a page (the page's viewport there, else the one the user set).</summary>
    public Func<int, PointD, MeasureScale>? MeasureScaleAt { get; set; }

    public event EventHandler<MeasureRequest>? MeasureRequested;

    public static bool IsMeasureTool(ViewerTool tool) => MeasureToolOf(tool) is not null;

    private static MeasureTool? MeasureToolOf(ViewerTool tool) => tool switch
    {
        ViewerTool.MeasureDistance => MeasureTool.Distance,
        ViewerTool.MeasurePerimeter => MeasureTool.Perimeter,
        ViewerTool.MeasureArea => MeasureTool.Area,
        ViewerTool.MeasureCalibrate => MeasureTool.Calibrate,
        _ => null,
    };

    /// <summary>The measurement of the current tool (a new one once the tool is another), or null for a tool that doesn't measure.</summary>
    private MeasureDraft? ActiveMeasure =>
        MeasureToolOf(_tool) is not { } tool ? null
        : _measure is { } m && m.Tool == tool ? m
        : _measure = new MeasureDraft(tool);

    private static bool ShiftDown => (Keyboard.Modifiers & ModifierKeys.Shift) != 0;

    /// <summary>The measurement under way, for the dev script and screen readers: its points and value.</summary>
    public string? MeasureInProgress => _measure is { } m ? m.Described(ScaleOf(m)) : null;

    private MeasureScale ScaleOf(MeasureDraft m) =>
        m.ScalePoint is { } at ? MeasureScaleAt?.Invoke(m.Page, at) ?? MeasureScale.Default : MeasureScale.Default;

    private void CancelMeasure()
    {
        if (_measure is not { } m || (!m.IsActive && m.Hover is null)) return;
        m.Cancel();
        _surface.InvalidateVisual();
    }

    private bool HandleMeasureDown(MouseButtonEventArgs e, int page, Point sp)
    {
        if (ActiveMeasure is not { } m || e.ChangedButton != MouseButton.Left || _engine is null) return false;
        e.Handled = true;
        _pressLink = null; // measuring over a link doesn't follow it
        Focus();
        if (page < 0) return true;
        var pt = ClampToPage(page, ToPagePoint(page, sp));
        if (m.Click(page, new PointD(pt.X, pt.Y), e.ClickCount, ShiftDown) is { } done) Finished(done);
        _surface.InvalidateVisual();
        return true;
    }

    private bool MoveMeasure(Point sp)
    {
        if (ActiveMeasure is not { IsActive: true } m) return false;
        // The pointer is kept on the page being measured, wherever it is.
        var pt = ClampToPage(m.Page, ToPagePoint(m.Page, sp));
        m.Move(m.Page, new PointD(pt.X, pt.Y), ShiftDown);
        _surface.InvalidateVisual();
        return true;
    }

    private bool HandleMeasureKey(KeyEventArgs e)
    {
        if (ActiveMeasure is not { } m) return false;
        switch (e.Key)
        {
            case Key.Escape when m.IsActive:
                CancelMeasure();
                return true;
            case Key.Escape:
                Tool = ViewerTool.Hand;
                return true;
            case Key.Enter when m.IsActive:
                if (m.Finish() is { } done) Finished(done);
                return true;
            case Key.Back when m.Points.Count > 0:
                m.RemoveLast();
                _surface.InvalidateVisual();
                return true;
        }
        return false;
    }

    private void Finished(MeasureDone done)
    {
        _surface.InvalidateVisual();
        MeasureRequested?.Invoke(this, new MeasureRequest(done.Page, _tool, done.Points));
    }

    /// <summary>For the dev script: a measurement as if clicked, a point a click (and Enter when the clicks didn't end it).</summary>
    internal void DevMeasure(int page, ViewerTool tool, IReadOnlyList<PointD> points)
    {
        var draft = new MeasureDraft(MeasureToolOf(tool) ?? MeasureTool.Distance);
        MeasureDone? done = null;
        foreach (var p in points) done = draft.Click(page, p) ?? done;
        if ((done ?? draft.Finish()) is { } d) MeasureRequested?.Invoke(this, new MeasureRequest(d.Page, tool, d.Points));
    }

    private void PaintMeasure(DrawingContext dc, int page)
    {
        if (_measure is not { Sketch: { } sketch } m || sketch.Page != page) return;
        var color = Color.FromRgb(0xCC, 0x1A, 0x1A);
        var pen = Frozen(new Pen(Frozen(new SolidColorBrush(color)), 1.5));
        var dashed = Frozen(new Pen(Frozen(new SolidColorBrush(color)), 1) { DashStyle = DashStyles.Dash });
        var screen = sketch.Points.Select(p => ToSurfacePoint(page, p.X, p.Y)).ToList();
        if (sketch.Filled)
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
        foreach (var s in screen.Take(sketch.Corners)) dc.DrawEllipse(Brushes.White, pen, s, 3, 3);

        // The value so far, by the pointer.
        var text = m.Value(ScaleOf(m));
        if (text.Length == 0) return;
        var ft = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12,
            Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        var at = screen[^1] + new Vector(14, 14);
        var box = new Rect(at.X - 6, at.Y - 3, ft.Width + 12, ft.Height + 6);
        dc.DrawRoundedRectangle(Frozen(new SolidColorBrush(Color.FromArgb(0xE6, 0x20, 0x20, 0x20))), null, box, 4, 4);
        dc.DrawText(ft, at);
    }
}
