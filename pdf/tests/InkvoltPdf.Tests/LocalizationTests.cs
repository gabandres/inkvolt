using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Tests;

/// <summary>
/// Inkvolt PDF's Spanish interface: the language it picks, and the resources both languages come from (the app's
/// Strings.resx and Core's PdfStrings.resx, each with its .es.resx).
/// </summary>
public partial class LocalizationTests
{
    public static TheoryData<string> ResourcePairs => new()
    {
        "pdf/src/InkvoltPdf.App/Strings.resx",
        "pdf/src/InkvoltPdf.Core/PdfStrings.resx",
    };

    [Theory]
    [InlineData(true, true, null, null, "es-PR", "es")] // Same as Windows: any Spanish
    [InlineData(true, true, null, null, "es-419", "es")]
    [InlineData(true, true, null, null, "pt-BR", "pt-BR")] // Same as Windows: exact pt-BR only
    [InlineData(true, true, null, null, "pt-PT", "en")]
    [InlineData(true, true, null, null, "en-US", "en")]
    [InlineData(true, true, null, null, "fr-FR", "en")]
    [InlineData(true, true, null, "es", "en-US", "es")] // the saved choice beats Windows
    [InlineData(true, true, null, "pt-BR", "en-US", "pt-BR")]
    [InlineData(true, true, null, "en", "es-ES", "en")]
    [InlineData(true, true, "en", "es", "es-MX", "en")] // --lang beats both
    [InlineData(true, true, "pt-BR", "es", "en-US", "pt-BR")]
    [InlineData(true, true, "xx", null, "es-MX", "es")] // an unknown --lang is ignored
    [InlineData(false, true, null, null, "es-ES", "en")] // not ready: a Spanish Windows stays English
    [InlineData(false, true, null, "es", "es-ES", "en")] // not ready: a saved choice is ignored
    [InlineData(false, true, "es", null, "en-US", "es")] // not ready: only the dev aid's --lang picks Spanish
    [InlineData(false, true, "xx", "es", "es-ES", "en")]
    [InlineData(true, false, null, null, "pt-BR", "en")]
    [InlineData(true, false, null, "pt-BR", "pt-BR", "en")]
    [InlineData(true, false, "pt-BR", null, "en-US", "pt-BR")]
    public void TheLanguage_FollowsTheDevArgument_ThenTheChoice_ThenWindows(bool spanishReady, bool portugueseReady, string? argument, string? saved, string windows, string expected)
    {
        Assert.Equal(expected, PdfLanguage.Choose(spanishReady, portugueseReady, argument, saved, CultureInfo.GetCultureInfo(windows)).Name);
    }

    [Theory]
    [InlineData("{0} pages", 3, "3 pages")]
    [InlineData("{0} pages {1}", 3, "{0} pages {1} (3)")] // a missing value: what the translator wrote, never a crash
    [InlineData("{0 pages", 3, "{0 pages (3)")]
    [InlineData("{1} pages", 3, "{1} pages (3)")]
    public void ABrokenFormat_NeverThrows(string format, int count, string expected)
    {
        var before = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
            Assert.Equal(expected, Loc.Format(format, count));
        }
        finally
        {
            CultureInfo.CurrentCulture = before;
        }
    }

    [Fact]
    public void APlural_PicksOneOrMany_AndTakesTheRegionalFormat()
    {
        var before = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("es-ES");
            Assert.Equal("1 página de x", Loc.Plural(1, "{0} página de {1}", "{0} páginas de {1}", "x"));
            Assert.Equal("1.200 páginas de x", Loc.Plural(1200, "{0:N0} página de {1}", "{0:N0} páginas de {1}", "x"));
            Assert.Equal("0 páginas", Loc.Plural(0, "{0} página", "{0} páginas"));
        }
        finally
        {
            CultureInfo.CurrentCulture = before;
        }
    }

    [Theory]
    [MemberData(nameof(ResourcePairs))]
    public void EveryString_IsInAllLanguages_NonEmpty_WithTheSamePlaceholders(string neutral)
    {
        var english = Read(neutral);
        var translations = new (string Name, Dictionary<string, string> Map)[]
        {
            ("Spanish", Read(neutral.Replace(".resx", ".es.resx"))),
            ("Portuguese (Brazil)", Read(neutral.Replace(".resx", ".pt-BR.resx"))),
        };
        var problems = new List<string>();
        foreach (var (lang, translated) in translations)
        {
            Assert.Empty(english.Keys.Except(translated.Keys)); // missing
            Assert.Empty(translated.Keys.Except(english.Keys)); // left over
            foreach (var (key, en) in english)
            {
                var tr = translated[key];
                if (string.IsNullOrWhiteSpace(en) || string.IsNullOrWhiteSpace(tr))
                {
                    problems.Add($"{lang} {key}: empty in {(string.IsNullOrWhiteSpace(en) ? "English" : lang)}");
                    continue;
                }
                if (!Placeholders(en).SequenceEqual(Placeholders(tr)))
                    problems.Add($"{lang} {key}: placeholders {string.Join(" ", Placeholders(en))} vs {string.Join(" ", Placeholders(tr))}");
                // A separator (" and ", "  ·  ") keeps its spaces in both languages.
                if (char.IsWhiteSpace(en[0]) != char.IsWhiteSpace(tr[0]) || char.IsWhiteSpace(en[^1]) != char.IsWhiteSpace(tr[^1]))
                    problems.Add($"{lang} {key}: spaces at the ends differ between English and {lang}");
                // string.Format must accept both, whatever their format specifiers ({0:t}, {0:N0}).
                var args = Enumerable.Range(0, 10).Select(_ => (object)new AnyValue()).ToArray();
                foreach (var text in (string[])[en, tr])
                    if (Placeholders(text).Count > 0)
                        try { _ = string.Format(CultureInfo.InvariantCulture, text, args); }
                        catch (FormatException) { problems.Add($"{lang} {key}: not a valid format string: {text}"); }
            }
        }
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }

    [Theory]
    [MemberData(nameof(ResourcePairs))]
    public void Keys_AreUnique_AndUsableAsNames(string neutral)
    {
        foreach (var path in (string[])[neutral, neutral.Replace(".resx", ".es.resx"), neutral.Replace(".resx", ".pt-BR.resx")])
        {
            var names = XDocument.Load(Path.Combine(Root(), path)).Root!.Elements("data").Select(d => (string)d.Attribute("name")!).ToList();
            Assert.Equal(names.Count, names.Distinct().Count());
            Assert.All(names, n => Assert.Matches("^[A-Za-z_][A-Za-z0-9_]*$", n));
        }
    }

    [Fact]
    public void Core_IsEnglishUnlessTheAppOptsIn_WhateverTheThreadsLanguage()
    {
        // The command line never opts in, so a Spanish Windows doesn't change what scripts read.
        var before = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = UiLanguage.Spanish;
            Assert.Equal("1 setting changed since Settings opened", PdfStrings.Settings_SummaryOne);
        }
        finally
        {
            CultureInfo.CurrentUICulture = before;
        }
    }

    [Fact]
    public void Translations_ComeFromTheSatelliteAssemblies()
    {
        Assert.Equal("1 opción cambió desde que se abrió Configuración",
            PdfStrings.ResourceManager.GetString(nameof(PdfStrings.Settings_SummaryOne), UiLanguage.Spanish));
        Assert.Equal("1 opção alterada desde que Configurações foi aberto",
            PdfStrings.ResourceManager.GetString(nameof(PdfStrings.Settings_SummaryOne), UiLanguage.PortugueseBrazil));
    }

    /// <summary>
    /// Translations aren't English left as it was: at most a few strings read the same in both (product names, units, paper
    /// sizes, punctuation-only formats).
    /// </summary>
    [Theory]
    [MemberData(nameof(ResourcePairs))]
    public void Translations_AreTranslated(string neutral)
    {
        var english = Read(neutral);
        foreach (var suffix in (string[])[".es.resx", ".pt-BR.resx"])
        {
            var translated = Read(neutral.Replace(".resx", suffix));
            var same = english.Where(e => e.Value == translated[e.Key] && e.Value.Count(char.IsLetter) > 3
                                          && !e.Value.Contains("Inkvolt", StringComparison.Ordinal)).Select(e => e.Key).ToList();
            Assert.True(same.Count <= 25, $"{suffix}: {same.Count} strings left in English: {string.Join(", ", same)}");
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
