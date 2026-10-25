using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace InkvoltPrint.App;

/// <summary>
/// <c>local:AppIcon.Size="24"</c> on an <see cref="Image"/>: shows the app icon from the frame of <c>InkvoltPrint.ico</c>
/// that fits the size at the screen's scale (the smallest frame at least that many pixels wide), picked again when the
/// window moves to a screen with another scale. <c>Source="/InkvoltPrint.ico"</c> would always use the first frame, 16 px,
/// blown up and blurry. Window.Icon (the title bar) picks its own frame and doesn't need this.
/// </summary>
public static class AppIcon
{
    private static readonly Lazy<BitmapFrame[]> Frames = new(() =>
    {
        var decoder = BitmapDecoder.Create(new Uri("pack://application:,,,/InkvoltPrint.ico"), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return [.. decoder.Frames.OrderBy(f => f.PixelWidth).ThenByDescending(f => f.Format.BitsPerPixel)];
    });

    public static readonly DependencyProperty SizeProperty =
        DependencyProperty.RegisterAttached("Size", typeof(double), typeof(AppIcon), new PropertyMetadata(0.0, OnSizeChanged));

    public static double GetSize(Image image) => (double)image.GetValue(SizeProperty);
    public static void SetSize(Image image, double value) => image.SetValue(SizeProperty, value);

    private static void OnSizeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not Image image) return;
        image.Width = image.Height = (double)e.NewValue;
        image.UseLayoutRounding = true; // whole pixels, so a frame of exactly the right size is drawn 1:1
        image.Loaded -= OnLoaded;
        image.Loaded += OnLoaded;
        image.DpiChanged -= OnDpiChanged;
        image.DpiChanged += OnDpiChanged;
        Pick(image, VisualTreeHelper.GetDpi(image).DpiScaleX);
    }

    private static void OnLoaded(object sender, RoutedEventArgs e) => Pick((Image)sender, VisualTreeHelper.GetDpi((Image)sender).DpiScaleX);

    private static void OnDpiChanged(object sender, DpiChangedEventArgs e) => Pick((Image)sender, e.NewDpi.DpiScaleX);

    /// <summary>The smallest frame at least <paramref name="pixels"/> wide, else the largest.</summary>
    public static BitmapFrame Frame(double pixels)
    {
        var frames = Frames.Value;
        return frames.FirstOrDefault(f => f.PixelWidth >= Math.Round(pixels)) ?? frames[^1];
    }

    private static void Pick(Image image, double scale)
    {
        var frame = Frame(GetSize(image) * scale);
        if (!ReferenceEquals(image.Source, frame)) image.Source = frame;
    }
}
