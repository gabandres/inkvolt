using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Media;
using InkvoltPrint.Core.History;

namespace InkvoltPrint.App.Views;

/// <summary>
/// The supplies card's level chart (roadmap 1.1): each supply's stored levels over the last year as a line in its own color,
/// broken where the printer gave no level and at a change of cartridge, which gets a dot where the new one starts. Draws
/// <see cref="SupplyChartData"/> as it is: no smoothing, nothing between the stored points.
/// </summary>
public sealed class SupplyChartView : FrameworkElement
{
    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(nameof(Data), typeof(SupplyChartData),
        typeof(SupplyChartView), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender, (d, _) => ((SupplyChartView)d).Describe()));

    public SupplyChartData? Data
    {
        get => (SupplyChartData?)GetValue(DataProperty);
        set => SetValue(DataProperty, value);
    }

    private const double Left = 34, Bottom = 18, Top = 4, Right = 6;

    private static readonly Color C = Color.FromRgb(0x00, 0xA3, 0xE0), M = Color.FromRgb(0xD0, 0x1C, 0x8B), Y = Color.FromRgb(0xE0, 0xB0, 0x00);

    private Brush Text => TryFindResource("TextFillColorSecondaryBrush") as Brush ?? SystemColors.GrayTextBrush;
    private Brush Ink => TryFindResource("TextFillColorPrimaryBrush") as Brush ?? SystemColors.WindowTextBrush;

    private Brush BrushFor(string? color)
    {
        if (SystemParameters.HighContrast) return SystemColors.WindowTextBrush;
        Color? c = color switch
        {
            "C" => C,
            "M" => M,
            "Y" => Y,
            { Length: 7 } hex when hex[0] == '#' && ColorConverter.ConvertFromString(hex) is Color parsed => parsed,
            _ => null, // black, or no color: the text color reads on light and dark
        };
        if (c is null) return Ink;
        var b = new SolidColorBrush(c.Value);
        b.Freeze();
        return b;
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (Data is not { } data) return;
        var plot = new Rect(Left, Top, Math.Max(0, ActualWidth - Left - Right), Math.Max(0, ActualHeight - Top - Bottom));
        if (plot.Width < 10 || plot.Height < 10) return;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var grid = new Pen(Text, 0.5) { DashStyle = DashStyles.Dot };
        grid.Freeze();

        foreach (var percent in new[] { 0, 50, 100 })
        {
            var y = plot.Bottom - plot.Height * percent / 100;
            dc.DrawLine(grid, new Point(plot.Left, y), new Point(plot.Right, y));
            var label = Label($"{percent}%", dpi);
            dc.DrawText(label, new Point(plot.Left - 6 - label.Width, y - label.Height / 2));
        }
        var from = Label(data.From.ToString("MMM yyyy", CultureInfo.CurrentCulture), dpi);
        dc.DrawText(from, new Point(plot.Left, plot.Bottom + 3));
        var to = Label(data.To.ToString("d MMM", CultureInfo.CurrentCulture), dpi);
        dc.DrawText(to, new Point(plot.Right - to.Width, plot.Bottom + 3));

        var days = Math.Max(1, data.To.DayNumber - data.From.DayNumber);
        Point At(ChartPoint p) => new(plot.Left + plot.Width * (p.Day.DayNumber - data.From.DayNumber) / days, plot.Bottom - plot.Height * p.Percent / 100.0);

        foreach (var line in data.Lines)
        {
            var brush = BrushFor(line.Color);
            var pen = new Pen(brush, 1.5) { LineJoin = PenLineJoin.Round };
            pen.Freeze();
            foreach (var segment in line.Segments)
            {
                if (segment.Count == 1)
                {
                    dc.DrawEllipse(brush, null, At(segment[0]), 1.5, 1.5);
                    continue;
                }
                var geometry = new StreamGeometry();
                using (var g = geometry.Open())
                {
                    g.BeginFigure(At(segment[0]), false, false);
                    g.PolyLineTo(segment.Skip(1).Select(At).ToList(), true, true);
                }
                geometry.Freeze();
                dc.DrawGeometry(null, pen, geometry);
            }
            foreach (var change in line.Changes)
                if (line.Segments.SelectMany(s => s).FirstOrDefault(p => p.Day >= change) is { } start)
                    dc.DrawEllipse(brush, null, At(start), 3, 3);
        }
    }

    private FormattedText Label(string text, double dpi) =>
        new(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, Text, dpi);

    /// <summary>What a screen reader says for the chart: each supply's first and last level shown, and its changes of cartridge.</summary>
    private void Describe()
    {
        if (Data is not { } data)
        {
            ClearValue(AutomationProperties.NameProperty); // null isn't a valid name
            return;
        }
        var parts = data.Lines.Select(l =>
        {
            var points = l.Segments.SelectMany(s => s).ToList();
            var changes = l.Changes.Count switch
            {
                0 => "",
                1 => $", changed on {l.Changes[0].ToString("d MMM yyyy", CultureInfo.CurrentCulture)}",
                var n => $", changed {n} times",
            };
            return $"{l.Supply} from {points[0].Percent}% to {points[^1].Percent}%{changes}";
        });
        AutomationProperties.SetName(this, $"Levels since {data.From.ToString("d MMM yyyy", CultureInfo.CurrentCulture)}: {string.Join("; ", parts)}");
    }
}
