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
        var (scan, words) = Scans(ScanCorpus.TextPdf(file).Pdf, [0], lineBoxes, paper, angle);
        return (scan, words[0]);
    }

    /// <summary>
    /// <paramref name="pages"/> of a typeset PDF as a scan (grey JPEGs, or with <paramref name="color"/> flate-compressed RGB),
    /// each with an invisible text layer of its words boxed as a recognizer boxes them (see <see cref="Scan(CorpusFile, bool, int, double)"/>).
    /// </summary>
    internal static (byte[] Scan, List<List<OcrWord>> Words) Scans(byte[] typeset, IReadOnlyList<int> pages, bool lineBoxes = false, int paper = 255,
        double angle = 0, bool color = false)
    {
        using var engine = PdfEngine.Open(typeset, InputFileTypes.PDF, null);
        var jpegs = new List<(byte[] Jpeg, int Width, int Height)>();
        var rgbs = new List<(byte[] Rgb, int Width, int Height)>();
        var all = new List<List<OcrWord>>();
        foreach (var pageIndex in pages)
        {
            var image = engine.Render(pageIndex, Dpi / 72);
            var (w, h) = (image.Width, image.Height);
            var gray = new byte[w * h];
            var rgb = new byte[w * h * 3];
            for (var i = 0; i < gray.Length; i++)
            {
                for (var c = 0; c < 3; c++) rgb[3 * i + c] = (byte)(30 + (paper - 30) * image.Pixels[3 * i + 2 - c] / 255);
                var ink = (image.Pixels[3 * i] * 29 + image.Pixels[3 * i + 1] * 150 + image.Pixels[3 * i + 2] * 77) >> 8;
                gray[i] = (byte)(30 + (paper - 30) * ink / 255);
            }
            if (color) rgbs.Add((rgb, w, h));
            else jpegs.Add((JpegEncoder.EncodeGray(gray, w, h, 90, (int)Dpi), w, h));

            // Each word as a recognizer boxes it.
            var text = engine.GetText(pageIndex);
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
            all.Add(words);
        }
        var scan = color ? RgbPdf(rgbs) : ScanCorpus.ScanPdf(ScanCorpus.Files[0], jpegs);
        return (TextLayer.AddInvisibleText(scan, null, all.Select((w, i) => (w, i)).ToDictionary(x => x.i, x => (IReadOnlyList<OcrWord>)x.w), "en-US"), all);
    }

    /// <summary>RGB pages at 300 dpi, one image filling each.</summary>
    private static byte[] RgbPdf(List<(byte[] Rgb, int Width, int Height)> pages)
    {
        using var ms = new MemoryStream();
        var w = new InkvoltPdf.Bench.PdfFileWriter(ms);
        var parent = w.Reserve();
        var kids = new List<int>();
        foreach (var (rgb, width, height) in pages)
        {
            var (pw, ph) = (width * 72.0 / Dpi, height * 72.0 / Dpi);
            var image = w.AddStream($"/Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceRGB /BitsPerComponent 8", rgb);
            var content = w.AddStream("", System.Text.Encoding.ASCII.GetBytes(string.Create(System.Globalization.CultureInfo.InvariantCulture, $"q {pw:0.##} 0 0 {ph:0.##} 0 0 cm /Im0 Do Q")));
            kids.Add(w.Add(string.Create(System.Globalization.CultureInfo.InvariantCulture,
                $"<< /Type /Page /Parent {parent} 0 R /MediaBox [0 0 {pw:0.##} {ph:0.##}] /Resources << /XObject << /Im0 {image} 0 R >> >> /Contents {content} 0 R >>")));
        }
        w.Put(parent, $"<< /Type /Pages /Kids [{string.Join(' ', kids.Select(k => $"{k} 0 R"))}] /Count {kids.Count} >>");
        var catalog = w.Add($"<< /Type /Catalog /Pages {parent} 0 R >>");
        w.Finish(catalog, w.Add("<< /Producer (Inkvolt PDF tests) >>"), new string('0', 32));
        return ms.ToArray();
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

    /// <summary>A typeset page of four paragraphs: Times, Times italic, Times again, and Times in dark blue; each four lines of 12 pt on 17.</summary>
    internal static byte[] LooksPdf()
    {
        var rng = new InkvoltPdf.Bench.Rng(5);
        var words = Enumerable.Range(0, 200).Select(_ => InkvoltPdf.Bench.Prose.Word(ref rng)).ToArray();
        var ops = new System.Text.StringBuilder();
        var y = 720.0;
        var n = 0;
        foreach (var (font, color) in new[] { ("/F1", "0 g"), ("/F2", "0 g"), ("/F1", "0 g"), ("/F1", "0.05 0.1 0.6 rg") })
        {
            for (var line = 0; line < 4; line++, y -= 17)
                ops.Append(System.Globalization.CultureInfo.InvariantCulture,
                    $"BT {color} {font} 12 Tf 72 {y} Td ({string.Join(' ', Enumerable.Range(0, 8).Select(_ => words[n++ % words.Length]))}) Tj ET\n");
            y -= 12;
        }
        return Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >> /F2 << /Type /Font /Subtype /Type1 /BaseFont /Times-Italic >> >> >> >>",
            Core2Pdf.Stream(ops.ToString()),
        ]);
    }

    [Fact]
    public void AnItalicParagraphIsItalicAndAColouredOneKeepsItsColour()
    {
        var (scan, _) = Scans(LooksPdf(), [0], color: true);
        var made = EditableText.Make(scan, null, [0], keepScan: false);
        Assert.True(made.Fonts.Order().SequenceEqual(new[] { "Times New Roman", "Times New Roman Italic" }.Order()), string.Join(", ", made.Fonts) + " | " +
            string.Join(" | ", ContentEditor.Read(made.Data, null, 0).Runs.Select(r => $"{r.FontName} {r.FontSize:0.#} {r.Box.Y:0}: {r.Text[..Math.Min(20, r.Text.Length)]}")));
        var content = ContentEditor.Read(made.Data, null, 0);
        var paragraphs = content.Paragraphs.OrderBy(p => p.Box.Y).ToList();
        Assert.Equal(4, paragraphs.Count);
        Assert.All(paragraphs, p => Assert.Equal(4, p.Lines.Count));
        Assert.All(paragraphs[0].Runs.Concat(paragraphs[2].Runs), r => Assert.False(r.Italic));
        Assert.All(paragraphs[1].Runs, r => Assert.Contains("Italic", r.FontName));
        Assert.All(paragraphs.Take(3).SelectMany(p => p.Runs), r => Assert.Equal(0, r.Color));
        // The blue paragraph: blue, near the typeset 0.05 0.1 0.6 as the scan shows it.
        Assert.All(paragraphs[3].Runs, r =>
        {
            var (red, green, blue) = (r.Color >> 16 & 255, r.Color >> 8 & 255, r.Color & 255);
            Assert.True(blue > 100 && red < 60 && green < 80, $"{red},{green},{blue}");
        });
    }

    [Fact]
    public void MakingPagesEditableTakesUnderASecondAPage()
    {
        // Two corpus pages: the first chooses among the installed families, the second compares the short list.
        var (typeset, _) = ScanCorpus.TextPdf(Times);
        var (scan, words) = Scans(typeset, [0, 1]);
        EditableText.Make(scan, null, [0], keepScan: false); // fonts loaded once for the run, as in the app after its first use
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var made = EditableText.Make(scan, null, [0, 1], keepScan: false);
        var perPage = watch.Elapsed.TotalSeconds / 2;
        Assert.Equal((2, words.Sum(w => w.Count)), (made.Pages, made.Words));
        // Measured on a Release build (an ARM64 laptop, other work running): 0.58 s a page, 0.6 s for a first page that also
        // loads the candidate fonts. A Debug build runs the comparisons several times slower: only a gross slip fails it.
#if DEBUG
        const double limit = 10;
#else
        const double limit = 1;
#endif
        Assert.True(perPage < limit, $"{perPage:0.00} s a page");
    }

    [Fact]
    public void WordsOnBothSidesOfHalfATurnAreOneLine()
    {
        // An upside-down page read through a warp: its words' angles straddle ±180°.
        OcrWord[] words =
        [
            new("upside", new RectD(400, 300, 40, 10), 179.9),
            new("down", new RectD(361, 300.1, 34, 10), -179.9),
            new("line", new RectD(330, 300.2, 26, 10), 179.95),
        ];
        var group = Assert.Single(EditableText.ByAngle([.. words]));
        Assert.InRange(Math.Abs(Angles.Difference(group.Angle, 180)), 0, 0.5);
        var line = Assert.Single(EditableText.Plan(words)!.Lines);
        Assert.Equal(["upside", "down", "line"], line.Words.Select(w => w.Text));

        // The invisible layer spaces them as one line too.
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.Stream("0.9 g 0 0 10 10 re f"),
        ]);
        var data = TextLayer.AddInvisibleText(scan, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = words });
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        Assert.Contains("upside down line", engine.GetText(0).Text);
    }

    /// <summary>Reads the topmost line of ink as four words, quarters of its width.</summary>
    private sealed class QuarterReader : InkvoltPrint.Core.Imaging.ITextRecognizer
    {
        public string Language => "en-US";
        public string LanguageName => "English";

        public IReadOnlyList<InkvoltPrint.Core.Imaging.RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            var gray = channels == 1 ? pixels : InkvoltPrint.Core.Imaging.ScanCleanup.ToGray(pixels, width, height);
            int Ink(int y) => Enumerable.Range(0, width).Count(x => gray[y * width + x] < 128);
            var top = Enumerable.Range(0, height).First(y => Ink(y) > 3);
            var bottom = top;
            while (bottom + 1 < height && Ink(bottom + 1) > 0) bottom++;
            var xs = Enumerable.Range(top, bottom - top + 1).SelectMany(y => Enumerable.Range(0, width).Where(x => gray[y * width + x] < 128)).ToList();
            var (left, w) = (xs.Min(), (xs.Max() - xs.Min() + 1) / 4.0);
            return [.. Enumerable.Range(0, 4).Select(i => new InkvoltPrint.Core.Imaging.RecognizedWord($"word{i}", (int)(left + i * w), top, (int)(w * 0.9), bottom - top + 1, i))];
        }
    }

    [Fact]
    public void AnUpsideDownBentPageReadsAsOneLineAtHalfATurn()
    {
        // A book's page photographed upside down: flattened, turned over, and its top line's words, mapped back, are near 180°.
        var (px, w, h, _) = PhotoCorpus.Photo(PhotoCorpus.Files.Single(f => f.Name == "en-book"));
        var turned = InkvoltPrint.Core.Imaging.ScanCleanup.Turn(px, w, h, 1, 2);
        var pdf = ScanCorpus.ScanPdf(ScanCorpus.Files[0], [(JpegEncoder.EncodeGray(turned, w, h, 85, 300), w, h)]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var read = ScanText.Recognize(engine, 0, new QuarterReader(), new RecognizeOptions(CheckWords: false, RereadMissed: false, CurvedLines: true));
        Assert.Equal(2, read.QuarterTurns);
        Assert.All(read.Words, x => Assert.InRange(Math.Abs(Angles.Difference(x.Angle, 180)), 0, 10));
        var line = Assert.Single(EditableText.Plan(read.Words)!.Lines);
        Assert.Equal(4, line.Words.Count);
    }
}
