using System.Windows;
using System.Windows.Controls;

namespace InkvoltPrint.App.Views;

/// <summary>
/// Lays cards out in rows of equal columns that share the whole width: as many columns as fit at
/// <see cref="MinItemWidth"/> (each child's margin included), at least one, each stretched to fill its share.
/// A row is as tall as its tallest card.
/// </summary>
public sealed class CardWrapPanel : Panel
{
    public static readonly DependencyProperty MinItemWidthProperty = DependencyProperty.Register(
        nameof(MinItemWidth), typeof(double), typeof(CardWrapPanel), new FrameworkPropertyMetadata(416.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double MinItemWidth
    {
        get => (double)GetValue(MinItemWidthProperty);
        set => SetValue(MinItemWidthProperty, value);
    }

    private double _slot;
    private int _columns;

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? MinItemWidth : availableSize.Width;
        var columns = _columns = Math.Max(1, (int)(width / MinItemWidth));
        _slot = width / columns;
        double height = 0, rowHeight = 0;
        var column = 0;
        foreach (UIElement child in InternalChildren)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            child.Measure(new Size(_slot, double.PositiveInfinity));
            rowHeight = Math.Max(rowHeight, child.DesiredSize.Height);
            if (++column == columns)
            {
                height += rowHeight;
                rowHeight = 0;
                column = 0;
            }
        }
        return new Size(width, height + rowHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var row = new List<UIElement>();
        double y = 0;
        foreach (UIElement child in InternalChildren)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            row.Add(child);
            if (row.Count == _columns) y += ArrangeRow(row, y);
        }
        ArrangeRow(row, y);
        return finalSize;
    }

    private double ArrangeRow(List<UIElement> row, double y)
    {
        var height = row.Count == 0 ? 0 : row.Max(c => c.DesiredSize.Height);
        for (var i = 0; i < row.Count; i++) row[i].Arrange(new Rect(i * _slot, y, _slot, row[i].DesiredSize.Height));
        row.Clear();
        return height;
    }
}
