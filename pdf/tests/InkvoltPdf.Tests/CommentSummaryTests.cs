using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Summarize Comments (roadmap 1.4): each page beside its comments, numbered on both sides, long lists continued.</summary>
public class CommentSummaryTests
{
    [Fact]
    public void PutsEachPageBesideItsNumberedComments()
    {
        var source = CommentFilesTests.Commented();
        var plan = CommentSummary.Plan(Annotations.Read(source, null));
        Assert.Equal([0, 1], plan.Select(p => p.Page));
        // Replies come right under their comment, with its number; numbers run on across pages.
        var first = plan[0].Entries;
        var note = first.First(e => e.Comment.Id == "note-1");
        var i = first.ToList().IndexOf(note);
        Assert.Equal(("reply-1", 1, note.Number), (first[i + 1].Comment.Id, first[i + 1].Depth, first[i + 1].Number));
        Assert.Equal(("reply-2", 2, note.Number), (first[i + 2].Comment.Id, first[i + 2].Depth, first[i + 2].Number));
        var numbers = plan.SelectMany(p => p.Entries).Where(e => e.Depth == 0).Select(e => e.Number).ToList();
        Assert.Equal(Enumerable.Range(1, 11), numbers);

        var pdf = CommentSummary.Make(source, null, "Report.pdf");
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        Assert.Equal(2, engine.PageCount);
        Assert.True(engine.GetPage(0).Width > engine.GetPage(0).Height, "landscape sheets");

        var sheet1 = Core2Pdf.AllText(pdf, 0);
        Assert.Contains("Page 1", sheet1);
        Assert.Contains("Comments on Report.pdf", sheet1);
        Assert.Contains("Check this,", sheet1);
        Assert.Contains("Agreed ✓ — señal", sheet1);
        Assert.Contains("Ana Lucía", sheet1);
        var sheet2 = Core2Pdf.AllText(pdf, 1);
        Assert.Contains("Page 2", sheet2);
        Assert.Contains("Callout, text", sheet2); // in the list and on the page

        // Each number is in a disc on the page side and at its entry: twice per sheet.
        foreach (var (page, entries) in plan)
        {
            var words = Core2Pdf.Lines(pdf, page).SelectMany(l => l.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries)).ToList();
            foreach (var n in entries.Where(e => e.Depth == 0).Select(e => e.Number.ToString()))
                Assert.True(words.Count(t => t == n) >= 2, $"number {n} on sheet {page + 1}");
        }

        // The page is drawn at the left (ink there), the list at the right.
        Assert.True(Core2Pdf.Ink(pdf, 0, new RectD(40, 100, 300, 400)) > 0.002);
    }

    [Fact]
    public void LongListsFlowOntoContinuationSheets()
    {
        var pdf = TestPdf.Make(1);
        for (var i = 0; i < 40; i++)
            pdf = Annotations.AddNote(pdf, null, 0, 40 + i * 12, 200 + i * 10, $"Comment {i + 1}: " + string.Concat(Enumerable.Repeat("words that wrap ", 6)), "Rev");
        var summary = CommentSummary.Make(pdf, null, "long.pdf");
        using var engine = PdfEngine.Open(summary, InputFileTypes.PDF, null);
        Assert.True(engine.PageCount >= 3);
        Assert.Contains("Page 1 (continued)", Core2Pdf.AllText(summary, 1));
        var all = string.Join("\n", Enumerable.Range(0, engine.PageCount).Select(p => Core2Pdf.AllText(summary, p)));
        for (var i = 1; i <= 40; i++) Assert.Contains($"Comment {i}:", all);
    }

    [Fact]
    public void NoCommentsNoSummary() =>
        Assert.Throws<InvalidOperationException>(() => CommentSummary.Make(TestPdf.Make(1), null, "x.pdf"));
}
