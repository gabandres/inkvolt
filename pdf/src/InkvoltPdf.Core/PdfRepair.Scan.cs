using System.Text;

namespace InkvoltPdf.Core;

public static partial class PdfRepair
{
    /// <summary>
    /// The bytes a rebuild may read token by token, in all (a few times the file's size, plus its object streams): each
    /// object's dictionary is read once in a sound file, but a damaged one whose dictionaries never close (an unclosed
    /// string in each) has each reading run over the next ones. Spent, the rebuild gives up and the file is read as it is.
    /// </summary>
    private sealed class Work(long budget)
    {
        public long Left { get; private set; } = budget;

        public bool Spent => Left < 0;

        public void Spend(long bytes) => Left -= bytes;
    }

    /// <summary>A dictionary read token by token: its top-level entries, each value as written.</summary>
    private sealed class RawDict
    {
        private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
        private readonly Dictionary<string, (int Start, int Length)> _entries = new(StringComparer.Ordinal);

        /// <summary>Just past its "&gt;&gt;".</summary>
        public int End { get; init; }

        public void Set(string key, string value, int start, int length)
        {
            _values[key] = value;
            _entries[key] = (start, length);
        }

        /// <summary>Where the entry (its key and its value) is in the bytes read, or null when the key isn't there.</summary>
        public (int Start, int Length)? Entry(string key) => _entries.TryGetValue(key, out var e) ? e : null;

        public bool Has(string key) => _values.ContainsKey(key);

        /// <summary>The value as written ("12 0 R", "/XRef", "[1 2]", "(text)"), or null when the key isn't there.</summary>
        public string? Raw(string key) => _values.GetValueOrDefault(key);

        /// <summary>A name value without its slash ("Catalog"), else null.</summary>
        public string? Name(string key) => Raw(key) is ['/', .. var name] ? name : null;

        /// <summary>A direct integer value, else null (an indirect "12 0 R" is no 12: <see cref="Ref"/>).</summary>
        public long? Int(string key) => Raw(key) is { Length: > 0 and <= 18 } v && v.All(char.IsAsciiDigit) ? long.Parse(v, PdfObj.Inv) : null;

        /// <summary>An indirect reference value ("12 0 R"), else null.</summary>
        public (int Num, int Gen)? Ref(string key) => RefOf(Raw(key));
    }

    private static (int Num, int Gen)? RefOf(string? value)
    {
        if (value is null) return null;
        var parts = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return parts is [var n, var g, "R"] && int.TryParse(n, PdfObj.Inv, out var num) && int.TryParse(g, PdfObj.Inv, out var gen) &&
               num is > 0 and <= Incremental.MaxObjectNumber && gen is >= 0 and <= 65535
            ? (num, gen) : null;
    }

    /// <summary>
    /// The dictionary at <paramref name="at"/> ("&lt;&lt;"), read token by token: strings, hex strings, names, nested arrays
    /// and dictionaries are skipped whole, so a "stream" or "obj" inside one is no keyword. Null when there is none, it
    /// doesn't close within <see cref="MaxDictChars"/>, or it holds a keyword no dictionary can (obj, endobj, stream,
    /// endstream, xref, trailer, startxref): the object is broken there and the next header begins another.
    /// </summary>
    private static RawDict? ReadDict(byte[] d, int at, Work work)
    {
        if (at + 1 >= d.Length || d[at] != '<' || d[at + 1] != '<') return null;
        var end = (int)Math.Min(d.Length, (long)at + MaxDictChars);
        var p = at + 2;
        var entries = new List<(string Key, string Value, int Start, int Length)>();
        try
        {
            while (true)
            {
                p = SkipWhite(d, p, end);
                if (p >= end) return null;
                if (d[p] == '>' && p + 1 < end && d[p + 1] == '>')
                {
                    var dict = new RawDict { End = p + 2 };
                    foreach (var (k, v, start, length) in entries) dict.Set(k, v, start, length);
                    return dict;
                }
                if (d[p] != '/') return null; // a key is a name
                var keyStart = p;
                var keyEnd = TokenEnd(d, p + 1, end);
                var key = Encoding.Latin1.GetString(d, p, keyEnd - p);
                p = SkipWhite(d, keyEnd, end);
                var value = p;
                if (!SkipValue(d, ref p, end)) return null;
                entries.Add((key, Encoding.Latin1.GetString(d, value, p - value), keyStart, p - keyStart));
            }
        }
        finally
        {
            work.Spend(p - at);
        }
    }

    /// <summary>Skips one value at <paramref name="p"/> (an indirect reference "12 0 R" whole); false where none can be.</summary>
    private static bool SkipValue(byte[] d, ref int p, int end)
    {
        var depth = 0;
        do
        {
            p = SkipWhite(d, p, end);
            if (p >= end) return false;
            switch (d[p])
            {
                case (byte)'/':
                    p = TokenEnd(d, p + 1, end);
                    break;
                case (byte)'(':
                    if (!SkipString(d, ref p, end)) return false;
                    break;
                case (byte)'<' when p + 1 < end && d[p + 1] == '<':
                case (byte)'[':
                    p += d[p] == '[' ? 1 : 2;
                    depth++;
                    break;
                case (byte)'<':
                    var close = d.AsSpan(p, end - p).IndexOf((byte)'>');
                    if (close < 0) return false;
                    p += close + 1;
                    break;
                case (byte)'>' when depth > 0 && p + 1 < end && d[p + 1] == '>':
                case (byte)']' when depth > 0:
                    p += d[p] == ']' ? 1 : 2;
                    depth--;
                    break;
                default:
                    if (Incremental.IsDelimiter(d[p])) return false; // ")", ">", "]", "{", "}" out of place
                    var t = TokenEnd(d, p, end);
                    var token = d.AsSpan(p, t - p);
                    if (IsKeyword(token)) return false;
                    p = t;
                    if (depth == 0 && IsDigits(token))
                    {
                        // "12 0 R": the reference is one value.
                        var g = SkipWhite(d, p, end);
                        var gEnd = TokenEnd(d, g, end);
                        var r = SkipWhite(d, gEnd, end);
                        if (gEnd > g && IsDigits(d.AsSpan(g, gEnd - g)) && r < end && d[r] == 'R' && TokenEnd(d, r, end) == r + 1) p = r + 1;
                    }
                    break;
            }
        } while (depth > 0);
        return true;
    }

    /// <summary>Skips a literal string (balanced parentheses, backslash escapes) at <paramref name="p"/>'s "(".</summary>
    private static bool SkipString(byte[] d, ref int p, int end)
    {
        var depth = 0;
        for (; p < end; p++)
        {
            switch (d[p])
            {
                case (byte)'\\':
                    p++;
                    break;
                case (byte)'(':
                    depth++;
                    break;
                case (byte)')' when --depth == 0:
                    p++;
                    return true;
            }
        }
        return false;
    }

    /// <summary>Past white space and comments.</summary>
    private static int SkipWhite(byte[] d, int p, int end)
    {
        while (p < end)
        {
            if (Incremental.IsWhite(d[p])) p++;
            else if (d[p] == '%')
                while (p < end && d[p] is not ((byte)'\r' or (byte)'\n')) p++;
            else break;
        }
        return p;
    }

    /// <summary>The end of the regular characters from <paramref name="p"/>.</summary>
    private static int TokenEnd(byte[] d, int p, int end)
    {
        while (p < end && !Incremental.IsWhite(d[p]) && !Incremental.IsDelimiter(d[p])) p++;
        return p;
    }

    private static bool IsDigits(ReadOnlySpan<byte> token) => token.Length is > 0 and <= 18 && !token.ContainsAnyExceptInRange((byte)'0', (byte)'9');

    private static bool IsKeyword(ReadOnlySpan<byte> token) =>
        token.SequenceEqual("obj"u8) || token.SequenceEqual("endobj"u8) || token.SequenceEqual("stream"u8) || token.SequenceEqual("endstream"u8) ||
        token.SequenceEqual("xref"u8) || token.SequenceEqual("trailer"u8) || token.SequenceEqual("startxref"u8);

    /// <summary>
    /// Where a stream's content starts when the keyword "stream" follows a dictionary that ends at <paramref name="p"/>
    /// (after white space, as a token, then an end of line: CR LF, LF or CR); -1 when the object is no stream.
    /// </summary>
    private static int StreamContentAfter(byte[] d, int p)
    {
        while (p < d.Length && Incremental.IsWhite(d[p])) p++;
        if (!d.AsSpan(p).StartsWith("stream"u8)) return -1;
        p += 6;
        while (p < d.Length && d[p] is (byte)' ' or (byte)'\t') p++;
        if (p < d.Length && d[p] == '\r') return p + 1 < d.Length && d[p + 1] == '\n' ? p + 2 : p + 1;
        return p < d.Length && d[p] == '\n' ? p + 1 : -1;
    }

    /// <summary>An unsigned integer token at <paramref name="p"/> (after white space), before <paramref name="end"/>.</summary>
    private static long? ReadInt(byte[] d, ref int p, int end)
    {
        p = SkipWhite(d, p, end);
        var t = TokenEnd(d, p, end);
        if (!IsDigits(d.AsSpan(p, t - p))) return null;
        var value = long.Parse(d.AsSpan(p, t - p), provider: PdfObj.Inv);
        p = t;
        return value;
    }

    /// <summary>
    /// Every object header in the file, by number, for an indirect /Length, /N or /First: built once, the first time one
    /// is met, and at most <see cref="MaxObjects"/> of them.
    /// </summary>
    private sealed class Headers
    {
        private readonly Dictionary<int, List<int>> _at = [];

        public Headers(byte[] d)
        {
            var count = 0;
            for (var from = 0; count < MaxObjects && from < d.Length && d.AsSpan(from).IndexOf("obj"u8) is var i and >= 0; from += i + 3)
            {
                if (Incremental.ObjectHeaderAt(d, from + i) is not { } h) continue;
                if (!_at.TryGetValue(h.Num, out var list)) _at[h.Num] = list = [];
                list.Add(from + i);
                count++;
            }
        }

        /// <summary>
        /// The integer object (n, g) holds, read at its first header at or after <paramref name="near"/> (a stream's length
        /// is usually written after it), else its last before; null when there is none or it holds no integer.
        /// </summary>
        public long? IntOf(byte[] d, (int Num, int Gen) id, int near)
        {
            if (!_at.TryGetValue(id.Num, out var list)) return null;
            var k = list.BinarySearch(near);
            k = k < 0 ? ~k : k;
            var candidates = new List<int>(2);
            if (k < list.Count) candidates.Add(list[k]);
            if (k > 0) candidates.Add(list[k - 1]);
            foreach (var obj in candidates)
            {
                if (Incremental.ObjectHeaderAt(d, obj) is not { } h || h.Gen != id.Gen) continue;
                var p = obj + 3;
                if (ReadInt(d, ref p, Math.Min(d.Length, p + 64)) is { } v && SkipWhite(d, p, Math.Min(d.Length, p + 64)) is var q &&
                    d.AsSpan(q).StartsWith("endobj"u8))
                    return v;
            }
            return null;
        }
    }
}
