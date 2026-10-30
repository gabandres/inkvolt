using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace InkvoltPrint.App;

/// <summary>
/// Placeholder text for a <see cref="TextBox"/> (WPF has none): shown in the secondary text color while the box is
/// empty, as Windows 11 text boxes do, so a box says what goes in it (recognition rather than recall). XAML:
/// <c>local:Placeholder.Text="Find in document"</c>; code: <c>Placeholder.SetText(box, "…")</c>. A box without an
/// accessible name gets the placeholder as its name.
/// </summary>
public static class Placeholder
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.RegisterAttached(
        "Text", typeof(string), typeof(Placeholder), new PropertyMetadata(null, OnTextChanged));

    public static string? GetText(DependencyObject d) => (string?)d.GetValue(TextProperty);
    public static void SetText(DependencyObject d, string? value) => d.SetValue(TextProperty, value);

    private static void OnTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not TextBox box) return;
        if (string.IsNullOrEmpty(AutomationProperties.GetName(box)) && e.NewValue is string name && name.Length > 0)
            AutomationProperties.SetName(box, name);
        if (box.IsLoaded) Attach(box);
        else box.Loaded += (_, _) => Attach(box);
    }

    private static void Attach(TextBox box)
    {
        if (AdornerLayer.GetAdornerLayer(box) is not { } layer) return;
        if (layer.GetAdorners(box)?.OfType<PlaceholderAdorner>().Any() == true) return;
        var adorner = new PlaceholderAdorner(box);
        layer.Add(adorner);
        box.TextChanged += (_, _) => adorner.InvalidateVisual();
        box.SizeChanged += (_, _) => adorner.InvalidateVisual();
        box.IsVisibleChanged += (_, _) => adorner.InvalidateVisual(); // adorners don't hide with their element by themselves
    }

    private sealed class PlaceholderAdorner : Adorner
    {
        private readonly TextBox _box;

        public PlaceholderAdorner(TextBox box) : base(box)
        {
            _box = box;
            IsHitTestVisible = false;
        }

        protected override void OnRender(DrawingContext dc)
        {
            if (!_box.IsVisible || _box.Text.Length > 0 || GetText(_box) is not { Length: > 0 } text) return;
            var brush = _box.TryFindResource("TextFillColorSecondaryBrush") as Brush ?? Brushes.Gray;
            var ft = new FormattedText(text, CultureInfo.CurrentCulture, _box.FlowDirection,
                new Typeface(_box.FontFamily, _box.FontStyle, _box.FontWeight, _box.FontStretch), _box.FontSize, brush,
                VisualTreeHelper.GetDpi(_box).PixelsPerDip)
            {
                MaxLineCount = 1,
                Trimming = TextTrimming.CharacterEllipsis,
            };
            // Where the text itself starts: the content host (its padding is the box's), plus the caret's own 2 px.
            var host = _box.Template?.FindName("PART_ContentHost", _box) as FrameworkElement;
            var origin = host is null ? new Point(_box.Padding.Left, _box.Padding.Top) : host.TranslatePoint(new Point(0, 0), _box);
            var padding = host is Control c ? c.Padding : default;
            var width = (host?.ActualWidth ?? _box.ActualWidth) - padding.Left - padding.Right - 4;
            if (width <= 0) return;
            ft.MaxTextWidth = width;
            var x = origin.X + padding.Left + 2;
            var innerHeight = (host?.ActualHeight ?? _box.ActualHeight) - padding.Top - padding.Bottom;
            var y = origin.Y + padding.Top + (_box.VerticalContentAlignment == VerticalAlignment.Center ? Math.Max(0, (innerHeight - ft.Height) / 2) : 0);
            if (_box.FlowDirection == FlowDirection.RightToLeft) x = _box.ActualWidth - x;
            dc.DrawText(ft, new Point(x, y));
        }
    }
}
