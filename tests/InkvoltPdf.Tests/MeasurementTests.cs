using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

public class MeasurementTests
{
    private static readonly PointD O = new(0, 0);

    [Fact]
    public void GeometryOfLinesAndShapes()
    {
        Assert.Equal(5, MeasureGeometry.Length([O, new(3, 4)]), 9);
        Assert.Equal(12, MeasureGeometry.Length([O, new(3, 4), new(3, 11)]), 9);
        // A closed outline counts the edge back to the start.
        Assert.Equal(40, MeasureGeometry.Length([O, new(10, 0), new(10, 10), new(0, 10)], closed: true), 9);
        // Shoelace: any winding, and a concave L-shape.
        Assert.Equal(100, MeasureGeometry.Area([O, new(10, 0), new(10, 10), new(0, 10)]), 9);
        Assert.Equal(100, MeasureGeometry.Area([O, new(0, 10), new(10, 10), new(10, 0)]), 9);
        Assert.Equal(75, MeasureGeometry.Area([O, new(10, 0), new(10, 5), new(5, 5), new(5, 10), new(0, 10)]), 9);
        Assert.Equal(0, MeasureGeometry.Area([O, new(1, 1)]), 9);
        Assert.Equal(new PointD(5, 5), MeasureGeometry.Centroid([O, new(10, 0), new(10, 10), new(0, 10)]));
        Assert.Equal(new PointD(1, 0), MeasureGeometry.Centroid([O, new(2, 0), new(1, 0)])); // degenerate: the points' middle
    }

    [Fact]
    public void ScalesTurnPointsIntoRealLengths()
    {
        var s = MeasureScale.From(1, "in", 10, "ft");
        Assert.Equal("1 in = 10 ft", s.Ratio);
        Assert.Equal(10.0 / 72, s.PerPoint, 12);
        Assert.Equal(10, s.Value(MeasureKind.Distance, [O, new(72, 0)]), 9);
        Assert.Equal("10.00 ft", s.Format(MeasureKind.Distance, [O, new(72, 0)]));
        Assert.Equal("1,000.00 sq ft", s.Format(MeasureKind.Area, [O, new(720, 0), new(720, 72), new(0, 72)]));
        Assert.Equal(100 * 10, s.Value(MeasureKind.Area, [O, new(720, 0), new(720, 72), new(0, 72)]), 6);
        Assert.Equal(40, s.Value(MeasureKind.Perimeter, [O, new(72, 0), new(72, 72), new(0, 72), O]), 9);

        var metric = MeasureScale.From(1, "cm", 2, "m") with { Decimals = 1 };
        Assert.Equal(2, metric.Value(MeasureKind.Distance, [O, new(72 / 2.54, 0)]), 9);
        Assert.Equal("2.0 m", metric.Format(MeasureKind.Distance, [O, new(72 / 2.54, 0)]));
        Assert.Equal("1 in = 1 in", MeasureScale.Default.Ratio);
        Assert.Equal(1, MeasureScale.Default.Value(MeasureKind.Distance, [O, new(72, 0)]), 9);
    }

    [Theory]
    [InlineData("1 in = 10 ft", 10.0 / 72, "ft")]
    [InlineData("1in=10ft", 10.0 / 72, "ft")]
    [InlineData("1/4 in = 1 ft", 4.0 / 72, "ft")]
    [InlineData("1 cm = 0.5 m", 0.5 * 2.54 / 72, "m")]
    [InlineData("2 mm = 1 km", 0.5 * 25.4 / 72, "km")]
    [InlineData("1:100 m", 100 * 0.0254 / 72, "m")]
    public void RatiosAreRead(string text, double perPoint, string unit)
    {
        Assert.True(MeasureScale.TryParse(text, out var s), text);
        Assert.Equal(perPoint, s!.PerPoint, 9);
        Assert.Equal(unit, s.Unit);
    }

    [Theory]
    [InlineData("")]
    [InlineData("10 ft")]
    [InlineData("1 in = ft")]
    [InlineData("0 in = 10 ft")]
    [InlineData("1 in = -2 ft")]
    [InlineData("1 parsec = 2 ft")]
    public void BadRatiosAreRefused(string text) => Assert.False(MeasureScale.TryParse(text, out _));

    [Fact]
    public void CalibrationFromAKnownLength()
    {
        // A wall drawn 144 pt long is 25 ft: 1 in on paper is 12.5 ft.
        var s = MeasureScale.Calibrate(144, 25, "ft");
        Assert.Equal(25.0 / 144, s.PerPoint, 12);
        Assert.Equal("1 in = 12.5 ft", s.Ratio);
        Assert.Throws<ArgumentException>(() => MeasureScale.Calibrate(0, 25, "ft"));
        Assert.Throws<ArgumentException>(() => MeasureScale.Calibrate(10, 0, "ft"));
        Assert.Throws<ArgumentException>(() => MeasureScale.Calibrate(10, 1, "furlong"));
    }

    [Fact]
    public void PageScalesAreWrittenAsViewportsAndReadBack()
    {
        var pdf = TestPdf.Make(2);
        var scale = MeasureScale.From(1, "in", 10, "ft");
        var scaled = Measurements.SetPageScale(pdf, null, [1], scale);
        Assert.Null(Measurements.PageScale(scaled, null, 0, new PointD(100, 100)));
        var back = Measurements.PageScale(scaled, null, 1, new PointD(100, 100));
        Assert.NotNull(back);
        Assert.Equal(scale.PerPoint, back!.PerPoint, 9);
        Assert.Equal("ft", back.Unit);
        Assert.Equal("1 in = 10 ft", back.Ratio);

        // Setting again replaces it; null removes it.
        var twice = Measurements.SetPageScale(scaled, null, [1], MeasureScale.From(1, "in", 20, "ft"));
        using (var doc = Core2Pdf.Open(twice)) Assert.Single(PdfObj.Array(doc.Pages[1].Elements["/VP"])!.Elements);
        Assert.Null(Measurements.PageScale(Measurements.SetPageScale(twice, null, [1], null), null, 1, new PointD(100, 100)));
    }

    [Fact]
    public void AViewportOfTheDocumentWinsWhereItApplies()
    {
        // A drawing whose lower half is a detail at another scale (a second viewport, after the whole-page one).
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /VP [" +
            "<< /Type /Viewport /BBox [0 0 612 792] /Measure << /Type /Measure /Subtype /RL /R (1 in = 10 ft) /X [<< /Type /NumberFormat /U (ft) /C 0.138889 /D 100 >>] >> >> " +
            "<< /Type /Viewport /BBox [0 0 612 396] /Measure << /Type /Measure /Subtype /RL /R (1 in = 2 ft) /X [<< /Type /NumberFormat /U (ft) /C 0.0277778 /D 10 >>] >> >>" +
            "] >>",
        ]);
        Assert.Equal("1 in = 10 ft", Measurements.PageScale(pdf, null, 0, new PointD(100, 100))!.Ratio); // top half (page space, y down)
        var detail = Measurements.PageScale(pdf, null, 0, new PointD(100, 700))!;
        Assert.Equal("1 in = 2 ft", detail.Ratio);
        Assert.Equal(1, detail.Decimals); // /D 10
        // The same, read once for the whole document and looked up per point (what the viewer does as the pointer moves).
        var areas = Measurements.Viewports(pdf, null)[0];
        Assert.Equal("1 in = 10 ft", Measurements.ScaleAt(areas, new PointD(100, 100))!.Ratio);
        Assert.Equal("1 in = 2 ft", Measurements.ScaleAt(areas, new PointD(100, 700))!.Ratio);
        Assert.Null(Measurements.ScaleAt(null, new PointD(1, 1)));
        // A new Inkvolt scale goes first, so the document's own detail viewport still wins inside its area.
        var ours = Measurements.SetPageScale(pdf, null, [0], MeasureScale.From(1, "in", 5, "ft"));
        Assert.Equal("1 in = 5 ft", Measurements.PageScale(ours, null, 0, new PointD(100, 100))!.Ratio);
        Assert.Equal("1 in = 2 ft", Measurements.PageScale(ours, null, 0, new PointD(100, 700))!.Ratio);
    }

    [Fact]
    public void MeasurementsBecomeAnnotationsAcrobatUnderstands()
    {
        var scale = MeasureScale.From(1, "in", 10, "ft");
        var pdf = TestPdf.Make(1);
        pdf = Measurements.Add(pdf, null, 0, MeasureKind.Distance, [new(72, 200), new(216, 200)], scale, "Ada", "m1");
        pdf = Measurements.Add(pdf, null, 0, MeasureKind.Perimeter, [new(72, 300), new(144, 300), new(144, 372)], scale, "Ada", "m2");
        pdf = Measurements.Add(pdf, null, 0, MeasureKind.Area, [new(300, 300), new(372, 300), new(372, 372), new(300, 372)], scale, "Ada", "m3");
        using var doc = Core2Pdf.Open(pdf);
        var annots = PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().ToList();
        Assert.Equal(["Line", "PolyLine", "Polygon"], annots.Select(a => PdfObj.Name(a.Elements["/Subtype"])));
        Assert.Equal(["LineDimension", "PolyLineDimension", "PolygonDimension"], annots.Select(a => PdfObj.Name(a.Elements["/IT"])));
        Assert.Equal(["20.00 ft", "20.00 ft", "100.00 sq ft"], annots.Select(a => PdfObj.Text(a.Elements["/Contents"])));
        foreach (var a in annots)
        {
            var m = PdfObj.Dict(a.Elements["/Measure"])!;
            Assert.Equal("RL", PdfObj.Name(m.Elements["/Subtype"]));
            Assert.Equal("1 in = 10 ft", PdfObj.Text(m.Elements["/R"]));
            var x = PdfObj.Dict(PdfObj.Array(m.Elements["/X"])!.Elements[0])!;
            Assert.Equal(10.0 / 72, PdfObj.Num(x.Elements["/C"]), 4);
            Assert.Equal("ft", PdfObj.Text(x.Elements["/U"]));
            Assert.NotNull(PdfObj.Dict(a.Elements["/AP"])?.Elements["/N"]);
        }
        Assert.True(PdfObj.Resolve(annots[0].Elements["/Cap"]) is PdfBoolean { Value: true });
        // The label is drawn into the appearance: the page shows the value.
        Assert.Contains("20.00 ft", Core2Pdf.AllText(pdf));
        Assert.Contains("100.00 sq ft", Core2Pdf.AllText(pdf));

        // Reshaped, the value follows.
        var moved = Annotations.UpdateGeometry(pdf, null, "m1", new AnnotGeometry { Paths = [[new(72, 200), new(288, 200)]] });
        using var doc2 = Core2Pdf.Open(moved);
        var line = PdfObj.Dict(PdfObj.Array(doc2.Pages[0].Elements["/Annots"])!.Elements[0])!;
        Assert.Equal("30.00 ft", PdfObj.Text(line.Elements["/Contents"]));
        Assert.Equal("LineDimension", PdfObj.Name(line.Elements["/IT"]));
    }

    [Fact]
    public void MeasurementsReadBackWithTheirValues()
    {
        var scale = MeasureScale.From(1, "cm", 1, "m");
        var pdf = Measurements.Add(TestPdf.Make(1), null, 0, MeasureKind.Distance, [new(100, 100), new(100 + 72 / 2.54 * 3, 100)], scale, "Ada", "d1");
        var found = Assert.Single(Measurements.Read(pdf, null, 0));
        Assert.Equal(MeasureKind.Distance, found.Kind);
        Assert.Equal("d1", found.Id);
        Assert.Equal(3, found.Value, 4); // coordinates are stored to 4 decimals
        Assert.Equal("3.00 m", found.Text);
        Assert.Equal("m", found.Scale.Unit);
    }

    [Fact]
    public void APageWithAUserUnitMeasuresTrue()
    {
        // /UserUnit 2: each unit of the page's coordinates is 2 points, so a 72-unit line is 2 in long.
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /UserUnit 2 >>",
        ]);
        var scale = MeasureScale.From(1, "in", 10, "ft");
        pdf = Measurements.SetPageScale(pdf, null, [0], scale);
        var read = Measurements.PageScale(pdf, null, 0, new PointD(10, 10))!;
        Assert.Equal(2, read.UserUnit);
        Assert.Equal(10.0 / 72, read.PerPoint, 9);
        Assert.Equal(20, read.Value(MeasureKind.Distance, [new(0, 0), new(72, 0)]), 9);
        Assert.Equal(2, Measurements.UserUnits(pdf, null)[0]);
        using (var doc = Core2Pdf.Open(pdf))
        {
            // /X /C converts from user space units: 20 ft per 72 units.
            var vp = PdfObj.Dict(PdfObj.Array(doc.Pages[0].Elements["/VP"])!.Elements[0])!;
            var x = PdfObj.Dict(PdfObj.Array(PdfObj.Dict(vp.Elements["/Measure"])!.Elements["/X"])!.Elements[0])!;
            Assert.Equal(20.0 / 72, PdfObj.Num(x.Elements["/C"]), 4);
        }
        pdf = Measurements.Add(pdf, null, 0, MeasureKind.Distance, [new(100, 100), new(172, 100)], read, "Ada", "u1");
        var m = Assert.Single(Measurements.Read(pdf, null, 0));
        Assert.Equal("20.00 ft", m.Text);
        // A real-size measurement there too: 72 units are 2 in.
        var plain = Measurements.Add(pdf, null, 0, MeasureKind.Distance, [new(100, 200), new(172, 200)], MeasureScale.Default, "Ada", "u2");
        Assert.Contains(Measurements.Read(plain, null, 0), x => x.Text == "2.00 in");
    }

    [Fact]
    public void MeasuringOnATurnedPageReadsUpright()
    {
        var pdf = PageEditor.Rotate(TestPdf.Make(1), null, [0], 90);
        var scale = MeasureScale.From(1, "in", 1, "ft");
        pdf = Measurements.Add(pdf, null, 0, MeasureKind.Distance, [new(100, 100), new(244, 100)], scale, "Ada", "r1");
        Assert.Equal("2.00 ft", Assert.Single(Measurements.Read(pdf, null, 0)).Text);
        // The label is upright as shown: MuPDF reads it as one horizontal run.
        Assert.Contains(Core2Pdf.Lines(pdf), l => l.Text.Contains("2.00 ft"));
    }
}
