using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// PDFs with hand-written page content for Edit Text &amp; Images. The fonts come from PDFsharp (Arial, embedded as
/// subsets): /FA is a simple TrueType font (WinAnsi), /FU a Type0 Identity-H font with a ToUnicode CMap. Both only hold
/// the glyphs of <see cref="FontText"/>. /Im1 is a 4 x 2 red image, /Fm1 a form XObject showing "Form text" in /FA.
/// </summary>
internal static class ContentEditPdf
{
    public const string FontText = "Hello World draft, 2024! Ünï";

    /// <param name="formInherits">/Fm1 has no /Resources of its own (it borrows the page's).</param>
    /// <param name="damagedPart">A last content stream that claims Flate but holds bytes that don't inflate.</param>
    /// <param name="fontText">The characters the fonts hold (default <see cref="FontText"/>).</param>
    /// <param name="faces">Also /FB (Arial Bold, WinAnsi) and /FT (Times New Roman, WinAnsi), holding <paramref name="fontText"/> too.</param>
    public static byte[] Make(string content, int rotate = 0, string? form = null, string[]? extraStreams = null, bool formInherits = false, bool damagedPart = false,
        string fontText = FontText, bool faces = false)
    {
        TestPdf.UseFonts();
        byte[] seed;
        using (var doc = new PdfDocument())
        {
            var page = doc.AddPage();
            page.Width = XUnit.FromPoint(612);
            page.Height = XUnit.FromPoint(792);
            using (var gfx = XGraphics.FromPdfPage(page))
            {
                gfx.DrawString(fontText, new XFont("Arial", 12, XFontStyleEx.Regular, new XPdfFontOptions(PdfFontEncoding.WinAnsi)), XBrushes.Black, new XPoint(72, 72));
                gfx.DrawString(fontText, new XFont("Arial", 12, XFontStyleEx.Regular, new XPdfFontOptions(PdfFontEncoding.Unicode)), XBrushes.Black, new XPoint(72, 96));
                if (faces)
                {
                    gfx.DrawString(fontText, new XFont("Arial", 12, XFontStyleEx.Bold, new XPdfFontOptions(PdfFontEncoding.WinAnsi)), XBrushes.Black, new XPoint(72, 120));
                    gfx.DrawString(fontText, new XFont("Times New Roman", 12, XFontStyleEx.Regular, new XPdfFontOptions(PdfFontEncoding.WinAnsi)), XBrushes.Black, new XPoint(72, 144));
                }
            }
            using var ms = new MemoryStream();
            doc.Save(ms, false);
            seed = ms.ToArray();
        }

        using var d = PdfReader.Open(new MemoryStream(seed), PdfDocumentOpenMode.Modify);
        var p = d.Pages[0];
        var fonts = PdfObj.Dict(PdfObj.Dict(p.Elements["/Resources"])!.Elements["/Font"])!;
        PdfItem? winAnsi = null, unicode = null, bold = null, times = null;
        foreach (var key in fonts.Elements.Keys)
        {
            var f = PdfObj.Dict(fonts.Elements[key])!;
            var baseFont = PdfObj.NameOf(f, "/BaseFont") ?? "";
            if (PdfObj.NameOf(f, "/Subtype") == "/Type0") unicode = fonts.Elements[key];
            else if (baseFont.Contains("Times", StringComparison.OrdinalIgnoreCase)) times = fonts.Elements[key];
            else if (baseFont.Contains("Bold", StringComparison.OrdinalIgnoreCase)) bold = fonts.Elements[key];
            else winAnsi = fonts.Elements[key];
        }
        var res = new PdfDictionary(d);
        var fd = new PdfDictionary(d);
        fd.Elements["/FA"] = winAnsi!;
        fd.Elements["/FU"] = unicode!;
        if (bold is not null) fd.Elements["/FB"] = bold;
        if (times is not null) fd.Elements["/FT"] = times;
        res.Elements["/Font"] = fd;
        var xo = new PdfDictionary(d);
        var image = ImageImport.ImageStream(d, 4, 2, [.. Enumerable.Repeat(new byte[] { 255, 0, 0 }, 8).SelectMany(x => x)], "/DeviceRGB");
        xo.Elements["/Im1"] = image.Reference!;
        if (form is not null)
        {
            var formRes = new PdfDictionary(d);
            var ffd = new PdfDictionary(d);
            ffd.Elements["/FA"] = winAnsi!;
            formRes.Elements["/Font"] = ffd;
            var fx = new PdfDictionary(d);
            fx.Elements["/Im1"] = image.Reference!;
            formRes.Elements["/XObject"] = fx;
            var fm = PdfObj.FormXObject(d, Encoding.Latin1.GetBytes(form), 0, 0, 612, 792, formRes);
            if (formInherits) fm.Elements.Remove("/Resources");
            xo.Elements["/Fm1"] = fm.Reference!;
        }
        res.Elements["/XObject"] = xo;
        p.Elements["/Resources"] = res;
        if (extraStreams is null) p.Elements["/Contents"] = PdfObj.AddStream(d, Encoding.Latin1.GetBytes(content)).Reference!;
        else
        {
            var arr = new PdfArray(d);
            foreach (var part in new[] { content }.Concat(extraStreams)) arr.Elements.Add(PdfObj.AddStream(d, Encoding.Latin1.GetBytes(part), compress: false).Reference!);
            if (damagedPart)
            {
                var bad = new PdfDictionary(d);
                bad.CreateStream([0x78, 0x9C, 0xFF, 0xFE, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
                bad.Elements["/Filter"] = new PdfName("/FlateDecode");
                d.Internals.AddObject(bad);
                arr.Elements.Add(bad.Reference!);
            }
            p.Elements["/Contents"] = arr;
        }
        if (rotate != 0) p.Elements["/Rotate"] = new PdfInteger(rotate);
        using var outMs = new MemoryStream();
        d.Save(outMs, false);
        return outMs.ToArray();
    }

    /// <summary>The same PDF with the space taken out of /FU's ToUnicode CMap.</summary>
    public static byte[] WithoutSpace(byte[] pdf)
    {
        using var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify);
        var fonts = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        var tu = PdfObj.Dict(PdfObj.Dict(fonts.Elements["/FU"])!.Elements["/ToUnicode"])!;
        var cmap = Encoding.Latin1.GetString(PdfObj.StreamBytes(tu));
        var cut = System.Text.RegularExpressions.Regex.Replace(cmap, @"<0003>\s*<0003>\s*<0020>\s*", "");
        Assert.NotEqual(cmap, cut);
        tu.Stream.Value = Encoding.Latin1.GetBytes(cut);
        tu.Elements.Remove("/Filter");
        using var ms = new MemoryStream();
        d.Save(ms, false);
        return ms.ToArray();
    }

    /// <summary>The page's content (all streams, decoded) as text.</summary>
    public static string Content(byte[] pdf, int page = 0)
    {
        using var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        return Encoding.Latin1.GetString(ContentEditor.ContentBytes(d.Pages[page]));
    }

    public static string Text(byte[] pdf, int page = 0)
    {
        using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
        return engine.GetText(page, cache: false).Text;
    }

    /// <summary>A string in the Unicode font /FU (glyph ids of PDFsharp's subset), as a hex string.</summary>
    public static string Cid(byte[] pdf, string text)
    {
        using var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        var fonts = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        var font = TextFont.For(PdfObj.Dict(fonts.Elements["/FU"])!);
        var enc = font.Encode(text);
        Assert.Empty(enc.Missing);
        return "<" + Convert.ToHexString(font.ToBytes(enc.Codes)) + ">";
    }
}
