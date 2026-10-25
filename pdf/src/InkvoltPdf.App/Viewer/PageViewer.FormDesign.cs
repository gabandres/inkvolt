using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>A field drawn with a field tool of Prepare Form (page space).</summary>
public sealed record DesignPlacement(DesignFieldKind Kind, int PageIndex, RectD Rect);

/// <summary>What the user asked for on the selected field or suggestion.</summary>
public enum DesignAction { Delete, Duplicate, Properties, Accept, Reject }

/// <summary>
/// Prepare Form on top of the page view (<see cref="ViewerTool.PrepareForm"/>): every form field shows as a named box;
/// with a field tool (<see cref="DesignKind"/>) a drag (or a click, for the kind's usual size) places a new field; with
/// none, a click selects a field, a drag moves it, its handles resize it (the view's turn applies), arrow keys nudge
/// it (Shift: 10 pt; written once the keys rest), Tab / Shift+Tab go through the fields and suggestions, Enter opens
/// the properties (accepts a suggestion), Delete removes it (rejects a suggestion), Ctrl+D duplicates it, Esc lets go.
/// Suggested fields (<see cref="SetSuggestions"/>) show dashed until accepted. The host turns each gesture into an edit.
/// </summary>
public sealed partial class PageViewer
{
    private Dictionary<int, List<DesignField>> _designByPage = [];
    private List<DesignField> _designOrder = [];
    private List<FieldSuggestion> _suggestions = [];
    private string? _designSel;
    private int _suggestionSel = -1;
    private DesignFieldKind? _designKind;
    private bool _showTabOrder;

    private sealed record DesignDrag(DesignField Field, int Handle, Point Press, Vector Offset, RectD Rect);
    private DesignDrag? _designDrag;
    private int _designBoxPage = -1;
    private Point _designBoxStart, _designBoxEnd;
    private readonly Dictionary<string, RectD> _designPending = []; // shown until the document catches up
    private Vector _designNudge;
    private DispatcherTimer? _designNudgeTimer;

    public event EventHandler<DesignPlacement>? DesignFieldDrawn;

    /// <summary>A field was moved or resized: the field with its new <see cref="DesignField.Rect"/>.</summary>
    public event EventHandler<DesignField>? DesignFieldMoved;

    public event EventHandler? DesignSelectionChanged;
    public event EventHandler<DesignAction>? DesignActionRequested;

    public bool IsDesigningForm => _tool == ViewerTool.PrepareForm;

    /// <summary>The field tool of Prepare Form; null selects and moves fields.</summary>
    public DesignFieldKind? DesignKind
    {
        get => _designKind;
        set
        {
            if (_designKind == value) return;
            _designKind = value;
            UpdateCursor(Mouse.GetPosition(_surface));
            ToolChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Numbers each field with its place in the fill (Tab) order.</summary>
    public bool ShowTabOrder
    {
        get => _showTabOrder;
        set
        {
            _showTabOrder = value;
            _surface.InvalidateVisual();
        }
    }

    public IReadOnlyList<DesignField> DesignFields => _designOrder;
    public IReadOnlyList<FieldSuggestion> Suggestions => _suggestions;
    public DesignField? SelectedDesignField => _designSel is null ? null : _designOrder.FirstOrDefault(f => f.Id == _designSel);
    public FieldSuggestion? SelectedSuggestion => _suggestionSel >= 0 && _suggestionSel < _suggestions.Count ? _suggestions[_suggestionSel] : null;
    public int SelectedSuggestionIndex => SelectedSuggestion is null ? -1 : _suggestionSel;

    public void SetDesignFields(IReadOnlyList<DesignField> fields)
    {
        _designByPage = fields.GroupBy(f => f.PageIndex).ToDictionary(g => g.Key, g => g.ToList());
        _designOrder = [.. fields.OrderBy(f => f.PageIndex).ThenBy(f => f.TabIndex)];
        _designPending.Clear();
        if (_designSel is not null && !fields.Any(f => f.Id == _designSel)) _designSel = null;
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetSuggestions(IReadOnlyList<FieldSuggestion> suggestions)
    {
        var selected = SelectedSuggestion;
        _suggestions = [.. suggestions];
        _suggestionSel = selected is null ? -1 : _suggestions.IndexOf(selected);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Selects a field (null: none), scrolling it into view with <paramref name="reveal"/>.</summary>
    public void SelectDesignField(string? id, bool reveal = false)
    {
        FlushDesignNudge();
        _designSel = id;
        _suggestionSel = -1;
        if (reveal && SelectedDesignField is { } f) EnsureVisible(f.PageIndex, f.Rect);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SelectSuggestion(int index, bool reveal = false)
    {
        FlushDesignNudge();
        _suggestionSel = index >= 0 && index < _suggestions.Count ? index : -1;
        if (_suggestionSel >= 0) _designSel = null;
        if (reveal && SelectedSuggestion is { } s) EnsureVisible(s.PageIndex, s.Rect);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnDesignToolChanged()
    {
        if (IsDesigningForm) return;
        FlushDesignNudge();
        CancelDesignDrag();
        _designKind = null;
        _designSel = null;
        _suggestionSel = -1;
    }

    /// <summary>Where a field shows: its rect, or the one it was just moved to (until the document catches up).</summary>
    private RectD ShownRect(DesignField f)
    {
        var r = _designPending.TryGetValue(f.Id, out var p) ? p : f.Rect;
        if (_designDrag is { } d && d.Field.Id == f.Id) r = d.Rect;
        if (_designSel == f.Id && _designNudge != default) r = r with { X = r.X + _designNudge.X, Y = r.Y + _designNudge.Y };
        return r;
    }

    private DesignField? DesignFieldAt(int page, Point pt) =>
        page >= 0 && _designByPage.TryGetValue(page, out var list)
            ? list.Where(f => ShownRect(f).Inflate(2).Contains(pt.X, pt.Y)).MinBy(f => f.Rect.Width * f.Rect.Height)
            : null;

    private int SuggestionAt(int page, Point pt) =>
        _suggestions.FindLastIndex(s => s.PageIndex == page && s.Rect.Inflate(2).Contains(pt.X, pt.Y));

    /// <summary>The resize handle of the selected field under the pointer (0-7, see <see cref="DrawingGeometry"/>), or -1.</summary>
    private int DesignHandleAt(int page, Point sp)
    {
        if (SelectedDesignField is not { } f || f.PageIndex != page || f.Signed) return -1;
        var r = ToSurfaceRect(page, ShownRect(f));
        var frame = new RectD(r.X, r.Y, r.Width, r.Height);
        var reach = HandlePx / 2 + 3;
        for (var i = 0; i < 8; i++)
        {
            var hp = DrawingGeometry.HandlePoint(frame, i);
            if (Math.Abs(hp.X - sp.X) <= reach && Math.Abs(hp.Y - sp.Y) <= reach) return i;
        }
        return -1;
    }

    // ───────────────────────────── Mouse ─────────────────────────────

    /// <summary>Prepare Form presses: select, move, resize, or draw a new field. True if consumed.</summary>
    private bool HandleDesignDown(MouseButtonEventArgs e, int page, Point sp)
    {
        if (!IsDesigningForm || e.ChangedButton != MouseButton.Left) return false;
        e.Handled = true;
        Focus();
        if (page < 0) return true;
        FlushDesignNudge();
        var pt = ToPagePoint(page, sp);
        if (DesignHandleAt(page, sp) is var h and >= 0)
        {
            StartDesignDrag(SelectedDesignField!, h, sp);
            return true;
        }
        if (_designKind is null && DesignFieldAt(page, pt) is { } hit)
        {
            SelectDesignField(hit.Id);
            if (e.ClickCount >= 2) DesignActionRequested?.Invoke(this, DesignAction.Properties);
            else if (!hit.Signed) StartDesignDrag(hit, -1, sp);
            return true;
        }
        if (_designKind is null && SuggestionAt(page, pt) is var si and >= 0)
        {
            SelectSuggestion(si);
            if (e.ClickCount >= 2) DesignActionRequested?.Invoke(this, DesignAction.Accept);
            return true;
        }
        if (_designKind is not null)
        {
            _designBoxPage = page;
            _designBoxStart = _designBoxEnd = ClampToPagePoint(page, pt);
            _surface.CaptureMouse();
            _surface.InvalidateVisual();
            return true;
        }
        if (_designSel is not null || _suggestionSel >= 0)
        {
            _designSel = null;
            _suggestionSel = -1;
            _surface.InvalidateVisual();
            DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
        }
        _panning = true; // an empty spot scrolls, as with the hand tool
        _surface.CaptureMouse();
        return true;
    }

    private Point ClampToPagePoint(int page, Point pt)
    {
        var g = _engine!.GetPage(page);
        return new Point(Math.Clamp(pt.X, 0, g.Width), Math.Clamp(pt.Y, 0, g.Height));
    }

    private void StartDesignDrag(DesignField f, int handle, Point sp)
    {
        var offset = new Vector();
        if (handle >= 0)
        {
            // The handle sits on the frame: keep the pointer's offset from it, so the frame doesn't jump.
            var r = ToSurfaceRect(f.PageIndex, ShownRect(f));
            var hp = DrawingGeometry.HandlePoint(new RectD(r.X, r.Y, r.Width, r.Height), handle);
            var k = _zoom * PtToDip;
            offset = new Vector((hp.X - sp.X) / k, (hp.Y - sp.Y) / k);
        }
        _designDrag = new DesignDrag(f, handle, sp, offset, ShownRect(f));
        _surface.CaptureMouse();
        _surface.InvalidateVisual();
    }

    private bool MoveDesignDrag(Point sp)
    {
        if (_designBoxPage >= 0)
        {
            _designBoxEnd = ClampToPagePoint(_designBoxPage, ToPagePoint(_designBoxPage, sp));
            _surface.InvalidateVisual();
            return true;
        }
        if (_designDrag is not { } d) return false;
        if (!_dragged) return true;
        var page = d.Field.PageIndex;
        var g = _engine!.GetPage(page);
        var start = _designPending.TryGetValue(d.Field.Id, out var p) ? p : d.Field.Rect;
        RectD r;
        if (d.Handle < 0)
        {
            var a = ToPagePoint(page, d.Press);
            var b = ToPagePoint(page, sp);
            var (dx, dy) = DrawingGeometry.ClampMove(start, b.X - a.X, b.Y - a.Y, g.Width, g.Height);
            r = start with { X = start.X + dx, Y = start.Y + dy };
        }
        else
        {
            // Resize in the page as shown (the handles follow the view's turn), then back to page space.
            var vp = ToViewPoint(page, sp);
            vp = new PointD(vp.X + d.Offset.X, vp.Y + d.Offset.Y);
            var view = RotatedView.ToView(start, g.Width, g.Height, _viewRotation);
            var (vw, vh) = RotatedView.Size(g.Width, g.Height, _viewRotation);
            vp = new PointD(Math.Clamp(vp.X, 0, vw), Math.Clamp(vp.Y, 0, vh));
            var square = d.Field.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio && (Keyboard.Modifiers & ModifierKeys.Shift) == 0;
            var sized = DrawingGeometry.Resize(view, d.Handle, vp, 6, keepAspect: square || (Keyboard.Modifiers & ModifierKeys.Shift) != 0);
            r = RotatedView.FromView(sized, g.Width, g.Height, _viewRotation);
        }
        _designDrag = d with { Rect = r };
        _surface.InvalidateVisual();
        return true;
    }

    private bool EndDesignDrag()
    {
        if (_designBoxPage >= 0)
        {
            var page = _designBoxPage;
            _designBoxPage = -1;
            _surface.InvalidateVisual();
            var kind = _designKind ?? DesignFieldKind.Text;
            var rect = RectD.FromEdges(_designBoxStart.X, _designBoxStart.Y, _designBoxEnd.X, _designBoxEnd.Y);
            if (!_dragged || rect.Width < 6 || rect.Height < 6)
            {
                // A click: the kind's usual size, its top-left at the pointer (kept on the page).
                var (w, h) = DefaultSize(kind);
                var g = _engine!.GetPage(page);
                rect = new RectD(Math.Clamp(_designBoxStart.X, 0, Math.Max(0, g.Width - w)), Math.Clamp(_designBoxStart.Y, 0, Math.Max(0, g.Height - h)), w, h);
            }
            else if (kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio)
            {
                var side = Math.Min(rect.Width, rect.Height);
                rect = rect with { Width = side, Height = side };
            }
            DesignFieldDrawn?.Invoke(this, new DesignPlacement(kind, page, rect));
            return true;
        }
        if (_designDrag is not { } d) return false;
        _designDrag = null;
        _surface.InvalidateVisual();
        var before = _designPending.TryGetValue(d.Field.Id, out var p) ? p : d.Field.Rect;
        if (_dragged && d.Rect != before)
        {
            _designPending[d.Field.Id] = d.Rect;
            DesignFieldMoved?.Invoke(this, d.Field with { Rect = d.Rect });
        }
        return true;
    }

    private void CancelDesignDrag()
    {
        if (_designBoxPage < 0 && _designDrag is null) return;
        _designBoxPage = -1;
        _designDrag = null;
        _surface.InvalidateVisual();
    }

    /// <summary>A new field's size when placed with a click (points).</summary>
    public static (double W, double H) DefaultSize(DesignFieldKind kind) => kind switch
    {
        DesignFieldKind.CheckBox or DesignFieldKind.Radio => (14, 14),
        DesignFieldKind.ComboBox => (140, 20),
        DesignFieldKind.ListBox => (140, 60),
        DesignFieldKind.Signature => (180, 40),
        DesignFieldKind.Button => (80, 24),
        _ => (160, 20),
    };

    private Cursor? DesignCursor(int page, Point sp)
    {
        if (!IsDesigningForm) return null;
        if (page < 0) return Cursors.Arrow;
        if (DesignHandleAt(page, sp) is var h and >= 0) return h is 0 or 4 ? Cursors.SizeNWSE : h is 2 or 6 ? Cursors.SizeNESW : h is 1 or 5 ? Cursors.SizeNS : Cursors.SizeWE;
        if (_designKind is not null) return Cursors.Cross;
        var pt = ToPagePoint(page, sp);
        if (DesignFieldAt(page, pt) is { } f) return f.Signed ? Cursors.Arrow : Cursors.SizeAll;
        return SuggestionAt(page, pt) >= 0 ? Cursors.Hand : Cursors.Arrow;
    }

    // ───────────────────────────── Keys ─────────────────────────────

    private bool HandleDesignKey(KeyEventArgs e)
    {
        if (!IsDesigningForm) return false;
        var mods = Keyboard.Modifiers;
        var field = SelectedDesignField;
        var suggestion = SelectedSuggestion;
        switch (e.Key)
        {
            case Key.Tab when (mods & ~ModifierKeys.Shift) == 0:
                StepDesignSelection((mods & ModifierKeys.Shift) != 0 ? -1 : 1);
                return true;
            case Key.Delete or Key.Back when mods == ModifierKeys.None && (field is { Signed: false } || suggestion is not null):
                FlushDesignNudge();
                DesignActionRequested?.Invoke(this, field is not null ? DesignAction.Delete : DesignAction.Reject);
                return true;
            case Key.Enter when mods == ModifierKeys.None && (field is not null || suggestion is not null):
                FlushDesignNudge();
                DesignActionRequested?.Invoke(this, field is not null ? DesignAction.Properties : DesignAction.Accept);
                return true;
            case Key.D when mods == ModifierKeys.Control && field is { Signed: false }:
                FlushDesignNudge();
                DesignActionRequested?.Invoke(this, DesignAction.Duplicate);
                return true;
            case Key.Left or Key.Right or Key.Up or Key.Down when mods is ModifierKeys.None or ModifierKeys.Shift && field is { Signed: false }:
                NudgeDesign(field, e.Key, mods == ModifierKeys.Shift ? 10 : 1);
                return true;
            case Key.Escape when mods == ModifierKeys.None:
                FlushDesignNudge();
                if (_designKind is not null) DesignKind = null;
                else if (field is not null || suggestion is not null) SelectDesignField(null);
                else Tool = ViewerTool.Hand;
                return true;
        }
        return false;
    }

    /// <summary>Tab order of the selection: fields in fill order, then suggestions in reading order.</summary>
    private void StepDesignSelection(int step)
    {
        var items = _designOrder.Select(f => (Field: (DesignField?)f, Index: -1))
            .Concat(_suggestions.Select((s, i) => (Field: (DesignField?)null, Index: i)))
            .OrderBy(x => x.Field?.PageIndex ?? _suggestions[x.Index].PageIndex).ToList();
        // Fields keep their fill order within a page; suggestions follow the fields of their page.
        items = [.. items.GroupBy(x => x.Field?.PageIndex ?? _suggestions[x.Index].PageIndex).OrderBy(g => g.Key)
            .SelectMany(g => g.Where(x => x.Field is not null).OrderBy(x => x.Field!.TabIndex).Concat(g.Where(x => x.Field is null)))];
        if (items.Count == 0) return;
        FlushDesignNudge();
        var at = items.FindIndex(x => x.Field is { } f ? f.Id == _designSel : x.Index == _suggestionSel && _designSel is null && _suggestionSel >= 0);
        var next = items[at < 0 ? (step > 0 ? 0 : items.Count - 1) : (at + step + items.Count) % items.Count];
        if (next.Field is { } nf) SelectDesignField(nf.Id, reveal: true);
        else SelectSuggestion(next.Index, reveal: true);
    }

    /// <summary>Arrow keys move the field the way the page is shown; the move is written once the keys rest.</summary>
    private void NudgeDesign(DesignField f, Key key, double step)
    {
        var (vx, vy) = key switch { Key.Left => (-step, 0.0), Key.Right => (step, 0.0), Key.Up => (0.0, -step), _ => (0.0, step) };
        var g = _engine!.GetPage(f.PageIndex);
        var (x0, y0) = RotatedView.FromView(0, 0, g.Width, g.Height, _viewRotation);
        var (x1, y1) = RotatedView.FromView(vx, vy, g.Width, g.Height, _viewRotation);
        var start = _designPending.TryGetValue(f.Id, out var p) ? p : f.Rect;
        var (dx, dy) = DrawingGeometry.ClampMove(start, _designNudge.X + x1 - x0, _designNudge.Y + y1 - y0, g.Width, g.Height);
        _designNudge = new Vector(dx, dy);
        if (_designNudgeTimer is null)
        {
            _designNudgeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
            _designNudgeTimer.Tick += (_, _) => FlushDesignNudge();
        }
        _designNudgeTimer.Stop();
        _designNudgeTimer.Start();
        _surface.InvalidateVisual();
    }

    /// <summary>Writes the arrow-key moves made so far (called before anything else acts on the selection).</summary>
    public void FlushDesignNudge()
    {
        _designNudgeTimer?.Stop();
        if (_designNudge == default || SelectedDesignField is not { } f)
        {
            _designNudge = default;
            return;
        }
        var v = _designNudge;
        _designNudge = default;
        var start = _designPending.TryGetValue(f.Id, out var p) ? p : f.Rect;
        var r = start with { X = start.X + v.X, Y = start.Y + v.Y };
        _designPending[f.Id] = r;
        _surface.InvalidateVisual();
        DesignFieldMoved?.Invoke(this, f with { Rect = r });
    }

    // ───────────────────────────── Painting ─────────────────────────────

    private static readonly Brush SuggestionFill = Frozen(new SolidColorBrush(Color.FromArgb(0x30, 0xF0, 0x8C, 0x00)));
    private static readonly Pen SuggestionPen = Frozen(new Pen(new SolidColorBrush(Color.FromRgb(0xD9, 0x6C, 0x00)), 1.5) { DashStyle = DashStyles.Dash });
    private static readonly Pen SuggestionSelectPen = Frozen(new Pen(new SolidColorBrush(Color.FromRgb(0xD9, 0x6C, 0x00)), 2.5));

    private void PaintDesign(DrawingContext dc, int page)
    {
        if (!IsDesigningForm) return;
        var accent = _highContrast ? SystemColors.HighlightBrush : TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.RoyalBlue;
        var handleFill = _highContrast ? SystemColors.WindowBrush : TryFindResource("ControlSolidFillColorDefaultBrush") as Brush ?? Brushes.White;
        var fieldPen = Frozen(new Pen(accent, 1));
        var selPen = Frozen(new Pen(accent, 2));
        var fill = _highContrast ? null : Frozen(new SolidColorBrush(Color.FromArgb(0x26, 0x20, 0x70, 0xE0)));
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var labelSize = Math.Clamp(9 * _zoom * PtToDip / 1.33, 8, 12);

        if (_designByPage.TryGetValue(page, out var fields))
        {
            foreach (var f in fields)
            {
                var r = ToSurfaceRect(page, ShownRect(f));
                var selected = f.Id == _designSel;
                if (f.Kind == DesignFieldKind.Radio)
                    dc.DrawEllipse(fill, selected ? selPen : fieldPen, new Point(r.X + r.Width / 2, r.Y + r.Height / 2), r.Width / 2, r.Height / 2);
                dc.DrawRectangle(f.Kind == DesignFieldKind.Radio ? null : fill, selected ? selPen : fieldPen, r);
                // Small boxes are named only when selected (their names would cover the page's text).
                if (f.Kind is not (DesignFieldKind.CheckBox or DesignFieldKind.Radio)) Label(dc, f.Name, r, accent, labelSize, dpi, inside: true);
                else if (selected) Label(dc, f.Kind == DesignFieldKind.Radio ? $"{f.Name}: {f.ExportValue}" : f.Name, r, accent, labelSize, dpi, inside: false);
                if (_showTabOrder) TabBadge(dc, f.TabIndex + 1, r, accent, dpi);
                if (!selected || f.Signed) continue;
                var frame = new RectD(r.X, r.Y, r.Width, r.Height);
                for (var i = 0; i < 8; i++)
                {
                    var hp = DrawingGeometry.HandlePoint(frame, i);
                    dc.DrawRoundedRectangle(handleFill, Frozen(new Pen(accent, 1.5)), new Rect(hp.X - HandlePx / 2, hp.Y - HandlePx / 2, HandlePx, HandlePx), 2, 2);
                }
            }
        }

        for (var i = 0; i < _suggestions.Count; i++)
        {
            var s = _suggestions[i];
            if (s.PageIndex != page) continue;
            var r = ToSurfaceRect(page, s.Rect);
            dc.DrawRectangle(SuggestionFill, i == _suggestionSel ? SuggestionSelectPen : SuggestionPen, r);
            if (s.Kind is not (DesignFieldKind.CheckBox or DesignFieldKind.Radio) || i == _suggestionSel)
                Label(dc, s.Name, r, SuggestionPen.Brush, labelSize, dpi, inside: s.Kind is not (DesignFieldKind.CheckBox or DesignFieldKind.Radio));
        }

        if (_designBoxPage == page)
            dc.DrawRectangle(SigBoxFill, SigBoxPen, ToSurfaceRect(page, RectD.FromEdges(_designBoxStart.X, _designBoxStart.Y, _designBoxEnd.X, _designBoxEnd.Y)));
    }

    /// <summary>A field's name: inside its box at the top-left when it fits, else just above it.</summary>
    private static void Label(DrawingContext dc, string text, Rect r, Brush brush, double size, double dpi, bool inside)
    {
        var ft = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), size, brush, dpi)
        {
            MaxTextWidth = Math.Max(20, inside ? r.Width - 4 : 200),
            MaxLineCount = 1,
            Trimming = TextTrimming.CharacterEllipsis,
        };
        if (inside && ft.Height <= r.Height - 1) dc.DrawText(ft, new Point(r.X + 2, r.Y + 1));
        else dc.DrawText(ft, new Point(r.X, r.Y - ft.Height - 1));
    }

    private static void TabBadge(DrawingContext dc, int n, Rect r, Brush accent, double dpi)
    {
        var ft = new FormattedText(n.ToString(CultureInfo.CurrentCulture), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), 10, Brushes.White, dpi);
        // Left of the field's top-left corner, clear of the selection handles.
        var d = Math.Max(16, ft.Width + 8);
        var c = new Point(r.X - d / 2 - 3, r.Y + Math.Min(8, r.Height / 2));
        dc.DrawRoundedRectangle(accent, null, new Rect(c.X - d / 2, c.Y - 8, d, 16), 8, 8);
        dc.DrawText(ft, new Point(c.X - ft.Width / 2, c.Y - ft.Height / 2));
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    internal void DevDrawField(DesignFieldKind kind, int page, RectD rect) => DesignFieldDrawn?.Invoke(this, new DesignPlacement(kind, page, rect));

    internal void DevMoveField(string id, RectD rect)
    {
        if (_designOrder.FirstOrDefault(f => f.Id == id) is not { } f) return;
        _designPending[id] = rect;
        DesignFieldMoved?.Invoke(this, f with { Rect = rect });
    }

    internal void DevDesignAction(DesignAction action) => DesignActionRequested?.Invoke(this, action);
}
