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
}
