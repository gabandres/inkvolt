using System.Globalization;
using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// Gives characters without a Unicode value one (Matterhorn 31-027, veraPDF 7.21.7-1), so screen readers can read them:
/// each font the pages, their forms and their annotations' appearances use, whose codes have no ToUnicode entry and no
/// glyph name the Adobe Glyph List knows, gets a ToUnicode CMap with every code it can tell: TeX's glyph names and math
/// encodings (<see cref="TexGlyphs"/>: the pdfTeX papers' CMEX, CMSY and CMMI glyphs), and a composite font's empty glyphs
/// as spaces. What a code already said stays as it was. Make Accessible runs it.
/// </summary>
internal static class FontUnicode
{
    /// <summary>Completes every font that needs it; returns how many were given (or had completed) a ToUnicode.</summary>
    public static int Complete(PdfDocument doc)
    {
        var fonts = new List<PdfDictionary>();
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        void Resources(PdfDictionary? res, int depth)
        {
            if (res is null || depth > 16 || !seen.Add(res)) return;
            if (PdfObj.Dict(res.Elements["/Font"]) is { } fs)
                foreach (var key in fs.Elements.Keys)
                    if (PdfObj.Dict(fs.Elements[key]) is { } f && seen.Add(f))
                    {
                        fonts.Add(f);
                        Resources(PdfObj.Dict(f.Elements["/Resources"]), depth + 1); // a Type 3 font's glyphs
                    }
            if (PdfObj.Dict(res.Elements["/XObject"]) is { } xs)
                foreach (var key in xs.Elements.Keys)
                    if (PdfObj.Dict(xs.Elements[key]) is { } x && PdfObj.NameOf(x, "/Subtype") == "/Form") Resources(PdfObj.Dict(x.Elements["/Resources"]), depth + 1);
            if (PdfObj.Dict(res.Elements["/Pattern"]) is { } ps)
                foreach (var key in ps.Elements.Keys)
                    if (PdfObj.Dict(ps.Elements[key]) is { } pat) Resources(PdfObj.Dict(pat.Elements["/Resources"]), depth + 1);
        }
        foreach (var page in doc.Pages.Cast<PdfPage>())
        {
            Resources(AutoTag.Resources(page), 0);
            foreach (var annot in PdfObj.Array(page.Elements["/Annots"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>() ?? [])
                if (PdfObj.Dict(annot.Elements["/AP"]) is { } ap)
                    foreach (var kind in new[] { "/N", "/R", "/D" })
                        switch (PdfObj.Dict(ap.Elements[kind]))
                        {
                            case { Stream: not null } s:
                                Resources(PdfObj.Dict(s.Elements["/Resources"]), 1);
                                break;
                            case { } states:
                                foreach (var key in states.Elements.Keys)
                                    if (PdfObj.Dict(states.Elements[key]) is { Stream: not null } st) Resources(PdfObj.Dict(st.Elements["/Resources"]), 1);
                                break;
                        }
        }
        return fonts.Count(f => Complete(doc, f));
    }

    /// <summary>Gives one font a ToUnicode with the codes it couldn't tell before; false when none was missing (or none can be told).</summary>
    private static bool Complete(PdfDocument doc, PdfDictionary font)
    {
        TextFont tf;
        try
        {
            tf = TextFont.For(font);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IndexOutOfRangeException)
        {
            return false;
        }
        var subtype = PdfObj.NameOf(font, "/Subtype");
        var map = new SortedDictionary<int, string>();
        var added = false;
        if (subtype is "/Type1" or "/MMType1" or "/TrueType" or "/Type3")
        {
            var baseFont = PdfObj.Name(font.Elements["/BaseFont"]) ?? "";
            // A Type 1 font without an Encoding whose program's encoding isn't read: a TeX math font's codes are its own
            // encoding's (OML, OMS, OMX), whatever StandardEncoding would say.
            var own = subtype is "/Type1" or "/MMType1" && !font.Elements.ContainsKey("/Encoding") && tf.Program is not Type1Program &&
                      TexGlyphs.NameIn(baseFont, 0) is not null;
            for (var c = 0; c < 256; c++)
            {
                if (tf.ToUnicodeOf(c) is { } had)
                {
                    map[c] = had;
                    continue;
                }
                if (own)
                {
                    if (TexGlyphs.NameIn(baseFont, c) is { } texName && TexGlyphs.ToUnicode(texName) is { } t)
                    {
                        map[c] = t;
                        added = true;
                    }
                    continue;
                }
                if (tf.UnicodeOf(c) is { } known) map[c] = known;
                else if (tf.GlyphNameOf(c) is { } g && g != ".notdef" && TexGlyphs.ToUnicode(g) is { } tex)
                {
                    map[c] = tex;
                    added = true;
                }
            }
            if (!added) return false;
            font.Elements["/ToUnicode"] = PdfObj.AddStream(doc, CMap(map, 1)).Reference!;
            return true;
        }
        if (subtype != "/Type0" || PdfObj.Name(font.Elements["/Encoding"]) is not ("Identity-H" or "Identity-V") ||
            PdfObj.Array(font.Elements["/DescendantFonts"]) is not { Elements.Count: > 0 } df || PdfObj.Dict(df.Elements[0]) is not { } cid ||
            FontProgram.Load(PdfObj.Dict(cid.Elements["/FontDescriptor"])) is not CffProgram cff)
            return false;
        // A CFF program (CIDFontType0): with Identity the codes are the CIDs, glyph indices in a name-keyed program.
        foreach (var (code, text) in tf.ToUnicodeMap) map[code] = text;
        var glyphs = cff.IsCid ? cff.Cids : Enumerable.Range(1, Math.Max(0, cff.NumGlyphs - 1));
        foreach (var g in glyphs)
        {
            if (map.ContainsKey(g)) continue;
            var text = cff.NameOfGlyph(g) is { } name ? TexGlyphs.ToUnicode(name) : null;
            text ??= cff.IsBlank(g) ? " " : null;
            if (text is null) continue;
            map[g] = text;
            added = true;
        }
        if (!added) return false;
        font.Elements["/ToUnicode"] = PdfObj.AddStream(doc, CMap(map, 2)).Reference!;
        return true;
    }

    /// <summary>A ToUnicode CMap of one- or two-byte codes.</summary>
    private static byte[] CMap(SortedDictionary<int, string> map, int bytes)
    {
        var hex = bytes == 1 ? "X2" : "X4";
        var sb = new StringBuilder();
        sb.Append("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n");
        sb.Append("/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n");
        sb.Append(bytes == 1 ? "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" : "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        foreach (var chunk in map.Where(kv => kv.Value.Length > 0).Chunk(100))
        {
            sb.Append(CultureInfo.InvariantCulture, $"{chunk.Length} beginbfchar\n");
            foreach (var (code, text) in chunk)
                sb.Append('<').Append(code.ToString(hex, CultureInfo.InvariantCulture)).Append("> <")
                  .Append(Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(text))).Append(">\n");
            sb.Append("endbfchar\n");
        }
        sb.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }
}
