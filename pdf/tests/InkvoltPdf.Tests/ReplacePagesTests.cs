using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Replace Pages (roadmap 4.13): one for one, keeping what led to the replaced pages.</summary>
public class ReplacePagesTests
{
    private static string[] Markers(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return [.. Enumerable.Range(0, engine.PageCount).Select(i => engine.GetText(i).Text.Split('\n')[0].Trim())];
    }

    [Fact]
    public void TheNewPagesTakeTheirPlaces_BookmarksAndLinksFollow()
    {
        var pdf = Bookmarks.SetOutline(TestPdf.Make(4), null, [new Bookmark("Third", 2, 300), new Bookmark("Fourth", 3)]);
        pdf = Links.Put(pdf, null, 0, new RectD(72, 300, 100, 20), null, 2);
        var source = new PdfSource(TestPdf.Make(3, "new"), null, "fixed.pdf");

        var replaced = PageEditor.Replace(pdf, null, [1, 2], source, [1, 2]);

        Assert.Equal(["Page 1 alpha", "Page 2 new", "Page 3 new", "Page 4 alpha"], Markers(replaced));
        var bookmarks = Bookmarks.Read(replaced, null);
        Assert.Equal([("Third", 2), ("Fourth", 3)], bookmarks.Select(b => (b.Title, b.PageIndex)));
        Assert.Equal(300, bookmarks[0].Top!.Value, 0); // the same spot
        Assert.Equal(2, Links.Read(replaced, null).Single().TargetPage);
    }

    [Fact]
    public void TheOrderOfTheNewPagesIsTheOrderGiven()
    {
        var replaced = PageEditor.Replace(TestPdf.Make(3), null, [0, 2], new PdfSource(TestPdf.Make(2, "new"), null, "x.pdf"), [1, 0]);
        Assert.Equal(["Page 2 new", "Page 2 alpha", "Page 1 new"], Markers(replaced));
    }

    [Fact]
    public void CountsThatDiffer_OrAPageNamedTwice_AreRefused()
    {
        var pdf = TestPdf.Make(3);
        var source = new PdfSource(TestPdf.Make(3, "new"), null, "x.pdf");
        Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [0, 1], source, [0]));
        Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [0, 0], source, [0, 1]));
        Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [5], source, [0]));
        Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [0], source, [7]));
    }

    [Fact]
    public void ASignedFileTakesItAsAnAppendedChange()
    {
        var signed = SignedEditTests.Signed();
        var (edited, report) = SignedEdits.Run(() => PageEditor.Replace(signed, null, [1], new PdfSource(TestPdf.Make(1, "new"), null, "x.pdf"), [0]));
        Assert.True(report.Appended);
        Assert.True(edited.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal(["Hello contract", "Page 1 new"], Markers(edited));
    }

    [Fact]
    public void APageNamedTwiceSaysSo()
    {
        var pdf = TestPdf.Make(3);
        var source = new PdfSource(TestPdf.Make(3, "new"), null, "x.pdf");
        Assert.Equal(PdfStrings.Page_ReplaceTwice, Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [0, 0], source, [0, 1])).Message.Split(" (")[0]);
        Assert.Equal(PdfStrings.Page_ReplaceSourceTwice, Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [0, 1], source, [2, 2])).Message.Split(" (")[0]);
        Assert.Equal(PdfStrings.Page_ReplaceCount, Assert.Throws<ArgumentException>(() => PageEditor.Replace(pdf, null, [0, 1], source, [0])).Message.Split(" (")[0]);
    }
}
