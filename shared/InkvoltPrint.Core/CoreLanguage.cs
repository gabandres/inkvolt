using System.Globalization;
using System.Runtime.CompilerServices;

namespace InkvoltPrint.Core;

/// <summary>
/// The language of the text this library writes for an interface (<see cref="CoreStrings"/>): English unless an app opts in.
/// The command lines (<c>inkvoltprint</c>, whose output scripts parse, and Inkvolt PDF's) never opt in, so they stay
/// English whatever Windows' language; Inkvolt Print and Inkvolt PDF set their interface language here at start-up.
/// </summary>
public static class CoreLanguage
{
    /// <summary>The culture <see cref="CoreStrings"/> reads from: English (the neutral resources) until <see cref="Use"/>.</summary>
    public static CultureInfo Culture => CoreStrings.Culture ?? CultureInfo.InvariantCulture;

    /// <summary>Text from here in <paramref name="culture"/> from now on (Inkvolt Print, before its first window).</summary>
    public static void Use(CultureInfo culture) => CoreStrings.Culture = culture;

#pragma warning disable CA2255 // a library's module initializer on purpose: the default (English) must hold before any caller asks
    [ModuleInitializer]
    internal static void EnglishByDefault() => CoreStrings.Culture ??= CultureInfo.InvariantCulture;
#pragma warning restore CA2255
}
