using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>
/// The Scan tab's page review: large thumbnails to turn, crop, delete and reorder. Reordering by dragging (pages make
/// room as the dragged one passes over them) or from the keyboard (Alt+Shift+arrows move the selected page; the new
/// position is announced to screen readers).
/// </summary>
public partial class ScanPages : UserControl
{
    private Point? _dragStart;
    private ScanPageViewModel? _dragPage;

    public static readonly DependencyProperty ThumbnailHeightProperty =
        DependencyProperty.Register(nameof(ThumbnailHeight), typeof(double), typeof(ScanPages), new PropertyMetadata(MaxThumbnail));

    private const double MaxThumbnail = 285, MinThumbnail = 150, BelowThumbnail = 98; // the page's buttons, its padding, the list's

    /// <summary>A page's thumbnail height: as tall as the list has room for (a whole page in view in a short window), up to 285.</summary>
    public double ThumbnailHeight
    {
        get => (double)GetValue(ThumbnailHeightProperty);
        set => SetValue(ThumbnailHeightProperty, value);
    }

    public ScanPages()
    {
        InitializeComponent();
        PagesList.SizeChanged += (_, e) =>
        {
            if (e.HeightChanged && e.NewSize.Height > 0) ThumbnailHeight = Math.Clamp(Math.Floor(e.NewSize.Height - BelowThumbnail), MinThumbnail, MaxThumbnail);
        };
        // The crop view takes the keyboard when it opens, so arrows move the box straight away.
        Cropper.IsVisibleChanged += (_, e) =>
        {
            if (e.NewValue is true) Dispatcher.BeginInvoke(DispatcherPriority.Input, () => Cropper.Focus());
        };
        // The clean up view takes the keyboard on its first choice, so Tab and Space work straight away.
        FirstCleanChoice.IsVisibleChanged += (_, e) =>
        {
            if (e.NewValue is true) Dispatcher.BeginInvoke(DispatcherPriority.Input, () => FirstCleanChoice.Focus());
        };
        PhotoBoxes.IsVisibleChanged += (_, e) =>
        {
            if (e.NewValue is true) Dispatcher.BeginInvoke(DispatcherPriority.Input, () => PhotoBoxes.Focus());
        };
    }

    private ScanViewModel? Vm => DataContext as ScanViewModel;

    private ScanPageViewModel? PageAt(object source) =>
        source is DependencyObject d && ItemsControl.ContainerFromElement(PagesList, d) is ListBoxItem { DataContext: ScanPageViewModel page } ? page : null;

    private static bool InButton(object source)
    {
        for (var d = source as DependencyObject; d is not null and not ListBoxItem; d = VisualTreeHelper.GetParent(d))
            if (d is ButtonBase) return true;
        return false;
    }

    private void Pages_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragPage = InButton(e.OriginalSource) ? null : PageAt(e.OriginalSource);
        _dragStart = _dragPage is null ? null : e.GetPosition(PagesList);
    }

    private void Pages_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _dragPage is not { } page || _dragStart is not { } start) return;
        var moved = e.GetPosition(PagesList) - start;
        if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragPage = null;
        _dragStart = null;
        var from = Vm?.Pages.IndexOf(page) ?? -1;
        DragDrop.DoDragDrop(PagesList, new DataObject(typeof(ScanPageViewModel), page), DragDropEffects.Move);
        if (Vm is { } vm && vm.Pages.IndexOf(page) is var to and >= 0 && to != from)
        {
            Announce($"Moved to position {to + 1} of {vm.Pages.Count}");
            Select(page);
        }
    }

    /// <summary>While dragging, the page takes the place of the one under the pointer, so the others show where it will land.</summary>
    private void Pages_DragOver(object sender, DragEventArgs e)
    {
        e.Handled = true; // not a PDF dropped on the window
        if (e.Data.GetData(typeof(ScanPageViewModel)) is not ScanPageViewModel page || Vm is not { } vm)
        {
            e.Effects = DragDropEffects.None;
            return;
        }
        e.Effects = DragDropEffects.Move;
        if (PageAt(e.OriginalSource) is { } over && over != page) vm.MovePage(page, vm.Pages.IndexOf(over));
    }

    private void Pages_Drop(object sender, DragEventArgs e) => e.Handled = true;

    private void Pages_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Vm is not { } vm || (PageAt(e.OriginalSource) ?? PagesList.SelectedItem as ScanPageViewModel) is not { } page) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key; // Alt turns arrows into system keys
        if (Keyboard.Modifiers == (ModifierKeys.Alt | ModifierKeys.Shift) && key is Key.Left or Key.Up or Key.Right or Key.Down)
        {
            var index = vm.Pages.IndexOf(page) + (key is Key.Left or Key.Up ? -1 : 1);
            Announce(vm.MovePage(page, index) ?? (index < 0 ? "Already the first page" : "Already the last page"));
            Select(page);
            e.Handled = true;
        }
        else if (key == Key.S && Keyboard.Modifiers == ModifierKeys.None && !page.IsSeparator)
        {
            vm.ToggleFileStartCommand.Execute(page); // announces where the file now starts
            e.Handled = true;
        }
        else if (key is Key.R or Key.L && Keyboard.Modifiers == ModifierKeys.Control)
        {
            (key == Key.R ? vm.RotateRightCommand : vm.RotateLeftCommand).Execute(page);
            Announce(key == Key.R ? $"Page {page.Number} turned right" : $"Page {page.Number} turned left");
            e.Handled = true;
        }
        else if (key == Key.Delete && Keyboard.Modifiers == ModifierKeys.None)
        {
            var index = vm.Pages.IndexOf(page);
            vm.RemovePageCommand.Execute(page);
            if (vm.Pages.Count > 0) Select(vm.Pages[Math.Min(index, vm.Pages.Count - 1)]);
            Announce(vm.Pages.Count == 0 ? "Page deleted. No pages left. Ctrl+Z puts it back" : "Page deleted. Ctrl+Z puts it back");
            e.Handled = true;
        }
    }

    /// <summary>Selects and focuses a page once its container exists again (a move re-creates it).</summary>
    private void Select(ScanPageViewModel page)
    {
        PagesList.SelectedItem = page;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (PagesList.ItemContainerGenerator.ContainerFromItem(page) is ListBoxItem item) item.Focus();
        });
    }

    private void Announce(string text) =>
        (UIElementAutomationPeer.FromElement(PagesList) ?? UIElementAutomationPeer.CreatePeerForElement(PagesList))?
            .RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, text, "InkvoltPrint.ScanPages");
}
