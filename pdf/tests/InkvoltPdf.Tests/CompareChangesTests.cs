using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>What Compare lists besides wording (roadmap 3.3): formatting changes, moved paragraphs, running headers and footers, words read from a scan.</summary>
public class CompareChangesTests
{
    private const double CW = 6, CH = 10;

    private static readonly WordLook Plain = new("Arial", 11, false, false, 0);

    private static PageText Page(params string[] lines) =>
        new([.. lines.Select((l, li) => l.Select((c, i) => (c.ToString(), new RectD(50 + i * CW, 50 + li * 14, CW, CH))).ToList())]);

    /// <summary>Looks over a page's text: <paramref name="runs"/> gives other looks to phrases of it, everything else is plain.</summary>
    private static PageLooks Looks(PageText page, params (string Phrase, WordLook Look)[] runs)
    {
        var list = new List<(int, WordLook)> { (0, Plain) };
        foreach (var (phrase, look) in runs.OrderBy(r => page.Text.IndexOf(r.Phrase, StringComparison.Ordinal)))
        {
            var at = page.Text.IndexOf(phrase, StringComparison.Ordinal);
            Assert.True(at >= 0, phrase);
            list.Add((at, look));
            list.Add((at + phrase.Length, Plain));
        }
        return new PageLooks(list);
    }

    private static CompareResult Styled(string text, (string, WordLook)[] oldRuns, (string, WordLook)[] newRuns)
    {
        var (o, n) = (Page(text), Page(text));
        return DocumentCompare.Run(new CompareSource([o], [Looks(o, oldRuns)]), new CompareSource([n], [Looks(n, newRuns)]));
    }

    // ---- Formatting ----

    [Fact]
    public void AWordTurnedBoldIsOneFormattingChangeAndNoWordingChange()
    {
        var r = Styled("the fee is due on the first day", [], [("fee is due", Plain with { Bold = true })]);
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.Formatted, c.Kind);
        Assert.Equal("fee is due", c.NewText);
        Assert.Equal("fee is due", c.OldText);
        Assert.Equal(LookParts.Bold, c.Look!.Parts);
        Assert.Equal("bold added", c.Look.Describe());
        Assert.Equal((0, 0, 0, 1), (r.Inserted, r.Deleted, r.Changed, r.Formatted));
        Assert.Equal([new WordSpan(0, 4, 14)], c.New);
        Assert.Contains("1 formatting change", r.Summary());
        Assert.StartsWith("No text changes", r.Summary());
        Assert.False(r.Identical);
    }

    [Theory]
    [InlineData("size", LookParts.Size, "size 11 → 14 pt")]
    [InlineData("font", LookParts.Font, "font Arial → Times New Roman")]
    [InlineData("color", LookParts.Color, "color black → #C00000")]
    [InlineData("italic", LookParts.Italic, "italic added")]
    public void EachKindOfFormattingIsNamed(string kind, LookParts parts, string description)
    {
        var look = kind switch
        {
            "size" => Plain with { Size = 14 },
            "font" => Plain with { Font = "Times New Roman" },
            "color" => Plain with { Color = 0xC00000 },
            _ => Plain with { Italic = true },
        };
        var c = Assert.Single(Styled("one two three", [], [("two", look)]).Changes);
        Assert.Equal(parts, c.Look!.Parts);
        Assert.Equal(description, c.Look.Describe());
    }

    [Fact]
    public void SeveralChangesInOneRunAreDescribedTogether()
    {
        var c = Assert.Single(Styled("one two three", [("two", Plain with { Bold = true })], [("two", Plain with { Size = 16, Italic = true })]).Changes);
        Assert.Equal(LookParts.Bold | LookParts.Italic | LookParts.Size, c.Look!.Parts);
        Assert.Equal("bold removed, italic added, size 11 → 16 pt", c.Look.Describe());
    }

    [Fact]
    public void TinyDifferencesAreNotFormattingChanges()
    {
        var r = Styled("one two three", [], [("two", Plain with { Size = 11.1, Color = 0x050505 })]);
        Assert.Empty(r.Changes);
        Assert.True(r.Identical);
    }

    [Fact]
    public void PartOfAWordCounts()
    {
        var c = Assert.Single(Styled("international", [], [("inter", Plain with { Bold = true })]).Changes);
        Assert.Equal(LookParts.Bold, c.Look!.Parts);
    }

    [Fact]
    public void AdjacentWordsWithDifferentChangesAreSeparate()
    {
        var r = Styled("one two three four", [], [("two", Plain with { Bold = true }), ("three", Plain with { Size = 14 })]);
        Assert.Equal(["two", "three"], r.Changes.Select(c => c.NewText));
    }

    [Fact]
    public void ARunOverAPageBreakIsOneChangeWithASpanOnEachPage()
    {
        var bold = Plain with { Bold = true };
        var (o1, o2) = (Page("alpha beta gamma"), Page("delta epsilon zeta"));
        var (n1, n2) = (Page("alpha beta gamma"), Page("delta epsilon zeta"));
        var r = DocumentCompare.Run(new CompareSource([o1, o2], [Looks(o1), Looks(o2)]),
            new CompareSource([n1, n2], [Looks(n1, ("gamma", bold)), Looks(n2, ("delta", bold))]));
        var c = Assert.Single(r.Changes);
        Assert.Equal("gamma delta", c.NewText);
        Assert.Equal([0, 1], c.New.Select(s => s.Page));
    }

    [Fact]
    public void WordingIsListedBeforeMovesAndFormattingOnARow()
    {
        var (o, n) = (Page("one two three four five"), Page("one 2 three four five"));
        var r = DocumentCompare.Run(new CompareSource([o], [Looks(o)]), new CompareSource([n], [Looks(n, ("three", Plain with { Bold = true }))]));
        Assert.Equal([ChangeKind.Changed, ChangeKind.Formatted], r.Changes.Select(c => c.Kind));
    }

    [Fact]
    public void WithoutLooksOnOneSideNoFormattingIsReported()
    {
        var (o, n) = (Page("one two"), Page("one two"));
        var r = DocumentCompare.Run(new CompareSource([o], [null]), new CompareSource([n], [Looks(n, ("two", Plain with { Bold = true }))]));
        Assert.Empty(r.Changes);
        Assert.Empty(DocumentCompare.Run(new CompareSource([o]), new CompareSource([n], [Looks(n, ("two", Plain with { Bold = true }))])).Changes);
    }

    // ---- Moves ----

    private const string A = "The supplier shall deliver the goods to the buyer at the agreed place before the end of each month.";
    private const string B = "The buyer shall inspect all goods within ten days and report any defects to the supplier in writing.";
    private const string C = "Neither party may assign this agreement without the prior written consent of the other party here.";
    private const string D = "Notices must be sent by registered mail or courier to the address that each party has given above.";

    [Fact]
    public void AMovedParagraphIsOneMoveNotARemovalAndAnInsertion()
    {
        var r = DocumentCompare.Run([Page(A, B, C, D)], [Page(B, C, A, D)]);
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.Moved, c.Kind);
        Assert.Equal(A, c.NewText);
        Assert.Equal(A, c.OldText);
        Assert.Equal((0, 0, 0, 1), (r.Inserted, r.Deleted, r.Changed, r.Moved));
        Assert.Contains("1 moved", r.Summary());
        Assert.Equal((0, 0), (c.Old[0].Page, c.Old[0].Start));
        Assert.Equal(Page(B, C, A, D).Text.IndexOf(A[..20], StringComparison.Ordinal), c.New[0].Start);
    }

    [Fact]
    public void AMoveSaysWhereTheTextWasTakenFrom()
    {
        var r = DocumentCompare.Run([Page(A, B, C, D)], [Page(A, C, B, D)]);
        var c = Assert.Single(r.Changes);
        Assert.Equal(ChangeKind.Moved, c.Kind);
        Assert.NotNull(c.NewAnchor);
        Assert.Equal(0, c.NewAnchor!.Value.Page);
    }

    [Fact]
    public void AMoveAcrossPagesKeepsBothPlaces()
    {
        var r = DocumentCompare.Run([Page(A, B), Page(C, D)], [Page(B), Page(C, D, A)]);
        var c = Assert.Single(r.Changes, x => x.Kind == ChangeKind.Moved);
        Assert.Equal(0, c.Old[0].Page);
        Assert.Equal(1, c.New[0].Page);
        Assert.Equal(1, c.Row);
    }

    [Fact]
    public void AMovedParagraphWithAnEditedWordIsAMoveAndAChange()
    {
        var edited = A.Replace("agreed", "chosen");
        var r = DocumentCompare.Run([Page(A, B, C, D)], [Page(B, C, edited, D)]);
        Assert.Equal(2, r.Changes.Count);
        var word = Assert.Single(r.Changes, c => c.Kind == ChangeKind.Changed);
        Assert.Equal(("agreed", "chosen"), (word.OldText, word.NewText));
        Assert.Equal(ChangeKind.Moved, r.Changes.Single(c => c != word).Kind);
    }

    [Fact]
    public void AReplacedSentenceInPlaceIsNotAMove()
    {
        var r = DocumentCompare.Run([Page(A, B, D)], [Page(A, C, D)]);
        Assert.DoesNotContain(r.Changes, c => c.Kind == ChangeKind.Moved);
    }

    [Fact]
    public void ShortRepeatedPhrasesAreNotMoves()
    {
        var r = DocumentCompare.Run([Page("in the event of alpha we pay beta gamma delta epsilon zeta eta theta")],
            [Page("alpha we pay beta gamma delta epsilon zeta in the event of eta theta")]);
        Assert.DoesNotContain(r.Changes, c => c.Kind == ChangeKind.Moved && c.NewText.Split(' ').Length < 3);
    }

    [Fact]
    public void APageMovedElsewhereIsOneMoveNotAPageRemovedAndInserted()
    {
        string[] pages = [A, B, C, D, A.Replace("goods", "wares") + " Extra words so the page stays apart from the first."];
        var r = DocumentCompare.Run(pages.Select(p => Page(p)).ToArray(), new[] { 0, 2, 3, 1, 4 }.Select(i => Page(pages[i])).ToArray());
        Assert.Equal(1, r.Moved);
        Assert.Equal((0, 0), (r.PagesRemoved, r.PagesInserted));
        Assert.Contains(r.Rows, x => x.PageMoved);
    }

    [Fact]
    public void FormattingInsideAMovedParagraphIsListedToo()
    {
        var (o, n) = (Page(A, B, C, D), Page(B, C, A, D));
        var r = DocumentCompare.Run(new CompareSource([o], [Looks(o)]), new CompareSource([n], [Looks(n, ("agreed place", Plain with { Bold = true }))]));
        Assert.Equal([ChangeKind.Moved, ChangeKind.Formatted], r.Changes.Select(c => c.Kind));
    }

    [Fact]
    public void MoveSearchIsBoundedOnRepetitiveText()
    {
        // No unique words and every run alike: the search must stop on its budget, not take quadratic time.
        var a = Enumerable.Range(0, 30_000).Select(i => i % 2 == 0 ? "aa bb cc dd ee" : "ff").ToArray();
        var b = a.Reverse().ToArray();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        DocumentCompare.Run([new PageText([string.Join(" ", a).Select(ch => (ch.ToString(), new RectD(0, 0, 1, 1))).ToList()])],
            [new PageText([string.Join(" ", b).Select(ch => (ch.ToString(), new RectD(0, 0, 1, 1))).ToList()])]);
        Assert.True(sw.ElapsedMilliseconds < 20_000, $"took {sw.ElapsedMilliseconds} ms");
    }

    [Fact]
    public void ALongMoveSearchCanBeCancelled()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => CompareMoves.Find([new DiffOp(DiffKind.Delete, 0, 0, 1), new DiffOp(DiffKind.Insert, 1, 0, 1)], ["a"], ["b"], cts.Token));
    }

    // ---- Running headers and footers ----

    /// <summary>Pages with a body of their own and a last line made from the page's number.</summary>
    private static PageText[] Footed(int count, Func<int, string> footer, int bodyWords = 12) =>
        [.. Enumerable.Range(0, count).Select(p => Page(
            string.Join(' ', Enumerable.Range(0, bodyWords).Select(w => $"body{p}word{w}")),
            string.Join(' ', Enumerable.Range(0, bodyWords).Select(w => $"more{p}word{w}")),
            footer(p)))];

    [Fact]
    public void ANumberThatDiffersWithoutCountingUpIsCompared()
    {
        static string Sub(int p) => $"Subtotal: {1000 + p * 137},{10 + p}";
        var r = DocumentCompare.Run(Footed(5, Sub), Footed(5, p => p == 2 ? "Subtotal: 9999,99" : Sub(p)));
        Assert.False(r.Identical);
        Assert.Contains(r.Changes, c => c.New is [{ Page: 2 }] && c.NewText.Contains("9999"));
    }

    [Fact]
    public void AFixedNumberBesideAPageNumberMustMatch()
    {
        var r = DocumentCompare.Run(Footed(5, p => $"Contract 123 - Page {p + 1}"), Footed(5, p => $"Contract 456 - Page {p + 1}"));
        Assert.Equal(5, r.Changes.Count(c => c.Kind == ChangeKind.Changed && c.OldText == "123" && c.NewText == "456"));
    }

    [Fact]
    public void PageNumbersKeepOutOfItPastNineAndWithAFixedNumberBesideThem()
    {
        static string Foot(int p) => $"Contract 123 - Page {p + 1} of 14";
        var r = DocumentCompare.Run(Footed(14, Foot), Footed(14, Foot));
        Assert.Empty(r.Changes);
        // A page removed: every later page's number is one less, and that's no change.
        var shifted = Footed(14, Foot).ToList();
        var after = Footed(14, Foot).Where((_, i) => i != 3).Select((page, i) => page).ToArray();
        var cut = DocumentCompare.Run(shifted, after);
        Assert.Equal(1, cut.PagesRemoved);
        Assert.Single(cut.Changes);
    }

    private static PageText[] Flowing(IEnumerable<string> words, int perPage) =>
        [.. words.Chunk(perPage).Select(chunk => Page([.. chunk.Chunk(12).Select(line => string.Join(' ', line))]))];

    [Fact]
    public void TextThatOnlyFlowedOntoAnotherPageIsNoPageChange()
    {
        var words = Enumerable.Range(0, 300).Select(i => $"w{i}").ToList();
        var added = Enumerable.Range(0, 50).Select(i => $"new{i}");
        var r = DocumentCompare.Run(Flowing(words, 100), Flowing(added.Concat(words), 100));
        Assert.Equal(0, r.PagesInserted);
        Assert.Equal(1, r.Inserted);
        Assert.Single(r.Changes);
    }

    [Fact]
    public void AWordRemovedOnAPageWhoseTextFlowedIsStillListed()
    {
        var words = Enumerable.Range(0, 300).Select(i => $"w{i}").ToList();
        var changed = words.Where(w => w is not ("w270" or "w271" or "w272")).ToList();
        var r = DocumentCompare.Run(Flowing(words, 100), Flowing(changed, 120));
        Assert.Equal(0, r.PagesRemoved);
        var c = Assert.Single(r.Changes);
        Assert.Equal((ChangeKind.Deleted, "w270 w271 w272"), (c.Kind, c.OldText));
    }

    [Fact]
    public void WhatIsLeftOnAPageThatMostlyMovedIsListed()
    {
        var moved = Enumerable.Range(0, 80).Select(i => $"m{i}").ToList();
        var gone = Enumerable.Range(0, 15).Select(i => $"gone{i}").ToList();
        var first = Enumerable.Range(0, 100).Select(i => $"a{i}").ToList();
        var last = Enumerable.Range(0, 100).Select(i => $"z{i}").ToList();
        var r = DocumentCompare.Run(
            [Flowing(first, 100)[0], Flowing(moved.Concat(gone), 100)[0], Flowing(last, 100)[0]],
            [Flowing(first, 100)[0], Flowing(last.Concat(moved), 200)[0]]);
        Assert.Equal(0, r.PagesRemoved);
        Assert.Equal(1, r.Moved);
        Assert.Contains(r.Changes, c => c.Kind == ChangeKind.Deleted && c.OldText.StartsWith("gone0", StringComparison.Ordinal));
    }

    private static PageText[] Bodied(string header, params (string Body, int Number)[] pages) =>
        [.. pages.Select(p => Page(header, p.Body, "more of the text on this page", "and a last line of it", $"Page {p.Number}"))];

    [Fact]
    public void PageNumbersThatMoveWithTheFlowAreNotChanges()
    {
        // The same words, with the page break elsewhere: the footers land between other words on the new side.
        var oldPages = new[]
        {
            Page("Supply Agreement", "alpha beta gamma", "delta epsilon zeta", "eta theta iota", "Page 1"),
            Page("Supply Agreement", "kappa lambda mu", "nu xi omicron", "pi rho sigma", "Page 2"),
        };
        var newPages = new[]
        {
            Page("Supply Agreement", "alpha beta gamma", "delta epsilon", "zeta eta theta iota", "Page 1"),
            Page("Supply Agreement", "kappa lambda", "mu nu xi omicron", "pi rho sigma", "Page 2"),
        };
        Assert.Empty(DocumentCompare.Run(oldPages, newPages).Changes);
        var moved = new[]
        {
            Page("Supply Agreement", "alpha beta gamma", "delta epsilon zeta", "Page 1"),
            Page("Supply Agreement", "eta theta iota", "kappa lambda mu", "nu xi omicron", "pi rho sigma", "Page 2"),
        };
        Assert.Empty(DocumentCompare.Run(oldPages, moved).Changes);
    }

    [Fact]
    public void AChangedFooterIsStillAChange()
    {
        var oldPages = Bodied("Draft for review", ("alpha", 1), ("beta", 2), ("gamma", 3));
        var newPages = Bodied("Final version", ("alpha", 1), ("beta", 2), ("gamma", 3));
        var r = DocumentCompare.Run(oldPages, newPages);
        Assert.Equal(3, r.Changes.Count);
        Assert.All(r.Changes, c => Assert.Equal(("Draft for review", "Final version"), (c.OldText, c.NewText)));
    }

    [Fact]
    public void AFixedNumberInAHeaderIsNotTakenForAPageNumber()
    {
        var oldPages = Bodied("Contract 123", ("alpha", 1), ("beta", 2), ("gamma", 3));
        var newPages = Bodied("Contract 124", ("alpha", 1), ("beta", 2), ("gamma", 3));
        Assert.Equal(3, DocumentCompare.Run(oldPages, newPages).Changed);
    }

    [Fact]
    public void AChangedShortPageIsNeverTakenForAFooter()
    {
        var r = DocumentCompare.Run([Page("Total 100"), Page("Total 200")], [Page("Total 100"), Page("Total 300")]);
        Assert.Equal(1, r.Changed);
    }

    // ---- Scans ----

    [Fact]
    public void ChangesOnARecognizedPageSayTheyWereReadFromAScan()
    {
        var r = DocumentCompare.Run(new CompareSource([Page("the fee is 100 dollars today")]),
            new CompareSource([Page("the fee is 150 dollars today")], Scanned: [true]));
        var c = Assert.Single(r.Changes);
        Assert.True(c.ReadFromScan);
        Assert.False(c.MaybeMisread); // 100 → 150 is no slip of a recognizer's
    }

    [Theory]
    [InlineData("modern", "rnodern")]
    [InlineData("Total", "TotaI")]
    [InlineData("100", "1O0")]
    [InlineData("SOLD", "S0LD")]
    public void ARecognizerSlipIsListedButMarkedAsMaybeMisread(string truth, string read)
    {
        var r = DocumentCompare.Run(new CompareSource([Page($"the {truth} is here")]), new CompareSource([Page($"the {read} is here")], Scanned: [true]));
        var c = Assert.Single(r.Changes);
        Assert.True(c.MaybeMisread);
        Assert.Contains("may be misread", r.Summary());
    }

    [Fact]
    public void WithoutAScanNothingIsCalledMisread()
    {
        var c = Assert.Single(DocumentCompare.Run([Page("the Total is here")], [Page("the TotaI is here")]).Changes);
        Assert.False(c.ReadFromScan);
        Assert.False(c.MaybeMisread);
    }

    [Fact]
    public void StrayPunctuationOnAScanIsMaybeMisread()
    {
        var r = DocumentCompare.Run(new CompareSource([Page("alpha beta gamma")]), new CompareSource([Page("alpha . beta gamma")], Scanned: [true]));
        Assert.True(Assert.Single(r.Changes).MaybeMisread);
    }

    [Fact]
    public void WordsOfASkewedScanBecomeLinesInReadingOrder()
    {
        // Two rows of words on a page turned 5° clockwise: each word's box is turned about its centre.
        var (sin, cos) = Math.SinCos(5 * Math.PI / 180);
        OcrWord At(string text, double x, double y) => new(text, new RectD(100 + x * cos - y * sin, 100 + x * sin + y * cos, 40, 10), 5);
        var page = CompareScan.PageTextOf([At("alpha", 0, 0), At("beta", 50, 0), At("gamma", 0, 20), At("delta", 50, 20)]);
        Assert.Equal("alpha beta\ngamma delta", page.Text);
        Assert.NotEmpty(page.GetRects(0, 5));
        // The first word's characters run along the turned line.
        var (first, last) = (page.BoxAt(0), page.BoxAt(4));
        Assert.True(last.CenterX > first.CenterX + 20);
        Assert.True(last.CenterY > first.CenterY + 2);
    }

    [Fact]
    public void NoWordsMakeNoText() => Assert.True(CompareScan.PageTextOf([]).IsEmpty);
}
