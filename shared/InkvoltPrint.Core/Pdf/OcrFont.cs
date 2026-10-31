using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Pdf;

/// <summary>
/// A recognized word as the text layer writes it: broken and invisible characters out, composed (NFC, what a search box
/// holds), cut into what each code of the font stands for (a letter with its marks), in the order the letters lie on the
/// page. PDF readers rebuild the reading order of right-to-left text from where it lies, so a right-to-left word is written
/// in visual order, its runs of Latin letters and digits forward (the same reversal pdf.js and MuPDF undo).
/// </summary>
public static class OcrText
{
    /// <summary>The longest text one code stands for, in UTF-16 units; a longer cluster (Zalgo) gets a code per character.</summary>
    public const int MaxCluster = 32;

    /// <summary>The word as it will be found: only characters a search could match, composed, trimmed. Empty when nothing is left.</summary>
    public static string Clean(string text)
    {
        var kept = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (char.IsSurrogate(c))
            {
                if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                {
                    var cp = char.ConvertToUtf32(c, text[i + 1]);
                    i++;
                    if ((cp & 0xFFFE) != 0xFFFE) kept.Append(char.ConvertFromUtf32(cp));
                }
                continue; // half a pair is no character
            }
            if (!Unwanted(c)) kept.Append(c);
        }
        try
        {
            return kept.ToString().Normalize(NormalizationForm.FormC).Trim();
        }
        catch (ArgumentException)
        {
            return kept.ToString().Trim(); // a character Windows won't normalize: as recognized is still valid
        }
    }

    /// <summary>Controls, the byte order mark, the replacement character, noncharacters, and direction marks and overrides, which would split a search.</summary>
    private static bool Unwanted(char c) =>
        char.IsControl(c) || c is '﻿' or '�' or '￾' or '￿' or '‎' or '‏' or '؜' or (>= '‪' and <= '‮') or (>= '⁦' and <= '⁩')
        or (>= '﷐' and <= '﷯');

    /// <summary>Whether the (cleaned) word has a letter of a right-to-left script.</summary>
    public static bool IsRightToLeft(string text)
    {
        for (var i = 0; i < text.Length; i += char.IsSurrogatePair(text, i) ? 2 : 1)
            if (IsStrongRtl(char.ConvertToUtf32(text, i))) return true;
        return false;
    }

    private static bool IsStrongRtl(int cp) =>
        cp is (>= 0x0590 and <= 0x08FF) or (>= 0xFB1D and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFC) or (>= 0x10800 and <= 0x10FFF) or (>= 0x1E800 and <= 0x1EFFF)
        && CharUnicodeInfo.GetUnicodeCategory(cp) is UnicodeCategory.OtherLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.LetterNumber;

    /// <summary>Chinese, Japanese and Thai-like scripts don't put spaces between words: such a word runs into the next.</summary>
    public static bool IsUnspaced(string text)
    {
        if (text.Length == 0) return false;
        for (var i = 0; i < text.Length; i += char.IsSurrogatePair(text, i) ? 2 : 1)
            if (!IsUnspacedLetter(char.ConvertToUtf32(text, i))) return false;
        return true;
    }

    private static bool IsUnspacedLetter(int cp) =>
        cp is (>= 0x3000 and <= 0x30FF) or (>= 0x3400 and <= 0x4DBF) or (>= 0x4E00 and <= 0x9FFF) or (>= 0xF900 and <= 0xFAFF) or (>= 0xFF00 and <= 0xFFEF) or (>= 0x20000 and <= 0x3FFFF);

    /// <summary>
    /// The (cleaned) word cut into what each code stands for, in the order they lie on the page: clusters (a letter with its
    /// marks) left to right. A right-to-left word is cut into characters instead: pdf.js and MuPDF turn the characters they
    /// read back round one by one, so a cluster's would come out in the wrong order.
    /// </summary>
    public static List<string> Clusters(string text)
    {
        if (IsRightToLeft(text)) return VisualOrder(Characters(text));
        var clusters = new List<string>();
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            var element = elements.GetTextElement();
            if (element.Length <= MaxCluster) clusters.Add(element);
            else clusters.AddRange(Characters(element));
        }
        return clusters;
    }

    private static List<string> Characters(string text)
    {
        var characters = new List<string>(text.Length);
        for (var i = 0; i < text.Length; i += char.IsSurrogatePair(text, i) ? 2 : 1)
            characters.Add(text.Substring(i, char.IsSurrogatePair(text, i) ? 2 : 1));
        return characters;
    }

    /// <summary>
    /// Right-to-left at the word's level: the whole list turned round, then each run that reads left to right (Latin letters,
    /// digits, what joins digits) turned back.
    /// </summary>
    private static List<string> VisualOrder(List<string> logical)
    {
        var forward = new bool[logical.Count];
        for (var i = 0; i < logical.Count; i++) forward[i] = ReadsForward(logical[i]);
        // A separator between two digits is part of the number: 1,234.50
        for (var i = 1; i + 1 < logical.Count; i++)
            if (logical[i] is "," or "." or ":" or "/" or "-" or "٫" or "٬" && forward[i - 1] && IsDigit(logical[i - 1]) && IsDigit(logical[i + 1])) forward[i] = true;
        var result = new List<string>(logical.Count);
        for (var i = logical.Count - 1; i >= 0;)
        {
            if (!forward[i])
            {
                result.Add(logical[i--]);
                continue;
            }
            var end = i;
            while (i >= 0 && forward[i]) i--;
            for (var k = i + 1; k <= end; k++) result.Add(logical[k]);
        }
        return result;
    }

    private static bool IsDigit(string cluster) => char.IsDigit(cluster, 0);

    private static bool ReadsForward(string cluster)
    {
        var cp = char.ConvertToUtf32(cluster, 0);
        return !IsStrongRtl(cp) && (CharUnicodeInfo.GetUnicodeCategory(cp) is UnicodeCategory.DecimalDigitNumber or UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter
            or UnicodeCategory.TitlecaseLetter or UnicodeCategory.OtherLetter or UnicodeCategory.ModifierLetter);
    }
}

/// <summary>
/// The text layer's one font: a Type0 font (Identity-H) over an embedded TrueType program of a single empty glyph half an em
/// wide, so nothing can ever be drawn and no system font is needed. Each different cluster gets a code as it first appears;
/// /CIDToGIDMap sends them all to that glyph and /ToUnicode gives each its text (surrogate pairs and marks included), which is
/// what search, selection and copy read. Tesseract's PDF output and OCRmyPDF work the same way.
/// </summary>
internal sealed class OcrFont
{
    /// <summary>The advance of the glyph, in thousandths of the font size.</summary>
    public const int Width = 500;

    /// <summary>A code is two bytes, and code 0 is .notdef.</summary>
    private const int MaxCodes = 65_535;

    private readonly Dictionary<string, int> _codes = new(StringComparer.Ordinal);
    private readonly List<string> _texts = [""];
    private readonly int _maxCodes;

    public OcrFont(int maxCodes = MaxCodes) => _maxCodes = maxCodes;

    public bool IsEmpty => _codes.Count == 0;

    /// <summary>The clusters' codes as a PDF hex string; a cluster past what the font can hold is left out. Empty when none could be given a code.</summary>
    public string Encode(IEnumerable<string> clusters, out int count)
    {
        var hex = new StringBuilder();
        count = 0;
        foreach (var cluster in clusters)
        {
            if (!_codes.TryGetValue(cluster, out var code))
            {
                if (_texts.Count > _maxCodes) continue;
                code = _texts.Count;
                _texts.Add(cluster);
                _codes[cluster] = code;
            }
            hex.Append(code.ToString("X4", CultureInfo.InvariantCulture));
            count++;
        }
        return hex.ToString();
    }

    public void Write(Action<int, string> obj, Action<int, string, byte[]> stream, int fontId, int firstId)
    {
        var (descendant, descriptor, program, cidMap, unicode) = (firstId, firstId + 1, firstId + 2, firstId + 3, firstId + 4);
        const string name = "/InkvoltOcrText";
        obj(fontId, $"<< /Type /Font /Subtype /Type0 /BaseFont {name} /Encoding /Identity-H /DescendantFonts [{descendant} 0 R] /ToUnicode {unicode} 0 R >>");
        obj(descendant, $"<< /Type /Font /Subtype /CIDFontType2 /BaseFont {name} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " +
                        $"/FontDescriptor {descriptor} 0 R /DW {Width} /CIDToGIDMap {cidMap} 0 R >>");
        obj(descriptor, $"<< /Type /FontDescriptor /FontName {name} /Flags 4 /FontBBox [0 -200 500 800] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontFile2 {program} 0 R >>");
        var ttf = Program.Value;
        stream(program, $"<< /Length {ttf.Length} /Length1 {ttf.Length} >>", ttf);
        var map = CidMap();
        stream(cidMap, $"<< /Length {map.Length} >>", map);
        var cmap = ToUnicode();
        stream(unicode, $"<< /Length {cmap.Length} >>", cmap);
    }

    private byte[] CidMap()
    {
        var map = new byte[_texts.Count * 2];
        for (var code = 1; code < _texts.Count; code++) map[code * 2 + 1] = 1;
        return map;
    }

    private byte[] ToUnicode()
    {
        var s = new StringBuilder("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" +
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" +
            "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        for (var code = 1; code < _texts.Count; code += 100)
        {
            var n = Math.Min(100, _texts.Count - code);
            s.Append(CultureInfo.InvariantCulture, $"{n} beginbfchar\n");
            for (var k = code; k < code + n; k++)
                s.Append(CultureInfo.InvariantCulture, $"<{k:X4}> <{Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(_texts[k]))}>\n");
            s.Append("endbfchar\n");
        }
        s.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        return Encoding.ASCII.GetBytes(s.ToString());
    }

    // ---- The font program ----

    private static readonly Lazy<byte[]> Program = new(BuildProgram);

    /// <summary>
    /// A TrueType font of two glyphs: .notdef (a small box) and glyph 1, half an em wide, whose outline runs out along a line
    /// and back: no area, so nothing to paint even in a reader that ignores render mode 3, but a real bounding box. MuPDF drops
    /// text whose bounds are empty, which is a whole line of it if the glyph has no outline at all. Fixed bytes: no dates.
    /// </summary>
    private static byte[] BuildProgram()
    {
        var head = new byte[54];
        Be32(head, 0, 0x00010000); // version
        Be32(head, 4, 0x00010000); // fontRevision
        Be32(head, 12, 0x5F0F3CF5); // magicNumber
        Be16(head, 18, 1000); // unitsPerEm
        Be16(head, 36, 0); // xMin
        Be16(head, 38, unchecked((ushort)-200)); // yMin
        Be16(head, 40, 500); // xMax
        Be16(head, 42, 800); // yMax
        Be16(head, 46, 8); // lowestRecPPEM
        Be16(head, 48, 2); // fontDirectionHint

        var hhea = new byte[36];
        Be32(hhea, 0, 0x00010000);
        Be16(hhea, 4, 800); // ascender
        Be16(hhea, 6, unchecked((ushort)-200)); // descender
        Be16(hhea, 10, Width); // advanceWidthMax
        Be16(hhea, 16, Width); // xMaxExtent
        Be16(hhea, 18, 1); // caretSlopeRise
        Be16(hhea, 34, 2); // numberOfHMetrics

        var hmtx = new byte[8];
        Be16(hmtx, 0, Width);
        Be16(hmtx, 4, Width);

        var maxp = new byte[32];
        Be32(maxp, 0, 0x00010000);
        Be16(maxp, 4, 2); // numGlyphs
        Be16(maxp, 6, 4); // maxPoints
        Be16(maxp, 8, 1); // maxContours
        Be16(maxp, 14, 1); // maxZones

        // Each: one contour, on-curve points, sixteen-bit relative coordinates.
        var notdef = Glyph([50, 450, 450, 50], [0, 0, 700, 700]);
        var line = Glyph([0, 500, 0], [-200, 800, -200]);
        var glyf = new byte[notdef.Length + line.Length];
        notdef.CopyTo(glyf, 0);
        line.CopyTo(glyf, notdef.Length);

        var loca = new byte[6]; // short offsets: half the byte offset
        Be16(loca, 2, (ushort)(notdef.Length / 2));
        Be16(loca, 4, (ushort)(glyf.Length / 2));

        // Windows Unicode: U+0020 to glyph 1, and the closing segment format 4 requires.
        var cmap = new byte[4 + 8 + 32];
        Be16(cmap, 2, 1); // numTables
        Be16(cmap, 4, 3); // platform
        Be16(cmap, 6, 1); // encoding
        Be32(cmap, 8, 12); // offset
        var f4 = 12;
        Be16(cmap, f4, 4); // format
        Be16(cmap, f4 + 2, 32); // length
        Be16(cmap, f4 + 6, 4); // segCountX2
        Be16(cmap, f4 + 8, 4); // searchRange
        Be16(cmap, f4 + 10, 1); // entrySelector
        Be16(cmap, f4 + 12, 0); // rangeShift
        Be16(cmap, f4 + 14, 0x0020); // endCode
        Be16(cmap, f4 + 16, 0xFFFF);
        Be16(cmap, f4 + 20, 0x0020); // startCode
        Be16(cmap, f4 + 22, 0xFFFF);
        Be16(cmap, f4 + 24, unchecked((ushort)(1 - 0x20))); // idDelta
        Be16(cmap, f4 + 26, 1);

        var post = new byte[32];
        Be32(post, 0, 0x00030000); // no glyph names

        var nameText = Encoding.BigEndianUnicode.GetBytes("InkvoltOcrText");
        var names = new byte[6 + 12 * 2 + nameText.Length];
        Be16(names, 2, 2); // count
        Be16(names, 4, 6 + 12 * 2); // stringOffset
        foreach (var (at, id) in new[] { (6, 1), (18, 6) })
        {
            Be16(names, at, 3); // Windows
            Be16(names, at + 2, 1); // Unicode
            Be16(names, at + 4, 0x0409);
            Be16(names, at + 6, (ushort)id);
            Be16(names, at + 8, (ushort)nameText.Length);
        }
        nameText.CopyTo(names, 6 + 12 * 2);

        (string Tag, byte[] Data)[] tables =
        [
            ("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea), ("hmtx", hmtx), ("loca", loca), ("maxp", maxp), ("name", names), ("post", post),
        ];
        var size = 12 + 16 * tables.Length + tables.Sum(t => (t.Data.Length + 3) & ~3);
        var font = new byte[size];
        Be32(font, 0, 0x00010000);
        Be16(font, 4, (ushort)tables.Length);
        Be16(font, 6, 128); // searchRange
        Be16(font, 8, 3); // entrySelector
        Be16(font, 10, (ushort)(tables.Length * 16 - 128)); // rangeShift
        var offset = 12 + 16 * tables.Length;
        var headAt = 0;
        for (var i = 0; i < tables.Length; i++)
        {
            var (tag, data) = tables[i];
            var entry = 12 + 16 * i;
            Encoding.ASCII.GetBytes(tag, font.AsSpan(entry));
            Be32(font, entry + 4, Checksum(data));
            Be32(font, entry + 8, (uint)offset);
            Be32(font, entry + 12, (uint)data.Length);
            data.CopyTo(font, offset);
            if (tag == "head") headAt = offset;
            offset += (data.Length + 3) & ~3;
        }
        Be32(font, headAt + 8, 0xB1B0AFBA - Checksum(font));
        return font;
    }

    private static byte[] Glyph(short[] xs, short[] ys)
    {
        var n = xs.Length;
        var glyph = new byte[(14 + n + n * 4 + 1) & ~1];
        Be16(glyph, 0, 1); // numberOfContours
        Be16(glyph, 2, unchecked((ushort)xs.Min()));
        Be16(glyph, 4, unchecked((ushort)ys.Min()));
        Be16(glyph, 6, unchecked((ushort)xs.Max()));
        Be16(glyph, 8, unchecked((ushort)ys.Max()));
        Be16(glyph, 10, (ushort)(n - 1)); // endPtsOfContours[0]; instructionLength stays 0
        for (var i = 0; i < n; i++)
        {
            glyph[14 + i] = 0x01; // on curve
            Be16(glyph, 14 + n + i * 2, unchecked((ushort)(xs[i] - (i > 0 ? xs[i - 1] : 0))));
            Be16(glyph, 14 + n + n * 2 + i * 2, unchecked((ushort)(ys[i] - (i > 0 ? ys[i - 1] : 0))));
        }
        return glyph;
    }

    private static void Be16(byte[] data, int at, ushort value) => BinaryPrimitives.WriteUInt16BigEndian(data.AsSpan(at), value);
    private static void Be32(byte[] data, int at, uint value) => BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(at), value);

    private static uint Checksum(byte[] data)
    {
        uint sum = 0;
        for (var i = 0; i < data.Length; i += 4)
        {
            uint word = 0;
            for (var k = 0; k < 4; k++) word = (word << 8) | (i + k < data.Length ? data[i + k] : (byte)0);
            sum += word;
        }
        return sum;
    }
}
