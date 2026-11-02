using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>A word (or a punctuation mark) of a page: characters [Start, End) of its <see cref="PageText.Text"/>, and the key it is compared by.</summary>
public sealed record CompareWord(int Page, int Start, int End, string Key);

/// <summary>Splits a page's text into the words Compare matches.</summary>
public static class CompareWords
{
    /// <summary>
    /// Words are runs of letters and digits (with apostrophes and combining marks); numbers keep their separators
    /// ("1,250.75"); each other mark is a word of its own, and so is each Chinese or Japanese character, since those
    /// scripts don't put spaces between words. A word hyphenated across a line break ("exam-" / "ple") is one word.
    /// Keys are NFKC-normalized, so ligatures ("ﬁ") match their letters.
    /// </summary>
    public static List<CompareWord> Of(PageText text, int page)
    {
        var s = text.Text;
        var words = new List<CompareWord>();
        var key = new StringBuilder();
        var i = 0;
        while (i < s.Length)
        {
            if (char.IsWhiteSpace(s[i]) || s[i] == '­')
            {
                i++;
                continue;
            }
            var start = i;
            key.Clear();
            if (IsWordChar(s, i) && !IsIdeograph(s, i))
            {
                while (i < s.Length)
                {
                    if (IsWordChar(s, i) && !IsIdeograph(s, i))
                    {
                        var n = Width(s, i);
                        key.Append(s, i, n);
                        i += n;
                    }
                    else if ((s[i] == '.' || s[i] == ',') && i > start && char.IsDigit(s[i - 1]) && i + 1 < s.Length && char.IsDigit(s[i + 1]))
                        key.Append(s[i++]);
                    else if (s[i] == '-' && i + 2 < s.Length && s[i + 1] == '\n' && char.IsLetter(s[i - 1]) && char.IsLetter(s[i + 2]))
                        i += 2; // hyphenated at a line break
                    else if (s[i] == '­' && i + 1 < s.Length && (IsWordChar(s, i + 1) || s[i + 1] == '\n' && i + 2 < s.Length && IsWordChar(s, i + 2)))
                        i += s[i + 1] == '\n' ? 2 : 1; // soft hyphen
                    else break;
                }
            }
            else
            {
                var n = Width(s, i);
                key.Append(s, i, n);
                i += n;
            }
            words.Add(new CompareWord(page, start, i, Normalize(key.ToString())));
        }
        return words;
    }

    private static string Normalize(string s)
    {
        try
        {
            return s.IsNormalized(NormalizationForm.FormKC) ? s : s.Normalize(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            return s; // a lone surrogate
        }
    }

    private static int Width(string s, int i) => char.IsSurrogatePair(s, i) ? 2 : 1;

    private static bool IsWordChar(string s, int i)
    {
        var c = s[i];
        if (c is '_' or '\'' or '’') return true;
        var cat = char.GetUnicodeCategory(s, i);
        return cat is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber
            or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber or UnicodeCategory.NonSpacingMark
            or UnicodeCategory.SpacingCombiningMark;
    }

    /// <summary>Han, kana and the like: each is compared on its own.</summary>
    private static bool IsIdeograph(string s, int i)
    {
        var cp = char.IsSurrogatePair(s, i) ? char.ConvertToUtf32(s, i) : s[i];
        return cp is >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF
            or >= 0x20000 and <= 0x3FFFF;
    }

    /// <summary>The text of [start, end) for showing in a list: line breaks as spaces, words hyphenated at a break joined.</summary>
    public static string Display(string text, int start, int end)
    {
        var sb = new StringBuilder(end - start);
        for (var i = start; i < end; i++)
        {
            var c = text[i];
            if (c == '-' && i + 1 < end && text[i + 1] == '\n' && i > start && char.IsLetter(text[i - 1]) && i + 2 < end && char.IsLetter(text[i + 2]))
                i++;
            else if (c == '­') { if (i + 1 < end && text[i + 1] == '\n') i++; }
            else sb.Append(c == '\n' ? ' ' : c);
        }
        return sb.ToString();
    }
}

/// <summary>How a row's text could be compared.</summary>
public enum RowText
{
    /// <summary>Both pages have text, compared word by word.</summary>
    Compared,
    /// <summary>The old page has no text (a scan?): compare the row visually.</summary>
    NoTextOld,
    /// <summary>The new page has no text.</summary>
    NoTextNew,
    /// <summary>Neither page has text.</summary>
    NoTextBoth,
    /// <summary>A page only the old document has (removed).</summary>
    OnlyOld,
    /// <summary>A page only the new document has (inserted).</summary>
    OnlyNew,
}

/// <summary>One row of the comparison: an old page and the new page it lines up with, or a page only one side has.</summary>
/// <param name="Changes">How many changes are on this row.</param>
/// <param name="PageMoved">A page only one side has here because it moved: its text is on another row, as a move.</param>
public sealed record CompareRow(int? OldPage, int? NewPage, RowText Text, int Changes = 0, bool PageMoved = false);

public enum ChangeKind { Inserted, Deleted, Changed, PageInserted, PageRemoved, Moved, Formatted }

/// <summary>Characters [Start, End) of a page's text (Start == End: a position between characters).</summary>
public readonly record struct WordSpan(int Page, int Start, int End);

/// <summary>
/// A change: words removed (Old), added (New) or both (a replacement), on one page of each side, or a whole page
/// removed or inserted, or text moved (Old where it was, New where it is), or text set differently (<see cref="Look"/>). An
/// insertion's <see cref="OldAnchor"/> is where it goes in the old text, a deletion's <see cref="NewAnchor"/> where it was
/// taken from in the new text (null when that isn't on the same row), a move's the same.
/// </summary>
public sealed record CompareChange(ChangeKind Kind, int Row, IReadOnlyList<WordSpan> Old, IReadOnlyList<WordSpan> New,
    string OldText, string NewText, WordSpan? OldAnchor = null, WordSpan? NewAnchor = null)
{
    /// <summary>What a <see cref="ChangeKind.Formatted"/> change did.</summary>
    public LookChange? Look { get; init; }

    /// <summary>One of its sides was read from a picture of the page.</summary>
    public bool ReadFromScan { get; init; }

    /// <summary>Read from a scan, and the difference is what recognizers confuse, or a stray mark: listed, but say so (<see cref="CompareScan.LooksLikeASlip"/>).</summary>
    public bool MaybeMisread { get; init; }

    /// <summary>A change of the words themselves (not a move, a look or a whole page).</summary>
    public bool IsWording => Kind is ChangeKind.Inserted or ChangeKind.Deleted or ChangeKind.Changed;
}

public sealed class CompareResult
{
    public required IReadOnlyList<CompareRow> Rows { get; init; }
    public required IReadOnlyList<CompareChange> Changes { get; init; }
    public int Inserted { get; init; }
    public int Deleted { get; init; }
    public int Changed { get; init; }
    public int PagesInserted { get; init; }
    public int PagesRemoved { get; init; }
    public int Moved { get; init; }
    public int Formatted { get; init; }

    /// <summary>Of the text changes, those read from a scan that may be misreadings.</summary>
    public int MaybeMisread { get; init; }

    /// <summary>Rows pairing two pages whose text couldn't be compared, because one or both have none (scans).</summary>
    public int PairsWithoutText { get; init; }

    /// <summary>No changes and every pair had text to compare.</summary>
    public bool Identical => Changes.Count == 0 && PairsWithoutText == 0;

    /// <summary>"3 text changes (1 inserted, 2 changed); 1 page removed; 2 pages without text": one line for the toolbar and the report.</summary>
    public string Summary()
    {
        if (Identical) return "No differences in the text";
        var parts = new List<string>();
        var text = Inserted + Deleted + Changed;
        if (text > 0)
        {
            var kinds = new[] { (Inserted, "inserted"), (Deleted, "removed"), (Changed, "changed") }.Where(k => k.Item1 > 0).Select(k => $"{k.Item1} {k.Item2}");
            parts.Add($"{Count(text, "text change")} ({string.Join(", ", kinds)})" + (MaybeMisread > 0 ? $", {MaybeMisread} of them may be misread on the scan" : ""));
        }
        else parts.Add("No text changes");
        if (Moved > 0) parts.Add($"{Moved} moved");
        if (Formatted > 0) parts.Add(Count(Formatted, "formatting change"));
        if (PagesInserted > 0) parts.Add($"{Count(PagesInserted, "page")} inserted");
        if (PagesRemoved > 0) parts.Add($"{Count(PagesRemoved, "page")} removed");
        if (PairsWithoutText > 0) parts.Add($"{Count(PairsWithoutText, "page")} without text to compare");
        return string.Join("; ", parts);

        static string Count(int n, string what) => n == 1 ? $"1 {what}" : $"{n} {what}s";
    }
}

/// <summary>
/// Compares the text of two documents. The whole documents are diffed word by word (so text that flows onto the next
/// page isn't a change), then pages are lined up by the words they share: an old and a new page that share most of
/// their matched words are paired; between such pairs, pages are paired by a small alignment that prefers pairing to
/// leaving a page out (a page rewritten in place is "changed", not removed and inserted). Pages left over were removed
/// or inserted and are reported once each, not word by word; pages without text (scans) are flagged instead of
/// having all their words reported as changed. Running headers and footers both documents have stay out of the diff
/// (<see cref="CompareRunningLines"/>), text taken out in one place and put back in another is one move
/// (<see cref="CompareMoves"/>) and the same words set differently are formatting changes, where looks are known.
/// </summary>
public static class DocumentCompare
{
    /// <summary>Largest old × new page block aligned exactly; bigger blocks without shared words are paired in order.</summary>
    private const long MaxAlignCells = 4_000_000;

    public static CompareResult Run(IReadOnlyList<PageText> oldPages, IReadOnlyList<PageText> newPages, CancellationToken cancel = default) =>
        Run(new CompareSource(oldPages), new CompareSource(newPages), cancel);

    public static CompareResult Run(CompareSource oldSide, CompareSource newSide, CancellationToken cancel = default)
    {
        var (oldPages, newPages) = (oldSide.Pages, newSide.Pages);
        var oldHasText = new bool[oldPages.Count];
        var newHasText = new bool[newPages.Count];
        var (oldRunning, newRunning) = CompareRunningLines.Find(oldPages, newPages, cancel);
        var oldWords = new List<CompareWord>();
        var newWords = new List<CompareWord>();
        for (var p = 0; p < oldPages.Count; p++) AddWords(oldWords, oldPages[p], p, oldRunning[p], oldHasText);
        for (var p = 0; p < newPages.Count; p++) AddWords(newWords, newPages[p], p, newRunning[p], newHasText);
        cancel.ThrowIfCancellationRequested();

        var oldKeys = oldWords.ConvertAll(w => w.Key);
        var newKeys = newWords.ConvertAll(w => w.Key);
        var ops = PageWiseDiff(oldWords, newWords, oldKeys, newKeys, cancel);
        cancel.ThrowIfCancellationRequested();

        // What moved leaves the diff: without it the words around it line up again, even those it took a "." from.
        var moves = CompareMoves.Find(ops, oldKeys, newKeys, cancel);
        var movedOld = new bool[oldWords.Count];
        var movedNew = new bool[newWords.Count];
        foreach (var m in moves)
        {
            Array.Fill(movedOld, true, m.OldStart, m.OldEnd - m.OldStart);
            Array.Fill(movedNew, true, m.NewStart, m.NewEnd - m.NewStart);
        }
        if (moves.Count > 0) ops = DiffOfTheRest(oldWords, newWords, movedOld, movedNew, cancel);

        var shared = new Dictionary<(int Old, int New), int>();
        foreach (var op in ops)
        {
            if (op.Kind != DiffKind.Equal) continue;
            for (var k = 0; k < op.Length; k++)
            {
                var key = (oldWords[op.A + k].Page, newWords[op.B + k].Page);
                shared[key] = shared.GetValueOrDefault(key) + 1;
            }
        }

        var pairs = Align(oldPages.Count, newPages.Count, shared, cancel);
        var rows = pairs.ConvertAll(p => new CompareRow(p.Old, p.New, p switch
        {
            (null, _) => RowText.OnlyNew,
            (_, null) => RowText.OnlyOld,
            ({ } o, { } n) when oldHasText[o] && newHasText[n] => RowText.Compared,
            ({ } o, _) when oldHasText[o] => RowText.NoTextNew,
            (_, { } n) when newHasText[n] => RowText.NoTextOld,
            _ => RowText.NoTextBoth,
        }));
        var rowOfOld = new int[oldPages.Count];
        var rowOfNew = new int[newPages.Count];
        for (var r = 0; r < rows.Count; r++)
        {
            if (rows[r].OldPage is { } o) rowOfOld[o] = r;
            if (rows[r].NewPage is { } n) rowOfNew[n] = r;
        }

        // A page only one side has whose words are nearly all elsewhere on the other side isn't removed or inserted: its text
        // moved or flowed there. What is left on it is compared like any other words.
        var inPlaceOld = (bool[])movedOld.Clone();
        var inPlaceNew = (bool[])movedNew.Clone();
        foreach (var op in ops.Where(op => op.Kind == DiffKind.Equal))
        {
            Array.Fill(inPlaceOld, true, op.A, op.Length);
            Array.Fill(inPlaceNew, true, op.B, op.Length);
        }
        for (var r = 0; r < rows.Count; r++)
        {
            if ((rows[r].Text == RowText.OnlyOld && rows[r].OldPage is { } o && MostlyMoved(oldWords, inPlaceOld, o))
                || (rows[r].Text == RowText.OnlyNew && rows[r].NewPage is { } n && MostlyMoved(newWords, inPlaceNew, n)))
                rows[r] = rows[r] with { PageMoved = true };
        }

        // Words that are the same on both sides: where they stayed, then where they moved.
        var matched = new List<(int Old, int New)>();
        foreach (var op in ops.Where(op => op.Kind == DiffKind.Equal))
            for (var k = 0; k < op.Length; k++) matched.Add((op.A + k, op.B + k));

        var changes = WordChanges(ops, oldWords, newWords, oldPages, newPages, rows, rowOfOld, rowOfNew);
        var oldToNew = new Dictionary<int, int>(matched.Count);
        foreach (var (o, n) in matched) oldToNew[o] = n;
        foreach (var m in moves)
        {
            foreach (var op in m.Inner.Where(op => op.Kind == DiffKind.Equal))
                for (var k = 0; k < op.Length; k++) matched.Add((op.A + k, op.B + k));
            changes.AddRange(WordChanges([.. m.Inner], oldWords, newWords, oldPages, newPages, rows, rowOfOld, rowOfNew, inMove: true));
            changes.Add(MoveChange(m, oldWords, newWords, oldPages, newPages, rowOfNew, oldToNew));
        }
        changes.AddRange(FormatChanges(matched, oldWords, newWords, oldSide, newSide, rowOfNew));
        for (var r = 0; r < rows.Count; r++)
        {
            if (rows[r].PageMoved) continue;
            if (rows[r].Text == RowText.OnlyOld && rows[r].OldPage is { } o)
                changes.Add(new CompareChange(ChangeKind.PageRemoved, r, [new WordSpan(o, 0, 0)], [], Excerpt(oldPages[o]), ""));
            else if (rows[r].Text == RowText.OnlyNew && rows[r].NewPage is { } n)
                changes.Add(new CompareChange(ChangeKind.PageInserted, r, [], [new WordSpan(n, 0, 0)], "", Excerpt(newPages[n])));
        }
        // Stable: within a row, wording in reading order, then moves, then looks.
        changes = [.. changes.Select(c => MarkScan(c, oldSide, newSide, rows)).OrderBy(c => c.Row).ThenBy(c => c.Kind switch { ChangeKind.Moved => 1, ChangeKind.Formatted => 2, _ => 0 })];
        var perRow = new int[rows.Count];
        foreach (var c in changes) perRow[c.Row]++;
        for (var r = 0; r < rows.Count; r++) rows[r] = rows[r] with { Changes = perRow[r] };

        return new CompareResult
        {
            Rows = rows,
            Changes = changes,
            Inserted = changes.Count(c => c.Kind == ChangeKind.Inserted),
            Deleted = changes.Count(c => c.Kind == ChangeKind.Deleted),
            Changed = changes.Count(c => c.Kind == ChangeKind.Changed),
            PagesInserted = changes.Count(c => c.Kind == ChangeKind.PageInserted),
            PagesRemoved = changes.Count(c => c.Kind == ChangeKind.PageRemoved),
            Moved = changes.Count(c => c.Kind == ChangeKind.Moved),
            Formatted = changes.Count(c => c.Kind == ChangeKind.Formatted),
            MaybeMisread = changes.Count(c => c.MaybeMisread),
            PairsWithoutText = rows.Count(r => r.Text is RowText.NoTextOld or RowText.NoTextNew or RowText.NoTextBoth),
        };
    }

    /// <summary>
    /// The word diff, preferring runs that start and end with a page, so a removed page doesn't take the next page's first
    /// word along; then with a sentence, so a removed paragraph doesn't take the next one's first word ("Article") along, which
    /// leaves that word removed on one side and inserted on the other when the paragraph only moved.
    /// </summary>
    private static List<DiffOp> PageWiseDiff(List<CompareWord> oldWords, List<CompareWord> newWords, List<string> oldKeys, List<string> newKeys, CancellationToken cancel) =>
        WordDiff.Slide(WordDiff.Diff(oldKeys, newKeys, cancel), oldKeys, newKeys, (kind, s, e) =>
        {
            var words = kind == DiffKind.Delete ? oldWords : newWords;
            var spans = words[e - 1].Page - words[s].Page + 1;
            var starts = s == 0 || words[s - 1].Page != words[s].Page;
            var ends = e == words.Count || words[e].Page != words[e - 1].Page;
            var sentenceStarts = s == 0 || EndsASentence(words[s - 1].Key);
            var sentenceEnds = EndsASentence(words[e - 1].Key);
            return spans * 4 - (starts ? 1 : 0) - (ends ? 1 : 0) - (sentenceStarts ? 0.4 : 0) - (sentenceEnds ? 0.4 : 0);
        });

    private static bool EndsASentence(string key) => key is "." or "!" or "?" or ":" or ";" or "。";

    /// <summary>The diff of the words no move took, as runs of word indices of the whole documents (a run may go past moved words).</summary>
    private static List<DiffOp> DiffOfTheRest(List<CompareWord> oldWords, List<CompareWord> newWords, bool[] movedOld, bool[] movedNew, CancellationToken cancel)
    {
        var oldRest = Enumerable.Range(0, oldWords.Count).Where(i => !movedOld[i]).ToList();
        var newRest = Enumerable.Range(0, newWords.Count).Where(j => !movedNew[j]).ToList();
        var (oldLeft, newLeft) = (oldRest.ConvertAll(i => oldWords[i]), newRest.ConvertAll(j => newWords[j]));
        var ops = new List<DiffOp>();
        foreach (var op in PageWiseDiff(oldLeft, newLeft, oldLeft.ConvertAll(w => w.Key), newLeft.ConvertAll(w => w.Key), cancel))
            for (var k = 0; k < op.Length; k++)
            {
                var (a, b) = (op.Kind == DiffKind.Insert ? op.A : op.A + k, op.Kind == DiffKind.Delete ? op.B : op.B + k);
                ops.Add(new DiffOp(op.Kind, a < oldRest.Count ? oldRest[a] : oldWords.Count, b < newRest.Count ? newRest[b] : newWords.Count, 1));
            }
        return ops;
    }

    private static void AddWords(List<CompareWord> words, PageText page, int p, (int Start, int End)[] skip, bool[] hasText)
    {
        var all = CompareWords.Of(page, p);
        if (all.Count > 0) hasText[p] = true;
        if (skip.Length == 0)
        {
            words.AddRange(all);
            return;
        }
        foreach (var w in all)
            if (!skip.Any(r => w.Start >= r.Start && w.Start < r.End)) words.Add(w);
    }

    private static bool MostlyMoved(List<CompareWord> words, bool[] moved, int page)
    {
        int all = 0, gone = 0;
        for (var i = 0; i < words.Count; i++)
        {
            if (words[i].Page != page) continue;
            all++;
            if (moved[i]) gone++;
        }
        return all > 0 && gone >= all * 0.8;
    }

    /// <summary>Says whether a change was read from a scan, and whether it may be a misreading.</summary>
    private static CompareChange MarkScan(CompareChange c, CompareSource oldSide, CompareSource newSide, List<CompareRow> rows)
    {
        // Its row too: a word only one side has may be one the scan on the other side lost.
        var row = rows[c.Row];
        if (!c.Old.Any(s => oldSide.IsScanned(s.Page)) && !c.New.Any(s => newSide.IsScanned(s.Page))
            && !(row.OldPage is { } o && oldSide.IsScanned(o)) && !(row.NewPage is { } n && newSide.IsScanned(n))) return c;
        var slip = c.Kind switch
        {
            ChangeKind.Changed => CompareScan.LooksLikeASlip(c.OldText, c.NewText),
            ChangeKind.Inserted => CompareScan.IsOnlyMarks(c.NewText) || (row.OldPage is { } lostOld && oldSide.IsScanned(lostOld) && CompareScan.CouldBeALostLine(c.NewText)),
            ChangeKind.Deleted => CompareScan.IsOnlyMarks(c.OldText) || (row.NewPage is { } lostNew && newSide.IsScanned(lostNew) && CompareScan.CouldBeALostLine(c.OldText)),
            _ => false,
        };
        return c with { ReadFromScan = true, MaybeMisread = slip };
    }

    /// <summary>A run of words as a span per page it is on, and its text for showing.</summary>
    private static (List<WordSpan> Spans, string Text) Spans(List<CompareWord> words, int first, int last, IReadOnlyList<PageText> pages)
    {
        var spans = new List<WordSpan>();
        var text = new StringBuilder();
        var start = first;
        for (var i = first; i <= last; i++)
        {
            if (i < last && words[i + 1].Page == words[start].Page) continue;
            var (page, from, to) = (words[start].Page, words[start].Start, words[i].End);
            spans.Add(new WordSpan(page, from, to));
            if (text.Length > 0) text.Append(' ');
            text.Append(CompareWords.Display(pages[page].Text, from, to));
            start = i + 1;
        }
        return (spans, text.ToString());
    }

    private static CompareChange MoveChange(CompareMove m, List<CompareWord> oldWords, List<CompareWord> newWords, IReadOnlyList<PageText> oldPages, IReadOnlyList<PageText> newPages,
        int[] rowOfNew, Dictionary<int, int> oldToNew)
    {
        var (oldSpans, oldText) = Spans(oldWords, m.OldStart, m.OldEnd - 1, oldPages);
        var (newSpans, newText) = Spans(newWords, m.NewStart, m.NewEnd - 1, newPages);

        // Where it was, in the new text: right after the last word before it that stayed.
        WordSpan? from = null;
        for (var i = m.OldStart - 1; i >= Math.Max(0, m.OldStart - 200) && from is null; i--)
            if (oldToNew.TryGetValue(i, out var j)) from = new WordSpan(newWords[j].Page, newWords[j].End, newWords[j].End);
        return new CompareChange(ChangeKind.Moved, rowOfNew[newSpans[0].Page], oldSpans, newSpans, oldText, newText, NewAnchor: from);
    }

    /// <summary>
    /// Matched words whose look differs, in the new text's order, one change per run of neighbouring words with the same
    /// change. Words with no look on either side are skipped.
    /// </summary>
    private static List<CompareChange> FormatChanges(List<(int Old, int New)> matched, List<CompareWord> oldWords, List<CompareWord> newWords, CompareSource oldSide, CompareSource newSide, int[] rowOfNew)
    {
        var changes = new List<CompareChange>();
        if (oldSide.Looks is null || newSide.Looks is null) return changes;
        (int OFirst, int OLast, int NFirst, int NLast, LookChange Look)? open = null;

        void Close()
        {
            if (open is not { } g) return;
            var (oldSpans, oldText) = Spans(oldWords, g.OFirst, g.OLast, oldSide.Pages);
            var (newSpans, newText) = Spans(newWords, g.NFirst, g.NLast, newSide.Pages);
            changes.Add(new CompareChange(ChangeKind.Formatted, rowOfNew[newSpans[0].Page], oldSpans, newSpans, oldText, newText) { Look = g.Look });
            open = null;
        }

        foreach (var (o, n) in matched.OrderBy(m => m.New))
        {
            var look = LookOf(oldWords[o], newWords[n], oldSide, newSide);
            if (look is null)
            {
                Close();
                continue;
            }
            if (open is { } g && g.OLast + 1 == o && g.NLast + 1 == n && SameChange(g.Look, look))
                open = g with { OLast = o, NLast = n };
            else
            {
                Close();
                open = (o, o, n, n, look);
            }
        }
        Close();
        return changes;
    }

    private static bool SameChange(LookChange a, LookChange b) =>
        a.Parts == b.Parts && a.Old.PartsDifferentFrom(b.Old) == LookParts.None && a.New.PartsDifferentFrom(b.New) == LookParts.None;

    /// <summary>How one word's look changed, or null: unit by unit when both are spelled alike, else what most of each has.</summary>
    private static LookChange? LookOf(CompareWord oldWord, CompareWord newWord, CompareSource oldSide, CompareSource newSide)
    {
        if (oldSide.LooksOf(oldWord.Page) is not { IsEmpty: false } oldLooks || newSide.LooksOf(newWord.Page) is not { IsEmpty: false } newLooks) return null;
        if (oldWord.End - oldWord.Start == newWord.End - newWord.Start)
        {
            for (var k = 0; k < oldWord.End - oldWord.Start; k++)
                if (oldLooks.At(oldWord.Start + k) is { } a && newLooks.At(newWord.Start + k) is { } b && a.PartsDifferentFrom(b) is var parts and not LookParts.None)
                    return new LookChange(a, b, parts);
            return null;
        }
        return oldLooks.Main(oldWord.Start, oldWord.End) is { } m && newLooks.Main(newWord.Start, newWord.End) is { } n && m.PartsDifferentFrom(n) is var p and not LookParts.None
            ? new LookChange(m, n, p) : null;
    }

    /// <summary>The start of a page's text, for naming a removed or inserted page.</summary>
    private static string Excerpt(PageText page)
    {
        var t = CompareWords.Display(page.Text, 0, Math.Min(page.Text.Length, 120)).Trim();
        return page.Text.Length > 120 ? t + "…" : t;
    }

    /// <summary>
    /// Groups the diff's inserted and deleted words into changes: a group ends at an unchanged word, at a page break on
    /// either side and at a word of a row whose text isn't compared (a removed, inserted or textless page; a page whose text
    /// moved elsewhere is compared, so what is left on it shows). Words of a move
    /// aren't in the diff, and a group ends where one was. <paramref name="inMove"/>: the diff inside a moved passage,
    /// whose two sides are on different rows and any page.
    /// </summary>
    private static List<CompareChange> WordChanges(List<DiffOp> ops, List<CompareWord> oldWords, List<CompareWord> newWords,
        IReadOnlyList<PageText> oldPages, IReadOnlyList<PageText> newPages, List<CompareRow> rows, int[] rowOfOld, int[] rowOfNew,
        bool inMove = false)
    {
        var changes = new List<CompareChange>();
        int? oFirst = null, oLast = null, nFirst = null, nLast = null; // word indices of the open group
        int? prevEqualOld = null, prevEqualNew = null;                // the last unchanged word before it
        var pending = new List<(int? OF, int? OL, int? NF, int? NL, int? PO, int? PN)>();

        void Close()
        {
            if (oFirst is null && nFirst is null) return;
            pending.Add((oFirst, oLast, nFirst, nLast, prevEqualOld, prevEqualNew));
            oFirst = oLast = nFirst = nLast = null;
        }
        void Resolve(int? nextOld, int? nextNew)
        {
            foreach (var g in pending) changes.Add(Make(g, nextOld, nextNew));
            pending.Clear();
        }

        static bool Listed(CompareRow row) => row.Text == RowText.Compared || row.PageMoved;

        foreach (var op in ops)
        {
            for (var k = 0; k < op.Length; k++)
            {
                switch (op.Kind)
                {
                    case DiffKind.Equal:
                        Close();
                        Resolve(op.A + k, op.B + k);
                        prevEqualOld = op.A + k;
                        prevEqualNew = op.B + k;
                        break;
                    case DiffKind.Delete:
                    {
                        var i = op.A + k;
                        if (!inMove && !Listed(rows[rowOfOld[oldWords[i].Page]])) { Close(); break; }
                        if (oLast is { } l && (l + 1 != i || oldWords[l].Page != oldWords[i].Page)) Close();
                        oFirst ??= i;
                        oLast = i;
                        break;
                    }
                    default:
                    {
                        var j = op.B + k;
                        if (!inMove && !Listed(rows[rowOfNew[newWords[j].Page]])) { Close(); break; }
                        if (nLast is { } l && (l + 1 != j || newWords[l].Page != newWords[j].Page)) Close();
                        else if (!inMove && nLast is null && oLast is { } ol && rowOfOld[oldWords[ol].Page] != rowOfNew[newWords[j].Page]) Close();
                        nFirst ??= j;
                        nLast = j;
                        break;
                    }
                }
            }
        }
        Close();
        Resolve(null, null);
        return changes;

        CompareChange Make((int? OF, int? OL, int? NF, int? NL, int? PO, int? PN) g, int? nextOld, int? nextNew)
        {
            var oldSpan = g.OF is { } of ? new WordSpan(oldWords[of].Page, oldWords[of].Start, oldWords[g.OL!.Value].End) : (WordSpan?)null;
            var newSpan = g.NF is { } nf ? new WordSpan(newWords[nf].Page, newWords[nf].Start, newWords[g.NL!.Value].End) : (WordSpan?)null;
            var row = inMove && newSpan is { } ns ? rowOfNew[ns.Page] : oldSpan is { } os ? rowOfOld[os.Page] : rowOfNew[newSpan!.Value.Page];
            var kind = oldSpan is null ? ChangeKind.Inserted : newSpan is null ? ChangeKind.Deleted : ChangeKind.Changed;

            // Where an insertion goes in the old text (or a deletion was in the new): next to the neighbouring
            // unchanged word, if that word is on this row.
            WordSpan? Anchor(List<CompareWord> words, int[] rowOf, int? before, int? after)
            {
                if (before is { } b && rowOf[words[b].Page] == row) return new WordSpan(words[b].Page, words[b].End, words[b].End);
                if (after is { } a && rowOf[words[a].Page] == row) return new WordSpan(words[a].Page, words[a].Start, words[a].Start);
                return null;
            }

            return new CompareChange(kind, row,
                oldSpan is { } o1 ? [o1] : [], newSpan is { } n1 ? [n1] : [],
                oldSpan is { } o2 ? CompareWords.Display(oldPages[o2.Page].Text, o2.Start, o2.End) : "",
                newSpan is { } n2 ? CompareWords.Display(newPages[n2.Page].Text, n2.Start, n2.End) : "",
                kind == ChangeKind.Inserted ? Anchor(oldWords, rowOfOld, g.PO, nextOld) : null,
                kind == ChangeKind.Deleted ? Anchor(newWords, rowOfNew, g.PN, nextNew) : null);
        }
    }

    /// <summary>
    /// Lines up old and new pages. Pages that are each other's best match (most shared words) are fixed pairs;
    /// the stretches between them are aligned to share the most words, with each pairing worth a little on its own.
    /// </summary>
    internal static List<(int? Old, int? New)> Align(int oldCount, int newCount, Dictionary<(int Old, int New), int> shared, CancellationToken cancel = default)
    {
        var bestNew = new (int Page, int Words)[oldCount];
        var bestOld = new (int Page, int Words)[newCount];
        Array.Fill(bestNew, (-1, 0));
        Array.Fill(bestOld, (-1, 0));
        foreach (var ((o, n), w) in shared)
        {
            if (w > bestNew[o].Words || (w == bestNew[o].Words && n < bestNew[o].Page)) bestNew[o] = (n, w);
            if (w > bestOld[n].Words || (w == bestOld[n].Words && o < bestOld[n].Page)) bestOld[n] = (o, w);
        }

        var result = new List<(int?, int?)>();
        int po = 0, pn = 0;
        for (var o = 0; o < oldCount; o++)
        {
            var n = bestNew[o].Page;
            if (n < pn || bestOld[n].Page != o) continue; // not mutual, or out of order
            Segment(po, o, pn, n);
            result.Add((o, n));
            po = o + 1;
            pn = n + 1;
        }
        Segment(po, oldCount, pn, newCount);
        return result;

        void Segment(int o0, int o1, int n0, int n1)
        {
            cancel.ThrowIfCancellationRequested();
            int p = o1 - o0, q = n1 - n0;
            if (p == 0 && q == 0) return;
            bool any;
            if ((long)p * q <= shared.Count)
            {
                any = false;
                for (var o = o0; o < o1 && !any; o++)
                    for (var n = n0; n < n1 && !any; n++)
                        any = shared.ContainsKey((o, n));
            }
            else any = shared.Keys.Any(k => k.Old >= o0 && k.Old < o1 && k.New >= n0 && k.New < n1);
            if (!any || (long)(p + 1) * (q + 1) > MaxAlignCells)
            {
                // Nothing shared: pages in order, then whatever one side has more.
                var k = Math.Min(p, q);
                for (var i = 0; i < k; i++) result.Add((o0 + i, n0 + i));
                for (var i = k; i < p; i++) result.Add((o0 + i, null));
                for (var i = k; i < q; i++) result.Add((null, n0 + i));
                return;
            }

            // score[i, j]: best for the first i old and j new pages; a pair is worth 2 per shared word plus 1.
            var score = new int[p + 1, q + 1];
            for (var i = 0; i <= p; i++)
                for (var j = 0; j <= q; j++)
                {
                    if (i == 0 && j == 0) continue;
                    var best = int.MinValue;
                    if (i > 0) best = score[i - 1, j];
                    if (j > 0) best = Math.Max(best, score[i, j - 1]);
                    if (i > 0 && j > 0) best = Math.Max(best, score[i - 1, j - 1] + 2 * shared.GetValueOrDefault((o0 + i - 1, n0 + j - 1)) + 1);
                    score[i, j] = best;
                }
            var path = new List<(int?, int?)>();
            for (int i = p, j = q; i > 0 || j > 0;)
            {
                if (i > 0 && j > 0 && score[i, j] == score[i - 1, j - 1] + 2 * shared.GetValueOrDefault((o0 + i - 1, n0 + j - 1)) + 1)
                {
                    path.Add((o0 + i - 1, n0 + j - 1));
                    i--;
                    j--;
                }
                else if (j > 0 && score[i, j] == score[i, j - 1])
                {
                    path.Add((null, n0 + j - 1)); // walking back: an inserted page comes after a removed one
                    j--;
                }
                else
                {
                    path.Add((o0 + i - 1, null));
                    i--;
                }
            }
            path.Reverse();
            result.AddRange(path);
        }
    }
}
