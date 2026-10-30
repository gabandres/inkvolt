using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Tests;

/// <summary>
/// Suspect words (roadmap 2.2): Windows' recognizer gives no per-word confidence, so doubtful words are found by a
/// documented heuristic. A small dictionary stands in for the spell checker.
/// </summary>
public class SuspectWordsTests
{
    private sealed class Dictionary(params string[] words) : ISpelling
    {
        private readonly HashSet<string> _words = new(words, StringComparer.OrdinalIgnoreCase);
        public string Language => "en-US";
        public bool IsKnown(string word) => _words.Contains(word);
        public IReadOnlyList<string> Suggest(string word) => [];
    }

    private static readonly Dictionary Words = new("the", "river", "invoice", "well", "known", "don't", "año");

    [Theory]
    [InlineData("river")]
    [InlineData("River,")]
    [InlineData("(invoice)")]
    [InlineData("\"the\"")]
    [InlineData("well-known")]
    [InlineData("don't")]
    [InlineData("año.")]
    [InlineData("1,234.50")]
    [InlineData("A4")]
    [InlineData("MP3")]
    [InlineData("2nd")]
    [InlineData("10mm")]
    [InlineData("COVID-19")]
    [InlineData("NASA")] // capitals: an acronym the dictionary needn't know
    [InlineData("—")]
    [InlineData("€")]
    [InlineData("a")] // one letter: nothing to look up
    public void OrdinaryWordsAreNotSuspect(string word) => Assert.Equal(SuspectReasons.None, SuspectWords.Check(word, Words));

    [Theory]
    [InlineData("rlver", SuspectReasons.NotInDictionary)]
    [InlineData("Invoise.", SuspectReasons.NotInDictionary)]
    [InlineData("c0de", SuspectReasons.LettersAndDigits)]
    [InlineData("1O5", SuspectReasons.LettersAndDigits)]
    [InlineData("100O", SuspectReasons.LettersAndDigits)]
    [InlineData("ri|ver", SuspectReasons.OddCharacters)]
    [InlineData("riv;er", SuspectReasons.OddCharacters)]
    [InlineData("|", SuspectReasons.OddCharacters)]
    [InlineData("the�", SuspectReasons.OddCharacters)]
    public void DoubtfulWordsAreSuspect(string word, SuspectReasons expected) => Assert.Equal(expected, SuspectWords.Check(word, Words));

    [Fact]
    public void WithoutADictionaryOnlyTheShapeOfAWordCounts()
    {
        Assert.Equal(SuspectReasons.None, SuspectWords.Check("rlver", null));
        Assert.Equal(SuspectReasons.LettersAndDigits, SuspectWords.Check("he1lo", null));
    }

    [Fact]
    public void AWordReadDifferentlyOnTheScanAsItWasIsSuspectWhenThatReadingIsARealWord()
    {
        OcrWord[] cleaned =
        [
            new("rlver", new RectD(100, 100, 40, 12)),
            new("the", new RectD(150, 100, 20, 12)),
            new("invoice", new RectD(180, 100, 50, 12)),
            new("found", new RectD(240, 100, 40, 12)),
        ];
        OcrWord[] original =
        [
            new("river", new RectD(99, 99, 42, 14)), // a real word where the cleaned page read "rlver"
            new("the", new RectD(149, 99, 22, 14)), // the same
            new("lnvoice", new RectD(179, 99, 52, 14)), // garbled on the scan: the cleaned reading is better
            // nothing at "found": the cleaning found it
        ];
        Assert.Equal([true, false, false, false], SuspectWords.ReadDifferently(cleaned, original, Words));
        Assert.Equal("river", SuspectWords.Alternative(cleaned[0], original));
        Assert.Null(SuspectWords.Alternative(cleaned[1], original));
    }
}
