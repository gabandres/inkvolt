using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Mark All Matches (roadmap 4.18, <see cref="SearchMarks"/>).</summary>
public class SearchMarksTests
{
    private static byte[] Pdf() => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (The invoice total and the invoice date.) Tj 0 -20 Td (No match here.) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> /Rotate 90 >>",
        Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (Page two has an invoice too.) Tj ET"),
    ]);

    private static List<HitToMark> Hits(byte[] pdf, string query)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var hits = new List<HitToMark>();
        foreach (var (page, text, found, _) in engine.FindAll(query, false, true, false, CancellationToken.None))
            foreach (var (s, e) in found) hits.Add(new HitToMark(page, text!.GetRects(s, e)));
        return hits;
    }

    [Fact]
    public void EveryHitBecomesAMarkInOneChange()
    {
        var pdf = Pdf();
        var hits = Hits(pdf, "invoice");
        Assert.Equal(3, hits.Count);
        var result = SearchMarks.Apply(pdf, null, hits, TextMarkupKind.Highlight, "Ana");
        Assert.Equal(new SearchMarksCount(3, 0, 0, 0), result.Count);
        Assert.Equal(result.Count, SearchMarks.Count(pdf, null, hits, TextMarkupKind.Highlight)); // what the undo step is named from
        var marks = Annotations.Read(result.Data, null);
        Assert.Equal(3, marks.Count);
        Assert.All(marks, m => Assert.Equal((AnnotationKind.Highlight, "Ana"), (m.Kind, m.Author)));
        Assert.Equal([0, 0, 1], marks.Select(m => m.PageIndex));
        // Each mark sits on its word, the turned page's too.
        for (var i = 0; i < 3; i++)
        {
            var quad = Assert.Single(marks[i].QuadRects);
            Assert.Equal(hits[i].Rects[0].CenterX, quad.CenterX, 1.5);
            Assert.Equal(hits[i].Rects[0].CenterY, quad.CenterY, 1.5);
        }
    }

    [Fact]
    public void HitsMarkedAlreadyAreLeftAloneAndOtherKindsStillMark()
    {
        var pdf = Pdf();
        var hits = Hits(pdf, "invoice");
        var once = SearchMarks.Apply(pdf, null, hits, TextMarkupKind.Highlight, "Ana").Data;
        var twice = SearchMarks.Apply(once, null, hits, TextMarkupKind.Highlight, "Ana");
        Assert.Equal(new SearchMarksCount(0, 3, 0, 0), twice.Count);
        Assert.Equal(twice.Count, SearchMarks.Count(once, null, hits, TextMarkupKind.Highlight));
        Assert.Same(once, twice.Data); // nothing changed: the same bytes, no edit to undo
        var underlined = SearchMarks.Apply(once, null, hits, TextMarkupKind.Underline, "Ana");
        Assert.Equal(3, underlined.Count.Marked);
        Assert.Equal(6, Annotations.Read(underlined.Data, null).Count);

        // The same hit twice in the list is marked once; hits off the document or without a box are passed over.
        var odd = SearchMarks.Apply(pdf, null, [hits[0], hits[0], new HitToMark(7, hits[0].Rects), new HitToMark(0, []),
            new HitToMark(0, [new RectD(double.NaN, 0, 5, 5)])], TextMarkupKind.StrikeOut, "Ana");
        Assert.Equal(new SearchMarksCount(1, 1, 0, 3), odd.Count);
        Assert.Equal(AnnotationKind.StrikeOut, Assert.Single(Annotations.Read(odd.Data, null)).Kind);
    }

    [Fact]
    public void AtMostTheLimitIsMarked()
    {
        var pdf = Pdf();
        var many = Enumerable.Range(0, SearchMarks.MaxMarks + 10)
            .Select(i => new HitToMark(0, [new RectD(10 + i % 50 * 11, 10 + i / 50 * 7, 10, 6)])).ToList();
        var result = SearchMarks.Apply(pdf, null, many, TextMarkupKind.Highlight, "Ana");
        // The hits past the limit are counted as left for another run, apart from those marked already or without a page.
        Assert.Equal(new SearchMarksCount(SearchMarks.MaxMarks, 0, 10, 0), result.Count);
        var again = SearchMarks.Apply(result.Data, null, [.. many, new HitToMark(9, many[0].Rects)], TextMarkupKind.Highlight, "Ana");
        Assert.Equal(new SearchMarksCount(10, SearchMarks.MaxMarks, 0, 1), again.Count);
    }
}
