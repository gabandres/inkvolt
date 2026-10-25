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
public sealed record CompareRow(int? OldPage, int? NewPage, RowText Text, int Changes = 0);

public enum ChangeKind { Inserted, Deleted, Changed, PageInserted, PageRemoved }

/// <summary>Characters [Start, End) of a page's text (Start == End: a position between characters).</summary>
public readonly record struct WordSpan(int Page, int Start, int End);

/// <summary>
/// A change: words removed (Old), added (New) or both (a replacement), on one page of each side, or a whole page
/// removed or inserted. An insertion's <see cref="OldAnchor"/> is where it goes in the old text, a deletion's
/// <see cref="NewAnchor"/> where it was taken from in the new text (null when that isn't on the same row).
/// </summary>
public sealed record CompareChange(ChangeKind Kind, int Row, IReadOnlyList<WordSpan> Old, IReadOnlyList<WordSpan> New,
    string OldText, string NewText, WordSpan? OldAnchor = null, WordSpan? NewAnchor = null);

public sealed class CompareResult
{
    public required IReadOnlyList<CompareRow> Rows { get; init; }
    public required IReadOnlyList<CompareChange> Changes { get; init; }
    public int Inserted { get; init; }
    public int Deleted { get; init; }
    public int Changed { get; init; }
    public int PagesInserted { get; init; }
    public int PagesRemoved { get; init; }

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
            parts.Add($"{Count(text, "text change")} ({string.Join(", ", kinds)})");
        }
        else parts.Add("No text changes");
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
/// having all their words reported as changed.
/// </summary>
public static class DocumentCompare
{
    /// <summary>Largest old × new page block aligned exactly; bigger blocks without shared words are paired in order.</summary>
    private const long MaxAlignCells = 4_000_000;

    public static CompareResult Run(IReadOnlyList<PageText> oldPages, IReadOnlyList<PageText> newPages, CancellationToken cancel = default)
    {
        var oldWords = new List<CompareWord>();
        var newWords = new List<CompareWord>();
        for (var p = 0; p < oldPages.Count; p++) oldWords.AddRange(CompareWords.Of(oldPages[p], p));
        for (var p = 0; p < newPages.Count; p++) newWords.AddRange(CompareWords.Of(newPages[p], p));
        cancel.ThrowIfCancellationRequested();

        var oldKeys = oldWords.ConvertAll(w => w.Key);
        var newKeys = newWords.ConvertAll(w => w.Key);
        var ops = WordDiff.Diff(oldKeys, newKeys, cancel);
        // Prefer runs that start and end with a page: a removed page shouldn't take the next page's first word along.
        ops = WordDiff.Slide(ops, oldKeys, newKeys, (kind, s, e) =>
        {
            var words = kind == DiffKind.Delete ? oldWords : newWords;
            var spans = words[e - 1].Page - words[s].Page + 1;
            var starts = s == 0 || words[s - 1].Page != words[s].Page;
            var ends = e == words.Count || words[e].Page != words[e - 1].Page;
            return spans * 4 - (starts ? 1 : 0) - (ends ? 1 : 0);
        });
        cancel.ThrowIfCancellationRequested();

        var oldHasText = new bool[oldPages.Count];
        var newHasText = new bool[newPages.Count];
        foreach (var w in oldWords) oldHasText[w.Page] = true;
        foreach (var w in newWords) newHasText[w.Page] = true;

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

        var changes = WordChanges(ops, oldWords, newWords, oldPages, newPages, rows, rowOfOld, rowOfNew);
        for (var r = 0; r < rows.Count; r++)
        {
            if (rows[r].Text == RowText.OnlyOld && rows[r].OldPage is { } o)
                changes.Add(new CompareChange(ChangeKind.PageRemoved, r, [new WordSpan(o, 0, 0)], [], Excerpt(oldPages[o]), ""));
            else if (rows[r].Text == RowText.OnlyNew && rows[r].NewPage is { } n)
                changes.Add(new CompareChange(ChangeKind.PageInserted, r, [], [new WordSpan(n, 0, 0)], "", Excerpt(newPages[n])));
        }
        changes = [.. changes.OrderBy(c => c.Row)]; // stable: within a row, in reading order
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
            PairsWithoutText = rows.Count(r => r.Text is RowText.NoTextOld or RowText.NoTextNew or RowText.NoTextBoth),
        };
    }

    /// <summary>The start of a page's text, for naming a removed or inserted page.</summary>
    private static string Excerpt(PageText page)
    {
        var t = CompareWords.Display(page.Text, 0, Math.Min(page.Text.Length, 120)).Trim();
        return page.Text.Length > 120 ? t + "…" : t;
    }

    /// <summary>
    /// Groups the diff's inserted and deleted words into changes: a group ends at an unchanged word, at a page break on
    /// either side and at a word of a row whose text isn't compared (a removed, inserted or textless page).
    /// </summary>
    private static List<CompareChange> WordChanges(List<DiffOp> ops, List<CompareWord> oldWords, List<CompareWord> newWords,
        IReadOnlyList<PageText> oldPages, IReadOnlyList<PageText> newPages, List<CompareRow> rows, int[] rowOfOld, int[] rowOfNew)
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
                        if (rows[rowOfOld[oldWords[i].Page]].Text != RowText.Compared) { Close(); break; }
                        if (oLast is { } l && oldWords[l].Page != oldWords[i].Page) Close();
                        oFirst ??= i;
                        oLast = i;
                        break;
                    }
                    default:
                    {
                        var j = op.B + k;
                        if (rows[rowOfNew[newWords[j].Page]].Text != RowText.Compared) { Close(); break; }
                        if (nLast is { } l && newWords[l].Page != newWords[j].Page) Close();
                        else if (nLast is null && oLast is { } ol && rowOfOld[oldWords[ol].Page] != rowOfNew[newWords[j].Page]) Close();
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
            var row = oldSpan is { } os ? rowOfOld[os.Page] : rowOfNew[newSpan!.Value.Page];
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
