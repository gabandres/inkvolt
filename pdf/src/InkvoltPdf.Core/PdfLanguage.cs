using System.Globalization;
using System.Runtime.CompilerServices;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Core;

/// <summary>
/// The language of the text this library writes for Inkvolt PDF's interface (<see cref="PdfStrings"/>): English unless the
/// app opts in. The command line (<c>--batch</c>, <c>--watch</c>, <c>--fill</c>), whose output scripts read, never opts in,
/// so it stays English whatever Windows' language; the app sets its interface language here at start-up.
/// </summary>
public static class PdfLanguage
{
    /// <summary>The culture <see cref="PdfStrings"/> reads from: English (the neutral resources) until <see cref="Use"/>.</summary>
    public static CultureInfo Culture => PdfStrings.Culture ?? CultureInfo.InvariantCulture;

    /// <summary>Text from here in <paramref name="culture"/> from now on (the app, before its first window).</summary>
    public static void Use(CultureInfo culture) => PdfStrings.Culture = culture;

    /// <summary>
    /// The interface's language: a dev aid's <c>--lang</c>, else the saved choice (<c>null</c>, <c>"en"</c> or <c>"es"</c>),
    /// else Windows' display language (Spanish for any es-*). While the Spanish isn't complete (<paramref name="spanishReady"/>
    /// false) only <c>--lang</c> can pick it: a saved choice or a Spanish Windows still get English.
    /// </summary>
    public static CultureInfo Choose(bool spanishReady, string? argument, string? saved, CultureInfo windowsDisplay)
    {
        if (spanishReady) return UiLanguage.Resolve(argument, saved, windowsDisplay);
        return UiLanguage.Parse(argument) is UiLanguageChoice.Windows ? UiLanguage.English : UiLanguage.Resolve(argument, null, windowsDisplay);
    }

#pragma warning disable CA2255 // a library's module initializer on purpose: the default (English) must hold before any caller asks
    [ModuleInitializer]
    internal static void EnglishByDefault() => PdfStrings.Culture ??= CultureInfo.InvariantCulture;
#pragma warning restore CA2255
}

/// <summary>
/// Sentences from resource strings: one format string per sentence ({0}, {1}), never pieces put together, and a count's
/// two forms (one, many) as two strings. Numbers and dates take the regional format (CurrentCulture). A translation whose
/// placeholders are broken shows its words and values instead of throwing: a wrong resource never crashes the app.
/// </summary>
public static class Loc
{
    public static string Format(string format, params object?[] args)
    {
        try
        {
            return string.Format(CultureInfo.CurrentCulture, format, args);
        }
        catch (FormatException)
        {
            return args.Length == 0 ? format : $"{format} ({string.Join(", ", args)})";
        }
    }

    /// <summary><paramref name="one"/> for exactly 1, <paramref name="many"/> for every other count ({0} is the count; then <paramref name="more"/>).</summary>
    public static string Plural(long count, string one, string many, params object?[] more) =>
        Format(count == 1 ? one : many, [count, .. more]);
}
