using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// The AI assistant pane at the right of a document: the conversation (questions, summaries, explanations, each answer
/// marked as AI-generated with a Copy button and page citations linked to the pages), and a box for questions about
/// the document with the pages they are about.
/// </summary>
public sealed partial class AiPane : Border
{
    private readonly StackPanel _list = new() { Margin = new Thickness(12, 4, 12, 12) };
    private readonly ScrollViewer _scroll;
    private readonly TextBlock _empty;
    private readonly TextBlock _where = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _whereIcon = new() { FontSize = 12, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Top };
    private readonly Border _whereBox = new() { CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(12, 0, 12, 6) };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 0, 0, 6) };
    private readonly Button _send = new() { Content = "Ask", MinWidth = 72 };
    private readonly Button _stop = new() { Content = "Stop", MinWidth = 72, Visibility = Visibility.Collapsed };

    public TextBox Input { get; } = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MinHeight = 56,
        MaxHeight = 160,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };

    /// <summary>"All", or the pages questions are about ("1-3, 5").</summary>
    public TextBox Scope { get; } = new() { Text = "All", Width = 110 };

    public event EventHandler? CloseRequested;
    public event EventHandler? ClearRequested;
    public event EventHandler? StopRequested;
    public event EventHandler? SummarizeRequested;
    public event EventHandler? SettingsRequested;
    public event EventHandler<string>? AskRequested;

    /// <summary>A page citation was clicked (0-based page).</summary>
    public event EventHandler<int>? PageRequested;

    public AiPane()
    {
        SetResourceReference(BackgroundProperty, "LayerFillColorDefaultBrush");
        SetResourceReference(BorderBrushProperty, "CardStrokeColorDefaultBrush");
        BorderThickness = new Thickness(1, 0, 0, 0);
        AutomationProperties.SetName(this, "AI assistant");

        var title = new TextBlock { Text = "AI assistant", FontWeight = FontWeights.SemiBold, FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        var close = IconButton("\uE711", "Close the AI assistant", 11);
        close.Click += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        var clear = IconButton("\uE74D", "Clear the conversation", 13);
        clear.Click += (_, _) => ClearRequested?.Invoke(this, EventArgs.Empty);
        var settings = IconButton("\uE713", "AI assistant settings", 13);
        settings.Click += (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty);
        var header = new DockPanel { Margin = new Thickness(12, 8, 6, 6) };
        foreach (var b in new[] { close, clear, settings })
        {
            DockPanel.SetDock(b, Dock.Right);
            header.Children.Add(b);
        }
        header.Children.Add(title);

        _whereIcon.Style = (Style)Application.Current.FindResource("Icon");
        var whereRow = new DockPanel();
        DockPanel.SetDock(_whereIcon, Dock.Left);
        whereRow.Children.Add(_whereIcon);
        whereRow.Children.Add(_where);
        _whereBox.Child = whereRow;

        _empty = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(4, 8, 4, 0),
            Style = (Style)Application.Current.FindResource("Caption"),
            Text = "Ask a question about this document below, summarize it, or select text and right-click › Explain with AI.\n\n" +
                   "Before anything is sent you see exactly what goes where. Answers are AI-generated and may be wrong: check them against the pages they cite.",
        };
        _list.Children.Add(_empty);
        _scroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false };

        // Footer: pages, question, send / stop
        var scopeRow = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var scopeLabel = new TextBlock { Text = "Pages", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(scopeLabel, Dock.Left);
        DockPanel.SetDock(Scope, Dock.Left);
        AutomationProperties.SetName(Scope, "Pages the questions are about");
        Scope.ToolTip = "All, or pages such as 1-3, 5";
        var summarize = new Button { Content = "Summarize…", Style = (Style)Application.Current.FindResource("TextButton"), HorizontalAlignment = HorizontalAlignment.Right };
        summarize.Click += (_, _) => SummarizeRequested?.Invoke(this, EventArgs.Empty);
        scopeRow.Children.Add(scopeLabel);
        scopeRow.Children.Add(Scope);
        scopeRow.Children.Add(summarize);

        AutomationProperties.SetName(Input, "Question about this document");
        AutomationProperties.SetHelpText(Input, "Enter sends, Shift+Enter starts a new line");
        Input.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.None)
            {
                e.Handled = true;
                Ask();
            }
        };
        _send.SetResourceReference(StyleProperty, "AccentButtonStyle");
        _send.Click += (_, _) => Ask();
        _stop.Click += (_, _) => StopRequested?.Invoke(this, EventArgs.Empty);
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        _status.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0) };
        buttons.Children.Add(_stop);
        buttons.Children.Add(_send);
        var footer = new StackPanel { Margin = new Thickness(12, 8, 12, 12) };
        footer.Children.Add(_status);
        footer.Children.Add(scopeRow);
        var hint = new TextBlock
        {
            Text = "Ask about this document… (Enter sends)",
            Margin = new Thickness(12, 7, 12, 0),
            IsHitTestVisible = false,
            Style = (Style)Application.Current.FindResource("Caption"),
        };
        Input.TextChanged += (_, _) => hint.Visibility = Input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var inputHost = new Grid();
        inputHost.Children.Add(Input);
        inputHost.Children.Add(hint);
        footer.Children.Add(inputHost);
        footer.Children.Add(buttons);
        var footerBorder = new Border { Child = footer, BorderThickness = new Thickness(0, 1, 0, 0) };
        footerBorder.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(_whereBox, Dock.Top);
        DockPanel.SetDock(footerBorder, Dock.Bottom);
        root.Children.Add(header);
        root.Children.Add(_whereBox);
        root.Children.Add(footerBorder);
        root.Children.Add(_scroll);
        Child = root;
        ShowStatus(null);
    }

    private static Button IconButton(string glyph, string tip, double size)
    {
        var b = new Button { Content = glyph, ToolTip = tip, FontSize = size, Height = 28, MinWidth = 28 };
        b.SetResourceReference(StyleProperty, "IconButton");
        AutomationProperties.SetName(b, tip);
        return b;
    }

    private void Ask()
    {
        var q = Input.Text.Trim();
        if (q.Length == 0 || _stop.Visibility == Visibility.Visible) return;
        AskRequested?.Invoke(this, q);
    }

    /// <summary>Shows where answers come from: model, host, and whether text leaves this PC (amber when it does).</summary>
    public void ShowDestination(AiConfig? config, string? problem)
    {
        if (config is null)
        {
            _where.Text = problem ?? "Not set up";
            _whereIcon.Text = "\uE946"; // info
            _whereBox.SetResourceReference(BackgroundProperty, "SubtleFillColorSecondaryBrush");
            _whereIcon.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
            return;
        }
        var cloud = config.Endpoint.Reach == AiReach.Internet;
        _where.Text = $"{config.Model} · {config.Endpoint.ReachText}";
        _whereIcon.Text = cloud ? "\uE7BA" : "\uE73E";
        _whereBox.SetResourceReference(BackgroundProperty, cloud ? "SystemFillColorCautionBackgroundBrush" : "SubtleFillColorSecondaryBrush");
        _whereIcon.SetResourceReference(TextBlock.ForegroundProperty, cloud ? "SystemFillColorCautionBrush" : "SystemFillColorSuccessBrush");
        AutomationProperties.SetName(_whereBox, _where.Text);
    }

    /// <summary>The line above the question box (progress, "Not sent"…); null hides it. Spoken to screen readers.</summary>
    public void ShowStatus(string? text)
    {
        _status.Text = text ?? "";
        _status.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        if (text is not null) AiActions.Announce(_status, text);
    }

    public void SetBusy(bool busy)
    {
        _stop.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _send.IsEnabled = !busy;
    }

    public void Clear()
    {
        _list.Children.Clear();
        _list.Children.Add(_empty);
    }

    /// <summary>What the user asked for, as a bubble on the right.</summary>
    public void AddQuestion(string text)
    {
        _list.Children.Remove(_empty);
        var bubble = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
            Margin = new Thickness(40, 10, 0, 4),
            HorizontalAlignment = HorizontalAlignment.Right,
            Child = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
        };
        bubble.SetResourceReference(BackgroundProperty, "SubtleFillColorSecondaryBrush");
        AutomationProperties.SetName(bubble, "You: " + text);
        _list.Children.Add(bubble);
        ScrollToEnd();
    }

    /// <summary>Starts an answer card; fill it with <see cref="AiAnswerCard.Update"/> as the answer streams in.</summary>
    public AiAnswerCard AddAnswer(string model, int pageCount)
    {
        _list.Children.Remove(_empty);
        var card = new AiAnswerCard(model, pageCount, p => PageRequested?.Invoke(this, p), ScrollToEnd);
        _list.Children.Add(card);
        ScrollToEnd();
        return card;
    }

    private void ScrollToEnd() => Dispatcher.BeginInvoke(() => _scroll.ScrollToEnd(), DispatcherPriority.Background);

    internal string DevState() =>
        $"where='{_where.Text}' status='{_status.Text}' busy={_stop.Visibility == Visibility.Visible} scope='{Scope.Text}' items=[" +
        string.Join(" | ", _list.Children.OfType<FrameworkElement>().Where(e => e != _empty).Select(e => e is AiAnswerCard c ? $"answer: {c.DevText}" : AutomationProperties.GetName(e))) + "]";
}

/// <summary>
/// One answer: an "AI-generated, may be wrong" note with the model's name, the text (simple Markdown: headings,
/// bullets, bold; "[p. N]" citations as links to the pages), and Copy.
/// </summary>
public sealed partial class AiAnswerCard : Border
{
    private readonly TextBlock _text = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), LineHeight = 20 };
    private readonly TextBlock _note = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
    private readonly Button _copy;
    private readonly int _pageCount;
    private readonly Action<int> _goTo;
    private readonly Action _scroll;
    private readonly DispatcherTimer _render;
    private readonly StringBuilder _raw = new();
    private readonly TextBlock _label;
    private readonly TextBlock _warn;
    private readonly string _model;
    private bool _dirty, _finished;

    internal AiAnswerCard(string model, int pageCount, Action<int> goTo, Action scroll)
    {
        _pageCount = pageCount;
        _model = model;
        _goTo = goTo;
        _scroll = scroll;
        Style = (Style)Application.Current.FindResource("Card");
        Padding = new Thickness(12, 10, 12, 10);
        Margin = new Thickness(0, 6, 0, 4);
        Focusable = true;

        var warn = _warn = new TextBlock { Style = (Style)Application.Current.FindResource("Icon"), Text = "\uE7BA", FontSize = 12, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
        warn.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        var label = _label = new TextBlock { Text = $"AI-generated, may be wrong · {model}", FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        label.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        _copy = new Button { Content = "\uE8C8", ToolTip = "Copy the answer", FontSize = 13, Height = 26, MinWidth = 26, IsEnabled = false };
        _copy.SetResourceReference(StyleProperty, "IconButton");
        AutomationProperties.SetName(_copy, "Copy the answer");
        _copy.Click += (_, _) => Copy();
        var head = new DockPanel();
        DockPanel.SetDock(_copy, Dock.Right);
        DockPanel.SetDock(warn, Dock.Left);
        head.Children.Add(_copy);
        head.Children.Add(warn);
        head.Children.Add(label);
        _note.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");

        var body = new StackPanel();
        body.Children.Add(head);
        body.Children.Add(_text);
        body.Children.Add(_note);
        Child = body;
        AutomationProperties.SetName(this, "AI answer");
        _text.Text = "…";

        // Re-render a few times a second while streaming, not per token.
        _render = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(120) };
        _render.Tick += (_, _) =>
        {
            if (!_dirty) return;
            _dirty = false;
            Render();
        };
        _render.Start();
    }

    public string Text => AiText.WithoutThinking(_raw.ToString(), out _).Trim();

    internal string DevText => $"{Text.Replace('\n', ' ')}{(_note.Visibility == Visibility.Visible ? $" ({_note.Text})" : "")} links={Links().Count()}";

    /// <summary>Adds streamed text (any thread-safe caller marshals to the UI thread first).</summary>
    public void Append(string piece)
    {
        if (_finished) return;
        _raw.Append(piece);
        _dirty = true;
    }

    /// <summary>Shows a progress line in place of the text while nothing has arrived yet.</summary>
    public void Progress(string text)
    {
        if (_raw.Length == 0 && !_finished) _text.Text = text;
    }

    /// <summary>Ends the card: the final text (null keeps what streamed) and a note (cut off, stopped, an error).</summary>
    public void Finish(string? text, string? note, bool error = false)
    {
        _finished = true;
        _render.Stop();
        if (text is not null)
        {
            _raw.Clear();
            _raw.Append(text);
        }
        Render();
        if (_raw.Length == 0 && note is not null) _text.Visibility = Visibility.Collapsed;
        if (error && Text.Length == 0)
        {
            _label.Text = $"No answer · {_model}";
            _warn.Text = "\uE783"; // error badge
            _warn.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
        }
        if (note is not null)
        {
            _note.Text = note;
            _note.Visibility = Visibility.Visible;
            if (error) _note.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
        }
        _copy.IsEnabled = Text.Length > 0;
        AutomationProperties.SetName(this, "AI answer, may be wrong: " + (Text.Length > 0 ? Text : note));
        _scroll();
    }

    private void Copy()
    {
        try
        {
            Clipboard.SetText(Text + "\n\n(AI-generated, may be wrong)");
            _copy.ToolTip = "Copied";
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            _copy.ToolTip = "Couldn't copy: the clipboard is busy";
        }
    }

    private void Render()
    {
        var shown = AiText.WithoutThinking(_raw.ToString(), out var thinking).Trim();
        _text.Inlines.Clear();
        if (thinking || shown.Length == 0)
        {
            _text.Text = thinking ? "Thinking…" : "…";
            return;
        }
        var lines = shown.Replace("\r\n", "\n").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0) _text.Inlines.Add(new LineBreak());
            var line = lines[i];
            var heading = Heading().Match(line);
            if (heading.Success)
            {
                var span = new Bold();
                AddInline(span.Inlines, heading.Groups[1].Value);
                _text.Inlines.Add(span);
                continue;
            }
            var bullet = Bullet().Match(line);
            if (bullet.Success) line = bullet.Groups[1].Value + "•  " + bullet.Groups[2].Value;
            AddInline(_text.Inlines, line);
        }
        _scroll();
    }

    /// <summary>A line's text with **bold** spans and page citations as links.</summary>
    private void AddInline(InlineCollection target, string line)
    {
        var parts = line.Split("**");
        for (var i = 0; i < parts.Length; i++)
        {
            var bold = i % 2 == 1 && i < parts.Length - 1; // an unclosed ** stays as text
            var text = bold || i % 2 == 0 ? parts[i] : "**" + parts[i];
            var container = bold ? new Bold() : null;
            var inlines = container?.Inlines ?? target;
            var at = 0;
            foreach (var c in AiText.Citations(text, _pageCount))
            {
                if (c.Start > at) inlines.Add(new Run(text[at..c.Start]));
                var page = c.Page;
                var link = new Hyperlink(new Run(text.Substring(c.Start, c.Length))) { ToolTip = $"Go to page {page + 1}" };
                AutomationProperties.SetName(link, $"Go to page {page + 1}");
                link.Click += (_, _) => _goTo(page);
                inlines.Add(link);
                at = c.Start + c.Length;
            }
            if (at < text.Length) inlines.Add(new Run(text[at..]));
            if (container is not null) target.Add(container);
        }
    }

    private IEnumerable<Hyperlink> Links() => Descend(_text.Inlines);

    private static IEnumerable<Hyperlink> Descend(InlineCollection inlines)
    {
        foreach (var i in inlines)
        {
            if (i is Hyperlink h) yield return h;
            else if (i is Span s)
                foreach (var x in Descend(s.Inlines)) yield return x;
        }
    }

    [GeneratedRegex(@"^\s{0,3}#{1,6}\s+(.*)$")]
    private static partial Regex Heading();

    [GeneratedRegex(@"^(\s*)(?:[-*+]|•)\s+(.*)$")]
    private static partial Regex Bullet();
}
