using System.Globalization;
using System.Windows;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App.Viewer;

/// <summary>A numbered box of the reading order panel: where a piece is, its place in its page's order, and how it shows.</summary>
public readonly record struct ReadingOrderBox(int Page, RectD Box, int Number, bool Selected, bool NeedsAlt);

/// <summary>
/// The reading order overlay (Review › Reading Order and Alt Text): each piece Make Accessible tags is outlined on its
/// page with its number in the page's reading order; the selected one is drawn stronger, a picture still without
/// alternate text in the warning color.
/// </summary>
public sealed partial class PageViewer
{
    private Dictionary<int, List<ReadingOrderBox>> _orderBoxes = [];

    private static readonly Pen OrderPen = Frozen(new Pen(Frozen(new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0))), 1.2));
    private static readonly Pen OrderSelectedPen = Frozen(new Pen(Frozen(new SolidColorBrush(Color.FromRgb(0xE0, 0x60, 0x00))), 2.5));
    private static readonly Pen OrderWarnPen = Frozen(new Pen(Frozen(new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C))), 1.5) { DashStyle = DashStyles.Dash });
    private static readonly Brush OrderBadge = Frozen(new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0)));
    private static readonly Brush OrderSelectedBadge = Frozen(new SolidColorBrush(Color.FromRgb(0xE0, 0x60, 0x00)));
    private static readonly Brush OrderWarnBadge = Frozen(new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)));
    private static readonly Brush OrderSelectedFill = Frozen(new SolidColorBrush(Color.FromArgb(0x18, 0xE0, 0x60, 0x00)));

    /// <summary>Shows the reading order's numbered boxes (empty: none).</summary>
    public void SetReadingOrder(IEnumerable<ReadingOrderBox> boxes)
    {
        _orderBoxes = boxes.GroupBy(b => b.Page).ToDictionary(g => g.Key, g => g.ToList());
        _surface.InvalidateVisual();
    }

    public void ClearReadingOrder()
    {
        if (_orderBoxes.Count == 0) return;
        _orderBoxes = [];
        _surface.InvalidateVisual();
    }

    private void PaintReadingOrder(DrawingContext dc, int page)
    {
        if (!_orderBoxes.TryGetValue(page, out var boxes)) return;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var b in boxes)
        {
            var r = ToSurfaceRect(page, b.Box.Inflate(2));
            if (_highContrast)
                dc.DrawRectangle(b.Selected ? _palette.Hit : null, b.Selected ? _palette.FocusPen : _palette.HoverPen, r);
            else
                dc.DrawRectangle(b.Selected ? OrderSelectedFill : null, b.Selected ? OrderSelectedPen : b.NeedsAlt ? OrderWarnPen : OrderPen, r);
            var label = new FormattedText(b.Number.ToString(CultureInfo.CurrentCulture), CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI Semibold"), 11, Brushes.White, dpi);
            var w = Math.Max(16, label.Width + 8);
            var badge = new Rect(r.Left - 1, Math.Max(0, r.Top - 16), w, 16);
            dc.DrawRoundedRectangle(_highContrast ? SystemColors.HighlightBrush : b.Selected ? OrderSelectedBadge : b.NeedsAlt ? OrderWarnBadge : OrderBadge, null, badge, 3, 3);
            if (_highContrast) label.SetForegroundBrush(SystemColors.HighlightTextBrush);
            dc.DrawText(label, new Point(badge.Left + (w - label.Width) / 2, badge.Top + (16 - label.Height) / 2));
        }
    }
}
