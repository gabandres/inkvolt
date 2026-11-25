using System.Globalization;

namespace InkvoltPrint.Core.Suite;

/// <summary>The interface language a person picked in Settings: Windows' own, or one of the languages the app is written in.</summary>
public enum UiLanguageChoice
{
    /// <summary>Follow Windows' display language (the default): Spanish for any Spanish, Brazilian Portuguese for pt-BR, English for the rest.</summary>
    Windows,
    English,
    Spanish,
    PortugueseBrazil,
}

/// <summary>
/// Which language an Inkvolt app's interface is shown in: the choice saved in its settings (<c>null</c>, <c>"en"</c>,
/// <c>"es"</c> or <c>"pt-BR"</c>), or a dev aid's <c>--lang</c>, against Windows' display language. Pure, so it is tested
/// here; each app sets its culture from it once, at start-up, before any window (a change applies the next time it starts).
/// </summary>
public static class UiLanguage
{
    /// <summary>English: the neutral resources, what every Inkvolt app was written in.</summary>
    public static readonly CultureInfo English = CultureInfo.GetCultureInfo("en");

    /// <summary>Plain Spanish, one for every Spanish-speaking market (as the Store listing).</summary>
    public static readonly CultureInfo Spanish = CultureInfo.GetCultureInfo("es");

    /// <summary>Brazilian Portuguese (pt-BR); other Portuguese variants such as pt-PT stay English.</summary>
    public static readonly CultureInfo PortugueseBrazil = CultureInfo.GetCultureInfo("pt-BR");

    /// <summary>The saved value read back: <c>"en"</c>, <c>"es"</c> (any case, or a region such as <c>es-PR</c>), or <c>"pt-BR"</c>; anything else follows Windows.</summary>
    public static UiLanguageChoice Parse(string? saved)
    {
        if (IsBrazilianPortuguese(saved)) return UiLanguageChoice.PortugueseBrazil;
        return Language(saved) switch
        {
            "en" => UiLanguageChoice.English,
            "es" => UiLanguageChoice.Spanish,
            _ => UiLanguageChoice.Windows,
        };
    }

    /// <summary>What settings keep for a choice: <c>null</c> for Windows' language, so a file without it follows Windows.</summary>
    public static string? Save(UiLanguageChoice choice) => choice switch
    {
        UiLanguageChoice.English => "en",
        UiLanguageChoice.Spanish => "es",
        UiLanguageChoice.PortugueseBrazil => "pt-BR",
        _ => null,
    };

    /// <summary>
    /// The culture the interface's text comes from: the choice, or for <see cref="UiLanguageChoice.Windows"/> Spanish when
    /// Windows' display language is any Spanish (es, es-ES, es-419, es-PR…), Brazilian Portuguese when it is pt-BR (not pt-PT),
    /// and English for every other.
    /// </summary>
    public static CultureInfo Resolve(UiLanguageChoice choice, CultureInfo windowsDisplay) => choice switch
    {
        UiLanguageChoice.English => English,
        UiLanguageChoice.Spanish => Spanish,
        UiLanguageChoice.PortugueseBrazil => PortugueseBrazil,
        _ => Language(windowsDisplay.Name) == "es" ? Spanish
            : IsBrazilianPortuguese(windowsDisplay.Name) ? PortugueseBrazil
            : English,
    };

    /// <summary>A dev aid's <c>--lang</c> value wins over the saved choice; then the saved choice; then Windows.</summary>
    public static CultureInfo Resolve(string? argument, string? saved, CultureInfo windowsDisplay) =>
        Resolve(Parse(argument) is var fromArgument and not UiLanguageChoice.Windows ? fromArgument : Parse(saved), windowsDisplay);

    /// <summary>
    /// The culture numbers and dates are written in: Windows' regional format, unless its language isn't the interface's;
    /// then the interface's language in the same region where there is one (Spanish on a PC set to United States formats:
    /// es-US, so "3 de noviembre de 2026" with the US's numbers), else the regional format as it is.
    /// </summary>
    public static CultureInfo FormatCulture(CultureInfo ui, CultureInfo regional)
    {
        var language = Language(ui.Name);
        if (language is null || Language(regional.Name) == language) return regional;
        var dash = regional.Name.LastIndexOf('-');
        if (dash > 0)
        {
            try
            {
                return CultureInfo.GetCultureInfo($"{language}-{regional.Name[(dash + 1)..]}", predefinedOnly: true);
            }
            catch (CultureNotFoundException)
            {
            }
        }
        return regional;
    }

    private static bool IsBrazilianPortuguese(string? tag)
    {
        var t = tag?.Trim();
        if (string.IsNullOrEmpty(t)) return false;
        var parts = t.Split(['-', '_'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2
            && parts[0].Equals("pt", StringComparison.OrdinalIgnoreCase)
            && parts[^1].Equals("br", StringComparison.OrdinalIgnoreCase);
    }

    private static string? Language(string? tag)
    {
        var t = tag?.Trim();
        if (string.IsNullOrEmpty(t)) return null;
        var dash = t.IndexOfAny(['-', '_']);
        return (dash < 0 ? t : t[..dash]).ToLowerInvariant();
    }
}
