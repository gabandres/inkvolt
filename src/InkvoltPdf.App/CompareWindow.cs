using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Compare: the original and the changed document as rows of lined-up pages (one scroll bar, so both sides always
/// scroll together), the text differences highlighted on both, a list of changes to step through (F8 / Shift+F8,
/// Alt+Down / Alt+Up) and a summary; or the pages overlaid (red: only in the original, blue: only in the changed
/// file) for drawings and scans. Pages render on demand, off the UI thread; the text is read and compared in the
/// background (Cancel or closing the window stops it). Works on its own copies of both documents, so the tabs can
/// change or close meanwhile.
/// </summary>
internal sealed class CompareWindow : Window
{
    private const double PtToDip = 96.0 / 72.0;
    private const double MinZoom = 0.1, MaxZoom = 8;
    private const int KeepRendered = 8; // rows beyond the visible ones that keep their bitmaps

    private sealed record ChangeItem(int Change, int Row, string Kind, string Where, string Text, Brush Chip)
    {
        public override string ToString() => $"{Kind}, {Where}: {Text}";
    }

    private readonly MainWindow _host;
    private readonly CompareSide _old;
    private readonly CompareSide _new;
    private readonly CancellationTokenSource _cts = new();
    private PdfEngine? _oldEngine, _newEngine;
    private PageText[] _oldText = [], _newText = [];
    private CompareResult? _result;
    private readonly List<CompareRowView> _rows = [];
    private double[] _tops = [];
    private readonly ObservableCollection<ChangeItem> _items = [];
    private bool _visual;
    private double _zoom; // 0: fit
    private bool _pumping;
    private bool _checking;

    private readonly StackPanel _rowsPanel = new();
    private readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Visible, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    private readonly ListBox _list = new() { BorderThickness = new Thickness(0) };
    private readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _position = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 10, 0), MinWidth = 60 };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 6, 12, 6) };
    private readonly RadioButton _textMode = new() { Content = "Text", GroupName = "mode", IsChecked = true };
    private readonly RadioButton _visualMode = new() { Content = "Visual", GroupName = "mode" };
    private readonly Button _prev = new() { Content = "\uE70E" };
    private readonly Button _next = new() { Content = "\uE70D" };
    private readonly Button _zoomOut = new() { Content = "\uE71F" };
    private readonly Button _zoomIn = new() { Content = "\uE8A3" };
    private readonly Button _zoomText = new() { Content = "Fit" };
    private readonly Button _report = new() { Content = "Annotated Copy" };
    private readonly StackPanel _legend = new() { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed, Margin = new Thickness(12, 0, 0, 0) };
    private readonly Border _busy = new() { Padding = new Thickness(24), CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _busyText = new() { TextWrapping = TextWrapping.Wrap, MaxWidth = 360, Margin = new Thickness(0, 0, 0, 10) };
    private readonly ProgressBar _busyBar = new() { Width = 320, Height = 4, Maximum = 1 };
    private readonly TextBlock _headerOld = new() { FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock _headerNew = new() { FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Grid _headers = new() { Margin = new Thickness(CompareRowView.Side, 6, CompareRowView.Side, 2) };

    private CompareWindow(MainWindow host, CompareSide oldSide, CompareSide newSide)
    {
        _host = host;
        _old = oldSide;
        _new = newSide;
        Title = $"Compare: {oldSide.Name} → {newSide.Name}";
        Width = Math.Min(1500, SystemParameters.WorkArea.Width * 0.9);
        Height = Math.Min(1000, SystemParameters.WorkArea.Height * 0.9);
        MinWidth = 640;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SourceInitialized += (_, _) => App.ApplyFrame(this);
        Content = Build();
        Cmd.AddShortcutsToTips(this);

        PreviewKeyDown += OnKey;
        _scroll.ScrollChanged += (_, e) =>
        {
            if (e.ViewportWidthChange != 0 || e.ViewportHeightChange != 0) Relayout(keepPlace: true);
            else Pump();
        };
        _scroll.PreviewMouseWheel += (_, e) =>
        {
            if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
            e.Handled = true;
            Zoom(e.Delta > 0 ? 1.15 : 1 / 1.15);
        };
        _list.SelectionChanged += (_, _) => OnSelected();
        Loaded += async (_, _) => await RunAsync();
        Closed += (_, _) =>
        {
            _cts.Cancel();
            foreach (var r in _rows) r.Release();
            _oldEngine?.Dispose();
            _newEngine?.Dispose();
        };
    }

    /// <summary>Opens a compare window for two documents (it reads and compares them itself).</summary>
    public static CompareWindow Open(MainWindow host, CompareSide oldSide, CompareSide newSide, bool offScreen = false)
    {
        var w = new CompareWindow(host, oldSide, newSide);
        if (offScreen)
        {
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Left = -20000;
            w.Top = 0;
            w.Width = 1400;
            w.Height = 900;
            w.ShowActivated = false;
        }
        w.Show();
        return w;
    }

    // ───────────────────────────── UI ─────────────────────────────

    private UIElement Build()
    {
        Button Icon(Button b, string tip, Action click)
        {
            b.Style = (Style)FindResource("IconButton");
            b.ToolTip = tip;
            b.Click += (_, _) => click();
            return b;
        }
        Icon(_prev, "Previous change (Shift+F8)", () => Step(-1));
        Icon(_next, "Next change (F8)", () => Step(1));
        Icon(_zoomOut, "Zoom out (Ctrl+-)", () => Zoom(1 / 1.25));
        Icon(_zoomIn, "Zoom in (Ctrl+=)", () => Zoom(1.25));
        _zoomText.Style = (Style)FindResource("TextButton");
        _zoomText.ToolTip = "Fit the pages to the window (Ctrl+0)";
        _zoomText.Click += (_, _) => SetZoom(0);
        AutomationProperties.SetName(_zoomText, "Fit to window");
        _report.Style = (Style)FindResource("CommandButton");
        _report.ToolTip = "Open a copy of the changed file with every text change as a comment, in a new tab";
        _report.Click += async (_, _) => await MakeReportAsync();
        _report.IsEnabled = false;
        foreach (var (rb, tip) in new[] { (_textMode, "Text differences side by side (Ctrl+1)"), (_visualMode, "Visual overlay: red only in the original, blue only in the changed file (Ctrl+2)") })
        {
            rb.Style = (Style)FindResource("CommandButton");
            rb.ToolTip = tip;
            AutomationProperties.SetName(rb, tip);
            rb.Checked += (_, _) => SetVisual(_visualMode.IsChecked == true);
        }

        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 6, 8, 2) };
        bar.Children.Add(_textMode);
        bar.Children.Add(_visualMode);
        bar.Children.Add(new Border { Style = (Style)FindResource("BarSeparator") });
        bar.Children.Add(_prev);
        bar.Children.Add(_next);
        bar.Children.Add(_position);
        bar.Children.Add(new Border { Style = (Style)FindResource("BarSeparator") });
        bar.Children.Add(_zoomOut);
        bar.Children.Add(_zoomText);
        bar.Children.Add(_zoomIn);
        bar.Children.Add(new Border { Style = (Style)FindResource("BarSeparator") });
        bar.Children.Add(_report);
        foreach (var (color, text) in new[] { (VisualCompare.RemovedColor, "only in the original"), (VisualCompare.AddedColor, "only in the changed file") })
        {
            _legend.Children.Add(new Border { Width = 12, Height = 12, CornerRadius = new CornerRadius(2), Margin = new Thickness(8, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center, Background = Frozen(Color.FromRgb(color.R, color.G, color.B)) });
            _legend.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        }
        _legend.Children.Add(new Border { Width = 12, Height = 12, CornerRadius = new CornerRadius(2), Margin = new Thickness(10, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center, Background = Frozen(Color.FromRgb(115, 115, 115)) });
        _legend.Children.Add(new TextBlock { Text = "in both", VerticalAlignment = VerticalAlignment.Center });
        bar.Children.Add(_legend);

        var summaryRow = new Border { Child = _summary, Padding = new Thickness(14, 2, 14, 8) };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        _summary.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");

        var top = new StackPanel();
        top.Children.Add(bar);
        top.Children.Add(summaryRow);
        var topBorder = new Border { Child = top, BorderThickness = new Thickness(0, 0, 0, 1) };
        topBorder.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");

        // The change list.
        _list.ItemsSource = _items;
        _list.ItemTemplate = (DataTemplate)XamlReader.Parse(
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
            "<DockPanel Margin='0,3,0,3'>" +
            "<Border DockPanel.Dock='Left' Width='4' CornerRadius='2' Background='{Binding Chip, Mode=OneWay}' Margin='0,0,10,0' />" +
            "<StackPanel>" +
            "<TextBlock><Run Text='{Binding Kind, Mode=OneWay}' FontWeight='SemiBold' /><Run Text=' · ' /><Run Text='{Binding Where, Mode=OneWay}' /></TextBlock>" +
            "<TextBlock Text='{Binding Text, Mode=OneWay}' TextWrapping='Wrap' MaxHeight='54' TextTrimming='CharacterEllipsis' Foreground='{DynamicResource TextFillColorSecondaryBrush}' />" +
            "</StackPanel></DockPanel></DataTemplate>");
        ScrollViewer.SetHorizontalScrollBarVisibility(_list, ScrollBarVisibility.Disabled);
        VirtualizingPanel.SetIsVirtualizing(_list, true);
        AutomationProperties.SetName(_list, "Changes");
        var listHeader = new TextBlock { Text = "Changes", FontWeight = FontWeights.SemiBold, Margin = new Thickness(12, 10, 12, 4) };
        var side = new DockPanel { Width = 300 };
        DockPanel.SetDock(listHeader, Dock.Top);
        side.Children.Add(listHeader);
        DockPanel.SetDock(_status, Dock.Bottom);
        side.Children.Add(_status);
        side.Children.Add(_list);
        var sideBorder = new Border { Child = side, BorderThickness = new Thickness(0, 0, 1, 0) };
        sideBorder.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");

        // The pages, with the two documents' names above their columns.
        _headers.ColumnDefinitions.Add(new ColumnDefinition());
        _headers.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(CompareRowView.Gap) });
        _headers.ColumnDefinitions.Add(new ColumnDefinition());
        _headerOld.Text = $"Original: {_old.Name}";
        _headerNew.Text = $"Changed: {_new.Name}";
        Grid.SetColumn(_headerNew, 2);
        _headers.Children.Add(_headerOld);
        _headers.Children.Add(_headerNew);
        _scroll.Content = _rowsPanel;
        AutomationProperties.SetName(_scroll, "Pages");
        var pages = new DockPanel();
        var headerClip = new Border { Child = _headers, ClipToBounds = true }; // the names scroll sideways with the pages
        DockPanel.SetDock(headerClip, Dock.Top);
        pages.Children.Add(headerClip);
        pages.Children.Add(_scroll);

        var busyPanel = new StackPanel();
        busyPanel.Children.Add(_busyText);
        busyPanel.Children.Add(_busyBar);
        var cancel = new Button { Content = "Cancel", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0), MinWidth = 96 };
        cancel.Click += (_, _) => Close();
        busyPanel.Children.Add(cancel);
        _busy.Child = busyPanel;
        _busy.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorQuarternaryBrush");
        _busy.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        _busy.BorderThickness = new Thickness(1);
        AutomationProperties.SetLiveSetting(_busyText, AutomationLiveSetting.Polite);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition());
        body.Children.Add(sideBorder);
        Grid.SetColumn(pages, 1);
        body.Children.Add(pages);
        Grid.SetColumnSpan(_busy, 2);
        body.Children.Add(_busy);

        var root = new DockPanel();
        DockPanel.SetDock(topBorder, Dock.Top);
        root.Children.Add(topBorder);
        root.Children.Add(body);
        UpdateButtons();
        return root;
    }

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    private void SetBusy(string? text, double progress = -1)
    {
        _busy.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        if (text is null) return;
        _busyText.Text = text;
        _busyBar.IsIndeterminate = progress < 0;
        if (progress >= 0) _busyBar.Value = progress;
    }

    /// <summary>Speaks <paramref name="message"/> through the status line (a polite live region).</summary>
    private void Announce(string message)
    {
        _status.Text = message;
        UIElementAutomationPeer.CreatePeerForElement(_status)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void UpdateButtons()
    {
        var any = _items.Count > 0;
        _prev.IsEnabled = _next.IsEnabled = any;
        _position.Text = !any ? "" : _list.SelectedIndex < 0 ? $"{_items.Count} in all" : $"{_list.SelectedIndex + 1} of {_items.Count}";
        _zoomText.Content = _zoom <= 0 ? "Fit" : $"{_zoom * 100:0}%";
        _legend.Visibility = _visual ? Visibility.Visible : Visibility.Collapsed;
        _headers.Visibility = _visual ? Visibility.Collapsed : Visibility.Visible;
    }

    // ───────────────────────────── Reading and comparing ─────────────────────────────

    private async Task RunAsync()
    {
        var cancel = _cts.Token;
        try
        {
            SetBusy("Opening both documents…");
            (_oldEngine, _newEngine) = await Task.Run(() =>
            {
                var o = PdfEngine.Open(_old.Data, MuPDFCore.InputFileTypes.PDF, _old.Password);
                try
                {
                    return (o, PdfEngine.Open(_new.Data, MuPDFCore.InputFileTypes.PDF, _new.Password));
                }
                catch
                {
                    o.Dispose();
                    throw;
                }
            }, cancel);
            if (cancel.IsCancellationRequested)
            {
                // Closed while they opened: Closed found nothing to dispose yet.
                _oldEngine.Dispose();
                _newEngine.Dispose();
                _oldEngine = _newEngine = null;
                return;
            }

            var total = _oldEngine.PageCount + _newEngine.PageCount;
            var done = 0;
            var progress = new Progress<int>(_ => SetBusy($"Reading the text… page {done} of {total}", total == 0 ? 0 : (double)done / total));
            IProgress<int> report = progress;
            PageText[] Read(PdfEngine engine) =>
                [.. Enumerable.Range(0, engine.PageCount).Select(p =>
                {
                    PageText t;
                    try
                    {
                        t = engine.GetText(p, cache: false, cancel);
                    }
                    catch (MuPDFCore.MuPDFException)
                    {
                        t = PageText.Empty; // a damaged page: no text to compare (its row says so)
                    }
                    report.Report(Interlocked.Increment(ref done));
                    return t;
                })];
            var oldEngine = _oldEngine;
            var newEngine = _newEngine;
            var texts = await Task.WhenAll(Task.Run(() => Read(oldEngine), cancel), Task.Run(() => Read(newEngine), cancel));
            (_oldText, _newText) = (texts[0], texts[1]);

            SetBusy("Comparing…");
            _result = await Task.Run(() => DocumentCompare.Run(_oldText, _newText, cancel), cancel);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (ObjectDisposedException)
        {
            return;
        }
        catch (Exception ex) when (ex is MuPDFCore.MuPDFException or InvalidOperationException or PasswordRequiredException or IOException)
        {
            SetBusy(null);
            _summary.Text = $"These documents couldn't be compared: {ex.Message}";
            Announce(_summary.Text);
            return;
        }
        SetBusy(null);
        ShowResult();
        _ = CheckScansAsync();
    }

    private void ShowResult()
    {
        var r = _result!;
        _rows.Clear();
        _rowsPanel.Children.Clear();
        for (var i = 0; i < r.Rows.Count; i++)
        {
            var row = r.Rows[i];
            var view = new CompareRowView(i, row,
                row.OldPage is { } o ? _oldEngine!.GetPage(o) : null,
                row.NewPage is { } n ? _newEngine!.GetPage(n) : null) { Label = RowLabel(row) };
            view.MouseLeftButtonDown += (_, e) => OnRowClick(view, e);
            AutomationProperties.SetName(view, view.Label);
            _rows.Add(view);
            _rowsPanel.Children.Add(view);
        }

        _rowOfOld = new int[_oldText.Length];
        _rowOfNew = new int[_newText.Length];
        for (var i = 0; i < r.Rows.Count; i++)
        {
            if (r.Rows[i].OldPage is { } o) _rowOfOld[o] = i;
            if (r.Rows[i].NewPage is { } n) _rowOfNew[n] = i;
        }

        // Highlights: each change's words on both sides, and where an insertion or deletion sits on the other side.
        for (var c = 0; c < r.Changes.Count; c++)
        {
            var ch = r.Changes[c];
            var row = _rows[ch.Row];
            switch (ch.Kind)
            {
                case ChangeKind.PageRemoved or ChangeKind.PageInserted:
                    row.PageChange = ch.Kind;
                    row.PageChangeIndex = c;
                    break;
                default:
                    foreach (var s in ch.Old) AddMarks(_rows[RowOf(s.Page, old: true)].OldMarks, _oldText[s.Page], s, ch.Kind, c);
                    foreach (var s in ch.New) AddMarks(_rows[RowOf(s.Page, old: false)].NewMarks, _newText[s.Page], s, ch.Kind, c);
                    if (ch.OldAnchor is { } oa && Caret(_oldText[oa.Page], oa.Start) is { } ob)
                        _rows[RowOf(oa.Page, old: true)].OldCarets.Add(new CompareRowView.Mark(ob, ch.Kind, c));
                    if (ch.NewAnchor is { } na && Caret(_newText[na.Page], na.Start) is { } nb)
                        _rows[RowOf(na.Page, old: false)].NewCarets.Add(new CompareRowView.Mark(nb, ch.Kind, c));
                    break;
            }
            _items.Add(Item(c, ch));
        }

        _summary.Text = $"{r.Summary()}." + (r.PairsWithoutText > 0
            ? " Pages without text (scans) can't be compared word by word: they are checked visually, and Visual shows them overlaid."
            : "");
        _report.IsEnabled = r.Changes.Count > 0;
        Relayout(keepPlace: false);
        UpdateButtons();
        Announce(_summary.Text);
        if (_items.Count > 0)
        {
            _list.SelectedIndex = 0;
            _list.Focus();
        }
        else _scroll.Focus();
    }

    private int[] _rowOfOld = [], _rowOfNew = [];

    private int RowOf(int page, bool old) => old ? _rowOfOld[page] : _rowOfNew[page];

    private static void AddMarks(List<CompareRowView.Mark> marks, PageText text, WordSpan span, ChangeKind kind, int change)
    {
        foreach (var rect in text.GetRects(span.Start, span.End)) marks.Add(new CompareRowView.Mark(rect, kind, change));
    }

    /// <summary>The spot for a position between characters: a thin box at the edge of the character before (or after) it.</summary>
    private static RectD? Caret(PageText text, int caret)
    {
        if (caret > 0 && text.GetRects(caret - 1, caret) is [var before, ..]) return new RectD(before.Right, before.Y, 0, before.Height);
        if (caret < text.Text.Length && text.GetRects(caret, caret + 1) is [var after, ..]) return new RectD(after.X, after.Y, 0, after.Height);
        return null;
    }

    private static readonly Brush InsertedChip = Frozen(Color.FromRgb(46, 160, 67));
    private static readonly Brush DeletedChip = Frozen(Color.FromRgb(214, 60, 60));
    private static readonly Brush ChangedChip = Frozen(Color.FromRgb(230, 150, 20));
    private static readonly Brush VisualChip = Frozen(Color.FromRgb(90, 110, 230));

    private ChangeItem Item(int index, CompareChange c)
    {
        var row = _result!.Rows[c.Row];
        var where = row switch
        {
            { OldPage: { } o, NewPage: { } n } when o == n => $"page {o + 1}",
            { OldPage: { } o, NewPage: { } n } => $"page {o + 1} → {n + 1}",
            { OldPage: { } o } => $"original page {o + 1}",
            { NewPage: { } n } => $"changed page {n + 1}",
            _ => "",
        };
        return c.Kind switch
        {
            ChangeKind.Inserted => new ChangeItem(index, c.Row, "Inserted", where, Quote(c.NewText), InsertedChip),
            ChangeKind.Deleted => new ChangeItem(index, c.Row, "Removed", where, Quote(c.OldText), DeletedChip),
            ChangeKind.Changed => new ChangeItem(index, c.Row, "Changed", where, $"{Quote(c.OldText)} → {Quote(c.NewText)}", ChangedChip),
            ChangeKind.PageInserted => new ChangeItem(index, c.Row, "Page inserted", where, c.NewText.Length > 0 ? Quote(c.NewText) : "(no text)", InsertedChip),
            _ => new ChangeItem(index, c.Row, "Page removed", where, c.OldText.Length > 0 ? Quote(c.OldText) : "(no text)", DeletedChip),
        };
    }

    private static string Quote(string s) => $"“{(s.Length > 160 ? s[..160] + "…" : s)}”";

    private static string RowPages(CompareRow r) => r switch
    {
        { OldPage: { } o, NewPage: { } n } => $"Original page {o + 1} · changed page {n + 1}",
        { OldPage: { } o } => $"Original page {o + 1}",
        { NewPage: { } n } => $"Changed page {n + 1}",
        _ => "",
    };

    private static string RowLabel(CompareRow r)
    {
        var pages = RowPages(r);
        var state = r.Text switch
        {
            RowText.OnlyOld => "removed: the changed file doesn't have it",
            RowText.OnlyNew => "inserted: the original doesn't have it",
            RowText.NoTextOld => "no text on the original page (a scan?): checking visually…",
            RowText.NoTextNew => "no text on the changed page (a scan?): checking visually…",
            RowText.NoTextBoth => "no text (scans?): checking visually…",
            _ => r.Changes == 0 ? "no text changes" : r.Changes == 1 ? "1 change" : $"{r.Changes} changes",
        };
        return $"{pages} · {state}";
    }

    /// <summary>
    /// Pages without text can't be compared word by word: render each such pair small and overlay them, then say
    /// whether they look the same, and list the ones that don't.
    /// </summary>
    private async Task CheckScansAsync()
    {
        var cancel = _cts.Token;
        _checking = true;
        try
        {
            foreach (var view in _rows.Where(v => v.Row.Text is RowText.NoTextOld or RowText.NoTextNew or RowText.NoTextBoth).ToList())
            {
                int o = view.Row.OldPage!.Value, n = view.Row.NewPage!.Value;
                VisualDiff diff;
                try
                {
                    var oldEngine = _oldEngine!;
                    var newEngine = _newEngine!;
                    diff = await Task.Run(() => VisualCompare.Overlay(oldEngine.Render(o, 0.7, null, cancel), newEngine.Render(n, 0.7, null, cancel), cancel: cancel), cancel);
                }
                catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException)
                {
                    return;
                }
                catch (Exception ex) when (ex is MuPDFCore.MuPDFException or InvalidOperationException)
                {
                    view.Label = RowLabel(view.Row).Replace("checking visually…", "couldn't be checked");
                    view.InvalidateVisual();
                    continue;
                }
                var areas = diff.Regions.Count;
                var what = view.Row.Text switch
                {
                    RowText.NoTextOld => "no text on the original page",
                    RowText.NoTextNew => "no text on the changed page",
                    _ => "no text",
                };
                view.Label = RowPages(view.Row) + " · " + what + (areas == 0 ? ": looks the same" : areas == 1 ? ": 1 area looks different" : $": {areas} areas look different");
                AutomationProperties.SetName(view, view.Label);
                view.InvalidateVisual();
                if (areas == 0) continue;

                // Listed after the row's other entries, in row order.
                var item = new ChangeItem(-1, view.Index, "Looks different", o == n ? $"page {o + 1}" : $"page {o + 1} → {n + 1}",
                    $"{(areas == 1 ? "1 area" : $"{areas} areas")} ({diff.ChangedShare:P1} of the page); no text to compare. Visual shows where.", VisualChip);
                var at = 0;
                while (at < _items.Count && _items[at].Row <= view.Index) at++;
                _items.Insert(at, item);
                UpdateButtons();
            }
        }
        finally
        {
            _checking = false;
        }
    }

    // ───────────────────────────── Layout and rendering ─────────────────────────────

    private void SetVisual(bool visual)
    {
        if (_visual == visual) return;
        _visual = visual;
        UpdateButtons();
        Relayout(keepPlace: true);
        Announce(visual ? "Visual overlay: red is only in the original, blue only in the changed file, grey in both." : "Text differences side by side.");
    }

    private void Zoom(double factor)
    {
        var current = _zoom > 0 ? _zoom : CurrentScale() / PtToDip;
        SetZoom(Math.Clamp(current * factor, MinZoom, MaxZoom));
    }

    private void SetZoom(double zoom)
    {
        _zoom = zoom;
        UpdateButtons();
        Relayout(keepPlace: true);
    }

    /// <summary>The scale (DIPs per point) of the first row in view.</summary>
    private double CurrentScale() => FirstVisible() is var i and >= 0 && i < _rows.Count ? _rows[i].Scale : PtToDip;

    /// <summary>Sizes every row for the window width, the zoom and the mode, keeping the row in view in place.</summary>
    private void Relayout(bool keepPlace)
    {
        if (_rows.Count == 0) return;
        var anchor = keepPlace ? FirstVisible() : -1;
        var within = anchor >= 0 ? (_scroll.VerticalOffset - _tops[anchor]) / Math.Max(1, _rows[anchor].Height) : 0;

        var viewW = Math.Max(300, _scroll.ViewportWidth > 0 ? _scroll.ViewportWidth : ActualWidth - 320);
        var viewH = Math.Max(200, _scroll.ViewportHeight > 0 ? _scroll.ViewportHeight : ActualHeight - 160);
        var maxW = _rows.Max(r => Math.Max(r.OldSize?.Width ?? 0, r.NewSize?.Width ?? 0));
        double width = viewW;
        if (_zoom > 0)
        {
            var s = _zoom * PtToDip;
            width = Math.Max(viewW, _visual ? 2 * CompareRowView.Side + maxW * s : 2 * CompareRowView.Side + CompareRowView.Gap + 2 * maxW * s);
        }
        _tops = new double[_rows.Count];
        var y = 0.0;
        for (var i = 0; i < _rows.Count; i++)
        {
            _rows[i].Layout(width, viewH, _zoom > 0 ? _zoom * PtToDip : 0, _visual);
            _tops[i] = y;
            y += _rows[i].Height;
        }
        _headers.Width = _visual ? double.NaN : width - 2 * CompareRowView.Side;
        _headers.HorizontalAlignment = HorizontalAlignment.Left;
        _rowsPanel.UpdateLayout();
        if (anchor >= 0) _scroll.ScrollToVerticalOffset(_tops[anchor] + within * _rows[anchor].Height);
        Pump();
    }

    private int FirstVisible()
    {
        if (_tops.Length == 0) return -1;
        var y = _scroll.VerticalOffset;
        int lo = 0, hi = _tops.Length - 1;
        while (lo < hi)
        {
            var mid = (lo + hi + 1) / 2;
            if (_tops[mid] <= y) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    private (int First, int Last) VisibleRows()
    {
        var first = FirstVisible();
        if (first < 0) return (0, -1);
        var last = first;
        var bottom = _scroll.VerticalOffset + Math.Max(1, _scroll.ViewportHeight);
        while (last + 1 < _rows.Count && _tops[last + 1] < bottom) last++;
        return (first, last);
    }

    /// <summary>All rows' bitmaps together stay under this, the rows in view excepted (farthest freed first).</summary>
    private const long BitmapBudget = 256L << 20;

    /// <summary>
    /// Largest whole-page render, in pixels: twice the area on screen, at least 4 MP. Beyond it (high zoom) a page is
    /// rendered whole at this size and the part in view gets a sharp tile, as in the page view.
    /// </summary>
    private long MaxFullPixels
    {
        get
        {
            var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
            var view = Math.Max(1, _scroll.ViewportWidth) * Math.Max(1, _scroll.ViewportHeight) * dpi * dpi;
            return Math.Max(4_000_000, (long)(2 * view));
        }
    }

    private static double FullScale(double px, (double Width, double Height) size, long maxFull)
    {
        var area = Math.Max(1, size.Width * size.Height);
        return area * px * px > maxFull ? Math.Sqrt(maxFull / area) : px;
    }

    private static bool Off(double had, double want) => Math.Abs(had - want) > want * 0.15;

    /// <summary>A render to make: a part's whole page (Region null) or a tile of it.</summary>
    private sealed record Job(CompareRowView View, CompareRowView.Part Part, double Scale, RectD? Region);

    /// <summary>Renders what the visible rows need, one at a time off the UI thread, nearest first; frees far ones.</summary>
    private async void Pump()
    {
        _headers.Margin = new Thickness(CompareRowView.Side - _scroll.HorizontalOffset, 6, CompareRowView.Side, 2);
        if (_pumping || _oldEngine is null || _newEngine is null) return;
        _pumping = true;
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                var (first, last) = VisibleRows();
                Trim(first, last);
                var job = NextJob(first, last, VisualTreeHelper.GetDpi(this).DpiScaleX, MaxFullPixels);
                if (job is null) break;
                await RenderAsync(job);
            }
        }
        finally
        {
            _pumping = false;
        }
    }

    /// <summary>Frees tiles out of view, and whole renders far from view or past the memory budget (farthest first).</summary>
    private void Trim(int first, int last)
    {
        int Distance(int i) => i < first ? first - i : i > last ? i - last : 0;
        var total = 0L;
        foreach (var i in Enumerable.Range(0, _rows.Count).OrderBy(Distance))
        {
            var d = Distance(i);
            if (d > 0) _rows[i].ReleaseTiles();
            total += _rows[i].Bytes;
            if (d > KeepRendered || (d > 0 && total > BitmapBudget))
            {
                total -= _rows[i].Bytes;
                _rows[i].Release();
            }
        }
    }

    /// <summary>Whole pages first (the rows in view and one either side), then sharp tiles of what's in view at high zoom.</summary>
    private Job? NextJob(int first, int last, double dpi, long maxFull)
    {
        if (last < first) return null;
        for (var i = Math.Max(0, first - 1); i <= Math.Min(_rows.Count - 1, last + 1); i++)
        {
            var view = _rows[i];
            if (view.HasError) continue;
            foreach (var part in view.Parts)
            {
                var want = FullScale(view.Scale * dpi, view.SizeOf(part), maxFull);
                if (view.Full(part) is not { } have || Off(have.Scale, want)) return new Job(view, part, want, null);
            }
        }
        for (var i = first; i <= last; i++)
        {
            var view = _rows[i];
            if (view.HasError) continue;
            var px = view.Scale * dpi;
            foreach (var part in view.Parts)
            {
                if (FullScale(px, view.SizeOf(part), maxFull) >= px * 0.999 || TileRegion(i, part) is not { } want) continue;
                var tile = view.Tile(part);
                var covers = tile is not null && Math.Abs(tile.Scale - px) <= px * 0.01
                             && tile.Region.Inflate(0.5).Contains(want.Visible.X, want.Visible.Y) && tile.Region.Inflate(0.5).Contains(want.Visible.Right, want.Visible.Bottom);
                if (!covers) return new Job(view, part, px, want.Region);
            }
        }
        return null;
    }

    /// <summary>The part of a row's page in view (page points), and the area to render: that plus a quarter view around it.</summary>
    private (RectD Region, RectD Visible)? TileRegion(int row, CompareRowView.Part part)
    {
        var view = _rows[row];
        var box = view.BoxOf(part);
        if (box.IsEmpty) return null;
        var vp = new Rect(_scroll.HorizontalOffset, _scroll.VerticalOffset - _tops[row], _scroll.ViewportWidth, _scroll.ViewportHeight);
        var visible = Rect.Intersect(vp, box);
        if (visible.IsEmpty) return null;
        var margin = vp;
        margin.Inflate(vp.Width / 4, vp.Height / 4);
        var area = Rect.Intersect(margin, box);
        RectD ToPoints(Rect r) => new((r.X - box.X) / view.Scale, (r.Y - box.Y) / view.Scale, r.Width / view.Scale, r.Height / view.Scale);
        return (ToPoints(area), ToPoints(visible));
    }

    private async Task RenderAsync(Job job)
    {
        var cancel = _cts.Token;
        var oldEngine = _oldEngine!;
        var newEngine = _newEngine!;
        var view = job.View;
        var (scale, region) = (job.Scale, job.Region);
        var size = view.SizeOf(job.Part);
        try
        {
            BitmapSource bmp;
            List<RectD>? regions = null;
            if (job.Part == CompareRowView.Part.Overlay)
            {
                int op = view.Row.OldPage!.Value, np = view.Row.NewPage!.Value;
                (bmp, regions) = await Task.Run(() =>
                {
                    var diff = VisualCompare.Overlay(Crop(oldEngine, op, scale, region, cancel), Crop(newEngine, np, scale, region, cancel), cancel: cancel);
                    // Areas come from the whole page only; a tile just draws sharper.
                    return (PageViewer.ToBitmap(diff.Image),
                        region is null ? diff.Regions.Select(r => new RectD(r.X / scale, r.Y / scale, r.Width / scale, r.Height / scale)).ToList() : null);
                }, cancel);
            }
            else
            {
                var page = (job.Part == CompareRowView.Part.Old ? view.Row.OldPage : view.Row.NewPage)!.Value;
                var engine = job.Part == CompareRowView.Part.Old ? oldEngine : newEngine;
                bmp = await Task.Run(() => PageViewer.ToBitmap(Crop(engine, page, scale, region, cancel)), cancel);
            }
            var render = new CompareRowView.Render(bmp, scale, region ?? new RectD(0, 0, size.Width, size.Height));
            if (region is null) view.SetFull(job.Part, render, regions);
            else view.SetTile(job.Part, render);
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException)
        {
        }
        catch (Exception ex) when (ex is MuPDFCore.MuPDFException or InvalidOperationException or OutOfMemoryException)
        {
            view.Failed(ex.Message);
        }
    }

    /// <summary>A page, or the part of it inside <paramref name="region"/> (white where the page doesn't reach).</summary>
    private static RenderedImage Crop(PdfEngine engine, int page, double scale, RectD? region, CancellationToken cancel)
    {
        if (region is not { } r) return engine.Render(page, scale, null, cancel);
        var g = engine.GetPage(page);
        var inside = r.Intersect(new RectD(0, 0, g.Width, g.Height));
        return inside.IsEmpty ? new RenderedImage(1, 1, [255, 255, 255]) : engine.Render(page, scale, inside, cancel);
    }

    // ───────────────────────────── Navigating ─────────────────────────────

    private void OnKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;
        switch (key)
        {
            case Key.F8:
                Step(mods.HasFlag(ModifierKeys.Shift) ? -1 : 1);
                break;
            case Key.Down when mods == ModifierKeys.Alt:
                Step(1);
                break;
            case Key.Up when mods == ModifierKeys.Alt:
                Step(-1);
                break;
            case Key.D1 or Key.NumPad1 when mods == ModifierKeys.Control:
                _textMode.IsChecked = true;
                break;
            case Key.D2 or Key.NumPad2 when mods == ModifierKeys.Control:
                _visualMode.IsChecked = true;
                break;
            case Key.OemPlus or Key.Add when mods == ModifierKeys.Control:
                Zoom(1.25);
                break;
            case Key.OemMinus or Key.Subtract when mods == ModifierKeys.Control:
                Zoom(1 / 1.25);
                break;
            case Key.D0 or Key.NumPad0 when mods == ModifierKeys.Control:
                SetZoom(0);
                break;
            case Key.PageDown or Key.PageUp or Key.Home or Key.End when mods == ModifierKeys.Control || !_list.IsKeyboardFocusWithin:
                // The page area isn't focusable: these scroll it from anywhere but the list.
                if (key == Key.PageDown) _scroll.PageDown();
                else if (key == Key.PageUp) _scroll.PageUp();
                else if (key == Key.Home) _scroll.ScrollToTop();
                else _scroll.ScrollToBottom();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    /// <summary>Selects the next or previous change (wrapping around).</summary>
    public void Step(int delta)
    {
        if (_items.Count == 0) return;
        var i = _list.SelectedIndex < 0 ? (delta > 0 ? 0 : _items.Count - 1) : (_list.SelectedIndex + delta + _items.Count) % _items.Count;
        _list.SelectedIndex = i;
        _list.ScrollIntoView(_list.SelectedItem);
        if (_list.ItemContainerGenerator.ContainerFromIndex(i) is ListBoxItem li && _list.IsKeyboardFocusWithin) li.Focus();
    }

    private void OnSelected()
    {
        UpdateButtons();
        if (_list.SelectedItem is not ChangeItem item) return;
        foreach (var r in _rows) r.Select(item.Change);
        GoTo(item);
        Announce($"{_list.SelectedIndex + 1} of {_items.Count}: {item}");
    }

    /// <summary>Scrolls the change into view: its row, and the change itself a third of the way down.</summary>
    private void GoTo(ChangeItem item)
    {
        if (item.Row >= _rows.Count) return;
        var view = _rows[item.Row];
        var spot = view.SpotOf(item.Change);
        var y = _tops[item.Row] + (spot?.Y ?? 0);
        var visible = _scroll.VerticalOffset <= y && y + (spot?.Height ?? view.Height) <= _scroll.VerticalOffset + _scroll.ViewportHeight;
        if (!visible) _scroll.ScrollToVerticalOffset(Math.Max(0, spot is null ? _tops[item.Row] : y - _scroll.ViewportHeight / 3));
        if (spot is { } s && (s.X < _scroll.HorizontalOffset || s.Right > _scroll.HorizontalOffset + _scroll.ViewportWidth))
            _scroll.ScrollToHorizontalOffset(Math.Max(0, s.X - _scroll.ViewportWidth / 3));
    }

    private void OnRowClick(CompareRowView view, MouseButtonEventArgs e)
    {
        var change = view.ChangeAt(e.GetPosition(view));
        var at = change is { } c ? _items.ToList().FindIndex(i => i.Change == c) : _items.ToList().FindIndex(i => i.Row == view.Index && i.Change < 0);
        if (at >= 0) _list.SelectedIndex = at;
    }

    // ───────────────────────────── Report ─────────────────────────────

    private async Task MakeReportAsync()
    {
        if (_result is not { } r) return;
        _report.IsEnabled = false;
        try
        {
            var summary = $"Compared with {_old.Name} on {DateTime.Now.ToString("g", CultureInfo.CurrentCulture)}: {r.Summary()}.";
            var bytes = await Task.Run(() => CompareReport.Annotate(_new.Data, _new.Password, r, _newText, _old.Name, summary));
            var stem = Path.GetFileNameWithoutExtension(_new.Name.Replace(" (saved)", ""));
            _host.OpenSession(DocumentSession.FromBytes(bytes, $"{stem} (compared).pdf", _new.Password));
            _host.ShowStatus($"The changes are comments in \"{stem} (compared).pdf\". Save it to keep it.");
            Announce("The annotated copy opened in a new tab in the main window.");
            _host.Activate();
        }
        catch (OwnerPasswordRequiredException)
        {
            Prompt.Info(this, "The changed file is protected against changes",
                "Comments can't be added to a copy without its permissions password. Open it with that password, or remove its protection, and compare again.");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Prompt.Error(this, "Couldn't make the annotated copy", ex.Message);
        }
        finally
        {
            _report.IsEnabled = true;
        }
    }

    // ───────────────────────────── Dev script ─────────────────────────────

    /// <summary>For DevScript: the summary, the list and the selection.</summary>
    internal string DevDescribe() =>
        $"compare: busy={_busy.Visibility == Visibility.Visible} '{_summary.Text}' rows=[{string.Join("; ", _rows.Select(r => r.Label))}] " +
        $"items={_items.Count} [{string.Join(" | ", _items.Take(12))}] selected={_list.SelectedIndex} visual={_visual} zoom={_zoom:0.##} report={_report.IsEnabled}";

    internal Task DevReportAsync() => MakeReportAsync();

    internal void DevMode(bool visual) => (visual ? _visualMode : _textMode).IsChecked = true;

    internal void DevSelect(int index) => _list.SelectedIndex = index;

    internal void DevZoom(double zoom) => SetZoom(zoom);

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        Pump(); // sharp again on a monitor with another scale
    }

    internal bool DevIdle => _busy.Visibility != Visibility.Visible && !_pumping && !_checking;
}

/// <summary>
/// One row of the compare view: the original's page and the changed page side by side (or their overlay), drawn
/// directly with the change highlights; a header names the pages and what changed. Sized by the window.
/// </summary>
internal sealed class CompareRowView : FrameworkElement
{
    public const double Side = 16, Gap = 16, HeaderHeight = 30, Bottom = 18;

    public readonly record struct Mark(RectD Rect, ChangeKind Kind, int Change);

    public int Index { get; }
    public CompareRow Row { get; }
    public PageGeometry? OldSize { get; }
    public PageGeometry? NewSize { get; }
    public string Label { get; set; } = "";
    public List<Mark> OldMarks { get; } = [];
    public List<Mark> NewMarks { get; } = [];
    public List<Mark> OldCarets { get; } = [];
    public List<Mark> NewCarets { get; } = [];
    public ChangeKind? PageChange { get; set; }
    public int PageChangeIndex { get; set; } = -1;

    /// <summary>DIPs per point.</summary>
    public double Scale { get; private set; } = 1;
    public bool Visual { get; private set; }

    /// <summary>What a row shows: the original's page, the changed page, or their overlay.</summary>
    public enum Part { Old, New, Overlay }

    /// <summary>A render of a page (Region: the whole page, or the part a detail tile covers; page points) at Scale pixels per point.</summary>
    public sealed record Render(BitmapSource Bitmap, double Scale, RectD Region)
    {
        public long Bytes => (long)Bitmap.PixelWidth * Bitmap.PixelHeight * 3;
    }

    private Rect _oldBox, _newBox, _overlayBox;
    private readonly Render?[] _full = new Render?[3];
    private readonly Render?[] _tile = new Render?[3];
    private List<RectD> _regions = [];
    private string? _error;
    private int _selected = -1;
    private bool _sideBySide = true;

    /// <summary>The header's color, from the theme; a theme change redraws the row (the other colors are looked up then too).</summary>
    public static readonly DependencyProperty ForegroundProperty =
        TextElement.ForegroundProperty.AddOwner(typeof(CompareRowView), new FrameworkPropertyMetadata(Brushes.Black, FrameworkPropertyMetadataOptions.AffectsRender));

    public CompareRowView(int index, CompareRow row, PageGeometry? oldSize, PageGeometry? newSize)
    {
        Index = index;
        Row = row;
        OldSize = oldSize;
        NewSize = newSize;
        SnapsToDevicePixels = true;
        SetResourceReference(ForegroundProperty, "TextFillColorPrimaryBrush");
    }

    /// <summary>Sizes the row: <paramref name="zoomScale"/> DIPs per point, or 0 to fit the width (and, overlaid, the height).</summary>
    public void Layout(double width, double viewHeight, double zoomScale, bool visual)
    {
        Visual = visual && Row.OldPage is not null && Row.NewPage is not null;
        _sideBySide = !visual;
        double ow = OldSize?.Width ?? 0, oh = OldSize?.Height ?? 0, nw = NewSize?.Width ?? 0, nh = NewSize?.Height ?? 0;
        double s;
        if (visual)
        {
            var w = Math.Max(Math.Max(ow, nw), 1);
            var h = Math.Max(Math.Max(oh, nh), 1);
            s = zoomScale > 0 ? zoomScale : Math.Min((width - 2 * Side) / w, (viewHeight - HeaderHeight - Bottom) / h);
            s = Math.Clamp(s, 0.05, 12);
            var box = new Rect((width - w * s) / 2, HeaderHeight, w * s, h * s);
            if (Visual) _overlayBox = box;
            // A page only one side has is shown alone, where the overlay would be.
            _oldBox = Row.NewPage is null ? new Rect((width - ow * s) / 2, HeaderHeight, ow * s, oh * s) : Rect.Empty;
            _newBox = Row.OldPage is null ? new Rect((width - nw * s) / 2, HeaderHeight, nw * s, nh * s) : Rect.Empty;
            Height = HeaderHeight + h * s + Bottom;
        }
        else
        {
            var col = (width - 2 * Side - Gap) / 2;
            s = zoomScale > 0 ? zoomScale : col / Math.Max(Math.Max(ow, nw), 1);
            s = Math.Clamp(s, 0.05, 12);
            _oldBox = OldSize is null ? Rect.Empty : new Rect(Side + (col - ow * s) / 2, HeaderHeight, ow * s, oh * s);
            _newBox = NewSize is null ? Rect.Empty : new Rect(Side + col + Gap + (col - nw * s) / 2, HeaderHeight, nw * s, nh * s);
            Height = HeaderHeight + Math.Max(oh, nh) * s + Bottom;
        }
        if (Math.Abs(s - Scale) > 1e-9) _error = null; // a page refused at one zoom may render at another
        Scale = s;
        Width = width;
        InvalidateVisual();
    }

    /// <summary>The parts this row shows in its current layout.</summary>
    public IEnumerable<Part> Parts
    {
        get
        {
            if (Visual)
            {
                yield return Part.Overlay;
                yield break;
            }
            if (Row.OldPage is not null) yield return Part.Old;
            if (Row.NewPage is not null) yield return Part.New;
        }
    }

    public bool HasError => _error is not null;

    /// <summary>A part's page size in points (the overlay: as large as the larger page).</summary>
    public (double Width, double Height) SizeOf(Part part) => part switch
    {
        Part.Old => (OldSize?.Width ?? 0, OldSize?.Height ?? 0),
        Part.New => (NewSize?.Width ?? 0, NewSize?.Height ?? 0),
        _ => (Math.Max(OldSize?.Width ?? 0, NewSize?.Width ?? 0), Math.Max(OldSize?.Height ?? 0, NewSize?.Height ?? 0)),
    };

    /// <summary>Where a part is drawn (DIPs, relative to the row).</summary>
    public Rect BoxOf(Part part) => part switch { Part.Old => _oldBox, Part.New => _newBox, _ => _overlayBox };

    public Render? Full(Part part) => _full[(int)part];
    public Render? Tile(Part part) => _tile[(int)part];

    /// <summary>Memory held by this row's bitmaps.</summary>
    public long Bytes => _full.Sum(r => r?.Bytes ?? 0) + _tile.Sum(r => r?.Bytes ?? 0);

    public void SetFull(Part part, Render render, List<RectD>? regions = null)
    {
        _full[(int)part] = render;
        if (regions is not null) _regions = regions;
        InvalidateVisual();
    }

    public void SetTile(Part part, Render render)
    {
        _tile[(int)part] = render;
        InvalidateVisual();
    }

    public void Failed(string message)
    {
        _error = message;
        InvalidateVisual();
    }

    /// <summary>Frees the bitmaps (the row is far from view, or over the memory budget).</summary>
    public void Release()
    {
        if (Bytes == 0) return;
        Array.Clear(_full);
        Array.Clear(_tile);
        InvalidateVisual();
    }

    /// <summary>Frees the detail tiles (the row scrolled out of view).</summary>
    public void ReleaseTiles()
    {
        if (_tile.All(t => t is null)) return;
        Array.Clear(_tile);
        InvalidateVisual();
    }

    public void Select(int change)
    {
        var had = _selected >= 0 && Has(_selected);
        _selected = change;
        if (had || (change >= 0 && Has(change))) InvalidateVisual();
    }

    private bool Has(int change) => PageChangeIndex == change || OldMarks.Exists(m => m.Change == change) || NewMarks.Exists(m => m.Change == change)
                                    || OldCarets.Exists(m => m.Change == change) || NewCarets.Exists(m => m.Change == change);

    /// <summary>Where a change is drawn in this row (DIPs, relative to the row), for scrolling to it.</summary>
    public Rect? SpotOf(int change)
    {
        // Overlaid: a "looks different" entry goes to the first area that differs (once the overlay is rendered).
        if (Visual) return change < 0 && _regions.Count > 0 ? ToView(_regions[0], _overlayBox) : null;
        if (change < 0 || change == PageChangeIndex) return null;
        Rect? spot = null;
        void Add(IEnumerable<Mark> marks, Rect box)
        {
            foreach (var m in marks.Where(m => m.Change == change))
            {
                var r = ToView(m.Rect, box);
                spot = spot is { } s ? Rect.Union(s, r) : r;
            }
        }
        Add(OldMarks.Concat(OldCarets), _oldBox);
        Add(NewMarks.Concat(NewCarets), _newBox);
        return spot;
    }

    /// <summary>The change drawn at a point of the row, if any.</summary>
    public int? ChangeAt(Point p)
    {
        if (Visual) return null;
        foreach (var (marks, box) in new[] { (OldMarks.Concat(OldCarets), _oldBox), (NewMarks.Concat(NewCarets), _newBox) })
        {
            if (box.IsEmpty || !box.Contains(p)) continue;
            foreach (var m in marks)
            {
                var r = ToView(m.Rect, box);
                r.Inflate(3, 3);
                if (r.Contains(p)) return m.Change;
            }
        }
        return PageChangeIndex >= 0 ? PageChangeIndex : null;
    }

    private Rect ToView(RectD r, Rect box) => new(box.X + r.X * Scale, box.Y + r.Y * Scale, Math.Max(0, r.Width * Scale), Math.Max(0, r.Height * Scale));

    private static readonly Dictionary<ChangeKind, (Brush Fill, Pen Edge)> Looks = new()
    {
        [ChangeKind.Inserted] = Look(Color.FromRgb(46, 160, 67)),
        [ChangeKind.Deleted] = Look(Color.FromRgb(214, 60, 60)),
        [ChangeKind.Changed] = Look(Color.FromRgb(230, 150, 20)),
    };

    private static (Brush, Pen) Look(Color c)
    {
        var fill = new SolidColorBrush(Color.FromArgb(70, c.R, c.G, c.B));
        fill.Freeze();
        var pen = new Pen(new SolidColorBrush(c), 1);
        pen.Freeze();
        return (fill, pen);
    }

    private static readonly Pen RegionPen = MakePen(Color.FromRgb(230, 120, 0), 2);
    private static readonly Pen RemovedPagePen = MakePen(Color.FromRgb(214, 60, 60), 3);
    private static readonly Pen InsertedPagePen = MakePen(Color.FromRgb(46, 160, 67), 3);

    private static Pen MakePen(Color c, double width)
    {
        var p = new Pen(new SolidColorBrush(c), width);
        p.Freeze();
        return p;
    }

    protected override void OnRender(DrawingContext dc)
    {
        var fg = (Brush)GetValue(ForegroundProperty);
        var muted = TryFindResource("TextFillColorSecondaryBrush") as Brush ?? Brushes.Gray;
        var stroke = TryFindResource("CardStrokeColorDefaultBrush") as Brush ?? Brushes.LightGray;
        var accent = TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.DodgerBlue;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var face = new Typeface(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        var semibold = new Typeface(face.FontFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

        var label = Label;
        var text = new FormattedText(label, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, semibold, 12.5, fg, dpi)
        {
            MaxTextWidth = Math.Max(10, Width - 2 * Side),
            MaxLineCount = 1,
            Trimming = TextTrimming.CharacterEllipsis,
        };
        dc.DrawText(text, new Point(Side, (HeaderHeight - text.Height) / 2));

        var edge = new Pen(stroke, 1);
        if (Visual)
        {
            DrawPage(dc, Part.Overlay, _overlayBox, edge, face, dpi);
            foreach (var r in _regions)
            {
                var v = ToView(r, _overlayBox);
                v.Inflate(4, 4);
                dc.DrawRoundedRectangle(null, RegionPen, v, 3, 3);
            }
        }
        else
        {
            DrawSide(dc, Part.Old, _oldBox, OldMarks, OldCarets, edge, face, dpi, accent);
            DrawSide(dc, Part.New, _newBox, NewMarks, NewCarets, edge, face, dpi, accent);
            if (_sideBySide && Row.NewPage is null) Missing(dc, "Not in the changed file", 1, muted, face, dpi);
            else if (_sideBySide && Row.OldPage is null) Missing(dc, "Not in the original", 0, muted, face, dpi);
        }
        if (PageChange is { } pc)
        {
            var box = PageChange == ChangeKind.PageRemoved ? _oldBox : _newBox;
            if (!box.IsEmpty)
            {
                var b = box;
                b.Inflate(2, 2);
                dc.DrawRectangle(null, pc == ChangeKind.PageRemoved ? RemovedPagePen : InsertedPagePen, b);
                if (_selected == PageChangeIndex)
                {
                    b.Inflate(4, 4);
                    dc.DrawRectangle(null, new Pen(accent, 2), b);
                }
            }
        }
        if (_error is not null)
        {
            var err = new FormattedText($"This page couldn't be shown: {_error}", CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, 12, muted, dpi) { MaxTextWidth = Math.Max(10, Width - 2 * Side) };
            dc.DrawText(err, new Point(Side, HeaderHeight + 8));
        }
    }

    private void Missing(DrawingContext dc, string message, int column, Brush muted, Typeface face, double dpi)
    {
        var col = (Width - 2 * Side - Gap) / 2;
        var x = Side + column * (col + Gap);
        var t = new FormattedText(message, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, 13, muted, dpi) { MaxTextWidth = Math.Max(10, col) };
        var box = new Rect(x, HeaderHeight, col, Math.Max(40, Height - HeaderHeight - Bottom));
        var dash = new Pen(muted, 1) { DashStyle = DashStyles.Dash };
        dc.DrawRoundedRectangle(null, dash, box, 6, 6);
        dc.DrawText(t, new Point(box.X + (col - t.Width) / 2, box.Y + 24));
    }

    private void DrawSide(DrawingContext dc, Part part, Rect box, List<Mark> marks, List<Mark> carets, Pen edge, Typeface face, double dpi, Brush accent)
    {
        if (box.IsEmpty) return;
        DrawPage(dc, part, box, edge, face, dpi);
        foreach (var m in marks)
        {
            var r = ToView(m.Rect, box);
            r.Inflate(1.5, 1); // a little room, so the outline doesn't run through the letters
            var (fill, pen) = Looks.GetValueOrDefault(m.Kind, Looks[ChangeKind.Changed]);
            dc.DrawRectangle(fill, m.Change == _selected ? new Pen(accent, 2) : pen, r);
        }
        foreach (var m in carets)
        {
            // Where words went missing (or were added on the other side): a small wedge at the spot.
            var r = ToView(m.Rect, box);
            var (_, pen) = Looks.GetValueOrDefault(m.Kind, Looks[ChangeKind.Changed]);
            var p = m.Change == _selected ? new Pen(accent, 2.5) : new Pen(pen.Brush, 2);
            dc.DrawLine(p, new Point(r.X, r.Y), new Point(r.X, r.Bottom));
            var wedge = new StreamGeometry();
            using (var g = wedge.Open())
            {
                g.BeginFigure(new Point(r.X - 4, r.Bottom + 5), true, true);
                g.LineTo(new Point(r.X + 4, r.Bottom + 5), true, false);
                g.LineTo(new Point(r.X, r.Bottom), true, false);
            }
            dc.DrawGeometry(p.Brush, null, wedge);
        }
    }

    /// <summary>The page's whole render (capped in size), then the sharp tile of the part in view on top.</summary>
    private void DrawPage(DrawingContext dc, Part part, Rect box, Pen edge, Typeface face, double dpi)
    {
        dc.DrawRectangle(Brushes.White, edge, box);
        var full = Full(part);
        if (full is not null)
        {
            dc.PushClip(new RectangleGeometry(box));
            foreach (var r in Tile(part) is { } tile ? [full, tile] : new[] { full })
                dc.DrawImage(r.Bitmap, new Rect(box.X + r.Region.X * Scale, box.Y + r.Region.Y * Scale,
                    r.Bitmap.PixelWidth / r.Scale * Scale, r.Bitmap.PixelHeight / r.Scale * Scale));
            dc.Pop();
        }
        else
        {
            var t = new FormattedText("Rendering…", CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, 12, Brushes.Gray, dpi);
            dc.DrawText(t, new Point(box.X + (box.Width - t.Width) / 2, box.Y + Math.Min(40, box.Height / 2)));
        }
    }

    protected override Size MeasureOverride(Size availableSize) => new(double.IsNaN(Width) ? 0 : Width, double.IsNaN(Height) ? 0 : Height);
}
