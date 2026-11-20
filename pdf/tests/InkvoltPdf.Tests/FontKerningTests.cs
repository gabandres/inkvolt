using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 2.1: a font's own pair kerning (GPOS, kern) for text a paragraph edit lays out.</summary>
public class FontKerningTests
{
    // ---- A font's tables, read ----

    /// <summary>An sfnt of the tables given (head with 1000 units per em added).</summary>
    private static byte[] Sfnt(params (string Tag, byte[] Data)[] tables)
    {
        var head = new byte[54];
        BinaryPrimitives.WriteUInt16BigEndian(head.AsSpan(18), 1000);
        var all = tables.Append(("head", head)).OrderBy(t => t.Item1, StringComparer.Ordinal).ToList();
        var ms = new MemoryStream();
        var dir = new byte[12 + 16 * all.Count];
        BinaryPrimitives.WriteUInt32BigEndian(dir, 0x00010000);
        BinaryPrimitives.WriteUInt16BigEndian(dir.AsSpan(4), (ushort)all.Count);
        var offset = dir.Length;
        for (var i = 0; i < all.Count; i++)
        {
            Encoding.ASCII.GetBytes(all[i].Item1).CopyTo(dir, 12 + 16 * i);
            BinaryPrimitives.WriteUInt32BigEndian(dir.AsSpan(12 + 16 * i + 8), (uint)offset);
            BinaryPrimitives.WriteUInt32BigEndian(dir.AsSpan(12 + 16 * i + 12), (uint)all[i].Item2.Length);
            offset += (all[i].Item2.Length + 3) & ~3;
        }
        ms.Write(dir);
        foreach (var (_, data) in all)
        {
            ms.Write(data);
            ms.Write(new byte[((data.Length + 3) & ~3) - data.Length]);
        }
        return ms.ToArray();
    }

    private static byte[] Words(params int[] values)
    {
        var b = new byte[values.Length * 2];
        for (var i = 0; i < values.Length; i++) BinaryPrimitives.WriteUInt16BigEndian(b.AsSpan(2 * i), (ushort)values[i]);
        return b;
    }

    /// <summary>A 'kern' table: version 0, one horizontal format 0 subtable with these pairs (sorted).</summary>
    private static byte[] KernTable(params (int L, int R, int V)[] pairs)
    {
        var sorted = pairs.OrderBy(p => p.L).ThenBy(p => p.R).ToList();
        var words = new List<int> { 0, 1, 0, 14 + 6 * sorted.Count, 1, sorted.Count, 0, 0, 0 };
        foreach (var (l, r, v) in sorted) words.AddRange([l, r, v & 0xFFFF]);
        return Words([.. words]);
    }

    /// <summary>
    /// A GPOS table with one 'kern' feature of one lookup (type 2, or type 9 holding it), whose subtables are a format 1
    /// pair set (glyph 10 then 20: -50; 10 then 21: -30) and a format 2 class pair (glyphs 30-31 class 1 then 40 class 1: -70).
    /// </summary>
    private static byte[] Gpos(bool extension)
    {
        // Subtable 1, PairPos format 1: coverage [10]; one pair set {20: -50, 21: -30}; value format 1 = XAdvance.
        var f1 = Words(1, 12, 4, 0, 1, 18, /* coverage */ 1, 1, 10, /* pair set */ 2, 20, -50 & 0xFFFF, 21, -30 & 0xFFFF);
        // Subtable 2, PairPos format 2: coverage [30, 31]; class def 1: 30-31 → 1; class def 2: 40 → 1; 2 x 2 classes.
        var cov = Words(1, 2, 30, 31);
        var cd1 = Words(2, 1, 30, 31, 1);
        var cd2 = Words(1, 40, 1, 1);
        var head2 = 16;
        var records = Words(0, 0, 0, -70 & 0xFFFF);
        var covAt = head2 + records.Length;
        var cd1At = covAt + cov.Length;
        var cd2At = cd1At + cd1.Length;
        var f2 = Words(2, covAt, 4, 0, cd1At, cd2At, 2, 2).Concat(records).Concat(cov).Concat(cd1).Concat(cd2).ToArray();
        byte[] lookup;
        if (!extension)
        {
            var at1 = 10;
            lookup = Words(2, 0, 2, at1, at1 + f1.Length).Concat(f1).Concat(f2).ToArray();
        }
        else
        {
            // Two extension subtables (8 bytes each) pointing on to the pair subtables.
            var e1 = 10;
            var e2 = e1 + 8;
            var p1 = e2 + 8;
            var p2 = p1 + f1.Length;
            byte[] Ext(int from, int to) => [.. Words(1, 2), .. new byte[] { 0, 0, (byte)((to - from) >> 8), (byte)(to - from) }];
            lookup = Words(9, 0, 2, e1, e2).Concat(Ext(e1, p1)).Concat(Ext(e2, p2)).Concat(f1).Concat(f2).ToArray();
        }
        var scripts = Words(0);
        var feature = Words(0, 1, 0);
        var features = Encoding.ASCII.GetBytes("kern").Prepend((byte)1).Prepend((byte)0).Concat(Words(8)).Concat(feature).ToArray();
        var lookups = Words(1, 4).Concat(lookup).ToArray();
        var scriptAt = 10;
        var featureAt = scriptAt + scripts.Length;
        var lookupAt = featureAt + features.Length;
        return Words(1, 0, scriptAt, featureAt, lookupAt).Concat(scripts).Concat(features).Concat(lookups).ToArray();
    }

    [Fact]
    public void TheKernTablesPairsAreRead()
    {
        var k = PairKerning.Read(Sfnt(("kern", KernTable((36, 57, -80), (55, 82, -60), (36, 55, -40)))))!;
        Assert.NotNull(k);
        Assert.Equal(1000, k.UnitsPerEm);
        Assert.Equal(-80, k.Kern(36, 57));
        Assert.Equal(-60, k.Kern(55, 82));
        Assert.Equal(-40, k.Kern(36, 55));
        Assert.Equal(0, k.Kern(57, 36));
        Assert.Equal(0, k.Kern(1, 2));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void GposPairAdjustmentsAreRead(bool extension)
    {
        var k = PairKerning.Read(Sfnt(("GPOS", Gpos(extension))))!;
        Assert.NotNull(k);
        Assert.Equal(-50, k.Kern(10, 20));
        Assert.Equal(-30, k.Kern(10, 21));
        Assert.Equal(0, k.Kern(10, 22));
        Assert.Equal(-70, k.Kern(30, 40));
        Assert.Equal(-70, k.Kern(31, 40));
        Assert.Equal(0, k.Kern(30, 41)); // class 0: the record's 0
        Assert.Equal(0, k.Kern(20, 10));
    }

    [Theory]
    [InlineData(true, -30)]
    [InlineData(false, -50)]
    public void OneScriptsKernFeatureCountsLatinFirst(bool latinKerns, int expected)
    {
        // DFLT's kern feature has its lookup (10 then 20: -50), latn's another (-30). Latin's applies, once; a latn
        // language system without a kern feature leaves DFLT's.
        static byte[] Pair(int v) => Words(1, 12, 4, 0, 1, 18, 1, 1, 10, 1, 20, v & 0xFFFF);
        var lookup0 = Words(2, 0, 1, 8).Concat(Pair(-50)).ToArray();
        var lookup1 = Words(2, 0, 1, 8).Concat(Pair(-30)).ToArray();
        var lookups = Words(2, 6, 6 + lookup0.Length).Concat(lookup0).Concat(lookup1).ToArray();
        byte[] Feature(int index) => Words(0, 1, index);
        var features = Words(2).Concat(Encoding.ASCII.GetBytes("kern")).Concat(Words(14)).Concat(Encoding.ASCII.GetBytes("kern")).Concat(Words(20))
            .Concat(Feature(0)).Concat(Feature(1)).ToArray();
        // Script list: DFLT (default language: feature 0), latn (default language: feature 1, or none).
        byte[] LangSys(int? feature) => feature is { } f ? Words(0, 0xFFFF, 1, f) : Words(0, 0xFFFF, 0);
        var scripts = Words(2).Concat(Encoding.ASCII.GetBytes("DFLT")).Concat(Words(14)).Concat(Encoding.ASCII.GetBytes("latn")).Concat(Words(26))
            .Concat(Words(4, 0)).Concat(LangSys(0)).Concat(Words(4, 0)).Concat(LangSys(latinKerns ? 1 : null)).ToArray();
        var scriptAt = 10;
        var featureAt = scriptAt + scripts.Length;
        var lookupAt = featureAt + features.Length;
        var gpos = Words(1, 0, scriptAt, featureAt, lookupAt).Concat(scripts).Concat(features).Concat(lookups).ToArray();
        var k = PairKerning.Read(Sfnt(("GPOS", gpos)))!;
        Assert.Equal(expected, k.Kern(10, 20));
    }

    [Fact]
    public void AFontWithoutKerningHasNone()
    {
        Assert.Null(PairKerning.Read(Sfnt()));
        Assert.Null(PairKerning.Read([]));
        Assert.Null(PairKerning.Read(new byte[11]));
    }

    [Fact]
    public void ACutOrScrambledFontNeverThrows()
    {
        foreach (var font in new[] { Sfnt(("GPOS", Gpos(true))), Sfnt(("kern", KernTable((36, 57, -80)))) })
        {
            for (var cut = 0; cut < font.Length; cut += 3)
            {
                var k = PairKerning.Read(font[..cut]);
                _ = k?.Kern(10, 20);
                _ = k?.Kern(36, 57);
            }
            var rng = new Random(7);
            for (var round = 0; round < 300; round++)
            {
                var bad = (byte[])font.Clone();
                for (var n = 0; n < 4; n++) bad[rng.Next(12 + 16 * 2, bad.Length)] = (byte)rng.Next(256);
                var k = PairKerning.Read(bad);
                _ = k?.Kern(10, 20);
                _ = k?.Kern(30, 40);
                _ = k?.Kern(36, 57);
            }
        }
    }

    [Fact]
    public void ArialsOwnKerningIsRead()
    {
        var arial = SystemFonts.Get("arial.ttf");
        Assert.NotNull(arial);
        var k = PairKerning.Read(arial.Bytes);
        Assert.NotNull(k);
        Assert.True(k.Kern(arial.GlyphOf('A'), arial.GlyphOf('V')) < 0);
        Assert.True(k.Kern(arial.GlyphOf('T'), arial.GlyphOf('o')) < 0);
        Assert.Equal(0, k.Kern(arial.GlyphOf('H'), arial.GlyphOf('H')));
    }

    // ---- In a paragraph edit ----

    private const string Chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?'-";

    /// <summary>Arial's own adjustment for a pair, as a TJ number (thousandths of an em, positive: closer).</summary>
    private static double ArialPair(char a, char b)
    {
        var arial = SystemFonts.Get("arial.ttf")!;
        var k = PairKerning.Read(arial.Bytes)!;
        return Math.Round(-k.Kern(arial.GlyphOf(a), arial.GlyphOf(b)) * 1000 / k.UnitsPerEm, 1);
    }

    private static string N(double v) => v.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);

    [Fact]
    public void NewPairsInAKernedParagraphGetTheFontsOwnKerning()
    {
        // The generator kerned "fo" by -40 (a TJ adjustment inside a word): the paragraph is kerned text, so "AV" and
        // "To" typed into it get Arial's own adjustments (the embedded subset kept no table: the installed Arial's, whose
        // widths are the subset's), while "fo" keeps the generator's.
        var pdf = ContentEditPdf.Make("BT /FA 11 Tf 14 TL 72 700 Td [(The f) -40 (ox jumps over the lazy dog and keeps going on)] TJ T* " +
                                      "[(while the f) -40 (ox runs along the river bank at night)] TJ ET", fontText: Chars);
        var p = ContentEditor.Read(pdf, null, 0).Paragraphs.Single(q => q.Text.StartsWith("The fox", StringComparison.Ordinal));
        Assert.Null(p.Blocked);
        var text = "To AVOW the fox " + p.Text;
        var content = ContentEditPdf.Content(ContentEditor.ReplaceParagraph(pdf, null, p, text));
        var to = ArialPair('T', 'o');
        var av = ArialPair('A', 'V');
        Assert.True(to > 0 && av > 0);
        Assert.Contains($"(T) {N(to)} (o", content);
        Assert.Contains($"A) {N(av)} (V", content);
        Assert.Equal(3, Regex.Matches(content, @"f\) -40 \(o").Count);
    }

    [Fact]
    public void AParagraphSetWithoutKerningGetsNone()
    {
        // No adjustment anywhere in the original: new pairs get none either, so the edited lines look like the rest.
        var pdf = ContentEditPdf.Make("BT /FA 11 Tf 14 TL 72 700 Td (The fox jumps over the lazy dog and keeps going on) Tj T* " +
                                      "(while the fox runs along the river bank at night) Tj ET", fontText: Chars);
        var p = ContentEditor.Read(pdf, null, 0).Paragraphs.Single(q => q.Text.StartsWith("The fox", StringComparison.Ordinal));
        var content = ContentEditPdf.Content(ContentEditor.ReplaceParagraph(pdf, null, p, "To AVOW " + p.Text));
        Assert.DoesNotContain($"(T) {N(ArialPair('T', 'o'))}", content);
        Assert.Contains("(To AVOW", content);
    }

    [Fact]
    public void TheOneRunEditorKernsNewPairsFromTheFontToo()
    {
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td [(Hel) -30 (lo World)] TJ ET", fontText: Chars);
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single(r => r.Text == "Hello World");
        var content = ContentEditPdf.Content(ContentEditor.ReplaceText(pdf, null, run, "Hello To World"));
        Assert.Contains($"T) {N(ArialPair('T', 'o'))} (o", content);
        Assert.Contains("(Hel) -30 (lo", content);
    }

    [Fact]
    public void AFontWhoseInstalledNamesakeHasOtherWidthsIsntKernedFromIt()
    {
        // /FA's widths made 10% wider: the installed Arial isn't its design, so its table isn't used.
        var pdf = ContentEditPdf.Make("BT /FA 11 Tf 72 700 Td (a) Tj ET", fontText: Chars);
        using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(pdf), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify);
        var fonts = PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        var fa = PdfObj.Dict(fonts.Elements["/FA"])!;
        Assert.NotNull(FontKerning.Of(TextFont.For(fa)));
        var widths = PdfObj.Array(fa.Elements["/Widths"])!;
        for (var i = 0; i < widths.Elements.Count; i++) widths.Elements[i] = new PdfSharp.Pdf.PdfReal(PdfObj.Num(widths.Elements[i]) * 1.1);
        var copy = (PdfSharp.Pdf.PdfDictionary)fa.Clone();
        Assert.Null(FontKerning.Of(TextFont.For(copy)));
    }
}
