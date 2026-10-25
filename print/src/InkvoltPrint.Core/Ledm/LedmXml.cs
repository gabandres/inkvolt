using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

/// <summary>Namespace-agnostic XML helpers. LEDM namespaces drift across firmware, local names don't.</summary>
internal static class LedmXml
{
    public static IEnumerable<XElement> All(this XContainer c, string localName) =>
        c.Descendants().Where(e => e.Name.LocalName == localName);

    public static IEnumerable<XElement> Kids(this XContainer c, string localName) =>
        c.Elements().Where(e => e.Name.LocalName == localName);

    public static XElement? Kid(this XContainer c, string localName) => c.Kids(localName).FirstOrDefault();

    public static string? KidValue(this XContainer c, string localName) => NonEmpty(c.Kid(localName)?.Value);

    public static string? FirstValue(this XContainer c, string localName) => NonEmpty(c.All(localName).FirstOrDefault()?.Value);

    public static int? ToInt(this string? s) => int.TryParse(s, out var i) ? i : null;

    private static string? NonEmpty(string? s) => s?.Trim() is { Length: > 0 } t ? t : null;
}
