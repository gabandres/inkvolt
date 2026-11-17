using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// The Polygon and Polyline tools' clicks (<see cref="VertexDraft"/>), as the Mac's page view takes them (its PagesTest:
/// a polygon closed by a click on its first corner, a polyline ended with Return), then drawn with <see cref="Annotations.AddPolygon"/>.
/// </summary>
public class VertexDraftTests
{
    [Fact]
    public void APolygonClosesOnAClickOnItsFirstCorner()
    {
        var draft = new VertexDraft(closed: true);
        Assert.False(draft.Click(0, new(100, 100), 1, 4));
        Assert.False(draft.Click(0, new(200, 100), 1, 4));
        Assert.False(draft.Click(0, new(150, 180), 1, 4));
        Assert.True(draft.Click(0, new(102, 101), 1, 4)); // on the first corner: done
        var points = draft.Finish();
        Assert.Equal([new(100, 100), new(200, 100), new(150, 180)], points);
        Assert.False(draft.IsActive);

        var pdf = Annotations.AddPolygon(TestPdf.Make(1), null, 0, points!, true, AnnotStyle.Pen(AnnotColor.Red, 2), "Ana", "pg-1");
        var a = Annotations.Read(pdf, null).Single(x => x.Id == "pg-1");
        Assert.Equal("Polygon", a.Subtype);
        Assert.Equal(3, a.Geometry!.Paths[0].Count);
    }

    [Fact]
    public void APolylineEndsWithEnter_OrADoubleClick()
    {
        var draft = new VertexDraft(closed: false);
        draft.Click(0, new(100, 100), 1, 4);
        draft.Click(0, new(200, 120), 1, 4);
        Assert.False(draft.Click(0, new(101, 100), 1, 4)); // a polyline doesn't close on its first point
        draft.Click(0, new(250, 160), 1, 4);
        Assert.Equal(4, draft.Finish()!.Count); // Enter

        // A double-click: its first press adds the last point, its second ends the line.
        draft.Click(0, new(100, 100), 1, 4);
        draft.Click(0, new(200, 100), 1, 4);
        Assert.True(draft.Click(0, new(200, 100), 2, 4));
        Assert.Equal([new(100, 100), new(200, 100)], draft.Finish());
        // A click on a point, then a double-click there: one point, not two.
        draft.Click(0, new(100, 100), 1, 4);
        draft.Click(0, new(150, 150), 1, 4);
        draft.Click(0, new(150, 150), 1, 4);
        Assert.True(draft.Click(0, new(150, 150), 2, 4));
        Assert.Equal(2, draft.Finish()!.Count);
    }

    [Fact]
    public void TooFewCornersDrawNothing_AndEachPageStartsOver()
    {
        var polygon = new VertexDraft(closed: true);
        polygon.Click(0, new(100, 100), 1, 4);
        polygon.Click(0, new(200, 100), 1, 4);
        Assert.True(polygon.Click(0, new(200, 100), 2, 4));
        Assert.Null(polygon.Finish()); // two corners aren't a polygon: dropped
        Assert.False(polygon.IsActive);

        polygon.Click(0, new(100, 100), 1, 4);
        polygon.Click(0, new(200, 100), 1, 4);
        polygon.Click(1, new(50, 50), 1, 4); // another page: starts over there
        Assert.Equal(1, polygon.Page);
        Assert.Single(polygon.Points);

        Assert.True(polygon.Undo());
        Assert.False(polygon.IsActive); // its last corner taken back: nothing left
        Assert.False(polygon.Undo());
        Assert.Null(new VertexDraft(closed: false).Finish());
    }

    [Fact]
    public void ClicksThatArentNumbers_OrAFlood_AreBounded()
    {
        var draft = new VertexDraft(closed: false);
        Assert.False(draft.Click(0, new(double.NaN, 1), 1, 4));
        Assert.False(draft.Click(-1, new(1, 1), 1, 4));
        Assert.False(draft.Click(0, new(1, double.PositiveInfinity), 1, 4));
        Assert.False(draft.IsActive);

        var finished = false;
        for (var i = 0; i < VertexDraft.MaxVertices + 50 && !finished; i++) finished = draft.Click(0, new(i % 500, i / 500), 1, 0);
        Assert.True(finished); // the limit ends the drawing
        Assert.Equal(VertexDraft.MaxVertices, draft.Finish()!.Count);
    }
}
