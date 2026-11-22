using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>
/// The paragraph editor's text as spell check reads it: each run's text in order, a line break (and a new block) as "\n",
/// so an offset into it is a place in the editor and back.
/// </summary>
internal sealed class EditorText
{
    private readonly List<(int Offset, Run Run)> _runs = [];

    public string Text { get; }

    private EditorText(RichTextBox box)
    {
        var sb = new System.Text.StringBuilder();
        void Walk(InlineCollection inlines)
        {
            foreach (var inline in inlines)
                switch (inline)
                {
                    case Run r:
                        _runs.Add((sb.Length, r));
                        sb.Append(r.Text);
                        break;
                    case LineBreak:
                        sb.Append('\n');
                        break;
                    case Span s:
                        Walk(s.Inlines);
                        break;
                    default:
                        sb.Append(TextParagraph.PictureMark); // a picture or a control: no word
                        break;
                }
        }
        var first = true;
        foreach (var block in box.Document.Blocks)
        {
            if (!first) sb.Append('\n');
            first = false;
            if (block is Paragraph p) Walk(p.Inlines);
        }
        Text = sb.ToString();
    }

    public static EditorText Of(RichTextBox box) => new(box);

    /// <summary>The place <paramref name="offset"/> characters in (inside a run), or null.</summary>
    public TextPointer? Pointer(int offset)
    {
        for (var i = _runs.Count - 1; i >= 0; i--)
        {
            var (at, run) = _runs[i];
            if (offset >= at && offset <= at + run.Text.Length) return run.ContentStart.GetPositionAtOffset(offset - at);
        }
        return null;
    }

    /// <summary>How far into the text a place is, or null when it is in no run.</summary>
    public int? Offset(TextPointer p)
    {
        foreach (var (at, run) in _runs)
            if (p.CompareTo(run.ContentStart) >= 0 && p.CompareTo(run.ContentEnd) <= 0)
                return at + run.ContentStart.GetOffsetToPosition(p);
        return null;
    }

    /// <summary>The stretch from <paramref name="start"/> to <paramref name="end"/> as it shows: on each line, its left and right edges and its bottom (the editor's coordinates).</summary>
    public List<(double Left, double Right, double Bottom)> Lines(int start, int end)
    {
        var result = new List<(double, double, double)>();
        for (var i = start; i < end; i++)
        {
            if (Pointer(i) is not { } a || Pointer(i + 1) is not { } b) continue;
            var left = a.GetCharacterRect(LogicalDirection.Forward);
            var right = b.GetCharacterRect(LogicalDirection.Backward);
            if (left.IsEmpty || right.IsEmpty) continue;
            if (result.Count > 0 && Math.Abs(result[^1].Item3 - left.Bottom) < left.Height / 2)
                result[^1] = (result[^1].Item1, Math.Max(result[^1].Item2, right.X), result[^1].Item3);
            else result.Add((left.X, Math.Max(left.X, right.X), left.Bottom));
        }
        return result;
    }
}

/// <summary>
/// A wavy red line under each word of the paragraph editor the spell checker doesn't know, drawn on the page view's
/// editor canvas through the editor's own transform (so it follows the zoom, the scroll and a turned page).
/// </summary>
internal sealed class SpellingUnderlines : FrameworkElement
{
    private static readonly Pen Wave = Frozen(new Pen(new SolidColorBrush(Color.FromRgb(0xE8, 0x11, 0x23)), 1));
    private static readonly Pen WaveHighContrast = new(SystemColors.HighlightBrush, 1.5);

    private readonly RichTextBox _box;
    private IReadOnlyList<Misspelling> _found = [];
    private (Point, Point) _drawnAt;

    public SpellingUnderlines(RichTextBox box)
    {
        _box = box;
        IsHitTestVisible = false;
    }

    public bool HighContrast { get; set; }

    public IReadOnlyList<Misspelling> Found => _found;

    public void Show(IReadOnlyList<Misspelling> found)
    {
        _found = found;
        InvalidateVisual();
    }

    /// <summary>After a layout pass: drawn again only when the editor moved (redrawing on every pass would never settle).</summary>
    public void Follow()
    {
        if (_found.Count == 0 || !_box.IsVisible || VisualParent is null) return;
        if (WhereIsBox() is { } t && Corners(t) != _drawnAt) InvalidateVisual();
    }

    private static (Point, Point) Corners(GeneralTransform t) => (t.Transform(new Point(0, 0)), t.Transform(new Point(100, 100)));

    private GeneralTransform? WhereIsBox()
    {
        try
        {
            return _box.TransformToVisual(this);
        }
        catch (InvalidOperationException)
        {
            return null; // not in the same tree (closing)
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (_found.Count == 0 || !_box.IsVisible || WhereIsBox() is not { } m) return;
        _drawnAt = Corners(m);
        var text = EditorText.Of(_box);
        var pen = HighContrast ? WaveHighContrast : Wave;
        foreach (var w in _found.Take(500))
        {
            // Typed over since it was checked: not underlined until it is checked again.
            if (w.End > text.Text.Length || string.CompareOrdinal(text.Text, w.Start, w.Word, 0, w.Word.Length) != 0) continue;
            foreach (var (left, right, bottom) in text.Lines(w.Start, w.End))
            {
                if (right - left < 1) continue;
                var g = new StreamGeometry();
                using (var c = g.Open())
                {
                    var y = bottom - 1.5;
                    c.BeginFigure(m.Transform(new Point(left, y)), false, false);
                    var up = true;
                    for (var x = left + 2; x <= right + 0.5; x += 2, up = !up)
                        c.LineTo(m.Transform(new Point(x, up ? y - 1.5 : y)), true, false);
                }
                g.Freeze();
                dc.DrawGeometry(null, pen, g);
            }
        }
    }

    private static Pen Frozen(Pen p)
    {
        p.Freeze();
        return p;
    }
}

/// <summary>
/// Spell check in the page view's editors (roadmap 4.1, <see cref="Spelling"/>): WPF's for the plain text boxes, and for
/// Edit Text &amp; Images' paragraph editor its own underlines (<see cref="SpellingUnderlines"/>) from Core's
/// <see cref="SpellChecker"/>, with suggestions, Ignore and Add to dictionary on right-click or the context menu key.
/// </summary>
public sealed partial class PageViewer
{
    private SpellChecker? _paraSpeller;
    private SpellingUnderlines? _paraUnderlines;

    /// <summary>The language the document's text is in, for spell check (the tab reads it); null: the interface's.</summary>
    public Func<string?>? DocumentLanguage { get; set; }

    /// <summary>WPF's spell check on a plain text box the page view opens.</summary>
    private void AttachSpelling(TextBox box) => Spelling.Attach(box, DocumentLanguage?.Invoke());

    /// <summary>The paragraph editor's own underlines and menu (nothing when spell check is off or Windows has no dictionary).</summary>
    private void AttachParagraphSpelling(RichTextBox box)
    {
        DetachParagraphSpelling();
        if (Spelling.For(DocumentLanguage?.Invoke()) is not { } speller) return;
        _paraSpeller = speller;
        _paraUnderlines = new SpellingUnderlines(box) { HighContrast = _highContrast };
        _overlay.Children.Add(_paraUnderlines);
        box.ContextMenuOpening += OnParagraphMenu;
        box.SizeChanged += (_, _) => _paraUnderlines?.InvalidateVisual();
        CheckParagraphSpelling();
    }

    private void DetachParagraphSpelling()
    {
        if (_paraUnderlines is not null) _overlay.Children.Remove(_paraUnderlines);
        _paraUnderlines = null;
        _paraSpeller = null;
    }

    /// <summary>Checks the paragraph editor's text again (as it changes: known words are remembered, so typing stays quick).</summary>
    private void CheckParagraphSpelling()
    {
        if (_paraSpeller is not { } speller || _paraUnderlines is not { } lines || _editor is not RichTextBox box) return;
        lines.Show(speller.Check(EditorText.Of(box).Text));
    }

    private void OnParagraphMenu(object sender, ContextMenuEventArgs e)
    {
        if (sender is not RichTextBox box) return;
        // From the keyboard (the context menu key, Shift+F10): the word at the caret.
        var mouse = !(e.CursorLeft < 0 && e.CursorTop < 0);
        var at = mouse ? box.GetPositionFromPoint(Mouse.GetPosition(box), snapToText: true) : box.CaretPosition;
        if (ParagraphMenu(box, at, mouse) is { } menu) box.ContextMenu = menu;
    }

    /// <summary>The paragraph editor's menu about the word at <paramref name="at"/> (right-clicked: the caret goes there).</summary>
    private ContextMenu? ParagraphMenu(RichTextBox box, TextPointer? at, bool clicked)
    {
        if (_paraSpeller is not { } speller) return null;
        var text = EditorText.Of(box);
        var found = speller.Check(text.Text);
        var word = at is not null && text.Offset(at) is { } offset ? SpellChecker.At(found, offset) : null;
        if (word is not null && clicked && !box.Selection.Contains(at!))
            box.CaretPosition = at!; // the right-clicked word is the one the menu is about
        return Spelling.Menu(box, word?.Word, word is { } m ? speller.Suggestions(m.Word) : [],
            s => CorrectParagraphWord(box, word!.Value, s),
            () =>
            {
                speller.Ignore(word!.Value.Word);
                CheckParagraphSpelling();
            },
            () =>
            {
                if (!speller.Add(word!.Value.Word)) Spelling.AddFailed(this, word.Value.Word);
                CheckParagraphSpelling();
            });
    }

    /// <summary>A suggestion in place of the misspelled word (in the word's own look), when the word is still there.</summary>
    private void CorrectParagraphWord(RichTextBox box, Misspelling word, string suggestion)
    {
        var text = EditorText.Of(box);
        if (SpellChecker.Correct(text.Text, word, suggestion) is null || text.Pointer(word.Start) is not { } from || text.Pointer(word.End) is not { } to) return;
        var range = new TextRange(from, to) { Text = suggestion };
        box.CaretPosition = range.End;
        box.Focus();
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    /// <summary>The open editor's spell check: its language and the words underlined (dev script).</summary>
    internal string DevSpelling()
    {
        if (_editor is RichTextBox && _paraSpeller is { } s && _paraUnderlines is { } u)
            return $"paragraph {s.Language}: [{string.Join(", ", u.Found.Select(m => $"{m.Word}@{m.Start}"))}]";
        if (_editor is RichTextBox) return "paragraph: no spell check";
        if (_editor is TextBox tb)
        {
            var words = new List<string>();
            for (var i = 0; i < tb.Text.Length; i++)
                if (tb.GetSpellingError(i) is not null && tb.GetSpellingErrorStart(i) == i)
                    words.Add($"{tb.Text.Substring(i, tb.GetSpellingErrorLength(i))}@{i}");
            return $"textbox {SpellCheck.GetIsEnabled(tb)} {tb.Language}: [{string.Join(", ", words)}]";
        }
        return "spelling: no editor open";
    }

    /// <summary>The menu the open editor would show at an offset of its text (dev script): its items, by header.</summary>
    internal string DevSpellingMenu(int offset)
    {
        Control editor;
        switch (_editor)
        {
            case RichTextBox box when EditorText.Of(box).Pointer(offset) is { } p:
                box.CaretPosition = p;
                box.ContextMenu = ParagraphMenu(box, p, clicked: false);
                editor = box;
                break;
            case TextBox tb:
                tb.CaretIndex = Math.Clamp(offset, 0, tb.Text.Length);
                tb.ContextMenu = Spelling.MenuAt(tb, tb.CaretIndex);
                editor = tb;
                break;
            default:
                return "spellmenu: no editor open";
        }
        return "spellmenu: " + string.Join(" | ", editor.ContextMenu?.Items.OfType<MenuItem>().Select(i => i.Header as string ?? (i.Command as RoutedUICommand)?.Text) ?? []);
    }

    /// <summary>Runs the open editor's menu item with that header (dev script; after <see cref="DevSpellingMenu"/>).</summary>
    internal void DevSpellingChoose(string header)
    {
        if ((_editor as Control)?.ContextMenu?.Items.OfType<MenuItem>().FirstOrDefault(i => (i.Header as string) == header) is { } item)
            item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
    }
}
