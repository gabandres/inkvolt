using System.Text;
using System.Text.RegularExpressions;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

public static partial class AccessibilityCheck
{
    /// <summary>The CMaps a PDF reader knows without the file embedding them (ISO 32000-1, 9.7.5.2, Table 118).</summary>
    private static readonly HashSet<string> PredefinedCMaps =
    [
        "GB-EUC-H", "GB-EUC-V", "GBpc-EUC-H", "GBpc-EUC-V", "GBK-EUC-H", "GBK-EUC-V", "GBKp-EUC-H", "GBKp-EUC-V", "GBK2K-H", "GBK2K-V",
        "UniGB-UCS2-H", "UniGB-UCS2-V", "UniGB-UTF16-H", "UniGB-UTF16-V", "B5pc-H", "B5pc-V", "HKscs-B5-H", "HKscs-B5-V", "ETen-B5-H",
        "ETen-B5-V", "ETenms-B5-H", "ETenms-B5-V", "CNS-EUC-H", "CNS-EUC-V", "UniCNS-UCS2-H", "UniCNS-UCS2-V", "UniCNS-UTF16-H",
        "UniCNS-UTF16-V", "83pv-RKSJ-H", "90ms-RKSJ-H", "90ms-RKSJ-V", "90msp-RKSJ-H", "90msp-RKSJ-V", "90pv-RKSJ-H", "Add-RKSJ-H",
        "Add-RKSJ-V", "EUC-H", "EUC-V", "Ext-RKSJ-H", "Ext-RKSJ-V", "H", "V", "UniJIS-UCS2-H", "UniJIS-UCS2-V", "UniJIS-UCS2-HW-H",
        "UniJIS-UCS2-HW-V", "UniJIS-UTF16-H", "UniJIS-UTF16-V", "KSC-EUC-H", "KSC-EUC-V", "KSCms-UHC-H", "KSCms-UHC-V", "KSCms-UHC-HW-H",
        "KSCms-UHC-HW-V", "KSCpc-EUC-H", "UniKS-UCS2-H", "UniKS-UCS2-V", "UniKS-UTF16-H", "UniKS-UTF16-V", "Identity-H", "Identity-V",
    ];

    /// <summary>The character collection a predefined CMap uses ("Japan1"), or null for Identity.</summary>
    private static string? OrderingOf(string cmap) => cmap switch
    {
        "Identity-H" or "Identity-V" => null,
        _ when cmap.Contains("GB", StringComparison.Ordinal) => "GB1",
        _ when cmap.Contains("CNS", StringComparison.Ordinal) || cmap.Contains("B5", StringComparison.Ordinal) => "CNS1",
        _ when cmap.Contains("KS", StringComparison.Ordinal) => "Korea1",
        _ => "Japan1",
    };

    [GeneratedRegex(@"/WMode\s+(\d+)\s+def")]
    private static partial Regex WModePattern();

    private sealed partial class Checker
    {
        private void CheckFonts()
        {
            foreach (var (font, use) in _fonts)
            {
                cancel.ThrowIfCancellationRequested();
                try
                {
                    Font(font, use);
                }
                catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IndexOutOfRangeException or OverflowException)
                {
                    _notes.Add($"The font {FontName(font)} couldn't be read in full: {ex.Message}");
                }
            }
        }

        private static string FontName(PdfDictionary font) => PdfObj.Name(font.Elements["/BaseFont"]) is { Length: > 0 } n ? n : "(unnamed)";

        private static bool IsSubset(string name) => name.Length > 7 && name[6] == '+' && name.Take(6).All(char.IsAsciiLetterUpper);

        private static bool Embedded(PdfDictionary? descriptor) =>
            descriptor is not null && (descriptor.Elements.ContainsKey("/FontFile") || descriptor.Elements.ContainsKey("/FontFile2") || descriptor.Elements.ContainsKey("/FontFile3"));

        private void Font(PdfDictionary font, FontUse use)
        {
            var name = FontName(font);
            var label = $"Font {name}";
            void Fail(string condition, string problem) => Add(condition, problem, use.Page, use.Box, label);

            var subtype = PdfObj.NameOf(font, "/Subtype");
            var cid = subtype == "/Type0" && PdfObj.Array(font.Elements["/DescendantFonts"]) is { Elements.Count: > 0 } df ? PdfObj.Dict(df.Elements[0]) : null;
            var descriptor = PdfObj.Dict((cid ?? font).Elements["/FontDescriptor"]);
            var embedded = Embedded(descriptor);
            var tf = TextFont.For(font);
            var flags = descriptor is null ? 0 : PdfObj.Int(descriptor.Elements["/Flags"]) ?? 0;
            var symbolic = (flags & 4) != 0;

            if (subtype != "/Type3" && use.Shown.Count > 0 && !embedded)
                Fail("31-009", $"The font {name} isn't embedded, so the text may show in another font, or not at all, on other computers.");

            // Glyph by glyph.
            int missing = 0, notdef = 0, unmapped = 0, zero = 0, bom = 0, widths = 0;
            // A font of one of the Adobe CJK collections (its own or its CMap's) gets its characters from the collection.
            var ordering = cid is null ? null : PdfObj.Text(PdfObj.Dict(cid.Elements["/CIDSystemInfo"])?.Elements["/Ordering"]);
            var cmapOrdering = cid is null ? null : PdfObj.Resolve(font.Elements["/Encoding"]) switch
            {
                PdfName n => OrderingOf(n.Value.TrimStart('/')),
                PdfDictionary e => PdfObj.Text(PdfObj.Dict(e.Elements["/CIDSystemInfo"])?.Elements["/Ordering"]),
                _ => null,
            };
            var collection = ordering is "GB1" or "CNS1" or "Japan1" or "Korea1" || cmapOrdering is "GB1" or "CNS1" or "Japan1" or "Korea1";
            // A symbolic Type 1 font without an Encoding uses its program's own: a CFF program's isn't read here (its glyphs
            // and characters aren't judged), and without a program nothing tells which glyph or character a code is.
            var ownEncoding = subtype is "/Type1" or "/MMType1" && !font.Elements.ContainsKey("/Encoding") && tf.Program is not Type1Program
                              && (symbolic || descriptor is null && Regex.IsMatch(name, @"(^|\+)(ZapfDingbats|Symbol)"));
            // A composite font with a CMap other than Identity: its codes aren't its CIDs, and CMaps aren't read here, so its
            // glyphs and widths aren't judged (its characters still are, through ToUnicode).
            var cidCodes = cid is null || PdfObj.Name(font.Elements["/Encoding"]) is "Identity-H" or "Identity-V";
            foreach (var code in use.Codes)
            {
                if (code < 0) continue;
                var shown = use.Shown.Contains(code) && cidCodes;
                if (ownEncoding && tf.ToUnicodeOf(code) is null)
                {
                    if (!embedded) unmapped++;
                    continue;
                }
                if (shown && embedded && subtype != "/Type3" && tf.Program is { } program)
                {
                    switch (program)
                    {
                        case TrueTypeProgram tt:
                            var gid = tf.GlyphIdOf(code);
                            if (gid == 0) notdef++;
                            else if (gid < 0 || gid >= tt.NumGlyphs) missing++;
                            break;
                        case CffProgram { IsCid: true } cff:
                            if (code == 0) notdef++;
                            else if (!cff.HasCid(code)) missing++;
                            break;
                        default:
                            var glyph = tf.GlyphNameOf(code);
                            if (glyph == ".notdef") notdef++;
                            else if (glyph is not null && program is Type1Program t1 ? !t1.HasName(glyph) : glyph is not null && program is CffProgram c1 && !c1.HasName(glyph)) missing++;
                            break;
                    }
                }
                else if (!embedded && tf.GlyphNameOf(code) == ".notdef") notdef++;
                var text = tf.UnicodeOf(code);
                if (text is null && !(collection && tf.ToUnicodeOf(code) is null)) unmapped++;
                if (tf.ToUnicodeOf(code) is { } raw)
                {
                    if (raw.Contains('\0')) zero++;
                    if (raw.Contains('﻿') || raw.Contains('￾')) bom++;
                }
                if (shown && tf.DictionaryWidth(code) is { } dw && tf.ProgramWidth(code) is { } pw && Math.Abs(dw - pw) > 1) widths++;
            }
            if (missing > 0) Fail("31-011", $"The embedded font {name} lacks {Count(missing, "glyph")} the text uses, so {(missing == 1 ? "that character" : "those characters")} can't be drawn as meant.");
            if (notdef > 0) Fail("31-030", $"Text in the font {name} draws the .notdef glyph (an empty box) {Count(notdef, "time")}: those characters aren't in the font.");
            if (unmapped > 0)
                Fail("31-027", $"{Count(unmapped, "character")} in the font {name} can't be turned into text (no ToUnicode entry or known glyph name), so screen readers can't read {(unmapped == 1 ? "it" : "them")}.");
            if (zero > 0) Fail("31-028", $"The font {name}'s ToUnicode map gives {Count(zero, "character")} the value 0.");
            if (bom > 0) Fail("31-029", $"The font {name}'s ToUnicode map gives {Count(bom, "character")} the value U+FEFF or U+FFFE.");
            if (widths > 0) Fail("31-016", $"{Count(widths, "glyph")} of the font {name} {(widths == 1 ? "has" : "have")} a different width in the PDF than in the font itself.");

            if (subtype == "/TrueType") TrueType(font, tf, symbolic, embedded, Fail);
            else if (subtype == "/Type0") Composite(font, cid, descriptor, embedded, name, Fail);
            else if (subtype is "/Type1" or "/MMType1" && embedded && IsSubset(name) && descriptor is not null && PdfObj.Text(descriptor.Elements["/CharSet"]) is { } charSet)
            {
                var listed = charSet.Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet(StringComparer.Ordinal);
                IEnumerable<string>? inProgram = tf.Program switch
                {
                    Type1Program t1 => t1.Names,
                    CffProgram { IsCid: false } cff => cff.Names,
                    _ => null,
                };
                if (inProgram is not null)
                {
                    var held = inProgram.ToHashSet(StringComparer.Ordinal);
                    var absent = held.Where(g => g != ".notdef" && !listed.Contains(g)).Take(3).ToList();
                    var extra = listed.Where(g => g != ".notdef" && !held.Contains(g)).Take(3).ToList();
                    if (absent.Count > 0) Fail("31-012", $"The font {name}'s CharSet doesn't list every glyph in it (such as {string.Join(", ", absent)}).");
                    if (extra.Count > 0) Fail("31-013", $"The font {name}'s CharSet lists glyphs it doesn't have (such as {string.Join(", ", extra)}).");
                }
            }
        }

        private void TrueType(PdfDictionary font, TextFont tf, bool symbolic, bool embedded, Action<string, string> fail)
        {
            var encoding = PdfObj.Resolve(font.Elements["/Encoding"]);
            var tt = embedded ? tf.Program as TrueTypeProgram : null;
            var cmaps = tt?.Cmaps.Count ?? 0;
            var has30 = tt?.HasCmap(3, 0) == true;
            var name = FontName(font);
            if (!symbolic)
            {
                if (tt is not null && !(has30 ? cmaps > 1 : cmaps > 0))
                    fail("31-017", $"The TrueType font {name} has no Unicode (3,1) or Mac (1,0) character map, so its glyphs can't be looked up.");
                switch (encoding)
                {
                    case null:
                        fail("31-019", $"The TrueType font {name} has no Encoding.");
                        break;
                    case PdfName n when n.Value is not ("/WinAnsiEncoding" or "/MacRomanEncoding"):
                        fail("31-021", $"The TrueType font {name}'s encoding is {n.Value.TrimStart('/')}, not WinAnsi or MacRoman.");
                        break;
                    case PdfDictionary d:
                        var baseEncoding = PdfObj.Name(d.Elements["/BaseEncoding"]);
                        if (baseEncoding is null) fail("31-020", $"The TrueType font {name}'s Encoding has no base encoding (WinAnsi or MacRoman).");
                        else if (baseEncoding is not ("WinAnsiEncoding" or "MacRomanEncoding")) fail("31-021", $"The TrueType font {name}'s base encoding is {baseEncoding}, not WinAnsi or MacRoman.");
                        if (PdfObj.Array(d.Elements["/Differences"]) is { } diffs)
                        {
                            var odd = diffs.Elements.Select(PdfObj.Name).OfType<string>().Where(g => g != ".notdef" && GlyphNames.ToUnicode(g) is null).Take(3).ToList();
                            if (odd.Count > 0) fail("31-022", $"The TrueType font {name}'s Differences name glyphs outside the Adobe Glyph List (such as {string.Join(", ", odd)}).");
                        }
                        break;
                }
            }
            else
            {
                if (encoding is not null) fail("31-024", $"The symbolic TrueType font {name} has an Encoding, which symbolic TrueType fonts mustn't have.");
                if (tt is not null && cmaps != 1 && !has30)
                    fail(cmaps == 0 ? "31-025" : "31-026", cmaps == 0
                        ? $"The symbolic TrueType font {name} has no character map (cmap)."
                        : $"The symbolic TrueType font {name} has several character maps but no Windows Symbol (3,0) one.");
            }
        }

        private void Composite(PdfDictionary font, PdfDictionary? cid, PdfDictionary? descriptor, bool embedded, string name, Action<string, string> fail)
        {
            var encoding = PdfObj.Resolve(font.Elements["/Encoding"]);
            string? cmapRegistry = null, cmapOrdering = null;
            int? cmapSupplement = null;
            var identity = false;
            switch (encoding)
            {
                case PdfName n:
                    var cmap = n.Value.TrimStart('/');
                    identity = cmap is "Identity-H" or "Identity-V";
                    if (!PredefinedCMaps.Contains(cmap)) fail("31-006", $"The font {name} uses the CMap {cmap}, which is neither a standard one nor embedded."); // its collection is unknown too
                    else if (!identity)
                    {
                        cmapRegistry = "Adobe";
                        cmapOrdering = OrderingOf(cmap);
                    }
                    break;
                case PdfDictionary { Stream: not null } stream:
                    var info = PdfObj.Dict(stream.Elements["/CIDSystemInfo"]);
                    cmapRegistry = PdfObj.Text(info?.Elements["/Registry"]);
                    cmapOrdering = PdfObj.Text(info?.Elements["/Ordering"]);
                    cmapSupplement = PdfObj.Int(info?.Elements["/Supplement"]);
                    var text = Encoding.Latin1.GetString(PdfObj.StreamBytes(stream));
                    var dictMode = PdfObj.Int(stream.Elements["/WMode"]) ?? 0;
                    var m = WModePattern().Match(text);
                    if ((m.Success ? int.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture) : 0) != dictMode)
                        fail("31-007", $"The font {name}'s embedded CMap gives two different writing modes (WMode).");
                    if (PdfObj.Resolve(stream.Elements["/UseCMap"]) is PdfName used && !PredefinedCMaps.Contains(used.Value.TrimStart('/')))
                        fail("31-008", $"The font {name}'s CMap uses the CMap {used.Value.TrimStart('/')}, which isn't a standard one.");
                    break;
            }
            if (cid is null) return;
            if (!identity)
            {
                var info = PdfObj.Dict(cid.Elements["/CIDSystemInfo"]);
                var registry = PdfObj.Text(info?.Elements["/Registry"]);
                var ordering = PdfObj.Text(info?.Elements["/Ordering"]);
                var supplement = PdfObj.Int(info?.Elements["/Supplement"]);
                if (registry != cmapRegistry) fail("31-001", $"The font {name}'s character collection registry ({registry ?? "none"}) differs from its CMap's ({cmapRegistry ?? "none"}).");
                if (ordering != cmapOrdering) fail("31-002", $"The font {name}'s character collection ordering ({ordering ?? "none"}) differs from its CMap's ({cmapOrdering ?? "none"}).");
                if (supplement is { } s && cmapSupplement is { } cs && s > cs) fail("31-003", $"The font {name}'s character collection supplement ({s}) is higher than its CMap's ({cs}).");
            }
            var cidType = PdfObj.NameOf(cid, "/Subtype");
            var map = PdfObj.Resolve(cid.Elements["/CIDToGIDMap"]);
            if (cidType == "/CIDFontType2" && embedded)
            {
                if (map is null) fail("31-005", $"The TrueType CID font {name} has no glyph map (CIDToGIDMap).");
                else if (map is not (PdfDictionary { Stream: not null } or PdfName { Value: "/Identity" })) fail("31-004", $"The TrueType CID font {name}'s glyph map (CIDToGIDMap) is neither a stream nor Identity.");
            }

            // A subset's CIDSet must list every glyph the program holds.
            if (!embedded || !IsSubset(name) || PdfObj.Dict(descriptor?.Elements["/CIDSet"]) is not { Stream: not null } cidSet) return;
            var bits = PdfObj.StreamBytes(cidSet);
            bool Listed(int c) => c / 8 < bits.Length && (bits[c / 8] & (0x80 >> (c % 8))) != 0;
            // The CIDs the program holds (.notdef left out): a CFF program's charset; a TrueType program's every glyph slot
            // reached through the glyph map (subsets that keep empty slots count them, as veraPDF does).
            Func<int, bool>? holds = null;
            IEnumerable<int> held = [];
            switch (FontProgram.Load(descriptor))
            {
                case CffProgram { IsCid: true } cff:
                    held = cff.Cids;
                    holds = c => cff.HasCid(c);
                    break;
                case TrueTypeProgram tt when cidType == "/CIDFontType2":
                    if (map is PdfDictionary { Stream: not null } ms)
                    {
                        var b = PdfObj.StreamBytes(ms);
                        var count = b.Length / 2;
                        holds = c => c > 0 && c < count && (b[2 * c] << 8 | b[2 * c + 1]) < tt.NumGlyphs;
                        held = Enumerable.Range(1, Math.Max(0, count - 1)).Where(holds);
                    }
                    else
                    {
                        holds = c => c > 0 && c < tt.NumGlyphs;
                        held = Enumerable.Range(1, Math.Max(0, tt.NumGlyphs - 1));
                    }
                    break;
            }
            if (holds is null) return;
            var unlisted = held.Count(c => c != 0 && !Listed(c));
            var extra = Enumerable.Range(1, Math.Max(0, bits.Length * 8 - 1)).Count(c => Listed(c) && !holds(c));
            if (unlisted > 0) fail("31-014", $"The font {name}'s CIDSet doesn't list {Count(unlisted, "glyph")} that the font holds.");
            if (extra > 0) fail("31-015", $"The font {name}'s CIDSet lists {Count(extra, "glyph")} that the font doesn't hold.");
        }
    }
}
