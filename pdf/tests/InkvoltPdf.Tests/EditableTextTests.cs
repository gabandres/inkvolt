using JpegEncoder = InkvoltPdf.Bench.JpegEncoder;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Make Text Editable (roadmap 2.2, for 2.1): a scan's recognized words become real text in the installed font closest to
/// the scan's, at their size and place, the scan covered behind them, so a paragraph can be edited. The scans are corpus
/// pages typeset in a known font (<see cref="ScanCorpus"/>), their words boxed as a recognizer boxes them (each word's own
/// ink, as Windows' and Tesseract's are, or its line's height).
/// </summary>
public class EditableTextTests
{
    private const double Dpi = 300;

    /// <summary>
    /// A corpus page as a scan (its typeset text rendered at 300 dpi on paper of <paramref name="paper"/>, as a JPEG) with an
    /// invisible text layer of its words, boxed around each word's ink (or, <paramref name="lineBoxes"/>, its line's
    /// height); and the words, in order, with where the typeset page has them.
    /// </summary>
    internal static (byte[] Scan, List<OcrWord> Words) Scan(CorpusFile file, bool lineBoxes = false, int paper = 255, double angle = 0)
    {
        var (typeset, _) = ScanCorpus.TextPdf(file);
        using var engine = PdfEngine.Open(typeset, InputFileTypes.PDF, null);
        var image = engine.Render(0, Dpi / 72);
        var (w, h) = (image.Width, image.Height);
        var gray = new byte[w * h];
        for (var i = 0; i < gray.Length; i++)
        {
            var ink = (image.Pixels[3 * i] * 29 + image.Pixels[3 * i + 1] * 150 + image.Pixels[3 * i + 2] * 77) >> 8;
            gray[i] = (byte)(30 + (paper - 30) * ink / 255);
        }
        var scan = ScanCorpus.ScanPdf(file, [(JpegEncoder.EncodeGray(gray, w, h, 90, (int)Dpi), w, h)]);

        // Each word as a recognizer boxes it.
        var text = engine.GetText(0);
        var found = new List<(string Text, RectD Em, RectD Ink)>();
        var s = text.Text;
        for (var i = 0; i < s.Length;)
        {
            if (char.IsWhiteSpace(s[i]))
            {
                i++;
                continue;
            }
            var start = i;
            while (i < s.Length && !char.IsWhiteSpace(s[i])) i++;
            var em = text.GetRects(start, i).Aggregate((a, b) => a.Union(b));
            // Its own ink: the dark pixels inside the box the text has.
            var (x0, y0, x1, y1) = ((int)(em.X * Dpi / 72), (int)(em.Y * Dpi / 72), (int)Math.Ceiling(em.Right * Dpi / 72), (int)Math.Ceiling(em.Bottom * Dpi / 72));
            int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
            for (var y = Math.Max(0, y0); y < Math.Min(h, y1); y++)
                for (var x = Math.Max(0, x0); x < Math.Min(w, x1); x++)
                    if (gray[y * w + x] < 128) (minX, minY, maxX, maxY) = (Math.Min(minX, x), Math.Min(minY, y), Math.Max(maxX, x), Math.Max(maxY, y));
            if (maxX < 0) continue;
            found.Add((s[start..i], em, new RectD(minX * 72 / Dpi, minY * 72 / Dpi, (maxX - minX + 1) * 72 / Dpi, (maxY - minY + 1) * 72 / Dpi)));
        }
        var words = new List<OcrWord>();
        foreach (var (word, em, ink) in found)
        {
            var box = ink;
            if (lineBoxes)
            {
                // Its line's height: from the highest ink on its line to the lowest.
                var line = found.Where(f => Math.Abs(f.Em.CenterY - em.CenterY) < 1).ToList();
                var (top, bottom) = (line.Min(f => f.Ink.Y), line.Max(f => f.Ink.Bottom));
                box = new RectD(ink.X, top, ink.Width, bottom - top);
            }
            if (angle != 0)
            {
                // A skewed scan's word: its centre turned with the page about the page's middle.
                var (sin, cos) = Math.SinCos(angle * Math.PI / 180);
                var (dx, dy) = (box.CenterX - 306, box.CenterY - 396);
                var (cx, cy) = (306 + dx * cos - dy * sin, 396 + dx * sin + dy * cos);
                box = new RectD(cx - box.Width / 2, cy - box.Height / 2, box.Width, box.Height);
            }
            words.Add(new OcrWord(word, box, angle));
        }
        return (TextLayer.AddInvisibleText(scan, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = words }, "en-US"), words);
    }

    private static CorpusFile Times => ScanCorpus.Files.Single(f => f.Name == "en-skew3-light"); // Times-Roman 11 pt

    private static CorpusFile Helvetica => ScanCorpus.Files.Single(f => f.Name == "en-skew6-noisy"); // Helvetica 10 pt

    private static List<string> WordsOf(byte[] data)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        return [.. engine.GetText(0).Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)];
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RecognizedWordsBecomeTextInTheFontTheyWereSetIn(bool lineBoxes)
    {
        foreach (var (file, family, size) in new[] { (Times, "Times New Roman", 11.0), (Helvetica, "Arial", 10.0) })
        {
            var (scan, words) = Scan(file, lineBoxes);
            Assert.Equal([0], EditableText.Pages(scan, null));
            var made = EditableText.Make(scan, null, [0], keepScan: false);
            Assert.Equal((1, words.Count), (made.Pages, made.Words));
            // The body in its family (Helvetica's shapes are Arial's), the Helvetica-Bold heading in Arial's bold face: picked
            // by how the words look set in each installed face where the scan has them.
            Assert.True(new[] { family, "Arial Bold" }.Order().SequenceEqual(made.Fonts.Order()), $"{file.Name}: {string.Join(", ", made.Fonts)}");

            // The words read back in order, once each: the invisible layer is gone.
            Assert.Equal(words.Select(w => w.Text), WordsOf(made.Data));
            Assert.Empty(TextLayer.Words(made.Data, null));
            Assert.Empty(EditableText.Pages(made.Data, null));

            // At the size and place the scan has them.
            var content = ContentEditor.Read(made.Data, null, 0);
            var body = content.Runs.Where(r => r.FontSize < 14).ToList();
            Assert.All(body, r => Assert.Equal(size, r.FontSize, lineBoxes ? 0.5 : 0.35));
            using var engine = PdfEngine.Open(made.Data, InputFileTypes.PDF, null);
            var text = engine.GetText(0);
            var off = 0.0;
            foreach (var word in words.Where(w => w.Text.Length >= 5).Take(60))
            {
                var hit = text.Find(word.Text, true, false).Select(f => text.GetRects(f.Start, f.End).Aggregate((a, b) => a.Union(b)))
                    .MinBy(r => Math.Abs(r.CenterY - word.Rect.CenterY) + Math.Abs(r.X - word.Rect.X));
                off = Math.Max(off, Math.Abs(hit.X - word.Rect.X));
                Assert.InRange(hit.CenterY, word.Rect.Y - 2, word.Rect.Bottom + 2);
            }
            Assert.True(off < 1.5, $"{file.Name}: a word starts {off:0.00} pt from the scan's");
        }
    }

    [Fact]
    public void ItsParagraphsCanBeEditedAsParagraphs()
    {
        var (scan, _) = Scan(Times);
        var made = EditableText.Make(scan, null, [0], keepScan: false).Data;
        var content = ContentEditor.Read(made, null, 0);
        // The typeset page's paragraphs: lines of one font, size, step and left edge, joined as 2.1 joins them.
        var paragraphs = content.Paragraphs.Where(p => p.Lines.Count >= 2).ToList();
        Assert.True(paragraphs.Count >= 3, $"{paragraphs.Count} paragraphs of two lines or more");
        Assert.All(paragraphs, p => Assert.Null(p.Blocked));
        var lines = content.Paragraphs.Sum(p => p.Lines.Count);
        Assert.True(paragraphs.Sum(p => p.Lines.Count) >= 0.8 * lines, "most lines are in paragraphs");

        var first = paragraphs.OrderBy(p => p.Box.Y).First();
        var edited = ContentEditor.ReplaceParagraph(made, null, first, first.Text + " Seven added words keep their paragraph here.", allowOverlap: true);
        var words = string.Join(' ', WordsOf(edited));
        Assert.Contains("Seven added words keep their paragraph here.", words);
        Assert.Contains(first.Text.Split(' ')[^1], words);
    }

    [Fact]
    public void TheScanIsCoveredBehindTheTextInThePapersColourOrKept()
    {
        var (scan, words) = Scan(Times, paper: 205);
        var covered = EditableText.Make(scan, null, [0], keepScan: false).Data;
        var kept = EditableText.Make(scan, null, [0], keepScan: true).Data;

        // Between two words of a line, at their middle height: the paper's grey where the scan is covered, never white.
        var pair = words.Zip(words.Skip(1)).First(p => p.First.Text.Length > 3 && Math.Abs(p.First.Rect.CenterY - p.Second.Rect.CenterY) < 1 && p.Second.Rect.X - p.First.Rect.Right > 2);
        var space = pair.Second.Rect.X - pair.First.Rect.Right;
        var gap = new RectD(pair.First.Rect.Right + 0.3 * space, pair.First.Rect.CenterY - 0.5, 0.4 * space, 1);
        Assert.InRange(Gray(covered, gap), 190, 220);

        // Under a word, what shows is the new text alone where the scan is covered; kept, the scan's ink shows too.
        Assert.True(Darkness(kept, pair.First.Rect) >= Darkness(covered, pair.First.Rect));
        Assert.True(Core2Pdf.Ink(covered, 0, pair.First.Rect) > 0.05);
    }

    private static double Gray(byte[] data, RectD region)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var img = engine.Render(0, 4, region);
        double sum = 0;
        for (var i = 0; i + 2 < img.Pixels.Length; i += 3) sum += (img.Pixels[i] + img.Pixels[i + 1] + img.Pixels[i + 2]) / 3.0;
        return sum / (img.Pixels.Length / 3);
    }

    private static double Darkness(byte[] data, RectD region) => 255 - Gray(data, region);

    [Fact]
    public void WordsOnASkewedScanBecomeTextAtTheirAngle()
    {
        // A scan recognized without replacing it: its words carry its skew.
        var (scan, words) = Scan(Times, angle: 3);
        var made = EditableText.Make(scan, null, [0], keepScan: false);
        Assert.Equal(words.Select(w => w.Text), WordsOf(made.Data));
        var content = ContentEditor.Read(made.Data, null, 0);
        Assert.All(content.Runs.Where(r => r.Text.Trim().Length > 0), r => Assert.Equal(3, r.Angle, 0.1));
        Assert.Contains(content.Paragraphs, p => p.Lines.Count >= 2 && p.Blocked is null && Math.Abs(p.Angle - 3) < 0.1);
    }

    [Fact]
    public void OnlyThePagesAskedForAndWithRecognizedTextChange()
    {
        var (scan, words) = Scan(Times);
        // A second page, a copy without a text layer.
        var two = PageEditor.InsertBlank(scan, null, 1, 1, 612, 792);
        var made = EditableText.Make(two, null, [1, 5, -1], keepScan: false);
        Assert.Equal(0, made.Pages);
        Assert.Same(two, made.Data);
        made = EditableText.Make(two, null, [0, 1], keepScan: false);
        Assert.Equal((1, words.Count), (made.Pages, made.Words));
    }

    [Fact]
    public void WordsNoPageHasAreLeftOut()
    {
        OcrWord[] words =
        [
            new("ok", new RectD(72, 100, 12, 8)),
            new(new string('x', EditableText.MaxWordLength + 1), new RectD(90, 100, 400, 8)),
            new("flat", new RectD(72, 120, 20, 0)),
            new("   ", new RectD(72, 140, 20, 8)),
        ];
        var plan = EditableText.Plan(words)!;
        Assert.Equal("ok", Assert.Single(Assert.Single(plan.Lines).Words).Text);
        Assert.Null(EditableText.Plan([]));
        // Many thousands: only so many are made text.
        var many = Enumerable.Range(0, EditableText.MaxWords + 50).Select(i => new OcrWord("w" + i, new RectD(72 + i % 40 * 12, 20 + i / 40 * 0.5, 10, 8))).ToList();
        Assert.Equal(EditableText.MaxWords, EditableText.Plan(many)!.Lines.Sum(l => l.Words.Count));
    }
}
