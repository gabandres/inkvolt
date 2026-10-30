using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Recognize Text's pipeline without Windows' engine (roadmap 2.2): a stand-in recognizer "reads" the first line of ink
/// of the image it is given, so the tests see what the engine would be handed (straight, upright, cleaned) and where its
/// words land on the page.
/// </summary>
public class ScanTextTests
{
    /// <summary>Returns one word, "Heading", boxed around the topmost line of ink; keeps the image it was given.</summary>
    private sealed class FirstLineReader : ITextRecognizer
    {
        public GrayImage? Seen { get; private set; }
        public int Calls { get; private set; }
        public string Language => "en-US";
        public string LanguageName => "English";

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            Calls++;
            var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
            Seen = new GrayImage(width, height, gray);
            int Ink(int y) => Enumerable.Range(0, width).Count(x => gray[y * width + x] < 128);
            var top = Enumerable.Range(0, height).First(y => Ink(y) > 3);
            var bottom = top;
            while (bottom + 1 < height && Ink(bottom + 1) > 0) bottom++;
            var xs = Enumerable.Range(top, bottom - top + 1).SelectMany(y => Enumerable.Range(0, width).Where(x => gray[y * width + x] < 128)).ToList();
            return [new RecognizedWord("Heading", xs.Min(), top, xs.Max() - xs.Min() + 1, bottom - top + 1, 0)];
        }
    }

    private static byte[] TurnedScan() => ScanCorpus.Make(ScanCorpus.Files.Single(f => f.Name == "en-turned") with { Pages = 1 }).Pdf;

    [Theory]
    [InlineData(0, 0)]
    [InlineData(7.5, 0)]
    [InlineData(-12, 1)]
    [InlineData(3, 2)]
    [InlineData(-4, 3)]
    public void APointOfTheCleanedImageMapsBackToTheScan(double skew, int turns)
    {
        const int w = 400, h = 300;
        var px = Enumerable.Repeat((byte)255, w * h).ToArray();
        for (var y = 70; y < 76; y++)
            for (var x = 120; x < 126; x++)
                px[y * w + x] = 0; // a dot centred on (123, 73)
        var straight = PageRotate.Rotate(px, w, h, w, 1, -skew);
        var cleaned = ScanCleanup.Turn(straight, w, h, 1, turns);
        var (cw, ch) = turns % 2 == 0 ? (w, h) : (h, w);
        var dark = Enumerable.Range(0, cw * ch).Where(i => cleaned[i] < 128).ToList();
        var (dx, dy) = (dark.Average(i => i % cw) + 0.5, dark.Average(i => i / cw) + 0.5);

        var (x0, y0) = new ScanFrame(w, h, skew, turns).ToRendered(dx, dy);
        Assert.Equal(123, x0, 1.0);
        Assert.Equal(73, y0, 1.0);
    }

    [Fact]
    public void AnUpsideDownSkewedScanIsReadUprightAndItsWordsLandWhereTheyAre()
    {
        var scan = TurnedScan();
        using var pdf = PdfEngine.Open(scan, InputFileTypes.PDF, null);
        var reader = new FirstLineReader();
        var page = ScanText.Recognize(pdf, 0, reader, new RecognizeOptions(CheckWords: false));

        Assert.Equal(2, page.QuarterTurns);
        Assert.Equal(3.1, page.Skew, 0.3);
        Assert.Null(page.Cleaned);
        // What the engine was given: straight, upright, white paper.
        var seen = reader.Seen!;
        Assert.Equal(0, ScanCleanup.SkewOf(seen, 300), 0.3);
        Assert.False(Upright.UpsideDown(ScanCleanup.Downscale(seen, 3)).UpsideDown);
        Assert.Equal(255, GrayImage.Median(seen, 0, 0, seen.Width, seen.Height));

        // The heading is at the top left of the page as written, so at the bottom right of the upside-down scan, upside down.
        var word = Assert.Single(page.Words);
        Assert.InRange(word.Rect.CenterX, 306, 612);
        Assert.InRange(word.Rect.CenterY, 600, 792);
        Assert.Equal(-176.9, word.Angle, 0.3);
        Assert.InRange(word.Rect.Height, 10, 22); // 16 pt Helvetica-Bold
    }

    [Fact]
    public void ThePageAsScannedIsReadAsToday()
    {
        using var pdf = PdfEngine.Open(TurnedScan(), InputFileTypes.PDF, null);
        var reader = new FirstLineReader();
        var page = ScanText.Recognize(pdf, 0, reader, RecognizeOptions.AsScanned);
        Assert.Equal(1, reader.Calls);
        Assert.Equal((0, 0.0), (page.QuarterTurns, page.Skew));
        Assert.Equal(0, Assert.Single(page.Words).Angle);
        Assert.Equal((2550, 3300), (reader.Seen!.Width, reader.Seen.Height)); // 300 dpi, as rendered
    }

    [Fact]
    public void TheCleanedPageCanReplaceTheScanAndTheWordsFitIt()
    {
        var scan = TurnedScan();
        RecognizedPage page;
        using (var pdf = PdfEngine.Open(scan, InputFileTypes.PDF, null))
            page = ScanText.Recognize(pdf, 0, new FirstLineReader(), new RecognizeOptions(CheckWords: false, KeepCleanedImage: true));
        var cleaned = Assert.IsType<CleanedPageImage>(page.Cleaned);
        Assert.Equal((2, 1), (cleaned.QuarterTurns, cleaned.Channels)); // a grey scan stays grey
        var word = Assert.Single(page.Words);
        Assert.Equal(0, word.Angle);
        Assert.InRange(word.Rect.CenterY, 40, 100); // on the page as it will be: upright, the heading at the top
        Assert.InRange(word.Rect.X, 60, 85);

        var data = ScanPage.WriteBack(scan, null, new Dictionary<int, CleanedPageImage> { [0] = cleaned });
        data = TextLayer.AddInvisibleText(data, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = page.Words });
        using var after = PdfEngine.Open(data, InputFileTypes.PDF, null);
        Assert.Equal(612, after.GetPage(0).Width, 1.0);
        var text = after.GetText(0);
        var (s, e) = text.Find("Heading", true, false).Single();
        var box = text.GetRects(s, e).Aggregate(default(RectD), (a, r) => a.Union(r));
        Assert.Equal(word.Rect.CenterX, box.CenterX, 3.0);
        Assert.Equal(word.Rect.CenterY, box.CenterY, 3.0);
        // Upright now: the heading's ink is at the top left, and the paper is white.
        Assert.True(Core2Pdf.Ink(data, 0, word.Rect) > 0.05);
        Assert.True(Core2Pdf.Ink(data, 0, new RectD(72, 700, 200, 40)) < Core2Pdf.Ink(data, 0, word.Rect));
    }

    [Fact]
    public void ACleanedPageIsHeldCompressedAsItWillBeWritten()
    {
        // Replace the scans holds every page until it writes them: raw, a 500-page Letter colour scan was about 12.6 GB.
        RecognizedPage page;
        using (var pdf = PdfEngine.Open(TurnedScan(), InputFileTypes.PDF, null))
            page = ScanText.Recognize(pdf, 0, new FirstLineReader(), new RecognizeOptions(CheckWords: false, KeepCleanedImage: true));
        var cleaned = page.Cleaned!;
        var raw = (long)cleaned.Width * cleaned.Height * cleaned.Channels;
        Assert.InRange(cleaned.Deflated.LongLength, 1, raw / 4);
    }

    [Fact]
    public void AColourPageWrittenBackKeepsItsColours()
    {
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>",
            Core2Pdf.Stream("BT /F1 24 Tf 72 700 Td (Heading) Tj ET 0.85 0.1 0.1 rg 72 300 200 150 re f 0.1 0.2 0.85 rg 320 300 200 150 re f"),
        ]);
        RecognizedPage page;
        using (var pdf = PdfEngine.Open(scan, InputFileTypes.PDF, null))
            page = ScanText.Recognize(pdf, 0, new FirstLineReader(), new RecognizeOptions(CheckWords: false, KeepCleanedImage: true));
        Assert.Equal(3, page.Cleaned!.Channels);
        var data = ScanPage.WriteBack(scan, null, new Dictionary<int, CleanedPageImage> { [0] = page.Cleaned });
        using var after = PdfEngine.Open(data, InputFileTypes.PDF, null);
        // So few lines may not say which way up: a page set upside down shows the boxes swapped round.
        var flipped = page.Cleaned.QuarterTurns == 2;
        (int R, int G, int B) At(double x, double y)
        {
            var px = after.Render(0, 1, flipped ? new RectD(612 - x - 4, 792 - y - 4, 4, 4) : new RectD(x, y, 4, 4)).Pixels; // BGR
            return (px[2], px[1], px[0]);
        }
        var red = At(170, 410);
        var blue = At(420, 410);
        Assert.True(red.R > 150 && red.B < 100, $"red came out {red}");
        Assert.True(blue.B > 150 && blue.R < 100, $"blue came out {blue}");
    }

    [Fact]
    public void TurnedWordsAreFoundWhereTheyWereRead()
    {
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.Stream("0.9 g 0 0 10 10 re f"),
        ]);
        OcrWord[] words =
        [
            new("Straight", new RectD(100, 100, 90, 20), 6),
            new("ahead", new RectD(200, 111, 60, 20), 6),
            new("Upside", new RectD(300, 400, 80, 20), -174),
        ];
        var data = TextLayer.AddInvisibleText(scan, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = words });
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        Assert.Contains("Straight ahead", text.Text); // the space between words on a skewed line
        foreach (var w in words)
        {
            var (s, e) = text.Find(w.Text, true, false).Single();
            var box = text.GetRects(s, e).Aggregate(default(RectD), (a, r) => a.Union(r));
            Assert.Equal(w.Rect.CenterX, box.CenterX, 3.0);
            Assert.Equal(w.Rect.CenterY, box.CenterY, 3.0);
        }
    }

    [Fact]
    public void ACorrectedWordIsFoundBySearchAndTheLayerIsReplacedInPlace()
    {
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.Stream("0.9 g 0 0 10 10 re f"),
        ]);
        OcrWord[] words =
        [
            new("The", new RectD(72, 100, 30, 14), 2.5),
            new("rlver", new RectD(106, 101, 40, 14), 2.5, SuspectReasons.NotInDictionary | SuspectReasons.ReadDifferently),
            new("año", new RectD(150, 102, 30, 14), 2.5, SuspectReasons.LettersAndDigits),
        ];
        var data = TextLayer.AddInvisibleText(scan, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = words }, "es-MX");
        var read = TextLayer.Words(data, null);
        Assert.Equal(words, read[0].Words); // the words, boxes, angles and suspect reasons come back as written
        Assert.Equal("es-MX", read[0].Language);

        var corrected = TextLayer.Correct(data, null, 0, 1, "river");
        corrected = TextLayer.Keep(corrected, null, 0, 2);
        Assert.Equal(["The", "river", "año"], TextLayer.Words(corrected, null)[0].Words.Select(w => w.Text));
        Assert.All(TextLayer.Words(corrected, null)[0].Words, w => Assert.Equal(SuspectReasons.None, w.Suspect));
        Assert.Equal("es-MX", TextLayer.Words(corrected, null)[0].Language);
        using var engine = PdfEngine.Open(corrected, InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        Assert.Single(text.Find("river", true, false));
        Assert.Empty(text.Find("rlver", true, false));
        Assert.Contains("The river año", text.Text);

        // One layer, not two: the page's content list and fonts don't grow with each correction.
        using var before = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(data), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        using var now = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(corrected), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        Assert.Equal(Contents(before.Pages[0]), Contents(now.Pages[0]));
        Assert.Equal(Fonts(before.Pages[0]), Fonts(now.Pages[0]));

        static int Contents(PdfSharp.Pdf.PdfPage p) => (PdfObj.Resolve(p.Elements["/Contents"]) as PdfSharp.Pdf.PdfArray)?.Elements.Count ?? 1;
        static int Fonts(PdfSharp.Pdf.PdfPage p) => PdfObj.Dict(PdfObj.Dict(p.Elements["/Resources"])!.Elements["/Font"])!.Elements.Count;
    }

    public static TheoryData<string, double, double, double, double, double> PageChanges => new()
    {
        // what is done, then where "hello" (72,100 100x20 on Letter) is: its centre, size and angle
        { "nothing", 122, 110, 100, 20, 0 },
        { "rotate 90", 682, 122, 100, 20, 90 },
        { "rotate 270", 110, 490, 100, 20, -90 },
        { "crop", 72, 60, 100, 20, 0 },
        { "crop, rotate 180", 470, 662, 100, 20, 180 },
    };

    [Theory]
    [MemberData(nameof(PageChanges))]
    public void WordsStayOnTheirTextWhenThePageIsTurnedOrCropped(string change, double cx, double cy, double w, double h, double angle)
    {
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.Stream("0.9 g 0 0 10 10 re f"),
        ]);
        OcrWord[] words = [new("hello", new RectD(72, 100, 100, 20)), new("wrld", new RectD(176, 100, 60, 20), 0, SuspectReasons.NotInDictionary)];
        var data = TextLayer.AddInvisibleText(scan, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = words }, "en-US");
        if (change.Contains("crop")) data = PageEditor.Crop(data, null, [0], new Margins(50, 50, 20, 20));
        if (change.Contains("rotate")) data = PageEditor.Rotate(data, null, [0], int.Parse(change[^3..]));

        void AssertHello(byte[] pdf)
        {
            var hello = TextLayer.Words(pdf, null)[0].Words[0];
            Assert.Equal(cx, hello.Rect.CenterX, 1);
            Assert.Equal(cy, hello.Rect.CenterY, 1);
            Assert.Equal(w, hello.Rect.Width, 1);
            Assert.Equal(h, hello.Rect.Height, 1);
            Assert.Equal(angle, hello.Angle, 1);
            // Where search finds it: the invisible text written over the word.
            using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
            var text = engine.GetText(0);
            var (start, end) = Assert.Single(text.Find("hello", true, false));
            var found = text.GetRects(start, end).Aggregate((a, b) => a.Union(b));
            Assert.Equal(cx, found.CenterX, 0);
            Assert.Equal(cy, found.CenterY, 0);
        }
        AssertHello(data);
        AssertHello(TextLayer.Keep(data, null, 0, 1));
        AssertHello(TextLayer.Correct(data, null, 0, 1, "world"));
    }

    [Fact]
    public void ALayerWrittenWithoutItsFrameIsReadInThePagesFrameNow()
    {
        // As the first 2.2 builds wrote it: no "%f" line. A page not turned or cropped since reads as it always did.
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.Stream("0.9 g 0 0 10 10 re f"),
        ]);
        OcrWord[] words = [new("hello", new RectD(72, 100, 100, 20), 1.5), new("wrld", new RectD(176, 100, 60, 20), 1.5, SuspectReasons.NotInDictionary)];
        var data = TextLayer.AddInvisibleText(scan, null, new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = words });
        using (var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(data), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify))
        {
            var layer = ((PdfSharp.Pdf.PdfArray)PdfObj.Resolve(doc.Pages[0].Elements["/Contents"])!).Elements.Select(PdfObj.Dict).First(d => PdfObj.StreamBytes(d!).AsSpan().StartsWith("%InkvoltOCR"u8))!;
            var lines = System.Text.Encoding.ASCII.GetString(PdfObj.StreamBytes(layer)).Split('\n');
            Assert.Single(lines, l => l.StartsWith("%f ", StringComparison.Ordinal));
            PdfObj.SetStream(layer, System.Text.Encoding.ASCII.GetBytes(string.Join('\n', lines.Where(l => !l.StartsWith("%f ", StringComparison.Ordinal)))));
            data = PdfObj.Save(doc);
        }
        Assert.Equal(words, TextLayer.Words(data, null)[0].Words);
        Assert.Equal(words[0], TextLayer.Words(TextLayer.Keep(data, null, 0, 1), null)[0].Words[0]);
    }

    [Fact]
    public void WordsWithBoxesNoPageHasAreLeftOut()
    {
        // A crafted layer: what the suspect words' list, pictures and Flash are given is only boxes a page can have.
        string[] hostile =
        [
            "%w 1 NaN 100 50 20 0 414243", "%w 1 1e300 1e300 1e300 1e300 0 414243", "%w 1 72 100 50 20 Infinity 414243",
            "%w 99999999999 72 100 50 20 0 414243", "%w 1 72 -Infinity 50 20 0 414243", "%w 1 72 100 50 20 0 6F6B",
        ];
        var scan = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.Stream(TextLayer.Marker + "\n%f 0 0 0 612 792\n" + string.Join("\n", hostile) + "\n"),
        ]);
        var word = Assert.Single(TextLayer.Words(scan, null)[0].Words);
        Assert.Equal(new OcrWord("ok", new RectD(72, 100, 50, 20), 0, SuspectReasons.NotInDictionary), word);
        Assert.Equal("fine", Assert.Single(TextLayer.Words(TextLayer.Correct(scan, null, 0, 0, "fine"), null)[0].Words).Text);
    }

    [Fact]
    public void APageWithoutAnInkvoltLayerHasNoWordsToReview()
    {
        var data = TestPdf.Make(1);
        Assert.Empty(TextLayer.Words(data, null));
        Assert.Throws<InvalidOperationException>(() => TextLayer.Correct(data, null, 0, 0, "x"));
    }
}
