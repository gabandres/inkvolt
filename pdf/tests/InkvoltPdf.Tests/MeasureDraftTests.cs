using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// A measurement under way (<see cref="MeasureDraft"/>; <c>PageViewer.Measure</c> only feeds it the mouse and keys and
/// draws it): what a click, a double-click, Enter, Backspace, Esc, Shift and a move do, the value so far, and what is
/// drawn. The names are the Mac's <c>MeasureDraftTests</c> where they apply.
/// </summary>
public class MeasureDraftTests
{
    private static readonly MeasureScale TenFeet = MeasureScale.From(1, "in", 10, "ft");

    [Fact]
    public void A_distance_ends_at_its_second_click()
    {
        var d = new MeasureDraft(MeasureTool.Distance);
        Assert.Null(d.Click(0, new PointD(72, 100)));
        Assert.True(d.IsActive);
        Assert.Single(d.Points);
        Assert.True(d.Move(0, new PointD(144, 100)));
        Assert.Equal("1.00 in", d.Value(MeasureScale.Default));
        Assert.Equal("1 point(s), 0.00 in", d.Described(MeasureScale.Default)); // without the pointer
        var done = d.Click(0, new PointD(216, 100));
        Assert.NotNull(done);
        Assert.Equal(0, done.Page);
        Assert.Equal([new PointD(72, 100), new PointD(216, 100)], done.Points);
        Assert.True(!d.IsActive && d.Hover is null && d.Described(MeasureScale.Default) is null);
    }

    [Fact]
    public void An_area_ends_with_a_double_click_or_enter_once_it_has_three_corners()
    {
        var d = new MeasureDraft(MeasureTool.Area);
        d.Click(1, new PointD(0, 0));
        d.Click(1, new PointD(72, 0));
        Assert.Null(d.Finish()); // two corners: it goes on
        Assert.True(d.IsActive);
        d.Click(1, new PointD(72, 72));
        // The double-click's first press adds the corner, its second ends the area without adding another.
        d.Click(1, new PointD(0, 72));
        var done = d.Click(1, new PointD(0, 72), clicks: 2);
        Assert.NotNull(done);
        Assert.Equal(4, done.Points.Count);
        Assert.Equal("100.00 sq ft", TenFeet.Format(MeasureKind.Area, done.Points));

        var r = new MeasureDraft(MeasureTool.Perimeter);
        r.Click(0, new PointD(0, 0));
        r.Click(0, new PointD(72, 0));
        Assert.Equal(2, r.Finish()?.Points.Count);
        // A distance's double-click is two clicks.
        var line = new MeasureDraft(MeasureTool.Distance);
        line.Click(0, new PointD(0, 0));
        Assert.Null(line.Click(0, new PointD(0, 0), clicks: 2));
        Assert.Single(line.Points);
    }

    [Fact]
    public void The_value_so_far_follows_the_pointer()
    {
        var d = new MeasureDraft(MeasureTool.Area);
        Assert.Equal("", d.Value(TenFeet));
        Assert.False(d.Move(0, new PointD(5, 5))); // nothing under way: ignored
        d.Click(0, new PointD(0, 0));
        d.Click(0, new PointD(72, 0));
        d.Move(0, new PointD(72, 72));
        Assert.Equal("50.00 sq ft · perimeter 34.14 ft", d.Value(TenFeet));
        Assert.Equal("10.00 ft", d.Value(TenFeet, includeHover: false));
        Assert.False(d.Move(3, new PointD(0, 0))); // another page: ignored
        Assert.Equal(new PointD(72, 72), d.Hover);
        Assert.False(d.Move(0, new PointD(double.NaN, 1)));
        Assert.Equal(new PointD(0, 0), d.ScalePoint); // the scale is read at the first point
    }

    [Fact]
    public void Backspace_escape_and_another_page()
    {
        var d = new MeasureDraft(MeasureTool.Perimeter);
        d.Click(0, new PointD(0, 0));
        d.Click(0, new PointD(10, 0));
        d.Click(0, new PointD(10, 0)); // the same spot again isn't a point
        Assert.Equal(2, d.Points.Count);
        Assert.True(d.RemoveLast());
        Assert.Equal([new PointD(0, 0)], d.Points);
        Assert.True(d.RemoveLast());
        Assert.False(d.IsActive);
        Assert.False(d.RemoveLast());
        d.Click(0, new PointD(0, 0));
        d.Click(2, new PointD(5, 5)); // a click on another page starts over there
        Assert.Equal(2, d.Page);
        Assert.Equal([new PointD(5, 5)], d.Points);
        d.Move(2, new PointD(9, 9));
        d.Cancel();
        Assert.True(!d.IsActive && d.Points.Count == 0 && d.Hover is null);
    }

    [Fact]
    public void Shift_keeps_a_segment_straight()
    {
        var d = new MeasureDraft(MeasureTool.Calibrate);
        Assert.Equal(MeasureKind.Distance, d.Kind);
        d.Click(0, new PointD(100, 100));
        d.Move(0, new PointD(200, 103), shift: true);
        Assert.Equal(100, d.Hover!.Value.Y, 9);
        var done = d.Click(0, new PointD(200, 103), shift: true);
        Assert.NotNull(done);
        Assert.Equal(100, done.Points[1].Y, 9);
    }

    /// <summary>Windows': what the page view draws while measuring.</summary>
    [Fact]
    public void The_sketch_joins_the_points_and_the_pointer_and_fills_an_area()
    {
        var d = new MeasureDraft(MeasureTool.Area);
        Assert.Null(d.Sketch);
        d.Click(4, new PointD(0, 0));
        d.Move(4, new PointD(10, 0));
        var two = d.Sketch!;
        Assert.Equal(4, two.Page);
        Assert.Equal([new PointD(0, 0), new PointD(10, 0)], two.Points);
        Assert.Equal(1, two.Corners); // the pointer's spot gets no dot
        Assert.False(two.Filled);
        d.Click(4, new PointD(10, 0));
        d.Move(4, new PointD(10, 10));
        Assert.True(d.Sketch!.Filled);
        Assert.Equal(2, d.Sketch.Corners);
        var line = new MeasureDraft(MeasureTool.Perimeter);
        line.Click(0, new PointD(0, 0));
        line.Click(0, new PointD(10, 0));
        line.Move(0, new PointD(10, 10));
        Assert.False(line.Sketch!.Filled); // only an area is filled
    }

    /// <summary>Windows': a click off the page or at no number does nothing, and a flood of clicks stops at the bound every drawing has.</summary>
    [Fact]
    public void Clicks_off_the_page_or_past_the_bound_add_nothing()
    {
        var d = new MeasureDraft(MeasureTool.Perimeter);
        Assert.Null(d.Click(-1, new PointD(1, 1)));
        Assert.Null(d.Click(0, new PointD(double.PositiveInfinity, 1)));
        Assert.False(d.IsActive);
        for (var i = 0; i < VertexDraft.MaxVertices + 5; i++) d.Click(0, new PointD(i, 0));
        Assert.Equal(VertexDraft.MaxVertices, d.Points.Count);
        Assert.Equal(VertexDraft.MaxVertices, d.Finish()?.Points.Count);
    }

    [Fact]
    public void Each_tool_measures_its_kind_with_the_points_it_needs()
    {
        Assert.Equal(MeasureKind.Distance, MeasureDraft.KindOf(MeasureTool.Distance));
        Assert.Equal(MeasureKind.Perimeter, MeasureDraft.KindOf(MeasureTool.Perimeter));
        Assert.Equal(MeasureKind.Area, MeasureDraft.KindOf(MeasureTool.Area));
        Assert.Equal(MeasureKind.Distance, MeasureDraft.KindOf(MeasureTool.Calibrate));
        Assert.Equal(3, new MeasureDraft(MeasureTool.Area).Needed);
        Assert.Equal(2, new MeasureDraft(MeasureTool.Perimeter).Needed);
        Assert.Equal(2, new MeasureDraft(MeasureTool.Calibrate).Needed);
    }
}
