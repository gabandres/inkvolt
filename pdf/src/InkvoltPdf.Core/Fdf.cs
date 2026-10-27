using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// Just enough PDF object syntax to read and write FDF files (form data and comments). Values are plain .NET objects:
/// null, bool, double, string (a text string, decoded), <see cref="Name"/>, <see cref="Ref"/>, <see cref="Stream"/>,
/// <c>List&lt;object?&gt;</c> (array) and <c>Dictionary&lt;string, object?&gt;</c> (keys without the slash).
/// </summary>
internal static class Fdf
{
    internal sealed record Name(string Value);

    internal sealed record Ref(int Id);

    /// <summary>A stream: its dictionary and its bytes as stored (still encoded by its /Filter).</summary>
    internal sealed class Stream(Dictionary<string, object?> dict, byte[] data)
    {
        public Dictionary<string, object?> Dict { get; } = dict;
        public byte[] Data { get; } = data;
    }

    // ---------------- Reading ----------------

    /// <summary>An FDF file's objects and its catalog.</summary>
    internal sealed class Document
    {
        public Dictionary<int, object?> Objects { get; } = [];
        public object? Root { get; set; }

        public object? Resolve(object? o)
        {
            for (var guard = 0; o is Ref r && guard < 32; guard++) o = Objects.GetValueOrDefault(r.Id);
            return o is Ref ? null : o;
        }

        /// <summary>The catalog's /FDF dictionary (the trailer's /Root, else the first object holding one).</summary>
        public Dictionary<string, object?>? FdfDict()
        {
            var catalog = Resolve(Root) as Dictionary<string, object?>
                ?? Objects.Values.OfType<Dictionary<string, object?>>().FirstOrDefault(d => d.ContainsKey("FDF"));
            return Resolve(catalog?.GetValueOrDefault("FDF")) as Dictionary<string, object?>;
        }
    }

    /// <summary>Reads FDF text (the file's bytes as Latin-1).</summary>
    public static Document Read(string text) => new Parser(text).Parse();

    private sealed class Parser(string s)
    {
        private sealed record Keyword(string Value);
        private sealed record StreamData(byte[] Data);
        private static readonly object Open = new(), Close = new(), ArrOpen = new(), ArrClose = new();
        private const int MaxTokens = 2_000_000;

        private int _p;
        private readonly List<object?> _tokens = [];

        public Document Parse()
        {
            Lex();
            var doc = new Document();
            var i = 0;
            while (i < _tokens.Count)
            {
                if (i + 2 < _tokens.Count && _tokens[i] is double id && _tokens[i + 1] is double && _tokens[i + 2] is Keyword { Value: "obj" })
                {
                    i += 3;
                    doc.Objects[(int)id] = Value(ref i);
                }
                else if (_tokens[i] is Keyword { Value: "trailer" })
                {
                    i++;
                    if (Value(ref i) is Dictionary<string, object?> t) doc.Root = t.GetValueOrDefault("Root");
                }
                else i++;
            }
            return doc;
        }

        private object? Value(ref int i)
        {
            if (i >= _tokens.Count) return null;
            var t = _tokens[i++];
            if (t is double n && i + 1 < _tokens.Count && _tokens[i] is double && _tokens[i + 1] is Keyword { Value: "R" })
            {
                i += 2;
                return new Ref((int)n);
            }
            if (ReferenceEquals(t, Open))
            {
                var d = new Dictionary<string, object?>(StringComparer.Ordinal);
                while (i < _tokens.Count && !ReferenceEquals(_tokens[i], Close))
                {
                    if (_tokens[i++] is not Name key) continue;
                    d[key.Value] = Value(ref i);
                }
                i++;
                if (i < _tokens.Count && _tokens[i] is StreamData data)
                {
                    i++;
                    return new Stream(d, data.Data);
                }
                return d;
            }
            if (ReferenceEquals(t, ArrOpen))
            {
                var list = new List<object?>();
                while (i < _tokens.Count && !ReferenceEquals(_tokens[i], ArrClose)) list.Add(Value(ref i));
                i++;
                return list;
            }
            return t switch
            {
                Keyword { Value: "true" } => true,
                Keyword { Value: "false" } => false,
                Keyword { Value: "null" } => null,
                Keyword or StreamData => null,
                _ => t,
            };
        }

        private void Lex()
        {
            while (_p < s.Length && _tokens.Count < MaxTokens)
            {
                var c = s[_p];
                if (char.IsWhiteSpace(c) || c == '\0') _p++;
                else if (c == '%') while (_p < s.Length && s[_p] is not ('\r' or '\n')) _p++;
                else if (c == '<' && At(1) == '<') { _tokens.Add(Open); _p += 2; }
                else if (c == '>' && At(1) == '>') { _tokens.Add(Close); _p += 2; }
                else if (c == '[') { _tokens.Add(ArrOpen); _p++; }
                else if (c == ']') { _tokens.Add(ArrClose); _p++; }
                else if (c == '(') _tokens.Add(Decode(Literal()));
                else if (c == '<') _tokens.Add(Decode(Hex()));
                else if (c == '/') _tokens.Add(new Name(NameToken()));
                else if (c is (>= '0' and <= '9') or '+' or '-' or '.') _tokens.Add(Number());
                else
                {
                    var start = _p;
                    while (_p < s.Length && !char.IsWhiteSpace(s[_p]) && "()<>[]{}/%".IndexOf(s[_p]) < 0) _p++;
                    if (_p == start) _p++;
                    var word = s[start.._p];
                    if (word == "stream") _tokens.Add(new StreamData(StreamBytes()));
                    else _tokens.Add(new Keyword(word));
                }
            }
        }

        /// <summary>A stream's bytes: /Length of the dictionary just read when it is a direct number that ends at
        /// "endstream", else up to "endstream".</summary>
        private byte[] StreamBytes()
        {
            if (_p < s.Length && s[_p] == '\r') _p++;
            if (_p < s.Length && s[_p] == '\n') _p++;
            var start = _p;
            int? length = null;
            var depth = 0;
            for (var k = _tokens.Count - 1; k >= 0 && k >= _tokens.Count - 4096; k--)
            {
                if (ReferenceEquals(_tokens[k], Close)) depth++;
                else if (ReferenceEquals(_tokens[k], Open) && --depth <= 0) break;
                else if (depth == 1 && _tokens[k] is Name { Value: "Length" } && k + 1 < _tokens.Count && _tokens[k + 1] is double len
                    && !(k + 3 < _tokens.Count && _tokens[k + 3] is Keyword { Value: "R" }))
                    length = len is >= 0 and <= int.MaxValue ? (int)len : null;
            }
            if (length is { } n && start + n <= s.Length)
            {
                var after = start + n;
                while (after < s.Length && char.IsWhiteSpace(s[after])) after++;
                if (string.CompareOrdinal(s, after, "endstream", 0, 9) == 0)
                {
                    _p = after + 9;
                    return Encoding.Latin1.GetBytes(s, start, n);
                }
            }
            var end = s.IndexOf("endstream", start, StringComparison.Ordinal);
            if (end < 0) end = s.Length;
            _p = Math.Min(s.Length, end + 9);
            var stop = end;
            if (stop > start && s[stop - 1] == '\n') stop--;
            if (stop > start && s[stop - 1] == '\r') stop--;
            return Encoding.Latin1.GetBytes(s, start, stop - start);
        }

        private char At(int ahead) => _p + ahead < s.Length ? s[_p + ahead] : '\0';

        private object Number()
        {
            var start = _p;
            _p++;
            while (_p < s.Length && (char.IsDigit(s[_p]) || s[_p] == '.')) _p++;
            return double.TryParse(s.AsSpan(start, _p - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : 0.0;
        }

        private string NameToken()
        {
            _p++;
            var bytes = new List<byte>();
            while (_p < s.Length && !char.IsWhiteSpace(s[_p]) && "()<>[]{}/%".IndexOf(s[_p]) < 0)
            {
                if (s[_p] == '#' && _p + 2 < s.Length && byte.TryParse(s.AsSpan(_p + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b))
                {
                    bytes.Add(b);
                    _p += 3;
                }
                else bytes.Add((byte)s[_p++]);
            }
            return Encoding.UTF8.GetString([.. bytes]);
        }

        private byte[] Literal()
        {
            _p++;
            var bytes = new List<byte>();
            var depth = 1;
            while (_p < s.Length)
            {
                var c = s[_p++];
                if (c == '\\' && _p < s.Length)
                {
                    var e = s[_p++];
                    switch (e)
                    {
                        case 'n': bytes.Add((byte)'\n'); break;
                        case 'r': bytes.Add((byte)'\r'); break;
                        case 't': bytes.Add((byte)'\t'); break;
                        case 'b': bytes.Add((byte)'\b'); break;
                        case 'f': bytes.Add((byte)'\f'); break;
                        case '\r':
                            if (_p < s.Length && s[_p] == '\n') _p++;
                            break;
                        case '\n': break;
                        case >= '0' and <= '7':
                        {
                            var v = e - '0';
                            for (var k = 0; k < 2 && _p < s.Length && s[_p] is >= '0' and <= '7'; k++) v = v * 8 + (s[_p++] - '0');
                            bytes.Add((byte)v);
                            break;
                        }
                        default: bytes.Add((byte)e); break;
                    }
                    continue;
                }
                if (c == '(') depth++;
                else if (c == ')' && --depth == 0) break;
                bytes.Add((byte)c);
            }
            return [.. bytes];
        }

        private byte[] Hex()
        {
            _p++;
            var digits = new StringBuilder();
            while (_p < s.Length && s[_p] != '>')
            {
                if (Uri.IsHexDigit(s[_p])) digits.Append(s[_p]);
                _p++;
            }
            _p++;
            if (digits.Length % 2 == 1) digits.Append('0');
            return Convert.FromHexString(digits.ToString());
        }

        /// <summary>PDF text string bytes: UTF-16BE or UTF-8 with a byte order mark, else PDFDocEncoding (as Latin-1).</summary>
        private static string Decode(byte[] b) =>
            b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF ? Encoding.BigEndianUnicode.GetString(b, 2, b.Length - 2)
            : b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF ? Encoding.UTF8.GetString(b, 3, b.Length - 3)
            : Encoding.Latin1.GetString(b);
    }

    // ---------------- Writing ----------------

    /// <summary>Writes an FDF file: objects added in order, streams always as indirect objects (each once).</summary>
    internal sealed class Writer
    {
        private readonly MemoryStream _out = new();
        private readonly Dictionary<object, int> _ids = new(ReferenceEqualityComparer.Instance);
        private readonly Queue<(int Id, object Value)> _pending = new();
        private int _next = 1;

        public Writer()
        {
            Raw("%FDF-1.2\n%âãÏÓ\n");
        }

        /// <summary>A number for an object to be written later (<see cref="Set"/>).</summary>
        public Ref Reserve() => new(_next++);

        /// <summary>Writes <paramref name="value"/> as object <paramref name="id"/>.</summary>
        public void Set(Ref id, object? value)
        {
            Raw($"{id.Id} 0 obj\n");
            if (value is Stream st) WriteStream(st);
            else Raw(Serialize(value));
            Raw("\nendobj\n");
            Flush();
        }

        /// <summary>A reference to <paramref name="value"/> as its own object (written once, however often it is referred to).</summary>
        public Ref Indirect(object value)
        {
            if (_ids.TryGetValue(value, out var id)) return new Ref(id);
            id = _next++;
            _ids[value] = id;
            _pending.Enqueue((id, value));
            return new Ref(id);
        }

        public byte[] Finish(Ref root)
        {
            Flush();
            Raw($"trailer\n<< /Root {root.Id} 0 R >>\n%%EOF\n");
            return _out.ToArray();
        }

        private void Flush()
        {
            while (_pending.TryDequeue(out var item))
            {
                Raw($"{item.Id} 0 obj\n");
                if (item.Value is Stream st) WriteStream(st);
                else Raw(Serialize(item.Value));
                Raw("\nendobj\n");
            }
        }

        private void WriteStream(Stream st)
        {
            var dict = new Dictionary<string, object?>(st.Dict, StringComparer.Ordinal) { ["Length"] = (double)st.Data.Length };
            Raw(Serialize(dict));
            Raw("\nstream\n");
            _out.Write(st.Data);
            Raw("\nendstream");
        }

        private void Raw(string text) => _out.Write(Encoding.Latin1.GetBytes(text));

        public string Serialize(object? value)
        {
            var sb = new StringBuilder();
            Write(sb, value, 0);
            return sb.ToString();
        }

        private void Write(StringBuilder sb, object? value, int depth)
        {
            if (depth > 64) { sb.Append("null"); return; }
            switch (value)
            {
                case null: sb.Append("null"); break;
                case bool b: sb.Append(b ? "true" : "false"); break;
                case double d: sb.Append(Number(d)); break;
                case int i: sb.Append(i.ToString(CultureInfo.InvariantCulture)); break;
                case string str: sb.Append(Text(str)); break;
                case Name n: sb.Append(NameText(n.Value)); break;
                case Ref r: sb.Append(CultureInfo.InvariantCulture, $"{r.Id} 0 R"); break;
                case Stream st:
                {
                    var r = Indirect(st);
                    sb.Append(CultureInfo.InvariantCulture, $"{r.Id} 0 R");
                    break;
                }
                case IEnumerable<KeyValuePair<string, object?>> dict:
                    sb.Append("<<");
                    foreach (var (k, v) in dict)
                    {
                        sb.Append(' ').Append(NameText(k)).Append(' ');
                        Write(sb, v, depth + 1);
                    }
                    sb.Append(" >>");
                    break;
                case System.Collections.IEnumerable list:
                    sb.Append('[');
                    var first = true;
                    foreach (var item in list)
                    {
                        if (!first) sb.Append(' ');
                        first = false;
                        Write(sb, item, depth + 1);
                    }
                    sb.Append(']');
                    break;
                default: sb.Append("null"); break;
            }
        }
    }

    public static string Number(double d)
    {
        if (!double.IsFinite(d)) return "0";
        if (Math.Abs(d - Math.Round(d)) < 1e-9 && Math.Abs(d) < 1e15) return Math.Round(d).ToString("0", CultureInfo.InvariantCulture);
        return Math.Round(d, 5).ToString("0.#####", CultureInfo.InvariantCulture);
    }

    /// <summary>A PDF string: literal for printable ASCII, else UTF-16BE hex with a byte order mark.</summary>
    public static string Text(string s)
    {
        if (s.All(c => c is >= ' ' and < '\u007f' or '\n' or '\r' or '\t'))
        {
            var sb = new StringBuilder("(");
            foreach (var c in s)
                sb.Append(c switch { '(' => "\\(", ')' => "\\)", '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t", _ => c.ToString() });
            return sb.Append(')').ToString();
        }
        return "<FEFF" + Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(s)) + ">";
    }

    public static string NameText(string s)
    {
        var sb = new StringBuilder("/");
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            if (b is > 0x20 and < 0x7f && "#()<>[]{}/%".IndexOf((char)b) < 0) sb.Append((char)b);
            else sb.Append('#').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }
}
