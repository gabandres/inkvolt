using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>How the document view is split (View › Split View).</summary>
public enum SplitMode { None, TopAndBottom, SideBySide }

/// <summary>
/// Split view: a second pane on the same document, with its own page, scroll, zoom, layout and view rotation, so two
/// places can be read at once. The panes share the document, its undo history and the page selection; an edit made
/// anywhere re-renders both (the second pane follows every engine the main pane gets). The second pane is for reading:
/// hand, text selection and snapshot tools, links, copy. Tools that change the document work in the main pane, which
/// becomes the active one when such a tool is picked. Navigation (page and zoom commands, the page pill, thumbnails,
/// bookmarks) acts on the active pane, which has an accent frame. Each pane renders on its own (its own render queue
/// and page bitmaps); the engine, and so MuPDF's cache of decoded images and fonts and the text cache, is shared.
/// The split is kept per tab while it is open, not saved.
/// </summary>
public partial class DocumentTab
{
    private PageViewer? _second;
    private RenderScheduler? _secondScheduler;
    private bool _secondActive;
    /// <summary>Another document the second pane shows beside this one (a translated copy's original): it scrolls with the main pane and takes no edits.</summary>
    private PdfEngine? _beside;
    private PageViewer? _moving;
    private System.Windows.FrameworkElement? _mainCaption, _secondCaption;

    public SplitMode Split { get; private set; }

    /// <summary>The pane navigation acts on: the second pane when it is the active one, else the main pane.</summary>
    public PageViewer ActiveView => _secondActive && _second is not null ? _second : Viewer;

    public bool IsSecondPaneFocused => _second?.IsKeyboardFocusWithin == true;

    private static bool IsReadingTool(ViewerTool tool) => tool is ViewerTool.Hand or ViewerTool.SelectText or ViewerTool.Snapshot;

    private void InitSplit()
    {
        // Every engine the main pane gets (an edit, undo, layers shown or hidden) goes to the second pane too.
        Viewer.EngineChanged += (_, contentOnly) =>
        {
            if (_beside is null && _second is not null && _secondScheduler is not null && Viewer.Engine is { } engine)
            {
                _secondScheduler.Clear();
                _second.SetEngine(engine, _secondScheduler, keepPosition: true, contentOnly: contentOnly);
            }
        };
        Viewer.ToolChanged += (_, _) =>
        {
            if (_second is not null && !IsReadingTool(Viewer.Tool)) ActivatePane(second: false);
        };
        MainPaneFrame.PreviewMouseDown += (_, _) => ActivatePane(second: false);
        Viewer.IsKeyboardFocusWithinChanged += (_, e) =>
        {
            if (e.NewValue is true) ActivatePane(second: false);
        };
        CloseSplitButton.Click += (_, _) => SetSplit(SplitMode.None);
        CloseSplitButton.ToolTip = Cmd.Tip("Close the split", Cmd.RemoveSplit);
        Viewer.ScrollChanged += (_, e) =>
        {
            if (_second is { } other) Follow(Viewer, other, e);
        };
        Viewer.ZoomChanged += (_, _) =>
        {
            if (_beside is not null && _second is { } other) FollowZoom(Viewer, other);
        };
    }

    /// <summary>
    /// Shows another document beside this one in the second pane, on the left, and keeps the two at the same place and
    /// zoom (they have the same pages). The pane owns <paramref name="other"/>; closing the split closes it.
    /// </summary>
    public void ShowBeside(PdfEngine other, string otherName)
    {
        if (_disposed)
        {
            other.Dispose();
            return;
        }
        SetSplit(SplitMode.None);
        _beside = other;
        SetSplit(SplitMode.SideBySide);
        _mainCaption = PaneCaption("Translated");
        _secondCaption = PaneCaption("Original");
        _secondCaption.ToolTip = otherName;
        SplitHost.Children.Add(_mainCaption);
        SecondPaneHost.Children.Add(_secondCaption);
        ApplySplitLayout();
    }

    private static System.Windows.FrameworkElement PaneCaption(string text)
    {
        var label = new TextBlock { Text = text, FontWeight = FontWeights.SemiBold };
        var box = new Border
        {
            Child = label,
            Padding = new Thickness(8, 2, 8, 3),
            CornerRadius = new CornerRadius(4),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(8, 8, 0, 0),
            IsHitTestVisible = false,
        };
        Panel.SetZIndex(box, 2);
        box.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorQuarternaryBrush");
        return box;
    }

    /// <summary>One pane moved: the other goes to the same place. Its own scroll event, a moment later, isn't followed back.</summary>
    private void Follow(PageViewer from, PageViewer to, ScrollChangedEventArgs e)
    {
        if (_beside is null || !ReferenceEquals(e.OriginalSource, from) || (e.VerticalChange == 0 && e.HorizontalChange == 0) || ReferenceEquals(_moving, from)) return;
        _moving = to;
        var (page, x, y) = from.ViewCorner();
        to.ShowCorner(page, x, y);
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (ReferenceEquals(_moving, to)) _moving = null;
        });
    }

    private void FollowZoom(PageViewer from, PageViewer to)
    {
        if (ReferenceEquals(_moving, from)) return;
        if (from.ZoomMode == to.ZoomMode && Math.Abs(from.Zoom - to.Zoom) < 0.001) return;
        _moving = to;
        if (from.ZoomMode == ZoomMode.Custom) to.SetZoom(from.Zoom);
        else to.SetZoomMode(from.ZoomMode);
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (ReferenceEquals(_moving, to)) _moving = null;
        });
    }

    /// <summary>Splits the view (or changes how), or closes the split with <see cref="SplitMode.None"/>.</summary>
    public void SetSplit(SplitMode mode)
    {
        if (mode == Split) return;
        if (IsOrganizing) SetOrganizing(false);
        if (mode == SplitMode.None)
        {
            CloseSecondPane();
            Split = SplitMode.None;
            ApplySplitLayout();
            Viewer.Focus();
            RaiseState();
            return;
        }
        var opening = _second is null;
        if (opening) OpenSecondPane();
        Split = mode;
        ApplySplitLayout();
        if (opening && _beside is null)
        {
            // The new pane starts where the main pane is, so it can be moved on from there.
            var page = Viewer.CurrentPage;
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () =>
            {
                if (_second is null) return;
                _second.GoToPage(page, record: false);
                ActivatePane(second: true);
                _second.Focus();
            });
        }
        RaiseState();
    }

    /// <summary>Moves to the other pane (Ctrl+F6). False when the view isn't split.</summary>
    public bool SwitchPane()
    {
        if (_second is null) return false;
        ActivatePane(!_secondActive);
        ActiveView.Focus();
        return true;
    }

    /// <summary>Focuses a pane (F6 cycling).</summary>
    public void FocusPaneView(bool second)
    {
        if (second && _second is not null) _second.Focus();
        else Viewer.Focus();
    }

    private void OpenSecondPane()
    {
        _secondScheduler = new RenderScheduler(Dispatcher);
        var second = new PageViewer { Background = Viewer.Background, Focusable = true };
        second.SetResourceReference(BackgroundProperty, "SolidBackgroundFillColorSecondaryBrush");
        AutomationProperties.SetName(second, "Document pages, second pane");
        second.InvertColors = Viewer.InvertColors;
        second.SetLayout(Viewer.Layout);
        second.SetViewRotation(Viewer.ViewRotation);
        if (Viewer.ZoomMode == ZoomMode.Custom) second.SetZoom(Viewer.Zoom);
        else second.SetZoomMode(Viewer.ZoomMode);
        second.SetEngine(_beside ?? Viewer.Engine ?? Session.Engine, _secondScheduler, keepPosition: false);
        second.ScrollChanged += (_, e) => Follow(second, Viewer, e);
        second.ZoomChanged += (_, _) =>
        {
            if (_beside is not null) FollowZoom(second, Viewer);
        };

        second.CurrentPageChanged += (_, _) =>
        {
            if (_secondActive) SyncThumbSelection();
            RaiseState();
        };
        second.ZoomChanged += (_, _) => RaiseState();
        second.SelectionChanged += (_, _) => RaiseState();
        second.ToolChanged += (_, _) =>
        {
            // Only reading tools here: anything else is for the main pane.
            if (!IsReadingTool(second.Tool))
            {
                var tool = second.Tool;
                second.Tool = ViewerTool.Hand;
                Viewer.Tool = tool;
            }
            RaiseState();
        };
        second.StatusMessage += (_, m) => Notify(m);
        second.PreviewMouseDown += (_, _) => ActivatePane(second: true);
        second.IsKeyboardFocusWithinChanged += (_, e) =>
        {
            if (e.NewValue is true) ActivatePane(second: true);
        };
        second.ContextMenu = SecondPaneMenu();
        SecondPaneHost.Children.Insert(0, second);
        _second = second;
    }

    private static ContextMenu SecondPaneMenu()
    {
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Command = Cmd.Copy });
        menu.Items.Add(new MenuItem { Command = Cmd.SelectAll });
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Command = Cmd.SwitchPane });
        menu.Items.Add(new MenuItem { Command = Cmd.RemoveSplit });
        return menu;
    }

    private void CloseSecondPane()
    {
        if (_second is null) return;
        var hadFocus = _second.IsKeyboardFocusWithin;
        SecondPaneHost.Children.Remove(_second);
        _second = null;
        _secondScheduler?.Dispose();
        _secondScheduler = null;
        _secondActive = false;
        CloseBeside();
        UpdatePaneFrames();
        SyncThumbSelection();
        if (hadFocus) Viewer.Focus();
    }

    private void ApplySplitLayout()
    {
        var rows = SplitHost.RowDefinitions;
        var cols = SplitHost.ColumnDefinitions;
        // The splitter leaves pixel or star sizes behind: start each layout from even halves.
        rows[0].Height = rows[2].Height = new GridLength(1, GridUnitType.Star);
        cols[0].Width = cols[2].Width = new GridLength(1, GridUnitType.Star);
        rows[1].Height = cols[1].Width = GridLength.Auto;

        var split = Split != SplitMode.None && _second is not null;
        SecondPaneFrame.Visibility = PaneSplitter.Visibility = split ? Visibility.Visible : Visibility.Collapsed;
        // The other document, when there is one, comes first (left or above).
        var (firstFrame, lastFrame) = _beside is null ? (MainPaneFrame, SecondPaneFrame) : (SecondPaneFrame, MainPaneFrame);
        if (!split)
        {
            Place(MainPaneFrame, 0, 0, 3, 3);
            UpdatePaneFrames();
            return;
        }
        if (Split == SplitMode.TopAndBottom)
        {
            Place(firstFrame, 0, 0, 1, 3);
            Place(PaneSplitter, 1, 0, 1, 3);
            Place(lastFrame, 2, 0, 1, 3);
            PaneSplitter.Height = 6;
            PaneSplitter.Width = double.NaN;
            PaneSplitter.ResizeDirection = GridResizeDirection.Rows;
            PaneSplitter.Cursor = Cursors.SizeNS;
        }
        else
        {
            Place(firstFrame, 0, 0, 3, 1);
            Place(PaneSplitter, 0, 1, 3, 1);
            Place(lastFrame, 0, 2, 3, 1);
            PaneSplitter.Width = 6;
            PaneSplitter.Height = double.NaN;
            PaneSplitter.ResizeDirection = GridResizeDirection.Columns;
            PaneSplitter.Cursor = Cursors.SizeWE;
        }
        UpdatePaneFrames();
        if (_mainCaption is not null) Place(_mainCaption, Grid.GetRow(MainPaneFrame), Grid.GetColumn(MainPaneFrame), Grid.GetRowSpan(MainPaneFrame), Grid.GetColumnSpan(MainPaneFrame));

        static void Place(UIElement e, int row, int col, int rowSpan, int colSpan)
        {
            Grid.SetRow(e, row);
            Grid.SetColumn(e, col);
            Grid.SetRowSpan(e, rowSpan);
            Grid.SetColumnSpan(e, colSpan);
        }
    }

    private void ActivatePane(bool second)
    {
        if (_second is null) second = false;
        if (_secondActive == second) return;
        _secondActive = second;
        UpdatePaneFrames();
        SyncThumbSelection();
        RaiseState();
    }

    /// <summary>The active pane's accent frame (only while split).</summary>
    private void UpdatePaneFrames()
    {
        var split = _second is not null && Split != SplitMode.None;
        MainPaneFrame.BorderThickness = new Thickness(split ? 2 : 0);
        SecondPaneFrame.BorderThickness = new Thickness(split ? 2 : 0);
        SetFrame(MainPaneFrame, split && !_secondActive);
        SetFrame(SecondPaneFrame, split && _secondActive);

        static void SetFrame(Border frame, bool active)
        {
            if (active) frame.SetResourceReference(Border.BorderBrushProperty, "AccentFillColorDefaultBrush");
            else frame.BorderBrush = System.Windows.Media.Brushes.Transparent;
        }
    }

    /// <summary>Night reading follows into the second pane.</summary>
    private void SplitFollowDarkPages(bool on)
    {
        if (_second is not null) _second.InvertColors = on;
    }

    private void DisposeSplit()
    {
        _secondScheduler?.Dispose();
        _secondScheduler = null;
        CloseBeside();
    }

    /// <summary>Lets go of the other document. Off the UI thread: it waits for a page still rendering.</summary>
    private void CloseBeside()
    {
        if (_mainCaption is not null) SplitHost.Children.Remove(_mainCaption);
        if (_secondCaption is not null) SecondPaneHost.Children.Remove(_secondCaption);
        _mainCaption = _secondCaption = null;
        _moving = null;
        if (_beside is not { } other) return;
        _beside = null;
        _ = Task.Run(other.Dispose);
    }

    internal string DevSplitState() =>
        _second is null
            ? "split=none"
            : $"split={Split} active={(_secondActive ? "second" : "main")} main: page={Viewer.CurrentPage + 1} zoom={Viewer.Zoom:P0} second: page={_second.CurrentPage + 1} zoom={_second.Zoom:P0} layout={_second.Layout}";
}
