using System.Globalization;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Rulers, guides, a grid and snapping (roadmap 4.19): <see cref="LayoutAids"/>, <see cref="PageGuides"/>,
/// <see cref="Snapper"/>, and snapping in Prepare Form's <see cref="FormDesigner"/>.</summary>
public class LayoutAidsTests
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    [Fact]
    public void RulersLabelNiceStepsInTheUnitAndTickBetween()
    {
        // 1 pixel a point, inches: 72 px an inch, so every inch is labelled, tenths between (7.2 px apart).
        var ticks = LayoutAids.Ticks(0, 612, 1, RulerUnit.Inches, Inv);
        Assert.Equal(["0", "1", "2", "3", "4", "5", "6", "7", "8"], ticks.Where(t => t.Level == 0).Select(t => t.Label));
        Assert.Equal(72, ticks.Where(t => t.Level == 0).ElementAt(1).At, 6);
        Assert.Contains(ticks, t => t.Level == 1 && Math.Abs(t.At - 36) < 1e-6); // the half inch
        Assert.True(ticks.Where(t => t.Level > 0).Select(t => t.At).Zip(ticks.Where(t => t.Level > 0).Select(t => t.At).Skip(1)).All(p => p.Second - p.First >= 5 - 1e-9));

        // Zoomed out: labels every 2 or 5 units so they stay 60 px apart.
        var far = LayoutAids.Ticks(0, 2000, 0.25, RulerUnit.Inches, Inv).Where(t => t.Level == 0).Select(t => t.Label).ToList();
        Assert.Equal("0", far[0]);
        Assert.Equal("5", far[1]);

        // Millimeters at 2 px a point (5.7 px a millimeter): 10 mm is 57 px, under 60, so every 20 mm.
        var mm = LayoutAids.Ticks(0, 200, 2, RulerUnit.Millimeters, Inv).Where(t => t.Level == 0).Select(t => t.Label).ToList();
        Assert.Equal(["0", "20", "40", "60"], mm);
        // A part of a page shown: ticks only there; fractions when zoomed in.
        var near = LayoutAids.Ticks(100, 120, 20, RulerUnit.Inches, Inv);
        Assert.All(near, t => Assert.InRange(t.At, 100, 120));
        Assert.Contains(near, t => t.Label == "1.5");
        Assert.Equal("1,5", LayoutAids.Ticks(100, 120, 20, RulerUnit.Inches, new CultureInfo("es-ES")).First(t => t.Level == 0 && t.At > 107).Label);

        Assert.Empty(LayoutAids.Ticks(0, 100, 0, RulerUnit.Inches));
        Assert.Empty(LayoutAids.Ticks(0, double.PositiveInfinity, 1, RulerUnit.Inches));
        Assert.Equal(2, LayoutAids.NiceStep(1.3));
        Assert.Equal(0.05, LayoutAids.NiceStep(0.041), 9);
        Assert.Equal(10, LayoutAids.NiceStep(10));
    }

    [Fact]
    public void TheRulerUnitIsThePagesScaleOrTheRegionsUnlessChosen()
    {
        Assert.Same(RulerUnit.Inches, RulerUnit.For("auto", null, metric: false));
        Assert.Same(RulerUnit.Millimeters, RulerUnit.For("auto", MeasureScale.Default, metric: true));
        Assert.Same(RulerUnit.Points, RulerUnit.For("pt", MeasureScale.From(1, "in", 10, "ft"), metric: true));
        var feet = RulerUnit.For("auto", MeasureScale.From(1, "in", 10, "ft"), metric: false);
        Assert.Equal("ft", feet.Name);
        Assert.Equal(7.2, feet.PointsPer, 6); // an inch on paper (72 pt) is 10 ft
    }

    [Fact]
    public void AGuideFromARulerRunsAsTheScreenShowsIt()
    {
        // Upright: the top ruler gives a line across (a page y), the left one a line down (a page x).
        Assert.Equal(new Guide(0, GuideAxis.Y, 100), LayoutAids.FromRuler(0, topRuler: true, 100, 612, 792, 0));
        Assert.Equal(new Guide(0, GuideAxis.X, 50), LayoutAids.FromRuler(0, topRuler: false, 50, 612, 792, 0));
        // Turned a quarter: a line across the screen is a page x; down the screen a page y, counted from the bottom.
        Assert.Equal(new Guide(1, GuideAxis.X, 100), LayoutAids.FromRuler(1, topRuler: true, 100, 612, 792, 90));
        Assert.Equal(new Guide(1, GuideAxis.Y, 792 - 50), LayoutAids.FromRuler(1, topRuler: false, 50, 612, 792, 90));
        Assert.Equal(new Guide(0, GuideAxis.Y, 792 - 100), LayoutAids.FromRuler(0, topRuler: true, 100, 612, 792, 180));
        Assert.Null(LayoutAids.FromRuler(0, topRuler: true, 800, 612, 792, 0));
        Assert.Null(LayoutAids.FromRuler(0, topRuler: false, -1, 612, 792, 0));
        Assert.True(LayoutAids.AcrossScreen(GuideAxis.Y, 0));
        Assert.False(LayoutAids.AcrossScreen(GuideAxis.Y, 90));
    }

    [Fact]
    public void GuidesAreKeptPerPageMovedAndDraggedOffToGo()
    {
        var guides = new PageGuides();
        Assert.True(guides.Add(new Guide(0, GuideAxis.X, 100), 612, 792));
        Assert.True(guides.Add(new Guide(0, GuideAxis.Y, 900), 612, 792)); // kept on the page
        Assert.True(guides.Add(new Guide(2, GuideAxis.Y, 300), 612, 792));
        Assert.Equal(792, guides.On(0)[1].At);
        Assert.Single(guides.On(2));
        Assert.Equal(new Guide(0, GuideAxis.X, 100), guides.At(0, new PointD(103, 500), 4));
        Assert.Null(guides.At(0, new PointD(110, 500), 4));

        var v = guides.Version;
        var moved = guides.Move(guides.On(0)[0], 150, 612, 792);
        Assert.Equal(150, moved!.At);
        Assert.True(guides.Version > v);
        Assert.Null(guides.Move(moved, -5, 612, 792)); // back onto the ruler: gone
        Assert.Single(guides.On(0));
        Assert.Equal(1, guides.Clear(2));
        Assert.Equal(1, guides.Clear());
        Assert.Empty(guides.All);

        for (var i = 0; i < PageGuides.MaxPerPage; i++) guides.Add(new Guide(0, GuideAxis.X, i), 612, 792);
        Assert.False(guides.Add(new Guide(0, GuideAxis.X, 1), 612, 792));
        Assert.False(guides.Add(new Guide(1, GuideAxis.X, double.NaN), 612, 792));
    }

    [Fact]
    public void PointsAndBoxesSnapToTheNearestGuideGridOrEdge()
    {
        var snap = Snapper.For([new Guide(0, GuideAxis.X, 100), new Guide(0, GuideAxis.Y, 200)], [new RectD(300, 300, 100, 50)], gridStep: 0, reach: 5)!;
        Assert.Equal(new PointD(100, 210), snap.Point(new PointD(97, 210)));
        Assert.Equal([new SnapLine(GuideAxis.X, 100)], snap.Lines);
        Assert.Equal(new PointD(350, 200), snap.Point(new PointD(347, 198))); // another box's center, a guide
        Assert.Equal(new PointD(50, 50), snap.Point(new PointD(50, 50)));
        Assert.Empty(snap.Lines);

        // A box moves so its nearest edge or center lands on a line: here its right edge on the guide.
        Assert.Equal(new RectD(40, 260, 60, 20), snap.Move(new RectD(42, 260, 60, 20)));
        // Its middle on the other box's middle.
        Assert.Equal(new RectD(330, 315, 40, 20), snap.Move(new RectD(332, 318, 40, 20)));
        // Resizing: only the edges that moved snap, never below the smallest size.
        Assert.Equal(new RectD(10, 10, 90, 20), snap.Resize(new RectD(10, 10, 80, 20), new RectD(10, 10, 93, 20)));
        Assert.Equal(new RectD(98, 10, 4, 20), snap.Resize(new RectD(90, 10, 12, 20), new RectD(98, 10, 4, 20), min: 4));

        var grid = Snapper.For(null, null, gridStep: 18, reach: 4)!;
        Assert.Equal(new PointD(36, 63), grid.Point(new PointD(38, 63)));
        Assert.Equal(new PointD(36, 72), grid.Point(new PointD(38, 70)));
        Assert.Null(Snapper.For(null, null, 0, 5));
        Assert.Null(Snapper.For([new Guide(0, GuideAxis.X, 1)], null, 0, 0));
        var (xs, ys) = LayoutAids.Grid(612, 792, 72);
        Assert.Equal(8, xs.Count);
        Assert.Equal(10, ys.Count);
        Assert.Empty(LayoutAids.Grid(612, 792, 0.1).Xs);
    }

    [Fact]
    public void PrepareFormSnapsFieldsToGuidesAndTheOtherFields()
    {
        var a = FormDesign.NewField(DesignFieldKind.Text, 0, new RectD(100, 100, 100, 20), [], "A") with { Id = "a" };
        var b = FormDesign.NewField(DesignFieldKind.Text, 0, new RectD(300, 200, 100, 20), [], "B") with { Id = "b" };
        var d = new FormDesigner(_ => new DesignPage(612, 792));
        d.SetFields([a, b]);
        var guides = new[] { new Guide(0, GuideAxis.X, 250) };
        d.SnapFor = (page, without) => Snapper.For(guides, d.Fields.Where(f => !without.Contains(f.Id)).Select(f => f.Rect), 0, 5);

        // Dragged near B's top: A's top snaps to it; its left stays where the pointer took it.
        d.Press(0, new PointD(110, 110), 1, 5);
        d.Move(new PointD(130, 207), shift: false, dragged: true);
        Assert.Equal(new RectD(120, 200, 100, 20), d.ShownRect(a));
        Assert.Contains(new SnapLine(GuideAxis.Y, 200), d.SnapLines);
        Assert.Equal(new RectD(120, 200, 100, 20), Assert.IsType<DesignRelease.Moved>(d.Release()).Field.Rect);
        Assert.Empty(d.SnapLines);

        // A new box's corner snaps to the guide.
        d.Kind = DesignFieldKind.Text;
        d.Press(0, new PointD(248, 400), 1, 5);
        d.Move(new PointD(352, 430), shift: false, dragged: true);
        Assert.Equal(new RectD(250, 400, 100, 30), Assert.IsType<DesignRelease.Placed>(d.Release()).Placement.Rect);

        // Snapping off: where the pointer is.
        d.Kind = null;
        d.SnapFor = null;
        d.Press(0, new PointD(310, 210), 1, 5);
        d.Move(new PointD(312, 213), shift: false, dragged: true);
        Assert.Equal(new RectD(302, 203, 100, 20), d.ShownRect(b));
    }
}
