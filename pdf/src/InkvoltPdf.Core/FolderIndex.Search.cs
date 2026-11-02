using System.IO.Compression;
using System.Numerics;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>What a folder search looks for, as Find's options; case and accents are ignored unless asked otherwise.</summary>
/// <param name="MaxPages">Pages to list at most.</param>
public sealed record FolderSearchOptions(bool MatchCase = false, bool WholeWord = false, bool IgnoreAccents = true, int MaxPages = 500);

/// <summary>One page a search found.</summary>
/// <param name="RelativePath">From the indexed folder.</param>
/// <param name="Page">The page, from 0.</param>
/// <param name="Hits">How often it is on the page.</param>
/// <param name="Excerpt">The first hit with the text around it, on one line.</param>
/// <param name="MatchStart">Where the hit is in the excerpt.</param>
public sealed record FolderHit(string RelativePath, int Page, int Hits, string Excerpt, int MatchStart, int MatchLength);

/// <summary>
/// One search under way on a snapshot of a <see cref="FolderIndex"/>: the index has narrowed it to the pages that have every word, and
/// <see cref="Hits"/> asks Find, on the kept text, about each of them in order. Holds the snapshot's file until disposed.
/// </summary>
public sealed class FolderSearchRun : IDisposable
{
    private readonly Func<CancellationToken, IEnumerable<FolderHit>> _hits;
    private readonly Action _release;
    private int _released;

    internal FolderSearchRun(int candidatePages, int candidateFiles, bool hasWords, Func<CancellationToken, IEnumerable<FolderHit>> hits, Action release)
    {
        CandidatePages = candidatePages;
        CandidateFiles = candidateFiles;
        HasWords = hasWords;
        _hits = hits;
        _release = release;
    }

    /// <summary>Pages with all the query's words: what a word found on many pages is counted by, before they are listed.</summary>
    public int CandidatePages { get; }

    public int CandidateFiles { get; }

    /// <summary>False: nothing in the query is a letter or digit, and the index files only those.</summary>
    public bool HasWords { get; }

    /// <summary>The pages Find confirms, in path order, up to the search's limit. Read them once.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="FolderIndexDamagedException">A page's text doesn't read back: the index should be built again.</exception>
    public IEnumerable<FolderHit> Hits(CancellationToken cancel = default) => _hits(cancel);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _released, 1) == 0) _release();
    }
}

public sealed partial class FolderIndex
{
    /// <summary>
    /// Starts a search. Each word of the query narrows the pages: every term with the word inside it counts, as Find finds a word inside a
    /// longer one; then <see cref="FolderSearchRun.Hits"/> runs Find itself on what is left, so a result here is what Find
    /// would say on that page. A phrase's words are next to each other only if Find says so.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="FolderIndexDamagedException">The list of terms doesn't read back.</exception>
    public FolderSearchRun Search(string query, FolderSearchOptions? options = null, CancellationToken cancel = default)
    {
        options ??= new FolderSearchOptions();
        ObjectDisposedException.ThrowIf(_disposed, this);
        var state = Acquire();
        try
        {
            var terms = IndexTerms.Of(query);
            if (terms.Count == 0) return Finished(state, false);
            var map = state.Pages;
            ulong[]? found = null;
            foreach (var term in terms.Distinct())
            {
                var bits = new ulong[(map.Total + 64) / 64];
                MarkPages(state, map, Encoding.UTF8.GetBytes(term), bits, cancel);
                if (found is null) found = bits;
                else
                    for (var i = 0; i < found.Length; i++)
                        found[i] &= bits[i];
            }
            var pages = 0;
            foreach (var word in found!) pages += BitOperations.PopCount(word);
            if (pages == 0) return Finished(state, true);
            var files = 0;
            for (var f = 0; f < map.Files.Length; f++)
                if (AnyPage(found, map.First[f], map.Files[f].Pages)) files++;
            var run = found;
            return new FolderSearchRun(pages, files, true, c => Confirm(state, map, run, query, options, terms, c), state.Store.Release);
        }
        catch
        {
            state.Store.Release();
            throw;
        }
    }

    private static FolderSearchRun Finished(Snapshot state, bool hasWords) =>
        new(0, 0, hasWords, _ => [], state.Store.Release);

    /// <summary>Sets the bit of every page with <paramref name="word"/> in one of its terms.</summary>
    private static void MarkPages(Snapshot state, PageMap map, ReadOnlySpan<byte> word, ulong[] bits, CancellationToken cancel)
    {
        var cursor = new Cursor(state.Store.Handle);
        var first = map.FirstById;
        var count = map.CountById;
        foreach (var segment in state.Segments)
        {
            cancel.ThrowIfCancellationRequested();
            var table = segment.Table(state.Store.Handle);
            var matches = table.Containing(word);
            for (var m = 0; m < matches.Count; m++)
            {
                if ((m & 255) == 0) cancel.ThrowIfCancellationRequested();
                var i = matches[m];
                var list = cursor.Read(table.Postings[i], checked((int)(table.Postings[i + 1] - table.Postings[i])));
                var reader = new PostingReader(list);
                while (reader.Next(out var id, out var page))
                {
                    if (id >= first.Length) throw new FolderIndexDamagedException("A posting out of range.");
                    if (first[id] < 0 || page >= count[id]) continue; // a file that is gone
                    var bit = first[id] + page;
                    bits[bit >> 6] |= 1UL << bit;
                }
            }
        }
    }

    private static bool AnyPage(ulong[] bits, int first, int count)
    {
        for (var p = first; p < first + count; p++)
        {
            if ((p & 63) == 0 && first + count - p >= 64)
            {
                if (bits[p >> 6] != 0) return true;
                p += 63;
                continue;
            }
            if ((bits[p >> 6] & (1UL << p)) != 0) return true;
        }
        return false;
    }

    /// <summary>Pages looked at together, on several threads; their results then come out in order.</summary>
    private const int ConfirmRound = 128;

    /// <summary>Threads confirming pages: a search is what the person is waiting for, but the PC has other work too.</summary>
    private static readonly int ConfirmThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 6);

    /// <summary>
    /// Runs Find on each proposed page's text, in order of path and page, a round of pages at a time on several threads. The words of a
    /// phrase being on a page says little about their being side by side, so a phrase's pages go through <see cref="SideBySide"/> first:
    /// a page's words in order are read in a tenth of the time Find takes.
    /// </summary>
    private static IEnumerable<FolderHit> Confirm(Snapshot state, PageMap map, ulong[] bits, string query, FolderSearchOptions options, List<string> terms, CancellationToken cancel)
    {
        var listed = 0;
        var round = new List<(int File, int Page)>(ConfirmRound);
        var results = new FolderHit?[ConfirmRound];
        var readers = new System.Collections.Concurrent.ConcurrentBag<PageReader>();
        var file = 0;
        var parallel = new ParallelOptions { MaxDegreeOfParallelism = ConfirmThreads, CancellationToken = cancel };
        var filter = terms.Count > 1 && terms.All(t => t.Length < IndexTerms.MaxChars) ? terms : null;
        for (var word = 0; word < bits.Length; word++)
        {
            var w = bits[word];
            while (w != 0 || (word == bits.Length - 1 && round.Count > 0))
            {
                if (w != 0)
                {
                    var bit = word * 64 + BitOperations.TrailingZeroCount(w);
                    w &= w - 1;
                    while (file + 1 < map.First.Length && map.First[file + 1] <= bit) file++;
                    var page = bit - map.First[file];
                    if (page >= map.Files[file].Pages) continue; // a file of no pages sharing its number with the next
                    round.Add((file, page));
                    if (round.Count < ConfirmRound && (w != 0 || word < bits.Length - 1)) continue;
                }

                var count = round.Count;
                try
                {
                    Parallel.For(0, count, parallel, () => readers.TryTake(out var r) ? r : new PageReader(state.Store.Handle), (i, _, reader) =>
                    {
                        var (fileAt, pageAt) = round[i];
                        results[i] = Check(reader, map.Files[fileAt], pageAt, query, options, filter);
                        return reader;
                    }, readers.Add);
                }
                catch (AggregateException ex) when (ex.Flatten().InnerExceptions[0] is { } inner)
                {
                    System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(inner); // as a caller would expect it from one thread
                }
                for (var i = 0; i < count; i++)
                {
                    if (results[i] is not { } hit) continue;
                    yield return hit;
                    if (++listed >= options.MaxPages) yield break;
                }
                round.Clear();
            }
        }
    }

    private static FolderHit? Check(PageReader reader, IndexedFile f, int page, string query, FolderSearchOptions options, List<string>? filter)
    {
        var text = reader.Page(f, page);
        if (filter is not null && !SideBySide(text, filter)) return null;
        var hits = PageText.FindIn(text, query, options.MatchCase, options.WholeWord, options.IgnoreAccents);
        if (hits.Count == 0) return null;
        var (start, end) = hits[0];
        var before = Math.Max(0, start - 40);
        return new FolderHit(f.RelativePath, page, hits.Count, PageText.ExcerptOf(text, start, end), (before > 0 ? 1 : 0) + start - before, end - start);
    }

    /// <summary>
    /// Whether a page has a phrase's terms one right after the other: the first the end of a word, the last the start of one, those between whole.
    /// Whatever Find finds has that (they are the same words, folded), so a page without it needs no asking.
    /// </summary>
    internal static bool SideBySide(string text, IReadOnlyList<string> terms)
    {
        // Every count of terms matched so far that ends at the word before this one: a phrase can start again inside itself.
        var ends = new List<int>();
        var next = new List<int>();
        var found = false;
        IndexTerms.Read(PageText.SearchTextOf(text), word =>
        {
            if (found) return;
            next.Clear();
            foreach (var at in ends)
                if (Fits(word, terms, at))
                {
                    if (at + 1 == terms.Count) found = true;
                    else next.Add(at + 1);
                }
            if (word.EndsWith(terms[0], StringComparison.Ordinal)) next.Add(1);
            (ends, next) = (next, ends);
        });
        return found;
    }

    private static bool Fits(ReadOnlySpan<char> word, IReadOnlyList<string> terms, int at) =>
        at == terms.Count - 1 ? word.StartsWith(terms[at], StringComparison.Ordinal) : word.SequenceEqual(terms[at]);

    /// <summary>Reads one page's kept text, holding on to the last file's list of pages.</summary>
    private sealed class PageReader(Microsoft.Win32.SafeHandles.SafeFileHandle file)
    {
        private readonly Cursor _cursor = new(file);
        private int _id = -1;
        private int[] _lengths = [];
        private long _blobs;

        public string Page(IndexedFile f, int page)
        {
            if (f.TextLength == 0) return "";
            if (f.Id != _id) ReadDirectory(f);
            if (page >= _lengths.Length) throw new FolderIndexDamagedException("A page out of range.");
            if (_lengths[page] == 0) return "";
            var at = _blobs;
            for (var i = 0; i < page; i++) at += _lengths[i];
            var packed = _cursor.Read(at, _lengths[page]).ToArray();
            try
            {
                using var zip = new ZLibStream(new MemoryStream(packed), CompressionMode.Decompress);
                using var text = new StreamReader(zip, Encoding.UTF8);
                return text.ReadToEnd();
            }
            catch (InvalidDataException)
            {
                throw new FolderIndexDamagedException("A page's text doesn't read back.");
            }
        }

        private void ReadDirectory(IndexedFile f)
        {
            var head = _cursor.Read(f.TextOffset, (int)Math.Min(f.TextLength, 1 << 20));
            var r = new VarReader(head);
            var pages = r.Int();
            if (pages != f.Pages) throw new FolderIndexDamagedException("A file's pages out of range.");
            var lengths = new int[pages];
            long total = 0;
            for (var i = 0; i < pages; i++)
            {
                lengths[i] = r.Int();
                total += lengths[i];
            }
            var used = f.TextLength - total;
            if (used < 0) throw new FolderIndexDamagedException("A file's text out of range.");
            _lengths = lengths;
            _blobs = f.TextOffset + used;
            _id = f.Id;
        }
    }
}
