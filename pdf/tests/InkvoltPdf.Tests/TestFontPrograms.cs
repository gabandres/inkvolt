using System.Text;

namespace InkvoltPdf.Tests;

/// <summary>
/// Font programs built byte by byte for the width checks: a CFF (name-keyed or CID-keyed, with Private DICTs, local
/// subroutines and FontMatrix) and a Type 1 program whose charstrings set their widths with hsbw.
/// </summary>
internal static class TestFontPrograms
{
    // Type 2 charstring operators used here.
    public const byte HStem = 1, CallSubr = 10, Return = 11, EndChar = 14, RMoveTo = 21;

    /// <summary>A number as a Type 2 (and Type 1) charstring encodes it.</summary>
    public static byte[] Num(int v) => v switch
    {
        >= -107 and <= 107 => [(byte)(v + 139)],
        >= 108 and <= 1131 => [(byte)(247 + (v - 108) / 256), (byte)((v - 108) % 256)],
        >= -1131 and <= -108 => [(byte)(251 + (-v - 108) / 256), (byte)((-v - 108) % 256)],
        _ => [28, (byte)(v >> 8), (byte)v],
    };

    /// <summary>A charstring from numbers (int) and operators (byte).</summary>
    public static byte[] Cs(params object[] parts) => [.. parts.SelectMany(p => p is int i ? Num(i) : [(byte)p])];

    private static byte[] Index(IReadOnlyList<byte[]> items)
    {
        if (items.Count == 0) return [0, 0];
        var o = new List<byte> { (byte)(items.Count >> 8), (byte)items.Count, 4 };
        var off = 1;
        o.AddRange(Int32(off));
        foreach (var it in items)
        {
            off += it.Length;
            o.AddRange(Int32(off));
        }
        foreach (var it in items) o.AddRange(it);
        return [.. o];
    }

    private static byte[] Int32(int v) => [(byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];

    /// <summary>A DICT integer, always 5 bytes, so offsets can be filled in after the sizes are known.</summary>
    private static byte[] Int(int v) => [29, .. Int32(v)];

    /// <summary>A DICT real ("0.0005", "-1.5E-3").</summary>
    private static byte[] Real(string s)
    {
        var nibbles = new List<int>();
        for (var i = 0; i < s.Length; i++)
            nibbles.Add(s[i] switch
            {
                '.' => 0xA,
                'E' when i + 1 < s.Length && s[i + 1] == '-' => 0xC,
                'E' => 0xB,
                '-' when i > 0 && s[i - 1] == 'E' => -1,
                '-' => 0xE,
                var c => c - '0',
            });
        nibbles.RemoveAll(n => n < 0);
        nibbles.Add(0xF);
        if (nibbles.Count % 2 == 1) nibbles.Add(0xF);
        return [30, .. Enumerable.Range(0, nibbles.Count / 2).Select(k => (byte)(nibbles[2 * k] << 4 | nibbles[2 * k + 1]))];
    }

    private static byte[] Matrix(string scale) => [.. Real(scale), 139, 139, .. Real(scale), 139, 139, 12, 7];

    /// <summary>One Private DICT: default and nominal widths, local subroutines (when any, right after it).</summary>
    public sealed record Private(int DefaultWidth, int NominalWidth, byte[][]? Subrs = null, string? FontMatrix = null);

    /// <summary>
    /// A CFF program. <paramref name="glyphs"/>: per glyph after .notdef, its SID (name-keyed) or CID (CID-keyed) and
    /// charstring. Name-keyed: <paramref name="privates"/>[0] is the font's. CID-keyed: one font DICT per Private, and
    /// <paramref name="fdOfGlyph"/> (per glyph, .notdef included) says which, written as FDSelect format 3.
    /// </summary>
    public static byte[] Cff(IReadOnlyList<(int Id, byte[] CharString)> glyphs, IReadOnlyList<Private> privates, bool cid = false,
        int[]? fdOfGlyph = null, string? topMatrix = null)
    {
        var header = new byte[] { 1, 0, 4, 4 };
        var name = Index([Encoding.ASCII.GetBytes("Test")]);
        var strings = Index([]);
        var gsubrs = Index([]);
        var charset = new List<byte> { 0 };
        foreach (var (id, _) in glyphs) { charset.Add((byte)(id >> 8)); charset.Add((byte)id); }
        var charStrings = Index([Cs(EndChar), .. glyphs.Select(g => g.CharString)]);

        byte[] PrivateDict(Private p, int subrsAt) =>
            [.. Int(p.DefaultWidth), 20, .. Int(p.NominalWidth), 21, .. p.Subrs is null ? [] : (byte[])[.. Int(subrsAt), 19]];
        // Private DICT (with its subroutines after it, at an offset relative to it) blocks, laid out from `at`.
        (byte[] Bytes, List<(int Size, int Offset)> Where) Privates(int at)
        {
            var bytes = new List<byte>();
            var where = new List<(int, int)>();
            foreach (var p in privates)
            {
                var size = PrivateDict(p, 0).Length;
                where.Add((size, at + bytes.Count));
                bytes.AddRange(PrivateDict(p, size));
                if (p.Subrs is not null) bytes.AddRange(Index(p.Subrs));
            }
            return ([.. bytes], where);
        }

        byte[] Top(int charsetAt, int charStringsAt, (int Size, int Offset) priv, int fdArrayAt, int fdSelectAt) => cid
            ? [.. Int(0), .. Int(0), .. Int(0), 12, 30, .. Int(charsetAt), 15, .. Int(charStringsAt), 17, .. Int(fdArrayAt), 12, 36, .. Int(fdSelectAt), 12, 37,
                .. topMatrix is null ? [] : Matrix(topMatrix)]
            : [.. Int(charsetAt), 15, .. Int(charStringsAt), 17, .. Int(priv.Size), .. Int(priv.Offset), 18, .. topMatrix is null ? [] : Matrix(topMatrix)];
        byte[] FdArray(List<(int Size, int Offset)> where) =>
            Index([.. privates.Select((p, i) => (byte[])[.. Int(where[i].Size), .. Int(where[i].Offset), 18, .. p.FontMatrix is null ? [] : Matrix(p.FontMatrix)])]);
        byte[] FdSelect()
        {
            var fds = fdOfGlyph ?? [.. Enumerable.Repeat(0, glyphs.Count + 1)];
            var ranges = new List<byte>();
            var count = 0;
            for (var g = 0; g < fds.Length; g++)
                if (g == 0 || fds[g] != fds[g - 1])
                {
                    ranges.AddRange([(byte)(g >> 8), (byte)g, (byte)fds[g]]);
                    count++;
                }
            return [3, (byte)(count >> 8), (byte)count, .. ranges, (byte)(fds.Length >> 8), (byte)fds.Length];
        }

        // Sizes don't depend on the offsets (5-byte integers), so lay out once with zeros, then for real.
        var topSize = Index([Top(0, 0, (0, 0), 0, 0)]).Length;
        var charsetAt = header.Length + name.Length + topSize + strings.Length + gsubrs.Length;
        var charStringsAt = charsetAt + charset.Count;
        var privatesAt = charStringsAt + charStrings.Length;
        var (privateBytes, where) = Privates(privatesAt);
        var fdArrayAt = privatesAt + privateBytes.Length;
        var fdArray = cid ? FdArray(where) : [];
        var fdSelectAt = fdArrayAt + fdArray.Length;
        var top = Index([Top(charsetAt, charStringsAt, where[0], fdArrayAt, fdSelectAt)]);
        return [.. header, .. name, .. top, .. strings, .. gsubrs, .. charset, .. charStrings, .. privateBytes, .. fdArray, .. (cid ? FdSelect() : [])];
    }

    /// <summary>
    /// A Type 1 program (cleartext, then the eexec-encrypted private part) whose CharStrings give each glyph its width with
    /// hsbw (or sbw), the charstrings encrypted as the spec says (key 4330, four leading bytes). <paramref name="cutLast"/>:
    /// the last charstring says it is longer than the rest of the program.
    /// </summary>
    public static byte[] Type1(IReadOnlyList<(string Name, byte[] CharString)> glyphs, string fontMatrix = "0.001", bool cutLast = false)
    {
        var clear = $"%!PS-AdobeFont-1.0: Test\n/FontName /Test def\n/FontMatrix [{fontMatrix} 0 0 {fontMatrix} 0 0] readonly def\n/Encoding StandardEncoding def\ncurrentfile eexec\n";
        var priv = new List<byte>(Encoding.Latin1.GetBytes("abcd" + "dup /Private 8 dict dup begin /RD{string currentfile exch readstring pop}executeonly def /lenIV 4 def end\n"));
        priv.AddRange(Encoding.Latin1.GetBytes($"2 index /CharStrings {glyphs.Count} dict dup begin\n"));
        foreach (var (n, cs) in glyphs)
        {
            var encrypted = Encrypt([.. "wxyz"u8, .. cs], 4330);
            var length = cutLast && n == glyphs[^1].Name ? 2_000_000_000 : encrypted.Length;
            priv.AddRange(Encoding.Latin1.GetBytes($"/{n} {length} RD "));
            priv.AddRange(encrypted);
            priv.AddRange(" ND\n"u8);
        }
        priv.AddRange("end\nend\nmark currentfile closefile\n"u8);
        return [.. Encoding.Latin1.GetBytes(clear), .. Encrypt([.. priv], 55665), .. Encoding.Latin1.GetBytes("\n" + new string('0', 64) + "\ncleartomark\n")];
    }

    /// <summary>A Type 1 charstring: "sbx wx hsbw" then endchar (widths past ±1131 as 32-bit numbers, as Type 1 writes them).</summary>
    public static byte[] Hsbw(int width) => [.. Num1(0), .. Num1(width), 13, EndChar];

    private static byte[] Num1(int v) => v is >= -1131 and <= 1131 ? Num(v) : [255, .. Int32(v)];

    private static byte[] Encrypt(byte[] plain, ushort key)
    {
        var enc = new byte[plain.Length];
        var r = key;
        for (var i = 0; i < plain.Length; i++)
        {
            var c = (byte)(plain[i] ^ (r >> 8));
            r = (ushort)((c + r) * 52845 + 22719);
            enc[i] = c;
        }
        return enc;
    }
}
