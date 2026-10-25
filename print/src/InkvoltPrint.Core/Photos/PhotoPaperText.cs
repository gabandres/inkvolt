using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Photos;

/// <summary>
/// Plain names for what a Windows print queue offers: paper sizes (by their size, since drivers name the same paper in
/// different ways), paper types, print quality and color modes (the Print Schema names, e.g. PhotographicGlossy).
/// </summary>
public static class PhotoPaperText
{
    private static readonly (double W, double H, string Name)[] Known =
    [
        (8.5, 11, "Letter (8.5 × 11 in)"),
        (8.5, 14, "Legal (8.5 × 14 in)"),
        (11, 17, "Tabloid (11 × 17 in)"),
        (7.25, 10.5, "Executive (7.25 × 10.5 in)"),
        (210 / 25.4, 297 / 25.4, "A4 (21 × 29.7 cm)"),
        (148 / 25.4, 210 / 25.4, "A5 (14.8 × 21 cm)"),
        (105 / 25.4, 148 / 25.4, "A6 (10.5 × 14.8 cm)"),
        (297 / 25.4, 420 / 25.4, "A3 (29.7 × 42 cm)"),
        (182 / 25.4, 257 / 25.4, "B5 (18.2 × 25.7 cm)"),
        (100 / 25.4, 148 / 25.4, "Hagaki postcard (10 × 14.8 cm)"),
        (3.5, 5, "3.5 × 5 in photo"),
        (4, 6, "4 × 6 in photo"),
        (5, 7, "5 × 7 in photo"),
        (8, 10, "8 × 10 in photo"),
        (100 / 25.4, 150 / 25.4, "10 × 15 cm photo"),
        (130 / 25.4, 180 / 25.4, "13 × 18 cm photo"),
        (5, 8, "5 × 8 in"),
    ];

    /// <summary>"Letter (8.5 × 11 in)", "4 × 6 in photo"; otherwise its size in inches. <paramref name="name"/> is the driver's (unused for now: sizes are what count).</summary>
    public static string Paper(string? name, double widthIn, double heightIn)
    {
        var (a, b) = (Math.Min(widthIn, heightIn), Math.Max(widthIn, heightIn));
        foreach (var (w, h, label) in Known)
            if (Math.Abs(a - w) < 0.04 && Math.Abs(b - h) < 0.04) return label;
        return string.Create(CultureInfo.InvariantCulture, $"{a:0.##} × {b:0.##} in");
    }

    /// <summary>Print Schema media type → "Photo paper, glossy", "Plain paper"…</summary>
    public static string MediaType(string name) => name switch
    {
        "Plain" => "Plain paper",
        "AutoSelect" => "Let the printer choose",
        "Photographic" => "Photo paper",
        "PhotographicGlossy" => "Photo paper, glossy",
        "PhotographicHighGloss" => "Photo paper, high gloss",
        "PhotographicSemiGloss" => "Photo paper, semi-gloss",
        "PhotographicMatte" => "Photo paper, matte",
        "PhotographicSatin" => "Photo paper, satin",
        "PhotographicFilm" => "Photo film",
        _ => Words(name),
    };

    public static bool IsPhotoMedia(string name) => name.StartsWith("Photographic", StringComparison.Ordinal);

    /// <summary>Print Schema output quality → a plain word.</summary>
    public static string Quality(string name) => name switch
    {
        "Photographic" => "Photo (best)",
        _ => Words(name),
    };

    /// <summary>Print Schema output color → a plain word.</summary>
    public static string Color(string name) => name switch
    {
        "Grayscale" => "Shades of grey",
        "Monochrome" => "Black and white",
        _ => Words(name),
    };

    /// <summary>"CardStockCoated" → "Card stock coated".</summary>
    private static string Words(string name)
    {
        var sb = new StringBuilder(name.Length + 4);
        for (var i = 0; i < name.Length; i++)
        {
            var c = name[i];
            if (i > 0 && char.IsUpper(c) && !char.IsUpper(name[i - 1])) sb.Append(' ').Append(char.ToLowerInvariant(c));
            else sb.Append(c);
        }
        return sb.ToString();
    }
}
