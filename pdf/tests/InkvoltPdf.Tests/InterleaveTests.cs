using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Interleave Pages and Scan the Backs (roadmap 4.3): fronts, then backs, put together sheet by sheet.</summary>
public class InterleaveTests
{
    [Fact]
    public void BacksScannedAfterTurningTheStackOverComeLastPageFirst()
    {
        Assert.Equal([0, 5, 1, 4, 2, 3], PageEditor.InterleaveOrder(6, [0, 1, 2], [3, 4, 5], reverseBacks: true));
        Assert.Equal([0, 3, 1, 4, 2, 5], PageEditor.InterleaveOrder(6, [0, 1, 2], [3, 4, 5], reverseBacks: false));
    }

    [Fact]
    public void OtherPagesStayWhereTheyAre_AndWhatOneSideHasLeftOverFollows()
    {
        // A cover page before the scan, three fronts and two backs, a page after.
        Assert.Equal([0, 1, 4, 2, 5, 3, 6], PageEditor.InterleaveOrder(7, [1, 2, 3], [4, 5], reverseBacks: false));
        Assert.Equal([0, 1, 5, 4, 3, 2], PageEditor.InterleaveOrder(6, [1], [2, 3, 4, 5], reverseBacks: true));
    }

    [Fact]
    public void APageOnBothSides_OrASideWithNone_IsRefused()
    {
        Assert.Throws<ArgumentException>(() => PageEditor.InterleaveOrder(4, [0, 1], [1, 2], false));
        Assert.Throws<ArgumentException>(() => PageEditor.InterleaveOrder(4, [], [1, 2], false));
        Assert.Throws<ArgumentException>(() => PageEditor.InterleaveOrder(4, [0], [4], false));
    }

    [Fact]
    public void TwoRangesOfOneDocument()
    {
        var pdf = PageEditor.Interleave(TestPdf.Make(6), null, [0, 1, 2], [3, 4, 5], reverseBacks: true);
        Assert.Equal([1, 6, 2, 5, 3, 4], TestPdf.PageNumbers(pdf));
    }

    [Fact]
    public void BacksFromAnotherFile_KeepTheFrontsBookmarks()
    {
        var fronts = Bookmarks.SetOutline(TestPdf.Make(3, "front"), null, [new Bookmark("Second sheet", 1)]);
        var pdf = PageEditor.InterleaveWith(fronts, null, new PdfSource(TestPdf.Make(3, "back"), null, "backs.pdf"), reverseBacks: true);

        Assert.Equal([1, 3, 2, 2, 3, 1], TestPdf.PageNumbers(pdf));
        using (var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null))
            Assert.Equal(["front", "back", "front", "back", "front", "back"],
                Enumerable.Range(0, 6).Select(i => engine.GetText(i).Text.Contains("front") ? "front" : "back"));
        Assert.Equal(2, Bookmarks.Read(pdf, null).Single().PageIndex); // the second front, now the third page
    }

    [Fact]
    public void ASignedFileTakesTheBacksAsAnAppendedChange()
    {
        var signed = SignedEditTests.Signed();
        var (edited, report) = SignedEdits.Run(() => PageEditor.InterleaveWith(signed, null, new PdfSource(TestPdf.Make(2, "back"), null, "backs.pdf"), true));
        Assert.True(report.Appended);
        Assert.True(edited.AsSpan(0, signed.Length).SequenceEqual(signed));
        // The signed revision stays as it was signed; added pages show as a change no signature allows, as a rotation does.
        Assert.Equal(SignatureStatus.DisallowedChanges, Signatures.Verify(edited).Single(s => s.FieldName == "Approval").Status);
        using var engine = PdfEngine.Open(edited, MuPDFCore.InputFileTypes.PDF, null);
        Assert.Equal(4, engine.PageCount);
        Assert.Contains("Page 2 back", engine.GetText(1).Text);
        Assert.Contains("Second page", engine.GetText(2).Text);
    }

    [Fact]
    public void PageLabelsAreNumberedOnThroughTheInterleavedPages_NoneShownTwice()
    {
        // A preface in i, ii, then six scanned pages labeled 1-6: the interleaved ones read 1-6 again, in their new order.
        var labeled = PageLabels.Write(TestPdf.Make(8), null, [0, 1], new PageLabelStyle(PageNumbering.LowerRoman, "", 1), restartAfter: true);
        var pdf = PageEditor.Interleave(labeled, null, [2, 3, 4], [5, 6, 7], reverseBacks: true);
        Assert.Equal(["i", "ii", "1", "2", "3", "4", "5", "6"], DocumentFeatures.PageLabels(pdf, null)!);
        Assert.Equal([1, 2, 3, 8, 4, 7, 5, 6], TestPdf.PageNumbers(pdf));

        // Backs from another file take labels too.
        var with = PageEditor.InterleaveWith(PageLabels.Write(TestPdf.Make(2), null, [0, 1], new PageLabelStyle(PageNumbering.Decimal, "A-", 1)), null,
            new PdfSource(TestPdf.Make(2, "back"), null, "backs.pdf"), reverseBacks: false);
        Assert.Equal(["A-1", "A-2", "A-3", "A-4"], DocumentFeatures.PageLabels(with, null)!);
    }

    [Fact]
    public void PlainLabelsAreDropped_TheNumbersShowAnyway()
    {
        var pdf = PlainLabels(TestPdf.Make(4));
        Assert.Equal(["1", "2", "3", "4"], DocumentFeatures.PageLabels(pdf, null)!);
        Assert.Null(DocumentFeatures.PageLabels(PageEditor.Interleave(pdf, null, [0, 1], [2, 3], true), null));
        Assert.Null(DocumentFeatures.PageLabels(TestPdf.Make(2), null));
        Assert.Null(DocumentFeatures.PageLabels(PageEditor.Interleave(TestPdf.Make(4), null, [0, 1], [2, 3], true), null));

        static byte[] PlainLabels(byte[] data)
        {
            using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(data), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify);
            var range = new PdfSharp.Pdf.PdfDictionary(doc);
            range.Elements.SetName("/S", "/D");
            var tree = new PdfSharp.Pdf.PdfDictionary(doc);
            tree.Elements["/Nums"] = new PdfSharp.Pdf.PdfArray(doc, new PdfSharp.Pdf.PdfInteger(0), range);
            doc.Internals.Catalog.Elements["/PageLabels"] = tree;
            using var ms = new MemoryStream();
            doc.Save(ms, false);
            return ms.ToArray();
        }
    }
}
