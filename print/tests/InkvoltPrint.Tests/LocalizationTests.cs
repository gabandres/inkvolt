using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Inkvolt Print's Spanish interface: the language it picks, and the resources both languages come from (the app's
/// Strings.resx and the shared library's CoreStrings.resx, each with its .es.resx).
/// </summary>
public partial class LocalizationTests
{
    public static TheoryData<string> ResourcePairs => new()
    {
        "print/src/InkvoltPrint.App/Strings.resx",
        "shared/InkvoltPrint.Core/CoreStrings.resx",
    };

    [Theory]
    [InlineData("es-ES", "es")]
    [InlineData("es-PR", "es")]
    [InlineData("es-419", "es")]
    [InlineData("es", "es")]
    [InlineData("en-US", "en")]
    [InlineData("en-GB", "en")]
    [InlineData("fr-FR", "en")]
    [InlineData("pt-BR", "en")]
    [InlineData("", "en")] // invariant
    public void SameAsWindows_IsSpanishForAnySpanish_EnglishOtherwise(string windows, string expected)
    {
        Assert.Equal(expected, UiLanguage.Resolve(UiLanguageChoice.Windows, CultureInfo.GetCultureInfo(windows)).Name);
    }

    [Theory]
    [InlineData(UiLanguageChoice.English, "es-PR", "en")]
    [InlineData(UiLanguageChoice.Spanish, "en-US", "es")]
    [InlineData(UiLanguageChoice.Spanish, "fr-FR", "es")]
    public void AChoice_BeatsWindows(UiLanguageChoice choice, string windows, string expected)
    {
        Assert.Equal(expected, UiLanguage.Resolve(choice, CultureInfo.GetCultureInfo(windows)).Name);
    }

    [Theory]
    [InlineData(null, UiLanguageChoice.Windows)]
    [InlineData("", UiLanguageChoice.Windows)]
    [InlineData("en", UiLanguageChoice.English)]
    [InlineData("EN-us", UiLanguageChoice.English)]
    [InlineData("es", UiLanguageChoice.Spanish)]
    [InlineData("es-MX", UiLanguageChoice.Spanish)]
    [InlineData("de", UiLanguageChoice.Windows)] // a language the app isn't written in: follow Windows
    [InlineData("nonsense", UiLanguageChoice.Windows)]
    public void SavedChoice_ReadsBack(string? saved, UiLanguageChoice expected)
    {
        Assert.Equal(expected, UiLanguage.Parse(saved));
        Assert.Equal(expected, UiLanguage.Parse(UiLanguage.Save(expected)));
    }

    [Fact]
    public void Windows_IsSavedAsNothing()
    {
        Assert.Null(UiLanguage.Save(UiLanguageChoice.Windows));
        Assert.Equal("en", UiLanguage.Save(UiLanguageChoice.English));
        Assert.Equal("es", UiLanguage.Save(UiLanguageChoice.Spanish));
    }

    [Theory]
    [InlineData("es", "en", "en-US", "es")] // --lang beats the saved choice
    [InlineData("en", null, "es-ES", "en")]
    [InlineData(null, "es", "en-US", "es")] // no --lang: the saved choice
    [InlineData(null, null, "es-MX", "es")] // neither: Windows
    [InlineData("xx", null, "en-US", "en")] // an unknown --lang is ignored
    public void DevArgument_ThenSaved_ThenWindows(string? argument, string? saved, string windows, string expected)
    {
        Assert.Equal(expected, UiLanguage.Resolve(argument, saved, CultureInfo.GetCultureInfo(windows)).Name);
    }

    [Theory]
    [InlineData("es", "en-US", "es-US")] // Spanish on a US-format PC: Spanish month names, the US's numbers
    [InlineData("en", "es-PR", "en-PR")]
    [InlineData("es", "es-MX", "es-MX")] // the same language: Windows' format as it is
    [InlineData("en", "en-GB", "en-GB")]
    [InlineData("es", "es-419", "es-419")]
    public void Formats_FollowTheRegion_InTheInterfacesLanguage(string ui, string regional, string expected)
    {
        Assert.Equal(expected, UiLanguage.FormatCulture(CultureInfo.GetCultureInfo(ui), CultureInfo.GetCultureInfo(regional)).Name);
    }

    [Fact]
    public void Formats_KeepTheRegion_WhenTheLanguageHasNoCultureThere()
    {
        var regional = CultureInfo.GetCultureInfo("ja-JP");
        Assert.Same(regional, UiLanguage.FormatCulture(UiLanguage.Spanish, regional));
    }

    [Theory]
    [MemberData(nameof(ResourcePairs))]
    public void EveryString_IsInBothLanguages_NonEmpty_WithTheSamePlaceholders(string neutral)
    {
        var english = Read(neutral);
        var spanish = Read(neutral.Replace(".resx", ".es.resx"));
        Assert.Empty(english.Keys.Except(spanish.Keys)); // missing in Spanish
        Assert.Empty(spanish.Keys.Except(english.Keys)); // left over in Spanish
        var problems = new List<string>();
        foreach (var (key, en) in english)
        {
            var es = spanish[key];
            if (string.IsNullOrWhiteSpace(en) || string.IsNullOrWhiteSpace(es))
            {
                problems.Add($"{key}: empty in {(string.IsNullOrWhiteSpace(en) ? "English" : "Spanish")}");
                continue;
            }
            if (!Placeholders(en).SequenceEqual(Placeholders(es)))
                problems.Add($"{key}: placeholders {string.Join(" ", Placeholders(en))} vs {string.Join(" ", Placeholders(es))}");
            // A separator (" and ", "  ·  last known") keeps its spaces in both languages.
            if (char.IsWhiteSpace(en[0]) != char.IsWhiteSpace(es[0]) || char.IsWhiteSpace(en[^1]) != char.IsWhiteSpace(es[^1]))
                problems.Add($"{key}: spaces at the ends differ between English and Spanish");
            // string.Format must accept both, whatever their format specifiers ({0:t}, {0:N0}).
            var args = Enumerable.Range(0, 10).Select(_ => (object)new AnyValue()).ToArray();
            foreach (var text in (string[])[en, es])
                if (Placeholders(text).Count > 0)
                    try { _ = string.Format(CultureInfo.InvariantCulture, text, args); }
                    catch (FormatException) { problems.Add($"{key}: not a valid format string: {text}"); }
        }
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }

    [Theory]
    [MemberData(nameof(ResourcePairs))]
    public void Keys_AreUnique_AndUsableAsNames(string neutral)
    {
        foreach (var path in (string[])[neutral, neutral.Replace(".resx", ".es.resx")])
        {
            var names = XDocument.Load(Path.Combine(Root(), path)).Root!.Elements("data").Select(d => (string)d.Attribute("name")!).ToList();
            Assert.Equal(names.Count, names.Distinct().Count());
            Assert.All(names, n => Assert.Matches("^[A-Za-z_][A-Za-z0-9_]*$", n));
        }
    }

    /// <summary>A value any format specifier accepts.</summary>
    private sealed class AnyValue : IFormattable
    {
        public string ToString(string? format, IFormatProvider? formatProvider) => "x";
        public override string ToString() => "x";
    }

    /// <summary>The placeholders a format string holds ({0}, {1:N0}…), sorted, escaped braces left out.</summary>
    internal static List<string> Placeholders(string text) =>
        [.. PlaceholderPattern().Matches(text.Replace("{{", "").Replace("}}", "")).Select(m => m.Value).Order(StringComparer.Ordinal)];

    [GeneratedRegex(@"\{\d+(,-?\d+)?(:[^}]*)?\}")]
    private static partial Regex PlaceholderPattern();

    internal static Dictionary<string, string> Read(string relative) =>
        XDocument.Load(Path.Combine(Root(), relative)).Root!.Elements("data")
            .ToDictionary(d => (string)d.Attribute("name")!, d => (string?)d.Element("value") ?? "");

    internal static string Root()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("Inkvolt.slnx not found above the test folder");
    }
}
