using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>
/// Filled forms show their values from their own appearance streams, without /NeedAppearances (pdf.js and poppler redraw
/// every field when it is set, losing formats and list and check box looks), and check boxes with a single-stream
/// appearance get proper on and off states.
/// </summary>
public class FormAppearanceTests
{
    private static bool NeedAppearances(byte[] pdf)
    {
        using var doc = Core2Pdf.Open(pdf);
        return PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"])!.Elements.GetBoolean("/NeedAppearances");
    }

    private static PdfDictionary Annot(PdfDocument doc, int i) => PdfObj.Dict(PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements[i])!;

    [Fact]
    public void EveryKindOfFieldIsFilledWithItsOwnAppearanceAndNoNeedAppearances()
    {
        DesignField New(DesignFieldKind kind, double y, string name) => FormDesign.NewField(kind, 0, new RectD(72, y, 150, kind is DesignFieldKind.ListBox ? 60 : kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio ? 14 : 22), [], name);
        var form = FormDesign.Add(TestPdf.Make(1), null,
        [
            New(DesignFieldKind.Text, 100, "Amount") with { Format = new FieldFormat(FieldFormatKind.Number, 2) },
            New(DesignFieldKind.ComboBox, 140, "Color") with { Options = ["Red", "Green"] },
            New(DesignFieldKind.ListBox, 180, "Fruit") with { Options = ["Apple", "Banana", "Cherry"] },
            New(DesignFieldKind.CheckBox, 260, "Agree"),
            New(DesignFieldKind.Radio, 290, "Pick") with { ExportValue = "A" },
            FormDesign.NewField(DesignFieldKind.Radio, 0, new RectD(100, 290, 14, 14), [], "Pick") with { ExportValue = "B" },
            New(DesignFieldKind.Signature, 320, "Sign"),
        ]);
        var filled = FormEditor.SetValues(form, null, new Dictionary<string, string>
        {
            ["Amount"] = "1234.5", ["Color"] = "Green", ["Fruit"] = "Banana", ["Agree"] = "Yes", ["Pick"] = "B",
        });
        Assert.False(NeedAppearances(filled));
        var text = Core2Pdf.AllText(filled);
        Assert.Contains("1,234.50", text);
        Assert.Contains("Green", text);
        Assert.Contains("Banana", text);
        using var doc = Core2Pdf.Open(filled);
        for (var i = 0; i < 7; i++)
        {
            var w = Annot(doc, i);
            var normal = PdfObj.Dict(PdfObj.Dict(w.Elements["/AP"])!.Elements["/N"]);
            Assert.NotNull(normal);
            // A check box or radio shows a state its normal appearance has.
            if (PdfObj.Name(w.Elements["/AS"]) is { } shown and not "Off") Assert.True(normal!.Elements.ContainsKey("/" + shown), shown);
        }
        Assert.Equal("Yes", PdfObj.Name(Annot(doc, 3).Elements["/AS"]));
        Assert.Equal("B", PdfObj.Name(Annot(doc, 5).Elements["/AS"]));
        Assert.Equal("Off", PdfObj.Name(Annot(doc, 4).Elements["/AS"]));
    }

    [Fact]
    public void AFormWhoseProducerAskedForNeedAppearancesGetsItsAppearancesBuilt()
    {
        // Fields with values but no appearances: the producer left drawing them to the viewer.
        var form = Core2Pdf.Form(
        [
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [72 700 272 720] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (b) /V (Kept value) /Rect [72 660 272 680] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (c) /V /Off /Rect [72 620 86 634] /P 3 0 R /MK << /BC [0] /CA (4) >> /DA (/ZaDb 0 Tf 0 g) >>",
        ], acroExtra: "/NeedAppearances true");
        var filled = FormEditor.SetValues(form, null, new Dictionary<string, string> { ["a"] = "New value", ["c"] = "Yes" });
        Assert.False(NeedAppearances(filled));
        var strict = Core2Pdf.AllText(filled);
        Assert.Contains("New value", strict);
        Assert.Contains("Kept value", strict); // the untouched field shows too
        Assert.True(Core2Pdf.Ink(filled, 0, new RectD(74, 160, 10, 10)) > 0.1, "the check box shows its check");

        // A check box with no appearance and no /MK to draw one from keeps NeedAppearances, so viewers still try.
        var broken = Core2Pdf.Form(
        [
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [72 700 272 720] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (c) /V /Off /Rect [72 620 86 634] /P 3 0 R >>",
        ], acroExtra: "/NeedAppearances true");
        Assert.True(NeedAppearances(FormEditor.SetValues(broken, null, new Dictionary<string, string> { ["a"] = "x" })));
    }

    [Fact]
    public void ACheckBoxWithASingleAppearanceStreamGetsOnAndOffStates()
    {
        // As some producers write it: /N is one stream (the checked look); only /D is a state dictionary.
        var form = Core2Pdf.Form(
        [
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /V /Off /AS /Off /Rect [72 600 86 614] /P 3 0 R /DA (/ZaDb 0 Tf 0 g) /MK << /BC [0] /CA (4) >> /AP << /N 8 0 R /D << /Off 9 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Plain) /V /Off /Rect [72 560 86 574] /P 3 0 R /AP << /N 10 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (x) /Rect [72 500 272 520] /P 3 0 R /DA (/Helv 0 Tf 0 g) /AP << /N 11 0 R >> >>",
        ], more:
        [
            Core2Pdf.Stream("q 0 G 0.5 0.5 13 13 re S Q BT 0 g /ZaDb 10 Tf 2 3 Td (4) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 14 14] /Resources << >>"),
            Core2Pdf.Stream("q 0.75 g 0 0 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            Core2Pdf.Stream("0 0 14 14 re f", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            Core2Pdf.Stream("BT /Helv 12 Tf 2 4 Td (x) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 200 20]"),
        ]);
        var widgets = FormEditor.Read(form, null);
        Assert.Equal("Yes", widgets.Single(w => w.FieldName == "Agree").OnState); // never "BBox" or "Resources"
        Assert.Equal("Yes", widgets.Single(w => w.FieldName == "Plain").OnState);
        Assert.Null(widgets.Single(w => w.FieldName == "Name").OnState);

        var off = Core2Pdf.Ink(form, 0, new RectD(75, 180, 8, 8));
        var on = FormEditor.SetValues(form, null, new Dictionary<string, string> { ["Agree"] = "Yes", ["Plain"] = "Yes" });
        Assert.False(NeedAppearances(on));
        using (var doc = Core2Pdf.Open(on))
        {
            var agree = Core2Pdf.Field(doc, "Agree")!;
            Assert.Equal("Yes", PdfObj.Name(agree.Elements["/V"]));
            Assert.Equal("Yes", PdfObj.Name(agree.Elements["/AS"]));
            var states = PdfObj.Dict(PdfObj.Dict(agree.Elements["/AP"])!.Elements["/N"])!;
            Assert.Null(states.Stream);
            Assert.True(states.Elements.ContainsKey("/Yes") && states.Elements.ContainsKey("/Off"));
            // Without /MK the single face is kept as the "on" look.
            var plain = PdfObj.Dict(PdfObj.Dict(Core2Pdf.Field(doc, "Plain")!.Elements["/AP"])!.Elements["/N"])!;
            Assert.Equal(["/Off", "/Yes"], plain.Elements.Keys.Order());
        }
        Assert.True(Core2Pdf.Ink(on, 0, new RectD(75, 180, 8, 8)) > off);
        var cleared = FormEditor.SetValues(on, null, new Dictionary<string, string> { ["Agree"] = "Off" });
        Assert.Equal("Off", FormEditor.Read(cleared, null).Single(w => w.FieldName == "Agree").Value);

        // With an /Opt, the state names are positions, as Acrobat writes them.
        var withOpt = Core2Pdf.Form(
        [
            "<< /FT /Btn /Ff 49152 /T (Size) /V /Off /Opt [(Small) (Large)] /Kids [6 0 R 7 0 R] >>",
        ], more:
        [
            "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [72 600 86 614] /P 3 0 R /AP << /N 8 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [100 600 114 614] /P 3 0 R /AP << /N 8 0 R >> >>",
            Core2Pdf.Stream("0 0 14 14 re f", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
        ], extraAnnots: "6 0 R 7 0 R");
        Assert.Equal(["0", "1"], FormEditor.Read(withOpt, null).Select(w => w.OnState));
        var large = FormEditor.SetValues(withOpt, null, new Dictionary<string, string> { ["Size"] = "Large" });
        Assert.Equal("1", FormEditor.Read(large, null)[0].Value);
    }

    [Fact]
    public void CheckMarksAreDrawnAsPathsSoViewersWithoutZapfDingbatsShowThem()
    {
        var form = FormDesign.Add(TestPdf.Make(1), null, [FormDesign.NewField(DesignFieldKind.CheckBox, 0, new RectD(72, 100, 14, 14), [], "Agree")]);
        using var doc = Core2Pdf.Open(form);
        var states = PdfObj.Dict(PdfObj.Dict(Annot(doc, 0).Elements["/AP"])!.Elements["/N"])!;
        var on = System.Text.Encoding.Latin1.GetString(PdfObj.StreamBytes(PdfObj.Dict(states.Elements["/Yes"])!));
        Assert.DoesNotContain("Tf", on);
        Assert.Contains(" l S", on);
    }
}
