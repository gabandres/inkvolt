using System.Media;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>
/// The Polygon and Polyline tools, as on the Mac: each click adds a corner (Shift: horizontal, vertical or at 45° from the
/// last); a double-click, Enter or (a polygon) a click on the first corner finishes it; Backspace takes a corner back; Esc
/// drops it. <see cref="VertexDraft"/> decides what a click does; the finished shape goes to the host as a
/// <see cref="DrawingRequest"/>, like every other drawing tool's.
/// </summary>
public sealed partial class PageViewer
{
    private const double ClosePx = 8; // how near the first corner (on screen) a click closes a polygon

    private VertexDraft? _vertices;
    private PointD? _vertexHover;

    /// <summary>The polygon or polyline being clicked, for the dev script: its page and corners.</summary>
    internal string? DevVerticesInProgress => _vertices is { IsActive: true } v ? $"p{v.Page + 1} {v.Points.Count} corners" : null;

    private void ClickVertex(int page, Point pt, int clicks)
    {
        var closed = _tool == ViewerTool.Polygon;
        if (_vertices is null || _vertices.Closed != closed) _vertices = new VertexDraft(closed);
        var p = new PointD(pt.X, pt.Y);
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0 && _vertices.Page == page && _vertices.Points.Count > 0)
            p = DrawingGeometry.SnapAngle(_vertices.Points[^1], p);
        Focus();
        _vertexHover = p; // the pointer is on the corner just clicked
        if (_vertices.Click(page, p, clicks, ClosePx / (_zoom * PtToDip))) FinishVertices();
        _surface.InvalidateVisual();
    }

    /// <summary>The shape clicked so far goes to the host; too few corners: a beep, and nothing is drawn.</summary>
    private void FinishVertices()
    {
        if (_vertices is not { IsActive: true } v || !DrawTools.IsVertexTool(_tool)) return;
        var page = v.Page;
        var tool = _tool;
        var points = v.Finish();
        _vertexHover = null;
        _surface.InvalidateVisual();
        if (points is null)
        {
            SystemSounds.Beep.Play();
            return;
        }
        var s = StyleFor(tool);
        var g = new AnnotGeometry { Paths = [points] };
        var id = Annotations.NewId();
        _pendingNew.Add((id, page, DrawTools.Subtype(tool), g, s));
        DrawingRequested?.Invoke(this, new DrawingRequest(id, page, tool, g, s));
    }

    private void CancelVertices()
    {
        if (_vertices is null && _vertexHover is null) return;
        _vertices?.Cancel();
        _vertexHover = null;
        _surface.InvalidateVisual();
    }

    /// <summary>The pointer's spot, for the segment to it.</summary>
    private void MoveVertexHover(Point sp)
    {
        if (_vertices is not { IsActive: true } v || !DrawTools.IsVertexTool(_tool)) return;
        var pt = ClampToPage(v.Page, ToPagePoint(v.Page, sp));
        var p = new PointD(pt.X, pt.Y);
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0 && v.Points.Count > 0) p = DrawingGeometry.SnapAngle(v.Points[^1], p);
        _vertexHover = p;
        _surface.InvalidateVisual();
    }

    /// <summary>Enter finishes, Esc drops, Backspace takes the last corner back. True if the key was used.</summary>
    private bool HandleVertexKey(KeyEventArgs e)
    {
        if (_vertices is not { IsActive: true } v || !DrawTools.IsVertexTool(_tool) || Keyboard.Modifiers != ModifierKeys.None) return false;
        switch (e.Key)
        {
            case Key.Enter:
                FinishVertices();
                return true;
            case Key.Escape:
                CancelVertices();
                return true;
            case Key.Back:
                v.Undo();
                if (!v.IsActive) _vertexHover = null;
                _surface.InvalidateVisual();
                return true;
        }
        return false;
    }

    private void PaintVertices(DrawingContext dc, int page)
    {
        if (_vertices is not { IsActive: true } v || v.Page != page || !DrawTools.IsVertexTool(_tool)) return;
        var s = StyleFor(_tool);
        List<PointD> pts = [.. v.Points];
        if (_vertexHover is { } h) pts.Add(h);
        var subtype = v.Closed && pts.Count >= 3 ? "Polygon" : "PolyLine";
        // In the tool's look, as it will be (a polyline's arrowheads only once it is drawn).
        DrawShape(dc, page, subtype, new AnnotGeometry { Paths = [pts] }, s with { StartEnding = LineEnding.None, EndEnding = LineEnding.None,
            Color = s.Color ?? AnnotStyle.Black, Width = s.Color is null ? 1 : s.Width }, 0.8);
        var accent = _highContrast ? SystemColors.HighlightBrush : TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.RoyalBlue;
        var handleFill = _highContrast ? SystemColors.WindowBrush : TryFindResource("ControlSolidFillColorDefaultBrush") as Brush ?? Brushes.White;
        var pen = Frozen(new Pen(accent, 1.5));
        for (var i = 0; i < v.Points.Count; i++)
        {
            // The first corner shows larger once a click there would close the polygon.
            var r = i == 0 && v.Closed && v.Points.Count >= 3 ? ClosePx / 2 + 1 : 3;
            var c = ToSurfacePoint(page, v.Points[i].X, v.Points[i].Y);
            dc.DrawEllipse(handleFill, pen, c, r, r);
        }
    }
}
