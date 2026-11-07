using System.Globalization;
using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>The index's words: whatever Find, with case and accents ignored, treats as equal has to file under the same term.</summary>
public class IndexTermsTests
{
    private static List<string> Terms(string text)
    {
        var terms = new List<string>();
        IndexTerms.Read(text, t => terms.Add(t.ToString()));
        return terms;
    }

    [Theory]
    [InlineData("Hello, World", "hello|world")]
    [InlineData("CAFÉ Résumé", "cafe|resume")]
    [InlineData("café", "cafe")]
    [InlineData("ﬁnal oﬃce", "final|office")]
    [InlineData("Straße", "strasse")]
    [InlineData("ｆｕｌｌ１２", "full12")]
    [InlineData("soft­hyphen", "softhyphen")]
    [InlineData("don't stop-now_please", "don|t|stop|now|please")]
    [InlineData("٣٤", "34")]
    public void Words_are_folded(string text, string expected) =>
        Assert.Equal(expected.Split('|'), Terms(text));

    [Fact]
    public void Text_without_spaces_is_filed_as_pairs()
    {
        Assert.Equal(["東京", "京都"], Terms("東京都"));
        Assert.Equal(["東"], Terms("東"));
        Assert.Equal(["東京", "abc", "京都"], Terms("東京 abc 京都"));
        Assert.Equal(["東京", "tower"], Terms("東京tower"));
    }

    [Fact]
    public void A_long_run_is_cut_and_a_query_cut_the_same_way()
    {
        var text = new string('a', 500) + " b";
        var terms = Terms(text);
        Assert.Equal(new string('a', IndexTerms.MaxChars), terms[0]);
        Assert.Equal("b", terms[1]);
        Assert.Equal(new string('a', IndexTerms.MaxChars), IndexTerms.Of(new string('a', 60))[0]);
    }

    /// <summary>
    /// What is filed of a run longer than a term: overlapping pieces, each within a term's length, so any part of the run up to
    /// <see cref="IndexTerms.LookupChars"/> long is inside one of them; bounded by <see cref="IndexTerms.MaxRun"/>.
    /// </summary>
    [Fact]
    public void A_long_run_is_filed_in_overlapping_pieces_up_to_a_bound()
    {
        var run = string.Concat(Enumerable.Range(0, 60).Select(i => (char)('a' + i % 26)));
        var filed = Filed(run + " b");
        Assert.Equal([run[..IndexTerms.MaxChars], run[IndexTerms.PieceStep..], "b"], filed);

        // A hostile run: its first MaxRun units at most, in at most MaxRun / PieceStep + 1 pieces of a term's length at most.
        var hostile = Filed(new string('a', 100_000));
        Assert.True(hostile.Count <= IndexTerms.MaxRun / IndexTerms.PieceStep + 1, $"{hostile.Count} pieces");
        Assert.All(hostile, t => Assert.True(t.Length <= IndexTerms.MaxChars));

        // A page of many long runs (base64-like): every run gives the same bounded pieces, so what is filed is at most twice
        // the text read, never more than 43 terms of 48 characters a run.
        var random = new Random(3);
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        var runs = Enumerable.Range(0, 500).Select(_ => new string(Enumerable.Range(0, 3000).Select(_ => alphabet[random.Next(alphabet.Length)]).ToArray())).ToList();
        var page = Filed(string.Join(' ', runs));
        Assert.True(page.Count <= runs.Count * (IndexTerms.MaxRun / IndexTerms.PieceStep + 1), $"{page.Count} terms");
        Assert.True(page.Sum(t => t.Length) <= runs.Count * 2 * IndexTerms.MaxRun, $"{page.Sum(t => t.Length)} chars");

        // A pair is never split between pieces (Gothic letters, two UTF-16 units each).
        var paired = Filed(string.Concat(Enumerable.Repeat("\U00010330", 40)));
        Assert.Equal(3, paired.Count);
        Assert.All(paired, t => Assert.True(t.Length <= IndexTerms.MaxChars && !char.IsLowSurrogate(t[0]) && !char.IsHighSurrogate(t[^1])));

        // The query side: a long word looks up its start, short enough to sit inside one piece.
        Assert.Equal(run[..IndexTerms.LookupChars], IndexTerms.Lookup(run));
        Assert.Equal("short", IndexTerms.Lookup("short"));
        Assert.True(IndexTerms.LookupChars <= IndexTerms.MaxChars - IndexTerms.PieceStep - 1);
        Assert.False(char.IsHighSurrogate(IndexTerms.Lookup(string.Concat(Enumerable.Repeat("\U00010330", 40)))[^1]));
    }

    /// <summary>Every part of a long run up to a lookup's length is inside a filed piece, wherever it starts.</summary>
    [Fact]
    public void Any_part_of_a_long_run_is_inside_a_piece()
    {
        var run = string.Concat(Enumerable.Range(0, 1000).Select(i => (char)('a' + i * 7 % 26)));
        var filed = Filed(run);
        for (var start = 0; start + IndexTerms.LookupChars <= run.Length; start++)
        {
            var part = IndexTerms.Lookup(run[start..]);
            Assert.True(filed.Any(t => t.Contains(part, StringComparison.Ordinal)), $"{start}");
        }
    }

    private static List<string> Filed(string text)
    {
        var terms = new List<string>();
        IndexTerms.File(text, t => terms.Add(t.ToString()));
        return terms;
    }

    [Fact]
    public void Half_a_surrogate_pair_breaks_a_word_and_breaks_nothing_else()
    {
        Assert.Equal(["ab", "cd"], Terms("ab\uD83Dcd"));
        Assert.Equal(["ab"], Terms("ab\uDC00"));
        Assert.Equal(["a"], Terms("𝐀")); // 𝐀, a mathematical capital A
    }

    [Fact]
    public void A_query_of_only_punctuation_has_no_terms() => Assert.Empty(IndexTerms.Of("+-*/ ... §"));

    /// <summary>
    /// The promise behind the index: letters Find sees as the same (the same sort key, with case and accents ignored) file under
    /// the same term, so a search by index can't lose a page Find would find. Compared as whole words made of the letter,
    /// so ignorable and word-breaking characters show up too. Letters that are one letter but not to the Unicode tables are
    /// listed in <c>IndexTerms.Fold</c>.
    /// </summary>
    [Fact]
    public void Letters_Find_treats_as_the_same_have_one_term()
    {
        var ci = CultureInfo.InvariantCulture.CompareInfo;
        const CompareOptions options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
        var groups = new Dictionary<string, List<int>>();
        for (var cp = 0x20; cp < 0xFFFF; cp++)
        {
            if (cp is >= 0xD800 and <= 0xF8FF) continue; // surrogates, private use
            var category = CharUnicodeInfo.GetUnicodeCategory(cp);
            if (category is not (UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
                or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber))
                continue;
            if (cp is >= 0x3400 and <= 0x9FFF or >= 0xAC00 and <= 0xD7A3 or >= 0xA000 and <= 0xA4CF) continue; // ideographs, syllables, Yi: each its own
            var key = Convert.ToHexString(ci.GetSortKey(char.ConvertFromUtf32(cp), options).KeyData);
            if (key.Length == 0) continue; // ignorable to Find
            if (!groups.TryGetValue(key, out var group)) groups[key] = group = [];
            group.Add(cp);
        }

        var lost = new List<string>();
        foreach (var group in groups.Values.Where(g => g.Count > 1))
        {
            var folds = group.GroupBy(cp => string.Join("|", Terms(char.ConvertFromUtf32(cp)))).ToList();
            if (folds.Count > 1)
                lost.Add(string.Join("  ", folds.Select(f => $"[{f.Key}]: {string.Concat(f.Take(6).Select(cp => $"{char.ConvertFromUtf32(cp)} U+{cp:X4} "))}")));
        }
        Assert.True(lost.Count == 0, $"{lost.Count} groups of letters Find reads alike file apart:\n{string.Join('\n', lost.Take(120))}");
    }

    [Theory]
    [InlineData("Ærøskøbing", "aeroskobing")]
    [InlineData("Œuvre", "oeuvre")]
    [InlineData("Łódź", "lodz")]
    [InlineData("Đà Nẵng", "da nang")]
    [InlineData("ΣΊΣΥΦΟΣ", "σίσυφος")]
    [InlineData("Ñandú", "nandu")]
    [InlineData("Ñ", "n")]
    public void Find_agrees_and_so_does_the_index(string page, string query)
    {
        // What Find does on the page, with case and accents ignored...
        Assert.NotEmpty(PageText.FindIn(page, query, matchCase: false, wholeWord: false, ignoreAccents: true));
        // ...the index proposes the page for.
        var pageTerms = Terms(page);
        foreach (var term in IndexTerms.Of(query))
            Assert.Contains(pageTerms, t => t.Contains(term, StringComparison.Ordinal));
    }
}
