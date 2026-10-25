using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.App.Views;

/// <summary>
/// A scan of the glass, large, with a box over each photo found on it. Click a box to select it (or Tab through them); drag
/// inside it to move it, a corner to resize it, the round handle on its top edge to turn it (the handle marks the photo's top);
/// drag on the glass outside the boxes to mark a photo that wasn't found. Keyboard: arrows move the selected box, Shift+arrows
/// resize it, Ctrl+arrows turn it (half a degree; Ctrl+Shift: five), Delete removes it. <see cref="Boxes"/> are in units of
/// the scan's width (<see cref="PhotoBox"/>); the view edits the collection in place.
/// </summary>
public sealed class PhotoBoxesView : FrameworkElement
{
    private const double Handle = 9, RotateGap = 26, KeyStep = 0.004, MinSize = 0.03;

    private static readonly Brush Dim = Frozen(new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)));
    private static readonly Pen Outline = Frozen(new Pen(Brushes.White, 2));
    private static readonly Pen Shadow = Frozen(new Pen(new SolidColorBrush(Color.FromArgb(0x80, 0, 0, 0)), 4));

    private enum Drag { None, Draw, Move, Corner, Rotate }

    private Drag _drag;
    private int _corner;
    private Point _start;          // in scan units
    private PhotoBox _startBox;

    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(nameof(Source), typeof(ImageSource), typeof(PhotoBoxesView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty BoxesProperty = DependencyProperty.Register(nameof(Boxes), typeof(ObservableCollection<PhotoBox>), typeof(PhotoBoxesView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender, (d, e) => ((PhotoBoxesView)d).OnBoxesChanged(e)));

    public static readonly DependencyProperty SelectedIndexProperty = DependencyProperty.Register(nameof(SelectedIndex), typeof(int), typeof(PhotoBoxesView),
        new FrameworkPropertyMetadata(-1, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));

    public PhotoBoxesView()
    {
        Focusable = true;
        FocusVisualStyle = null; // the selected box turns accent-coloured instead
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        Cursor = Cursors.Cross;
    }

    public ImageSource? Source
    {
        get => (ImageSource?)GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public ObservableCollection<PhotoBox>? Boxes
    {
        get => (ObservableCollection<PhotoBox>?)GetValue(BoxesProperty);
        set => SetValue(BoxesProperty, value);
    }

    public int SelectedIndex
    {
        get => (int)GetValue(SelectedIndexProperty);
        set => SetValue(SelectedIndexProperty, value);
    }

    private void OnBoxesChanged(DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyCollectionChanged old) old.CollectionChanged -= BoxesChanged;
        if (e.NewValue is INotifyCollectionChanged now) now.CollectionChanged += BoxesChanged;
    }

    private void BoxesChanged(object? sender, NotifyCollectionChangedEventArgs e) => InvalidateVisual();

    private PhotoBox? Selected => Boxes is { } boxes && SelectedIndex >= 0 && SelectedIndex < boxes.Count ? boxes[SelectedIndex] : null;

    private void Replace(PhotoBox box)
    {
        if (Boxes is { } boxes && SelectedIndex >= 0 && SelectedIndex < boxes.Count) boxes[SelectedIndex] = box;
    }

    /// <summary>Where the scan is drawn: fitted and centred, as an Image with Stretch=Uniform would.</summary>
    private Rect PageRect()
    {
        if (Source is not { Width: > 0, Height: > 0 } src || ActualWidth <= 0 || ActualHeight <= 0) return Rect.Empty;
        var scale = Math.Min(ActualWidth / src.Width, ActualHeight / src.Height);
        var (w, h) = (src.Width * scale, src.Height * scale);
        return new Rect((ActualWidth - w) / 2, (ActualHeight - h) / 2, w, h);
    }

    // Box units are the scan's width, so both axes scale by the page's drawn width.
    private static Point ToView(Rect page, double x, double y) => new(page.X + x * page.Width, page.Y + y * page.Width);
    private static Point ToScan(Rect page, Point p) => new((p.X - page.X) / page.Width, (p.Y - page.Y) / page.Width);

    private static Point[] Corners(Rect page, PhotoBox box) => [.. box.Corners().Select(c => ToView(page, c.X, c.Y))];

    /// <summary>The turning handle: above the middle of the box's top edge.</summary>
    private static Point RotateHandle(Rect page, PhotoBox box)
    {
        var c = Corners(page, box);
        var top = new Point((c[0].X + c[1].X) / 2, (c[0].Y + c[1].Y) / 2);
        var (sin, cos) = Math.SinCos(box.Angle * Math.PI / 180);
        return new Point(top.X + sin * RotateGap, top.Y - cos * RotateGap);
    }

    private static Geometry Polygon(Point[] corners)
    {
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(corners[0], true, true);
            ctx.PolyLineTo(corners.Skip(1).ToList(), true, false);
        }
        g.Freeze();
        return g;
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // hit-testable everywhere
        var page = PageRect();
        if (page.IsEmpty) return;
        dc.DrawImage(Source, page);
        if (Boxes is not { } boxes) return;

        Geometry outside = new RectangleGeometry(page);
        foreach (var box in boxes) outside = new CombinedGeometry(GeometryCombineMode.Exclude, outside, Polygon(Corners(page, box)));
        dc.DrawGeometry(Dim, null, outside);

        var accent = TryFindResource("AccentFillColorDefaultBrush") as Brush ?? Brushes.DodgerBlue;
        var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        for (var i = 0; i < boxes.Count; i++)
        {
            var selected = i == SelectedIndex;
            var corners = Corners(page, boxes[i]);
            var shape = Polygon(corners);
            dc.DrawGeometry(null, Shadow, shape);
            dc.DrawGeometry(null, selected ? new Pen(accent, IsKeyboardFocused ? 3 : 2) : Outline, shape);

            // The number, as the photos are saved.
            var label = new FormattedText($"{i + 1}", System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, 15, Brushes.White, dpi);
            var centre = ToView(page, boxes[i].CenterX, boxes[i].CenterY);
            dc.DrawEllipse(selected ? accent : Dim, null, centre, 14, 14);
            dc.DrawText(label, new Point(centre.X - label.Width / 2, centre.Y - label.Height / 2));

            if (!selected) continue;
            foreach (var c in corners) dc.DrawRectangle(Brushes.White, Shadow, new Rect(c.X - Handle / 2, c.Y - Handle / 2, Handle, Handle));
            var top = new Point((corners[0].X + corners[1].X) / 2, (corners[0].Y + corners[1].Y) / 2);
            var handle = RotateHandle(page, boxes[i]);
            dc.DrawLine(new Pen(accent, 2), top, handle);
            dc.DrawEllipse(Brushes.White, new Pen(accent, 2), handle, Handle / 2 + 1, Handle / 2 + 1);
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        var page = PageRect();
        if (page.IsEmpty || Boxes is not { } boxes) return;
        var at = e.GetPosition(this);
        _start = ToScan(page, at);
        if (Selected is { } selected)
        {
            if ((RotateHandle(page, selected) - at).Length <= Handle + 2)
            {
                Begin(Drag.Rotate, selected);
                return;
            }
            var corners = Corners(page, selected);
            var hit = Array.FindIndex(corners, c => (c - at).Length <= Handle);
            if (hit >= 0)
            {
                _corner = hit;
                Begin(Drag.Corner, selected);
                return;
            }
        }
        // The box under the pointer (the selected one first, then the last drawn).
        var index = Selected is { } s && s.Contains(_start.X, _start.Y) ? SelectedIndex
            : Enumerable.Range(0, boxes.Count).LastOrDefault(i => boxes[i].Contains(_start.X, _start.Y), -1);
        if (index >= 0)
        {
            SelectedIndex = index;
            Begin(Drag.Move, boxes[index]);
            return;
        }
        Begin(Drag.Draw, default);

        void Begin(Drag drag, PhotoBox box)
        {
            _drag = drag;
            _startBox = box;
            CaptureMouse();
            e.Handled = true;
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var page = PageRect();
        if (page.IsEmpty || Boxes is not { } boxes) return;
        var at = e.GetPosition(this);
        var p = ToScan(page, at);
        switch (_drag)
        {
            case Drag.None:
                Cursor = Selected is { } sel && (RotateHandle(page, sel) - at).Length <= Handle + 2 ? Cursors.Hand
                    : Selected is { } s && Corners(page, s).Any(c => (c - at).Length <= Handle) ? Cursors.SizeAll
                    : boxes.Any(b => b.Contains(p.X, p.Y)) ? Cursors.SizeAll : Cursors.Cross;
                return;
            case Drag.Move:
                Replace(_startBox with { CenterX = _startBox.CenterX + p.X - _start.X, CenterY = _startBox.CenterY + p.Y - _start.Y });
                return;
            case Drag.Corner:
                Replace(_startBox.WithCorner(_corner, p.X, p.Y, MinSize));
                return;
            case Drag.Rotate:
                // The handle points at the photo's top: the angle from the centre to the pointer, a quarter back.
                var degrees = Math.Atan2(p.X - _startBox.CenterX, -(p.Y - _startBox.CenterY)) * 180 / Math.PI;
                if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) degrees = Math.Round(degrees / 15) * 15;
                Replace(_startBox with { Angle = Math.Round(degrees, 1) });
                return;
            case Drag.Draw:
                var box = new PhotoBox((_start.X + p.X) / 2, (_start.Y + p.Y) / 2, Math.Abs(p.X - _start.X), Math.Abs(p.Y - _start.Y), 0);
                if (SelectedIndex >= 0 && SelectedIndex < boxes.Count && _startBox.Width < 0) Replace(box); // already added: follow the pointer
                else if (box.Width > MinSize / 3 || box.Height > MinSize / 3)
                {
                    boxes.Add(box);
                    SelectedIndex = boxes.Count - 1;
                    _startBox = _startBox with { Width = -1 }; // marks "added"
                }
                return;
        }
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (_drag == Drag.None) return;
        // A box drawn too small to be a photo goes away again.
        if (_drag == Drag.Draw && _startBox.Width < 0 && Selected is { } drawn && (drawn.Width < MinSize || drawn.Height < MinSize) && Boxes is { } boxes)
        {
            boxes.RemoveAt(SelectedIndex);
            SelectedIndex = boxes.Count - 1;
        }
        _drag = Drag.None;
        ReleaseMouseCapture();
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (Boxes is not { Count: > 0 } boxes) return;
        if (e.Key == Key.Tab && Keyboard.Modifiers is ModifierKeys.None or ModifierKeys.Shift)
        {
            // Through the photos; past the last (or before the first) the focus moves on as usual.
            var next = SelectedIndex + (Keyboard.Modifiers == ModifierKeys.Shift ? -1 : 1);
            if (next < 0 || next >= boxes.Count) return;
            SelectedIndex = next;
            e.Handled = true;
            return;
        }
        if (Selected is not { } b) return;
        if (e.Key == Key.Delete)
        {
            var removed = SelectedIndex;
            boxes.RemoveAt(removed);
            SelectedIndex = Math.Min(removed, boxes.Count - 1);
            e.Handled = true;
            return;
        }
        var (dx, dy) = e.Key switch
        {
            Key.Left => (-1, 0),
            Key.Right => (1, 0),
            Key.Up => (0, -1),
            Key.Down => (0, 1),
            _ => (0, 0),
        };
        if (dx == 0 && dy == 0) return;
        var mods = Keyboard.Modifiers;
        if (mods.HasFlag(ModifierKeys.Control))
            Replace(b with { Angle = Math.Round(b.Angle + (dx + dy) * (mods.HasFlag(ModifierKeys.Shift) ? 5 : 0.5), 1) });
        else if (mods.HasFlag(ModifierKeys.Shift))
            Replace(b with { Width = Math.Max(MinSize, b.Width + dx * KeyStep), Height = Math.Max(MinSize, b.Height + dy * KeyStep) });
        else
            Replace(b with { CenterX = b.CenterX + dx * KeyStep, CenterY = b.CenterY + dy * KeyStep });
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
