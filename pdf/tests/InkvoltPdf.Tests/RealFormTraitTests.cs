using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Traits of real forms the forms corpus (pdf/tools/forms-corpus) found Inkvolt mishandling, each in a small made-up form.</summary>
public class RealFormTraitTests
{
    private const string Page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [{0}] /Resources << >> >>";
    private const string Catalog = "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [{0}] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R /ZaDb 5 0 R >> >> {1} >> >>";
    private const string Helv = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>";
    private const string ZaDb = "<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>";
    private const string Pages = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";

    /// <summary>Objects 1-5 (catalog, pages, page, Helvetica, ZapfDingbats) and then <paramref name="objects"/> from 6.</summary>
    private static byte[] Doc(string fields, string annots, IReadOnlyList<string> objects, string acroExtra = "") =>
        Core2Pdf.Build([string.Format(Catalog, fields, acroExtra), Pages, string.Format(Page, annots), Helv, ZaDb, .. objects]);

    private static string Widget(string extra) => $"<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R {extra} >>";

    // ---- Widgets their parent doesn't list in /Kids (pdfjs-opt_demo, qpdf-form-errors) ----

    [Fact]
    public void AWidgetJoinsItsParentFieldEvenWhenKidsLeavesItOut()
    {
        // veg (8) has no /Kids; its widgets are listed in /Fields and on the page. r2 (9) lists one of its two widgets.
        // r1 (14) has a named kid (a field of its own, r1.choice1) and two nameless ones: its own widgets (qpdf's
        // form-document-defaults).
        const string ap = "/AP << /N << /{0} 11 0 R /Off 12 0 R >> >> /MK << /CA (l) >>";
        var data = Doc("6 0 R 7 0 R 9 0 R 14 0 R", "6 0 R 7 0 R 10 0 R 13 0 R 15 0 R 16 0 R 17 0 R",
        [
            Widget("/Parent 8 0 R /Rect [72 700 90 718] /AS /Off " + string.Format(ap, "0")),
            Widget("/Parent 8 0 R /Rect [72 670 90 688] /AS /1 " + string.Format(ap, "1")),
            "<< /FT /Btn /Ff 49152 /T (veg) /V /1 /Opt [(Carrot) (Potato)] >>",
            "<< /FT /Btn /Ff 49152 /T (r2) /V /Off /Kids [10 0 R] >>",
            Widget("/Parent 9 0 R /Rect [200 700 218 718] /AS /Off " + string.Format(ap, "a")),
            Core2Pdf.Stream("0 g 4 4 10 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            Core2Pdf.Stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            Widget("/Parent 9 0 R /Rect [200 670 218 688] /AS /Off " + string.Format(ap, "b")),
            "<< /FT /Btn /Ff 49152 /T (r1) /V /1 /Kids [15 0 R 16 0 R 17 0 R] >>",
            Widget("/Parent 14 0 R /T (choice1) /Rect [300 700 318 718] /AS /1 " + string.Format(ap, "1")),
            Widget("/Parent 14 0 R /Rect [300 670 318 688] /AS /Off " + string.Format(ap, "2")),
            Widget("/Parent 14 0 R /Rect [300 640 318 658] /AS /Off " + string.Format(ap, "3")),
        ]);

        var widgets = FormEditor.Read(data, null);
        Assert.Equal(["r1", "r1", "r1.choice1", "r2", "r2", "veg", "veg"], widgets.Select(w => w.FieldName).Order());
        Assert.Equal(["2", "3"], widgets.Where(w => w.FieldName == "r1").Select(w => w.OnState));
        Assert.Equal(["0", "1"], widgets.Where(w => w.FieldName == "veg").Select(w => w.OnState));
        Assert.Equal(["a", "b"], widgets.Where(w => w.FieldName == "r2").Select(w => w.OnState).Order());
        Assert.DoesNotContain(FormEditor.DataFields(data, null), f => f.Name.StartsWith("field", StringComparison.Ordinal));

        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["veg"] = "0", ["r2"] = "b", ["r1"] = "3" }).Data;
        Assert.Contains("/V /3", Fields(filled, "r1"));
        var after = FormEditor.Read(filled, null);
        Assert.Equal(["0", "Off"], after.Where(w => w.FieldName == "veg").Select(w => w.Value == w.OnState ? w.OnState : "Off"));
        Assert.Equal(["Off", "b"], after.Where(w => w.FieldName == "r2").OrderBy(w => w.OnState).Select(w => w.Value == w.OnState ? w.OnState : "Off"));
        Assert.Contains("/V /0", Fields(filled, "veg"));
        Assert.Contains("/V /b", Fields(filled, "r2"));
    }

    /// <summary>The field dictionary named <paramref name="name"/> as PDF text (the last one written).</summary>
    private static string Fields(byte[] data, string name)
    {
        using var doc = Core2Pdf.Open(data);
        return doc.Internals.GetAllObjects().OfType<PdfDictionary>().Last(o => o.Elements.GetString("/T") == name).ToString()!;
    }
}
