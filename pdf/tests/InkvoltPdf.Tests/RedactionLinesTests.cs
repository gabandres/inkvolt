using System.Globalization;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 1.5's last item: glyph-spacing inference around pixel redactions (arXiv 2206.02285). Pages where the width
/// of the gap a removed name leaves would tell the name: after Redaction, a line looks the same whichever name it held.
/// </summary>
public class RedactionLinesTests
{
    private static byte[] Page(string content) => Core2Pdf.Build([
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream(content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]);

    private static string Show(string text, double y = 700, double wordSpacing = 0) =>
        string.Create(CultureInfo.InvariantCulture, $"BT /F1 18 Tf {wordSpacing:0.###} Tw 72 {y:0.##} Td ({text}) Tj ET ");

    /// <summary>Each match of <paramref name="text"/> on the page, grown by a point (as Apply Redactions marks it).</summary>
    private static List<RectD> Boxes(byte[] pdf, string text)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var t = engine.GetText(0);
        return [.. t.Find(text, true, false).Select(m => t.GetRects(m.Start, m.End).Aggregate(default(RectD), (a, r) => a.Union(r)).Inflate(1))];
    }

    private static RedactedPages Redact(byte[] pdf, string text) =>
        Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = Boxes(pdf, text) }, dpi: 144);

    /// <summary>Which pixel columns of a strip of the page hold ink, at 2 pixels a point.</summary>
    private static bool[] Ink(byte[] pdf, RectD strip)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var img = engine.Render(0, 2, strip);
        var ink = new bool[img.Width];
        for (var y = 0; y < img.Height; y++)
            for (var x = 0; x < img.Width; x++)
                if (img.Pixels[y * img.Stride + x * 3] + img.Pixels[y * img.Stride + x * 3 + 1] + img.Pixels[y * img.Stride + x * 3 + 2] < 384) ink[x] = true;
        return ink;
    }

    /// <summary>The first column with ink at or after <paramref name="from"/>.</summary>
    private static int FirstInk(bool[] ink, int from) => Array.FindIndex(ink, from, x => x);

    private static int Differing(bool[] a, bool[] b) => a.Zip(b).Count(p => p.First != p.Second);

    /// <summary>The stretches of ink (words and boxes: gaps under 4 pixels, between letters, joined).</summary>
    private static List<(int Start, int End)> Runs(bool[] ink)
    {
        var runs = new List<(int, int)>();
        for (var x = 0; x < ink.Length; x++)
        {
            if (!ink[x]) continue;
            if (runs.Count > 0 && x - runs[^1].Item2 < 4) runs[^1] = (runs[^1].Item1, x + 1);
            else runs.Add((x, x + 1));
        }
        return runs;
    }

    /// <summary>
    /// The line looks the same in both: the same words and box, each starting and ending within a pixel of the other's.
    /// (Not to the pixel: a moved word keeps the shading it was drawn with, a fraction of a pixel that depends on where it was.)
    /// </summary>
    private static void SameLine(bool[] a, bool[] b)
    {
        var ra = Runs(a);
        var rb = Runs(b);
        Assert.True(ra.Count == rb.Count, $"{ra.Count} vs {rb.Count} stretches");
        foreach (var (x, y) in ra.Zip(rb))
        {
            Assert.InRange(x.Start - y.Start, -1, 1);
            Assert.InRange(x.End - y.End, -1, 1);
        }
    }

    /// <summary>The line at 700 (Helvetica 18) from its start to the page's right margin.</summary>
    private static readonly RectD LineStrip = new(60, 72, 500, 24);

    [Fact]
    public void TheLayoutDependsOnTheRemovedWidthOnlyByItsStep()
    {
        // "Name: ▮ lives here", the box 70 or 80 points wide: in a line 20 points high both are two 40-point steps.
        RedactionLines.CutLine Line(double boxWidth, double gap) => new(new RectD(72, 80, 300, 20), new RectD(72, 78, 300, 24),
        [
            new(72, 120, false, false),
            new(120 + gap, 120 + gap + boxWidth, true, true),
            new(120 + 2 * gap + boxWidth, 160 + 2 * gap + boxWidth, false, true),
            new(165 + 2 * gap + boxWidth, 190 + 2 * gap + boxWidth, false, true),
        ], []);
        var narrow = RedactionLines.Layout(Line(70, 5), 612);
        var wide = RedactionLines.Layout(Line(80, 9), 612); // a justified line's wider spaces too
        Assert.Equal(narrow, wide);
        Assert.Equal([(72d, 48d), (125d, 80d), (210d, 40d), (255d, 25d)], narrow);
        Assert.Equal(40, RedactionLines.BoxWidth(1, 20)); // at least one step
        Assert.Equal(120, RedactionLines.BoxWidth(110, 20));
        // A line that would run off the page (or into the next column) narrows its spaces to fit.
        var tight = RedactionLines.Layout(Line(80, 5), 275);
        Assert.Equal(275, tight[^1].X + tight[^1].Width, 3);
    }

    [Fact]
    public void TwoNamesOfDifferentWidthsLeaveTheSameLine()
    {
        // The text after the name starts where the name ended: left as it was, its place tells the name's width.
        var a = Page(Show("Patient: Robert Kahn was seen on Monday"));
        var b = Page(Show("Patient: Bob Kahn was seen on Monday"));
        var wasA = Boxes(a, "was")[0].X;
        var wasB = Boxes(b, "was")[0].X;
        Assert.True(Math.Abs(wasA - wasB) > 10, $"{wasA} {wasB}"); // the names differ by 22 points

        var ra = Redact(a, "Robert Kahn");
        var rb = Redact(b, "Bob Kahn");
        Assert.Equal(ra.Blacked[0].Single(), rb.Blacked[0].Single());
        var inkA = Ink(ra.Data, LineStrip);
        var inkB = Ink(rb.Data, LineStrip);
        SameLine(inkA, inkB);
        // Everything after the box is still there, in order: "was seen on Monday" starts a space after it.
        var box = ra.Blacked[0].Single();
        var after = FirstInk(inkA, (int)((box.Right - LineStrip.X) * 2) + 3); // past the box's shaded edge
        Assert.InRange(after / 2.0 + LineStrip.X - box.Right, 3, 8);
        Assert.True(inkA.Skip(after).Count(x => x) > 100, "the words after the box show");
        // The box is a whole number of steps of twice the line's height.
        var steps = box.Width / (RedactionLines.StepOfHeight * Boxes(a, "Patient:")[0].Inflate(-1).Height);
        Assert.Equal(Math.Round(steps), steps, 1);
    }

    [Fact]
    public void JustifiedLinesKeepNoTraceOfTheRemovedWidthInTheirSpaces()
    {
        // Justified to the same width, the spaces of a line with a shorter name are wider: the words before the box tell it.
        const string Before = "The patient";
        string Text(string name) => $"{Before} {name} was seen at the clinic today";
        double Natural(string name) => Boxes(Page(Show(Text(name))), Text(name)).Single().Width - 2;
        double Spacing(string name) => (480 - Natural(name)) / (Text(name).Count(c => c == ' '));
        var a = Page(Show(Text("Robert Kahn"), wordSpacing: Spacing("Robert Kahn")));
        var b = Page(Show(Text("Bob Kahn"), wordSpacing: Spacing("Bob Kahn")));
        Assert.Equal(Boxes(a, "today")[0].Right, Boxes(b, "today")[0].Right, 0.5);
        Assert.True(Math.Abs(Boxes(a, "patient")[0].X - Boxes(b, "patient")[0].X) > 1); // the first space already differs

        var ra = Redact(a, "Robert Kahn");
        var rb = Redact(b, "Bob Kahn");
        var inkA = Ink(ra.Data, LineStrip);
        var inkB = Ink(rb.Data, LineStrip);
        SameLine(inkA, inkB);
        // The words that moved are said, so what was kept can be found where it went.
        var today = Boxes(a, "today")[0];
        var now = ra.Moved.Now(0, today);
        Assert.NotEqual(today.X, now.X);
        Assert.True(Ink(ra.Data, now.Inflate(-2)).Count(x => x) > 10);
    }

    [Fact]
    public void ALineRedactedWholeIsJustItsRoundedBoxAndABlockKeepsItsArea()
    {
        // A whole line redacted: its box, drawn round the words, would be as wide as they are; it is rounded to whole steps,
        // so two names on lines of their own leave the same box. The line under it keeps its place.
        var a = Page(Show("Bob Kahn") + Show("Visible line below", 670));
        var b = Page(Show("Robert Kahn") + Show("Visible line below", 670));
        var ra = Redact(a, "Bob Kahn");
        var rb = Redact(b, "Robert Kahn");
        var black = ra.Blacked[0].Single();
        Assert.Equal(black, rb.Blacked[0].Single());
        Assert.Equal(Boxes(a, "Bob Kahn")[0].X, black.X, 0);
        SameLine(Ink(ra.Data, LineStrip), Ink(rb.Data, LineStrip));
        Assert.True(ra.Moved.IsEmpty);
        var below = new RectD(60, 792 - 690, 500, 24);
        Assert.True(Differing(Ink(a, below), Ink(ra.Data, below)) <= 4);

        // A block over both lines: its box is the area drawn, as drawn.
        var block = RectD.FromEdges(60, 70, 400, 130);
        var rc = Redaction.Redact(a, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [block] }, dpi: 144);
        Assert.Equal(block, rc.Blacked[0].Single());
    }

    [Fact]
    public void ANeighbouringColumnIsNotRunInto()
    {
        // "Ann a b" and, on the same rows, another column's "Right": with "a" redacted and its box rounded up to a whole
        // step, the line would reach past where the other column starts; its spaces narrow so it stops short of it.
        static List<(string, RectD)> Chars(string s, double x) => [.. s.Select((c, i) => (c.ToString(), new RectD(x + 10 * i, 80, 10, 20)))];
        var text = new PageText([Chars("Ann a b", 72), Chars("Right", 170)]);
        var line = Assert.Single(RedactionLines.Find(text, [new RectD(111, 79, 12, 22)]));
        Assert.Equal(160, line.Limit, 3);
        Assert.Equal([false, true, false], line.Pieces.Select(p => p.Box));
        var placed = RedactionLines.Layout(line, 612);
        Assert.Equal(40, placed[1].Width, 3); // one step of twice the line's height
        Assert.Equal(160, placed[^1].X + placed[^1].Width, 3);
    }

    [Fact]
    public void APictureRedactedBesideAParagraphLeavesItsLinesAlone()
    {
        static List<(string, RectD)> Chars(string s, double x, double y) => [.. s.Select((c, i) => (c.ToString(), new RectD(x + 10 * i, y, 10, 20)))];
        var text = new PageText([Chars("abc def", 72, 80), Chars("ghi jkl", 72, 104), Chars("mno pqr", 72, 128)]);
        // Taller than a line, a few points right of the paragraph: no letter of it is taken.
        Assert.Empty(RedactionLines.Find(text, [new RectD(150, 70, 200, 90)]));
        // A block over the middle of the lines takes "def", "jkl" and "pqr": each line keeps the rest, laid out again.
        Assert.Equal(3, RedactionLines.Find(text, [new RectD(110, 70, 100, 90)]).Count);
    }

    [Fact]
    public void HostileAreasAndTextLeaveThePageRedacted()
    {
        var pdf = Page(Show("Patient: Ann Lee was seen"));
        var name = Boxes(pdf, "Ann Lee")[0];
        IReadOnlyList<RectD>[] hostile =
        [
            [name, new RectD(double.NaN, 0, 10, 10), new RectD(0, double.PositiveInfinity, 10, 10)],
            [name, new RectD(-1e9, name.Y, 2e9, name.Height)], // an area across the whole line and far beyond
            [.. Enumerable.Range(0, 2000).Select(i => new RectD(72 + i * 0.01, name.Y, 0.5, name.Height))], // thousands of slivers
        ];
        foreach (var areas in hostile)
        {
            var r = Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = areas }, dpi: 72);
            using var engine = PdfEngine.Open(r.Data, InputFileTypes.PDF, null);
            Assert.True(engine.GetText(0).IsEmpty);
        }
        // Lines found from text with no size, or turned sideways, are left alone.
        var text = new PageText([[("A", new RectD(10, 10, 0, 0)), ("B", new RectD(20, 10, 5, 0))]]);
        Assert.Empty(RedactionLines.Find(text, [new RectD(0, 0, 50, 50)]));
        var turned = new PageText([[("A", new RectD(10, 10, 10, 10)), ("B", new RectD(10, 20, 10, 10)), ("C", new RectD(10, 30, 10, 10))]], [(0d, 1d)]);
        Assert.Empty(RedactionLines.Find(turned, [new RectD(10, 20, 10, 10)]));
    }
}
