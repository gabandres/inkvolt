using System.Globalization;
using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>One glyph of a text-showing string: its code, how many bytes it took, the text it stands for and its advance (ems).</summary>
internal readonly record struct Glyph(int Code, int Length, string Text, double Width);

/// <summary>New text in a font's codes. A code of <see cref="TextFont.Gap"/> is a word space the font has no glyph for.</summary>
internal sealed record EncodedText(IReadOnlyList<int> Codes, IReadOnlyList<string> Missing);

/// <summary>
/// A page font as text editing needs it: decoding a string's bytes into glyphs (codes, Unicode text, widths) and
/// encoding new text back into the same font's codes, refusing characters the font can't draw. Simple fonts map
/// text to codes through their ToUnicode CMap, else their /Encoding (+ /Differences) and glyph names; composite fonts
/// (Type0, Identity-H) through the inverse ToUnicode CMap, else the embedded TrueType cmap. A code counts only when its
/// glyph is really in the embedded program (subset fonts keep only the glyphs the document used) and it has a width.
/// </summary>
internal sealed class TextFont
{
    /// <summary>Stands for a word space drawn as a gap (a TJ adjustment), when the font has no space glyph.</summary>
    public const int Gap = -1;

    private readonly PdfDictionary _font;
    private readonly PdfDictionary? _cidFont;
    private readonly FontProgram? _program;
    private readonly Dictionary<int, string> _toUnicode = [];
    private readonly bool _hasToUnicode;
    private readonly string?[] _names = new string?[256];
    private readonly string?[] _simpleText = new string?[256];
    private readonly double?[] _widths = new double?[256];
    private readonly Dictionary<int, double> _cidWidths = [];
    private readonly double _dw = 1000;
    private readonly double _missingWidth; // a simple font's width for codes its /Widths doesn't list
    private readonly int[]? _cidToGid; // null: identity
    private readonly bool _symbolic;
    private readonly bool _standard14;
    // Read once: checks run later, after the document they came from may be closed.
    private readonly bool _hasDescriptor, _embedded, _hasWidths;
    private readonly Dictionary<int, bool> _glyphKnown = [];
    private Dictionary<string, List<int>>? _inverse;
    private Dictionary<int, int>? _gidToCid;

    public string Name { get; }
    public bool TwoByte { get; }
    /// <summary>Why text in this font can't be edited (null: it can).</summary>
    public string? Blocked { get; }
    /// <summary>Ascent and descent in ems (descent negative).</summary>
    public double Ascent { get; } = 0.8;
    public double Descent { get; } = -0.2;
    public bool Bold { get; }
    public bool Italic { get; }
    /// <summary>The descriptor's /Flags (1 fixed pitch, 2 serif, 64 italic, …); 0 without a descriptor.</summary>
    public int Flags { get; }
    /// <summary>The descriptor's x-height in ems, when it gives one.</summary>
    public double? XHeight { get; }

    private TextFont(PdfDictionary font)
    {
        _font = font;
        var subtype = PdfObj.NameOf(font, "/Subtype");
        Name = (PdfObj.Name(font.Elements["/BaseFont"]) ?? "").Trim();
        if (Name.Length > 7 && Name[6] == '+' && Name.Take(6).All(char.IsAsciiLetterUpper)) Name = Name[7..];
        Name = Name.Replace(',', ' '); // "Arial,Bold" → "Arial Bold"
        if (PdfObj.Dict(font.Elements["/ToUnicode"]) is { Stream: not null } tu)
        {
            ReadCMap(PdfObj.StreamBytes(tu), _toUnicode);
            _hasToUnicode = _toUnicode.Count > 0;
        }

        PdfDictionary? descriptor;
        if (subtype == "/Type0")
        {
            TwoByte = true;
            _cidFont = PdfObj.Array(font.Elements["/DescendantFonts"]) is { Elements.Count: > 0 } df ? PdfObj.Dict(df.Elements[0]) : null;
            descriptor = _cidFont is null ? null : PdfObj.Dict(_cidFont.Elements["/FontDescriptor"]);
            var encoding = PdfObj.Name(font.Elements["/Encoding"]);
            if (_cidFont is null) Blocked = "its font is damaged";
            else if (encoding == "Identity-V") Blocked = "it is vertical text";
            else if (encoding != "Identity-H")
            {
                Blocked = "its font uses a character map (CMap) that can't be written to yet";
                TwoByte = encoding is { } e && (e.Contains("UCS2", StringComparison.Ordinal) || e.Contains("UTF16", StringComparison.Ordinal));
            }
            if (_cidFont is not null)
            {
                _dw = PdfObj.Num(_cidFont.Elements["/DW"], 1000);
                ReadW(PdfObj.Array(_cidFont.Elements["/W"]));
                if (PdfObj.Dict(_cidFont.Elements["/CIDToGIDMap"]) is { Stream: not null } map)
                {
                    var b = PdfObj.StreamBytes(map);
                    _cidToGid = new int[b.Length / 2];
                    for (var i = 0; i < _cidToGid.Length; i++) _cidToGid[i] = b[2 * i] << 8 | b[2 * i + 1];
                }
            }
            if (Blocked is null && !_hasToUnicode) Blocked = "its font doesn't say which characters its glyphs are";
        }
        else
        {
            descriptor = PdfObj.Dict(font.Elements["/FontDescriptor"]);
            if (subtype == "/Type3") Blocked = "it is drawn with a Type 3 font (glyphs drawn as pictures)";
            var first = (int)PdfObj.Num(font.Elements["/FirstChar"], 0);
            if (PdfObj.Array(font.Elements["/Widths"]) is { } widths)
                for (var i = 0; i < widths.Elements.Count; i++)
                    if (first + i is >= 0 and < 256) _widths[first + i] = PdfObj.Num(widths.Elements[i]);
            var plain = StripStyle(Name);
            _standard14 = descriptor is null && plain is "Helvetica" or "Arial" or "Times" or "TimesNewRoman" or "Times-Roman" or "Courier" or "CourierNew";
            if (descriptor is null && (Name.StartsWith("Symbol", StringComparison.Ordinal) || Name.StartsWith("ZapfDingbats", StringComparison.Ordinal)))
                Blocked ??= "its font is a symbol font";
        }

        _hasDescriptor = descriptor is not null;
        _embedded = descriptor is not null && Embedded(descriptor);
        _hasWidths = PdfObj.Array(font.Elements["/Widths"]) is not null;
        var flags = descriptor is null ? 0 : (int)PdfObj.Num(descriptor.Elements["/Flags"]);
        Flags = flags;
        if (descriptor is not null && PdfObj.Num(descriptor.Elements["/XHeight"]) is var xh and > 0 and < 1500) XHeight = xh / 1000;
        _symbolic = (flags & 4) != 0 && (flags & 32) == 0;
        if (descriptor is not null)
        {
            var asc = PdfObj.Num(descriptor.Elements["/Ascent"]);
            var desc = PdfObj.Num(descriptor.Elements["/Descent"]);
            if (asc > 0) Ascent = Math.Min(asc, 1500) / 1000;
            if (desc < 0) Descent = Math.Max(desc, -1000) / 1000;
            else if (desc > 0) Descent = -Math.Min(desc, 1000) / 1000; // positive descents turn up (PDFsharp writes them)
            _program = FontProgram.Load(descriptor);
            _missingWidth = PdfObj.Num(descriptor.Elements["/MissingWidth"]);
        }
        Bold = FontNames.LooksBold(Name) || (flags & 0x40000) != 0;
        Italic = FontNames.LooksItalic(Name) || (flags & 64) != 0;
        if (!TwoByte) ReadSimpleEncoding(PdfObj.NameOf(font, "/Subtype"));
    }

    private static string StripStyle(string name)
    {
        var cut = name.IndexOfAny([',', '-', ' ']);
        var n = cut > 0 ? name[..cut] : name;
        return name.StartsWith("Times-Roman", StringComparison.Ordinal) ? "Times-Roman" : n;
    }

    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<PdfDictionary, TextFont> Cache = new();

    public static TextFont For(PdfDictionary font) => Cache.GetValue(font, f => new TextFont(f));

    // ---- Reading ----

    private void ReadSimpleEncoding(string subtype)
    {
        string? baseEncoding = null;
        PdfArray? differences = null;
        switch (PdfObj.Resolve(_font.Elements["/Encoding"]))
        {
            case PdfName n:
                baseEncoding = n.Value.TrimStart('/');
                break;
            case PdfDictionary d:
                baseEncoding = PdfObj.Name(d.Elements["/BaseEncoding"]);
                differences = PdfObj.Array(d.Elements["/Differences"]);
                break;
        }
        var builtIn = (_program as Type1Program)?.BuiltIn;
        if (baseEncoding is null || !GlyphNames.IsKnownEncoding(baseEncoding))
        {
            // No (usable) base encoding: the font's own. Type 1 programs carry one; otherwise Standard for text fonts.
            baseEncoding = builtIn is not null || (_symbolic && subtype == "/TrueType") ? null : "StandardEncoding";
        }
        for (var c = 0; c < 256; c++) _names[c] = baseEncoding is null ? builtIn?[c] : GlyphNames.InEncoding(baseEncoding, c);
        if (differences is not null)
        {
            var code = 0;
            foreach (var item in differences.Elements)
            {
                switch (PdfObj.Resolve(item))
                {
                    case PdfInteger i:
                        code = i.Value;
                        break;
                    case PdfName name:
                        if (code is >= 0 and < 256) _names[code] = name.Value.TrimStart('/');
                        code++;
                        break;
                }
            }
        }
        for (var c = 0; c < 256; c++)
            _simpleText[c] = _toUnicode.TryGetValue(c, out var t) ? t : _names[c] is { } n ? GlyphNames.ToUnicode(n) : null;
    }

    private void ReadW(PdfArray? w)
    {
        if (w is null) return;
        var e = w.Elements;
        for (var i = 0; i < e.Count;)
        {
            var first = PdfObj.Int(e[i]);
            if (first is null) break;
            if (i + 1 < e.Count && PdfObj.Array(e[i + 1]) is { } list)
            {
                for (var k = 0; k < list.Elements.Count; k++) _cidWidths[first.Value + k] = PdfObj.Num(list.Elements[k]);
                i += 2;
            }
            else if (i + 2 < e.Count && PdfObj.Int(e[i + 1]) is { } last)
            {
                var width = PdfObj.Num(e[i + 2]);
                for (var c = first.Value; c <= last && c - first.Value < 65536; c++) _cidWidths[c] = width;
                i += 3;
            }
            else break;
        }
    }

    /// <summary>Reads a ToUnicode CMap's bfchar and bfrange entries (codes as integers, targets as UTF-16BE text).</summary>
    internal static void ReadCMap(byte[] data, Dictionary<int, string> into)
    {
        foreach (var op in ContentLexer.Parse(data))
        {
            var o = op.Operands;
            if (op.Name == "endbfchar")
            {
                for (var i = 0; i + 1 < o.Count; i += 2)
                    if (o[i].Kind == CKind.String && o[i + 1] is var dst)
                        if (Target(dst) is { } t) into[Code(o[i].Bytes)] = t;
            }
            else if (op.Name == "endbfrange")
            {
                for (var i = 0; i + 2 < o.Count; i += 3)
                {
                    if (o[i].Kind != CKind.String || o[i + 1].Kind != CKind.String) continue;
                    int lo = Code(o[i].Bytes), hi = Code(o[i + 1].Bytes);
                    if (hi < lo || hi - lo > 65535 || into.Count > 200_000) continue;
                    if (o[i + 2].Kind == CKind.Array)
                    {
                        for (var k = 0; k < o[i + 2].Items.Count && lo + k <= hi; k++)
                            if (Target(o[i + 2].Items[k]) is { } t) into[lo + k] = t;
                    }
                    else if (o[i + 2].Kind == CKind.String && o[i + 2].Bytes.Length >= 2)
                    {
                        var start = o[i + 2].Bytes;
                        for (var c = lo; c <= hi; c++)
                        {
                            var b = (byte[])start.Clone();
                            // The last byte counts up (carrying into the one before, as most readers do).
                            var add = c - lo;
                            var v = (b[^2] << 8 | b[^1]) + add;
                            b[^2] = (byte)(v >> 8);
                            b[^1] = (byte)v;
                            into[c] = Encoding.BigEndianUnicode.GetString(b);
                        }
                    }
                }
            }
        }
    }

    private static int Code(byte[] b)
    {
        var v = 0;
        foreach (var x in b.Take(4)) v = v << 8 | x;
        return v;
    }

    private static string? Target(CObj o)
    {
        if (o.Kind == CKind.Name) return GlyphNames.ToUnicode(o.Name);
        if (o.Kind != CKind.String || o.Bytes.Length == 0) return null;
        if (o.Bytes.Length == 1) return ((char)o.Bytes[0]).ToString();
        var s = Encoding.BigEndianUnicode.GetString(o.Bytes, 0, o.Bytes.Length & ~1);
        return s.Length == 0 ? null : s;
    }

    /// <summary>The glyphs a string shows (1-byte codes for simple fonts, 2-byte for composite ones).</summary>
    public List<Glyph> Decode(ReadOnlySpan<byte> bytes)
    {
        var list = new List<Glyph>(bytes.Length);
        if (TwoByte)
        {
            for (var i = 0; i + 1 < bytes.Length; i += 2)
            {
                var code = bytes[i] << 8 | bytes[i + 1];
                list.Add(new Glyph(code, 2, TextOf(code) ?? "�", WidthOf(code) / 1000));
            }
        }
        else
        {
            foreach (var code in bytes) list.Add(new Glyph(code, 1, TextOf(code) ?? "�", WidthOf(code) / 1000));
        }
        return list;
    }

    private string? TextOf(int code) => TwoByte ? _toUnicode.GetValueOrDefault(code) : code is >= 0 and < 256 ? _simpleText[code] : null;

    /// <summary>A code's width in thousandths of an em (as the PDF says, else the program's, else a fallback).</summary>
    public double WidthOf(int code)
    {
        if (TwoByte) return _cidWidths.TryGetValue(code, out var w) ? w : ProgramAdvance(code) ?? _dw;
        if (code is >= 0 and < 256 && _widths[code] is > 0 and var sw) return sw;
        if (ProgramAdvance(code) is { } pa) return pa;
        if (_standard14 && _simpleText[code] is { Length: 1 } t) return StdFont.FromName(Name).Advance(t[0]) * 1000;
        return code is >= 0 and < 256 && _widths[code] is { } z ? z : _hasWidths ? _missingWidth : 500;
    }

    private bool HasWidth(int code) => TwoByte ? _cidWidths.ContainsKey(code) : code is >= 0 and < 256 && _widths[code] is > 0;

    // ---- Glyphs ----

    private int GidOf(int code)
    {
        if (_program is not TrueTypeProgram tt) return -1;
        if (TwoByte) return _cidToGid is null ? code : code < _cidToGid.Length ? _cidToGid[code] : 0;
        // PDF 32000 9.6.6.4: a (3,1) cmap is reached through the glyph name's Unicode value, else (3,0) and (1,0) by code.
        // (A Unicode-platform cmap, (0,*), is read the same way: some Mac fonts have only that.)
        if (tt.HasUnicodeCmap && !_symbolic)
        {
            var text = _names[code] is { } n ? GlyphNames.ToUnicode(n) : _simpleText[code];
            if (text is { Length: > 0 } && char.IsSurrogate(text, 0) == char.IsSurrogatePair(text, 0) && tt.LookupUnicode(char.ConvertToUtf32(text, 0)) is var g and > 0) return g;
        }
        if (tt.HasCmap(3, 0))
            foreach (var c in new[] { code, 0xF000 + code, 0xF100 + code, 0xF200 + code })
                if (tt.Lookup(3, 0, c) is var g and > 0) return g;
        // A (1,0) Mac cmap is reached through the glyph name's Mac Roman code (9.6.6.4); a symbolic font's by the code itself.
        if (tt.HasCmap(1, 0) && !_symbolic && _names[code] is { } macName && MacCode(macName) is { } mc && tt.Lookup(1, 0, mc) is var mg and > 0) return mg;
        if (tt.HasCmap(1, 0) && tt.Lookup(1, 0, code) is var m and > 0) return m;
        if (tt.HasCmap(3, 1) && _simpleText[code] is { Length: > 0 } st && tt.Lookup(3, 1, char.ConvertToUtf32(st, 0)) is var u and > 0) return u;
        return 0;
    }

    private static readonly Lazy<Dictionary<string, int>> MacCodes = new(() =>
    {
        var map = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var c = 0; c < 256; c++)
            if (GlyphNames.InEncoding("MacRomanEncoding", c) is { } n) map.TryAdd(n, c);
        return map;
    });

    private static int? MacCode(string glyphName) => MacCodes.Value.TryGetValue(glyphName, out var c) ? c : null;

    private double? ProgramAdvance(int code) => _program is TrueTypeProgram tt && GidOf(code) is var g and > 0 ? tt.Advance(g) : null;

    // ---- What the accessibility check reads (AccessibilityCheck.Fonts) ----

    /// <summary>The embedded program, when it could be read.</summary>
    internal FontProgram? Program => _program;

    /// <summary>A code's glyph in an embedded TrueType program (0: .notdef), or -1 when the program isn't TrueType.</summary>
    internal int GlyphIdOf(int code) => GidOf(code);

    /// <summary>A simple font's glyph name for a code (from its encoding and /Differences), or null.</summary>
    internal string? GlyphNameOf(int code) => !TwoByte && code is >= 0 and < 256 ? _names[code] : null;

    /// <summary>The Unicode text a code stands for (ToUnicode, else the glyph name), or null when it can't be told.</summary>
    internal string? UnicodeOf(int code) => TextOf(code);

    /// <summary>The ToUnicode CMap's own value for a code, or null when it has none.</summary>
    internal string? ToUnicodeOf(int code) => _toUnicode.GetValueOrDefault(code);

    /// <summary>The width the PDF itself gives a code (/Widths or /W), or null.</summary>
    internal double? DictionaryWidth(int code) =>
        TwoByte ? (_cidWidths.TryGetValue(code, out var w) ? w : _cidFont is not null ? _dw : null)
        : code is >= 0 and < 256 ? _widths[code] : null;

    /// <summary>A code's advance in the embedded TrueType program, in thousandths of an em, or null.</summary>
    internal double? ProgramWidth(int code) => _program is TrueTypeProgram tt && GidOf(code) is var g and >= 0 && g < tt.NumGlyphs ? tt.Advance(g) : null;

    /// <summary>Whether the font can draw a code: its glyph is in the embedded program, or the font isn't embedded.</summary>
    public bool HasGlyph(int code)
    {
        if (_glyphKnown.TryGetValue(code, out var known)) return known;
        var blank = TextOf(code) is { } t && t.All(char.IsWhiteSpace);
        bool has;
        if (TwoByte)
        {
            has = _program switch
            {
                TrueTypeProgram tt => tt.HasGlyph(GidOf(code), blank),
                CffProgram cff => cff.HasCid(code),
                _ => _toUnicode.ContainsKey(code) && HasWidth(code), // not embedded or unreadable: only codes the font already maps
            };
        }
        else if (code is < 0 or > 255) has = false;
        else
        {
            var name = _names[code];
            has = _program switch
            {
                TrueTypeProgram tt => tt.HasGlyph(GidOf(code), blank),
                Type1Program t1 when name is not null => t1.HasName(name),
                CffProgram { IsCid: false } cff when name is not null && cff.HasName(name) => true,
                CffProgram { IsCid: false } when name is not null => false,
                null when _hasDescriptor && !_embedded => name is not null || _simpleText[code] is not null,
                null when !_hasDescriptor => name is not null,
                _ => HasWidth(code) && (!_hasToUnicode || _toUnicode.ContainsKey(code)), // program unreadable: the PDF's tables
            };
            // A width is needed to place it; an embedded TrueType glyph's width can be added from the program.
            if (has && !HasWidth(code) && !(_standard14 && !_hasWidths) && ProgramAdvance(code) is null) has = false;
        }
        _glyphKnown[code] = has;
        return has;
    }

    private static bool Embedded(PdfDictionary descriptor) =>
        descriptor.Elements.ContainsKey("/FontFile") || descriptor.Elements.ContainsKey("/FontFile2") || descriptor.Elements.ContainsKey("/FontFile3");

    // ---- Encoding ----

    private Dictionary<string, List<int>> Inverse()
    {
        if (_inverse is not null) return _inverse;
        var inv = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        void Add(string text, int code)
        {
            text = text.Normalize(NormalizationForm.FormC);
            if (!inv.TryGetValue(text, out var list)) inv[text] = list = [];
            if (!list.Contains(code)) list.Add(code);
        }
        if (TwoByte)
        {
            foreach (var (code, text) in _toUnicode) Add(text, code);
        }
        else
        {
            for (var c = 0; c < 256; c++) if (_simpleText[c] is { Length: > 0 } t) Add(t, c);
        }
        return _inverse = inv;
    }

    /// <summary>
    /// The codes for <paramref name="text"/>, longest match first (ligatures such as "fi" when the font maps one), or the
    /// characters the font can't draw. A space the font has no glyph for becomes a <see cref="Gap"/>.
    /// </summary>
    public EncodedText Encode(string text)
    {
        var codes = new List<int>();
        var missing = new List<string>();
        var inv = Inverse();
        text = text.Normalize(NormalizationForm.FormC);
        for (var i = 0; i < text.Length;)
        {
            var found = false;
            for (var len = Math.Min(4, text.Length - i); len >= 1 && !found; len--)
            {
                if (len < text.Length - i && char.IsHighSurrogate(text[i + len - 1])) continue; // don't split a pair
                var key = text.Substring(i, len);
                if (inv.TryGetValue(key, out var list) && list.FirstOrDefault(HasGlyph, -1) is var code and >= 0)
                {
                    codes.Add(code);
                    i += len;
                    found = true;
                }
            }
            if (found) continue;
            var step = char.IsHighSurrogate(text[i]) && i + 1 < text.Length ? 2 : 1;
            var ch = text.Substring(i, step);
            if (FromProgram(ch) is { } c2) codes.Add(c2);
            else if (ch.Length == 1 && char.IsWhiteSpace(ch[0])) codes.Add(Gap);
            else if (!missing.Contains(ch)) missing.Add(ch);
            i += step;
        }
        return new EncodedText(codes, missing);
    }

    /// <summary>A composite TrueType font's code for a character through the program's own Unicode cmap (the PDF doesn't map it yet).</summary>
    private int? FromProgram(string ch)
    {
        if (!TwoByte || Blocked is not null || _program is not TrueTypeProgram { HasUnicodeCmap: true } tt) return null;
        var gid = tt.LookupUnicode(char.ConvertToUtf32(ch, 0));
        if (gid <= 0) return null;
        int cid;
        if (_cidToGid is null) cid = gid;
        else
        {
            if (_gidToCid is null)
            {
                _gidToCid = [];
                for (var c = _cidToGid.Length - 1; c >= 0; c--) _gidToCid[_cidToGid[c]] = c;
            }
            if (!_gidToCid.TryGetValue(gid, out cid)) return null;
        }
        if (cid > 0xFFFF || !tt.HasGlyph(gid, char.IsWhiteSpace(ch, 0))) return null;
        return cid;
    }

    public byte[] ToBytes(IEnumerable<int> codes)
    {
        var list = new List<byte>();
        foreach (var c in codes)
        {
            if (c < 0) continue;
            if (TwoByte) list.Add((byte)(c >> 8));
            list.Add((byte)c);
        }
        return [.. list];
    }

    /// <summary>The advance of codes in ems, as <see cref="Decode"/> would give it, plus <paramref name="gap"/> ems per <see cref="Gap"/>.</summary>
    public double Advance(IEnumerable<int> codes, double gap) => codes.Sum(c => c == Gap ? gap : WidthOf(c) / 1000);

    /// <summary>
    /// Before codes the PDF didn't use are written: their widths go into /Widths or /W (from the program), and their
    /// text into the ToUnicode CMap, so the new text is spaced right and still copies and searches as typed.
    /// </summary>
    public void Prepare(PdfDocument doc, IReadOnlyList<int> codes, string text)
    {
        var fresh = codes.Where(c => c >= 0).Distinct().Where(c => !HasWidth(c) || (_hasToUnicode && !_toUnicode.ContainsKey(c))).ToList();
        if (fresh.Count == 0) return;
        var needW = fresh.Where(c => !HasWidth(c) && ProgramAdvance(c) is not null).ToList();
        if (needW.Count > 0)
        {
            if (TwoByte && _cidFont is not null)
            {
                var w = PdfObj.Array(_cidFont.Elements["/W"]) is { } old ? new PdfArray(doc, [.. old.Elements]) : new PdfArray(doc);
                foreach (var c in needW)
                {
                    var adv = Math.Round(ProgramAdvance(c)!.Value);
                    w.Elements.Add(new PdfInteger(c));
                    w.Elements.Add(new PdfArray(doc, new PdfInteger((int)adv)));
                    _cidWidths[c] = adv;
                }
                _cidFont.Elements["/W"] = w;
            }
            else if (!TwoByte)
            {
                foreach (var c in needW) _widths[c] = Math.Round(ProgramAdvance(c)!.Value);
                var first = Enumerable.Range(0, 256).First(c => _widths[c] is not null);
                var last = Enumerable.Range(0, 256).Last(c => _widths[c] is not null);
                var arr = new PdfArray(doc);
                // Codes in between that the old range didn't cover keep the width viewers gave them: /MissingWidth.
                for (var c = first; c <= last; c++) arr.Elements.Add(new PdfInteger((int)Math.Round(_widths[c] ?? _missingWidth)));
                _font.Elements["/FirstChar"] = new PdfInteger(first);
                _font.Elements["/LastChar"] = new PdfInteger(last);
                _font.Elements["/Widths"] = arr;
            }
        }
        var needU = fresh.Where(c => _hasToUnicode && !_toUnicode.ContainsKey(c)).ToList();
        if (needU.Count > 0 && PdfObj.Dict(_font.Elements["/ToUnicode"]) is { Stream: not null } tu)
        {
            // The text each new code stands for: what Encode matched it with.
            var map = CodeTexts(codes, text);
            var sb = new StringBuilder($"\n{needU.Count} beginbfchar\n");
            foreach (var c in needU)
            {
                if (!map.TryGetValue(c, out var t)) continue;
                sb.Append('<').Append(TwoByte ? c.ToString("X4", CultureInfo.InvariantCulture) : c.ToString("X2", CultureInfo.InvariantCulture)).Append("> <")
                  .Append(Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(t))).Append(">\n");
                _toUnicode[c] = t;
            }
            sb.Append("endbfchar\n");
            var bytes = PdfObj.StreamBytes(tu);
            var s = Encoding.Latin1.GetString(bytes);
            var at = s.LastIndexOf("endcmap", StringComparison.Ordinal);
            if (at >= 0)
            {
                s = s[..at] + sb + s[at..];
                tu.Stream.Value = Encoding.Latin1.GetBytes(s);
                tu.Elements.Remove("/Filter");
                tu.Elements.Remove("/DecodeParms");
                tu.Elements["/Length"] = new PdfInteger(tu.Stream.Value.Length);
                _inverse = null;
            }
        }
    }

    /// <summary>Which text each code of an encoding stands for (codes from the program's cmap stand for one character).</summary>
    private Dictionary<int, string> CodeTexts(IReadOnlyList<int> codes, string text)
    {
        var map = new Dictionary<int, string>();
        var inv = Inverse();
        text = text.Normalize(NormalizationForm.FormC);
        var i = 0;
        foreach (var c in codes)
        {
            if (i >= text.Length) break;
            var matched = false;
            for (var len = Math.Min(4, text.Length - i); len >= 1 && !matched; len--)
            {
                if (inv.TryGetValue(text.Substring(i, len), out var list) && list.Contains(c))
                {
                    i += len;
                    matched = true;
                }
            }
            if (matched) continue;
            var step = char.IsHighSurrogate(text[i]) && i + 1 < text.Length ? 2 : 1;
            if (c >= 0) map.TryAdd(c, text.Substring(i, step));
            i += step;
        }
        return map;
    }
}
