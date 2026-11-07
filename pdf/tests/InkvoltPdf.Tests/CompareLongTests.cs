using Inkvolt.Testing;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Compare on a long document against a short one: the work grows with the pages and words, never with their product, and a
/// cancel stops it. Alone: a processor-time limit that other tests' collections inflate.
/// </summary>
[Collection(Timing.Alone)]
public class CompareLongTests
{
    /// <summary>
    /// <paramref name="count"/> pages of 25 lines of words from a small vocabulary, as a long report has, and a heading that
    /// names the page.
    /// </summary>
    private static PageText[] LongDocument(int count)
    {
        string[] vocabulary = ["the", "contract", "of", "and", "party", "shall", "to", "in", "any", "notice", "term", "payment", "a", "by", "agreement", "section", "is", "for", "with", "under"];
        var rng = new Random(11);
        return [.. Enumerable.Range(0, count).Select(p => CompareTests.Page([$"Page {p} heading{p}",
            .. Enumerable.Range(0, 25).Select(_ => string.Join(' ', Enumerable.Range(0, 8).Select(_ => vocabulary[rng.Next(vocabulary.Length)])))]))];
    }

    /// <summary>
    /// A long document against its first page: every other page is only the old side's. Whether such a page's words moved
    /// was asked of every word of the document, page by page (rows × words: seconds for these 2,000 pages, minutes for 10,000, and no cancelling).
    /// </summary>
    [Fact]
    public void ALongDocumentAgainstOnePageFinishesQuickly()
    {
        var oldPages = LongDocument(2000);
        var watch = new ThreadClock.Stopwatch(); // this thread's processor time: other tests running meanwhile don't count
        watch.Start();
        var r = DocumentCompare.Run(oldPages, [oldPages[0]]);
        watch.Stop();
        Assert.True(watch.Elapsed < Timing.Limit(TimeSpan.FromMilliseconds(750)), $"took {watch.Elapsed}");
        Assert.Equal((0, (int?)0), (r.Rows[0].OldPage!.Value, r.Rows[0].NewPage));
        Assert.Equal(1999, r.PagesRemoved);
        Assert.Equal(0, r.Inserted + r.Deleted + r.Changed + r.Moved);
        Assert.DoesNotContain(r.Rows, row => row.PageMoved);

        // The report: each removed page's note went looking for the next page the new document has (rows × rows).
        var removed = Enumerable.Range(0, 20_000).Select(i => new CompareRow(i, i == 0 ? 0 : null, i == 0 ? RowText.Compared : RowText.OnlyOld)).ToList();
        var big = new CompareResult
        {
            Rows = removed,
            Changes = [.. removed.Skip(1).Select((row, i) => new CompareChange(ChangeKind.PageRemoved, i + 1, [new WordSpan(i + 1, 0, 0)], [], "", ""))],
        };
        watch.Restart();
        var notes = Annotations.Read(CompareReport.Annotate(TestPdf.Make(1, "x"), null, big, [oldPages[0]], "old.pdf", "summary"), null);
        watch.Stop();
        Assert.True(watch.Elapsed < Timing.Limit(TimeSpan.FromMilliseconds(600)), $"report took {watch.Elapsed}");
        Assert.Contains(" 20000 ", Assert.Single(notes).Contents); // every removed page, on the one page there is

        // And the other way round: the long document is the new one.
        r = DocumentCompare.Run([oldPages[0]], oldPages);
        Assert.Equal(1999, r.PagesInserted);
        Assert.Equal(0, r.Inserted + r.Deleted + r.Changed + r.Moved);
    }

    /// <summary>A cancel stops a long compare at once, wherever it is.</summary>
    [Fact]
    public void CancellingALongCompareStopsIt()
    {
        var oldPages = LongDocument(2000);
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            Assert.ThrowsAny<OperationCanceledException>(() => DocumentCompare.Run(oldPages, [oldPages[0]], cancelled.Token));
        }

        // Cancelled at each point of the work in turn: it stops within a moment of the cancel, or had finished.
        var full = System.Diagnostics.Stopwatch.StartNew();
        DocumentCompare.Run(oldPages, [oldPages[0]]);
        var whole = full.Elapsed;
        for (var share = 0.1; share < 1; share += 0.2)
        {
            var delay = whole * share;
            using var cancel = Timing.CancelAfter(delay);
            var clock = System.Diagnostics.Stopwatch.StartNew();
            try { DocumentCompare.Run(oldPages, [oldPages[0]], cancel.Token); }
            catch (OperationCanceledException) { }
            Assert.True(clock.Elapsed < delay + Timing.Limit(TimeSpan.FromMilliseconds(150)), $"cancelled after {delay}, stopped after {clock.Elapsed} (whole: {whole})");
        }
    }
}
