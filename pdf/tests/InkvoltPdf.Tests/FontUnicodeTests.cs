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

    /// <summary>
    /// A Type 3 bitmap font as dvips and Ghostscript write TeX's PK fonts: each glyph named by its code ("a65"), so no
    /// name says what it is; <paramref name="name"/> its /Name (the TeX font, or dvips's own "Fa").
    /// </summary>
    private static A11yDoc Bitmap(string name, int[] codes, string text, string glyphPrefix = "a", int offset = 0)
    {
        var procs = string.Join(' ', codes.Select(c => $"/{glyphPrefix}{c + offset} 9 0 R"));
        var differences = string.Join(' ', codes.Select(c => $"{c} /{glyphPrefix}{c + offset}"));
        var widths = string.Join(' ', Enumerable.Range(codes.Min(), codes.Max() - codes.Min() + 1).Select(_ => "600"));
        return new A11yDoc
        {
            Font = $"<< /Type /Font /Subtype /Type3 /Name /{name} /FontBBox [0 0 600 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << {procs} >> " +
                   $"/Encoding << /Type /Encoding /Differences [{differences}] >> /FirstChar {codes.Min()} /LastChar {codes.Max()} /Widths [{widths}] /Resources << >> >>",
            Content = $"/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td ({text}) Tj ET EMC",
        };
    }

    private static string Hex(int code, string text) => $"<{code:X2}> <{Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(text))}>";

    [Fact]
    public void A_type3_bitmap_font_named_by_codes_reads_its_letters()
    {
        // A TeX text font (CMR10) whose glyphs are named by their codes: its codes are OT1's characters.
        var pdf = Bitmap("CMR10", [34, 44, 48, 65, 66, 67, 97], "ABC,0a\\042").Build();
        Assert.Contains("31-027", AccessibilityCheck.Run(pdf, null).FailedConditions);
        var tagged = Tag(pdf);
        Assert.DoesNotContain("31-027", AccessibilityCheck.Run(tagged, null).FailedConditions);
        var cmap = ToUnicode(tagged);
        foreach (var (code, text) in new[] { (65, "A"), (66, "B"), (67, "C"), (97, "a"), (48, "0"), (44, ","), (34, "”") })
            Assert.Contains(Hex(code, text), cmap);
        using var engine = PdfEngine.Open(tagged, InputFileTypes.PDF, null);
        Assert.Contains("ABC,0a", engine.GetText(0, cache: false).Text);
    }

    [Theory]
    [InlineData("Fa")]     // dvips's own name for a bitmap font
    [InlineData("T3Font")]
    public void A_type3_bitmap_font_whose_name_says_nothing_is_left_alone(string name)
    {
        // It could as well be CMSY10 (code 65 a calligraphic A, 48 a prime) or MSAM10: no text is better than wrong text.
        var tagged = Tag(Bitmap(name, [48, 65, 66], "AB0").Build());
        Assert.Contains("31-027", AccessibilityCheck.Run(tagged, null).FailedConditions);
    }

    [Theory]
    [InlineData("CMR10", 12, "ﬁ")] // OT1: the fi ligature
    [InlineData("CMR10", 34, "”")]
    [InlineData("CMR10", 36, "$")]
    [InlineData("CMTI10", 36, "£")] // the italic fonts have sterling where the upright ones have dollar
    [InlineData("CMBXTI10", 36, "£")]
    [InlineData("CMSLTI10", 36, "£")]
    [InlineData("CMBX12", 123, "–")]
    [InlineData("CMMI10", 11, "α")] // OML
    [InlineData("CMSY10", 50, "∈")] // OMS
    [InlineData("CMTT10", 34, "\"")] // typewriter: ASCII
    public void A_type3_bitmap_font_of_a_tex_family_reads_by_its_encoding(string family, int code, string text)
    {
        var pdf = Bitmap(family, [code, 65], "A").Build();
        Assert.Contains(Hex(code, text), ToUnicode(Tag(pdf)));
    }

    [Fact]
    public void A_type3_font_whose_glyph_numbers_arent_its_codes_is_left_alone()
    {
        // "g1", "g2" at 65 and 66: numbered in drawing order, not by code, so the number says nothing.
        var tagged = Tag(Bitmap("Fa", [65, 66], "AB", glyphPrefix: "g", offset: -64).Build());
        Assert.Contains("31-027", AccessibilityCheck.Run(tagged, null).FailedConditions);
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
