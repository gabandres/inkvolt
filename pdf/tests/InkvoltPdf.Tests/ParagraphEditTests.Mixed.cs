using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 2.1: paragraphs from other software that mix faces of one family (a bold word in Word's PDFs) edit as one.</summary>
public partial class ParagraphEditTests
{
    /// <summary>Body as a left-aligned paragraph in /FA with <paramref name="word"/> drawn in <paramref name="face"/> ("FB": Arial Bold, "FT": Times), a line under it.</summary>
    private static byte[] WithFace(string word, string face)
    {
        var lines = Wrap(Body, Width);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td");
        for (var i = 0; i < lines.Count; i++)
        {
            if (i > 0) sb.Append(" T*");
            var at = lines[i].IndexOf(word, StringComparison.Ordinal);
            if (at < 0) sb.Append($" ({lines[i]}) Tj");
            else sb.Append($" ({lines[i][..at]}) Tj /{face} {N(Size)} Tf ({word}) Tj /FA {N(Size)} Tf ({lines[i][(at + word.Length)..]}) Tj");
        }
        sb.Append(" 0 -60 Td (Next block starts here) Tj ET");
        return ContentEditPdf.Make(sb.ToString(), fontText: Chars, faces: true);
    }

    [Fact]
    public void AParagraphWithABoldWordOfItsOwnFamilyIsOneParagraphWithASpan()
    {
        var pdf = WithFace("boxing", "FB");
        var before = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal(Body, p.Text);
        var boldRun = before.Runs.Single(r => r.Text == "boxing");
        Assert.True(boldRun.Bold);
        Assert.False(p.Lead.Bold);
        AssertSpans([Span(Body, "boxing", new TextLook(Bold: true))], p.Spans);
        var next = before.Runs.Single(r => r.Text == "Next block starts here");

        // Rewritten with words in front, the word moves along and stays bold, drawn in the PDF's own bold font.
        var text = "Now then " + Body;
        var check = p.Check(text);
        Assert.Empty(check.Missing);
        Assert.Empty(check.Faces); // nothing from this PC: the page has the face
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        Assert.Contains(Words(text), Words(Regex.Replace(ContentEditPdf.Text(edited), "Next block starts here", "")));
        var q = Body0(edited, "Now then");
        Assert.Null(q.Blocked);
        Assert.Equal(text, q.Text);
        AssertSpans([Span(text, "boxing", new TextLook(Bold: true))], q.Spans);
        var bold2 = q.Runs.Single(r => r.Text.Trim() == "boxing");
        Assert.True(bold2.Bold);
        Assert.Equal(boldRun.FontName, bold2.FontName);
        Assert.Equal(p.Lead.FontName, q.Lead.FontName);
        var next2 = ContentEditor.Read(edited, null, 0).Runs.Single(r => r.Text == "Next block starts here");
        Assert.Equal(next.Box.Y, next2.Box.Y, 2);
        Assert.Equal(next.FontName, next2.FontName);
    }

    [Fact]
    public void NewBoldTextUsesTheParagraphsOwnBoldFont()
    {
        var pdf = WithFace("boxing", "FB");
        var p = Body0(pdf);
        var boldName = ContentEditor.Read(pdf, null, 0).Runs.Single(r => r.Text == "boxing").FontName;
        var looks = new List<TextSpan> { Span(Body, "boxing", new TextLook(Bold: true)), Span(Body, "quick", new TextLook(Bold: true)), Span(Body, "lazy", new TextLook(Italic: true)) };
        var check = p.Check(Body, looks);
        Assert.Empty(check.Missing);
        Assert.Equal(["Arial Italic"], check.Faces); // the page has no italic face: that one comes from this PC
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, Body, spans: looks);
        var q = Body0(edited);
        AssertSpans(looks, q.Spans);
        var runs = q.Runs.GroupBy(r => r.Text.Trim()).ToDictionary(g => g.Key, g => g.First());
        Assert.Equal(boldName, runs["quick"].FontName);
        Assert.Equal(boldName, runs["boxing"].FontName);
        Assert.Contains("ariali", runs["lazy"].FontName, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(Words(Body), Words(ContentEditPdf.Text(edited)));
    }

    [Fact]
    public void AParagraphMixingFamiliesIsEditedLineByLine()
    {
        // A Times word inside a line of Arial: the lines still group, but the paragraph can't be rewritten as one.
        var pdf = WithFace("sphinx", "FT");
        var p = ContentEditor.Read(pdf, null, 0).Paragraphs.Single(q => q.Text.Contains("sphinx", StringComparison.Ordinal));
        Assert.True(p.Lines.Count > 1);
        Assert.NotNull(p.Blocked);
        Assert.Contains("mixes fonts", p.Blocked);
        // A line that begins with the other family doesn't join the lines around it at all.
        var pdf2 = WithFace("boxing", "FT");
        var alone = ContentEditor.Read(pdf2, null, 0).Paragraphs.Single(q => q.Text.StartsWith("boxing", StringComparison.Ordinal));
        Assert.Single(alone.Lines);
        Assert.NotNull(alone.Blocked);
    }
}
