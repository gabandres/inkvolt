using System.Globalization;
using System.Windows;
using System.Windows.Markup;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.App;

/// <summary>
/// The interface's language, chosen once at start-up (Settings › Language applies the next time the app starts): the dev
/// aids' <c>--lang en|es</c>, else the saved choice (<see cref="AppSettings.Language"/>), else Windows' display language
/// (<see cref="UiLanguage"/>). Text comes from <see cref="Strings"/>, Core's PdfStrings and the shared library's
/// CoreStrings (scanners, printers) in that language. Numbers and dates keep Windows' regional format (CurrentCulture),
/// WPF's bindings included, in the interface's language when Windows' format is in another (UiLanguage.FormatCulture).
/// The command line (<c>--batch</c>, <c>--watch</c>, <c>--fill</c>) never comes here: it stays English.
/// </summary>
public static class AppLanguage
{
    /// <summary>
    /// The Spanish translation is complete (every string in Strings.es.resx and PdfStrings.es.resx; LocalizationTests). When
    /// false, the interface is always English, Settings › Language is hidden and a saved choice is ignored (only the dev
    /// aids' <c>--lang</c> still picks a language): the switch for a language whose strings are still being written.
    /// </summary>
    public static bool SpanishReady => true;

    /// <summary>
    /// How much wider than in English a dialog laid out for English words is made for the interface's language: 1 in English,
    /// 1.15 in Spanish, whose sentences and button labels run about a fifth longer.
    /// </summary>
    public static double TextWidth => Current.TwoLetterISOLanguageName == "en" ? 1 : 1.15;

    /// <summary>Windows' display language as the process started, before <see cref="Apply"/> changed the UI culture.</summary>
    private static readonly CultureInfo WindowsDisplay = CultureInfo.CurrentUICulture;

    /// <summary>The language the interface is in (English until <see cref="Apply"/>).</summary>
    public static CultureInfo Current { get; private set; } = UiLanguage.English;

    /// <summary>
    /// English for what runs before the window, the command line above all: its output is read by scripts and stays English
    /// whatever Windows' language.
    /// </summary>
    public static void UseEnglish() => Use(UiLanguage.English);

    /// <summary>Picks the language and makes every thread's text use it. Call before the first window.</summary>
    public static void Apply(string? saved, string[] args)
    {
        var argument = Array.IndexOf(args, "--lang") is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        Use(Core.PdfLanguage.Choose(SpanishReady, argument, saved, WindowsDisplay));
        // Dates and numbers: Windows' regional format, in the interface's language when the two differ (UiLanguage.FormatCulture).
        var format = UiLanguage.FormatCulture(Current, CultureInfo.CurrentCulture);
        if (!ReferenceEquals(format, CultureInfo.CurrentCulture))
        {
            CultureInfo.DefaultThreadCurrentCulture = format;
            CultureInfo.CurrentCulture = format;
        }
        // WPF formats bound numbers and dates as en-US unless told otherwise: Windows' regional format instead.
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(CultureInfo.CurrentCulture.IetfLanguageTag)));
        Log.Write($"Interface language: {Current.Name}, formats {CultureInfo.CurrentCulture.Name} (Windows: {WindowsDisplay.Name}, saved: {saved ?? "Windows"})");
    }

    /// <summary>The arguments without the dev aids' <c>--lang xx</c>, so it isn't taken for a file to open.</summary>
    public static string[] WithoutLanguageArgument(string[] args) =>
        Array.IndexOf(args, "--lang") is var i and >= 0 ? [.. args.Where((_, j) => j != i && j != i + 1)] : args;

    /// <summary>
    /// The English of a menu item or command name shown in another language ("Girar páginas…" → "Rotate Pages"), so the
    /// command palette also finds commands by the English names tutorials use; "" when the interface is English or the
    /// name isn't one of <see cref="Strings"/>' (a file name, a printer's). Access keys and a trailing "…" are left out.
    /// </summary>
    public static string EnglishOf(string shown)
    {
        if (Current.Name == UiLanguage.English.Name || shown.Length == 0) return "";
        return (_english ??= BuildEnglish()).GetValueOrDefault(Plain(shown), "");
    }

    private static Dictionary<string, string>? _english;

    private static Dictionary<string, string> BuildEnglish()
    {
        var names = new Dictionary<string, string>(StringComparer.CurrentCultureIgnoreCase);
        var shown = Strings.ResourceManager.GetResourceSet(Current, createIfNotExists: true, tryParents: true);
        var english = Strings.ResourceManager.GetResourceSet(CultureInfo.InvariantCulture, createIfNotExists: true, tryParents: false);
        if (shown is null || english is null) return names;
        foreach (System.Collections.DictionaryEntry entry in shown)
            if (entry.Value is string text && english.GetString((string)entry.Key) is { } en && Plain(en) is var plain && plain != Plain(text))
                names.TryAdd(Plain(text), plain);
        return names;
    }

    private static string Plain(string text) => text.Replace("_", "").TrimEnd('…', '.').Trim();

    private static void Use(CultureInfo culture)
    {
        Current = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentUICulture = culture;
        Strings.Culture = culture;
        Core.PdfLanguage.Use(culture);
        InkvoltPrint.Core.CoreLanguage.Use(culture);
    }
}
