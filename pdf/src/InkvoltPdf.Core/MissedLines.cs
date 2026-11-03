using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// Windows' recognizer now and then skips a whole line that is plainly on the page (or a stretch of one). On the cleaned
/// page (straight, upright, white paper), this finds the ink no recognized word covers, in bands the size of a line of
/// type, and reads each band again on its own: cut out, the words already read painted out, on a margin of white; then
/// what that left unread, word by word. The words it gives are put back in reading order among the others. Only ink that
/// looks like type and stands apart from the words read on its row is read again (not specks, rules, filled blocks or
/// pictures, nor the rest of a word read short), at most <see cref="MaxRereads"/> places and <see cref="MaxReads"/>
/// readings a page. pdf/tools/ocr-corpus measures it with Windows' recognizer (its `skipped-lines` page).
/// </summary>
internal static class MissedLines
{
    /// <summary>Places read again on a page at most: those with the most ink.</summary>
    public const int MaxRereads = 12;

    /// <summary>Readings a page at most: each place whole, then the words it left unread one by one.</summary>
    public const int MaxReads = 40;

    private const int Dark = 128;
    private const int Margin = 24; // px of white around a place read alone: with 48 Windows lost "4111", with 12 it read "1111" as "11 11"

    /// <summary>A place to read again, in the image's pixels.</summary>
    public readonly record struct Place(int X, int Y, int Width, int Height, int Ink)
    {
        public int Right => X + Width;
        public int Bottom => Y + Height;
    }

    /// <summary>
    /// The places on <paramref name="gray"/> with ink no word covers, line-sized and type-like, most ink first, at most
    /// <see cref="MaxRereads"/>, in reading order (top to bottom, left to right).
    /// </summary>
    public static List<Place> Find(GrayImage gray, IReadOnlyList<RecognizedWord> words, int dpi, CancellationToken cancel = default)
    {
        var (w, h, px) = (gray.Width, gray.Height, gray.Pixels);
        var covered = Covered(words, w, h, dpi);

        // Ink nobody read, row by row.
        var rowInk = new int[h];
        for (var y = 0; y < h; y++)
        {
            if ((y & 255) == 0) cancel.ThrowIfCancellationRequested();
            var row = y * w;
            var spans = covered[y];
            var n = 0;
            var s = 0;
            for (var x = 0; x < w; x++)
            {
                while (spans is not null && s < spans.Count && spans[s].End <= x) s++;
                if (spans is not null && s < spans.Count && spans[s].Start <= x) { x = spans[s].End - 1; continue; }
                if (px[row + x] < Dark) n++;
            }
            rowInk[y] = n;
        }

        var minHeight = Math.Max(8, dpi * 0.04);   // a line of 6 pt type is ~0.06 in from cap to descender
        var maxHeight = dpi * 0.5;                 // taller is a picture, or lines too close to tell apart
        var minWidth = dpi * 0.3;                  // a word or two
        var wordGap = (int)Math.Round(dpi * 0.25); // ink closer than this along a band is one place
        var apart = dpi * 0.15;                    // a place this close to a word read on its row isn't a line skipped
        var places = new List<Place>();
        foreach (var (y0, y1) in Runs(rowInk, h, minInk: 2, gap: Math.Max(1, dpi / 100)))
        {
            if (y1 - y0 < minHeight || y1 - y0 > maxHeight) continue;
            // Along the band: which columns have unread ink.
            var colInk = new int[w];
            for (var y = y0; y < y1; y++)
            {
                var row = y * w;
                var spans = covered[y];
                for (var x = 0; x < w; x++)
                    if (px[row + x] < Dark && !Inside(spans, x)) colInk[x]++;
            }
            foreach (var (x0, x1) in Runs(colInk, w, minInk: 1, gap: wordGap))
            {
                if (x1 - x0 < minWidth) continue;
                var (top, bottom) = Rows(px, w, covered, x0, x1, y0, y1);
                if (bottom - top < minHeight) continue;
                var ink = 0;
                var strokes = 0; // separate pieces along the place: letters, not one rule or block
                var wasInk = false;
                for (var x = x0; x < x1; x++)
                {
                    ink += colInk[x];
                    var isInk = colInk[x] > 0;
                    if (isInk && !wasInk) strokes++;
                    wasInk = isInk;
                }
                var area = (double)(x1 - x0) * (bottom - top);
                // Type covers roughly 8-35 % of its box; a filled bar or a picture covers more, specks less.
                if (ink < area * 0.04 || ink > area * 0.6) continue;
                if (strokes < Math.Max(3, (x1 - x0) / (dpi * 0.4))) continue;
                // Ink right beside a word read on the same row is most often the rest of a word read short, or a word
                // read wrong; read alone, it gives fragments ("4 lY).70"). A line skipped, or a column of one, stands apart.
                var (pt, pb) = (top, bottom);
                if (words.Any(o => Math.Min(o.Y + o.Height, pb) - Math.Max(o.Y, pt) > 0.5 * Math.Min(o.Height, pb - pt)
                                   && o.X < x1 + apart && o.X + o.Width > x0 - apart)) continue;
                places.Add(new Place(x0, top, x1 - x0, bottom - top, ink));
            }
        }
        return [.. places.OrderByDescending(p => p.Ink).Take(MaxRereads).OrderBy(p => p.Y).ThenBy(p => p.X)];
    }

    /// <summary>
    /// <paramref name="words"/> with what <paramref name="recognizer"/> reads in each of <see cref="Find"/>'s places, put in
    /// page order; a word that lands on one already read is left out. A place is read whole first; what it leaves unread is
    /// read again word by word (cut at the gaps between words), as Windows' recognizer reads some words only alone (it
    /// passes over "1111" in a line, and even alone). At most <see cref="MaxReads"/> readings a page.
    /// </summary>
    public static IReadOnlyList<RecognizedWord> Reread(GrayImage gray, IReadOnlyList<RecognizedWord> words, int dpi, ITextRecognizer recognizer,
        CancellationToken cancel = default)
    {
        var places = Find(gray, words, dpi, cancel);
        if (places.Count == 0) return words;
        var result = words.ToList();
        var line = words.Count == 0 ? 0 : words.Max(x => x.Line) + 1;
        var pad = Math.Max(2, dpi / 100);
        var reads = 0;
        foreach (var place in places)
        {
            if (reads >= MaxReads) break;
            var read = new List<RecognizedWord>();
            reads++;
            Read(place.X, place.Right);
            // What the whole place left unread, word by word.
            foreach (var (x0, x1) in Unread(gray, result.Concat(read), place, dpi))
            {
                if (reads >= MaxReads) break;
                reads++;
                Read(x0, x1);
            }
            line++;
            if (read.Count == 0) continue;
            result.InsertRange(InsertAt(result, place), read.OrderBy(r => r.X));

            void Read(int left, int right)
            {
                cancel.ThrowIfCancellationRequested();
                var (x0, y0) = (Math.Max(0, left - pad), Math.Max(0, place.Y - pad));
                var (x1, y1) = (Math.Min(gray.Width, right + pad), Math.Min(gray.Height, place.Bottom + pad));
                var (cw, ch) = (x1 - x0 + 2 * Margin, y1 - y0 + 2 * Margin);
                var canvas = new byte[cw * ch];
                Array.Fill(canvas, (byte)255);
                for (var y = y0; y < y1; y++) Array.Copy(gray.Pixels, y * gray.Width + x0, canvas, (y - y0 + Margin) * cw + Margin, x1 - x0);
                // Words already read are painted out, so only the unread ink is there to read.
                foreach (var o in result.Concat(read))
                {
                    var (ox0, oy0) = (Math.Max(0, (int)Math.Floor(o.X) - x0 + Margin), Math.Max(0, (int)Math.Floor(o.Y) - y0 + Margin));
                    var (ox1, oy1) = (Math.Min(cw, (int)Math.Ceiling(o.X + o.Width) - x0 + Margin), Math.Min(ch, (int)Math.Ceiling(o.Y + o.Height) - y0 + Margin));
                    if (ox1 <= ox0) continue;
                    for (var y = oy0; y < oy1; y++) Array.Fill(canvas, (byte)255, y * cw + ox0, ox1 - ox0);
                }
                foreach (var r in recognizer.Recognize(canvas, cw, ch, 1, cancel))
                {
                    if (string.IsNullOrWhiteSpace(r.Text)) continue;
                    var word = r with { X = r.X - Margin + x0, Y = r.Y - Margin + y0, Line = line };
                    var (cx, cy) = (word.X + word.Width / 2, word.Y + word.Height / 2);
                    if (cx < x0 || cx >= x1 || cy < y0 || cy >= y1) continue; // the edge of a neighbour, not this place
                    if (result.Concat(read).Any(o => Overlap(o, word) > 0.5)) continue;
                    read.Add(word);
                }
            }
        }
        return result;
    }

    /// <summary>The stretches of a place (columns) whose ink no word covers yet, cut at the gaps between words.</summary>
    private static List<(int Start, int End)> Unread(GrayImage gray, IEnumerable<RecognizedWord> words, Place place, int dpi)
    {
        var near = words.Where(o => o.X < place.Right && o.X + o.Width > place.X && o.Y < place.Bottom && o.Y + o.Height > place.Y).ToList();
        var cols = new int[place.Width];
        for (var y = place.Y; y < place.Bottom; y++)
            for (var x = place.X; x < place.Right; x++)
                if (gray.Pixels[y * gray.Width + x] < Dark && !near.Any(o => x >= o.X && x < o.X + o.Width && y >= o.Y && y < o.Y + o.Height))
                    cols[x - place.X]++;
        var minWidth = dpi * 0.06; // a narrow word or a number
        // A gap between words is about 0.4 of a line's height; a "1" in some faces stands nearly as far from the next.
        return [.. Runs(cols, cols.Length, minInk: 1, gap: Math.Max(2, (int)Math.Round(place.Height * 0.4)))
            .Where(r => r.End - r.Start >= minWidth && cols.AsSpan(r.Start, r.End - r.Start).ToArray().Sum() >= minWidth * place.Height * 0.04)
            .Select(r => (r.Start + place.X, r.End + place.X))];
    }

    /// <summary>
    /// Where in reading order a place's words go: after the last word left of it on its row, or of a line above it that
    /// shares its columns (the recognizer's lines, whole: a line's last word may be past the place's right end).
    /// </summary>
    private static int InsertAt(List<RecognizedWord> words, Place place)
    {
        var cy = place.Y + place.Height / 2.0;
        var lines = words.GroupBy(o => o.Line).ToDictionary(g => g.Key, g => (Left: g.Min(o => o.X), Right: g.Max(o => o.X + o.Width)));
        bool SameRow(RecognizedWord o) => Math.Min(o.Y + o.Height, place.Bottom) - Math.Max(o.Y, place.Y) > 0.5 * Math.Min(o.Height, place.Height);
        bool SameColumn(RecognizedWord o) => Math.Min(lines[o.Line].Right, place.Right) - Math.Max(lines[o.Line].Left, place.X) > 0;
        bool Before(RecognizedWord o) => SameRow(o) ? o.X + o.Width / 2 < place.X : SameColumn(o) && o.Y + o.Height / 2 < cy;
        bool After(RecognizedWord o) => SameRow(o) ? o.X + o.Width / 2 > place.Right : SameColumn(o) && o.Y + o.Height / 2 > cy;
        var last = words.FindLastIndex(Before);
        if (last >= 0) return last + 1;
        var first = words.FindIndex(After);
        return first >= 0 ? first : words.Count;
    }

    /// <summary>How much of the smaller of two boxes the other covers.</summary>
    private static double Overlap(RecognizedWord a, RecognizedWord b)
    {
        var iw = Math.Min(a.X + a.Width, b.X + b.Width) - Math.Max(a.X, b.X);
        var ih = Math.Min(a.Y + a.Height, b.Y + b.Height) - Math.Max(a.Y, b.Y);
        if (iw <= 0 || ih <= 0) return 0;
        return iw * ih / Math.Max(1e-9, Math.Min(a.Width * a.Height, b.Width * b.Height));
    }

    /// <summary>The top and bottom rows of the unread ink between columns x0 and x1 of a band.</summary>
    private static (int Top, int Bottom) Rows(byte[] px, int w, List<(int Start, int End)>?[] covered, int x0, int x1, int y0, int y1)
    {
        int top = -1, bottom = -1;
        for (var y = y0; y < y1; y++)
        {
            for (var x = x0; x < x1; x++)
            {
                if (px[y * w + x] >= Dark || Inside(covered[y], x)) continue;
                if (top < 0) top = y;
                bottom = y + 1;
                break;
            }
        }
        return top < 0 ? (0, 0) : (top, bottom);
    }

    /// <summary>Per row, the column spans (sorted, merged) that recognized words cover, a little larger than the words' boxes.</summary>
    private static List<(int Start, int End)>?[] Covered(IReadOnlyList<RecognizedWord> words, int w, int h, int dpi)
    {
        var (padX, padY) = (Math.Max(2, dpi / 50), Math.Max(2, dpi / 30));
        var rows = new List<(int Start, int End)>?[h];
        foreach (var word in words)
        {
            var (x0, x1) = (Math.Max(0, (int)Math.Floor(word.X) - padX), Math.Min(w, (int)Math.Ceiling(word.X + word.Width) + padX));
            var (y0, y1) = (Math.Max(0, (int)Math.Floor(word.Y) - padY), Math.Min(h, (int)Math.Ceiling(word.Y + word.Height) + padY));
            if (x1 <= x0) continue;
            for (var y = y0; y < y1; y++) (rows[y] ??= []).Add((x0, x1));
        }
        for (var y = 0; y < h; y++)
        {
            var spans = rows[y];
            if (spans is null || spans.Count < 2) continue;
            spans.Sort();
            var merged = new List<(int Start, int End)> { spans[0] };
            foreach (var s in spans.Skip(1))
            {
                var last = merged[^1];
                if (s.Start <= last.End) merged[^1] = (last.Start, Math.Max(last.End, s.End));
                else merged.Add(s);
            }
            rows[y] = merged;
        }
        return rows;
    }

    private static bool Inside(List<(int Start, int End)>? spans, int x)
    {
        if (spans is null) return false;
        foreach (var (start, end) in spans)
        {
            if (x < start) return false;
            if (x < end) return true;
        }
        return false;
    }

    /// <summary>Runs of indices whose count is at least <paramref name="minInk"/>, joined across gaps up to <paramref name="gap"/>.</summary>
    private static List<(int Start, int End)> Runs(int[] counts, int length, int minInk, int gap)
    {
        var runs = new List<(int Start, int End)>();
        int start = -1, end = -1;
        for (var i = 0; i < length; i++)
        {
            if (counts[i] < minInk) continue;
            if (start >= 0 && i - end <= gap) end = i + 1;
            else
            {
                if (start >= 0) runs.Add((start, end));
                (start, end) = (i, i + 1);
            }
        }
        if (start >= 0) runs.Add((start, end));
        return runs;
    }
}
