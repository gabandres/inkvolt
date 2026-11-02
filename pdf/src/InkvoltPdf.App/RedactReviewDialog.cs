using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>What the person chose in <see cref="RedactReviewDialog"/>.</summary>
/// <param name="LookAreas">Places with ink nothing could read, chosen to be blacked out whatever they say.</param>
internal sealed record RedactReview(List<RedactionMatch> Accepted, List<RedactionMatch> Skipped, List<RedactMark> LookAreas);

/// <summary>A line of the list: a hit, or a page to look at by hand.</summary>
internal sealed class ReviewRow : INotifyPropertyChanged
{
    private bool _accepted;

    public event PropertyChangedEventHandler? PropertyChanged;

    public RedactionMatch? Hit { get; init; }

    public RedactionLook? Look { get; init; }

    public int Page => Hit?.Page ?? Look!.Page;

    public string Where => $"Page {Page + 1}";

    public string Kind => Hit is { } h ? RedactionPatterns.Name(h.Pattern) + (h.FromOcr ? " (read by OCR)" : "") : "Look at this page by hand";

    public string Before => Hit is { } h ? (h.Before.Length > 28 ? "…" + h.Before[^28..] : h.Before) : "";

    public string Value => Hit is { } h ? RedactionPatterns.Displayable(h.Text) : "";

    public string After => Hit is { } h ? (h.After.Length > 28 ? h.After[..28] + "…" : h.After) : Look!.Short;

    public Visibility CheckVisibility => Hit is not null || Look!.Unread.Count > 0 ? Visibility.Visible : Visibility.Hidden;

    /// <summary>What the check box does, for a screen reader.</summary>
    public string Spoken => Hit is not null
        ? $"{Where}, {Kind}: {Before}{Value}{After}. Checked: it will be redacted."
        : $"{Where}: {Look!.Text} Checked: the places where nothing was read will be blacked out.";

    public bool Accepted
    {
        get => _accepted;
        set
        {
            if (_accepted == value) return;
            _accepted = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Accepted)));
        }
    }
}

/// <summary>
/// Every hit with its page and the words around it, accepted or skipped one by one or all, before anything is applied, with
/// the page beside the list to check it against. Pages only text recognition could read come first: the list never lets
/// a scan pass as looked at, whatever was or wasn't found on it.
/// </summary>
internal sealed class RedactReviewDialog
{
    private readonly FormDialog _dialog;
    private readonly List<ReviewRow> _rows;
    private readonly ListBox _list = new() { Height = 430, MinWidth = 540 };
    private readonly Image _page = new() { Stretch = Stretch.None };
    private readonly Canvas _marks = new() { IsHitTestVisible = false };
    private readonly TextBlock _pageLabel = new() { Margin = new Thickness(0, 0, 0, 4), FontWeight = FontWeights.SemiBold };
    private readonly DocumentTab _tab;
    private CancellationTokenSource? _render;
    private bool _settingAll;

    /// <summary>The list on the screen, for the developer script.</summary>
    internal static RedactReviewDialog? Open { get; private set; }

    private RedactReviewDialog(Window owner, DocumentTab tab, RedactionSearchResult found)
    {
        _tab = tab;
        // In page order, a page to look at just before its hits: a long scan's flags mustn't push every hit out of sight.
        _rows =
        [
            .. found.Looks.Select(l => new ReviewRow { Look = l })
                .Concat(found.Hits.Select(h => new ReviewRow { Hit = h, Accepted = true }))
                .OrderBy(r => r.Page).ThenBy(r => r.Look is null).ThenBy(r => r.Hit?.Rects[0].Y ?? 0).ThenBy(r => r.Hit?.Rects[0].X ?? 0),
        ];
        _dialog = new FormDialog(owner, "Check What Was Found", "Redact", 1000);
        Build(found);
    }

    public static RedactReview? Show(Window owner, DocumentTab tab, RedactionSearchResult found)
    {
        var review = new RedactReviewDialog(owner, tab, found);
        Open = review;
        try
        {
            review.UpdateOk();
            if (!review._dialog.ShowModal()) return null;
            var (rows, marks) = (review._rows, new List<RedactMark>());
            foreach (var row in rows.Where(r => r.Look is not null && r.Accepted))
                marks.AddRange(row.Look!.Unread.Select(a => new RedactMark(row.Page, a)));
            return new RedactReview([.. rows.Where(r => r.Hit is not null && r.Accepted).Select(r => r.Hit!)], [.. rows.Where(r => r.Hit is not null && !r.Accepted).Select(r => r.Hit!)], marks);
        }
        finally
        {
            Open = null;
            review._render?.Cancel();
        }
    }

    private void Build(RedactionSearchResult found)
    {
        var hits = found.Hits.Count;
        _dialog.AddNote((hits == 0 ? "Nothing matching was found. " : hits == 1 ? "1 match was found. Untick it to keep it. " : $"{hits:N0} matches were found. Untick any you want to keep. ") +
                        "Nothing is removed until you press Redact. Pages with something to remove become images, and you can undo it until you save.");
        if (found.Looks.Count > 0)
        {
            var warn = _dialog.AddNote($"Look at {RedactionReport.Pages(found.Looks.Select(l => l.Page))} yourself, whatever the list says: " +
                                       "text in scans and pictures is read by text recognition (OCR), which can misread words and miss whole lines, so these pages can't be taken as clean. Each is flagged in the list.");
            warn.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
            AutomationProperties.SetLiveSetting(warn, AutomationLiveSetting.Polite);
        }

        _list.ItemTemplate = (DataTemplate)XamlReader.Parse(
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
            "<DockPanel Margin='0,3,4,3'>" +
            "<CheckBox DockPanel.Dock='Left' IsChecked='{Binding Accepted, Mode=TwoWay}' Visibility='{Binding CheckVisibility, Mode=OneTime}' " +
            "AutomationProperties.Name='{Binding Spoken, Mode=OneTime}' VerticalAlignment='Top' MinWidth='0' Margin='0,0,8,0' />" +
            "<StackPanel>" +
            "<TextBlock><Run Text='{Binding Where, Mode=OneTime}' FontWeight='SemiBold' /><Run Text=' · ' /><Run Text='{Binding Kind, Mode=OneTime}' /></TextBlock>" +
            "<TextBlock TextWrapping='Wrap' Foreground='{DynamicResource TextFillColorSecondaryBrush}'><Run Text='{Binding Before, Mode=OneTime}' />" +
            "<Run Text='{Binding Value, Mode=OneTime}' FontWeight='Bold' Foreground='{DynamicResource TextFillColorPrimaryBrush}' /><Run Text='{Binding After, Mode=OneTime}' /></TextBlock>" +
            "</StackPanel></DockPanel></DataTemplate>");
        _list.ItemsSource = _rows;
        ScrollViewer.SetHorizontalScrollBarVisibility(_list, ScrollBarVisibility.Disabled);
        VirtualizingPanel.SetIsVirtualizing(_list, true);
        VirtualizingPanel.SetVirtualizationMode(_list, VirtualizationMode.Recycling);
        AutomationProperties.SetName(_list, "What was found");
        _list.SelectionChanged += (_, _) =>
        {
            if (_list.SelectedItem is { } selected) _list.ScrollIntoView(selected);
            ShowSelected();
        };
        // Space ticks or unticks the line, wherever the focus is in it.
        _list.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Space || _list.SelectedItem is not ReviewRow { CheckVisibility: Visibility.Visible } row) return;
            row.Accepted = !row.Accepted;
            e.Handled = true;
        };
        foreach (var row in _rows) row.PropertyChanged += (_, _) => UpdateOk();

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(392) });
        grid.Children.Add(_list);
        var pane = new DockPanel { Margin = new Thickness(12, 0, 0, 0) };
        DockPanel.SetDock(_pageLabel, Dock.Top);
        pane.Children.Add(_pageLabel);
        var sheet = new Grid { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        sheet.Children.Add(_page);
        sheet.Children.Add(_marks);
        var scroll = new ScrollViewer { Content = sheet, Height = 408, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
        pane.Children.Add(scroll);
        Grid.SetColumn(pane, 1);
        grid.Children.Add(pane);
        _dialog.Add(null, grid);

        _dialog.AddFooterButton("Accept All").Click += (_, _) => SetAll(true);
        _dialog.AddFooterButton("Skip All").Click += (_, _) => SetAll(false);
        if (_rows.Count > 0) _list.SelectedIndex = 0;
    }

    private void SetAll(bool accepted)
    {
        // The count once, at the end: per row it would be quadratic on a list of a hundred thousand.
        _settingAll = true;
        foreach (var row in _rows.Where(r => r.Hit is not null)) row.Accepted = accepted;
        _settingAll = false;
        UpdateOk();
    }

    private void UpdateOk()
    {
        if (_settingAll) return;
        var hits = _rows.Count(r => r.Hit is not null && r.Accepted);
        var areas = _rows.Where(r => r.Look is not null && r.Accepted).Sum(r => r.Look!.Unread.Count);
        _dialog.SetOkText(hits + areas == 0 ? "Keep All" : areas == 0 ? (hits == 1 ? "Redact 1" : $"Redact {hits:N0}") : $"Redact {hits + areas:N0}");
    }

    /// <summary>The selected line's page, with what the line is about outlined.</summary>
    private async void ShowSelected()
    {
        if (_list.SelectedItem is not ReviewRow row || _tab.PageView.Engine is not { } engine) return;
        _render?.Cancel();
        var cts = _render = new CancellationTokenSource();
        _pageLabel.Text = row.Where;
        var g = engine.GetPage(row.Page);
        var scale = Math.Min(1.2, 372 / Math.Max(1, g.Width));
        RenderedImage image;
        try
        {
            await Task.Delay(40, cts.Token);
            image = await Task.Run(() => engine.Render(row.Page, scale, null, cts.Token), cts.Token);
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or InvalidOperationException or MuPDFCore.MuPDFException)
        {
            return;
        }
        if (cts.IsCancellationRequested) return;
        var source = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr24, null, image.Pixels, image.Width * 3);
        source.Freeze();
        _page.Source = source;
        AutomationProperties.SetName(_page, $"{row.Where}, as it is now");
        _marks.Children.Clear();
        _marks.Width = image.Width;
        _marks.Height = image.Height;
        var boxes = row.Hit?.Rects ?? row.Look!.Unread;
        foreach (var box in boxes)
        {
            var mark = new Rectangle { Width = Math.Max(2, box.Width * scale + 4), Height = Math.Max(2, box.Height * scale + 4), StrokeThickness = 2 };
            mark.SetResourceReference(Shape.StrokeProperty, row.Hit is not null ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush");
            Canvas.SetLeft(mark, box.X * scale - 2);
            Canvas.SetTop(mark, box.Y * scale - 2);
            _marks.Children.Add(mark);
        }
        if (boxes.Count > 0 && VisualTreeHelperFind(_page) is { } scroll)
            scroll.ScrollToVerticalOffset(Math.Max(0, boxes[0].Y * scale - 120));
    }

    private static ScrollViewer? VisualTreeHelperFind(DependencyObject from)
    {
        for (var d = from; d is not null; d = VisualTreeHelper.GetParent(d))
            if (d is ScrollViewer s) return s;
        return null;
    }

    // ───────────────────────────── for the developer script ─────────────────────────────

    internal void DevSelect(int index) => _list.SelectedIndex = index;

    internal void DevToggle(int index)
    {
        _rows[index].Accepted = !_rows[index].Accepted;
        _list.SelectedIndex = index;
    }

    internal void DevAll(bool accepted) => SetAll(accepted);

    internal string DevState() =>
        $"review: {_rows.Count(r => r.Hit is not null)} hits, {_rows.Count(r => r.Hit is not null && r.Accepted)} accepted, looks on {string.Join(',', _rows.Where(r => r.Look is not null).Select(r => r.Page + 1))}";

    internal void DevPress() => _dialog.DialogResult = true;

    internal void DevCancel() => _dialog.DialogResult = false;

    internal Window Window => _dialog;
}
