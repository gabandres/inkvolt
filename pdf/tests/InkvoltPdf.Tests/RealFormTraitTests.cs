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

    [Fact]
    public void AFieldReachedThroughItsWidgetsListsEachWidgetOnce()
    {
        // /Fields leaves out "name" (6), whose /Kids lists both its nameless widgets (7, 8), found only on the page: the
        // first walks the field's tree, which reaches both, and neither is added to the field again.
        var data = Doc("9 0 R", "7 0 R 8 0 R 9 0 R",
        [
            "<< /FT /Tx /T (name) /V (Ann) /DA (/Helv 12 Tf 0 g) /Kids [7 0 R 8 0 R] >>",
            Widget("/Parent 6 0 R /Rect [72 700 272 720]"),
            Widget("/Parent 6 0 R /Rect [72 650 272 670]"),
            Widget("/FT /Tx /T (other) /Rect [72 600 272 620] /DA (/Helv 12 Tf 0 g)"),
        ]);

        var widgets = FormEditor.Read(data, null);
        Assert.Equal(["name", "name", "other"], widgets.Select(w => w.FieldName).Order());
        Assert.Equal(2, widgets.Where(w => w.FieldName == "name").Select(w => w.Key).Distinct().Count());
        using var doc = Core2Pdf.Open(data);
        var fields = new List<FormEditor.Field>();
        FormEditor.Collect(doc, doc.AcroForm, fields);
        Assert.Equal(2, fields.Single(f => f.Name == "name").Widgets.Count);
    }

    [Fact]
    public void ANamelessWidgetListedInFieldsIsNamedAfterItsOwnPage()
    {
        // A widget listed in /Fields whose parent (no name of its own) doesn't list it: named after the page it is on.
        var data = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R 7 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>",
            Helv,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R] /Resources << >> >>",
            "<< /FT /Tx /DA (/Helv 12 Tf 0 g) /Kids [] >>",
            "<< /Type /Annot /Subtype /Widget /F 4 /P 5 0 R /Parent 6 0 R /Rect [72 700 272 720] >>",
        ]);

        var widget = Assert.Single(FormEditor.Read(data, null));
        Assert.Equal(1, widget.PageIndex);
        Assert.Equal("field1_p2", widget.FieldName);
    }

    // ---- A choice field's widgets with their own /I (pdflib-fancy_fields) ----

    [Fact]
    public void AChoiceFieldsWidgetsDontKeepTheirOldSelection()
    {
        var data = Doc("6 0 R", "7 0 R 8 0 R",
        [
            "<< /FT /Ch /Ff 131072 /T (gundam) /Opt [(Exia) (Kyrios) (Virtue) (Dynames)] /V (Dynames) /I [3] /DA (/Helv 12 Tf 0 g) /Kids [7 0 R 8 0 R] >>",
            Widget("/Parent 6 0 R /Rect [72 700 172 720] /I [3] /V (Dynames)"),
            Widget("/Parent 6 0 R /Rect [72 650 172 670] /I [3]"),
        ]);

        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["gundam"] = "Kyrios" }).Data;
        Assert.Contains("/I [1]", Fields(filled, "gundam").Replace("[ 1 ]", "[1]"));
        using var doc = Core2Pdf.Open(filled);
        var widgets = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Where(o => o.Elements.GetName("/Subtype") == "/Widget").ToList();
        Assert.Equal(2, widgets.Count);
        Assert.All(widgets, w => Assert.False(w.Elements.ContainsKey("/I") && !w.Elements.GetArray("/I")!.Elements.Select(e => e.ToString()).SequenceEqual(["1"])));
        Assert.All(widgets, w => Assert.False(w.Elements.ContainsKey("/V") && w.Elements.GetString("/V") != "Kyrios"));
    }

    // ---- Check box faces (pdfjs-checkbox_no_appearance, pypdf-pdflatex-forms) ----

    [Theory]
    [InlineData("")] // no appearance and no /MK at all
    [InlineData("/AP << /N << /Yes << >> >> >> /MK << /BC [1 0 0] /BG [1 1 1] /CA (4) >> /DA (/ZaDb 10 Tf 0 0 0 rg)")] // pdfTeX: the on face isn't a stream
    [InlineData("/AP << /N << /Yes 7 0 R /Off 7 0 R >> >>")] // the on face is an empty stream
    public void ATickedCheckBoxGetsATickItCanShow(string extra)
    {
        var data = Doc("6 0 R", "6 0 R",
        [
            Widget($"/FT /Btn /T (cb) /Rect [100 600 140 640] /V /Off /AS /Off {extra}"),
            Core2Pdf.Stream("", "/Type /XObject /Subtype /Form /BBox [0 0 40 40]"),
        ]);
        var box = FormEditor.Read(data, null).Single();
        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["cb"] = box.OnState! }).Data;

        Assert.DoesNotContain("/NeedAppearances true", System.Text.Encoding.Latin1.GetString(filled));
        var on = Core2Pdf.Ink(filled, 0, box.Rect);
        Assert.True(on > 0.05, "the tick shows");
        var off = FormEditor.Fill(filled, null, new Dictionary<string, string> { ["cb"] = "Off" }).Data;
        Assert.True(Core2Pdf.Ink(off, 0, box.Rect) < on - 0.04, "and goes when unticked (the border stays)");
    }

    // ---- One widget on several pages (qpdf-form-fields-and-annotations-shared) ----

    [Fact]
    public void AWidgetSharedByTwoPagesIsOnBoth()
    {
        var data = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Resources << >> >>",
            Widget("/FT /Tx /T (shared) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (x)"),
            Helv,
        ]);
        Assert.Equal([0, 1], FormEditor.Read(data, null).Select(w => w.PageIndex));
    }

    // ---- A kid widget without /Parent (qpdf-form-document-defaults: MuPDF didn't show its value) ----

    [Fact]
    public void AKidWidgetWithoutParentGetsItSoEveryViewerShowsItsValue()
    {
        var data = Doc("6 0 R", "7 0 R",
        [
            "<< /FT /Tx /T (Text Box 1) /DA (0 g /Helv 12 Tf) /V () /Kids [7 0 R] >>",
            Widget("/Rect [72 700 300 720]"),
        ]);
        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["Text Box 1"] = "Filled kid" }).Data;
        Assert.Contains("Filled kid", Core2Pdf.AllText(filled));
    }

    // ---- Calculations (pdfjs-issue15753) ----

    [Fact]
    public void ACalculationThatSetsItsOwnFieldThroughGetFieldKeepsTheValue()
    {
        var data = Doc("6 0 R 7 0 R", "6 0 R 7 0 R",
        [
            Widget("/FT /Tx /T (Field1) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g)"),
            Widget("/FT /Tx /T (Field2) /Rect [72 650 300 670] /DA (/Helv 12 Tf 0 g) /AA << /C << /S /JavaScript " +
                   "/JS (var field1 = this.getField\\(\"Field1\"\\); var field2 = this.getField\\(\"Field2\"\\); field2.value = field1.value;) >> >>"),
        ], acroExtra: "/CO [7 0 R]");
        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["Field1"] = "Copied" }).Data;
        Assert.Equal("Copied", FormEditor.Read(filled, null).Single(w => w.FieldName == "Field2").Value);
    }

    [Fact]
    public void CalculationsHaveAcrobatsSimpleAndExtractNumsHelpers()
    {
        var data = Doc("6 0 R 7 0 R", "6 0 R 7 0 R",
        [
            Widget("/FT /Tx /T (in) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g)"),
            Widget("/FT /Tx /T (out) /Rect [72 650 300 670] /DA (/Helv 12 Tf 0 g) /AA << /C << /S /JavaScript " +
                   "/JS (var n = AFExtractNums\\(this.getField\\('in'\\).value\\); event.value = AFSimple\\('SUM', n[0], n[1]\\) + AFSimple\\('MAX', 2, 9\\) + AFSimple\\('PRD', 2, 3\\) + " +
                   "AFSimple\\('AVG', 4, 6\\) + AFSimple\\('XYZ', 7, 100\\);) >> >>"),
        ], acroExtra: "/CO [7 0 R]");
        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["in"] = "(555) 1234" }).Data;
        // 555 + 1234 + 9 + 6, then AVG's sum (AFSimple_Calculate divides it afterwards) and an unknown operation's first value.
        Assert.Equal("1821", FormEditor.Read(filled, null).Single(w => w.FieldName == "out").Value);
    }

    /// <summary>The field dictionary named <paramref name="name"/> as PDF text (the last one written).</summary>
    private static string Fields(byte[] data, string name)
    {
        using var doc = Core2Pdf.Open(data);
        return doc.Internals.GetAllObjects().OfType<PdfDictionary>().Last(o => o.Elements.GetString("/T") == name).ToString()!;
    }
}
