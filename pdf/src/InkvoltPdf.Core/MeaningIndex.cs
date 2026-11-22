using System.Buffers.Binary;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>A piece of a page's text to embed: its file (as the folder index has it), page and piece number, and its text.</summary>
public sealed record MeaningPiece(string RelativePath, long Size, long WriteTicks, int Page, int Piece, string Text);

/// <summary>A page close in meaning to a query: its best piece's closeness (cosine, about −1 to 1).</summary>
public sealed record MeaningHit(string RelativePath, int Page, int Piece, double Score);

/// <summary>What a meaning index lacks against its folder index: the pieces to embed, files to forget, and pieces past the size limit.</summary>
public sealed record MeaningPending(IReadOnlyList<MeaningPiece> Pieces, IReadOnlyList<string> Gone, int LeftOut)
{
    public bool IsEmpty => Pieces.Count == 0 && Gone.Count == 0;

    /// <summary>"report.pdf: pages 1–3" for each file whose text would be sent, for the send window.</summary>
    public IReadOnlyList<string> Listing => [.. Pieces.GroupBy(p => p.RelativePath)
        .Select(g => Loc.Format(PdfStrings.FolderAsk_SentLine, g.Key, AiText.PagesText(g.Select(p => p.Page))))];
}

/// <summary>
/// Search by meaning (roadmap 4.21, Pro): the embeddings of a folder's pages, one file beside its <see cref="FolderIndex"/>
/// (<c>.meaning</c>), made by the user's own endpoint and only once the user turns it on. Each page's text, as the folder
/// index keeps it, is cut into pieces (<see cref="MaxPiecesPerPage"/> of <see cref="MaxPieceChars"/> at most); each piece's
/// vector is kept unit length in 8 bits a number with its scale. Bounded (<see cref="MaxEntries"/>, <see cref="MaxBytes"/>),
/// versioned (<see cref="Version"/>), and thrown away when the model or the endpoint changes, or when the file doesn't
/// read back whole (a checksum at its end). Files are known by path, size and time, as the folder index knows them: a
/// changed file's pieces are embedded again.
/// </summary>
public sealed class MeaningIndex
{
    public const int Version = 1;
    public const int MaxPieceChars = 1000;
    public const int MaxPiecesPerPage = 3;
    public const int MaxEntries = 50_000;
    public const long MaxBytes = 256L << 20;
    private static readonly byte[] Magic = "INKVOLT-MEANING"u8.ToArray();

    private readonly List<Entry> _entries = [];

    /// <summary>About what the entries take in the file (<see cref="CostOf"/> each).</summary>
    private long _bytes;

    /// <summary>The most the entries may take: <see cref="MaxBytes"/>, smaller in tests.</summary>
    internal long ByteLimit { get; private init; } = MaxBytes;

    /// <summary>What one entry takes in the file at most: its vector, its path, and its numbers (at most 36 bytes, some to spare).</summary>
    private static long CostOf(string path, int dimensions) => dimensions + Encoding.UTF8.GetByteCount(path) + 48;

    /// <summary>Why <see cref="Discarded"/> may say the file wasn't used without it being wrong: it couldn't be read just now (kept, tried again).</summary>
    public const string UnreadableReason = "unreadable";

    /// <summary>The file couldn't be read just now (busy, locked): it isn't wrong, so it is neither used nor deleted.</summary>
    public bool Unreadable => Discarded == UnreadableReason;

    private sealed record Entry(string RelativePath, long Size, long WriteTicks, int Page, int Piece, float Scale, sbyte[] Vector);

    private MeaningIndex(string model, string endpoint)
    {
        Model = model;
        Endpoint = endpoint;
    }

    /// <summary>The embedding model the vectors came from.</summary>
    public string Model { get; }

    /// <summary>The endpoint's identity (<see cref="AiEndpoint.Key"/>) they came from.</summary>
    public string Endpoint { get; }

    /// <summary>How long each vector is (0 while empty).</summary>
    public int Dimensions { get; private set; }

    public int Count => _entries.Count;

    /// <summary>Why the file on disk wasn't used when it was there (another model, another version, damaged); null otherwise.</summary>
    public string? Discarded { get; private set; }

    /// <summary>The file beside a folder index's base path.</summary>
    public static string PathFor(string indexBasePath) => indexBasePath + ".meaning";

    /// <summary>An empty index for <paramref name="model"/> at <paramref name="endpoint"/>.</summary>
    public static MeaningIndex Empty(string model, string endpoint) => new(model, endpoint);

    internal static MeaningIndex Empty(string model, string endpoint, long byteLimit) => new(model, endpoint) { ByteLimit = byteLimit };

    /// <summary>
    /// Reads the index at <paramref name="path"/> when it was made by <paramref name="model"/> at <paramref name="endpoint"/>
    /// in this <see cref="Version"/> and reads back whole; else an empty one (<see cref="Discarded"/> says why).
    /// </summary>
    public static MeaningIndex Load(string path, string model, string endpoint) => Load(path, model, endpoint, MaxBytes);

    internal static MeaningIndex Load(string path, string model, string endpoint, long byteLimit)
    {
        var index = new MeaningIndex(model, endpoint) { ByteLimit = byteLimit };
        byte[] data;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) return index;
            if (info.Length > byteLimit + (1 << 20))
            {
                index.Discarded = "too large";
                return index;
            }
            data = File.ReadAllBytes(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            index.Discarded = UnreadableReason;
            return index;
        }
        index.Discarded = index.Read(data);
        if (index.Discarded is not null)
        {
            index._entries.Clear();
            index.Dimensions = 0;
            index._bytes = 0;
        }
        return index;
    }

    private string? Read(byte[] data)
    {
        if (data.Length < Magic.Length + 8 || !data.AsSpan(0, Magic.Length).SequenceEqual(Magic)) return "not a meaning index";
        var body = data.AsSpan(0, data.Length - 4);
        if (BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(data.Length - 4)) != FolderIndex.Crc32.Of(body)) return "damaged";
        try
        {
            var r = new FolderIndex.VarReader(body[Magic.Length..]);
            if (r.Int() != Version) return "another version";
            if (r.String() != Model || r.String() != Endpoint) return "another model";
            var dims = r.Int();
            var count = r.Int();
            if (dims < 0 || dims > AiEmbeddings.MaxDimensions || count < 0 || count > MaxEntries || (dims == 0) != (count == 0)) return "damaged";
            Dimensions = dims;
            for (var i = 0; i < count; i++)
            {
                var path = r.String();
                var size = r.Long();
                var ticks = r.Long();
                var page = r.Int();
                var piece = r.Int();
                var scale = BitConverter.Int32BitsToSingle(r.Int());
                if (page < 0 || piece < 0 || piece >= MaxPiecesPerPage || !float.IsFinite(scale) || scale < 0) return "damaged";
                var vector = new sbyte[dims];
                r.Bytes(dims).CopyTo(System.Runtime.InteropServices.MemoryMarshal.AsBytes(vector.AsSpan()));
                _entries.Add(new Entry(path, size, ticks, page, piece, scale, vector));
                _bytes += CostOf(path, dims);
            }
            return r.AtEnd ? null : "damaged";
        }
        catch (Exception ex) when (ex is ArgumentException or IndexOutOfRangeException or OverflowException or FormatException or FolderIndexDamagedException)
        {
            return "damaged";
        }
    }

    /// <summary>Writes the index to <paramref name="path"/> whole or not at all (a new file moved over the old).</summary>
    public void Save(string path)
    {
        var w = new FolderIndex.VarWriter(1 << 16);
        w.Bytes(Magic);
        w.Int(Version);
        w.String(Model);
        w.String(Endpoint);
        w.Int(Dimensions);
        w.Int(_entries.Count);
        foreach (var e in _entries)
        {
            w.String(e.RelativePath);
            w.Long(e.Size);
            w.Long(e.WriteTicks);
            w.Int(e.Page);
            w.Int(e.Piece);
            w.Int(BitConverter.SingleToInt32Bits(e.Scale));
            w.Bytes(System.Runtime.InteropServices.MemoryMarshal.AsBytes(e.Vector.AsSpan()));
        }
        var body = w.Span;
        var crc = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(crc, FolderIndex.Crc32.Of(body));
        var temp = path + ".new";
        using (var f = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            f.Write(body);
            f.Write(crc);
            f.Flush(flushToDisk: true);
        }
        File.Move(temp, path, overwrite: true);
    }

    /// <summary>
    /// The pieces of a file's pages, in order: each page's text cut at a paragraph, line, sentence or word into pieces of
    /// <see cref="MaxPieceChars"/> at most, the first <see cref="MaxPiecesPerPage"/> of them; pages without text have none.
    /// </summary>
    public static IEnumerable<MeaningPiece> PiecesOf(IndexedFile file, IReadOnlyList<string> pageTexts)
    {
        for (var p = 0; p < pageTexts.Count; p++)
        {
            var text = AiText.Clean(pageTexts[p]);
            if (text.Length == 0) continue;
            var n = 0;
            foreach (var piece in Cut(text))
            {
                yield return new MeaningPiece(file.RelativePath, file.Size, file.WriteTicks, p, n, piece);
                if (++n >= MaxPiecesPerPage) break;
            }
        }
    }

    /// <summary>Piece <paramref name="piece"/> of a page's text as <see cref="PiecesOf"/> cuts it ("" past its last).</summary>
    public static string PieceText(string pageText, int piece) =>
        Cut(AiText.Clean(pageText)).Skip(piece).FirstOrDefault() ?? "";

    private static IEnumerable<string> Cut(string text)
    {
        while (text.Length > MaxPieceChars)
        {
            var cut = -1;
            foreach (var sep in new[] { "\n\n", "\n", ". ", " " })
            {
                cut = text.LastIndexOf(sep, MaxPieceChars - 1, MaxPieceChars / 2, StringComparison.Ordinal);
                if (cut > 0)
                {
                    cut += sep.Length;
                    break;
                }
            }
            if (cut <= 0) cut = char.IsHighSurrogate(text[MaxPieceChars - 1]) ? MaxPieceChars - 1 : MaxPieceChars;
            yield return text[..cut].TrimEnd();
            text = text[cut..].TrimStart();
        }
        if (text.Length > 0) yield return text;
    }

    /// <summary>
    /// What this index lacks against <paramref name="folder"/>: the pieces of the files new or changed since they were
    /// embedded (their text read from the folder index), in path order up to the size limit, and the files gone or changed.
    /// </summary>
    /// <exception cref="FolderIndexDamagedException">A page's text doesn't read back.</exception>
    public MeaningPending Pending(FolderIndex folder, CancellationToken cancel = default)
    {
        var files = folder.Files;
        var have = new Dictionary<string, (long Size, long Ticks)>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in _entries) have.TryAdd(e.RelativePath, (e.Size, e.WriteTicks));
        var gone = have.Where(h => !files.TryGetValue(h.Key, out var f) || f.Size != h.Value.Size || f.WriteTicks != h.Value.Ticks)
            .Select(h => h.Key).Order(StringComparer.OrdinalIgnoreCase).ToList();
        var goneSet = gone.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var keptEntries = _entries.Where(e => !goneSet.Contains(e.RelativePath)).ToList();
        var count = keptEntries.Count;
        var bytes = keptEntries.Sum(e => CostOf(e.RelativePath, Dimensions));
        var pieces = new List<MeaningPiece>();
        var leftOut = 0;
        foreach (var f in files.Values.OrderBy(f => f.RelativePath, StringComparer.OrdinalIgnoreCase))
        {
            cancel.ThrowIfCancellationRequested();
            if (f.State == IndexedState.Damaged || f.Pages == 0 || f.TextLength == 0) continue;
            if (have.TryGetValue(f.RelativePath, out var h) && h.Size == f.Size && h.Ticks == f.WriteTicks) continue;
            if (count >= MaxEntries || (Dimensions > 0 && bytes + CostOf(f.RelativePath, Dimensions) > ByteLimit))
            {
                leftOut += f.Pages; // full: a page's pieces counted as one, an estimate of what isn't searched by meaning
                continue;
            }
            var texts = folder.PageTexts([.. Enumerable.Range(0, f.Pages).Select(p => (f.RelativePath, p))], cancel);
            var mine = PiecesOf(f, texts).ToList();
            var cost = Dimensions > 0 ? mine.Count * CostOf(f.RelativePath, Dimensions) : 0;
            // A file goes whole or not at all: one cut short would be kept as if embedded, and never sent again.
            if (count + mine.Count > MaxEntries || bytes + cost > ByteLimit)
            {
                leftOut += mine.Count;
                continue;
            }
            pieces.AddRange(mine);
            count += mine.Count;
            bytes += cost;
        }
        return new MeaningPending(pieces, gone, leftOut);
    }

    /// <summary>Forgets every piece of <paramref name="paths"/>.</summary>
    public void Forget(IEnumerable<string> paths)
    {
        var set = paths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        _entries.RemoveAll(e => set.Contains(e.RelativePath));
        if (_entries.Count == 0) Dimensions = 0;
        _bytes = _entries.Sum(e => CostOf(e.RelativePath, Dimensions));
    }

    /// <summary>
    /// Adds embedded pieces (their vectors in the same order) while they fit: <see cref="MaxEntries"/>, and the size limit
    /// once the vectors' length is known. Returns how many were added, from the first.
    /// </summary>
    /// <exception cref="AiException">A vector's length differs from the index's (the model changed its output).</exception>
    public int Add(IReadOnlyList<MeaningPiece> pieces, IReadOnlyList<float[]> vectors)
    {
        if (pieces.Count != vectors.Count) throw new ArgumentException("A vector for each piece.", nameof(vectors));
        var added = 0;
        for (var i = 0; i < pieces.Count && _entries.Count < MaxEntries; i++)
        {
            var v = vectors[i];
            if (Dimensions == 0) Dimensions = v.Length;
            if (v.Length != Dimensions) throw new AiException(PdfStrings.Embed_LengthChanged);
            var p = pieces[i];
            var cost = CostOf(p.RelativePath, Dimensions);
            if (_bytes + cost > ByteLimit) break;
            var (scale, q) = Quantize(v);
            _entries.Add(new Entry(p.RelativePath, p.Size, p.WriteTicks, p.Page, p.Piece, scale, q));
            _bytes += cost;
            added++;
        }
        if (_entries.Count == 0) Dimensions = 0;
        return added;
    }

    /// <summary>A vector made unit length, then in 8 bits a number: the largest number is ±127, <c>scale</c> brings them back.</summary>
    internal static (float Scale, sbyte[] Vector) Quantize(float[] v)
    {
        var unit = Normalized(v);
        var max = unit.Max(x => Math.Abs(x));
        var scale = max == 0 ? 0 : max / 127f;
        var q = new sbyte[unit.Length];
        if (scale > 0)
            for (var i = 0; i < unit.Length; i++) q[i] = (sbyte)Math.Clamp(Math.Round(unit[i] / scale), -127, 127);
        return (scale, q);
    }

    private static float[] Normalized(float[] v)
    {
        double sum = 0;
        foreach (var x in v) sum += (double)x * x;
        var length = Math.Sqrt(sum);
        return length == 0 ? new float[v.Length] : [.. v.Select(x => (float)(x / length))];
    }

    /// <summary>
    /// The pages closest in meaning to <paramref name="query"/>'s vector, best first, each page once (its best piece), at
    /// most <paramref name="count"/>. A query of another length than the index's finds nothing.
    /// </summary>
    public IReadOnlyList<MeaningHit> Nearest(float[] query, int count)
    {
        if (query.Length != Dimensions || Dimensions == 0 || count <= 0) return [];
        var q = Normalized(query);
        var best = new Dictionary<(string, int), MeaningHit>();
        foreach (var e in _entries)
        {
            double dot = 0;
            var v = e.Vector;
            for (var i = 0; i < v.Length; i++) dot += q[i] * v[i];
            var score = dot * e.Scale;
            var key = (e.RelativePath, e.Page);
            if (!best.TryGetValue(key, out var had) || had.Score < score) best[key] = new MeaningHit(e.RelativePath, e.Page, e.Piece, score);
        }
        return [.. best.Values.OrderByDescending(h => h.Score).ThenBy(h => h.RelativePath, StringComparer.OrdinalIgnoreCase).ThenBy(h => h.Page).Take(count)];
    }

    /// <summary>
    /// Embeds <paramref name="pending"/>'s pieces a batch at a time through <paramref name="embed"/> (forgetting its gone
    /// files first), saving to <paramref name="path"/> every few batches and at the end, so a stop keeps what was done.
    /// </summary>
    /// <param name="progress">Pieces done so far.</param>
    /// <returns>Pieces left out because the index is full (their files whole: they are said, and not sent again while it stays full).</returns>
    public async Task<int> UpdateAsync(MeaningPending pending, Func<IReadOnlyList<string>, CancellationToken, Task<float[][]>> embed, string path,
        IProgress<int>? progress = null, CancellationToken cancel = default)
    {
        Forget(pending.Gone);
        // A changed file's old pieces go too, before its new ones come.
        Forget(pending.Pieces.Select(p => p.RelativePath).Distinct(StringComparer.OrdinalIgnoreCase));
        var done = 0;
        var unsaved = 0;
        try
        {
            for (var at = 0; at < pending.Pieces.Count; at += AiEmbeddings.BatchSize)
            {
                cancel.ThrowIfCancellationRequested();
                var batch = pending.Pieces.Skip(at).Take(AiEmbeddings.BatchSize).ToList();
                var vectors = await embed([.. batch.Select(p => p.Text)], cancel);
                if (vectors.Length != batch.Count) throw new AiException(PdfStrings.Embed_NotEmbeddings);
                var added = Add(batch, vectors);
                done += added;
                progress?.Report(done);
                if (added < batch.Count) break; // full (a first answer's length can make it so): the rest is left out
                if (++unsaved >= 16)
                {
                    Save(path);
                    unsaved = 0;
                }
            }
        }
        finally
        {
            // A file half embedded is forgotten again, so the next update embeds it whole.
            var partial = pending.Pieces.Skip(done).Select(p => p.RelativePath).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (partial.Count > 0) Forget(partial);
            Save(path);
        }
        var stored = _entries.Select(e => (e.RelativePath.ToUpperInvariant(), e.Page, e.Piece)).ToHashSet();
        return pending.Pieces.Count(p => !stored.Contains((p.RelativePath.ToUpperInvariant(), p.Page, p.Piece)));
    }
}
