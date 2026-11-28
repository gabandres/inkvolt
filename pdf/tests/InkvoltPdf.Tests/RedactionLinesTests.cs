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

    /// <summary>The stretches of ink (words and boxes: gaps under 8 pixels, between letters, joined; a space is 12).</summary>
    private static List<(int Start, int End)> Runs(bool[] ink)
    {
        var runs = new List<(int, int)>();
        for (var x = 0; x < ink.Length; x++)
        {
            if (!ink[x]) continue;
            if (runs.Count > 0 && x - runs[^1].Item2 < 8) runs[^1] = (runs[^1].Item1, x + 1);
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
        Assert.True(ra.Count == rb.Count, $"{ra.Count} vs {rb.Count} stretches: {string.Join(" ", ra)} | {string.Join(" ", rb)}");
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
            new(72, 120, Word, false),
            new(120 + gap, 120 + gap + boxWidth, Box, true),
            new(120 + 2 * gap + boxWidth, 160 + 2 * gap + boxWidth, Word, true),
            new(165 + 2 * gap + boxWidth, 190 + 2 * gap + boxWidth, Word, true),
        ], []) { Limit = 612 };
        var narrow = RedactionLines.Layout(Line(70, 5));
        var wide = RedactionLines.Layout(Line(80, 9)); // a justified line's wider spaces too
        Assert.Equal(narrow, wide);
        Assert.Equal([(72d, 48d), (125d, 80d), (210d, 40d), (255d, 25d)], narrow);
        Assert.Equal(40, RedactionLines.BoxWidth(1, 20)); // at least one step
        Assert.Equal(120, RedactionLines.BoxWidth(110, 20));
        // A line that would run off the page (or into the next column) narrows its spaces to fit.
        var tight = RedactionLines.Layout(Line(80, 5) with { Limit = 275 });
        Assert.Equal(275, tight[^1].X + tight[^1].Width, 3);
        // Right-aligned, it keeps its end (the band's: 372); centred, its middle (222); either way the same for both widths.
        foreach (var align in new[] { RedactionLines.Alignment.End, RedactionLines.Alignment.Middle })
        {
            var a = RedactionLines.Layout(Line(70, 5) with { Align = align });
            Assert.Equal(a, RedactionLines.Layout(Line(80, 9) with { Align = align }));
            var (first, last) = (a[0].X, a[^1].X + a[^1].Width);
            Assert.Equal(align == RedactionLines.Alignment.End ? 372 : 222, align == RedactionLines.Alignment.End ? last : (first + last) / 2, 3);
        }
    }

    private const RedactionLines.PieceKind Word = RedactionLines.PieceKind.Word, Box = RedactionLines.PieceKind.Box;

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
        Assert.Equal(Boxes(a, "Bob Kahn")[0].X + 1, black.X, 0); // where its text started
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
        var line = Assert.Single(RedactionLines.Find(text, [new RectD(111, 79, 12, 22)], 612, 792));
        Assert.Equal(160, line.Limit, 3);
        Assert.Equal([false, true, false], line.Pieces.Select(p => p.Box));
        var placed = RedactionLines.Layout(line);
        Assert.Equal(40, placed[1].Width, 3); // one step of twice the line's height
        Assert.Equal(160, placed[^1].X + placed[^1].Width, 3);
    }

    [Fact]
    public void APictureRedactedBesideAParagraphLeavesItsLinesAlone()
    {
        static List<(string, RectD)> Chars(string s, double x, double y) => [.. s.Select((c, i) => (c.ToString(), new RectD(x + 10 * i, y, 10, 20)))];
        var text = new PageText([Chars("abc def", 72, 80), Chars("ghi jkl", 72, 104), Chars("mno pqr", 72, 128)]);
        // Taller than a line, a few points right of the paragraph: no letter of it is taken.
        Assert.Empty(RedactionLines.Find(text, [new RectD(150, 70, 200, 90)], 612, 792));
        // A block over the middle of the lines takes "def", "jkl" and "pqr": each line keeps the rest, laid out again.
        Assert.Equal(3, RedactionLines.Find(text, [new RectD(110, 70, 100, 90)], 612, 792).Count);
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
        // Lines found from text with no size are left alone.
        var text = new PageText([[("A", new RectD(10, 10, 0, 0)), ("B", new RectD(20, 10, 5, 0))]]);
        Assert.Empty(RedactionLines.Find(text, [new RectD(0, 0, 50, 50)], 612, 792));
    }

    [Fact]
    public void ASidewaysLineIsLaidOutAlongItsOwnAxis()
    {
        // "A B C" turned clockwise (down the page): "B" redacted, the line's pieces run down it.
        var turned = new PageText([[("A", new RectD(10, 10, 10, 10)), (" ", new RectD(10, 20, 10, 10)), ("B", new RectD(10, 30, 10, 10)),
            (" ", new RectD(10, 40, 10, 10)), ("C", new RectD(10, 50, 10, 10))]], [(0d, 1d)]);
        var line = Assert.Single(RedactionLines.Find(turned, [new RectD(9, 29, 12, 12)], 612, 792));
        Assert.True(line.Vertical);
        Assert.Equal([Word, Box, Word], line.Pieces.Select(p => p.Kind));
        Assert.Equal(new RectD(10, 10, 10, 50), line.ToPage(line.Band));

        // On a page: a name written up the page, two names of different lengths leave the same column.
        static byte[] Up(string name) => Page($"BT /F1 18 Tf 0 1 -1 0 300 100 Tm (Patient: {name} was seen on Monday) Tj ET");
        var a = Redaction.Redact(Up("Robert Kahn"), null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = Boxes(Up("Robert Kahn"), "Robert Kahn") }, dpi: 144);
        var b = Redaction.Redact(Up("Bob Kahn"), null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = Boxes(Up("Bob Kahn"), "Bob Kahn") }, dpi: 144);
        Assert.Equal(a.Blacked[0].Single(), b.Blacked[0].Single());
        var column = new RectD(276, 60, 30, 680);
        SameLine(InkRows(a.Data, column), InkRows(b.Data, column));
    }

    /// <summary>Which pixel rows of a strip of the page hold ink, at 2 pixels a point.</summary>
    private static bool[] InkRows(byte[] pdf, RectD strip)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var img = engine.Render(0, 2, strip);
        var ink = new bool[img.Height];
        for (var y = 0; y < img.Height; y++)
            for (var x = 0; x < img.Width; x++)
                if (img.Pixels[y * img.Stride + x * 3] + img.Pixels[y * img.Stride + x * 3 + 1] + img.Pixels[y * img.Stride + x * 3 + 2] < 384) ink[y] = true;
        return ink;
    }

    [Fact]
    public void RightAlignedAndCentredLinesKeepTheirEdgeNotTheirStart()
    {
        // A right-aligned block (each line ends at 540) and a centred one (each line's middle at 306): with a name of
        // either length redacted, the line comes out the same, still ending at 540, or centred at 306.
        static string Right(string text, double y, string name) => string.Create(CultureInfo.InvariantCulture,
            $"BT /F1 18 Tf {540 - Width(text, name):0.###} {y} Td ({text}) Tj ET ");
        static string Centre(string text, double y, string name) => string.Create(CultureInfo.InvariantCulture,
            $"BT /F1 18 Tf {306 - Width(text, name) / 2:0.###} {y} Td ({text}) Tj ET ");
        foreach (var place in new Func<string, double, string, string>[] { Right, Centre })
        {
            byte[] Block(string name) => Page(place($"Patient: {name} was seen", 700, name) + place("Second line of the block", 676, name)
                                              + place("A third one", 652, name));
            var a = Redact(Block("Robert Kahn"), "Robert Kahn");
            var b = Redact(Block("Bob Kahn"), "Bob Kahn");
            var inkA = Ink(a.Data, LineStrip);
            SameLine(inkA, Ink(b.Data, LineStrip));
            var runs = Runs(inkA);
            var (first, last) = (runs[0].Start / 2.0 + LineStrip.X, runs[^1].End / 2.0 + LineStrip.X);
            if (place == Right) Assert.InRange(last, 538, 542);
            else Assert.InRange((first + last) / 2, 304, 308);
        }
    }

    /// <summary>The width Helvetica 18 gives <paramref name="text"/> on its page (found through the page's text).</summary>
    private static double Width(string text, string name) => Boxes(Page(Show(text)), text).Single().Width - 2;

    [Fact]
    public void NothingOfAnAreaMarksWhereTheLineEnded()
    {
        // The area runs from the name to 500 points, far past the line's end, and starts left of the line: what isn't the
        // box is paper, not black, and the shortened line leaves paper behind it (not the black the area left).
        var pdf = Page(Show("Patient: Robert Kahn"));
        var name = Boxes(pdf, "Robert Kahn")[0];
        var area = RectD.FromEdges(name.X, name.Y, 500, name.Bottom);
        var r = Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [area] }, dpi: 144);
        var box = r.Blacked[0].Single();
        Assert.True(box.Right < 300, $"{box}");
        var after = new RectD(box.Right + 1, area.Y + 1, 500 - box.Right, area.Height - 2);
        Assert.Equal(0, Ink(r.Data, after).Count(x => x));

        var start = Page(Show("Patient: Robert Kahn was seen"));
        var whole = RectD.FromEdges(40, name.Y, Boxes(start, "Patient:")[0].Right, name.Bottom); // the area starts left of the line
        var s = Redaction.Redact(start, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [whole] }, dpi: 144);
        var words = Runs(Ink(s.Data, LineStrip));
        var end = words[^1].End / 2.0 + LineStrip.X;
        Assert.Equal(0, Ink(s.Data, new RectD(end + 1, name.Y + 1, 560 - end, name.Height - 2)).Count(x => x));
    }

    [Fact]
    public void AnEarlierRedactionsBoxKeepsItsWidthAndMovesWithItsLine()
    {
        // A box an earlier redaction left between words (40 points), then another word redacted on the line: the earlier
        // box isn't squeezed into the space it sits in, it moves with the line, and Moved says where it went.
        var pdf = Page("BT /F1 18 Tf 72 700 Td (Name: ) Tj ET 0 g 130 695 40 18 re f BT /F1 18 Tf 175 700 Td (lives at Main Street now) Tj ET");
        var earlier = new RectD(130, 792 - 713, 40, 18);
        var r = Redact(pdf, "Main");
        Assert.Equal(2, r.Blacked[0].Count);
        var kept = r.Blacked[0].Single(b => Math.Abs(b.Width - 40) < 1);
        Assert.Equal(kept.X, r.Moved.Now(0, earlier).X, 0);
        var runs = Runs(Ink(r.Data, LineStrip));
        Assert.Contains(runs, x => Math.Abs((x.End - x.Start) / 2.0 - 40) <= 1); // still 40 points of black
    }

    [Fact]
    public void ALineWhoseSpaceHoldsARuleStaysWhereItIs()
    {
        // A table row: a rule between "here" and "and". Laying the line out again would cut and move the rule, so the line
        // stays: the rule and the words after it where they were, the box rounded where it allows, and it isn't recorded
        // as laid out (the check reports it).
        var pdf = Page(Show("Code    A1 here and B2 there"));
        var code = Boxes(pdf, "Code")[0];
        var a1 = Boxes(pdf, "A1")[0];
        var rule = (code.Right + a1.X) / 2;
        pdf = Page(Show("Code    A1 here and B2 there") + string.Create(CultureInfo.InvariantCulture, $"0 g {rule:0.##} 690 1 30 re f"));
        var r = Redact(pdf, "A1");
        foreach (var kept in new[] { RectD.FromEdges(code.X - 2, 72, rule + 4, 96), RectD.FromEdges(Boxes(pdf, "here")[0].X, 72, 540, 96) })
            Assert.True(Differing(Ink(pdf, kept), Ink(r.Data, kept)) <= 4, $"{kept} stays");
        using var doc = PdfObj.Read(r.Data, null, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var image = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/PdRedacted"])!;
        Assert.Empty(Redaction.LaidOutBoxes(image));
        Assert.NotEmpty(r.Blacked[0]);
    }

    [Fact]
    public void AHighlightedLineIsLaidOutAgain()
    {
        // A highlight from the line's first letter to its last: the paper beside the line is white, its spaces yellow. The
        // yellow is the line's background, not a rule or a picture: the line is laid out again (recorded as Inkvolt's, so
        // the check doesn't report its box), and two names leave the same line. Before, it stayed in place and the space
        // after the box still told the name's width.
        static byte[] Highlighted(string text, bool rule = false)
        {
            var b = Boxes(Page(Show(text)), text)[0].Inflate(-1);
            var was = Boxes(Page(Show(text)), "was")[0];
            var fill = string.Create(CultureInfo.InvariantCulture, $"1 0.85 0.1 rg {b.X:0.##} {792 - b.Bottom:0.##} {b.Width:0.##} {b.Height:0.##} re f 0 g ");
            return Page(fill + (rule ? string.Create(CultureInfo.InvariantCulture, $"{was.X - 3:0.##} 690 1 30 re f ") : "") + Show(text));
        }
        static List<RectD> LaidOut(byte[] data)
        {
            using var doc = PdfObj.Read(data, null, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
            return [.. Redaction.LaidOutBoxes(PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/PdRedacted"])!)];
        }
        var ra = Redact(Highlighted("Patient: Robert Kahn was seen on Monday"), "Robert Kahn");
        var rb = Redact(Highlighted("Patient: Bob Kahn was seen on Monday"), "Bob Kahn");
        Assert.Single(ra.Blacked[0]);
        Assert.Single(rb.Blacked[0]);
        Assert.Equal(ra.Blacked[0][0], rb.Blacked[0][0]);
        SameLine(Ink(ra.Data, LineStrip), Ink(rb.Data, LineStrip));
        Assert.Single(LaidOut(ra.Data));

        // A rule in a highlighted line's space still keeps the line where it is.
        var ruled = Redact(Highlighted("Patient: Robert Kahn was seen on Monday", rule: true), "Robert Kahn");
        Assert.Empty(LaidOut(ruled.Data));
    }

    [Fact]
    public void LinesWhoseBandsOverlapAreEachLaidOutFromThePageAsItWas()
    {
        // Tight leading: the bands of the two lines overlap. The second line is laid out from the page as it was, not from
        // the first line's moved pixels in the rows they share: its rows come out exactly as when it is redacted alone.
        const string Content = "BT /F1 18 Tf 72 700 Td (Alpha Robert Kahn beta) Tj ET BT /F1 18 Tf 72 686 Td (Gamma Bob Kahn delta) Tj ET";
        var pdf = Page(Content);
        var first = Boxes(pdf, "Alpha Robert Kahn beta")[0].Inflate(-1);
        var second = Boxes(pdf, "Gamma Bob Kahn delta")[0].Inflate(-1);
        Assert.True(second.Y < first.Bottom - 2, "the bands overlap");
        // Each area over its own line's rows only, so the rows they share hold the same pixels before either is laid out.
        var (n1, n2) = (Boxes(pdf, "Robert Kahn")[0], Boxes(pdf, "Bob Kahn")[0]);
        var a1 = RectD.FromEdges(n1.X, first.Y, n1.Right, second.Y - 0.5);
        var a2 = RectD.FromEdges(n2.X, first.Bottom + 0.5, n2.Right, second.Bottom);
        var both = Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [a1, a2] }, dpi: 144);
        var bottom = Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [a2] }, dpi: 144);
        Assert.Equal(2, both.Blacked[0].Count);
        using var e1 = PdfEngine.Open(both.Data, InputFileTypes.PDF, null);
        using var e2 = PdfEngine.Open(bottom.Data, InputFileTypes.PDF, null);
        Assert.Equal(e2.Render(0, 2, second).Pixels, e1.Render(0, 2, second).Pixels);
    }

    [Fact]
    public void ATallAreaIsRowsOfLines()
    {
        // An area over the middle of three lines: each line keeps its words with a rounded box, and between the lines,
        // where the area was, is paper, not black with the area's drawn edges.
        var pdf = Page(Show("Alpha one two three") + Show("Beta four five six", 666) + Show("Gamma seven eight", 632));
        var area = RectD.FromEdges(130, 792 - 718, 200, 792 - 626);
        var r = Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [area] }, dpi: 144);
        Assert.Equal(3, r.Blacked[0].Count);
        Assert.All(r.Blacked[0], b => Assert.True(b.Height < 30));
        var bands = new[] { "Alpha one two three", "Beta four five six", "Gamma seven eight" }.Select(t => Boxes(pdf, t)[0].Inflate(-1)).ToList();
        for (var k = 0; k + 1 < bands.Count; k++) // the leading between the lines
        {
            var between = RectD.FromEdges(area.X, bands[k].Bottom + 1, area.Right, bands[k + 1].Y - 1);
            Assert.True(Ink(r.Data, between).Count(x => x) <= 2, $"black between lines {k + 1} and {k + 2}");
        }
    }

    [Fact]
    public void ABlockIsRecordedAsInkvoltsOwn()
    {
        // A block (no text left beside it) is black as drawn, and the picture says so: a check later doesn't call it a leak.
        var pdf = Page(Show("Alpha one two three") + Show("Beta four five six", 676));
        var block = RectD.FromEdges(60, 70, 400, 125);
        var r = Redaction.Redact(pdf, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [block] }, dpi: 72);
        using var doc = PdfObj.Read(r.Data, null, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var image = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/PdRedacted"])!;
        var written = Assert.Single(Redaction.LaidOutBoxes(image));
        Assert.Equal(block.X, written.X, 1);
        Assert.Equal(block.Width, written.Width, 1);
    }
}
