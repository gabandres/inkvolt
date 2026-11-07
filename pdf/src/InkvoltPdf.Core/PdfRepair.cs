using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
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
public static class PdfRepair
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

    /// <summary>
    /// The bytes every reader of the document uses, tried in order: the file as it is; without a stale tail; with a rebuilt
    /// cross-reference section. The first PDFsharp reads wins. A file none of them makes readable is kept as it is, so the
    /// readers report the file's own first failure. Not for a file PDFsharp refuses for its password or a stream too large
    /// to decode: a repair changes neither.
    /// </summary>
    public static Result Normalize(byte[] data, string? password)
    {
        if (data.AsSpan(0, Math.Min(data.Length, 1024)).IndexOf("%PDF"u8) < 0) return new Result(data, Outcome.AsIs);
        var (failure, missing) = Reads(data, password);
        if (failure is null && missing == 0) return new Result(data, Outcome.AsIs);
        if (failure is StreamTooLargeException || failure?.Message.Contains("password", StringComparison.OrdinalIgnoreCase) == true)
            return new Result(data, Outcome.AsIs);
        // A candidate wins when PDFsharp reads it and finds more of the objects it refers to (a file PDFsharp opens can
        // still have lost them: a cross-reference stream without /Size reads as empty).
        bool Better(byte[] candidate) => Reads(candidate, password) is (null, var m) && (failure is not null || m < missing);
        if (StaleTail.Cut(data) is { } cut && Better(cut)) return new Result(cut, Outcome.StaleTailCut);
        if (Rebuild(data) is { } rebuilt && Better(rebuilt)) return new Result(rebuilt, Outcome.Repaired);
        return new Result(data, Outcome.AsIs);
    }

    /// <summary>What PDFsharp threw opening <paramref name="data"/> (null when it opened it), and how many references it found pointing at no object.</summary>
    private static (Exception? Failure, int Missing) Reads(byte[] data, string? password)
    {
        try
        {
            using var doc = PdfObj.Read(data, password, PdfDocumentOpenMode.Import);
            _ = doc.Pages.Count; // the page tree, as every reader walks it (PageCount alone doesn't)
            return (null, Missing(doc));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return (ex, 0);
        }
    }

    /// <summary>References reachable from the catalog that resolve to no object (an empty catalog counts as one).</summary>
    private static int Missing(PdfDocument doc)
    {
        var missing = doc.Internals.Catalog.Elements.Count == 0 ? 1 : 0;
        var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance) { doc.Internals.Catalog };
        var queue = new Queue<PdfObject>([doc.Internals.Catalog]);
        while (queue.TryDequeue(out var obj)) Visit(obj, 0);
        return missing;

        void Visit(PdfItem? item, int depth)
        {
            switch (item)
            {
                case PdfReference r when r.Value is null:
                    missing++;
                    break;
                case PdfReference r:
                    if (seen.Add(r.Value)) queue.Enqueue(r.Value);
                    break;
                case PdfDictionary d when depth < 32:
                    foreach (var v in d.Elements.Values) Visit(v, depth + 1);
                    break;
                case PdfArray a when depth < 32:
                    foreach (var v in a.Elements) Visit(v, depth + 1);
                    break;
            }
        }
    }

    // ---- Rebuilding the cross-reference section ----

    /// <summary>The most objects a rebuilt section lists: more than any real file, few enough to hold in memory.</summary>
    private const int MaxObjects = 4 << 20;

    /// <summary>The most bytes the object streams decode to, each and in all.</summary>
    private const int MaxObjStmBytes = 64 << 20;

    /// <summary>The most of an object's dictionary read for its /Type and /Length (they come first in real files).</summary>
    private const int MaxDictChars = 64 * 1024;

    /// <summary>The most trailers read, from the end of the file.</summary>
    private const int MaxTrailers = 16;

    /// <summary>Where an object is: at an offset in the file, or the index'th object of object stream Stream.</summary>
    private readonly record struct Entry(long Order, bool Compressed, long Offset, int Gen, int Stream, int Index);

    /// <summary>A trailer's references (as "n g R") and /ID, where it is in the file.</summary>
    private sealed record Trailer(long At, (int Num, int Gen)? Root, (int Num, int Gen)? Info, (int Num, int Gen)? Encrypt, string? Id);

    /// <summary>
    /// <paramref name="data"/> with a cross-reference stream appended that lists every object found in it, as MuPDF's repair
    /// finds them: the file read front to back for "n g obj" headers (a stream's content skipped by its /Length, or up to
    /// "endstream"), the objects held in object streams, and the last occurrence of each number winning. The trailer's
    /// /Root, /Info, /Encrypt and /ID come from the last trailer (or cross-reference stream) whose /Root is among them, else
    /// /Root is the last catalog found. Null when there is no catalog to point at. Linear in the file's size.
    /// </summary>
    internal static byte[]? Rebuild(byte[] data)
    {
        var entries = new Dictionary<int, Entry>();
        var trailers = new List<Trailer>();
        var catalogs = new List<(long Order, int Num, int Gen)>();
        var objStms = new List<(int Num, long Order, int Start, int End, string Dict)>();
        var span = data.AsSpan();
        var objKw = new Next(data, "obj"u8.ToArray());
        var endobjKw = new Next(data, "endobj"u8.ToArray());
        var streamKw = new Next(data, "stream"u8.ToArray());
        var endstreamKw = new Next(data, "endstream"u8.ToArray());

        var pos = 0;
        while (objKw.From(pos) is var i and >= 0)
        {
            if (Incremental.ObjectHeaderAt(span, i) is not ({ } num, var gen, var start))
            {
                pos = i + 3;
                continue;
            }
            var body = i + 3;
            // The object runs to "stream", "endobj" or the next object header, whichever comes first.
            var endobj = endobjKw.From(body);
            var stream = StreamKeyword(streamKw, data, body);
            var bound = Min(endobj, stream);
            var header = -1;
            for (var o = objKw.From(body); o >= 0 && (bound < 0 || o < bound); o = objKw.From(o + 3))
                if (Incremental.ObjectHeaderAt(span, o) is { } h)
                {
                    header = h.Start;
                    break;
                }
            var dictEnd = header >= 0 ? header : bound >= 0 ? bound : Math.Min(data.Length, body + 4096);
            var dict = Encoding.Latin1.GetString(data, body, Math.Min(dictEnd - body, MaxDictChars));
            entries[num] = new Entry(start, false, start, gen, 0, 0);
            if (entries.Count > MaxObjects) return null;

            if (stream >= 0 && stream == dictEnd)
            {
                var content = stream + 6;
                if (content < data.Length && data[content] == '\r') content++;
                if (content < data.Length && data[content] == '\n') content++;
                var contentEnd = EndOfStream(data, content, dict, endstreamKw);
                if (Has(dict, "/ObjStm") && contentEnd >= 0) objStms.Add((num, start, content, contentEnd, dict));
                if (Has(dict, "/XRef")) trailers.Add(TrailerOf(start, dict));
                pos = contentEnd >= 0 ? contentEnd : content;
            }
            else
            {
                if (Has(dict, "/Catalog")) catalogs.Add((start, num, gen));
                pos = endobj >= 0 && endobj == dictEnd ? endobj + 6 : dictEnd;
            }
        }

        // Objects in object streams: each where its stream is in the file.
        var decoded = 0L;
        foreach (var (stmNum, order, startAt, end, dict) in objStms)
        {
            if (entries.GetValueOrDefault(stmNum) is not { Compressed: false } own || own.Order != order) continue; // a later object took its number
            if (Decode(data, startAt, end, dict, MaxObjStmBytes - decoded) is not { } content) continue;
            decoded += content.Length;
            if (Int(dict, "/N") is not { } n || Int(dict, "/First") is not { } first || first > content.Length || n < 0) continue;
            var header = Encoding.Latin1.GetString(content, 0, first);
            var pairs = Regex.Matches(header, @"(\d{1,7})\s+(\d{1,10})");
            for (var k = 0; k < Math.Min(n, pairs.Count); k++)
            {
                if (!int.TryParse(pairs[k].Groups[1].Value, out var num) || num is <= 0 or > Incremental.MaxObjectNumber) continue;
                if (entries.TryGetValue(num, out var e) && e.Order > order) continue;
                entries[num] = new Entry(order, true, 0, 0, stmNum, k);
                if (entries.Count > MaxObjects) return null;
                if (long.TryParse(pairs[k].Groups[2].Value, out var off) && first + off < content.Length)
                {
                    var stop = k + 1 < pairs.Count && long.TryParse(pairs[k + 1].Groups[2].Value, out var o2) && first + o2 > first + off ? first + o2 : content.Length;
                    if (Has(Encoding.Latin1.GetString(content, (int)(first + off), (int)Math.Min(stop - first - off, 4096)), "/Catalog")) catalogs.Add((order, num, 0));
                }
            }
        }

        // Classic trailers, the last few.
        var from = data.Length;
        for (var t = 0; t < MaxTrailers && from > 0 && span[..from].LastIndexOf("trailer"u8) is var at and >= 0; t++, from = at)
            trailers.Add(TrailerOf(at, Encoding.Latin1.GetString(data, at, Math.Min(data.Length - at, 4096)) is var s && s.IndexOf("startxref", StringComparison.Ordinal) is var e and > 0 ? s[..e] : s));

        bool Known((int Num, int Gen)? r) => r is { } x && entries.ContainsKey(x.Num);
        var trailer = trailers.Where(t => Known(t.Root)).MaxBy(t => t.At);
        var root = trailer?.Root ?? (catalogs.Count > 0 ? (catalogs.MaxBy(c => c.Order).Num, catalogs.MaxBy(c => c.Order).Gen) : null);
        if (root is null || !Known(root)) return null;
        return Write(data, entries, root.Value, Known(trailer?.Info) ? trailer!.Info : null, trailer?.Encrypt, trailer?.Id);
    }

    /// <summary>The file with the new cross-reference stream (object number one past the largest) and its startxref appended.</summary>
    private static byte[] Write(byte[] data, Dictionary<int, Entry> entries, (int Num, int Gen) root, (int Num, int Gen)? info, (int Num, int Gen)? encrypt, string? id)
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
        if (encrypt is { } x) keys.Append($" /Encrypt {x.Num} {x.Gen} R");
        if (id is not null) keys.Append($" /ID {id}");
        using var ms = new MemoryStream(data.Length + rows.Length + 512);
        ms.Write(data);
        ms.Write(Encoding.Latin1.GetBytes($"{gap}{self} 0 obj\n<< {keys} /Length {rows.Length} >>\nstream\n"));
        ms.Write(rows);
        ms.Write(Encoding.Latin1.GetBytes($"\nendstream\nendobj\nstartxref\n{at}\n%%EOF\n"));
        return ms.ToArray();
    }

    /// <summary>
    /// Where a stream's content ends: at /Length when "endstream" follows there, else at the next "endstream"; -1 when
    /// neither (the file ends inside the stream).
    /// </summary>
    private static int EndOfStream(byte[] data, int content, string dict, Next endstreamKw)
    {
        if (Int(dict, "/Length") is { } length && length >= 0 && content + (long)length <= data.Length)
        {
            var p = content + length;
            while (p < data.Length && p - content - length < 4 && Incremental.IsWhite(data[p])) p++;
            if (data.AsSpan(p).StartsWith("endstream"u8)) return content + length;
        }
        var end = endstreamKw.From(content);
        return end;
    }

    /// <summary>The next "stream" keyword from <paramref name="from"/> that isn't the end of an "endstream".</summary>
    private static int StreamKeyword(Next streamKw, byte[] data, int from)
    {
        while (streamKw.From(from) is var s and >= 0)
        {
            if (s < 3 || !data.AsSpan(s - 3).StartsWith("end"u8)) return s;
            from = s + 6;
        }
        return -1;
    }

    /// <summary>An object stream's content: as it is, or Flate-decoded (no predictor); null for any other filter or a damaged stream.</summary>
    private static byte[]? Decode(byte[] data, int start, int end, string dict, long budget)
    {
        if (end < start || budget <= 0) return null;
        var raw = data.AsSpan(start, end - start);
        var filter = Regex.Match(dict, @"/Filter\s*\[?\s*/(\w+)\s*\]?");
        if (!filter.Success) return raw.Length <= budget ? raw.ToArray() : null;
        if (filter.Groups[1].Value != "FlateDecode" || dict.Contains("/DecodeParms", StringComparison.Ordinal)) return null;
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

    private static Trailer TrailerOf(long at, string dict) =>
        new(at, Ref(dict, "/Root"), Ref(dict, "/Info"), Ref(dict, "/Encrypt"), Incremental.FileId(dict));

    private static (int, int)? Ref(string dict, string key) =>
        Regex.Match(dict, Regex.Escape(key) + @"\s+(\d{1,7})\s+(\d{1,5})\s+R") is { Success: true } m &&
        int.TryParse(m.Groups[1].Value, out var n) && int.TryParse(m.Groups[2].Value, out var g) && n is > 0 and <= Incremental.MaxObjectNumber
            ? (n, g) : null;

    private static int? Int(string dict, string key) =>
        Regex.Match(dict, Regex.Escape(key) + @"\s+(\d{1,10})(?!\s+\d+\s+R)") is { Success: true } m && int.TryParse(m.Groups[1].Value, out var v) ? v : null;

    /// <summary>Whether the dictionary names <paramref name="name"/> (not as the start of a longer name).</summary>
    private static bool Has(string dict, string name)
    {
        for (var i = dict.IndexOf(name, StringComparison.Ordinal); i >= 0; i = dict.IndexOf(name, i + 1, StringComparison.Ordinal))
            if (i + name.Length >= dict.Length || !char.IsAsciiLetterOrDigit(dict[i + name.Length])) return true;
        return false;
    }

    private static int Min(int a, int b) => a < 0 ? b : b < 0 ? a : Math.Min(a, b);

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
