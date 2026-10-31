using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;
using MuPDFCore;
using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

public class PdfATests
{
    private static string Xmp(byte[] pdf)
    {
        using var doc = Core2Pdf.Open(pdf);
        return Encoding.UTF8.GetString(PdfObj.Dict(doc.Internals.Catalog.Elements["/Metadata"])!.Stream!.Value);
    }

    private static byte[] ScriptsPdf() =>
        Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R /OpenAction 5 0 R /AA << /WC 5 0 R >> /Names << /JavaScript << /Names [(a) 5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [6 0 R 7 0 R 8 0 R 10 0 R] /AA << /O 5 0 R >> >>",
            Core2Pdf.Stream("0 0 1 rg 72 72 100 100 re f"),
            "<< /Type /Action /S /JavaScript /JS (app.alert(1)) >>",
            "<< /Type /Annot /Subtype /Link /Rect [72 600 200 620] /A << /S /Launch /F (calc.exe) >> >>",
            "<< /Type /Annot /Subtype /Square /Rect [72 500 200 560] /F 2 /AP << /N 9 0 R >> >>",
            "<< /Type /Annot /Subtype /Square /Rect [72 400 200 460] /AP << /N 9 0 R /D 9 0 R >> >>",
            Core2Pdf.Stream("0 0 1 RG 2 w 1 1 126 58 re S", "/Type /XObject /Subtype /Form /BBox [0 0 128 60]"),
            "<< /Type /Annot /Subtype /Link /Rect [72 300 200 320] /A << /S /Named /N /Print >> >>",
        ]);

    private static byte[] StandardFontsPdf() =>
        Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 24 Tf 72 700 Td (Archive \\222quote\\222 caf\\351) Tj ET BT /F2 12 Tf 72 650 Td (Courier text) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
        ]);

    [Fact]
    public void TheSrgbProfileIsAWellFormedIccProfile()
    {
        var p = IccProfiles.Srgb();
        Assert.Equal(p.Length, BinaryPrimitives.ReadInt32BigEndian(p));
        Assert.Equal("acsp", Encoding.ASCII.GetString(p, 36, 4));
        Assert.Equal("mntr", Encoding.ASCII.GetString(p, 12, 4));
        Assert.Equal("RGB ", Encoding.ASCII.GetString(p, 16, 4));
        Assert.Equal("XYZ ", Encoding.ASCII.GetString(p, 20, 4));
        Assert.Equal(2, p[8]); // version 2.x
        var count = BinaryPrimitives.ReadInt32BigEndian(p.AsSpan(128));
        var tags = Enumerable.Range(0, count).Select(i => Encoding.ASCII.GetString(p, 132 + 12 * i, 4)).ToHashSet();
        Assert.Superset(new HashSet<string> { "desc", "cprt", "wtpt", "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC" }, tags);
        for (var i = 0; i < count; i++)
        {
            var offset = BinaryPrimitives.ReadInt32BigEndian(p.AsSpan(132 + 12 * i + 4));
            var size = BinaryPrimitives.ReadInt32BigEndian(p.AsSpan(132 + 12 * i + 8));
            Assert.True(offset % 4 == 0 && offset + size <= p.Length);
        }
        // The curve runs from 0 to 1, and mid-grey is about 21.4% light (sRGB 0.5).
        var trc = Enumerable.Range(0, count).First(i => Encoding.ASCII.GetString(p, 132 + 12 * i, 4) == "rTRC");
        var at = BinaryPrimitives.ReadInt32BigEndian(p.AsSpan(132 + 12 * trc + 4));
        Assert.Equal("curv", Encoding.ASCII.GetString(p, at, 4));
        Assert.Equal(0, BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(at + 12)));
        Assert.Equal(65535, BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(at + 12 + 2 * 1023)));
        Assert.InRange(BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(at + 12 + 2 * 512)) / 65535.0, 0.20, 0.23);
    }

    [Fact]
    public void ASimplePdfBecomesPdfA2b()
    {
        var source = TestPdf.Make(2);
        Assert.NotEmpty(PdfA.Validate(source)); // no output intent, no pdfaid
        var result = PdfA.Convert(source, null);
        Assert.Empty(PdfA.Validate(result.Data));
        var xmp = Xmp(result.Data);
        Assert.Contains("pdfaid", xmp);
        Assert.Contains("<pdfaid:part>2</pdfaid:part>", xmp);
        Assert.Contains("<pdfaid:conformance>B</pdfaid:conformance>", xmp);
        Assert.Contains("Synthetic", xmp); // dc:title from the document properties
        using (var doc = Core2Pdf.Open(result.Data))
        {
            var intent = PdfObj.Dict(PdfObj.Array(doc.Internals.Catalog.Elements["/OutputIntents"])!.Elements[0])!;
            Assert.Equal("GTS_PDFA1", PdfObj.Name(intent.Elements["/S"]));
            Assert.Equal(3, PdfObj.Int(PdfObj.Dict(intent.Elements["/DestOutputProfile"])!.Elements["/N"]));
        }
        Assert.Equal(TestPdf.PageNumbers(source), TestPdf.PageNumbers(result.Data));
        Assert.Contains(result.Changes, c => c.Contains("output intent"));
    }

    [Fact]
    public void ScriptsActionsAndHiddenCommentsGo()
    {
        var pdf = ScriptsPdf();
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        using var doc = Core2Pdf.Open(result.Data);
        var catalog = doc.Internals.Catalog;
        Assert.False(catalog.Elements.ContainsKey("/AA"));
        Assert.False(catalog.Elements.ContainsKey("/OpenAction") && PdfObj.Name(PdfObj.Dict(catalog.Elements["/OpenAction"])?.Elements["/S"]) == "JavaScript");
        var annots = PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().ToList();
        // The hidden square is gone; the link that launched a program went with Sanitize; the rest print.
        Assert.Single(annots, a => PdfObj.Name(a.Elements["/Subtype"]) == "Square");
        Assert.All(annots, a => Assert.Equal(4, PdfObj.Int(a.Elements["/F"])! & 4));
        Assert.All(annots, a => Assert.Null(PdfObj.Dict(a.Elements["/A"]))); // Launch and Named Print removed
        Assert.False(PdfObj.Dict(annots.Single(a => PdfObj.Name(a.Elements["/Subtype"]) == "Square").Elements["/AP"])!.Elements.ContainsKey("/D"));
        Assert.Contains(result.Changes, c => c.Contains("hidden comment"));
    }

    [Fact]
    public void StandardFontsAreEmbeddedFromWindowsTwins()
    {
        var pdf = StandardFontsPdf();
        var before = Core2Pdf.AllText(pdf);
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        Assert.Equal(before, Core2Pdf.AllText(result.Data));
        using var doc = Core2Pdf.Open(result.Data);
        var fonts = PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        foreach (var key in new[] { "/F1", "/F2" })
        {
            var f = PdfObj.Dict(fonts.Elements[key])!;
            Assert.Equal("TrueType", PdfObj.Name(f.Elements["/Subtype"]));
            Assert.NotNull(PdfObj.Dict(PdfObj.Dict(f.Elements["/FontDescriptor"])!.Elements["/FontFile2"]));
        }
        // Courier had no encoding (StandardEncoding): WinAnsi plus differences for the codes it maps elsewhere.
        var courier = PdfObj.Dict(fonts.Elements["/F2"])!;
        Assert.Equal("WinAnsiEncoding", PdfObj.Name(PdfObj.Dict(courier.Elements["/Encoding"])!.Elements["/BaseEncoding"]));
        Assert.Contains(result.Changes, c => c.Contains("2 standard fonts embedded"));
    }

    private static byte[] OneFont(string font) => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 24 Tf 72 700 Td (ri) Tj ET"),
        font,
    ]);

    [Theory]
    [InlineData("Helvetica", false, false)]
    [InlineData("Helvetica-BoldOblique", true, true)]
    [InlineData("Times-Roman", false, false)]
    [InlineData("ABCDEF+Arial,Bold", true, false)]
    [InlineData("Arial,BoldItalic", true, true)]
    [InlineData("Arial-ItalicMT", false, true)]
    [InlineData("ArialMT", false, false)]
    [InlineData("TimesNewRomanPS-BoldMT", true, false)]
    [InlineData("TimesNewRoman,Italic", false, true)]
    [InlineData("CourierNewPSMT", false, false)]
    [InlineData("Courier-Oblique", false, true)]
    public void StandardFacesAreRecognizedWithTheirStyle(string name, bool bold, bool italic)
    {
        var face = PdfA.StandardFace(name);
        Assert.NotNull(face);
        Assert.Equal((bold, italic), (face!.Bold, face.Italic));
    }

    [Theory]
    [InlineData("HelveticaNeue")]
    [InlineData("HelveticaNeue-Bold")]
    [InlineData("Helvetica-Condensed")]
    [InlineData("Arial-Black")]
    [InlineData("ArialNarrow")]
    [InlineData("Arial,Light")]
    [InlineData("TimesTen-Roman")]
    public void OtherDesignsOfTheFamilyAreNotStandardFaces(string name) => Assert.Null(PdfA.StandardFace(name));

    [Fact]
    public void ABoldFontIsEmbeddedBoldAndWidthsMustFit()
    {
        // "i" is 278 wide in Arial Bold and 222 in Arial: a bold font named "Arial,Bold" with bold widths gets the bold face.
        var bold = PdfA.Convert(OneFont("<< /Type /Font /Subtype /TrueType /BaseFont /Arial,Bold /FirstChar 105 /LastChar 114 /Widths [278 0 0 0 0 0 0 0 0 389] /Encoding /WinAnsiEncoding >>"), null);
        Assert.Empty(PdfA.Validate(bold.Data));
        using (var doc = Core2Pdf.Open(bold.Data))
        {
            var f = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/Font"])!.Elements["/F1"])!;
            Assert.EndsWith("Arial-Bold", PdfObj.Name(f.Elements["/BaseFont"]));
            Assert.Equal(278, PdfObj.Num(PdfObj.Array(f.Elements["/Widths"])!, 'i' - PdfObj.Int(f.Elements["/FirstChar"])!.Value));
        }
        // Widths that aren't the Windows face's (another design under a standard name) refuse, saying why.
        var narrow = OneFont("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 105 /LastChar 105 /Widths [400] >>");
        Assert.Contains(PdfA.Check(narrow, null), b => b.Contains("widths"));
        Assert.Contains(PdfA.Check(OneFont("<< /Type /Font /Subtype /Type1 /BaseFont /HelveticaNeue >>"), null), b => b.Contains("HelveticaNeue"));
    }

    [Fact]
    public void DocumentPropertiesAndXmpSayTheSame()
    {
        using var source = new PdfDocument();
        source.Info.Title = "  Spaced\u0001 title  ";
        source.Info.Author = "Ada ";
        source.AddPage();
        using var ms = new MemoryStream();
        source.Save(ms);
        var result = PdfA.Convert(ms.ToArray(), null);
        Assert.Empty(PdfA.Validate(result.Data));
        using var doc = Core2Pdf.Open(result.Data);
        Assert.Equal("Spaced title", doc.Info.Title);
        Assert.Equal("Ada", doc.Info.Author);
        var xmp = Xmp(result.Data);
        Assert.Contains(">Spaced title<", xmp);
        Assert.Contains(">Ada<", xmp);
    }

    [Fact]
    public void WhatCantBeKeptRefusesTheConversion()
    {
        var cmyk = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.Stream("0 0 0 1 k 72 72 100 100 re f"),
        ]);
        var ex = Assert.Throws<PdfAException>(() => PdfA.Convert(cmyk, null));
        Assert.Contains(ex.Blockers, b => b.Contains("CMYK"));
        Assert.NotEmpty(PdfA.Check(cmyk, null));

        var symbol = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 24 Tf 72 700 Td (abc) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Symbol >>",
        ]);
        Assert.Contains(PdfA.Check(symbol, null), b => b.Contains("Symbol"));
        Assert.Contains(PdfA.Check(Core2SignatureTests.Signed(), null), b => b.Contains("signed"));
        Assert.Empty(PdfA.Check(TestPdf.Make(1), null));
    }

    [Fact]
    public void ProtectedFilesNeedTheirPermissionsPasswordAndComeOutUnencrypted()
    {
        var locked = PdfSecurity.Protect(TestPdf.Make(1), null, "open", "owner");
        Assert.Throws<OwnerPasswordRequiredException>(() => PdfA.Convert(locked, "open"));
        var result = PdfA.Convert(locked, "owner");
        Assert.Empty(PdfA.Validate(result.Data));
        using var engine = PdfEngine.Open(result.Data, InputFileTypes.PDF, null);
        Assert.Contains("Page 1", engine.GetText(0).Text);
        Assert.Contains(result.Changes, c => c.Contains("password"));
    }

    private const string PhotoshopXmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\" xmlns:made=\"http://example.com/made/\"><made:Tool>Not in any schema</made:Tool></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>";

    /// <summary>A picture and a page with XMP packets of their own, in properties PDF/A's schemas don't have.</summary>
    private static byte[] OwnMetadataPdf() => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Metadata 7 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>",
        Core2Pdf.Stream("q 100 0 0 100 50 50 cm /Im0 Do Q"),
        Core2Pdf.Stream("FF0000>", "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Metadata 6 0 R /Filter /ASCIIHexDecode"),
        Core2Pdf.Stream(PhotoshopXmp, "/Type /Metadata /Subtype /XML"),
        Core2Pdf.Stream(PhotoshopXmp, "/Type /Metadata /Subtype /XML"),
    ]);

    [Fact]
    public void PicturesAndPagesLoseTheirOwnMetadata()
    {
        var pdf = OwnMetadataPdf();
        Assert.Contains(PdfA.Validate(pdf), p => p.Contains("metadata of its own"));
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        using (var doc = Core2Pdf.Open(result.Data))
        {
            Assert.NotNull(PdfObj.Dict(doc.Internals.Catalog.Elements["/Metadata"]));
            Assert.False(doc.Pages[0].Elements.ContainsKey("/Metadata"));
            var image = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/Im0"])!;
            Assert.False(image.Elements.ContainsKey("/Metadata"));
        }
        Assert.DoesNotContain("made:Tool", Encoding.Latin1.GetString(result.Data));
        Assert.Contains(result.Changes, c => c.Contains("2 pictures' and pages' own metadata"));
        using var before = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        using var after = PdfEngine.Open(result.Data, InputFileTypes.PDF, null);
        Assert.Equal(before.Render(0, 1).Pixels, after.Render(0, 1).Pixels);
    }

    private static readonly string LongRole = "Caption,Figure" + string.Concat(Enumerable.Repeat("#20Caption#20Char", 12));

    /// <summary>A role name over PDF/A's 127 bytes, as Word's styles make one (nist-sp800-63-3.pdf), in the role map and on the element.</summary>
    private static byte[] LongRolePdf(string content = "BT ET") => Core2Pdf.Build(
    [
        $"<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot << /Type /StructTreeRoot /RoleMap << /{LongRole} /P >> /K 5 0 R >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
        Core2Pdf.Stream(content),
        $"<< /Type /StructElem /S /{LongRole} /P null >>",
    ]);

    [Fact]
    public void NamesOverPdfALimitAreShortenedTogether()
    {
        var pdf = LongRolePdf();
        Assert.Contains(PdfA.Validate(pdf), p => p.Contains("127"));
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        Assert.Contains(result.Changes, c => c.Contains("1 name"));
        using var doc = Core2Pdf.Open(result.Data);
        var root = PdfObj.Dict(doc.Internals.Catalog.Elements["/StructTreeRoot"])!;
        var key = Assert.Single(PdfObj.Dict(root.Elements["/RoleMap"])!.Elements.Keys);
        Assert.InRange(Encoding.UTF8.GetByteCount(key) - 1, 1, 127);
        Assert.Equal(key, "/" + PdfObj.Name(PdfObj.Dict(root.Elements["/K"])!.Elements["/S"]));
        Assert.Equal("P", PdfObj.Name(PdfObj.Dict(root.Elements["/RoleMap"])!.Elements[key]));
    }

    [Fact]
    public void ALongNameInPageContentRefuses()
    {
        // The page's content refers to it by name; a rewrite of the content is more than a copy should do.
        var blockers = PdfA.Check(LongRolePdf($"/{LongRole} BMC EMC"), null);
        Assert.Contains(blockers, b => b.Contains("127"));
    }

    /// <summary>A form as the IRS sends it: Reader usage rights in the catalog's /Perms (a /ByteRange, so it looks signed), no signed field.</summary>
    private static byte[] UsageRightsPdf(string perm = "/UR3") => Core2Pdf.Form(
        ["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /V (Ada) /P 3 0 R >>"],
        catalogExtra: $"/Perms << {perm} << /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 10 20 30] /Contents <00> /Reference [<< /TransformMethod /UR3 >>] >> >>");

    [Fact]
    public void UsageRightsAreNoSignatureAndTheCopySaysTheyWent()
    {
        var pdf = UsageRightsPdf();
        Assert.True(Incremental.LooksSigned(pdf));
        Assert.Empty(PdfA.Check(pdf, null));
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        Assert.Contains(result.Changes, c => c.Contains("usage rights"));
        Assert.Contains("name", FormEditor.Read(result.Data, null).Select(f => f.FieldName));
        using var doc = Core2Pdf.Open(result.Data);
        Assert.False(doc.Internals.Catalog.Elements.ContainsKey("/Perms"));

        // A plain form says nothing about them.
        Assert.DoesNotContain(PdfA.Convert(Core2Pdf.Form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"]), null).Changes, c => c.Contains("usage rights"));
    }

    [Fact]
    public void ACertificationWithoutASignedFieldStillRefuses()
    {
        // Somebody certified it, even if no field shows it: a rewrite must not drop that quietly.
        var blockers = PdfA.Check(UsageRightsPdf("/DocMDP"), null);
        Assert.Contains(blockers, b => b.Contains("certified"));
    }

    private static byte[] MarksPdf() =>
        TextStamps.Put(TextStamps.Put(TestPdf.Make(1), null, 0, new RectD(300, 400, 14, 14), StampKind.Check, "", 12), null, 0, new RectD(330, 400, 14, 14), StampKind.Cross, "", 12);

    [Fact]
    public void FillAndSignMarksConvertWithTheirSymbolsEmbedded()
    {
        var pdf = MarksPdf();
        Assert.Empty(PdfA.Check(pdf, null));
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        Assert.Contains(result.Changes, c => c.Contains("Segoe UI Symbol"));
        Assert.DoesNotContain(result.Changes, c => c.Contains("standard font"));
        using var engine = PdfEngine.Open(result.Data, InputFileTypes.PDF, null);
        // Drawn where the stamps are: dark pixels inside both boxes, none just beside them.
        var image = engine.Render(0, 1);
        int Dark(int x1, int y1, int x2, int y2)
        {
            var bpp = image.Pixels.Length / (image.Width * image.Height);
            var n = 0;
            for (var y = y1; y < y2; y++)
                for (var x = x1; x < x2; x++)
                    if (image.Pixels[(y * image.Width + x) * bpp + 1] < 128) n++;
            return n;
        }
        Assert.True(Dark(300, 400, 314, 414) > 10);
        Assert.True(Dark(330, 400, 344, 414) > 10);
        Assert.Equal(0, Dark(316, 400, 328, 414));
    }

    [Fact]
    public void EveryZapfDingbatsCodeIsCovered()
    {
        // Every symbol in the built-in encoding draws, in a string a form might use (no code falls back to nothing).
        var all = string.Concat(Enumerable.Range(0x21, 0x5E).Concat(Enumerable.Range(0xA1, 0x5E).Where(c => c != 0xF0)).Select(c => $"\\{System.Convert.ToString(c, 8).PadLeft(3, '0')}"));
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2000 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream($"BT /F1 9 Tf 5 40 Td ({all}) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>",
        ]);
        var result = PdfA.Convert(pdf, null);
        Assert.Empty(PdfA.Validate(result.Data));
        using var engine = PdfEngine.Open(result.Data, InputFileTypes.PDF, null);
        var text = engine.GetText(0).Text;
        foreach (var symbol in new[] { "\u2714", "\u2718", "\u2605", "\u25CF", "\u25A0", "\u25C6", "\u2460", "\u2192", "\u27BE" }) Assert.Contains(symbol, text);
    }

    [Fact]
    public void ZapfDingbatsWithItsOwnEncodingOrWidthsRefusesSayingWhy()
    {
        Assert.Contains(PdfA.Check(OneFont("<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats /Encoding << /Differences [114 /a20] >> >>"), null), b => b.Contains("encoding of its own"));
        Assert.Contains(PdfA.Check(OneFont("<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats /FirstChar 114 /LastChar 114 /Widths [5] >>"), null), b => b.Contains("widths"));
    }

    /// <summary>
    /// Checked with veraPDF when INKVOLTPDF_VERAPDF names its launcher (verapdf.bat): every converted sample must pass
    /// PDF/A-2b. Without it this test only converts (veraPDF needs Java; it isn't part of the build).
    /// </summary>
    [Fact]
    public void ConvertedFilesPassVeraPdf()
    {
        var samples = new List<(string Name, byte[] Pdf)>
        {
            ("synthetic", TestPdf.Make(3)),
            ("scripts", ScriptsPdf()),
            ("standard-fonts", StandardFontsPdf()),
            ("bold-arial", OneFont("<< /Type /Font /Subtype /TrueType /BaseFont /Arial,BoldItalic /Encoding /WinAnsiEncoding >>")),
            ("times-mt", OneFont("<< /Type /Font /Subtype /TrueType /BaseFont /TimesNewRomanPS-BoldMT /Encoding /WinAnsiEncoding >>")),
            ("commented", Annotations.AddNote(Annotations.AddTextMarkup(TestPdf.Make(1), null, 0, TextMarkupKind.Highlight, [new RectD(72, 80, 200, 24)],
                AnnotColor.Yellow, "check", "Ada"), null, 0, 300, 300, "A note", "Ada")),
            ("form", FormEditor.SetValues(Core2Pdf.Form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"]),
                null, new Dictionary<string, string> { ["name"] = "Ada Lovelace" })),
            ("own-metadata", OwnMetadataPdf()),
            ("long-role", LongRolePdf()),
            ("usage-rights", UsageRightsPdf()),
            ("marks", MarksPdf()),
            ("export", ExportTestPdf.Make(logo: true)),
            ("stamped", HeaderFooter.Apply(Watermarks.Apply(TestPdf.Make(2), null, [0, 1], new WatermarkOptions { Text = "DRAFT" }), null, [0, 1],
                new HeaderFooterOptions { FooterCenter = "Page <<page>> of <<pages>>" })),
        };
        // INKVOLTPDF_PDFA_INPUTS: more PDFs to convert (a folder); those that can't be converted are skipped.
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_PDFA_INPUTS") is { Length: > 0 } inputs && Directory.Exists(inputs))
            foreach (var f in Directory.GetFiles(inputs, "*.pdf"))
            {
                try
                {
                    if (PdfA.Check(File.ReadAllBytes(f), null).Count == 0) samples.Add((Path.GetFileNameWithoutExtension(f), File.ReadAllBytes(f)));
                }
                catch (OwnerPasswordRequiredException)
                {
                    // restricted: needs its permissions password
                }
            }
        var dir = Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } keep
            ? Directory.CreateDirectory(Path.Combine(keep, "pdfa"))
            : Directory.CreateTempSubdirectory("inkvolt-pdfa-");
        try
        {
            var files = new List<string>();
            foreach (var (name, pdf) in samples)
            {
                var path = Path.Combine(dir.FullName, name + ".pdf");
                File.WriteAllBytes(path, PdfA.Convert(pdf, null).Data);
                files.Add(path);
            }
            if (Environment.GetEnvironmentVariable("INKVOLTPDF_VERAPDF") is not { Length: > 0 } vera || !File.Exists(vera)) return;
            var info = new ProcessStartInfo("cmd.exe") { RedirectStandardOutput = true, UseShellExecute = false };
            foreach (var a in new[] { "/c", vera, "--flavour", "2b", "--format", "text" }.Concat(files)) info.ArgumentList.Add(a);
            using var p = Process.Start(info)!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            Assert.DoesNotContain("FAIL", output);
            Assert.Equal(files.Count, output.Split('\n').Count(l => l.StartsWith("PASS", StringComparison.Ordinal)));
        }
        finally
        {
            if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is not { Length: > 0 }) dir.Delete(true);
        }
    }
}
