using System.Globalization;
using System.Windows;
using System.Windows.Markup;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App;

/// <summary>
/// The interface's language, chosen once at start-up (Settings › Language applies the next time the app starts): the dev
/// aids' <c>--lang en|es</c>, else the saved choice (<see cref="AppState.Language"/>), else Windows' display language
/// (<see cref="UiLanguage"/>). Text comes from <see cref="Strings"/> and the shared library's CoreStrings in that
/// language. Numbers and dates keep Windows' regional format (CurrentCulture), WPF's bindings included.
/// </summary>
public static class AppLanguage
{
    /// <summary>Windows' display language as the process started, before <see cref="Apply"/> changed the UI culture.</summary>
    private static readonly CultureInfo WindowsDisplay = CultureInfo.CurrentUICulture;

    /// <summary>The language the interface is in (English until <see cref="Apply"/>).</summary>
    public static CultureInfo Current { get; private set; } = UiLanguage.English;

    /// <summary>
    /// English for what runs before the window: the command-line paths (<c>print</c>, <c>status --all</c>) write English
    /// whatever Windows' language, as <c>inkvoltprint</c> does.
    /// </summary>
    public static void UseEnglish() => Use(UiLanguage.English);

    /// <summary>Picks the language and makes every thread's text use it. Call before the first view model or window.</summary>
    public static void Apply(string? saved, string[] args)
    {
        var argument = Array.IndexOf(args, "--lang") is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        Use(UiLanguage.Resolve(argument, saved, WindowsDisplay));
        // WPF formats bound numbers and dates as en-US unless told otherwise: Windows' regional format instead.
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(CultureInfo.CurrentCulture.IetfLanguageTag)));
        Log.Write($"Interface language: {Current.Name} (Windows: {WindowsDisplay.Name}, saved: {saved ?? "Windows"})");
    }

    private static void Use(CultureInfo culture)
    {
        Current = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentUICulture = culture;
        Strings.Culture = culture;
        Core.CoreLanguage.Use(culture);
    }
}
