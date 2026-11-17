namespace InkvoltPdf.Core;

/// <summary>
/// A polygon or polyline being clicked (the Polygon and Polyline tools, as on the Mac): each click adds a corner on one
/// page; a double-click, a click on the first corner (a polygon of three corners or more) or Enter finishes it; Esc drops
/// it; Backspace takes the last corner back. Page space. The page view keeps one and asks it what a click does.
/// </summary>
public sealed class VertexDraft(bool closed)
{
    /// <summary>The most corners one drawing takes (a hostile flood of clicks or a script stops here).</summary>
    public const int MaxVertices = 10_000;

    private readonly List<PointD> _points = [];

    /// <summary>A polygon (closed) rather than a polyline.</summary>
    public bool Closed { get; } = closed;

    /// <summary>The page being drawn on; -1 when nothing is under way.</summary>
    public int Page { get; private set; } = -1;

    public IReadOnlyList<PointD> Points => _points;

    public bool IsActive => Page >= 0;

    /// <summary>The fewest corners the drawing needs: 3 for a polygon, 2 for a polyline.</summary>
    public int Needed => Closed ? 3 : 2;

    /// <summary>
    /// A click at <paramref name="p"/> on <paramref name="page"/> (<paramref name="clicks"/>: 2 for a double-click's second
    /// press). <paramref name="closeDistance"/>: how near the first corner (page points, across plus down) a click closes a
    /// polygon. True when the drawing is finished: take it with <see cref="Finish"/>. A click on another page starts over there;
    /// a double-click's later presses never start one.
    /// </summary>
    public bool Click(int page, PointD p, int clicks, double closeDistance)
    {
        if (page < 0 || !double.IsFinite(p.X) || !double.IsFinite(p.Y)) return false;
        // The rest of a double- or triple-click whose first press finished a drawing doesn't start another.
        if (clicks >= 2 && Page != page) return false;
        if (Page != page)
        {
            Page = page;
            _points.Clear();
            _points.Add(p);
            return false;
        }
        if (clicks >= 2) return true;
        if (Closed && _points.Count >= 3 && Math.Abs(_points[0].X - p.X) + Math.Abs(_points[0].Y - p.Y) <= closeDistance) return true;
        if (_points.Count < MaxVertices) _points.Add(p);
        return _points.Count >= MaxVertices;
    }

    /// <summary>
    /// Ends the drawing: its corners, or null when there are too few (it is dropped either way). A last corner on top of
    /// the one before (a double-click's first press) is left out.
    /// </summary>
    public IReadOnlyList<PointD>? Finish()
    {
        var points = _points.ToList();
        Cancel();
        if (points.Count >= 2 && Math.Abs(points[^1].X - points[^2].X) + Math.Abs(points[^1].Y - points[^2].Y) < 0.5)
            points.RemoveAt(points.Count - 1);
        return points.Count >= Needed ? points : null;
    }

    /// <summary>Takes the last corner back; the drawing ends with its first. False when nothing is under way.</summary>
    public bool Undo()
    {
        if (!IsActive) return false;
        _points.RemoveAt(_points.Count - 1);
        if (_points.Count == 0) Cancel();
        return true;
    }

    /// <summary>Drops the drawing.</summary>
    public void Cancel()
    {
        Page = -1;
        _points.Clear();
    }
}
