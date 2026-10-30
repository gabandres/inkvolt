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
}
