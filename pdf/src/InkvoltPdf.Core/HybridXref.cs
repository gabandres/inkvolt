using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>
/// Hybrid-reference files (Word writes them: a classic xref table whose trailer points at an xref stream with /XRefStm, for
/// the objects kept in object streams). PDFsharp reads the table and ignores /XRefStm, so those objects (in Word's files,
/// the structure tree among them) resolve to null. <see cref="Normalize"/> appends one xref stream that lists every object
/// of the whole chain, as a reader that knows /XRefStm sees them; PDFsharp then finds them all, each as its latest revision
/// has it. Nothing before it changes.
/// </summary>
internal static partial class HybridXref
{
    private const int MaxSections = 64, MaxObjects = 8_000_000;

    /// <summary>The file with every object reachable by PDFsharp, or the same array when it isn't a hybrid file (or can't be read as one).</summary>
    public static byte[] Normalize(byte[] data)
    {
        try
        {
            return Merge(data) ?? data;
        }
        catch (Exception ex) when (ex is FormatException or InvalidDataException or ArgumentException or IndexOutOfRangeException or OverflowException)
        {
            return data;
        }
    }

    private readonly record struct Entry(int Type, long Field2, int Field3);

    [GeneratedRegex(@"/XRefStm\s+(\d+)")] private static partial Regex XRefStm();
    [GeneratedRegex(@"/Prev\s+(\d+)")] private static partial Regex Prev();

    private static byte[]? Merge(byte[] data)
    {
        if (Incremental.StartXref(data) is not { } start) return null;
        var entries = new Dictionary<int, Entry>();
        var seen = new HashSet<long>();
        var hybrid = false;
        string? lastTrailer = null;
        var queue = new List<long> { start };
        for (var i = 0; i < queue.Count && i < MaxSections; i++)
        {
            var at = queue[i];
            if (at <= 0 || at >= data.Length || !seen.Add(at)) continue;
            string trailer;
            if (StartsWith(data, at, "xref"))
            {
                trailer = Classic(data, at, entries);
                if (XRefStm().Match(trailer) is { Success: true } x)
                {
                    hybrid = true;
                    var stm = long.Parse(x.Groups[1].Value, CultureInfo.InvariantCulture);
                    if (seen.Add(stm)) Stream(data, stm, entries);
                }
            }
            else trailer = Stream(data, at, entries);
            lastTrailer ??= trailer;
            if (Prev().Match(trailer) is { Success: true } p) queue.Add(long.Parse(p.Groups[1].Value, CultureInfo.InvariantCulture));
        }
        if (!hybrid || lastTrailer is null || entries.Count == 0) return null;

        // One xref stream after the file: every object, no /Prev.
        var self = entries.Keys.Max() + 1;
        var size = self + 1;
        var offset = data.Length + 1L;
        entries[self] = new Entry(1, offset, 0);
        // PDFsharp reads an object stream whole at the first row naming it and keeps what it read first, so an object a later
        // revision rewrote in a stream of its own would come from the older stream: the rows of the streams latest in the file go first.
        var order = Enumerable.Range(0, size).OrderByDescending(n =>
            entries.TryGetValue(n, out var e) && e.Type == 2 && entries.TryGetValue((int)e.Field2, out var stream) ? stream.Field2 : -1).ToList();
        var index = new StringBuilder();
        for (int i = 0, run; i < order.Count; i += run)
        {
            for (run = 1; i + run < order.Count && order[i + run] == order[i] + run; run++) { }
            index.Append($"{order[i]} {run} ");
        }
        var rows = new MemoryStream();
        foreach (var n in order)
        {
            var e = entries.TryGetValue(n, out var found) ? found : new Entry(0, 0, n == 0 ? 65535 : 0);
            rows.WriteByte((byte)e.Type);
            for (var b = 7; b >= 0; b--) rows.WriteByte((byte)(e.Field2 >> (8 * b)));
            rows.WriteByte((byte)(e.Field3 >> 8));
            rows.WriteByte((byte)e.Field3);
        }
        var keys = new StringBuilder();
        foreach (var key in new[] { "Root", "Info", "Encrypt" })
            if (Regex.Match(lastTrailer, $@"/{key}\s+(\d+\s+\d+\s+R)") is { Success: true } m) keys.Append($" /{key} {m.Groups[1].Value}");
        if (Regex.Match(lastTrailer, @"/ID\s*(\[[^\]]*\])") is { Success: true } id) keys.Append($" /ID {id.Groups[1].Value}");
        var head = Encoding.Latin1.GetBytes($"\n{self} 0 obj\n<< /Type /XRef /Size {size} /Index [{index}] /W [1 8 2]{keys} /Length {rows.Length} >>\nstream\n");
        var tail = Encoding.Latin1.GetBytes($"\nendstream\nendobj\nstartxref\n{offset}\n%%EOF\n");
        var result = new byte[data.Length + head.Length + rows.Length + tail.Length];
        data.CopyTo(result, 0);
        head.CopyTo(result, data.Length);
        rows.ToArray().CopyTo(result, data.Length + head.Length);
        tail.CopyTo(result, data.Length + head.Length + rows.Length);
        return result;
    }

    private static bool StartsWith(byte[] data, long at, string s) =>
        at + s.Length <= data.Length && Encoding.Latin1.GetString(data, (int)at, s.Length) == s;

    /// <summary>Reads a classic table into <paramref name="entries"/> (entries already known win) and returns its trailer's text.</summary>
    private static string Classic(byte[] data, long at, Dictionary<int, Entry> entries)
    {
        var p = (int)at + 4;
        var text = Encoding.Latin1.GetString(data, p, (int)Math.Min(data.Length - p, 40_000_000));
        var pos = 0;
        while (true)
        {
            var line = Regex.Match(text[pos..Math.Min(text.Length, pos + 200)], @"^\s*(\d+)\s+(\d+)[ \t]*\r?\n?");
            if (!line.Success) break;
            var first = int.Parse(line.Groups[1].Value, CultureInfo.InvariantCulture);
            var count = int.Parse(line.Groups[2].Value, CultureInfo.InvariantCulture);
            pos += line.Length;
            for (var k = 0; k < count && entries.Count < MaxObjects; k++)
            {
                var row = Regex.Match(text[pos..Math.Min(text.Length, pos + 40)], @"^\s*(\d{1,10})\s+(\d{1,5})\s+([nf])");
                if (!row.Success) throw new FormatException("xref row");
                pos += row.Length;
                // A hybrid file's table marks the objects kept in object streams as free (so older readers skip them): a free
                // row doesn't hide what the xref stream says.
                if (row.Groups[3].Value != "n") continue;
                entries.TryAdd(first + k, new Entry(1, long.Parse(row.Groups[1].Value, CultureInfo.InvariantCulture), int.Parse(row.Groups[2].Value, CultureInfo.InvariantCulture)));
            }
        }
        var t = text.IndexOf("trailer", pos, StringComparison.Ordinal);
        if (t < 0) throw new FormatException("trailer");
        var end = text.IndexOf("startxref", t, StringComparison.Ordinal);
        return text[t..(end < 0 ? Math.Min(text.Length, t + 4096) : end)];
    }

    /// <summary>Reads an xref stream into <paramref name="entries"/> (entries already known win) and returns its dictionary's text.</summary>
    private static string Stream(byte[] data, long at, Dictionary<int, Entry> entries)
    {
        var window = Encoding.Latin1.GetString(data, (int)at, (int)Math.Min(data.Length - at, 64 * 1024));
        var s = window.IndexOf("stream", StringComparison.Ordinal);
        if (s < 0) throw new FormatException("xref stream");
        var dict = window[..s];
        if (!Regex.IsMatch(dict, @"/Type\s*/XRef\b")) throw new FormatException("not an xref stream");
        var length = Regex.Match(dict, @"/Length\s+(\d+)(?!\s+\d+\s+R)");
        if (!length.Success) throw new FormatException("xref stream length");
        var bodyAt = (int)at + s + 6;
        if (data[bodyAt] == '\r') bodyAt++;
        if (data[bodyAt] == '\n') bodyAt++;
        var raw = data.AsSpan(bodyAt, Math.Min(int.Parse(length.Groups[1].Value, CultureInfo.InvariantCulture), data.Length - bodyAt)).ToArray();
        var bytes = Regex.IsMatch(dict, @"/Filter\s*\[?\s*/FlateDecode") ? Inflate(raw) : raw;
        var w = Regex.Match(dict, @"/W\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s*\]");
        if (!w.Success) throw new FormatException("xref W");
        int w1 = int.Parse(w.Groups[1].Value, CultureInfo.InvariantCulture), w2 = int.Parse(w.Groups[2].Value, CultureInfo.InvariantCulture), w3 = int.Parse(w.Groups[3].Value, CultureInfo.InvariantCulture);
        var rowLength = w1 + w2 + w3;
        if (rowLength == 0) throw new FormatException("xref W");
        if (Regex.Match(dict, @"/Predictor\s+(\d+)") is { Success: true } pr && int.Parse(pr.Groups[1].Value, CultureInfo.InvariantCulture) >= 10)
        {
            var columns = Regex.Match(dict, @"/Columns\s+(\d+)") is { Success: true } c ? int.Parse(c.Groups[1].Value, CultureInfo.InvariantCulture) : 1;
            bytes = Unpredict(bytes, columns);
        }
        var size = Regex.Match(dict, @"/Size\s+(\d+)") is { Success: true } sz ? int.Parse(sz.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
        var index = new List<(int First, int Count)>();
        if (Regex.Match(dict, @"/Index\s*\[([\d\s]*)\]") is { Success: true } ix)
        {
            var nums = ix.Groups[1].Value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(x => int.Parse(x, CultureInfo.InvariantCulture)).ToList();
            for (var i = 0; i + 1 < nums.Count; i += 2) index.Add((nums[i], nums[i + 1]));
        }
        else index.Add((0, size));
        var row = 0;
        foreach (var (first, count) in index)
            for (var k = 0; k < count && (row + 1) * rowLength <= bytes.Length && entries.Count < MaxObjects; k++, row++)
            {
                var o = row * rowLength;
                long Field(int from, int width)
                {
                    long v = 0;
                    for (var b = 0; b < width; b++) v = v << 8 | bytes[o + from + b];
                    return v;
                }
                var type = w1 == 0 ? 1 : (int)Field(0, w1);
                if (type is < 0 or > 2) continue;
                entries.TryAdd(first + k, new Entry(type, Field(w1, w2), (int)Field(w1 + w2, w3)));
            }
        return dict;
    }

    private static byte[] Inflate(byte[] raw)
    {
        using var input = new MemoryStream(raw);
        using var z = new ZLibStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        z.CopyTo(output);
        return output.ToArray();
    }

    /// <summary>Undoes PNG predictors (one filter byte per row of <paramref name="columns"/> bytes).</summary>
    private static byte[] Unpredict(byte[] data, int columns)
    {
        var rows = data.Length / (columns + 1);
        var result = new byte[rows * columns];
        var prior = new byte[columns];
        for (var r = 0; r < rows; r++)
        {
            var filter = data[r * (columns + 1)];
            var row = result.AsSpan(r * columns, columns);
            for (var c = 0; c < columns; c++)
            {
                var x = data[r * (columns + 1) + 1 + c];
                var left = c > 0 ? row[c - 1] : 0;
                var up = prior[c];
                var upLeft = c > 0 ? prior[c - 1] : 0;
                row[c] = filter switch
                {
                    1 => (byte)(x + left),
                    2 => (byte)(x + up),
                    3 => (byte)(x + (left + up) / 2),
                    4 => (byte)(x + Paeth(left, up, upLeft)),
                    _ => x,
                };
            }
            row.CopyTo(prior);
        }
        return result;
    }

    private static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }
}
