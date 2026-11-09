using System.Globalization;

namespace InkvoltPdf.Core;

/// <summary>
/// The command bar's only colors (the owner, 2026-11-08); the rest of it is monochrome. Convert's file types (our own
/// document glyphs, never the Office logos) in their usual colors, Word blue, Excel green, PowerPoint orange and PDF/A
/// grey, and Apply Redactions' icon red. Text, HTML and pictures stay the text color. The tool in use takes Windows'
/// accent from the theme, not from here. Each color has a dark-theme variant, and every one keeps 3:1 against the
/// flyout's and the bar's backgrounds in its theme (WCAG's non-text contrast). Under high contrast none is used: the
/// app draws them with the system's colors. Labels always say what an icon means; color never does it alone.
/// </summary>
public static class BarColors
{
    /// <summary>A resource key (the command's <see cref="CommandBarLayout.Command.IconBrush"/>) and its color in each theme (#RRGGBB).</summary>
    public sealed record Tint(string Key, string Light, string Dark);

    public static readonly IReadOnlyList<Tint> All =
    [
        new("FormatWordBrush", "#185ABD", "#6AA6EE"),
        new("FormatExcelBrush", "#107C41", "#3BB26B"),
        new("FormatPowerPointBrush", "#C43E1C", "#F0805C"),
        new("FormatPdfABrush", "#6B6B6B", "#A0A0A0"),
        new("ApplyRedactionsBrush", "#C42B1C", "#FF99A4"),
    ];

    /// <summary>The backgrounds an icon sits on: the flyout, the bar (Mica), a hovered item; light, then dark.</summary>
    public static readonly IReadOnlyList<string> LightBackgrounds = ["#FFFFFF", "#F9F9F9", "#F3F3F3", "#EBEBEB"];
    public static readonly IReadOnlyList<string> DarkBackgrounds = ["#202020", "#2C2C2C", "#383838", "#454545"];

    /// <summary>The colors to define for the theme, by key; empty under high contrast (the system's colors draw them).</summary>
    public static IReadOnlyDictionary<string, string> For(bool dark, bool highContrast) =>
        highContrast ? new Dictionary<string, string>() : All.ToDictionary(t => t.Key, t => dark ? t.Dark : t.Light);

    /// <summary>WCAG's contrast ratio of two #RRGGBB colors (1 to 21).</summary>
    public static double ContrastRatio(string a, string b)
    {
        var (la, lb) = (Luminance(a), Luminance(b));
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    /// <summary>The three bytes of a #RRGGBB color.</summary>
    public static (byte R, byte G, byte B) Rgb(string hex)
    {
        var h = hex.TrimStart('#');
        if (h.Length != 6 || !int.TryParse(h, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v))
            throw new FormatException($"Not a #RRGGBB color: {hex}");
        return ((byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }

    private static double Luminance(string hex)
    {
        var (r, g, b) = Rgb(hex);
        static double Linear(byte c)
        {
            var x = c / 255.0;
            return x <= 0.04045 ? x / 12.92 : Math.Pow((x + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Linear(r) + 0.7152 * Linear(g) + 0.0722 * Linear(b);
    }
}
