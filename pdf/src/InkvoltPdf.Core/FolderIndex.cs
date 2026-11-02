using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPdf.Core;

/// <summary>What became of a file when it was read for the index.</summary>
public enum IndexedState : byte
{
    /// <summary>Its text is in the index (a page that couldn't be read counts in <see cref="IndexedFile.FailedPages"/>).</summary>
    Indexed,

    /// <summary>Read, and no page has text: a scan nobody has recognized yet.</summary>
    NoText,

    /// <summary>Needs a password to open. Never asked, never in the index.</summary>
    Password,

    /// <summary>Not a PDF that can be opened.</summary>
    Damaged,

    /// <summary>Over the size or page limit, or more text than a file may keep; what was read before the limit is searchable.</summary>
    TooBig,

    /// <summary>Took too long and was given up; what was read before that is searchable.</summary>
    TooSlow,

    /// <summary>Brought the reading process down, twice; what was read before that is searchable.</summary>
    Crashed,
}

/// <summary>One file in a folder index.</summary>
/// <param name="RelativePath">From the indexed folder.</param>
/// <param name="WriteTicks">Its last-write time in UTC when read: with the size, how a change is noticed.</param>
/// <param name="FailedPages">Pages that couldn't be read.</param>
public sealed record IndexedFile(int Id, string RelativePath, long Size, long WriteTicks, IndexedState State, int Pages, int FailedPages, long TextOffset, long TextLength);

/// <summary>The index file can't be used (a damaged block found while searching): it is built again.</summary>
public sealed class FolderIndexDamagedException(string message) : IOException(message);

/// <summary>Another Inkvolt PDF has this index open.</summary>
public sealed class FolderIndexBusyException(string message) : IOException(message);

/// <summary>
/// The search index of one folder, in one local file. Words (<see cref="IndexTerms"/>) lead to the pages they are on, and each
/// page's text is kept compressed, so a search gets its results and their context without opening a single PDF: only an
/// <see cref="IndexWorkers">index worker</see> ever parses one. <see cref="Search"/> reads a snapshot and takes no lock, so
/// it runs while the indexer commits.
/// <para>
/// The file is written only at its end: a header, then transactions, each a block of page texts, a block of postings
/// (term to pages), the sorted terms, what files came and went, and last a footer with checksums. A transaction counts once
/// its footer is on disk, written after everything before it was flushed, so a crash leaves the last commit readable and
/// the torn end is cut off at the next open. <see cref="Compact"/> writes the live contents to a new file under the next
/// generation number and renames it into place; the highest complete generation wins. An index can always be built again from the
/// PDFs, so a file that fails its checks is thrown away, never trusted.
/// </para>
/// </summary>
public sealed partial class FolderIndex : IDisposable
{
    private const int FormatVersion = 1;
    private const string Extension = ".idx";
    private static readonly byte[] Magic = "INKVIDX\n"u8.ToArray();
    private const int HeaderSize = 32;
    private const int TxHeaderSize = 16;
    private const int FooterSize = 32;
    private const uint TxMagic = 0x58544B49;     // "IKTX"
    private const uint FooterMagic = 0x54464B49; // "IKFT"

    private readonly string _basePath;
    private readonly FileStream _lock;
    private readonly Lock _writeGate = new();
    private readonly Lock _stateGate = new();
    private Snapshot _state;
    private long _length;          // committed bytes in the current file; what is past it is thrown away (under _writeGate)
    private int _generation;       // under _writeGate
    private bool _disposed;

    private FolderIndex(string basePath, FileStream fileLock, Snapshot state, long length, int generation)
    {
        _basePath = basePath;
        _lock = fileLock;
        _state = state;
        _length = length;
        _generation = generation;
    }

    /// <summary>The files in the index now, by relative path.</summary>
    public IReadOnlyDictionary<string, IndexedFile> Files => _state.ByPath;

    /// <summary>Commits since the last compaction that brought their own words: each is searched on its own.</summary>
    public int Segments => _state.Segments.Length;

    /// <summary>For the benchmark: how many terms the lists hold, repeats between lists included.</summary>
    internal long TermsForBench => _state.Segments.Sum(s => (long)s.Info.TermCount);

    /// <summary>Text of files since changed or removed is still in the file (until <see cref="Compact"/>), though no search shows it.</summary>
    public bool HasDeadText => _state.HasDead;

    /// <summary>The index file's size on disk.</summary>
    public long FileBytes => Volatile.Read(ref _length);

    /// <summary>Opens the index at <paramref name="basePath"/> (a path without extension), or a new empty one; recovers from a crash.</summary>
    /// <exception cref="FolderIndexBusyException">Another Inkvolt PDF has it open.</exception>
    public static FolderIndex Open(string basePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(basePath)!);
        FileStream fileLock;
        try
        {
            fileLock = new FileStream(basePath + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
        }
        catch (IOException ex) when (ex is not FileNotFoundException and not DirectoryNotFoundException)
        {
            throw new FolderIndexBusyException("Another Inkvolt PDF has this folder's index open.");
        }
        try
        {
            var dir = Path.GetDirectoryName(basePath)!;
            var name = Path.GetFileName(basePath);
            foreach (var tmp in Directory.EnumerateFiles(dir, name + ".*.tmp")) TryDelete(tmp); // a compaction that never finished
            var generations = Generations(dir, name);
            var stamp = IndexTerms.Stamp;
            foreach (var generation in generations)
            {
                var path = PathOf(basePath, generation);
                if (TryRecover(path, stamp) is not { } found)
                {
                    TryDelete(path);
                    continue;
                }
                foreach (var older in generations.Where(g => g < generation)) TryDelete(PathOf(basePath, older));
                return new FolderIndex(basePath, fileLock, found.State, found.Length, generation);
            }
            var first = generations.Count > 0 ? generations[0] + 1 : 1;
            var store = CreateStore(PathOf(basePath, first), stamp);
            return new FolderIndex(basePath, fileLock, new Snapshot(store, EmptyFiles, [], 0, false), HeaderSize, first);
        }
        catch
        {
            fileLock.Dispose();
            throw;
        }
    }

    /// <summary>The name a folder's index goes by in <paramref name="directory"/>: a hash, so any path fits and no folder name is on show.</summary>
    public static string BasePathFor(string directory, string folder)
    {
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)).ToUpperInvariant();
        var hash = System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(full));
        return Path.Combine(directory, Convert.ToHexStringLower(hash, 0, 16));
    }

    /// <summary>Starts a batch of changes for one <see cref="Commit"/>.</summary>
    public IndexBatch NewBatch() => new(_state.NextId);

    /// <summary>
    /// Makes the batch part of the index, all of it or none: when this returns it is on disk and searches see it. A failure
    /// (the disk is full) leaves the index as it was, and the next commit overwrites what was written.
    /// </summary>
    public void Commit(IndexBatch batch)
    {
        lock (_writeGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var state = _state;
            var store = state.Store;
            RandomAccess.SetLength(store.Handle, _length);
            var start = _length;
            var bodyStart = start + TxHeaderSize;
            var (terms, dict) = batch.SortedTerms();
            var textBytes = batch.TextBytes;
            var postingsStart = bodyStart + textBytes;
            long postingBytes = 0;
            foreach (var t in terms) postingBytes += t.List.Length;
            var dictStart = postingsStart + postingBytes;
            var meta = batch.WriteMeta(bodyStart, terms.Count > 0 ? new SegmentInfo(dictStart, dict.Length, Crc32.Of(dict), terms.Count, postingsStart, postingBytes) : null);
            var metaStart = dictStart + dict.Length;

            using var writer = new FileWriter(store.Handle, start);
            writer.Write(TxHeader(meta.Length + dict.Length + postingBytes + textBytes));
            batch.WriteTexts(writer);
            foreach (var t in terms) writer.Write(t.List.Span);
            writer.Write(dict);
            writer.Write(meta);
            writer.Flush();
            RandomAccess.FlushToDisk(store.Handle);
            writer.Write(Footer(metaStart - start, meta.Length, Crc32.Of(meta)));
            writer.Flush();
            RandomAccess.FlushToDisk(store.Handle);

            var next = Apply(state, meta);
            _length = writer.Position;
            lock (_stateGate) _state = next;
        }
    }

    /// <summary>
    /// Writes what is live to a new file and swaps it in, one list of terms and no text of files that are gone. Searches
    /// under way finish on the old file, which is deleted then.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired; the index stays as it was.</exception>
    public void Compact(CancellationToken cancel = default)
    {
        lock (_writeGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var state = _state;
            var generation = _generation + 1;
            var final = PathOf(_basePath, generation);
            var tmp = final + ".tmp";
            try
            {
                using (var handle = File.OpenHandle(tmp, FileMode.Create, FileAccess.ReadWrite, FileShare.None, FileOptions.None))
                {
                    RandomAccess.Write(handle, Header(IndexTerms.Stamp), 0);
                    using var writer = new FileWriter(handle, HeaderSize);
                    writer.Write(new byte[TxHeaderSize]); // filled in below
                    var bodyStart = writer.Position;

                    // The texts, as they are.
                    var ordered = state.ByPath.Values.OrderBy(f => f.Id).ToList();
                    var moved = new List<IndexedFile>(ordered.Count);
                    var reader = new Cursor(state.Store.Handle);
                    foreach (var file in ordered)
                    {
                        cancel.ThrowIfCancellationRequested();
                        var at = writer.Position;
                        var left = file.TextLength;
                        var from = file.TextOffset;
                        while (left > 0)
                        {
                            var chunk = (int)Math.Min(left, 1 << 20);
                            writer.Write(reader.Read(from, chunk));
                            from += chunk;
                            left -= chunk;
                        }
                        moved.Add(file with { TextOffset = at });
                    }

                    // The terms of every list merged, in order, without the files that are gone.
                    var postingsStart = writer.Position;
                    var (dict, count) = MergeTerms(state, writer, cancel);
                    var postingBytes = writer.Position - postingsStart;
                    var dictStart = writer.Position;
                    writer.Write(dict);
                    var segment = count > 0 ? new SegmentInfo(dictStart, dict.Length, Crc32.Of(dict), count, postingsStart, postingBytes) : null;
                    var meta = IndexBatch.WriteMeta(state.NextId, [], moved, segment);
                    var metaStart = writer.Position;
                    writer.Write(meta);
                    writer.Flush();
                    RandomAccess.Write(handle, TxHeader(metaStart + meta.Length - bodyStart), HeaderSize);
                    writer.Write(Footer(metaStart - HeaderSize, meta.Length, Crc32.Of(meta)));
                    writer.Flush();
                    RandomAccess.FlushToDisk(handle);
                }
                cancel.ThrowIfCancellationRequested();
                File.Move(tmp, final);
            }
            catch
            {
                TryDelete(tmp);
                throw;
            }

            var found = TryRecover(final, IndexTerms.Stamp) ?? throw new FolderIndexDamagedException("The compacted index doesn't read back.");
            _generation = generation;
            _length = found.Length;
            lock (_stateGate) _state = found.State;
            state.Store.Retire(); // deleted when the last search on it ends
        }
    }

    /// <summary>Empties the index, as a new file: what the old one held is gone with it once searches on it end.</summary>
    public void Clear()
    {
        lock (_writeGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var state = _state;
            var generation = _generation + 1;
            var store = CreateStore(PathOf(_basePath, generation), IndexTerms.Stamp);
            _generation = generation;
            _length = HeaderSize;
            lock (_stateGate) _state = new Snapshot(store, EmptyFiles, [], state.NextId, false);
            state.Store.Retire();
        }
    }

    /// <summary>Forgets the terms kept in memory for searching; the next search reads them again.</summary>
    public void ForgetCaches()
    {
        foreach (var segment in _state.Segments) segment.Forget();
    }

    public void Dispose()
    {
        lock (_writeGate)
        {
            if (_disposed) return;
            _disposed = true;
            _state.Store.Release();
            _lock.Dispose();
        }
    }

    /// <summary>Closes the index and deletes its file.</summary>
    public void DisposeAndDelete()
    {
        lock (_writeGate)
        {
            if (_disposed) return;
            _disposed = true;
            _state.Store.Retire();
            _lock.Dispose();
        }
    }

    // ---- Opening ----

    private static readonly Dictionary<string, IndexedFile> EmptyFiles = new(StringComparer.OrdinalIgnoreCase);

    private static string PathOf(string basePath, int generation) => $"{basePath}.{generation}{Extension}";

    /// <summary>The generations there are, highest first.</summary>
    private static List<int> Generations(string dir, string name)
    {
        var list = new List<int>();
        foreach (var path in Directory.EnumerateFiles(dir, $"{name}.*{Extension}"))
        {
            var middle = Path.GetFileNameWithoutExtension(path);
            if (middle.Length > name.Length + 1 && int.TryParse(middle.AsSpan(name.Length + 1), out var generation) && generation > 0) list.Add(generation);
        }
        list.Sort((a, b) => b.CompareTo(a));
        return list;
    }

    private static Store CreateStore(string path, long stamp)
    {
        var handle = File.OpenHandle(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read | FileShare.Delete, FileOptions.RandomAccess);
        RandomAccess.Write(handle, Header(stamp), 0);
        RandomAccess.FlushToDisk(handle);
        return new Store(path, handle);
    }

    private static byte[] Header(long stamp)
    {
        var header = new byte[HeaderSize];
        Magic.CopyTo(header, 0);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(8), FormatVersion);
        BinaryPrimitives.WriteInt64LittleEndian(header.AsSpan(12), stamp);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(HeaderSize - 4), Crc32.Of(header.AsSpan(0, HeaderSize - 4)));
        return header;
    }

    private static byte[] TxHeader(long bodyLength)
    {
        var header = new byte[TxHeaderSize];
        BinaryPrimitives.WriteUInt32LittleEndian(header, TxMagic);
        BinaryPrimitives.WriteInt64LittleEndian(header.AsSpan(8), bodyLength);
        return header;
    }

    /// <param name="metaOffset">Where the file list starts, from the start of the transaction's header.</param>
    private static byte[] Footer(long metaOffset, long metaLength, uint metaCrc)
    {
        var footer = new byte[FooterSize];
        BinaryPrimitives.WriteUInt32LittleEndian(footer, FooterMagic);
        BinaryPrimitives.WriteUInt32LittleEndian(footer.AsSpan(4), metaCrc);
        BinaryPrimitives.WriteInt64LittleEndian(footer.AsSpan(8), metaOffset);
        BinaryPrimitives.WriteInt64LittleEndian(footer.AsSpan(16), metaLength);
        BinaryPrimitives.WriteUInt32LittleEndian(footer.AsSpan(FooterSize - 4), Crc32.Of(footer.AsSpan(0, FooterSize - 4)));
        return footer;
    }

    /// <summary>Reads a file's transactions to the last whole one and cuts off the rest. Null: this file can't be used.</summary>
    private static (Snapshot State, long Length)? TryRecover(string path, long stamp)
    {
        SafeFileHandle? handle = null;
        try
        {
            handle = File.OpenHandle(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read | FileShare.Delete, FileOptions.RandomAccess);
            var size = RandomAccess.GetLength(handle);
            Span<byte> header = stackalloc byte[HeaderSize];
            if (size < HeaderSize || RandomAccess.Read(handle, header, 0) != HeaderSize || !header.SequenceEqual(Header(stamp)))
            {
                handle.Dispose();
                return null;
            }
            var store = new Store(path, handle);
            var state = new Snapshot(store, EmptyFiles, [], 0, false);
            long position = HeaderSize;
            Span<byte> txHeader = stackalloc byte[TxHeaderSize];
            Span<byte> footer = stackalloc byte[FooterSize];
            while (position + TxHeaderSize + FooterSize <= size)
            {
                if (RandomAccess.Read(handle, txHeader, position) != TxHeaderSize || BinaryPrimitives.ReadUInt32LittleEndian(txHeader) != TxMagic) break;
                var body = BinaryPrimitives.ReadInt64LittleEndian(txHeader[8..]);
                if (body < 0 || body > size - position - TxHeaderSize - FooterSize) break;
                var footerAt = position + TxHeaderSize + body;
                if (RandomAccess.Read(handle, footer, footerAt) != FooterSize) break;
                if (BinaryPrimitives.ReadUInt32LittleEndian(footer) != FooterMagic) break;
                if (Crc32.Of(footer[..(FooterSize - 4)]) != BinaryPrimitives.ReadUInt32LittleEndian(footer[(FooterSize - 4)..])) break;
                var metaOffset = BinaryPrimitives.ReadInt64LittleEndian(footer[8..]);
                var metaLength = BinaryPrimitives.ReadInt64LittleEndian(footer[16..]);
                if (metaLength < 0 || metaLength > int.MaxValue || metaOffset < TxHeaderSize || metaOffset + metaLength != TxHeaderSize + body) break;
                var meta = new byte[metaLength];
                if (RandomAccess.Read(handle, meta, position + metaOffset) != metaLength) break;
                if (Crc32.Of(meta) != BinaryPrimitives.ReadUInt32LittleEndian(footer[4..])) break;
                try
                {
                    state = Apply(state, meta);
                }
                catch (FolderIndexDamagedException)
                {
                    break;
                }
                position = footerAt + FooterSize;
            }
            if (position < size)
            {
                RandomAccess.SetLength(handle, position);
                RandomAccess.FlushToDisk(handle);
            }
            return (state, position);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            handle?.Dispose();
            return null;
        }
    }

    /// <summary>The state after one transaction's file list. Everything in it is checked: a file's contents are data.</summary>
    private static Snapshot Apply(Snapshot state, ReadOnlySpan<byte> meta)
    {
        var r = new VarReader(meta);
        var nextId = r.Int();
        var removed = r.Int();
        var byPath = new Dictionary<string, IndexedFile>(state.ByPath, StringComparer.OrdinalIgnoreCase);
        var dead = state.HasDead;
        var byId = removed > 0 ? state.ByPath.Values.ToDictionary(f => f.Id) : null;
        for (var i = 0; i < removed; i++)
        {
            if (byId!.TryGetValue(r.Int(), out var gone)) byPath.Remove(gone.RelativePath);
            dead = true;
        }
        var added = r.Int();
        for (var i = 0; i < added; i++)
        {
            var id = r.Int();
            var path = r.String();
            var size = r.Long();
            var ticks = r.Long();
            var fileState = (IndexedState)r.Int();
            var pages = r.Int();
            var failed = r.Int();
            var offset = r.Long();
            var length = r.Long();
            if (id >= nextId || path.Length == 0 || pages < 0 || failed < 0 || offset < 0 || length < 0 || fileState > IndexedState.Crashed || offset > long.MaxValue - length)
                throw new FolderIndexDamagedException("A file entry out of range.");
            byPath[path] = new IndexedFile(id, path, size, ticks, fileState, pages, failed, offset, length);
        }
        var segments = state.Segments;
        if (r.Int() != 0)
        {
            var info = new SegmentInfo(r.Long(), r.Long(), (uint)r.Long(), r.Int(), r.Long(), r.Long());
            segments = [.. segments, new Segment(info)];
        }
        if (!r.AtEnd) throw new FolderIndexDamagedException("More than a file list.");
        return new Snapshot(state.Store, byPath, segments, nextId, dead);
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    // ---- What a search reads ----

    /// <summary>Takes the current state for a search: its file stays open until <see cref="Store.Release"/>.</summary>
    private Snapshot Acquire()
    {
        lock (_stateGate)
        {
            _state.Store.AddRef();
            return _state;
        }
    }

    /// <summary>One generation's open file; closed when the index and the last search are done with it.</summary>
    private sealed class Store(string path, SafeFileHandle handle)
    {
        private int _refs = 1;
        private bool _retired;

        public SafeFileHandle Handle { get; } = handle;

        public void AddRef() => Interlocked.Increment(ref _refs);

        public void Release()
        {
            if (Interlocked.Decrement(ref _refs) != 0) return;
            Handle.Dispose();
            if (Volatile.Read(ref _retired)) TryDelete(path);
        }

        /// <summary>The index has moved on: this file goes as soon as nothing reads it.</summary>
        public void Retire()
        {
            Volatile.Write(ref _retired, true);
            Release();
        }
    }

    /// <summary>One moment of the index. Never changes; a commit makes a new one.</summary>
    private sealed class Snapshot(Store store, Dictionary<string, IndexedFile> byPath, Segment[] segments, int nextId, bool hasDead)
    {
        public Store Store { get; } = store;
        public Dictionary<string, IndexedFile> ByPath { get; } = byPath;
        public Segment[] Segments { get; } = segments;
        public int NextId { get; } = nextId;
        public bool HasDead { get; } = hasDead;
        private PageMap? _pages;

        public PageMap Pages => _pages ??= new PageMap(this);
    }

    /// <summary>
    /// Every page of the files in a snapshot numbered in order of path, so a set of pages is a set of bits and a search's
    /// results come out sorted.
    /// </summary>
    private sealed class PageMap
    {
        public IndexedFile[] Files { get; }
        public int[] First { get; }           // the first page's number, by position in Files
        public int[] FirstById { get; }       // the same by id; -1: no longer there
        public int[] CountById { get; }
        public int Total { get; }

        public PageMap(Snapshot state)
        {
            Files = [.. state.ByPath.Values.OrderBy(f => f.RelativePath, StringComparer.OrdinalIgnoreCase)];
            First = new int[Files.Length];
            FirstById = new int[state.NextId];
            CountById = new int[state.NextId];
            Array.Fill(FirstById, -1);
            var total = 0L;
            for (var i = 0; i < Files.Length; i++)
            {
                var f = Files[i];
                First[i] = (int)total;
                FirstById[f.Id] = (int)total;
                CountById[f.Id] = f.Pages;
                total = Math.Min(total + f.Pages, int.MaxValue / 2);
            }
            Total = (int)total;
        }
    }

    /// <summary>Where one commit's list of terms and postings are.</summary>
    internal sealed record SegmentInfo(long DictOffset, long DictLength, uint DictCrc, int TermCount, long PostingsOffset, long PostingsLength);

    /// <summary>One commit's terms, read from the file when first searched and kept until <see cref="Forget"/>.</summary>
    private sealed class Segment(SegmentInfo info)
    {
        private TermTable? _table;

        public SegmentInfo Info { get; } = info;

        public TermTable Table(SafeFileHandle file) => Volatile.Read(ref _table) ?? (_table = TermTable.Read(file, Info));

        public void Forget() => Volatile.Write(ref _table, null);
    }

    /// <summary>Sorted terms as one block of UTF-8 ("term\n" each), where finding a word inside any of them is one fast scan, and where each one's postings start.</summary>
    private sealed class TermTable
    {
        public required byte[] Text { get; init; }
        public required int[] Starts { get; init; }           // Count + 1, the last at the end of the text
        public required long[] Postings { get; init; }        // Count + 1, offsets in the file

        public int Count => Starts.Length - 1;

        public ReadOnlySpan<byte> Term(int i) => Text.AsSpan(Starts[i], Starts[i + 1] - Starts[i] - 1);

        public static TermTable Read(SafeFileHandle file, SegmentInfo info)
        {
            if (info.DictLength is < 0 or > int.MaxValue) throw new FolderIndexDamagedException("A list of terms out of range.");
            var block = new byte[info.DictLength];
            if (RandomAccess.Read(file, block, info.DictOffset) != block.Length || Crc32.Of(block) != info.DictCrc) throw new FolderIndexDamagedException("A list of terms doesn't read back.");
            var r = new VarReader(block);
            var textLength = r.Int();
            var text = r.Bytes(textLength).ToArray();
            var starts = new int[info.TermCount + 1];
            var postings = new long[info.TermCount + 1];
            var at = 0;
            for (var i = 0; i < info.TermCount; i++)
            {
                starts[i] = at;
                var end = text.AsSpan(at).IndexOf((byte)'\n');
                if (end < 0) throw new FolderIndexDamagedException("A list of terms cut short.");
                at += end + 1;
            }
            starts[info.TermCount] = at;
            if (at != text.Length) throw new FolderIndexDamagedException("A list of terms too long.");
            var offset = info.PostingsOffset;
            for (var i = 0; i < info.TermCount; i++)
            {
                postings[i] = offset;
                var length = r.Long();
                if (length is < 0 or > int.MaxValue) throw new FolderIndexDamagedException("Postings out of range.");
                offset += length;
            }
            postings[info.TermCount] = offset;
            if (offset != info.PostingsOffset + info.PostingsLength) throw new FolderIndexDamagedException("Postings out of range.");
            return new TermTable { Text = text, Starts = starts, Postings = postings };
        }

        /// <summary>The numbers of the terms with <paramref name="word"/> anywhere in them, as Find finds a word inside a longer one.</summary>
        public List<int> Containing(ReadOnlySpan<byte> word)
        {
            var found = new List<int>();
            var text = Text.AsSpan();
            var at = 0;
            while (at < text.Length)
            {
                var rel = text[at..].IndexOf(word);
                if (rel < 0) break;
                var hit = at + rel;
                var i = Array.BinarySearch(Starts, hit);
                if (i < 0) i = ~i - 1;
                found.Add(i);
                at = Starts[i + 1];
            }
            return found;
        }
    }

    /// <summary>The block of a term table: its text, then each term's postings length.</summary>
    internal static byte[] BuildDictionary(ReadOnlySpan<byte> text, IReadOnlyList<long> lengths)
    {
        var w = new VarWriter(text.Length + lengths.Count * 2 + 8);
        w.Int(text.Length);
        w.Bytes(text);
        foreach (var length in lengths) w.Long(length);
        return w.ToArray();
    }

    /// <summary>Merges every segment's terms into <paramref name="writer"/>'s postings; returns the dictionary and the terms kept.</summary>
    private static (byte[] Dict, int Count) MergeTerms(Snapshot state, FileWriter writer, CancellationToken cancel)
    {
        var map = state.Pages;
        var tables = state.Segments.Select(s => s.Table(state.Store.Handle)).ToArray();
        var cursors = tables.Select(_ => new Cursor(state.Store.Handle)).ToArray();
        var at = new int[tables.Length];
        var text = new MemoryStream();
        var lengths = new List<long>();
        var output = new VarWriter(1 << 16);
        while (true)
        {
            // The smallest term not done yet; a handful of tables, so a look at each is fine.
            var least = -1;
            for (var t = 0; t < tables.Length; t++)
                if (at[t] < tables[t].Count && (least < 0 || tables[t].Term(at[t]).SequenceCompareTo(tables[least].Term(at[least])) < 0)) least = t;
            if (least < 0) break;
            if ((lengths.Count & 1023) == 0) cancel.ThrowIfCancellationRequested();
            var term = tables[least].Term(at[least]).ToArray();

            output.Clear();
            int lastId = 0, lastPage = -1;
            var first = true;
            for (var t = 0; t < tables.Length; t++) // oldest first: ids only grow from one commit to the next
            {
                if (at[t] >= tables[t].Count || !tables[t].Term(at[t]).SequenceEqual(term)) continue;
                var i = at[t]++;
                var list = cursors[t].Read(tables[t].Postings[i], checked((int)(tables[t].Postings[i + 1] - tables[t].Postings[i])));
                var reader = new PostingReader(list);
                while (reader.Next(out var id, out var page))
                {
                    if (id >= map.FirstById.Length || map.FirstById[id] < 0) continue;
                    if (first || id != lastId) output.Long(((long)(id - (first ? 0 : lastId)) << 1) | 1).Int(page);
                    else output.Long((long)(page - lastPage) << 1);
                    first = false;
                    lastId = id;
                    lastPage = page;
                }
            }
            if (output.Length == 0) continue; // only in files that are gone
            writer.Write(output.Span);
            text.Write(term);
            text.WriteByte((byte)'\n');
            lengths.Add(output.Length);
        }
        return (BuildDictionary(text.GetBuffer().AsSpan(0, (int)text.Length), lengths), lengths.Count);
    }

    // ---- Small tools ----

    /// <summary>Reads through a file in order with one buffer (and back, which reads again).</summary>
    private sealed class Cursor(SafeFileHandle file)
    {
        private byte[] _buffer = new byte[1 << 20];
        private long _start = long.MinValue / 2;
        private int _length;

        public ReadOnlySpan<byte> Read(long offset, int count)
        {
            if (offset >= _start && offset + count <= _start + _length) return _buffer.AsSpan((int)(offset - _start), count);
            if (count > _buffer.Length) _buffer = new byte[count];
            var read = 0;
            while (read < _buffer.Length)
            {
                var n = RandomAccess.Read(file, _buffer.AsSpan(read), offset + read);
                if (n == 0) break;
                read += n;
            }
            if (read < count) throw new FolderIndexDamagedException("The index file ends too soon.");
            _start = offset;
            _length = read;
            return _buffer.AsSpan(0, count);
        }
    }

    /// <summary>Writes at a position in a file through a buffer.</summary>
    internal sealed class FileWriter(SafeFileHandle file, long position) : IDisposable
    {
        private readonly byte[] _buffer = new byte[1 << 20];
        private long _written = position;
        private int _used;

        public long Position => _written + _used;

        public void Write(ReadOnlySpan<byte> bytes)
        {
            if (bytes.Length > _buffer.Length - _used)
            {
                Flush();
                if (bytes.Length >= _buffer.Length)
                {
                    RandomAccess.Write(file, bytes, _written);
                    _written += bytes.Length;
                    return;
                }
            }
            bytes.CopyTo(_buffer.AsSpan(_used));
            _used += bytes.Length;
        }

        public void Flush()
        {
            if (_used == 0) return;
            RandomAccess.Write(file, _buffer.AsSpan(0, _used), _written);
            _written += _used;
            _used = 0;
        }

        public void Dispose() { }
    }

    /// <summary>The pages a term is on: (file id, page) in order. A new file is its id's difference from the last, shifted, with the low bit set, then its page; another page of the same file is the difference, shifted.</summary>
    internal ref struct PostingReader(ReadOnlySpan<byte> list)
    {
        private VarReader _r = new(list);
        private int _id;
        private int _page;

        public bool Next(out int id, out int page)
        {
            if (_r.AtEnd)
            {
                id = page = 0;
                return false;
            }
            var v = _r.Long();
            if ((v & 1) != 0)
            {
                _id = InRange(_id + (v >> 1));
                _page = _r.Int();
            }
            else
            {
                _page = InRange(_page + (v >> 1));
            }
            id = _id;
            page = _page;
            return true;
        }

        /// <summary>No checksum covers postings: what they say is checked here, so damage reads as damage.</summary>
        private static int InRange(long value) => value is >= 0 and <= int.MaxValue ? (int)value : throw new FolderIndexDamagedException("A posting out of range.");
    }

    /// <summary>Little-endian base-128 numbers: the file's small numbers in few bytes. What it reads comes from a file, so it is checked.</summary>
    internal ref struct VarReader(ReadOnlySpan<byte> data)
    {
        private readonly ReadOnlySpan<byte> _data = data;
        private int _at;

        public readonly bool AtEnd => _at >= _data.Length;

        public long Long()
        {
            ulong value = 0;
            for (var shift = 0; shift < 64; shift += 7)
            {
                if (_at >= _data.Length) throw new FolderIndexDamagedException("A number cut short.");
                var b = _data[_at++];
                value |= (ulong)(b & 0x7F) << shift;
                if (b < 0x80) return (long)value;
            }
            throw new FolderIndexDamagedException("A number too long.");
        }

        public int Int()
        {
            var v = Long();
            if (v is < 0 or > int.MaxValue) throw new FolderIndexDamagedException("A number out of range.");
            return (int)v;
        }

        public ReadOnlySpan<byte> Bytes(int count)
        {
            if (count < 0 || count > _data.Length - _at) throw new FolderIndexDamagedException("A block cut short.");
            var bytes = _data.Slice(_at, count);
            _at += count;
            return bytes;
        }

        public string String() => Encoding.UTF8.GetString(Bytes(Int()));
    }

    /// <summary>Writes what <see cref="VarReader"/> reads.</summary>
    internal sealed class VarWriter(int capacity = 256)
    {
        private byte[] _data = new byte[capacity];

        public int Length { get; private set; }

        public ReadOnlySpan<byte> Span => _data.AsSpan(0, Length);

        public ReadOnlyMemory<byte> Memory => _data.AsMemory(0, Length);

        public void Clear() => Length = 0;

        public VarWriter Long(long value)
        {
            Grow(10);
            var v = (ulong)value;
            while (v >= 0x80)
            {
                _data[Length++] = (byte)(v | 0x80);
                v >>= 7;
            }
            _data[Length++] = (byte)v;
            return this;
        }

        public VarWriter Int(int value) => Long(value);

        public void Bytes(ReadOnlySpan<byte> bytes)
        {
            Grow(bytes.Length);
            bytes.CopyTo(_data.AsSpan(Length));
            Length += bytes.Length;
        }

        public void String(string value)
        {
            var bytes = Encoding.UTF8.GetBytes(value);
            Int(bytes.Length);
            Bytes(bytes);
        }

        public byte[] ToArray() => Span.ToArray();

        private void Grow(int more)
        {
            if (Length + more <= _data.Length) return;
            Array.Resize(ref _data, Math.Max(_data.Length * 2, Length + more));
        }
    }

    /// <summary>CRC-32 (the zip polynomial), for the blocks that decide what a file holds.</summary>
    internal static class Crc32
    {
        private static readonly uint[] Table = MakeTable();

        private static uint[] MakeTable()
        {
            var table = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                var c = i;
                for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
                table[i] = c;
            }
            return table;
        }

        public static uint Of(ReadOnlySpan<byte> data)
        {
            var c = 0xFFFFFFFF;
            foreach (var b in data) c = Table[(byte)(c ^ b)] ^ (c >> 8);
            return ~c;
        }
    }

    /// <summary>The text of one file for the index: how many pages, each page's packed length, then each page packed.</summary>
    internal static byte[] PackPages(IReadOnlyList<string?> pages)
    {
        var lengths = new VarWriter(pages.Count + 8);
        lengths.Int(pages.Count);
        var packed = new byte[pages.Count][];
        using var buffer = new MemoryStream();
        for (var i = 0; i < pages.Count; i++)
        {
            if (string.IsNullOrEmpty(pages[i]))
            {
                packed[i] = [];
                lengths.Int(0);
                continue;
            }
            buffer.SetLength(0);
            using (var zip = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) zip.Write(Encoding.UTF8.GetBytes(pages[i]!));
            packed[i] = buffer.ToArray();
            lengths.Int(packed[i].Length);
        }
        var all = new VarWriter(lengths.Length + packed.Sum(p => p.Length));
        all.Bytes(lengths.Span);
        foreach (var p in packed) all.Bytes(p);
        return all.ToArray();
    }
}

/// <summary>
/// Changes on their way into a <see cref="FolderIndex"/>, all kept in memory until <see cref="FolderIndex.Commit"/>: files
/// to add with their words filed, files to take out. Not safe to share between threads: the indexer holds a lock.
/// </summary>
public sealed class IndexBatch
{
    private readonly int _firstId;
    private readonly Dictionary<string, PostingList> _terms = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PostingList>.AlternateLookup<ReadOnlySpan<char>> _lookup;
    private readonly MemoryStream _texts = new();
    private readonly List<IndexedFile> _added = [];
    private readonly List<IndexedFile> _removed = [];
    private long _postingBytes;

    internal IndexBatch(int firstId)
    {
        _firstId = firstId;
        _lookup = _terms.GetAlternateLookup<ReadOnlySpan<char>>();
    }

    /// <summary>Bytes this batch holds on to (and will write): the indexer commits when it has enough.</summary>
    public long Bytes => _texts.Length + _postingBytes;

    public int TermCount => _terms.Count;

    public int Added => _added.Count;

    public bool IsEmpty => _added.Count == 0 && _removed.Count == 0;

    internal long TextBytes => _texts.Length;

    /// <summary>Takes <paramref name="file"/> out when this commits.</summary>
    public void Remove(IndexedFile file) => _removed.Add(file);

    /// <summary>Adds a file. <paramref name="packed"/> comes from <see cref="FolderIndex.PackPages"/>; <paramref name="pages"/> by page number, null for no text.</summary>
    public void Add(string relativePath, long size, long writeTicks, IndexedState state, int pageCount, int failedPages, byte[] packed, IReadOnlyList<string?> pages)
    {
        var id = _firstId + _added.Count;
        _added.Add(new IndexedFile(id, relativePath, size, writeTicks, state, pageCount, failedPages, _texts.Length, packed.Length));
        _texts.Write(packed);
        for (var page = 0; page < pages.Count; page++)
        {
            if (string.IsNullOrEmpty(pages[page])) continue;
            var p = page;
            IndexTerms.Read(PageText.SearchTextOf(pages[page]!), term =>
            {
                if (!_lookup.TryGetValue(term, out var list))
                {
                    list = new PostingList();
                    _terms[term.ToString()] = list;
                }
                _postingBytes += list.Add(id, p);
            });
        }
    }

    /// <summary>Terms in the order of their UTF-8 bytes, with the block that lists them.</summary>
    internal (List<(byte[] Term, FolderIndex.VarWriter List)> Terms, byte[] Dict) SortedTerms()
    {
        var sorted = new List<(byte[] Term, FolderIndex.VarWriter List)>(_terms.Count);
        foreach (var (term, list) in _terms) sorted.Add((Encoding.UTF8.GetBytes(term), list.Bytes));
        sorted.Sort((a, b) => a.Term.AsSpan().SequenceCompareTo(b.Term));
        var text = new MemoryStream(sorted.Count * 8);
        var lengths = new long[sorted.Count];
        for (var i = 0; i < sorted.Count; i++)
        {
            text.Write(sorted[i].Term);
            text.WriteByte((byte)'\n');
            lengths[i] = sorted[i].List.Length;
        }
        return (sorted, FolderIndex.BuildDictionary(text.GetBuffer().AsSpan(0, (int)text.Length), lengths));
    }

    internal void WriteTexts(FolderIndex.FileWriter writer) => writer.Write(_texts.GetBuffer().AsSpan(0, (int)_texts.Length));

    /// <summary>The file list this batch's transaction ends with, with offsets now known.</summary>
    internal byte[] WriteMeta(long textStart, FolderIndex.SegmentInfo? segment) =>
        WriteMeta(_firstId + _added.Count, _removed.Select(f => f.Id), _added.Select(f => f with { TextOffset = f.TextOffset + textStart }), segment);

    internal static byte[] WriteMeta(int nextId, IEnumerable<int> removed, IEnumerable<IndexedFile> added, FolderIndex.SegmentInfo? segment)
    {
        var w = new FolderIndex.VarWriter(4096);
        w.Int(nextId);
        var gone = removed.ToList();
        w.Int(gone.Count);
        foreach (var id in gone) w.Int(id);
        var files = added.ToList();
        w.Int(files.Count);
        foreach (var f in files)
        {
            w.Int(f.Id);
            w.String(f.RelativePath);
            w.Long(f.Size);
            w.Long(f.WriteTicks);
            w.Int((int)f.State);
            w.Int(f.Pages);
            w.Int(f.FailedPages);
            w.Long(f.TextOffset);
            w.Long(f.TextLength);
        }
        if (segment is null) w.Int(0);
        else
        {
            w.Int(1);
            w.Long(segment.DictOffset);
            w.Long(segment.DictLength);
            w.Long(segment.DictCrc);
            w.Int(segment.TermCount);
            w.Long(segment.PostingsOffset);
            w.Long(segment.PostingsLength);
        }
        return w.ToArray();
    }

    private sealed class PostingList
    {
        public FolderIndex.VarWriter Bytes { get; } = new(8);
        private int _id = -1;
        private int _page = -1;

        /// <summary>Files the page once, however often the word is on it. Returns the bytes added.</summary>
        public int Add(int id, int page)
        {
            if (id == _id && page == _page) return 0;
            var before = Bytes.Length;
            if (id != _id) Bytes.Long(((long)(id - Math.Max(_id, 0)) << 1) | 1).Int(page);
            else Bytes.Long((long)(page - _page) << 1);
            _id = id;
            _page = page;
            return Bytes.Length - before;
        }
    }
}
