using System.Buffers.Binary;
using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// What an embedded font program holds, read just far enough to tell whether a glyph is really in it: subset fonts
/// keep only the glyphs the document used, so a character the PDF's tables name can still be missing from the font.
/// </summary>
internal abstract class FontProgram
{
    /// <summary>The embedded program of a font descriptor (FontFile2 TrueType, FontFile Type 1, FontFile3 CFF / OpenType), or null.</summary>
    public static FontProgram? Load(PdfDictionary? descriptor)
    {
        if (descriptor is null) return null;
        try
        {
            if (PdfObj.Dict(descriptor.Elements["/FontFile2"]) is { } ff2) return TrueTypeProgram.Read(PdfObj.StreamBytes(ff2));
            if (PdfObj.Dict(descriptor.Elements["/FontFile"]) is { } ff1) return Type1Program.Read(PdfObj.StreamBytes(ff1));
            if (PdfObj.Dict(descriptor.Elements["/FontFile3"]) is { } ff3)
            {
                var bytes = PdfObj.StreamBytes(ff3);
                return PdfObj.NameOf(ff3, "/Subtype") == "/OpenType" ? OpenType(bytes) : CffProgram.Read(bytes);
            }
        }
        catch (Exception ex) when (ex is ArgumentException or IndexOutOfRangeException or InvalidOperationException or OverflowException)
        {
            // Unreadable program: the caller falls back to the PDF's own tables.
        }
        return null;
    }

    private static FontProgram? OpenType(byte[] b)
    {
        var tables = TrueTypeProgram.Tables(b);
        if (tables is null) return null;
        if (tables.ContainsKey("glyf")) return TrueTypeProgram.Read(b);
        return tables.TryGetValue("CFF ", out var cff) ? CffProgram.Read(b.AsSpan(cff.Offset, cff.Length).ToArray()) : null;
    }
}

/// <summary>A TrueType program: glyph count, which glyphs have outlines (loca), advances (hmtx) and the cmap subtables.</summary>
internal sealed class TrueTypeProgram : FontProgram
{
    private readonly byte[] _b;
    private readonly int[] _loca;
    private readonly ushort[] _advances;
    private readonly Dictionary<(int Platform, int Encoding), int> _cmaps = [];

    public int NumGlyphs { get; }
    public double UnitsPerEm { get; }

    private TrueTypeProgram(byte[] b, int numGlyphs, double upem, int[] loca, ushort[] advances)
    {
        _b = b;
        NumGlyphs = numGlyphs;
        UnitsPerEm = upem;
        _loca = loca;
        _advances = advances;
    }

    internal static Dictionary<string, (int Offset, int Length)>? Tables(byte[] b)
    {
        if (b.Length < 12) return null;
        var s = b.AsSpan();
        var n = BinaryPrimitives.ReadUInt16BigEndian(s[4..]);
        var map = new Dictionary<string, (int, int)>();
        for (var i = 0; i < n; i++)
        {
            var rec = 12 + i * 16;
            if (rec + 16 > b.Length) break;
            var tag = Encoding.ASCII.GetString(b, rec, 4);
            var off = (int)BinaryPrimitives.ReadUInt32BigEndian(s[(rec + 8)..]);
            var len = (int)BinaryPrimitives.ReadUInt32BigEndian(s[(rec + 12)..]);
            if (off < 0 || len < 0 || off > b.Length) continue;
            map[tag] = (off, Math.Min(len, b.Length - off));
        }
        return map;
    }

    public static TrueTypeProgram? Read(byte[] b)
    {
        if (Tables(b) is not { } t || !t.TryGetValue("head", out var head) || !t.TryGetValue("maxp", out var maxp)) return null;
        var s = b.AsSpan();
        double upem = BinaryPrimitives.ReadUInt16BigEndian(s[(head.Offset + 18)..]);
        if (upem <= 0) upem = 1000;
        var longLoca = BinaryPrimitives.ReadInt16BigEndian(s[(head.Offset + 50)..]) == 1;
        var numGlyphs = BinaryPrimitives.ReadUInt16BigEndian(s[(maxp.Offset + 4)..]);
        var loca = Array.Empty<int>();
        if (t.TryGetValue("loca", out var l) && t.ContainsKey("glyf"))
        {
            var count = Math.Min(numGlyphs + 1, l.Length / (longLoca ? 4 : 2));
            loca = new int[count];
            for (var i = 0; i < count; i++)
                loca[i] = longLoca ? (int)BinaryPrimitives.ReadUInt32BigEndian(s[(l.Offset + 4 * i)..]) : 2 * BinaryPrimitives.ReadUInt16BigEndian(s[(l.Offset + 2 * i)..]);
        }
        var advances = Array.Empty<ushort>();
        if (t.TryGetValue("hhea", out var hhea) && t.TryGetValue("hmtx", out var hmtx))
        {
            var nHm = BinaryPrimitives.ReadUInt16BigEndian(s[(hhea.Offset + 34)..]);
            advances = new ushort[Math.Min(nHm, hmtx.Length / 4)];
            for (var i = 0; i < advances.Length; i++) advances[i] = BinaryPrimitives.ReadUInt16BigEndian(s[(hmtx.Offset + 4 * i)..]);
        }
        var font = new TrueTypeProgram(b, numGlyphs, upem, loca, advances);
        if (t.TryGetValue("cmap", out var cmap))
        {
            var n = BinaryPrimitives.ReadUInt16BigEndian(s[(cmap.Offset + 2)..]);
            for (var i = 0; i < n; i++)
            {
                var rec = cmap.Offset + 4 + i * 8;
                if (rec + 8 > b.Length) break;
                var platform = BinaryPrimitives.ReadUInt16BigEndian(s[rec..]);
                var encoding = BinaryPrimitives.ReadUInt16BigEndian(s[(rec + 2)..]);
                var sub = cmap.Offset + (int)BinaryPrimitives.ReadUInt32BigEndian(s[(rec + 4)..]);
                if (sub < 0 || sub + 4 > b.Length) continue;
                var format = BinaryPrimitives.ReadUInt16BigEndian(s[sub..]);
                if (format is 0 or 4 or 6 or 12) font._cmaps.TryAdd((platform, encoding), sub);
            }
        }
        return font;
    }

    public bool HasCmap(int platform, int encoding) => _cmaps.ContainsKey((platform, encoding));

    /// <summary>The (platform, encoding) of each cmap subtable read (formats 0, 4, 6 and 12).</summary>
    internal IReadOnlyCollection<(int Platform, int Encoding)> Cmaps => _cmaps.Keys;

    /// <summary>Whether the font has a Unicode cmap (3,1), (3,10) or (0,*).</summary>
    public bool HasUnicodeCmap => _cmaps.Keys.Any(k => k.Platform == 0 || k is (3, 1) or (3, 10));

    /// <summary>The glyph for a code in a cmap subtable (0: none).</summary>
    public int Lookup(int platform, int encoding, int code) => _cmaps.TryGetValue((platform, encoding), out var sub) ? Lookup(sub, code) : 0;

    /// <summary>The glyph for a code point through the best Unicode cmap (0: none).</summary>
    public int LookupUnicode(int cp)
    {
        foreach (var key in new[] { (3, 10), (0, 4), (0, 6), (3, 1), (0, 3), (0, 0), (0, 1), (0, 2) })
            if (_cmaps.TryGetValue(key, out var sub) && Lookup(sub, cp) is var g and > 0) return g;
        return 0;
    }

    private int Lookup(int sub, int code)
    {
        var s = _b.AsSpan();
        try
        {
            switch (BinaryPrimitives.ReadUInt16BigEndian(s[sub..]))
            {
                case 0:
                    return code is >= 0 and < 256 ? s[sub + 6 + code] : 0;
                case 6:
                {
                    var first = BinaryPrimitives.ReadUInt16BigEndian(s[(sub + 6)..]);
                    var count = BinaryPrimitives.ReadUInt16BigEndian(s[(sub + 8)..]);
                    return code >= first && code < first + count ? BinaryPrimitives.ReadUInt16BigEndian(s[(sub + 10 + 2 * (code - first))..]) : 0;
                }
                case 4:
                {
                    if (code > 0xFFFF) return 0;
                    var segX2 = BinaryPrimitives.ReadUInt16BigEndian(s[(sub + 6)..]);
                    var ends = sub + 14;
                    var starts = ends + segX2 + 2;
                    var deltas = starts + segX2;
                    var ranges = deltas + segX2;
                    for (var i = 0; i < segX2 / 2; i++)
                    {
                        var end = BinaryPrimitives.ReadUInt16BigEndian(s[(ends + 2 * i)..]);
                        if (code > end) continue;
                        var start = BinaryPrimitives.ReadUInt16BigEndian(s[(starts + 2 * i)..]);
                        if (code < start) return 0;
                        var delta = BinaryPrimitives.ReadInt16BigEndian(s[(deltas + 2 * i)..]);
                        var rangeAt = ranges + 2 * i;
                        var range = BinaryPrimitives.ReadUInt16BigEndian(s[rangeAt..]);
                        if (range == 0) return (code + delta) & 0xFFFF;
                        var addr = rangeAt + range + 2 * (code - start);
                        if (addr + 2 > s.Length) return 0;
                        var g = BinaryPrimitives.ReadUInt16BigEndian(s[addr..]);
                        return g == 0 ? 0 : (g + delta) & 0xFFFF;
                    }
                    return 0;
                }
                case 12:
                {
                    var count = (int)BinaryPrimitives.ReadUInt32BigEndian(s[(sub + 12)..]);
                    int lo = 0, hi = count - 1;
                    while (lo <= hi)
                    {
                        var mid = (lo + hi) / 2;
                        var g = sub + 16 + mid * 12;
                        var startCode = BinaryPrimitives.ReadUInt32BigEndian(s[g..]);
                        var endCode = BinaryPrimitives.ReadUInt32BigEndian(s[(g + 4)..]);
                        if (code < startCode) hi = mid - 1;
                        else if (code > endCode) lo = mid + 1;
                        else return (int)(BinaryPrimitives.ReadUInt32BigEndian(s[(g + 8)..]) + (uint)code - startCode);
                    }
                    return 0;
                }
            }
        }
        catch (ArgumentOutOfRangeException)
        {
            // A truncated subtable: no glyph.
        }
        return 0;
    }

    /// <summary>
    /// Whether the glyph is in the font with an outline (subsets keep the glyph's slot but drop its outline). A blank
    /// glyph (a space) has no outline, so for those only the slot is checked.
    /// </summary>
    public bool HasGlyph(int gid, bool blank)
    {
        if (gid <= 0 || gid >= NumGlyphs) return false;
        if (blank || _loca.Length == 0) return true;
        return gid + 1 < _loca.Length && _loca[gid + 1] > _loca[gid];
    }

    /// <summary>The glyph's advance in thousandths of an em (null when the font has no metrics).</summary>
    public double? Advance(int gid)
    {
        if (_advances.Length == 0 || gid < 0 || gid >= NumGlyphs) return null;
        return _advances[Math.Min(gid, _advances.Length - 1)] * 1000 / UnitsPerEm;
    }
}

/// <summary>A CFF program (FontFile3 / Type1C / CIDFontType0C): glyph names (charset) or, CID-keyed, the CIDs it holds.</summary>
internal sealed class CffProgram : FontProgram
{
    public int NumGlyphs { get; private init; }
    public bool IsCid { get; private init; }
    private readonly HashSet<string> _names = [];
    private readonly HashSet<int> _cids = [];

    public bool HasName(string name) => !IsCid && _names.Contains(name);
    public bool HasCid(int cid) => IsCid ? _cids.Contains(cid) : cid > 0 && cid < NumGlyphs;

    /// <summary>The glyph names (charset) of a name-keyed program, .notdef left out.</summary>
    internal IReadOnlyCollection<string> Names => _names;

    /// <summary>The CIDs of a CID-keyed program, 0 (.notdef) left out.</summary>
    internal IReadOnlyCollection<int> Cids => _cids;

    public static CffProgram? Read(byte[] b)
    {
        if (b.Length < 4 || b[0] != 1) return null;
        int p = b[2];
        _ = Index(b, ref p); // names
        var tops = Index(b, ref p);
        var strings = Index(b, ref p);
        if (tops.Count == 0) return null;
        var top = Dict(b, tops[0].Offset, tops[0].Offset + tops[0].Length);
        var cid = top.ContainsKey(1230);
        if (!top.TryGetValue(17, out var cs) || cs.Count == 0) return null;
        var csAt = (int)cs[0];
        var charStrings = Index(b, ref csAt);
        var n = charStrings.Count;
        var font = new CffProgram { NumGlyphs = n, IsCid = cid };
        var charset = top.TryGetValue(15, out var c) && c.Count > 0 ? (int)c[0] : 0;
        var sids = new int[n];
        if (charset > 2)
        {
            var q = charset;
            var format = b[q++];
            var gid = 1;
            while (gid < n)
            {
                if (format == 0)
                {
                    sids[gid++] = b[q] << 8 | b[q + 1];
                    q += 2;
                }
                else if (format is 1 or 2)
                {
                    var first = b[q] << 8 | b[q + 1];
                    var left = format == 1 ? b[q + 2] : b[q + 2] << 8 | b[q + 3];
                    q += format == 1 ? 3 : 4;
                    for (var k = 0; k <= left && gid < n; k++) sids[gid++] = first + k;
                }
                else return null;
            }
        }
        else if (charset == 0)
        {
            for (var gid = 1; gid < n; gid++) sids[gid] = gid; // ISOAdobe: SID = glyph index
        }
        else return font.IsCid ? null : font; // Expert charsets: names unknown here
        for (var gid = 1; gid < n; gid++)
        {
            if (cid) font._cids.Add(sids[gid]);
            else if (Sid(sids[gid], b, strings) is { } name) font._names.Add(name);
        }
        return font;
    }

    private static string? Sid(int sid, byte[] b, List<(int Offset, int Length)> strings)
    {
        if (sid < StandardStrings.Length) return StandardStrings[sid];
        if (sid < 391) return null; // expert names: not text glyphs
        var i = sid - 391;
        return i < strings.Count ? Encoding.ASCII.GetString(b, strings[i].Offset, strings[i].Length) : null;
    }

    private static List<(int Offset, int Length)> Index(byte[] b, ref int p)
    {
        var list = new List<(int, int)>();
        var count = b[p] << 8 | b[p + 1];
        p += 2;
        if (count == 0) return list;
        var offSize = b[p++];
        var at = p;
        int Off(int i)
        {
            var v = 0;
            for (var k = 0; k < offSize; k++) v = v << 8 | b[at + i * offSize + k];
            return v;
        }
        var data = p + (count + 1) * offSize - 1;
        for (var i = 0; i < count; i++)
        {
            var start = data + Off(i);
            var end = data + Off(i + 1);
            if (start < 0 || end > b.Length || end < start) throw new InvalidOperationException("Bad CFF INDEX");
            list.Add((start, end - start));
        }
        p = data + Off(count);
        return list;
    }

    /// <summary>A DICT's operators (12 x as 1200 + x) with their operands.</summary>
    private static Dictionary<int, List<double>> Dict(byte[] b, int p, int end)
    {
        var d = new Dictionary<int, List<double>>();
        var operands = new List<double>();
        while (p < end)
        {
            var v = b[p];
            if (v <= 21)
            {
                var op = v == 12 ? 1200 + b[++p] : v;
                p++;
                d[op] = operands;
                operands = [];
            }
            else if (v == 28)
            {
                operands.Add((short)(b[p + 1] << 8 | b[p + 2]));
                p += 3;
            }
            else if (v == 29)
            {
                operands.Add(b[p + 1] << 24 | b[p + 2] << 16 | b[p + 3] << 8 | b[p + 4]);
                p += 5;
            }
            else if (v == 30)
            {
                p++; // real number: nibbles until 0xf
                while (p < end && (b[p] & 0x0F) != 0x0F && (b[p] & 0xF0) != 0xF0) p++;
                p++;
                operands.Add(0);
            }
            else if (v is >= 32 and <= 246) { operands.Add(v - 139); p++; }
            else if (v is >= 247 and <= 250) { operands.Add((v - 247) * 256 + b[p + 1] + 108); p += 2; }
            else if (v is >= 251 and <= 254) { operands.Add(-(v - 251) * 256 - b[p + 1] - 108); p += 2; }
            else p++;
        }
        return d;
    }

    /// <summary>CFF standard strings 0-228 (the ISOAdobe glyph names).</summary>
    private static readonly string[] StandardStrings = (
        ".notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma " +
        "hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at " +
        "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft " +
        "a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde exclamdown cent sterling " +
        "fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl endash " +
        "dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis " +
        "perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut ogonek " +
        "caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior " +
        "logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters twosuperior " +
        "registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute " +
        "Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde " +
        "Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde " +
        "ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave ntilde oacute ocircumflex odieresis " +
        "ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron").Split(' ');

    internal static int StandardStringCount => StandardStrings.Length;
}

/// <summary>A Type 1 program (FontFile): the glyph names in its CharStrings and its built-in encoding.</summary>
internal sealed class Type1Program : FontProgram
{
    private readonly HashSet<string> _names = [];

    /// <summary>The program's own encoding (code → glyph name); null for StandardEncoding or when it can't be read.</summary>
    public string?[]? BuiltIn { get; private set; }

    public bool HasName(string name) => _names.Contains(name);

    /// <summary>The glyph names in the program's CharStrings.</summary>
    internal IReadOnlyCollection<string> Names => _names;

    public static Type1Program? Read(byte[] b)
    {
        // PFB segments (0x80 0x01 / 0x80 0x02) or a plain cleartext + binary eexec part.
        if (b.Length > 6 && b[0] == 0x80) b = Unwrap(b);
        var text = Encoding.Latin1.GetString(b);
        var eexec = text.IndexOf("eexec", StringComparison.Ordinal);
        if (eexec < 0) return null;
        var font = new Type1Program();
        font.ReadEncoding(text[..eexec]);
        var p = eexec + 5;
        while (p < b.Length && b[p] is 9 or 10 or 13 or 32) p++;
        var data = b.AsSpan(p).ToArray();
        // Hex eexec (rare): the first four bytes are hex digits.
        if (data.Length >= 4 && data.Take(4).All(c => Uri.IsHexDigit((char)c)))
        {
            var hex = new string([.. data.Select(c => (char)c).Where(Uri.IsHexDigit)]);
            data = Convert.FromHexString(hex[..(hex.Length & ~1)]);
        }
        var plain = Decrypt(data, 55665, 4);
        font.ReadCharStrings(plain);
        return font._names.Count > 0 ? font : null;
    }

    private static byte[] Unwrap(byte[] b)
    {
        using var ms = new MemoryStream();
        var p = 0;
        while (p + 6 <= b.Length && b[p] == 0x80 && b[p + 1] is 1 or 2)
        {
            var len = BinaryPrimitives.ReadInt32LittleEndian(b.AsSpan(p + 2));
            p += 6;
            if (len < 0 || p + len > b.Length) break;
            ms.Write(b, p, len);
            p += len;
        }
        return ms.ToArray();
    }

    internal static byte[] Decrypt(ReadOnlySpan<byte> data, ushort key, int skip)
    {
        var r = key;
        var o = new byte[Math.Max(0, data.Length - skip)];
        for (var i = 0; i < data.Length; i++)
        {
            var c = data[i];
            var p = (byte)(c ^ (r >> 8));
            r = (ushort)((c + r) * 52845 + 22719);
            if (i >= skip) o[i - skip] = p;
        }
        return o;
    }

    private void ReadEncoding(string clear)
    {
        var at = clear.IndexOf("/Encoding", StringComparison.Ordinal);
        if (at < 0 || clear.AsSpan(at).StartsWith("/Encoding StandardEncoding")) return;
        var enc = new string?[256];
        var any = false;
        // "dup 65 /A put" entries up to "readonly def" / "def".
        var end = clear.IndexOf(" def", at, StringComparison.Ordinal);
        var body = clear[at..(end < 0 ? clear.Length : Math.Min(clear.Length, end + 4 + 20000))];
        foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(body, @"dup\s+(\d+)\s*/([^\s/\[\]{}()<>%]+)\s+put"))
        {
            var code = int.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
            if (code is >= 0 and < 256)
            {
                enc[code] = m.Groups[2].Value;
                any = true;
            }
        }
        if (any) BuiltIn = enc;
    }

    /// <summary>Reads "/name len RD &lt;len bytes&gt; ND" entries after /CharStrings.</summary>
    private void ReadCharStrings(byte[] plain)
    {
        var text = Encoding.Latin1.GetString(plain);
        var at = text.IndexOf("/CharStrings", StringComparison.Ordinal);
        if (at < 0) return;
        var p = text.IndexOf("begin", at, StringComparison.Ordinal);
        if (p < 0) return;
        p += 5;
        while (p < plain.Length)
        {
            while (p < plain.Length && plain[p] is 9 or 10 or 13 or 32) p++;
            if (p >= plain.Length || plain[p] != '/') break; // "end": done
            var q = ++p;
            while (q < plain.Length && plain[q] is not (9 or 10 or 13 or 32)) q++;
            var name = text[p..q];
            p = q;
            while (p < plain.Length && plain[p] is 9 or 10 or 13 or 32) p++;
            var n0 = p;
            while (p < plain.Length && plain[p] is >= (byte)'0' and <= (byte)'9') p++;
            if (!int.TryParse(text.AsSpan(n0, p - n0), out var len)) break;
            while (p < plain.Length && plain[p] is 9 or 10 or 13 or 32) p++;
            while (p < plain.Length && plain[p] is not (9 or 10 or 13 or 32)) p++; // RD or -|
            p++; // the single space before the binary
            p += len;
            while (p < plain.Length && plain[p] is 9 or 10 or 13 or 32) p++;
            while (p < plain.Length && plain[p] is not (9 or 10 or 13 or 32)) p++; // ND or |-
            _names.Add(name);
        }
    }
}
