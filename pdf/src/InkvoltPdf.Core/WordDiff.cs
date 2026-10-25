namespace InkvoltPdf.Core;

public enum DiffKind { Equal, Delete, Insert }

/// <summary>
/// One run of a diff. Equal: a[A..A+Length) matches b[B..B+Length). Delete: a[A..A+Length) is gone (B is where it was in
/// b). Insert: b[B..B+Length) is new (A is where it goes in a). Runs come in order and cover both sequences.
/// </summary>
public readonly record struct DiffOp(DiffKind Kind, int A, int B, int Length);

/// <summary>
/// Word-level diff: common prefix and suffix trimmed, then words that occur exactly once on both sides anchor the
/// match (patience diff, so moved boilerplate like "the" can't pull unrelated passages together), and the stretches
/// between anchors get Myers' shortest edit script. Bounded: a stretch needing more than <see cref="MaxEdits"/> edits,
/// or a run past the overall work budget, is reported as replaced instead of searched further.
/// </summary>
public static class WordDiff
{
    /// <summary>Most edits Myers looks for in one stretch (its memory grows with the square of this).</summary>
    public const int MaxEdits = 2000;

    /// <summary>Rough upper bound on the steps one diff takes before the rest is reported as replaced.</summary>
    private const long WorkBudget = 300_000_000;

    public static List<DiffOp> Diff(IReadOnlyList<string> a, IReadOnlyList<string> b, CancellationToken cancel = default) =>
        Diff(a, b, patience: true, cancel);

    /// <summary>Myers alone, without unique-word anchors: always a shortest edit script (within <see cref="MaxEdits"/>).</summary>
    internal static List<DiffOp> Shortest(IReadOnlyList<string> a, IReadOnlyList<string> b) => Diff(a, b, patience: false, default);

    private static List<DiffOp> Diff(IReadOnlyList<string> a, IReadOnlyList<string> b, bool patience, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        // Words become ints, so comparisons are cheap.
        var ids = new Dictionary<string, int>(StringComparer.Ordinal);
        int Id(string s)
        {
            if (!ids.TryGetValue(s, out var id)) ids[s] = id = ids.Count;
            return id;
        }
        var x = new int[a.Count];
        var y = new int[b.Count];
        for (var i = 0; i < x.Length; i++) x[i] = Id(a[i]);
        for (var i = 0; i < y.Length; i++) y[i] = Id(b[i]);
        return new Differ(x, y, patience, cancel).Run();
    }

    /// <summary>
    /// Slides each pure insert or delete run (an Equal on both sides) along runs of repeated words to the place where
    /// <paramref name="cost"/> is lowest, e.g. so a removed passage doesn't take the first word of the next page with it.
    /// <paramref name="cost"/> gets the run's kind and its [start, end) in a (Delete) or b (Insert); ties keep the
    /// position the diff found.
    /// </summary>
    public static List<DiffOp> Slide(List<DiffOp> ops, IReadOnlyList<string> a, IReadOnlyList<string> b, Func<DiffKind, int, int, double> cost)
    {
        var list = ops.ToList();
        for (var i = 0; i < list.Count; i++)
        {
            var op = list[i];
            if (op.Kind == DiffKind.Equal) continue;
            var before = i > 0 ? list[i - 1] : default;
            var after = i + 1 < list.Count ? list[i + 1] : default;
            var hasBefore = i > 0 && before.Kind == DiffKind.Equal;
            var hasAfter = i + 1 < list.Count && after.Kind == DiffKind.Equal;
            if (!hasBefore && !hasAfter) continue; // next to the other kind: a replacement, not a pure run
            if ((i > 0 && !hasBefore) || (i + 1 < list.Count && !hasAfter)) continue;

            var seq = op.Kind == DiffKind.Delete ? a : b;
            var start = op.Kind == DiffKind.Delete ? op.A : op.B;
            var len = op.Length;
            // How far it can move: up while the word before the run equals the run's last word, down likewise.
            var up = 0;
            while (hasBefore && up < before.Length && seq[start - up - 1] == seq[start + len - up - 1]) up++;
            var down = 0;
            while (hasAfter && down < after.Length && seq[start + down] == seq[start + len + down]) down++;
            if (up == 0 && down == 0) continue;

            var best = 0;
            var bestCost = cost(op.Kind, start, start + len);
            for (var k = -up; k <= down; k++)
            {
                if (k == 0) continue;
                var c = cost(op.Kind, start + k, start + k + len);
                if (c < bestCost - 1e-9)
                {
                    bestCost = c;
                    best = k;
                }
            }
            if (best == 0) continue;
            var moved = op with { A = op.A + best, B = op.B + best };
            list[i] = moved;
            // The words the run moved past change sides; at either end of the sequences they make a new equal run.
            if (hasBefore) list[i - 1] = before with { Length = before.Length + best };
            else if (best > 0) list.Insert(i++, new DiffOp(DiffKind.Equal, op.A, op.B, best));
            if (hasAfter) list[i + 1] = after with { A = after.A + best, B = after.B + best, Length = after.Length - best };
            else if (best < 0)
                list.Insert(i + 1, new DiffOp(DiffKind.Equal, moved.A + (op.Kind == DiffKind.Delete ? len : 0), moved.B + (op.Kind == DiffKind.Insert ? len : 0), -best));
        }
        return Merge(list);
    }

    /// <summary>Drops empty runs and joins neighbours: equal runs merged, and between two equal runs one delete then one insert.</summary>
    private static List<DiffOp> Merge(List<DiffOp> ops)
    {
        var result = new List<DiffOp>(ops.Count);
        int del = 0, ins = 0, blockA = 0, blockB = 0;
        void Flush()
        {
            if (del > 0) result.Add(new DiffOp(DiffKind.Delete, blockA, blockB, del));
            if (ins > 0) result.Add(new DiffOp(DiffKind.Insert, blockA + del, blockB, ins));
            del = ins = 0;
        }
        foreach (var op in ops)
        {
            if (op.Length <= 0) continue;
            if (op.Kind == DiffKind.Equal)
            {
                Flush();
                if (result.Count > 0 && result[^1].Kind == DiffKind.Equal) result[^1] = result[^1] with { Length = result[^1].Length + op.Length };
                else result.Add(op);
                continue;
            }
            if (del == 0 && ins == 0)
            {
                // The block starts where its first edit sits.
                blockA = op.A;
                blockB = op.B;
            }
            if (op.Kind == DiffKind.Delete) del += op.Length;
            else ins += op.Length;
        }
        Flush();
        return result;
    }

    private sealed class Differ(int[] a, int[] b, bool patience, CancellationToken cancel)
    {
        private readonly List<DiffOp> _ops = [];
        private long _work;

        /// <summary>Work items: a stretch to diff, or an equal run to emit once everything before it is out.</summary>
        private readonly record struct Item(bool IsEqual, int ALo, int AHi, int BLo, int BHi);

        public List<DiffOp> Run()
        {
            // An explicit stack instead of recursion: anchors can nest as deep as the input is long.
            var stack = new Stack<Item>();
            stack.Push(new Item(false, 0, a.Length, 0, b.Length));
            while (stack.Count > 0)
            {
                cancel.ThrowIfCancellationRequested();
                var it = stack.Pop();
                if (it.IsEqual) Emit(DiffKind.Equal, it.ALo, it.BLo, it.AHi - it.ALo);
                else Range(it.ALo, it.AHi, it.BLo, it.BHi, stack);
            }
            return Merge(_ops);
        }

        private void Emit(DiffKind kind, int ai, int bi, int length)
        {
            if (length > 0) _ops.Add(new DiffOp(kind, ai, bi, length));
        }

        private void Replace(int aLo, int aHi, int bLo, int bHi)
        {
            Emit(DiffKind.Delete, aLo, bLo, aHi - aLo);
            Emit(DiffKind.Insert, aHi, bLo, bHi - bLo);
        }

        private void Range(int aLo, int aHi, int bLo, int bHi, Stack<Item> stack)
        {
            var pre = 0;
            while (aLo + pre < aHi && bLo + pre < bHi && a[aLo + pre] == b[bLo + pre]) pre++;
            Emit(DiffKind.Equal, aLo, bLo, pre);
            aLo += pre;
            bLo += pre;
            var suf = 0;
            while (aHi - suf > aLo && bHi - suf > bLo && a[aHi - suf - 1] == b[bHi - suf - 1]) suf++;
            aHi -= suf;
            bHi -= suf;
            // Pushed first, so it's emitted after the middle.
            if (suf > 0) stack.Push(new Item(true, aHi, aHi + suf, bHi, bHi + suf));

            if (aLo == aHi || bLo == bHi)
            {
                Replace(aLo, aHi, bLo, bHi);
                return;
            }
            _work += (aHi - aLo) + (bHi - bLo);
            if (_work > WorkBudget)
            {
                Replace(aLo, aHi, bLo, bHi);
                return;
            }

            var anchors = patience ? Anchors(aLo, aHi, bLo, bHi) : [];
            if (anchors is null)
            {
                Replace(aLo, aHi, bLo, bHi); // nothing in common at all
                return;
            }
            if (anchors.Count > 0)
            {
                // Stretches between anchors, pushed in reverse so they come out in order.
                var items = new List<Item>();
                int pa = aLo, pb = bLo;
                foreach (var (i, j) in anchors)
                {
                    items.Add(new Item(false, pa, i, pb, j));
                    items.Add(new Item(true, i, i + 1, j, j + 1));
                    pa = i + 1;
                    pb = j + 1;
                }
                items.Add(new Item(false, pa, aHi, pb, bHi));
                for (var k = items.Count - 1; k >= 0; k--)
                    if (items[k].IsEqual || items[k].AHi > items[k].ALo || items[k].BHi > items[k].BLo) stack.Push(items[k]);
                return;
            }
            if (!Myers(aLo, aHi, bLo, bHi)) Replace(aLo, aHi, bLo, bHi);
        }

        /// <summary>
        /// The longest increasing chain of words found exactly once in each side of the stretch (patience sorting).
        /// Empty when there are none; null when the two sides share no word at all.
        /// </summary>
        private List<(int I, int J)>? Anchors(int aLo, int aHi, int bLo, int bHi)
        {
            var countA = new Dictionary<int, (int Count, int Index)>();
            for (var i = aLo; i < aHi; i++)
                countA[a[i]] = countA.TryGetValue(a[i], out var c) ? (c.Count + 1, c.Index) : (1, i);
            var countB = new Dictionary<int, (int Count, int Index)>();
            var shared = false;
            for (var j = bLo; j < bHi; j++)
            {
                if (!countA.ContainsKey(b[j])) continue;
                shared = true;
                countB[b[j]] = countB.TryGetValue(b[j], out var c) ? (c.Count + 1, c.Index) : (1, j);
            }
            if (!shared) return null;

            var pairs = new List<(int I, int J)>();
            for (var i = aLo; i < aHi; i++)
                if (countA[a[i]].Count == 1 && countB.TryGetValue(a[i], out var cb) && cb.Count == 1)
                    pairs.Add((i, cb.Index));
            if (pairs.Count == 0) return [];

            // Longest increasing subsequence by J (pairs are already ordered by I).
            var tails = new List<int>(); // index into pairs of the smallest tail of each length
            var prev = new int[pairs.Count];
            for (var k = 0; k < pairs.Count; k++)
            {
                int lo = 0, hi = tails.Count;
                while (lo < hi)
                {
                    var mid = (lo + hi) / 2;
                    if (pairs[tails[mid]].J < pairs[k].J) lo = mid + 1;
                    else hi = mid;
                }
                prev[k] = lo > 0 ? tails[lo - 1] : -1;
                if (lo == tails.Count) tails.Add(k);
                else tails[lo] = k;
            }
            var chain = new List<(int, int)>(tails.Count);
            for (var k = tails[^1]; k >= 0; k = prev[k]) chain.Add(pairs[k]);
            chain.Reverse();
            return chain;
        }

        /// <summary>Myers' O((N+M)D) shortest edit script; false when it needs more than <see cref="MaxEdits"/> edits.</summary>
        private bool Myers(int aLo, int aHi, int bLo, int bHi)
        {
            int n = aHi - aLo, m = bHi - bLo, max = Math.Min(n + m, MaxEdits);
            var offset = max + 1;
            var v = new int[2 * max + 3];
            var trace = new List<int[]>();
            var found = -1;
            for (var d = 0; d <= max && found < 0; d++)
            {
                if ((d & 63) == 0) cancel.ThrowIfCancellationRequested();
                // Keep only the diagonals reachable in d steps.
                var snapshot = new int[2 * d + 1];
                for (var k = -d; k <= d; k += 2)
                {
                    int xx = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
                    var yy = xx - k;
                    while (xx < n && yy < m && a[aLo + xx] == b[bLo + yy]) { xx++; yy++; }
                    v[offset + k] = xx;
                    if (xx >= n && yy >= m) found = d;
                }
                for (var k = -d; k <= d; k++) snapshot[k + d] = v[offset + k];
                trace.Add(snapshot);
                _work += 2 * d + 1;
            }
            if (found < 0) return false;

            // Walk back from (n, m), collecting single steps, then emit them in order.
            var steps = new List<(DiffKind Kind, int X, int Y)>();
            int px = n, py = m;
            for (var d = found; d > 0; d--)
            {
                var prevV = trace[d - 1];
                int Prev(int k) => prevV[k + d - 1];
                var k = px - py;
                var down = k == -d || (k != d && Prev(k - 1) < Prev(k + 1));
                var pk = down ? k + 1 : k - 1;
                var sx = Prev(pk);
                var sy = sx - pk;
                var ex = down ? sx : sx + 1;
                var ey = ex - k;
                while (px > ex && py > ey) { px--; py--; steps.Add((DiffKind.Equal, px, py)); }
                steps.Add(down ? (DiffKind.Insert, sx, sy) : (DiffKind.Delete, sx, sy));
                px = sx;
                py = sy;
            }
            while (px > 0 && py > 0) { px--; py--; steps.Add((DiffKind.Equal, px, py)); }
            for (var s = steps.Count - 1; s >= 0; s--) Emit(steps[s].Kind, aLo + steps[s].X, bLo + steps[s].Y, 1);
            return true;
        }
    }
}
