using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 4.17: Insert Text and Replace Text, made as Acrobat makes them and carried through the comment paths.</summary>
public class ProofreadingTests
{
    /// <summary>The insertion point before "quick" on page 1 of <see cref="TestPdf.Make"/>, and the struck-out boxes of "brown".</summary>
    private static (RectD Caret, List<RectD> Brown) Places(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        var quick = text.Text.IndexOf("quick", StringComparison.Ordinal);
        var brown = text.Text.IndexOf("brown", StringComparison.Ordinal);
        return (Annotations.CaretAt(text, quick)!.Value, text.GetRects(brown, brown + 5));
    }

    [Fact]
    public void CaretAt_IsTheInsertionPointAsTallAsItsLine()
    {
        var pdf = TestPdf.Make(1);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        var quick = text.Text.IndexOf("quick", StringComparison.Ordinal);
        var at = Annotations.CaretAt(text, quick)!.Value;
        var q = text.BoxAt(quick);
        Assert.Equal(0, at.Width);
        Assert.Equal(q.X, at.X, 3);
        Assert.Equal(q.Height, at.Height, 3);
        // At the end of the text: after its last character.
        var end = Annotations.CaretAt(text, text.Text.Length)!.Value;
        Assert.Equal(text.BoxAt(text.Text.Length - 1).Right, end.X, 3);
        Assert.Null(Annotations.CaretAt(PageText.Empty, 0));
    }

    [Fact]
    public void InsertText_IsABlueCaretWithTheTextAsItsComment()
    {
        var pdf = TestPdf.Make(1);
        var (caret, _) = Places(pdf);
        var marked = Annotations.AddInsertText(pdf, null, 0, caret, "  very  ", "Ana", "ins-1");

        var a = Assert.Single(Annotations.Read(marked, null));
        Assert.Equal(AnnotationKind.Caret, a.Kind);
        Assert.Equal("ins-1", a.Id);
        Assert.Equal("very", a.Contents);
        Assert.Equal("Ana", a.Author);
        Assert.Equal("Inserted Text", a.Subject);
        Assert.Equal(Annotations.ProofBlue, a.Color);
        Assert.Null(a.ReplyTo);
        Assert.Equal(ProofMarkKind.InsertText, Annotations.ProofKindOf(a, Annotations.ReplacedCarets([a])));
        // Its tip sits at the insertion point, under the line's middle; it reaches below the line.
        Assert.InRange(a.Rect.CenterX, caret.X - 1, caret.X + 1);
        Assert.True(a.Rect.Y > caret.CenterY && a.Rect.Bottom > caret.Bottom, $"{a.Rect} vs {caret}");
        // Drawn by every viewer: an appearance of its own, shown blue under the text.
        using var doc = PdfReader.Open(new MemoryStream(marked), PdfDocumentOpenMode.Import);
        var annot = (PdfDictionary)((PdfSharp.Pdf.Advanced.PdfReference)doc.Pages[0].Elements.GetArray("/Annots")!.Elements[0]).Value;
        Assert.NotNull(annot.Elements.GetDictionary("/AP")?.Elements.GetDictionary("/N"));
        Assert.Equal("/None", annot.Elements.GetName("/Sy"));
        Assert.True(Core2Pdf.Ink(marked, 0, a.Rect) > 0.05);
    }

    [Fact]
    public void ReplaceText_StrikesTheWordsOutAndGroupsThemWithACaretHoldingTheNewText()
    {
        var pdf = TestPdf.Make(1);
        var (_, brown) = Places(pdf);
        var marked = Annotations.AddReplaceText(pdf, null, 0, brown, "red", "Ana", "rep-1");

        var all = Annotations.Read(marked, null);
        Assert.Equal(2, all.Count);
        var caret = Assert.Single(all, c => c.Kind == AnnotationKind.Caret);
        var strike = Assert.Single(all, c => c.Kind == AnnotationKind.StrikeOut);
        Assert.Equal("rep-1", caret.Id);
        Assert.Equal("red", caret.Contents);
        Assert.Equal("rep-1", strike.ReplyTo);
        Assert.True(strike.Grouped);
        Assert.False(caret.Grouped);
        Assert.Equal("Cross-Out", strike.Subject);
        Assert.Equal(Annotations.ProofBlue, strike.Color);
        Assert.Equal(brown[0].X, strike.QuadRects[0].X, 1);
        // The caret comes after the struck-out word.
        Assert.InRange(caret.Rect.CenterX, brown[^1].Right - 1, brown[^1].Right + 1);
        var ids = all.Select(c => c.Id).ToHashSet();
        Assert.True(Annotations.IsGroupMember(strike, ids));
        Assert.False(Annotations.IsGroupMember(caret, ids));
        Assert.Equal(ProofMarkKind.ReplaceText, Annotations.ProofKindOf(caret, Annotations.ReplacedCarets(all)));
        Assert.Null(Annotations.ProofKindOf(strike, Annotations.ReplacedCarets(all)));

        // One comment: deleting it takes the strike-out along.
        Assert.Empty(Annotations.Read(Annotations.Delete(marked, null, "rep-1"), null));
        // Deleting the strike-out (picked on the page) takes the group too: never a caret left as Insert Text.
        Assert.Same(caret, Annotations.GroupHead(strike, all));
        Assert.Same(caret, Annotations.GroupHead(caret, all));
        Assert.Empty(Annotations.Read(Annotations.Delete(marked, null, strike.Id), null));
    }

    [Fact]
    public void AGroupThatLoops_StopsClimbing()
    {
        AnnotationInfo Grouped(string id, string to) =>
            new(id, AnnotationKind.StrikeOut, "StrikeOut", 0, default, "", null, null, null, null, [], false, to, false, Grouped: true);
        List<AnnotationInfo> loop = [Grouped("a", "b"), Grouped("b", "a")];
        Assert.Contains(Annotations.GroupHead(loop[0], loop).Id, new[] { "a", "b" });
        Assert.Same(loop[0], Annotations.GroupHead(loop[0], [loop[0]])); // its head isn't there: itself
    }

    [Fact]
    public void ARealReplyIsNotAGroup()
    {
        var pdf = Annotations.AddInsertText(TestPdf.Make(1), null, 0, new RectD(100, 100, 0, 20), "x", "Ana", "ins-1");
        pdf = Annotations.AddReply(pdf, null, "ins-1", "Agreed", "Bo", "reply-1");
        var all = Annotations.Read(pdf, null);
        var reply = Assert.Single(all, a => a.Id == "reply-1");
        Assert.False(reply.Grouped);
        Assert.False(Annotations.IsGroupMember(reply, all.Select(a => a.Id).ToHashSet()));
        Assert.Equal(ProofMarkKind.InsertText, Annotations.ProofKindOf(all.Single(a => a.Id == "ins-1"), Annotations.ReplacedCarets(all)));
    }

    [Fact]
    public void RefusesEmptyOrHugeTextAndNoWords()
    {
        var pdf = TestPdf.Make(1);
        Assert.Throws<ArgumentException>(() => Annotations.AddInsertText(pdf, null, 0, new RectD(100, 100, 0, 20), "  \n ", "Ana"));
        Assert.Throws<ArgumentException>(() => Annotations.AddInsertText(pdf, null, 0, new RectD(100, 100, 0, 20), new string('x', Annotations.MaxProofText + 1), "Ana"));
        Assert.Throws<ArgumentException>(() => Annotations.AddInsertText(pdf, null, 0, new RectD(double.NaN, 100, 0, 20), "x", "Ana"));
        Assert.Throws<ArgumentException>(() => Annotations.AddReplaceText(pdf, null, 0, [], "x", "Ana"));
        Assert.Throws<ArgumentOutOfRangeException>(() => Annotations.AddInsertText(pdf, null, 3, new RectD(100, 100, 0, 20), "x", "Ana"));
    }

    [Fact]
    public void OnATurnedPage_TheCaretStaysUnderTheLineAsShown()
    {
        using var doc = PdfReader.Open(new MemoryStream(TestPdf.Make(1)), PdfDocumentOpenMode.Modify);
        doc.Pages[0].Rotate = 90;
        using var ms = new MemoryStream();
        doc.Save(ms);
        var turned = ms.ToArray();
        var at = new RectD(200, 300, 0, 20); // page space: as the page is shown
        var a = Assert.Single(Annotations.Read(Annotations.AddInsertText(turned, null, 0, at, "x", "Ana"), null));
        Assert.InRange(a.Rect.CenterX, at.X - 1, at.X + 1);
        Assert.True(a.Rect.Y > at.CenterY && a.Rect.Bottom > at.Bottom, $"{a.Rect}");
        // The same chevron as on an unturned page (not on its side).
        var upright = Assert.Single(Annotations.Read(Annotations.AddInsertText(TestPdf.Make(1), null, 0, at, "x", "Ana"), null));
        Assert.Equal(upright.Rect.Width, a.Rect.Width, 2);
        Assert.Equal(upright.Rect.Height, a.Rect.Height, 2);
        Assert.NotEqual(a.Rect.Width, a.Rect.Height, 1);
    }

    private static byte[] Proofread()
    {
        var pdf = TestPdf.Make(1);
        var (caret, brown) = Places(pdf);
        pdf = Annotations.AddInsertText(pdf, null, 0, caret, "very", "Ana", "ins-1");
        pdf = Annotations.AddReplaceText(pdf, null, 0, brown, "red", "Ana", "rep-1");
        return Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Highlight, [new RectD(72, 150, 100, 20)], AnnotColor.Yellow, "look", "Bo", "hl-1");
    }

    [Theory]
    [InlineData(CommentFileFormat.Xfdf)]
    [InlineData(CommentFileFormat.Fdf)]
    public void TheMarksTravelThroughXfdfAndFdf_StillGrouped(CommentFileFormat format)
    {
        var export = CommentFiles.Export(Proofread(), null, format, "source.pdf");
        Assert.Equal(4, export.Count);
        if (format == CommentFileFormat.Xfdf)
        {
            var xml = Encoding.UTF8.GetString(export.Data);
            Assert.Contains("<caret", xml);
            Assert.Contains("replyType=\"group\"", xml);
            Assert.Contains("inreplyto=\"rep-1\"", xml);
        }
        var result = CommentFiles.Import(TestPdf.Make(1), null, export.Data);
        Assert.Equal(4, result.Added);
        var all = Annotations.Read(result.Data, null);
        var caret = Assert.Single(all, a => a.Id == "rep-1");
        var strike = Assert.Single(all, a => a.Kind == AnnotationKind.StrikeOut);
        Assert.True(strike.Grouped);
        Assert.Equal("rep-1", strike.ReplyTo);
        Assert.Equal("red", caret.Contents);
        Assert.Equal("very", all.Single(a => a.Id == "ins-1").Contents);
        // XFDF carries no appearance for a caret: the import draws one.
        using var doc = PdfReader.Open(new MemoryStream(result.Data), PdfDocumentOpenMode.Import);
        foreach (var a in doc.Pages[0].Elements.GetArray("/Annots")!.Elements.Select(e => ((PdfSharp.Pdf.Advanced.PdfReference)e).Value).OfType<PdfDictionary>())
            Assert.NotNull(a.Elements.GetDictionary("/AP")?.Elements.GetDictionary("/N"));
    }

    [Fact]
    public void TheSummaryListsEachMarkOnce_ByWhatItAsks()
    {
        var pdf = Proofread();
        var (_, entries) = Assert.Single(CommentSummary.Plan(Annotations.Read(pdf, null)));
        Assert.Equal(3, entries.Count);
        Assert.All(entries, e => Assert.Equal(0, e.Depth));
        Assert.DoesNotContain(entries, e => e.Comment.Kind == AnnotationKind.StrikeOut);
        Assert.Equal(ProofMarkKind.InsertText, entries.Single(e => e.Comment.Id == "ins-1").Proof);
        Assert.Equal(ProofMarkKind.ReplaceText, entries.Single(e => e.Comment.Id == "rep-1").Proof);
        Assert.Null(entries.Single(e => e.Comment.Id == "hl-1").Proof);

        var text = Core2Pdf.AllText(CommentSummary.Make(pdf, null, "proof"), 0);
        Assert.Contains("Replace text", text);
        Assert.Contains("Insert text", text);
    }
}
