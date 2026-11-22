using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Spell check where people type (roadmap 4.1): what is looked up, what is underlined, and what Ignore, Add to dictionary
/// and a suggestion do. A word list stands in for Windows' spell checker.
/// </summary>
public class SpellCheckerTests
{
    private sealed class WordList(params string[] words) : ISpellingDictionary
    {
        private readonly HashSet<string> _words = new(words, StringComparer.OrdinalIgnoreCase);
        public List<string> Added { get; } = [];
        public int Lookups { get; private set; }
        public bool Refuses { get; init; }
        public string Language => "en-US";

        public bool IsKnown(string word)
        {
            Lookups++;
            return _words.Contains(word);
        }

        public IReadOnlyList<string> Suggest(string word) => [.. _words.Where(w => w.Length == word.Length && w[0] == char.ToLowerInvariant(word[0])).Append(word).Order()];

        public bool Add(string word)
        {
            if (Refuses) return false;
            Added.Add(word);
            return _words.Add(word);
        }
    }

    private static List<string> Looked(string text, bool skipAllCaps = true) =>
        [.. SpellChecker.Words(text, skipAllCaps).Select(w => text.Substring(w.Start, w.Length))];

    [Fact]
    public void WordsAreLettersWithApostrophesInside()
    {
        Assert.Equal(["Don't", "worry", "it's", "well", "known", "año"], Looked("Don't worry, it's well-known (año)."));
        Assert.Equal(["rock", "roll"], Looked("rock ’n’ roll"));
        Assert.Equal(["l'été"], Looked("«l'été»"));
    }

    [Theory]
    [InlineData("A4 2nd 10mm MP3 COVID-19 1,234.50")] // digits
    [InlineData("a I x")] // single letters
    [InlineData("NASA UNESCO")] // capitals: an acronym
    [InlineData("https://example.com/path www.inkvolt.app mail@example.com example.com C:\\Users\\me\\file.pdf ./notes and/or")]
    [InlineData("— € … ¿¡ \uFFFC")]
    public void NumbersAddressesAcronymsAndSymbolsAreLeftAlone(string text) => Assert.Empty(Looked(text));

    [Fact]
    public void CapitalsAreLookedUpWhenAsked() => Assert.Equal(["NASA"], Looked("NASA", skipAllCaps: false));

    [Fact]
    public void AnOverlongRunIsNoWord() => Assert.Empty(Looked(new string('x', SpellChecker.MaxWordLength + 1)));

    [Fact]
    public void AHugeTextIsLookedUpOnlyThatFar()
    {
        var text = string.Join(' ', Enumerable.Repeat("word", SpellChecker.MaxWords * 3));
        Assert.Equal(SpellChecker.MaxWords, SpellChecker.Words(text).Count());
    }

    [Fact]
    public void MisspellingsAreTheUnknownWordsWithTheirPlace()
    {
        var check = new SpellChecker(new WordList("the", "quick", "fox", "jumps"));
        var found = check.Check("The quikc fox jumsp, NASA said.");
        Assert.Equal([new Misspelling(4, "quikc"), new Misspelling(14, "jumsp"), new Misspelling(26, "said")], found);
        Assert.Equal(new Misspelling(4, "quikc"), SpellChecker.At(found, 9)); // the caret just after the word
        Assert.Null(SpellChecker.At(found, 11));
    }

    [Fact]
    public void AWordIsLookedUpOnce()
    {
        var words = new WordList("fine");
        var check = new SpellChecker(words);
        check.Check("fine fine wrng wrng");
        check.Check("fine wrng");
        Assert.Equal(2, words.Lookups);
    }

    [Fact]
    public void IgnoreLastsForTheSession()
    {
        var check = new SpellChecker(new WordList("hello"));
        Assert.Single(check.Check("hello Inkvolt"));
        Assert.False(check.IsIgnored("Inkvolt"));
        check.Ignore("Inkvolt");
        Assert.True(check.IsIgnored("Inkvolt"));
        Assert.Empty(check.Check("Inkvolt hello Inkvolt"));
        Assert.Single(check.Check("inkvolt")); // as written: another spelling is another word
    }

    [Fact]
    public void AddToDictionaryTeachesTheUsersDictionary()
    {
        var words = new WordList("hello");
        var check = new SpellChecker(words);
        Assert.Single(check.Check("Inkvolt"));
        Assert.True(check.Add("Inkvolt"));
        Assert.Equal(["Inkvolt"], words.Added);
        Assert.Empty(check.Check("Inkvolt"));
        Assert.Empty(new SpellChecker(words).Check("Inkvolt")); // the dictionary has it, not only this checker
    }

    [Fact]
    public void AWordTheDictionaryRefusesStaysUnderlined()
    {
        var check = new SpellChecker(new WordList("hello") { Refuses = true });
        Assert.False(check.Add("Inkvolt"));
        Assert.Single(check.Check("Inkvolt"));
    }

    [Fact]
    public void SuggestionsLeaveTheWordOutAndStopAtFive()
    {
        var check = new SpellChecker(new WordList("cart", "card", "care", "cars", "cast", "cash", "cats"));
        var s = check.Suggestions("cazt");
        Assert.Equal(SpellChecker.MaxSuggestions, s.Count);
        Assert.DoesNotContain("cazt", s);
    }

    [Fact]
    public void ASuggestionReplacesTheWordOnlyWhereItStillIs()
    {
        var m = new Misspelling(4, "quikc");
        Assert.Equal("The quick fox", SpellChecker.Correct("The quikc fox", m, "quick"));
        Assert.Null(SpellChecker.Correct("The quick fox", m, "quick")); // typed over since
        Assert.Null(SpellChecker.Correct("The", m, "quick"));
    }

    [Fact]
    public void TheDocumentsLanguageComesFirstThenTheInterfacesInWindowsRegion()
    {
        Assert.Equal(["fr-CA", "es-MX", "en-US"], SpellChecker.Languages("fr-CA", "es", "es-MX"));
        Assert.Equal(["es-ES", "en-GB", "en-US"], SpellChecker.Languages(null, "es", "en-GB"));
        Assert.Equal(["en-GB", "en-US"], SpellChecker.Languages("", "en", "en-GB"));
        Assert.Equal(["en-US", "de-DE"], SpellChecker.Languages("en-us", "en", "de-DE"));
    }

    [Theory]
    [InlineData("x-klingon-and-more-than-thirty-five-chars")]
    [InlineData("en US")]
    [InlineData("<script>")]
    [InlineData("123")]
    public void AHostileLanguageTagIsLeftOut(string tag) => Assert.Equal(["en-US"], SpellChecker.Languages(tag, "en", "en-US"));

    [Fact]
    public void TheDocumentSaysItsLanguage()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R /Lang (es-MX) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ]);
        Assert.Equal("es-MX", SpellChecker.DocumentLanguage(pdf, null));
        Assert.Null(SpellChecker.DocumentLanguage(TestPdf.Make(1), null));
        Assert.Null(SpellChecker.DocumentLanguage([1, 2, 3], null));
    }
}
