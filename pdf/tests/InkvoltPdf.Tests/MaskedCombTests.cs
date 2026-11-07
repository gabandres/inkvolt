using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>
/// An SSN, phone or ZIP field whose MaxLen holds just its digits (AFSpecial): a comb field draws the digits in its cells,
/// not the formatted text cut to MaxLen; a number pasted with its dashes goes in as its digits. As the Mac does
/// (`FormEditor` combed, `FieldKeystrokes.typed`). And the faces a check box keeps when it is drawn again.
/// </summary>
public class MaskedCombTests
{
    private const string Widget = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R";

    private static byte[] SsnForm(bool comb) => Core2Pdf.Form(
    [
        $"<< {Widget} /FT /Tx /T (ssn) /Rect [72 700 252 720] /DA (/Helv 10 Tf 0 g) /MaxLen 9 {(comb ? "/Ff 16777216" : "")} " +
        "/AA << /K << /S /JavaScript /JS (AFSpecial_Keystroke\\(3\\);) >> /F << /S /JavaScript /JS (AFSpecial_Format\\(3\\);) >> >> >>",
    ]);

    private static string Appearance(byte[] data, string name)
    {
        using var doc = Core2Pdf.Open(data);
        var w = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Last(o => o.Elements.GetString("/T") == name);
        return System.Text.Encoding.Latin1.GetString(PdfObj.StreamBytes(PdfObj.Dict(PdfObj.Dict(w.Elements["/AP"])!.Elements["/N"])!));
    }

    [Fact]
    public void ACombSsnFieldDrawsItsNineDigitsInItsCells()
    {
        var filled = FormEditor.Fill(SsnForm(comb: true), null, new Dictionary<string, string> { ["ssn"] = "123456789" }).Data;
        var ap = Appearance(filled, "ssn");
        Assert.DoesNotContain("(-)", ap);
        Assert.Contains("(9)", ap);
        // Without comb cells the formatted text is drawn.
        var plain = FormEditor.Fill(SsnForm(comb: false), null, new Dictionary<string, string> { ["ssn"] = "123456789" }).Data;
        Assert.Contains("123-45-6789", Appearance(plain, "ssn"));
    }

    [Fact]
    public void AnSsnPastedWithItsDashesGoesInAsItsDigits()
    {
        using var keys = FieldKeystrokes.Open(SsnForm(comb: true), null, "ssn")!;
        Assert.True(keys.DigitsOnly);
        Assert.Equal("123456789", FieldKeystrokes.Pasted("", 0, 0, "123-45-6789", 9, keys.DigitsOnly));
        Assert.Equal("123-45-6789", FieldKeystrokes.Pasted("", 0, 0, "123-45-6789", 11, keys.DigitsOnly)); // it fits: as pasted
        Assert.Equal("123-45-67", FieldKeystrokes.Pasted("", 0, 0, "123-45-6789", 9, digitsOnly: false)); // another field: cut
    }

    [Fact]
    public void ACheckBoxRedrawnKeepsItsOffFaceWhereverItIsListed()
    {
        // The on face is missing; twenty faces come before /Off in the state dictionary. /Off is kept, whatever the order.
        var others = string.Join(' ', Enumerable.Range(0, 20).Select(i => $"/F{i} 6 0 R"));
        var form = Core2Pdf.Form(
        [
            $"<< {Widget} /FT /Btn /T (c) /V /Off /AS /Off /Rect [10 10 30 30] /AP << /N << /On 99 0 R {others} /Off 7 0 R >> >> /MK << /CA (4) >> >>",
            Core2Pdf.Stream("0 0 m 1 1 l S", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
            Core2Pdf.Stream("0.5 g 0 0 10 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
        ]);
        var filled = FormEditor.Fill(form, null, new Dictionary<string, string> { ["c"] = "On" }).Data;
        using var doc = Core2Pdf.Open(filled);
        var w = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Last(o => o.Elements.GetString("/T") == "c");
        var off = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(w.Elements["/AP"])!.Elements["/N"])!.Elements["/Off"])!;
        Assert.Equal("0.5 g 0 0 10 10 re f", System.Text.Encoding.Latin1.GetString(PdfObj.StreamBytes(off)).Trim());
    }
}
