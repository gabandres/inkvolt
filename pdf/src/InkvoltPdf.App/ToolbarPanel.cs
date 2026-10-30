using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// A command bar that always stays one row: children are laid out left to right, and those that don't fit are hidden
/// and listed in <see cref="OverflowItems"/> for the overflow ("More") button, the child marked
/// <see cref="IsOverflowButtonProperty"/>, which shows when something overflowed (or always, with
/// <see cref="MoreAlways"/>). Which children go is <see cref="CommandBarLayout.Layout"/>'s: the lowest
/// <see cref="PriorityProperty"/> first (on a tie, the later one); labels go only when keeping them would push out a
/// child of priority <see cref="KeepsLabels"/> or more. Separators (any non-button child) show only between two shown
/// commands.
/// </summary>
public sealed class ToolbarPanel : Panel
{
    public static readonly DependencyProperty IsOverflowButtonProperty = DependencyProperty.RegisterAttached(
        "IsOverflowButton", typeof(bool), typeof(ToolbarPanel), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsParentMeasure));

    public static bool GetIsOverflowButton(DependencyObject d) => (bool)d.GetValue(IsOverflowButtonProperty);
    public static void SetIsOverflowButton(DependencyObject d, bool value) => d.SetValue(IsOverflowButtonProperty, value);

    /// <summary>A button's text label (next to its icon): dropped, on every button at once, when the bar goes icons-only.</summary>
    public static readonly DependencyProperty IsLabelProperty = DependencyProperty.RegisterAttached(
        "IsLabel", typeof(bool), typeof(ToolbarPanel), new PropertyMetadata(false));

    public static bool GetIsLabel(DependencyObject d) => (bool)d.GetValue(IsLabelProperty);
    public static void SetIsLabel(DependencyObject d, bool value) => d.SetValue(IsLabelProperty, value);

    /// <summary>How long a child stays on the bar as room runs short (higher stays longer).</summary>
    public static readonly DependencyProperty PriorityProperty = DependencyProperty.RegisterAttached(
        "Priority", typeof(int), typeof(ToolbarPanel), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsParentMeasure));

    public static int GetPriority(DependencyObject d) => (int)d.GetValue(PriorityProperty);
    public static void SetPriority(DependencyObject d, int value) => d.SetValue(PriorityProperty, value);

    /// <summary>The overflow button shows even when everything fits (its menu has commands of its own).</summary>
    public bool MoreAlways { get; set; }

    /// <summary>The priority from which a child keeps the labels: the bar goes icons-only before such a child overflows.</summary>
    public int KeepsLabels { get; set; } = int.MinValue;

    private readonly HashSet<UIElement> _shown = [];
    private readonly List<UIElement> _overflow = [];
    // Each item's width with and without its labels, remembered from when it was last measured that way.
    private readonly Dictionary<UIElement, (double Full, double Compact)> _widths = [];
    private bool _compact;

    /// <summary>The children hidden for lack of room, in bar order.</summary>
    public IReadOnlyList<UIElement> OverflowItems => _overflow;

    /// <summary>True while the bar shows icons only.</summary>
    public bool IsCompact => _compact;

    protected override Size MeasureOverride(Size availableSize)
    {
        UIElement? more = null;
        var items = new List<UIElement>();
        var height = 0.0;
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(double.PositiveInfinity, availableSize.Height));
            height = Math.Max(height, child.DesiredSize.Height);
            if (GetIsOverflowButton(child)) more = child;
            else if (child.Visibility != Visibility.Collapsed) items.Add(child);
        }

        foreach (var item in items)
        {
            var w = item.DesiredSize.Width;
            _widths[item] = _compact
                ? (_widths.TryGetValue(item, out var known) ? Math.Max(known.Full, w) : w, w)
                : (w, w - LabelWidth(item));
        }
        var fit = CommandBarLayout.Layout(
            [.. items.Select(c => new CommandBarLayout.Item(_widths[c].Full, _widths[c].Compact, GetPriority(c), c is not System.Windows.Controls.Primitives.ButtonBase))],
            availableSize.Width, more?.DesiredSize.Width ?? 0, MoreAlways, KeepsLabels);
        if (fit.Compact != _compact)
        {
            _compact = fit.Compact;
            foreach (var item in items) SetLabelsVisible(item, !_compact);
            foreach (var item in items) item.Measure(new Size(double.PositiveInfinity, availableSize.Height));
        }

        _shown.Clear();
        _overflow.Clear();
        for (var i = 0; i < items.Count; i++)
            if (fit.Shown[i]) _shown.Add(items[i]);
            else if (items[i] is System.Windows.Controls.Primitives.ButtonBase) _overflow.Add(items[i]);
            else if (_overflow.Count > 0 && _overflow[^1] is System.Windows.Controls.Primitives.ButtonBase) _overflow.Add(items[i]); // a group break in the menu
        _moreShown = fit.MoreShown;

        var width = _shown.Sum(c => c.DesiredSize.Width) + (_moreShown ? more?.DesiredSize.Width ?? 0 : 0);
        return new Size(double.IsInfinity(availableSize.Width) ? width : Math.Min(width, availableSize.Width), height);
    }

    private bool _moreShown;

    /// <summary>The width the item's labels take (with their margins); 0 when it has none or they are hidden.</summary>
    private static double LabelWidth(DependencyObject root)
    {
        var sum = 0.0;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            sum += child is UIElement label && GetIsLabel(label) ? label.DesiredSize.Width : LabelWidth(child);
        return sum;
    }

    private static void SetLabelsVisible(DependencyObject root, bool visible)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is UIElement label && GetIsLabel(label)) label.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            else SetLabelsVisible(child, visible);
        }
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var x = 0.0;
        foreach (UIElement child in InternalChildren)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            var show = GetIsOverflowButton(child) ? _moreShown : _shown.Contains(child);
            // Hidden, not just squeezed: out of Tab order, hit testing and screen readers' view (the More menu has them).
            var visibility = show ? Visibility.Visible : Visibility.Hidden;
            if (child.Visibility != visibility) child.Visibility = visibility;
            if (!show)
            {
                child.Arrange(new Rect(0, 0, 0, 0));
                continue;
            }
            var size = child.DesiredSize;
            child.Arrange(new Rect(x, (finalSize.Height - size.Height) / 2, size.Width, size.Height));
            x += size.Width;
        }
        return finalSize;
    }
}
