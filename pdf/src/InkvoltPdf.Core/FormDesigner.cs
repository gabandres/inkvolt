namespace InkvoltPdf.Core;

/// <summary>A field drawn with a field tool of Prepare Form (page space).</summary>
public sealed record DesignPlacement(DesignFieldKind Kind, int PageIndex, RectD Rect);

/// <summary>What the user asked for on the selected field or suggestion.</summary>
public enum DesignAction { Delete, Duplicate, Properties, Accept, Reject }

/// <summary>What a press on the page asks of the window.</summary>
public enum DesignPress
{
    /// <summary>Nothing more than what the designer did itself (started a drag or a new field, or nothing).</summary>
    None,

    /// <summary>A click on a field or suggestion selected it (Windows tells the panel even when it was selected already;
    /// the Mac's <c>.none</c> covers it).</summary>
    Selected,

    /// <summary>A double-click on a field: open its properties.</summary>
    Properties,

    /// <summary>A double-click on a suggestion: add it.</summary>
    Accept,

    /// <summary>An empty spot: scroll with the pointer, as with the hand tool.</summary>
    Pan,
}

/// <summary>What a finished press hands over: a new field, or a field with its new <see cref="DesignField.Rect"/>.</summary>
public abstract record DesignRelease
{
    private DesignRelease() { }

    public sealed record Placed(DesignPlacement Placement) : DesignRelease;

    public sealed record Moved(DesignField Field) : DesignRelease;
}

public enum DesignCursorKind { Arrow, Crosshair, Move, PointingHand, Resize }

/// <summary>What the pointer shows; <see cref="Handle"/>: the handle of a <see cref="DesignCursorKind.Resize"/> (0-7,
/// <see cref="DrawingGeometry"/>, as the page is shown).</summary>
public readonly record struct DesignCursor(DesignCursorKind Kind, int Handle = -1)
{
    public static DesignCursor Arrow => new(DesignCursorKind.Arrow);
    public static DesignCursor Crosshair => new(DesignCursorKind.Crosshair);
    public static DesignCursor Move => new(DesignCursorKind.Move);
    public static DesignCursor PointingHand => new(DesignCursorKind.PointingHand);
    public static DesignCursor Resize(int handle) => new(DesignCursorKind.Resize, handle);
}

/// <summary>What Esc does.</summary>
public enum DesignEscape { DroppedTool, Deselected, Leave }

/// <summary>The keys Prepare Form acts on.</summary>
public enum DesignKey { Tab, Delete, Backspace, Enter, D, Left, Right, Up, Down, Escape }

[Flags]
public enum DesignModifiers { None = 0, Shift = 1, Control = 2, Alt = 4, Windows = 8 }

/// <summary>Where a selection is, to bring it into view.</summary>
public readonly record struct DesignReveal(int Page, RectD Rect);

/// <summary>
/// What a key did: <see cref="Written"/>, the arrow-key moves made so far, to write first; then the action the window
/// runs, what Esc did, where Tab went, or that arrows moved the selection (<see cref="Nudged"/>: write it once the keys
/// rest, <see cref="FormDesigner.NudgeRest"/>).
/// </summary>
public sealed record DesignKeyResult(DesignField? Written = null, DesignAction? Action = null, DesignEscape? Escape = null, DesignReveal? Reveal = null, bool Nudged = false);

/// <summary>A page as the designer sees it: its size in points (unturned) and the view's turn (0, 90, 180, 270).</summary>
public readonly record struct DesignPage(double Width, double Height, int Rotation = 0);

/// <summary>
/// Prepare Form's state on top of the page view (ADR 1: the rules, here so they are tested; <c>PageViewer.FormDesign</c>
/// only draws what it says and passes on the mouse and keys; the Mac's <c>FormDesigner</c> is the spec). Every form field
/// shows as a named box; with a field tool (<see cref="Kind"/>) a drag (or a click, for the kind's usual size) places a
/// new field; with none, a click selects a field, a drag moves it, its handles resize it, arrow keys nudge it (Shift:
/// 10 pt; written once the keys rest), Tab / Shift+Tab go through the fields and suggestions, Enter opens the properties
/// (accepts a suggestion), Delete removes it (rejects a suggestion), Ctrl+D duplicates it, Esc lets go. Suggested fields
/// show dashed until accepted. The window turns each gesture into an edit (<see cref="FormDesign"/>).
/// <para>Unlike the Mac, Windows' handles, resizing and arrow keys follow the view's turn (<see cref="DesignPage.Rotation"/>):
/// the bottom-right handle is the one shown there, and Right moves the field right on screen.</para>
/// </summary>
public sealed class FormDesigner(Func<int, DesignPage> page)
{
    /// <summary>How long the arrow keys rest before their moves are written.</summary>
    public static readonly TimeSpan NudgeRest = TimeSpan.FromMilliseconds(450);

    /// <summary>The smallest side a resize leaves, and a drawn box must have to be kept (else the kind's usual size).</summary>
    public const double MinSize = 6;

    private sealed record Drag(DesignField Field, int Handle, PointD Press, PointD Offset, RectD Rect, bool Dragged);

    private sealed record NewBox(int Page, PointD Start, PointD End, bool Dragged);

    private Dictionary<int, List<DesignField>> _byPage = [];
    private List<DesignField> _fields = [];
    private List<FieldSuggestion> _suggestions = [];
    private int _suggestionIndex = -1;
    private readonly Dictionary<string, RectD> _pending = []; // where moved fields show until the document catches up
    private PointD _nudged;
    private Drag? _drag;
    private NewBox? _box;

    /// <summary>The fields in fill order, page by page.</summary>
    public IReadOnlyList<DesignField> Fields => _fields;

    public IReadOnlyList<FieldSuggestion> Suggestions => _suggestions;
    public string? SelectedId { get; private set; }

    /// <summary>The field tool; null selects and moves fields.</summary>
    public DesignFieldKind? Kind { get; set; }

    /// <summary>Numbers each field with its place in the fill (Tab) order.</summary>
    public bool ShowTabOrder { get; set; }

    public DesignField? SelectedField => SelectedId is null ? null : _fields.FirstOrDefault(f => f.Id == SelectedId);
    public FieldSuggestion? SelectedSuggestion => _suggestionIndex >= 0 && _suggestionIndex < _suggestions.Count ? _suggestions[_suggestionIndex] : null;
    public int SelectedSuggestionIndex => SelectedSuggestion is null ? -1 : _suggestionIndex;
    public bool IsDragging => _drag is not null || _box is not null;
    public bool HasNudge => _nudged != default;

    /// <summary>The rectangle being drawn for a new field, on its page.</summary>
    public (int Page, RectD Rect)? NewBoxRect => _box is { } b ? (b.Page, RectD.FromEdges(b.Start.X, b.Start.Y, b.End.X, b.End.Y)) : null;

    public IReadOnlyList<DesignField> FieldsOnPage(int pageIndex) => _byPage.TryGetValue(pageIndex, out var list) ? list : [];

    public void SetFields(IReadOnlyList<DesignField> list)
    {
        _byPage = list.GroupBy(f => f.PageIndex).ToDictionary(g => g.Key, g => g.ToList());
        _fields = [.. list.OrderBy(f => f.PageIndex).ThenBy(f => f.TabIndex)];
        _pending.Clear();
        if (SelectedId is { } id && !list.Any(f => f.Id == id)) SelectedId = null;
    }

    public void SetSuggestions(IReadOnlyList<FieldSuggestion> list)
    {
        var selected = SelectedSuggestion;
        _suggestions = [.. list];
        _suggestionIndex = selected is null ? -1 : _suggestions.IndexOf(selected);
    }

    /// <summary>Selects a field (null: none); the caller flushes any nudge first.</summary>
    public void Select(string? id)
    {
        SelectedId = id;
        _suggestionIndex = -1;
    }

    public void SelectSuggestion(int index)
    {
        _suggestionIndex = index >= 0 && index < _suggestions.Count ? index : -1;
        if (_suggestionIndex >= 0) SelectedId = null;
    }

    /// <summary>Leaving Prepare Form: nothing stays selected, no tool, no suggestions, no numbers. The caller flushes any nudge first.</summary>
    public void Reset()
    {
        _drag = null;
        _box = null;
        _nudged = default;
        Kind = null;
        SelectedId = null;
        _suggestionIndex = -1;
        _suggestions = [];
        ShowTabOrder = false;
    }

    /// <summary>Where a field shows: its rect, or the one it was just moved to (until the document catches up).</summary>
    public RectD ShownRect(DesignField f)
    {
        var r = _pending.TryGetValue(f.Id, out var p) ? p : f.Rect;
        if (_drag is { } d && d.Field.Id == f.Id) r = d.Rect;
        if (SelectedId == f.Id && HasNudge) r = r with { X = r.X + _nudged.X, Y = r.Y + _nudged.Y };
        return r;
    }

    /// <summary>The smallest field under a point of a page.</summary>
    public DesignField? FieldAt(int pageIndex, PointD p) =>
        FieldsOnPage(pageIndex).Where(f => ShownRect(f).Inflate(2).Contains(p.X, p.Y)).MinBy(f => f.Rect.Width * f.Rect.Height);

    /// <summary>The last suggestion under a point of a page, or -1.</summary>
    public int SuggestionAt(int pageIndex, PointD p) =>
        _suggestions.FindLastIndex(s => s.PageIndex == pageIndex && s.Rect.Inflate(2).Contains(p.X, p.Y));

    /// <summary>
    /// The resize handle of the selected field under a point (0-7, <see cref="DrawingGeometry"/>, numbered as the page is
    /// shown), or -1. <paramref name="reach"/>: how near counts, in points (what a handle's size is at the zoom shown).
    /// </summary>
    public int HandleAt(int pageIndex, PointD p, double reach)
    {
        if (SelectedField is not { } f || f.PageIndex != pageIndex || f.Signed) return -1;
        var g = page(pageIndex);
        var frame = RotatedView.ToView(ShownRect(f), g.Width, g.Height, g.Rotation);
        var v = ToView(p, g);
        for (var i = 0; i < 8; i++)
        {
            var h = DrawingGeometry.HandlePoint(frame, i);
            if (Math.Abs(h.X - v.X) <= reach && Math.Abs(h.Y - v.Y) <= reach) return i;
        }
        return -1;
    }

    public DesignCursor Cursor(int pageIndex, PointD p, double reach)
    {
        if (HandleAt(pageIndex, p, reach) is var h and >= 0) return DesignCursor.Resize(h);
        if (Kind is not null) return DesignCursor.Crosshair;
        if (FieldAt(pageIndex, p) is { } f) return f.Signed ? DesignCursor.Arrow : DesignCursor.Move;
        return SuggestionAt(pageIndex, p) >= 0 ? DesignCursor.PointingHand : DesignCursor.Arrow;
    }

    // ───────────────────────────── Mouse ─────────────────────────────

    /// <summary>
    /// A press at <paramref name="p"/> (page space): selects, starts moving or resizing, or starts a new field. The caller
    /// flushes any nudge first.
    /// </summary>
    public DesignPress Press(int pageIndex, PointD p, int clicks, double reach)
    {
        if (HandleAt(pageIndex, p, reach) is var h and >= 0 && SelectedField is { } selected)
        {
            StartDrag(selected, h, p);
            return DesignPress.None;
        }
        if (Kind is null && FieldAt(pageIndex, p) is { } hit)
        {
            Select(hit.Id);
            if (clicks >= 2) return DesignPress.Properties;
            if (!hit.Signed) StartDrag(hit, -1, p);
            return DesignPress.Selected;
        }
        if (Kind is null && SuggestionAt(pageIndex, p) is var s and >= 0)
        {
            SelectSuggestion(s);
            return clicks >= 2 ? DesignPress.Accept : DesignPress.Selected;
        }
        if (Kind is not null)
        {
            var start = OnPage(pageIndex, p);
            _box = new NewBox(pageIndex, start, start, false);
            return DesignPress.None;
        }
        Select(null);
        return DesignPress.Pan;
    }

    private void StartDrag(DesignField f, int handle, PointD p)
    {
        var offset = default(PointD);
        if (handle >= 0)
        {
            // The handle sits on the frame: keep the pointer's offset from it, so the frame doesn't jump.
            var g = page(f.PageIndex);
            var h = DrawingGeometry.HandlePoint(RotatedView.ToView(ShownRect(f), g.Width, g.Height, g.Rotation), handle);
            var v = ToView(p, g);
            offset = new PointD(h.X - v.X, h.Y - v.Y);
        }
        _drag = new Drag(f, handle, p, offset, ShownRect(f), false);
    }

    /// <summary>
    /// The pointer moved to <paramref name="p"/> (page space) with the button down. <paramref name="dragged"/>: it has gone
    /// far enough to count as a drag (Windows' viewer decides that for every tool, 3 DIPs; the Mac passes a threshold in
    /// points). <paramref name="shift"/> keeps a corner resize's proportions. True when it was the designer's press.
    /// </summary>
    public bool Move(PointD p, bool shift, bool dragged)
    {
        if (_box is { } b)
        {
            _box = b with { End = OnPage(b.Page, p), Dragged = b.Dragged || dragged };
            return true;
        }
        if (_drag is not { } d) return false;
        if (dragged) d = d with { Dragged = true };
        if (!d.Dragged)
        {
            _drag = d;
            return true;
        }
        var g = page(d.Field.PageIndex);
        var start = _pending.TryGetValue(d.Field.Id, out var pend) ? pend : d.Field.Rect;
        RectD r;
        if (d.Handle < 0)
        {
            var (dx, dy) = DrawingGeometry.ClampMove(start, p.X - d.Press.X, p.Y - d.Press.Y, g.Width, g.Height);
            r = start with { X = start.X + dx, Y = start.Y + dy };
        }
        else
        {
            // Resize in the page as shown (the handles follow the view's turn), then back to page space.
            var v = ToView(p, g);
            var (vw, vh) = RotatedView.Size(g.Width, g.Height, g.Rotation);
            var to = new PointD(Math.Clamp(v.X + d.Offset.X, 0, vw), Math.Clamp(v.Y + d.Offset.Y, 0, vh));
            var toggle = d.Field.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio;
            var view = RotatedView.ToView(start, g.Width, g.Height, g.Rotation);
            var sized = DrawingGeometry.Resize(view, d.Handle, to, MinSize, keepAspect: toggle || shift);
            r = RotatedView.FromView(sized, g.Width, g.Height, g.Rotation);
        }
        _drag = d with { Rect = r };
        return true;
    }

    /// <summary>
    /// The press ended: the new field or the moved one to write, if any. A short press with a field tool places the kind's
    /// usual size, its top-left at the pointer, kept on the page; check boxes and radio buttons stay square.
    /// </summary>
    public DesignRelease? Release()
    {
        if (_box is { } b)
        {
            _box = null;
            var kind = Kind ?? DesignFieldKind.Text;
            var rect = RectD.FromEdges(b.Start.X, b.Start.Y, b.End.X, b.End.Y);
            if (!b.Dragged || rect.Width < MinSize || rect.Height < MinSize)
            {
                var (w, h) = DefaultSize(kind);
                var g = page(b.Page);
                rect = new RectD(Math.Clamp(b.Start.X, 0, Math.Max(0, g.Width - w)), Math.Clamp(b.Start.Y, 0, Math.Max(0, g.Height - h)), w, h);
            }
            else if (kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio)
            {
                var side = Math.Min(rect.Width, rect.Height);
                rect = rect with { Width = side, Height = side };
            }
            return new DesignRelease.Placed(new DesignPlacement(kind, b.Page, rect));
        }
        if (_drag is not { } d) return null;
        _drag = null;
        var before = _pending.TryGetValue(d.Field.Id, out var p) ? p : d.Field.Rect;
        if (!d.Dragged || d.Rect == before) return null;
        _pending[d.Field.Id] = d.Rect;
        return new DesignRelease.Moved(d.Field with { Rect = d.Rect });
    }

    public void CancelDrag()
    {
        _drag = null;
        _box = null;
    }

    /// <summary>A new field's size when placed with a click (points).</summary>
    public static (double Width, double Height) DefaultSize(DesignFieldKind kind) => kind switch
    {
        DesignFieldKind.CheckBox or DesignFieldKind.Radio => (14, 14),
        DesignFieldKind.ComboBox => (140, 20),
        DesignFieldKind.ListBox => (140, 60),
        DesignFieldKind.Signature => (180, 40),
        DesignFieldKind.Button => (80, 24),
        _ => (160, 20),
    };

    // ───────────────────────────── Keys ─────────────────────────────

    /// <summary>What <paramref name="key"/> does in Prepare Form; null when it isn't Prepare Form's (it goes on to the view).</summary>
    public DesignKeyResult? Key(DesignKey key, DesignModifiers mods)
    {
        var field = SelectedField;
        var suggestion = SelectedSuggestion;
        switch (key)
        {
            case DesignKey.Tab when (mods & ~DesignModifiers.Shift) == 0:
            {
                var written = FlushNudge();
                return new DesignKeyResult(written, Reveal: Step((mods & DesignModifiers.Shift) != 0 ? -1 : 1));
            }
            case DesignKey.Delete or DesignKey.Backspace when mods == DesignModifiers.None && (field is { Signed: false } || suggestion is not null):
                return new DesignKeyResult(FlushNudge(), field is not null ? DesignAction.Delete : DesignAction.Reject);
            case DesignKey.Enter when mods == DesignModifiers.None && (field is not null || suggestion is not null):
                return new DesignKeyResult(FlushNudge(), field is not null ? DesignAction.Properties : DesignAction.Accept);
            case DesignKey.D when mods == DesignModifiers.Control && field is { Signed: false }:
                return new DesignKeyResult(FlushNudge(), DesignAction.Duplicate);
            case DesignKey.Left or DesignKey.Right or DesignKey.Up or DesignKey.Down when mods is DesignModifiers.None or DesignModifiers.Shift && field is { Signed: false }:
            {
                var step = mods == DesignModifiers.Shift ? 10 : 1;
                var (dx, dy) = key switch { DesignKey.Left => (-step, 0), DesignKey.Right => (step, 0), DesignKey.Up => (0, -step), _ => (0, step) };
                Nudge(dx, dy);
                return new DesignKeyResult(Nudged: true);
            }
            case DesignKey.Escape when mods == DesignModifiers.None:
            {
                var written = FlushNudge();
                return new DesignKeyResult(written, Escape: Escape());
            }
        }
        return null;
    }

    /// <summary>
    /// Tab order of the selection: fields in fill order within a page, then that page's suggestions. Returns where the new
    /// selection is, to bring it into view (null: nothing to go to). The caller flushes any nudge first.
    /// </summary>
    public DesignReveal? Step(int by)
    {
        var items = new List<(DesignField? Field, int Suggestion)>();
        var pages = _fields.Select(f => f.PageIndex).Concat(_suggestions.Select(s => s.PageIndex)).Distinct().Order();
        foreach (var p in pages)
        {
            items.AddRange(_fields.Where(f => f.PageIndex == p).Select(f => ((DesignField?)f, -1)));
            items.AddRange(Enumerable.Range(0, _suggestions.Count).Where(i => _suggestions[i].PageIndex == p).Select(i => ((DesignField?)null, i)));
        }
        if (items.Count == 0) return null;
        var at = items.FindIndex(x => x.Field is { } f ? f.Id == SelectedId : SelectedId is null && x.Suggestion == _suggestionIndex);
        var next = items[at < 0 ? (by > 0 ? 0 : items.Count - 1) : ((at + by) % items.Count + items.Count) % items.Count];
        if (next.Field is { } nf)
        {
            Select(nf.Id);
            return new DesignReveal(nf.PageIndex, nf.Rect);
        }
        SelectSuggestion(next.Suggestion);
        return new DesignReveal(_suggestions[next.Suggestion].PageIndex, _suggestions[next.Suggestion].Rect);
    }

    /// <summary>
    /// Arrow keys move the selected field by (<paramref name="dx"/>, <paramref name="dy"/>) points the way the page is shown,
    /// kept on the page; the move is written once the keys rest (<see cref="FlushNudge"/>). The Mac's moves are in page space.
    /// </summary>
    public void Nudge(double dx, double dy)
    {
        if (SelectedField is not { Signed: false } f) return;
        var g = page(f.PageIndex);
        var (x0, y0) = RotatedView.FromView(0, 0, g.Width, g.Height, g.Rotation);
        var (x1, y1) = RotatedView.FromView(dx, dy, g.Width, g.Height, g.Rotation);
        var start = _pending.TryGetValue(f.Id, out var p) ? p : f.Rect;
        var (mx, my) = DrawingGeometry.ClampMove(start, _nudged.X + x1 - x0, _nudged.Y + y1 - y0, g.Width, g.Height);
        _nudged = new PointD(mx, my);
    }

    /// <summary>The arrow-key moves made so far, as the field to write (called before anything else acts on the selection).</summary>
    public DesignField? FlushNudge()
    {
        var moved = _nudged;
        _nudged = default;
        if (moved == default || SelectedField is not { } f) return null;
        var start = _pending.TryGetValue(f.Id, out var p) ? p : f.Rect;
        var r = start with { X = start.X + moved.X, Y = start.Y + moved.Y };
        _pending[f.Id] = r;
        return f with { Rect = r };
    }

    /// <summary>Esc lets go step by step: the field tool, then the selection, then Prepare Form. The caller flushes any nudge first.</summary>
    public DesignEscape Escape()
    {
        if (Kind is not null)
        {
            Kind = null;
            return DesignEscape.DroppedTool;
        }
        if (SelectedField is not null || SelectedSuggestion is not null)
        {
            Select(null);
            return DesignEscape.Deselected;
        }
        return DesignEscape.Leave;
    }

    private PointD OnPage(int pageIndex, PointD p)
    {
        var g = page(pageIndex);
        return new PointD(Math.Clamp(p.X, 0, g.Width), Math.Clamp(p.Y, 0, g.Height));
    }

    private static PointD ToView(PointD p, DesignPage g)
    {
        var (x, y) = RotatedView.ToView(p.X, p.Y, g.Width, g.Height, g.Rotation);
        return new PointD(x, y);
    }
}
