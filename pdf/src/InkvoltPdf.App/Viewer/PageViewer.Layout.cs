using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>
/// Rulers, guides, a grid and snapping (roadmap 4.19), an adapter (ADR 1): Core's <see cref="LayoutAids"/> says what the
/// rulers mark and where a guide dragged from one lands, <see cref="PageGuides"/> keeps the document's guides, and
/// <see cref="Snapper"/> what a point or box snaps to. This draws them, passes the pointer in, and gives the tools that
/// place things (Prepare Form, drawing, stamps and signatures, measuring) their snapping. Alt held: no snapping.
/// </summary>
public sealed partial class PageViewer
{
    /// <summary>How thick the rulers are (DIPs).</summary>
    private const double RulerSize = 20;

    private bool _showRulers, _showGrid;
    private PageGuides? _guides;
    private IReadOnlyList<SnapLine> _snapLines = [];
    private int _snapLinesPage = -1;

    private sealed record GuideDrag(Guide? Existing, bool TopRuler, Point Now);

    private GuideDrag? _guideDrag;

    /// <summary>The guides were added to, moved or cleared (the host says so, and refreshes its commands).</summary>
    public event EventHandler? GuidesChanged;

    /// <summary>The document's guides (kept on its session).</summary>
    public PageGuides? Guides
    {
        get => _guides;
        set
        {
            _guides = value;
            _surface.InvalidateVisual();
        }
    }

    public bool ShowRulers
    {
        get => _showRulers;
        set
        {
            _showRulers = value;
            _surface.InvalidateVisual();
        }
    }

    public bool ShowGrid
    {
        get => _showGrid;
        set
        {
            _showGrid = value;
            _surface.InvalidateVisual();
        }
    }

    public bool SnapToGuides { get; set; } = true;
    public bool SnapToGrid { get; set; } = true;
    public bool SnapToObjects { get; set; } = true;

    /// <summary>The grid's step, in points.</summary>
    public double GridStep { get; set; } = 18;

    /// <summary>The rulers' unit: one of <see cref="RulerUnit.Choices"/>.</summary>
    public string RulerUnitSetting { get; set; } = "auto";

    /// <summary>The unit the rulers count in on a page.</summary>
    public RulerUnit RulerUnitOn(int page) =>
        RulerUnit.For(RulerUnitSetting, RulerUnitSetting == "auto" ? MeasureScaleAt?.Invoke(page, new PointD(1, 1)) : null, RegionInfo.CurrentRegion.IsMetric); // Windows' region (a neutral culture has none of its own)

    // ───────────────────────────── Snapping ─────────────────────────────

    /// <summary>
    /// What a page snaps to now: its guides, the grid (shown and on) and other objects' edges and middles (Prepare Form's
    /// fields, else the form fields, comments, stamps and signatures), without <paramref name="without"/> (fields by id)
    /// and <paramref name="self"/> (the box being moved). Null: snapping is off, or Alt is held.
    /// </summary>
    internal Snapper? SnapperFor(int page, IReadOnlySet<string>? without = null, RectD? self = null)
    {
        if (_engine is null || page < 0 || page >= PageCount || (Keyboard.Modifiers & ModifierKeys.Alt) != 0) return null;
        var guides = SnapToGuides && _guides is not null ? _guides.On(page) : null;
        var grid = SnapToGrid && _showGrid ? GridStep : 0;
        List<RectD>? objects = null;
        if (SnapToObjects)
        {
            objects = [];
            if (IsDesigningForm) objects.AddRange(Designer.FieldsOnPage(page).Where(f => without is null || !without.Contains(f.Id)).Select(Designer.ShownRect));
            else
            {
                objects.AddRange(_widgetsByPage.GetValueOrDefault(page)?.Select(w => w.Rect) ?? []);
                objects.AddRange(_annotsByPage.GetValueOrDefault(page)?.Where(a => !a.Hidden).Select(a => a.Rect) ?? []);
                objects.AddRange(_sigStamps.GetValueOrDefault(page)?.Select(s => s.Rect) ?? []);
            }
            if (self is { } me) objects.RemoveAll(r => Math.Abs(r.X - me.X) < 0.01 && Math.Abs(r.Y - me.Y) < 0.01 && Math.Abs(r.Width - me.Width) < 0.01 && Math.Abs(r.Height - me.Height) < 0.01);
        }
        return Snapper.For(guides, objects, grid, LayoutAids.SnapPixels / (_zoom * PtToDip));
    }

    /// <summary>A page point snapped (what it snapped to is shown until the press ends).</summary>
    private Point SnapPoint(int page, Point pt, RectD? self = null)
    {
        if (SnapperFor(page, self: self) is not { } snap)
        {
            ShowSnapLines(page, []);
            return pt;
        }
        var q = snap.Point(new PointD(pt.X, pt.Y));
        ShowSnapLines(page, snap.Lines);
        return new Point(q.X, q.Y);
    }

    /// <summary>A box being moved, snapped by its edges or middle (<paramref name="self"/>: where it was, not a target).</summary>
    private RectD SnapMove(int page, RectD r, RectD self)
    {
        if (SnapperFor(page, self: self) is not { } snap)
        {
            ShowSnapLines(page, []);
            return r;
        }
        var moved = snap.Move(r);
        ShowSnapLines(page, snap.Lines);
        return moved;
    }

    private void ShowSnapLines(int page, IReadOnlyList<SnapLine> lines)
    {
        if (lines.Count == 0 && _snapLines.Count == 0) return;
        _snapLines = lines;
        _snapLinesPage = page;
        _surface.InvalidateVisual();
    }

    /// <summary>A press ended: what it snapped to isn't shown any more.</summary>
    private void ClearSnapLines() => ShowSnapLines(-1, []);

    // ───────────────────────────── Guides from the rulers ─────────────────────────────

    /// <summary>Which ruler a surface point is on (null: neither).</summary>
    private bool? RulerAt(Point sp)
    {
        if (!_showRulers) return null;
        var vp = Viewport;
        if (sp.Y - vp.Y < RulerSize && sp.Y >= vp.Y) return sp.X - vp.X >= RulerSize ? true : null;
        if (sp.X - vp.X < RulerSize && sp.X >= vp.X) return false;
        return null;
    }

    /// <summary>
    /// A press on a ruler starts a new guide; with the hand or select tool, a press on a guide picks it up (dropped on a
    /// ruler or off the page, it goes). True if it was one of these.
    /// </summary>
    private bool HandleRulerDown(MouseButtonEventArgs e, int page, Point sp)
    {
        if (e.ChangedButton != MouseButton.Left || _engine is null || _guides is null) return false;
        if (RulerAt(sp) is { } top)
        {
            _guideDrag = new GuideDrag(null, top, sp);
        }
        else if (_tool is ViewerTool.Hand or ViewerTool.SelectText && page >= 0 && GuideNear(page, sp) is { } g)
        {
            _guideDrag = new GuideDrag(g, LayoutAids.AcrossScreen(g.Axis, _viewRotation), sp);
        }
        else return false;
        e.Handled = true;
        _surface.CaptureMouse();
        _surface.InvalidateVisual();
        return true;
    }

    private Guide? GuideNear(int page, Point sp)
    {
        var pt = ToPagePoint(page, sp);
        return _guides?.At(page, new PointD(pt.X, pt.Y), 4 / (_zoom * PtToDip));
    }

    private bool MoveGuideDrag(Point sp)
    {
        if (_guideDrag is not { } d) return false;
        _guideDrag = d with { Now = sp };
        _surface.InvalidateVisual();
        return true;
    }

    private bool EndGuideDrag(Point sp)
    {
        if (_guideDrag is not { } d) return false;
        _guideDrag = null;
        _surface.InvalidateVisual();
        var page = d.Existing?.Page ?? HitPage(sp);
        if (_guides is null) return true;
        if (page < 0 || RulerAt(sp) is not null)
        {
            if (d.Existing is { } gone) _guides.Remove(gone); // dropped back on a ruler (or off the pages)
        }
        else
        {
            var g = _engine!.GetPage(page);
            var v = ToViewPoint(page, sp);
            if (d.Existing is { } existing)
            {
                var pt = ToPagePoint(page, sp);
                _guides.Move(existing, existing.Axis == GuideAxis.X ? pt.X : pt.Y, g.Width, g.Height);
            }
            else if (LayoutAids.FromRuler(page, d.TopRuler, d.TopRuler ? v.Y : v.X, g.Width, g.Height, _viewRotation) is { } guide)
                _guides.Add(guide, g.Width, g.Height);
        }
        GuidesChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    private Cursor? LayoutCursor(int page, Point sp)
    {
        if (RulerAt(sp) is { } top) return top ? Cursors.SizeNS : Cursors.SizeWE;
        if (_guides is not null && _tool is ViewerTool.Hand or ViewerTool.SelectText && page >= 0 && GuideNear(page, sp) is { } g)
            return LayoutAids.AcrossScreen(g.Axis, _viewRotation) ? Cursors.SizeNS : Cursors.SizeWE;
        return null;
    }

    // ───────────────────────────── Painting ─────────────────────────────

    private static readonly Brush GuideBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x00, 0xA8, 0xE8)));
    private static readonly Brush SnapBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xE0, 0x30, 0xC0)));

    /// <summary>A page's grid, guides and what a press snapped to.</summary>
    private void PaintLayout(DrawingContext dc, int page)
    {
        if (_engine is null) return;
        var g = _engine.GetPage(page);
        if (_showGrid && GridStep >= 1)
        {
            var (xs, ys) = LayoutAids.Grid(g.Width, g.Height, GridStep);
            // Not drawn when its lines would be closer than 4 DIPs.
            if (GridStep * _zoom * PtToDip >= 4)
            {
                var pen = Frozen(new Pen(_highContrast ? SystemColors.GrayTextBrush : new SolidColorBrush(Color.FromArgb(0x38, 0x40, 0x80, 0xC0)), 1));
                foreach (var x in xs) Line(dc, pen, page, GuideAxis.X, x);
                foreach (var y in ys) Line(dc, pen, page, GuideAxis.Y, y);
            }
        }
        if (_guides is not null)
        {
            var pen = Frozen(new Pen(_highContrast ? SystemColors.HighlightBrush : GuideBrush, 1));
            foreach (var guide in _guides.On(page))
                if (_guideDrag?.Existing != guide) Line(dc, pen, page, guide.Axis, guide.At);
        }
        if (_snapLinesPage == page || Designer.SnapLines.Count > 0 && Designer.PressPage == page)
        {
            var pen = Frozen(new Pen(_highContrast ? SystemColors.HighlightBrush : SnapBrush, 1) { DashStyle = DashStyles.Dash });
            foreach (var s in _snapLinesPage == page ? _snapLines : Designer.SnapLines) Line(dc, pen, page, s.Axis, s.At);
        }
    }

    private void Line(DrawingContext dc, Pen pen, int page, GuideAxis axis, double at)
    {
        var g = _engine!.GetPage(page);
        var r = ToSurfaceRect(page, axis == GuideAxis.X ? new RectD(at, 0, 0, g.Height) : new RectD(0, at, g.Width, 0));
        dc.DrawLine(pen, r.TopLeft, r.BottomRight);
    }

    /// <summary>The rulers along the top and left of the view, counting from the current page's top-left as shown, and a
    /// guide being dragged.</summary>
    private void PaintRulers(DrawingContext dc, Rect vp)
    {
        if (_engine is null || PageCount == 0) return;
        var po = _paintOrigin;
        var view = new Rect(vp.X - po.X, vp.Y - po.Y, vp.Width, vp.Height);
        if (_guideDrag is { } d)
        {
            var pen = Frozen(new Pen(_highContrast ? SystemColors.HighlightBrush : GuideBrush, 1) { DashStyle = DashStyles.Dash });
            var at = new Point(d.Now.X - po.X, d.Now.Y - po.Y);
            if (d.TopRuler) dc.DrawLine(pen, new Point(view.Left, at.Y), new Point(view.Right, at.Y));
            else dc.DrawLine(pen, new Point(at.X, view.Top), new Point(at.X, view.Bottom));
        }
        if (!_showRulers) return;
        var page = Math.Clamp(CurrentPage, 0, PageCount - 1);
        if (page >= _rects.Length) return;
        var pr = _rects[page];
        var origin = new Point(pr.X - po.X, pr.Y - po.Y);
        var k = _zoom * PtToDip;
        var unit = RulerUnitOn(page);
        var back = _highContrast ? SystemColors.WindowBrush : TryFindResource("SolidBackgroundFillColorQuarternaryBrush") as Brush ?? Brushes.WhiteSmoke;
        var ink = _highContrast ? SystemColors.WindowTextBrush : TryFindResource("TextFillColorSecondaryBrush") as Brush ?? Brushes.DimGray;
        var line = Frozen(new Pen(ink, 1));
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var top = new Rect(view.Left, view.Top, view.Width, RulerSize);
        var left = new Rect(view.Left, view.Top, RulerSize, view.Height);
        dc.DrawRectangle(back, null, top);
        dc.DrawRectangle(back, null, left);
        dc.DrawLine(line, top.BottomLeft, top.BottomRight);
        dc.DrawLine(line, left.TopRight, left.BottomRight);
        foreach (var t in LayoutAids.Ticks((top.Left + RulerSize - origin.X) / k, (top.Right - origin.X) / k, k, unit))
        {
            var x = origin.X + t.At * k;
            var len = t.Level switch { 0 => RulerSize * 0.6, 1 => RulerSize * 0.4, _ => RulerSize * 0.25 };
            dc.DrawLine(line, new Point(x, top.Bottom - len), new Point(x, top.Bottom));
            if (t.Label is { } label) dc.DrawText(RulerText(label, ink, dpi), new Point(x + 2, top.Top + 1));
        }
        foreach (var t in LayoutAids.Ticks((left.Top + RulerSize - origin.Y) / k, (left.Bottom - origin.Y) / k, k, unit))
        {
            var y = origin.Y + t.At * k;
            var len = t.Level switch { 0 => RulerSize * 0.6, 1 => RulerSize * 0.4, _ => RulerSize * 0.25 };
            dc.DrawLine(line, new Point(left.Right - len, y), new Point(left.Right, y));
            if (t.Label is { } label)
            {
                dc.PushTransform(new RotateTransform(-90, left.Left + 2, y - 2));
                dc.DrawText(RulerText(label, ink, dpi), new Point(left.Left + 2, y - 2));
                dc.Pop();
            }
        }
        // The corner: the unit.
        var corner = new Rect(view.Left, view.Top, RulerSize, RulerSize);
        dc.DrawRectangle(back, null, corner);
        var name = RulerText(unit.Name, ink, dpi);
        dc.DrawText(name, new Point(corner.Left + (RulerSize - name.Width) / 2, corner.Top + (RulerSize - name.Height) / 2));
    }

    private static FormattedText RulerText(string text, Brush brush, double dpi) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 9, brush, dpi);

    // ───────────────────────────── Dev entries ─────────────────────────────

    /// <summary>DevScript's guide: a guide dragged from the top (or left) ruler onto a page, at a point of the page as shown.</summary>
    internal bool DevAddGuide(int page, bool topRuler, double viewPos)
    {
        if (_guides is null || _engine is null) return false;
        var g = _engine.GetPage(page);
        if (LayoutAids.FromRuler(page, topRuler, viewPos, g.Width, g.Height, _viewRotation) is not { } guide || !_guides.Add(guide, g.Width, g.Height)) return false;
        _surface.InvalidateVisual();
        GuidesChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>DevScript's snappoint: what a page point snaps to now.</summary>
    internal string DevSnap(int page, double x, double y)
    {
        var snap = SnapperFor(page);
        if (snap is null) return "snap: off";
        var p = snap.Point(new PointD(x, y));
        return $"snap: {x:0.##},{y:0.##} → {p.X:0.##},{p.Y:0.##} lines {string.Join(" ", snap.Lines.Select(l => $"{l.Axis}={l.At:0.##}"))}";
    }
}
