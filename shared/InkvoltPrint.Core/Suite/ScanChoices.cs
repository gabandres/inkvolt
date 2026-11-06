using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.Core.Suite;

/// <summary>A scan area in 1/300 inch (eSCL units). Null size = the source's whole area.</summary>
public sealed record ScanPageSize(string Key, string Label, int? Width, int? Height);

/// <summary>
/// The scan options a dialog offers for a scanner, from its eSCL capabilities, and the <see cref="ScanRequest"/> they make.
/// Shared by Inkvolt Print's Scan tab (page sizes) and Inkvolt PDF's Scan dialog.
/// </summary>
public static class ScanChoices
{
    /// <summary>The sizes offered, labelled in the interface's language (a new list each time: the labels are read when asked).</summary>
    public static IReadOnlyList<ScanPageSize> PageSizes =>
    [
        new("letter", CoreStrings.Suite_PageLetter, 2550, 3300),
        new("a4", CoreStrings.Suite_PageA4, 2480, 3508),
        new("legal", CoreStrings.Suite_PageLegal, 2550, 4200),
        new("full", CoreStrings.Suite_PageWhole, null, null),
    ];

    /// <summary>Document resolutions offered by Inkvolt PDF: enough for text and OCR, small files.</summary>
    public static readonly IReadOnlyList<int> DocumentResolutions = [150, 200, 300];

    public static string SourceLabel(ScanSource s) => s switch
    {
        ScanSource.Platen => CoreStrings.Suite_SourceGlass,
        ScanSource.Adf => CoreStrings.Suite_SourceFeeder,
        _ => CoreStrings.Suite_SourceFeederDuplex,
    };

    public static IReadOnlyList<ScanSource> Sources(ScannerCapabilities caps) => caps.Sources.ToList();

    /// <summary>
    /// Color, then grayscale, as far as the source lists them (a source listing neither gets both: eSCL falls back), then black
    /// and white when the source lists it.
    /// </summary>
    public static IReadOnlyList<ScanColor> Colors(ScannerCapabilities caps, ScanSource source)
    {
        var modes = caps.For(source)?.ColorModes ?? [];
        var list = new List<ScanColor>();
        if (modes.Count == 0 || modes.Contains("RGB24")) list.Add(ScanColor.Color);
        if (modes.Count == 0 || modes.Contains("Grayscale8")) list.Add(ScanColor.Grayscale);
        if (list.Count == 0) list.Add(ScanColor.Color);
        if (modes.Contains("BlackAndWhite1")) list.Add(ScanColor.BlackAndWhite);
        return list;
    }

    /// <summary>
    /// The color mode to scan in from a remembered choice (Inkvolt Print's Scan tab, a preset), as <paramref name="offered"/>
    /// (<see cref="Colors"/>) allows: color when wanted and offered, black and white when wanted and offered, else grey, else what
    /// the source has.
    /// </summary>
    public static ScanColor Pick(IReadOnlyList<ScanColor> offered, bool color, bool blackAndWhite) =>
        color && offered.Contains(ScanColor.Color) ? ScanColor.Color
        : !color && blackAndWhite && offered.Contains(ScanColor.BlackAndWhite) ? ScanColor.BlackAndWhite
        : offered.Contains(ScanColor.Grayscale) ? ScanColor.Grayscale
        : offered.Count > 0 ? offered[0] : ScanColor.Color;

    /// <summary>A chosen color mode as it is remembered (<see cref="Pick"/>'s two flags): color, or black and white, or neither (grey).</summary>
    public static (bool Color, bool BlackAndWhite) Remember(ScanColor color) => (color == ScanColor.Color, color == ScanColor.BlackAndWhite);

    public static string ColorLabel(ScanColor c) => c switch
    {
        ScanColor.Color => CoreStrings.Suite_ColorColor,
        ScanColor.Grayscale => CoreStrings.Suite_ColorGrayscale,
        _ => CoreStrings.Suite_ColorBlackAndWhite,
    };

    /// <summary>
    /// The <paramref name="wanted"/> resolutions the source supports; when it lists resolutions but none of these, its closest
    /// one to each (distinct). A source that lists none accepts the wanted values as they are.
    /// </summary>
    public static IReadOnlyList<int> Resolutions(ScannerCapabilities caps, ScanSource source, IReadOnlyList<int>? wanted = null)
    {
        wanted ??= DocumentResolutions;
        var supported = caps.For(source)?.Resolutions ?? [];
        if (supported.Count == 0) return wanted;
        return wanted.Select(w => supported.MinBy(s => Math.Abs(s - w))).Distinct().Order().ToList();
    }

    /// <summary>Sizes the source can scan (a few pixels of tolerance), whole area last.</summary>
    public static IReadOnlyList<ScanPageSize> PageSizesFor(ScannerCapabilities caps, ScanSource source)
    {
        if (caps.For(source) is not { } input) return [PageSizes[^1]];
        return PageSizes.Where(p => p.Width is null || (p.Width <= input.MaxWidth + 5 && p.Height <= input.MaxHeight + 5)).ToList();
    }

    /// <summary>The page size to preselect: the remembered key if still offered, else Letter or A4 by region.</summary>
    public static ScanPageSize DefaultPageSize(IReadOnlyList<ScanPageSize> offered, string? remembered, bool metric) =>
        offered.FirstOrDefault(p => p.Key == remembered) ?? offered.FirstOrDefault(p => p.Key == (metric ? "a4" : "letter")) ?? offered[0];

    public static ScanRequest ToRequest(ScanSource source, ScanColor color, int dpi, ScanPageSize? size) =>
        new(source, color, dpi, Width: size?.Width, Height: size?.Height);
}
