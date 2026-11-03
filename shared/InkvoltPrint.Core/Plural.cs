using System.Globalization;

namespace InkvoltPrint.Core;

/// <summary>
/// A count in a sentence, from two resource strings: one for exactly one ("{0} page", "{0} página") and one for every
/// other number ("{0} pages", "{0} páginas"), which is the rule in both English and Spanish. The number takes the
/// regional format, as the rest of the interface's numbers.
/// </summary>
public static class Plural
{
    public static string Of(long count, string one, string many) =>
        string.Format(CultureInfo.CurrentCulture, count == 1 ? one : many, count);

    /// <summary>The same with more values after the count ({1}, {2}…).</summary>
    public static string Of(long count, string one, string many, params object?[] more) =>
        string.Format(CultureInfo.CurrentCulture, count == 1 ? one : many, [count, .. more]);
}
