using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Paragraph editing, part c (roadmap 2.1): font, size, color, bold and italic for stretches of a paragraph.</summary>
public partial class ParagraphEditTests
{
    private static TextSpan Span(string text, string word, TextLook look)
    {
        var at = text.IndexOf(word, StringComparison.Ordinal);
        Assert.True(at >= 0, word);
        return new TextSpan(at, word.Length, look);
    }

    /// <summary>"quick" bold, "brown" italic and red, "fox" at 16 pt, "lazy dog" in Times New Roman.</summary>
    private static List<TextSpan> Looks(string text) =>
    [
        Span(text, "quick", new TextLook(Bold: true)),
        Span(text, "brown", new TextLook(Italic: true, Color: 0xCC0000)),
        Span(text, "fox", new TextLook(Size: 16)),
        Span(text, "lazy dog", new TextLook(Font: "Times New Roman")),
    ];

    private static void AssertSpans(IReadOnlyList<TextSpan> expected, IReadOnlyList<TextSpan> actual) =>
        Assert.Equal(expected.OrderBy(s => s.Start).Select(s => (s.Start, s.Length, s.Look)), actual.OrderBy(s => s.Start).Select(s => (s.Start, s.Length, s.Look)));

    [Fact]
    public void TheLookBarListsEveryInstalledFamily()
    {
        var fonts = ContentEditor.LookFonts();
        Assert.Contains("Arial", fonts);
        Assert.Contains("Times New Roman", fonts);
        // Beyond the 14 common families: whatever Windows lists (Comic Sans MS and Impact ship with every Windows).
        Assert.Contains("Comic Sans MS", fonts);
        Assert.Contains("Impact", fonts);
        Assert.Equal(fonts.Order(StringComparer.OrdinalIgnoreCase), fonts);
        Assert.Equal(fonts.Distinct(StringComparer.OrdinalIgnoreCase).Count(), fonts.Count);
        Assert.DoesNotContain(fonts, f => f.EndsWith(" Bold", StringComparison.Ordinal) || f.EndsWith(" Italic", StringComparison.Ordinal) || f.EndsWith(" Regular", StringComparison.Ordinal));
    }

    [Fact]
    public void ALookInAFamilyBeyondTheFourteenDrawsInIt()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 120);
        var p = Body0(pdf);
        var looks = new List<TextSpan>
        {
            Span(Body, "lazy dog", new TextLook(Font: "Comic Sans MS")),
            Span(Body, "wizards", new TextLook(Font: "Comic Sans MS", Bold: true)),
            Span(Body, "sphinx", new TextLook(Font: "No Such Family")),
        };
        var check = p.Check(Body, looks);
        Assert.Null(check.LookProblem);
        Assert.Empty(check.Missing);
        // A family not installed falls back to the closest installed font, named as such.
        Assert.Equal(["Comic Sans MS", "Comic Sans MS Bold", "Arial"], check.Faces);

        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, Body, spans: looks);
        Assert.Equal(Words(Body), Words(Regex.Replace(ContentEditPdf.Text(edited), "A Heading Here|Next block starts here", "")));
        var q = Body0(edited);
        AssertSpans(looks, q.Spans);
        var runs = q.Runs.GroupBy(r => r.Text.Trim()).ToDictionary(g => g.Key, g => g.First());
        Assert.Contains("comic", runs["lazy dog"].FontName, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("comicbd", runs["wizards"].FontName, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AStretchGetsItsOwnFontSizeColorBoldAndItalic()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 120);
        var p = Body0(pdf);
        var next = ContentEditor.Read(pdf, null, 0).Runs.Single(r => r.Text == "Next block starts here");
        var looks = Looks(Body);
        looks.Add(Span(Body, " boxin", new TextLook(Italic: true)));
        var check = p.Check(Body, looks);
        Assert.Null(check.LookProblem);
        Assert.Empty(check.Missing);
        Assert.Equal(["Arial Bold", "Arial Italic", "Times New Roman"], check.Faces);

        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, Body, spans: looks);
        Assert.Equal(Words(Body), Words(Regex.Replace(ContentEditPdf.Text(edited), "A Heading Here|Next block starts here", "")));
        var q = Body0(edited);
        Assert.Null(q.Blocked);
        Assert.Equal(Body, q.Text);
        Assert.Equal(p.Lead.FontName, q.Lead.FontName);
        // A space at a line's end isn't drawn: its look goes with it.
        AssertSpans([.. looks.SkipLast(1), Span(Body, "boxin", new TextLook(Italic: true))], q.Spans);
        // Read back, the same text and looks lay out as they are.
        var same = q.Check(q.Text, q.Spans);
        Assert.Equal(q.Lines.Count, same.LineCount);
        Assert.Null(same.Overlaps);
        var runs = q.Runs.GroupBy(r => r.Text.Trim()).ToDictionary(g => g.Key, g => g.First());
        Assert.Contains("arialbd", runs["quick"].FontName, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ariali", runs["boxin"].FontName, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0xCC0000, runs["brown"].Color);
        Assert.Equal(16, runs["fox"].FontSize, 1);
        Assert.Equal(p.Lead.FontName, runs["fox"].FontName);
        Assert.Contains("times", runs["lazy dog"].FontName, StringComparison.OrdinalIgnoreCase); // one stretch, one operator
        // The rest keeps the paragraph's own color and size; the lines don't run into each other; what follows stays.
        Assert.All(q.Runs.Where(r => r.Text.Trim() is not ("brown" or "fox")), r => Assert.Equal(p.Lead.Color, r.Color));
        for (var i = 1; i < q.Lines.Count; i++) Assert.True(q.Lines[i].Y >= q.Lines[i - 1].Bottom - 1, $"line {i}");
        Assert.True(q.Lines[0].Y >= p.Box.Y - 0.5, "the first line stays inside the box's top");
        var next2 = ContentEditor.Read(edited, null, 0).Runs.Single(r => r.Text == "Next block starts here");
        Assert.Equal(next.Box.Y, next2.Box.Y, 2);
        Assert.Equal(p.Lead.Color, next2.Color);
        Assert.Equal(p.FontSize, next2.FontSize, 2);
        Assert.Equal(p.Lead.FontName, next2.FontName);
    }

    [Fact]
    public void TypingAgainKeepsTheLooksOfWhatDidntChange()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 120);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, Body0(pdf), Body, spans: Looks(Body));
        var q = Body0(edited);
        // Text typed without looks: the stretches around the change keep theirs.
        var text = q.Text.Replace("jumps", "leaps high", StringComparison.Ordinal) + " and more words at the end";
        var again = ContentEditor.ReplaceParagraph(edited, null, q, text);
        var r = Body0(again);
        Assert.Equal(text, r.Text);
        AssertSpans(Looks(text), r.Spans);
        // The same text and looks: nothing to write.
        Assert.Same(again, ContentEditor.ReplaceParagraph(again, null, r, r.Text));
    }

    [Fact]
    public void TheLooksAloneCanChangeAndBeTakenOff()
    {
        var (pdf, _) = Page(ParagraphAlign.Justified, gap: 120);
        var p = Body0(pdf);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, Body, spans: [Span(Body, "black quartz", new TextLook(Bold: true, Size: 13))]);
        var q = Body0(edited);
        Assert.Equal(ParagraphAlign.Justified, q.Align);
        Assert.All(q.Lines.Take(q.Lines.Count - 1), l => Assert.Equal(p.Box.Right, l.Right, 0));
        AssertSpans([Span(Body, "black quartz", new TextLook(Bold: true, Size: 13))], q.Spans);
        // Taken off: plain again, at the old line step.
        var plain = ContentEditor.ReplaceParagraph(edited, null, q, q.Text, spans: []);
        var r = Body0(plain);
        Assert.Empty(r.Spans);
        Assert.All(r.Runs, run => Assert.Equal(p.Lead.FontName, run.FontName));
        Assert.Equal(p.LineStep, r.LineStep, 1);
        Assert.Equal(p.Lines.Count, r.Lines.Count);
    }

    [Theory]
    [InlineData(ParagraphAlign.Left)]
    [InlineData(ParagraphAlign.Justified)]
    public void AllOfItInAnotherFontIsStillOneParagraphDrawnALineAtATime(ParagraphAlign align)
    {
        var (pdf, lines) = Page(align, gap: 120);
        var p = Body0(pdf);
        var georgia = new TextLook(Font: "Georgia");
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, Body, spans: [new TextSpan(0, Body.Length, georgia)]);
        var q = Body0(edited);
        Assert.Null(q.Blocked);
        Assert.Equal(align, q.Align);
        AssertSpans([new TextSpan(0, Body.Length, georgia)], q.Spans);
        // One operator a line (words, spaces and justification together), not one a word.
        Assert.InRange(q.Runs.Count, q.Lines.Count, q.Lines.Count + 1);
        Assert.Equal(Words(Body), Words(Regex.Replace(ContentEditPdf.Text(edited), "A Heading Here|Next block starts here", "")));
        if (align == ParagraphAlign.Justified) Assert.All(q.Lines.Take(q.Lines.Count - 1), l => Assert.Equal(p.Box.Right, l.Right, 0));
        // Edited again: more words, still all Georgia.
        var text = Body + " " + Twenty;
        var again = Body0(ContentEditor.ReplaceParagraph(edited, null, q, text));
        Assert.Equal(text, again.Text);
        AssertSpans([new TextSpan(0, text.Length, georgia)], again.Spans);
    }

    [Fact]
    public void AColorOverASpotInkIsSetBackAfterwardsAndOverAPatternRefused()
    {
        var lines = Wrap(Body, Width);
        string Make(string color)
        {
            var sb = new StringBuilder($"{color} BT /FA {N(Size)} Tf {N(Step)} TL 72 {N(Top)} Td ({lines[0]}) Tj");
            foreach (var l in lines.Skip(1)) sb.Append($" T* ({l}) Tj");
            return sb.Append(" 0 -60 Td (Next block starts here) Tj ET").ToString();
        }
        var spot = ContentEditPdf.Make(Make("/CS0 cs 0.5 scn"), fontText: Chars);
        var looks = new List<TextSpan> { Span(Body, "quick", new TextLook(Color: 0x0000FF)) };
        var edited = ContentEditor.ReplaceParagraph(spot, null, Body0(spot), Body, spans: looks);
        var content = ContentEditPdf.Content(edited);
        Assert.Matches(@"0 0 1 rg[\s\S]*/CS0 cs 0\.5 scn[\s\S]*Next block", content);

        var pattern = ContentEditPdf.Make(Make("/Pattern cs /P1 scn"), fontText: Chars);
        var p = Body0(pattern);
        Assert.NotNull(p.Check(Body, looks).LookProblem);
        Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pattern, null, p, Body, spans: looks));
        // Other looks are fine there.
        ContentEditor.ReplaceParagraph(pattern, null, p, Body, spans: [Span(Body, "quick", new TextLook(Bold: true))]);
    }
}
