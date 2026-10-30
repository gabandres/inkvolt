using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 2.1: hyphenated line ends kept as typed, and the kerning of rewritten lines.</summary>
public partial class ParagraphEditTests
{
    /// <summary>A left-aligned paragraph of the given lines (one text object, T* between them), with a line under it.</summary>
    private static byte[] Lines(IReadOnlyList<string> lines, string fontText = Chars, bool unicode = false)
    {
        var seed = unicode ? ContentEditPdf.Make("", fontText: fontText) : null;
        string Show(string s) => seed is null ? $"({s})" : ContentEditPdf.Cid(seed, s);
        var sb = new StringBuilder($"BT /{(unicode ? "FU" : "FA")} {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td {Show(lines[0])} Tj");
        foreach (var l in lines.Skip(1)) sb.Append($" T* {Show(l)} Tj");
        sb.Append($" 0 -60 Td {Show("Next block starts here")} Tj ET");
        return ContentEditPdf.Make(sb.ToString(), fontText: fontText);
    }

    [Fact]
    public void AHyphenatedLineEndStaysOneWordWhenRewrapped()
    {
        var pdf = Lines(["The quick brown fox is respon-", "sible for the lazy dog and the", "five boxing wizards too"]);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal("The quick brown fox is respon-sible for the lazy dog and the five boxing wizards too", p.Text);
        // Words added in front move the word along: it stays "respon-sible", never split at the hyphen or given a space.
        var text = "Now then " + p.Text;
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        Assert.Contains("respon-sible", Words(ContentEditPdf.Text(edited)));
        Assert.Equal(text, Body0(edited, "Now then").Text);
    }

    [Fact]
    public void ASoftHyphenALineBreakAddedIsDropped()
    {
        // Some generators write the hyphen a line break added as U+00AD (a Unicode font's ToUnicode says so): it isn't part of the word.
        var pdf = Lines(["The quick brown fox is respon­", "sible for the lazy dog and the", "five boxing wizards too"], fontText: Chars + "­", unicode: true);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal("The quick brown fox is responsible for the lazy dog and the five boxing wizards too", p.Text);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, "Now then " + p.Text);
        Assert.Contains("responsible", Words(ContentEditPdf.Text(edited)));
        Assert.Equal("Now then " + p.Text, Body0(edited, "Now then").Text);
    }

    [Fact]
    public void KerningOfTheOriginalLinesIsKeptWhereThePairSurvives()
    {
        // The generator kerned "fo" by -40, "ov" and "vo" by -25 (TJ adjustments inside words); the word gaps are plain spaces.
        static string Kerned(string line) => "[(" + line.Replace("fo", "f) -40 (o").Replace("ov", "o) -25 (v").Replace("vo", "v) -25 (o") + ")] TJ";
        var lines = Wrap(Body, Width);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td {Kerned(lines[0])}");
        foreach (var l in lines.Skip(1)) sb.Append($" T* {Kerned(l)}");
        sb.Append(" 0 -60 Td (Next block starts here) Tj ET");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal(Body, p.Text);
        var text = "Now then " + p.Text + " for the fox";
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        var content = ContentEditPdf.Content(edited);
        // "fox" moved along its line, and "for" and "fox" were typed at the end: each pair keeps its kerning; "vow" and "over" too.
        Assert.Equal(3, System.Text.RegularExpressions.Regex.Matches(content, @"f\) -40 \(o").Count);
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(content, @"o\) -25 \(v")); // "over"
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(content, @"v\) -25 \(o")); // "vow"
        Assert.Equal(text, Body0(edited, "Now then").Text);
        Assert.Contains(Words(text), Words(ContentEditPdf.Text(edited)));
        // Lines without the pair get no adjustment of theirs.
        var plain = ContentEditor.ReplaceParagraph(pdf, null, p, "No such pairs in here at all");
        Assert.DoesNotContain("-40", ContentEditPdf.Content(plain));
    }

    [Fact]
    public void TheOneRunEditorKernsTheChangedMiddleLikeTheRestOfTheRun()
    {
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td [(Hel) -30 (lo World)] TJ ET");
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single(r => r.Text == "Hello World");
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello Hello");
        var content = ContentEditPdf.Content(edited);
        // The kept start keeps its adjustment as before; the typed "Hello" gets the same pair kerned.
        Assert.Contains("[(Hel) -30 (lo Hel) -30 (lo)] TJ", content);
        Assert.Contains("Hello Hello", ContentEditPdf.Text(edited));
    }
}
