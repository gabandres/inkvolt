using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>
/// The paragraph editor of Edit Text &amp; Images (roadmap 2.1): a rich text box over the paragraph showing its text with
/// the looks stretches of it have (font, size, color, bold, italic), and a bar above it that gives the selection
/// another look. What it holds goes to the host as text and <see cref="TextSpan"/>s against the paragraph's own look.
/// </summary>
public sealed partial class PageViewer
{
    private Border? _lookBar;
    private ComboBox? _lookFont;
    private double _paraK = 1; // the scale the editor's font sizes are at (screen pixels per point)

    /// <summary>Colors the bar offers, after the paragraph's own.</summary>
    private static readonly (string Name, int Rgb)[] LookColors =
        [("Black", 0x000000), ("Dark gray", 0x595959), ("Red", 0xC00000), ("Blue", 0x0070C0), ("Green", 0x00803C), ("Orange", 0xE36C09)];

    private static Color ToColor(int rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    private static int ToRgb(Color c) => c.R << 16 | c.G << 8 | c.B;

    /// <summary>The paragraph's color as the editor shows it (black when it is too light to read on the editor's white).</summary>
    private static int ShownColor(TextRun lead) =>
        (lead.Color >> 16 & 0xFF) + (lead.Color >> 8 & 0xFF) + (lead.Color & 0xFF) > 600 ? 0 : lead.Color;

    private static string BaseFamily(TextParagraph p) => FontNames.Family(p.Lead.FontName);

    /// <summary>A rich text box holding the paragraph's text, its stretches in their looks (sizes set later, at the zoom).</summary>
    private RichTextBox NewParagraphEditor(TextParagraph p)
    {
        var lead = p.Lead;
        var para = new Paragraph { Margin = new Thickness(0) };
        para.TextAlignment = p.Align switch
        {
            ParagraphAlign.Center => TextAlignment.Center,
            ParagraphAlign.Right => TextAlignment.Right,
            ParagraphAlign.Justified => TextAlignment.Justify,
            _ => TextAlignment.Left,
        };
        var looks = new TextLook?[p.Text.Length];
        foreach (var s in p.Spans)
            for (var i = Math.Max(0, s.Start); i < Math.Min(looks.Length, s.End); i++) looks[i] = s.Look;
        for (var i = 0; i < p.Text.Length;)
        {
            var j = i + 1;
            while (j < p.Text.Length && looks[j] == looks[i] && p.Text[j] != '\n' && p.Text[i] != '\n') j++;
            if (p.Text[i] == '\n') para.Inlines.Add(new LineBreak());
            else
            {
                var run = new Run(p.Text[i..j]);
                if (looks[i] is { } look) ApplyLook(run, look);
                para.Inlines.Add(run);
            }
            i = j;
        }
        // The document's own defaults (Georgia) would win over the box's: it gets the paragraph's look itself.
        var doc = new FlowDocument(para)
        {
            PagePadding = new Thickness(0),
            LineStackingStrategy = LineStackingStrategy.MaxHeight,
            FontFamily = new FontFamily(BaseFamily(p) + ", Arial"),
            FontWeight = lead.Bold ? FontWeights.Bold : FontWeights.Normal,
            FontStyle = lead.Italic ? FontStyles.Italic : FontStyles.Normal,
            Foreground = new SolidColorBrush(ToColor(ShownColor(lead))),
        };
        var box = new RichTextBox(doc)
        {
            FontFamily = doc.FontFamily,
            FontWeight = doc.FontWeight,
            FontStyle = doc.FontStyle,
            Foreground = doc.Foreground,
            Padding = new Thickness(0),
            MinHeight = 0,
            BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF)),
            CaretBrush = Brushes.Black,
            AcceptsReturn = true,
            AcceptsTab = false,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        // Pasted text comes in plain (the looks are the bar's to give).
        DataObject.AddPastingHandler(box, (_, e) =>
        {
            if (e.DataObject.GetDataPresent(DataFormats.UnicodeText) && e.DataObject.GetData(DataFormats.UnicodeText) is string t)
            {
                var plain = new DataObject();
                plain.SetData(DataFormats.UnicodeText, t);
                e.DataObject = plain;
            }
        });
        return box;
    }

    /// <summary>Gives a run a look (its size in points: the editor sets it at the zoom).</summary>
    private void ApplyLook(TextElement e, TextLook look)
    {
        if (look.Font is { } f) e.FontFamily = new FontFamily(f + ", Arial");
        if (look.Size is { } s) e.FontSize = Math.Max(1, s * _paraK);
        if (look.Color is { } c) e.Foreground = new SolidColorBrush(ToColor(c));
        if (look.Bold is { } b) e.FontWeight = b ? FontWeights.Bold : FontWeights.Normal;
        if (look.Italic is { } i) e.FontStyle = i ? FontStyles.Italic : FontStyles.Normal;
    }

    /// <summary>The editor's text (line breaks as "\n") and the stretches whose look differs from the paragraph's own.</summary>
    private (string Text, List<TextSpan> Spans) ParagraphContent(RichTextBox box, TextParagraph p)
    {
        var sb = new System.Text.StringBuilder();
        var spans = new List<TextSpan>();
        var lead = p.Lead;
        var family = BaseFamily(p);
        var shown = ShownColor(lead);
        void Inlines(InlineCollection inlines)
        {
            foreach (var inline in inlines)
            {
                switch (inline)
                {
                    case Run r:
                    {
                        var size = Math.Round(r.FontSize / _paraK * 2) / 2;
                        var f = r.FontFamily.Source.Split(',')[0].Trim();
                        var c = r.Foreground is SolidColorBrush b ? ToRgb(b.Color) : shown;
                        var bold = r.FontWeight.ToOpenTypeWeight() >= 600;
                        var italic = r.FontStyle != FontStyles.Normal;
                        var look = new TextLook(
                            f.Equals(family, StringComparison.OrdinalIgnoreCase) ? null : f,
                            Math.Abs(size - p.FontSize) > 0.3 ? size : null,
                            c == shown ? null : c,
                            bold != lead.Bold ? bold : null,
                            italic != lead.Italic ? italic : null);
                        var text = r.Text.Replace("\r\n", "\n").Replace('\r', '\n');
                        if (!look.IsPlain && text.Length > 0)
                        {
                            if (spans.Count > 0 && spans[^1].End == sb.Length && spans[^1].Look == look) spans[^1] = spans[^1] with { Length = spans[^1].Length + text.Length };
                            else spans.Add(new TextSpan(sb.Length, text.Length, look));
                        }
                        sb.Append(text);
                        break;
                    }
                    case LineBreak:
                        sb.Append('\n');
                        break;
                    case Span s:
                        Inlines(s.Inlines);
                        break;
                }
            }
        }
        foreach (var block in box.Document.Blocks)
        {
            if (sb.Length > 0) sb.Append('\n');
            if (block is Paragraph para) Inlines(para.Inlines);
        }
        var all = sb.ToString();
        var trimmed = all.TrimEnd();
        return (trimmed, [.. spans.Where(s => s.Start < trimmed.Length).Select(s => s with { Length = Math.Min(s.Length, trimmed.Length - s.Start) })]);
    }

    /// <summary>Sets the editor's sizes at a zoom: its own size, and each run given a size of its own scaled with it.</summary>
    private void ScaleParagraphEditor(RichTextBox box, TextParagraph p, double k)
    {
        if (Math.Abs(k - _paraK) > 1e-9)
        {
            foreach (var block in box.Document.Blocks.OfType<Paragraph>())
                foreach (var run in Descendants(block.Inlines))
                    if (run.ReadLocalValue(TextElement.FontSizeProperty) != DependencyProperty.UnsetValue) run.FontSize = run.FontSize / _paraK * k;
            _paraK = k;
        }
        box.FontSize = Math.Max(1, p.FontSize * k);
        box.Document.FontSize = box.FontSize;
        box.Document.LineHeight = Math.Max(1, p.LineStep * k);
    }

    private static IEnumerable<Run> Descendants(InlineCollection inlines)
    {
        foreach (var i in inlines)
        {
            if (i is Run r) yield return r;
            else if (i is Span s) foreach (var x in Descendants(s.Inlines)) yield return x;
        }
    }

    // ---- The look bar ----

    /// <summary>The bar over the paragraph editor: font, smaller/larger, bold, italic and colors for the selection.</summary>
    private void ShowLookBar(TextParagraph p, RichTextBox box)
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal };
        Button Btn(string text, string tip, Action click, FontWeight? weight = null, FontStyle? style = null)
        {
            var b = new Button
            {
                Content = text, Focusable = false, IsTabStop = false, MinWidth = 26, Height = 26, Padding = new Thickness(6, 0, 6, 0),
                Margin = new Thickness(1, 0, 1, 0), ToolTip = tip, FontWeight = weight ?? FontWeights.Normal, FontStyle = style ?? FontStyles.Normal,
            };
            System.Windows.Automation.AutomationProperties.SetName(b, tip);
            b.Click += (_, _) =>
            {
                click();
                box.Focus();
            };
            return b;
        }
        var fonts = new ComboBox { Width = 150, Height = 26, IsTabStop = false, ToolTip = "Font of the selected text" };
        System.Windows.Automation.AutomationProperties.SetName(fonts, "Font of the selected text");
        fonts.Items.Add(BaseFamily(p));
        foreach (var f in ContentEditor.LookFonts())
            if (!f.Equals(BaseFamily(p), StringComparison.OrdinalIgnoreCase)) fonts.Items.Add(f);
        fonts.SelectedIndex = 0;
        fonts.SelectionChanged += (_, _) =>
        {
            if (fonts.SelectedItem is not string f || !fonts.IsDropDownOpen && !fonts.IsKeyboardFocusWithin) return;
            box.Selection.ApplyPropertyValue(TextElement.FontFamilyProperty, new FontFamily(f + ", Arial"));
            box.Focus();
            UpdateRunInfo();
        };
        _lookFont = fonts;
        bar.Children.Add(fonts);
        bar.Children.Add(Btn("A−", "Smaller (1 point)", () => Resize(box, p, -1)));
        bar.Children.Add(Btn("A+", "Larger (1 point)", () => Resize(box, p, +1)));
        bar.Children.Add(Btn("B", "Bold", () => Toggle(box, TextElement.FontWeightProperty, FontWeights.Bold, FontWeights.Normal), FontWeights.Bold));
        bar.Children.Add(Btn("I", "Italic", () => Toggle(box, TextElement.FontStyleProperty, FontStyles.Italic, FontStyles.Normal), style: FontStyles.Italic));
        void Swatch(string name, int rgb)
        {
            var b = Btn("", $"Color: {name}", () =>
            {
                box.Selection.ApplyPropertyValue(TextElement.ForegroundProperty, new SolidColorBrush(ToColor(rgb)));
                UpdateRunInfo();
            });
            b.MinWidth = 22;
            b.Content = new Border { Width = 12, Height = 12, Background = new SolidColorBrush(ToColor(rgb)), BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1) };
            bar.Children.Add(b);
        }
        Swatch("the paragraph's own", ShownColor(p.Lead));
        foreach (var (name, rgb) in LookColors)
            if (rgb != ShownColor(p.Lead)) Swatch(name, rgb);
        _lookBar = new Border
        {
            Child = bar,
            Padding = new Thickness(3),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1),
        };
        _lookBar.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorQuarternaryBrush");
        _lookBar.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        System.Windows.Automation.AutomationProperties.SetName(_lookBar, "Look of the selected text");
        _overlay.Children.Add(_lookBar);
        box.SelectionChanged += (_, _) =>
        {
            // The font box shows the selection's font.
            if (box.Selection.GetPropertyValue(TextElement.FontFamilyProperty) is FontFamily ff && !fonts.IsDropDownOpen)
            {
                var name = ff.Source.Split(',')[0].Trim();
                fonts.SelectedItem = fonts.Items.OfType<string>().FirstOrDefault(i => i.Equals(name, StringComparison.OrdinalIgnoreCase));
            }
        };
    }

    private void Toggle(RichTextBox box, DependencyProperty property, object on, object off)
    {
        var now = box.Selection.GetPropertyValue(property);
        box.Selection.ApplyPropertyValue(property, Equals(now, on) ? off : on);
        UpdateRunInfo();
    }

    private void Resize(RichTextBox box, TextParagraph p, int points)
    {
        var now = box.Selection.GetPropertyValue(TextElement.FontSizeProperty) is double d ? d / _paraK : p.FontSize;
        var size = Math.Clamp(Math.Round(now + points), 4, 144);
        box.Selection.ApplyPropertyValue(TextElement.FontSizeProperty, size * _paraK);
        UpdateRunInfo();
    }

    /// <summary>The look bar just above the paragraph editor (under it when there is no room above).</summary>
    private void PlaceLookBar(Rect editor)
    {
        if (_lookBar is null) return;
        _lookBar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var h = _lookBar.DesiredSize.Height;
        Canvas.SetLeft(_lookBar, editor.X);
        Canvas.SetTop(_lookBar, editor.Y - h - 4 >= Viewport.Top ? editor.Y - h - 4 : editor.Bottom + 4);
    }

    private void CloseLookBar()
    {
        if (_lookBar is not null) _overlay.Children.Remove(_lookBar);
        _lookBar = null;
        _lookFont = null;
    }

    /// <summary>Whether focus moving to <paramref name="target"/> stays with the paragraph editor (its look bar, the font list).</summary>
    private bool InLookBar(DependencyObject target) =>
        _lookBar is { } bar && (IsDescendant(bar, target) || _lookFont is { } f && (IsDescendant(f, target) || target is ComboBoxItem { Parent: var parent } && ReferenceEquals(parent, f)
            || target is ComboBoxItem item && ItemsControl.ItemsControlFromItemContainer(item) == f));

    /// <summary>Gives text of the open paragraph editor a look (dev script; offsets into its text).</summary>
    internal void DevStyleParagraph(int start, int length, TextLook look)
    {
        if (_editor is not RichTextBox box || _editorParagraph is not { } p) return;
        var from = PointerAt(box, start);
        var to = PointerAt(box, start + length);
        if (from is null || to is null) return;
        var range = new TextRange(from, to);
        if (look.Font is { } f) range.ApplyPropertyValue(TextElement.FontFamilyProperty, new FontFamily(f + ", Arial"));
        if (look.Size is { } s) range.ApplyPropertyValue(TextElement.FontSizeProperty, s * _paraK);
        if (look.Color is { } c) range.ApplyPropertyValue(TextElement.ForegroundProperty, new SolidColorBrush(ToColor(c)));
        if (look.Bold is { } b) range.ApplyPropertyValue(TextElement.FontWeightProperty, b ? FontWeights.Bold : FontWeights.Normal);
        if (look.Italic is { } i) range.ApplyPropertyValue(TextElement.FontStyleProperty, i ? FontStyles.Italic : FontStyles.Normal);
        UpdateRunInfo();
    }

    /// <summary>The place <paramref name="offset"/> characters into the editor's text (a line break counts one).</summary>
    private static TextPointer? PointerAt(RichTextBox box, int offset)
    {
        var at = 0;
        for (var p = box.Document.ContentStart; p is not null; p = p.GetNextContextPosition(LogicalDirection.Forward))
        {
            switch (p.GetPointerContext(LogicalDirection.Forward))
            {
                case TextPointerContext.Text:
                {
                    var run = p.GetTextInRun(LogicalDirection.Forward);
                    if (offset <= at + run.Length) return p.GetPositionAtOffset(offset - at);
                    at += run.Length;
                    break;
                }
                case TextPointerContext.ElementStart when p.GetAdjacentElement(LogicalDirection.Forward) is LineBreak:
                    if (offset == at) return p;
                    at++;
                    break;
                case TextPointerContext.None:
                    return offset == at ? p : null;
            }
        }
        return null;
    }

    /// <summary>The paragraph editor's text and looks (dev script).</summary>
    internal string? DevParagraphLooks() =>
        _editor is RichTextBox box && _editorParagraph is { } p && ParagraphContent(box, p) is var (text, spans)
            ? string.Join("; ", spans.Select(s => $"'{text.Substring(s.Start, s.Length)}' {s.Look}"))
            : null;
}
