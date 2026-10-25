using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.App.Views;

/// <summary>
/// A page, large, with a crop box over it: drag on the page to draw a new box, drag inside the box to move it, drag a
/// corner to resize it. Keyboard: arrows move the box, Shift+arrows move its bottom-right corner. Outside the box is
/// dimmed. <see cref="Box"/> is in fractions of the page.
/// </summary>
public sealed class CropView : FrameworkElement
{
    private const double Handle = 9;
    private const double KeyStep = 0.01;

    private static readonly Brush Dim = Frozen(new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)));
    private static readonly Pen Outline = Frozen(new Pen(Brushes.White, 2));
    private static readonly Pen Shadow = Frozen(new Pen(new SolidColorBrush(Color.FromArgb(0x80, 0, 0, 0)), 4));

    private enum Drag { None, Draw, Move, Corner }

    private Drag _drag;
    private Point _anchor;      // Draw: where it started; Corner: the opposite corner (both in page fractions)
    private CropBox _startBox;  // Move: the box when the drag started
    private Point _start;

    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(nameof(Source), typeof(ImageSource), typeof(CropView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty BoxProperty = DependencyProperty.Register(nameof(Box), typeof(CropBox), typeof(CropView),
        new FrameworkPropertyMetadata(CropBox.Full, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));

    public CropView()
    {
        Focusable = true;
        FocusVisualStyle = null; // the box outline turns accent-coloured instead
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        Cursor = Cursors.Cross;
    }

    public ImageSource? Source
    {
        get => (ImageSource?)GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public CropBox Box
    {
        get => (CropBox)GetValue(BoxProperty);
        set => SetValue(BoxProperty, value);
    }

    /// <summary>Where the page is drawn: fitted and centred, as an Image with Stretch=Uniform would.</summary>
    private Rect PageRect()
    {
        if (Source is not { Width: > 0, Height: > 0 } src || ActualWidth <= 0 || ActualHeight <= 0) return Rect.Empty;
        var scale = Math.Min(ActualWidth / src.Width, ActualHeight / src.Height);
        var (w, h) = (src.Width * scale, src.Height * scale);
        return new Rect((ActualWidth - w) / 2, (ActualHeight - h) / 2, w, h);
    }

    private static Rect BoxRect(Rect page, CropBox box) =>
        new(page.X + box.X * page.Width, page.Y + box.Y * page.Height, box.Width * page.Width, box.Height * page.Height);

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // hit-testable everywhere
        var page = PageRect();
        if (page.IsEmpty) return;
        dc.DrawImage(Source, page);
        var box = BoxRect(page, Box);
        dc.DrawGeometry(Dim, null, new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(page), new RectangleGeometry(box)));
        dc.DrawRectangle(null, Shadow, box);
        var outline = IsKeyboardFocused && TryFindResource("AccentFillColorDefaultBrush") is Brush accent ? new Pen(accent, 3) : Outline;
        dc.DrawRectangle(null, outline, box);
        foreach (var corner in Corners(box))
            dc.DrawRectangle(Brushes.White, Shadow, new Rect(corner.X - Handle / 2, corner.Y - Handle / 2, Handle, Handle));
    }

    private static Point[] Corners(Rect r) => [r.TopLeft, r.TopRight, r.BottomRight, r.BottomLeft];

    private Point ToPage(Point p, Rect page) =>
        new(Math.Clamp((p.X - page.X) / page.Width, 0, 1), Math.Clamp((p.Y - page.Y) / page.Height, 0, 1));

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        var page = PageRect();
        if (page.IsEmpty) return;
        var at = e.GetPosition(this);
        var box = BoxRect(page, Box);
        var corners = Corners(box);
        var hit = Array.FindIndex(corners, c => (c - at).Length <= Handle);
        if (hit >= 0)
        {
            _drag = Drag.Corner;
            _anchor = ToPage(corners[(hit + 2) % 4], page);
        }
        else if (box.Contains(at) && !Box.IsFull)
        {
            _drag = Drag.Move;
            _startBox = Box;
            _start = ToPage(at, page);
        }
        else
        {
            _drag = Drag.Draw;
            _anchor = ToPage(at, page);
        }
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var page = PageRect();
        if (page.IsEmpty) return;
        var at = e.GetPosition(this);
        if (_drag == Drag.None)
        {
            var box = BoxRect(page, Box);
            Cursor = Corners(box).Any(c => (c - at).Length <= Handle) ? Cursors.SizeNWSE : box.Contains(at) && !Box.IsFull ? Cursors.SizeAll : Cursors.Cross;
            return;
        }
        var p = ToPage(at, page);
        if (_drag == Drag.Move)
        {
            var b = _startBox;
            Box = (b with { X = b.X + p.X - _start.X, Y = b.Y + p.Y - _start.Y }).Clamp();
        }
        else
        {
            Box = new CropBox(Math.Min(_anchor.X, p.X), Math.Min(_anchor.Y, p.Y), Math.Abs(p.X - _anchor.X), Math.Abs(p.Y - _anchor.Y)).Clamp();
        }
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (_drag == Drag.None) return;
        _drag = Drag.None;
        ReleaseMouseCapture();
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        var (dx, dy) = e.Key switch
        {
            Key.Left => (-KeyStep, 0.0),
            Key.Right => (KeyStep, 0.0),
            Key.Up => (0.0, -KeyStep),
            Key.Down => (0.0, KeyStep),
            _ => (0.0, 0.0),
        };
        if (dx == 0 && dy == 0) return;
        var b = Box;
        Box = (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)
            ? b with { Width = Math.Min(1 - b.X, b.Width + dx), Height = Math.Min(1 - b.Y, b.Height + dy) }
            : b with { X = b.X + dx, Y = b.Y + dy }).Clamp();
        e.Handled = true;
    }

    protected override void OnIsKeyboardFocusedChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnIsKeyboardFocusedChanged(e);
        InvalidateVisual();
    }

    private static T Frozen<T>(T freezable) where T : Freezable
    {
        freezable.Freeze();
        return freezable;
    }
}
