using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 2.1: paragraphs in turned text (a sideways column, text set at an angle) edit as paragraphs, in their own direction.</summary>
public partial class ParagraphEditTests
{
    /// <summary>
    /// Body as a left-aligned paragraph turned <paramref name="degrees"/> counterclockwise on an upright page (PDF space),
    /// its first baseline starting at (<paramref name="x"/>, <paramref name="y"/>), "Next block starts here"
    /// <paramref name="gap"/> points under its last line in the same direction.
    /// </summary>
    private static byte[] Turned(double degrees, double x, double y, double gap = 60, string extra = "")
    {
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        var lines = Wrap(Body, Width);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(cos)} {N(sin)} {N(-sin)} {N(cos)} {N(x)} {N(y)} Tm ({lines[0]}) Tj");
        foreach (var l in lines.Skip(1)) sb.Append($" T* ({l}) Tj");
        sb.Append($" 0 {N(-gap)} Td (Next block starts here) Tj ET {extra}");
        return ContentEditPdf.Make(sb.ToString(), fontText: Chars);
    }

    /// <summary>A paragraph's lines in its own direction (as if turned upright).</summary>
    private static IReadOnlyList<RectD> FrameLines(TextParagraph p) => (p.Upright ?? p).Lines;

    /// <summary>Two angles are one direction (180° and -180° alike).</summary>
    private static void AssertDirection(double expected, double actual) =>
        Assert.True(Math.Cos((actual - expected) * Math.PI / 180) > 0.9999, $"{actual}° is not {expected}°");

    [Theory]
    [InlineData(90, 150, 250)]
    [InlineData(-90, 450, 600)]
    [InlineData(180, 450, 500)]
    [InlineData(30, 150, 300)]
    public void ATurnedParagraphReflowsInItsOwnDirection(double degrees, double x, double y)
    {
        var pdf = Turned(degrees, x, y);
        var before = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal(Body, p.Text);
        AssertDirection(-degrees, p.Angle);
        Assert.Equal(Wrap(Body, Width).Count, p.Lines.Count);
        Assert.Equal(Step, p.LineStep, 1);
        var next = before.Runs.Single(r => r.Text == "Next block starts here");
        Assert.DoesNotContain(next, p.Runs);

        var text = Body + " " + Twenty;
        var check = p.Check(text);
        Assert.Null(check.Overlaps);
        Assert.True(check.LineCount > p.Lines.Count);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        Assert.Contains(Words(text), Words(ContentEditPdf.Text(edited)));
        var q = Body0(edited);
        Assert.Equal(text, q.Text);
        AssertDirection(-degrees, q.Angle);
        Assert.Equal(check.LineCount, q.Lines.Count);
        Assert.Equal(p.LineStep, q.LineStep, 1);
        // Its lines start where its first line did, in its own direction, and stay inside its width.
        var was = FrameLines(p);
        Assert.All(FrameLines(q), l => Assert.Equal(was[0].X, l.X, 1));
        Assert.Equal(was[0].Y, FrameLines(q)[0].Y, 1);
        Assert.True(FrameLines(q).Max(l => l.Right) <= was.Max(l => l.Right) + 0.5);
        var next2 = ContentEditor.Read(edited, null, 0).Runs.Single(r => r.Text == "Next block starts here");
        Assert.Equal(next.Box.X, next2.Box.X, 2);
        Assert.Equal(next.Box.Y, next2.Box.Y, 2);
        output.WriteLine($"{degrees}°: {p.Box} → {q.Box}, {q.Lines.Count} lines");
    }

    [Fact]
    public void TurnedTextRunningIntoTheBlockBelowIsReportedBeforeAnythingIsWritten()
    {
        var pdf = Turned(90, 150, 250, gap: 18);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.NotNull(p.Below);
        var next = ContentEditor.Read(pdf, null, 0).Runs.Single(r => r.Text == "Next block starts here");
        var check = p.Check(Body + " " + Twenty);
        Assert.NotNull(check.Overlaps);
        Assert.False(check.Overlaps!.Value.Intersect(next.Box).IsEmpty);
        var e = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, Body + " " + Twenty));
        Assert.NotNull(e.Overlaps);
    }

    [Fact]
    public void TurnedAndUprightTextAreNotJoinedAndClicksBetweenTurnedLinesFindTheParagraph()
    {
        // A sideways column beside an upright paragraph: two paragraphs, each in its own direction.
        var lines = Wrap(Body, Width);
        var upright = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL 200 700 Td ({lines[0]}) Tj");
        foreach (var l in lines.Skip(1)) upright.Append($" T* ({l}) Tj");
        upright.Append(" ET");
        var pdf = Turned(90, 80, 300, extra: upright.ToString());
        var content = ContentEditor.Read(pdf, null, 0);
        var both = content.Paragraphs.Where(q => q.Text == Body).ToList();
        Assert.Equal(2, both.Count);
        Assert.Single(both, q => Math.Abs(q.Angle) < 0.5);
        var turned = Assert.Single(both, q => Math.Abs(q.Angle + 90) < 0.5);
        Assert.All(turned.Runs, r => Assert.Equal(-90, r.Angle, 1));

        // Between its first two lines (they run up the page, one beside the other), the turned paragraph.
        var l0 = turned.Lines[0];
        var l1 = turned.Lines[1];
        var x = (Math.Min(l0.Right, l1.Right) + Math.Max(l0.X, l1.X)) / 2;
        Assert.Same(turned, content.ParagraphAt(x, l0.CenterY));
    }

    [Theory]
    [InlineData(new[] { 10.0, 10.4, 10.6, 10.9 })] // two directions side by side: 10.6 is near both middles
    [InlineData(new[] { 0.3, 0.6, 0.7 })]           // a turned direction beside upright text
    public void EachRunIsInOneParagraphWhateverDirectionsAreNearIt(double[] degrees)
    {
        // Short lines, each turned its own few degrees (counterclockwise in PDF space), far enough apart not to join.
        var sb = new StringBuilder();
        for (var i = 0; i < degrees.Length; i++)
        {
            var (sin, cos) = Math.SinCos(degrees[i] * Math.PI / 180);
            sb.Append($"BT /FA {N(Size)} Tf {N(cos)} {N(sin)} {N(-sin)} {N(cos)} 72 {N(700 - i * 120)} Tm (Line number {i} of the page) Tj ET\n");
        }
        var content = ContentEditor.Read(ContentEditPdf.Make(sb.ToString(), fontText: Chars), null, 0);
        var runs = content.Runs.Where(r => r.Text.StartsWith("Line number", StringComparison.Ordinal)).ToList();
        Assert.Equal(degrees.Length, runs.Count);
        foreach (var r in runs)
        {
            var holding = content.Paragraphs.Where(p => p.Runs.Contains(r)).ToList();
            Assert.True(holding.Count == 1, $"{r.Text} ({r.Angle:0.##}°) is in {holding.Count} paragraphs");
            // In the paragraph of its own direction: within half a degree of the paragraph's angle.
            Assert.True(Math.Abs(ContentEditor.Turn(r.Angle - holding[0].Angle)) < 0.5, $"{r.Angle} in a paragraph at {holding[0].Angle}");
        }
    }
}
