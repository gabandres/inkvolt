using System.Globalization;

namespace InkvoltPdf.Core;

/// <summary>
/// The part of the Unicode bidirectional algorithm (UAX #9) single-line text needs: paragraph level from the first
/// strong character, weak-type rules W1–W7 (numbers stay left-to-right inside right-to-left text), neutral rules N1–N2,
/// implicit levels I1–I2 and trailing-whitespace reset L1. Explicit embeddings/overrides/isolates are not handled
/// (their control characters are treated as ignorable).
/// </summary>
internal static class Bidi
{
    internal enum Cls : byte { L, R, AL, EN, ES, ET, AN, CS, NSM, BN, WS, ON }

    /// <summary>Embedding level of every UTF-16 unit of <paramref name="text"/>, and the paragraph level (0 = LTR, 1 = RTL).</summary>
    public static (byte[] Levels, int Paragraph) Levels(string text, int? paragraphLevel = null)
    {
        var n = text.Length;
        var types = new Cls[n];
        for (var i = 0; i < n; i++)
        {
            if (char.IsHighSurrogate(text[i]) && i + 1 < n && char.IsLowSurrogate(text[i + 1]))
            {
                types[i] = types[i + 1] = Classify(char.ConvertToUtf32(text[i], text[i + 1]));
                i++;
            }
            else types[i] = Classify(text[i]);
        }
        var original = (Cls[])types.Clone();

        var para = paragraphLevel ?? FirstStrong(types);
        var e = para % 2 == 0 ? Cls.L : Cls.R;

        // W1 (and X9: boundary neutrals/joiners take the previous type)
        var prev = e;
        for (var i = 0; i < n; i++)
        {
            if (types[i] is Cls.NSM or Cls.BN) types[i] = prev;
            prev = types[i];
        }
        // W2, W3
        var lastStrong = e;
        for (var i = 0; i < n; i++)
        {
            switch (types[i])
            {
                case Cls.L or Cls.R or Cls.AL:
                    lastStrong = types[i];
                    break;
                case Cls.EN when lastStrong == Cls.AL:
                    types[i] = Cls.AN;
                    break;
            }
        }
        for (var i = 0; i < n; i++)
            if (types[i] == Cls.AL) types[i] = Cls.R;
        // W4
        for (var i = 1; i + 1 < n; i++)
        {
            if (types[i] == Cls.ES && types[i - 1] == Cls.EN && types[i + 1] == Cls.EN) types[i] = Cls.EN;
            else if (types[i] == Cls.CS && types[i - 1] == types[i + 1] && types[i - 1] is Cls.EN or Cls.AN) types[i] = types[i - 1];
        }
        // W5
        for (var i = 0; i < n; i++)
        {
            if (types[i] != Cls.ET) continue;
            var j = i;
            while (j < n && types[j] == Cls.ET) j++;
            if ((i > 0 && types[i - 1] == Cls.EN) || (j < n && types[j] == Cls.EN))
                for (var k = i; k < j; k++) types[k] = Cls.EN;
            i = j - 1;
        }
        // W6
        for (var i = 0; i < n; i++)
            if (types[i] is Cls.ES or Cls.ET or Cls.CS) types[i] = Cls.ON;
        // W7
        lastStrong = e;
        for (var i = 0; i < n; i++)
        {
            if (types[i] is Cls.L or Cls.R) lastStrong = types[i];
            else if (types[i] == Cls.EN && lastStrong == Cls.L) types[i] = Cls.L;
        }
        // N1, N2
        static Cls Dir(Cls c) => c is Cls.L ? Cls.L : Cls.R; // EN and AN act as R
        for (var i = 0; i < n; i++)
        {
            if (types[i] is not (Cls.WS or Cls.ON)) continue;
            var j = i;
            while (j < n && types[j] is Cls.WS or Cls.ON) j++;
            var before = i == 0 ? e : Dir(types[i - 1]);
            var after = j == n ? e : Dir(types[j]);
            var resolved = before == after ? before : e;
            for (var k = i; k < j; k++) types[k] = resolved;
            i = j - 1;
        }
        // I1, I2
        var levels = new byte[n];
        for (var i = 0; i < n; i++)
        {
            levels[i] = (byte)(para % 2 == 0
                ? types[i] switch { Cls.R => para + 1, Cls.AN or Cls.EN => para + 2, _ => para }
                : types[i] switch { Cls.L or Cls.EN or Cls.AN => para + 1, _ => para });
        }
        // L1: trailing whitespace goes back to the paragraph level.
        for (var i = n - 1; i >= 0 && original[i] is Cls.WS or Cls.BN; i--) levels[i] = (byte)para;
        return (levels, para);
    }

    private static int FirstStrong(Cls[] types)
    {
        foreach (var t in types)
        {
            if (t == Cls.L) return 0;
            if (t is Cls.R or Cls.AL) return 1;
        }
        return 0;
    }

    /// <summary>Whether the text starts (first strong character) right-to-left.</summary>
    public static bool IsRtl(string text) => Levels(text).Paragraph == 1;

    /// <summary>
    /// A line's characters as drawn left to right (visual order, as Word and a translated copy write right-to-left text) put
    /// in reading order: rule L2's reversals, which undo themselves, with the line's direction that of most of its letters
    /// (a right-to-left line's English word at its left end doesn't make it left to right). Character by character, as MuPDF
    /// and pdf.js read it: a glyph standing for several characters holds them backwards (<see cref="TextShaper.Shape(string, TrueTypeFont?, bool)"/>).
    /// </summary>
    public static string ToReadingOrder(string text)
    {
        var glyphs = TrueTypeFont.CodePoints(text).Select(char.ConvertFromUtf32).ToList();
        int rtl = 0, ltr = 0;
        foreach (var cp in TrueTypeFont.CodePoints(text))
            switch (Classify(cp))
            {
                case Cls.R or Cls.AL: rtl++; break;
                case Cls.L: ltr++; break;
            }
        if (rtl == 0) return text;
        var (levels, _) = Levels(text, rtl > ltr ? 1 : 0);
        var units = new List<(string Text, byte Level)>(glyphs.Count);
        var at = 0;
        foreach (var g in glyphs)
        {
            if (g.Length > 0) units.Add((g, levels[at]));
            at += g.Length;
        }
        if (units.Count == 0) return text;
        var max = units.Max(u => u.Level);
        var minOdd = units.Where(u => u.Level % 2 == 1).Select(u => (int)u.Level).DefaultIfEmpty(int.MaxValue).Min();
        for (var level = (int)max; level >= minOdd; level--)
            for (var i = 0; i < units.Count;)
            {
                if (units[i].Level < level)
                {
                    i++;
                    continue;
                }
                var j = i;
                while (j < units.Count && units[j].Level >= level) j++;
                units.Reverse(i, j - i);
                i = j;
            }
        return string.Concat(units.Select(u => u.Text));
    }

    internal static Cls Classify(int cp)
    {
        switch (cp)
        {
            case >= '0' and <= '9': return Cls.EN;
            case >= 0x0660 and <= 0x0669 or 0x066B or 0x066C: return Cls.AN;
            case >= 0x06F0 and <= 0x06F9: return Cls.EN;
            case '+' or '-' or 0x2212: return Cls.ES;
            case '#' or '$' or '%' or (>= 0xA2 and <= 0xA5) or 0xB0 or 0xB1 or 0x066A or 0x2030 or (>= 0x20A0 and <= 0x20CF): return Cls.ET;
            case ',' or '.' or '/' or ':' or 0xA0 or 0x060C or 0x202F: return Cls.CS;
            case 0x200E: return Cls.L;
            case 0x200F: return Cls.R;
            case 0x061C: return Cls.AL;
            case 0x200B or 0x200C or 0x200D or 0xFEFF or (>= 0x202A and <= 0x202E) or (>= 0x2066 and <= 0x2069) or 0xAD: return Cls.BN;
        }
        var cat = CharUnicodeInfo.GetUnicodeCategory(cp);
        if (cat is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark) return Cls.NSM;
        if (cat is UnicodeCategory.SpaceSeparator or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator || cp is '\t') return Cls.WS;
        if (cp is (>= 0x0600 and <= 0x07BF) or (>= 0x0860 and <= 0x08FF) or (>= 0xFB50 and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFF) or (>= 0x1EC70 and <= 0x1EEFF))
            return Cls.AL;
        if (cp is (>= 0x0590 and <= 0x05FF) or (>= 0x07C0 and <= 0x085F) or (>= 0xFB1D and <= 0xFB4F) or (>= 0x10800 and <= 0x10FFF) or (>= 0x1E800 and <= 0x1EC6F))
            return Cls.R;
        return cat switch
        {
            UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter
                or UnicodeCategory.OtherLetter or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.DecimalDigitNumber
                or UnicodeCategory.LetterNumber or UnicodeCategory.PrivateUse => Cls.L,
            UnicodeCategory.OtherNumber => Cls.EN,
            UnicodeCategory.Control or UnicodeCategory.Format => Cls.BN,
            _ => Cls.ON,
        };
    }
}
