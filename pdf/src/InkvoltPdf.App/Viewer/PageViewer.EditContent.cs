using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>What the user asked for on the selected picture.</summary>
public enum ContentAction { Delete, Replace }

/// <summary>Text typed over a run (committed with Enter or by clicking elsewhere).</summary>
public sealed record RunEdit(TextRun Run, string Text);

/// <summary>
/// A paragraph's new text (committed with Enter or by clicking elsewhere; Shift+Enter is a line break in it) and the
/// stretches of it with a look of their own.
/// </summary>
public sealed record ParagraphEdit(TextParagraph Paragraph, string Text, IReadOnlyList<TextSpan> Spans);

/// <summary>A picture dragged or nudged to a new box (page space).</summary>
public sealed record ImageMove(PageImage Image, RectD Box);

/// <summary>
/// Edit Text &amp; Images on top of the page view (<see cref="ViewerTool.EditContent"/>): pieces of text show a frame
/// under the pointer and open an editor in place on a click, sized and styled like the text, with its width
/// compared live to the original's and the characters its font lacks named; text in a paragraph of several lines (or
/// runs) frames and edits the whole paragraph, wrapping in its box, with its line count and what it would run into
/// below said live; pictures show a frame, a click selects one,
/// a drag moves it, its handles resize it (Shift keeps its proportions), arrow keys nudge it (Shift: 10 pt; written
/// once the keys rest), Delete removes it, Enter replaces it. Tab goes through the page's text and pictures. The host
/// reads each page's content (<see cref="ContentNeeded"/> → <see cref="SetPageContent"/>) and turns gestures into edits.
/// </summary>
public sealed partial class PageViewer
{
    private Dictionary<int, PageContent> _contentByPage = [];
    private readonly HashSet<int> _contentAsked = [];
    private (int Page, RectD Box)? _imageSel;
    private (int Page, int Index)? _contentFocus; // keyboard: a run (or, past the runs, a picture) of a page
    private TextRun? _hoverRun;
    private PageImage? _hoverImage;
    private TextRun? _editorRun;
    private TextParagraph? _editorParagraph; // with _editorRun (its first run) when the editor holds a whole paragraph
    private Border? _runInfo;
    private TextBlock? _runInfoText;

    private sealed record ImageDrag(PageImage Image, int Handle, Point Press, Vector Offset, RectD Start, RectD Rect);
    private ImageDrag? _imageDrag;
    private readonly Dictionary<(int Page, int Id), RectD> _imagePending = []; // shown until the document catches up
    private Vector _imageNudge;
    private DispatcherTimer? _imageNudgeTimer;

    /// <summary>The page's text and pictures are needed (shown in Edit Text &amp; Images and not read yet).</summary>
    public event EventHandler<int>? ContentNeeded;
    public event EventHandler<RunEdit>? RunEdited;
    public event EventHandler<ParagraphEdit>? ParagraphEdited;
    public event EventHandler<ImageMove>? ImageMoved;
    public event EventHandler<ContentAction>? ContentActionRequested;
    /// <summary>A click on text or a picture that can't be edited: why (a sentence for the user).</summary>
    public event EventHandler<string>? ContentRefused;
    public event EventHandler? ContentSelectionChanged;

    public bool IsEditingContent => _tool == ViewerTool.EditContent;

    /// <summary>The selected picture as last read (null: none, or not read yet).</summary>
    public PageImage? SelectedImage =>
        _imageSel is { } s && _contentByPage.TryGetValue(s.Page, out var c) ? c.Images.FirstOrDefault(i => Near(i.Box, s.Box)) : null;

    /// <summary>The run whose editor is open.</summary>
    public TextRun? EditedRun => _editorRun;

    /// <summary>The live note under the open editor (null: none).</summary>
    public string? EditorNote => _runInfoText?.Text;

    /// <summary>The paragraph whose editor is open (null: none, or a single run's).</summary>
    public TextParagraph? EditedParagraph => _editorParagraph;

    /// <summary>
    /// The paragraph a run is edited as: its paragraph when that can be rewritten as one and is more than the run alone
    /// (several lines, or a line drawn in pieces); else null, and the run is edited on its own.
    /// </summary>
    private static TextParagraph? EditableParagraph(PageContent content, TextRun run) =>
        content.ParagraphOf(run) is { Blocked: null } p && (p.Lines.Count > 1 || p.Runs.Count > 1) ? p : null;

    public void SetPageContent(int page, PageContent content)
    {
        _contentByPage[page] = content;
        _contentAsked.Remove(page);
        foreach (var key in _imagePending.Keys.Where(k => k.Page == page).ToList()) _imagePending.Remove(key);
        _surface.InvalidateVisual();
        ContentSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Forgets what was read (the document changed): pages ask again as they show.</summary>
    public void ClearPageContent()
    {
        _contentByPage = [];
        _contentAsked.Clear();
        _hoverRun = null;
        _hoverImage = null;
        _surface.InvalidateVisual();
    }

    /// <summary>Selects a picture by its box (it may have just moved: the nearest one there once read).</summary>
    public void SelectImage(int page, RectD? box)
    {
        FlushImageNudge();
        _imageSel = box is { } b ? (page, b) : null;
        _surface.InvalidateVisual();
        ContentSelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnContentToolChanged()
    {
        if (IsEditingContent) return;
        FlushImageNudge();
        _imageDrag = null;
        _imageSel = null;
        _contentFocus = null;
        _hoverRun = null;
        _hoverImage = null;
        _imagePending.Clear();
        _contentByPage = [];
        _contentAsked.Clear();
    }

    private static bool Near(RectD a, RectD b) =>
        Math.Abs(a.X - b.X) < 1 && Math.Abs(a.Y - b.Y) < 1 && Math.Abs(a.Width - b.Width) < 1 && Math.Abs(a.Height - b.Height) < 1;

    private PageContent? ContentOf(int page)
    {
        if (_contentByPage.TryGetValue(page, out var c)) return c;
        if (_contentAsked.Add(page)) ContentNeeded?.Invoke(this, page);
        return null;
    }

    /// <summary>Where a picture shows: its box, or where it was just moved to (until the document catches up).</summary>
    private RectD ShownBox(PageImage i)
    {
        var r = _imagePending.TryGetValue((i.PageIndex, i.Id), out var p) ? p : i.Box;
        if (_imageDrag is { } d && d.Image == i) r = d.Rect;
        if (_imageSel is { } s && s.Page == i.PageIndex && Near(s.Box, i.Box) && _imageNudge != default) r = r with { X = r.X + _imageNudge.X, Y = r.Y + _imageNudge.Y };
        return r;
    }

    private int ImageHandleAt(int page, Point sp)
    {
        if (SelectedImage is not { Blocked: null } img || img.PageIndex != page) return -1;
        var r = ToSurfaceRect(page, ShownBox(img));
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

    /// <summary>Edit Text &amp; Images presses: edit a run, select / move / resize a picture. True if consumed.</summary>
    private bool HandleContentDown(MouseButtonEventArgs e, int page, Point sp)
    {
        if (!IsEditingContent || e.ChangedButton != MouseButton.Left) return false;
        e.Handled = true;
        if (page < 0) return true;
        FlushImageNudge();
        if (ImageHandleAt(page, sp) is var h and >= 0)
        {
            StartImageDrag(SelectedImage!, h, sp);
            return true;
        }
        if (ContentOf(page) is not { } content) return true; // still being read
        var pt = ToPagePoint(page, sp);
        var image = content.Images.LastOrDefault(i => ShownBox(i).Contains(pt.X, pt.Y));
        var selected = SelectedImage;
        var run = content.RunAt(pt.X, pt.Y) ?? content.ParagraphAt(pt.X, pt.Y)?.Runs[0]; // between a paragraph's lines: the paragraph
        // Text on a picture wins, except over the selected picture (so it can be dragged).
        if (run is not null && !(image is not null && selected is not null && image == selected))
        {
            _contentFocus = (page, content.Runs.ToList().IndexOf(run));
            if (run.Blocked is { } why)
            {
                ContentRefused?.Invoke(this, $"This text can't be edited: {why}.");
                _surface.InvalidateVisual();
                return true;
            }
            SelectImage(page, null);
            OpenTextEditor(content, run);
            return true;
        }
        if (image is not null)
        {
            SelectImage(page, image.Box);
            _contentFocus = (page, content.Runs.Count + content.Images.ToList().IndexOf(image));
            if (image.Blocked is { } why) ContentRefused?.Invoke(this, $"This picture can't be edited: {why}.");
            else if (e.ClickCount >= 2) ContentActionRequested?.Invoke(this, ContentAction.Replace);
            else StartImageDrag(image, -1, sp);
            return true;
        }
        if (_imageSel is not null) SelectImage(page, null);
        _panning = true; // an empty spot scrolls, as with the hand tool
        _surface.CaptureMouse();
        return true;
    }

    private void StartImageDrag(PageImage image, int handle, Point sp)
    {
        var offset = new Vector();
        var shown = ShownBox(image);
        if (handle >= 0)
        {
            var r = ToSurfaceRect(image.PageIndex, shown);
            var hp = DrawingGeometry.HandlePoint(new RectD(r.X, r.Y, r.Width, r.Height), handle);
            var k = _zoom * PtToDip;
            offset = new Vector((hp.X - sp.X) / k, (hp.Y - sp.Y) / k);
        }
        _imageDrag = new ImageDrag(image, handle, sp, offset, shown, shown);
        _surface.CaptureMouse();
        _surface.InvalidateVisual();
    }

    private bool MoveImageDrag(Point sp)
    {
        if (_imageDrag is not { } d) return false;
        if (!_dragged) return true;
        var page = d.Image.PageIndex;
        var g = _engine!.GetPage(page);
        RectD r;
        if (d.Handle < 0)
        {
            var a = ToPagePoint(page, d.Press);
            var b = ToPagePoint(page, sp);
            // A picture may hang over the page's edge; keep at least part of it on the page.
            var dx = Math.Clamp(b.X - a.X, -d.Start.Right + 8, g.Width - d.Start.X - 8);
            var dy = Math.Clamp(b.Y - a.Y, -d.Start.Bottom + 8, g.Height - d.Start.Y - 8);
            r = d.Start with { X = d.Start.X + dx, Y = d.Start.Y + dy };
        }
        else
        {
            var vp = ToViewPoint(page, sp);
            vp = new PointD(vp.X + d.Offset.X, vp.Y + d.Offset.Y);
            var view = RotatedView.ToView(d.Start, g.Width, g.Height, _viewRotation);
            var sized = DrawingGeometry.Resize(view, d.Handle, vp, 4, keepAspect: (Keyboard.Modifiers & ModifierKeys.Shift) != 0);
            r = RotatedView.FromView(sized, g.Width, g.Height, _viewRotation);
        }
        _imageDrag = d with { Rect = r };
        _surface.InvalidateVisual();
        return true;
    }

    private bool EndImageDrag()
    {
        if (_imageDrag is not { } d) return false;
        _imageDrag = null;
        _surface.InvalidateVisual();
        if (_dragged && !Near(d.Rect, d.Start))
        {
            _imagePending[(d.Image.PageIndex, d.Image.Id)] = d.Rect;
            ImageMoved?.Invoke(this, new ImageMove(d.Image, d.Rect));
        }
        return true;
    }

    private void CancelImageDrag()
    {
        if (_imageDrag is null) return;
        _imageDrag = null;
        _surface.InvalidateVisual();
    }

    private Cursor? ContentCursor(int page, Point sp)
    {
        if (!IsEditingContent) return null;
        TextRun? run = null;
        PageImage? image = null;
        Cursor cursor = Cursors.Arrow;
        if (page >= 0 && ImageHandleAt(page, sp) is var h and >= 0)
            cursor = h is 0 or 4 ? Cursors.SizeNWSE : h is 2 or 6 ? Cursors.SizeNESW : h is 1 or 5 ? Cursors.SizeNS : Cursors.SizeWE;
        else if (page >= 0 && ContentOf(page) is { } content)
        {
            var pt = ToPagePoint(page, sp);
            image = content.Images.LastOrDefault(i => ShownBox(i).Contains(pt.X, pt.Y));
            run = content.RunAt(pt.X, pt.Y) ?? content.ParagraphAt(pt.X, pt.Y)?.Runs[0];
            if (run is not null && image is not null && image == SelectedImage) run = null;
            if (run is not null) image = null;
            cursor = run is { Blocked: null } ? Cursors.IBeam : image is { Blocked: null } ? Cursors.SizeAll : Cursors.Arrow;
        }
        if (run != _hoverRun || image != _hoverImage)
        {
            _hoverRun = run;
            _hoverImage = image;
            _surface.InvalidateVisual();
        }
        return cursor;
    }

    // ───────────────────────────── Text editor ─────────────────────────────

    /// <summary>Opens the editor on a run's paragraph, or on the run alone (see <see cref="EditableParagraph"/>).</summary>
    private void OpenTextEditor(PageContent content, TextRun run)
    {
        if (EditableParagraph(content, run) is { } p) OpenParagraphEditor(p);
        else OpenRunEditor(run);
    }

    private static TextBox NewTextEditor(TextRun run, string text) => new()
    {
        Text = text,
        FontFamily = new FontFamily(FontNames.Family(run.FontName) + ", Arial"),
        FontWeight = run.Bold ? FontWeights.Bold : FontWeights.Normal,
        FontStyle = run.Italic ? FontStyles.Italic : FontStyles.Normal,
        Padding = new Thickness(0),
        MinHeight = 0,
        BorderThickness = new Thickness(1),
        Background = new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF)),
        // Its own color, unless that is too light to read on the editor's white.
        Foreground = (run.Color >> 16 & 0xFF) + (run.Color >> 8 & 0xFF) + (run.Color & 0xFF) > 600
            ? Brushes.Black
            : new SolidColorBrush(Color.FromRgb((byte)(run.Color >> 16), (byte)(run.Color >> 8), (byte)run.Color)),
        CaretBrush = Brushes.Black,
    };

    /// <summary>
    /// An editor over a whole paragraph: wrapping in its box with its alignment, growing downward as it fills, its
    /// stretches in their looks, with the look bar over it for the selection.
    /// </summary>
    private void OpenParagraphEditor(TextParagraph p)
    {
        var run = p.Lead;
        _paraK = 1;
        var box = NewParagraphEditor(p);
        ScaleParagraphEditor(box, p, _zoom * PtToDip); // its sizes at the zoom before anything reads them
        box.ToolTip = "Type, then press Enter or click elsewhere. Shift+Enter starts a new line. Esc cancels. The bar above changes the selection's look.";
        box.SetResourceReference(BorderBrushProperty, "AccentFillColorDefaultBrush");
        System.Windows.Automation.AutomationProperties.SetName(box, "Paragraph text");
        System.Windows.Automation.AutomationProperties.SetHelpText(box,
            "Edits this paragraph in its own font; the text rewraps in the paragraph's box. The bar above gives the selected text another font, size, color, bold or italic. Enter applies, Shift+Enter starts a new line, Escape cancels.");
        ShowEditor(box, null, null);
        _editorRun = run; // ShowEditor closes any previous editor first
        _editorParagraph = p;
        box.TextChanged += (_, _) => UpdateRunInfo();
        box.SizeChanged += (_, _) => PlaceRunInfo();
        box.SelectAll();
        ShowLookBar(p, box);
        ShowRunInfo();
    }

    private void OpenRunEditor(TextRun run)
    {
        var box = NewTextEditor(run, run.Text);
        box.AcceptsReturn = false;
        box.ToolTip = "Type, then press Enter or click elsewhere. Esc cancels.";
        box.SetResourceReference(BorderBrushProperty, "AccentFillColorDefaultBrush");
        System.Windows.Automation.AutomationProperties.SetName(box, "Page text");
        System.Windows.Automation.AutomationProperties.SetHelpText(box, "Edits this text in its own font. Enter applies, Escape cancels.");
        _editorRun = run;
        ShowEditor(box, null, null);
        _editorRun = run; // ShowEditor closes any previous editor first
        box.TextChanged += (_, _) => UpdateRunInfo();
        box.SelectAll();
        ShowRunInfo();
    }

    /// <summary>
    /// The live note under the editor: the new width against the old (a paragraph: its line count and whether it would
    /// run into what follows below), or the characters the font can't draw.
    /// </summary>
    private void ShowRunInfo()
    {
        _runInfoText = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 };
        _runInfo = new Border
        {
            Child = _runInfoText,
            Padding = new Thickness(6, 3, 6, 3),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1),
            IsHitTestVisible = false,
        };
        _runInfo.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorQuarternaryBrush");
        _runInfo.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        _runInfoText.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorPrimaryBrush");
        System.Windows.Automation.AutomationProperties.SetLiveSetting(_runInfoText, System.Windows.Automation.AutomationLiveSetting.Polite);
        _overlay.Children.Add(_runInfo);
        UpdateRunInfo();
        PositionEditor();
    }

    private void UpdateRunInfo()
    {
        if (_editorParagraph is { } p && _editor is RichTextBox rb && _runInfoText is not null && _runInfo is not null)
        {
            var (text, spans) = ParagraphContent(rb, p);
            UpdateParagraphInfo(p, text, spans);
            return;
        }
        if (_editorRun is not { } run || _editor is not TextBox tb || _runInfoText is null || _runInfo is null) return;
        var check = run.Check(tb.Text);
        string note;
        var problem = false;
        if (check.Missing.Count > 0)
        {
            problem = true;
            var list = string.Join(", ", check.Missing.Take(10).Select(c => c == " " ? "space" : $"“{c}”")) + (check.Missing.Count > 10 ? " …" : "");
            note = $"The font “{run.FontName}” has no {list} in this PDF, so those can't be typed here.";
        }
        else
        {
            var diff = check.Width - check.OldWidth;
            note = Math.Abs(diff) < 0.5
                ? $"Width {check.Width.ToString("0", CultureInfo.CurrentCulture)} pt, as before."
                : diff > 0
                    ? $"{diff.ToString("0", CultureInfo.CurrentCulture)} pt wider than before: it may run into what follows (text doesn't reflow)."
                    : $"{(-diff).ToString("0", CultureInfo.CurrentCulture)} pt narrower than before.";
            problem = diff > 0.5;
        }
        _runInfoText.Text = note;
        if (problem) _runInfoText.SetResourceReference(TextBlock.ForegroundProperty, check.Missing.Count > 0 ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush");
        else _runInfoText.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        if (_highContrast) _runInfoText.Foreground = SystemColors.WindowTextBrush;
        System.Windows.Automation.AutomationProperties.SetName(_runInfoText, note);
    }

    private void UpdateParagraphInfo(TextParagraph p, string text, IReadOnlyList<TextSpan> spans)
    {
        var check = p.Check(text, spans);
        string note;
        string? brush = null;
        if (check.Missing.Count > 0)
        {
            note = $"Neither the font “{p.Lead.FontName}” nor any font on this PC has {CharList(check.Missing)}, so those can't be typed here.";
            brush = "SystemFillColorCriticalBrush";
        }
        else
        {
            var lines = check.LineCount == 1 ? "1 line" : $"{check.LineCount.ToString(CultureInfo.CurrentCulture)} lines";
            var was = check.LineCount == p.Lines.Count ? "as before" : $"was {p.Lines.Count.ToString(CultureInfo.CurrentCulture)}";
            if (check.LookProblem is { } lp)
            {
                note = $"{lines} ({was}), but {lp}.";
                brush = "SystemFillColorCriticalBrush";
            }
            else if (check.Overlaps is not null)
            {
                note = $"{lines} ({was}): it would run into what follows below. You'll be asked before it is written.";
                brush = "SystemFillColorCautionBrush";
            }
            else note = $"{lines} ({was}), in the paragraph's box. Enter applies, Shift+Enter starts a new line.";
            // Characters the paragraph's font lacks: never drawn from another font silently.
            if (check.Borrowed.Count > 0)
                note += $"\n{CharList(check.Borrowed)} {(check.Borrowed.Count == 1 ? "isn't" : "aren't")} in this PDF's copy of “{p.Lead.FontName}”: drawn in " +
                        $"{string.Join(" and ", check.StandIns)}, the closest font on this PC.";
            if (check.Faces.Count > 0) note += $"\nDrawn in {string.Join(", ", check.Faces)} where the look asks for it (fonts on this PC, embedded as used).";
        }
        _runInfoText!.Text = note;
        _runInfoText.SetResourceReference(TextBlock.ForegroundProperty, brush ?? "TextFillColorSecondaryBrush");
        if (_highContrast) _runInfoText.Foreground = SystemColors.WindowTextBrush;
        System.Windows.Automation.AutomationProperties.SetName(_runInfoText, note);
    }

    /// <summary>Characters for a note: “@”, “#” (a space as "space"), at most ten.</summary>
    private static string CharList(IReadOnlyList<string> chars) =>
        string.Join(", ", chars.Take(10).Select(c => c == " " ? "space" : char.IsControl(c[0]) || char.GetUnicodeCategory(c, 0) == UnicodeCategory.PrivateUse ? $"U+{char.ConvertToUtf32(c, 0):X4}" : $"“{c}”"))
        + (chars.Count > 10 ? " …" : "");

    /// <summary>Lays the paragraph editor over the paragraph's box (its width; as tall as its text), the look bar over it and the note under it.</summary>
    private void PositionParagraphEditor(TextParagraph p, RichTextBox tb, double k)
    {
        var r = ToSurfaceRect(p.PageIndex, p.Box);
        var turn = ((int)Math.Round(_viewRotation / 90.0) * 90 % 360 + 360) % 360;
        var (length, thickness) = turn is 90 or 270 ? (r.Height, r.Width) : (r.Width, r.Height);
        ScaleParagraphEditor(tb, p, k);
        // The box's width inside the border and the text box's own margins, so its lines break where the page's do
        // when the screen font is the PDF's.
        tb.Width = Math.Max(length, 40) + 12;
        tb.Height = double.NaN;
        tb.MinHeight = Math.Max(thickness, tb.FontSize * 1.2) + 2;
        tb.LayoutTransform = turn == 0 ? Transform.Identity : Frozen(new RotateTransform(turn));
        Canvas.SetLeft(tb, r.X - 1);
        Canvas.SetTop(tb, r.Y - 1);
        PlaceLookBar(r);
        PlaceRunInfo();
    }

    /// <summary>The note under the paragraph editor as it grows (beside it when the page is turned).</summary>
    private void PlaceRunInfo()
    {
        if (_editorParagraph is not { } p || _editor is not RichTextBox tb || _runInfo is null || p.PageIndex >= _rects.Length) return;
        var r = ToSurfaceRect(p.PageIndex, p.Box);
        var turn = ((int)Math.Round(_viewRotation / 90.0) * 90 % 360 + 360) % 360;
        _runInfo.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var w = _runInfo.DesiredSize.Width;
        var tall = Math.Max(tb.ActualHeight, turn is 90 or 270 ? r.Width : r.Height);
        if (turn is 90 or 270)
        {
            Canvas.SetLeft(_runInfo, r.X - w - 6 >= Viewport.Left ? r.X - w - 6 : r.X - 1 + tall + 6);
            Canvas.SetTop(_runInfo, r.Y);
        }
        else
        {
            Canvas.SetLeft(_runInfo, r.X);
            Canvas.SetTop(_runInfo, r.Y - 1 + tall + 4);
        }
    }

    /// <summary>Lays the editor over its run (font size and the page's turn applied) and the note under it.</summary>
    private void PositionRunEditor(double k)
    {
        if (_editorParagraph is { } para && _editor is RichTextBox prb)
        {
            PositionParagraphEditor(para, prb, k);
            return;
        }
        if (_editorRun is not { } run || _editor is not TextBox tb) return;
        var r = ToSurfaceRect(run.PageIndex, run.Box);
        var turn = ((int)Math.Round((run.Angle + _viewRotation) / 90) * 90 % 360 + 360) % 360;
        var straight = Math.Abs(run.Angle - Math.Round(run.Angle / 90) * 90) < 1;
        if (!straight) turn = 0;
        var (length, thickness) = turn is 90 or 270 ? (r.Height, r.Width) : (r.Width, r.Height);
        tb.FontSize = Math.Max(6, run.FontSize * k);
        tb.MinWidth = Math.Max(length, 24);
        tb.Height = Math.Max(thickness, tb.FontSize * 1.2) + 2;
        tb.LayoutTransform = turn == 0 ? Transform.Identity : Frozen(new RotateTransform(turn));
        Canvas.SetLeft(tb, r.X - 1);
        Canvas.SetTop(tb, r.Y - 1);
        if (_runInfo is not null)
        {
            // Under the text; beside it (on the side with room) when the text runs up or down the screen.
            _runInfo.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var w = _runInfo.DesiredSize.Width;
            var left = turn is 90 or 270 ? (r.X - w - 6 >= Viewport.Left ? r.X - w - 6 : r.Right + 6) : r.X;
            Canvas.SetLeft(_runInfo, left);
            Canvas.SetTop(_runInfo, turn is 90 or 270 ? r.Y : r.Bottom + 4);
        }
    }

    private void CommitRunText(TextRun run, string text)
    {
        if (text != run.Text) RunEdited?.Invoke(this, new RunEdit(run, text));
    }

    /// <summary>A paragraph's text and looks, when either changed.</summary>
    private void CommitParagraph(TextParagraph p, RichTextBox box)
    {
        var (text, spans) = ParagraphContent(box, p);
        var same = text == p.Text && spans.Count == p.Spans.Count && spans.Zip(p.Spans).All(x => x.First == x.Second);
        if (!same) ParagraphEdited?.Invoke(this, new ParagraphEdit(p, text, spans));
    }

    private void CloseRunInfo()
    {
        if (_runInfo is not null) _overlay.Children.Remove(_runInfo);
        CloseLookBar();
        _runInfo = null;
        _runInfoText = null;
        _editorRun = null;
        _editorParagraph = null;
    }

    // ───────────────────────────── Keys ─────────────────────────────

    private bool HandleContentKey(KeyEventArgs e)
    {
        if (!IsEditingContent) return false;
        var mods = Keyboard.Modifiers;
        var image = SelectedImage;
        switch (e.Key)
        {
            case Key.Tab when (mods & ~ModifierKeys.Shift) == 0:
                StepContentFocus((mods & ModifierKeys.Shift) != 0 ? -1 : 1);
                return true;
            case Key.Enter or Key.F2 when mods == ModifierKeys.None && FocusedRun() is { } run:
                if (run.Blocked is { } why) ContentRefused?.Invoke(this, $"This text can't be edited: {why}.");
                else OpenTextEditor(_contentByPage[_contentFocus!.Value.Page], run);
                return true;
            case Key.Enter when mods == ModifierKeys.None && image is { Blocked: null }:
                FlushImageNudge();
                ContentActionRequested?.Invoke(this, ContentAction.Replace);
                return true;
            case Key.Delete or Key.Back when mods == ModifierKeys.None && image is { Blocked: null }:
                FlushImageNudge();
                ContentActionRequested?.Invoke(this, ContentAction.Delete);
                return true;
            case Key.Left or Key.Right or Key.Up or Key.Down when mods is ModifierKeys.None or ModifierKeys.Shift && image is { Blocked: null }:
                NudgeImage(image, e.Key, mods == ModifierKeys.Shift ? 10 : 1);
                return true;
            case Key.Escape when mods == ModifierKeys.None:
                FlushImageNudge();
                if (_imageSel is not null || _contentFocus is not null)
                {
                    _contentFocus = null;
                    SelectImage(0, null);
                }
                else Tool = ViewerTool.Hand;
                return true;
        }
        return false;
    }

    private TextRun? FocusedRun() =>
        _contentFocus is { } f && _contentByPage.TryGetValue(f.Page, out var c) && f.Index < c.Runs.Count ? c.Runs[f.Index] : null;

    /// <summary>Tab order: the current page's text in content order, then its pictures; then the next page's.</summary>
    private void StepContentFocus(int step)
    {
        FlushImageNudge();
        var page = _contentFocus?.Page ?? _imageSel?.Page ?? CurrentPage;
        for (var guard = 0; guard < 3; guard++)
        {
            if (ContentOf(page) is not { } c) return; // being read: try again in a moment
            var count = c.Runs.Count + c.Images.Count;
            var at = _contentFocus is { } f && f.Page == page ? f.Index : step > 0 ? -1 : count;
            var next = at + step;
            if (next >= 0 && next < count)
            {
                _contentFocus = (page, next);
                if (next < c.Runs.Count)
                {
                    var run = c.Runs[next];
                    SelectImage(page, null);
                    EnsureVisible(page, run.Box);
                    ContentAnnounce?.Invoke(this, run.Blocked is null ? $"Text: {run.Text}. Enter edits it." : $"Text: {run.Text}. Can't be edited: {run.Blocked}.");
                }
                else
                {
                    var img = c.Images[next - c.Runs.Count];
                    SelectImage(page, img.Box);
                    EnsureVisible(page, img.Box);
                    ContentAnnounce?.Invoke(this, img.Blocked is null
                        ? "Picture selected. Arrow keys move it, Delete removes it, Enter replaces it."
                        : $"Picture. Can't be edited: {img.Blocked}.");
                }
                _surface.InvalidateVisual();
                return;
            }
            var np = page + step;
            if (np < 0 || np >= PageCount) return;
            page = np;
            _contentFocus = null;
        }
    }

    /// <summary>Something for the screen reader (the host speaks it).</summary>
    public event EventHandler<string>? ContentAnnounce;

    private void NudgeImage(PageImage image, Key key, double step)
    {
        var (vx, vy) = key switch { Key.Left => (-step, 0.0), Key.Right => (step, 0.0), Key.Up => (0.0, -step), _ => (0.0, step) };
        var g = _engine!.GetPage(image.PageIndex);
        var (x0, y0) = RotatedView.FromView(0, 0, g.Width, g.Height, _viewRotation);
        var (x1, y1) = RotatedView.FromView(vx, vy, g.Width, g.Height, _viewRotation);
        _imageNudge += new Vector(x1 - x0, y1 - y0);
        if (_imageNudgeTimer is null)
        {
            _imageNudgeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
            _imageNudgeTimer.Tick += (_, _) => FlushImageNudge();
        }
        _imageNudgeTimer.Stop();
        _imageNudgeTimer.Start();
        _surface.InvalidateVisual();
    }

    /// <summary>Writes the arrow-key moves made so far (called before anything else acts on the selection).</summary>
    public void FlushImageNudge()
    {
        _imageNudgeTimer?.Stop();
        if (_imageNudge == default || SelectedImage is not { } image)
        {
            _imageNudge = default;
            return;
        }
        var v = _imageNudge;
        _imageNudge = default;
        var start = _imagePending.TryGetValue((image.PageIndex, image.Id), out var p) ? p : image.Box;
        var r = start with { X = start.X + v.X, Y = start.Y + v.Y };
        _imagePending[(image.PageIndex, image.Id)] = r;
        _surface.InvalidateVisual();
        ImageMoved?.Invoke(this, new ImageMove(image, r));
    }

    // ───────────────────────────── Painting ─────────────────────────────

    private static readonly Pen RefusedPen = Frozen(new Pen(new SolidColorBrush(Color.FromRgb(0x80, 0x80, 0x80)), 1) { DashStyle = DashStyles.Dot });

    private void PaintContent(DrawingContext dc, int page)
    {
        if (!IsEditingContent || ContentOf(page) is not { } content) return;
        var accent = _highContrast ? SystemColors.HighlightBrush : TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.RoyalBlue;
        var handleFill = _highContrast ? SystemColors.WindowBrush : TryFindResource("ControlSolidFillColorDefaultBrush") as Brush ?? Brushes.White;
        var thin = Frozen(new Pen(accent, 1) { DashStyle = DashStyles.Dash });
        var solid = Frozen(new Pen(accent, 1));
        var bold = Frozen(new Pen(accent, 2));
        var focused = FocusedRun();
        var selected = SelectedImage;

        foreach (var img in content.Images)
        {
            var r = ToSurfaceRect(page, ShownBox(img));
            var isSel = selected is not null && img == selected;
            dc.DrawRectangle(null, img.Blocked is not null ? RefusedPen : isSel ? bold : thin, r);
            if (!isSel || img.Blocked is not null) continue;
            var frame = new RectD(r.X, r.Y, r.Width, r.Height);
            for (var i = 0; i < 8; i++)
            {
                var hp = DrawingGeometry.HandlePoint(frame, i);
                dc.DrawRoundedRectangle(handleFill, Frozen(new Pen(accent, 1.5)), new Rect(hp.X - HandlePx / 2, hp.Y - HandlePx / 2, HandlePx, HandlePx), 2, 2);
            }
        }
        var framed = new HashSet<TextParagraph>(ReferenceEqualityComparer.Instance);
        foreach (var run in content.Runs)
        {
            var hot = run == _hoverRun || run == focused;
            if (!hot || run == _editorRun) continue;
            // Text of a paragraph frames the paragraph: a click edits all of it.
            if (run.Blocked is null && EditableParagraph(content, run) is { } p)
            {
                if (!ReferenceEquals(p, _editorParagraph) && framed.Add(p)) dc.DrawRectangle(null, run == focused ? bold : solid, ToSurfaceRect(page, p.Box.Inflate(2)));
                continue;
            }
            var r = ToSurfaceRect(page, run.Box.Inflate(1));
            dc.DrawRectangle(null, run.Blocked is not null ? RefusedPen : run == focused ? bold : solid, r);
        }
        // The paragraph being edited: its box as it was (the editor grows from it).
        if (_editorParagraph is { } edited && edited.PageIndex == page) dc.DrawRectangle(null, bold, ToSurfaceRect(page, edited.Box.Inflate(2)));
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    internal PageContent? DevContent(int page) => _contentByPage.GetValueOrDefault(page);

    internal void DevEditRun(TextRun run, string? text)
    {
        OpenRunEditor(run);
        if (text is not null && _editor is TextBox tb) tb.Text = text;
    }

    /// <summary>Opens the editor on a paragraph (a literal \n in <paramref name="text"/> is a line break).</summary>
    internal void DevEditParagraph(TextParagraph p, string? text)
    {
        OpenParagraphEditor(p);
        if (text is null || _editor is not RichTextBox rb) return;
        var para = new System.Windows.Documents.Paragraph { Margin = new Thickness(0), TextAlignment = rb.Document.Blocks.OfType<System.Windows.Documents.Paragraph>().FirstOrDefault()?.TextAlignment ?? TextAlignment.Left };
        var lines = text.Split("\\n");
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0) para.Inlines.Add(new System.Windows.Documents.LineBreak());
            para.Inlines.Add(new System.Windows.Documents.Run(lines[i]));
        }
        rb.Document.Blocks.Clear();
        rb.Document.Blocks.Add(para);
    }

    internal void DevMoveImage(PageImage image, RectD box)
    {
        _imagePending[(image.PageIndex, image.Id)] = box;
        ImageMoved?.Invoke(this, new ImageMove(image, box));
    }

    internal void DevContentAction(ContentAction action) => ContentActionRequested?.Invoke(this, action);
}
