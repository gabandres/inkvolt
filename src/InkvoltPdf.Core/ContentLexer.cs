using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

internal enum CKind { Number, Name, String, Array, Dict, Bool, Null }

/// <summary>An operand of a content-stream operator, with where it sits in the stream (byte offsets, end exclusive).</summary>
internal sealed class CObj
{
    public CKind Kind;
    public double Num;
    public bool IsInt;
    /// <summary>A name (without the slash, #xx decoded) or a bool/null keyword.</summary>
    public string Name = "";
    /// <summary>A string's bytes (escapes and hex decoded).</summary>
    public byte[] Bytes = [];
    public bool Hex;
    public List<CObj> Items = [];
    public List<(string Key, CObj Value)> Entries = [];
    public int Start, End;

    public CObj? this[string key] => Entries.FirstOrDefault(e => e.Key == key).Value;
}

/// <summary>An operator with its operands. An inline image is one "BI" op spanning BI…EI (its dictionary in <see cref="Operands"/>).</summary>
internal sealed class COp
{
    public string Name = "";
    public List<CObj> Operands = [];
    /// <summary>Where the op starts (its first operand, else the operator) and ends (after the operator; after EI for an inline image).</summary>
    public int Start, End;
    /// <summary>Inline image data (between ID and EI).</summary>
    public int DataStart, DataEnd;

    public double N(int i) => i < Operands.Count && Operands[i].Kind == CKind.Number ? Operands[i].Num : 0;
}

/// <summary>
/// Reads a PDF content stream into operators, keeping byte offsets so a single operator can be replaced without
/// rewriting (or misreading) the rest: strings with escapes, hex strings, names with #xx, arrays, dictionaries
/// (marked-content properties), comments, and inline images (BI … ID data EI), whose binary data is skipped by its
/// computed length when unfiltered, else by finding an EI that is followed by ordinary content.
/// Malformed input never throws: a stray delimiter is skipped and an unterminated object ends at the end of the data.
/// </summary>
internal sealed class ContentLexer
{
    private readonly byte[] _b;
    private int _p;

    private ContentLexer(byte[] data) => _b = data;

    public static List<COp> Parse(byte[] data, CancellationToken cancel = default)
    {
        var lx = new ContentLexer(data);
        var ops = new List<COp>();
        var operands = new List<CObj>();
        var n = 0;
        while (true)
        {
            if ((++n & 4095) == 0) cancel.ThrowIfCancellationRequested();
            lx.SkipSpace();
            if (lx._p >= data.Length) break;
            var start = lx._p;
            if (lx.ReadObject() is { } obj)
            {
                operands.Add(obj);
                if (operands.Count > 4096) operands.RemoveAt(0); // junk: don't grow without bound
                continue;
            }
            if (lx._p == start)
            {
                lx._p++; // a stray delimiter: skip it
                continue;
            }
            var word = Encoding.ASCII.GetString(data, start, lx._p - start);
            var op = new COp { Name = word, Operands = operands, Start = operands.Count > 0 ? operands[0].Start : start, End = lx._p };
            operands = [];
            if (word == "BI") lx.InlineImage(op);
            ops.Add(op);
        }
        return ops;
    }

    private static bool IsSpace(byte c) => c is 0 or 9 or 10 or 12 or 13 or 32;
    private static bool IsDelim(byte c) => c is (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']' or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%';
    private static bool IsRegular(byte c) => !IsSpace(c) && !IsDelim(c);

    private void SkipSpace()
    {
        while (_p < _b.Length)
        {
            var c = _b[_p];
            if (IsSpace(c)) _p++;
            else if (c == '%')
            {
                while (_p < _b.Length && _b[_p] is not (10 or 13)) _p++;
            }
            else break;
        }
    }

    /// <summary>An operand at the position, or null with the position past an operator keyword (or unchanged at a stray delimiter).</summary>
    private CObj? ReadObject(int depth = 0)
    {
        var start = _p;
        var c = _b[_p];
        switch (c)
        {
            case (byte)'/':
            {
                _p++;
                var sb = new StringBuilder();
                while (_p < _b.Length && IsRegular(_b[_p]))
                {
                    if (_b[_p] == '#' && _p + 2 < _b.Length && IsHex(_b[_p + 1]) && IsHex(_b[_p + 2]))
                    {
                        sb.Append((char)(HexVal(_b[_p + 1]) * 16 + HexVal(_b[_p + 2])));
                        _p += 3;
                    }
                    else sb.Append((char)_b[_p++]);
                }
                return new CObj { Kind = CKind.Name, Name = sb.ToString(), Start = start, End = _p };
            }
            case (byte)'(':
                return LiteralString(start);
            case (byte)'<' when _p + 1 < _b.Length && _b[_p + 1] == '<':
            {
                _p += 2;
                var d = new CObj { Kind = CKind.Dict, Start = start };
                while (true)
                {
                    SkipSpace();
                    if (_p >= _b.Length) break;
                    if (_b[_p] == '>' && _p + 1 < _b.Length && _b[_p + 1] == '>')
                    {
                        _p += 2;
                        break;
                    }
                    var at = _p;
                    var key = depth < 32 ? ReadObject(depth + 1) : null;
                    if (key is null)
                    {
                        if (_p == at) _p++;
                        continue;
                    }
                    SkipSpace();
                    if (_p >= _b.Length) break;
                    var at2 = _p;
                    var value = ReadObject(depth + 1);
                    if (value is null && _p == at2) _p++;
                    if (key.Kind == CKind.Name && value is not null) d.Entries.Add((key.Name, value));
                }
                d.End = _p;
                return d;
            }
            case (byte)'<':
            {
                _p++;
                var bytes = new List<byte>();
                int? hi = null;
                while (_p < _b.Length && _b[_p] != '>')
                {
                    var h = _b[_p++];
                    if (!IsHex(h)) continue;
                    if (hi is null) hi = HexVal(h);
                    else
                    {
                        bytes.Add((byte)(hi.Value * 16 + HexVal(h)));
                        hi = null;
                    }
                }
                if (hi is not null) bytes.Add((byte)(hi.Value * 16));
                if (_p < _b.Length) _p++;
                return new CObj { Kind = CKind.String, Bytes = [.. bytes], Hex = true, Start = start, End = _p };
            }
            case (byte)'[':
            {
                _p++;
                var a = new CObj { Kind = CKind.Array, Start = start };
                while (true)
                {
                    SkipSpace();
                    if (_p >= _b.Length) break;
                    if (_b[_p] == ']')
                    {
                        _p++;
                        break;
                    }
                    var at = _p;
                    var item = depth < 32 ? ReadObject(depth + 1) : null;
                    if (item is not null) a.Items.Add(item);
                    else if (_p == at) _p++; // a stray delimiter inside an array
                    // An operator keyword inside an array: malformed; ignore it.
                }
                a.End = _p;
                return a;
            }
            case (byte)'+' or (byte)'-' or (byte)'.' or (>= (byte)'0' and <= (byte)'9'):
            {
                var end = _p;
                while (end < _b.Length && IsRegular(_b[end])) end++;
                var text = Encoding.ASCII.GetString(_b, _p, end - _p);
                // "--5" and "5-" turn up in the wild: read what parses as a number.
                var clean = text.TrimStart('+');
                while (clean.StartsWith("--", StringComparison.Ordinal)) clean = clean[1..];
                var cut = clean.Length;
                for (var i = 1; i < clean.Length; i++) if (clean[i] is '-' or '+') { cut = i; break; }
                clean = clean[..cut];
                _p = end;
                var ok = double.TryParse(clean, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var v);
                return new CObj { Kind = CKind.Number, Num = ok && double.IsFinite(v) ? v : 0, IsInt = !clean.Contains('.'), Start = start, End = _p };
            }
            case (byte)')' or (byte)'>' or (byte)']' or (byte)'{' or (byte)'}':
                return null; // stray: the caller skips it
        }
        // A keyword: true/false/null are operands, anything else is an operator.
        var e = _p;
        while (e < _b.Length && IsRegular(_b[e])) e++;
        var word = Encoding.ASCII.GetString(_b, _p, e - _p);
        _p = e;
        return word switch
        {
            "true" or "false" => new CObj { Kind = CKind.Bool, Name = word, Start = start, End = _p },
            "null" => new CObj { Kind = CKind.Null, Name = word, Start = start, End = _p },
            _ => null,
        };
    }

    private CObj LiteralString(int start)
    {
        _p++;
        var bytes = new List<byte>();
        var depth = 1;
        while (_p < _b.Length)
        {
            var c = _b[_p++];
            if (c == '\\')
            {
                if (_p >= _b.Length) break;
                var e = _b[_p++];
                switch (e)
                {
                    case (byte)'n': bytes.Add(10); break;
                    case (byte)'r': bytes.Add(13); break;
                    case (byte)'t': bytes.Add(9); break;
                    case (byte)'b': bytes.Add(8); break;
                    case (byte)'f': bytes.Add(12); break;
                    case 13:
                        if (_p < _b.Length && _b[_p] == 10) _p++;
                        break;
                    case 10:
                        break;
                    case >= (byte)'0' and <= (byte)'7':
                    {
                        var v = e - '0';
                        for (var k = 0; k < 2 && _p < _b.Length && _b[_p] is >= (byte)'0' and <= (byte)'7'; k++) v = v * 8 + (_b[_p++] - '0');
                        bytes.Add((byte)v);
                        break;
                    }
                    default:
                        bytes.Add(e);
                        break;
                }
                continue;
            }
            if (c == '(') depth++;
            else if (c == ')' && --depth == 0) break;
            bytes.Add(c);
        }
        return new CObj { Kind = CKind.String, Bytes = [.. bytes], Start = start, End = _p };
    }

    /// <summary>BI was just read: its dictionary up to ID, then the data up to EI.</summary>
    private void InlineImage(COp op)
    {
        var dict = new CObj { Kind = CKind.Dict, Start = _p };
        while (true)
        {
            SkipSpace();
            if (_p >= _b.Length) break;
            var at = _p;
            var key = ReadObject();
            if (key is null)
            {
                if (_p == at)
                {
                    _p++;
                    continue;
                }
                var word = Encoding.ASCII.GetString(_b, at, _p - at);
                if (word == "ID") break;
                continue;
            }
            SkipSpace();
            if (_p >= _b.Length) break;
            var at2 = _p;
            var value = ReadObject();
            if (value is null && _p == at2) _p++;
            if (key.Kind == CKind.Name && value is not null) dict.Entries.Add((key.Name, value));
        }
        dict.End = _p;
        op.Operands = [dict];
        if (_p < _b.Length && IsSpace(_b[_p])) _p++; // the single white-space byte after ID
        op.DataStart = _p;
        var length = ExpectedLength(dict);
        int end;
        if (length is { } len && _p + len <= _b.Length && EiAt(_p + len, strict: false)) end = _p + len;
        else end = FindEi(_p);
        op.DataEnd = end;
        // Past the data: optional white space, then EI.
        var q = end;
        while (q < _b.Length && IsSpace(_b[q])) q++;
        if (q + 1 < _b.Length && _b[q] == 'E' && _b[q + 1] == 'I') q += 2;
        else q = _b.Length;
        _p = q;
        op.End = q;
    }

    /// <summary>The data length of an unfiltered inline image (null when filtered or unknown).</summary>
    private static int? ExpectedLength(CObj d)
    {
        if ((d["F"] ?? d["Filter"]) is { } f && !(f.Kind == CKind.Array && f.Items.Count == 0)) return null;
        var w = (d["W"] ?? d["Width"])?.Num ?? 0;
        var h = (d["H"] ?? d["Height"])?.Num ?? 0;
        var mask = (d["IM"] ?? d["ImageMask"])?.Name == "true";
        var bpc = mask ? 1 : (d["BPC"] ?? d["BitsPerComponent"])?.Num ?? 0;
        var cs = (d["CS"] ?? d["ColorSpace"]) is { Kind: CKind.Name } c ? c.Name : null;
        var comps = mask ? 1 : cs switch
        {
            "G" or "DeviceGray" or "CalGray" or "I" or "Indexed" => 1,
            "RGB" or "DeviceRGB" or "CalRGB" => 3,
            "CMYK" or "DeviceCMYK" => 4,
            _ => 0,
        };
        if (w <= 0 || h <= 0 || bpc <= 0 || comps == 0 || w * h > 1e8) return null;
        return (int)(Math.Ceiling(w * comps * bpc / 8) * h);
    }

    /// <summary>Whether white space (when <paramref name="strict"/>, required before) then "EI" and a delimiter or the end follow.</summary>
    private bool EiAt(int at, bool strict)
    {
        var q = at;
        if (strict && (q >= _b.Length || !IsSpace(_b[q]))) return false;
        while (q < _b.Length && IsSpace(_b[q])) q++;
        if (q + 1 >= _b.Length || _b[q] != 'E' || _b[q + 1] != 'I') return false;
        return q + 2 >= _b.Length || !IsRegular(_b[q + 2]);
    }

    /// <summary>
    /// The end of filtered inline-image data: the first "EI" preceded by white space and followed by white space or the
    /// end, where what comes next reads as ordinary content (no binary bytes in the next stretch).
    /// </summary>
    private int FindEi(int from)
    {
        for (var q = from; q + 2 < _b.Length + 1; q++)
        {
            if (!IsSpace(_b[q]) || q + 2 >= _b.Length || _b[q + 1] != 'E' || _b[q + 2] != 'I') continue;
            var after = q + 3;
            if (after < _b.Length && !IsSpace(_b[after]) && !IsDelim(_b[after])) continue;
            var plain = true;
            for (var k = after; k < Math.Min(_b.Length, after + 32) && plain; k++)
                plain = _b[k] is 9 or 10 or 13 or (>= 32 and < 127);
            if (plain) return q;
        }
        return _b.Length;
    }

    private static bool IsHex(byte c) => c is >= (byte)'0' and <= (byte)'9' or >= (byte)'a' and <= (byte)'f' or >= (byte)'A' and <= (byte)'F';
    private static int HexVal(byte c) => c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;

    // ---- Writing ----

    /// <summary>A literal string with the bytes escaped as needed (non-printing bytes as octal).</summary>
    public static string Literal(ReadOnlySpan<byte> bytes)
    {
        var sb = new StringBuilder(bytes.Length + 2).Append('(');
        foreach (var c in bytes)
        {
            if (c is (byte)'(' or (byte)')' or (byte)'\\') sb.Append('\\').Append((char)c);
            else if (c is >= 32 and < 127) sb.Append((char)c);
            else sb.Append('\\').Append(Convert.ToString(c, 8).PadLeft(3, '0'));
        }
        return sb.Append(')').ToString();
    }

    public static string HexString(ReadOnlySpan<byte> bytes) => "<" + Convert.ToHexString(bytes) + ">";

    public static string Number(double v)
    {
        var r = Math.Round(v, 4);
        if (Math.Abs(r) < 1e-9) return "0";
        return r.ToString("0.####", CultureInfo.InvariantCulture);
    }
}
