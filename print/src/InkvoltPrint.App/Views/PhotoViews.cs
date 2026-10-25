using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPrint.App.Printing;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Photos;

namespace InkvoltPrint.App.Views;

/// <summary>
/// A sheet of the photo preview, drawn by <see cref="PhotoDrawing"/> exactly as it prints (thumbnails instead of the full
/// pictures). Click a print to select its photo; drag it to move the crop. The printable area is outlined faintly.
/// </summary>
public sealed class PhotoSheetView : FrameworkElement
{
    public static readonly DependencyProperty PreviewProperty = DependencyProperty.Register(nameof(Preview), typeof(PhotoSheetPreview),
        typeof(PhotoSheetView), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty VersionProperty = DependencyProperty.Register(nameof(Version), typeof(int),
        typeof(PhotoSheetView), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));

    private static readonly Pen MarginPen = Frozen(new Pen(new SolidColorBrush(Color.FromArgb(0x50, 0x80, 0x80, 0x80)), 1) { DashStyle = DashStyles.Dash });

    private int _dragCell = -1;
    private Point _last;

    public PhotoSheetPreview? Preview
    {
        get => (PhotoSheetPreview?)GetValue(PreviewProperty);
        set => SetValue(PreviewProperty, value);
    }

    /// <summary>Bound to <see cref="PhotoSheetPreview.Version"/>: redraws when the layout changes.</summary>
    public int Version
    {
        get => (int)GetValue(VersionProperty);
        set => SetValue(VersionProperty, value);
    }

    private double Unit => Preview is { Paper.Width: > 0 } p ? ActualWidth / p.Paper.Width : 0;

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.White, null, new Rect(RenderSize));
        if (Preview is not { } p || Unit <= 0) return;
        var unit = Unit;
        var printable = p.Paper.Printable;
        if (printable.Width < p.Paper.Width || printable.Height < p.Paper.Height)
            dc.DrawRectangle(null, MarginPen, PhotoDrawing.Scale(printable, unit));
        dc.PushClip(new RectangleGeometry(new Rect(RenderSize)));
        PhotoDrawing.DrawSheet(dc, p.Sheet, p.Photos, i => i < p.Thumbnails.Count ? p.Thumbnails[i] : null, unit,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
        dc.Pop();
        var selected = p.Owner.Selected is { } s ? p.Owner.Photos.IndexOf(s) : -1;
        if (selected < 0) return;
        var accent = TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.DodgerBlue;
        var pen = new Pen(accent, 2);
        foreach (var cell in p.Sheet.Cells.Where(c => c.Photo == selected))
            dc.DrawRectangle(null, pen, PhotoDrawing.Scale(cell.Cell, unit));
    }

    private int CellAt(Point at)
    {
        if (Preview is not { } p || Unit <= 0) return -1;
        var (x, y) = (at.X / Unit, at.Y / Unit);
        for (var i = 0; i < p.Sheet.Cells.Count; i++)
        {
            var c = p.Sheet.Cells[i].Cell;
            if (x >= c.X && x <= c.X + c.Width && y >= c.Y && y <= c.Y + c.Height) return i;
        }
        return -1;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (Preview is not { } p || CellAt(e.GetPosition(this)) is not (>= 0 and var k)) return;
        p.Owner.Select(p.Sheet.Cells[k].Photo);
        _dragCell = k;
        _last = e.GetPosition(this);
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_dragCell < 0 || Preview is not { } p || _dragCell >= p.Sheet.Cells.Count || Unit <= 0) return;
        var now = e.GetPosition(this);
        p.Owner.Drag(p.Sheet.Cells[_dragCell], (now.X - _last.X) / Unit, (now.Y - _last.Y) / Unit);
        _last = now;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        _dragCell = -1;
        ReleaseMouseCapture();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        _dragCell = -1;
    }

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        Cursor = Preview?.Owner.IsContactSheet == true ? Cursors.Hand : Cursors.SizeAll;
    }

    internal static Pen Frozen(Pen pen)
    {
        pen.Freeze();
        return pen;
    }
}

/// <summary>
/// The selected photo's first print, enlarged: the part outside the print shows faded, so moving the crop is easy to judge.
/// Drag or use the arrow keys to move it (Shift: further), + and − or the mouse wheel to zoom, Home to reset.
/// </summary>
public sealed class PhotoCropView : FrameworkElement
{
    public static readonly DependencyProperty CellProperty = DependencyProperty.Register(nameof(Cell), typeof(PhotoCell), typeof(PhotoCropView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ItemProperty = DependencyProperty.Register(nameof(Item), typeof(PhotoItemViewModel), typeof(PhotoCropView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty OwnerProperty = DependencyProperty.Register(nameof(Owner), typeof(PhotosViewModel), typeof(PhotoCropView));

    public static readonly DependencyProperty GreyProperty = DependencyProperty.Register(nameof(Grey), typeof(bool), typeof(PhotoCropView),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    private const double Pad = 18;
    private Point? _last;

    public PhotoCropView()
    {
        Focusable = true;
        FocusVisualStyle = null; // drawn in OnRender, around the print
        Cursor = Cursors.SizeAll;
    }

    public PhotoCell? Cell
    {
        get => (PhotoCell?)GetValue(CellProperty);
        set => SetValue(CellProperty, value);
    }

    public PhotoItemViewModel? Item
    {
        get => (PhotoItemViewModel?)GetValue(ItemProperty);
        set => SetValue(ItemProperty, value);
    }

    public PhotosViewModel? Owner
    {
        get => (PhotosViewModel?)GetValue(OwnerProperty);
        set => SetValue(OwnerProperty, value);
    }

    /// <summary>Shown in shades of grey, as a black-only printer prints it.</summary>
    public bool Grey
    {
        get => (bool)GetValue(GreyProperty);
        set => SetValue(GreyProperty, value);
    }

    /// <summary>Screen DIPs per inch of paper, and where the print's top-left corner is drawn.</summary>
    private (double Scale, Point Origin) Frame(PhotoCell cell)
    {
        var scale = Math.Min((ActualWidth - 2 * Pad) / cell.Cell.Width, (ActualHeight - 2 * Pad) / cell.Cell.Height);
        if (scale <= 0 || double.IsNaN(scale) || double.IsInfinity(scale)) scale = 0;
        return (scale, new Point((ActualWidth - cell.Cell.Width * scale) / 2, (ActualHeight - cell.Cell.Height * scale) / 2));
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // hit-testable everywhere
        if (Cell is not { } cell || Item is not { } item) return;
        var (scale, origin) = Frame(cell);
        if (scale <= 0) return;
        Rect At(InkvoltPrint.Core.Printing.Placement p) =>
            new(origin.X + (p.X - cell.Cell.X) * scale, origin.Y + (p.Y - cell.Cell.Y) * scale, p.Width * scale, p.Height * scale);
        var print = At(cell.Cell);
        var image = At(cell.Image);
        var turns = item.Turns + (cell.Turned ? 1 : 0);
        var picture = Grey ? item.GreyThumbnail : item.Thumbnail;
        dc.PushClip(new RectangleGeometry(new Rect(RenderSize)));
        dc.PushOpacity(0.3);
        PhotoDrawing.DrawPhoto(dc, picture, image, turns, item.Mirror);
        dc.Pop();
        dc.Pop();
        dc.DrawRectangle(Brushes.White, null, print);
        dc.PushClip(new RectangleGeometry(print));
        PhotoDrawing.DrawPhoto(dc, picture, image, turns, item.Mirror);
        dc.Pop();
        var accent = TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.DodgerBlue;
        dc.DrawRectangle(null, new Pen(accent, IsKeyboardFocused ? 3 : 1.5), print);
    }

    protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e)
    {
        base.OnGotKeyboardFocus(e);
        InvalidateVisual();
    }

    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e)
    {
        base.OnLostKeyboardFocus(e);
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        if (Cell is null) return;
        _last = e.GetPosition(this);
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_last is not { } last || Cell is not { } cell || Owner is not { } owner) return;
        var (scale, _) = Frame(cell);
        if (scale <= 0) return;
        var now = e.GetPosition(this);
        owner.Drag(cell, (now.X - last.X) / scale, (now.Y - last.Y) / scale);
        _last = now;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        _last = null;
        ReleaseMouseCapture();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        _last = null;
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        if (Item is not { } item) return;
        item.ZoomPercent += e.Delta > 0 ? 10 : -10;
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (Owner is not { } owner || Item is not { } item) return;
        var large = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        switch (e.Key)
        {
            case Key.Left: owner.Nudge(-1, 0, large); break;
            case Key.Right: owner.Nudge(1, 0, large); break;
            case Key.Up: owner.Nudge(0, -1, large); break;
            case Key.Down: owner.Nudge(0, 1, large); break;
            case Key.OemPlus or Key.Add: item.ZoomPercent += 10; break;
            case Key.OemMinus or Key.Subtract: item.ZoomPercent -= 10; break;
            case Key.Home: item.SetCrop(PhotoCrop.None); break;
            default: return;
        }
        e.Handled = true;
    }
}
