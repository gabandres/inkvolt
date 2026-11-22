using System.Globalization;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 4.22: a picture or a paragraph turned to any angle in Edit Text &amp; Images (<see cref="ContentEditor.RotateImage"/>,
/// <see cref="ContentEditor.RotateParagraph"/>), the turn handle's and angle box's rules (<see cref="ContentTurn"/>), and
/// pdf.js reading a turned paragraph's words in order.
/// </summary>
public partial class ParagraphEditTests
{
    private static void Near(PointD expected, PointD actual, double slack = 0.5) =>
        Assert.True(Math.Abs(expected.X - actual.X) < slack && Math.Abs(expected.Y - actual.Y) < slack, $"{actual} is not {expected}");

    [Theory]
    [InlineData(30)]
    [InlineData(-45)]
    [InlineData(90)]
    [InlineData(180)]
    public void AParagraphTurnsAboutItsMiddleKeepingItsTextAndWhatFollows(double degrees)
    {
        // Room all round (a turned paragraph reaching the heading would take it in as text inside it).
        var pdf = Turned(0, 150, 450, gap: 160);
        var before = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        var others = before.Runs.Where(r => p.Runs.All(x => x.Id != r.Id) && r.Text.Trim().Length > 0).Select(r => (r.Text, r.Box)).ToList();
        Assert.NotEmpty(others);

        var turned = ContentEditor.RotateParagraph(pdf, null, p, degrees);
        var after = ContentEditor.Read(turned, null, 0);
        var q = after.Paragraphs.Single(x => x.Text.StartsWith("The quick", StringComparison.Ordinal));
        // The same words, in the turned direction, about the same middle.
        Assert.Equal(p.Text, q.Text);
        Assert.Equal(p.Lines.Count, q.Lines.Count);
        AssertDirection(degrees, q.Angle);
        Near(new PointD(p.Box.CenterX, p.Box.CenterY), new PointD(q.Box.CenterX, q.Box.CenterY), 2);
        // Each glyph run turned about that middle: the first line's start went where the turn takes it.
        var first = p.Runs.MinBy(r => r.Origin.Y + r.Origin.X / 1000)!;
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        double cx = p.Box.CenterX, cy = p.Box.CenterY;
        var expected = new PointD(cx + (first.Origin.X - cx) * cos - (first.Origin.Y - cy) * sin, cy + (first.Origin.X - cx) * sin + (first.Origin.Y - cy) * cos);
        var firstAfter = after.Runs.Where(r => r.Text == first.Text).MinBy(r => Math.Abs(r.Origin.X - expected.X) + Math.Abs(r.Origin.Y - expected.Y))!;
        Near(expected, firstAfter.Origin, 0.6);
        // What follows is where it was.
        var lost = others.Where(o => !after.Runs.Any(r => r.Text == o.Text && Math.Abs(r.Box.X - o.Box.X) < 0.5 && Math.Abs(r.Box.Y - o.Box.Y) < 0.5)).ToList();
        Assert.True(lost.Count == 0, string.Join("; ", lost.Select(o => $"{o.Text} at {o.Box}: now " + string.Join(",", after.Runs.Where(r => r.Text == o.Text).Select(r => r.Box.ToString())))));

        // Turned back: where it started.
        var back = ContentEditor.RotateParagraph(turned, null, q, -degrees);
        var again = ContentEditor.Read(back, null, 0).Paragraphs.Single(x => x.Text.StartsWith("The quick", StringComparison.Ordinal));
        Assert.Equal(0, again.Angle, 3);
        Assert.Equal(p.Lines.Count, again.Lines.Count);
        for (var i = 0; i < p.Lines.Count; i++)
        {
            Assert.Equal(p.Lines[i].X, again.Lines[i].X, 1);
            Assert.Equal(p.Lines[i].Y, again.Lines[i].Y, 1);
        }
        Assert.Same(pdf, ContentEditor.RotateParagraph(pdf, null, p, 360));
    }

    [Fact]
    public void ATurnedParagraphStaysEditableAndAFormsParagraphTurnsInItsForm()
    {
        var pdf = Turned(30, 150, 300);
        var p = Body0(pdf);
        var turned = ContentEditor.RotateParagraph(pdf, null, p, 20);
        var q = Body0(turned);
        AssertDirection(p.Angle + 20, q.Angle);
        // Still a paragraph that reflows in its own direction.
        var edited = ContentEditor.ReplaceParagraph(turned, null, q, q.Text + " " + Twenty);
        Assert.Equal(q.Text + " " + Twenty, Body0(edited).Text);

        var form = ContentEditPdf.Make("q /Fm1 Do Q", form: FormBody(), fontText: Chars);
        var fp = ContentEditor.Read(form, null, 0).Paragraphs.Where(x => x.Blocked is null).MaxBy(x => x.Lines.Count)!;
        var ft = ContentEditor.RotateParagraph(form, null, fp, -15);
        var after = ContentEditor.Read(ft, null, 0).Paragraphs.Single(x => x.Text == fp.Text);
        AssertDirection(-15, after.Angle);
    }

    [Fact]
    public void APictureTurnsAboutItsMiddleAndSaysItsAngle()
    {
        const string pictures = "q 100 0 0 50 72 600 cm /Im1 Do Q\nq 40 0 0 20 300 300 cm /Im1 Do Q";
        var pdf = ContentEditPdf.Make(pictures);
        var images = ContentEditor.Read(pdf, null, 0).Images;
        Assert.Equal(0, images[0].Angle);
        var center = new PointD(images[0].Box.CenterX, images[0].Box.CenterY);

        var turned = ContentEditor.RotateImage(pdf, null, images[0], 90);
        var after = ContentEditor.Read(turned, null, 0).Images;
        Assert.Equal(90, after[0].Angle, 3);
        Near(center, new PointD(after[0].Box.CenterX, after[0].Box.CenterY));
        Assert.Equal(50, after[0].Box.Width, 1); // a quarter turn: its width is its height
        Assert.Equal(100, after[0].Box.Height, 1);
        Assert.Equal(images[1].Box, after[1].Box); // the other use stays

        var more = ContentEditor.RotateImage(turned, null, after[0], -60);
        var a2 = ContentEditor.Read(more, null, 0).Images[0];
        Assert.Equal(30, a2.Angle, 3);
        Assert.True(a2.Turned);
        Near(center, new PointD(a2.Box.CenterX, a2.Box.CenterY));
        // The bounding box of a 100 x 50 box turned 30°.
        var (sin, cos) = Math.SinCos(Math.PI / 6);
        Assert.Equal(100 * cos + 50 * sin, a2.Box.Width, 1);

        // MuPDF draws it there.
        using var engine = PdfEngine.Open(more, MuPDFCore.InputFileTypes.PDF, null);
        var shown = engine.GetExportPage(0, images: true).Images.Select(i => i.Box).ToList();
        Assert.Contains(shown, b => Math.Abs(b.X + b.Width / 2 - center.X) < 1 && Math.Abs(b.Y + b.Height / 2 - center.Y) < 1);

        Assert.Same(pdf, ContentEditor.RotateImage(pdf, null, images[0], 0));
        // On a turned page, the turn is as the page shows.
        var onTurned = ContentEditPdf.Make(pictures, rotate: 90);
        var img = ContentEditor.Read(onTurned, null, 0).Images[0];
        var t = ContentEditor.Read(ContentEditor.RotateImage(onTurned, null, img, 45), null, 0).Images[0];
        Assert.Equal(ContentTurn.Normalize(img.Angle + 45), t.Angle, 3);
    }

    [Fact]
    public void TheTurnHandleAndAngleBoxRules()
    {
        Assert.Equal(-170, ContentTurn.Normalize(190));
        Assert.Equal(180, ContentTurn.Normalize(-180));
        Assert.Equal(0, ContentTurn.Normalize(720));
        Assert.Equal(0, ContentTurn.Normalize(double.NaN));

        var box = new RectD(100, 100, 200, 100);
        Assert.Equal(new PointD(300 + ContentTurn.HandleGap, 100 - ContentTurn.HandleGap), ContentTurn.HandlePoint(box));
        Assert.True(ContentTurn.OnHandle(box, new PointD(318, 82), 5));
        Assert.False(ContentTurn.OnHandle(box, new PointD(300, 100), 5));

        // From straight above the middle to straight right of it: a quarter turn clockwise.
        var c = new PointD(200, 150);
        Assert.Equal(90, ContentTurn.Dragged(c, new PointD(200, 50), new PointD(300, 150), 0, steps: false), 6);
        Assert.Equal(100, ContentTurn.Dragged(c, new PointD(200, 50), new PointD(300, 150), 10, steps: false), 6);
        // Shift: the nearest 15°.
        var a = ContentTurn.Dragged(c, new PointD(200, 50), new PointD(300, 140), 0, steps: false);
        Assert.InRange(a, 80, 90);
        Assert.Equal(90, ContentTurn.Dragged(c, new PointD(200, 50), new PointD(300, 140), 0, steps: true));
        Assert.Equal(0, ContentTurn.Dragged(c, new PointD(200, 50), c, 0, steps: false));
        Assert.Equal(-90, ContentTurn.Dragged(c, new PointD(200, 50), new PointD(100, 150), 0, steps: false), 6);

        Assert.Equal(30, ContentTurn.Parse("30°"));
        Assert.Equal(-12.5, ContentTurn.Parse(" -12.5 ", CultureInfo.InvariantCulture));
        Assert.Equal(12.5, ContentTurn.Parse("12,5", new CultureInfo("es-ES")));
        Assert.Equal(-90, ContentTurn.Parse("270"));
        Assert.Null(ContentTurn.Parse("abc"));
        Assert.Null(ContentTurn.Parse(""));
        Assert.Null(ContentTurn.Parse("1e300"));

        Assert.Equal(20, ContentTurn.TurnBy(10, 30));
        Assert.Equal(-20, ContentTurn.TurnBy(170, 150));
        Assert.Equal(20, ContentTurn.TurnBy(170, -170));
        Assert.Null(ContentTurn.TurnBy(45, 45.001));
        Assert.Equal("-12.5°", ContentTurn.Format(-12.5, CultureInfo.InvariantCulture));

        var corners = ContentTurn.Corners(new RectD(0, 0, 20, 10), 90);
        Near(new PointD(15, -5), corners[0], 1e-6);
        Near(new PointD(15, 15), corners[1], 1e-6);
    }

    [Fact]
    public void TurnedParagraphsReadTheSameInPdfJs()
    {
        var (node, skipped) = PdfJs.Ready();
        if (node is null)
        {
            if (skipped is not null) output.WriteLine(skipped);
            return;
        }
        var failures = new List<string>();
        foreach (var degrees in new[] { 30.0, -15, 90, 180 })
        {
            var pdf = Turned(0, 150, 450, gap: 160);
            var p = Body0(pdf);
            var turned = ContentEditor.RotateParagraph(pdf, null, p, degrees);
            var got = Words(PdfJs.Text(node, turned, 0));
            var miss = PdfJs.FirstMiss(Words(p.Text), got);
            output.WriteLine($"turned {degrees}°: pdf.js {(miss is null ? "reads it in order" : "DIFFERS: " + miss)}");
            if (miss is not null) failures.Add($"turned {degrees}°: {miss}");
        }
        foreach (var f in failures) output.WriteLine("FAIL " + f);
        Assert.Empty(failures);
    }
}
