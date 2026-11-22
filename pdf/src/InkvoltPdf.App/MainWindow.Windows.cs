using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Two documents side by side (roadmap 4.9): File › New Window, a tab dragged out of the strip into a window of its own or
/// onto another window's strip, and the tab menu's Move to New Window and Move to Window. Which window owns which tab, and
/// what may move, is <see cref="App.Hub"/>'s (<see cref="DocumentWindows"/>, <see cref="TabDrag"/>); this turns the mouse
/// and the menus into its inputs and moves the tab's view.
/// </summary>
public partial class MainWindow
{
    private void BindWindowCommands()
    {
        BindAlways(Cmd.NewWindow, () => App.Current.OpenNewWindow([]));
        BindTab(Cmd.MoveToNewWindow, t =>
        {
            if (_tabs.FirstOrDefault(m => m.Tab == t) is { } model) TearOff(model, null);
        }, _ => _tabs.Count > 1);
    }

    /// <summary>A tab being moved is busy when a job holds its document, or it is being saved or closed.</summary>
    private bool IsTabBusy(TabModel model) => model.Tab.IsBusy || IsSaving(model.Tab) || _closingTabs.Contains(model.Tab);

    /// <summary>Brings this window forward with the tab <paramref name="id"/> selected (a file asked for that is open here).</summary>
    internal void ShowTab(long id)
    {
        if (ShowActivated) BringToFront(); // a dev script's windows stay unfocused
        if (_tabs.FirstOrDefault(m => m.Id == id) is not { } model) return;
        TabStrip.SelectedItem = model;
        model.Tab.ScheduleDiskCheck();
    }

    /// <summary>The tab menu's Move to Window: the other windows, each named by the document it shows.</summary>
    private MenuItem MoveToWindowMenu(TabModel model)
    {
        var menu = new MenuItem { Header = Strings.Main_TabMoveToWindow };
        foreach (var other in App.Current.MainsFrontFirst.Where(w => w != this))
        {
            var target = other;
            var item = new MenuItem { Header = target.Describe() };
            item.Click += (_, _) => MoveTabTo(model, target, target._tabs.Count);
            menu.Items.Add(item);
        }
        menu.IsEnabled = menu.Items.Count > 0;
        return menu;
    }

    /// <summary>This window in a menu: the document it shows, and how many more it has.</summary>
    private string Describe()
    {
        if (ActiveTabModel is not { } shown) return Strings.Main_EmptyWindow;
        return _tabs.Count > 1 ? Loc.Format(Strings.Main_WindowWithMore, shown.Label, _tabs.Count - 1) : shown.Label;
    }

    /// <summary>
    /// <paramref name="model"/>'s tab into a new window: let go at <paramref name="screenAt"/> (screen pixels; the window
    /// opens there, the size this one is), or from a menu (a little down and right of this one).
    /// </summary>
    private void TearOff(TabModel model, Point? screenAt)
    {
        switch (App.Hub.CanTearOff(model.Id, IsTabBusy(model)))
        {
            case TearOffCheck.Busy:
                ShowStatus(Loc.Format(Strings.Main_StillBusy, model.Title));
                return;
            case TearOffCheck.TearsOff:
                break;
            default:
                return;
        }
        Rect? bounds = null;
        if (screenAt is { } at && PresentationSource.FromVisual(this)?.CompositionTarget is { } target)
        {
            var p = target.TransformFromDevice.Transform(at);
            var size = WindowState == WindowState.Normal ? new Size(Width, Height) : RestoreBounds.Size;
            // The tab stays under the pointer, near the new window's top left as it was in this one's strip.
            bounds = new Rect(p.X - 80, p.Y - 16, size.Width, size.Height);
        }
        var window = App.Current.OpenNewWindow([], bounds);
        MoveTabTo(model, window, 0);
    }

    /// <summary>
    /// Moves <paramref name="model"/>'s tab, document and all (its panes, view, undo steps, unsaved changes), to
    /// <paramref name="target"/> at <paramref name="index"/>; this window closes when it was its last tab.
    /// </summary>
    private void MoveTabTo(TabModel model, MainWindow target, int index)
    {
        switch (App.Hub.CanMove(model.Id, target.WindowId, IsTabBusy(model)))
        {
            case TabMoveCheck.Busy:
                ShowStatus(Loc.Format(Strings.Main_StillBusy, model.Title));
                return;
            case TabMoveCheck.Moves:
                break;
            default:
                return;
        }
        var at = _tabs.IndexOf(model);
        var wasActive = ActiveTabModel == model;
        // The Reflow view's browser is made again in its new window (it doesn't survive being moved), at the same page.
        var reflowing = model.Tab.IsReflowing;
        if (reflowing) model.Tab.SetReflow(false);
        var moved = App.Hub.Move(model.Id, target.WindowId, index);
        Release(model, moving: true);
        // A toast about the document ("Delete 1 page · Undo") stays with this window: its Undo would act on another's tab.
        foreach (var card in Toasts.Children.OfType<FrameworkElement>().Where(c => c.Tag == model.Tab).ToList()) Toasts.Children.Remove(card);
        if (wasActive && _tabs.Count > 0) TabStrip.SelectedItem = _tabs[Math.Clamp(at, 0, _tabs.Count - 1)];
        RelabelTabs();
        UpdateUi();
        target.Attach(model, App.Hub.TabsOf(target.WindowId).ToList().IndexOf(model.Id));
        if (reflowing) model.Tab.SetReflow(true);
        target.RelabelTabs();
        target.UpdateUi();
        target._autosave.Copy(wait: false); // its recovery copy, now under the window that has it
        Log.Write($"Tab moved to window {target.WindowId} ({_tabs.Count} left here)");
        if (target.ShowActivated) target.BringToFront();
        if (moved.FromEmptied)
        {
            _closeApproved = true; // nothing left to ask about
            Close();
        }
    }

    // ── Dragging a tab ──

    private TabModel? _pressedTab;
    private Point _pressedAt; // screen pixels
    private bool _draggingTab;

    private double DeviceScale => VisualTreeHelper.GetDpi(this).DpiScaleX;

    private void WatchTabDrags()
    {
        TabStrip.PreviewMouseLeftButtonDown += (_, e) =>
        {
            _draggingTab = false;
            // A tab's close button closes; it doesn't drag.
            _pressedTab = IsInButton(e.OriginalSource) ? null : ItemUnder(e.OriginalSource);
            if (_pressedTab is not null) _pressedAt = PointToScreen(e.GetPosition(this));
        };
        TabStrip.PreviewMouseMove += (_, e) =>
        {
            if (_pressedTab is null) return;
            if (e.LeftButton != MouseButtonState.Pressed)
            {
                EndTabDrag();
                return;
            }
            var now = PointToScreen(e.GetPosition(this));
            if (!_draggingTab)
            {
                var scale = DeviceScale;
                if (!TabDrag.Started(new PointD(_pressedAt.X, _pressedAt.Y), new PointD(now.X, now.Y),
                        SystemParameters.MinimumHorizontalDragDistance * scale, SystemParameters.MinimumVerticalDragDistance * scale)) return;
                _draggingTab = true;
                TabStrip.CaptureMouse();
                TabStrip.Cursor = Cursors.SizeAll;
            }
            e.Handled = true; // the list doesn't select the tabs passed over
        };
        TabStrip.PreviewMouseLeftButtonUp += (_, e) =>
        {
            var model = _pressedTab;
            var dragged = _draggingTab;
            var at = PointToScreen(e.GetPosition(this));
            EndTabDrag();
            if (!dragged || model is null || !_tabs.Contains(model)) return;
            e.Handled = true;
            DropTab(model, at);
        };
        TabStrip.LostMouseCapture += (_, _) =>
        {
            if (_draggingTab && Mouse.LeftButton != MouseButtonState.Pressed) EndTabDrag();
        };
    }

    private void EndTabDrag()
    {
        _pressedTab = null;
        if (!_draggingTab) return;
        _draggingTab = false;
        TabStrip.Cursor = null;
        if (TabStrip.IsMouseCaptured) TabStrip.ReleaseMouseCapture();
    }

    private static bool IsInButton(object source)
    {
        for (var d = source as DependencyObject; d is not null and not ListBoxItem; d = d is Visual ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d is System.Windows.Controls.Primitives.ButtonBase) return true;
        return false;
    }

    /// <summary>A tab let go at <paramref name="at"/> (screen pixels): reordered, moved to the window whose strip is there, or torn off.</summary>
    private void DropTab(TabModel model, Point at)
    {
        var strips = App.Current.MainsFrontFirst.Select(w => w.StripArea()).OfType<TabStripArea>().ToList();
        var drop = TabDrag.Drop(WindowId, _tabs.Count, new PointD(at.X, at.Y), strips, DeviceScale);
        switch (drop.Kind)
        {
            case TabDropKind.Reorder:
                var from = _tabs.IndexOf(model);
                App.Hub.Move(model.Id, WindowId, drop.Index);
                var to = App.Hub.TabsOf(WindowId).ToList().IndexOf(model.Id);
                if (from >= 0 && to >= 0 && from != to) _tabs.Move(from, to);
                TabStrip.SelectedItem = model;
                break;
            case TabDropKind.MoveToWindow when App.Current.MainById(drop.Window) is { } target:
                MoveTabTo(model, target, drop.Index);
                break;
            case TabDropKind.TearOff:
                TearOff(model, at);
                break;
        }
    }

    /// <summary>This window's tab strip on the screen (the title bar's tab area), or null when it isn't showing (minimized, full screen).</summary>
    private TabStripArea? StripArea()
    {
        if (WindowState == WindowState.Minimized || !TabArea.IsVisible || TabArea.ActualWidth <= 0) return null;
        var topLeft = TabArea.PointToScreen(new Point(0, 0));
        var bottomRight = TabArea.PointToScreen(new Point(TabArea.ActualWidth, TabArea.ActualHeight));
        var middles = new List<double>();
        foreach (var m in _tabs)
            if (TabStrip.ItemContainerGenerator.ContainerFromItem(m) is FrameworkElement { IsVisible: true } item)
                middles.Add(item.PointToScreen(new Point(item.ActualWidth / 2, 0)).X);
        return new TabStripArea(WindowId, RectD.FromEdges(topLeft.X, topLeft.Y, bottomRight.X, bottomRight.Y), middles);
    }

    // ── Dev script ──

    /// <summary>DevScript's <c>tearoff</c>: the selected tab into a new window, as the tab menu's Move to New Window does.</summary>
    internal void DevTearOff()
    {
        if (ActiveTabModel is { } model) TearOff(model, null);
    }

    /// <summary>DevScript's <c>movetab</c>: the selected tab to <paramref name="target"/> at <paramref name="index"/> (-1: the end).</summary>
    internal void DevMoveTab(MainWindow target, int index)
    {
        if (ActiveTabModel is { } model) MoveTabTo(model, target, index < 0 ? target._tabs.Count : index);
    }

    /// <summary>DevScript's <c>droptab x y</c>: the selected tab let go at a screen point (in this window's DIPs from its top left).</summary>
    internal void DevDropTab(double x, double y)
    {
        if (ActiveTabModel is { } model) DropTab(model, PointToScreen(new Point(x, y)));
    }

    /// <summary>DevScript's <c>mainwindows</c>: each window, its tabs and the one in use.</summary>
    internal string DevWindowState() =>
        $"window {WindowId}{(App.Hub.Active == WindowId ? " (in use)" : "")}: {(_tabs.Count == 0 ? "start page" : string.Join(", ", _tabs.Select(t => t == ActiveTabModel ? $"[{t.Label}]" : t.Label)))}";
}
