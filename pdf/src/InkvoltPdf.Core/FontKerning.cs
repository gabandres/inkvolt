using System.Buffers.Binary;
using System.Runtime.CompilerServices;

namespace InkvoltPdf.Core;

/// <summary>
/// A font program's own pair kerning (roadmap 2.1): the pair adjustments of the GPOS table's 'kern' feature (pair
/// positioning formats 1 and 2, through extension lookups too), else the 'kern' table's first horizontal format 0
/// subtable, by glyph index, in font units. Read lazily from an sfnt's bytes; every offset and count is checked against
/// them and the lookups and subtables read are bounded, since an embedded program is hostile input.
/// </summary>
internal sealed class PairKerning
{
    private const int MaxLookups = 64, MaxSubtables = 1024, MaxCached = 65_536;

    private readonly byte[] _b;
    /// <summary>Each 'kern' lookup's pair positioning subtables (absolute offsets), in lookup order.</summary>
    private readonly List<List<int>> _lookups;
    /// <summary>The 'kern' table's format 0 pairs: where the first is and how many there are (none: count 0).</summary>
    private readonly (int At, int Count) _pairs;
    private readonly Dictionary<(int, int), int> _cache = [];
    private readonly Lock _gate = new();

    public double UnitsPerEm { get; }

    private PairKerning(byte[] b, double upem, List<List<int>> lookups, (int, int) pairs)
    {
        _b = b;
        UnitsPerEm = upem;
        _lookups = lookups;
        _pairs = pairs;
    }

    /// <summary>The kerning an sfnt (TrueType or OpenType) holds, or null when it holds none that can be read.</summary>
    public static PairKerning? Read(byte[] sfnt)
    {
        try
        {
            if (TrueTypeProgram.Tables(sfnt) is not { } tables || !tables.TryGetValue("head", out var head) || head.Length < 20) return null;
            double upem = U16(sfnt, head.Offset + 18);
            if (upem is < 16 or > 16384) return null;
            var lookups = tables.TryGetValue("GPOS", out var gpos) ? KernLookups(sfnt, gpos.Offset, gpos.Length) : [];
            (int, int) pairs = default;
            if (lookups.Count == 0 && tables.TryGetValue("kern", out var kern)) pairs = KernPairs(sfnt, kern.Offset, kern.Length);
            return lookups.Count > 0 || pairs.Item2 > 0 ? new PairKerning(sfnt, upem, lookups, pairs) : null;
        }
        catch (Exception ex) when (ex is ArgumentException or IndexOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>The adjustment between two glyphs, in font units (negative: closer); 0 when the font has none.</summary>
    public int Kern(int left, int right)
    {
        if (left is <= 0 or > 0xFFFF || right is <= 0 or > 0xFFFF) return 0;
        lock (_gate)
        {
            if (_cache.TryGetValue((left, right), out var known)) return known;
            int k;
            try
            {
                k = _lookups.Count > 0 ? _lookups.Sum(l => FromLookup(l, left, right)) : FromKernTable(left, right);
            }
            catch (Exception ex) when (ex is ArgumentException or IndexOutOfRangeException)
            {
                k = 0;
            }
            if (_cache.Count < MaxCached) _cache[(left, right)] = k;
            return k;
        }
    }

    private static int U16(byte[] b, int at) => at < 0 || at + 2 > b.Length ? throw new ArgumentException("past the font's end") : BinaryPrimitives.ReadUInt16BigEndian(b.AsSpan(at));
    private static int I16(byte[] b, int at) => at < 0 || at + 2 > b.Length ? throw new ArgumentException("past the font's end") : BinaryPrimitives.ReadInt16BigEndian(b.AsSpan(at));
    private static long U32(byte[] b, int at) => at < 0 || at + 4 > b.Length ? throw new ArgumentException("past the font's end") : BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(at));

    /// <summary>The pair positioning subtables of the lookups the GPOS table's 'kern' features name, in lookup order.</summary>
    private static List<List<int>> KernLookups(byte[] b, int g, int length)
    {
        var result = new List<List<int>>();
        if (length < 10 || U16(b, g) != 1) return result;
        var features = g + U16(b, g + 6);
        var lookupList = g + U16(b, g + 8);
        var wanted = new SortedSet<int>();
        var count = U16(b, features);
        bool Kern(int i) => i < count && features + 2 + 6 * i + 6 <= b.Length && b[features + 2 + 6 * i] == 'k' && b[features + 3 + 6 * i] == 'e'
                            && b[features + 4 + 6 * i] == 'r' && b[features + 5 + 6 * i] == 'n';
        void Add(int i)
        {
            var feature = features + U16(b, features + 2 + 6 * i + 4);
            var n = U16(b, feature + 2);
            for (var k = 0; k < n && wanted.Count < MaxLookups; k++) wanted.Add(U16(b, feature + 4 + 2 * k));
        }
        // Only the features of one language system, as a shaper applies them to Latin text: the default script's
        // (DFLT), else Latin's (latn), else the first script's; its default language, else its first one. Another
        // script's or language's kern feature may hold the same pairs again.
        var langSys = DefaultLangSys(b, g + U16(b, g + 4));
        if (langSys >= 0)
        {
            var n = U16(b, langSys + 4);
            for (var k = 0; k < n; k++)
                if (U16(b, langSys + 6 + 2 * k) is var i && Kern(i)) Add(i);
        }
        else
        {
            // No script list to choose by: the first kern feature.
            for (var i = 0; i < count; i++)
                if (Kern(i))
                {
                    Add(i);
                    break;
                }
        }
        var lookups = U16(b, lookupList);
        var subtables = 0;
        foreach (var index in wanted)
        {
            if (index >= lookups) continue;
            var lookup = lookupList + U16(b, lookupList + 2 + 2 * index);
            var type = U16(b, lookup);
            var n = U16(b, lookup + 4);
            var list = new List<int>();
            for (var k = 0; k < n && subtables < MaxSubtables; k++, subtables++)
            {
                var sub = lookup + U16(b, lookup + 6 + 2 * k);
                if (type == 9 && U16(b, sub) == 1 && U16(b, sub + 2) == 2) sub += (int)Math.Min(U32(b, sub + 4), int.MaxValue / 2);
                else if (type != 2) continue;
                if (sub > 0 && sub + 10 <= b.Length && U16(b, sub) is 1 or 2) list.Add(sub);
            }
            if (list.Count > 0) result.Add(list);
        }
        return result;
    }

    /// <summary>The language system whose features apply (DFLT, else latn, else the first script; its default, else its first), or -1.</summary>
    private static int DefaultLangSys(byte[] b, int scripts)
    {
        var n = U16(b, scripts);
        if (n == 0) return -1;
        int? Find(string tag)
        {
            for (var i = 0; i < n; i++)
            {
                var rec = scripts + 2 + 6 * i;
                if (rec + 6 > b.Length) return null;
                if (b[rec] == tag[0] && b[rec + 1] == tag[1] && b[rec + 2] == tag[2] && b[rec + 3] == tag[3]) return scripts + U16(b, rec + 4);
            }
            return null;
        }
        var script = Find("DFLT") ?? Find("latn") ?? scripts + U16(b, scripts + 6);
        var def = U16(b, script);
        if (def != 0) return script + def;
        return U16(b, script + 2) > 0 ? script + U16(b, script + 4 + 4) : -1;
    }

    /// <summary>A lookup's adjustment for a pair: its first subtable that covers the pair decides.</summary>
    private int FromLookup(List<int> subtables, int left, int right)
    {
        foreach (var sub in subtables)
        {
            var at = Coverage(sub + U16(_b, sub + 2), left);
            if (at < 0) continue;
            int vf1 = U16(_b, sub + 4), vf2 = U16(_b, sub + 6);
            int size1 = 2 * System.Numerics.BitOperations.PopCount((uint)(vf1 & 0xFF)), size2 = 2 * System.Numerics.BitOperations.PopCount((uint)(vf2 & 0xFF));
            // The first glyph's x advance is what kerning sets (other fields move glyphs, not the pen).
            var advance = (vf1 & 4) == 0 ? -1 : 2 * System.Numerics.BitOperations.PopCount((uint)(vf1 & 3));
            if (U16(_b, sub) == 1)
            {
                var sets = U16(_b, sub + 8);
                if (at >= sets) continue;
                var set = sub + U16(_b, sub + 10 + 2 * at);
                var n = U16(_b, set);
                var rec = 2 + size1 + size2;
                // Pair value records sorted by the second glyph.
                int lo = 0, hi = n - 1;
                while (lo <= hi)
                {
                    var mid = (lo + hi) >>> 1;
                    var r = set + 2 + rec * mid;
                    var second = U16(_b, r);
                    if (second == right) return advance < 0 ? 0 : I16(_b, r + 2 + advance);
                    if (second < right) lo = mid + 1;
                    else hi = mid - 1;
                }
            }
            else
            {
                var c1 = ClassOf(sub + U16(_b, sub + 8), left);
                var c2 = ClassOf(sub + U16(_b, sub + 10), right);
                int n1 = U16(_b, sub + 12), n2 = U16(_b, sub + 14);
                if (c1 >= n1 || c2 >= n2) continue;
                if (advance < 0) return 0;
                var r = sub + 16 + ((long)c1 * n2 + c2) * (size1 + size2);
                return r + advance + 2 <= _b.Length ? I16(_b, (int)r + advance) : 0;
            }
        }
        return 0;
    }

    /// <summary>A glyph's index in a coverage table, or -1.</summary>
    private int Coverage(int table, int glyph)
    {
        var format = U16(_b, table);
        var n = U16(_b, table + 2);
        int lo = 0, hi = n - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) >>> 1;
            if (format == 1)
            {
                var g = U16(_b, table + 4 + 2 * mid);
                if (g == glyph) return mid;
                if (g < glyph) lo = mid + 1;
                else hi = mid - 1;
            }
            else if (format == 2)
            {
                var r = table + 4 + 6 * mid;
                int start = U16(_b, r), end = U16(_b, r + 2);
                if (glyph < start) hi = mid - 1;
                else if (glyph > end) lo = mid + 1;
                else return U16(_b, r + 4) + glyph - start;
            }
            else return -1;
        }
        return -1;
    }

    /// <summary>A glyph's class in a class definition table (0 when it lists none).</summary>
    private int ClassOf(int table, int glyph)
    {
        var format = U16(_b, table);
        if (format == 1)
        {
            int start = U16(_b, table + 2), n = U16(_b, table + 4);
            return glyph >= start && glyph - start < n ? U16(_b, table + 6 + 2 * (glyph - start)) : 0;
        }
        if (format != 2) return 0;
        int lo = 0, hi = U16(_b, table + 2) - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) >>> 1;
            var r = table + 4 + 6 * mid;
            int start = U16(_b, r), end = U16(_b, r + 2);
            if (glyph < start) hi = mid - 1;
            else if (glyph > end) lo = mid + 1;
            else return U16(_b, r + 4);
        }
        return 0;
    }

    /// <summary>The 'kern' table's first horizontal format 0 subtable that isn't minimum or cross-stream: where its pairs start and how many fit.</summary>
    private static (int, int) KernPairs(byte[] b, int at, int length)
    {
        if (length < 4 || U16(b, at) != 0) return default; // Apple's version 1 tables aren't read
        var n = U16(b, at + 2);
        var sub = at + 4;
        var end = at + length;
        for (var i = 0; i < n && sub + 6 <= end; i++)
        {
            var subLength = U16(b, sub + 2);
            var coverage = U16(b, sub + 4);
            if (coverage >> 8 == 0 && (coverage & 0x7) == 1)
            {
                var pairs = U16(b, sub + 6);
                // The subtable's own length overflows 16 bits in big tables: the pairs are counted against the table's.
                var fit = Math.Min(pairs, Math.Max(0, (end - (sub + 14)) / 6));
                return (sub + 14, fit);
            }
            if (subLength < 6) break;
            sub += subLength;
        }
        return default;
    }

    private int FromKernTable(int left, int right)
    {
        var key = (uint)left << 16 | (uint)right;
        int lo = 0, hi = _pairs.Count - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) >>> 1;
            var r = _pairs.At + 6 * mid;
            var k = (uint)U16(_b, r) << 16 | (uint)U16(_b, r + 2);
            if (k == key) return I16(_b, r + 4);
            if (k < key) lo = mid + 1;
            else hi = mid - 1;
        }
        return 0;
    }
}

/// <summary>
/// The kerning a page font's own table gives two of its codes, for text a paragraph edit lays out (roadmap 2.1): the
/// embedded TrueType program's when it kept its tables, else the installed face of the font's own family (its PDF name,
/// "Helvetica" as Arial) when its widths are the page font's; by glyph or by the characters the codes stand for. A
/// word space has none. As a TJ adjustment: thousandths of an em, positive to set the pair closer.
/// </summary>
internal sealed class FontKerning
{
    private static readonly ConditionalWeakTable<TextFont, FontKerning?> Cache = new();

    private readonly TextFont _font;
    private readonly PairKerning _table;
    /// <summary>Null: the table is the embedded program's, by glyph; else the installed twin's, by character.</summary>
    private readonly TrueTypeFont? _twin;

    private FontKerning(TextFont font, PairKerning table, TrueTypeFont? twin)
    {
        _font = font;
        _table = table;
        _twin = twin;
    }

    /// <summary>The kerning of a page font's own family, or null when neither its program nor an installed twin has any.</summary>
    public static FontKerning? Of(TextFont font) => Cache.GetValue(font, Find);

    private static FontKerning? Find(TextFont font)
    {
        if (font.Program is TrueTypeProgram tt && PairKerning.Read(tt.Bytes) is { } own) return new FontKerning(font, own, null);
        if (StandInFonts.Twin(font) is not { } twin || !SameWidths(font, twin.Font) || PairKerning.Read(twin.Font.Bytes) is not { } table) return null;
        return new FontKerning(font, table, twin.Font);
    }

    /// <summary>
    /// The installed face draws the page font's letters at its widths (within 1.5%, on most letters it has): the same
    /// design, so its kerning is the page font's own.
    /// </summary>
    private static bool SameWidths(TextFont font, TrueTypeFont twin)
    {
        int same = 0, compared = 0;
        foreach (var ch in "aeinorstAEHNOTVWY")
        {
            var enc = font.Encode(ch.ToString());
            if (enc.Missing.Count > 0 || enc.Codes is not [var code and >= 0] || !font.HasGlyph(code) || font.WidthOf(code) is not (> 0 and var w) || !twin.Has(ch)) continue;
            compared++;
            if (Math.Abs(w / 1000 - twin.Advance(ch)) <= 0.015 * Math.Max(0.3, twin.Advance(ch))) same++;
        }
        return compared >= 5 && same >= 0.8 * compared;
    }

    /// <summary>The adjustment between two codes (TJ units; 0: none). A space on either side, or a pair past a quarter em, gets none.</summary>
    public double Pair(int left, int right)
    {
        if (left < 0 || right < 0) return 0;
        int a, b;
        if (_twin is null)
        {
            a = _font.GlyphIdOf(left);
            b = _font.GlyphIdOf(right);
        }
        else
        {
            if (Single(left) is not { } ca || Single(right) is not { } cb) return 0;
            a = _twin.GlyphOf(ca);
            b = _twin.GlyphOf(cb);
        }
        if (a <= 0 || b <= 0 || Blank(left) || Blank(right)) return 0;
        var k = -_table.Kern(a, b) * 1000 / _table.UnitsPerEm;
        return Math.Abs(k) is < 0.5 or > 250 ? 0 : Math.Round(k, 1);
    }

    private bool Blank(int code) => _font.UnicodeOf(code) is not { Length: > 0 } t || t.All(char.IsWhiteSpace);

    /// <summary>The one character a code stands for, or null.</summary>
    private int? Single(int code)
    {
        if (_font.UnicodeOf(code) is not { Length: > 0 } t) return null;
        if (char.IsHighSurrogate(t[0])) return t.Length == 2 && char.IsSurrogatePair(t[0], t[1]) ? char.ConvertToUtf32(t[0], t[1]) : null;
        return t.Length == 1 && !char.IsSurrogate(t[0]) ? t[0] : null;
    }
}
