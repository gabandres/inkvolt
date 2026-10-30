using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Characters without Unicode in TeX's fonts (Matterhorn 31-027, veraPDF 7.21.7-1): the TeX glyph names and math
/// encodings (<see cref="TexGlyphs"/>), and the ToUnicode Make Accessible writes for them (<see cref="FontUnicode"/>).
/// </summary>
public class FontUnicodeTests
{
    [Theory]
    [InlineData("parenleftbig", "(")]
    [InlineData("bracketleftbigg", "[")]
    [InlineData("bracketrightBigg", "]")]
    [InlineData("summationtext", "∑")]
    [InlineData("summationdisplay", "∑")]
    [InlineData("integraldisplay", "∫")]
    [InlineData("uniondisplay", "⋃")]
    [InlineData("radicalBig", "√")]
    [InlineData("bracketlefttp", "⎡")]
    [InlineData("braceleftmid", "⎨")]
    [InlineData("floorleftbig", "⌊")]
    [InlineData("angbracketrightBig", "⟩")]
    [InlineData("hatwide", "̂")]
    [InlineData("element", "∈")]
    [InlineData("epsilon1", "ε")]
    [InlineData("arrowhookleft", "↪")]
    [InlineData("zerooldstyle", "0")]
    [InlineData("minusplus", "∓")]
    [InlineData("dotlessj", "ȷ")]
    [InlineData("notatexname", null)]
    public void Tex_glyph_names_read_as_text(string name, string? text) => Assert.Equal(text, TexGlyphs.ToUnicode(name));

    [Theory]
    [InlineData("ABCDEF+CMSY10", 50, "element")]
    [InlineData("CMSY7", 0, "minus")]
    [InlineData("XYZABC+CMMI10", 27, "sigma")]
    [InlineData("CMMIB10", 11, "alpha")]
    [InlineData("THPNLT+CMEX9", 80, "summationtext")]
    [InlineData("CMEX10", 20, "bracketleftbigg")]
    [InlineData("Times-Roman", 50, null)]
    [InlineData("CMSY10", 200, null)]
    public void Tex_math_encodings_name_codes_by_the_fonts_family(string font, int code, string? name) => Assert.Equal(name, TexGlyphs.NameIn(font, code));

    [Fact]
    public void Adobe_glyph_list_math_and_greek_names_count_as_text_as_veraPDF_reads_them()
    {
        var doc = new A11yDoc { Font = A11yDoc.Type3Font.Replace("[65 /A /B]", "[65 /element /sigma]").Replace("/A 9 0 R /B 9 0 R", "/element 9 0 R /sigma 9 0 R") };
        Assert.DoesNotContain("31-027", doc.Check().FailedConditions);
    }

    [Fact]
    public void Make_accessible_gives_tex_glyph_names_a_tounicode()
    {
        var pdf = new A11yDoc
        {
            Font = A11yDoc.Type3Font.Replace("[65 /A /B]", "[65 /summationdisplay /bracketleftbigg]").Replace("/A 9 0 R /B 9 0 R", "/summationdisplay 9 0 R /bracketleftbigg 9 0 R"),
        }.Build();
        Assert.Contains("31-027", AccessibilityCheck.Run(pdf, null).FailedConditions);

        var tagged = Tag(pdf);

        Assert.DoesNotContain("31-027", AccessibilityCheck.Run(tagged, null).FailedConditions);
        var cmap = ToUnicode(tagged);
        Assert.Contains("<41> <2211>", cmap);
        Assert.Contains("<42> <005B>", cmap);
    }

    [Fact]
    public void A_math_font_without_glyph_names_gets_its_tex_encoding()
    {
        // CMSY10 without an Encoding or a program to read one from: the codes are OMS's (50 is element, 0 minus).
        var doc = new A11yDoc
        {
            Font = "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+CMSY10 /FirstChar 0 /LastChar 127 /FontDescriptor 11 0 R >>",
            More = ["<< /Type /FontDescriptor /FontName /ABCDEF+CMSY10 /Flags 4 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 750 /Descent -250 /CapHeight 700 /StemV 80 >>"],
            Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (x2\\000) Tj ET EMC",
        };
        var pdf = doc.Build();
        Assert.Contains("31-027", AccessibilityCheck.Run(pdf, null).FailedConditions);

        var tagged = Tag(pdf);

        Assert.DoesNotContain("31-027", AccessibilityCheck.Run(tagged, null).FailedConditions);
        var cmap = ToUnicode(tagged);
        Assert.Contains("<32> <2208>", cmap);
        Assert.Contains("<00> <2212>", cmap);
        Assert.Contains("<78> <00A7>", cmap); // 120: section
    }

    private static byte[] Tag(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var plan = AutoTag.Plan(engine, pdf, null);
        return AutoTag.Write(pdf, null, plan, new AccessibleOptions { Title = "A test", Language = "en" });
    }

    private static string ToUnicode(byte[] pdf)
    {
        using var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        var font = (PdfDictionary)PdfObj.Resolve(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/Font"])!.Elements["/F1"])!;
        var tu = PdfObj.Dict(font.Elements["/ToUnicode"]);
        Assert.NotNull(tu);
        return Encoding.Latin1.GetString(PdfObj.StreamBytes(tu));
    }
}
