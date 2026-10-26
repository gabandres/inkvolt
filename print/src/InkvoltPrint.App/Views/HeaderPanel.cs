using System.Windows;
using System.Windows.Controls;

namespace InkvoltPrint.App.Views;

/// <summary>
/// A header of two parts: a title (the first child) on the left and its buttons (the second) on the right, on one row while
/// the title fits beside them unwrapped; narrower, the title takes the whole width and the buttons go on a row of their own
/// under it (aligned by their own <see cref="FrameworkElement.HorizontalAlignment"/>), so neither is squeezed into a sliver.
/// </summary>
public sealed class HeaderPanel : Panel
{
    /// <summary>Space between the title and the buttons, across or down.</summary>
    public double Gap { get; set; } = 12;

    private bool _stacked;
    private double _gap;

    private (UIElement? Title, UIElement? Actions) Parts() =>
        (InternalChildren.Count > 0 ? InternalChildren[0] : null, InternalChildren.Count > 1 ? InternalChildren[1] : null);

    protected override Size MeasureOverride(Size availableSize)
    {
        var (title, actions) = Parts();
        var infinite = new Size(double.PositiveInfinity, double.PositiveInfinity);
        actions?.Measure(infinite);
        title?.Measure(infinite);
        var actionsSize = actions?.DesiredSize ?? default;
        var gap = _gap = actionsSize.Width > 0 && title?.DesiredSize.Width > 0 ? Gap : 0;
        var width = availableSize.Width;
        _stacked = !double.IsInfinity(width) && (title?.DesiredSize.Width ?? 0) + gap + actionsSize.Width > width;
        if (!_stacked)
        {
            title?.Measure(new Size(double.IsInfinity(width) ? width : Math.Max(0, width - gap - actionsSize.Width), availableSize.Height));
            var titleSize = title?.DesiredSize ?? default;
            return new Size(titleSize.Width + gap + actionsSize.Width, Math.Max(titleSize.Height, actionsSize.Height));
        }
        title?.Measure(new Size(width, double.PositiveInfinity));
        actions?.Measure(new Size(width, double.PositiveInfinity));
        var top = title?.DesiredSize.Height ?? 0;
        var below = actions?.DesiredSize.Height ?? 0;
        return new Size(width, top + (top > 0 && below > 0 ? Gap : 0) + below);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var (title, actions) = Parts();
        var actionsSize = actions?.DesiredSize ?? default;
        if (!_stacked)
        {
            title?.Arrange(new Rect(0, 0, Math.Max(0, finalSize.Width - _gap - actionsSize.Width), finalSize.Height));
            actions?.Arrange(new Rect(Math.Max(0, finalSize.Width - actionsSize.Width), 0, actionsSize.Width, finalSize.Height));
            return finalSize;
        }
        var top = title?.DesiredSize.Height ?? 0;
        title?.Arrange(new Rect(0, 0, finalSize.Width, top));
        var y = top + (top > 0 && actionsSize.Height > 0 ? Gap : 0);
        actions?.Arrange(new Rect(0, y, finalSize.Width, actionsSize.Height));
        return finalSize;
    }
}
