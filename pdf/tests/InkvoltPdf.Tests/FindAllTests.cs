using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Find across a document (roadmap 3.6): pages read on several threads, in order, remembered for the next search.</summary>
public class FindAllTests
{
    [Theory]
    [InlineData("fox", false, false)]
    [InlineData("FOX", true, false)]
    [InlineData("quick brown", false, false)]
    [InlineData("Page 3", false, true)]
    [InlineData("lazy  dog", false, false)]
    [InlineData("o", false, true)]
    public void FindsWhatEachPageFindsInPageOrder(string query, bool matchCase, bool wholeWord)
    {
        using var engine = PdfEngine.Open(TestPdf.Make(9), InputFileTypes.PDF, null);
        var all = engine.FindAll(query, matchCase, wholeWord).ToList();

        Assert.Equal(Enumerable.Range(0, 9), all.Select(m => m.Page));
        for (var p = 0; p < 9; p++)
        {
            var expected = engine.GetText(p, cache: false).Find(query, matchCase, wholeWord);
            Assert.Equal(expected, all[p].Hits);
            Assert.Null(all[p].Error);
            if (expected.Count > 0) Assert.Equal(engine.GetText(p).Text, all[p].Text!.Text);
            else Assert.Null(all[p].Text);
        }
    }

    [Fact]
    public void ASecondSearchReadsOnlyThePagesThatCanMatch()
    {
        using var engine = PdfEngine.Open(TestPdf.Make(8), InputFileTypes.PDF, null);
        Assert.Equal(8, engine.FindAll("fox", false, false).Sum(m => m.Hits.Count));
        var read = engine.Extractions;
        Assert.Equal(8, read);

        // Nothing matches: every page's text is remembered, none is read again.
        Assert.All(engine.FindAll("zebra", false, false), m => Assert.Empty(m.Hits));
        Assert.Equal(read, engine.Extractions);

        // One page matches: only it is read again (for its boxes), and its hit has them.
        var found = engine.FindAll("Page 7", false, true).Single(m => m.Hits.Count > 0);
        Assert.Equal(6, found.Page);
        Assert.Equal(read + 1, engine.Extractions);
        Assert.NotEmpty(found.Text!.GetRects(found.Hits[0].Start, found.Hits[0].End));
    }

    [Fact]
    public void PagesAlreadyReadForTheViewAreNotReadAgain()
    {
        using var engine = PdfEngine.Open(TestPdf.Make(3), InputFileTypes.PDF, null);
        engine.GetText(0);
        engine.GetText(1, cache: false);
        var read = engine.Extractions;
        Assert.Equal(3, engine.FindAll("lazy", false, false).Count(m => m.Hits.Count > 0));
        // Page 1 is in the view's cache and page 2 had never been read; page 1's string says it matches, so it is read
        // again for its boxes (it wasn't cached as a whole).
        Assert.Equal(read + 2, engine.Extractions);
    }

    [Fact]
    public void ACancelledSearchStops()
    {
        using var engine = PdfEngine.Open(TestPdf.Make(40), InputFileTypes.PDF, null);
        using var cts = new CancellationTokenSource();
        var seen = 0;
        Assert.Throws<OperationCanceledException>(() =>
        {
            foreach (var _ in engine.FindAll("fox", false, false, cancel: cts.Token))
                if (++seen == 2) cts.Cancel();
        });
        Assert.Equal(2, seen);
    }

    [Fact]
    public void StoppingEarlyAndDisposingLeaveNothingRunning()
    {
        var engine = PdfEngine.Open(TestPdf.Make(30), InputFileTypes.PDF, null);
        var first = engine.FindAll("fox", false, false).First();
        Assert.Equal(0, first.Page);
        Assert.Single(first.Hits);
        engine.Dispose();
        Assert.Throws<ObjectDisposedException>(() => engine.FindAll("fox", false, false).ToList());
        GC.Collect();
        GC.WaitForPendingFinalizers();
    }

    [Fact]
    public void AnEditSearchesTheNewContent()
    {
        using var session = DocumentSession.FromBytes(TestPdf.Make(2, "alpha"), "a.pdf");
        Assert.Equal(2, session.Engine.FindAll("alpha", false, false).Count(m => m.Hits.Count > 0));
        session.Commit(TestPdf.Make(2, "omega"), "Edit");
        Assert.Empty(session.Engine.FindAll("alpha", false, false).SelectMany(m => m.Hits));
        Assert.Equal(2, session.Engine.FindAll("omega", false, false).Count(m => m.Hits.Count > 0));
    }

    [Theory]
    [InlineData("exam-\nple", "example")]
    [InlineData("Café au lait", "cafe")]
    [InlineData("Café au lait", "CAFE")]
    [InlineData("a cat", "at")]
    [InlineData("a cat", "a cat")]
    public void MatchesOnAStringAgreesWithFind(string text, string query)
    {
        var lines = text.Split('\n').Select((l, y) => l.Select((c, i) => (c.ToString(), new RectD(i * 5, y * 12, 5, 10))).ToList()).ToList();
        var page = new PageText(lines);
        Assert.Equal(text, page.Text);
        foreach (var (matchCase, wholeWord, accents) in new[] { (false, false, false), (true, false, false), (false, true, false), (false, false, true) })
            Assert.Equal(page.Find(query, matchCase, wholeWord, accents).Count > 0, PageText.Matches(page.Text, query, matchCase, wholeWord, accents));
    }
}
