using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 2.1: text inside form XObjects (reused drawings) edits as paragraphs and as single runs.</summary>
public partial class ParagraphEditTests
{
    /// <summary>Body's lines as a left-aligned paragraph, with a line under it, as a form's content.</summary>
    private static string FormBody(string body = Body)
    {
        var lines = Wrap(body, Width);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td ({lines[0]}) Tj");
        foreach (var l in lines.Skip(1)) sb.Append($" T* ({l}) Tj");
        sb.Append(" 0 -60 Td (Inside the form too) Tj ET");
        return sb.ToString();
    }

    private static string FormStream(byte[] pdf, int page = 0, string name = "/Fm1")
    {
        using var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        var xo = PdfObj.Dict(PdfObj.Dict(d.Pages[page].Elements["/Resources"])!.Elements["/XObject"])!;
        return Encoding.Latin1.GetString(PdfObj.StreamBytes(PdfObj.Dict(xo.Elements[name])!));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AParagraphInsideAFormXObjectReflows(bool inherits)
    {
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q BT /FA 12 Tf 72 300 Td (On the page itself) Tj ET", form: FormBody(), formInherits: inherits, fontText: Chars);
        var before = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.All(p.Runs, r => Assert.True(r.Id < 0));
        var inside = before.Runs.Single(r => r.Text == "Inside the form too");
        var onPage = before.Runs.Single(r => r.Text == "On the page itself");
        var text = Body + " " + Twenty;
        var check = p.Check(text);
        Assert.Null(check.Overlaps);

        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        Assert.Contains(Words(text), Words(ContentEditPdf.Text(edited)));
        var after = ContentEditor.Read(edited, null, 0);
        var q = Body0(edited);
        Assert.Equal(text, q.Text);
        Assert.Equal(check.LineCount, q.Lines.Count);
        Assert.Equal(inside.Box.Y, after.Runs.Single(r => r.Text == "Inside the form too").Box.Y, 2);
        Assert.Equal(onPage.Box, after.Runs.Single(r => r.Text == "On the page itself").Box);
        // The form's stream was rewritten; the page's own content wasn't.
        Assert.Contains("Then seven tired", FormStream(edited));
        Assert.Equal(ContentEditPdf.Content(pdf), ContentEditPdf.Content(edited));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void StandInFontsForAFormGoWithItsResources(bool inherits)
    {
        // "@" isn't in the font: drawn in a stand-in, embedded where the form's fonts are (its own resources, or the page's when it borrows them).
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q", form: FormBody(), formInherits: inherits, fontText: Chars);
        var p = Body0(pdf);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, "Mail me @ home, " + Body);
        Assert.Contains("Mail me @ home", Words(ContentEditPdf.Text(edited)));
        using var d = PdfReader.Open(new MemoryStream(edited), PdfDocumentOpenMode.Import);
        var pageFonts = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        var form = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/Fm1"])!;
        var formFonts = PdfObj.Dict(PdfObj.Dict(form.Elements["/Resources"])?.Elements["/Font"]);
        var holder = inherits ? pageFonts : formFonts!;
        Assert.Contains(holder.Elements.Keys, k => k.StartsWith("/InkFb", StringComparison.Ordinal));
        if (!inherits) Assert.DoesNotContain(pageFonts.Elements.Keys, k => k.StartsWith("/InkFb", StringComparison.Ordinal));
    }

    [Fact]
    public void AFormDrawnTwiceOnThePageIsCopiedSoOnlyTheClickedOneChanges()
    {
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q q 1 0 0 1 0 -380 cm /Fm1 Do Q", form: FormBody(), fontText: Chars);
        var paras = ContentEditor.Read(pdf, null, 0).Paragraphs.Where(p => p.Text == Body).OrderBy(p => p.Box.Y).ToList();
        Assert.Equal(2, paras.Count);
        Assert.All(paras, p => Assert.Null(p.Blocked));
        var edited = ContentEditor.ReplaceParagraph(pdf, null, paras[1], Twenty);
        var after = ContentEditor.Read(edited, null, 0).Paragraphs.Where(p => p.Lines.Count > 1).OrderBy(p => p.Box.Y).ToList();
        Assert.Equal([Body, Twenty], after.Select(p => p.Text));
        Assert.Equal(paras[0].Box, after[0].Box);
        Assert.Equal(paras[1].Box.Y, after[1].Box.Y, 1);
        // The original form is untouched; the lower Do now draws a copy of its own.
        Assert.DoesNotContain("Then seven", FormStream(edited));
    }

    [Fact]
    public void AFormSharedWithAnotherPageIsCopiedForThisPage()
    {
        var one = ContentEditPdf.Make("q /Fm1 Do Q", form: FormBody(), fontText: Chars);
        byte[] pdf;
        using (var d = PdfReader.Open(new MemoryStream(one), PdfDocumentOpenMode.Modify))
        {
            var page2 = d.AddPage();
            page2.Width = d.Pages[0].Width;
            page2.Height = d.Pages[0].Height;
            page2.Elements["/Resources"] = d.Pages[0].Elements["/Resources"];
            page2.Elements["/Contents"] = PdfObj.AddStream(d, Encoding.Latin1.GetBytes("q /Fm1 Do Q")).Reference!;
            using var ms = new MemoryStream();
            d.Save(ms, false);
            pdf = ms.ToArray();
        }
        Assert.Equal(Body, Body0(pdf).Text);
        Assert.Equal(Body, ContentEditor.Read(pdf, null, 1).Paragraphs.Single(p => p.Lines.Count > 1).Text);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, Body0(pdf), Twenty);
        Assert.Contains(Words(Twenty), Words(ContentEditPdf.Text(edited)));
        Assert.Contains(Words(Body), Words(ContentEditPdf.Text(edited, 1)));
        Assert.Equal(Twenty, ContentEditor.Read(edited, null, 0).Paragraphs.Single(p => p.Lines.Count > 1).Text);
        Assert.Equal(Body, ContentEditor.Read(edited, null, 1).Paragraphs.Single(p => p.Lines.Count > 1).Text);
    }

    [Fact]
    public void AParagraphHalfInAFormIsEditedLineByLine()
    {
        // The form draws the first two lines, the page the rest, lined up: two streams can't be rewritten as one.
        var lines = Wrap(Body, Width);
        var form = $"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td ({lines[0]}) Tj T* ({lines[1]}) Tj ET";
        var sb = new StringBuilder($"q /Fm1 Do Q BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top - 2 * Step)} Td ({lines[2]}) Tj");
        foreach (var l in lines.Skip(3)) sb.Append($" T* ({l}) Tj");
        sb.Append(" ET");
        var pdf = ContentEditPdf.Make(sb.ToString(), form: form, fontText: Chars);
        var p = Body0(pdf);
        Assert.NotNull(p.Blocked);
        Assert.Contains("form XObject", p.Blocked);
    }

    [Fact]
    public void ASingleRunInsideAFormIsEditedInPlace()
    {
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q BT /FA 12 Tf 72 600 Td (draft) Tj ET", form: "BT /FA 12 Tf 72 700 Td (Hello) Tj (World) Tj ET");
        var content = ContentEditor.Read(pdf, null, 0);
        var hello = content.Runs.Single(r => r.Text == "Hello");
        Assert.Null(hello.Blocked);
        Assert.True(hello.Id < 0);
        var world = content.Runs.Single(r => r.Text == "World");
        var edited = ContentEditor.ReplaceText(pdf, null, hello, "Hell");
        var after = ContentEditor.Read(edited, null, 0);
        var hell = after.Runs.Single(r => r.Id == hello.Id);
        Assert.Equal("Hell", hell.Text);
        // "World" follows in the same text object: it moves with the end of "Hell", as on a page (no reflow).
        var world2 = after.Runs.Single(r => r.Text == "World");
        Assert.Equal(world.Box.Y, world2.Box.Y, 2);
        Assert.Equal(hell.Box.Right, world2.Box.X, 0);
        Assert.Contains("(Hell) Tj", FormStream(edited));
        Assert.Contains("draft", ContentEditPdf.Text(edited));
    }

    [Fact]
    public void PicturesInsideAFormStayAsTheyAre()
    {
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q", form: "q 100 0 0 50 72 600 cm /Im1 Do Q BT /FA 12 Tf 72 700 Td (Hello) Tj ET");
        var content = ContentEditor.Read(pdf, null, 0);
        Assert.Contains("form XObject", content.Images.Single().Blocked);
        Assert.Null(content.Runs.Single(r => r.Text == "Hello").Blocked);
    }
}
