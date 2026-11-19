namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// Print Photos speaks Print Schema names (what a Windows driver offers: <c>PhotographicGlossy</c>, <c>High</c>, <c>Color</c>),
/// so a printer printed to over IPP has its <c>media-type</c> keywords, <c>print-quality</c> values and color modes named the
/// same way, and back again for the job.
/// </summary>
public static class IppPhotoNames
{
    private static readonly (string Keyword, string Name)[] Types =
    [
        ("stationery", "Plain"), ("auto", "AutoSelect"), ("photographic", "Photographic"),
        ("photographic-glossy", "PhotographicGlossy"), ("photographic-high-gloss", "PhotographicHighGloss"),
        ("photographic-semi-gloss", "PhotographicSemiGloss"), ("photographic-matte", "PhotographicMatte"),
        ("photographic-satin", "PhotographicSatin"), ("photographic-film", "PhotographicFilm"), ("labels", "Label"),
        ("cardstock", "CardStock"), ("transparency", "Transparency"), ("envelope", "Envelope"),
    ];

    /// <summary>The Print Schema name for a <c>media-type</c> keyword; null for one with no counterpart (left out of the list).</summary>
    public static string? MediaTypeName(string keyword) => Types.FirstOrDefault(t => t.Keyword == keyword).Name;

    public static string? MediaTypeKeyword(string? name) => name is null ? null : Types.FirstOrDefault(t => t.Name == name).Keyword;

    public static string QualityName(int quality) => quality switch { 3 => "Draft", 5 => "High", _ => "Normal" };

    public static int? Quality(string? name) => name switch { "Draft" => 3, "Normal" => 4, "High" or "Photographic" => 5, _ => null };

    /// <summary>"Color" true, "Monochrome" or "Grayscale" false, else null (the printer's default).</summary>
    public static bool? Color(string? name) => name switch { "Color" => true, "Monochrome" or "Grayscale" => false, _ => null };
}
