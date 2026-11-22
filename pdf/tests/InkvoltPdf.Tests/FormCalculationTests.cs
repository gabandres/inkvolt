using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Calculated fields made in Prepare Form (<see cref="FormCalculations"/>, <see cref="FormDesign"/>'s /AA /C and /CO), and
/// several fields aligned, sized and spaced together (<see cref="FormDesignRules"/>, <see cref="FormDesigner"/>'s
/// selection), roadmap 4.12.
/// </summary>
public class FormCalculationTests
{
    private static DesignField Text(string name, double y, double x = 72) => FormDesign.NewField(DesignFieldKind.Text, 0, new RectD(x, y, 120, 20), [], name);

    private static string Value(byte[] pdf, string name) => FormEditor.Read(pdf, null).First(w => w.FieldName == name).Value;

    private static byte[] Fill(byte[] pdf, params (string Name, string Value)[] values) =>
        FormEditor.SetValues(pdf, null, values.ToDictionary(v => v.Name, v => v.Value));

    [Fact]
    public void SimpleCalculationsAreWrittenAsAcrobatWritesThemAndReadBack()
    {
        var sum = new FieldCalc(CalcKind.Sum, ["a", "b \"c\""]);
        var script = FormCalculations.ScriptOf(sum);
        Assert.Equal("AFSimple_Calculate(\"SUM\", new Array (\"a\", \"b \\\"c\\\"\"));", script);
        Assert.Equal(sum, FormCalculations.Read(script));
        // Acrobat's own spellings of the same.
        Assert.Equal(new FieldCalc(CalcKind.Average, ["x", "y"]), FormCalculations.Read("AFSimple_Calculate('AVG', ['x','y'])"));
        Assert.Equal(new FieldCalc(CalcKind.Product, ["Qty", "Price"]), FormCalculations.Read("AFSimple_Calculate(\"PRD\", new Array (\"Qty\", \"Price\"));\r\n"));
        Assert.Equal(CalcKind.Minimum, FormCalculations.Read("AFSimple_Calculate(\"MIN\", new Array(\"a\"))")!.Kind);
        Assert.Equal(CalcKind.Maximum, FormCalculations.Read("AFSimple_Calculate(\"MAX\", new Array(\"a\"))")!.Kind);
        // Anything more is the form's own script, kept whole.
        var own = "AFSimple_Calculate(\"SUM\", new Array(\"a\")); event.value *= 2;";
        Assert.Equal(new FieldCalc(CalcKind.Custom, [], Script: own), FormCalculations.Read(own));
        Assert.Equal(CalcKind.Custom, FormCalculations.Read("AFSimple_Calculate(\"SUM\", new Array(a))")!.Kind);
        Assert.Null(FormCalculations.Read("  "));
    }

    [Fact]
    public void SimplifiedFieldNotationCompilesToJavaScriptAndKeepsTheNotation()
    {
        var js = FormCalculations.Compile("Price * Qty + 1.5");
        Assert.Equal("event.value = AFMakeNumber(getField(\"Price\").value) * AFMakeNumber(getField(\"Qty\").value) + 1.5;", js);
        var calc = new FieldCalc(CalcKind.Notation, ["Unit price", "Qty"], "(Unit\\ price - 2) * Qty");
        var script = FormCalculations.ScriptOf(calc);
        Assert.StartsWith("/** BVCALC (Unit\\ price - 2) * Qty EVCALC **/ ", script);
        Assert.Equal(calc, FormCalculations.Read(script));
        Assert.Equal(["Unit price", "Qty"], FormCalculations.NotationFields("(Unit\\ price - 2) * Qty * Qty"));
        Assert.Equal("Unit\\ price", FormCalculations.NameInNotation("Unit price"));
        Assert.Equal("\\2nd", FormCalculations.NameInNotation("2nd"));
        Assert.Equal("Text1.0", FormCalculations.NameInNotation("Text1.0"));

        // An edited script after the notation is the form's own.
        Assert.Equal(CalcKind.Custom, FormCalculations.Read("/** BVCALC a*b EVCALC **/ event.value = 3;")!.Kind);

        foreach (var bad in new[] { "", "a *", "* a", "(a + b", "a + b)", "a b", "a $ b", "a\\*/b", "a + EVCALC" })
            Assert.Throws<DesignRefusal>(() => FormCalculations.Compile(bad));
        Assert.Throws<DesignRefusal>(() => FormCalculations.Compile(new string('(', 40) + "a" + new string(')', 40)));
        Assert.Throws<DesignRefusal>(() => FormCalculations.Compile(string.Join("+", Enumerable.Repeat("a", 3000))));
    }

    [Fact]
    public void CalculatedFieldsRecalculateWhenTheFormIsFilled()
    {
        var fields = new[] { Text("Price", 100), Text("Qty", 130), Text("Total", 160), Text("Tax", 190), Text("Sum", 220), Text("Avg", 250), Text("Low", 280), Text("High", 310) };
        var pdf = FormDesign.Add(TestPdf.Make(1), null, fields);
        var design = FormDesign.Read(pdf, null);
        DesignField Of(string n) => design.Single(f => f.Name == n);
        var changes = new[]
        {
            FormDesignRules.WithCalculation(Of("Total"), CalcKind.Notation, [], "Price * Qty", design),
            FormDesignRules.WithCalculation(Of("Tax"), CalcKind.Notation, [], "Total * 0.1", design) with { Format = FormDesignRules.Formats[1] },
            FormDesignRules.WithCalculation(Of("Sum"), CalcKind.Sum, ["Qty", "Price"], "", design),
            FormDesignRules.WithCalculation(Of("Avg"), CalcKind.Average, ["Price", "Qty"], "", design),
            FormDesignRules.WithCalculation(Of("Low"), CalcKind.Minimum, ["Price", "Qty"], "", design),
            FormDesignRules.WithCalculation(Of("High"), CalcKind.Maximum, ["Price", "Qty"], "", design),
        };
        // Picked fields are kept in the form's order.
        Assert.Equal(["Price", "Qty"], changes[2].Calculation!.Fields);
        pdf = FormDesign.Update(pdf, null, changes);

        // They read back, and the calculation order lists them as they were made.
        design = FormDesign.Read(pdf, null);
        Assert.Equal(new FieldCalc(CalcKind.Notation, ["Price", "Qty"], "Price * Qty"), Of("Total").Calculation);
        Assert.Equal(new FieldCalc(CalcKind.Sum, ["Price", "Qty"]), Of("Sum").Calculation);
        Assert.Null(Of("Price").Calculation);
        Assert.Equal(["Total", "Tax", "Sum", "Avg", "Low", "High"], FormDesign.CalculationOrder(pdf, null));

        var filled = Fill(pdf, ("Price", "12.5"), ("Qty", "4"));
        Assert.Equal("50", Value(filled, "Total"));
        Assert.Equal("5", Value(filled, "Tax"));
        Assert.Equal("16.5", Value(filled, "Sum"));
        Assert.Equal("8.25", Value(filled, "Avg"));
        Assert.Equal("4", Value(filled, "Low"));
        Assert.Equal("12.5", Value(filled, "High"));
        Assert.Contains("5.00", Core2Pdf.AllText(filled)); // Tax shows in its number format

        // Tax before Total: Tax reads the Total of before (Acrobat's order rule), until the next fill.
        var reordered = FormDesign.SetCalculationOrder(pdf, null, ["Tax", "Total"]);
        Assert.Equal(["Tax", "Total", "Sum", "Avg", "Low", "High"], FormDesign.CalculationOrder(reordered, null));
        var stale = Fill(reordered, ("Price", "10"), ("Qty", "2"));
        Assert.Equal("20", Value(stale, "Total"));
        Assert.Equal("0", Value(stale, "Tax"));
        Assert.Same(reordered, FormDesign.SetCalculationOrder(reordered, null, ["Tax"]));

        // Not calculated any more: the script and its place in the order go.
        design = FormDesign.Read(pdf, null);
        pdf = FormDesign.Update(pdf, null, [FormDesignRules.WithCalculation(Of("Sum"), CalcKind.None, [], "", design)]);
        Assert.Null(FormDesign.Read(pdf, null).Single(f => f.Name == "Sum").Calculation);
        Assert.DoesNotContain("Sum", FormDesign.CalculationOrder(pdf, null));
        Assert.Equal("", Value(Fill(pdf, ("Price", "3")), "Sum"));
    }

    [Fact]
    public void AFormsOwnCalculateScriptIsKeptAndTheRulesRefuseWhatCantWork()
    {
        var pdf = FormDesign.Add(TestPdf.Make(1), null, [Text("A", 100), Text("B", 130)]);
        var design = FormDesign.Read(pdf, null);
        var b = design.Single(f => f.Name == "B");
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithCalculation(b, CalcKind.Sum, ["B"], "", design));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithCalculation(b, CalcKind.Notation, [], "A + B", design));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithCalculation(b, CalcKind.Notation, [], "A + Missing", design));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithCalculation(b, CalcKind.Notation, [], " ", design));
        // From a list to the notation: the picked fields, added.
        Assert.Equal("A", FormDesignRules.WithCalculation(b, CalcKind.Notation, ["A"], "", design).Calculation!.Notation);
        Assert.Equal(["A"], FormDesignRules.CalcSources(b, design));

        var custom = new FieldCalc(CalcKind.Custom, [], Script: "event.value = this.getField(\"A\").value * 3;");
        var withOwn = b with { Calculation = custom };
        Assert.Equal(-1, FormDesignRules.CalcIndex(withOwn));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.WithCalculation(withOwn, CalcKind.Sum, ["A"], "", design));
        Assert.Equal(1, FormDesignRules.CalcIndex(b with { Calculation = new FieldCalc(CalcKind.Sum, ["A"]) }));
        Assert.Equal(0, FormDesignRules.CalcIndex(b));

        // A script set some other way stays through a property change.
        pdf = FormDesign.Update(pdf, null, [FormDesignRules.WithCalculation(b, CalcKind.Sum, ["A"], "", design)]);
        var read = FormDesign.Read(pdf, null).Single(f => f.Name == "B");
        pdf = FormDesign.Update(pdf, null, [read with { Tooltip = "Three times A", Calculation = custom }]);
        Assert.Equal(new FieldCalc(CalcKind.Sum, ["A"]), FormDesign.Read(pdf, null).Single(f => f.Name == "B").Calculation);

        Assert.Equal(["b", "a", "c"], FormDesignRules.MovedInOrder(["a", "b", "c"], 1, -1));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.MovedInOrder(["a", "b"], 1, 1));
    }

    [Fact]
    public void NumberFormatsAreAcrobatsAndReadBackAsTheirChoice()
    {
        var pdf = FormDesign.Add(TestPdf.Make(1), null, [Text("Euro", 100)]);
        var f = FormDesign.Read(pdf, null).Single();
        var euro = FormDesignRules.Formats.ToList().FindIndex(x => x is { Currency: " €" });
        Assert.True(euro > 0);
        pdf = FormDesign.Update(pdf, null, [f with { Format = FormDesignRules.Formats[euro] }]);
        Assert.Equal(euro, FormDesignRules.FormatIndex(FormDesign.Read(pdf, null).Single()));
        Assert.Equal("AFNumber_Format(2, 2, 0, 0, \" €\", false);", FormDesign.FormatScripts(FormDesignRules.Formats[euro]!).Format);
        Assert.Contains("1.234,50 €", Core2Pdf.AllText(Fill(pdf, ("Euro", "1234.5"))));
        var parens = FormDesignRules.Formats.ToList().FindIndex(x => x is { NegativeStyle: 2 });
        pdf = FormDesign.Update(pdf, null, [FormDesign.Read(pdf, null).Single() with { Format = FormDesignRules.Formats[parens] }]);
        Assert.Contains("(1,234.50)", Core2Pdf.AllText(Fill(pdf, ("Euro", "-1234.5"))));
    }

    // ───────────────────────────── Several fields ─────────────────────────────

    private static DesignField At(string id, double x, double y, double w = 100, double h = 20, DesignFieldKind kind = DesignFieldKind.Text) =>
        FormDesign.NewField(kind, 0, new RectD(x, y, w, h), [], id) with { Id = id };

    private static readonly DesignPage Page = new(612, 792);

    [Fact]
    public void CtrlClickSelectsSeveralAndADragMovesThemTogether()
    {
        var d = new FormDesigner(_ => Page);
        d.SetFields([At("a", 100, 100), At("b", 100, 200), At("c", 300, 300), At("d", 100, 400) with { PageIndex = 1 }]);
        d.Press(0, new PointD(110, 110), 1, 5);
        d.Release();
        Assert.Equal(DesignPress.Selected, d.Press(0, new PointD(310, 310), 1, 5, toggle: true));
        Assert.Null(d.Release());
        d.Press(0, new PointD(110, 210), 1, 5, toggle: true);
        Assert.Equal(["a", "c", "b"], d.SelectedIds);
        Assert.True(d.HasSeveral);
        Assert.Equal(-1, d.HandleAt(0, new PointD(100, 100), 5)); // no handles on several

        // Taking the anchor out: the next one picked is the anchor.
        d.Toggle("a");
        Assert.Equal(["c", "b"], d.SelectedIds);
        d.Toggle("a");
        Assert.Equal(["c", "b", "a"], d.SelectedIds);

        // A drag of one moves them all, stopped where the last one meets the page's edge.
        d.Press(0, new PointD(110, 210), 1, 5);
        d.Move(new PointD(110 + 500, 220), shift: false, dragged: true);
        Assert.Equal(new RectD(512, 300 + 10, 100, 20), d.ShownRect(d.Fields.Single(f => f.Id == "c")));
        var all = Assert.IsType<DesignRelease.MovedAll>(d.Release()).Fields;
        Assert.Equal(["b", "c", "a"], all.Select(f => f.Id));
        Assert.Equal([312.0, 512, 312], all.Select(f => f.Rect.X));
        Assert.Equal(["c", "b", "a"], d.SelectedIds);

        // Arrow keys move them all, written together once they rest.
        d.Key(DesignKey.Up, DesignModifiers.Shift);
        var written = d.Key(DesignKey.Escape, DesignModifiers.None)!.WrittenAll;
        Assert.Equal([300.0, 200, 100], written.Select(f => f.Rect.Y));
        Assert.Empty(d.SelectedIds);

        // A field of another page starts a new selection; a plain click on one, a single one.
        d.SelectAll(["a", "b"]);
        d.Toggle("d");
        Assert.Equal(["d"], d.SelectedIds);
        d.SelectAll(["a", "b", "d"]);
        Assert.Equal(["a", "b"], d.SelectedIds);
        d.Press(0, new PointD(520, 315), 1, 5);
        d.Release();
        Assert.Equal(["c"], d.SelectedIds);
    }

    [Fact]
    public void SeveralFieldsAlignToTheFirstOnePicked()
    {
        IReadOnlyList<DesignField> sel = [At("a", 100, 100, 100, 20), At("b", 150, 200, 60, 30), At("c", 40, 300, 200, 10)];
        RectD R(IReadOnlyList<DesignField> moved, string id) => moved.Single(f => f.Id == id).Rect;

        var left = FormDesignRules.Aligned(sel, DesignAlign.Left, Page);
        Assert.Equal([100.0, 100], [R(left, "b").X, R(left, "c").X]);
        var right = FormDesignRules.Aligned(sel, DesignAlign.Right, Page);
        Assert.Equal([200.0, 200], [R(right, "b").Right, R(right, "c").Right]);
        var center = FormDesignRules.Aligned(sel, DesignAlign.Center, Page);
        Assert.Equal([150.0, 150], [R(center, "b").CenterX, R(center, "c").CenterX]);
        var top = FormDesignRules.Aligned(sel, DesignAlign.Top, Page);
        Assert.Equal([100.0, 100], [R(top, "b").Y, R(top, "c").Y]);
        var bottom = FormDesignRules.Aligned(sel, DesignAlign.Bottom, Page);
        Assert.Equal([120.0, 120], [R(bottom, "b").Bottom, R(bottom, "c").Bottom]);
        var middle = FormDesignRules.Aligned(sel, DesignAlign.Middle, Page);
        Assert.Equal([110.0, 110], [R(middle, "b").CenterY, R(middle, "c").CenterY]);
        Assert.DoesNotContain(left, f => f.Id == "a");

        // Already lined up: nothing to write. A signed field never moves.
        Assert.Empty(FormDesignRules.Aligned([At("a", 100, 100), At("b", 100, 300)], DesignAlign.Left, Page));
        Assert.Empty(FormDesignRules.Aligned([At("a", 100, 100), At("b", 50, 300) with { Signed = true }], DesignAlign.Left, Page));
        Assert.Throws<DesignRefusal>(() => FormDesignRules.Aligned([At("a", 100, 100)], DesignAlign.Left, Page));

        // On a page shown turned 90°, "left" is the page as shown: the fields' page-space Y lines up.
        var turned = FormDesignRules.Aligned([At("a", 100, 100), At("b", 300, 200)], DesignAlign.Left, Page with { Rotation = 90 });
        Assert.Equal(792 - 120.0, RotatedView.ToView(R(turned, "b"), 612, 792, 90).X);
        Assert.Equal(new RectD(300, 100, 100, 20), R(turned, "b"));
    }

    [Fact]
    public void SeveralFieldsTakeTheFirstOnesSizeAndSpreadEvenly()
    {
        IReadOnlyList<DesignField> sel = [At("a", 100, 100, 150, 30), At("b", 100, 200, 60, 20), At("box", 100, 300, 14, 14, DesignFieldKind.CheckBox)];
        var width = FormDesignRules.SizedAlike(sel, DesignSameSize.Width, Page);
        Assert.Equal(new RectD(100, 200, 150, 20), width.Single(f => f.Id == "b").Rect);
        Assert.Equal(new RectD(100, 300, 150, 150), width.Single(f => f.Id == "box").Rect); // a check box stays square
        var both = FormDesignRules.SizedAlike(sel, DesignSameSize.Both, Page);
        Assert.Equal(new RectD(100, 200, 150, 30), both.Single(f => f.Id == "b").Rect);
        Assert.Equal(new RectD(100, 300, 30, 30), FormDesignRules.SizedAlike(sel, DesignSameSize.Height, Page).Single(f => f.Id == "box").Rect);
        // Kept on the page.
        Assert.Equal(612.0, FormDesignRules.SizedAlike([At("a", 0, 0, 400, 20), At("b", 500, 50)], DesignSameSize.Width, Page).Single().Rect.Right);

        // Across: the outer two stay, the gaps between are equal, in the order shown on the page.
        IReadOnlyList<DesignField> row = [At("m", 300, 100, 50), At("first", 100, 100, 50), At("last", 500, 100, 100), At("n", 200, 100, 20)];
        var spread = FormDesignRules.Spread(row, DesignSpread.Across, Page);
        // span 100..600 = 500, widths 220, gaps 280/3
        var gap = 280.0 / 3;
        Assert.Equal(150 + gap, spread.Single(f => f.Id == "n").Rect.X, 6);
        Assert.Equal(150 + gap + 20 + gap, spread.Single(f => f.Id == "m").Rect.X, 6);
        Assert.DoesNotContain(spread, f => f.Id is "first" or "last");
        var down = FormDesignRules.Spread([At("a", 100, 100), At("b", 100, 130), At("c", 100, 400)], DesignSpread.Down, Page);
        Assert.Equal(250.0, down.Single().Rect.Y);
        Assert.Throws<DesignRefusal>(() => FormDesignRules.Spread([At("a", 0, 0), At("b", 0, 50)], DesignSpread.Down, Page));
    }
}
