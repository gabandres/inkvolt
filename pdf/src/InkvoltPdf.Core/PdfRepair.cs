using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// Makes a document's bytes readable by PDFsharp once, as the document opens (<see cref="Normalize"/>), so every reader
/// (form, comments, bookmarks, stamps, rotations, signing, <see cref="Incremental.Track"/>) and the MuPDF view see the same
/// bytes. MuPDF repairs a damaged file as it opens it and shows its pages; PDFsharp refuses it, which left such a form with
/// no fields, comments or bookmarks and every edit failing.
/// </summary>
public static partial class PdfRepair
{
    public enum Outcome
    {
        /// <summary>PDFsharp reads the file as it is (or nothing here helps it, and readers say what is wrong).</summary>
        AsIs,
        /// <summary>The file without the old copy's bytes left after its last good %%EOF (<see cref="StaleTail"/>).</summary>
        StaleTailCut,
        /// <summary>The file with a cross-reference section rebuilt from the objects found in it (<see cref="Rebuild"/>).</summary>
        Repaired,
    }

    /// <summary>The bytes to open, and how they came from the file's.</summary>
    public sealed record Result(byte[] Data, Outcome Outcome)
    {
        /// <summary>The file was damaged and these bytes are a repaired copy: the person is told, and its signatures aren't checked.</summary>
        public bool Repaired => Outcome == Outcome.Repaired;
    }

    /// <summary>How much of a document PDFsharp reads, best first.</summary>
    private enum Health
    {
        /// <summary>Opened, with its catalog, page tree, and the fields, comments and bookmarks it names.</summary>
        Sound,
        /// <summary>Opened, but its fields, a page's comments or its bookmarks are lost: every one named resolves to no object.</summary>
        PartsLost,
        /// <summary>Opened with no catalog or no page tree (a cross-reference stream without /Size reads as empty).</summary>
        NoDocument,
        /// <summary>Not opened.</summary>
        Unreadable,
    }

    /// <summary>
    /// The bytes every reader of the document uses: the file as it is when PDFsharp reads it soundly (<see cref="Health"/>;
    /// a reference to no object alone, as an editor leaves a deleted one, is no damage), else without a stale tail, else
    /// with a rebuilt cross-reference section, whichever PDFsharp reads better first; never throws. A file none of them
    /// helps is kept as it is, so the readers report the file's own first failure. Not tried for a file PDFsharp refuses for
    /// its password, a stream too large to decode or its shape (<see cref="PdfShapeException"/>): a repair changes none of them,
    /// but cross-reference sections that loop, which the rebuilt one replaces.
    /// </summary>
    public static Result Normalize(byte[] data, string? password)
    {
        if (data.AsSpan(0, Math.Min(data.Length, 1024)).IndexOf("%PDF"u8) < 0) return new Result(data, Outcome.AsIs);
        var (failure, health) = Reads(data, password);
        if (health == Health.Sound) return new Result(data, Outcome.AsIs);
        // Cross-reference sections that loop are what a rebuilt cross-reference repairs (it has no /Prev): every other
        // refused shape is in the objects themselves.
        if (failure is StreamTooLargeException || (failure is PdfShapeException && SectionsEnd(data)) ||
            failure?.Message.Contains("password", StringComparison.OrdinalIgnoreCase) == true)
            return new Result(data, Outcome.AsIs);
        bool Better(byte[] candidate) => Reads(candidate, password).Health < health;
        try
        {
            if (StaleTail.Cut(data) is { } cut && Better(cut)) return new Result(cut, Outcome.StaleTailCut);
            if (Rebuild(data) is { } rebuilt && Better(rebuilt)) return new Result(rebuilt, Outcome.Repaired);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // A file too odd to cut or rebuild is read as it is: its readers say what is wrong with it.
        }
        return new Result(data, Outcome.AsIs);
    }

    /// <summary>What PDFsharp threw opening <paramref name="data"/> (null when it opened it), and how much of it it reads.</summary>
    private static (Exception? Failure, Health Health) Reads(byte[] data, string? password)
    {
        try
        {
            using var doc = PdfObj.Read(data, password, PdfDocumentOpenMode.Import);
            if (Resolved(doc.Internals.Catalog.Elements["/Pages"]) is not PdfDictionary) return (null, Health.NoDocument);
            _ = doc.Pages.Count; // the page tree, as every reader walks it (PageCount alone doesn't)
            return (null, PartsLost(doc) ? Health.PartsLost : Health.Sound);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return (ex, Health.Unreadable);
        }
    }

    /// <summary>
    /// Whether the document's fields, a page's comments or its bookmarks can't be read: the entry naming them, or every
    /// item in a non-empty list of them, refers to no object. One lost item among readable ones is not this.
    /// </summary>
    private static bool PartsLost(PdfDocument doc)
    {
        var catalog = doc.Internals.Catalog;
        if (Lost(catalog.Elements["/AcroForm"]) || Lost(catalog.Elements["/Outlines"])) return true;
        if (Resolved(catalog.Elements["/AcroForm"]) is PdfDictionary form && (Lost(form.Elements["/Fields"]) || AllLost(form.Elements["/Fields"])))
            return true;
        if (Resolved(catalog.Elements["/Outlines"]) is PdfDictionary outlines && Lost(outlines.Elements["/First"])) return true;
        foreach (var page in doc.Pages)
            if (Lost(page.Elements["/Annots"]) || AllLost(page.Elements["/Annots"]))
                return true;
        return false;

        static bool Lost(PdfItem? item) => item is PdfReference { Value: null };
        static bool AllLost(PdfItem? item) => Resolved(item) is PdfArray { Elements.Count: > 0 } a && a.Elements.All(Lost);
    }

    private static PdfItem? Resolved(PdfItem? item) => item is PdfReference r ? r.Value : item;

    // ---- Rebuilding the cross-reference section ----

    /// <summary>The most objects a rebuilt section lists, and the most object-stream entries read: more than any real file.</summary>
    private const int MaxObjects = 4 << 20;

    /// <summary>The most bytes the object streams decode to, each and in all.</summary>
    private const int MaxObjStmBytes = 64 << 20;

    /// <summary>The most of a dictionary read (token by token) before it is taken as broken.</summary>
    private const int MaxDictChars = 64 * 1024;

    /// <summary>The most trailers read, from the end of the file.</summary>
    private const int MaxTrailers = 16;

    /// <summary>Where an object is: at an offset in the file, or the index'th object of object stream Stream.</summary>
    private readonly record struct Entry(long Order, bool Compressed, long Offset, int Gen, int Stream, int Index);

    /// <summary>A trailer's (or cross-reference stream's) /Root and /Info, its /Encrypt as written, and its /ID, where it is in the file.</summary>
    private sealed record Trailer(long At, (int Num, int Gen)? Root, (int Num, int Gen)? Info, string? Encrypt, string? Id);

    private sealed record ObjStm(int Num, long Order, int Start, int End, RawDict Dict);

    /// <summary>
    /// <paramref name="data"/> with a cross-reference stream appended that lists every object found in it, as MuPDF's repair
    /// finds them: the file read front to back for "n g obj" headers, each object's dictionary read token by token, a
    /// stream's content (only after its dictionary's "&gt;&gt;", the keyword "stream" and an end of line) skipped by its
    /// /Length (followed when indirect) or up to "endstream"; the objects held in object streams; the last occurrence of
    /// each number winning. The trailer's /Root, /Info, /Encrypt and /ID come from the last trailer (or cross-reference
    /// stream) whose /Root is among them, else /Root is the last catalog found; /Encrypt and /ID from any trailer naming one.
    /// Null when there is no catalog to point at, or the file is encrypted (an encryption dictionary among its objects) and
    /// no trailer says how: a rebuild without /Encrypt would have PDFsharp read the ciphertext as text. Linear in the
    /// file's size, its total work capped (<see cref="Work"/>).
    /// </summary>
    internal static byte[]? Rebuild(byte[] data)
    {
        var work = new Work(4L * data.Length + 2L * MaxObjStmBytes + (1 << 20));
        var entries = new Dictionary<int, Entry>();
        var trailers = new List<Trailer>();
        var catalogs = new List<(long Order, int Num, int Gen)>();
        var objStms = new List<ObjStm>();
        var encrypted = false;
        Headers? headers = null;
        long? Resolve(RawDict dict, string key, int near) =>
            dict.Int(key) ?? (dict.Ref(key) is { } r ? (headers ??= new Headers(data)).IntOf(data, r, near) : null);
        var objKw = new Next(data, "obj"u8.ToArray());
        var endstreamKw = new Next(data, "endstream"u8.ToArray());

        var pos = 0;
        while (objKw.From(pos) is var i and >= 0)
        {
            var body = i + 3;
            if (Incremental.ObjectHeaderAt(data, i) is not ({ } num, var gen, var start))
            {
                pos = body;
                continue;
            }
            entries[num] = new Entry(start, false, start, gen, 0, 0);
            if (entries.Count > MaxObjects) return null;
            pos = body;
            var dict = ReadDict(data, SkipWhite(data, body, data.Length), work);
            if (work.Spent) return null;
            if (dict is null) continue; // no dictionary, or a broken one: the next header begins another object
            pos = dict.End;
            var content = StreamContentAfter(data, dict.End);
            if (content < 0)
            {
                if (dict.Name("/Type") == "Catalog") catalogs.Add((start, num, gen));
                if (dict.Name("/Filter") is not null && (dict.Has("/O") && dict.Has("/U") || dict.Has("/Recipients"))) encrypted = true;
                continue;
            }
            var length = Resolve(dict, "/Length", content);
            var contentEnd = EndOfStream(data, content, length, endstreamKw);
            if (dict.Name("/Type") == "ObjStm" && contentEnd >= 0) objStms.Add(new ObjStm(num, start, content, contentEnd, dict));
            if (dict.Name("/Type") == "XRef") trailers.Add(TrailerOf(start, dict));
            pos = contentEnd >= 0 ? contentEnd : content;
        }

        // Objects in object streams: each where its stream is in the file.
        var decoded = 0L;
        var pairs = 0L;
        foreach (var stm in objStms)
        {
            if (entries.GetValueOrDefault(stm.Num) is not { Compressed: false } own || own.Order != stm.Order) continue; // a later object took its number
            if (Decode(data, stm.Start, stm.End, stm.Dict, MaxObjStmBytes - decoded) is not { } content) continue;
            decoded += content.Length;
            work.Spend(content.Length);
            if (Resolve(stm.Dict, "/N", stm.End) is not { } n || Resolve(stm.Dict, "/First", stm.End) is not { } first || first > content.Length) continue;
            n = Math.Min(n, first / 4 + 1); // a pair takes at least 4 bytes ("1 0 ")
            var catalogNames = CatalogNames(content, (int)first);
            var (lastAt, lastCatalog) = (-1L, false);
            var p = 0;
            for (var k = 0; k < n; k++)
            {
                if (ReadInt(content, ref p, (int)first) is not { } objNum || ReadInt(content, ref p, (int)first) is not { } offset) break;
                if (++pairs > MaxObjects) return null;
                if (objNum is <= 0 or > Incremental.MaxObjectNumber) continue;
                if (entries.TryGetValue((int)objNum, out var e) && e.Order > stm.Order) continue;
                entries[(int)objNum] = new Entry(stm.Order, true, 0, 0, stm.Num, k);
                if (entries.Count > MaxObjects) return null;
                // A catalog, read only where a "/Catalog" lies within reach of the object's start.
                var at = first + offset;
                if (catalogNames.Count == 0 || at >= content.Length) continue;
                if (at != lastAt)
                {
                    var c = catalogNames.BinarySearch((int)at);
                    c = c < 0 ? ~c : c;
                    lastCatalog = c < catalogNames.Count && catalogNames[c] - at < MaxDictChars &&
                                  ReadDict(content, SkipWhite(content, (int)at, content.Length), work)?.Name("/Type") == "Catalog";
                    lastAt = at;
                    if (work.Spent) return null;
                }
                if (lastCatalog) catalogs.Add((stm.Order, (int)objNum, 0));
            }
        }

        // Classic trailers, the last few.
        var from = data.Length;
        for (var t = 0; t < MaxTrailers && from > 0 && data.AsSpan(0, from).LastIndexOf("trailer"u8) is var at and >= 0; t++, from = at)
        {
            if (ReadDict(data, SkipWhite(data, at + 7, data.Length), work) is { } dict) trailers.Add(TrailerOf(at, dict));
            if (work.Spent) return null;
        }

        bool Known((int Num, int Gen)? r) => r is { } x && entries.ContainsKey(x.Num);
        var trailer = trailers.Where(t => Known(t.Root)).MaxBy(t => t.At);
        var root = trailer?.Root ?? (catalogs.Count > 0 ? (catalogs.MaxBy(c => c.Order).Num, catalogs.MaxBy(c => c.Order).Gen) : null);
        if (root is null || !Known(root)) return null;
        // Encrypted objects stay encrypted in every revision: any trailer naming /Encrypt says how to read them.
        var secured = trailer?.Encrypt is not null ? trailer : trailers.Where(t => t.Encrypt is not null).MaxBy(t => t.At);
        var encrypt = secured?.Encrypt;
        var id = secured?.Id ?? trailer?.Id;
        if (encrypt is null ? encrypted : id is null || (RefOf(encrypt) is { } e2 && !entries.ContainsKey(e2.Num))) return null;
        return Write(data, entries, root.Value, Known(trailer?.Info) ? trailer!.Info : null, encrypt, id);
    }

    /// <summary>Where "/Catalog" names appear in an object stream's objects (after <paramref name="first"/>), in order.</summary>
    private static List<int> CatalogNames(byte[] content, int first)
    {
        var at = new List<int>();
        for (var p = first; p < content.Length && content.AsSpan(p).IndexOf("/Catalog"u8) is var i and >= 0; p += i + 8)
            if (TokenEnd(content, p + i + 1, content.Length) == p + i + 8) at.Add(p + i);
        return at;
    }

    /// <summary>The file with the new cross-reference stream (object number one past the largest) and its startxref appended.</summary>
    private static byte[] Write(byte[] data, Dictionary<int, Entry> entries, (int Num, int Gen) root, (int Num, int Gen)? info, string? encrypt, string? id)
    {
        var self = entries.Keys.Max() + 1;
        var gap = data.Length > 0 && data[^1] is (byte)'\n' or (byte)'\r' ? "" : "\n";
        var at = data.Length + gap.Length;
        entries[self] = new Entry(at, false, at, 0, 0, 0);
        var nums = entries.Keys.Order().ToList();
        var rows = new byte[(nums.Count + 1) * 9];
        BinaryPrimitives.WriteInt32BigEndian(rows.AsSpan(5), 65535); // object 0: the head of the free list
        var index = new StringBuilder("0 1");
        var r = 9;
        for (var k = 0; k < nums.Count;)
        {
            var run = 1;
            while (k + run < nums.Count && nums[k + run] == nums[k] + run) run++;
            index.Append($" {nums[k]} {run}");
            for (var j = k; j < k + run; j++, r += 9)
            {
                var e = entries[nums[j]];
                rows[r] = (byte)(e.Compressed ? 2 : 1);
                BinaryPrimitives.WriteInt32BigEndian(rows.AsSpan(r + 1), e.Compressed ? e.Stream : (int)e.Offset);
                BinaryPrimitives.WriteInt32BigEndian(rows.AsSpan(r + 5), e.Compressed ? e.Index : e.Gen);
            }
            k += run;
        }
        var keys = new StringBuilder($"/Type /XRef /Size {self + 1} /Index [{index}] /W [1 4 4] /Root {root.Num} {root.Gen} R");
        if (info is { } i) keys.Append($" /Info {i.Num} {i.Gen} R");
        if (encrypt is not null) keys.Append($" /Encrypt {encrypt}");
        if (id is not null) keys.Append($" /ID {id}");
        using var ms = new MemoryStream(data.Length + rows.Length + 512);
        ms.Write(data);
        ms.Write(Encoding.Latin1.GetBytes($"{gap}{self} 0 obj\n<< {keys} /Length {rows.Length} >>\nstream\n"));
        ms.Write(rows);
        ms.Write(Encoding.Latin1.GetBytes($"\nendstream\nendobj\nstartxref\n{at}\n%%EOF\n"));
        return ms.ToArray();
    }

    /// <summary>
    /// Where a stream's content ends: at <paramref name="length"/> when "endstream" follows there, else at the next
    /// "endstream" (found once for the whole scan, <see cref="Next"/>); -1 when neither (the file ends inside the stream).
    /// </summary>
    private static int EndOfStream(byte[] data, int content, long? length, Next endstreamKw)
    {
        if (length is { } n && n >= 0 && content + n <= data.Length)
        {
            var end = content + (int)n;
            var p = end;
            while (p < data.Length && p - end < 4 && Incremental.IsWhite(data[p])) p++;
            if (data.AsSpan(p).StartsWith("endstream"u8)) return end;
        }
        return endstreamKw.From(content);
    }

    /// <summary>An object stream's content: as it is, or Flate-decoded (no predictor); null for any other filter or a damaged stream.</summary>
    private static byte[]? Decode(byte[] data, int start, int end, RawDict dict, long budget)
    {
        if (end < start || budget <= 0) return null;
        var raw = data.AsSpan(start, end - start);
        var filter = dict.Raw("/Filter")?.Trim().TrimStart('[').TrimEnd(']').Trim();
        if (filter is null) return raw.Length <= budget ? raw.ToArray() : null;
        if (filter != "/FlateDecode" || dict.Has("/DecodeParms")) return null;
        try
        {
            using var z = new ZLibStream(new MemoryStream(data, start, end - start, writable: false), CompressionMode.Decompress);
            using var output = new MemoryStream();
            var buffer = new byte[81920];
            int read;
            while ((read = z.Read(buffer)) > 0)
            {
                if (output.Length + read > Math.Min(budget, MaxObjStmBytes)) return null;
                output.Write(buffer, 0, read);
            }
            return output.ToArray();
        }
        catch (InvalidDataException)
        {
            return null;
        }
    }

    private static Trailer TrailerOf(long at, RawDict dict) =>
        new(at, dict.Ref("/Root"), dict.Ref("/Info"), dict.Raw("/Encrypt"), dict.Raw("/ID") is { } ids ? Incremental.FileId("/ID " + ids) : null);

    /// <summary>
    /// The next occurrence of a keyword at or after a position, remembered until the position passes it, so scanning a
    /// file front to back reads it once per keyword however often it asks.
    /// </summary>
    private sealed class Next(byte[] data, byte[] keyword)
    {
        private int _at = -2; // not looked for yet
        private int _from;

        public int From(int from)
        {
            if (_at == -1 && from >= _from) return -1; // none from where it last looked, so none from further on
            if (_at >= from && from >= _from) return _at;
            var i = from >= data.Length ? -1 : data.AsSpan(from).IndexOf(keyword);
            (_at, _from) = (i < 0 ? -1 : from + i, from);
            return _at;
        }
    }
}
