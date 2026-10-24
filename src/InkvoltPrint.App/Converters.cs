using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace InkvoltPrint.App;

/// <summary>Status kind (ok/warning/error/offline/connecting) → dot colour.</summary>
public sealed class StatusBrushConverter : IValueConverter
{
    private static readonly Brush Ok = Frozen(0x2E, 0x9D, 0x4F);
    private static readonly Brush Warning = Frozen(0xE8, 0xA3, 0x17);
    private static readonly Brush Error = Frozen(0xD1, 0x34, 0x38);
    private static readonly Brush Idle = Frozen(0x8A, 0x8A, 0x8A);

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        "ok" => Ok,
        "warning" => Warning,
        "error" => Error,
        _ => Idle,
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();

    internal static Brush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }
}

/// <summary>Supply colour code (K, C, M, Y, or #RRGGBB from IPP <c>marker-colors</c>) → swatch colour.</summary>
public sealed class SupplyBrushConverter : IValueConverter
{
    private static readonly Brush K = StatusBrushConverter.Frozen(0x30, 0x30, 0x30);
    private static readonly Brush C = StatusBrushConverter.Frozen(0x00, 0xA3, 0xE0);
    private static readonly Brush M = StatusBrushConverter.Frozen(0xD0, 0x1C, 0x8B);
    private static readonly Brush Y = StatusBrushConverter.Frozen(0xF2, 0xC8, 0x00);

    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        "C" => C,
        "M" => M,
        "Y" => Y,
        "K" => SystemParameters.HighContrast ? SystemColors.WindowTextBrush : K,
        string hex when hex.Length == 7 && hex[0] == '#' && ColorConverter.ConvertFromString(hex) is Color c => Freeze(new SolidColorBrush(c)),
        _ => DependencyProperty.UnsetValue,
    };

    private static Brush Freeze(Brush b)
    {
        b.Freeze();
        return b;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>null / false / empty → Collapsed; anything else → Visible. ConverterParameter "invert" flips it.</summary>
public sealed class VisibleWhenConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var visible = value switch
        {
            null => false,
            bool b => b,
            string s => s.Length > 0,
            int i => i > 0,
            _ => true,
        };
        if (parameter as string == "invert") visible = !visible;
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class PlusOneConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is int i ? $"Page {i + 1}" : "";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Status kind → Segoe Fluent Icons glyph.</summary>
public sealed class StatusGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        "ok" => "",        // CheckMark
        "warning" => "",   // Warning
        "error" => "",     // Error
        "offline" => "",   // Disconnected (falls back to a box on older fonts)
        _ => "",           // Sync
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Supply level (ok/low/empty) → Fluent semantic brush resource.</summary>
public sealed class LevelBrushConverter : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        "empty" => Application.Current.TryFindResource("SystemFillColorCriticalBrush"),
        "low" => Application.Current.TryFindResource("SystemFillColorCautionBrush"),
        _ => Application.Current.TryFindResource("AccentFillColorDefaultBrush"),
    } ?? DependencyProperty.UnsetValue;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class NotConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is not true;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => value is not true;
}

/// <summary>Glyph colour on the status disc: dark on the amber warning disc (white fails contrast), white elsewhere.</summary>
public sealed class StatusGlyphBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is "warning" ? Brushes.Black : Brushes.White;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
