using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using Xunit;

namespace InkvoltPdf.Tests;

/// <summary>
/// Translate's looks markup against crafted pages and crafted replies (the hostile-input review before 1.10): no tag of
/// ours reaches a page, and marking or reading stays linear. Alone: processor-time limits that other tests inflate.
/// </summary>
[Collection(Timing.Alone)]
public class TranslationMarkupHostileTests
{
    private static readonly TextLook B = new(Bold: true);
    private static readonly TextLook I = new(Italic: true);
    private static readonly TextLook Sub = new(Script: TextScript.Sub);

    private static readonly Regex OurTag = new(@"<\s*/?\s*(?:b|i|span|sub|sup)\s*>", RegexOptions.IgnoreCase);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Random_replies_never_leave_a_tag_of_ours_in_the_text(bool boldParagraph)
    {
        const string text = "The quick brown fox jumps over d model and the lazy dog.";
        // A regular word in a bold paragraph is marked the other way round: its bold around the rest.
        var face = boldParagraph ? new TextLook(Bold: false) : B;
        TextSpan[] spans = [new(10, 5, face), new(33, 5, Sub), new(43, 3, I), new(20, 5, new TextLook(Color: 0xFF0000))];
        string[] bits = ["<", ">", "/", "b", "i", "sub", "sup", "span", " ", "x", "<b>", "</b>", "<i>", "</i>", "<sub>", "</sub>", "<sup>", "</sup>", "<span>", "</span>", "B", "!", "=", "1"];
        var random = new Random(1234);
        for (var n = 0; n < 50_000; n++)
        {
            var sb = new StringBuilder();
            var count = random.Next(1, 14);
            for (var k = 0; k < count; k++) sb.Append(bits[random.Next(bits.Length)]);
            var reply = sb.ToString();
            var (got, _) = TranslationMarkup.Read(reply, text, spans);
            Assert.False(OurTag.IsMatch(got), $"{reply} -> {got}");
        }
    }

    [Fact]
    public void A_huge_paragraph_with_brackets_of_its_own_is_checked_quickly()
    {
        // Whether its own brackets could be read as tags is one pass over it, however many there are.
        var text = string.Concat(Enumerable.Repeat("a < 0.5 -> c ", 150_000));
        var watch = new ThreadClock.Stopwatch();
        watch.Start();
        var marked = TranslationMarkup.Mark(text, [new TextSpan(0, 1, B)]);
        Assert.True(watch.Elapsed < TimeSpan.FromMilliseconds(1500), $"{watch.Elapsed.TotalMilliseconds:F0} ms");
        Assert.StartsWith("<b>a</b> < 0.5", marked, StringComparison.Ordinal);
    }

    [Fact]
    public void Pieces_of_marked_text_each_close_their_tags_and_a_cut_inside_a_tag_gives_none()
    {
        var text = string.Join(' ', Enumerable.Repeat("A <b>long bold stretch of words</b> and <sup>2</sup> more.", 60));
        var pieces = TranslationMarkup.Pieces(text, 60)!;
        Assert.True(pieces.Count > 3);
        // Each piece is markup of its own, and the pieces together say what the whole did.
        Assert.All(pieces, p => Assert.Equal(Regex.Matches(p, "<b>").Count, Regex.Matches(p, "</b>").Count));
        Assert.Equal(TranslationMarkup.Plain(text), TranslationMarkup.Plain(string.Join(' ', pieces)));
        // No space to cut at: a cut lands inside a tag, and the text goes in plain pieces instead.
        Assert.Null(TranslationMarkup.Pieces(string.Concat(Enumerable.Repeat("<b>x</b><sub>y</sub>", 200)), 20));
    }

    [Fact]
    public void A_huge_paragraph_with_many_looks_is_marked_quickly()
    {
        // A crafted page: one paragraph of 4 million characters, 256 looks over all of it.
        var text = new string('a', 4_000_000);
        var spans = new List<TextSpan>();
        for (var k = 0; k < 256; k++) spans.Add(new TextSpan(0, text.Length, k % 3 == 0 ? Sub : k % 3 == 1 ? B : I));
        var watch = new ThreadClock.Stopwatch();
        watch.Start();
        TranslationMarkup.Mark(text, spans);
        Assert.True(watch.Elapsed < TimeSpan.FromMilliseconds(750), $"{watch.Elapsed.TotalMilliseconds:F0} ms");
    }

    [Fact]
    public void Overlapping_looks_are_marked_as_they_lay_over_each_other()
    {
        // Bold and italic where any span gives them, the latest span's script: the same markup as the looks laid out one by one.
        TextLook[] looks = [B, I, Sub, new(Script: TextScript.Super), new(Bold: true, Script: TextScript.Sub), new(Italic: true, Script: TextScript.Super), new(Color: 0xFF0000)];
        var random = new Random(77);
        for (var n = 0; n < 5_000; n++)
        {
            var text = new string('a', random.Next(1, 40));
            var spans = new List<TextSpan>();
            for (var k = random.Next(1, 6); k > 0; k--) spans.Add(new TextSpan(random.Next(-3, text.Length + 3), random.Next(0, 20), looks[random.Next(looks.Length)]));
            Assert.Equal(TranslationMarkup.Mark(text, OneByOne(text.Length, spans)), TranslationMarkup.Mark(text, spans));
        }
    }

    /// <summary>The spans' looks laid over each other character by character, as disjoint spans.</summary>
    private static List<TextSpan> OneByOne(int length, List<TextSpan> spans)
    {
        var at = new (bool Bold, bool Italic, bool Other, TextScript? Script)[length];
        foreach (var s in spans)
            for (var i = Math.Max(0, s.Start); i < Math.Min(length, s.End); i++)
                at[i] = (at[i].Bold || s.Look.Bold == true, at[i].Italic || s.Look.Italic == true, at[i].Other || s.Look.Color is not null, s.Look.Script ?? at[i].Script);
        var result = new List<TextSpan>();
        for (var i = 0; i < length;)
        {
            var j = i + 1;
            while (j < length && at[j] == at[i]) j++;
            if (at[i] is var (b, it, other, script) && (b || it || other || script is not null))
                result.Add(new TextSpan(i, j - i, new TextLook(Bold: b ? true : null, Italic: it ? true : null, Color: other ? 0xFF0000 : null, Script: script)));
            i = j;
        }
        return result;
    }

    [Theory]
    [InlineData("<b ")]
    [InlineData("</")]
    [InlineData("< / ")]
    [InlineData("b> ")]
    [InlineData("<b>x</b> ")]
    [InlineData("<<b>b> ")]
    public void A_long_reply_of_tag_pieces_is_read_quickly(string unit)
    {
        // The longest answer a 100,000-character paragraph may get (400 + 12 × its length).
        var sb = new StringBuilder();
        while (sb.Length < 1_200_000) sb.Append(unit);
        var reply = sb.ToString();
        var text = "word " + new string('x', 100);
        TextSpan[] spans = [new(0, 4, B)];
        var watch = new ThreadClock.Stopwatch();
        watch.Start();
        var (got, _) = TranslationMarkup.Read(reply, text, spans);
        Assert.True(watch.Elapsed < TimeSpan.FromMilliseconds(1500), $"{watch.Elapsed.TotalMilliseconds:F0} ms");
        Assert.DoesNotMatch(OurTag, got);
    }
}
