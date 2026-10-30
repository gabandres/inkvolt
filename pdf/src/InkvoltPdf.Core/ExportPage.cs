namespace InkvoltPdf.Core;

/// <summary>A run of text in one look: font family as the PDF names it, size in points, bold, italic, color (0xRRGGBB).</summary>
public sealed record ExportSpan(string Text, string Font, double Size, bool Bold, bool Italic, uint Color, RectD Box)
{
    /// <summary>The font is a serif one (from the PDF's font flags), so a reader without it gets a serif in its place.</summary>
    public bool Serif { get; init; }

    /// <summary>The font is monospaced.</summary>
    public bool Mono { get; init; }

    /// <summary>Where the run is on the page as shown, when something needs that after a page was turned (<see cref="DocLayout.AnalyzeForTags"/>).</summary>
    public RectD? PageBox { get; init; }

    /// <summary>Same look as <paramref name="other"/> (text and position aside).</summary>
    public bool SameLook(ExportSpan other) =>
        Font == other.Font && Math.Abs(Size - other.Size) < 0.25 && Bold == other.Bold && Italic == other.Italic && Color == other.Color;
}

/// <summary>
/// A line of text on a page (page space: points, top-left of the displayed page). Sideways: not left-to-right;
/// <see cref="Turn"/> says which way it reads.
/// </summary>
public sealed record ExportLine(IReadOnlyList<ExportSpan> Spans, RectD Box, bool Sideways = false)
{
    /// <summary>
    /// Quarter turns clockwise from left-to-right: 0 reads left to right, 1 top to bottom, 2 upside down, 3 bottom to
    /// top. Slanted lines take the nearest.
    /// </summary>
    public int Turn { get; init; }

    /// <summary>The turn to read it by: <see cref="Turn"/>, or bottom to top (the usual) for a sideways line made without one.</summary>
    public int Reads => Turn != 0 || !Sideways ? Turn : 3;

    /// <summary>
    /// Where a line's characters split at column gaps: [Start, End) ranges. Each character gives its text, where it
    /// starts and ends along the reading direction, and its type size. A gap over 2.5 times the size splits; so does
    /// one over the size between two number-like words ("28.54", "12%", "–"): table columns set close together that
    /// MuPDF reads as one line. Spaces in a gap are dropped.
    /// </summary>
    public static List<(int Start, int End)> SplitAtColumnGaps(IReadOnlyList<(string Text, double From, double To, double Size)> chars)
    {
        var parts = new List<(int Start, int End)>();
        var start = 0;
        var lastInk = -1;
        bool Blank(int k) => string.IsNullOrWhiteSpace(chars[k].Text);
        string Word(int from, int step)
        {
            var k = from;
            while (k + step >= 0 && k + step < chars.Count && !Blank(k + step)) k += step;
            var (a, b) = step < 0 ? (k, from) : (from, k);
            return string.Concat(Enumerable.Range(a, b - a + 1).Select(i => chars[i].Text));
        }
        for (var i = 0; i < chars.Count; i++)
        {
            if (Blank(i)) continue;
            if (lastInk >= 0)
            {
                var gap = chars[i].From - chars[lastInk].To;
                var size = Math.Max(1, Math.Max(chars[i].Size, chars[lastInk].Size));
                if (gap > 2.5 * size || (gap > size && NumberLike(Word(lastInk, -1)) && NumberLike(Word(i, 1))))
                {
                    parts.Add((start, lastInk + 1));
                    start = i;
                }
            }
            lastInk = i;
        }
        parts.Add((start, chars.Count));
        return parts;

    }

    /// <summary>A number as a table shows it ("28.54", "1,200", "12%", "(3)", "$5"), or a dash standing for none.</summary>
    public static bool NumberLike(string w)
    {
        w = w.Trim();
        return
            w.Length > 0 && w.All(c => char.IsDigit(c) || c is '.' or ',' or '%' or '-' or '–' or '—' or '+' or '(' or ')' or '$' or '€' or '£' or '±')
            && (w.Any(char.IsDigit) || w is "-" or "–" or "—");
    }

    /// <summary>The quarter turn nearest a baseline direction (MuPDF's line direction, page space, y down).</summary>
    public static int TurnOf(double dx, double dy) =>
        Math.Abs(dx) >= Math.Abs(dy) ? (dx >= 0 ? 0 : 2) : (dy > 0 ? 1 : 3);

    public string Text => string.Concat(Spans.Select(s => s.Text));

    /// <summary>The size most of the line's characters have.</summary>
    public double Size => Spans.Count == 0 ? 0 : Spans.GroupBy(s => Math.Round(s.Size * 2) / 2).MaxBy(g => g.Sum(s => s.Text.Length))!.Key;

    public static ExportLine Of(IReadOnlyList<ExportSpan> spans, bool sideways = false)
    {
        var box = spans[0].Box;
        foreach (var s in spans.Skip(1)) box = box.Union(s.Box);
        return new ExportLine(spans, box, sideways);
    }
}

/// <summary>
/// A picture on a page: encoded bytes (PNG or JPEG, see <see cref="Extension"/>) and where it is drawn. <see cref="Ref"/>:
/// the name a writer gave it once stored (its bytes are then dropped).
/// </summary>
public sealed record ExportImage(byte[] Data, string Extension, int PixelWidth, int PixelHeight, RectD Box, string? Ref = null)
{
    /// <summary>Where it is on the page as shown, when something needs that after a page was turned (<see cref="DocLayout.AnalyzeForTags"/>).</summary>
    public RectD? PageBox { get; init; }

    /// <summary>What it shows, from the PDF's tags (<see cref="ExportTags"/>); null when they don't say.</summary>
    public string? Alt { get; init; }

    /// <summary>The quarter turns its page was turned by for layout (<see cref="ExportPage.Turned"/>): its pixels weren't.</summary>
    public int Turn { get; init; }
}

/// <summary>
/// What an export reads from one page: its text lines, pictures and the thin lines and box outlines it draws (for ruled
/// tables). <see cref="FromOcr"/>: the text came from recognizing a scanned page.
/// </summary>
public sealed record ExportPage(double Width, double Height, IReadOnlyList<ExportLine> Lines, IReadOnlyList<ExportImage> Images,
    IReadOnlyList<RectD> Rules, bool FromOcr = false)
{
    /// <summary>The simple shapes the page draws, in order (only read for PowerPoint; see <see cref="ExportShapes"/>).</summary>
    public IReadOnlyList<ExportShape> Shapes { get; init; } = [];

    public bool HasText => Lines.Any(l => l.Spans.Any(s => s.Text.Any(c => !char.IsWhiteSpace(c))));

    /// <summary>
    /// The page turned so that text reading <paramref name="turn"/> quarter turns clockwise reads left to right: boxes
    /// move into the turned frame (width and height swap for 1 and 3), lines' turns change to match. Pictures keep their
    /// pixels (only their place turns).
    /// </summary>
    public ExportPage Turned(int turn)
    {
        turn = ((turn % 4) + 4) % 4;
        if (turn == 0) return this;
        var (w, h) = (Width, Height);
        (double X, double Y) P(double x, double y) => turn switch
        {
            1 => (y, w - x),     // read downwards: down the page becomes left to right
            2 => (w - x, h - y),
            _ => (h - y, x),     // read upwards
        };
        RectD Map(RectD r)
        {
            var a = P(r.X, r.Y);
            var b = P(r.Right, r.Bottom);
            return RectD.FromEdges(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
        }
        var lines = Lines.Select(l =>
        {
            var t = (l.Reads - turn + 4) % 4;
            return new ExportLine([.. l.Spans.Select(s => s with { Box = Map(s.Box) })], Map(l.Box), t != 0) { Turn = t };
        }).ToList();
        var (nw, nh) = turn == 2 ? (w, h) : (h, w);
        return this with
        {
            Width = nw, Height = nh, Lines = lines,
            Images = [.. Images.Select(i => i with { Box = Map(i.Box), Turn = (i.Turn + turn) % 4 })],
            Rules = [.. Rules.Select(Map)],
            Shapes = [.. Shapes.Select(s => s with { Box = Map(s.Box) })],
        };
    }

    /// <summary>The same page without its pictures (Excel and plain text don't use them).</summary>
    public ExportPage WithoutImages() => Images.Count == 0 ? this : this with { Images = [] };

    /// <summary>
    /// A scanned page's recognized words as text lines: words side by side at the same height form a line, split where a
    /// gap is wider than a few letters (columns, table cells). Sizes are estimated from the word heights.
    /// </summary>
    public static IReadOnlyList<ExportLine> LinesFromOcr(IEnumerable<OcrWord> words)
    {
        var rows = new List<List<OcrWord>>();
        foreach (var w in words.Where(w => !string.IsNullOrWhiteSpace(w.Text) && w.Rect.Height > 0).OrderBy(w => w.Rect.Y))
        {
            List<OcrWord>? best = null;
            var bestOverlap = 0.0;
            foreach (var row in rows)
            {
                double top = row.Min(r => r.Rect.Y), bottom = row.Max(r => r.Rect.Bottom);
                var overlap = Math.Min(bottom, w.Rect.Bottom) - Math.Max(top, w.Rect.Y);
                var h = Math.Min(bottom - top, w.Rect.Height);
                if (overlap < 0.5 * h || overlap <= bestOverlap) continue;
                if (row.Any(r => r.Rect.X < w.Rect.Right && w.Rect.X < r.Rect.Right)) continue; // a word below or above, not beside
                best = row;
                bestOverlap = overlap;
            }
            if (best is null) rows.Add([w]);
            else best.Add(w);
        }

        var lines = new List<ExportLine>();
        foreach (var row in rows.OrderBy(r => r.Min(w => w.Rect.Y)))
        {
            row.Sort((a, b) => a.Rect.X.CompareTo(b.Rect.X));
            var height = row.Max(r => r.Rect.Height);
            // Word boxes run from ascenders to descenders, about 0.85 of the font size.
            var size = Math.Max(4, Math.Round(height / 0.85 * 2) / 2);
            var part = new List<OcrWord>();
            void Flush()
            {
                if (part.Count == 0) return;
                var spans = new List<ExportSpan>();
                for (var i = 0; i < part.Count; i++)
                    spans.Add(new ExportSpan(i == part.Count - 1 ? part[i].Text : part[i].Text + " ", "", size, false, false, 0, part[i].Rect));
                lines.Add(ExportLine.Of(spans));
                part.Clear();
            }
            foreach (var w in row)
            {
                if (part.Count > 0 && w.Rect.X - part[^1].Rect.Right > 1.5 * height) Flush();
                part.Add(w);
            }
            Flush();
        }
        return lines;
    }
}
