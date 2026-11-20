namespace InkvoltPdf.Core;

/// <summary>
/// Pixel redaction's answer to glyph-spacing inference (arXiv 2206.02285): a redacted line keeps its words, not their
/// positions. Left where they were, the text after a black box starts where the removed words ended, a justified line's
/// spaces are as wide as the removed width makes them, and the box is as wide as the area drawn over the words: from
/// the page image and the font, the removed width can be measured and often the words guessed. So each line an area
/// cuts is laid out again in the page image (<see cref="Redaction.Redact"/>): its words in order from where the line
/// started, one space of a fixed width (<see cref="SpaceOfHeight"/> of the line's height) between them, and each box its
/// width rounded to steps of <see cref="StepOfHeight"/> line heights; a line redacted whole is just its rounded box. Nothing
/// on the line then depends on the removed width but that step. A word's own letters move together, unchanged (so their
/// shading still has the fraction of a pixel where they were: 0.24 pt at 300 dpi).
/// </summary>
internal static class RedactionLines
{
    /// <summary>The space put between the words of a line laid out again, in line heights (a space is about a quarter of an em).</summary>
    public const double SpaceOfHeight = 0.25;

    /// <summary>The steps a box's width is rounded to, in line heights (at least one step).</summary>
    public const double StepOfHeight = 2;

    /// <summary>Lines longer than this (characters) are left as they are.</summary>
    private const int MaxChars = 5000;

    /// <summary>A piece of a line, left to right (page space): a word kept (its pixels move) or a box (drawn black).
    /// <paramref name="Spaced"/>: a space came before it (else it touched the piece before, as a comma after a name).</summary>
    internal readonly record struct Piece(double X, double Right, bool Box, bool Spaced);

    /// <param name="Band">The line's characters, all of them.</param>
    /// <param name="Rows">The rows laid out again: the band, and the areas on it up to half a line above and below.</param>
    /// <param name="Areas">The areas on the line (page space).</param>
    internal sealed record CutLine(RectD Band, RectD Rows, IReadOnlyList<Piece> Pieces, IReadOnlyList<RectD> Areas)
    {
        public double Height => Band.Height;

        /// <summary>How far right the line may reach when laid out again (the next column's text on its rows), page space.</summary>
        public double Limit { get; init; } = double.MaxValue;
    }

    /// <summary>A box's width once rounded: whole steps of <see cref="StepOfHeight"/> line heights, at least one.</summary>
    public static double BoxWidth(double width, double height)
    {
        var step = StepOfHeight * height;
        return Math.Max(1, Math.Round(width / step)) * step;
    }

    /// <summary>
    /// The lines of a page that areas cut: across the page, an area over at least half the line's height and over its
    /// text or within a line's height beside it, and some of its text left outside every area. A character whose middle
    /// an area covers goes into the box (as <see cref="RedactionCheck.ValuesUnder"/> reads it); one it only touches stays
    /// whole, its box ending where it starts.
    /// </summary>
    public static List<CutLine> Find(PageText text, IReadOnlyList<RectD> areas)
    {
        var found = new List<CutLine>();
        var cuts = areas.Where(a => !a.IsEmpty && double.IsFinite(a.X + a.Y + a.Width + a.Height)).ToList();
        if (cuts.Count == 0 || text.IsEmpty) return found;
        var lines = new List<(int Start, int End, RectD Band)>();
        foreach (var (start, end, across) in text.Lines)
        {
            if (!across || end - start > MaxChars) continue;
            var band = default(RectD);
            for (var i = start; i < end; i++)
                if (!char.IsWhiteSpace(text.Text[i]) && text.BoxAt(i) is { Width: > 0, Height: > 0 } b && double.IsFinite(b.X + b.Y + b.Width + b.Height))
                    band = band.IsEmpty ? b : band.Union(b);
            if (band.Height is >= 1 and <= 300) lines.Add((start, end, band));
        }
        foreach (var (start, end, band) in lines)
        {
            var h = band.Height;
            var hits = cuts.Where(a => Math.Min(a.Bottom, band.Bottom) - Math.Max(a.Y, band.Y) >= 0.5 * h && a.Right >= band.X - h && a.X <= band.Right + h).ToList();
            if (hits.Count == 0) continue;
            static bool Takes(RectD a, RectD b) => a.X <= b.CenterX && b.CenterX <= a.Right && Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y) >= 0.3 * b.Height;
            var visible = Enumerable.Range(start, end - start).Where(i => !char.IsWhiteSpace(text.Text[i]) && text.BoxAt(i).Width > 0).ToList();
            // An area taller than the line (a block) is one of its boxes only where it takes some of its letters: a picture
            // redacted beside a paragraph leaves the paragraph's lines alone.
            hits = [.. hits.Where(a => a.Height <= 1.6 * h || visible.Any(i => Takes(a, text.BoxAt(i))))];
            if (hits.Count == 0) continue;
            bool Covered(RectD b) => hits.Any(a => Takes(a, b));
            var kept = visible.Where(i => !Covered(text.BoxAt(i))).OrderBy(i => text.BoxAt(i).X).ToList();
            // A line redacted whole: its box, drawn round its words, would give their width away too, so it is laid out the
            // same (only its box, from where the line starts). Not when an area takes more than this line (a block: its
            // width is the area's, not the words').
            if (kept.Count == 0 && hits.Any(a => a.Height > 1.6 * h)) continue;

            // Boxes: each area's stretch of the line with the characters it takes, overlapping ones joined.
            var boxes = hits.Select(a =>
            {
                var (x, right) = (Math.Max(a.X, band.X - h), Math.Min(a.Right, band.Right + h));
                foreach (var i in visible)
                    if (text.BoxAt(i) is var b && Covered(b) && Math.Min(a.Right, b.Right) - Math.Max(a.X, b.X) > 0)
                        (x, right) = (Math.Min(x, b.X), Math.Max(right, b.Right));
                return (X: x, Right: right);
            }).Where(b => b.Right > b.X).OrderBy(b => b.X).ToList();
            var joined = new List<(double X, double Right)>();
            foreach (var b in boxes)
                if (joined.Count > 0 && b.X <= joined[^1].Right) joined[^1] = (joined[^1].X, Math.Max(joined[^1].Right, b.Right));
                else joined.Add(b);

            // Words: kept characters left to right, split at a space, a wide gap or a box.
            var words = new List<(double X, double Right)>();
            var last = -1;
            foreach (var i in kept)
            {
                var b = text.BoxAt(i);
                var split = last < 0
                    || b.X - text.BoxAt(last).Right > 0.3 * h
                    || Math.Abs(i - last) > 64
                    || Enumerable.Range(Math.Min(i, last) + 1, Math.Max(0, Math.Abs(i - last) - 1)).Any(k => char.IsWhiteSpace(text.Text[k]))
                    || joined.Any(x => x.X >= text.BoxAt(last).CenterX && x.Right <= b.CenterX);
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

            var all = words.Select(w => (w.X, w.Right, Box: false)).Concat(joined.Select(b => (b.X, b.Right, Box: true))).OrderBy(p => p.X).ToList();
            var pieces = new List<Piece>();
            foreach (var (x0, right, box) in all)
            {
                // A piece still overlapping the one before starts where that one ends.
                var x = pieces.Count > 0 ? Math.Max(x0, pieces[^1].Right) : x0;
                if (right <= x) continue;
                pieces.Add(new Piece(x, right, box, pieces.Count > 0 && x0 - pieces[^1].Right > 0.1 * h));
            }
            if (!pieces.Any(p => p.Box)) continue;
            // How far right the line may now reach: up to the next text beside it on its rows (another column), else anywhere.
            var limit = lines.Where(o => o.Band != band && o.Band.X >= band.Right - 0.5 * h
                                         && Math.Min(o.Band.Bottom, band.Bottom) - Math.Max(o.Band.Y, band.Y) > 0.3 * h)
                .Select(o => o.Band.X - 0.5 * h).DefaultIfEmpty(double.MaxValue).Min();

            // Rows: the band, and the areas on it up to half a line beyond, but not into another line beside it.
            var top = Math.Max(Math.Min(band.Y, hits.Min(a => a.Y)), band.Y - 0.5 * h);
            var bottom = Math.Min(Math.Max(band.Bottom, hits.Max(a => a.Bottom)), band.Bottom + 0.5 * h);
            foreach (var (_, _, other) in lines)
            {
                if (other == band || other.Right < pieces[0].X || other.X > pieces[^1].Right) continue;
                if (other.Bottom <= band.Y) top = Math.Max(top, other.Bottom);
                else if (other.Y >= band.Bottom) bottom = Math.Min(bottom, other.Y);
            }
            found.Add(new CutLine(band, RectD.FromEdges(band.X, top, band.Right, bottom), pieces, hits) { Limit = Math.Max(limit, pieces[^1].Right) });
        }
        return found;
    }

    /// <summary>
    /// Where each piece goes (its new left edge, page space): from where the line started, each word as wide as it was,
    /// each box <see cref="BoxWidth"/>, a space of <see cref="SpaceOfHeight"/> line heights where there was one. A line
    /// that would run off the page (past <paramref name="pageWidth"/>) or into the next column has its spaces narrowed to
    /// fit (only then does anything depend on the removed width).
    /// </summary>
    public static (double X, double Width)[] Layout(CutLine line, double pageWidth)
    {
        var h = line.Height;
        var pieces = line.Pieces;
        var widths = pieces.Select(p => p.Box ? BoxWidth(p.Right - p.X, h) : p.Right - p.X).ToArray();
        var spaces = pieces.Skip(1).Count(p => p.Spaced);
        var space = SpaceOfHeight * h;
        var over = pieces[0].X + widths.Sum() + spaces * space - Math.Min(pageWidth, line.Limit);
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
        var placed = new (double, double)[pieces.Count];
        var x = pieces[0].X;
        for (var k = 0; k < pieces.Count; k++)
        {
            if (k > 0 && pieces[k].Spaced) x += space;
            placed[k] = (x, widths[k]);
            x += widths[k];
        }
        return placed;
    }

    /// <summary>
    /// Lays the line out again in <paramref name="rgb"/> (3 bytes a pixel, <paramref name="scale"/> pixels a point): the
    /// rows of <see cref="CutLine.Rows"/> from the line's start to the further of its old and new ends are drawn anew, each
    /// word's pixels where <see cref="Layout"/> puts it, each box black, the space between from the space that was there
    /// (stretched or squeezed, never from inside an area), and what is left after a line that got shorter from the
    /// background beside its start. Returns the boxes as drawn and the rows (page space).
    /// </summary>
    public static (List<RectD> Boxes, RectD Rows) Relay(byte[] rgb, int width, int height, double scale, CutLine line, (double X, double Width)[] placed)
    {
        int Px(double v) => (int)Math.Clamp(Math.Round(v * scale), 0, width);
        var y0 = (int)Math.Clamp(Math.Floor(line.Rows.Y * scale), 0, height);
        var y1 = (int)Math.Clamp(Math.Ceiling(line.Rows.Bottom * scale), 0, height);
        var pieces = line.Pieces;
        var oldStart = pieces.Select(p => Px(p.X)).ToArray();
        var oldEnd = pieces.Select(p => Px(p.Right)).ToArray();
        var newStart = placed.Select(p => Px(p.X)).ToArray();
        var newEnd = placed.Select(p => Px(p.X + p.Width)).ToArray();
        // Out to whole pixels: the areas were blacked out to them.
        var left = Math.Min((int)Math.Clamp(Math.Floor(pieces[0].X * scale), 0, width), newStart[0]);
        var right = Math.Max((int)Math.Clamp(Math.Ceiling(pieces[^1].Right * scale), 0, width), newEnd[^1]);
        var boxes = new List<RectD>();
        if (y1 <= y0 || right <= left) return (boxes, default);

        // Columns that areas blacked out: never the source of a space.
        var blacked = new bool[width];
        foreach (var a in line.Areas)
            for (var c = (int)Math.Clamp(Math.Floor(a.X * scale), 0, width); c < (int)Math.Clamp(Math.Ceiling(a.Right * scale), 0, width); c++) blacked[c] = true;
        const int Black = -1, Background = -2;
        var source = new int[right - left];
        Array.Fill(source, Background);
        for (var k = 0; k < pieces.Count; k++)
        {
            for (var c = newStart[k]; c < newEnd[k]; c++)
                source[c - left] = pieces[k].Box ? Black : Math.Clamp(oldStart[k] + (c - newStart[k]), 0, width - 1);
            if (k + 1 == pieces.Count) break;
            // The space after it: from the old space's columns outside every area, stretched or squeezed to fit.
            var clean = Enumerable.Range(oldEnd[k], Math.Max(0, oldStart[k + 1] - oldEnd[k])).Where(c => c < width && !blacked[c]).ToList();
            var gap = newStart[k + 1] - newEnd[k];
            for (var j = 0; j < gap && clean.Count > 0; j++) source[newEnd[k] + j - left] = clean[j * clean.Count / gap];
        }
        var background = Math.Clamp(oldStart[0] - 2, 0, width - 1);

        var stride = width * 3;
        var rows = new byte[(y1 - y0) * stride];
        Array.Copy(rgb, y0 * stride, rows, 0, rows.Length);
        for (var y = y0; y < y1; y++)
        {
            var from = (y - y0) * stride;
            for (var c = left; c < right; c++)
            {
                var at = y * stride + c * 3;
                switch (source[c - left])
                {
                    case Black:
                        rgb[at] = rgb[at + 1] = rgb[at + 2] = 0;
                        break;
                    case var s:
                        var src = from + (s == Background ? background : s) * 3;
                        rgb[at] = rows[src];
                        rgb[at + 1] = rows[src + 1];
                        rgb[at + 2] = rows[src + 2];
                        break;
                }
            }
        }
        for (var k = 0; k < pieces.Count; k++)
            if (pieces[k].Box && newEnd[k] > newStart[k])
                boxes.Add(new RectD(newStart[k] / scale, y0 / scale, (newEnd[k] - newStart[k]) / scale, (y1 - y0) / scale));
        return (boxes, new RectD(left / scale, y0 / scale, (right - left) / scale, (y1 - y0) / scale));
    }
}
