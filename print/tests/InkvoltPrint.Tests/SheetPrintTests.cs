using InkvoltPrint.Core.Sheets;

namespace InkvoltPrint.Tests;

/// <summary>
/// Roadmap 4.18: Print a PDF's booklet, poster and pages per sheet, laid out by the shared core's <see cref="PrintLayout"/> (moved
/// from Inkvolt PDF, whose PrintLayoutTests still run on it) through <see cref="SheetPrint"/>.
/// </summary>
public class SheetPrintTests
{
    private static readonly (double W, double H) Letter = (816, 1056);

    private static IReadOnlyList<(double W, double H)> Pages(int n) => [.. Enumerable.Repeat(Letter, n)];

    [Fact]
    public void EachChoiceGivesItsSetup()
    {
        Assert.Null(SheetPrint.Setup(new SheetChoice(PdfLayout.Normal)));
        Assert.Equal(PrintHandling.Booklet, SheetPrint.Setup(new SheetChoice(PdfLayout.Booklet))!.Handling);
        var four = SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 4))!;
        Assert.Equal((PrintHandling.PagesPerSheet, 4), (four.Handling, four.PagesPerSheet));
        Assert.Equal(2, SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 5))!.PagesPerSheet); // not a choice: 2
        var poster = SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, PosterPercent: 300, CutMarks: false))!;
        Assert.Equal((3.0, SheetPrint.PosterOverlap, false), (poster.PosterScale, poster.Overlap, poster.CutMarks));
        Assert.Equal(2.0, SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, PosterPercent: 1000))!.PosterScale);
    }

    [Fact]
    public void ABookletIsTwoSidedAndAPosterNever()
    {
        var booklet = SheetPrint.Setup(new SheetChoice(PdfLayout.Booklet))!;
        var poster = SheetPrint.Setup(new SheetChoice(PdfLayout.Poster))!;
        var four = SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 4))!;
        Assert.True(SheetPrint.TwoSided(booklet, asked: false));
        Assert.False(SheetPrint.TwoSided(poster, asked: true));
        Assert.True(SheetPrint.TwoSided(four, asked: true));
        Assert.False(SheetPrint.TwoSided(four, asked: false));
    }

    [Fact]
    public void ABookletOfSixPagesTakesTwoSheetsBothSidesPerCopy()
    {
        var setup = SheetPrint.Setup(new SheetChoice(PdfLayout.Booklet))!;
        Assert.Equal((4 * 3, 2 * 3), SheetPrint.Count(setup, Pages(6), Letter, copies: 3, twoSided: false));
        // In the order a folded stack reads: sheet 1 carries 8|1 and 2|7 (pages 7 and 8 blank), sheet 2 6|3 and 4|5.
        var plan = SheetPrint.Plan(Pages(6), Letter.W, Letter.H, setup);
        Assert.Equal([0], plan.Sheet(0).Pages.Select(p => p.Page));
        Assert.Equal([1], plan.Sheet(1).Pages.Select(p => p.Page));
        Assert.Equal([5, 2], plan.Sheet(2).Pages.Select(p => p.Page));
        Assert.Equal([3, 4], plan.Sheet(3).Pages.Select(p => p.Page));
    }

    [Fact]
    public void PagesPerSheetCountSidesAndSheets()
    {
        var four = SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 4))!;
        Assert.Equal((3, 3), SheetPrint.Count(four, Pages(9), Letter, copies: 1, twoSided: false));
        Assert.Equal((3, 2), SheetPrint.Count(four, Pages(9), Letter, copies: 1, twoSided: true));
        var sixteen = SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 16))!;
        Assert.Equal((1, 1), SheetPrint.Count(sixteen, Pages(16), Letter, 1, false));
        Assert.Equal((0, 0), SheetPrint.Count(sixteen, [], Letter, 1, false));
    }

    [Fact]
    public void APosterTilesOnePageOverSeveralSheetsWithMarksInsideTheArea()
    {
        var poster = SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, PosterPercent: 200))!;
        var (sides, sheets) = SheetPrint.Count(poster, Pages(1), Letter, 1, true);
        Assert.Equal(sides, sheets);
        Assert.InRange(sheets, 4, 9); // a Letter page twice its size, on Letter sheets less the margins, overlapping
        var plan = SheetPrint.Plan(Pages(1), Letter.W, Letter.H, poster);
        var area = SheetPrint.Area(Letter.W, Letter.H);
        for (var i = 0; i < plan.SheetCount; i++)
        {
            var sheet = plan.Sheet(i);
            Assert.NotEmpty(sheet.Marks);
            Assert.All(sheet.Marks, m => Assert.True(m.X1 >= area.X - 0.01 && m.X2 <= area.Right + 0.01 && m.Y1 >= area.Y - 0.01 && m.Y2 <= area.Bottom + 0.01));
            Assert.NotNull(sheet.Pages.Single().Source);
        }
        var nomarks = SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, CutMarks: false))!;
        Assert.Empty(SheetPrint.Plan(Pages(1), Letter.W, Letter.H, nomarks).Sheet(0).Marks);
    }

    [Fact]
    public void ATurnedSheetsBacksAreDrawnUpsideDown()
    {
        var booklet = SheetPrint.Plan(Pages(4), Letter.W, Letter.H, SheetPrint.Setup(new SheetChoice(PdfLayout.Booklet))!);
        Assert.False(SheetPrint.HalfTurned(booklet.Sheet(0), 0, twoSided: true));
        Assert.True(SheetPrint.HalfTurned(booklet.Sheet(1), 1, twoSided: true));
        Assert.False(SheetPrint.HalfTurned(booklet.Sheet(1), 1, twoSided: false));
        // Four pages on a sheet stay upright: its backs are not turned.
        var four = SheetPrint.Plan(Pages(8), Letter.W, Letter.H, SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 4))!);
        Assert.False(SheetPrint.HalfTurned(four.Sheet(1), 1, twoSided: true));
        // Two portrait pages side by side are on a turned sheet: turned backs.
        var two = SheetPrint.Plan(Pages(4), Letter.W, Letter.H, SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 2))!);
        Assert.True(SheetPrint.HalfTurned(two.Sheet(1), 1, twoSided: true));
    }

    [Fact]
    public void CopiesEachStartOnASheetOfTheirOwn()
    {
        Assert.Equal([0, 1, 2, -1, 0, 1, 2], SheetPrint.Order(3, 2, twoSided: true));
        Assert.Equal([0, 1, 2, 0, 1, 2], SheetPrint.Order(3, 2, twoSided: false));
        Assert.Equal([0, 1, 0, 1], SheetPrint.Order(2, 2, twoSided: true));
        Assert.Empty(SheetPrint.Order(0, 5, true));
        Assert.Equal(999 * 2, SheetPrint.Order(2, 100_000, false).Count); // copies capped
    }

    [Fact]
    public void APosterIsDrawnSharperUpToALimit()
    {
        Assert.Equal(300, SheetPrint.RenderDpi(null));
        Assert.Equal(300, SheetPrint.RenderDpi(SheetPrint.Setup(new SheetChoice(PdfLayout.Booklet))));
        Assert.Equal(450, SheetPrint.RenderDpi(SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, PosterPercent: 150))));
        Assert.Equal(600, SheetPrint.RenderDpi(SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, PosterPercent: 400))));
    }

    [Fact]
    public void AnAbsurdPageSizeCantMakeMillionsOfTiles()
    {
        var poster = SheetPrint.Setup(new SheetChoice(PdfLayout.Poster, PosterPercent: 400))!;
        (double, double)[] huge = [(1e9, 1e9)], broken = [(double.NaN, double.PositiveInfinity)];
        var (sides, _) = SheetPrint.Count(poster, huge, Letter, 1, false);
        Assert.InRange(sides, 1, 20_000); // counted at 200 in a side
        Assert.Equal(sides, SheetPrint.Count(poster, broken, Letter, 1, false).Sides);
        Assert.True(SheetPrint.TooMany(poster, huge, Letter, 1));
        Assert.False(SheetPrint.TooMany(poster, Pages(1), Letter, 1));
        var four = SheetPrint.Setup(new SheetChoice(PdfLayout.PagesPerSheet, PagesPerSheet: 4))!;
        Assert.True(SheetPrint.TooMany(four, Pages(40), Letter, copies: 101)); // 10 sides × 101
        Assert.False(SheetPrint.TooMany(four, Pages(40), Letter, copies: 100));
    }

    [Fact]
    public void TheAreaKeepsAQuarterInchClear()
    {
        var a = SheetPrint.Area(816, 1056);
        Assert.Equal((24.0, 24.0, 768.0, 1008.0), (a.X, a.Y, a.Width, a.Height));
        Assert.Equal(1, SheetPrint.Area(10, 10).Width); // a paper smaller than the margins still has an area
    }
}
