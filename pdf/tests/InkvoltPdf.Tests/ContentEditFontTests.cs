using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Edit Text: which glyphs a page font really has (Type 1, CFF and TrueType programs) and what a new code adds to the font.</summary>
public class ContentEditFontTests
{
    /// <summary>A one-page PDF showing "ab" in a simple font (/F1) with the given dictionary and descriptor extras.</summary>
    private static byte[] WithFont(string fontDict, string programObject, string show = "(ab) Tj")
    {
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream($"BT /F1 20 Tf 72 700 Td {show} ET"),
            fontDict,
            "<< /Type /FontDescriptor /FontName /ABCDEF+Test /Flags 32 /FontBBox [0 -200 1000 800] /Ascent 800 /Descent -200 /ItalicAngle 0 /StemV 80 /CapHeight 700 " + programObject.Split('|')[0] + " >>",
            programObject.Split('|')[1],
        };
        return Core2Pdf.Build(objects);
    }

    /// <summary>A Type 1 program (cleartext + eexec-encrypted part) whose CharStrings hold the given glyph names.</summary>
    private static string Type1Program(params string[] names)
    {
        var clear = "%!PS-AdobeFont-1.0: Test\n/FontName /Test def\n/Encoding StandardEncoding def\ncurrentfile eexec\n";
        var priv = new StringBuilder("dup /Private 8 dict dup begin /RD{string currentfile exch readstring pop}executeonly def end\n");
        priv.Append($"2 index /CharStrings {names.Length} dict dup begin\n");
        foreach (var n in names) priv.Append($"/{n} 4 RD \u0001\u0002\u0003\u0004 ND\n");
        priv.Append("end\nend\nmark currentfile closefile\n");
        var plain = Encoding.Latin1.GetBytes("abcd" + priv); // four random bytes lead the encrypted part
        var enc = new byte[plain.Length];
        ushort r = 55665;
        for (var i = 0; i < plain.Length; i++)
        {
            var c = (byte)(plain[i] ^ (r >> 8));
            r = (ushort)((c + r) * 52845 + 22719);
            enc[i] = c;
        }
        var body = clear + Encoding.Latin1.GetString(enc) + "\n" + new string('0', 64) + "\ncleartomark\n";
        return "/FontFile 7 0 R|" + Core2Pdf.Stream(body, $"/Length1 {clear.Length} /Length2 {enc.Length} /Length3 0");
    }

    [Fact]
    public void Type1CharStringsDecideWhichGlyphsExist()
    {
        var pdf = WithFont("<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Test /FirstChar 97 /LastChar 99 /Widths [500 600 700] " +
            "/Encoding << /Type /Encoding /Differences [97 /a /b /c] >> /FontDescriptor 6 0 R >>", Type1Program(".notdef", "a", "b"));
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single();
        Assert.Equal("ab", run.Text);
        Assert.Null(run.Blocked);
        Assert.Empty(run.Check("ba").Borrowed);
        Assert.Equal(["c"], run.Check("abc").Borrowed); // a width, but no glyph in the subset: a stand-in font draws it
        var edited = ContentEditor.ReplaceText(pdf, null, run, "bab");
        Assert.Contains("(bab) Tj", ContentEditPdf.Content(edited));
    }

    [Fact]
    public void Type1ProgramParsing()
    {
        var program = Type1Program(".notdef", "eacute", "f_i");
        var stream = program[(program.IndexOf("stream\n", StringComparison.Ordinal) + 7)..program.LastIndexOf("\nendstream", StringComparison.Ordinal)];
        var t1 = InkvoltPdf.Core.Type1Program.Read(Encoding.Latin1.GetBytes(stream));
        Assert.NotNull(t1);
        Assert.True(t1!.HasName("eacute"));
        Assert.True(t1.HasName("f_i"));
        Assert.False(t1.HasName("a"));
    }

    /// <summary>A minimal CFF (one font) whose charset names the glyphs by SID, CharStrings all "endchar".</summary>
    private static byte[] Cff(params int[] sids)
    {
        static byte[] Index(params byte[][] items)
        {
            if (items.Length == 0) return [0, 0];
            var o = new List<byte> { (byte)(items.Length >> 8), (byte)items.Length, 2, 0, 1 };
            var off = 1;
            foreach (var it in items)
            {
                off += it.Length;
                o.Add((byte)(off >> 8));
                o.Add((byte)off);
            }
            foreach (var it in items) o.AddRange(it);
            return [.. o];
        }
        static byte[] Int(int v) => [29, (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];
        var header = new byte[] { 1, 0, 4, 1 };
        var name = Index(Encoding.ASCII.GetBytes("Test"));
        var strings = Index();
        var gsubrs = Index();
        var n = sids.Length + 1;
        // Top DICT size is fixed (two 5-byte ints and their operators): 12 bytes.
        var topIndexSize = Index(new byte[12]).Length;
        var charsetAt = header.Length + name.Length + topIndexSize + strings.Length + gsubrs.Length;
        var charset = new List<byte> { 0 };
        foreach (var s in sids) { charset.Add((byte)(s >> 8)); charset.Add((byte)s); }
        var charStringsAt = charsetAt + charset.Count;
        var top = Index([.. Int(charsetAt), 15, .. Int(charStringsAt), 17]);
        var charStrings = Index([.. Enumerable.Range(0, n).Select(_ => new byte[] { 14 })]);
        return [.. header, .. name, .. top, .. strings, .. gsubrs, .. charset, .. charStrings];
    }

    [Fact]
    public void CffCharsetDecidesWhichGlyphsExist()
    {
        var cff = Cff(66, 67); // a, b (CFF standard strings)
        var parsed = CffProgram.Read(cff);
        Assert.NotNull(parsed);
        Assert.True(parsed!.HasName("a"));
        Assert.False(parsed.HasName("c"));

        var body = Encoding.Latin1.GetString(cff);
        var pdf = WithFont("<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Test /FirstChar 97 /LastChar 99 /Widths [500 600 700] " +
            "/Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>", "/FontFile3 7 0 R|" + Core2Pdf.Stream(body, "/Subtype /Type1C"));
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single();
        Assert.Empty(run.Check("bba").Borrowed);
        Assert.Equal(["c"], run.Check("cab").Borrowed);
    }

    [Fact]
    public void NonEmbeddedStandardFontsTakeAnyCharacterOfTheirEncoding()
    {
        var pdf = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 20 Tf 72 700 Td (Total: 12) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single();
        var check = run.Check("Zoë – €5 中");
        Assert.Empty(check.Missing);
        Assert.Equal(["中"], check.Borrowed); // not in WinAnsi: a CJK font on this PC stands in
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Zoë – €5");
        Assert.Contains("Zoë – €5", ContentEditPdf.Text(edited));
    }

    [Fact]
    public void ANewCodeGetsItsWidthFromTheProgram()
    {
        // /FA with its widths cut down to "H" only: "W" is in the program but not in /Widths.
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td (H) Tj ET");
        using (var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify))
        {
            var font = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/Font"])!.Elements["/FA"])!;
            font.Elements["/FirstChar"] = new PdfInteger('H');
            font.Elements["/LastChar"] = new PdfInteger('H');
            font.Elements["/Widths"] = new PdfArray(d, new PdfInteger(722));
            PdfObj.Dict(font.Elements["/FontDescriptor"])!.Elements["/MissingWidth"] = new PdfInteger(333);
            using var ms = new MemoryStream();
            d.Save(ms, false);
            pdf = ms.ToArray();
        }
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single();
        var edited = ContentEditor.ReplaceText(pdf, null, run, "HW");
        using var e = PdfReader.Open(new MemoryStream(edited), PdfDocumentOpenMode.Import);
        var fa = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(e.Pages[0].Elements["/Resources"])!.Elements["/Font"])!.Elements["/FA"])!;
        Assert.Equal('H', PdfObj.Int(fa.Elements["/FirstChar"]));
        Assert.Equal('W', PdfObj.Int(fa.Elements["/LastChar"]));
        var widths = PdfObj.Array(fa.Elements["/Widths"])!;
        Assert.InRange(PdfObj.Num(widths, 'W' - 'H'), 942, 945); // Arial's W
        Assert.Equal(333, PdfObj.Num(widths, 'I' - 'H')); // codes in the gap keep the width viewers gave them
        // MuPDF places the next glyph after it: the run is as wide as H + W.
        var after = ContentEditor.Read(edited, null, 0).Runs.Single();
        Assert.Equal((722 + 943) / 1000.0 * 20, after.OldWidth, 0);
    }

    [Fact]
    public void ANewCidGetsItsTextIntoToUnicodeAndItsWidthIntoW()
    {
        var seed = ContentEditPdf.Make("");
        var pdf = ContentEditPdf.WithoutSpace(ContentEditPdf.Make("BT /FU 20 Tf 72 692 Td " + ContentEditPdf.Cid(seed, "Hello") + " Tj ET"));
        var run = ContentEditor.Read(pdf, null, 0).Runs.Single();
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello Hello");
        Assert.Equal("Hello Hello", ContentEditor.Read(edited, null, 0).Runs.Single().Text);
        using var e = PdfReader.Open(new MemoryStream(edited), PdfDocumentOpenMode.Import);
        var fu = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(e.Pages[0].Elements["/Resources"])!.Elements["/Font"])!.Elements["/FU"])!;
        var cmap = Encoding.Latin1.GetString(PdfObj.StreamBytes(PdfObj.Dict(fu.Elements["/ToUnicode"])!));
        Assert.True(cmap.Contains("<0003> <0020>"), cmap + "\n" + ContentEditPdf.Content(edited));
        Assert.Contains("Hello Hello", ContentEditPdf.Text(edited));
    }
}
