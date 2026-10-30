using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// Glyph names and the standard simple-font encodings (PDF 32000 Annex D) for reading and writing text in a page's own
/// fonts: WinAnsiEncoding (Windows-1252), MacRomanEncoding (Mac OS Roman), StandardEncoding (Adobe standard), and
/// Adobe Glyph List names for the Latin characters they hold, Greek and mathematics, plus uniXXXX / uXXXX[XX] names and
/// ligature names (f_i).
/// </summary>
internal static class GlyphNames
{
    // Unicode → name, for every character the three encodings hold and a few common extras.
    private const string List =
        "space 20 exclam 21 quotedbl 22 numbersign 23 dollar 24 percent 25 ampersand 26 quotesingle 27 parenleft 28 parenright 29 " +
        "asterisk 2A plus 2B comma 2C hyphen 2D period 2E slash 2F zero 30 one 31 two 32 three 33 four 34 five 35 six 36 seven 37 " +
        "eight 38 nine 39 colon 3A semicolon 3B less 3C equal 3D greater 3E question 3F at 40 bracketleft 5B backslash 5C " +
        "bracketright 5D asciicircum 5E underscore 5F grave 60 braceleft 7B bar 7C braceright 7D asciitilde 7E " +
        "exclamdown A1 cent A2 sterling A3 currency A4 yen A5 brokenbar A6 section A7 dieresis A8 copyright A9 ordfeminine AA " +
        "guillemotleft AB logicalnot AC registered AE macron AF degree B0 plusminus B1 twosuperior B2 threesuperior B3 acute B4 " +
        "mu B5 paragraph B6 periodcentered B7 cedilla B8 onesuperior B9 ordmasculine BA guillemotright BB onequarter BC onehalf BD " +
        "threequarters BE questiondown BF Agrave C0 Aacute C1 Acircumflex C2 Atilde C3 Adieresis C4 Aring C5 AE C6 Ccedilla C7 " +
        "Egrave C8 Eacute C9 Ecircumflex CA Edieresis CB Igrave CC Iacute CD Icircumflex CE Idieresis CF Eth D0 Ntilde D1 " +
        "Ograve D2 Oacute D3 Ocircumflex D4 Otilde D5 Odieresis D6 multiply D7 Oslash D8 Ugrave D9 Uacute DA Ucircumflex DB " +
        "Udieresis DC Yacute DD Thorn DE germandbls DF agrave E0 aacute E1 acircumflex E2 atilde E3 adieresis E4 aring E5 ae E6 " +
        "ccedilla E7 egrave E8 eacute E9 ecircumflex EA edieresis EB igrave EC iacute ED icircumflex EE idieresis EF eth F0 " +
        "ntilde F1 ograve F2 oacute F3 ocircumflex F4 otilde F5 odieresis F6 divide F7 oslash F8 ugrave F9 uacute FA " +
        "ucircumflex FB udieresis FC yacute FD thorn FE ydieresis FF " +
        "Euro 20AC quotesinglbase 201A florin 192 quotedblbase 201E ellipsis 2026 dagger 2020 daggerdbl 2021 circumflex 2C6 " +
        "perthousand 2030 Scaron 160 guilsinglleft 2039 OE 152 Zcaron 17D quoteleft 2018 quoteright 2019 quotedblleft 201C " +
        "quotedblright 201D bullet 2022 endash 2013 emdash 2014 tilde 2DC trademark 2122 scaron 161 guilsinglright 203A oe 153 " +
        "zcaron 17E Ydieresis 178 fi FB01 fl FB02 ff FB00 ffi FB03 ffl FB04 dotlessi 131 Lslash 141 lslash 142 fraction 2044 " +
        "minus 2212 breve 2D8 dotaccent 2D9 ring 2DA hungarumlaut 2DD ogonek 2DB caron 2C7 nbspace A0 sfthyphen AD " +
        "Delta 2206 Omega 2126 approxequal 2248 notequal 2260 lessequal 2264 greaterequal 2265 infinity 221E partialdiff 2202 " +
        "summation 2211 product 220F pi 3C0 integral 222B radical 221A lozenge 25CA " +
        // Greek and mathematics from the Adobe Glyph List (the names TeX's math fonts use; veraPDF reads them as text too).
        "Alpha 391 Beta 392 Gamma 393 Epsilon 395 Zeta 396 Eta 397 Theta 398 Iota 399 Kappa 39A Lambda 39B Mu 39C Nu 39D " +
        "Xi 39E Omicron 39F Pi 3A0 Rho 3A1 Sigma 3A3 Tau 3A4 Upsilon 3A5 Phi 3A6 Chi 3A7 Psi 3A8 alpha 3B1 beta 3B2 gamma 3B3 " +
        "delta 3B4 epsilon 3B5 zeta 3B6 eta 3B7 theta 3B8 iota 3B9 kappa 3BA lambda 3BB nu 3BD xi 3BE omicron 3BF rho 3C1 " +
        "sigma1 3C2 sigma 3C3 tau 3C4 upsilon 3C5 phi 3C6 chi 3C7 psi 3C8 omega 3C9 theta1 3D1 Upsilon1 3D2 phi1 3D5 omega1 3D6 " +
        "aleph 2135 Ifraktur 2111 Rfraktur 211C weierstrass 2118 arrowleft 2190 arrowup 2191 arrowright 2192 arrowdown 2193 " +
        "arrowboth 2194 arrowupdn 2195 arrowdblleft 21D0 arrowdblup 21D1 arrowdblright 21D2 arrowdbldown 21D3 arrowdblboth 21D4 " +
        "universal 2200 existential 2203 emptyset 2205 gradient 2207 element 2208 notelement 2209 suchthat 220B asteriskmath 2217 " +
        "proportional 221D orthogonal 221F angle 2220 logicaland 2227 logicalor 2228 intersection 2229 union 222A therefore 2234 " +
        "similar 223C congruent 2245 equivalence 2261 propersubset 2282 propersuperset 2283 notsubset 2284 reflexsubset 2286 " +
        "reflexsuperset 2287 circleplus 2295 circlemultiply 2297 perpendicular 22A5 dotmath 22C5 integraltp 2320 integralbt 2321 " +
        "angleleft 2329 angleright 232A minute 2032 second 2033 openbullet 25E6 club 2663 heart 2665 diamond 2666 spade 2660 " +
        // The Symbol font's pieces of big brackets, which the list puts in the Private Use Area: their Unicode characters.
        "parenlefttp 239B parenleftex 239C parenleftbt 239D parenrighttp 239E parenrightex 239F parenrightbt 23A0 " +
        "bracketlefttp 23A1 bracketleftex 23A2 bracketleftbt 23A3 bracketrighttp 23A4 bracketrightex 23A5 bracketrightbt 23A6 " +
        "bracelefttp 23A7 braceleftmid 23A8 braceleftbt 23A9 braceex 23AA bracerighttp 23AB bracerightmid 23AC bracerightbt 23AD " +
        "integralex 23AE arrowhorizex 23AF arrowvertex 23D0";

    private static readonly Dictionary<string, string> ByName = new(StringComparer.Ordinal);
    private static readonly Dictionary<int, string> ByCode = [];

    private static readonly string?[] Win = new string?[256];
    private static readonly string?[] Mac = new string?[256];
    private static readonly string?[] Std = new string?[256];

    static GlyphNames()
    {
        var parts = List.Split(' ');
        for (var i = 0; i + 1 < parts.Length; i += 2)
        {
            var cp = int.Parse(parts[i + 1], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            ByName[parts[i]] = char.ConvertFromUtf32(cp);
            ByCode.TryAdd(cp, parts[i]);
        }
        for (var c = 'A'; c <= 'Z'; c++) Add(c.ToString(), c);
        for (var c = 'a'; c <= 'z'; c++) Add(c.ToString(), c);
        ByCode[0xA0] = "space"; // the encodings name both spaces "space"
        ByCode[0xAD] = "hyphen";

        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var win = Encoding.GetEncoding(1252, EncoderFallback.ExceptionFallback, DecoderFallback.ReplacementFallback);
        var mac = Encoding.GetEncoding(10000, EncoderFallback.ExceptionFallback, DecoderFallback.ReplacementFallback);
        for (var b = 32; b < 256; b++)
        {
            Win[b] = NameOf(win.GetString([(byte)b]));
            Mac[b] = NameOf(mac.GetString([(byte)b]));
        }
        Win[127] = null;
        foreach (var b in new[] { 0x81, 0x8D, 0x8F, 0x90, 0x9D }) Win[b] = null; // unassigned in Windows-1252
        Mac[127] = null;
        Mac[0xDB] = "currency"; // PDF's MacRomanEncoding predates the euro

        // StandardEncoding: ASCII except the two quotes, plus the upper half Adobe defines.
        for (var b = 32; b < 127; b++) Std[b] = Win[b];
        Std[0x27] = "quoteright";
        Std[0x60] = "quoteleft";
        const string upper =
            "A1 exclamdown A2 cent A3 sterling A4 fraction A5 yen A6 florin A7 section A8 currency A9 quotesingle AA quotedblleft " +
            "AB guillemotleft AC guilsinglleft AD guilsinglright AE fi AF fl B1 endash B2 dagger B3 daggerdbl B4 periodcentered " +
            "B6 paragraph B7 bullet B8 quotesinglbase B9 quotedblbase BA quotedblright BB guillemotright BC ellipsis BD perthousand " +
            "BF questiondown C1 grave C2 acute C3 circumflex C4 tilde C5 macron C6 breve C7 dotaccent C8 dieresis CA ring " +
            "CB cedilla CD hungarumlaut CE ogonek CF caron D0 emdash E1 AE E3 ordfeminine E8 Lslash E9 Oslash EA OE EB ordmasculine " +
            "F1 ae F5 dotlessi F8 lslash F9 oslash FA oe FB germandbls";
        var u = upper.Split(' ');
        for (var i = 0; i + 1 < u.Length; i += 2) Std[int.Parse(u[i], NumberStyles.HexNumber, CultureInfo.InvariantCulture)] = u[i + 1];
    }

    private static void Add(string name, char c)
    {
        ByName[name] = c.ToString();
        ByCode[c] = name;
    }

    /// <summary>The glyph name of a single character (null when it has none in the list and isn't one character).</summary>
    public static string? NameOf(string text)
    {
        if (text.Length == 0 || text == "�") return null;
        var cp = char.ConvertToUtf32(text, 0);
        if (text.Length != (cp > 0xFFFF ? 2 : 1)) return null;
        return ByCode.TryGetValue(cp, out var n) ? n : cp <= 0xFFFF ? $"uni{cp:X4}" : $"u{cp:X}";
    }

    /// <summary>The text a glyph name stands for (null when unknown): list names, uniXXXX…, uXXXX[XX], f_i ligatures, suffixes (a.sc).</summary>
    public static string? ToUnicode(string name)
    {
        if (ByName.TryGetValue(name, out var s)) return s;
        var dot = name.IndexOf('.');
        if (dot > 0) return ToUnicode(name[..dot]);
        if (dot == 0) return null;
        if (name.Contains('_'))
        {
            var sb = new StringBuilder();
            foreach (var part in name.Split('_'))
            {
                if (ToUnicode(part) is not { } p) return null;
                sb.Append(p);
            }
            return sb.ToString();
        }
        if (name.StartsWith("uni", StringComparison.Ordinal) && name.Length >= 7 && (name.Length - 3) % 4 == 0)
        {
            var sb = new StringBuilder();
            for (var i = 3; i < name.Length; i += 4)
            {
                if (!int.TryParse(name.AsSpan(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var cp) || cp is >= 0xD800 and <= 0xDFFF) return null;
                sb.Append((char)cp);
            }
            return sb.ToString();
        }
        if (name.Length is >= 5 and <= 7 && name[0] == 'u' && int.TryParse(name.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var u)
            && u is <= 0x10FFFF and not (>= 0xD800 and <= 0xDFFF))
            return char.ConvertFromUtf32(u);
        return null;
    }

    /// <summary>The glyph name of a code in a standard encoding ("WinAnsiEncoding", "MacRomanEncoding", "StandardEncoding").</summary>
    public static string? InEncoding(string encoding, int code) => code is < 0 or > 255 ? null : encoding switch
    {
        "WinAnsiEncoding" => Win[code],
        "MacRomanEncoding" => Mac[code],
        "StandardEncoding" => Std[code],
        _ => null,
    };

    public static bool IsKnownEncoding(string encoding) => encoding is "WinAnsiEncoding" or "MacRomanEncoding" or "StandardEncoding";
}
