using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>
/// Prepare Form on top of the page view (<see cref="ViewerTool.PrepareForm"/>), an adapter (ADR 1): Core's
/// <see cref="FormDesigner"/> decides what a press, drag, key or nudge does and what is selected; this file turns the
/// mouse and keys into its inputs (page points, the view's turn), draws the fields, suggestions, handles and the box being
/// drawn, sets the cursor, and raises what it hands over as events. The host turns each into an edit.
/// </summary>
public sealed partial class PageViewer
{
    private FormDesigner? _designerState;
    private DispatcherTimer? _designNudgeTimer;

    /// <summary>Prepare Form's state: the fields, suggestions, selection and the tool.</summary>
    internal FormDesigner Designer => _designerState ??= new FormDesigner(p =>
    {
        var g = _engine!.GetPage(p);
        return new DesignPage(g.Width, g.Height, _viewRotation);
    });

    public event EventHandler<DesignPlacement>? DesignFieldDrawn;

    /// <summary>A field was moved or resized: the field with its new <see cref="DesignField.Rect"/>.</summary>
    public event EventHandler<DesignField>? DesignFieldMoved;

    public event EventHandler? DesignSelectionChanged;
    public event EventHandler<DesignAction>? DesignActionRequested;

    public bool IsDesigningForm => _tool == ViewerTool.PrepareForm;

    /// <summary>The field tool of Prepare Form; null selects and moves fields.</summary>
    public DesignFieldKind? DesignKind
    {
        get => Designer.Kind;
        set
        {
            if (Designer.Kind == value) return;
            Designer.Kind = value;
            OnDesignKindChanged();
        }
    }

    private void OnDesignKindChanged()
    {
        UpdateCursor(Mouse.GetPosition(_surface));
        ToolChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Numbers each field with its place in the fill (Tab) order.</summary>
    public bool ShowTabOrder
    {
        get => Designer.ShowTabOrder;
        set
        {
            Designer.ShowTabOrder = value;
            _surface.InvalidateVisual();
        }
    }

    public IReadOnlyList<DesignField> DesignFields => Designer.Fields;
    public IReadOnlyList<FieldSuggestion> Suggestions => Designer.Suggestions;
    public DesignField? SelectedDesignField => Designer.SelectedField;
    public FieldSuggestion? SelectedSuggestion => Designer.SelectedSuggestion;
    public int SelectedSuggestionIndex => Designer.SelectedSuggestionIndex;

    public void SetDesignFields(IReadOnlyList<DesignField> fields)
    {
        Designer.SetFields(fields);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetSuggestions(IReadOnlyList<FieldSuggestion> suggestions)
    {
        Designer.SetSuggestions(suggestions);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Selects a field (null: none), scrolling it into view with <paramref name="reveal"/>.</summary>
    public void SelectDesignField(string? id, bool reveal = false)
    {
        FlushDesignNudge();
        Designer.Select(id);
        if (reveal && SelectedDesignField is { } f) EnsureVisible(f.PageIndex, f.Rect);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SelectSuggestion(int index, bool reveal = false)
    {
        FlushDesignNudge();
        Designer.SelectSuggestion(index);
        if (reveal && SelectedSuggestion is { } s) EnsureVisible(s.PageIndex, s.Rect);
        _surface.InvalidateVisual();
        DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnDesignToolChanged()
    {
        if (IsDesigningForm) return;
        FlushDesignNudge();
        Designer.Reset();
    }

    /// <summary>A handle's reach in page points at the zoom shown (its half size and 3 DIPs more).</summary>
    private double DesignReach => (HandlePx / 2 + 3) / (_zoom * PtToDip);

    private static PointD ToPointD(Point p) => new(p.X, p.Y);

    // ───────────────────────────── Mouse ─────────────────────────────

    /// <summary>Prepare Form presses: select, move, resize, or draw a new field. True if consumed.</summary>
    private bool HandleDesignDown(MouseButtonEventArgs e, int page, Point sp)
    {
        if (!IsDesigningForm || e.ChangedButton != MouseButton.Left) return false;
        e.Handled = true;
        Focus();
        if (page < 0) return true;
        FlushDesignNudge();
        var hadSelection = SelectedDesignField is not null || SelectedSuggestion is not null;
        var press = Designer.Press(page, ToPointD(ToPagePoint(page, sp)), e.ClickCount, DesignReach);
        if (Designer.IsDragging) _surface.CaptureMouse();
        _surface.InvalidateVisual();
        switch (press)
        {
            case DesignPress.Selected or DesignPress.Properties or DesignPress.Accept:
                DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
                if (press != DesignPress.Selected) DesignActionRequested?.Invoke(this, press == DesignPress.Properties ? DesignAction.Properties : DesignAction.Accept);
                break;
            case DesignPress.Pan:
                if (hadSelection) DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
                _panning = true; // an empty spot scrolls, as with the hand tool
                _surface.CaptureMouse();
                break;
        }
        return true;
    }

    private bool MoveDesignDrag(Point sp)
    {
        if (Designer.PressPage is not { } page) return false;
        Designer.Move(ToPointD(ToPagePoint(page, sp)), (Keyboard.Modifiers & ModifierKeys.Shift) != 0, _dragged);
        _surface.InvalidateVisual();
        return true;
    }

    private bool EndDesignDrag()
    {
        if (!Designer.IsDragging) return false;
        var release = Designer.Release();
        _surface.InvalidateVisual();
        switch (release)
        {
            case DesignRelease.Placed p: DesignFieldDrawn?.Invoke(this, p.Placement); break;
            case DesignRelease.Moved m: DesignFieldMoved?.Invoke(this, m.Field); break;
        }
        return true;
    }

    private void CancelDesignDrag()
    {
        if (!Designer.IsDragging) return;
        Designer.CancelDrag();
        _surface.InvalidateVisual();
    }

    private Cursor? DesignCursor(int page, Point sp)
    {
        if (!IsDesigningForm) return null;
        if (page < 0) return Cursors.Arrow;
        var c = Designer.Cursor(page, ToPointD(ToPagePoint(page, sp)), DesignReach);
        return c.Kind switch
        {
            DesignCursorKind.Resize => c.Handle is DrawingGeometry.TopLeft or DrawingGeometry.BottomRight ? Cursors.SizeNWSE
                : c.Handle is DrawingGeometry.TopRight or DrawingGeometry.BottomLeft ? Cursors.SizeNESW
                : c.Handle is DrawingGeometry.Top or DrawingGeometry.Bottom ? Cursors.SizeNS : Cursors.SizeWE,
            DesignCursorKind.Crosshair => Cursors.Cross,
            DesignCursorKind.Move => Cursors.SizeAll,
            DesignCursorKind.PointingHand => Cursors.Hand,
            _ => Cursors.Arrow,
        };
    }

    // ───────────────────────────── Keys ─────────────────────────────

    private bool HandleDesignKey(KeyEventArgs e)
    {
        if (!IsDesigningForm) return false;
        DesignKey? key = e.Key switch
        {
            Key.Tab => DesignKey.Tab,
            Key.Delete => DesignKey.Delete,
            Key.Back => DesignKey.Backspace,
            Key.Enter => DesignKey.Enter,
            Key.D => DesignKey.D,
            Key.Left => DesignKey.Left,
            Key.Right => DesignKey.Right,
            Key.Up => DesignKey.Up,
            Key.Down => DesignKey.Down,
            Key.Escape => DesignKey.Escape,
            _ => null,
        };
        if (key is null) return false;
        var mods = Keyboard.Modifiers;
        var designMods = ((mods & ModifierKeys.Shift) != 0 ? DesignModifiers.Shift : 0) | ((mods & ModifierKeys.Control) != 0 ? DesignModifiers.Control : 0)
                         | ((mods & ModifierKeys.Alt) != 0 ? DesignModifiers.Alt : 0) | ((mods & ModifierKeys.Windows) != 0 ? DesignModifiers.Windows : 0);
        var before = (SelectedDesignField?.Id, SelectedSuggestionIndex);
        if (Designer.Key(key.Value, designMods) is not { } result) return false;
        if (result.Nudged)
        {
            _designNudgeTimer ??= NewNudgeTimer();
            _designNudgeTimer.Stop();
            _designNudgeTimer.Start();
        }
        else
        {
            _designNudgeTimer?.Stop();
        }
        if (result.Written is { } written) DesignFieldMoved?.Invoke(this, written);
        if (result.Reveal is { } reveal) EnsureVisible(reveal.Page, reveal.Rect);
        _surface.InvalidateVisual();
        if (result.Reveal is not null || before != (SelectedDesignField?.Id, SelectedSuggestionIndex)) DesignSelectionChanged?.Invoke(this, EventArgs.Empty);
        switch (result.Escape)
        {
            case DesignEscape.CancelledPress: UpdateCursor(Mouse.GetPosition(_surface)); break; // the release that follows writes nothing
            case DesignEscape.DroppedTool: OnDesignKindChanged(); break;
            case DesignEscape.Leave: Tool = ViewerTool.Hand; break;
        }
        if (result.Action is { } action) DesignActionRequested?.Invoke(this, action);
        return true;
    }

    private DispatcherTimer NewNudgeTimer()
    {
        var timer = new DispatcherTimer { Interval = FormDesigner.NudgeRest };
        timer.Tick += (_, _) => FlushDesignNudge();
        return timer;
    }

    /// <summary>Writes the arrow-key moves made so far (called before anything else acts on the selection).</summary>
    public void FlushDesignNudge()
    {
        _designNudgeTimer?.Stop();
        if (Designer.FlushNudge() is not { } moved) return;
        _surface.InvalidateVisual();
        DesignFieldMoved?.Invoke(this, moved);
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

        if (Designer.FieldsOnPage(page) is { Count: > 0 } fields)
        {
            foreach (var f in fields)
            {
                var r = ToSurfaceRect(page, Designer.ShownRect(f));
                var selected = f.Id == Designer.SelectedId;
                if (f.Kind == DesignFieldKind.Radio)
                    dc.DrawEllipse(fill, selected ? selPen : fieldPen, new Point(r.X + r.Width / 2, r.Y + r.Height / 2), r.Width / 2, r.Height / 2);
                dc.DrawRectangle(f.Kind == DesignFieldKind.Radio ? null : fill, selected ? selPen : fieldPen, r);
                // Small boxes are named only when selected (their names would cover the page's text).
                if (f.Kind is not (DesignFieldKind.CheckBox or DesignFieldKind.Radio)) Label(dc, f.Name, r, accent, labelSize, dpi, inside: true);
                else if (selected) Label(dc, f.Kind == DesignFieldKind.Radio ? $"{f.Name}: {f.ExportValue}" : f.Name, r, accent, labelSize, dpi, inside: false);
                if (Designer.ShowTabOrder) TabBadge(dc, f.TabIndex + 1, r, accent, dpi);
                if (!selected || f.Signed) continue;
                var frame = new RectD(r.X, r.Y, r.Width, r.Height);
                for (var i = 0; i < 8; i++)
                {
                    var hp = DrawingGeometry.HandlePoint(frame, i);
                    dc.DrawRoundedRectangle(handleFill, Frozen(new Pen(accent, 1.5)), new Rect(hp.X - HandlePx / 2, hp.Y - HandlePx / 2, HandlePx, HandlePx), 2, 2);
                }
            }
        }

        var suggestions = Designer.Suggestions;
        var selectedSuggestion = Designer.SelectedSuggestionIndex;
        for (var i = 0; i < suggestions.Count; i++)
        {
            var s = suggestions[i];
            if (s.PageIndex != page) continue;
            var r = ToSurfaceRect(page, s.Rect);
            dc.DrawRectangle(SuggestionFill, i == selectedSuggestion ? SuggestionSelectPen : SuggestionPen, r);
            if (s.Kind is not (DesignFieldKind.CheckBox or DesignFieldKind.Radio) || i == selectedSuggestion)
                Label(dc, s.Name, r, SuggestionPen.Brush, labelSize, dpi, inside: s.Kind is not (DesignFieldKind.CheckBox or DesignFieldKind.Radio));
        }

        if (Designer.NewBoxRect is { } box && box.Page == page)
            dc.DrawRectangle(SigBoxFill, SigBoxPen, ToSurfaceRect(page, box.Rect));
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
}
