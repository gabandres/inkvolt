using MuPDFCore;
using InkvoltPdf.Core;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Remove Blank Pages and Split at Blank Pages (roadmap 4.4), in the app and in Batch.</summary>
public sealed class BlankPagesTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-blank-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    /// <summary>Pages 1-3 of <see cref="TestPdf.Make"/> with blank pages after page 1 and after page 3 (five pages).</summary>
    internal static byte[] WithBlanks()
    {
        var pdf = PageEditor.InsertBlank(TestPdf.Make(3), null, 1, 1, 612, 792);
        return PageEditor.InsertBlank(pdf, null, 4, 1, 612, 792);
    }

    private static int[] Find(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return BlankPages.Find(engine);
    }

    [Fact]
    public void FindsThePagesThatAreAllPaper()
    {
        Assert.Equal([1, 4], Find(WithBlanks()));
        Assert.Empty(Find(TestPdf.Make(2)));
    }

    [Fact]
    public void AShortLineIsNotBlank_ButSpecksAndPaleShowThroughAre()
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var word = doc.AddPage();
        using (var gfx = XGraphics.FromPdfPage(word)) gfx.DrawString("Continued overleaf", new XFont("Arial", 11), XBrushes.Black, new XPoint(250, 400));
        var specks = doc.AddPage();
        using (var gfx = XGraphics.FromPdfPage(specks))
        {
            gfx.DrawRectangle(XBrushes.Black, 200, 300, 0.6, 0.6); // dust
            gfx.DrawRectangle(new XSolidBrush(XColor.FromArgb(235, 235, 235)), 100, 100, 300, 200); // the back of the sheet showing through
        }
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        Assert.Equal([1], Find(ms.ToArray()));
    }

    [Fact]
    public void SeparatorSheetsSplitTheStack()
    {
        Assert.Equal([[0], [2, 3]], BlankPages.SplitAt(5, [1, 4]));
        Assert.Equal([[2], [5]], BlankPages.SplitAt(6, [0, 1, 3, 4])); // two blank sides in a row separate once; none before the first
        Assert.Equal([[0, 1, 2]], BlankPages.SplitAt(3, []));
        Assert.Empty(BlankPages.SplitAt(2, [0, 1]));
    }

    [Fact]
    public void RemovingThemKeepsTheRest_AndNeverTheLastPage()
    {
        var removed = BlankPages.Remove(WithBlanks(), null, [1, 4]);
        Assert.Equal([1, 2, 3], TestPdf.PageNumbers(removed));
        var allBlank = PageEditor.InsertBlank(PageEditor.Delete(TestPdf.Make(2), null, [0]), null, 0, 1, 612, 792);
        Assert.Throws<InvalidOperationException>(() => BlankPages.Remove(allBlank, null, [0, 1]));
    }

    [Fact]
    public void ASignedFileTakesTheRemovalAsAnAppendedChange()
    {
        var signed = SignedEditTests.Signed();
        var withBlank = SignedEdits.Run(() => PageEditor.InsertBlank(signed, null, 2, 1, 612, 792)).Data;
        Assert.Equal([2], Find(withBlank));
        var (edited, report) = SignedEdits.Run(() => BlankPages.Remove(withBlank, null, [2]));
        Assert.True(report.Appended);
        Assert.True(edited.AsSpan(0, signed.Length).SequenceEqual(signed));
        using var engine = PdfEngine.Open(edited, InputFileTypes.PDF, null);
        Assert.Equal(2, engine.PageCount);
    }

    [Fact]
    public async Task BatchRemovesThem_AndSplitsAtThem()
    {
        var input = Path.Combine(_root, "stack.pdf");
        File.WriteAllBytes(input, WithBlanks());
        var plan = new BatchPlan { Steps = [new SplitAtBlankPagesStep(), new RemoveBlankPagesStep()], OutputFolder = Path.Combine(_root, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(input)], plan, new BatchHost(), null, default);

        var item = summary.Items.Single();
        Assert.Equal(BatchItemState.Done, item.State);
        Assert.Equal(["stack.pdf", "stack - part 1.pdf", "stack - part 2.pdf"], item.Outputs.Select(Path.GetFileName));
        Assert.Equal([1, 2, 3], TestPdf.PageNumbers(File.ReadAllBytes(item.Outputs[0])));
        Assert.Equal([1], TestPdf.PageNumbers(File.ReadAllBytes(item.Outputs[1])));
        Assert.Equal([2, 3], TestPdf.PageNumbers(File.ReadAllBytes(item.Outputs[2])));
        Assert.Contains("2 blank pages removed.", item.Notes);
        Assert.Contains("2 parts saved.", item.Notes);

        // A file without a blank page: nothing split, said so.
        var plain = Path.Combine(_root, "plain.pdf");
        File.WriteAllBytes(plain, TestPdf.Make(2));
        var none = (await BatchRunner.RunAsync([new BatchFile(plain)], plan with { Steps = [new SplitAtBlankPagesStep()] }, new BatchHost(), null, default)).Items.Single();
        Assert.Empty(none.Outputs);
        Assert.Contains(PdfStrings.Batch_NoBlank, none.Notes);
    }
}
