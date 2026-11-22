using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>A turn asked for in Edit Text &amp; Images: a picture or a paragraph, by how many degrees clockwise.</summary>
public sealed record ContentTurnEdit(PageImage? Image, TextParagraph? Paragraph, double By);

/// <summary>
/// Edit Text &amp; Images' turn handle (roadmap 4.22), an adapter (ADR 1): <see cref="ContentTurn"/> decides where the
/// handle is, what a drag of it turns to (Shift: 15° steps) and what a typed angle is; this draws the handle over the
/// selected picture or the paragraph whose editor is open, shows the turn while it is dragged, and raises the turn.
/// </summary>
public sealed partial class PageViewer
{
    private sealed record TurnDrag(int Page, Rect Shown, double Start, Point Press, double Angle, PageImage? Image, TextParagraph? Paragraph);

    private TurnDrag? _turnDrag;
    private (int Page, PointD Center)? _imageSelAt; // select the picture there once the page is read again (it turned)
    private TextParagraph? _turnParagraph;          // the text last clicked: what the handle and the angle box turn

    public event EventHandler<ContentTurnEdit>? ContentTurned;

    /// <summary>What the handle and the angle box turn: the selected picture, else the paragraph last clicked (its editor
    /// open, or closed since: typing in the angle box closes it).</summary>
    private (int Page, RectD Box, double Angle, PageImage? Image, TextParagraph? Paragraph)? TurnTarget()
    {
        if (!IsEditingContent) return null;
        if (SelectedImage is { Blocked: null } img && !CroppingImage) return (img.PageIndex, ShownBox(img), img.Angle, img, null);
        if (_turnParagraph is { Blocked: null } p && _contentByPage.TryGetValue(p.PageIndex, out var c) && c.Paragraphs.Contains(p))
            return (p.PageIndex, p.Box, p.Angle, null, p);
        return null;
    }

    /// <summary>The angle the bar's box shows (null: nothing to turn), and whether it is a picture's.</summary>
    public (double Angle, bool Picture)? TurnSubject => TurnTarget() is { } t ? (_turnDrag?.Angle ?? t.Angle, t.Image is not null) : null;

    /// <summary>The angle box: turns the picture or paragraph to <paramref name="wanted"/> degrees (as the page shows).</summary>
    public void TurnTo(double wanted)
    {
        if (TurnTarget() is not { } t || ContentTurn.TurnBy(t.Angle, wanted) is not { } by) return;
        RaiseTurn(t.Image, t.Paragraph, t.Box, by);
    }

    private void RaiseTurn(PageImage? image, TextParagraph? paragraph, RectD box, double by)
    {
        if (paragraph is not null && _editor is not null) CloseEditor(); // unchanged (checked before): it would be stale
        if (image is not null) _imageSelAt = (image.PageIndex, new PointD(box.CenterX, box.CenterY));
        ContentTurned?.Invoke(this, new ContentTurnEdit(image, paragraph, by));
    }

    /// <summary>After a turn: the picture to select once its page is read again (its box changed; its middle didn't).</summary>
    private void ReselectTurnedImage(int page, PageContent content)
    {
        if (_imageSelAt is not { } at || at.Page != page) return;
        _imageSelAt = null;
        if (content.Images.Where(i => Math.Abs(i.Box.CenterX - at.Center.X) < 1 && Math.Abs(i.Box.CenterY - at.Center.Y) < 1).LastOrDefault() is { } img)
            _imageSel = (page, img.Box);
    }

    private Rect? TurnHandleRect(int page)
    {
        if (_turnDrag is null && TurnTarget() is { } t && t.Page == page) return ToSurfaceRect(page, t.Box);
        return null;
    }

    private bool OnTurnHandle(int page, Point sp) =>
        page >= 0 && TurnHandleRect(page) is { } r && ContentTurn.OnHandle(new RectD(r.X, r.Y, r.Width, r.Height), new PointD(sp.X, sp.Y), HandlePx / 2 + 3);

    /// <summary>A press on the turn handle starts turning. True if it was.</summary>
    private bool TurnHandleDown(int page, Point sp)
    {
        if (!OnTurnHandle(page, sp) || TurnTarget() is not { } t) return false;
        if (t.Paragraph is not null && EditorChanged())
        {
            // The text was changed: keep that first (Enter), then turn it.
            ContentRefused?.Invoke(this, Strings.Viewer_TurnAfterEdit);
            return true;
        }
        _turnDrag = new TurnDrag(page, ToSurfaceRect(page, t.Box), t.Angle, sp, t.Angle, t.Image, t.Paragraph);
        _surface.CaptureMouse();
        _surface.InvalidateVisual();
        return true;
    }

    /// <summary>Whether the open editor holds text other than the page's.</summary>
    private bool EditorChanged()
    {
        if (_editorParagraph is { } p && _editor is RichTextBox rb)
        {
            var (text, spans, added) = ParagraphContent(rb, p);
            return !(text == p.Text && added.Count == 0 && spans.Count == p.Spans.Count && spans.Zip(p.Spans).All(x => x.First == x.Second));
        }
        return _editorRun is { } run && _editor is TextBox tb && tb.Text != run.Text;
    }

    private bool MoveTurnDrag(Point sp)
    {
        if (_turnDrag is not { } d) return false;
        var c = new PointD(d.Shown.X + d.Shown.Width / 2, d.Shown.Y + d.Shown.Height / 2);
        var angle = ContentTurn.Dragged(c, new PointD(d.Press.X, d.Press.Y), new PointD(sp.X, sp.Y), d.Start, (Keyboard.Modifiers & ModifierKeys.Shift) != 0);
        if (angle != d.Angle)
        {
            _turnDrag = d with { Angle = angle };
            _surface.InvalidateVisual();
            ContentSelectionChanged?.Invoke(this, EventArgs.Empty); // the bar's box follows
        }
        return true;
    }

    private bool EndTurnDrag()
    {
        if (_turnDrag is not { } d) return false;
        _turnDrag = null;
        _surface.InvalidateVisual();
        if (_dragged && ContentTurn.TurnBy(d.Start, d.Angle) is { } by)
            RaiseTurn(d.Image, d.Paragraph, d.Image is not null ? ShownBox(d.Image) : d.Paragraph!.Box, by);
        ContentSelectionChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    private void CancelTurnDrag()
    {
        if (_turnDrag is null) return;
        _turnDrag = null;
        _surface.InvalidateVisual();
        ContentSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The handle over what can be turned (a line up from its top edge to a round knob), and while dragging the
    /// turned outline and its angle.</summary>
    private void PaintTurn(DrawingContext dc, int page, Brush accent, Brush handleFill)
    {
        if (_turnDrag is { } d && d.Page == page)
        {
            var corners = ContentTurn.Corners(new RectD(d.Shown.X, d.Shown.Y, d.Shown.Width, d.Shown.Height), d.Angle - d.Start);
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                g.BeginFigure(new Point(corners[0].X, corners[0].Y), false, true);
                g.PolyLineTo([.. corners.Skip(1).Select(p => new Point(p.X, p.Y))], true, false);
            }
            geo.Freeze();
            dc.DrawGeometry(null, Frozen(new Pen(accent, 1.5) { DashStyle = DashStyles.Dash }), geo);
            var ft = new FormattedText(ContentTurn.Format(d.Angle), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12,
                _highContrast ? SystemColors.HighlightTextBrush : Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            var at = new Point(d.Shown.Right + ContentTurn.HandleGap + 12, d.Shown.Y - ContentTurn.HandleGap - ft.Height / 2);
            dc.DrawRoundedRectangle(accent, null, new Rect(at.X - 6, at.Y - 2, ft.Width + 12, ft.Height + 4), 4, 4);
            dc.DrawText(ft, at);
            return;
        }
        if (TurnHandleRect(page) is not { } r) return;
        var h = ContentTurn.HandlePoint(new RectD(r.X, r.Y, r.Width, r.Height));
        var pen = Frozen(new Pen(accent, 1.5));
        dc.DrawLine(pen, new Point(r.Right, r.Y), new Point(h.X, h.Y));
        dc.DrawEllipse(handleFill, pen, new Point(h.X, h.Y), HandlePx / 2 + 1, HandlePx / 2 + 1);
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    /// <summary>DevScript's turndrag: a drag of the handle from its knob to (dx, dy) DIPs away, as the mouse would.</summary>
    internal bool DevTurnDrag(double dx, double dy, bool shift)
    {
        if (TurnTarget() is not { } t) return false;
        var r = ToSurfaceRect(t.Page, t.Box);
        var h = ContentTurn.HandlePoint(new RectD(r.X, r.Y, r.Width, r.Height));
        var press = new Point(h.X, h.Y);
        if (!TurnHandleDown(t.Page, press)) return false;
        var c = new PointD(r.X + r.Width / 2, r.Y + r.Height / 2);
        if (_turnDrag is { } d)
            _turnDrag = d with { Angle = ContentTurn.Dragged(c, new PointD(press.X, press.Y), new PointD(press.X + dx, press.Y + dy), d.Start, shift) };
        _dragged = true;
        var done = EndTurnDrag();
        _dragged = false;
        _surface.ReleaseMouseCapture();
        return done;
    }
}
