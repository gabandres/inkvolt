namespace InkvoltPdf.Core;

/// <summary>
/// Pixel redaction's answer to glyph-spacing inference (arXiv 2206.02285): a redacted line keeps its words, not their
/// positions. Left where they were, the text after a black box starts where the removed words ended, a justified line's
/// spaces are as wide as the removed width makes them, and the box is as wide as the area drawn over the words: from
/// the page image and the font, the removed width can be measured and often the words guessed. So each line an area
/// cuts is laid out again in the page image (<see cref="Redaction.Redact"/>): its words in order from the line's own
/// alignment edge (its start, its end, or its middle for a centred line), one space of a fixed width
/// (<see cref="SpaceOfHeight"/> of the line's height) between them, and each box its width rounded to steps of
/// <see cref="StepOfHeight"/> line heights; a line redacted whole is just its rounded box; boxes already there (an
/// earlier redaction's) keep their width and move with the line. A line turned sideways is laid out along its own axis.
/// Nothing on the line then depends on the removed width but that step. A word's own letters move together, unchanged:
/// whole pixels, so their shading keeps the fraction of a pixel where they were (0.24 pt at 300 dpi), a limit of
/// drawing the page once (MuPDF's renders sit on the pixel grid: a moved word can't be drawn again at a fraction of a
/// pixel). A line whose space holds something else (a table's rule, a picture) isn't laid out again: its boxes are
/// rounded where they are, as far as the words beside them allow, and it is said (<see cref="Relaid.LaidOut"/>).
/// </summary>
/// <remarks>
/// Everything about a line is in its own space: along its baseline as X, across it as Y (a sideways line's rectangles
/// transposed, <see cref="CutLine.Vertical"/>).
/// </remarks>
internal static class RedactionLines
{
    /// <summary>The space put between the words of a line laid out again, in line heights (a space is about a quarter of an em).</summary>
    public const double SpaceOfHeight = 0.25;

    /// <summary>The steps a box's width is rounded to, in line heights (at least one step).</summary>
    public const double StepOfHeight = 2;

    /// <summary>Lines longer than this (characters) are left as they are.</summary>
    private const int MaxChars = 5000;

    /// <summary>An area this many line heights tall or more takes more than one line.</summary>
    private const double TallerThanALine = 1.6;

    internal enum PieceKind
    {
        /// <summary>A word kept: its pixels move.</summary>
        Word,
        /// <summary>A box drawn now: black, its width rounded.</summary>
        Box,
        /// <summary>A box that was there (an earlier redaction's): its pixels move, its width stays.</summary>
        Fixed,
    }

    internal enum Alignment { Start, Middle, End }

    /// <summary>A piece of a line, in order along it. <paramref name="Spaced"/>: a space came before it (else it touched the
    /// piece before, as a comma after a name).</summary>
    internal readonly record struct Piece(double X, double Right, PieceKind Kind, bool Spaced)
    {
        public bool Box => Kind == PieceKind.Box;
    }

    /// <param name="Band">The line's characters, all of them.</param>
    /// <param name="Rows">The rows laid out again: the band, and the areas on it up to half a line beyond it.</param>
    /// <param name="Areas">The areas on the line.</param>
    internal sealed record CutLine(RectD Band, RectD Rows, IReadOnlyList<Piece> Pieces, IReadOnlyList<RectD> Areas)
    {
        public double Height => Band.Height;

        /// <summary>The line's baseline runs down the page: its rectangles are transposed (X along it, Y across it).</summary>
        public bool Vertical { get; init; }

        public Alignment Align { get; init; }

        /// <summary>How far along the line may reach when laid out again (another column's text on its rows), both ways.</summary>
        public double Limit { get; init; } = double.MaxValue;

        public double LimitStart { get; init; }

        /// <summary>The rectangle in page space.</summary>
        public RectD ToPage(RectD r) => Vertical ? Transpose(r) : r;
    }

    /// <summary>A line laid out again: its boxes drawn now, its fixed boxes where they went, its rows, and the words and fixed boxes moved
    /// (page space). <see cref="LaidOut"/> false: it was left in place (its space holds a rule or a picture), its boxes only rounded.</summary>
    internal sealed record Relaid(List<RectD> Boxes, List<(RectD Was, RectD Now)> Fixed, RectD Rows, List<(RectD Was, double Dx, double Dy)> Moved, bool LaidOut);

    internal static RectD Transpose(RectD r) => new(r.Y, r.X, r.Height, r.Width);

    /// <summary>A box's width once rounded: whole steps of <see cref="StepOfHeight"/> line heights, at least one.</summary>
    public static double BoxWidth(double width, double height)
    {
        var step = StepOfHeight * height;
        return Math.Max(1, Math.Round(width / step)) * step;
    }

    private static bool Finite(RectD r) => double.IsFinite(r.X + r.Y + r.Width + r.Height);

    /// <summary>
    /// The lines of a page that areas cut, across the page or turned sideways: an area over at least half the line's
    /// height and over its text or within a line's height beside it. A character whose middle an area covers goes into
    /// the box (as <see cref="RedactionCheck.ValuesUnder"/> reads it); one it only touches stays whole, its box ending
    /// where it starts. An area taller than a line counts on the lines whose letters it takes, as rows of lines: one that
    /// takes some of a line and leaves the rest, and the lines it takes whole in between; one that leaves no letter of any
    /// line beside it is a block, as drawn.
    /// </summary>
    /// <param name="darkRuns">Boxes already on a line (its band, line space; whether sideways): stretches dark across its middle, line space.</param>
    public static List<CutLine> Find(PageText text, IReadOnlyList<RectD> areas, double pageWidth, double pageHeight,
        Func<RectD, bool, IReadOnlyList<(double X, double Right)>>? darkRuns = null)
    {
        var found = new List<CutLine>();
        var cuts = areas.Where(a => !a.IsEmpty && Finite(a)).ToList();
        if (cuts.Count == 0 || text.IsEmpty) return found;
        foreach (var vertical in new[] { false, true })
            found.AddRange(Find(text, cuts, vertical, vertical ? pageHeight : pageWidth, darkRuns));
        return found;
    }

    private static List<CutLine> Find(PageText text, List<RectD> pageCuts, bool vertical, double extent,
        Func<RectD, bool, IReadOnlyList<(double X, double Right)>>? darkRuns)
    {
        RectD Box(int i) => vertical ? Transpose(text.BoxAt(i)) : text.BoxAt(i);
        var cuts = pageCuts.Select(a => vertical ? Transpose(a) : a).ToList();
        var lines = new List<(int Start, int End, RectD Band, List<int> Visible)>();
        var reversed = new Dictionary<(int, int), bool>(); // a line read against its axis (up the page): its start is its far edge
        foreach (var (start, end, dx, dy) in text.Lines)
        {
            if (Math.Abs(vertical ? dy : dx) < 0.99 || end - start > MaxChars) continue;
            reversed[(start, end)] = (vertical ? dy : dx) < 0;
            var band = default(RectD);
            var visible = new List<int>();
            for (var i = start; i < end; i++)
                if (!char.IsWhiteSpace(text.Text[i]) && Box(i) is { Width: > 0, Height: > 0 } b && Finite(b))
                {
                    band = band.IsEmpty ? b : band.Union(b);
                    visible.Add(i);
                }
            if (band.Height is >= 1 and <= 300) lines.Add((start, end, band, visible));
        }
        static bool Takes(RectD a, RectD b) => a.X <= b.CenterX && b.CenterX <= a.Right && Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y) >= 0.3 * b.Height;
        List<RectD> Hits(RectD band, List<int> visible)
        {
            var h = band.Height;
            return [.. cuts.Where(a => Math.Min(a.Bottom, band.Bottom) - Math.Max(a.Y, band.Y) >= 0.5 * h && a.Right >= band.X - h && a.X <= band.Right + h)
                .Where(a => a.Height <= TallerThanALine * h || visible.Any(i => Takes(a, Box(i))))];
        }
        // Tall areas that leave letters of some line beside them: rows of lines (the lines they take whole are laid out too).
        var rowAreas = new HashSet<RectD>();
        foreach (var (_, _, band, visible) in lines)
        {
            var hits = Hits(band, visible);
            if (visible.Any(i => !hits.Any(a => Takes(a, Box(i)))))
                foreach (var a in hits.Where(a => a.Height > TallerThanALine * band.Height)) rowAreas.Add(a);
        }

        var found = new List<CutLine>();
        foreach (var (start, end, band, visible) in lines)
        {
            var h = band.Height;
            var hits = Hits(band, visible);
            if (hits.Count == 0) continue;
            bool Covered(RectD b) => hits.Any(a => Takes(a, b));
            var kept = visible.Where(i => !Covered(Box(i))).OrderBy(i => Box(i).X).ToList();
            // A line redacted whole: its box, drawn round its words, would give their width away too, so it is laid out the
            // same (only its box). Not when a block takes it (an area taller than a line that leaves no line beside it).
            if (kept.Count == 0 && hits.Any(a => a.Height > TallerThanALine * h && !rowAreas.Contains(a))) continue;

            // Boxes: each area's stretch of the line with the characters it takes, overlapping ones joined.
            var spans = hits.Select(a =>
            {
                var (x, right) = (Math.Max(a.X, band.X - h), Math.Min(a.Right, band.Right + h));
                if (a.Height > TallerThanALine * h) (x, right) = (double.MaxValue, double.MinValue); // a row area: only what it takes
                foreach (var i in visible)
                    if (Box(i) is var b && Takes(a, b))
                        (x, right) = (Math.Min(x, b.X), Math.Max(right, b.Right));
                return (X: x, Right: right);
            }).Where(b => b.Right > b.X).ToList();
            // Boxes already on the line (an earlier redaction's): the areas just painted are dark too, so only what lies
            // outside them counts; a piece of one touching a new box joins it, the others stay as they are.
            var fixedBoxes = new List<(double X, double Right)>();
            foreach (var run in darkRuns?.Invoke(band, vertical) ?? [])
            {
                var rest = new List<(double X, double Right)> { run };
                foreach (var a in hits)
                    rest = [.. rest.SelectMany(r => r.Right <= a.X || r.X >= a.Right ? [r]
                        : new[] { (r.X, Math.Min(r.Right, a.X)), (Math.Max(r.X, a.Right), r.Right) }.Where(p => p.Item2 > p.Item1))];
                foreach (var piece in rest)
                {
                    if (piece.Right - piece.X < 0.6 * h || kept.Any(i => Box(i).Right > piece.X && Box(i).X < piece.Right)) continue;
                    if (spans.Any(s => s.Right >= piece.X - 0.5 && s.X <= piece.Right + 0.5)) spans.Add(piece);
                    else fixedBoxes.Add(piece);
                }
            }
            var joined = new List<(double X, double Right)>();
            foreach (var b in spans.OrderBy(b => b.X))
                if (joined.Count > 0 && b.X <= joined[^1].Right) joined[^1] = (joined[^1].X, Math.Max(joined[^1].Right, b.Right));
                else joined.Add(b);
            if (joined.Count == 0) continue;

            // Words: kept characters in order along the line, split at a space, a wide gap or a box.
            var words = new List<(double X, double Right)>();
            var last = -1;
            foreach (var i in kept)
            {
                var b = Box(i);
                var lb = last < 0 ? default : Box(last);
                var split = last < 0
                    || b.X - lb.Right > 0.3 * h
                    || Math.Abs(i - last) > 64
                    || Enumerable.Range(Math.Min(i, last) + 1, Math.Max(0, Math.Abs(i - last) - 1)).Any(k => char.IsWhiteSpace(text.Text[k]))
                    || joined.Concat(fixedBoxes).Any(x => x.X >= lb.CenterX && x.Right <= b.CenterX);
                if (split) words.Add((b.X, b.Right));
                else words[^1] = (words[^1].X, Math.Max(words[^1].Right, b.Right));
                last = i;
            }

            // A box gives way to a word it only touches (an area over the edge of a letter it doesn't take): the letter stays whole.
            for (var k = 0; k < joined.Count; k++)
            {
                var (x, right) = joined[k];
                foreach (var w in words)
                {
                    if (w.X <= x && w.Right > x) x = w.Right;
                    else if (w.X > x && w.X < right && w.Right > right) right = w.X;
                }
                joined[k] = (x, Math.Max(x, right));
            }

            var all = words.Select(w => (w.X, w.Right, Kind: PieceKind.Word))
                .Concat(joined.Select(b => (b.X, b.Right, Kind: PieceKind.Box)))
                .Concat(fixedBoxes.Select(b => (b.X, b.Right, Kind: PieceKind.Fixed)))
                .OrderBy(p => p.X).ToList();
            var pieces = new List<Piece>();
            foreach (var (x0, right, kind) in all)
            {
                // A piece still overlapping the one before starts where that one ends.
                var x = pieces.Count > 0 ? Math.Max(x0, pieces[^1].Right) : x0;
                if (right <= x) continue;
                pieces.Add(new Piece(x, right, kind, pieces.Count > 0 && x0 - pieces[^1].Right > 0.1 * h));
            }
            if (!pieces.Any(p => p.Box)) continue;

            // Other text on the same rows (another column): the line stays between it.
            bool SameRows(RectD o) => o != band && Math.Min(o.Bottom, band.Bottom) - Math.Max(o.Y, band.Y) > 0.3 * h;
            var limit = lines.Where(o => SameRows(o.Band) && o.Band.X >= band.Right - 0.5 * h).Select(o => o.Band.X - 0.5 * h).DefaultIfEmpty(extent).Min();
            var limitStart = lines.Where(o => SameRows(o.Band) && o.Band.Right <= band.X + 0.5 * h).Select(o => o.Band.Right + 0.5 * h).DefaultIfEmpty(0).Max();

            // Rows: the band, and the areas of this line on it up to half a line beyond (a tall area's rows between lines
            // become paper), but not into another line above or below.
            var own = hits.Where(a => a.Height <= TallerThanALine * h).ToList();
            var top = Math.Max(Math.Min(band.Y, own.Count > 0 ? own.Min(a => a.Y) : band.Y), band.Y - 0.5 * h);
            var bottom = Math.Min(Math.Max(band.Bottom, own.Count > 0 ? own.Max(a => a.Bottom) : band.Bottom), band.Bottom + 0.5 * h);
            foreach (var (_, _, other, _) in lines)
            {
                if (other == band || other.Right < pieces[0].X || other.X > pieces[^1].Right) continue;
                if (other.Bottom <= band.Y) top = Math.Max(top, other.Bottom);
                else if (other.Y >= band.Bottom) bottom = Math.Min(bottom, other.Y);
            }
            found.Add(new CutLine(band, RectD.FromEdges(band.X, top, band.Right, bottom), pieces, hits)
            {
                Vertical = vertical,
                Align = AlignmentOf(band, lines.Select(l => l.Band).Where(o => o != band), extent) is var align && reversed[(start, end)]
                    ? align switch { Alignment.Start => Alignment.End, Alignment.End => Alignment.Start, _ => align } // it reads the other way
                    : align,
                Limit = Math.Max(Math.Min(limit, extent), pieces[^1].Right),
                LimitStart = Math.Min(Math.Max(limitStart, 0), pieces[0].X),
            });
        }
        return found;
    }

    /// <summary>
    /// Which edge a line keeps: its start when it starts where a line near it does (left-aligned or justified text), its
    /// end when it ends where one near it ends (right-aligned), its middle when its middle is another's or, alone, the
    /// page's (centred); else its start.
    /// </summary>
    internal static Alignment AlignmentOf(RectD band, IEnumerable<RectD> others, double extent)
    {
        var h = band.Height;
        var near = others.Where(o => o.Right > band.X && o.X < band.Right && Math.Abs(o.CenterY - band.CenterY) <= 4 * h && Math.Abs(o.Height - h) <= 0.5 * h).ToList();
        var tol = 0.5 * h;
        if (near.Any(o => Math.Abs(o.X - band.X) <= tol)) return Alignment.Start;
        if (near.Any(o => Math.Abs(o.Right - band.Right) <= tol)) return Alignment.End;
        if (near.Any(o => Math.Abs(o.CenterX - band.CenterX) <= tol)) return Alignment.Middle;
        if (near.Count == 0 && Math.Abs(band.CenterX - extent / 2) <= h) return Alignment.Middle;
        return Alignment.Start;
    }

    /// <summary>
    /// Where each piece goes (its new start and width, line space): kept to the line's alignment edge, each word and earlier
    /// box as wide as it was, each new box <see cref="BoxWidth"/>, a space of <see cref="SpaceOfHeight"/> line heights where
    /// there was one. A line that would run into the next column or off the page has its spaces narrowed to fit, then its
    /// boxes (only then does anything depend on the removed width).
    /// </summary>
    public static (double X, double Width)[] Layout(CutLine line)
    {
        var h = line.Height;
        var pieces = line.Pieces;
        var widths = pieces.Select(p => p.Box ? BoxWidth(p.Right - p.X, h) : p.Right - p.X).ToArray();
        var spaces = pieces.Skip(1).Count(p => p.Spaced);
        var space = SpaceOfHeight * h;
        // The edge kept, and the room the line has from it.
        var (edge, room) = line.Align switch
        {
            Alignment.End => (line.Band.Right, line.Band.Right - line.LimitStart),
            Alignment.Middle => (line.Band.CenterX, 2 * Math.Min(line.Band.CenterX - line.LimitStart, line.Limit - line.Band.CenterX)),
            // Its start: where its text started (a new box first starts there too), or an earlier box that was first.
            _ => (pieces[0].Box ? Math.Max(pieces[0].X, line.Band.X) : pieces[0].X, line.Limit - (pieces[0].Box ? Math.Max(pieces[0].X, line.Band.X) : pieces[0].X)),
        };
        var over = widths.Sum() + spaces * space - room;
        if (over > 0 && spaces > 0)
        {
            var narrowed = Math.Max(0, space - over / spaces);
            over -= (space - narrowed) * spaces;
            space = narrowed;
        }
        // Still too wide (a box rounded up with no space to take it from): the boxes give back what rounding added.
        for (var k = 0; k < pieces.Count && over > 1e-9; k++)
            if (pieces[k].Box && widths[k] > pieces[k].Right - pieces[k].X)
            {
                var back = Math.Min(over, widths[k] - (pieces[k].Right - pieces[k].X));
                widths[k] -= back;
                over -= back;
            }
        var total = widths.Sum() + spaces * space;
        var x = line.Align switch
        {
            Alignment.End => edge - total,
            Alignment.Middle => edge - total / 2,
            _ => edge,
        };
        var placed = new (double, double)[pieces.Count];
        for (var k = 0; k < pieces.Count; k++)
        {
            if (k > 0 && pieces[k].Spaced) x += space;
            placed[k] = (x, widths[k]);
            x += widths[k];
        }
        return placed;
    }

    /// <summary>A page image being redacted: what was there (<see cref="Before"/>, every area already black) is read, the image written.</summary>
    internal sealed class Canvas(byte[] rgb, int width, int height, double scale, IReadOnlyList<RectD> areas)
    {
        public byte[] Rgb => rgb;
        public byte[] Before { get; } = (byte[])rgb.Clone();
        public int Width => width;
        public int Height => height;
        public double Scale => scale;

        /// <summary>The areas in pixels (x0, y0, x1, y1), as they were blacked out (out to whole pixels).</summary>
        public IReadOnlyList<(int X0, int Y0, int X1, int Y1)> Areas { get; } = [.. areas.Select(a => (
            (int)Math.Clamp(Math.Floor(a.X * scale), 0, width), (int)Math.Clamp(Math.Floor(a.Y * scale), 0, height),
            (int)Math.Clamp(Math.Ceiling(a.Right * scale), 0, width), (int)Math.Clamp(Math.Ceiling(a.Bottom * scale), 0, height)))];

        /// <summary>The page's most common color (in steps of 16, as its middle; sampled), for what has nothing better.</summary>
        public (byte R, byte G, byte B) Paper { get; } = PaperOf(rgb, width, height);

        public bool InArea(int x, int y) => Areas.Any(a => x >= a.X0 && x < a.X1 && y >= a.Y0 && y < a.Y1);

        private static (byte, byte, byte) PaperOf(byte[] rgb, int width, int height)
        {
            var counts = new Dictionary<int, int>();
            var n = width * height;
            var step = Math.Max(1, n / 200_000);
            for (var i = 0; i < n; i += step)
            {
                var key = rgb[i * 3] >> 4 << 8 | rgb[i * 3 + 1] >> 4 << 4 | rgb[i * 3 + 2] >> 4;
                counts[key] = counts.GetValueOrDefault(key) + 1;
            }
            var k = counts.Count == 0 ? 0xFFF : counts.MaxBy(kv => kv.Value).Key;
            return ((byte)((k >> 8 & 15) * 16 + 8), (byte)((k >> 4 & 15) * 16 + 8), (byte)((k & 15) * 16 + 8));
        }

        /// <summary>The paper beside (along, across) in line space: the nearest pixel on its row outside every area, before
        /// <paramref name="from"/> or after <paramref name="to"/>, else <see cref="Paper"/>.</summary>
        public (byte R, byte G, byte B) PaperBeside(bool vertical, int from, int to, int across)
        {
            var along = vertical ? height : width;
            for (var d = 2; d <= 96; d++)
                foreach (var a in new[] { from - d, to - 1 + d })
                {
                    if (a < 0 || a >= along) continue;
                    var (x, y) = vertical ? (across, a) : (a, across);
                    if (InArea(x, y)) continue;
                    var o = (y * width + x) * 3;
                    return (Before[o], Before[o + 1], Before[o + 2]);
                }
            return Paper;
        }
    }

    /// <summary>
    /// Lays the line out again in the canvas: the rows of <see cref="CutLine.Rows"/>, from the furthest of the line's old
    /// and new edges and its areas' (not past another column), are drawn anew from <see cref="Canvas.Before"/>: each word
    /// and earlier box where <see cref="Layout"/> puts it, each new box black, the space between from the space that was
    /// there (stretched or squeezed, never from inside an area), the rest paper. When the line's space holds something that
    /// isn't paper (a rule, a picture), the line stays: each box is rounded where it is as far as the words beside it
    /// allow, the rest of it paper.
    /// </summary>
    public static Relaid Relay(Canvas canvas, CutLine line, (double X, double Width)[] placed)
    {
        var scale = canvas.Scale;
        var vertical = line.Vertical;
        var along = vertical ? canvas.Height : canvas.Width;
        var acrossMax = vertical ? canvas.Width : canvas.Height;
        int Px(double v) => (int)Math.Clamp(Math.Round(v * scale), 0, along);
        int Floor(double v, int max) => (int)Math.Clamp(Math.Floor(v * scale), 0, max);
        int Ceil(double v, int max) => (int)Math.Clamp(Math.Ceiling(v * scale), 0, max);
        int At(int a, int c) => vertical ? (a * canvas.Width + c) * 3 : (c * canvas.Width + a) * 3;
        var y0 = Floor(line.Rows.Y, acrossMax);
        var y1 = Ceil(line.Rows.Bottom, acrossMax);
        var pieces = line.Pieces;
        var oldStart = pieces.Select(p => Px(p.X)).ToArray();
        var oldEnd = pieces.Select(p => Px(p.Right)).ToArray();
        var newStart = placed.Select(p => Px(p.X)).ToArray();
        var newEnd = placed.Select(p => Px(p.X + p.Width)).ToArray();
        var limitStart = Floor(line.LimitStart, along);
        var limitEnd = Ceil(line.Limit, along);
        // Out to whole pixels and over the areas' width on these rows (up to another column): nothing marks where the line ended.
        var left = Math.Min(Math.Min(Floor(pieces[0].X, along), newStart[0]), Math.Max(limitStart, Floor(line.Areas.Min(a => a.X), along)));
        var right = Math.Max(Math.Max(Ceil(pieces[^1].Right, along), newEnd[^1]), Math.Min(limitEnd, Ceil(line.Areas.Max(a => a.Right), along)));
        var result = new Relaid([], [], default, [], true);
        if (y1 <= y0 || right <= left) return result;
        RectD Rect(int a0, int a1) => line.ToPage(new RectD(a0 / scale, y0 / scale, (a1 - a0) / scale, (y1 - y0) / scale));
        // What the areas blacked out on these rows (line space, from the line's start to its end).
        var mask = new bool[(right - left) * (y1 - y0)];
        foreach (var (x0, ay0, x1, ay1) in canvas.Areas)
        {
            var (a0, a1, c0, c1) = vertical ? (ay0, ay1, x0, x1) : (x0, x1, ay0, ay1);
            for (var c = Math.Max(c0, y0); c < Math.Min(c1, y1); c++)
                for (var a = Math.Max(a0, left); a < Math.Min(a1, right); a++) mask[(c - y0) * (right - left) + a - left] = true;
        }
        bool Blacked(int a, int c) => a >= left && a < right && mask[(c - y0) * (right - left) + a - left];

        // Paper for each row, from beside the line.
        var paper = Enumerable.Range(y0, y1 - y0).Select(c => canvas.PaperBeside(vertical, left, right, c)).ToArray();
        void Paper(int a, int c)
        {
            var o = At(a, c);
            (canvas.Rgb[o], canvas.Rgb[o + 1], canvas.Rgb[o + 2]) = paper[c - y0];
        }

        // Its spaces must be paper, or the colour the line's own spaces share (a highlight, a shaded cell: the line's
        // background, which the paper beside a line highlighted from its first letter to its last isn't): a rule or a
        // picture there would be cut up and moved.
        var mid = (y0 + y1) / 2;
        var inPiece = new bool[right - left];
        for (var k = 0; k < pieces.Count; k++)
            for (var a = Math.Max(left, oldStart[k] - 1); a < Math.Min(right, oldEnd[k] + 1); a++) inPiece[a - left] = true;
        var spaceStart = Math.Min(Math.Max(left, oldStart[0]), right);
        var spaces = Enumerable.Range(spaceStart, Math.Max(spaceStart, Math.Min(right, oldEnd[^1])) - spaceStart)
            .Where(a => !inPiece[a - left] && !Blacked(a, mid)).ToArray();
        var shared = Enumerable.Range(y0, y1 - y0).Select(c => SharedColour(canvas.Before, [.. spaces.Select(a => At(a, c))])).ToArray();
        bool Near(int o, (byte R, byte G, byte B) colour) => Distance(canvas.Before, o, colour) <= 120;
        var busy = false;
        for (var a = left; a < right && !busy; a++)
        {
            if (inPiece[a - left] || Blacked(a, mid)) continue;
            var ink = 0;
            for (var c = y0; c < y1; c++)
            {
                var o = At(a, c);
                if (Near(o, paper[c - y0]) || shared[c - y0] is { } s && Near(o, s)) continue;
                ink++;
            }
            busy = ink > 0.5 * (y1 - y0);
        }
        if (busy) return InPlace(canvas, line, Rect, At, Paper, y0, y1, oldStart, oldEnd);

        const int Black = -1, Background = -2;
        var source = new int[right - left];
        Array.Fill(source, Background);
        for (var k = 0; k < pieces.Count; k++)
        {
            for (var a = Math.Max(left, newStart[k]); a < Math.Min(right, newEnd[k]); a++)
                source[a - left] = pieces[k].Box ? Black : Math.Clamp(oldStart[k] + (a - newStart[k]), 0, along - 1);
            if (k + 1 == pieces.Count) break;
            // The space after it: from the old space's columns outside every area, stretched or squeezed to fit.
            var clean = Enumerable.Range(oldEnd[k], Math.Max(0, oldStart[k + 1] - oldEnd[k])).Where(a => a < along && !Blacked(a, mid)).ToList();
            var gap = newStart[k + 1] - newEnd[k];
            for (var j = 0; j < gap && clean.Count > 0; j++)
                if (newEnd[k] + j >= left && newEnd[k] + j < right) source[newEnd[k] + j - left] = clean[j * clean.Count / gap];
        }
        for (var c = y0; c < y1; c++)
            for (var a = left; a < right; a++)
            {
                var s = source[a - left];
                var o = At(a, c);
                if (s == Black) canvas.Rgb[o] = canvas.Rgb[o + 1] = canvas.Rgb[o + 2] = 0;
                else if (s == Background || Blacked(s, c)) Paper(a, c); // nothing of an area moves with a word
                else Array.Copy(canvas.Before, At(s, c), canvas.Rgb, o, 3);
            }
        for (var k = 0; k < pieces.Count; k++)
        {
            if (newEnd[k] <= newStart[k]) continue;
            if (pieces[k].Box) result.Boxes.Add(Rect(newStart[k], newEnd[k]));
            else
            {
                var was = line.ToPage(RectD.FromEdges(pieces[k].X, y0 / scale, pieces[k].Right, y1 / scale));
                if (pieces[k].Kind == PieceKind.Fixed) result.Fixed.Add((was, Rect(newStart[k], newEnd[k])));
                if (placed[k].X != pieces[k].X)
                {
                    var d = placed[k].X - pieces[k].X;
                    result.Moved.Add((was, vertical ? 0 : d, vertical ? d : 0));
                }
            }
        }
        return result with { Rows = Rect(left, right) };
    }

    /// <summary>How far the pixel at <paramref name="o"/> is from <paramref name="colour"/>: the sum of its channels' differences.</summary>
    internal static int Distance(byte[] rgb, int o, (byte R, byte G, byte B) colour) =>
        Math.Abs(rgb[o] - colour.R) + Math.Abs(rgb[o + 1] - colour.G) + Math.Abs(rgb[o + 2] - colour.B);

    /// <summary>
    /// The colour nine in ten of the pixels at <paramref name="offsets"/> share (each within 120 of it), or null: a line's
    /// background on one row, from its spaces. A rule or a picture's edge in a space is a few of them; a picture filling
    /// them isn't one colour.
    /// </summary>
    internal static (byte R, byte G, byte B)? SharedColour(byte[] rgb, int[] offsets)
    {
        if (offsets.Length < 2) return null;
        var counts = new Dictionary<int, int>();
        var first = new Dictionary<int, int>();
        foreach (var o in offsets)
        {
            var k = rgb[o] >> 4 << 8 | rgb[o + 1] >> 4 << 4 | rgb[o + 2] >> 4;
            counts[k] = counts.GetValueOrDefault(k) + 1;
            first.TryAdd(k, o);
        }
        var top = counts.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).First().Key; // of equal counts the lowest, as the Mac
        var p = first[top];
        (byte R, byte G, byte B) colour = (rgb[p], rgb[p + 1], rgb[p + 2]);
        return offsets.Count(o => Distance(rgb, o, colour) <= 120) >= 0.9 * offsets.Length ? colour : null;
    }

    /// <summary>A line left where it is: each new box rounded from its start, no further than the next piece, its rest paper.</summary>
    private static Relaid InPlace(Canvas canvas, CutLine line, Func<int, int, RectD> rect, Func<int, int, int> at, Action<int, int> paper,
        int y0, int y1, int[] oldStart, int[] oldEnd)
    {
        var result = new Relaid([], [], default, [], false);
        var pieces = line.Pieces;
        var step = (int)Math.Round(StepOfHeight * line.Height * canvas.Scale);
        for (var k = 0; k < pieces.Count; k++)
        {
            if (!pieces[k].Box) continue;
            var room = k + 1 < pieces.Count ? oldStart[k + 1] - oldStart[k] : int.MaxValue;
            var width = Math.Min(Math.Max(1, (int)Math.Round((oldEnd[k] - oldStart[k]) / (double)Math.Max(1, step))) * step, room);
            for (var c = y0; c < y1; c++)
            {
                for (var a = oldStart[k]; a < oldStart[k] + width && a < (line.Vertical ? canvas.Height : canvas.Width); a++)
                {
                    var o = at(a, c);
                    canvas.Rgb[o] = canvas.Rgb[o + 1] = canvas.Rgb[o + 2] = 0;
                }
                for (var a = oldStart[k] + width; a < oldEnd[k]; a++) paper(a, c);
            }
            result.Boxes.Add(rect(oldStart[k], oldStart[k] + width));
        }
        return result with { Rows = rect(oldStart[0], oldEnd[^1]) };
    }
}
