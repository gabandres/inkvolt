using InkvoltPrint.Core.Imaging;
using MuPDFCore;
using MuPDFCore.StructuredText;

namespace InkvoltPdf.Core;

/// <summary>Why a page needs a person's eyes: what the search could only read through text recognition, or not at all.</summary>
public enum RedactionLookReason
{
    /// <summary>The page is a scan (a picture with or without a text layer), read by text recognition.</summary>
    ScanReadByOcr,

    /// <summary>The page has its own text and pictures or drawn text besides, those read by text recognition.</summary>
    PicturesReadByOcr,

    /// <summary>The page is a scan and no text recognition is available: at most its text layer was searched.</summary>
    ScanNotRead,

    /// <summary>The page has ink that isn't text, and no text recognition is available to read it.</summary>
    PicturesNotRead,
}

/// <summary>A page to look at by hand.</summary>
/// <param name="Unread">Places with ink where no word was read at all, page space (a dropped line, a stamp, a signature, a logo).</param>
public sealed record RedactionLook(int Page, RedactionLookReason Reason, IReadOnlyList<RectD> Unread)
{
    /// <summary>One line for a list that has said the rest above it.</summary>
    public string Short =>
        (Reason switch
        {
            RedactionLookReason.ScanReadByOcr => "A scan, read by OCR.",
            RedactionLookReason.PicturesReadByOcr => "Pictures or drawn text, read by OCR.",
            RedactionLookReason.ScanNotRead => "A scan that couldn't be read: no OCR language.",
            _ => "Pictures or drawn text that couldn't be read: no OCR language.",
        }) + (Unread.Count switch { 0 => "", 1 => " Tick to black out the 1 place nothing was read.", _ => $" Tick to black out the {Unread.Count} places nothing was read." });

    /// <summary>What to tell the person. Never says a page is clean.</summary>
    public string Text
    {
        get
        {
            var why = Reason switch
            {
                RedactionLookReason.ScanReadByOcr => "A scan, read by text recognition, which can misread words and miss whole lines.",
                RedactionLookReason.PicturesReadByOcr => "Has pictures or drawn text, read by text recognition, which can misread words and miss whole lines.",
                RedactionLookReason.ScanNotRead => "A scan, and Windows has no text recognition language: only a text layer, if it has one, was searched.",
                _ => "Has pictures or drawn text that couldn't be read: Windows has no text recognition language.",
            };
            return Unread.Count switch
            {
                0 => why,
                1 => why + " 1 place has ink where nothing was read.",
                _ => $"{why} {Unread.Count} places have ink where nothing was read.",
            };
        }
    }
}

/// <summary>What a search found: the matches, and the pages that can't be taken as clean whatever it found on them.</summary>
public sealed record RedactionSearchResult(IReadOnlyList<RedactionMatch> Hits, IReadOnlyList<RedactionLook> Looks)
{
    /// <summary>Scans that nothing could read: searching this file didn't really happen.</summary>
    public IEnumerable<int> UnreadScans => Looks.Where(l => l.Reason == RedactionLookReason.ScanNotRead).Select(l => l.Page);
}

/// <summary>
/// Redaction by pattern over a whole document, its scans too: <see cref="RedactionPatterns"/> runs on each page's own text
/// and, on a page that has ink the text doesn't explain (a scan, a picture of text, text drawn as shapes), on what text
/// recognition reads there. Places with ink where nothing at all was read are read again on their own (Windows' recognizer
/// can skip a whole line), and what stays unread is reported. A page read by recognition is never reported clean: it comes
/// back in <see cref="RedactionSearchResult.Looks"/> for a person to look at, hits or not.
/// </summary>
public static class RedactionSearch
{
    /// <summary>A picture share above this makes a page a scan, even under a text layer (an old layer can be poor or planted).</summary>
    private const double ScanShare = 0.5;

    /// <summary>A place is read again at this resolution, and no more than this many on a page.</summary>
    private const double RereadDpi = 300;

    private const int MaxRereads = 24;

    /// <summary>Text boxes taller than this don't vouch for the ink under them (hostile text can claim to cover a whole page).</summary>
    private const double TallestWord = 150;

    /// <param name="ocr">The recognizer; null: pages that need one come back as not read.</param>
    /// <param name="ocrOnly">Look past the text only on these pages (the read-back, after the others were looked at once); null: every page.</param>
    /// <param name="progress">(pages done, pages to search).</param>
    /// <exception cref="ArgumentException">The options aren't valid (see <see cref="RedactionPatterns.Validate"/>).</exception>
    /// <exception cref="TimeoutException">A pattern took too long: the search stopped, it isn't reported clean.</exception>
    /// <exception cref="TooManyHitsException">More matches than can be reviewed.</exception>
    public static RedactionSearchResult Find(PdfEngine engine, RedactionPatternOptions options, ITextRecognizer? ocr = null,
        IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default, IReadOnlySet<int>? ocrOnly = null)
    {
        var custom = RedactionPatterns.Compile(options);
        var pages = (options.Pages ?? Enumerable.Range(0, engine.PageCount).ToArray()).Where(p => p >= 0 && p < engine.PageCount).Distinct().Order().ToList();
        var hits = new List<RedactionMatch>();
        var looks = new List<RedactionLook>();
        for (var i = 0; i < pages.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            var p = pages[i];
            // Cached only for a few pages: a long document would push the pages the viewer shows out of the engine's text cache.
            var text = engine.GetText(p, cache: pages.Count <= 8, cancel);
            var own = RedactionPatterns.FindOnPage(text, p, options, custom);
            hits.AddRange(own);
            if (ocrOnly is null || ocrOnly.Contains(p))
            {
                var (read, look) = ReadInk(engine, p, text, ocr, cancel);
                if (look is not null) looks.Add(look);
                if (read.Count > 0)
                {
                    var taken = own.GroupBy(o => o.Pattern).ToDictionary(g => g.Key, g => new RectIndex(g.SelectMany(o => o.Rects)));
                    foreach (var hit in RedactionPatterns.FindOnPage(OcrPageText(read), p, options, custom, lenient: true))
                    {
                        // Boxes from a recognizer are rough: a little more room, so no edge of a figure stays.
                        var rects = (IReadOnlyList<RectD>)[.. hit.Rects.Select(r => r.Inflate(1.5))];
                        // The same value read twice lies on itself; one on the next line only touches the first.
                        if (!(taken.TryGetValue(hit.Pattern, out var same) && same.LiesOn(hit.Rects))) hits.Add(hit with { Rects = rects, FromOcr = true });
                    }
                }
            }
            if (hits.Count > RedactionPatterns.MaxHits) throw new TooManyHitsException(RedactionPatterns.MaxHits);
            progress?.Report((i + 1, pages.Count));
        }
        return new RedactionSearchResult(hits, looks);
    }

    /// <summary>
    /// The result of redacting searched again: the matches that are still there, other than those the person chose to keep
    /// (<paramref name="kept"/>, by place). Empty means nothing the patterns can read is left on the pages; it doesn't
    /// say a scanned page is clean.
    /// </summary>
    /// <param name="redactedPages">The pages that were redacted: they are pictures now, so the recognizer reads them again.</param>
    public static List<RedactionMatch> ReadBack(byte[] data, string? password, RedactionPatternOptions options, ITextRecognizer? ocr,
        IReadOnlySet<int> redactedPages, IReadOnlyList<RedactionMatch> kept, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        var found = Find(engine, options, ocr, progress, cancel, redactedPages);
        var keptByPage = kept.GroupBy(k => k.Page).ToDictionary(g => g.Key, g => new RectIndex(g.SelectMany(k => k.Rects)));
        return [.. found.Hits.Where(h => !(keptByPage.TryGetValue(h.Page, out var keptHere) && keptHere.Touches(h.Rects)))];
    }

    /// <summary>The areas to black out per page: each match's boxes, grown by half a point so no edge of a glyph survives.</summary>
    public static Dictionary<int, IReadOnlyList<RectD>> Areas(IEnumerable<RedactionMatch> matches) => RedactionPatterns.Areas(matches);

    /// <summary>What to look for afterwards in everything else the file holds: each match as it reads, and as it was written.</summary>
    public static List<string> Values(IEnumerable<RedactionMatch> matches)
    {
        var values = new List<string>();
        foreach (var m in matches)
        {
            // Long matches (a pattern that takes a whole page) are looked for by their start: the checker's matcher has a size limit.
            values.Add(m.Normalized.Length > MaxValueLength ? m.Normalized[..MaxValueLength] : m.Normalized);
            if (!m.FromOcr) values.Add(m.Text.Length > MaxValueLength ? m.Text[..MaxValueLength] : m.Text);
        }
        return values;
    }

    /// <summary>
    /// What was removed, to look for in the rest of the file: not dates and ZIP codes, whose digits a file's own time stamps and
    /// ids can hold. What the patterns read outside the pages (<see cref="RedactionCheckOptions.Patterns"/>) covers those.
    /// </summary>
    public static List<string> SoughtValues(IEnumerable<RedactionMatch> matches) =>
        Values(matches.Where(m => m.Pattern is not (RedactionPattern.Date or RedactionPattern.ZipCode)));

    private const int MaxValueLength = 200;

    /// <summary>Boxes filed by height on the page: a page of hostile text can hold a hundred thousand of them.</summary>
    private sealed class RectIndex
    {
        private const double Band = 16;
        private readonly Dictionary<long, List<RectD>> _bands = [];

        public RectIndex(IEnumerable<RectD> rects)
        {
            foreach (var r in rects)
                foreach (var band in Bands(r))
                    (_bands.TryGetValue(band, out var list) ? list : _bands[band] = []).Add(r);
        }

        // A box taller than the page is odd enough to file by its first bands only; it stays findable from them.
        private static IEnumerable<long> Bands(RectD r)
        {
            var first = (long)Math.Floor(r.Y / Band);
            var last = Math.Min((long)Math.Floor(r.Bottom / Band), first + 512);
            for (var b = first; b <= last; b++) yield return b;
        }

        /// <summary>Most of one of the boxes is inside one of these.</summary>
        public bool LiesOn(IReadOnlyList<RectD> rects) =>
            rects.Any(r => Bands(r).Any(b => _bands.TryGetValue(b, out var list) && list.Any(k => k.Intersect(r) is { IsEmpty: false } i && i.Width * i.Height >= 0.5 * Math.Min(k.Width * k.Height, r.Width * r.Height))));

        public bool Touches(IReadOnlyList<RectD> rects) =>
            rects.Any(r => Bands(r).Any(b => _bands.TryGetValue(b, out var list) && list.Any(k => !k.Intersect(r).IsEmpty)));
    }

    // ───────────────────────────── the page's ink ─────────────────────────────

    /// <summary>What recognition reads on a page whose ink its text doesn't explain, and what to tell the person about the page.</summary>
    private static (IReadOnlyList<OcrWord> Words, RedactionLook? Look) ReadInk(PdfEngine engine, int page, PageText text, ITextRecognizer? ocr, CancellationToken cancel)
    {
        var boxes = engine.PictureBoxes(page, cancel);
        var ink = InkMap.Of(engine, page, boxes, cancel);
        var g = engine.GetPage(page);
        var pictures = boxes.Sum(b => b.Width * b.Height);
        // No ink and no picture: a blank page. A picture with no ink to see may be a very faint scan, so it isn't let through.
        if (ink.IsBlank && pictures <= 0) return ([], null);
        var known = KnownBoxes(text);
        var unread = ink.Unread(known);
        var hasText = text.Text.Any(c => !char.IsWhiteSpace(c));
        var scan = !hasText || pictures >= ScanShare * (g.Width * g.Height);
        if (!scan && unread.Count == 0) return ([], null);
        var notRead = new RedactionLook(page, scan ? RedactionLookReason.ScanNotRead : RedactionLookReason.PicturesNotRead, unread);
        if (ocr is null) return ([], notRead);

        try
        {
            var read = ScanText.Recognize(engine, page, ocr, new RecognizeOptions(CheckWords: false), null, cancel);
            var words = read.Words.ToList();
            unread = ink.Unread([.. known, .. words.Select(Box)]);
            if (unread.Count > 0 && read.QuarterTurns == 0 && Math.Abs(read.Skew) <= 3)
            {
                words.AddRange(Reread(engine, page, ocr, unread, words, cancel));
                unread = ink.Unread([.. known, .. words.Select(Box)]);
            }
            var reason = scan ? RedactionLookReason.ScanReadByOcr : RedactionLookReason.PicturesReadByOcr;
            return (words, new RedactionLook(page, reason, unread));
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not OutOfMemoryException)
        {
            // The recognizer gave up on this page (a page too large for it, an engine error): as good as not having one here.
            return ([], notRead);
        }
    }

    private static List<RectD> KnownBoxes(PageText text)
    {
        var boxes = new List<RectD>();
        if (text.IsEmpty) return boxes;
        // Character by character: a line's box would also vouch for a picture sitting between two of its words.
        for (var i = 0; i < text.Text.Length; i++)
        {
            if (char.IsWhiteSpace(text.Text[i])) continue;
            var box = text.BoxAt(i);
            if (!box.IsEmpty && box.Height <= TallestWord && box.Width <= TallestWord) boxes.Add(box);
        }
        return boxes;
    }

    /// <summary>The places with ink and no words, each read on its own, larger and with a margin of white.</summary>
    private static List<OcrWord> Reread(PdfEngine engine, int page, ITextRecognizer ocr, IReadOnlyList<RectD> places, List<OcrWord> have, CancellationToken cancel)
    {
        const int margin = 48;
        var scale = RereadDpi / 72;
        var g = engine.GetPage(page);
        var found = new List<OcrWord>();
        foreach (var place in places.Where(p => p.Height <= 96 && p.Width <= 2000).OrderByDescending(p => p.Width).Take(MaxRereads))
        {
            cancel.ThrowIfCancellationRequested();
            var region = place.Inflate(3).Intersect(new RectD(0, 0, g.Width, g.Height));
            if (region.IsEmpty) continue;
            var image = engine.Render(page, scale, region, cancel);
            var gray = ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
            var (w, h) = (image.Width + 2 * margin, image.Height + 2 * margin);
            var canvas = new byte[w * h];
            Array.Fill(canvas, (byte)255);
            for (var y = 0; y < image.Height; y++) Array.Copy(gray, y * image.Width, canvas, (y + margin) * w + margin, image.Width);
            foreach (var word in ocr.Recognize(canvas, w, h, 1, cancel))
            {
                var box = new RectD(region.X + (word.X - margin) / scale, region.Y + (word.Y - margin) / scale, word.Width / scale, word.Height / scale);
                if (string.IsNullOrWhiteSpace(word.Text) || have.Concat(found).Any(o => !Box(o).Intersect(box).IsEmpty && Box(o).Intersect(box).Width * Box(o).Intersect(box).Height > 0.5 * box.Width * box.Height)) continue;
                found.Add(new OcrWord(word.Text, box));
            }
        }
        return found;
    }

    /// <summary>A word's level box on the page: its own box turned by its angle.</summary>
    private static RectD Box(OcrWord word)
    {
        if (word.Angle == 0) return word.Rect;
        var (sin, cos) = Math.SinCos(word.Angle * Math.PI / 180);
        var (w, h) = (Math.Abs(word.Rect.Width * cos) + Math.Abs(word.Rect.Height * sin), Math.Abs(word.Rect.Width * sin) + Math.Abs(word.Rect.Height * cos));
        return new RectD(word.Rect.CenterX - w / 2, word.Rect.CenterY - h / 2, w, h);
    }

    /// <summary>
    /// Recognized words as a page's text, in the order they were read (the recognizer knows the columns). Every character
    /// has the box of its whole word: a recognizer gives no finer place, and guessing from the width could leave a digit
    /// of a value showing, so a hit always blacks out the whole word it is in.
    /// </summary>
    internal static PageText OcrPageText(IReadOnlyList<OcrWord> words)
    {
        var lines = new List<List<(string Ch, RectD Box)>>();
        var directions = new List<(double X, double Y)>();
        var (lastAcross, lastAlong, lastHeight) = (0.0, double.MinValue, 0.0);
        foreach (var word in words.Where(w => !string.IsNullOrWhiteSpace(w.Text) && !w.Rect.IsEmpty))
        {
            // Along and across the line, whatever way the word runs on the page.
            var (sin, cos) = Math.SinCos(word.Angle * Math.PI / 180);
            var along = word.Rect.CenterX * cos + word.Rect.CenterY * sin;
            var across = -word.Rect.CenterX * sin + word.Rect.CenterY * cos;
            var box = Box(word);
            if (lines.Count == 0 || Math.Abs(across - lastAcross) > 0.6 * Math.Max(word.Rect.Height, lastHeight) || along < lastAlong)
            {
                lines.Add([]);
                directions.Add((cos, sin));
            }
            else lines[^1].Add((" ", new RectD(lines[^1][^1].Box.Right, lines[^1][^1].Box.Y, 0, lines[^1][^1].Box.Height)));
            foreach (var rune in word.Text.EnumerateRunes()) lines[^1].Add((rune.ToString(), box));
            (lastAcross, lastAlong, lastHeight) = (across, along, word.Rect.Height);
        }
        return new PageText(lines, directions);
    }
}

/// <summary>
/// Where a page has ink, drawn small: enough to tell the ink the page's words explain from the ink they don't (a line the
/// recognizer dropped, a picture, text drawn as shapes). Paper shade, rules, frames and specks don't count.
/// </summary>
internal sealed class InkMap
{
    private const double Scale = 1.5, MaxPixels = 8_000_000;

    /// <summary>A straight run of ink this long (points) is a rule, a frame or a filled box, not a character.</summary>
    private const double LongestStroke = 36;

    /// <summary>The smallest place that could be a few characters (points); ink this close together is one place.</summary>
    private const double MinWidth = 14, MinHeight = 4, JoinAcross = 6;

    private readonly int _w, _h;
    private readonly double _scale;
    private readonly bool[] _dark;

    private InkMap(int w, int h, double scale, bool[] dark)
    {
        (_w, _h, _scale, _dark) = (w, h, scale, dark);
        IsBlank = !Array.Exists(dark, d => d);
    }

    public bool IsBlank { get; }

    /// <param name="pictures">The page's pictures: in them, what is lighter than around it is ink too (words on a colored band).</param>
    public static InkMap Of(PdfEngine engine, int page, IReadOnlyList<RectD> pictures, CancellationToken cancel)
    {
        var g = engine.GetPage(page);
        var scale = Math.Min(Scale, Math.Sqrt(MaxPixels / Math.Max(1, g.Width * g.Height)));
        var image = engine.Render(page, scale, null, cancel);
        var gray = ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        return new InkMap(image.Width, image.Height, scale, Threshold(gray, image.Width, image.Height, InPictures(pictures, image.Width, image.Height, scale)));
    }

    /// <summary>Dark against the paper around it, tile by tile, so a shaded scan isn't all ink; black is ink wherever it is.</summary>
    private static bool[] Threshold(byte[] gray, int w, int h, bool[]? inPicture)
    {
        const int tile = 64;
        var dark = new bool[w * h];
        Span<int> histogram = stackalloc int[256];
        for (var ty = 0; ty < h; ty += tile)
        {
            for (var tx = 0; tx < w; tx += tile)
            {
                histogram.Clear();
                var (x1, y1) = (Math.Min(w, tx + tile), Math.Min(h, ty + tile));
                for (var y = ty; y < y1; y++)
                    for (var x = tx; x < x1; x++)
                        histogram[gray[y * w + x]]++;
                var half = (x1 - tx) * (y1 - ty) / 2;
                var (paper, seen) = (0, 0);
                for (; paper < 255 && (seen += histogram[paper]) < half; paper++) { }
                var limit = Math.Max(90, paper - 40);
                for (var y = ty; y < y1; y++)
                    for (var x = tx; x < x1; x++)
                    {
                        // In a picture, what is lighter than around it is ink; on a dark ground it is the only ink there is.
                        var light = inPicture?[y * w + x] == true;
                        dark[y * w + x] = light && gray[y * w + x] > paper + 40 || (gray[y * w + x] < limit && !(light && paper < limit));
                    }
            }
        }
        return dark;
    }

    private static bool[]? InPictures(IReadOnlyList<RectD> pictures, int w, int h, double scale)
    {
        if (pictures.Count == 0) return null;
        var mask = new bool[w * h];
        foreach (var box in pictures)
        {
            var (x0, x1) = (Math.Clamp((int)Math.Ceiling(box.X * scale), 0, w), Math.Clamp((int)Math.Floor(box.Right * scale), 0, w));
            var (y0, y1) = (Math.Clamp((int)Math.Ceiling(box.Y * scale), 0, h), Math.Clamp((int)Math.Floor(box.Bottom * scale), 0, h));
            if (x1 <= x0) continue;
            for (var y = y0; y < y1; y++) Array.Fill(mask, true, y * w + x0, x1 - x0);
        }
        return mask;
    }

    /// <summary>The places with ink outside <paramref name="known"/> (boxes in page points), largest first, at most 64.</summary>
    public IReadOnlyList<RectD> Unread(IEnumerable<RectD> known)
    {
        var left = (bool[])_dark.Clone();
        foreach (var box in known)
        {
            var b = box.Inflate(1.5);
            var (x0, x1) = (Math.Clamp((int)Math.Floor(b.X * _scale), 0, _w), Math.Clamp((int)Math.Ceiling(b.Right * _scale), 0, _w));
            var (y0, y1) = (Math.Clamp((int)Math.Floor(b.Y * _scale), 0, _h), Math.Clamp((int)Math.Ceiling(b.Bottom * _scale), 0, _h));
            if (x1 <= x0) continue;
            for (var y = y0; y < y1; y++) Array.Clear(left, y * _w + x0, x1 - x0);
        }
        var alone = new bool[left.Length];
        for (var y = 0; y < _h; y++)
            for (var x = 0; x < _w; x++)
                if (left[y * _w + x] && !HasNeighbour(left, x, y)) alone[y * _w + x] = true;
        for (var i = 0; i < left.Length; i++)
            if (alone[i]) left[i] = false;
        RemoveLongRuns(left);
        return Places(left);
    }

    private bool HasNeighbour(bool[] map, int x, int y) =>
        (x > 0 && map[y * _w + x - 1]) || (x + 1 < _w && map[y * _w + x + 1]) || (y > 0 && map[(y - 1) * _w + x]) || (y + 1 < _h && map[(y + 1) * _w + x]);

    /// <summary>Takes out straight runs of ink longer than any stroke of a character.</summary>
    private void RemoveLongRuns(bool[] map)
    {
        var limit = (int)(LongestStroke * _scale);
        var marks = new bool[map.Length];
        for (var y = 0; y < _h; y++)
        {
            var run = 0;
            for (var x = 0; x <= _w; x++)
            {
                if (x < _w && map[y * _w + x]) run++;
                else
                {
                    if (run >= limit) Array.Fill(marks, true, y * _w + x - run, run);
                    run = 0;
                }
            }
        }
        for (var x = 0; x < _w; x++)
        {
            var run = 0;
            for (var y = 0; y <= _h; y++)
            {
                if (y < _h && map[y * _w + x]) run++;
                else
                {
                    if (run >= limit)
                        for (var k = y - run; k < y; k++)
                            marks[k * _w + x] = true;
                    run = 0;
                }
            }
        }
        for (var i = 0; i < map.Length; i++)
            if (marks[i]) map[i] = false;
    }

    /// <summary>Ink close together as boxes (runs of each row joined across small gaps, touching the row above).</summary>
    private List<RectD> Places(bool[] map)
    {
        var join = Math.Max(1, (int)(JoinAcross * _scale));
        var parents = new List<int>();
        var boxes = new List<(int X0, int Y0, int X1, int Y1, int Ink)>();
        var above = new List<(int X0, int X1, int Id)>();
        int Root(int i)
        {
            while (parents[i] != i) i = parents[i] = parents[parents[i]];
            return i;
        }
        for (var y = 0; y < _h; y++)
        {
            var row = new List<(int X0, int X1, int Id)>();
            for (var x = 0; x < _w;)
            {
                if (!map[y * _w + x])
                {
                    x++;
                    continue;
                }
                var (start, end, ink) = (x, x, 0);
                for (var gap = 0; x < _w && gap <= join; x++)
                {
                    if (map[y * _w + x])
                    {
                        end = x;
                        gap = 0;
                        ink++;
                    }
                    else gap++;
                }
                var id = parents.Count;
                parents.Add(id);
                boxes.Add((start, y, end, y, ink));
                foreach (var a in above)
                {
                    if (a.X0 > end || a.X1 < start) continue;
                    var (r, s) = (Root(a.Id), Root(id));
                    if (r == s) continue;
                    parents[s] = r;
                    var (p, q) = (boxes[r], boxes[s]);
                    boxes[r] = (Math.Min(p.X0, q.X0), Math.Min(p.Y0, q.Y0), Math.Max(p.X1, q.X1), Math.Max(p.Y1, q.Y1), p.Ink + q.Ink);
                }
                row.Add((start, end, id));
            }
            above = row;
        }
        var places = new List<RectD>();
        for (var i = 0; i < parents.Count; i++)
        {
            if (Root(i) != i) continue;
            var (x0, y0, x1, y1, ink) = boxes[i];
            var (w, h) = ((x1 - x0 + 1) / _scale, (y1 - y0 + 1) / _scale);
            if (w < MinWidth || h < MinHeight || ink < 16) continue;
            places.Add(new RectD(x0 / _scale, y0 / _scale, w, h).Inflate(1));
        }
        return [.. places.OrderByDescending(p => p.Width * p.Height).Take(64)];
    }
}

public sealed partial class PdfEngine
{
    /// <summary>Where a page's pictures are, in page points (cut to the page).</summary>
    internal List<RectD> PictureBoxes(int page, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        EnterText(cancel);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var g = _pages[page];
            using var st = TextDoc(page).GetStructuredTextPage(page, includeAnnotations: true, StructuredTextFlags.PreserveImages);
            var whole = new RectD(0, 0, g.Width, g.Height);
            var boxes = new List<RectD>();
            foreach (var block in st)
            {
                if (block is not MuPDFImageStructuredTextBlock image) continue;
                var r = image.BoundingBox;
                var box = RectD.FromEdges(r.X0 - g.OriginX, r.Y0 - g.OriginY, r.X1 - g.OriginX, r.Y1 - g.OriginY).Intersect(whole);
                if (!box.IsEmpty) boxes.Add(box);
            }
            return boxes;
        }
        finally
        {
            _textGate.Exit();
        }
    }
}
