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
    public static readonly IReadOnlyList<ScanPageSize> PageSizes =
    [
        new("letter", "Letter (8.5 × 11 in)", 2550, 3300),
        new("a4", "A4 (210 × 297 mm)", 2480, 3508),
        new("legal", "Legal (8.5 × 14 in)", 2550, 4200),
        new("full", "Whole scanning area", null, null),
    ];

    /// <summary>Document resolutions offered by Inkvolt PDF: enough for text and OCR, small files.</summary>
    public static readonly IReadOnlyList<int> DocumentResolutions = [150, 200, 300];

    public static string SourceLabel(ScanSource s) => s switch
    {
        ScanSource.Platen => "Scanner glass",
        ScanSource.Adf => "Document feeder",
        _ => "Document feeder (both sides)",
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

    public static string ColorLabel(ScanColor c) => c switch
    {
        ScanColor.Color => "Color",
        ScanColor.Grayscale => "Grayscale",
        _ => "Black and white",
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
