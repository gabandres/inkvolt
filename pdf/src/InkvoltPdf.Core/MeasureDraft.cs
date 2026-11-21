namespace InkvoltPdf.Core;

/// <summary>What a measuring tool measures: a distance, a perimeter, an area, or a distance whose real length sets the scale.</summary>
public enum MeasureTool { Distance, Perimeter, Area, Calibrate }

/// <summary>A measurement clicked to its end: the page and its points (page space), for the host to make it a comment.</summary>
public sealed record MeasureDone(int Page, IReadOnlyList<PointD> Points);

/// <summary>
/// What the page view draws for a measurement under way: the points clicked and the pointer's spot after them, joined;
/// a dot on each of the first <paramref name="Corners"/>; an area of three points or more <paramref name="Filled"/>, its
/// closing side dashed.
/// </summary>
public sealed record MeasureSketch(int Page, IReadOnlyList<PointD> Points, int Corners, bool Filled);

/// <summary>
/// A measurement under way (the glossary's "Measuring scale"): the points clicked on one page and where the pointer is.
/// A distance (or calibration) ends at its second click; a perimeter or an area at a double-click or <see cref="Finish"/>
/// (Enter) once it has enough points; <see cref="RemoveLast"/> (Backspace) takes a point back and <see cref="Cancel"/>
/// (Esc) drops it. Shift keeps the next segment horizontal, vertical or at 45°. Points are page space, already kept on the
/// page by the caller. <c>PageViewer.Measure</c> feeds it clicks, moves and keys and draws <see cref="Sketch"/>; the Mac's
/// <c>MeasureDraft</c> (PdfCore) is the same. Not a <see cref="VertexDraft"/>: a measurement keeps going when Enter comes
/// too early, a double-click's second press never adds a point, and a click on its first point doesn't close it; only
/// the bound on points (<see cref="VertexDraft.MaxVertices"/>) is shared.
/// </summary>
public sealed class MeasureDraft(MeasureTool tool)
{
    private readonly List<PointD> _points = [];

    public MeasureTool Tool { get; } = tool;

    /// <summary>What the value is: a calibration measures a distance.</summary>
    public MeasureKind Kind => KindOf(Tool);

    /// <summary>The page being measured; -1 while nothing is under way.</summary>
    public int Page { get; private set; } = -1;

    public IReadOnlyList<PointD> Points => _points;

    /// <summary>Where the pointer is (the next point if clicked), on <see cref="Page"/>.</summary>
    public PointD? Hover { get; private set; }

    public bool IsActive => Page >= 0;

    /// <summary>Points a finished measurement needs.</summary>
    public int Needed => Tool == MeasureTool.Area ? 3 : 2;

    public static MeasureKind KindOf(MeasureTool tool) => tool switch
    {
        MeasureTool.Perimeter => MeasureKind.Perimeter,
        MeasureTool.Area => MeasureKind.Area,
        _ => MeasureKind.Distance,
    };

    /// <summary>With Shift, the new point lies horizontally, vertically or at 45° from the last one.</summary>
    private PointD Snap(PointD p, bool shift) => shift && _points.Count > 0 ? DrawingGeometry.SnapAngle(_points[^1], p) : p;

    /// <summary>
    /// A click at <paramref name="p"/> on <paramref name="page"/> (<paramref name="clicks"/> 2 for a double-click's second
    /// press). The finished measurement when the click ends it, else null. A click on another page starts over there; a
    /// point on top of the last one isn't another.
    /// </summary>
    public MeasureDone? Click(int page, PointD p, int clicks = 1, bool shift = false)
    {
        if (page < 0 || !double.IsFinite(p.X) || !double.IsFinite(p.Y)) return null;
        if (IsActive && page != Page) Cancel();
        var q = Snap(p, shift);
        if (!IsActive)
        {
            Page = page;
            _points.Clear();
        }
        // A double-click finishes a perimeter or area (its second press lands on the point just added).
        if (clicks >= 2 && Kind != MeasureKind.Distance) return Finish();
        if ((_points.Count == 0 || MeasureGeometry.Distance(_points[^1], q) > 0.01) && _points.Count < VertexDraft.MaxVertices) _points.Add(q);
        return Kind == MeasureKind.Distance && _points.Count == 2 ? Finish() : null;
    }

    /// <summary>
    /// The pointer moved to <paramref name="p"/> on <paramref name="page"/>. False, and ignored, unless a measurement is under
    /// way there. (Windows' page view passes the page being measured, the pointer kept on it, wherever the pointer is.)
    /// </summary>
    public bool Move(int page, PointD p, bool shift = false)
    {
        if (!IsActive || page != Page || !double.IsFinite(p.X) || !double.IsFinite(p.Y)) return false;
        Hover = Snap(p, shift);
        return true;
    }

    /// <summary>Enter: the measurement when it has enough points (it is then over), else null and it goes on.</summary>
    public MeasureDone? Finish()
    {
        if (Page < 0 || _points.Count < Needed) return null;
        var done = new MeasureDone(Page, [.. _points]);
        Cancel();
        return done;
    }

    /// <summary>Backspace: the last point taken back (none left: nothing is under way). False when there was none.</summary>
    public bool RemoveLast()
    {
        if (_points.Count == 0) return false;
        _points.RemoveAt(_points.Count - 1);
        if (_points.Count == 0) Cancel();
        return true;
    }

    /// <summary>Esc: drops the measurement.</summary>
    public void Cancel()
    {
        Page = -1;
        _points.Clear();
        Hover = null;
    }

    /// <summary>Where the scale is read (a page can have several): the first point, else the pointer's spot.</summary>
    public PointD? ScalePoint => _points.Count > 0 ? _points[0] : Hover;

    /// <summary>
    /// The value so far at <paramref name="scale"/> ("12.50 ft"; an area with its perimeter), the pointer's spot as the
    /// next point when <paramref name="includeHover"/>; "" while nothing is under way.
    /// </summary>
    public string Value(MeasureScale scale, bool includeHover = true)
    {
        if (!IsActive) return "";
        List<PointD> pts = [.. _points];
        if (includeHover && Hover is { } h) pts.Add(h);
        if (pts.Count == 0) return "";
        if (Kind == MeasureKind.Area && pts.Count >= 3)
            return Loc.Format(PdfStrings.Measure_AreaPerimeter, scale.Format(MeasureKind.Area, pts),
                scale.FormatValue(MeasureKind.Perimeter, MeasureGeometry.Length(pts, closed: true) * scale.PerUnit));
        return scale.Format(MeasureKind.Distance, pts);
    }

    /// <summary>How many points and the value without the pointer (screen readers, the dev script); null while nothing is under way.</summary>
    public string? Described(MeasureScale scale) =>
        IsActive ? Loc.Format(PdfStrings.Measure_DraftPoints, _points.Count, Value(scale, includeHover: false)) : null;

    /// <summary>What to draw now, or null when there is nothing (no point clicked yet).</summary>
    public MeasureSketch? Sketch
    {
        get
        {
            if (!IsActive || _points.Count == 0) return null;
            List<PointD> pts = [.. _points];
            if (Hover is { } h) pts.Add(h);
            return new MeasureSketch(Page, pts, _points.Count, Kind == MeasureKind.Area && pts.Count >= 3);
        }
    }
}
