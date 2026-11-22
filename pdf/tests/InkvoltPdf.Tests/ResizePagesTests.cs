using MuPDFCore;
using InkvoltPdf.Core;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Resize Pages (roadmap 4.7): Letter, A4 or any size, the content scaled to fit or given margins.</summary>
public class ResizePagesTests
{
    private const double A4W = 595, A4H = 842;

    private static (double W, double H)[] Sizes(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return [.. Enumerable.Range(0, engine.PageCount).Select(i => (Math.Round(engine.GetPage(i).Width), Math.Round(engine.GetPage(i).Height)))];
    }

    [Fact]
    public void TheContentIsScaledAndCentred_OrKeptWithMargins()
    {
        var scale = PageEditor.ResizeTransform((0, 0, 612, 792), 0, A4W, A4H, ResizeFit.Scale)!.Value;
        Assert.Equal(A4W / 612, scale.S, 4);
        Assert.Equal(0, scale.E, 2);
        Assert.Equal((A4H - 792 * scale.S) / 2, scale.F, 2);
        Assert.Equal((A4W, A4H), (scale.W, scale.H));

        // Margins: a smaller page keeps its size, centred; a larger one shrinks to fit.
        var small = PageEditor.ResizeTransform((0, 0, 420, 595), 0, 612, 792, ResizeFit.Margins)!.Value;
        Assert.Equal((1, 96, 98.5), (small.S, small.E, small.F));
        Assert.True(PageEditor.ResizeTransform((0, 0, 842, 1191), 0, 612, 792, ResizeFit.Margins)!.Value.S < 1);

        // A crop's corner goes to where the content starts.
        var cropped = PageEditor.ResizeTransform((100, 50, 712, 842), 0, 612, 792, ResizeFit.Scale)!.Value;
        Assert.Equal((1, -100, -50), (cropped.S, cropped.E, cropped.F));
        Assert.Null(PageEditor.ResizeTransform((0, 0, 612, 792), 0, 612, 792, ResizeFit.Scale)); // already so
    }

    [Fact]
    public void APageSizeNoPageCanHave_IsRefusedWithAMessage_NeverWrittenAsNaN()
    {
        // ±1e308: the width is infinite, the scale nothing, the place NaN.
        var huge = "1" + new string('0', 308);
        byte[] Doc(string mediaBox, string pageExtra = "") => Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.Stream("0 0 1 rg 100 100 200 200 re f"),
            $"<< /Type /Page /Parent 2 0 R /MediaBox [{mediaBox}] {pageExtra} /Contents 4 0 R /Annots [6 0 R] >>",
            $"<< /Type /Annot /Subtype /Square /Rect [-{huge} 0 {huge} 10] >>",
        ]);
        Assert.Null(PageEditor.ResizeTransform((-1e308, 0, 1e308, 792), 0, A4W, A4H, ResizeFit.Scale));
        Assert.Null(PageEditor.ResizeTransform((0, 0, double.NaN, 792), 0, A4W, A4H, ResizeFit.Scale));

        // As wide as no page is (one side, or both, which PDFsharp itself can't take): refused, saying which page.
        foreach (var box in new[] { $"-{huge} 0 {huge} 792", $"-{huge} -{huge} {huge} {huge}", "0 0 612 20000000" })
        {
            var ex = Assert.Throws<InvalidOperationException>(() => PageEditor.Resize(Doc(box), null, [0, 1], A4W, A4H, ResizeFit.Scale));
            Assert.Contains("2", ex.Message); // the page named
        }
        var bad = Doc($"-{huge} 0 {huge} 792");
        using (var first = Core2Pdf.Open(PageEditor.Resize(bad, null, [0], A4W, A4H, ResizeFit.Scale))) // the other page alone: resized
            Assert.Equal(A4W, first.Pages[0].MediaBox.Width, 1);

        // A crop that shows a page of a usable size: that is the page, and it resizes; the comment's absurd box stays as it was.
        var cropped = PageEditor.Resize(Doc($"-{huge} 0 {huge} 792", "/CropBox [0 0 612 792]"), null, [1], A4W, A4H, ResizeFit.Scale);
        Assert.DoesNotContain("NaN", System.Text.Encoding.Latin1.GetString(cropped));
        Assert.Equal((A4W, A4H), Sizes(cropped)[1]);
    }

    [Fact]
    public void APageKeepsTheWayItIsTurned()
    {
        // Landscape content gets the paper sideways; a page turned with /Rotate gets it in its own space.
        Assert.Equal((A4H, A4W), Size(PageEditor.ResizeTransform((0, 0, 792, 612), 0, A4W, A4H, ResizeFit.Scale)));
        Assert.Equal((A4W, A4H), Size(PageEditor.ResizeTransform((0, 0, 612, 792), 90, A4W, A4H, ResizeFit.Scale)));
        Assert.Equal((A4W, A4H), Size(PageEditor.ResizeTransform((0, 0, 612, 792), 0, A4H, A4W, ResizeFit.Scale))); // paper given sideways

        static (double, double) Size((double S, double E, double F, double W, double H)? t) => (t!.Value.W, t.Value.H);
    }

    [Fact]
    public void MixedSizesBecomeOneSize_TheTextStaying()
    {
        var mixed = PageEditor.InsertBlank(TestPdf.Make(2), null, 1, 1, 420, 595); // Letter, A5, Letter
        var rotated = PageEditor.Rotate(mixed, null, [2], 90);
        var pdf = PageEditor.Resize(rotated, null, [0, 1, 2], A4W, A4H, ResizeFit.Scale);
        Assert.Equal([(A4W, A4H), (A4W, A4H), (A4H, A4W)], Sizes(pdf));
        Assert.Equal([1, 0, 2], TestPdf.PageNumbers(pdf));

        var some = PageEditor.Resize(mixed, null, [1], 612, 792, ResizeFit.Margins);
        Assert.Equal([(612, 792), (612, 792), (612, 792)], Sizes(some));
    }

    [Fact]
    public void CommentsMoveWithTheContent_AndTheCropGoes()
    {
        var noted = Annotations.AddNote(TestPdf.Make(1), null, 0, 100, 100, "Look here", "Me");
        var before = Annotations.Read(noted, null).Single().Rect;
        var pdf = PageEditor.Resize(noted, null, [0], A4W, A4H, ResizeFit.Scale);
        var after = Annotations.Read(pdf, null).Single().Rect;
        var s = A4W / 612;
        Assert.Equal(before.X * s, after.X, 1);
        Assert.Equal(before.Y * s + (A4H - 792 * s) / 2, after.Y, 1);
        Assert.Equal(before.Width * s, after.Width, 1);

        var cropped = PageEditor.Crop(TestPdf.Make(1), null, [0], new Margins(36, 36, 36, 36));
        using var doc = PdfReader.Open(new MemoryStream(PageEditor.Resize(cropped, null, [0], 612, 792, ResizeFit.Margins)), PdfDocumentOpenMode.Import);
        Assert.False(doc.Pages[0].Elements.ContainsKey("/CropBox"));
        Assert.Equal((612.0, 792.0), (doc.Pages[0].MediaBox.Width, doc.Pages[0].MediaBox.Height));
    }

    [Fact]
    public void AnUnusablePaperSizeIsRefused()
    {
        var pdf = TestPdf.Make(1);
        Assert.Throws<ArgumentOutOfRangeException>(() => PageEditor.Resize(pdf, null, [0], double.NaN, 792, ResizeFit.Scale));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageEditor.Resize(pdf, null, [0], 612, 1e9, ResizeFit.Scale));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageEditor.Resize(pdf, null, [0], 10, 792, ResizeFit.Scale));
    }

    [Fact]
    public void ASignedFileTakesItAsAnAppendedChange()
    {
        var signed = SignedEditTests.Signed();
        var (edited, report) = SignedEdits.Run(() => PageEditor.Resize(signed, null, [1], A4W, A4H, ResizeFit.Scale));
        Assert.True(report.Appended);
        Assert.True(edited.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal([(612, 792), (A4W, A4H)], Sizes(edited));
        using var engine = PdfEngine.Open(edited, InputFileTypes.PDF, null);
        Assert.Contains("Second page", engine.GetText(1).Text);
    }

    [Fact]
    public void BookmarksAndLinksToAResizedPageLandOnTheSameSpot()
    {
        var pdf = Bookmarks.SetOutline(TestPdf.Make(2), null, [new Bookmark("Here", 0, 100), new Bookmark("Other page", 1, 100)]);
        var resized = PageEditor.Resize(pdf, null, [0], A4W, A4H, ResizeFit.Scale);
        var s = A4W / 612;
        var f = (A4H - 792 * s) / 2;
        var read = Bookmarks.Read(resized, null);
        Assert.Equal(A4H - (s * (792 - 100) + f), read[0].Top!.Value, 1); // the same line of the content
        Assert.Equal(100, read[1].Top!.Value, 1); // a page left as it was
    }

    [Fact]
    public void EveryKindOfDestinationMovesWithTheContent()
    {
        static PdfSharp.Pdf.PdfArray Dest(string kind, params double?[] values)
        {
            var a = new PdfSharp.Pdf.PdfArray();
            a.Elements.Add(PdfSharp.Pdf.PdfNull.Value);
            a.Elements.Add(new PdfSharp.Pdf.PdfName("/" + kind));
            foreach (var v in values) a.Elements.Add(v is { } d ? new PdfSharp.Pdf.PdfReal(d) : PdfSharp.Pdf.PdfNull.Value);
            return a;
        }
        static double?[] Values(PdfSharp.Pdf.PdfArray a) =>
            [.. a.Elements.Skip(2).Select(e => e is PdfSharp.Pdf.PdfNull ? (double?)null : Math.Round(PdfObj.Num(e), 3))];

        var xyz = Dest("XYZ", 10, 20, 2);
        PageEditor.MoveDestination(xyz, 0.5, 100, 200);
        Assert.Equal([105, 210, 2], Values(xyz)); // the zoom stays
        var unset = Dest("XYZ", null, 20, null);
        PageEditor.MoveDestination(unset, 0.5, 100, 200);
        Assert.Equal([null, 210, null], Values(unset));
        var fitR = Dest("FitR", 10, 20, 30, 40);
        PageEditor.MoveDestination(fitR, 2, 1, 1);
        Assert.Equal([21, 41, 61, 81], Values(fitR));
        var fitH = Dest("FitBH", 20);
        PageEditor.MoveDestination(fitH, 2, 1, 5);
        Assert.Equal([45], Values(fitH));
        var fitV = Dest("FitV", 20);
        PageEditor.MoveDestination(fitV, 2, 1, 5);
        Assert.Equal([41], Values(fitV));
        var fit = Dest("Fit");
        PageEditor.MoveDestination(fit, 2, 1, 5);
        Assert.Empty(Values(fit));
    }
}
