namespace InkvoltPdf.Core;

/// <summary>
/// Text that was taken out in one place and put back in another: old words [OldStart, OldEnd) are new words
/// [NewStart, NewEnd), and <see cref="Inner"/> is the diff of the two (indices in the whole documents), so a word edited on
/// the way is a change inside the move.
/// </summary>
public sealed record CompareMove(int OldStart, int OldEnd, int NewStart, int NewEnd, IReadOnlyList<DiffOp> Inner);

/// <summary>
/// Finds moved text in a word diff. A diff can only say removed and inserted, so runs of removed words are looked for in
/// runs of inserted ones: the longest common stretches first (each word used once), stretches a few edited words apart
/// joined. The diff may have matched a common word of the moved text to the same word elsewhere ("the", a final "."), so
/// a stretch grows over a few such words when more of it follows, and over marks at its ends. A stretch counts when it is long enough to mean something (<see cref="MinWords"/> words with letters or digits),
/// or is everything removed and inserted there (<see cref="MinWholeRunWords"/>). What was removed and inserted at the same
/// place is a rewording, never a move. Bounded: past <see cref="MaxWords"/> removed or inserted words, or
/// <see cref="MaxWork"/> word comparisons, no more is looked for.
/// </summary>
public static class CompareMoves
{
    public const int MinWords = 6;
    public const int MinWholeRunWords = 3;

    /// <summary>Stretches this few words apart on both sides are one move, the words between them edited.</summary>
    private const int MaxInnerGap = 12;

    private const int Seed = 3;              // words that must match for a stretch to be looked at
    private const int MaxGrowOver = 3;       // unchanged words in a row a stretch grows over
    private const int MaxSeedPlaces = 32;    // places kept for one seed (boilerplate repeats)
    public const int MaxWords = 200_000;
    public const long MaxWork = 40_000_000;

    private sealed record Stretch(int Old, int New, int Length);

    public static List<CompareMove> Find(IReadOnlyList<DiffOp> ops, IReadOnlyList<string> oldKeys, IReadOnlyList<string> newKeys, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        var deleted = 0L;
        var inserted = 0L;
        foreach (var op in ops)
        {
            if (op.Kind == DiffKind.Delete) deleted += op.Length;
            else if (op.Kind == DiffKind.Insert) inserted += op.Length;
        }
        if (deleted == 0 || inserted == 0 || deleted > MaxWords || inserted > MaxWords) return [];

        // Which unchanged stretch each removed or inserted word follows (the same one: the same place), -1 when unchanged.
        var oldPlace = new int[oldKeys.Count];
        var newPlace = new int[newKeys.Count];
        Array.Fill(oldPlace, -1);
        Array.Fill(newPlace, -1);
        var place = 0;
        foreach (var op in ops)
        {
            if (op.Kind == DiffKind.Equal) place++;
            else if (op.Kind == DiffKind.Delete) Array.Fill(oldPlace, place, op.A, op.Length);
            else Array.Fill(newPlace, place, op.B, op.Length);
        }

        var ids = new Dictionary<string, int>(StringComparer.Ordinal);
        int Id(string key)
        {
            if (!ids.TryGetValue(key, out var id)) ids[key] = id = ids.Count;
            return id;
        }
        var oldIds = new int[oldKeys.Count];
        var newIds = new int[newKeys.Count];
        for (var i = 0; i < oldIds.Length; i++) if (oldPlace[i] >= 0) oldIds[i] = Id(oldKeys[i]);
        for (var j = 0; j < newIds.Length; j++) if (newPlace[j] >= 0) newIds[j] = Id(newKeys[j]);

        var stretches = Stretches(oldIds, newIds, oldPlace, newPlace, oldKeys, newKeys, cancel);
        var usedOld = new bool[oldKeys.Count];
        var usedNew = new bool[newKeys.Count];
        var taken = Take(stretches, usedOld, usedNew);
        var joined = Join(taken, oldPlace, newPlace);

        var moves = new List<CompareMove>();
        foreach (var (o0, o1, n0, n1, matched) in joined)
        {
            cancel.ThrowIfCancellationRequested();
            if (oldPlace[o0] == newPlace[n0]) continue; // the same place: a rewording
            var words = 0;
            foreach (var s in matched)
                for (var k = 0; k < s.Length; k++)
                    if (HasLetterOrDigit(oldKeys[s.Old + k])) words++;
            var whole = (o0 == 0 || oldPlace[o0 - 1] < 0) && (o1 == oldPlace.Length || oldPlace[o1] < 0)
                        && (n0 == 0 || newPlace[n0 - 1] < 0) && (n1 == newPlace.Length || newPlace[n1] < 0);
            if (words < MinWords && !(whole && words >= MinWholeRunWords)) continue;

            // Marks that came along, whichever word the diff matched them to: an opening one before it, a final "." after it
            // (the "." before it belongs to the sentence before).
            var (a0, b0, a1, b1) = (o0, n0, o1, n1);
            while (a0 > 0 && b0 > 0 && !usedOld[a0 - 1] && !usedNew[b0 - 1] && oldKeys[a0 - 1] == newKeys[b0 - 1] && IsOpening(oldKeys[a0 - 1])) (a0, b0) = (a0 - 1, b0 - 1);
            while (a1 < usedOld.Length && b1 < usedNew.Length && !usedOld[a1] && !usedNew[b1] && oldKeys[a1] == newKeys[b1] && !HasLetterOrDigit(oldKeys[a1]) && !IsOpening(oldKeys[a1])) (a1, b1) = (a1 + 1, b1 + 1);
            moves.Add(new CompareMove(a0, a1, b0, b1, Inner(oldKeys, newKeys, a0, a1, b0, b1, cancel)));
        }
        return moves;
    }

    private static bool IsOpening(string key) =>
        key.Length == 1 && char.GetUnicodeCategory(key[0]) is System.Globalization.UnicodeCategory.OpenPunctuation or System.Globalization.UnicodeCategory.InitialQuotePunctuation;

    private static bool HasLetterOrDigit(string key)
    {
        foreach (var c in key)
            if (char.IsLetterOrDigit(c)) return true;
        return false;
    }

    /// <summary>The longest runs of the same words among removed (old) and inserted (new) ones that start at a shared seed.</summary>
    private static List<Stretch> Stretches(int[] oldIds, int[] newIds, int[] oldPlace, int[] newPlace, IReadOnlyList<string> oldKeys, IReadOnlyList<string> newKeys, CancellationToken cancel)
    {
        var seeds = new Dictionary<(int, int, int), List<int>>();
        for (var i = 0; i + Seed <= oldIds.Length; i++)
        {
            if (oldPlace[i] < 0 || oldPlace[i + 1] < 0 || oldPlace[i + 2] < 0) continue;
            var key = (oldIds[i], oldIds[i + 1], oldIds[i + 2]);
            if (!seeds.TryGetValue(key, out var at)) seeds[key] = at = [];
            if (at.Count < MaxSeedPlaces) at.Add(i);
        }

        var found = new List<Stretch>();
        var work = 0L;
        for (var j = 0; j + Seed <= newIds.Length; j++)
        {
            if ((j & 1023) == 0) cancel.ThrowIfCancellationRequested();
            if (newPlace[j] < 0 || newPlace[j + 1] < 0 || newPlace[j + 2] < 0) continue;
            if (!seeds.TryGetValue((newIds[j], newIds[j + 1], newIds[j + 2]), out var at)) continue;
            foreach (var i in at)
            {
                // Only where a run starts: inside one it was found already.
                if (i > 0 && j > 0 && oldPlace[i - 1] >= 0 && newPlace[j - 1] >= 0 && oldIds[i - 1] == newIds[j - 1]) continue;
                var length = Seed;
                while (true)
                {
                    while (i + length < oldIds.Length && j + length < newIds.Length && oldPlace[i + length] >= 0 && newPlace[j + length] >= 0
                           && oldIds[i + length] == newIds[j + length]) length++;
                    // Over a few words the diff matched elsewhere, if the same words go on after them.
                    var over = 0;
                    while (over < MaxGrowOver && i + length + over < oldIds.Length && j + length + over < newIds.Length
                           && (oldPlace[i + length + over] < 0 || newPlace[j + length + over] < 0)
                           && oldKeys[i + length + over] == newKeys[j + length + over]) over++;
                    if (over == 0 || i + length + over >= oldIds.Length || j + length + over >= newIds.Length
                        || oldPlace[i + length + over] < 0 || newPlace[j + length + over] < 0
                        || oldIds[i + length + over] != newIds[j + length + over]) break;
                    length += over;
                }
                found.Add(new Stretch(i, j, length));
                work += length;
                if (work > MaxWork) return found;
            }
        }
        return found;
    }

    /// <summary>Longest first; a stretch keeps its longest part no earlier stretch has used.</summary>
    private static List<Stretch> Take(List<Stretch> stretches, bool[] usedOld, bool[] usedNew)
    {
        var taken = new List<Stretch>();
        foreach (var s in stretches.OrderByDescending(s => s.Length).ThenBy(s => s.Old).ThenBy(s => s.New))
        {
            var (bestStart, bestLength, start) = (0, 0, -1);
            for (var k = 0; k <= s.Length; k++)
            {
                var free = k < s.Length && !usedOld[s.Old + k] && !usedNew[s.New + k];
                if (free && start < 0) start = k;
                else if (!free && start >= 0)
                {
                    if (k - start > bestLength) (bestStart, bestLength) = (start, k - start);
                    start = -1;
                }
            }
            if (bestLength < Seed) continue;
            Array.Fill(usedOld, true, s.Old + bestStart, bestLength);
            Array.Fill(usedNew, true, s.New + bestStart, bestLength);
            taken.Add(new Stretch(s.Old + bestStart, s.New + bestStart, bestLength));
        }
        return [.. taken.OrderBy(s => s.Old)];
    }

    /// <summary>Stretches a few edited words apart, in order on both sides, are one move.</summary>
    private static List<(int O0, int O1, int N0, int N1, List<Stretch> Matched)> Join(List<Stretch> stretches, int[] oldPlace, int[] newPlace)
    {
        var joined = new List<(int, int, int, int, List<Stretch>)>();
        for (var k = 0; k < stretches.Count;)
        {
            var first = stretches[k++];
            var matched = new List<Stretch> { first };
            var (o1, n1) = (first.Old + first.Length, first.New + first.Length);
            while (k < stretches.Count)
            {
                var next = stretches[k];
                var (gapOld, gapNew) = (next.Old - o1, next.New - n1);
                if (gapOld < 0 || gapNew < 0 || gapOld > MaxInnerGap || gapNew > MaxInnerGap) break;
                if (!AllChanged(oldPlace, o1, next.Old) || !AllChanged(newPlace, n1, next.New)) break;
                matched.Add(next);
                (o1, n1) = (next.Old + next.Length, next.New + next.Length);
                k++;
            }
            joined.Add((first.Old, o1, first.New, n1, matched));
        }
        return joined;

        static bool AllChanged(int[] place, int from, int to)
        {
            for (var i = from; i < to; i++)
                if (place[i] < 0) return false;
            return true;
        }
    }

    private static List<DiffOp> Inner(IReadOnlyList<string> oldKeys, IReadOnlyList<string> newKeys, int o0, int o1, int n0, int n1, CancellationToken cancel)
    {
        var a = new string[o1 - o0];
        var b = new string[n1 - n0];
        for (var i = 0; i < a.Length; i++) a[i] = oldKeys[o0 + i];
        for (var j = 0; j < b.Length; j++) b[j] = newKeys[n0 + j];
        return [.. WordDiff.Diff(a, b, cancel).Select(op => op with { A = op.A + o0, B = op.B + n0 })];
    }
}

/// <summary>
/// Running headers and footers: a line at the top or bottom of most pages, the same but for its page number. Where both
/// documents have the same one it is left out of the word diff, since page numbers land between other words wherever the
/// text flows differently. A number that stays the same on every page isn't a page number ("Contract 123"): it must match
/// too, and so does one that differs without counting up with the page ("Subtotal: 1,234.56"), which makes the line text. A line only one document has, or that differs, is compared as text, so it is reported.
/// </summary>
public static class CompareRunningLines
{
    private const int EdgeLines = 2;       // lines looked at on each edge of a page
    private const int MinPageLines = 3;    // a page with less is all text, no furniture
    private const double MinShare = 0.6;
    private const double MinCountingShare = 0.8; // of a line's steps from page to page: a section may start its numbering again

    /// <summary>For each page of each document, the [Start, End) ranges of its text to leave out of the diff.</summary>
    public static ((int Start, int End)[][] Old, (int Start, int End)[][] New) Find(IReadOnlyList<PageText> oldPages, IReadOnlyList<PageText> newPages, CancellationToken cancel = default)
    {
        var (oldLines, oldRunning) = Running(oldPages, cancel);
        var (newLines, newRunning) = Running(newPages, cancel);
        oldRunning.IntersectWith(newRunning);
        return (Ranges(oldLines, oldRunning), Ranges(newLines, oldRunning));

        static (int, int)[][] Ranges(List<(string Key, int Start, int End)>[] lines, HashSet<string> keep) =>
            [.. lines.Select(page => page.Where(l => keep.Contains(l.Key)).Select(l => (l.Start, l.End)).ToArray())];
    }

    private static (List<(string Key, int Start, int End)>[] Lines, HashSet<string> Running) Running(IReadOnlyList<PageText> pages, CancellationToken cancel)
    {
        var edges = new List<(string Raw, string Masked, int Start, int End)>[pages.Count];
        var eligible = 0;
        var seen = new Dictionary<string, (int Pages, HashSet<string> Texts, List<(int Page, string Raw)> Where)>(StringComparer.Ordinal);
        for (var p = 0; p < pages.Count; p++)
        {
            if ((p & 63) == 0) cancel.ThrowIfCancellationRequested();
            edges[p] = Edges(pages[p]);
            if (edges[p].Count == 0) continue;
            eligible++;
            foreach (var masked in edges[p].Select(e => e.Masked).Distinct())
            {
                if (!seen.TryGetValue(masked, out var entry)) entry = (0, new HashSet<string>(StringComparer.Ordinal), []);
                foreach (var e in edges[p].Where(e => e.Masked == masked))
                {
                    entry.Texts.Add(e.Raw);
                    entry.Where.Add((p, e.Raw));
                }
                seen[masked] = (entry.Pages + 1, entry.Texts, entry.Where);
            }
        }

        var needed = Math.Max(2, (int)Math.Ceiling(eligible * MinShare));
        var counting = new Dictionary<string, bool[]?>(StringComparer.Ordinal);
        var running = new HashSet<string>(StringComparer.Ordinal);
        var lines = new List<(string, int, int)>[pages.Count];
        for (var p = 0; p < pages.Count; p++)
        {
            lines[p] = [];
            foreach (var (raw, masked, start, end) in edges[p])
            {
                if (seen[masked].Pages < needed) continue;
                // A number that counts up with the page is a page number; any other number must match, on every page: a line
                // whose numbers just differ ("Subtotal: 1,234.56") is text, and is compared.
                if (!counting.TryGetValue(masked, out var slots)) counting[masked] = slots = CountingNumbers(seen[masked].Where);
                if (seen[masked].Texts.Count > 1 && slots is null) continue;
                var key = seen[masked].Texts.Count > 1 ? KeyOf(raw, slots!) : raw;
                running.Add(key);
                lines[p].Add((key, start, end));
            }
        }
        return (lines, running);
    }

    /// <summary>Which of a line's numbers count up with the page across the pages it is on; null when all the differing ones don't.</summary>
    private static bool[]? CountingNumbers(List<(int Page, string Raw)> where)
    {
        var numbers = where.ConvertAll(w => Numbers(w.Raw));
        var count = numbers[0].Count;
        var slots = new bool[count];
        var any = false;
        for (var k = 0; k < count; k++)
        {
            int steps = 0, counted = 0;
            var same = true;
            for (var i = 1; i < where.Count; i++)
            {
                if (where[i].Page == where[i - 1].Page) continue;
                steps++;
                if (numbers[i][k] != numbers[i - 1][k]) same = false;
                if (long.TryParse(numbers[i][k], out var b) && long.TryParse(numbers[i - 1][k], out var a) && b - a == where[i].Page - where[i - 1].Page) counted++;
            }
            if (same) continue; // stays as it is, and must match
            if (steps == 0 || counted < steps * MinCountingShare) return null;
            slots[k] = any = true;
        }
        return any ? slots : null;
    }

    private static List<string> Numbers(string raw) =>
        [.. System.Text.RegularExpressions.Regex.Matches(raw, @"\d+").Select(m => m.Value)];

    /// <summary>The line with the numbers that count up masked, the others as they are.</summary>
    private static string KeyOf(string raw, bool[] slots)
    {
        var k = 0;
        return System.Text.RegularExpressions.Regex.Replace(raw, @"\d+", m => k < slots.Length && slots[k++] ? "#" : m.Value);
    }

    /// <summary>The topmost and bottommost lines of a page, by where they are, not where the file stores them.</summary>
    private static List<(string Raw, string Masked, int Start, int End)> Edges(PageText page)
    {
        var all = new List<(int Start, int End, double Top)>();
        var s = page.Text;
        for (var start = 0; start < s.Length;)
        {
            var end = s.IndexOf('\n', start);
            if (end < 0) end = s.Length;
            if (end > start) all.Add((start, end, page.BoxAt(start).Y));
            start = end + 1;
        }
        if (all.Count < MinPageLines) return [];
        var byTop = all.OrderBy(l => l.Top).ToList();
        var edge = byTop.Take(EdgeLines).Concat(byTop.Skip(Math.Max(EdgeLines, byTop.Count - EdgeLines)));
        return [.. edge.Select(l =>
        {
            var raw = s[l.Start..l.End].Trim();
            return (raw, System.Text.RegularExpressions.Regex.Replace(raw, @"\d+", "#"), l.Start, l.End);
        })];
    }
}
