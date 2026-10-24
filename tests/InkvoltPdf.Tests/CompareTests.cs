using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Compare two PDFs: the word diff, words of a page, page alignment, change grouping and the pixel overlay.</summary>
public class CompareTests
{
    private static string[] W(string s) => s.Split(' ', StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Rebuilds both sides from the ops, so every op must cover the sequences in order without gaps.</summary>
    private static void AssertCovers(string[] a, string[] b, List<DiffOp> ops)
    {
        int ia = 0, ib = 0;
        foreach (var op in ops)
        {
            Assert.True(op.Length > 0, "empty op");
            Assert.Equal(ia, op.A);
            Assert.Equal(ib, op.B);
            switch (op.Kind)
            {
                case DiffKind.Equal:
                    for (var k = 0; k < op.Length; k++) Assert.Equal(a[ia + k], b[ib + k]);
                    ia += op.Length;
                    ib += op.Length;
                    break;
                case DiffKind.Delete: ia += op.Length; break;
                case DiffKind.Insert: ib += op.Length; break;
            }
        }
        Assert.Equal(a.Length, ia);
        Assert.Equal(b.Length, ib);
        for (var i = 1; i < ops.Count; i++) Assert.NotEqual(ops[i - 1].Kind, ops[i].Kind); // runs are merged
    }

    private static int Matched(List<DiffOp> ops) => ops.Where(o => o.Kind == DiffKind.Equal).Sum(o => o.Length);

    private static int Lcs(string[] a, string[] b)
    {
        var d = new int[a.Length + 1, b.Length + 1];
        for (var i = 1; i <= a.Length; i++)
            for (var j = 1; j <= b.Length; j++)
                d[i, j] = a[i - 1] == b[j - 1] ? d[i - 1, j - 1] + 1 : Math.Max(d[i - 1, j], d[i, j - 1]);
        return d[a.Length, b.Length];
    }

    [Fact]
    public void IdenticalWordsAreOneEqualRun()
    {
        var a = W("the quick brown fox");
        var ops = WordDiff.Diff(a, a);
        Assert.Equal([new DiffOp(DiffKind.Equal, 0, 0, 4)], ops);
    }

    [Fact]
    public void InsertedDeletedAndReplacedWordsAreFound()
    {
        var ops = WordDiff.Diff(W("a b c d"), W("a x b c d"));
        Assert.Equal([new DiffOp(DiffKind.Equal, 0, 0, 1), new DiffOp(DiffKind.Insert, 1, 1, 1), new DiffOp(DiffKind.Equal, 1, 2, 3)], ops);

        ops = WordDiff.Diff(W("a b c d"), W("a c d"));
        Assert.Equal([new DiffOp(DiffKind.Equal, 0, 0, 1), new DiffOp(DiffKind.Delete, 1, 1, 1), new DiffOp(DiffKind.Equal, 2, 1, 2)], ops);

        ops = WordDiff.Diff(W("pay 100 dollars now"), W("pay 150 dollars now"));
        Assert.Equal([new DiffOp(DiffKind.Equal, 0, 0, 1), new DiffOp(DiffKind.Delete, 1, 1, 1), new DiffOp(DiffKind.Insert, 2, 1, 1), new DiffOp(DiffKind.Equal, 2, 2, 2)], ops);
    }

    [Fact]
    public void EmptySidesAreAllInsertedOrAllDeleted()
    {
        Assert.Empty(WordDiff.Diff([], []));
        Assert.Equal([new DiffOp(DiffKind.Insert, 0, 0, 2)], WordDiff.Diff([], W("a b")));
        Assert.Equal([new DiffOp(DiffKind.Delete, 0, 0, 2)], WordDiff.Diff(W("a b"), []));
    }

    [Fact]
    public void MyersFindsAShortestEditScript()
    {
        // The stretches between unique-word anchors go to Myers, which must be minimal: checked against the LCS.
        var rng = new Random(7);
        for (var round = 0; round < 300; round++)
        {
            var a = Enumerable.Range(0, rng.Next(0, 30)).Select(_ => "xyz"[rng.Next(3)].ToString()).ToArray();
            var b = Enumerable.Range(0, rng.Next(0, 30)).Select(_ => "xyz"[rng.Next(3)].ToString()).ToArray();
            var ops = WordDiff.Shortest(a, b);
            AssertCovers(a, b, ops);
            Assert.Equal(Lcs(a, b), Matched(ops));
            AssertCovers(a, b, WordDiff.Diff(a, b));
        }
    }

    [Fact]
    public void RandomEditsAreValidAndNearlyMinimal()
    {
        var rng = new Random(11);
        var vocabulary = Enumerable.Range(0, 40).Select(i => $"w{i}").ToArray();
        for (var round = 0; round < 200; round++)
        {
            var a = Enumerable.Range(0, rng.Next(0, 60)).Select(_ => vocabulary[rng.Next(vocabulary.Length)]).ToArray();
            var b = a.ToList();
            for (var e = rng.Next(0, 6); e > 0; e--)
            {
                var at = rng.Next(0, b.Count + 1);
                switch (rng.Next(3))
                {
                    case 0: b.Insert(at, vocabulary[rng.Next(vocabulary.Length)]); break;
                    case 1 when at < b.Count: b.RemoveAt(at); break;
                    default: if (at < b.Count) b[at] = vocabulary[rng.Next(vocabulary.Length)]; break;
                }
            }
            var ops = WordDiff.Diff(a, [.. b]);
            AssertCovers(a, [.. b], ops);
            // Anchoring on unique words can cost a little against the true LCS, never much.
            Assert.True(Matched(ops) >= Lcs(a, [.. b]) - 3, $"round {round}: matched {Matched(ops)} of LCS {Lcs(a, [.. b])}");
            // Sliding runs anywhere keeps the script valid and as short.
            var salt = rng.Next();
            var slid = WordDiff.Slide(ops, a, [.. b], (k, s, e) => HashCode.Combine(salt, k, s) % 7);
            AssertCovers(a, [.. b], slid);
            Assert.Equal(Matched(ops), Matched(slid));
        }
    }

    [Fact]
    public void LargeUnrelatedInputsFinishQuicklyAndStayValid()
    {
        var a = Enumerable.Range(0, 60_000).Select(i => $"a{i}").ToArray();
        var b = Enumerable.Range(0, 60_000).Select(i => $"a{59_999 - i}").ToArray(); // reversed: unique anchors everywhere
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var ops = WordDiff.Diff(a, b);
        Assert.True(sw.ElapsedMilliseconds < 5000, $"took {sw.ElapsedMilliseconds} ms");
        AssertCovers(a, b, ops);

        var c = Enumerable.Range(0, 40_000).Select(i => i % 3 == 0 ? "x" : "y").ToArray();
        var d = Enumerable.Range(0, 40_000).Select(i => i % 5 == 0 ? "x" : "y").ToArray(); // no unique words at all
        sw.Restart();
        ops = WordDiff.Diff(c, d);
        Assert.True(sw.ElapsedMilliseconds < 5000, $"took {sw.ElapsedMilliseconds} ms");
        AssertCovers(c, d, ops);
    }

    [Fact]
    public void DiffCanBeCancelled()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => WordDiff.Diff(W("a b"), W("a c"), cts.Token));
    }

    // ---- Words of a page ----

    private const double CW = 6, CH = 10;

    /// <summary>A page whose lines are the given strings, fixed-width characters, one line every 14 pt.</summary>
    private static PageText Page(params string[] lines) =>
        new([.. lines.Select((l, li) => l.Select((c, i) => (c.ToString(), new RectD(50 + i * CW, 50 + li * 14, CW, CH))).ToList())]);

    [Fact]
    public void WordsSplitPunctuationKeepNumbersWholeAndJoinHyphenatedLineBreaks()
    {
        var page = Page("Hello, world: 1,250.75 was 3.", "the exam-", "ple ﬁle");
        var words = CompareWords.Of(page, 2);
        Assert.Equal(["Hello", ",", "world", ":", "1,250.75", "was", "3", ".", "the", "example", "file"], words.Select(w => w.Key));
        Assert.All(words, w => Assert.Equal(2, w.Page));
        var example = words.Single(w => w.Key == "example");
        Assert.Equal("exam-\nple", page.Text[example.Start..example.End]);
        var hello = words[0];
        Assert.Equal((0, 5), (hello.Start, hello.End));
    }

    // ---- Page alignment and changes ----

    private static PageText[] Pages(params string[] pages) => [.. pages.Select(p => p.Length == 0 ? PageText.Empty : Page(p))];

    private static (int? Old, int? New)[] Rows(CompareResult r) => [.. r.Rows.Select(x => (x.OldPage, x.NewPage))];

    [Fact]
    public void IdenticalDocumentsPairPageByPageWithNoChanges()
    {
        var pages = Pages("alpha one", "beta two", "gamma three");
        var r = DocumentCompare.Run(pages, pages);
        Assert.Equal([(0, 0), (1, 1), (2, 2)], Rows(r));
        Assert.Empty(r.Changes);
        Assert.True(r.Identical);
        Assert.All(r.Rows, x => Assert.Equal(RowText.Compared, x.Text));
    }

    [Fact]
    public void AnEditedWordIsOneChangedChangeOnItsRowWithBothSidesHighlighted()
    {
        var r = DocumentCompare.Run(Pages("alpha one", "the fee is 100 dollars", "gamma three"), Pages("alpha one", "the fee is 150 dollars", "gamma three"));
        Assert.Equal([(0, 0), (1, 1), (2, 2)], Rows(r));
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.Changed, c.Kind);
        Assert.Equal(1, c.Row);
        Assert.Equal("100", c.OldText);
        Assert.Equal("150", c.NewText);
        Assert.Equal([new WordSpan(1, 11, 14)], c.Old);
        Assert.Equal([new WordSpan(1, 11, 14)], c.New);
        Assert.Equal((1, 0, 0, 0), (r.Changed, r.Inserted, r.Deleted, r.PagesInserted + r.PagesRemoved));
        Assert.Equal(1, r.Rows[1].Changes);
        Assert.False(r.Identical);
    }

    [Fact]
    public void InsertedAndDeletedWordsAnchorOnTheOtherSide()
    {
        var r = DocumentCompare.Run(Pages("one two three four"), Pages("one three four five"));
        Assert.Equal(2, r.Changes.Count);
        var del = r.Changes[0];
        Assert.Equal(ChangeKind.Deleted, del.Kind);
        Assert.Equal("two", del.OldText);
        Assert.Empty(del.New);
        Assert.Equal(new WordSpan(0, 3, 3), del.NewAnchor); // right after "one" in the new text
        var ins = r.Changes[1];
        Assert.Equal(ChangeKind.Inserted, ins.Kind);
        Assert.Equal("five", ins.NewText);
        Assert.Equal(new WordSpan(0, 18, 18), ins.OldAnchor); // after "four" in the old text
        Assert.Equal((0, 1, 1), (r.Changed, r.Inserted, r.Deleted));
    }

    [Fact]
    public void ARemovedPageIsOnePageChangeNotAWallOfDeletedWords()
    {
        var r = DocumentCompare.Run(Pages("alpha one", "beta removed text here", "gamma three"), Pages("alpha one", "gamma three"));
        Assert.Equal([(0, 0), (1, null), (2, 1)], Rows(r));
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.PageRemoved, c.Kind);
        Assert.Equal(1, c.Row);
        Assert.Equal(1, r.PagesRemoved);
        Assert.Equal(RowText.OnlyOld, r.Rows[1].Text);
    }

    [Fact]
    public void AnInsertedPageIsFoundEvenWhenItRepeatsWordsOfItsNeighbours()
    {
        var r = DocumentCompare.Run(Pages("intro text", "chapter one body", "chapter two body"),
            Pages("intro text", "chapter one body", "new chapter body", "chapter two body"));
        Assert.Equal([(0, 0), (1, 1), (null, 2), (2, 3)], Rows(r));
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.PageInserted, c.Kind);
        Assert.Equal(2, c.Row);
        Assert.Equal(1, r.PagesInserted);
    }

    [Fact]
    public void APageRewrittenInPlaceStaysPairedAsChanged()
    {
        var r = DocumentCompare.Run(Pages("alpha one", "old words entirely", "gamma three"), Pages("alpha one", "brand new content", "gamma three"));
        Assert.Equal([(0, 0), (1, 1), (2, 2)], Rows(r));
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.Changed, c.Kind);
        Assert.Equal("old words entirely", c.OldText);
        Assert.Equal("brand new content", c.NewText);
    }

    [Fact]
    public void TextMovingToTheNextPageIsNotAChange()
    {
        // The same words reflowed: the last line of page 1 moved to the top of page 2.
        var r = DocumentCompare.Run(Pages("one two three", "four five six"), Pages("one two", "three four five six"));
        Assert.Equal([(0, 0), (1, 1)], Rows(r));
        Assert.Empty(r.Changes);
    }

    [Fact]
    public void ScannedPagesSayTheyHaveNoTextInsteadOfReportingEveryWordAsChanged()
    {
        var r = DocumentCompare.Run(Pages("alpha one", "beta two"), Pages("", ""));
        Assert.Equal([(0, 0), (1, 1)], Rows(r));
        Assert.Empty(r.Changes);
        Assert.All(r.Rows, x => Assert.Equal(RowText.NoTextNew, x.Text));
        Assert.Equal(2, r.PairsWithoutText);
        Assert.False(r.Identical); // nothing proves they're the same

        r = DocumentCompare.Run(Pages("", "", ""), Pages("", ""));
        Assert.Equal([(0, 0), (1, 1), (2, null)], Rows(r));
        Assert.Equal(RowText.NoTextBoth, r.Rows[0].Text);
        Assert.Equal(ChangeKind.PageRemoved, Assert.Single(r.Changes).Kind);
    }

    [Fact]
    public void AMixOfScannedAndTextPagesComparesTheTextOnes()
    {
        var r = DocumentCompare.Run(Pages("alpha one", "", "gamma three"), Pages("alpha uno", "", "gamma three"));
        Assert.Equal([(0, 0), (1, 1), (2, 2)], Rows(r));
        Assert.Equal(RowText.NoTextBoth, r.Rows[1].Text);
        var c = Assert.Single(r.Changes);
        Assert.Equal(("one", "uno", 0), (c.OldText, c.NewText, c.Row));
        Assert.Equal(1, r.PairsWithoutText);
    }

    [Fact]
    public void ChangesSplitAtPageBreaks()
    {
        // "x y" were added at the end of page 1 and the start of page 2 of the new file.
        var r = DocumentCompare.Run(Pages("one two", "three four"), Pages("one two x", "y three four"));
        Assert.Equal(2, r.Changes.Count);
        Assert.Equal((ChangeKind.Inserted, 0, "x"), (r.Changes[0].Kind, r.Changes[0].Row, r.Changes[0].NewText));
        Assert.Equal((ChangeKind.Inserted, 1, "y"), (r.Changes[1].Kind, r.Changes[1].Row, r.Changes[1].NewText));
    }

    [Fact]
    public void ManyPagesAlignFast()
    {
        var oldPages = Enumerable.Range(0, 1500).Select(i => Page($"page {i} unique{i} common words here", $"more text {i}")).ToArray();
        var newPages = oldPages.Where((_, i) => i % 100 != 7).ToList();
        newPages.Insert(500, Page("an inserted page", "with lines"));
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var r = DocumentCompare.Run(oldPages, newPages);
        Assert.True(sw.ElapsedMilliseconds < 10_000, $"took {sw.ElapsedMilliseconds} ms");
        Assert.Equal(15, r.PagesRemoved);
        Assert.Equal(1, r.PagesInserted);
        Assert.Equal(0, r.Inserted + r.Deleted + r.Changed);
    }

    [Fact]
    public void SummaryNamesWhatChanged()
    {
        Assert.Equal("No differences in the text", DocumentCompare.Run(Pages("a b"), Pages("a b")).Summary());
        Assert.Equal("2 text changes (1 inserted, 1 changed)", DocumentCompare.Run(Pages("one two three"), Pages("one 2 three four")).Summary());
        Assert.Equal("No text changes; 1 page removed; 1 page without text to compare",
            DocumentCompare.Run(Pages("alpha one", "beta two words", ""), Pages("alpha one", "")).Summary());
    }

    [Fact]
    public void SlidingMovesARunToThePlaceThatCostsLeast()
    {
        // "b a b" inserted into "a b": the diff may put the run anywhere along the repeats; the cost picks the end.
        string[] a = ["a", "b"], b = ["a", "b", "a", "b"];
        var ops = WordDiff.Slide(WordDiff.Diff(a, b), a, b, (kind, s, e) => kind == DiffKind.Insert ? -s : 0);
        Assert.Equal([new DiffOp(DiffKind.Equal, 0, 0, 2), new DiffOp(DiffKind.Insert, 2, 2, 2)], ops);
        ops = WordDiff.Slide(WordDiff.Diff(a, b), a, b, (kind, s, e) => kind == DiffKind.Insert ? s : 0);
        Assert.Equal([new DiffOp(DiffKind.Insert, 0, 0, 2), new DiffOp(DiffKind.Equal, 0, 2, 2)], ops);
    }

    // ---- Real PDFs (MuPDF text) and the report ----

    private static PageText[] TextOf(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
        return [.. Enumerable.Range(0, engine.PageCount).Select(p => engine.GetText(p, cache: false))];
    }

    [Fact]
    public void RealPdfsCompareWordByWordAndTheReportMarksTheChanges()
    {
        var oldPdf = TestPdf.Make(3, "alpha");
        var newPdf = TestPdf.Make(3, "beta");
        var newText = TextOf(newPdf);
        var r = DocumentCompare.Run(TextOf(oldPdf), newText);
        Assert.Equal([(0, 0), (1, 1), (2, 2)], Rows(r));
        Assert.Equal(3, r.Changes.Count);
        Assert.All(r.Changes, c => Assert.Equal((ChangeKind.Changed, "alpha", "beta"), (c.Kind, c.OldText, c.NewText)));

        var report = CompareReport.Annotate(newPdf, null, r, newText, "old.pdf", r.Summary());
        var annots = Annotations.Read(report, null);
        Assert.Equal(3, annots.Count(a => a.Kind == AnnotationKind.Highlight && a.Contents.Contains("“alpha”") && a.Author == CompareReport.Author));
        var summary = Assert.Single(annots, a => a.Kind == AnnotationKind.Text);
        Assert.Equal((0, "3 text changes (3 changed)"), (summary.PageIndex, summary.Contents));
        var mark = annots.First(a => a.Kind == AnnotationKind.Highlight);
        var word = newText[mark.PageIndex].Find("beta", true, true).Single();
        var box = newText[mark.PageIndex].GetRects(word.Start, word.End)[0];
        Assert.True(mark.Rect.Contains(box.CenterX, box.CenterY), "the highlight covers the changed word");
    }

    [Fact]
    public void TheReportNotesRemovedWordsAndPages()
    {
        var oldText = Pages("one two three", "a page that goes", "four five");
        var newPdf = TestPdf.Make(2, "x");
        var newText = Pages("one three", "four five");
        var r = DocumentCompare.Run(oldText, newText);
        var annots = Annotations.Read(CompareReport.Annotate(newPdf, null, r, newText, "old.pdf", r.Summary()), null);
        Assert.Contains(annots, a => a.Kind == AnnotationKind.Text && a.PageIndex == 0 && a.Contents == "Removed: “two”");
        Assert.Contains(annots, a => a.Kind == AnnotationKind.Text && a.PageIndex == 1 && a.Contents.StartsWith("Removed page: page 2 of old.pdf was here: “a page that goes”"));
    }

    /// <summary>
    /// A two-version contract for the compare samples: wording edits, a removed and an inserted page, and a drawing
    /// with no text that changed. With INKVOLTPDF_SAMPLES set they are written there (compare-old.pdf, compare-new.pdf).
    /// </summary>
    internal static (byte[] Old, byte[] New) ContractVersions()
    {
        PdfSharp.Fonts.GlobalFontSettings.UseWindowsFontsUnderWindows = true;
        string[][] oldPages =
        [
            ["Service Agreement", "This agreement is made between Contoso Ltd and Fabrikam Inc.", "The term of this agreement is twelve months from the start date.",
             "Fees: the client pays 1,200 dollars per month, due on the first day.", "Either party may end it with 30 days written notice."],
            ["Scope of work", "Fabrikam maintains the reception area, the meeting rooms", "and the kitchen on every working day.", "Supplies are ordered by Contoso."],
            ["Appendix A: old schedule", "Cleaning happens on Mondays and Thursdays."],
            [],
        ];
        string[][] newPages =
        [
            ["Service Agreement", "This agreement is made between Contoso Ltd and Fabrikam Inc.", "The term of this agreement is eighteen months from the start date.",
             "Fees: the client pays 1,450 dollars per month, due on the first day.", "Late payments incur a 2% fee.", "Either party may end it with 30 days notice."],
            ["Scope of work", "Fabrikam maintains the reception area, the meeting rooms", "and the kitchen on every working day.", "Supplies are ordered by Contoso."],
            ["Appendix B: support hours", "Support is available from 8 am to 6 pm."],
            [],
        ];
        return (Contract(oldPages, moved: false), Contract(newPages, moved: true));

        static byte[] Contract(string[][] pages, bool moved)
        {
            using var doc = new PdfSharp.Pdf.PdfDocument();
            var title = new PdfSharp.Drawing.XFont("Arial", 20, PdfSharp.Drawing.XFontStyleEx.Bold);
            var body = new PdfSharp.Drawing.XFont("Arial", 12);
            foreach (var lines in pages)
            {
                var page = doc.AddPage();
                page.Width = PdfSharp.Drawing.XUnit.FromPoint(612);
                page.Height = PdfSharp.Drawing.XUnit.FromPoint(792);
                using var gfx = PdfSharp.Drawing.XGraphics.FromPdfPage(page);
                if (lines.Length == 0)
                {
                    // A floor plan with no text, as a scan or a drawing would be: one room moves, a table is added.
                    var pen = new PdfSharp.Drawing.XPen(PdfSharp.Drawing.XColors.Black, 3);
                    gfx.DrawRectangle(pen, 72, 100, 468, 300);
                    gfx.DrawLine(pen, 300, 100, 300, 400);
                    gfx.DrawRectangle(pen, moved ? 360 : 330, 180, 120, 90);
                    gfx.DrawEllipse(pen, 120, 200, 80, 80);
                    if (moved) gfx.DrawEllipse(pen, 140, 450, 60, 60);
                    continue;
                }
                gfx.DrawString(lines[0], title, PdfSharp.Drawing.XBrushes.Black, new PdfSharp.Drawing.XPoint(72, 90));
                for (var i = 1; i < lines.Length; i++)
                    gfx.DrawString(lines[i], body, PdfSharp.Drawing.XBrushes.Black, new PdfSharp.Drawing.XPoint(72, 130 + i * 20));
            }
            using var ms = new MemoryStream();
            doc.Save(ms, false);
            return ms.ToArray();
        }
    }

    [Fact]
    public void ContractVersionsCompareAsAPersonWouldDescribeThem()
    {
        var (oldPdf, newPdf) = ContractVersions();
        var r = DocumentCompare.Run(TextOf(oldPdf), TextOf(newPdf));
        Assert.Equal([(0, 0), (1, 1), (2, 2), (3, 3)], Rows(r)); // the appendix was rewritten in place
        Assert.Equal(RowText.NoTextBoth, r.Rows[3].Text);
        var texts = r.Changes.Select(c => (c.Kind, c.OldText, c.NewText)).ToList();
        Assert.Contains((ChangeKind.Changed, "twelve", "eighteen"), texts);
        Assert.Contains((ChangeKind.Changed, "1,200", "1,450"), texts);
        Assert.Contains((ChangeKind.Inserted, "", "Late payments incur a 2% fee."), texts);
        Assert.Contains((ChangeKind.Deleted, "written", ""), texts);
        Assert.All(r.Changes, c => Assert.NotEqual(1, c.Row)); // page 2 didn't change
        Assert.Equal(1, r.PairsWithoutText);

        using var a = PdfEngine.Open(oldPdf, MuPDFCore.InputFileTypes.PDF, null);
        using var b = PdfEngine.Open(newPdf, MuPDFCore.InputFileTypes.PDF, null);
        var visual = VisualCompare.Overlay(a.Render(3, 0.7), b.Render(3, 0.7));
        Assert.True(visual.Regions.Count is >= 2 and <= 4, $"{visual.Regions.Count} regions"); // the moved room (both places) and the new table
        Assert.Empty(VisualCompare.Overlay(a.Render(1, 0.7), b.Render(1, 0.7)).Regions);

        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "compare-old.pdf"), oldPdf);
            File.WriteAllBytes(Path.Combine(dir, "compare-new.pdf"), newPdf);
        }
    }

    // ---- Pixel overlay ----

    private static RenderedImage Blank(int w, int h)
    {
        var px = new byte[w * h * 3];
        Array.Fill(px, (byte)255);
        return new RenderedImage(w, h, px);
    }

    private static RenderedImage WithBox(RenderedImage img, int x, int y, int w, int h, byte value = 0)
    {
        var px = (byte[])img.Pixels.Clone();
        for (var yy = y; yy < y + h; yy++)
            for (var xx = x; xx < x + w; xx++)
                px[yy * img.Stride + xx * 3] = px[yy * img.Stride + xx * 3 + 1] = px[yy * img.Stride + xx * 3 + 2] = value;
        return new RenderedImage(img.Width, img.Height, px);
    }

    private static (byte B, byte G, byte R) At(RenderedImage img, int x, int y) =>
        (img.Pixels[y * img.Stride + x * 3], img.Pixels[y * img.Stride + x * 3 + 1], img.Pixels[y * img.Stride + x * 3 + 2]);

    [Fact]
    public void IdenticalImagesHaveNoDifferencesAndShowGrey()
    {
        var a = WithBox(Blank(100, 80), 10, 10, 20, 20);
        var r = VisualCompare.Overlay(a, a);
        Assert.Equal(0, r.ChangedPixels);
        Assert.Empty(r.Regions);
        var (b, g, rr) = At(r.Image, 15, 15);
        Assert.True(b == g && g == rr && rr < 200, "shared ink is grey");
        Assert.Equal(((byte)255, (byte)255, (byte)255), At(r.Image, 90, 70));
    }

    [Fact]
    public void InkOnlyInOneSideIsTintedAndBoxed()
    {
        var blank = Blank(200, 100);
        var oldImg = WithBox(blank, 10, 10, 20, 20);
        var newImg = WithBox(blank, 150, 50, 30, 30);
        var r = VisualCompare.Overlay(oldImg, newImg);
        Assert.Equal(20 * 20 + 30 * 30, r.ChangedPixels);
        var removed = At(r.Image, 15, 15);
        Assert.True(removed.R > 150 && removed.B < 100, $"removed ink is red: {removed}");
        var added = At(r.Image, 160, 60);
        Assert.True(added.B > 150 && added.R < 100, $"added ink is blue: {added}");
        Assert.Equal(2, r.Regions.Count);
        Assert.Contains(r.Regions, x => x.Contains(10, 10) && x.Contains(29, 29) && x.Width < 40);
        Assert.Contains(r.Regions, x => x.Contains(150, 50) && x.Contains(179, 79));
    }

    [Fact]
    public void FaintNoiseAndLonePixelsAreIgnored()
    {
        var a = Blank(64, 64);
        var b = WithBox(WithBox(a, 5, 5, 40, 40, 235), 50, 50, 1, 1); // faint tint, and one dark pixel
        var r = VisualCompare.Overlay(a, b);
        Assert.Empty(r.Regions);
        Assert.Equal(1, r.ChangedPixels);
    }

    [Fact]
    public void PagesOfDifferentSizesOverlayAtTheTopLeft()
    {
        var r = VisualCompare.Overlay(Blank(50, 40), WithBox(Blank(60, 70), 0, 50, 60, 20));
        Assert.Equal((60, 70), (r.Image.Width, r.Image.Height));
        Assert.Equal(60 * 20, r.ChangedPixels);
        Assert.Single(r.Regions);
    }
}
