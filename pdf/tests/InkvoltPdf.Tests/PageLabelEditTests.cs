using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Page Labels (roadmap 4.14): written for a range, the other pages keeping theirs.</summary>
public class PageLabelEditTests
{
    /// <summary>Each page's label, or "none" when the document has no labels.</summary>
    private static string[] Labels(byte[] pdf) => DocumentFeatures.PageLabels(pdf, null) ?? ["none"];

    private static PageLabelStyle Roman => new(PageNumbering.LowerRoman, "", 1);

    [Fact]
    public void APrefaceInRomanThenTheBodyFromOne()
    {
        var pdf = PageLabels.Write(TestPdf.Make(6), null, [0, 1], Roman, restartAfter: true);
        Assert.Equal(["i", "ii", "1", "2", "3", "4"], Labels(pdf));

        // Without restarting, the pages after keep the labels they had.
        Assert.Equal(["i", "ii", "3", "4", "5", "6"], Labels(PageLabels.Write(TestPdf.Make(6), null, [0, 1], Roman)));
    }

    [Fact]
    public void EveryStyle_PrefixesAndAStartNumber()
    {
        var pdf = TestPdf.Make(8);
        pdf = PageLabels.Write(pdf, null, [0, 1], new PageLabelStyle(PageNumbering.UpperRoman, "", 4));
        pdf = PageLabels.Write(pdf, null, [2, 3], new PageLabelStyle(PageNumbering.UpperLetters, "App-", 1));
        pdf = PageLabels.Write(pdf, null, [4, 5], new PageLabelStyle(PageNumbering.LowerLetters, "", 26));
        pdf = PageLabels.Write(pdf, null, [6], new PageLabelStyle(PageNumbering.None, "Cover", 1));
        pdf = PageLabels.Write(pdf, null, [7], new PageLabelStyle(PageNumbering.Decimal, "A-", 10));
        Assert.Equal(["IV", "V", "App-A", "App-B", "z", "aa", "Cover", "A-10"], Labels(pdf));
        Assert.Equal("App-B", new PageLabelStyle(PageNumbering.UpperLetters, "App-", 1).Format(1));
        Assert.Equal(new PageLabelStyle(PageNumbering.UpperLetters, "App-", 2), PageLabels.At(pdf, null, 3));
    }

    [Fact]
    public void LabelsThatComeBackToPlainNumbersAreNotWritten()
    {
        var labeled = PageLabels.Write(TestPdf.Make(3), null, [0], Roman, restartAfter: true);
        Assert.Equal(["i", "1", "2"], Labels(labeled));
        Assert.Equal(["none"], Labels(PageLabels.Remove(labeled, null)));
        Assert.Equal(["none"], Labels(PageLabels.Write(labeled, null, [0, 1, 2], new PageLabelStyle(PageNumbering.Decimal, "", 1))));
        Assert.Equal(new PageLabelStyle(PageNumbering.Decimal, "", 3), PageLabels.At(TestPdf.Make(3), null, 2));
    }

    [Fact]
    public void TheFewestRangesAreWritten()
    {
        var pdf = PageLabels.Write(TestPdf.Make(10), null, [0, 1, 2], Roman, restartAfter: true);
        using var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        var nums = PdfObj.Array(PdfObj.Dict(doc.Internals.Catalog.Elements["/PageLabels"])!.Elements["/Nums"])!;
        Assert.Equal(4, nums.Elements.Count); // [0 << /S /r >> 3 << /S /D >>]
    }

    [Fact]
    public void AHostilePrefixOrNumberIsRefused()
    {
        var pdf = TestPdf.Make(2);
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [0], new PageLabelStyle(PageNumbering.Decimal, new string('x', 65), 1)));
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [0], new PageLabelStyle(PageNumbering.Decimal, "a\nb", 1)));
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [0], new PageLabelStyle(PageNumbering.Decimal, "", 0)));
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [0], new PageLabelStyle(PageNumbering.Decimal, "", PageLabels.MaxStart + 1)));
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [0], new PageLabelStyle(PageNumbering.None, "", 1)));
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [2], Roman));
        Assert.Throws<ArgumentException>(() => PageLabels.Write(pdf, null, [], Roman));
    }

    [Fact]
    public void PageEditsKeepTheLabelsWritten_AndAReplacedPageKeepsItsOwn()
    {
        var labeled = PageLabels.Write(TestPdf.Make(4), null, [0, 1], Roman, restartAfter: true);
        Assert.Equal(["i", "ii", "1", "2"], Labels(labeled));
        var replaced = PageEditor.Replace(labeled, null, [1, 2], new PdfSource(TestPdf.Make(2, "new"), null, "x.pdf"), [0, 1]);
        Assert.Equal(["i", "ii", "1", "2"], Labels(replaced));
        Assert.Equal(["ii", "1", "2", "i"], Labels(PageEditor.Move(labeled, null, 4, [0], 4)));
    }

    [Fact]
    public void ASignedFileTakesThemAsAnAppendedChange()
    {
        var signed = SignedEditTests.Signed();
        var (edited, report) = SignedEdits.Run(() => PageLabels.Write(signed, null, [0], new PageLabelStyle(PageNumbering.None, "Cover", 1), restartAfter: true));
        Assert.True(report.Appended);
        Assert.True(edited.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal(["Cover", "1"], Labels(edited));
    }
}
