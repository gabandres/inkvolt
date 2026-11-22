using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Review fixes for Wave 4 Batch C (4.12, 4.19): the cases the first version got wrong.</summary>
public class Wave4CReviewTests
{
    private static DesignField At(string id, double x, double y, bool signed = false) =>
        FormDesign.NewField(signed ? DesignFieldKind.Signature : DesignFieldKind.Text, 0, new RectD(x, y, 100, 20), [], id) with { Id = id, Signed = signed };

    [Fact]
    public void AGroupDragGoesOnFromTheFieldsAsReadAgain()
    {
        var d = new FormDesigner(_ => new DesignPage(612, 792));
        d.SetFields([At("a", 100, 100), At("b", 100, 200)]);
        d.SelectAll(["a", "b"]);
        d.Press(0, new PointD(110, 110), 1, 5);
        d.Move(new PointD(120, 110), shift: false, dragged: true);
        // The document catches up meanwhile (b was moved by an earlier edit): the drag carries b from where it is now.
        d.SetFields([At("a", 100, 100), At("b", 300, 200)]);
        d.Move(new PointD(130, 110), shift: false, dragged: true);
        var all = Assert.IsType<DesignRelease.MovedAll>(d.Release()).Fields;
        Assert.Equal(new RectD(320, 200, 100, 20), all.Single(f => f.Id == "b").Rect);
    }

    [Fact]
    public void SeveralWithASignedAnchorStillDeleteAndNudgeTheUnsignedOnly()
    {
        var d = new FormDesigner(_ => new DesignPage(612, 792));
        var sig = At("s", 100, 100, signed: true);
        var a = At("a", 100, 200);
        d.SetFields([sig, a]);
        d.SelectAll(["s", "a"]);
        Assert.Equal(DesignAction.Delete, d.Key(DesignKey.Delete, DesignModifiers.None)!.Action);
        d.Key(DesignKey.Right, DesignModifiers.Shift);
        Assert.Equal(sig.Rect, d.ShownRect(sig)); // a signed field never shows moved
        Assert.Equal(110, d.ShownRect(a).X);
        Assert.Equal(["a"], d.FlushNudgeAll().Select(f => f.Id));
    }

    [Fact]
    public void ASnapRefusedForSizeShowsNoLine()
    {
        var snap = Snapper.For([new Guide(0, GuideAxis.X, 100)], null, 0, 5)!;
        Assert.Equal(new RectD(98, 10, 4, 20), snap.Resize(new RectD(90, 10, 12, 20), new RectD(98, 10, 4, 20), min: 4));
        Assert.Empty(snap.Lines);
        snap.Resize(new RectD(10, 10, 80, 20), new RectD(10, 10, 93, 20));
        Assert.Equal([new SnapLine(GuideAxis.X, 100)], snap.Lines);
    }

    [Fact]
    public void ANotationKeepsANameWithABracketAsWritten()
    {
        var notation = FormCalculations.NameInNotation("Unit )") + " * 2";
        var js = FormCalculations.Compile(notation);
        Assert.Contains("getField(\"Unit )\")", js);
        Assert.Equal("event.value = (AFMakeNumber(getField(\"a\").value) + 1) * 2;", FormCalculations.Compile("(a + 1) * 2"));
        Assert.Equal(new FieldCalc(CalcKind.Notation, ["Unit )"], notation), FormCalculations.Read(FormCalculations.ScriptOf(new FieldCalc(CalcKind.Notation, ["Unit )"], notation))));
    }

    [Fact]
    public void AWidgetsOwnCalculateScriptIsReadChangedAndRemovedWhereItIs()
    {
        var pdf = FormDesign.Add(TestPdf.Make(1), null,
            [FormDesign.NewField(DesignFieldKind.Text, 0, new RectD(72, 100, 100, 20), [], "A"), FormDesign.NewField(DesignFieldKind.Text, 0, new RectD(72, 200, 100, 20), [], "T")]);
        // T as a parent field with one widget kid that holds the calculate script, as some forms are made.
        using (var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify))
        {
            var acro = PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"])!;
            var fields = PdfObj.Array(acro.Elements["/Fields"])!;
            var i = fields.Elements.Select(PdfObj.Dict).ToList().FindIndex(f => PdfObj.Str(f!.Elements["/T"]) == "T");
            var w = PdfObj.Dict(fields.Elements[i])!;
            var parent = new PdfDictionary(doc);
            doc.Internals.AddObject(parent);
            parent.Elements["/FT"] = w.Elements["/FT"];
            parent.Elements["/T"] = w.Elements["/T"];
            parent.Elements["/Kids"] = new PdfArray(doc, w.Reference!);
            w.Elements.Remove("/FT");
            w.Elements.Remove("/T");
            w.Elements["/Parent"] = parent.Reference!;
            var c = new PdfDictionary(doc);
            c.Elements["/S"] = new PdfName("/JavaScript");
            c.Elements["/JS"] = new PdfString("AFSimple_Calculate(\"SUM\", new Array (\"A\"));");
            var aa = new PdfDictionary(doc);
            aa.Elements["/C"] = c;
            w.Elements["/AA"] = aa;
            fields.Elements[i] = parent.Reference!;
            acro.Elements["/CO"] = new PdfArray(doc, parent.Reference!);
            using var ms = new MemoryStream();
            doc.Save(ms, false);
            pdf = ms.ToArray();
        }
        DesignField T(byte[] b) => FormDesign.Read(b, null).Single(f => f.Name == "T");
        Assert.Equal(new FieldCalc(CalcKind.Sum, ["A"]), T(pdf).Calculation);

        // Another property changed: the script stays on the widget, not copied to the field.
        var renamed = FormDesign.Update(pdf, null, [T(pdf) with { Tooltip = "Total" }]);
        Assert.Equal(new FieldCalc(CalcKind.Sum, ["A"]), T(renamed).Calculation);
        Assert.Equal(1, Scripts(renamed));

        // Changed where it is, then removed there (and from the order).
        var avg = FormDesign.Update(renamed, null, [T(renamed) with { Calculation = new FieldCalc(CalcKind.Average, ["A"]) }]);
        Assert.Equal(CalcKind.Average, T(avg).Calculation!.Kind);
        Assert.Equal(1, Scripts(avg));
        var none = FormDesign.Update(avg, null, [T(avg) with { Calculation = null }]);
        Assert.Null(T(none).Calculation);
        Assert.Equal(0, Scripts(none));
        Assert.Empty(FormDesign.CalculationOrder(none, null));

        static int Scripts(byte[] b)
        {
            using var doc = PdfReader.Open(new MemoryStream(b), PdfDocumentOpenMode.Import);
            return doc.Internals.GetAllObjects().OfType<PdfDictionary>()
                .Count(o => PdfObj.Dict(PdfObj.Dict(o.Elements["/AA"])?.Elements["/C"]) is not null);
        }
    }

    [Fact]
    public void GuidesFollowTheirPagesAndGoWithAPageThatChanged()
    {
        var pdf = TestPdf.Make(3);
        var keys = PageGuides.Keys(pdf, null);
        Assert.Equal(3, keys.Distinct().Count());
        var guides = new PageGuides();
        guides.Add(new Guide(0, GuideAxis.X, 100), 612, 792);
        guides.Add(new Guide(2, GuideAxis.Y, 300), 612, 792);

        // A comment changes nothing; a move takes the guides along.
        var noted = Annotations.AddNote(pdf, null, 0, 100, 100, "note", "me");
        Assert.Equal(keys, PageGuides.Keys(noted, null));
        var moved = PageEditor.Reorder(noted, null, [2, 0, 1]);
        Assert.Equal(0, guides.Remap(keys, PageGuides.Keys(moved, null)));
        Assert.Equal([(1, GuideAxis.X), (0, GuideAxis.Y)], guides.All.Select(g => (g.Page, g.Axis)));

        // A turned page takes its guides with it; the other's stay.
        var before = PageGuides.Keys(moved, null);
        var turned = PageEditor.Rotate(moved, null, [1], 90);
        Assert.Equal(1, guides.Remap(before, PageGuides.Keys(turned, null)));
        Assert.Equal([(0, GuideAxis.Y)], guides.All.Select(g => (g.Page, g.Axis)));
    }
}
