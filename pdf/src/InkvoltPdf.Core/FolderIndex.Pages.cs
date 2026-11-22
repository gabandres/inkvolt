using System.Text;

namespace InkvoltPdf.Core;

/// <summary>A page the index proposes for a question: where it is, and how many of the question's words it holds.</summary>
/// <param name="RelativePath">From the indexed folder.</param>
/// <param name="Page">The page, from 0.</param>
/// <param name="Words">How many of the question's distinct words are on the page.</param>
public sealed record RankedPage(string RelativePath, int Page, int Words);

public sealed partial class FolderIndex
{
    /// <summary>
    /// The pages holding the most of <paramref name="words"/> (any of them, not all, as a search needs), best first and then
    /// in path and page order, at most <paramref name="maxPages"/>: what Ask Across Folders reads before it picks the
    /// passages to send. A word counts where a term holds it, as in <see cref="Search"/>; words with no letter or digit
    /// count for nothing.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="FolderIndexDamagedException">The list of terms doesn't read back.</exception>
    public IReadOnlyList<RankedPage> Rank(IEnumerable<string> words, int maxPages, CancellationToken cancel = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var terms = words.SelectMany(IndexTerms.Of).Distinct().Take(MaxRankWords).ToList();
        if (terms.Count == 0 || maxPages <= 0) return [];
        var state = Acquire();
        try
        {
            var map = state.Pages;
            var counts = new byte[map.Total];
            var bits = new ulong[(map.Total + 64) / 64];
            foreach (var term in terms)
            {
                Array.Clear(bits);
                MarkPages(state, map, Encoding.UTF8.GetBytes(IndexTerms.Lookup(term)), bits, cancel);
                for (var w = 0; w < bits.Length; w++)
                    for (var b = bits[w]; b != 0; b &= b - 1)
                    {
                        var page = w * 64 + System.Numerics.BitOperations.TrailingZeroCount(b);
                        if (page < counts.Length) counts[page]++;
                    }
            }
            // Best first: by words held, then in path and page order (the bits' order).
            var best = new List<(int Bit, int Words)>();
            for (var p = 0; p < counts.Length; p++)
                if (counts[p] > 0) best.Add((p, counts[p]));
            var chosen = best.OrderByDescending(x => x.Words).ThenBy(x => x.Bit).Take(maxPages);
            var result = new List<RankedPage>();
            var file = 0;
            foreach (var (bit, n) in chosen.OrderBy(x => x.Bit))
            {
                while (file + 1 < map.First.Length && map.First[file + 1] <= bit) file++;
                while (file > 0 && map.First[file] > bit) file--;
                var page = bit - map.First[file];
                if (page < map.Files[file].Pages) result.Add(new RankedPage(map.Files[file].RelativePath, page, n));
            }
            return [.. result.OrderByDescending(r => r.Words)];
        }
        finally
        {
            state.Store.Release();
        }
    }

    /// <summary>Most distinct words a question is ranked by (a question is a sentence, not a document).</summary>
    public const int MaxRankWords = 32;

    /// <summary>
    /// The kept text of each page asked for, in the order asked; "" for a page the index doesn't have (its file gone, or the
    /// page past its end).
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="FolderIndexDamagedException">A page's text doesn't read back.</exception>
    public IReadOnlyList<string> PageTexts(IReadOnlyList<(string RelativePath, int Page)> pages, CancellationToken cancel = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var state = Acquire();
        try
        {
            var reader = new PageReader(state.Store.Handle, new System.Collections.Concurrent.ConcurrentDictionary<int, PageDirectory>());
            var texts = new List<string>(pages.Count);
            foreach (var (path, page) in pages)
            {
                cancel.ThrowIfCancellationRequested();
                texts.Add(state.ByPath.TryGetValue(path, out var f) && f.State != IndexedState.Damaged && page >= 0 && page < f.Pages
                    ? Encoding.UTF8.GetString(reader.PageBytes(f, page))
                    : "");
            }
            return texts;
        }
        finally
        {
            state.Store.Release();
        }
    }
}
