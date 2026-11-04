using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// Windows' recognizer now and then skips a whole line that is plainly on the page (or a stretch of one). On the cleaned
/// page (straight, upright, white paper), this finds the ink no recognized word covers, in bands the size of a line of
/// type, and reads each band again on its own: cut out, the words already read painted out, on a margin of white; then
/// what that left unread, word by word. The words it gives are put back in reading order among the others. Only ink that
/// looks like type and stands apart from the words read on its row is read again (not specks, rules, filled blocks or
/// pictures, nor the rest of a word read short), at most <see cref="MaxRereads"/> places and <see cref="MaxReads"/>
/// readings a page. Then the same for a word left out inside a line that was read (<see cref="FindInLines"/>). Four 1s in
/// a row ("1111"), which Windows never reads and for which it leaves out their whole line, are read three at a time.
/// pdf/tools/ocr-corpus measures it with Windows' recognizer (its `skipped-lines` page, and `probe`).
/// </summary>
internal static class MissedLines
{
    /// <summary>Places read again on a page at most: those with the most ink.</summary>
    public const int MaxRereads = 12;

    /// <summary>Places inside lines read (words left out) read again on a page at most: those with the most ink.</summary>
    public const int MaxInLine = 16;

    /// <summary>Readings a page at most: each place whole, then the words it left unread one by one, then in pieces.</summary>
    public const int MaxReads = 60;

    /// <summary>Strokes a stretch read in pieces may have at most (eight chunks).</summary>
    private const int MaxStrokes = 24;

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
    /// <paramref name="words"/> with what <paramref name="recognizer"/> reads in each of <see cref="Find"/>'s places (lines
    /// skipped) and then in <see cref="FindInLines"/>'s (words left out inside a line that was read), put in page order; a
    /// word that lands on one already read is left out. A place is read whole first; what it leaves unread is read again
    /// word by word (cut at the gaps between words), as Windows' recognizer reads some words only alone; what still reads as
    /// nothing is read in pieces (Windows never reads four 1s in a row, "1111", and leaves out the whole line they are in).
    /// At most <see cref="MaxReads"/> readings a page.
    /// </summary>
    public static IReadOnlyList<RecognizedWord> Reread(GrayImage gray, IReadOnlyList<RecognizedWord> words, int dpi, ITextRecognizer recognizer,
        CancellationToken cancel = default)
    {
        var places = Find(gray, words, dpi, cancel);
        var reader = new Reader(gray, dpi, recognizer, words, cancel);
        var line = words.Count == 0 ? 0 : words.Max(x => x.Line) + 1;
        foreach (var place in places)
        {
            if (reader.Spent) break;
            reader.ReadPlace(place, line++);
        }
        // Then, on the lines read by now, the words left out inside them.
        foreach (var (place, ofLine) in FindInLines(gray, reader.Result, dpi, cancel))
        {
            if (reader.Spent) break;
            reader.ReadPlace(place, ofLine, wholeWords: true);
        }
        return reader.Result;
    }

    /// <summary>
    /// Places inside the lines read where a word was left out: ink no word covers on a read line's row, between two of its
    /// words or just past its ends (within two line heights), that stands clear of the words beside it (a word read short
    /// leaves the rest of its ink touching its box; a word left out stands a word's gap away), is as tall as a digit or a
    /// small letter (not a comma, a dot or a speck) and looks like type. At most <see cref="MaxInLine"/> places a page, the
    /// most ink first, in reading order, each with the line it belongs to. Each place spans its line's height.
    /// </summary>
    public static List<(Place Place, int Line)> FindInLines(GrayImage gray, IReadOnlyList<RecognizedWord> words, int dpi, CancellationToken cancel = default)
    {
        var (w, h, px) = (gray.Width, gray.Height, gray.Pixels);
        var found = new List<(Place Place, int Line)>();
        foreach (var group in words.GroupBy(o => o.Line))
        {
            cancel.ThrowIfCancellationRequested();
            var row = group.OrderBy(o => o.X).ToList();
            var top = Math.Max(0, (int)Math.Floor(row.Min(o => o.Y)));
            var bottom = Math.Min(h, (int)Math.Ceiling(row.Max(o => o.Y + o.Height)));
            var lh = bottom - top;
            if (lh < Math.Max(8, dpi * 0.04) || lh > dpi * 0.5) continue;
            var (first, last) = (row[0].X, row[^1].X + row[^1].Width);
            var (left, right) = (Math.Max(0, (int)(first - 8 * lh)), Math.Min(w, (int)Math.Ceiling(last + 8 * lh))); // a word or two past the ends
            if (right <= left) continue;
            // Every word whose box reaches into the row (of this line or another): its ink isn't unread.
            var boxes = words.Where(o => o.Y < bottom && o.Y + o.Height > top && o.X < right && o.X + o.Width > left)
                .Select(o => (X0: (int)Math.Floor(o.X) - 1, X1: (int)Math.Ceiling(o.X + o.Width) + 1, Y0: (int)Math.Floor(o.Y) - 1, Y1: (int)Math.Ceiling(o.Y + o.Height) + 1))
                .ToList();
            bool Unread(int x, int y)
            {
                if (px[y * w + x] >= Dark) return false;
                foreach (var b in boxes)
                    if (x >= b.X0 && x < b.X1 && y >= b.Y0 && y < b.Y1) return false;
                return true;
            }
            var colInk = new int[right - left];
            for (var x = left; x < right; x++)
                for (var y = top; y < bottom; y++)
                    if (Unread(x, y)) colInk[x - left]++;
            var clear = Math.Max(2, lh * 0.12);
            // Unread ink this close is one place: the letters of a word, and the 1s of a number, which stand further apart.
            foreach (var (s, e) in Runs(colInk, colInk.Length, minInk: 1, gap: Math.Max(2, (int)Math.Round(lh * 0.6))))
            {
                var (x0, x1) = (s + left, e + left);
                if (x1 - x0 < Math.Max(3, lh * 0.15)) continue;
                int inkTop = -1, inkBottom = -1, ink = 0;
                for (var y = top; y < bottom; y++)
                {
                    var any = false;
                    for (var x = x0; x < x1; x++)
                    {
                        if (!Unread(x, y)) continue;
                        ink++;
                        any = true;
                    }
                    if (!any) continue;
                    if (inkTop < 0) inkTop = y;
                    inkBottom = y + 1;
                }
                if (inkTop < 0 || inkBottom - inkTop < lh * 0.4) continue; // a comma, a dot, a dash, a speck
                var area = (double)(x1 - x0) * (inkBottom - inkTop);
                if (ink < area * 0.05 || ink > area * 0.7) continue;
                // Clear of the words beside it on its row, and past a line's end by no more than a word or two.
                if (row.Any(o => Math.Min(o.Y + o.Height, inkBottom) - Math.Max(o.Y, inkTop) > 0 && o.X - clear < x1 && o.X + o.Width + clear > x0)) continue;
                if (x1 <= first && first - x1 > 2 * lh) continue;
                if (x0 >= last && x0 - last > 2 * lh) continue;
                found.Add((new Place(x0, top, x1 - x0, lh, ink), group.Key));
            }
        }
        return [.. found.OrderByDescending(f => f.Place.Ink).Take(MaxInLine).OrderBy(f => f.Place.Y).ThenBy(f => f.Place.X)];
    }

    /// <summary>Reads places of a page again, each on its own, within the page's budget of readings.</summary>
    private sealed class Reader(GrayImage gray, int dpi, ITextRecognizer recognizer, IReadOnlyList<RecognizedWord> words, CancellationToken cancel)
    {
        private readonly int _pad = Math.Max(2, dpi / 100);
        private int _reads;

        /// <summary>The words read so far, in page order.</summary>
        public List<RecognizedWord> Result { get; } = [.. words];

        public bool Spent => _reads >= MaxReads;

        /// <summary>
        /// Reads a place: whole, then what that left unread word by word, then its runs of 1s (<see cref="ReadOnes"/>); its
        /// words go in page order. With <paramref name="wholeWords"/> (a word left out inside a line), only a reading
        /// whose every word is a plain word or number is kept: beside words read already, a recognizer reading a bit of ink
        /// alone gives fragments ("4 IY).70").
        /// </summary>
        public void ReadPlace(Place place, int line, bool wholeWords = false)
        {
            var read = new List<RecognizedWord>();
            read.AddRange(Read(place, place.X, place.Right, line, read));
            foreach (var (x0, x1) in Unread(gray, Result.Concat(read), place, dpi))
            {
                if (Spent) break;
                read.AddRange(Read(place, x0, x1, line, read));
            }
            // A run of 1s cut up word by word may have been read in part ("11" and "11" for "1111"): its parts count as unread.
            var parts = read.Where(o => o.Text.All(c => c is '1' or 'I' or 'l' or '|')).ToList();
            var others = read.Except(parts).ToList();
            foreach (var run in Ones(place, others))
            {
                if (Spent) break;
                if (ReadOnes(place, run, line, others) is not { } word) continue;
                read.RemoveAll(o => parts.Contains(o) && Overlap(o, word) > 0.5);
                read.Add(word);
            }
            if (read.Count == 0 || (wholeWords && !read.All(o => Plain(o.Text)))) return;
            Result.InsertRange(InsertAt(Result, place), read.OrderBy(r => r.X));
        }

        /// <summary>
        /// Runs of four or more narrow strokes of one height, evenly apart, in a place's unread ink: what four 1s in a row
        /// look like ("1111"), which Windows' recognizer never reads, alone or in a line, at any size or margin, and leaves
        /// out the whole line they are in. A gap wider than the others (a space) ends a run, as does a stroke of another
        /// height or width.
        /// </summary>
        private List<List<Stroke>> Ones(Place place, List<RecognizedWord> read)
        {
            var runs = new List<List<Stroke>>();
            List<Stroke>? run = null;
            var minGap = 0;
            foreach (var s in Strokes(place, read))
            {
                var narrow = s.Height >= place.Height * 0.45 && s.Width <= s.Height * 0.7;
                if (run is not null)
                {
                    var gap = s.Start - run[^1].End;
                    var even = narrow && Math.Abs(s.Height - run[0].Height) <= run[0].Height * 0.15 && gap < run[0].Height
                               && (run.Count < 2 || (gap <= minGap * 1.3 && gap * 1.3 >= minGap));
                    if (even)
                    {
                        run.Add(s);
                        minGap = run.Count == 2 ? gap : Math.Min(minGap, gap);
                        continue;
                    }
                    var previous = run[^1];
                    if (run.Count >= 4) runs.Add(run);
                    run = null;
                    // A run may start at the stroke before ("y" of "Pay" is narrow too, a space from the 1s after it).
                    if (narrow && previous.Width <= previous.Height * 0.7 && Math.Abs(s.Height - previous.Height) <= previous.Height * 0.15 && gap < previous.Height
                        && !runs.Any(r => r.Contains(previous)))
                    {
                        run = [previous, s];
                        minGap = gap;
                        continue;
                    }
                }
                if (narrow) run = [s];
            }
            if (run is { Count: >= 4 }) runs.Add(run);
            return runs;
        }

        /// <summary>
        /// A run of 1s (<see cref="Ones"/>) read three strokes at a time, each three on its own (three 1s Windows reads; one
        /// alone it never does, and two not always), the last three ending at the run's end. Each reading must be three
        /// digits, one a stroke (an I, l or | read among them is a 1); else the run isn't a number and nothing is kept.
        /// </summary>
        private RecognizedWord? ReadOnes(Place place, List<Stroke> run, int line, List<RecognizedWord> read)
        {
            if (run.Count > MaxStrokes) return null;
            var starts = new List<int>();
            for (var s = 0; s + 3 < run.Count; s += 3) starts.Add(s);
            starts.Add(run.Count - 3);
            if (_reads + starts.Count > MaxReads) return null;
            var digits = new char[run.Count];
            foreach (var s in starts)
            {
                var text = string.Concat(Read(place, run[s].Start, run[s + 2].End, line, read).OrderBy(g => g.X).Select(g => g.Text));
                if (text.Length != 3 || !text.All(c => char.IsDigit(c) || c is 'I' or 'l' or '|')) return null;
                for (var k = 0; k < 3; k++) digits[s + k] = text[k] is 'I' or 'l' or '|' ? '1' : text[k];
            }
            var (top, bottom) = (run.Min(s => s.Top), run.Max(s => s.Bottom));
            var word = new RecognizedWord(new string(digits), run[0].Start, top, run[^1].End - run[0].Start, bottom - top, line);
            return Result.Concat(read).Any(o => Overlap(o, word) > 0.5) ? null : word;
        }

        /// <summary>A stroke: a run of columns with ink, and the rows its ink spans.</summary>
        private readonly record struct Stroke(int Start, int End, int Top, int Bottom)
        {
            public int Width => End - Start;
            public int Height => Bottom - Top;
        }

        /// <summary>The separate strokes of a place's ink that no word read covers, left to right.</summary>
        private List<Stroke> Strokes(Place place, List<RecognizedWord> read)
        {
            var near = Result.Concat(read).Where(o => o.X < place.Right && o.X + o.Width > place.X && o.Y < place.Bottom && o.Y + o.Height > place.Y).ToList();
            var (top, bottom) = (new int[place.Width], new int[place.Width]);
            Array.Fill(top, -1);
            for (var y = place.Y; y < place.Bottom; y++)
                for (var x = place.X; x < place.Right; x++)
                {
                    if (gray.Pixels[y * gray.Width + x] >= Dark || near.Any(o => x >= o.X && x < o.X + o.Width && y >= o.Y && y < o.Y + o.Height)) continue;
                    var i = x - place.X;
                    if (top[i] < 0) top[i] = y;
                    bottom[i] = y + 1;
                }
            var strokes = new List<Stroke>();
            for (var i = 0; i < place.Width; i++)
            {
                if (top[i] < 0) continue;
                if (strokes.Count > 0 && strokes[^1].End == place.X + i)
                    strokes[^1] = strokes[^1] with { End = place.X + i + 1, Top = Math.Min(strokes[^1].Top, top[i]), Bottom = Math.Max(strokes[^1].Bottom, bottom[i]) };
                else strokes.Add(new Stroke(place.X + i, place.X + i + 1, top[i], bottom[i]));
            }
            return strokes;
        }

        /// <summary>
        /// What the recognizer reads in columns <paramref name="left"/> to <paramref name="right"/> of a place alone: cut out,
        /// the words already read painted out, on a margin of white; in page pixels, none on a word already read.
        /// </summary>
        private List<RecognizedWord> Read(Place place, int left, int right, int line, List<RecognizedWord> read)
        {
            cancel.ThrowIfCancellationRequested();
            _reads++;
            var got = new List<RecognizedWord>();
            var (x0, y0) = (Math.Max(0, left - _pad), Math.Max(0, place.Y - _pad));
            var (x1, y1) = (Math.Min(gray.Width, right + _pad), Math.Min(gray.Height, place.Bottom + _pad));
            if (x1 <= x0 || y1 <= y0) return got;
            var (cw, ch) = (x1 - x0 + 2 * Margin, y1 - y0 + 2 * Margin);
            var canvas = new byte[cw * ch];
            Array.Fill(canvas, (byte)255);
            for (var y = y0; y < y1; y++) Array.Copy(gray.Pixels, y * gray.Width + x0, canvas, (y - y0 + Margin) * cw + Margin, x1 - x0);
            // Words already read are painted out, so only the unread ink is there to read.
            foreach (var o in Result.Concat(read))
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
                if (Result.Concat(read).Concat(got).Any(o => Overlap(o, word) > 0.5)) continue;
                got.Add(word);
            }
            return got;
        }
    }

    /// <summary>
    /// A plain word or number, with the punctuation around it: letters (an apostrophe or hyphen inside), or digits (with
    /// a number's . , : / or - inside).
    /// </summary>
    internal static bool Plain(string text)
    {
        var core = SuspectWords.Core(text);
        if (core.Length == 0) return false;
        if (core.All(c => char.IsLetter(c) || c is '\'' or '’' or '-')) return char.IsLetter(core[0]) && char.IsLetter(core[^1]);
        return char.IsDigit(core[0]) && char.IsDigit(core[^1]) && core.All(c => char.IsDigit(c) || c is '.' or ',' or ':' or '/' or '-');
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
